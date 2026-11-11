const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

fn expectOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try program.run(t.allocator, input, &output.writer, &diagnostic);
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

test "structural sort orders mixed JSON types arrays and object key sets" {
    try expectOutput("sort_values(.)", "[{\"b\":0},{\"a\":0,\"z\":0},{\"a\":100},{\"a\":1},{},[1,0],[1],[false],false,null,true,1,0,\"a\"]", "[null,false,true,0,1,\"a\",[false],[1],[1,0],{},{\"a\":1},{\"a\":100},{\"a\":0,\"z\":0},{\"b\":0}]\n");
    try expectOutput("sort_values(.)", "[[[1]],[[0,1]],[[0]],[],[[]]]", "[[],[[]],[[0]],[[0,1]],[[1]]]\n");
    try expectOutput("sort_values(.)", "[{\"é\":0},{\"z\":0},{\"A\":1},{\"A\":0}]", "[{\"A\":0},{\"A\":1},{\"z\":0},{\"é\":0}]\n");
}

test "structural uniqueness normalizes numbers and objects but retains the first original representative" {
    try expectOutput("unique(.)", "[{\"z\":0,\"a\":1.0},{\"a\":1e0,\"z\":-0},null,null,false,0,false,[1.0],[1e0],[2]]", "[null,false,0,[1.0],[2],{\"z\":0,\"a\":1.0}]\n");
    try expectOutput("[sort_values(.),unique(.)]", "[9007199254740993,9007199254740992,1e0,1.0,-0,0e10]", "[[-0,0e10,1e0,1.0,9007199254740992,9007199254740993],[-0,1e0,9007199254740992,9007199254740993]]\n");
    try expectOutput("unique(.)", "[[1,2],[2,1],[1,2],\"1\",1,true,false,null]", "[null,false,true,1,\"1\",[1,2],[2,1]]\n");
}

test "structural functions compose with schema discovery scopes postfix and empty arrays" {
    try expectOutput("unique(map(.fixtures,keys(.)))", "{\"fixtures\":[{\"b\":0,\"a\":0},{\"a\":1},{\"a\":2,\"b\":2},{\"c\":0}]}", "[[\"a\"],[\"a\",\"b\"],[\"c\"]]\n");
    try expectOutput("{groups:map(.groups,unique(.)),name}", "{\"name\":\"outer\",\"groups\":[[2,1,2],[]]}", "{\"groups\":[[1,2],[]],\"name\":\"outer\"}\n");
    try expectOutput("sort_values([2,1])[0] + length(unique([]))", "null", "1\n");
    try expectOutput("[sort_values([]),unique([])]", "null", "[[],[]]\n");
}

test "structural failures identify source items and preserve original stream key restrictions" {
    try expectFailure("unique(.values)", "{\"values\":false}", "expects an array", "$[\"values\"]");
    try expectFailure("sort_values(.values?)", "{}", "missing value", "$[\"values\"]");
    try expectFailure("unique(.values)", "{\"values\":[0,{\"x\":1e999999999999999999999}]}", "i64 range", "$[\"values\"][1]");
    try expectFailure("map(.groups,sort_values(.items))", "{\"groups\":[{\"items\":[1e999999999999999999999]}]}", "i64 range", "$[\"groups\"][0][\"items\"][0]");
    try expectFailure("sort_values([1e999999999999999999999])", "null", "i64 range", "");
    try expectFailure("each | sort", "[null,[]]", "all be numbers or all strings", "$[0]");
    try expectFailure("sort_by(.,.)", "[null,[]]", "all be numbers or all strings", "$[0]");
}

test "structural functions reject invalid arity and overdeep computed keys" {
    for ([_][]const u8{ "unique()", "unique(.,.)", "sort_values()", "sort_values(.,.)", "unique(. | each)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
    var input = std.Io.Writer.Allocating.init(t.allocator);
    defer input.deinit();
    for (0..128) |_| try input.writer.writeByte('[');
    try input.writer.writeByte('0');
    for (0..128) |_| try input.writer.writeByte(']');
    try expectFailure("length(unique([[.]]))", input.written(), "comparison nesting", "");
}

test "structural generated sorting and uniqueness agree with a finite ordered universe" {
    const universe = [_][]const u8{ "null", "false", "true", "-1", "0", "1", "\"a\"", "\"b\"", "[]", "[0]", "[0,0]", "[1]", "{}", "{\"a\":0}", "{\"a\":1}", "{\"b\":0}" };
    var random = std.Random.DefaultPrng.init(0x51A7);
    for (0..300) |_| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var input = std.Io.Writer.Allocating.init(a);
        var counts: [universe.len]usize = @splat(0);
        try input.writer.writeByte('[');
        for (0..random.random().uintLessThan(usize, 33)) |index| {
            const rank = random.random().uintLessThan(usize, universe.len);
            counts[rank] += 1;
            if (index != 0) try input.writer.writeByte(',');
            try input.writer.writeAll(universe[rank]);
        }
        try input.writer.writeByte(']');
        for ([_]bool{ false, true }) |unique| {
            var expected = std.Io.Writer.Allocating.init(a);
            try expected.writer.writeByte('[');
            var emitted: usize = 0;
            for (counts, universe) |count, token| {
                for (0..(if (unique) @min(count, 1) else count)) |_| {
                    if (emitted != 0) try expected.writer.writeByte(',');
                    try expected.writer.writeAll(token);
                    emitted += 1;
                }
            }
            try expected.writer.writeAll("]\n");
            try expectOutput(if (unique) "unique(.)" else "sort_values(.)", input.written(), expected.written());
        }
    }
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "{unique:unique(.items),sorted:sort_values(.items)} | collect", &diagnostic);
    defer program.deinit();
    var bytes: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    var input = "{\"items\":[{\"z\":0,\"a\":[1.0]}, {\"a\":[1e0],\"z\":-0},false]}".*;
    _ = try stream.feed(&input);
    @memset(&input, 'x');
    try stream.finish();
    try t.expectEqualStrings("[{\"unique\":[false,{\"z\":0,\"a\":[1.0]}],\"sorted\":[false,{\"z\":0,\"a\":[1.0]},{\"a\":[1e0],\"z\":-0}]}]\n", output.buffered());
}

test "structural allocation failures release comparison copies and retain original representatives safely" {
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
