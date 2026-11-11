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

test "array grouping retains report context and explicitly sorted group summaries" {
    const source = "{passed, statuses: sort_by(map(group_by(.http,.status), {status: .[0].status, count: length(.)}), .status)}";
    try expectOutput(source, "{\"passed\":false,\"http\":[{\"status\":500},{\"status\":200},{\"status\":200},{\"status\":404},{\"status\":500}]}", "{\"passed\":false,\"statuses\":[{\"status\":200,\"count\":2},{\"status\":404,\"count\":1},{\"status\":500,\"count\":2}]}\n");
    try expectOutput(source, "{\"passed\":true,\"http\":[]}", "{\"passed\":true,\"statuses\":[]}\n");
    try expectOutput("map(group_by(., .), length(.))", "[500,200,500,404]", "[2,1,1]\n");
}

test "array grouping uses structural keys numeric normalization and first-seen order" {
    try expectOutput("map(group_by(.,.key),map(.,.id))",
        \\[{"id":"a","key":{"n":1.0,"x":[true,null]}},{"id":"b","key":null},{"id":"c","key":{"x":[true,null],"n":1e0}},{"id":"d","key":null},{"id":"e","key":false},{"id":"f","key":[1,2]},{"id":"g","key":[2,1]},{"id":"h","key":1},{"id":"i","key":"1"}]
    , "[[\"a\",\"c\"],[\"b\",\"d\"],[\"e\"],[\"f\"],[\"g\"],[\"h\"],[\"i\"]]\n");
    try expectOutput("map(group_by(.,{parity: .k % 2}),map(.,.id))", "[{\"id\":0,\"k\":2},{\"id\":1,\"k\":1},{\"id\":2,\"k\":4},{\"id\":3,\"k\":3}]", "[[0,2],[1,3]]\n");
    try expectOutput("map(group_by(., .key? ?? null),length(.))", "[{}, {\"key\":null}, {\"key\":false}]", "[2,1]\n");
}

test "array sorting is stable exact and uses UTF-8 string order" {
    try expectOutput("map(sort_by(.,.k),.id)", "[{\"id\":0,\"k\":9007199254740993},{\"id\":1,\"k\":1e0},{\"id\":2,\"k\":1.00},{\"id\":3,\"k\":9007199254740992}]", "[1,2,3,0]\n");
    try expectOutput("sort_by(., .)", "[\"é\",\"z\",\"Z\",\"a\",\"\"]", "[\"\",\"Z\",\"a\",\"z\",\"é\"]\n");
    try expectOutput("sort_by(., .)", "[1e100,1e-100,-1e100,0.00,-0]", "[-1e100,0.00,-0,1e-100,1e100]\n");
    try expectOutput("sort_by(., length(.))", "[\"bb\",\"a\",\"cc\",\"\"]", "[\"\",\"a\",\"bb\",\"cc\"]\n");
}

test "array keyed calls support postfix operators nesting and original stream forms" {
    try expectOutput("sort_by([3,1,2],.)[0] + 4*2", "null", "9\n");
    try expectOutput("group_by([2,1,2],.)[0][-1] == 2 and true", "null", "true\n");
    try expectOutput("(group_by([2,1,2],.))[1]", "null", "[1]\n");
    try expectOutput("sort_by # array\n ([3,1,2],.) | each | sort_by # stage\n (.) | group_by # stage\n (.) | collect", "null", "[[1],[2],[3]]\n");
    try expectOutput("{name, groups: map(.groups,{id, sorted: sort_by(.ns,.), total: sum(.ns), grouped: group_by(.ns,.)})}", "{\"name\":\"outer\",\"groups\":[{\"id\":0,\"ns\":[2,1,2]},{\"id\":1,\"ns\":[]}]}", "{\"name\":\"outer\",\"groups\":[{\"id\":0,\"sorted\":[1,2,2],\"total\":5,\"grouped\":[[2,2],[1]]},{\"id\":1,\"sorted\":[],\"total\":0,\"grouped\":[]}]}\n");
    try expectOutput("[sort_by([],1/0),group_by([],.missing)]", "null", "[[],[]]\n");
    try expectOutput("{sort_by,group_by}", "{\"sort_by\":1,\"group_by\":2}", "{\"sort_by\":1,\"group_by\":2}\n");
}

test "array keyed functions locate bad sources keys and caller fields" {
    for ([_][]const u8{ "sort_by(.rows,.key)", "group_by(.rows,.key)" }) |source| {
        try expectFailure(source, "{\"rows\":false}", "expects an array", "$[\"rows\"]");
        try expectFailure(source, "{\"rows\":[{\"key\":0},{}]}", "absent", "$[\"rows\"][1][\"key\"]");
        try expectFailure(source, "{\"rows\":[{\"key\":1e999999999999999999999}]}", "i64 range", "$[\"rows\"][0][\"key\"]");
    }
    try expectFailure("group_by(.rows,.key?)", "{\"rows\":[{}]}", "missing value", "$[\"rows\"][0][\"key\"]");
    try expectFailure("group_by(.rows,.key)", "{\"rows\":[{\"key\":{\"n\":1e999999999999999999999}}]}", "i64 range", "$[\"rows\"][0][\"key\"]");
    try expectFailure("sort_by(.rows,.key)", "{\"rows\":[{\"key\":1},{\"key\":\"2\"}]}", "all be numbers or all strings", "$[\"rows\"][1][\"key\"]");
    try expectFailure("sort_by(.rows,.key)", "{\"rows\":[{\"key\":null}]}", "all be numbers or all strings", "$[\"rows\"][0][\"key\"]");
    try expectFailure("sort_by(.rows, keys(.))", "{\"rows\":[{}]}", "all be numbers or all strings", "");
    try expectFailure("map(.groups, sort_by(.rows,.key))", "{\"groups\":[{\"rows\":[]},{\"rows\":[{}]}]}", "absent", "$[\"groups\"][1][\"rows\"][0][\"key\"]");
    try expectFailure("{sorted: sort_by(.rows,.key), missing}", "{\"rows\":[{\"key\":1}]}", "absent", "$[\"missing\"]");
    try expectFailure("map(group_by(.rows,.key), .[0].missing)", "{\"rows\":[{\"key\":1}]}", "absent", "");
}

test "array keyed functions reject bad scalar arity and nested stream expressions" {
    for ([_][]const u8{
        "sort_by()",            "group_by()",        "sort_by(.,)",           "group_by(.,.,.)",       "sort_by(.,.,.)",
        "{x:sort_by(.)}",       "{x:group_by(.)}",   "group_by(. | each, .)", "sort_by(., . | count)", "sort_by(., where(true))",
        "group_by(., .) extra", "sort_by(.,.)[0] +",
    }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

test "array grouping and sorting retained children survive input and key arenas" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{grouped: group_by(.rows, {k:.k}), sorted: sort_by(.rows,.k)} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var session = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer session.deinit();
    var input = "{\"rows\":[{\"k\":2,\"v\":\"second\"},{\"k\":1,\"v\":\"first\"}]}".*;
    _ = try session.feed(&input);
    @memset(&input, 'x');
    _ = try session.feed("{\"rows\":[]}");
    try session.finish();
    try t.expectEqualStrings("[{\"grouped\":[[{\"k\":2,\"v\":\"second\"}],[{\"k\":1,\"v\":\"first\"}]],\"sorted\":[{\"k\":1,\"v\":\"first\"},{\"k\":2,\"v\":\"second\"}]},{\"grouped\":[],\"sorted\":[]}]\n", output.written());
}

test "array keyed temporaries are separate from downstream retention budget" {
    for ([_][]const u8{ "sort_by(.,.)", "group_by(.,.)" }) |source| {
        for ([_]bool{ false, true }) |retained| {
            var diagnostic: query.Diagnostic = .{};
            const pipeline = try std.fmt.allocPrint(t.allocator, "{s}{s}", .{ source, if (retained) " | collect" else "" });
            defer t.allocator.free(pipeline);
            var program = try query.Program.compile(t.allocator, pipeline, &diagnostic);
            defer program.deinit();
            var output = std.Io.Writer.Allocating.init(t.allocator);
            defer output.deinit();
            var session = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 0 });
            defer session.deinit();
            if (retained) {
                try t.expectError(error.EvaluationFailed, session.feed("[2,1,2]"));
                try t.expect(std.mem.indexOf(u8, diagnostic.message, "collect exceeded") != null);
                try t.expectError(error.StreamFailed, session.finish());
                try t.expectEqualStrings("", output.written());
            } else {
                _ = try session.feed("[2,1,2]");
                try session.finish();
                try t.expect(output.written().len > 0);
            }
        }
    }
}

test "array sorting and grouping generated results match independent bounded models" {
    var random = std.Random.DefaultPrng.init(0x600D);
    for (0..250) |_| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var input = std.Io.Writer.Allocating.init(a);
        var expected = std.Io.Writer.Allocating.init(a);
        var keys: [24]u8 = undefined;
        const length = random.random().uintLessThan(usize, keys.len + 1);
        try input.writer.writeByte('[');
        for (keys[0..length], 0..) |*key, index| {
            key.* = random.random().uintLessThan(u8, 4);
            if (index != 0) try input.writer.writeByte(',');
            try input.writer.print("{{\"key\":{d},\"id\":{d}}}", .{ key.*, index });
        }
        try input.writer.writeByte(']');
        // Sorting oracle enumerates bounded keys rather than sorting rows.
        try expected.writer.writeByte('[');
        var count: usize = 0;
        for (0..4) |key| for (keys[0..length], 0..) |candidate, index| {
            if (candidate != key) continue;
            if (count != 0) try expected.writer.writeByte(',');
            try expected.writer.print("{d}", .{index});
            count += 1;
        };
        try expected.writer.writeAll("]\n");
        try expectOutput("map(sort_by(.,.key),.id)", input.written(), expected.written());

        // Grouping oracle directly indexes buckets, emitting at first sight.
        var buckets: [4]std.ArrayList(usize) = @splat(.empty);
        var order: std.ArrayList(u8) = .empty;
        for (keys[0..length], 0..) |key, index| {
            if (buckets[key].items.len == 0) try order.append(a, key);
            try buckets[key].append(a, index);
        }
        var grouped = std.Io.Writer.Allocating.init(a);
        try std.json.Stringify.value(blk: {
            var groups: std.ArrayList([]const usize) = .empty;
            for (order.items) |key| try groups.append(a, buckets[key].items);
            break :blk groups.items;
        }, .{}, &grouped.writer);
        try grouped.writer.writeByte('\n');
        try expectOutput("map(group_by(.,.key),map(.,.id))", input.written(), grouped.written());
    }
}

fn keyedAllocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "{groups: map(group_by(.rows,{k:.k}),map(.,.v)), sorted: map(sort_by(.rows,.k),.v)} | collect", &diagnostic);
    defer program.deinit();
    var bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try program.run(allocator, "{\"rows\":[{\"k\":2,\"v\":\"b\"},{\"k\":1,\"v\":\"a\"},{\"k\":2,\"v\":\"c\"}]}", &output, &diagnostic);
    try t.expectEqualStrings("[{\"groups\":[[\"b\",\"c\"],[\"a\"]],\"sorted\":[\"a\",\"b\",\"c\"]}]\n", output.buffered());
}

test "array grouping and sorting allocation failures release keys rows groups and retained results" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try keyedAllocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, keyedAllocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
