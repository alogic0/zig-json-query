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

test "pretty stream output formats 2-space containers keeps empty containers compact and preserves exact numbers" {
    const expected =
        \\{
        \\  "z": [
        \\    null,
        \\    false,
        \\    9007199254740993,
        \\    170141183460469231731687303715884105727,
        \\    -170141183460469231731687303715884105728,
        \\    -0,
        \\    1.2300e+2
        \\  ],
        \\  "empty_obj": {},
        \\  "empty_arr": []
        \\}
        \\
    ;
    try expectOutput(
        ".",
        "{\"z\":[null,false,9007199254740993,170141183460469231731687303715884105727,-170141183460469231731687303715884105728,-0,1.2300e+2],\"empty_obj\":{},\"empty_arr\":[]}",
        expected,
        .{ .pretty = true },
    );
    try expectOutput("each", "[{},[],null,false,\"hi\"]", "{}\n[]\nnull\nfalse\n\"hi\"\n", .{ .pretty = true });
    try expectOutput(
        "each",
        "[\"raw\\nline\",{\"b\":2,\"a\":1},[]]",
        "raw\nline\n{\n  \"a\": 1,\n  \"b\": 2\n}\n[]\n",
        .{ .pretty = true, .raw_output = true, .sort_keys = true },
    );
    try expectOutput("{encoded:tojson({z:1,a:2})}", "null", "{\n  \"encoded\": \"{\\\"z\\\":1,\\\"a\\\":2}\"\n}\n", .{ .pretty = true, .sort_keys = true });

    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.InvalidOptions, program.start(t.allocator, &output.writer, &diagnostic, .{ .pretty = true, .join_output = true }));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "cannot be combined") != null);
}

test "fromjson try_fromjson and bare tojson round-trip exact values and compose with defaults" {
    try expectOutput(
        ".body | fromjson",
        "{\"body\":\"{\\\"ok\\\":true,\\\"id\\\":9007199254740993,\\\"max\\\":170141183460469231731687303715884105727,\\\"raw\\\":1.2300e+2}\"}",
        "{\"ok\":true,\"id\":9007199254740993,\"max\":170141183460469231731687303715884105727,\"raw\":1.2300e+2}\n",
        .{},
    );
    try expectOutput("fromjson(.body).id + 1", "{\"body\":\"{\\\"id\\\":9007199254740992}\"}", "9007199254740993\n", .{});
    try expectOutput("tojson | fromjson", "{\"z\":[null,false,\"é😀\\n\",-0],\"a\":{}}", "{\"z\":[null,false,\"é😀\\n\",-0],\"a\":{}}\n", .{});
    try expectOutput("fromjson.ok", "\"{\\\"ok\\\":true}\"", "true\n", .{});
    try expectOutput("{tojson,from_field:.fromjson,encoded:tojson}", "{\"tojson\":1,\"fromjson\":2}", "{\"tojson\":1,\"from_field\":2,\"encoded\":\"{\\\"tojson\\\":1,\\\"fromjson\\\":2}\"}\n", .{});
    try expectOutput(
        "map(., try_fromjson(.body?) ?? {fallback:true})",
        "[{},{\"body\":null},{\"body\":\"502 Bad Gateway\"},{\"body\":\"{\\\"a\\\":1,\\\"a\\\":2}\"},{\"body\":\"{\\\"ok\\\":false}\"}]",
        "[{\"fallback\":true},{\"fallback\":true},{\"fallback\":true},{\"fallback\":true},{\"ok\":false}]\n",
        .{},
    );
    try expectOutput(
        "each | .body? ?? null | try_fromjson ?? \"missing\" | collect",
        "[{\"body\":\"false\"},{\"body\":\"0\"},{\"body\":\"\\\"\\\"\"},{\"body\":\"[]\"},{\"body\":\"null\"},{\"body\":null},{\"body\":\"{bad}\"},{}]",
        "[false,0,\"\",[],\"missing\",\"missing\",\"missing\",\"missing\"]\n",
        .{},
    );
}

test "fromjson and try_fromjson validate types syntax duplicates and arity with source paths" {
    try expectFailure("fromjson(.body)", "{\"body\":null}", "fromjson expects a string", "$[\"body\"]");
    try expectFailure("fromjson(.body)", "{\"body\":42}", "fromjson expects a string", "$[\"body\"]");
    try expectFailure("fromjson(.body?)", "{}", "missing value", "$[\"body\"]");
    try expectFailure("map(.rows, fromjson)", "{\"rows\":[\"1\",true]}", "fromjson expects a string", "$[\"rows\"][1]");
    for ([_][]const u8{
        "\"\"",
        "\"   \"",
        "\"{broken}\"",
        "\"1 2\"",
        "\"{} []\"",
        "\"01\"",
        "\"{\\\"a\\\":1,\\\"a\\\":2}\"",
        "\"{\\\"a\\\":1,\\\"\\\\u0061\\\":2}\"",
        "\"\\\"\\\\uD800\\\"\"",
        "\"\\\"\\u0000\\\"\"",
    }) |bad| {
        try expectFailure("fromjson", bad, "fromjson requires one valid JSON value", "$");
    }
    try expectFailure("try_fromjson(.body)", "{\"body\":42}", "try_fromjson expects a string or null", "$[\"body\"]");
    try expectFailure("try_fromjson(.body)", "{\"body\":false}", "try_fromjson expects a string or null", "$[\"body\"]");
    try expectFailure("try_fromjson(.body)", "{\"body\":{}}", "try_fromjson expects a string or null", "$[\"body\"]");
    try expectFailure("try_fromjson(.body?)", "42", "expects an object", "$[\"body\"]");
    for ([_][]const u8{ "fromjson()", "fromjson(.,.)", "try_fromjson()", "try_fromjson(.,.)", "fromjson(. | collect)", "try_fromjson(. | collect)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

test "fromjson and try_fromjson enforce depth byte and retention limits" {
    var nested = std.Io.Writer.Allocating.init(t.allocator);
    defer nested.deinit();
    try nested.writer.writeByte('"');
    for (0..128) |_| try nested.writer.writeByte('[');
    try nested.writer.writeByte('0');
    for (0..128) |_| try nested.writer.writeByte(']');
    try nested.writer.writeByte('"');
    try expectOutput("[length(fromjson),length(try_fromjson)]", nested.written(), "[1,1]\n", .{});
    try expectFailure("[fromjson]", nested.written(), "output nesting exceeds 128 levels", "");
    try expectFailure("tojson([try_fromjson])", nested.written(), "serialization nesting exceeds 128 levels", "");

    var too_deep = std.Io.Writer.Allocating.init(t.allocator);
    defer too_deep.deinit();
    try too_deep.writer.writeByte('"');
    for (0..129) |_| try too_deep.writer.writeByte('[');
    try too_deep.writer.writeByte('0');
    for (0..129) |_| try too_deep.writer.writeByte(']');
    try too_deep.writer.writeByte('"');
    try expectFailure("length(fromjson)", too_deep.written(), "embedded JSON nesting exceeds 128 levels", "$");
    try expectFailure("try_fromjson ?? null", too_deep.written(), "embedded JSON nesting exceeds 128 levels", "$");

    const half_len = (query.max_input_bytes / 2) + 16;
    const half = try t.allocator.alloc(u8, half_len);
    defer t.allocator.free(half);
    @memset(half, 'a');
    for ([_][]const u8{ "tojson([$half,$half]) | fromjson", "tojson([$half,$half]) | try_fromjson ?? null" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compileWithBindings(t.allocator, source, &.{.{ .name = "half", .value = .{ .string = half } }}, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.Allocating.init(t.allocator);
        defer output.deinit();
        try t.expectError(error.EvaluationFailed, program.run(t.allocator, "null", &output.writer, &diagnostic));
        try t.expect(std.mem.indexOf(u8, diagnostic.message, "embedded JSON exceeds 64 MiB") != null);
    }

    var diagnostic: query.Diagnostic = .{};
    var retained_program = try query.Program.compile(t.allocator, "fromjson(.body) | collect", &diagnostic);
    defer retained_program.deinit();
    var sink: [64]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&sink);
    var small = try retained_program.start(t.allocator, &fixed, &diagnostic, .{ .max_collect_bytes = 16 });
    defer small.deinit();
    try t.expectError(error.EvaluationFailed, small.feed("{\"body\":\"{\\\"id\\\":9007199254740993}\"}"));
    try t.expectEqual(.retained, diagnostic.budget.?.kind);
}

fn embeddedAllocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "each | {decoded:try_fromjson(.body?) ?? {ok:false},round:fromjson(tojson(.tag))} | collect", &diagnostic);
    defer program.deinit();
    var bytes: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    var input = "[{\"body\":\"{\\\"ok\\\":true,\\\"v\\\":[1,\\\"é\\\\n\\\"]}\",\"tag\":\"9007199254740993\"},{\"body\":\"{bad}\",\"tag\":\"null\"}]".*;
    _ = try stream.feed(&input);
    @memset(&input, 'x');
    try stream.finish();
    try t.expectEqualStrings("[{\"decoded\":{\"ok\":true,\"v\":[1,\"é\\n\"]},\"round\":\"9007199254740993\"},{\"decoded\":{\"ok\":false},\"round\":\"null\"}]\n", output.buffered());
}

test "embedded JSON parsing releases allocations on failure and survives caller buffer reuse" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try embeddedAllocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, embeddedAllocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "concat preserves UTF-8 and escape bytes, empties and retained results" {
    try expectOutput("[concat([]), concat([\"\",\"\"]), concat(.)]", "[\"é\",\"\",\"😀\",\"\\\"\",\"\\\\\",\"\\u0000\"]", "[\"\",\"\",\"é😀\\\"\\\\\\u0000\"]\n", .{ .max_collect_bytes = 0 });
    try expectOutput("each | concat(.) | collect", "[[\"a\",\"b\"],[\"c\"]]", "[\"ab\",\"c\"]\n", .{});
    try expectFailure("concat(.row)", "{\"row\":27}", "expects an array", "$[\"row\"]");
    try expectFailure("concat(.row)", "{\"row\":[\"abc\",null]}", "expects a string", "$[\"row\"][1]");
    try expectFailure("concat([\"a\",.bad])", "{\"bad\":42}", "expects a string", "$[\"bad\"]");
    try expectFailure("\"a\" + \"b\"", "null", "integer arithmetic", "");
}
