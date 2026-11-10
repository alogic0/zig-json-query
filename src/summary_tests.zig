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
    for ([_][]const u8{ ".[.index]", ".[1+1]", ".[1e0]", ".[-0.5]", ".[0:1.0]", ".[::]", ".[1::2]", ".[1:2:3]", ".[+1]", ".[--1]", ".[1:--1]", ".[\"x\":1]", ".[", ".[:" }) |source| try expectInvalid(source);
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
