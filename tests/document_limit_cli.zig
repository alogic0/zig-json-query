const std = @import("std");
const t = std.testing;
const check = @import("cli.zig").check;

test "CLI document byte limit requires a positive platform sized decimal value" {
    for ([_][]const u8{ "", "0", "-1", "+1", "1.0", "1MiB", " 1", "18446744073709551616" }) |bad| {
        try check(&.{ "--max-document-bytes", bad, "-f", "/nonexistent-jqz-document-limit-query" }, "", 2, "", "positive decimal bytes");
    }
    try check(&.{"--max-document-bytes"}, "", 2, "", "requires positive decimal bytes");
    try check(&.{ "--max-document-bytes", "18446744073709551615", "-n", "true" }, "", 0, "true\n", null);
}

test "CLI document byte limit accepts exact boundaries and a deliberately raised bound" {
    try check(&.{ "--max-document-bytes", "7", ".a" }, "{\"a\":1}", 0, "1\n", null);
    try check(&.{ "--max-document-bytes", "6", ".a" }, "{\"a\":1}", 2, "", "limit 6 bytes");
    try check(&.{ "--max-document-bytes", "7", ".a" }, "{\"a\":1}\n", 2, "", "limit 7 bytes");
    try check(&.{ "--max-document-bytes", "8", ".a" }, "{\"a\":1}\n", 0, "1\n", null);
    try check(&.{ "--max-document-bytes", "4", "." }, "\"é\"", 0, "\"é\"\n", null);
    try check(&.{ "--max-document-bytes", "3", "." }, "\"é\"", 2, "", "limit 3 bytes");
}

test "CLI ordinary file limits apply separately to every input" {
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "input.json", .data = "{\"a\":1}" });
    const path = try temp.dir.realPathFileAlloc(t.io, "input.json", t.allocator);
    defer t.allocator.free(path);
    try check(&.{ "--max-document-bytes", "7", ".a", path, path }, "", 0, "1\n1\n", null);
    try check(&.{ "--max-document-bytes", "6", ".a", path }, "", 2, "", "limit 6 bytes");
    try check(&.{ "--max-document-bytes", "7", ".a", path, "-" }, "{\"a\":2}", 0, "1\n2\n", null);
}

test "CLI admitted documents are validated completely before projection" {
    for ([_][]const u8{ "{\"ok\":1} {}", "{\"ok\":1,\"unused\":\"\xff\"}", "{\"ok\":1,\"unused\":[0,]}", "{\"ok\":1,\"ok\":2}" }) |input| {
        try check(&.{ "--max-document-bytes", "1024", ".ok" }, input, 2, "", "<stdin>:");
    }
}

test "CLI document limits do not replace NDJSON line limits" {
    try check(&.{ "--max-document-bytes", "1", "--ndjson", ".a" }, "{\"a\":1}\n{\"a\":2}\n", 0, "1\n2\n", null);
    try check(&.{ "--max-document-bytes", "1", "--ndjson", "-s", "length(.)" }, "{\"a\":1}\n{\"a\":2}\n", 0, "2\n", null);
    const long_line = try t.allocator.alloc(u8, 1024 * 1024 + 3);
    defer t.allocator.free(long_line);
    @memset(long_line, 'x');
    long_line[0] = '"';
    long_line[long_line.len - 2] = '"';
    long_line[long_line.len - 1] = '\n';
    try check(&.{ "--max-document-bytes", "134217728", "--ndjson", "." }, long_line, 2, "", "1 MiB");
}

test "CLI document retained slurp and binding limits are independent" {
    try check(&.{ "--max-document-bytes", "4", "--max-retained-bytes", "1", "collect" }, "null", 2, "", "increase --max-retained-bytes");
    try check(&.{ "--max-document-bytes", "4", "--max-slurp-bytes", "1", "-s", "." }, "null", 2, "", "increase --max-slurp-bytes");
    try check(&.{ "--max-document-bytes", "4", "--max-slurp-bytes", "1048576", "--max-retained-bytes", "0", "-s", "length(.)" }, "null", 0, "1\n", null);
    try check(&.{ "--max-document-bytes", "3", "--max-slurp-bytes", "1048576", "-s", "." }, "null", 2, "", "limit 3 bytes");
    try check(&.{ "--max-document-bytes", "1", "-n", "--argjson", "v", "{\"larger\":true}", "$v" }, "", 0, "{\"larger\":true}\n", null);
    var temp = t.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(t.io, .{ .sub_path = "query", .data = "length(.)" });
    const query_path = try temp.dir.realPathFileAlloc(t.io, "query", t.allocator);
    defer t.allocator.free(query_path);
    try check(&.{ "--max-document-bytes", "2", "-f", query_path }, "{}", 0, "0\n", null);
}
