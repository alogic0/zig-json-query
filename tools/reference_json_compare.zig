//! Frozen validated comparator from jqz 0.22.0 (9a5c90b). Number semantics are
//! unchanged; retain rank mapping/call boundaries when production comparison moves.
const std = @import("std");
const number = @import("profile_engine").Number;
const Value = std.json.Value;

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
