//! Storage for query arrays whose final length is known before construction.
const std = @import("std");

pub inline fn init(allocator: std.mem.Allocator, count: usize) !std.json.Array {
    var array = std.json.Array.init(allocator);
    try array.ensureTotalCapacity(count);
    return array;
}
