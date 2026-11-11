const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

fn expectOutput(source: []const u8, input: []const u8, expected: []const u8, options: query.StreamOptions) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, options);
    defer stream.deinit();
    _ = try stream.feed(input);
    try stream.finish();
    try t.expectEqualStrings(expected, output.written());
}

fn expectFailure(source: []const u8, input: []const u8, message: []const u8, path: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, input, &output.writer, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
    try t.expectEqualStrings(path, diagnostic.path.bytes[0..diagnostic.path.len]);
    try t.expectEqualStrings("", output.written());
}

test "serialization compact text preserves all JSON kinds insertion order and exact number tokens" {
    try expectOutput("tojson(.)", "{ \"z\": [null, true, false, 9007199254740993, -0, 1.2300e+2], \"a\": {} }", "{\"z\":[null,true,false,9007199254740993,-0,1.2300e+2],\"a\":{}}\n", .{ .raw_output = true });
    try expectOutput("tojson(.)", "[1e999999999999999999999]", "[1e999999999999999999999]\n", .{ .raw_output = true });
    try expectOutput("[tojson(null),tojson(false),tojson([]),tojson({})]", "null", "[\"null\",\"false\",\"[]\",\"{}\"]\n", .{});
}

test "serialization escapes controls quotes and slashes while retaining UTF-8" {
    try expectOutput("tojson(.)", "\"é😀\\n\\t\\r\\b\\f\\u0000\\\"\\\\/\"", "\"é😀\\n\\t\\r\\b\\f\\u0000\\\"\\\\/\"\n", .{ .raw_output = true });
    try expectOutput("tojson({\"a\\n\": .})", "\"x\"", "{\"a\\n\":\"x\"}\n", .{ .raw_output = true });
    try expectOutput("tojson(.)", "\"\\u00e9\\ud83d\\ude00\"", "\"é😀\"\n", .{ .raw_output = true });
}

test "serialization size separates UTF-8 bytes Unicode scalars and JSON escapes" {
    try expectOutput("[length(.),byte_length(.),length(tojson(.)),byte_length(tojson(.))]", "\"é😀\"", "[2,6,4,8]\n", .{});
    try expectOutput("[length(.),byte_length(.),length(tojson(.)),byte_length(tojson(.))]", "\"e\\u0301\\n\"", "[3,4,6,7]\n", .{});
    try expectOutput("{text:tojson(.),bytes:byte_length(tojson(.)),characters:length(tojson(.))}", "{\"x\":\"é\"}", "{\"text\":\"{\\\"x\\\":\\\"é\\\"}\",\"bytes\":10,\"characters\":9}\n", .{});
    try expectOutput("[byte_length(\"\"),byte_length(tojson(\"\")),byte_length(tojson(100))]", "null", "[0,2,3]\n", .{});
}

test "serialization errors retain operand paths and reject wrong types and arity" {
    try expectFailure("byte_length(.x)", "{\"x\":[]}", "expects a string", "$[\"x\"]");
    try expectFailure("byte_length(.x?)", "{}", "missing value", "$[\"x\"]");
    try expectFailure("tojson(.x?)", "{}", "missing value", "$[\"x\"]");
    try expectFailure("map(.rows,byte_length(.name))", "{\"rows\":[{\"name\":null}]}", "expects a string", "$[\"rows\"][0][\"name\"]");
    try expectFailure("{text:tojson(.x),missing}", "{\"x\":1}", "absent", "$[\"missing\"]");
    for ([_][]const u8{ "tojson()", "tojson(.,.)", "byte_length()", "byte_length(.,.)", "tojson(. | collect)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

test "serialization rejects too-deep constructed values even when final output is a string" {
    var input = std.Io.Writer.Allocating.init(t.allocator);
    defer input.deinit();
    for (0..128) |_| try input.writer.writeByte('[');
    try input.writer.writeByte('0');
    for (0..128) |_| try input.writer.writeByte(']');
    try expectOutput("byte_length(tojson(.))", input.written(), "257\n", .{});
    try expectFailure("tojson([.])", input.written(), "serialization nesting", "");
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "map(.items,{text:tojson(.),bytes:byte_length(tojson(.))}) | collect", &diagnostic);
    defer program.deinit();
    var bytes: [200]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    var input = "{\"items\":[\"é😀\",9007199254740993]}".*;
    _ = try stream.feed(&input);
    @memset(&input, 'x');
    try stream.finish();
    try t.expectEqualStrings("[[{\"text\":\"\\\"é😀\\\"\",\"bytes\":8},{\"text\":\"9007199254740993\",\"bytes\":16}]]\n", output.buffered());
}

test "serialization allocation failures release encoded strings and retained results" {
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
