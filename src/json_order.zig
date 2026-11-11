//! Ordered object copies for deterministic output and structural comparison.
//! Callers enforce container-depth limits. Leaves borrow the original storage.
const std = @import("std");
const number = @import("number.zig");
const Value = std.json.Value;

pub fn ordered(allocator: std.mem.Allocator, value: Value) error{OutOfMemory}!Value {
    return (try prepare(allocator, value)).value;
}

const Prepared = struct { value: Value, changed: bool };

fn prepare(allocator: std.mem.Allocator, value: Value) error{OutOfMemory}!Prepared {
    return switch (value) {
        .object => |object| blk: {
            const names = object.keys();
            var sorted = true;
            if (names.len > 1) for (names[0 .. names.len - 1], names[1..]) |a, b| {
                if (std.mem.order(u8, a, b) == .gt) {
                    sorted = false;
                    break;
                }
            };
            if (!sorted) {
                const keys = try allocator.dupe([]const u8, names);
                defer allocator.free(keys);
                std.sort.pdq([]const u8, keys, {}, struct {
                    fn less(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.less);
                var result = try objectStorage(allocator, names.len);
                const entries = result.entries.slice();
                for (keys, 0..) |key, index| {
                    entries.items(.key)[index] = key;
                    entries.items(.value)[index] = (try prepare(allocator, object.get(key).?)).value;
                }
                try result.reIndex(allocator);
                break :blk .{ .value = .{ .object = result }, .changed = true };
            }
            var copy: ?std.json.ObjectMap = null;
            for (object.values(), 0..) |item, index| {
                const child = try prepare(allocator, item);
                if (child.changed and copy == null) {
                    copy = try objectStorage(allocator, names.len);
                    const entries = copy.?.entries.slice();
                    @memcpy(entries.items(.key), names);
                    @memcpy(entries.items(.value)[0..index], object.values()[0..index]);
                }
                if (copy) |*result| result.entries.items(.value)[index] = child.value;
            }
            if (copy) |*result| {
                try result.reIndex(allocator);
                break :blk .{ .value = .{ .object = result.* }, .changed = true };
            }
            break :blk .{ .value = value, .changed = false };
        },
        .array => |array| blk: {
            var copy: ?std.json.Array = null;
            for (array.items, 0..) |item, index| {
                const child = try prepare(allocator, item);
                if (child.changed and copy == null) {
                    copy = std.json.Array.init(allocator);
                    try copy.?.ensureTotalCapacity(array.items.len);
                    try copy.?.appendSlice(array.items[0..index]);
                }
                if (copy) |*result| result.appendAssumeCapacity(child.value);
            }
            if (copy) |result| break :blk .{ .value = .{ .array = result }, .changed = true };
            break :blk .{ .value = value, .changed = false };
        },
        else => .{ .value = value, .changed = false },
    };
}

fn objectStorage(allocator: std.mem.Allocator, count: usize) !std.json.ObjectMap {
    var result: std.json.ObjectMap = .empty;
    try result.entries.setCapacity(allocator, count);
    try result.entries.resize(allocator, count);
    return result;
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
