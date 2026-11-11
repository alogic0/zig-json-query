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

test "array sum composes with projections nested scopes operators and exact tokens" {
    try expectOutput("{status, total: sum(map(.items, .moves)), empty: sum([])}", "{\"status\":\"reviewed\",\"items\":[{\"moves\":1},{\"moves\":2}]}", "{\"status\":\"reviewed\",\"total\":3,\"empty\":0}\n");
    try expectOutput("sum(.) + 1 == 9007199254740995", "[9007199254740993,1]", "true\n");
    try expectOutput("[sum([1.0,0.001e3,-2,1e3]),sum([-0e99999999999999999999]),sum([170141183460469231731687303715884105727,-1])]", "null", "[1000,0,170141183460469231731687303715884105726]\n");
    try expectOutput("{totals: map(.groups, sum(.values)), name}", "{\"name\":\"outer\",\"groups\":[{\"values\":[1,2]},{\"values\":[]}]}", "{\"totals\":[3,0],\"name\":\"outer\"}\n");
}

test "array sum and stream sum remain distinct with whitespace comments and completion" {
    try expectOutput("sum # array call\n (.) | collect", "[1,2]", "[3]\n");
    try expectOutput("each | sum # stream stage\n | collect", "[1,2]", "[3]\n");
    try expectOutput("each | sum", "[]", "0\n");
    try expectOutput("sum([])", "null", "0\n");
    try expectOutput("each | sum(.) | sum", "[[1,2],[],[3]]", "6\n");
    try expectOutput("{sum}", "{\"sum\":7}", "{\"sum\":7}\n");
}

test "array sum locates types fractions range overflow and missing elements" {
    try expectFailure("sum(.values)", "{\"values\":null}", "expects an array", "$[\"values\"]");
    try expectFailure("sum(.values?)", "{}", "missing value", "$[\"values\"]");
    try expectFailure("sum(.values)", "{\"values\":[1,\"2\"]}", "expects a number", "$[\"values\"][1]");
    try expectFailure("sum(.values)", "{\"values\":[1,0.5]}", "fractional", "$[\"values\"][1]");
    try expectFailure("sum(.values)", "{\"values\":[0,170141183460469231731687303715884105728]}", "128-bit", "$[\"values\"][1]");
    try expectFailure("sum(.values)", "{\"values\":[170141183460469231731687303715884105727,1,-1]}", "128-bit", "$[\"values\"][1]");
    try expectFailure("sum(.values)", "{\"values\":[-170141183460469231731687303715884105728,-1]}", "128-bit", "$[\"values\"][1]");
    try expectFailure("map(.groups, sum(.values))", "{\"groups\":[{\"values\":[]},{\"values\":[true]}]}", "expects a number", "$[\"groups\"][1][\"values\"][0]");
    try expectFailure("sum(map(.values, .))", "{\"values\":[null]}", "expects a number", "");
    try expectFailure("{total: sum(.values), missing}", "{\"values\":[1]}", "absent", "$[\"missing\"]");
}

test "array sum rejects malformed calls and nested stream syntax" {
    for ([_][]const u8{ "sum()", "sum(.,.)", "sum(.,)", "sum(. | each)", "{total: sum}", "sum(collect)", "sum(1,2,3)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

test "array sum generated values agree with wider integer totals" {
    var random = std.Random.DefaultPrng.init(0x20261110);
    for (0..300) |_| {
        var input = std.Io.Writer.Allocating.init(t.allocator);
        defer input.deinit();
        var total: i256 = 0;
        try input.writer.writeByte('[');
        for (0..random.random().uintLessThan(usize, 17)) |i| {
            const term = random.random().int(i64);
            total += term;
            if (i != 0) try input.writer.writeByte(',');
            try input.writer.print("{d}", .{term});
        }
        try input.writer.writeByte(']');
        var expected: [100]u8 = undefined;
        try expectOutput("sum(.)", input.written(), try std.fmt.bufPrint(&expected, "{d}\n", .{total}));
    }
}

fn sumAllocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "{status, total: sum(map(.items, .moves))} | collect", &diagnostic);
    defer program.deinit();
    var bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try program.run(allocator, "{\"status\":\"reviewed\",\"items\":[{\"moves\":1},{\"moves\":2}]}", &output, &diagnostic);
    try t.expectEqualStrings("[{\"status\":\"reviewed\",\"total\":3}]\n", output.buffered());
}

test "array sum allocation failures clean up nested results and retained output" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try sumAllocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, sumAllocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
