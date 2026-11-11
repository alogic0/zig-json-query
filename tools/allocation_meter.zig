//! Counts successful allocator requests, not RSS or backing allocator metadata.
const std = @import("std");
const A = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Self = @This();

pub const Counters = struct {
    allocations: u64 = 0,
    allocation_failures: u64 = 0,
    resize_attempts: u64 = 0,
    remap_attempts: u64 = 0,
    frees: u64 = 0,
    requested_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
};
pub const Delta = struct {
    allocations: u64,
    allocation_failures: u64,
    resize_attempts: u64,
    remap_attempts: u64,
    frees: u64,
    requested_bytes: u64,
    start_live_bytes: u64,
    end_live_bytes: u64,
    peak_live_bytes: u64,
};
backing: A,
counters: Counters = .{},

pub fn allocator(self: *Self) A {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

pub fn begin(self: *Self) Counters {
    self.counters.peak_live_bytes = self.counters.live_bytes;
    return self.counters;
}

pub fn end(self: *const Self, before: Counters) Delta {
    return .{
        .allocations = self.counters.allocations - before.allocations,
        .allocation_failures = self.counters.allocation_failures - before.allocation_failures,
        .resize_attempts = self.counters.resize_attempts - before.resize_attempts,
        .remap_attempts = self.counters.remap_attempts - before.remap_attempts,
        .frees = self.counters.frees - before.frees,
        .requested_bytes = self.counters.requested_bytes - before.requested_bytes,
        .start_live_bytes = before.live_bytes,
        .end_live_bytes = self.counters.live_bytes,
        .peak_live_bytes = self.counters.peak_live_bytes,
    };
}

fn changed(self: *Self, old_len: usize, new_len: usize) void {
    self.counters.live_bytes = self.counters.live_bytes - old_len + new_len;
    self.counters.requested_bytes += new_len -| old_len;
    self.counters.peak_live_bytes = @max(self.counters.peak_live_bytes, self.counters.live_bytes);
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, address: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    const memory = self.backing.rawAlloc(len, alignment, address) orelse {
        self.counters.allocation_failures += 1;
        return null;
    };
    self.counters.allocations += 1;
    self.changed(0, len);
    return memory;
}

fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, address: usize) bool {
    const self: *Self = @ptrCast(@alignCast(context));
    self.counters.resize_attempts += 1;
    if (!self.backing.rawResize(memory, alignment, new_len, address)) return false;
    self.changed(memory.len, new_len);
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, address: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(context));
    self.counters.remap_attempts += 1;
    const next = self.backing.rawRemap(memory, alignment, new_len, address) orelse return null;
    self.changed(memory.len, new_len);
    return next;
}

fn free(context: *anyopaque, memory: []u8, alignment: Alignment, address: usize) void {
    const self: *Self = @ptrCast(@alignCast(context));
    self.backing.rawFree(memory, alignment, address);
    self.counters.frees += 1;
    self.changed(memory.len, 0);
}

test "profile meter counts allocation growth shrink remap free and phase baselines" {
    const t = std.testing;
    var buffer: [256]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&buffer);
    var meter: Self = .{ .backing = backing.allocator() };
    const a = meter.allocator();
    const initial = meter.begin();
    var memory = try a.alloc(u8, 8);
    try t.expect(a.resize(memory, 16));
    memory = memory.ptr[0..16];
    if (a.remap(memory, 32)) |next| memory = next;
    const peak = memory.len;
    try t.expect(a.resize(memory, 4));
    memory = memory.ptr[0..4];
    const first = meter.end(initial);
    try t.expectEqual(@as(u64, 1), first.allocations);
    try t.expectEqual(@as(u64, 2), first.resize_attempts);
    try t.expectEqual(@as(u64, 1), first.remap_attempts);
    try t.expectEqual(peak, first.requested_bytes);
    try t.expectEqual(peak, first.peak_live_bytes);
    try t.expectEqual(@as(u64, 4), first.end_live_bytes);
    const cleanup = meter.begin();
    a.free(memory);
    const last = meter.end(cleanup);
    try t.expectEqual(@as(u64, 4), last.start_live_bytes);
    try t.expectEqual(@as(u64, 0), last.end_live_bytes);
    try t.expectEqual(@as(u64, 1), last.frees);
    try t.expectEqual(@as(u64, 4), last.peak_live_bytes);
}

test "profile meter failed allocation and growth do not charge live requests" {
    const t = std.testing;
    var buffer: [16]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&buffer);
    var meter: Self = .{ .backing = backing.allocator() };
    const a = meter.allocator();
    const memory = try a.alloc(u8, 8);
    try t.expectError(error.OutOfMemory, a.alloc(u8, 100));
    try t.expect(!a.resize(memory, 100));
    try t.expectEqual(@as(?[]u8, null), a.remap(memory, 100));
    try t.expectEqual(@as(u64, 1), meter.counters.allocation_failures);
    try t.expectEqual(@as(u64, 8), meter.counters.live_bytes);
    try t.expectEqual(@as(u64, 8), meter.counters.requested_bytes);
    a.free(memory);
    try t.expectEqual(@as(u64, 0), meter.counters.live_bytes);
}
