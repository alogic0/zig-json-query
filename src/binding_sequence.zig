//! Shared source and encoded byte limits for external bindings.
const std = @import("std");
const A = std.mem.Allocator;

pub const BindingBudget = struct {
    source_left: usize,
    prepared_left: usize,

    pub fn init(limit: usize) BindingBudget {
        const n = @min(limit, @import("input.zig").max_bytes);
        return .{ .source_left = n, .prepared_left = n };
    }

    /// Account for inline and raw bindings that keep their original bytes.
    pub fn chargeText(self: *BindingBudget, n: usize) !void {
        if (n > self.source_left or n > self.prepared_left) return error.FileBindingTooLarge;
        self.source_left -= n;
        self.prepared_left -= n;
    }

    /// Frame the CLI --slurpfile JSON sequence from already captured bytes.
    /// Free the result after compileWithBindings, which validates and copies it.
    /// A failed preparation consumes neither budget.
    pub fn prepareJson(self: *BindingBudget, a: A, bytes: []const u8) ![]u8 {
        if (bytes.len > self.source_left) return error.FileBindingTooLarge;
        const value = try jsonArray(a, bytes, self.prepared_left);
        self.source_left -= bytes.len;
        self.prepared_left -= value.len;
        return value;
    }
};

fn whitespace(byte: u8) bool {
    return byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
}

fn jsonArray(a: A, input: []const u8, limit: usize) ![]u8 {
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

test "cumulative source and prepared limits are independent" {
    const t = std.testing;
    var budget = BindingBudget.init(5);
    try budget.chargeText(1);
    const frame = try budget.prepareJson(t.allocator, "   1");
    defer t.allocator.free(frame);
    try t.expectEqualStrings("[1]", frame);
    try t.expectEqual(@as(usize, 0), budget.source_left);
    try t.expectEqual(@as(usize, 1), budget.prepared_left);
    try t.expectError(error.FileBindingTooLarge, budget.prepareJson(t.allocator, ""));
    budget = BindingBudget.init(3);
    const other = try budget.prepareJson(t.allocator, "1");
    defer t.allocator.free(other);
    try t.expectError(error.FileBindingTooLarge, budget.chargeText(1));
    try t.expectEqual(@as(usize, 2), budget.source_left);
    try t.expectError(error.FileBindingTooLarge, budget.prepareJson(t.allocator, "   "));
}
