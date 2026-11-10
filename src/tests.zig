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

fn expectEvaluationError(source: []const u8, input: []const u8, message: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, input, &output.writer, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
}

test "pipeline filters records and constructs one object per surviving record" {
    try expectOutput(
        ".users | each | where(.age >= 18) | {name: .name, enabled: .enabled? ?? true}",
        "{\"users\":[{\"name\":\"Ada\",\"age\":36,\"enabled\":false},{\"name\":\"Ben\",\"age\":15},{\"name\":\"Cy\",\"age\":20}]}",
        "{\"name\":\"Ada\",\"enabled\":false}\n{\"name\":\"Cy\",\"enabled\":true}\n",
    );
}

test "defaults preserve false zero empty strings and empty arrays" {
    try expectOutput("each | . ?? 99", "[false,0,\"\",[],null]", "false\n0\n\"\"\n[]\n99\n");
    try expectOutput(".absent? ?? 9", "{}", "9\n");
    try expectOutput(".a? ?? .b? ?? 9", "{}", "9\n");
    try expectEvaluationError(".absent ?? 9", "{}", "absent");
}

test "missing and JSON null are distinguishable with exists" {
    try expectOutput("[exists(.a?), exists(.b?), .a == null]", "{\"a\":null}", "[true,false,true]\n");
    try expectEvaluationError(".a?", "{}", "missing value");
    try expectEvaluationError("{a: .a?}", "{}", "missing value");
}

test "optional access propagates absence but never masks a wrong type" {
    try expectOutput(".contact?.email ?? \"unknown\"", "{}", "\"unknown\"\n");
    try expectEvaluationError(".contact?.email ?? \"unknown\"", "{\"contact\":null}", "expects an object");
    try expectEvaluationError(".name? ?? \"unknown\"", "42", "expects an object");
}

test "bracket keys and array indexes have explicit optional semantics" {
    try expectOutput(".[\"a-b\"][1].name", "{\"a-b\":[null,{\"name\":\"ok\"}]}", "\"ok\"\n");
    try expectOutput(".[4]? ?? 7", "[1]", "7\n");
    try expectEvaluationError(".[4]", "[1]", "absent");
    try expectEvaluationError(".[0]?", "{}", "expects an array");
}

test "boolean operators short circuit and predicates reject implicit truthiness" {
    try expectOutput("[false and .missing, true or .missing, false ?? .missing, not false]", "{}", "[false,true,false,true]\n");
    try expectOutput("true or false and false", "null", "true\n");
    try expectOutput(". and true", "true", "true\n");
    try expectEvaluationError("where(.name)", "{\"name\":\"Ada\"}", "expected a boolean");
    try expectEvaluationError("1 and true", "null", "expected a boolean");
}

test "numbers remain exact in filtering and output" {
    try expectOutput("each | where(. > 9007199254740992)", "[9007199254740992,9007199254740993,18446744073709551616]", "9007199254740993\n18446744073709551616\n");
    try expectOutput("[1 == 1.0, 1e3 == 1000, -0 == 0, 1 == \"1\"]", "null", "[true,true,true,false]\n");
    try expectOutput(".", "1.234567890123456789e1234", "1.234567890123456789e1234\n");
    try expectEvaluationError(". > \"1\"", "2", "types are not coerced");
    try expectEvaluationError(". > 1", "1e999999999999999999999", "exponent");
}

test "structural equality ignores object key order but preserves array order" {
    try expectOutput(".a == .b", "{\"a\":{\"x\":[1,2],\"y\":true},\"b\":{\"y\":true,\"x\":[1.0,2]}}", "true\n");
    try expectOutput("[1,2] == [2,1]", "null", "false\n");
}

test "each is the only expansion operation and nested arrays can expand twice" {
    try expectOutput("each | each", "[[1,2],[],[3]]", "1\n2\n3\n");
    try expectOutput("each | where(false)", "[1,2]", "");
    try expectOutput("[.a, .b]", "{\"a\":[1,2],\"b\":[3,4]}", "[[1,2],[3,4]]\n");
    try expectEvaluationError("each", "{}", "expects an array");
}

test "regex uses the shared package with Unicode and JSON string escapes" {
    try expectOutput("each | where(matches(., \"(?i)^a\"))", "[\"Ada\",\"ben\",\"AL\"]", "\"Ada\"\n\"AL\"\n");
    try expectOutput("matches(., \"^\\\\p{L}+$\")", "\"Ελλάδα\"", "true\n");
    try expectEvaluationError("matches(., \"a\")", "1", "expects a string");
}

test "malformed queries and unsupported features give diagnostics and clean up" {
    const cases = [_][]const u8{
        "",                     ".a |",                "where(", ".[]", ".[0.5]",         ".[-]",    "{a:1,a:2}",
        "[1,]",                 "{a:1,}",              "01",     "1e",  "\"unterminated", "\"\\x\"", "matches(., \"[\")",
        "matches(., .pattern)", "matches(., \"x\") |",
    };
    for (cases) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
        try t.expect(diagnostic.message.len != 0);
        try t.expect(diagnostic.offset <= source.len);
    }
}

test "query text is owned and one compiled program can process many inputs" {
    const source = try t.allocator.dupe(u8, ".x | where(matches(., \"a\"))");
    var diagnostic: query.Diagnostic = .{};
    var program = query.Program.compile(t.allocator, source, &diagnostic) catch |err| {
        t.allocator.free(source);
        return err;
    };
    t.allocator.free(source);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    for (0..100) |_| try program.run(t.allocator, "{\"x\":\"a\"}", &output.writer, &diagnostic);
    try t.expectEqual(@as(usize, 400), output.written().len);
}

test "JSON input rejects duplicate keys invalid syntax and excessive depth" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.DuplicateField, program.run(t.allocator, "{\"x\":1,\"x\":2}", &output.writer, &diagnostic));
    try t.expectError(error.SyntaxError, program.run(t.allocator, "[1,]", &output.writer, &diagnostic));
    var deep: [259]u8 = undefined;
    @memset(deep[0..129], '[');
    deep[129] = '0';
    @memset(deep[130..], ']');
    try t.expectError(error.InputTooDeep, program.run(t.allocator, &deep, &output.writer, &diagnostic));
}

test "parser bounds nesting and long access chains before evaluation" {
    var diagnostic: query.Diagnostic = .{};
    var nested: [259]u8 = undefined;
    @memset(nested[0..129], '(');
    nested[129] = '.';
    @memset(nested[130..], ')');
    try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, &nested, &diagnostic));
    var chain: [400]u8 = undefined;
    for (0..200) |index| {
        chain[index * 2] = '.';
        chain[index * 2 + 1] = 'a';
    }
    try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, &chain, &diagnostic));
}

test "diagnostics locate the failing field in a multiline query" {
    var diagnostic: query.Diagnostic = .{};
    const source = ".users\n| each\n| .missing";
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, "{\"users\":[{}]}", &output.writer, &diagnostic));
    try diagnostic.write(program.source, &output.writer);
    try t.expect(std.mem.indexOf(u8, output.written(), "query:3:4:") != null);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "each | where(matches(.name, \"^A\")) | {name:.name, age:.age? ?? 0}", &diagnostic);
    defer program.deinit();
    var bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try program.run(allocator, "[{\"name\":\"Ada\"},{\"name\":\"Ben\"}]", &output, &diagnostic);
    try t.expectEqualStrings("{\"name\":\"Ada\",\"age\":0}\n", output.buffered());
}

test "allocation failure releases AST regex input and stage owners" {
    // Arena growth can resize in place depending on backing address layout.
    // Disable resizes in both runs so failure indexes are reproducible.
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
