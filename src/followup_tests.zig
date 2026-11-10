const std = @import("std");
const query = @import("root.zig");
const number = @import("number.zig");
const t = std.testing;

fn expectStream(source: []const u8, inputs: []const []const u8, expected: []const u8, options: query.StreamOptions) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, options);
    defer stream.deinit();
    for (inputs) |input| {
        if (!stream.needsInput()) break;
        _ = try stream.feed(input);
    }
    try stream.finish();
    try t.expectEqualStrings(expected, output.written());
}

fn expectFailure(source: []const u8, input: []const u8, message: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, input, &output.writer, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
}

test "followup depth counts empty containers at exactly 128 levels" {
    var arrays: [256]u8 = undefined;
    @memset(arrays[0..128], '[');
    @memset(arrays[128..], ']');
    var expected: [257]u8 = undefined;
    @memcpy(expected[0..256], &arrays);
    expected[256] = '\n';
    try expectStream(".", &.{&arrays}, &expected, .{});
    try expectFailure("collect", &arrays, "nesting");
    try expectFailure("[.]", &arrays, "nesting");
    try expectFailure("[.] == [.]", &arrays, "comparison nesting");
    try expectStream("collect | each", &.{&arrays}, &expected, .{});
    try expectStream("collect", &.{arrays[1..255]}, &expected, .{});
    var objects = std.Io.Writer.Allocating.init(t.allocator);
    defer objects.deinit();
    for (0..127) |_| try objects.writer.writeAll("{\"x\":");
    try objects.writer.writeAll("{}");
    for (0..127) |_| try objects.writer.writeByte('}');
    try expectFailure("collect", objects.written(), "nesting");
}

test "followup raw output writes strings and keeps other JSON values" {
    try expectStream("each", &.{"[\"hello\",\"a\\nb\",null,false,2,{\"x\":1}]"}, "hello\na\nb\nnull\nfalse\n2\n{\"x\":1}\n", .{ .raw_output = true });
    try expectStream("sort", &.{ "\"z\"", "\"a\"" }, "a\nz\n", .{ .raw_output = true });
}

test "followup arithmetic precedence exact decimals unary and remainder" {
    try expectStream("[1+2*3,(1+2)*3,1-2,-.x,12/3,-7%3,7%-3,1.0+1e3,1e-2 == 0.01]", &.{"{\"x\":5}"}, "[7,9,-1,-5,4,-1,1,1001,true]\n", .{});
    try expectStream("-0.125", &.{"null"}, "-0.125\n", .{});
    try expectStream("--2", &.{"null"}, "2\n", .{});
    try expectStream("(-0.0)+0", &.{"null"}, "0\n", .{});
    try expectStream("170141183460469231731687303715884105727 + 0", &.{"null"}, "170141183460469231731687303715884105727\n", .{});
    try expectStream("-170141183460469231731687303715884105728 + 0", &.{"null"}, "-170141183460469231731687303715884105728\n", .{});
}

test "followup arithmetic rejects rounding type coercion division zero and overflow" {
    try expectFailure("1/2", "null", "must be exact");
    try expectFailure("1/0", "null", "by zero");
    try expectFailure("1%0", "null", "by zero");
    try expectFailure("0.5+1", "null", "fractional");
    try expectFailure("true+1", "null", "expects a number");
    try expectFailure("\"1\"+1", "null", "expects a number");
    try expectFailure("170141183460469231731687303715884105727+1", "null", "128-bit");
    try expectFailure("-170141183460469231731687303715884105728-1", "null", "128-bit");
    try expectFailure("170141183460469231731687303715884105728+0", "null", "128-bit");
    try expectFailure("1e999+0", "null", "128-bit");
    try expectFailure("-(-170141183460469231731687303715884105728)", "null", "128-bit");
    try expectFailure("-170141183460469231731687303715884105728/-1", "null", "128-bit");
    try expectStream("-170141183460469231731687303715884105728%-1", &.{"null"}, "0\n", .{});
    try t.expectEqual(@as(i128, 100), try number.integer("100.0000"));
    try t.expectEqual(@as(i128, 1), try number.integer("0.001e3"));
    try t.expectEqual(@as(i128, 0), try number.integer("0e999999999999999999999"));
}

test "followup sum spans streams and composes with early stops and aggregates" {
    try expectStream("sum", &.{ "9007199254740993", "1.0", "1e2", "-5" }, "9007199254741089\n", .{});
    try expectStream("sum", &.{}, "0\n", .{ .max_collect_bytes = 0 });
    try expectStream("each | take(2) | sum | collect", &.{"[2,3,\"ignored\"]"}, "[5]\n", .{});
    try expectStream("sum | take(0) | sum", &.{"bad"}, "0\n", .{});
    try expectStream("collect | each | sum | sum", &.{ "1", "2" }, "3\n", .{});
    try expectFailure("each | sum", "[1,0.5]", "fractional");
    try expectFailure("each | sum", "[170141183460469231731687303715884105727,1]", "128-bit");
}

test "followup sorting is stable across records and preserves numeric spelling" {
    try expectStream("sort_by(.key) | .id", &.{ "{\"key\":1.0,\"id\":\"first\"}", "{\"key\":0,\"id\":\"zero\"}", "{\"key\":1e0,\"id\":\"second\"}" }, "\"zero\"\n\"first\"\n\"second\"\n", .{});
    try expectStream("sort", &.{ "9007199254740993", "-1", "9007199254740992", "1.0", "1e0" }, "-1\n1.0\n1e0\n9007199254740992\n9007199254740993\n", .{});
    try expectStream("sort", &.{ "\"é\"", "\"Z\"", "\"a\"" }, "\"Z\"\n\"a\"\n\"é\"\n", .{});
    try expectStream("sort | take(2) | collect", &.{ "3", "1", "2" }, "[1,2]\n", .{});
    try expectStream("sort | count", &.{}, "0\n", .{ .max_collect_bytes = 0 });
    try expectStream("take(0) | sort | collect", &.{"bad"}, "[]\n", .{});
    try expectFailure("each | sort", "[1,\"1\"]", "all be numbers");
    try expectFailure("sort", "null", "all be numbers");
    try expectFailure("sort_by(.key?)", "{}", "missing value");
    try expectFailure("sort", "1e999999999999999999999", "exponent");
}

test "followup grouping uses structural equality and first-seen key order" {
    try expectStream("each | group_by(.k) | [.[0].k, .]", &.{"[{\"k\":\"z\",\"v\":1},{\"k\":\"a\",\"v\":2},{\"k\":\"z\",\"v\":3}]"}, "[\"z\",[{\"k\":\"z\",\"v\":1},{\"k\":\"z\",\"v\":3}]]\n[\"a\",[{\"k\":\"a\",\"v\":2}]]\n", .{});
    try expectStream("group_by(.)", &.{ "{\"a\":1,\"b\":2}", "{\"b\":2.0,\"a\":1e0}", "false", "null", "false", "[1,2]", "[2,1]" }, "[{\"a\":1,\"b\":2},{\"b\":2.0,\"a\":1e0}]\n[false,false]\n[null]\n[[1,2]]\n[[2,1]]\n", .{});
    try expectStream("group_by(.)", &.{ "9007199254740993", "9007199254740992", "9007199254740993.0" }, "[9007199254740993,9007199254740993.0]\n[9007199254740992]\n", .{});
    try expectStream("group_by(.) | count", &.{}, "0\n", .{ .max_collect_bytes = 0 });
    try expectStream("group_by(.) | take(1) | each | sum", &.{ "2", "1", "2" }, "4\n", .{});
    try expectFailure("group_by(.k?)", "{}", "missing value");
    try expectFailure("group_by(.)", "{\"n\":1e999999999999999999999}", "exponent");
}

test "followup retained keys and values survive input buffer reuse" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "sort_by(.k) | group_by({k:.k}) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var buffer: [64]u8 = undefined;
    for ([_][]const u8{ "{\"k\":2,\"v\":\"two\"}", "{\"k\":1,\"v\":\"one\"}" }) |input| {
        @memcpy(buffer[0..input.len], input);
        _ = try stream.feed(buffer[0..input.len]);
        @memset(&buffer, 'x');
    }
    try stream.finish();
    try stream.finish();
    try t.expectEqualStrings("[[{\"k\":1,\"v\":\"one\"}],[{\"k\":2,\"v\":\"two\"}]]\n", output.written());
}

test "followup retaining stages share budgets and poison on budget or writer failure" {
    for ([_][]const u8{ "sort", "group_by(.)", "collect | each | sort" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.fixed(&.{});
        var stream = try program.start(t.allocator, &output, &diagnostic, .{ .max_collect_bytes = 0 });
        defer stream.deinit();
        try t.expectError(error.EvaluationFailed, stream.feed("1"));
        try t.expect(std.mem.indexOf(u8, diagnostic.message, "memory limit") != null);
        try t.expectError(error.StreamFailed, stream.finish());
    }
    for ([_][]const u8{ "sort | collect", "group_by(.) | collect" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.fixed(&.{});
        var stream = try program.start(t.allocator, &output, &diagnostic, .{});
        defer stream.deinit();
        _ = try stream.feed("1");
        try t.expectError(error.WriteFailed, stream.finish());
        try t.expectError(error.StreamFailed, stream.feed("2"));
    }
}

test "followup sort handoff charges both retained owners to the shared budget" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "sort | sort", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var backing = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    var stream = try program.start(backing.allocator(), &output.writer, &diagnostic, .{ .max_collect_bytes = 22000 });
    defer stream.deinit();
    var input: [4098]u8 = @splat('a');
    input[0] = '"';
    input[input.len - 1] = '"';
    _ = try stream.feed(&input);
    try t.expectError(error.EvaluationFailed, stream.finish());
    try t.expectEqual(@as(usize, 7), diagnostic.offset);
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "memory limit") != null);
    try t.expectEqualStrings("", output.written());
}

test "followup diagnostics retain JSON paths and JSON syntax locations" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".users | each | .missing", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.fixed(&.{});
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, "{\"users\":[{}]}", &output, &diagnostic));
    try t.expectEqualStrings("$[\"users\"][0][\"missing\"]", diagnostic.path.bytes[0..diagnostic.path.len]);
    try t.expectError(error.SyntaxError, program.run(t.allocator, "{\n \"x\": nope\n}", &output, &diagnostic));
    try t.expectEqual(@as(u64, 2), diagnostic.input_line);
    try t.expect(diagnostic.input_column > 1);
    try t.expect(diagnostic.input_offset.? < 16);
}

test "followup path diagnostics distinguish missing input from constructed output" {
    for ([_]struct { source: []const u8, path: []const u8 }{
        .{ .source = ".missing?", .path = "$[\"missing\"]" },
        .{ .source = "sort_by(.missing?)", .path = "$[\"missing\"]" },
        .{ .source = "where(.x)", .path = "$[\"x\"]" },
        .{ .source = ".missing? == 0", .path = "$[\"missing\"]" },
        .{ .source = "not .x", .path = "$[\"x\"]" },
        .{ .source = "matches(.x, \"a\")", .path = "$[\"x\"]" },
        .{ .source = "{made:1} | .missing", .path = "" },
        .{ .source = "collect | each | .missing", .path = "" },
    }) |case| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, case.source, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.fixed(&.{});
        try t.expectError(error.EvaluationFailed, program.run(t.allocator, "{\"x\":1}", &output, &diagnostic));
        try t.expectEqualStrings(case.path, diagnostic.path.bytes[0..diagnostic.path.len]);
    }
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "sort_by(.key) | group_by(.key) | each | .value+1 | sum | collect", &diagnostic);
    defer program.deinit();
    var buffer: [100]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("{\"key\":\"b\",\"value\":2}");
    _ = try stream.feed("{\"key\":\"a\",\"value\":3}");
    _ = try stream.feed("{\"key\":\"a\",\"value\":4}");
    try stream.finish();
    try t.expectEqualStrings("[12]\n", output.buffered());
}

test "followup allocation failures release sorting grouping arithmetic and downstream state" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try allocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, allocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
