const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

fn expect(source: []const u8, inputs: []const []const u8, expected: []const u8) !void {
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
    try stream.finish();
    try t.expectEqualStrings(expected, output.written());
}

fn failure(source: []const u8, input: []const u8, message: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    try t.expectError(error.EvaluationFailed, stream.feed(input));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
    try t.expectEqualStrings("", output.written());
    try t.expectError(error.StreamFailed, stream.finish());
}

test "key index builds once and owns exact records across reused input" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "index_by(.path) | map([\"é\",\"other\"],root()[.]) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var input = "{\"path\":\"é\",\"size\":9007199254740993,\"meta\":[false,null]}".*;
    _ = try stream.feed(&input);
    @memset(&input, 'x');
    _ = try stream.feed("{\"path\":\"other\",\"size\":1.2300e-4}");
    try t.expectEqualStrings("", output.written());
    try stream.finish();
    try t.expectEqualStrings("[[{\"path\":\"é\",\"size\":9007199254740993,\"meta\":[false,null]},{\"path\":\"other\",\"size\":1.2300e-4}]]\n", output.written());
    try t.expectEqual(@as(usize, 0), stream.execution.budget.used);
    try expect("index_by(.missing)", &.{}, "{}\n");
    try expect("index_by(tojson(.)) | [.[\"false\" ?? \"x\"],.[\"null\" ?? \"x\"]]", &.{ "false", "null" }, "[false,null]\n");
}

test "key index computed access distinguishes missing null and false" {
    const input = "{\"table\":{\"é\\\"\":9007199254740993,\"nil\":null,\"no\":false},\"key\":\"é\\\"\"}";
    try expect("[.table[.key],exists(.table[(\"nil\")]?),.table[(\"nil\")]?,exists(.table[(\"no\")]?),.table[(\"no\")]? ?? true,exists(.table[(\"missing\")]?)]", &.{input}, "[9007199254740993,true,null,true,false,false]\n");
    try expect(".absent?[.also_absent] ?? 42", &.{"{}"}, "42\n");
    try failure(".table[.key]", "{\"table\":{},\"key\":\"missing\"}", "field or index is absent");
    try failure(".table[.key]?", "{\"table\":null,\"key\":\"x\"}", "expects an object");
    try failure(".table[.key]?", "{\"table\":{},\"key\":0}", "must be a string");
    try failure(".[root()]?", "[]", "expects an object");
    try failure(".table[.key?]?", "{\"table\":{}}", "missing value");
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".table[.key]", &diagnostic);
    defer program.deinit();
    var bytes: [0]u8 = .{};
    var writer = std.Io.Writer.fixed(&bytes);
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, "{\"table\":{},\"key\":\"x\"}", &writer, &diagnostic));
    try t.expectEqualStrings("$[\"table\"][\"x\"]", diagnostic.path.bytes[0..diagnostic.path.len]);
}

test "key index root scope is stable inside nested array bodies and resets per stage" {
    try expect("map(.rows,{label:root().label,name:.name,nested:map(.ids,root().label)})", &.{"{\"label\":\"outer\",\"rows\":[{\"name\":\"first\",\"ids\":[1,2]},{\"name\":\"second\",\"ids\":[]}]}"}, "[{\"label\":\"outer\",\"name\":\"first\",\"nested\":[\"outer\",\"outer\"]},{\"label\":\"outer\",\"name\":\"second\",\"nested\":[]}]\n");
    try expect("each | {old:root()} | root()", &.{"[1,2]"}, "{\"old\":1}\n{\"old\":2}\n");
    try expect("all(.items,any(.,. == root().target))", &.{"{\"target\":2,\"items\":[[1,2],[2]]}"}, "true\n");
    for ([_][]const u8{ "root(1)", "index_by()", "index_by(.,.)", "update(.,.[.key],0)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

test "key index rejects decoded duplicates missing keys and wrong types without totals" {
    try failure("each | index_by(.path)", "[{\"path\":\"a\"},{\"path\":\"\\u0061\"}]", "duplicate key");
    try failure("each | index_by(.path)", "[{\"path\":\"é\"},{\"path\":\"\\u00e9\"}]", "duplicate key");
    try failure("each | index_by(.path)", "[{\"path\":\"a\"},{\"path\":1}]", "must be a string");
    try failure("each | index_by(.path)", "[{\"path\":\"a\"},{}]", "field or index is absent");
    var deep: [256]u8 = undefined;
    @memset(deep[0..128], '[');
    @memset(deep[128..], ']');
    try failure("index_by(\"key\")", &deep, "output wrapper");
}

test "key index left inner and unmatched projections preserve left ordering" {
    var diagnostic: query.Diagnostic = .{};
    const left = "[{\"path\":\"b\",\"size\":2},{\"path\":\"a\",\"size\":9007199254740993},{\"path\":\"removed\",\"size\":1}]";
    const right = "[{\"path\":\"a\",\"size\":9007199254740994},{\"path\":\"b\",\"size\":2},{\"path\":\"added\",\"size\":1}]";
    const prefix = "each | index_by(.path) | map($left,{path:.path,matched:exists(root()[.path]?),before:.size,after:root()[.path]?.size ?? null}) | each";
    const cases = [_]struct { suffix: []const u8, expected: []const u8 }{
        .{ .suffix = "", .expected = "{\"path\":\"b\",\"matched\":true,\"before\":2,\"after\":2}\n{\"path\":\"a\",\"matched\":true,\"before\":9007199254740993,\"after\":9007199254740994}\n{\"path\":\"removed\",\"matched\":false,\"before\":1,\"after\":null}\n" },
        .{ .suffix = " | where(.matched) | .path", .expected = "\"b\"\n\"a\"\n" },
        .{ .suffix = " | where(.matched and .before != .after) | .path", .expected = "\"a\"\n" },
        .{ .suffix = " | where(not .matched) | .path", .expected = "\"removed\"\n" },
    };
    for (cases) |case| {
        const source = try std.mem.concat(t.allocator, u8, &.{ prefix, case.suffix });
        defer t.allocator.free(source);
        var program = try query.Program.compileWithBindings(t.allocator, source, &.{.{ .name = "left", .value = .{ .json = left } }}, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.Allocating.init(t.allocator);
        defer output.deinit();
        try program.run(t.allocator, right, &output.writer, &diagnostic);
        try t.expectEqualStrings(case.expected, output.written());
    }
}

test "key index obeys memory early-stop completion and failed-write contracts" {
    try expect("index_by(.) | take(0) | collect", &.{"invalid"}, "[]\n");
    try expect("take(1) | index_by(.)", &.{ "\"x\"", "invalid" }, "{\"x\":\"x\"}\n");
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "index_by(.)", &diagnostic);
    defer program.deinit();
    var bytes: [0]u8 = .{};
    var output = std.Io.Writer.fixed(&bytes);
    var small = try program.start(t.allocator, &output, &diagnostic, .{ .max_collect_bytes = 1 });
    defer small.deinit();
    try t.expectError(error.EvaluationFailed, small.feed("\"key\""));
    try t.expectEqual(@as(usize, 1), diagnostic.budget.?.limit);
    try t.expectEqual(@as(usize, 0), small.execution.budget.used);
    var failed = try program.start(t.allocator, &output, &diagnostic, .{});
    defer failed.deinit();
    _ = try failed.feed("\"key\"");
    try t.expectError(error.WriteFailed, failed.finish());
    try t.expectError(error.StreamFailed, failed.finish());
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(a, "index_by(.path) | map([\"p0\",\"p11\"],root()[.].path) | collect", &diagnostic);
    defer program.deinit();
    var bytes: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(a, &output, &diagnostic, .{});
    defer stream.deinit();
    var input: [128]u8 = undefined;
    for (0..12) |index| {
        const text = try std.fmt.bufPrint(&input, "{{\"path\":\"p{d}\",\"size\":9007199254740993,\"meta\":[false,null]}}", .{index});
        _ = try stream.feed(text);
        @memset(&input, 'x');
    }
    try t.expect(stream.execution.states[0].index.entries.index_header != null);
    try stream.finish();
    try t.expectEqualStrings("[[\"p0\",\"p11\"]]\n", output.buffered());
}

test "key index allocation failures release hash growth cloned records and lookup outputs" {
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
