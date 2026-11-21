const std = @import("std");
const S = @import("test_support");
const exe = @import("test_options").exe;
const t = std.testing;
const check = @import("cli.zig").check;
const checkIn = @import("cli.zig").checkIn;
const expectExitWithOpenInputArgs = @import("cli.zig").expectExitWithOpenInputArgs;

test "CLI manifest examples match by path preserve exact sizes and report additions removals" {
    const before_b = "{\"path\":\"b\",\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"size\":2}";
    const after_b = "{\"path\":\"b\",\"sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"size\":2}";
    const before_a = "{\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":9007199254740993}";
    const after_a = "{\"path\":\"a\",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"size\":9007199254740994}";
    const removed = "{\"path\":\"removed\",\"sha256\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"size\":1}";
    const inner = "{\"before\":" ++ before_b ++ ",\"matched\":true,\"after\":" ++ after_b ++ "}\n{\"before\":" ++ before_a ++ ",\"matched\":true,\"after\":" ++ after_a ++ "}\n";
    const cases = [_]struct { file: []const u8, expected: []const u8 }{
        .{ .file = "left-match.query", .expected = inner ++ "{\"before\":" ++ removed ++ ",\"matched\":false,\"after\":null}\n" },
        .{ .file = "inner-match.query", .expected = inner },
        .{ .file = "changes.query", .expected = "{\"path\":\"b\",\"sha256_changed\":true,\"size_changed\":false,\"before_size\":2,\"after_size\":2}\n{\"path\":\"a\",\"sha256_changed\":false,\"size_changed\":true,\"before_size\":9007199254740993,\"after_size\":9007199254740994}\n" },
        .{ .file = "removed.query", .expected = "\"removed\"\n" },
        .{ .file = "added.query", .expected = "\"added\"\n" },
    };
    for (cases) |case| {
        const source = try std.fs.path.join(t.allocator, &.{ "examples/cleanup", case.file });
        defer t.allocator.free(source);
        try check(&.{ "-n", "--slurpfile", "before", "examples/cleanup/before.json", "--slurpfile", "after", "examples/cleanup/after.json", "-f", source }, "", 0, case.expected, null);
    }
}

test "CLI key index spans files supports empty matches and stops before later inputs" {
    var files = try InputFiles.init();
    defer files.deinit();
    const first = try files.write("first.json", "{\"path\":\"é\",\"size\":9007199254740993}");
    const second = try files.write("second.json", "{\"path\":\"other\",\"size\":2}");
    try check(&.{ "index_by(.path) | map([\"other\",\"é\"],root()[.].size)", first, second }, "", 0, "[2,9007199254740993]\n", null);
    try check(&.{ "index_by(.path)", first, first }, "", 2, "", "duplicate key");
    try check(&.{ "--ndjson", "index_by(.path) | map([\"missing\"],exists(root()[.]?))" }, "", 0, "[false]\n", null);
    try check(&.{ "--max-retained-bytes", "1", "index_by(.path)", first }, "", 2, "", "increase --max-retained-bytes");
    try expectExitWithOpenInputArgs(&.{ exe, "--ndjson", "take(1) | index_by(.)" }, "\"x\"\n", "{\"x\":\"x\"}\n");
}

test "CLI grouped totals span files retain order and accept bounded streaming" {
    var files = try InputFiles.init();
    defer files.deinit();
    const first = try files.write("first.jsonl", "{\"kind\":\"b\",\"size\":9007199254740993}\n{\"kind\":\"a\",\"size\":-2}\n");
    const second = try files.write("second.jsonl", "{\"kind\":\"b\",\"size\":-3}\n");
    try check(&.{ "--ndjson", "--max-retained-bytes", "8192", "sum_by(.kind,.size)", first, second }, "", 0, "{\"key\":\"b\",\"count\":2,\"sum\":9007199254740990}\n{\"key\":\"a\",\"count\":1,\"sum\":-2}\n", null);
    try check(&.{ "--ndjson", "count_by(.kind)", first, second }, "", 0, "{\"key\":\"b\",\"count\":2}\n{\"key\":\"a\",\"count\":1}\n", null);
    try check(&.{ "--ndjson", "--max-retained-bytes", "1", "count_by(.)" }, "null\n", 2, "", "increase --max-retained-bytes");
    try expectExitWithOpenInputArgs(&.{ exe, "--ndjson", "take(1) | sum_by(.kind,.size)" }, "{\"kind\":\"x\",\"size\":3}\n", "{\"key\":\"x\",\"count\":1,\"sum\":3}\n");
}

const InputFiles = struct {
    temporary: t.TmpDir,
    root: [:0]u8,
    paths: std.ArrayList([]const u8) = .empty,

    fn init() !InputFiles {
        var temporary = t.tmpDir(.{});
        errdefer temporary.cleanup();
        return .{ .temporary = temporary, .root = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator) };
    }

    fn path(self: *InputFiles, name: []const u8) ![]const u8 {
        const result = try std.fs.path.join(t.allocator, &.{ self.root, name });
        errdefer t.allocator.free(result);
        try self.paths.append(t.allocator, result);
        return result;
    }

    fn write(self: *InputFiles, name: []const u8, bytes: []const u8) ![]const u8 {
        const result = try self.path(name);
        try S.files.writeAtomic(t.io, .{ .path = result, .replace = false }, &.{bytes});
        return result;
    }

    fn deinit(self: *InputFiles) void {
        for (self.paths.items) |path_name| t.allocator.free(path_name);
        self.paths.deinit(t.allocator);
        t.allocator.free(self.root);
        self.temporary.cleanup();
    }
};

test "CLI multiple documents share aggregates and retain their source filenames" {
    var files = try InputFiles.init();
    defer files.deinit();
    const a = try files.write("first report.json", "{\"passed\":true,\"value\":1}");
    const b = try files.write("second.json", "{\"passed\":false,\"value\":2}");
    try check(&.{ ".value | sum", a, b }, "", 0, "3\n", null);
    try check(&.{ "count", a, b }, "", 0, "2\n", null);
    try check(&.{ "count | input_filename()", a, b }, "", 0, "null\n", null);
    var expected = std.Io.Writer.Allocating.init(t.allocator);
    defer expected.deinit();
    try std.json.Stringify.value(.{ .{ .file = a, .passed = true }, .{ .file = b, .passed = false } }, .{}, &expected.writer);
    try expected.writer.writeByte('\n');
    try check(&.{ "{file: input_filename(), passed} | collect", a, b }, "", 0, expected.written(), null);
    try check(&.{ "--arg", "source", a, "input_filename() == $source", a }, "", 0, "true\n", null);
}

test "CLI files stdin and query files compose without sharing stdin twice" {
    var files = try InputFiles.init();
    defer files.deinit();
    const a = try files.write("first.json", "{\"value\":1}");
    const b = try files.write("second.json", "{\"value\":2}");
    const source = try files.write("sum.query", ".value | sum");
    try check(&.{ ".value | sum", a, "-", b }, "{\"value\":3}", 0, "6\n", null);
    try check(&.{ "-f", source, a, b }, "", 0, "3\n", null);
    try check(&.{ "-f", "-", a, b }, ".value | sum", 0, "3\n", null);
    try check(&.{ "--", ".value | sum", a, b }, "", 0, "3\n", null);
    try check(&.{"input_filename()"}, "null", 0, "\"<stdin>\"\n", null);
    try check(&.{ ".", "-", "-" }, "", 2, "", "stdin may be used as input at most once");
    try check(&.{ "-f", "-", a, "-" }, "", 2, "", "requires explicit non-stdin input files");
    try check(&.{"input_filename(1)"}, "", 2, "", "takes no arguments");
}

test "CLI joined output composes with named queries and multiple files" {
    var files = try InputFiles.init();
    defer files.deinit();
    const source = try files.write("paths.query", "map(keys(.files),[.,\"\\u0000\"]) | each | each");
    const a = try files.write("first.json", "{\"files\":{\"a.zig\":true}}");
    const b = try files.write("second.json", "{\"files\":{\"b.zig\":true}}");
    try check(&.{ "-jr", "-f", source, a, b }, "", 0, "a.zig\x00b.zig\x00", null);
    try check(&.{ "-nj", "-f", "-" }, "\"from query\"", 0, "from query", null);
}

test "CLI file bindings preserve exact JSON values and raw UTF-8 bytes" {
    var files = try InputFiles.init();
    defer files.deinit();
    const json = try files.write("values.json", "{\n\"n\":9007199254740993\n}\n[1.2300e-4]\nfalse null");
    const raw = try files.write("text.txt", "line\né😀\x00$(literal)");
    try check(&.{ "-n", "--slurpfile", "values", json, "--rawfile", "text", raw, "--arg", "label", "record", "--argjson", "limit", "2", "{values:$values,text:$text,label:$label,limit:$limit,file:input_filename()}" }, "", 0, "{\"values\":[{\"n\":9007199254740993},[1.2300e-4],false,null],\"text\":\"line\\né😀\\u0000$(literal)\",\"label\":\"record\",\"limit\":2,\"file\":null}\n", null);
    try check(&.{ "-nj", "--rawfile", "text", raw, "$text" }, "", 0, "line\né😀\x00$(literal)", null);
}

test "CLI file bindings handle empty and adjacent JSON documents" {
    var files = try InputFiles.init();
    defer files.deinit();
    const empty = try files.write("empty", "");
    const spaces = try files.write("spaces", " \n\t\r");
    const adjacent = try files.write("adjacent", "{}[]\"a\"\"b\"true{}null[]1[]");
    try check(&.{ "-n", "--slurpfile", "a", empty, "--slurpfile", "b", spaces, "--rawfile", "text", empty, "[$a,$b,$text]" }, "", 0, "[[],[],\"\"]\n", null);
    try check(&.{ "-n", "--slurpfile", "values", adjacent, "$values" }, "", 0, "[{},[],\"a\",\"b\",true,{},null,[],1,[]]\n", null);
}

test "CLI file bindings compose with query files ordinary input and early stop" {
    var files = try InputFiles.init();
    defer files.deinit();
    const config = try files.write("config.json", "{\"minimum\":2}");
    const label = try files.write("label.txt", "run-1");
    const source = try files.write("bound.query", "{minimum:$cfg[0].minimum,label:$label,values:filter(.,. >= $cfg[0].minimum)}");
    const input = try files.write("input.json", "[3,1,2]");
    try check(&.{ "--slurpfile", "cfg", config, "--rawfile", "label", label, "-f", source, input }, "", 0, "{\"minimum\":2,\"label\":\"run-1\",\"values\":[3,2]}\n", null);
    try check(&.{ "--slurpfile", "cfg", config, ". + $cfg[0].minimum" }, "3", 0, "5\n", null);
    try check(&.{ "-nj", "--rawfile", "label", label, "-f", "-" }, "$label", 0, "run-1", null);
    try check(&.{ "--ndjson", "-s", "--slurpfile", "cfg", config, "length(.) + $cfg[0].minimum" }, "1\n2\n", 0, "4\n", null);
    try expectExitWithOpenInputArgs(&.{ exe, "--slurpfile", "cfg", config, "take(0) | count" }, "", "0\n");
}

test "CLI unused file bindings reject invalid input names and missing files" {
    var files = try InputFiles.init();
    defer files.deinit();
    const invalid = try files.write("bad.json", "truefalse");
    const truncated = try files.write("truncated.json", "{\"x\":[");
    const duplicate = try files.write("duplicate.json", "{\"a\":1,\"\\u0061\":2}");
    const bytes = try files.write("bad-utf8", &.{0xff});
    const valid = try files.write("valid.json", "{}");
    const absent = try files.path("missing");
    try check(&.{ "-n", "--slurpfile", "unused", invalid, "take(0)" }, "", 2, "", "parse JSON binding sequence");
    try check(&.{ "-n", "--slurpfile", "unused", truncated, "take(0)" }, "", 2, "", "UnexpectedEndOfInput");
    try check(&.{ "-n", "--slurpfile", "unused", duplicate, "take(0)" }, "", 2, "", "without duplicate keys");
    try check(&.{ "-n", "--rawfile", "unused", bytes, "take(0)" }, "", 2, "", "valid UTF-8");
    try check(&.{ "-n", "--slurpfile", "unused", bytes, "take(0)" }, "", 2, "", "SyntaxError");
    try check(&.{ "--rawfile", "unused", absent, "take(0)" }, "", 2, "", "read binding file");
    try check(&.{ "-n", "--rawfile", "bad-name", valid, "." }, "", 2, "", "binding names must match");
    try check(&.{ "-n", "--arg", "x", "text", "--slurpfile", "x", valid, "." }, "", 2, "", "duplicate external binding");
    try check(&.{ "-n", "--slurpfile", "x", valid, "--rawfile", "x", valid, "." }, "", 2, "", "duplicate external binding");
    try check(&.{ "--rawfile", "name" }, "", 2, "", "requires a NAME and FILE");
    try check(&.{ "--slurpfile", "name" }, "", 2, "", "requires a NAME and FILE");
}

test "CLI file binding depth count and input-byte admission are bounded" {
    var files = try InputFiles.init();
    defer files.deinit();
    var deep: [257]u8 = undefined;
    @memset(deep[0..128], '[');
    deep[128] = '0';
    @memset(deep[129..], ']');
    const allowed = try files.write("allowed.json", deep[1..256]);
    const denied = try files.write("denied.json", &deep);
    const empty = try files.write("empty", "");
    try check(&.{ "-n", "--slurpfile", "values", allowed, "length($values)" }, "", 0, "1\n", null);
    try check(&.{ "-n", "--slurpfile", "values", denied, "take(0)" }, "", 2, "", "nesting exceeds 128 levels");
    try check(&.{ "-n", "--rawfile", "unused", "/dev/zero", "take(0)" }, "", 2, "", "shared limit 64 MiB");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "-n");
    for (0..129) |index| try args.appendSlice(a, &.{ "--rawfile", try a.print("value{d}", .{index}), empty });
    try args.append(a, "take(0)");
    try check(args.items, "", 2, "", "at most 128 external bindings");
}

test "CLI binding filename dash is literal and independent of query stdin" {
    var files = try InputFiles.init();
    defer files.deinit();
    try checkIn(files.root, &.{ "-n", "--rawfile", "text", "-", "$text" }, "", 2, "", "read binding file");
    _ = try files.write("-", "1\n2");
    try checkIn(files.root, &.{ "-nj", "--rawfile", "text", "-", "$text" }, "", 0, "1\n2", null);
    try checkIn(files.root, &.{ "-n", "--slurpfile", "values", "-", "$values" }, "", 0, "[1,2]\n", null);
    try checkIn(files.root, &.{ "-nj", "--rawfile", "text", "-", "-f", "-" }, "$text", 0, "1\n2", null);
}

test "CLI null input skips malformed missing and repeated stdin sources in every input mode" {
    var files = try InputFiles.init();
    defer files.deinit();
    const malformed = try files.write("malformed.json", "{bad}");
    const absent = try files.path("missing.json");
    try check(&.{ "-n", "[.,input_filename()]", malformed, absent, "-", "-" }, "", 0, "[null,null]\n", null);
    try check(&.{ "-n", "-s", ".", absent }, "", 0, "null\n", null);
    try check(&.{ "--slurp", "--null-input", ".", malformed }, "", 0, "null\n", null);
    try check(&.{ "-n", "--ndjson", "count", absent, malformed }, "", 0, "1\n", null);
    try check(&.{ "--ndjson", "-s", "-n", "collect", malformed, "-", "-" }, "", 0, "[null]\n", null);
    try expectExitWithOpenInputArgs(&.{ exe, "--null-input", "count", "-", absent }, "", "1\n");
}

test "CLI null input accepts named and stdin queries without data files" {
    var files = try InputFiles.init();
    defer files.deinit();
    const source = try files.write("bound.query", "{value:$value,file:input_filename()}");
    const invalid = try files.write("invalid.query", "where(");
    const absent = try files.path("missing.query");
    try check(&.{ "-n", "--argjson", "value", "42", "-f", source }, "", 0, "{\"value\":42,\"file\":null}\n", null);
    try check(&.{ "--null-input", "--argjson", "value", "false", "--from-file", source, absent }, "", 0, "{\"value\":false,\"file\":null}\n", null);
    try check(&.{ "-n", "--arg", "value", "bound", "-f", "-" }, "$value", 0, "\"bound\"\n", null);
    try check(&.{ "-s", "--ndjson", "-n", "-f", "-", "-", absent, "-" }, "[.,input_filename()]", 0, "[null,null]\n", null);
    try check(&.{ "-n", "-f", absent }, "", 2, "", "open query file");
    try check(&.{ "-n", "-f", invalid }, "", 2, "", invalid);
    try check(&.{ "-n", "-f", "-" }, "where(", 2, "", "-:1:");
    try check(&.{ "-n", "-f", source, "-f", source }, "", 2, "", "only one -f");
}

test "CLI NDJSON spans files but keeps diagnostics local to each file" {
    var files = try InputFiles.init();
    defer files.deinit();
    const a = try files.write("first.jsonl", "{\"x\":1}\n\n{\"x\":2}\n");
    const b = try files.write("second.jsonl", "{\"x\":3}\r\n");
    const broken = try files.write("broken.jsonl", "{\"x\":3}\n{}\n");
    try check(&.{ "--ndjson", ".x | sum", a, b }, "", 0, "6\n", null);
    try check(&.{ "--ndjson", "count", a, b }, "", 0, "3\n", null);
    const local_line = try std.fmt.allocPrint(t.allocator, "{s}:2:", .{broken});
    defer t.allocator.free(local_line);
    try check(&.{ "--ndjson", ".x", a, broken }, "", 2, "1\n2\n3\n", local_line);
    try check(&.{ ".", a }, "", 2, "", a);
}

test "CLI later input errors preserve emitted output and discard pending aggregates" {
    var files = try InputFiles.init();
    defer files.deinit();
    const good = try files.write("good.json", "1");
    const broken = try files.write("broken.json", "{bad}");
    const absent = try files.path("missing.json");
    try check(&.{ ".", good, broken }, "", 2, "1\n", "SyntaxError");
    try check(&.{ ".", good, absent }, "", 2, "1\n", "open input file");
    try check(&.{ "collect", good, broken }, "", 2, "", "SyntaxError");
    try check(&.{ "-s", "length(.)", good, broken }, "", 2, "", "SyntaxError");
    try check(&.{ "-s", "take(1)", good, absent }, "", 2, "", "open input file");
}

test "CLI early termination skips later filenames and works while stdin remains open" {
    var files = try InputFiles.init();
    defer files.deinit();
    const good = try files.write("good.json", "1");
    const absent = try files.path("missing.json");
    try check(&.{ "take(1) | collect", good, absent }, "", 0, "[1]\n", null);
    try check(&.{ "take(0) | count", absent }, "", 0, "0\n", null);
    try check(&.{ "-s", "take(0) | count", absent }, "", 0, "0\n", null);
    try expectExitWithOpenInputArgs(&.{ exe, "-e", "--ndjson", "take(1) | collect", "-", absent }, "false\n", "[false]\n");
}

test "CLI slurp evaluates one ordered array and has no unique filename" {
    var files = try InputFiles.init();
    defer files.deinit();
    const a = try files.write("a.json", "9007199254740993");
    const b = try files.write("b.json", "false");
    const records = try files.write("records.jsonl", "1\r\n\n1.2300e-4\n");
    try check(&.{ "-s", ".", a, b }, "", 0, "[9007199254740993,false]\n", null);
    try check(&.{ "--slurp", "[input_filename(), length(.)]", a, b }, "", 0, "[null,2]\n", null);
    try check(&.{ "-s", "--ndjson", ".", records, "-" }, "null\n", 0, "[1,1.2300e-4,null]\n", null);
    try check(&.{ "-s", "--ndjson", "-e", "." }, "\n\r\n", 0, "[]\n", null);
    try check(&.{ "-s", "." }, "", 2, "", "UnexpectedEndOfInput");
    try check(&.{ "-s", "-e", "length(.) > 2", a, b }, "", 1, "false\n", null);
}

test "CLI quantified predicates gate all reports with typed expectations" {
    var files = try InputFiles.init();
    defer files.deinit();
    const a = try files.write("passed.json", "{\"passed\":true,\"cleanup_passed\":true}");
    const b = try files.write("failed.json", "{\"passed\":false,\"cleanup_passed\":true}");
    try check(&.{ "-s", "-e", "all(., .passed and .cleanup_passed)", a, b }, "", 1, "false\n", null);
    try check(&.{ "-s", "-e", "any(., .passed)", a, b }, "", 0, "true\n", null);
    try check(&.{ "-s", "--argjson", "expected", "true", "-e", "all(., .passed == $expected)", a }, "", 0, "true\n", null);
    try check(&.{ "-s", "--ndjson", "-e", "all(., .ok)" }, "", 0, "true\n", null);
    try check(&.{ "-s", "--ndjson", "-e", "any(., .ok)" }, "", 1, "false\n", null);
    try check(&.{ "-e", "all(., .ok)" }, "[{}]", 2, "", "$[0][\"ok\"]");
}

test "CLI decimal statistics report fractional timings and gate exact comparisons" {
    try check(&.{"{samples: length(.samples), mean_ms: mean(map(.samples, divide(.,1000000,6)),6)}"}, "{\"samples\":[1000001,2000002,3000003]}", 0, "{\"samples\":3,\"mean_ms\":2.000002}\n", null);
    try check(&.{ "--argjson", "limit", "2.1", "-e", "mean(map(.samples, divide(.,1000000,6)),6) <= $limit" }, "{\"samples\":[1000001,2000002,3000003]}", 0, "true\n", null);
    try check(&.{ "-e", "mean(.,6)" }, "[]", 1, "null\n", null);
    try check(&.{ "-e", "divide(.a,.b,6)" }, "{\"a\":1,\"b\":0}", 2, "", "$[\"b\"]");
    try check(&.{"mean(.samples,6)"}, "{\"samples\":[1,null]}", 2, "", "$[\"samples\"][1]");
    try check(&.{"divide(1,3,19)"}, "", 2, "", "precision must be a constant integer");
}

test "CLI receipt assertions report the first bad receipt row after indexing" {
    const checkExact = @import("cli.zig").checkExact;
    const a = "{\"path\":\"a\",\"bytes\":9007199254740993,\"sha256\":\"aa\"}";
    const b = "{\"path\":\"b\",\"bytes\":9007199254740994,\"sha256\":\"bb\"}";
    const wrong_a = "{\"path\":\"a\",\"bytes\":9007199254740995,\"sha256\":\"aa\"}";
    const wrong_b = "{\"path\":\"b\",\"bytes\":9007199254740996,\"sha256\":\"bb\"}";
    const digest_b = "{\"path\":\"b\",\"bytes\":9007199254740994,\"sha256\":\"cc\"}";
    const args: []const []const u8 = &.{ "-e", "--argjson", "receipt", "{\"files\":[" ++ a ++ "," ++ b ++ "]}", "-f", "examples/cleanup/verify-receipt.query" };
    try checkExact(args, "[" ++ b ++ "," ++ a ++ "]", 0, "true\n", "");
    try checkExact(args, "[" ++ a ++ "]", 1, "", "{\"kind\":\"assertion_failed\",\"detail\":{\"reason\":\"missing_file\",\"path\":\"b\"}}\n");
    try checkExact(args, "[" ++ wrong_b ++ "," ++ wrong_a ++ "]", 1, "", "{\"kind\":\"assertion_failed\",\"detail\":{\"reason\":\"size_mismatch\",\"path\":\"a\",\"expected\":9007199254740993,\"observed\":9007199254740995}}\n");
    try checkExact(args, "[" ++ a ++ "," ++ digest_b ++ "]", 1, "", "{\"kind\":\"assertion_failed\",\"detail\":{\"reason\":\"digest_mismatch\",\"path\":\"b\",\"expected\":\"bb\",\"observed\":\"cc\"}}\n");
    try check(args, "[" ++ a ++ "," ++ a ++ "]", 2, "", "input path: $[1][\"path\"]");
}

test "CLI assertion framing is independent of output flags and preserves earlier writes" {
    const checkExact = @import("cli.zig").checkExact;
    const source = "assert(.ok, {z:.msg, truncated:true})";
    const input = "{\"ok\":true}\n{\"ok\":false,\"msg\":\"é\\n\"}\n{\n";
    const expected = "{\"kind\":\"assertion_failed\",\"detail\":{\"z\":\"é\\n\",\"truncated\":true}}\n";
    try checkExact(&.{ "--ndjson", "-prS", source }, input, 1, "true\n", expected);
    try checkExact(&.{ "--ndjson", "-je", source }, input, 1, "true", expected);
    try check(&.{ "-n", "assert(0,{})" }, "", 2, "", "expected a boolean");
    try check(&.{ "-n", "assert(false,.absent)" }, "", 2, "", "EvaluationFailed");
    try check(&.{ "-n", "assert(false, null)" }, "", 2, "", "must be an object");
    try check(&.{"assert(false,{})"}, "{", 2, "", "<stdin>:1:");
}

test "CLI assertion cap counts compact escaped detail bytes exactly" {
    const checkExact = @import("cli.zig").checkExact;
    const filler: [4086]u8 = @splat('a');
    const inside = "{\"x\":\"" ++ filler ++ "\\n\"}";
    const outside = "{\"x\":\"" ++ filler ++ "\\na\"}";
    try t.expectEqual(4096, inside.len);
    try t.expectEqual(4097, outside.len);
    try checkExact(&.{"assert(false, .)"}, inside, 1, "", "{\"kind\":\"assertion_failed\",\"detail\":" ++ inside ++ "}\n");
    try checkExact(&.{"assert(false, .)"}, outside, 1, "", "{\"kind\":\"assertion_failed\",\"truncated\":true}\n");
}

test "CLI concat verifies ordered case and command receipt projections in one invocation" {
    const common = .{ "-e", "--arg", "stage", "/run", "--slurpfile", "cases", "examples/cleanup/cases.json" };
    const query = "examples/cleanup/verify-commands.query";
    const commands = "examples/cleanup/commands.json";
    try check(&(common ++ .{ "-f", query, commands }), "", 0, "true\n", null);

    const verifier = try std.Io.Dir.cwd().readFileAlloc(t.io, query, t.allocator, .limited(4096));
    defer t.allocator.free(verifier);
    const changes = [_][]const u8{
        "[.[1], .[0]]",
        ".[0:1]",
        "update(., .[1].argv[1], \"/work/one/freeze.sh\")",
        "update(., .[0].stdout, \"/other.stdout\")",
        "update(., .[0].stderr, \"/run/commands/reject.stderr\")",
        "update(., .[1].returncode, 0)",
    };
    for (changes) |change| {
        const modified = try std.fmt.allocPrint(t.allocator, "{s} | {s}", .{ change, verifier });
        defer t.allocator.free(modified);
        try check(&(common ++ .{ modified, commands }), "", 1, "false\n", null);
    }
}

test "CLI concat enforces string types and locates computed array elements" {
    try check(&.{ "-nr", "--max-slurp-bytes", "0", "--max-retained-bytes", "0", "concat([\"a\",\"\",\"b\"])" }, "", 0, "ab\n", null);
    try check(&.{ "-n", "concat(map([1, null], .))" }, "", 2, "", "array element index: 0");
    try check(&.{"concat(.parts)"}, "{\"parts\":[\"ok\",null]}", 2, "", "input path: $[\"parts\"][1]");
}
