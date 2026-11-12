const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

test "automation predicate status classifies the last emitted JSON value" {
    for ([_]struct { source: []const u8, input: []const u8, status: u8 }{
        .{ .source = ".", .input = "true", .status = 0 },
        .{ .source = ".", .input = "false", .status = 1 },
        .{ .source = ".", .input = "null", .status = 1 },
        .{ .source = "each", .input = "[false,true]", .status = 0 },
        .{ .source = "each", .input = "[true,null]", .status = 1 },
        .{ .source = "each", .input = "[0,\"\",[],{}]", .status = 0 },
        .{ .source = "each", .input = "[]", .status = 4 },
        .{ .source = "where(false)", .input = "true", .status = 4 },
        .{ .source = "each | take(1)", .input = "[false,true]", .status = 1 },
    }) |case| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, case.source, &diagnostic);
        defer program.deinit();
        var bytes: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        var stream = try program.start(t.allocator, &output, &diagnostic, .{});
        defer stream.deinit();
        _ = try stream.feed(case.input);
        try stream.finish();
        try t.expectEqual(case.status, stream.predicateStatus());
    }
}

test "automation predicate status includes completion aggregates and raw output" {
    for ([_][]const u8{ "count", "collect", "sum", "sort | collect" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        var bytes: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        var stream = try program.start(t.allocator, &output, &diagnostic, .{ .raw_output = true });
        defer stream.deinit();
        try stream.finish();
        try t.expectEqual(@as(u8, 0), stream.predicateStatus());
    }
}

test "automation failed writes do not classify an incomplete emission" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var bytes: [4]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(t.allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    try t.expectError(error.WriteFailed, stream.feed("true"));
    try t.expectEqual(@as(u8, 4), stream.predicateStatus());
    try t.expectError(error.StreamFailed, stream.finish());
}

fn expectBoundOutput(source: []const u8, bindings: []const query.Binding, input: []const u8, expected: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(t.allocator, source, bindings, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try program.run(t.allocator, input, &output.writer, &diagnostic);
    try t.expectEqualStrings(expected, output.written());
}

test "joined stream options imply raw strings and remain session-local" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "each", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var joined = try program.start(t.allocator, &output.writer, &diagnostic, .{ .join_output = true, .sort_keys = true });
    defer joined.deinit();
    _ = try joined.feed("[\"é\\u0000\",1,false,{\"z\":1,\"a\":2},[]]");
    try joined.finish();
    try joined.finish();
    try t.expectEqualStrings("é\x001false{\"a\":2,\"z\":1}[]", output.written());
    var normal = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer normal.deinit();
    _ = try normal.feed("[\"x\"]");
    try normal.finish();
    try t.expectEqualStrings("é\x001false{\"a\":2,\"z\":1}[]\"x\"\n", output.written());
}

test "joined output classifies empty strings but never incomplete writes" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var empty: [0]u8 = .{};
    var empty_writer = std.Io.Writer.fixed(&empty);
    var success = try program.start(t.allocator, &empty_writer, &diagnostic, .{ .join_output = true });
    defer success.deinit();
    _ = try success.feed("\"\"");
    try success.finish();
    try t.expectEqual(@as(u8, 0), success.predicateStatus());
    var bytes: [3]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    var failed = try program.start(t.allocator, &writer, &diagnostic, .{ .join_output = true });
    defer failed.deinit();
    try t.expectError(error.WriteFailed, failed.feed("true"));
    try t.expectEqual(@as(u8, 4), failed.predicateStatus());
    try t.expectError(error.StreamFailed, failed.finish());
}

test "automation external values retain types exact numbers and literal string contents" {
    try expectBoundOutput("[$text, $number, $data[0].value, $flag, $nil]", &.{
        .{ .name = "text", .value = .{ .string = "quote'\"\n$(literal)" } },
        .{ .name = "number", .value = .{ .json = "9007199254740993" } },
        .{ .name = "data", .value = .{ .json = "[{\"value\":1.2300e-4}]" } },
        .{ .name = "flag", .value = .{ .json = "false" } },
        .{ .name = "nil", .value = .{ .json = "null" } },
    }, "null", "[\"quote'\\\"\\n$(literal)\",9007199254740993,1.2300e-4,false,null]\n");
    try expectBoundOutput("{label: $label, ids: map(filter(.rows, .id >= $config.minimum), .id), outer: $label}", &.{
        .{ .name = "label", .value = .{ .string = "run-1" } },
        .{ .name = "config", .value = .{ .json = "{\"minimum\":2}" } },
    }, "{\"rows\":[{\"id\":1},{\"id\":2},{\"id\":3}]}", "{\"label\":\"run-1\",\"ids\":[2,3],\"outer\":\"run-1\"}\n");
}

test "automation compiled bindings own caller buffers and support independent runs" {
    var name = "data".*;
    var value = "{\"key\":9007199254740993}".*;
    var text = "label".*;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(t.allocator, "{data: $data, text: $text}", &.{
        .{ .name = &name, .value = .{ .json = &value } },
        .{ .name = "text", .value = .{ .string = &text } },
    }, &diagnostic);
    defer program.deinit();
    @memset(&name, 'x');
    @memset(&value, 'x');
    @memset(&text, 'x');
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    for (0..2) |_| try program.run(t.allocator, "null", &output.writer, &diagnostic);
    try t.expectEqualStrings("{\"data\":{\"key\":9007199254740993},\"text\":\"label\"}\n{\"data\":{\"key\":9007199254740993},\"text\":\"label\"}\n", output.written());
}

test "automation rejects invalid duplicate unknown and malformed binding names" {
    var diagnostic: query.Diagnostic = .{};
    for ([_][]const u8{ "", "1a", "a-b", "a.b", "a b", "$a", "é" }) |name| try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, ".", &.{.{ .name = name, .value = .{ .string = "" } }}, &diagnostic));
    try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, ".", &.{
        .{ .name = "a", .value = .{ .string = "" } },
        .{ .name = "a", .value = .{ .json = "0" } },
    }, &diagnostic));
    for ([_][]const u8{ "$", "$ a", "$1", "$unknown", "$A" }) |source| try t.expectError(error.InvalidQuery, query.Program.compileWithBindings(t.allocator, source, &.{.{ .name = "a", .value = .{ .json = "true" } }}, &diagnostic));
    try expectBoundOutput("$_a1", &.{.{ .name = "_a1", .value = .{ .json = "true" } }}, "null", "true\n");
}

test "automation validates unused bindings duplicate JSON keys depth and admission limits" {
    var diagnostic: query.Diagnostic = .{};
    for ([_][]const u8{ "", "{bad}", "0 1", "{\"x\":1,\"x\":2}", "[1,]" }) |value| try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, "take(0)", &.{.{ .name = "unused", .value = .{ .json = value } }}, &diagnostic));
    var deep: [258]u8 = undefined;
    @memset(deep[0..129], '[');
    @memset(deep[129..], ']');
    try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, ".", &.{.{ .name = "deep", .value = .{ .json = &deep } }}, &diagnostic));
    try expectBoundOutput("length($deep)", &.{.{ .name = "deep", .value = .{ .json = deep[1..257] } }}, "null", "1\n");
    const too_many: [129]query.Binding = @splat(.{ .name = "a", .value = .{ .string = "" } });
    try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, ".", &too_many, &diagnostic));
    const large = try t.allocator.alloc(u8, query.max_input_bytes + 1);
    defer t.allocator.free(large);
    try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, ".", &.{.{ .name = "large", .value = .{ .string = large } }}, &diagnostic));
    try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, ".", &.{.{ .name = "invalid", .value = .{ .string = &.{0xff} } }}, &diagnostic));
}

fn bindingAllocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(allocator, "map(filter(.items, matches($tag, \"^b\")), {tag: $tag, id: .id+$offset}) | collect", &.{
        .{ .name = "tag", .value = .{ .string = "bound" } },
        .{ .name = "offset", .value = .{ .json = "2" } },
    }, &diagnostic);
    defer program.deinit();
    var bytes: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try program.run(allocator, "{\"items\":[{\"id\":1}]}", &output, &diagnostic);
    try t.expectEqualStrings("[[{\"tag\":\"bound\",\"id\":3}]]\n", output.buffered());
}

test "automation allocation failures release bound data AST regex and retained values" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try bindingAllocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, bindingAllocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
