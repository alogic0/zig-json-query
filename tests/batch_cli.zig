const std = @import("std");
const S = @import("test_support");
const exe = @import("test_options").exe;
const t = std.testing;
const check = @import("cli.zig").check;
const expectExitWithOpenInputArgs = @import("cli.zig").expectExitWithOpenInputArgs;

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
