const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

test "automation predicate status classifies the last emitted JSON value" {
    for ([_]struct { source: []const u8, input: []const u8, status: u8 }{
        .{ .source = ".", .input = "true", .status = 0 },
        .{ .source = ".", .input = "false", .status = 1 },
        .{ .source = ".", .input = "null", .status = 1 },
        .{ .source = "each", .input = "[false,true]", .status = 0 },
        .{ .source = "each", .input = "[true,null]", .status = 1 },
        .{ .source = "each", .input = "[0,\"\",[],{}]", .status = 0 },
        .{ .source = "each", .input = "[]", .status = 4 },
        .{ .source = "where(false)", .input = "true", .status = 4 },
        .{ .source = "each | take(1)", .input = "[false,true]", .status = 1 },
    }) |case| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, case.source, &diagnostic);
        defer program.deinit();
        var bytes: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        var stream = try program.start(t.allocator, &output, &diagnostic, .{});
        defer stream.deinit();
        _ = try stream.feed(case.input);
        try stream.finish();
        try t.expectEqual(case.status, stream.predicateStatus());
    }
}

test "automation predicate status includes completion aggregates and raw output" {
    for ([_][]const u8{ "count", "collect", "sum", "sort | collect" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        var bytes: [64]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        var stream = try program.start(t.allocator, &output, &diagnostic, .{ .raw_output = true });
        defer stream.deinit();
        try stream.finish();
        try t.expectEqual(@as(u8, 0), stream.predicateStatus());
    }
}

test "automation failed writes do not classify an incomplete emission" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var bytes: [4]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(t.allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    try t.expectError(error.WriteFailed, stream.feed("true"));
    try t.expectEqual(@as(u8, 4), stream.predicateStatus());
    try t.expectError(error.StreamFailed, stream.finish());
}
