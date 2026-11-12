const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

test "known-size keys and map results fit their exact value-storage budget" {
    const cases = [_]struct { source: []const u8, input: []const u8, count: usize, expected: []const u8 }{
        .{ .source = "keys(.)", .input = "{\"é\":0,\"a\":1,\"Z\":2}", .count = 3, .expected = "[\"Z\",\"a\",\"é\"]" },
        .{ .source = "map(.,.)", .input = "[false,{},[],1.00,null,\"é\"]", .count = 6, .expected = "[false,{},[],1.00,null,\"é\"]" },
        .{ .source = "keys(.)", .input = "{}", .count = 0, .expected = "[]" },
        .{ .source = "map(.,.)", .input = "[]", .count = 0, .expected = "[]" },
    };
    for (cases) |case| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, case.source, &diagnostic);
        defer program.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, case.input, .{ .parse_numbers = false });
        defer parsed.deinit();
        var storage: [6]std.json.Value = undefined;
        var bounded = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(storage[0..case.count]));
        var evaluator: @import("evaluator.zig").Evaluator = .{ .patterns = program.patterns, .diagnostic = &diagnostic, .path = .root() };
        const result = try evaluator.evalRequired(bounded.allocator(), program.stages[0].expression, parsed.value);
        const text = try std.json.Stringify.valueAlloc(t.allocator, result, .{});
        defer t.allocator.free(text);
        try t.expectEqualStrings(case.expected, text);
    }
}

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
}

fn expectInvalid(source: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    try t.expect(diagnostic.message.len != 0);
    try t.expect(diagnostic.offset <= source.len);
}

test "summary shorthand supports mixed quoted reserved and decoded field names" {
    try expectOutput("{passed, result, requests: length(.http), \"a-b\", true, \"\\u006eame\"}", "{\"passed\":false,\"result\":null,\"http\":[1,2],\"a-b\":0,\"true\":[],\"name\":\"Ada\"}", "{\"passed\":false,\"result\":null,\"requests\":2,\"a-b\":0,\"true\":[],\"name\":\"Ada\"}\n");
    try expectOutput(".child | {name, missing: .missing? ?? null}", "{\"child\":{\"name\":\"Ada\"}}", "{\"name\":\"Ada\",\"missing\":null}\n");
    try expectOutput("{}", "null", "{}\n");
    try expectFailure("{missing}", "{}", "absent", "$[\"missing\"]");
    try expectFailure("{name}", "null", "expects an object", "$[\"name\"]");
}

test "summary shorthand rejects duplicate keys and malformed fields" {
    for ([_][]const u8{ "{a,a}", "{a,\"\\u0061\":1}", "{\"a\",a}", "{a,}", "{a b}", "{a:}", "{a?}", "length()", "length(.,.)", "keys(.,.)", "keys(" }) |source| try expectInvalid(source);
}

test "summary length counts containers and Unicode scalar values" {
    try expectOutput("[length(.a), length(.o), length(.s), length(\"\"), length([]), length({})]", "{\"a\":[null,false,9007199254740993],\"o\":{\"x\":0,\"y\":1},\"s\":\"Aé😀e\\u0301\"}", "[3,2,5,0,0,0]\n");
    try expectOutput("length(keys(.)) + length(.items)", "{\"items\":[1,2],\"other\":null}", "4\n");
    try expectOutput("length(.missing? ?? [])", "{}", "0\n");
}

test "summary container functions reject unsupported types and unhandled missing" {
    for ([_][]const u8{ "null", "false", "1", "1.5" }) |input| {
        try expectFailure("length(.)", input, "expects an array, object, or string", "$");
        try expectFailure("keys(.)", input, "expects an object or array", "$");
    }
    try expectFailure("keys(.s)", "{\"s\":\"abc\"}", "expects an object or array", "$[\"s\"]");
    try expectFailure("length(.missing?)", "{}", "missing value", "$[\"missing\"]");
    try expectFailure("keys(.missing?)", "{}", "missing value", "$[\"missing\"]");
    try expectFailure("length(.http)", "{\"http\":false}", "expects an array", "$[\"http\"]");
}

test "summary keys sort object names by UTF-8 and enumerate array indexes" {
    try expectOutput("keys(.)", "{\"é\":1,\"z\":2,\"Z\":3,\"a\":4,\"\":5}", "[\"\",\"Z\",\"a\",\"z\",\"é\"]\n");
    try expectOutput("keys(.)", "[null,false,9007199254740993]", "[0,1,2]\n");
    try expectOutput("[keys({}),keys([])]", "null", "[[],[]]\n");
    try expectOutput("keys(.) | each | matches(., \"^a\")", "{\"beta\":1,\"alpha\":2}", "true\nfalse\n");
}

test "summary container functions compose with groups and query-file style comments" {
    try expectOutput("# HTTP outcome summary\n.http | each | group_by(.status) | {status: .[0].status, count: length(.)} | collect", "{\"http\":[{\"status\":500},{\"status\":200},{\"status\":500}]}", "[{\"status\":500,\"count\":2},{\"status\":200,\"count\":1}]\n");
    try expectOutput(".http | each | group_by(.status) | {status: .[0].status, count: length(.)} | collect", "{\"http\":[]}", "[]\n");
}

test "summary negative indexes preserve strict optional and minus-zero behavior" {
    try expectOutput("[.[-1], .[-3], .[-0], .[0], .[-4]? ?? null]", "[10,20,30]", "[30,10,10,10,null]\n");
    try expectOutput(".http[-1].status", "{\"http\":[{\"status\":200},{\"status\":500}]}", "500\n");
    try expectOutput(".missing?[-1].value ?? false", "{}", "false\n");
    try expectOutput(".[-1]? ?? null", "[]", "null\n");
    try expectFailure(".http[-2]", "{\"http\":[0]}", "absent", "$[\"http\"][-2]");
    try expectFailure(".[-1]", "[]", "absent", "$[-1]");
    try expectFailure(".[-1]?", "null", "expects an array", "$[-1]");
}

test "summary slices clamp signed omitted and reversed bounds" {
    try expectOutput("[.[:], .[-3:], .[:2], .[1:4], .[-4:-1], .[4:1], .[9:], .[:-9], .[-9:9], .[-0:2]]", "[0,1,2,3,4]", "[[0,1,2,3,4],[2,3,4],[0,1],[1,2,3],[1,2,3],[],[],[],[0,1,2,3,4],[0,1]]\n");
    try expectOutput("[.[:], .[-1:], .[:-1], .[1:0]]", "[]", "[[],[],[],[]]\n");
    try expectOutput(".http[-3:][1:][-1].status", "{\"http\":[{\"status\":200},{\"status\":404},{\"status\":500}]}", "500\n");
    try expectOutput(".missing?[:] ?? []", "{}", "[]\n");
    try expectOutput(".[5:9]?", "[0]", "[]\n");
    try expectFailure(".http[:]", "{\"http\":null}", "slice access expects an array", "$[\"http\"]");
    try expectFailure(".[:]?", "\"abc\"", "slice access expects an array", "$");
    try expectFailure(".[1:][0]", "[1]", "absent", "");
}

test "summary indexes and slices handle full usize magnitudes without overflow" {
    const largest = std.math.maxInt(usize);
    var source_buffer: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "[.[{d}]? ?? null, .[-{d}]? ?? null, .[-{d}:{d}], .[{d}:-{d}]]", .{ largest, largest, largest, largest, largest, largest });
    try expectOutput(source, "[0,1]", "[null,null,[0,1],[]]\n");
    const overflow = @as(u128, largest) + 1;
    const invalid = try std.fmt.bufPrint(&source_buffer, ".[-{d}]", .{overflow});
    try expectInvalid(invalid);
}

test "summary slices and indexes reject dynamic fractional and malformed bounds" {
    for ([_][]const u8{ ".[1+1]", ".[1e0]", ".[-0.5]", ".[0:1.0]", ".[::]", ".[1::2]", ".[1:2:3]", ".[+1]", ".[--1]", ".[1:--1]", ".[\"x\":1]", ".[", ".[:" }) |source| try expectInvalid(source);
}

test "summary generated slices match selecting positions in a small-array model" {
    const bounds = [_]i32{ -8, -5, -1, 0, 1, 3, 5, 8 };
    for (0..7) |len| {
        var input = std.Io.Writer.Allocating.init(t.allocator);
        defer input.deinit();
        try input.writer.writeByte('[');
        for (0..len) |index| {
            if (index != 0) try input.writer.writeByte(',');
            try input.writer.print("{d}", .{index});
        }
        try input.writer.writeByte(']');
        for (bounds) |start| for (bounds) |end| {
            var source_buffer: [64]u8 = undefined;
            const source = try std.fmt.bufPrint(&source_buffer, ".[{d}:{d}]", .{ start, end });
            const n: i32 = @intCast(len);
            const first = if (start < 0) n + start else start;
            const last = if (end < 0) n + end else end;
            var expected = std.Io.Writer.Allocating.init(t.allocator);
            defer expected.deinit();
            try expected.writer.writeByte('[');
            var comma = false;
            for (0..len) |index| {
                const position: i32 = @intCast(index);
                if (position < first or position >= last) continue;
                if (comma) try expected.writer.writeByte(',');
                try expected.writer.print("{d}", .{index});
                comma = true;
            }
            try expected.writer.writeAll("]\n");
            try expectOutput(source, input.written(), expected.written());
        };
    }
}

test "summary slice views and computed key arrays survive downstream retention" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".items[-2:] | {values: ., indexes: keys(.)} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var bytes: [64]u8 = undefined;
    for ([_][]const u8{ "{\"items\":[\"skip\",\"one\",\"two\"]}", "{\"items\":[\"three\"]}" }) |input| {
        @memcpy(bytes[0..input.len], input);
        _ = try stream.feed(bytes[0..input.len]);
        @memset(&bytes, 'x');
    }
    try stream.finish();
    try t.expectEqualStrings("[{\"values\":[\"one\",\"two\"],\"indexes\":[0,1]},{\"values\":[\"three\"],\"indexes\":[0]}]\n", output.written());
}

test "summary map returns one ordered array of scalar object and array results" {
    try expectOutput("map(., .)", "[false,null,9007199254740993,1.2300e-4,{\"a\":1},[2]]", "[false,null,9007199254740993,1.2300e-4,{\"a\":1},[2]]\n");
    try expectOutput("map(., false)", "[1,2]", "[false,false]\n");
    try expectOutput("map(., [.name, .id])", "[{\"name\":\"Ada\",\"id\":9007199254740993},{\"name\":\"Cy\",\"id\":2}]", "[[\"Ada\",9007199254740993],[\"Cy\",2]]\n");
    try expectOutput("map(.fixtures, {case, code: .result.code})", "{\"fixtures\":[{\"case\":\"compile\",\"result\":{\"code\":0}},{\"case\":\"link\",\"result\":{\"code\":1}}]}", "[{\"case\":\"compile\",\"code\":0},{\"case\":\"link\",\"code\":1}]\n");
}

test "summary filter preserves matching values order and numeric spelling" {
    try expectOutput("filter(., . != null)", "[false,0,null,9007199254740993,1.2300e-4,{}]", "[false,0,9007199254740993,1.2300e-4,{}]\n");
    try expectOutput("filter(., .)", "[false,true,false,true]", "[true,true]\n");
    try expectOutput("filter(., false and .missing)", "[1,null,{}]", "[]\n");
    try expectOutput("filter(.rows, exists(.keep?) and (.keep == true))", "{\"rows\":[{}, {\"keep\":false},{\"keep\":true,\"name\":\"Ada\"}]}", "[{\"keep\":true,\"name\":\"Ada\"}]\n");
}

test "summary map and filter compose inside projections and restore nested item scopes" {
    try expectOutput("{before: .name, rows: map(.rows, {name, doubled: map(.values, . * 2), name_after: .name}), after: .name}", "{\"name\":\"outer\",\"rows\":[{\"name\":\"first\",\"values\":[1,2]},{\"name\":\"second\",\"values\":[3]}]}", "{\"before\":\"outer\",\"rows\":[{\"name\":\"first\",\"doubled\":[2,4],\"name_after\":\"first\"},{\"name\":\"second\",\"doubled\":[6],\"name_after\":\"second\"}],\"after\":\"outer\"}\n");
    try expectOutput("map(filter(.rows, length(filter(.values, . > 1)) > 0), {name, count: length(.values), selected: filter(.values, . > 1)})", "{\"rows\":[{\"name\":\"skip\",\"values\":[0]},{\"name\":\"keep\",\"values\":[0,2,3]}]}", "[{\"name\":\"keep\",\"count\":3,\"selected\":[2,3]}]\n");
    try expectOutput("map(., .value? ?? null) | each | collect", "[{\"value\":false},{},{\"value\":0}]", "[false,null,0]\n");
}

test "summary empty transformations skip bodies without changing their outer context" {
    try expectOutput("{mapped: map(.items, .missing), filtered: filter(.items, 1/0), name}", "{\"items\":[],\"name\":\"outer\"}", "{\"mapped\":[],\"filtered\":[],\"name\":\"outer\"}\n");
    try expectOutput("length(map(filter([], .missing), .missing))", "null", "0\n");
}

test "summary transformations enforce array inputs boolean predicates and required results" {
    for ([_][]const u8{ "null", "false", "1", "\"\"", "{}" }) |input| {
        try expectFailure("map(., .)", input, "expects an array", "$");
        try expectFailure("filter(., true)", input, "expects an array", "$");
    }
    try expectFailure("map(.items?, .)", "{}", "missing value", "$[\"items\"]");
    try expectFailure("filter(.items?, true)", "{}", "missing value", "$[\"items\"]");
    try expectFailure("map(.items, .value?)", "{\"items\":[{}]}", "missing value", "$[\"items\"][0][\"value\"]");
    for ([_][]const u8{ "filter(., null)", "filter(., 1)", "filter(., \"true\")", "filter(., {})", "filter(., [])" }) |source| try expectFailure(source, "[{}]", "expected a boolean", "");
    try expectFailure("filter(.items, .keep?)", "{\"items\":[{}]}", "missing value", "$[\"items\"][0][\"keep\"]");
    try expectFailure("filter(.items, .keep)", "{\"items\":[{\"keep\":null}]}", "expected a boolean", "$[\"items\"][0][\"keep\"]");
}

test "summary transformations retain precise nested source paths and clear computed paths" {
    const input = "{\"rows\":[{\"items\":[{\"value\":1}]},{\"items\":[{}]}]}";
    try expectFailure("map(.rows, map(.items, .value))", input, "absent", "$[\"rows\"][1][\"items\"][0][\"value\"]");
    try expectFailure("filter(.rows, length(filter(.items, .value > 0)) > 0)", input, "absent", "$[\"rows\"][1][\"items\"][0][\"value\"]");
    try expectFailure("map(.rows[-1].items, .value)", input, "absent", "$[\"rows\"][-1][\"items\"][0][\"value\"]");
    try expectFailure("map(.rows[:], .missing)", input, "absent", "");
    try expectFailure("filter(.rows, true) | each | .missing", input, "absent", "");
    try expectFailure("{mapped: map(.rows, .), missing: .missing}", input, "absent", "$[\"missing\"]");
}

test "summary transformations reject bad arity nested pipes and malformed bodies" {
    for ([_][]const u8{ "map()", "map(.)", "filter(.)", "map(.,)", "filter(.,)", "map(.,.,.)", "filter(.,.,.)", "map(., . | each)", "filter(., where(true))", "map(., {value,})", "map(.,", "filter(," }) |source| try expectInvalid(source);
}

test "summary transformations respect output depth and preserve an accepted input shape" {
    var arrays: [256]u8 = undefined;
    @memset(arrays[0..128], '[');
    @memset(arrays[128..], ']');
    var expected: [257]u8 = undefined;
    @memcpy(expected[0..256], &arrays);
    expected[256] = '\n';
    try expectOutput("map(., .)", &arrays, &expected);
    try expectOutput("filter(., true)", &arrays, &expected);
    try expectFailure("map(., [.])", &arrays, "output nesting", "");
}

test "summary transformed values survive input and expression arena reuse before sorting" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "map(filter(.items[:], .keep), {name, id, fields: keys(.)}) | each | sort_by(.name) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{
        "{\"items\":[{\"name\":\"Cy\",\"id\":9007199254740993,\"keep\":true},{\"name\":\"skip\",\"id\":0,\"keep\":false}]}",
        "{\"items\":[{\"name\":\"Ada\",\"id\":1e3,\"keep\":true}]}",
    }) |input| {
        @memcpy(buffer[0..input.len], input);
        _ = try stream.feed(buffer[0..input.len]);
        @memset(&buffer, 'x');
    }
    try stream.finish();
    try t.expectEqualStrings("[{\"name\":\"Ada\",\"id\":1e3,\"fields\":[\"id\",\"keep\",\"name\"]},{\"name\":\"Cy\",\"id\":9007199254740993,\"fields\":[\"id\",\"keep\",\"name\"]}]\n", output.written());
}

test "summary failed transformations discard buffered results and honor retention budgets" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "map(.items, .value) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("{\"items\":[{\"value\":1}]}");
    try t.expectError(error.EvaluationFailed, stream.feed("{\"items\":[{\"value\":2},{}]}"));
    try t.expectError(error.StreamFailed, stream.finish());
    try t.expectEqualStrings("", output.written());
    var limited = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 0 });
    defer limited.deinit();
    try t.expectError(error.EvaluationFailed, limited.feed("{\"items\":[{\"value\":1}]}"));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "memory limit") != null);
    try t.expectError(error.StreamFailed, limited.finish());
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "{rows: map(filter(.items[:], .keep and matches(.name, \"^[a-z]+$\")), {name, size: length(.name), fields: keys(.), value: .value+1})} | collect", &diagnostic);
    defer program.deinit();
    var bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("{\"items\":[{\"name\":\"first\",\"keep\":true,\"value\":1},{\"name\":\"skip\",\"keep\":false,\"value\":2}]}");
    _ = try stream.feed("{\"items\":[{\"name\":\"next\",\"keep\":true,\"value\":3}]}");
    try stream.finish();
    try t.expectEqualStrings("[{\"rows\":[{\"name\":\"first\",\"size\":5,\"fields\":[\"keep\",\"name\",\"value\"],\"value\":2}]},{\"rows\":[{\"name\":\"next\",\"size\":4,\"fields\":[\"keep\",\"name\",\"value\"],\"value\":4}]}]\n", output.buffered());
}

test "summary allocation failures release parser transformations borrowed children and collectors" {
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
