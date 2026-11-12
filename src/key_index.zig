//! Owned string-keyed records. ObjectMap maintains its reusable hash index.
const std = @import("std");
const Buffered = @import("buffered.zig");
const Self = @This();
arena: std.heap.ArenaAllocator,
entries: std.json.ObjectMap = .empty,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

/// Caller rejects duplicates and depth/type errors before retaining anything.
pub fn append(self: *Self, key: []const u8, value: std.json.Value) error{OutOfMemory}!void {
    std.debug.assert(!self.entries.contains(key));
    const a = self.arena.allocator();
    try self.entries.put(a, try a.dupe(u8, key), try Buffered.clone(a, value));
}
