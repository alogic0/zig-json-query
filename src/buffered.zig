//! Owned sort/group rows. All storage, including grouping scratch, uses the
//! session's retained allocator. Downstream consumers borrow synchronously.
const std = @import("std");
const scalar = @import("evaluator.zig");
const row_ops = @import("rows.zig");
const A = std.mem.Allocator;
const Value = std.json.Value;
const Self = @This();

pub const Row = row_ops.Row;
arena: std.heap.ArenaAllocator,
rows: std.ArrayList(Row) = .empty,

pub fn init(allocator: A) Self {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn append(self: *Self, value: Value, key: Value) error{OutOfMemory}!void {
    const allocator = self.arena.allocator();
    try self.rows.append(allocator, .{ .value = try clone(allocator, value), .key = try clone(allocator, key) });
}

pub fn sort(self: *Self) void {
    row_ops.sort(self.rows.items);
}

/// Compare before changing scratch: callers may have to distinguish a numeric
/// comparison error from an allocator/budget failure.
pub fn group(self: *Self, evaluator: *scalar.Evaluator, visited: []bool, start: usize, offset: usize) !Value {
    return row_ops.group(self.arena.allocator(), self.rows.items, visited, start, evaluator, offset);
}

pub fn clone(allocator: A, value: Value) error{OutOfMemory}!Value {
    return switch (value) {
        .null, .bool => value,
        .string => |bytes| .{ .string = try allocator.dupe(u8, bytes) },
        .number_string => |bytes| .{ .number_string = try allocator.dupe(u8, bytes) },
        .array => |array| blk: {
            var result = std.json.Array.init(allocator);
            try result.ensureTotalCapacity(array.items.len);
            for (array.items) |item| result.appendAssumeCapacity(try clone(allocator, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result: std.json.ObjectMap = .empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| try result.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try clone(allocator, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
        .integer, .float => unreachable,
    };
}
