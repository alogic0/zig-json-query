//! CLI binding input preparation. Scanner supplies JSON-value boundaries;
//! Program.compileWithBindings performs strict DOM/depth/duplicate validation.
const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Kind = enum { json, raw };
pub const Spec = struct { index: usize, kind: Kind, path: []const u8 };

pub fn readNamed(a: A, io: Io, path: []const u8, limit: usize) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(limit));
}

fn whitespace(byte: u8) bool {
    return byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
}

pub fn jsonArray(a: A, input: []const u8, limit: usize) ![]u8 {
    if (limit < 2) return error.FileBindingTooLarge;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    try output.append(a, '[');
    var cursor: usize = 0;
    var first = true;
    while (cursor < input.len) {
        while (cursor < input.len and whitespace(input[cursor])) : (cursor += 1) {}
        if (cursor == input.len) break;
        const start = cursor;
        // Avoid skipValue's precondition trap on stray closers/end tokens.
        if (std.mem.indexOfScalar(u8, "{[\"tfn-0123456789", input[start]) == null) return error.SyntaxError;
        var scanner = std.json.Scanner.initCompleteInput(a, input[start..]);
        defer scanner.deinit();
        try scanner.skipValue();
        if (scanner.cursor == 0) return error.SyntaxError;
        cursor += scanner.cursor;
        const primitive = std.mem.indexOfScalar(u8, "tfn-0123456789", input[start]) != null;
        if (primitive and cursor < input.len and !whitespace(input[cursor]) and std.mem.indexOfScalar(u8, "{[\"", input[cursor]) == null) return error.SyntaxError;
        const comma: usize = if (first) 0 else 1;
        // Always reserve the closing bracket before allocating/copying text.
        if (cursor - start > limit - output.items.len - 1 or comma > limit - output.items.len - 1 - (cursor - start)) return error.FileBindingTooLarge;
        if (!first) try output.append(a, ',');
        try output.appendSlice(a, input[start..cursor]);
        first = false;
    }
    try output.append(a, ']');
    return output.toOwnedSlice(a);
}

test "file binding framing preserves complete values and exact source spellings" {
    const t = std.testing;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = " \n\t", .expected = "[]" },
        .{ .input = "{\n\"n\":9007199254740993\n}\r\n[1.2300e-4]\nfalse null", .expected = "[{\n\"n\":9007199254740993\n},[1.2300e-4],false,null]" },
        .{ .input = "{}[]\"a\"\"é\\u0000\"true{}false[]1[]", .expected = "[{},[],\"a\",\"é\\u0000\",true,{},false,[],1,[]]" },
    };
    for (cases) |case| {
        const encoded = try jsonArray(t.allocator, case.input, 4096);
        defer t.allocator.free(encoded);
        try t.expectEqualStrings(case.expected, encoded);
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, encoded, .{ .parse_numbers = false });
        parsed.deinit();
    }
    for ([_][]const u8{ "]", "}", ",", "truefalse", "null0", "1x", "01", "[1,]", "{\"x\":}", "\x00", "\x0b" }) |bad| try t.expectError(error.SyntaxError, jsonArray(t.allocator, bad, 4096));
    try t.expectError(error.UnexpectedEndOfInput, jsonArray(t.allocator, "{\"x\":[1", 4096));
}

test "file binding framing enforces encoded limits and releases failed allocations" {
    const t = std.testing;
    const exact = try jsonArray(t.allocator, "1 2", 5);
    defer t.allocator.free(exact);
    try t.expectEqualStrings("[1,2]", exact);
    try t.expectError(error.FileBindingTooLarge, jsonArray(t.allocator, "1 2", 4));
    try t.expectError(error.FileBindingTooLarge, jsonArray(t.allocator, "", 1));
    const Exercise = struct {
        fn run(a: A) !void {
            const bytes = try jsonArray(a, "{\"a\":[1,2,3]} [true,null] \"text\"", 4096);
            defer a.free(bytes);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Exercise.run, .{});
}

test "named file reads enforce their bound even for non-positional sources" {
    try std.testing.expectError(error.StreamTooLong, readNamed(std.testing.allocator, std.testing.io, "/dev/zero", 8));
}
