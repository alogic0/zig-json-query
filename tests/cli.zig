const std = @import("std");
const S = @import("test_support");
const exe = @import("test_options").exe;
const t = std.testing;

pub fn check(args: []const []const u8, input: []const u8, code: i32, output: []const u8, diagnostic: ?[]const u8) !void {
    return checkIn(null, args, input, code, output, diagnostic);
}

pub fn checkIn(cwd: ?[]const u8, args: []const []const u8, input: []const u8, code: i32, output: []const u8, diagnostic: ?[]const u8) !void {
    const absolute_exe = if (cwd != null) try std.Io.Dir.cwd().realPathFileAlloc(t.io, exe, t.allocator) else null;
    defer if (absolute_exe) |path| t.allocator.free(path);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.append(t.allocator, absolute_exe orelse exe);
    try argv.appendSlice(t.allocator, args);
    const report = try S.command.runReport(t.allocator, t.io, .{
        .run = .{ .spawn = .{ .argv = argv.items, .cwd = if (cwd) |path| .{ .path = path } else .inherit }, .timeout_ms = 5000, .stdout_limit = 64 * 1024, .stderr_limit = 16 * 1024 },
        .stdin = input,
    });
    defer report.deinit(t.allocator);
    try S.Diagnostic.expectExit(report, .{ .assertion = "jqz CLI", .code = code });
    try t.expectEqualStrings(output, report.stdout);
    if (diagnostic) |message| {
        try t.expect(std.mem.indexOf(u8, report.stderr, message) != null);
    } else try t.expectEqualStrings("", report.stderr);
}

test "CLI reads stdin and emits filtered records" {
    try check(&.{"each | where(.age >= 18) | .name"}, "[{\"name\":\"Ada\",\"age\":36},{\"name\":\"Ben\",\"age\":15}]", 0, "\"Ada\"\n", null);
    try check(&.{"each | where(false)"}, "[1,2]", 0, "", null);
}

test "CLI budget arguments reject invalid values before query or input IO" {
    for ([_][]const u8{ "--max-retained-bytes", "--max-slurp-bytes" }) |option| {
        for ([_][]const u8{ "", "-1", "+1", "1.0", "1KiB", " 1", "18446744073709551616" }) |bad| {
            try check(&.{ option, bad, "-f", "/nonexistent-jqz-budget-query" }, "", 2, "", "unsigned decimal bytes");
        }
        try check(&.{option}, "", 2, "", "requires unsigned decimal bytes");
    }
    try check(&.{ "--max-retained-bytes", "0", "--max-slurp-bytes", "0", "-n", "take(0) | collect" }, "", 0, "[]\n", null);
    try check(&.{ "--max-retained-bytes", "18446744073709551615", "-n", "count" }, "", 0, "1\n", null);
}

test "CLI retention and slurp budgets are independent with actionable diagnostics" {
    try check(&.{ "--max-retained-bytes", "1", "--max-slurp-bytes", "1048576", "collect" }, "null", 2, "", "retained allocation budget: limit=1 bytes, retained=0 bytes, requested=");
    try check(&.{ "--max-retained-bytes", "1", "collect" }, "null", 2, "", "increase --max-retained-bytes");
    try check(&.{ "--max-retained-bytes", "1048576", "--max-slurp-bytes", "1", "-s", "length(.)" }, "null", 2, "", "increase --max-slurp-bytes or avoid -s");
    try check(&.{ "--max-retained-bytes", "1048576", "--max-slurp-bytes", "0", "collect" }, "null", 0, "[null]\n", null);
    try check(&.{ "--max-retained-bytes", "0", "--max-slurp-bytes", "1048576", "-s", "length(.)" }, "null", 0, "1\n", null);
    try check(&.{ "--max-slurp-bytes", "0", "--ndjson", "-s", "length(.)" }, "", 0, "0\n", null);
}

test "CLI admitted synthetic manifest needs a separate owned slurp budget" {
    var input = std.Io.Writer.Allocating.init(t.allocator);
    defer input.deinit();
    try input.writer.writeByte('[');
    for (0..400) |index| {
        if (index != 0) try input.writer.writeByte(',');
        try input.writer.print("{{\"id\":{d},\"name\":\"retained\",\"meta\":{{\"valid\":true}}}}", .{index});
    }
    try input.writer.writeByte(']');
    try t.expect(input.written().len < 64 * 1024 * 1024);
    try check(&.{"length(.)"}, input.written(), 0, "400\n", null);
    try check(&.{ "-s", "--max-slurp-bytes", "8192", "length(.[0])" }, input.written(), 2, "", "slurp allocation budget: limit=8192 bytes");
    try check(&.{ "-s", "--max-slurp-bytes", "1048576", "--max-retained-bytes", "0", "length(.[0])" }, input.written(), 0, "400\n", null);
}

test "CLI joined output preserves NUL Unicode and JSON bytes without separators" {
    try check(&.{ "--join-output", "each" }, "[\"a\\u0000\",\"é😀\",\"\",1,false,null,{\"b\":2,\"a\":1},[]]", 0, "a\x00é😀1falsenull{\"b\":2,\"a\":1}[]", null);
    try check(&.{ "-j", "each" }, "[\"line\\nnext\",\"x\"]", 0, "line\nnextx", null);
    try check(&.{ "-r", "-j", "each" }, "[\"a\",\"b\"]", 0, "ab", null);
    try check(&.{ "-j", "-r", "each" }, "[\"a\",\"b\"]", 0, "ab", null);
}

test "CLI bundles no-argument flags and preserves option terminators" {
    try check(&.{ "-nj", "\"value\"" }, "", 0, "value", null);
    try check(&.{ "-jr", "each" }, "[\"a\",\"b\"]", 0, "ab", null);
    try check(&.{ "-rj", "each" }, "[1,2]", 0, "12", null);
    try check(&.{ "-nSje", "{z:1,a:2}" }, "", 0, "{\"a\":2,\"z\":1}", null);
    try check(&.{ "-js", "--ndjson", "." }, "1\n2\n", 0, "[1,2]", null);
    try check(&.{ "-nj", "--", "-2" }, "", 0, "-2", null);
    try check(&.{ "-np", "--", "-2" }, "", 0, "-2\n", null);
    try check(&.{ "-jx", "." }, "", 2, "", "unknown option");
    try check(&.{ "-px", "." }, "", 2, "", "unknown option");
    try check(&.{ "-jf", "query" }, "", 2, "", "unknown option");
}

test "CLI pretty output formats containers composes with flags and rejects join-output" {
    const nested =
        \\{
        \\  "a": 1,
        \\  "b": [
        \\    9007199254740993,
        \\    170141183460469231731687303715884105727,
        \\    -170141183460469231731687303715884105728
        \\  ],
        \\  "empty_obj": {},
        \\  "empty_arr": []
        \\}
        \\
    ;
    try check(
        &.{ "-p", "." },
        "{\"a\":1,\"b\":[9007199254740993,170141183460469231731687303715884105727,-170141183460469231731687303715884105728],\"empty_obj\":{},\"empty_arr\":[]}",
        0,
        nested,
        null,
    );
    try check(&.{ "--pretty", "." }, "{}", 0, "{}\n", null);
    try check(&.{ "-p", "." }, "[]", 0, "[]\n", null);
    try check(&.{ "-nSpe", "{z:[2,1],a:{}}" }, "", 0, "{\n  \"a\": {},\n  \"z\": [\n    2,\n    1\n  ]\n}\n", null);
    try check(&.{ "-pr", "each" }, "[\"hello\\nworld\",{\"b\":2,\"a\":1},[]]", 0, "hello\nworld\n{\n  \"b\": 2,\n  \"a\": 1\n}\n[]\n", null);
    try check(&.{ "-rpS", "each" }, "[\"raw\",{\"z\":1,\"a\":2}]", 0, "raw\n{\n  \"a\": 2,\n  \"z\": 1\n}\n", null);
    try check(&.{ "-p", "--ndjson", "." }, "{\"a\":1}\n[]\n{\"b\":[2]}\n", 0, "{\n  \"a\": 1\n}\n[]\n{\n  \"b\": [\n    2\n  ]\n}\n", null);
    try check(&.{ "-ps", "--ndjson", "." }, "1\n2\n", 0, "[\n  1,\n  2\n]\n", null);
    try check(&.{ "-pe", "." }, "false", 1, "false\n", null);
    try check(&.{ "-pe", "." }, "null", 1, "null\n", null);
    try check(&.{ "-pe", "where(false)" }, "{}", 4, "", null);
    try check(&.{ "-pp", "-n", "{ok:true}" }, "", 0, "{\n  \"ok\": true\n}\n", null);

    for ([_][]const []const u8{
        &.{ "-p", "-j", "." },
        &.{ "-j", "-p", "." },
        &.{ "--pretty", "--join-output", "." },
        &.{ "-pj", "." },
        &.{ "-jp", "." },
        &.{ "-nSpje", "." },
        &.{ "-pj", "-f", "/nonexistent-jqz-pretty-query" },
    }) |args| {
        try check(args, "", 2, "", "cannot be combined");
    }
}

test "CLI joined output keeps value-based exit status and completion" {
    try check(&.{ "-je", "." }, "\"\"", 0, "", null);
    try check(&.{ "-je", "each" }, "[\"x\",false]", 1, "xfalse", null);
    try check(&.{ "-je", "." }, "null", 1, "null", null);
    try check(&.{ "-je", "." }, "\"false\"", 0, "false", null);
    try check(&.{ "-je", "where(false)" }, "null", 4, "", null);
    try check(&.{ "-nje", "take(0) | collect" }, "", 0, "[]", null);
    try check(&.{ "-j", "--ndjson", "collect" }, "1\n2\n", 0, "[1,2]", null);
    try check(&.{ "-je", "--ndjson", "." }, "false\n{bad}\n", 2, "false", "<stdin>:2:");
    try expectExitWithOpenInputArgs(&.{ exe, "-j", "--ndjson", "take(1)" }, "\"ready\"\n", "ready");
}

test "CLI output failures override predicate status and informational exits" {
    const full = try std.Io.Dir.cwd().openFile(t.io, "/dev/full", .{ .mode = .write_only });
    defer full.close(t.io);
    for ([_][]const []const u8{ &.{ exe, "-nje", "false" }, &.{ exe, "-ne", "false" }, &.{ exe, "-nre", "false" }, &.{ exe, "-npe", "{a:1}" }, &.{ exe, "--help" }, &.{ exe, "--version" } }) |argv| {
        const report = try S.command.File.run(t.allocator, t.io, .{ .spawn = .{ .argv = argv, .stdout = .{ .file = full } }, .timeout_ms = 5000 });
        try t.expect(report.outcome == .completed);
        try t.expect(report.cleanup_failure == null);
        try t.expectEqual(@as(i32, 2), S.command.code(report.term.?));
    }
}

test "CLI null input constructs records from typed bindings with anonymous provenance" {
    try check(&.{ "-n", "--arg", "name", "artifact", "--argjson", "bytes", "9007199254740993", "{name:$name,bytes:$bytes,input:.,file:input_filename()}" }, "", 0, "{\"name\":\"artifact\",\"bytes\":9007199254740993,\"input\":null,\"file\":null}\n", null);
    try check(&.{ "--null-input", "--argjson", "value", "1.2300e-4", "$value | collect" }, "", 0, "[1.2300e-4]\n", null);
    try check(&.{ "--arg", "value", "-n", "-n", "-r", "$value" }, "", 0, "-n\n", null);
    try check(&.{ ".", "--null-input", "-n" }, "", 0, "null\n", null);
    try check(&.{ "-n", "--", "-2" }, "", 0, "-2\n", null);
}

test "CLI null input preserves predicate status completion and error precedence" {
    try check(&.{ "-n", "-e", "." }, "", 1, "null\n", null);
    try check(&.{ "-n", "--exit-status", "false" }, "", 1, "false\n", null);
    try check(&.{ "-n", "-e", "true" }, "", 0, "true\n", null);
    try check(&.{ "-n", "-e", "where(false)" }, "", 4, "", null);
    try check(&.{ "-n", "-e", "take(0)" }, "", 4, "", null);
    try check(&.{ "-n", "-e", "take(0) | collect" }, "", 0, "[]\n", null);
    try check(&.{ "-n", "-r", "-e", "\"false\"" }, "", 0, "false\n", null);
    try check(&.{ "-n", "-S", "-e", "{z:1,a:2}" }, "", 0, "{\"a\":2,\"z\":1}\n", null);
    try check(&.{ "-n", "-e", ".missing" }, "", 2, "", "<null>:1:");
    try check(&.{ "-n", "count | .missing" }, "", 2, "", "<null>:EOF:");
    try check(&.{ "-n", "--argjson", "unused", "{bad}", "take(0)" }, "", 2, "", "one valid JSON value");
    try check(&.{ "-n", "$unbound" }, "", 2, "", "unbound variable");
    try check(&.{"-n"}, "", 2, "", "Usage:");
}

test "CLI serializes JSON text and distinguishes Unicode bytes from characters" {
    try check(&.{ "-r", "tojson(.)" }, "{\"x\":\"é😀\",\"n\":9007199254740993}", 0, "{\"x\":\"é😀\",\"n\":9007199254740993}\n", null);
    try check(&.{ "-r", "tojson" }, "{\"x\":\"é😀\",\"n\":9007199254740993}", 0, "{\"x\":\"é😀\",\"n\":9007199254740993}\n", null);
    try check(&.{"[length(tojson(.)),byte_length(tojson(.))]"}, "\"é😀\"", 0, "[4,8]\n", null);
    try check(&.{"byte_length(.)"}, "null", 2, "", "expects a string");
}

test "CLI parses embedded JSON strings with fromjson and try_fromjson across streams" {
    try check(
        &.{ "-p", ".body | fromjson" },
        "{\"body\":\"{\\\"ok\\\":true,\\\"id\\\":9007199254740993}\"}",
        0,
        "{\n  \"ok\": true,\n  \"id\": 9007199254740993\n}\n",
        null,
    );
    try check(
        &.{ "--ndjson", "try_fromjson(.body?) ?? {}" },
        "{}\n{\"body\":null}\n{\"body\":\"not-json\"}\n{\"body\":\"{\\\"ok\\\":true,\\\"id\\\":42}\"}\n",
        0,
        "{}\n{}\n{}\n{\"ok\":true,\"id\":42}\n",
        null,
    );
    try check(
        &.{ "--ndjson", ".body? ?? null | try_fromjson ?? {}" },
        "{}\n{\"body\":null}\n{\"body\":\"not-json\"}\n{\"body\":\"{\\\"ok\\\":false}\"}\n",
        0,
        "{}\n{}\n{}\n{\"ok\":false}\n",
        null,
    );
    try check(&.{ "-r", "fromjson(.body) | tojson" }, "{\"body\":\" { \\\"a\\\" : [ 1 , 2 ] } \"}", 0, "{\"a\":[1,2]}\n", null);
    try check(&.{".body | fromjson"}, "{\"body\":\"{broken}\"}", 2, "", "fromjson requires one valid JSON value");
    try check(&.{"fromjson(.body)"}, "{\"body\":123}", 2, "", "$[\"body\"]");
    try check(&.{"try_fromjson(.body)"}, "{\"body\":123}", 2, "", "try_fromjson expects a string or null");
}

test "CLI immutable configuration edits preserve unknown fields and support sorted keys" {
    try check(&.{ "-S", "--arg", "remove", "calendar.journey", "update(.,.groups,filter(.,.id != $remove))" }, "{\"meta\":{\"z\":9007199254740993,\"a\":true},\"groups\":[{\"id\":\"calendar.journey\"},{\"id\":\"keep\",\"done\":false}]}", 0, "{\"groups\":[{\"done\":false,\"id\":\"keep\"}],\"meta\":{\"a\":true,\"z\":9007199254740993}}\n", null);
    try check(&.{ "--sort-keys", "--ndjson", "." }, "{\"z\":{\"y\":2,\"a\":1},\"a\":[]}\n{\"b\":0,\"a\":-0}\n", 0, "{\"a\":[],\"z\":{\"a\":1,\"y\":2}}\n{\"a\":-0,\"b\":0}\n", null);
    try check(&.{"del(.,.missing)"}, "{}", 2, "", "edit field or index is absent");
}

test "CLI sorted keys compose with raw output predicate status and skipped input" {
    try check(&.{ "-S", "-r", "-e", "." }, "\"false\"", 0, "false\n", null);
    try check(&.{ "--sort-keys", "-e", "." }, "false", 1, "false\n", null);
    try check(&.{ "-S", "-e", "take(0) | collect" }, "{bad}", 0, "[]\n", null);
}

test "CLI structural sets order nested arrays while stream sorting stays strict" {
    try check(&.{"unique(.)"}, "[[2],[1],[2],false,null]", 0, "[null,false,[1],[2]]\n", null);
    try check(&.{"sort_values(.)"}, "[{\"b\":0},{\"a\":1},[]]", 0, "[[],{\"a\":1},{\"b\":0}]\n", null);
    try check(&.{"each | sort"}, "[[2],[1]]", 2, "", "sort keys must all be numbers or all strings");
}

test "CLI exit-status mode uses the last value without changing output" {
    try check(&.{ "-e", "." }, "false", 1, "false\n", null);
    try check(&.{ "--exit-status", "." }, "null", 1, "null\n", null);
    try check(&.{ "-e", "each" }, "[false,true]", 0, "false\ntrue\n", null);
    try check(&.{ "-e", "each" }, "[true,false]", 1, "true\nfalse\n", null);
    try check(&.{ "-e", "each" }, "[0,\"\",[],{}]", 0, "0\n\"\"\n[]\n{}\n", null);
    try check(&.{ "-e", "where(false)" }, "{}", 4, "", null);
    try check(&.{ "-e", "-r", "." }, "\"\"", 0, "\n", null);
    try check(&.{ "-e", "-r", "." }, "\"false\"", 0, "false\n", null);
    try check(&.{"."}, "false", 0, "false\n", null);
}

test "CLI exit-status mode handles aggregates early stops and error precedence" {
    try check(&.{ "-e", "--ndjson", "each" }, "", 4, "", null);
    try check(&.{ "-e", "--ndjson", "count" }, "", 0, "0\n", null);
    try check(&.{ "-e", "take(0) | collect" }, "{bad}", 0, "[]\n", null);
    try check(&.{ "-e", "each | take(1)" }, "[false,true]", 1, "false\n", null);
    try check(&.{ "-e", ".missing" }, "{}", 2, "", "absent");
    try check(&.{ "-e", "." }, "{bad}", 2, "", "SyntaxError");
    try check(&.{ "-e", "--ndjson", "." }, "false\n{bad}\n", 2, "false\n", "<stdin>:2:");
}

test "CLI external arguments preserve strings JSON types and exact values" {
    try check(&.{ "--arg", "label", "quote'\"\n$(literal)", "--argjson", "id", "9007199254740993", "--argjson", "data", "{\"ok\":false}", "{label: $label, id: $id, ok: $data.ok}" }, "null", 0, "{\"label\":\"quote'\\\"\\n$(literal)\",\"id\":9007199254740993,\"ok\":false}\n", null);
    try check(&.{ "--argjson", "expected", "false", "-e", ".passed == $expected" }, "{\"passed\":false}", 0, "true\n", null);
    try check(&.{ "--arg", "value", "--ndjson", "$value" }, "null", 0, "\"--ndjson\"\n", null);
    try check(&.{ "--argjson", "min", "2", "map(filter(., . >= $min), .)" }, "[1,2,3]", 0, "[2,3]\n", null);
    try check(&.{ "--arg", "message", "hello", "--", "$message" }, "null", 0, "\"hello\"\n", null);
}

test "CLI external argument errors precede input and reject ambiguity" {
    try check(&.{ "--arg", "a" }, "", 2, "", "requires a NAME and VALUE");
    try check(&.{ "--argjson", "a", "{bad}", "take(0)" }, "", 2, "", "JSON bindings require one valid JSON value");
    try check(&.{ "--argjson", "a", "0 1", "." }, "", 2, "", "one valid JSON value");
    try check(&.{ "--arg", "a-b", "x", "." }, "", 2, "", "binding names must match");
    try check(&.{ "--arg", "a", "x", "--argjson", "a", "0", "." }, "", 2, "", "duplicate external binding");
    try check(&.{"$missing"}, "", 2, "", "unbound variable");
    try check(&.{ "--argjson", "flag", "0", "-e", "$flag and true" }, "null", 2, "", "expected a boolean");
}

test "CLI external arguments compose with named and stdin query files" {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const input_path = try std.fs.path.join(t.allocator, &.{ root, "input data.json" });
    defer t.allocator.free(input_path);
    const query_path = try std.fs.path.join(t.allocator, &.{ root, "bound query.query" });
    defer t.allocator.free(query_path);
    try S.files.writeAtomic(t.io, .{ .path = input_path, .replace = false }, &.{"null"});
    try S.files.writeAtomic(t.io, .{ .path = query_path, .replace = false }, &.{"$data.value"});
    try check(&.{ "--argjson", "data", "{\"value\":9007199254740993}", "-f", query_path, input_path }, "", 0, "9007199254740993\n", null);
    try check(&.{ "--arg", "label", "bound", "-f", "-", input_path }, "$label", 0, "\"bound\"\n", null);
}

test "CLI streams NDJSON with blank lines CRLF and no trailing newline" {
    try check(&.{ "--ndjson", ".x? ?? false" }, "{\"x\":0}\r\n\n{}\n{\"x\":true}", 0, "0\nfalse\ntrue\n", null);
    try check(&.{ "--ndjson", "." }, "", 0, "", null);
}

test "CLI syntax and runtime errors are nonzero with query locations" {
    try check(&.{".x |"}, "{}", 2, "", "query:1:5:");
    try check(&.{".missing"}, "{}", 2, "", "field or index is absent");
    try check(&.{ "--ndjson", ".x" }, "{\"x\":1}\n{}\n{\"x\":3}\n", 2, "1\n", "<stdin>:2:");
}

test "CLI rejects malformed JSON duplicate fields and unsupported options" {
    try check(&.{"."}, "{broken}", 2, "", "SyntaxError");
    try check(&.{"."}, "{\"x\":1,\"x\":2}", 2, "", "DuplicateField");
    try check(&.{"--unknown"}, "", 2, "", "jqz: unknown option");
}

test "CLI accepts negative literals after option terminator" {
    try check(&.{ "--", "-2" }, "null", 0, "-2\n", null);
}

test "CLI reads an explicit input file" {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "input.json" });
    defer t.allocator.free(path);
    try S.files.writeAtomic(t.io, .{ .path = path, .replace = false }, &.{"{\"id\":9007199254740993}"});
    try check(&.{ ".id", path }, "", 0, "9007199254740993\n", null);
}

test "CLI rejects an oversized NDJSON line" {
    const bytes = try t.allocator.alloc(u8, 1024 * 1024 + 2);
    defer t.allocator.free(bytes);
    @memset(bytes, ' ');
    try check(&.{ "--ndjson", "." }, bytes, 2, "", "line limit 1 MiB");
}

test "CLI aggregates one NDJSON stream including blank lines and empty input" {
    try check(&.{ "--ndjson", "where(.level == \"error\") | count" }, "{\"level\":\"info\"}\n\n{\"level\":\"error\"}\r\n{\"level\":\"error\"}", 0, "2\n", null);
    try check(&.{ "--ndjson", "collect" }, "0\nfalse\nnull\n\"last\"", 0, "[0,false,null,\"last\"]\n", null);
    try check(&.{ "--ndjson", "count" }, " \n\r\n", 0, "0\n", null);
    try check(&.{ "--ndjson", "collect" }, "", 0, "[]\n", null);
    try check(&.{"each | where(. >= 2) | count"}, "[1,2,3]", 0, "2\n", null);
}

test "CLI take skips later bad records while downstream aggregates finish" {
    try check(&.{ "--ndjson", "take(2) | collect" }, "1\n2\n{bad}\n", 0, "[1,2]\n", null);
    try check(&.{ "--ndjson", ".value | take(1) | count" }, "{\"value\":1}\n{}\n", 0, "1\n", null);
    try check(&.{ "--ndjson", "take(0) | count" }, "{bad}\n", 0, "0\n", null);
    try check(&.{"take(0) | collect"}, "{bad}", 0, "[]\n", null);
}

test "CLI input and EOF failures do not emit buffered partial aggregates" {
    try check(&.{ "--ndjson", "collect" }, "1\n{bad}\n", 2, "", "<stdin>:2:");
    try check(&.{ "--ndjson", ".value | count" }, "{\"value\":1}\n{}\n", 2, "", "<stdin>:2:");
    try check(&.{ "--ndjson", "count | .missing" }, "1\n", 2, "", "<stdin>:EOF:");
}

fn expectExitWithOpenInput(source: []const u8, input: []const u8, expected: []const u8) !void {
    return expectExitWithOpenInputArgs(&.{ exe, "--ndjson", source }, input, expected);
}

pub fn expectExitWithOpenInputArgs(argv: []const []const u8, input: []const u8, expected: []const u8) !void {
    var child = try S.process.Child.spawn(t.allocator, t.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.deinit();
    if (input.len != 0) {
        var write_buffer: [128]u8 = undefined;
        var writer = S.process.PipeWriter.init(child.stdin.?, t.io, &write_buffer);
        try writer.interface.writeAll(input);
        try writer.interface.flush();
    }
    // Keep stdin open: the CLI must finish without waiting for producer EOF.
    const termination = try child.wait(2000);
    try t.expect(termination.success());
    var read_buffer: [128]u8 = undefined;
    var reader = S.process.PipeReader.init(child.stdout.?, t.io, &read_buffer);
    const output = try reader.interface.allocRemaining(t.allocator, .limited(1024));
    defer t.allocator.free(output);
    try t.expectEqualStrings(expected, output);
    var stderr_buffer: [128]u8 = undefined;
    var stderr_reader = S.process.PipeReader.init(child.stderr.?, t.io, &stderr_buffer);
    const errors = try stderr_reader.interface.allocRemaining(t.allocator, .limited(1024));
    defer t.allocator.free(errors);
    try t.expectEqualStrings("", errors);
}

test "CLI null input completes without waiting for stdin data or EOF" {
    try expectExitWithOpenInputArgs(&.{ exe, "-n", "[.,input_filename()]" }, "", "[null,null]\n");
    try expectExitWithOpenInputArgs(&.{ exe, "--null-input", "count" }, "", "1\n");
    try expectExitWithOpenInputArgs(&.{ exe, "-n", "collect" }, "", "[null]\n");
    try expectExitWithOpenInputArgs(&.{ exe, "-s", "--ndjson", "-n", "." }, "", "null\n");
    try expectExitWithOpenInputArgs(&.{ exe, "-n", "--slurp", "take(0) | count" }, "", "0\n");
}

test "CLI summarizes acceptance reports with shorthand length and keys" {
    try check(&.{"{passed, cleanup_passed, requests: length(.http), fields: keys(.result)}"}, "{\"passed\":false,\"cleanup_passed\":true,\"http\":[{},{}],\"result\":{\"message\":\"failed\",\"code\":1}}", 0, "{\"passed\":false,\"cleanup_passed\":true,\"requests\":2,\"fields\":[\"code\",\"message\"]}\n", null);
    try check(&.{ "--ndjson", "{passed, requests: length(.http)} | collect" }, "{\"passed\":true,\"http\":[]}\n{\"passed\":false,\"http\":[null]}\n", 0, "[{\"passed\":true,\"requests\":0},{\"passed\":false,\"requests\":1}]\n", null);
    try check(&.{"{passed}"}, "{}", 2, "", "$[\"passed\"]");
}

test "CLI inspects recent compiler commands with slices and negative indexes" {
    try check(&.{"{commands: length(.), recent: .[-2:], last: .[-1].argv[1:4]}"}, "[{\"argv\":[\"cc\",\"a.c\"]},{\"argv\":[\"cc\",\"b.c\"]},{\"argv\":[\"ld\",\"a.o\",\"b.o\",\"-o\",\"app\"]}]", 0, "{\"commands\":3,\"recent\":[{\"argv\":[\"cc\",\"b.c\"]},{\"argv\":[\"ld\",\"a.o\",\"b.o\",\"-o\",\"app\"]}],\"last\":[\"a.o\",\"b.o\",\"-o\"]}\n", null);
    try check(&.{"{commands: length(.), last: .[-1]? ?? null}"}, "[]", 0, "{\"commands\":0,\"last\":null}\n", null);
    try check(&.{".commands[-1]"}, "{\"commands\":[]}", 2, "", "$[\"commands\"][-1]");
}

test "CLI builds nested failure summaries using scalar array functions" {
    try check(&.{"{passed, cleanup_passed, requests: length(.http), last_request: .http[-1]? ?? null, failures: map(filter(.fixtures, .result.code != 0), {case, code: .result.code})}"}, "{\"passed\":false,\"cleanup_passed\":true,\"http\":[{\"status\":500}],\"fixtures\":[{\"case\":\"compile\",\"result\":{\"code\":0}},{\"case\":\"link\",\"result\":{\"code\":1}}]}", 0, "{\"passed\":false,\"cleanup_passed\":true,\"requests\":1,\"last_request\":{\"status\":500},\"failures\":[{\"case\":\"link\",\"code\":1}]}\n", null);
    try check(&.{"map(.rows, map(.items, .value))"}, "{\"rows\":[{\"items\":[1]}]}", 2, "", "$[\"rows\"][0][\"items\"][0][\"value\"]");
    try check(&.{"filter(., .)"}, "[true,null]", 2, "", "expected a boolean");
}

test "CLI retains transformed NDJSON summaries and suppresses failed partial aggregates" {
    try check(&.{ "--ndjson", "{passed, errors: map(filter(.fixtures, .code != 0), .case)} | collect" }, "{\"passed\":true,\"fixtures\":[]}\n{\"passed\":false,\"fixtures\":[{\"case\":\"link\",\"code\":1}]}\n", 0, "[{\"passed\":true,\"errors\":[]},{\"passed\":false,\"errors\":[\"link\"]}]\n", null);
    try check(&.{ "--ndjson", "map(.fixtures, .code) | collect" }, "{\"fixtures\":[{\"code\":0}]}\n{\"fixtures\":[{}]}\n", 2, "", "<stdin>:2:");
}

test "CLI take terminates with stdin still open after enough records" {
    try expectExitWithOpenInput("take(2) | collect", "1\n2\n", "[1,2]\n");
    try expectExitWithOpenInput("take(0) | count", "", "0\n");
    try expectExitWithOpenInput("collect | take(0) | collect", "", "[]\n");
    try expectExitWithOpenInputArgs(&.{ exe, "-e", "--ndjson", "take(1) | collect" }, "false\n", "[false]\n");
}

test "CLI raw output preserves JSON for non-strings and accepts long option" {
    try check(&.{ "-r", "each" }, "[\"a\\nb\",false,null,2,{}]", 0, "a\nb\nfalse\nnull\n2\n{}\n", null);
    try check(&.{ "--raw-output", ".x" }, "{\"x\":\"hi\"}", 0, "hi\n", null);
}

test "CLI query files argument precedence stdin queries and source errors" {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const query_path = try std.fs.path.join(t.allocator, &.{ root, "query.jq" });
    defer t.allocator.free(query_path);
    const input_path = try std.fs.path.join(t.allocator, &.{ root, "input.json" });
    defer t.allocator.free(input_path);
    const missing_path = try std.fs.path.join(t.allocator, &.{ root, "missing.json" });
    defer t.allocator.free(missing_path);
    try S.files.writeAtomic(t.io, .{ .path = query_path, .replace = false }, &.{".name # query file\n"});
    try S.files.writeAtomic(t.io, .{ .path = input_path, .replace = false }, &.{"{\"name\":\"Ada\"}"});
    try check(&.{ "-r", "-f", query_path }, "{\"name\":\"Ada\"}", 0, "Ada\n", null);
    try check(&.{ "--from-file", query_path, input_path }, "", 0, "\"Ada\"\n", null);
    try check(&.{ input_path, "-f", query_path }, "", 0, "\"Ada\"\n", null);
    try check(&.{ "-f", "-", input_path }, ".name", 0, "\"Ada\"\n", null);
    try check(&.{ "-f", "-" }, ".", 2, "", "explicit non-stdin input");
    try check(&.{ "-f", query_path, ".", input_path }, "", 2, "", "read JSON document");
    try check(&.{ "-f", query_path, "-f", query_path }, "", 2, "", "only one -f");
    try check(&.{"-f"}, "", 2, "", "requires a query filename");
    try check(&.{ ".", missing_path }, "", 2, "", missing_path);
    try check(&.{ "-f", missing_path }, "", 2, "", missing_path);
    try S.files.writeAtomic(t.io, .{ .path = query_path, .replace = true }, &.{".x |"});
    try check(&.{ "-f", query_path }, "", 2, "", query_path);
    const oversized = try t.allocator.alloc(u8, 65537);
    defer t.allocator.free(oversized);
    @memset(oversized, ' ');
    try S.files.writeAtomic(t.io, .{ .path = query_path, .replace = true }, &.{oversized});
    try check(&.{ "-f", query_path }, "", 2, "", "limit 64 KiB");
}

test "CLI locates malformed multiline input and nested evaluation paths" {
    try check(&.{"."}, "{\n \"x\": nope\n}", 2, "", "<stdin>:2:8:");
    try check(&.{ "--ndjson", "." }, "{}\n{\"x\": nope}\n", 2, "{}\n", "<stdin>:2:8:");
    try check(&.{".users | each | .age"}, "{\"users\":[{}]}", 2, "", "$[\"users\"][0][\"age\"]");
}

test "CLI arithmetic sorting and grouping share one NDJSON stream" {
    try check(&.{ "--ndjson", ".value*2 | sum" }, "{\"value\":9007199254740993}\n{\"value\":1}\n", 0, "18014398509481988\n", null);
    try check(&.{ "--ndjson", "sort_by(.k) | .v | collect" }, "{\"k\":2,\"v\":\"b\"}\n{\"k\":1,\"v\":\"a\"}\n", 0, "[\"a\",\"b\"]\n", null);
    try check(&.{ "--ndjson", "group_by(.) | collect" }, "2\n1\n2\n", 0, "[[2,2],[1]]\n", null);
    try check(&.{ "--ndjson", "sum" }, "1\n0.5\n", 2, "", "fractional");
    try check(&.{ "--ndjson", "sort" }, "1\n\"x\"\n", 2, "", "all be numbers");
    try expectExitWithOpenInput("group_by(.) | take(0) | sum", "", "0\n");
}

test {
    _ = @import("batch_cli.zig");
    _ = @import("descriptor_cli.zig");
}
