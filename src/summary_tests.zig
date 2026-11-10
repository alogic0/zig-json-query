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
