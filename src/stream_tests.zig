const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

fn expectStream(source: []const u8, inputs: []const []const u8, expected: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    for (inputs) |input| {
        if (!stream.needsInput()) break;
        _ = try stream.feed(input);
    }
    try stream.finish();
    try t.expectEqualStrings(expected, output.written());
}

test "stream aggregates cover all records and emit only on finish" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "where(.ok) | count", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    try t.expect(try stream.feed("{\"ok\":true}"));
    try t.expect(try stream.feed("{\"ok\":false}"));
    try t.expect(try stream.feed("{\"ok\":true}"));
    try t.expectEqualStrings("", output.written());
    try stream.finish();
    try t.expectEqualStrings("2\n", output.written());
    try expectStream("count", &.{"[1,2,3]"}, "1\n");
    try expectStream("each | count", &.{ "[1,2]", "[]", "[3]" }, "3\n");
}

test "stream empty input finalizes every aggregate in pipeline order" {
    try expectStream("count", &.{}, "0\n");
    try expectStream("collect", &.{}, "[]\n");
    try expectStream("each | count", &.{"[]"}, "0\n");
    try expectStream("where(false) | collect", &.{ "1", "2" }, "[]\n");
    try expectStream("count | collect", &.{}, "[0]\n");
    try expectStream("count | count", &.{}, "1\n");
    try expectStream("collect | collect", &.{}, "[[]]\n");
    try expectStream("collect | each | count", &.{}, "0\n");
}

test "stream take counts values at its own stage and closes upstream" {
    try expectStream("each | take(2) | collect", &.{"[1,2,3]"}, "[1,2]\n");
    try expectStream("each | where(. > 2) | take(1) | count", &.{"[1,2,3,4]"}, "1\n");
    try expectStream("take(2) | where(false) | count", &.{ "1", "2", "3" }, "0\n");
    try expectStream("count | take(1)", &.{ "1", "2", "3" }, "3\n");
    try expectStream("collect | each | take(2) | count", &.{ "1", "2", "3" }, "2\n");
    try expectStream("take(2) | collect | each | take(1) | count", &.{ "1", "2", "3" }, "1\n");
    try expectStream("collect | each | count | collect | each", &.{ "1", "2", "3" }, "3\n");
    try expectStream("take(18446744073709551615) | count", &.{ "1", "2" }, "2\n");
}

test "stream take zero bypasses input and upstream expressions" {
    try expectStream("take(0) | count", &.{"not JSON"}, "0\n");
    try expectStream("take(0) | collect", &.{"not JSON"}, "[]\n");
    try expectStream("count | take(0) | collect", &.{"not JSON"}, "[]\n");
    try expectStream("collect | take(0) | count", &.{"not JSON"}, "0\n");
    try expectStream(".missing | take(0) | count | collect", &.{"not JSON"}, "[0]\n");
    try expectStream("take(0) | count | each | take(0) | count", &.{}, "0\n");
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "take(0) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try program.run(t.allocator, "not JSON", &output.writer, &diagnostic);
    try t.expectEqualStrings("[]\n", output.written());
}

test "stream take skips later evaluation failures in nested expansions" {
    try expectStream("each | .x | take(1) | collect", &.{"[{\"x\":1},{}]"}, "[1]\n");
    try expectStream("each | each | .x | take(1) | count", &.{"[[{\"x\":1},{}],null]"}, "1\n");
    try expectStream("collect | each | .x | take(1) | count", &.{ "{\"x\":1}", "{}" }, "1\n");
    try expectStream("each | take(3) | where(. < 0) | take(1) | collect", &.{"[1,2,3,null]"}, "[]\n");
}

test "stream collect owns projection containers and reused input bytes" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{record: ., flag: false} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var buffer: [128]u8 = undefined;
    const inputs = [_][]const u8{
        "{\"name\":\"Ada\",\"id\":9007199254740993,\"tags\":[\"one\",null]}",
        "{\"name\":\"Cy\",\"id\":1.234567890123456789e500,\"tags\":[]}",
    };
    for (inputs) |input| {
        @memcpy(buffer[0..input.len], input);
        _ = try stream.feed(buffer[0..input.len]);
        @memset(&buffer, 'x');
    }
    try t.expectEqualStrings("", output.written());
    try stream.finish();
    try t.expectEqualStrings(
        "[{\"record\":{\"name\":\"Ada\",\"id\":9007199254740993,\"tags\":[\"one\",null]},\"flag\":false},{\"record\":{\"name\":\"Cy\",\"id\":1.234567890123456789e500,\"tags\":[]},\"flag\":false}]\n",
        output.written(),
    );
}

test "stream finish is idempotent and rejected feeds cannot corrupt completion" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "take(1) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    try t.expect(!try stream.feed("1"));
    try t.expect(!stream.needsInput());
    try t.expect(!try stream.feed("invalid ignored input"));
    try stream.finish();
    try stream.finish();
    try t.expectError(error.StreamFinished, stream.feed("2"));
    try stream.finish();
    try t.expectEqualStrings("[1]\n", output.written());
}

test "stream sessions have independent aggregate state with one compiled program" {
    var a_diag: query.Diagnostic = .{};
    var b_diag: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect", &a_diag);
    defer program.deinit();
    var a_output = std.Io.Writer.Allocating.init(t.allocator);
    defer a_output.deinit();
    var b_output = std.Io.Writer.Allocating.init(t.allocator);
    defer b_output.deinit();
    var a = try program.start(t.allocator, &a_output.writer, &a_diag, .{});
    defer a.deinit();
    var b = try program.start(t.allocator, &b_output.writer, &b_diag, .{});
    defer b.deinit();
    _ = try a.feed("1");
    _ = try b.feed("2");
    _ = try a.feed("3");
    try b.finish();
    try a.finish();
    try t.expectEqualStrings("[1,3]\n", a_output.written());
    try t.expectEqualStrings("[2]\n", b_output.written());
}

test "stream invalid input discards retained aggregates and poisons the session" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("{\"value\":[1,2]}");
    try t.expectError(error.SyntaxError, stream.feed("{bad}"));
    try t.expect(!stream.needsInput());
    try t.expectError(error.StreamFailed, stream.feed("3"));
    try t.expectError(error.StreamFailed, stream.finish());
    try t.expectEqualStrings("", output.written());
}

test "stream errors in the final taken value and aggregate output are not hidden" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "take(1) | .missing | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    try t.expectError(error.EvaluationFailed, stream.feed("{}"));
    try t.expectError(error.StreamFailed, stream.finish());
    try t.expectEqualStrings("", output.written());

    var aggregated = try query.Program.compile(t.allocator, "count | .missing", &diagnostic);
    defer aggregated.deinit();
    var final = try aggregated.start(t.allocator, &output.writer, &diagnostic, .{});
    defer final.deinit();
    _ = try final.feed("1");
    try t.expectError(error.EvaluationFailed, final.finish());
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "expects an object") != null);
}

test "stream output failures discard buffered collectors" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect | each | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.fixed(&.{});
    var stream = try program.start(t.allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("{\"value\":[1,2]}");
    try t.expectError(error.WriteFailed, stream.finish());
    try t.expectError(error.StreamFailed, stream.finish());
}

test "stream collection budget distinguishes configured limit from allocation failure" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var empty = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 0 });
    defer empty.deinit();
    try empty.finish();
    try t.expectEqualStrings("[]\n", output.written());
    var limited = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 0 });
    defer limited.deinit();
    try t.expectError(error.EvaluationFailed, limited.feed("null"));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "memory limit") != null);
    try t.expectError(error.StreamFailed, limited.finish());
    try t.expectEqualStrings("[]\n", output.written());

    var count_program = try query.Program.compile(t.allocator, "count", &diagnostic);
    defer count_program.deinit();
    var counter = try count_program.start(t.allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 0 });
    defer counter.deinit();
    for (0..1000) |_| _ = try counter.feed("0");
    try counter.finish();
    try t.expectEqualStrings("[]\n1000\n", output.written());
}

test "stream collection growth stays within its retained allocation budget" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var accounting = t.FailingAllocator.init(t.allocator, .{});
    var stream = try program.start(accounting.allocator(), &output.writer, &diagnostic, .{ .max_collect_bytes = 4096 });
    defer stream.deinit();
    const baseline = accounting.allocated_bytes - accounting.freed_bytes;
    var accepted: usize = 0;
    var exceeded = false;
    for (0..200) |_| {
        _ = stream.feed("{\"message\":\"retained bytes\"}") catch |err| {
            try t.expectEqual(error.EvaluationFailed, err);
            try t.expect(std.mem.indexOf(u8, diagnostic.message, "memory limit") != null);
            exceeded = true;
            break;
        };
        accepted += 1;
        try t.expect(accounting.allocated_bytes - accounting.freed_bytes - baseline <= 4096);
    }
    try t.expect(accepted > 0);
    try t.expect(exceeded);
    try t.expectEqual(baseline, accounting.allocated_bytes - accounting.freed_bytes);
    try t.expectEqualStrings("", output.written());
}

test "stream collectors share one budget during aggregate handoff" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 8192 });
    defer stream.deinit();
    var input: [4098]u8 = @splat('a');
    input[0] = '"';
    input[input.len - 1] = '"';
    _ = try stream.feed(&input);
    try t.expectError(error.EvaluationFailed, stream.finish());
    try t.expectEqual(@as(usize, 10), diagnostic.offset);
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "memory limit") != null);
    try t.expectEqualStrings("", output.written());
}

test "stream deinit discards unfinished retained input without emitting" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    {
        var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
        defer stream.deinit();
        _ = try stream.feed("{\"name\":\"Ada\"}");
    }
    try t.expectEqualStrings("", output.written());
}

test "stream stage grammar rejects invalid arguments and scalar aggregates" {
    const cases = [_][]const u8{
        "take",      "take()",                     "take(-1)",  "take(-0)",   "take(1.0)", "take(1e2)",
        "take(01)",  "take(18446744073709551616)", "take(.n)",  "take(true)", "take(1,2)", "count()",
        "collect()", "{n:count}",                  "[collect]",
    };
    for (cases) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
        try t.expect(diagnostic.message.len > 0);
    }
    try expectStream(".count | each | .take", &.{"{\"count\":[{\"take\":1}]}"}, "1\n");
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "where(matches(.name, \"^A\")) | {name:.name, values:[.id,.enabled? ?? false]} | take(2) | collect | each | collect", &diagnostic);
    defer program.deinit();
    var buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("{\"name\":\"Ada\",\"id\":9007199254740993}");
    _ = try stream.feed("{\"name\":\"Al\",\"id\":2}");
    try stream.finish();
    try t.expectEqualStrings("[{\"name\":\"Ada\",\"values\":[9007199254740993,false]},{\"name\":\"Al\",\"values\":[2,false]}]\n", output.buffered());
}

test "stream allocation failures release state and every retained handoff" {
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
