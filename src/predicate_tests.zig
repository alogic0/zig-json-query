const std = @import("std");
const query = @import("root.zig");
const scalar = @import("evaluator.zig");
const t = std.testing;

fn expectOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(t.allocator, source, &.{.{ .name = "expected", .value = .{ .json = "true" } }}, &diagnostic);
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

test "predicates all and any have explicit empty identities and ordered short circuit" {
    try expectOutput("[all([], 1/0), any([], .missing), all([false,null], .), any([true,null], .)]", "null", "[true,false,false,true]\n");
    try expectOutput("[all(., . > 0), any(., . > 2)]", "[1,2,3]", "[true,true]\n");
    try expectOutput("all(., . >= 0) == not any(., . < 0)", "[-1,0,5]", "true\n");
    try expectOutput("{all, any}", "{\"all\":false,\"any\":true}", "{\"all\":false,\"any\":true}\n");
}

test "predicates nested quantifiers preserve item scopes caller fields and external constants" {
    try expectOutput("{ok: all(.groups, any(.checks, .ok == $expected)), name}", "{\"name\":\"outer\",\"groups\":[{\"checks\":[{\"ok\":false},{\"ok\":true}]},{\"checks\":[{\"ok\":true}]}]}", "{\"ok\":true,\"name\":\"outer\"}\n");
    try expectOutput("map(.groups, {ok: all(.flags, .), id})", "{\"groups\":[{\"flags\":[false],\"id\":1},{\"flags\":[true],\"id\":2}]}", "[{\"ok\":false,\"id\":1},{\"ok\":true,\"id\":2}]\n");
    try expectOutput("{ok: any(.groups, .ok), name}", "{\"name\":\"outer\",\"groups\":[{\"ok\":true},{}]}", "{\"ok\":true,\"name\":\"outer\"}\n");
}

test "predicates require arrays and booleans only for evaluated items" {
    for ([_][]const u8{ "null", "0", "false", "{}", "\"\"" }) |input| {
        try expectFailure("all(., true)", input, "expects an array", "$");
        try expectFailure("any(., true)", input, "expects an array", "$");
    }
    try expectFailure("all(., .)", "[true,null]", "expected a boolean", "$[1]");
    try expectFailure("any(., .)", "[false,0]", "expected a boolean", "$[1]");
    try expectFailure("all(.checks, .ok?)", "{\"checks\":[{}]}", "missing value", "$[\"checks\"][0][\"ok\"]");
    try expectFailure("any(.checks?, true)", "{}", "missing value", "$[\"checks\"]");
}

test "predicates errors retain nested item paths and clear computed source paths" {
    try expectFailure("any(.groups, all(.checks, .ok))", "{\"groups\":[{\"checks\":[{\"ok\":false}]},{\"checks\":[{\"ok\":true},{}]}]}", "absent", "$[\"groups\"][1][\"checks\"][1][\"ok\"]");
    try expectFailure("all(.checks[:], .ok)", "{\"checks\":[{}]}", "absent", "");
    try expectFailure("{ok: all(.checks, true), missing}", "{\"checks\":[]}", "absent", "$[\"missing\"]");
}

test "predicates do not allocate result arrays during scalar evaluation" {
    var flags = [_]std.json.Value{ .{ .bool = true }, .{ .bool = false } };
    var input = std.json.Array.init(t.allocator);
    input.items = &flags;
    input.capacity = flags.len;
    for ([_][]const u8{ "all(., .)", "any(., .)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        var allocator = std.heap.FixedBufferAllocator.init(&.{});
        var evaluator: scalar.Evaluator = .{ .patterns = program.patterns, .diagnostic = &diagnostic, .path = .root() };
        const result = try evaluator.evalRequired(allocator.allocator(), program.stages[0].expression, .{ .array = input });
        try t.expectEqual(std.mem.startsWith(u8, source, "any"), result.bool);
    }
}

test "predicates reject malformed arity and nested stream syntax" {
    for ([_][]const u8{ "all()", "all(.)", "all(.,)", "any(.,true,false)", "all(., . | each)", "any(., where(true))" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}
