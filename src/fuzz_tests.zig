const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

const sources = [_][]const u8{
    ".",                                 ".x? ?? 0",                     "each | take(2) | collect",        "each | sum",
    "sort_by(.x)",                       "group_by(.) | collect",        "[.,.]",                           ".+1",
    "1/.",                               "matches(., \"^a+$\")",         "collect | each | sort | collect", "where(. == .) | count",
    "take(0) | sum",                     "exists(.x?)",                  "length(.)",                       "keys(.)",
    "{x: .x? ?? null, fields: keys(.)}", ".[-1]? ?? null",               ".[-3:]",                          "map(., {value: ., size: length(.)})",
    "filter(., . == null)",              "map(filter(., . != null), .)", "$bound.value",
};

fn input(smith: *t.Smith, buffer: []u8) []const u8 {
    return if (smith.in) |bytes| bytes[0..@min(bytes.len, buffer.len)] else buffer[0..smith.slice(buffer)];
}

fn parserOne(_: void, smith: *t.Smith) !void {
    var buffer: [512]u8 = undefined;
    const source = input(smith, &buffer);
    var diagnostic: query.Diagnostic = .{};
    var program = query.Program.compile(t.allocator, source, &diagnostic) catch |err| {
        try t.expectEqual(error.InvalidQuery, err);
        try t.expect(diagnostic.offset <= source.len);
        try t.expect(diagnostic.message.len != 0);
        return;
    };
    program.deinit();
}

fn evaluatorOne(_: void, smith: *t.Smith) !void {
    var buffer: [512]u8 = undefined;
    const bytes = input(smith, &buffer);
    if (bytes.len == 0) return;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(t.allocator, sources[bytes[0] % sources.len], &.{.{ .name = "bound", .value = .{ .json = "{\"value\":9007199254740993}" } }}, &diagnostic);
    defer program.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var stream = try program.start(t.allocator, &output, &diagnostic, .{ .max_collect_bytes = 8192 });
    defer stream.deinit();
    for (0..3) |_| {
        if (!stream.needsInput()) break;
        _ = stream.feed(bytes[1..]) catch |err| {
            if (err == error.OutOfMemory) return err;
            try t.expectError(error.StreamFailed, stream.finish());
            return;
        };
    }
    stream.finish() catch |err| {
        if (err == error.OutOfMemory) return err;
        try t.expectError(error.StreamFailed, stream.finish());
        return;
    };
    var lines = std.mem.splitScalar(u8, output.buffered(), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{ .parse_numbers = false });
        defer parsed.deinit();
        // Validate the output/input depth contract as well as JSON syntax.
        try t.expect(@import("evaluator.zig").withinDepth(parsed.value, 0));
    }
}

test "fuzz parser" {
    try t.fuzz({}, parserOne, .{ .corpus = &.{ ".", "1-2*3", "sort_by(.x) | group_by(.)", "take(0) | sum", "matches(., \"(?i)^a\")", "{x:.x? ?? 0}", "{passed, count: length(.http), fields: keys(.)}", ".[-3:][0]?", "map(filter(.rows, .ok), {name})", ".[-18446744073709551615:]", "filter(.,)", "", "[", "-" } });
}

test "fuzz evaluator" {
    try t.fuzz({}, evaluatorOne, .{ .corpus = &.{ "\x00null", "\x01{}", "\x02[1,2,3]", "\x03[1,2,3]", "\x04{\"x\":1}", "\x05{\"a\":1}", "\x07-170141183460469231731687303715884105728", "\x080", "\x09\"aaa\"", "\x0a2", "\x0b1e999", "\x0c{bad}", "\x0d{}", "\x0e\"é😀\"", "\x0f{\"z\":1,\"a\":2}", "\x10{}", "\x11[]", "\x12[1,2,3]", "\x13[\"é\",\"abc\"]", "\x14[null,1,null]", "\x15[null,false,9007199254740993]" } });
}
