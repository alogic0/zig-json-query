const std = @import("std");
const query = @import("root.zig");
const input = @import("input.zig");
const t = std.testing;

test "document input default remains 64 MiB and zero session limits are invalid" {
    try t.expectEqual(@as(usize, 67108864), query.max_input_bytes);
    try t.expectEqual(query.max_input_bytes, (query.StreamOptions{}).max_document_bytes);
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.InvalidOptions, program.start(t.allocator, &output.writer, &diagnostic, .{ .max_document_bytes = 0 }));
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    const large = try t.allocator.alloc(u8, query.max_input_bytes + 1);
    defer t.allocator.free(large);
    try t.expectError(error.InputTooLarge, stream.feed(large));
    try t.expectEqualStrings("", output.written());
}

test "document input boundaries apply per feed and preserve failed session state" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var small = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_document_bytes = 4 });
    defer small.deinit();
    _ = try small.feed("null");
    _ = try small.feed("true");
    try t.expectError(error.InputTooLarge, small.feed("false"));
    try t.expectError(error.StreamFailed, small.finish());
    try t.expectEqualStrings("null\ntrue\n", output.written());
    output.clearRetainingCapacity();
    var raised = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_document_bytes = 5, .max_collect_bytes = 0 });
    defer raised.deinit();
    _ = try raised.feed("false");
    try raised.finish();
    try t.expectEqualStrings("false\n", output.written());
}

test "document parser limits preserve complete validation and strict nesting" {
    var diagnostic: query.Diagnostic = .{};
    try t.expectError(error.InvalidOptions, input.parseWithLimit(t.allocator, "null", &diagnostic, 0));
    for ([_][]const u8{ "{} {}", "{\"a\":1,\"a\":2}", "[1,]", "\"\xff\"" }) |bytes| {
        const parsed = input.parseWithLimit(t.allocator, bytes, &diagnostic, 1024) catch continue;
        parsed.deinit();
        return error.AcceptedInvalidJson;
    }
    var nested: [258]u8 = undefined;
    @memset(nested[0..129], '[');
    @memset(nested[129..], ']');
    try t.expectError(error.InputTooDeep, input.parseWithLimit(t.allocator, &nested, &diagnostic, 1024));
}

test "slurp source byte admission stays separate from owned capacity" {
    var diagnostic: query.Diagnostic = .{};
    const admitted = try query.Slurp.init(t.allocator, 1048576);
    defer admitted.deinit();
    try admitted.appendWithDocumentLimit("null", &diagnostic, 4);
    try t.expectError(error.InputTooLarge, admitted.appendWithDocumentLimit("false", &diagnostic, 4));
    const bounded = try query.Slurp.init(t.allocator, 1);
    defer bounded.deinit();
    try t.expectError(error.SlurpTooLarge, bounded.appendWithDocumentLimit("false", &diagnostic, 5));
    const zero = try query.Slurp.init(t.allocator, 1048576);
    defer zero.deinit();
    try t.expectError(error.InvalidOptions, zero.appendWithDocumentLimit("null", &diagnostic, 0));
}

test "session document byte limits do not constrain embedded JSON or binding text" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(t.allocator, "fromjson($payload)", &.{.{ .name = "payload", .value = .{ .string = "{\"larger\":true}" } }}, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{ .max_document_bytes = 1 });
    defer stream.deinit();
    _ = try stream.feed("0");
    try stream.finish();
    try t.expectEqualStrings("{\"larger\":true}\n", output.written());
}
