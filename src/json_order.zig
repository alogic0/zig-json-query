//! Ordered object copies for deterministic output and structural comparison.
//! Callers enforce container-depth limits. Leaves borrow the original storage.
const std = @import("std");
const number = @import("number.zig");
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

fn rank(value: Value) u8 {
    return switch (value) {
        .null => 0,
        .bool => 1,
        .number_string => 2,
        .string => 3,
        .array => 4,
        .object => 5,
        .integer, .float => unreachable,
    };
}

/// Compare ordered copies with prevalidated numeric exponents and depth. The
/// comparator cannot fail or allocate during sorting. Original values are kept
/// separately so equal representatives preserve their spelling and field order.
pub fn compare(a: Value, b: Value) std.math.Order {
    const types = std.math.order(rank(a), rank(b));
    if (types != .eq) return types;
    return switch (a) {
        .null => .eq,
        .bool => std.math.order(@intFromBool(a.bool), @intFromBool(b.bool)),
        .number_string => number.compare(a.number_string, b.number_string) catch unreachable,
        .string => std.mem.order(u8, a.string, b.string),
        .array => |array| blk: {
            for (array.items[0..@min(array.items.len, b.array.items.len)], b.array.items[0..@min(array.items.len, b.array.items.len)]) |av, bv| {
                const order = compare(av, bv);
                if (order != .eq) break :blk order;
            }
            break :blk std.math.order(array.items.len, b.array.items.len);
        },
        .object => |object| blk: {
            const length = @min(object.count(), b.object.count());
            for (object.keys()[0..length], b.object.keys()[0..length]) |ak, bk| {
                const order = std.mem.order(u8, ak, bk);
                if (order != .eq) break :blk order;
            }
            const sizes = std.math.order(object.count(), b.object.count());
            if (sizes != .eq) break :blk sizes;
            for (object.values(), b.object.values()) |av, bv| {
                const order = compare(av, bv);
                if (order != .eq) break :blk order;
            }
            break :blk .eq;
        },
        .integer, .float => unreachable,
    };
}
