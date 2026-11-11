//! Ordered object copies for deterministic output and structural comparison.
//! Callers enforce container-depth limits. Leaves borrow the original storage.
const std = @import("std");
const Value = std.json.Value;

pub fn ordered(allocator: std.mem.Allocator, value: Value) error{OutOfMemory}!Value {
    return switch (value) {
        .object => |object| blk: {
            const keys = try allocator.dupe([]const u8, object.keys());
            std.sort.pdq([]const u8, keys, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            var result: std.json.ObjectMap = .empty;
            for (keys) |key| try result.put(allocator, key, try ordered(allocator, object.get(key).?));
            break :blk .{ .object = result };
        },
        .array => |array| blk: {
            var result = std.json.Array.init(allocator);
            try result.ensureTotalCapacity(array.items.len);
            for (array.items) |item| result.appendAssumeCapacity(try ordered(allocator, item));
            break :blk .{ .array = result };
        },
        else => value,
    };
}
