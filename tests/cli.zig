const std = @import("std");
const S = @import("test_support");
const exe = @import("test_options").exe;
const t = std.testing;

fn check(args: []const []const u8, input: []const u8, code: i32, output: []const u8, diagnostic: ?[]const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(t.allocator);
    try argv.append(t.allocator, exe);
    try argv.appendSlice(t.allocator, args);
    const report = try S.command.runReport(t.allocator, t.io, .{
        .run = .{ .spawn = .{ .argv = argv.items }, .timeout_ms = 5000, .stdout_limit = 64 * 1024, .stderr_limit = 16 * 1024 },
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

fn expectExitWithOpenInputArgs(argv: []const []const u8, input: []const u8, expected: []const u8) !void {
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
    try check(&.{ "-f", query_path, ".", input_path }, "", 2, "", "inline queries cannot");
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
