//! Limit live allocator requests for retained collection data. This measures
//! requested capacity, not process RSS or the backing allocator's metadata.
const std = @import("std");
const A = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Self = @This();

backing: A,
limit: usize,
used: usize = 0,
denied: bool = false,

pub fn allocator(self: *Self) A {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, address: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (len > self.limit - self.used) {
        self.denied = true;
        return null;
    }
    const bytes = self.backing.rawAlloc(len, alignment, address) orelse return null;
    self.used += len;
    return bytes;
}

fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, address: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    if (new_len > memory.len and new_len - memory.len > self.limit - self.used) return false;
    if (!self.backing.rawResize(memory, alignment, new_len, address)) return false;
    self.used = self.used - memory.len + new_len;
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, address: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    if (new_len > memory.len and new_len - memory.len > self.limit - self.used) return null;
    const bytes = self.backing.rawRemap(memory, alignment, new_len, address) orelse return null;
    self.used = self.used - memory.len + new_len;
    return bytes;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, address: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.backing.rawFree(memory, alignment, address);
    self.used -= memory.len;
}
