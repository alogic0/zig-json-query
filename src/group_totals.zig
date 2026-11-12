//! One owned key and accumulator per distinct group, in first-seen order.
const std = @import("std");
const scalar = @import("evaluator.zig");
const Buffered = @import("buffered.zig");
const number = @import("number.zig");
const Value = std.json.Value;
const Self = @This();
const Error = error{ OutOfMemory, EvaluationFailed };

pub const Row = struct { key: Value, count: u64, sum: i128 };
arena: std.heap.ArenaAllocator,
rows: std.ArrayList(Row) = .empty,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn add(self: *Self, evaluator: *scalar.Evaluator, key: Value, amount: ?i128, offset: usize) Error!void {
    for (self.rows.items) |*row| {
        if (!try evaluator.equal(row.key, key, offset, 0)) continue;
        const count = std.math.add(u64, row.count, 1) catch {
            evaluator.diagnostic.set(offset, "group count exceeds the supported u64 range");
            return error.EvaluationFailed;
        };
        const sum = if (amount) |value| number.arithmetic(.add, row.sum, value) catch |err| return evaluator.integerFailure(offset, err) else row.sum;
        row.count = count;
        row.sum = sum;
        return;
    }
    const allocator = self.arena.allocator();
    try self.rows.append(allocator, .{ .key = try Buffered.clone(allocator, key), .count = 1, .sum = amount orelse 0 });
}
