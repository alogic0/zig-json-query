const std = @import("std");
const input = @import("input.zig");
const query = @import("root.zig");
const t = std.testing;

fn reference(a: std.mem.Allocator, text: []const u8, diagnostic: *query.Diagnostic) !std.json.Parsed(std.json.Value) {
    try input.checkDepth(text, diagnostic);
    var scanner = std.json.Scanner.initCompleteInput(a, text);
    defer scanner.deinit();
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    return std.json.parseFromTokenSource(std.json.Value, a, &scanner, .{ .parse_numbers = false }) catch |err| {
        diagnostic.input_offset = @intCast(position.getByteOffset());
        diagnostic.input_line = position.getLine();
        diagnostic.input_column = position.getColumn();
        return err;
    };
}

fn compare(text: []const u8) !void {
    var old_diagnostic: query.Diagnostic = .{};
    var new_diagnostic: query.Diagnostic = .{};
    const old = reference(t.allocator, text, &old_diagnostic) catch |err| {
        try t.expectError(err, input.parse(t.allocator, text, &new_diagnostic));
        try t.expectEqual(old_diagnostic.input_offset, new_diagnostic.input_offset);
        try t.expectEqual(old_diagnostic.input_line, new_diagnostic.input_line);
        try t.expectEqual(old_diagnostic.input_column, new_diagnostic.input_column);
        return;
    };
    defer old.deinit();
    const new = try input.parse(t.allocator, text, &new_diagnostic);
    defer new.deinit();
    const old_text = try std.json.Stringify.valueAlloc(t.allocator, old.value, .{});
    defer t.allocator.free(old_text);
    const new_text = try std.json.Stringify.valueAlloc(t.allocator, new.value, .{});
    defer t.allocator.free(new_text);
    try t.expectEqualStrings(old_text, new_text);
}

test "input adapter preserves standard errors and locations including decoded duplicate names" {
    for ([_][]const u8{
        "",            " ",           "{} []",    "[1,]",         "{\"x\":}",                 "{\"x\":1,}", "01",                                     "1.",                                          "1e",                                "truex",
        "\"\\uD800\"", "\"\\uDC00\"", "\"\xff\"", "\"\xc0\xaf\"", "\"\xed\xa0\x80\"",         "\"\x00\"",   "{\"a\":1,\"\\u0061\":{\"deep\":[2,3]}}", "{\"a\":1,\"b\":2,\"c\":3,\"d\":4,\"a\":[5]}", "{\n\"a\":0,\n\"unused\":\"\xff\"}", "{\n\"a\":0,\n\"a\":[1,2]}",
        "[]",          "{}",          "null",     "1.2300e+42",   "-0e999999999999999999999",
        "\"é😀\\n\"",
    }) |text| try compare(text);
}

test "input adapter matches standard construction across small-map and indexed-map boundaries" {
    for (0..40) |fields| {
        var text = std.Io.Writer.Allocating.init(t.allocator);
        defer text.deinit();
        try text.writer.writeByte('{');
        for (0..fields) |index| {
            if (index != 0) try text.writer.writeByte(',');
            try text.writer.print("\"field-{d}\":{{\"n\":1.00,\"data\":[false,null,\"é\\n\"]}}", .{index});
        }
        try text.writer.writeByte('}');
        try compare(text.written());
        if (fields != 0) {
            text.writer.end -= 1;
            try text.writer.writeAll(",\"field-0\":{\"duplicate\":[1,2]}}");
            try compare(text.written());
        }
    }
    var deep = std.Io.Writer.Allocating.init(t.allocator);
    defer deep.deinit();
    for (0..128) |_| try deep.writer.writeByte('[');
    try deep.writer.writeByte('0');
    for (0..128) |_| try deep.writer.writeByte(']');
    try compare(deep.written());
    try deep.writer.writeByte('[');
    try compare(deep.written());
}

test "input adapter retained keys strings and exact tokens survive caller-buffer reuse" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{data:.,keys:keys(.)} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var text = "{\"label\":\"first\",\"n\":1.00,\"escaped\":\"é\\n\"}".*;
    _ = try stream.feed(&text);
    @memset(&text, 'x');
    _ = try stream.feed("{\"label\":\"second\"}");
    try stream.finish();
    try t.expectEqualStrings("[{\"data\":{\"label\":\"first\",\"n\":1.00,\"escaped\":\"é\\n\"},\"keys\":[\"escaped\",\"label\",\"n\"]},{\"data\":{\"label\":\"second\"},\"keys\":[\"label\"]}]\n", output.written());
}

test "input adapter allocation failures free partially built escaped and nested values" {
    const text = "{\"a\":{\"b\":[1,\"é\\n\"]},\"b\":0,\"c\":1,\"d\":2,\"e\":3,\"f\":4}";
    var diagnostic: query.Diagnostic = .{};
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    const parsed = try input.parse(baseline.allocator(), text, &diagnostic);
    parsed.deinit();
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        diagnostic = .{};
        try t.expectError(error.OutOfMemory, input.parse(failing.allocator(), text, &diagnostic));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "input adapter bounded large-document reservation cleans up on allocation failure" {
    var text = std.Io.Writer.Allocating.init(t.allocator);
    defer text.deinit();
    try text.writer.writeAll("{\"payload\":\"");
    for (0..64 * 1024) |_| try text.writer.writeByte('a');
    try text.writer.writeAll("\",\"decoded\":\"\\u0061\"}");
    var diagnostic: query.Diagnostic = .{};
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    const parsed = try input.parse(baseline.allocator(), text.written(), &diagnostic);
    parsed.deinit();
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        diagnostic = .{};
        try t.expectError(error.OutOfMemory, input.parse(failing.allocator(), text.written(), &diagnostic));
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "input arrays preserve standard values and diagnostics across storage boundaries" {
    for ([_]usize{ 0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 2049 }) |length| {
        for (0..3) |shape| {
            var text = std.Io.Writer.Allocating.init(t.allocator);
            defer text.deinit();
            try text.writer.writeByte('[');
            for (0..length) |index| {
                if (index != 0) try text.writer.writeByte(',');
                try text.writer.writeAll(switch (shape) {
                    0 => if (index < 32) "1.00" else "{\"é\":[-0,\"\\u0061\"]}",
                    1 => "{\"n\":1e+2,\"array\":[\"é\\n\",false]}",
                    2 => if (index % 2 == 0) "[]" else "{}",
                    else => unreachable,
                });
            }
            try text.writer.writeByte(']');
            try compare(text.written());
            if (length != 0) {
                text.writer.end -= 1;
                try text.writer.writeAll(",]");
                try compare(text.written());
            }
        }
    }
}

fn buildWithAllocators(a: std.mem.Allocator, temporary: std.mem.Allocator, bytes: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(temporary, bytes);
    defer scanner.deinit();
    _ = try @import("value_builder.zig").build(a, temporary, &scanner, bytes.len, {});
    try t.expectEqual(.end_of_document, try scanner.next());
}

fn allocationTrial(bytes: []const u8, failure: ?struct { temporary: bool, index: usize }) !struct { arena: usize, temporary: usize } {
    var region = std.heap.ArenaAllocator.init(t.allocator);
    defer region.deinit();
    var arena = t.FailingAllocator.init(region.allocator(), .{ .fail_index = if (failure != null and !failure.?.temporary) failure.?.index else std.math.maxInt(usize), .resize_fail_index = 0 });
    var temporary = t.FailingAllocator.init(t.allocator, .{ .fail_index = if (failure != null and failure.?.temporary) failure.?.index else std.math.maxInt(usize), .resize_fail_index = 0 });
    buildWithAllocators(arena.allocator(), temporary.allocator(), bytes) catch |err| {
        if (failure == null) return err;
        try t.expectEqual(error.OutOfMemory, err);
        try t.expect(if (failure.?.temporary) temporary.has_induced_failure else arena.has_induced_failure);
        try t.expectEqual(temporary.allocated_bytes, temporary.freed_bytes);
        return .{ .arena = arena.alloc_index, .temporary = temporary.alloc_index };
    };
    try t.expect(failure == null);
    try t.expectEqual(temporary.allocated_bytes, temporary.freed_bytes);
    return .{ .arena = arena.alloc_index, .temporary = temporary.alloc_index };
}

test "input array failures release temporary chunks and partially parsed arena storage" {
    var text = std.Io.Writer.Allocating.init(t.allocator);
    defer text.deinit();
    try text.writer.writeByte('[');
    for (0..65) |index| {
        if (index != 0) try text.writer.writeByte(',');
        try text.writer.writeAll("{\"n\":1.00,\"s\":\"é\\n\"}");
    }
    try text.writer.writeByte(']');
    const counts = try allocationTrial(text.written(), null);
    for (0..counts.arena) |index| _ = try allocationTrial(text.written(), .{ .temporary = false, .index = index });
    for (0..counts.temporary) |index| _ = try allocationTrial(text.written(), .{ .temporary = true, .index = index });
}

test "input temporary array storage is released before retained caller buffers are reused" {
    var text = std.Io.Writer.Allocating.init(t.allocator);
    defer text.deinit();
    try text.writer.writeByte('[');
    for (0..70) |index| {
        if (index != 0) try text.writer.writeByte(',');
        try text.writer.writeAll("{\"n\":1.00,\"s\":\"é\\n\"}");
    }
    try text.writer.writeByte(']');
    var diagnostic: query.Diagnostic = .{};
    const parsed = try reference(t.allocator, text.written(), &diagnostic);
    defer parsed.deinit();
    var expected = std.Io.Writer.Allocating.init(t.allocator);
    defer expected.deinit();
    try expected.writer.writeByte('[');
    try std.json.Stringify.value(parsed.value, .{}, &expected.writer);
    try expected.writer.writeAll("]\n");
    var program = try query.Program.compile(t.allocator, ". | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed(text.written());
    @memset(text.written(), 'x');
    try stream.finish();
    try t.expectEqualStrings(expected.written(), output.written());
}
