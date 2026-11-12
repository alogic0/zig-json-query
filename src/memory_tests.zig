const std = @import("std");
const query = @import("root.zig");
const Budget = @import("collection_budget.zig");
const t = std.testing;

test "memory diagnostics preserve rejected capacity after retained cleanup" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "collect", &diagnostic);
    defer program.deinit();
    var bytes: [16]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(t.allocator, &output, &diagnostic, .{ .max_collect_bytes = 4096 });
    defer stream.deinit();
    var rejected = false;
    for (0..1000) |_| {
        _ = stream.feed("null") catch |err| {
            try t.expectEqual(error.EvaluationFailed, err);
            rejected = true;
            break;
        };
    }
    try t.expect(rejected);
    const failure = diagnostic.budget.?;
    try t.expectEqual(.retained, failure.kind);
    try t.expectEqual(@as(usize, 4096), failure.limit);
    try t.expect(failure.retained > 0 and failure.retained <= failure.limit);
    try t.expect(failure.requested > failure.limit - failure.retained);
    try t.expectEqual(@as(usize, 0), stream.execution.budget.used);
    try t.expectError(error.StreamFailed, stream.finish());
    try t.expectEqualStrings("", output.buffered());
}

test "memory diagnostics distinguish slurp admission from allocator exhaustion" {
    var diagnostic: query.Diagnostic = .{};
    const slurp = try query.Slurp.init(t.allocator, 1);
    defer slurp.deinit();
    try t.expectError(error.SlurpTooLarge, slurp.append("null", &diagnostic));
    const failure = diagnostic.budget.?;
    try t.expectEqual(.slurp, failure.kind);
    try t.expectEqual(@as(usize, 1), failure.limit);
    try t.expect(failure.requested > failure.limit);
    var empty: [0]u8 = .{};
    var backing = std.heap.FixedBufferAllocator.init(&empty);
    var budget: Budget = .{ .backing = backing.allocator(), .limit = 4096 };
    try t.expectError(error.OutOfMemory, budget.allocator().alloc(u8, 8));
    try t.expect(!budget.denied);
    try t.expectEqual(@as(usize, 0), budget.used);
}
