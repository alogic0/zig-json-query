const std = @import("std");
const query = @import("query");

test "external consumer owns sessions and composes new stages" {
    const allocator = std.testing.allocator;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "sort_by(.k) | group_by(.k) | each | .v*2 | sum", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var session = try program.start(allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 8192 });
    defer session.deinit();
    _ = try session.feed("{\"k\":2,\"v\":9007199254740993}");
    _ = try session.feed("{\"k\":1,\"v\":1}");
    try session.finish();
    try std.testing.expectEqualStrings("18014398509481988\n", output.written());
}
