//! Complete-input DOM construction over Zig's validating JSON Scanner. Plain
//! token text borrows input; decoded escapes and containers use the parsed arena.
//! Input must outlive the Parsed value, as it does during synchronous feeds.
const std = @import("std");
const A = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Error = std.json.ParseError(Scanner);

pub const Event = enum { token, arena_seed, array_growth, array_append, duplicate_check, object_insert, object_finish };

/// Carries the caller allocator through the standard Parsed arena owner without
/// recovering it from Scanner internals or changing token allocation identity.
pub const Source = struct {
    scanner: *Scanner,
    temporary: A,
    pub const NextError = Scanner.NextError;
    pub const PeekError = Scanner.PeekError;
    pub const AllocError = Scanner.AllocError;

    pub inline fn next(self: *Source) NextError!std.json.Token {
        return self.scanner.next();
    }
};

value: std.json.Value,

pub fn jsonParse(a: A, source: *Source, options: std.json.ParseOptions) Error!@This() {
    std.debug.assert(source.scanner.is_end_of_input);
    std.debug.assert(!options.parse_numbers and options.duplicate_field_behavior == .@"error");
    return .{ .value = try build(a, source.temporary, source.scanner, options.max_value_len.?, {}) };
}

/// Internal observation points compile away when observer is void. Observers
/// belong to profiling only; children are parsed outside container intervals.
pub fn build(a: A, temporary: A, source: *Scanner, max: usize, observer: anytype) Error!std.json.Value {
    // A bounded initial region avoids many tiny arena growth attempts on large
    // documents. Free the reservation immediately so DOM storage can reuse it.
    if (max >= 64 * 1024) {
        const stamp = begin(observer, .arena_seed);
        defer end(observer, .arena_seed, stamp);
        const reservation = try a.alloc(u8, 16 * 1024);
        a.free(reservation);
    }
    return read(a, temporary, source, max, try next(a, source, max, observer), observer);
}

inline fn begin(observer: anytype, event: Event) @TypeOf(if (@TypeOf(observer) == void) {} else observer.begin(event)) {
    if (@TypeOf(observer) == void) return;
    return observer.begin(event);
}

inline fn end(observer: anytype, event: Event, stamp: anytype) void {
    if (@TypeOf(observer) != void) observer.end(event, stamp);
}

inline fn next(a: A, source: *Scanner, max: usize, observer: anytype) Error!std.json.Token {
    const stamp = begin(observer, .token);
    defer end(observer, .token, stamp);
    return source.nextAllocMax(a, .alloc_if_needed, max);
}

fn read(a: A, temporary: A, source: *Scanner, max: usize, token: std.json.Token, observer: anytype) Error!std.json.Value {
    return switch (token) {
        .null => .null,
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .string, .allocated_string => |text| .{ .string = text },
        .number, .allocated_number => |text| .{ .number_string = text },
        .array_begin => .{ .array = try readArray(a, temporary, source, max, observer) },
        .object_begin => try readObject(a, temporary, source, max, observer),
        else => error.UnexpectedToken,
    };
}

// Array growth interleaved with allocating children strands old arena buffers.
// A small stack prefix needs one exact allocation. For larger arrays, allocating
// prefixes select bounded temporary chunks; scalar prefixes keep ordinary arena
// growth so flat scalar arrays do not pay for an unnecessary final duplicate.
const ArrayBuilder = struct {
    const Chunk = struct { items: []std.json.Value, used: usize = 0, next: ?*Chunk = null };
    small: [16]std.json.Value = undefined,
    count: usize = 0,
    allocating_prefix: bool = false,
    flat: ?std.json.Array = null,
    first: ?*Chunk = null,
    last: ?*Chunk = null,

    fn grows(self: *const ArrayBuilder) bool {
        if (self.count < self.small.len) return false;
        if (self.flat) |flat| return flat.items.len == flat.capacity;
        return self.last == null or self.last.?.used == self.last.?.items.len;
    }

    inline fn append(self: *ArrayBuilder, a: A, temporary: A, item: std.json.Value, allocating: bool) !void {
        if (self.count <= self.small.len) self.allocating_prefix = self.allocating_prefix or allocating;
        if (self.count < self.small.len) {
            self.small[self.count] = item;
        } else {
            if (self.count == self.small.len and !self.allocating_prefix) {
                self.flat = std.json.Array.init(a);
                try self.flat.?.appendSlice(&self.small);
            }
            if (self.flat) |*flat| {
                try flat.append(item);
            } else {
                if (self.last == null or self.last.?.used == self.last.?.items.len) {
                    const capacity: usize = if (self.last) |last| @min(last.items.len * 2, 1024) else 16;
                    const chunk = try temporary.create(Chunk);
                    errdefer temporary.destroy(chunk);
                    chunk.* = .{ .items = try temporary.alloc(std.json.Value, capacity) };
                    if (self.last) |last| last.next = chunk else self.first = chunk;
                    self.last = chunk;
                }
                const last = self.last.?;
                last.items[last.used] = item;
                last.used += 1;
            }
        }
        self.count += 1;
    }

    fn finish(self: *const ArrayBuilder, a: A) !std.json.Array {
        if (self.flat) |flat| return flat;
        if (self.count == 0) return std.json.Array.init(a);
        const items = try a.alloc(std.json.Value, self.count);
        var offset: usize = @min(self.count, self.small.len);
        @memcpy(items[0..offset], self.small[0..offset]);
        var chunk = self.first;
        while (chunk) |part| : (chunk = part.next) {
            @memcpy(items[offset..][0..part.used], part.items[0..part.used]);
            offset += part.used;
        }
        std.debug.assert(offset == items.len);
        return std.json.Array.fromOwnedSlice(a, items);
    }

    fn deinit(self: *ArrayBuilder, temporary: A) void {
        var chunk = self.first;
        while (chunk) |part| {
            chunk = part.next;
            temporary.free(part.items);
            temporary.destroy(part);
        }
    }
};

fn readArray(a: A, temporary: A, source: *Scanner, max: usize, observer: anytype) Error!std.json.Array {
    var array: ArrayBuilder = .{};
    defer if (array.first != null) array.deinit(temporary);
    while (true) {
        const token = try next(a, source, max, observer);
        if (token == .array_end) {
            if (array.count == 0) return std.json.Array.init(a);
            break;
        }
        const item = try read(a, temporary, source, max, token, observer);
        const event: Event = if (@TypeOf(observer) == void) .array_append else if (array.grows()) .array_growth else .array_append;
        const stamp = begin(observer, event);
        defer end(observer, event, stamp);
        try array.append(a, temporary, item, switch (token) {
            .array_begin => item.array.items.len != 0,
            .object_begin => item.object.count() != 0,
            .allocated_string, .allocated_number => true,
            else => false,
        });
    }
    const stamp = begin(observer, .array_growth);
    defer end(observer, .array_growth, stamp);
    return array.finish(a);
}

fn readObject(a: A, temporary: A, source: *Scanner, max: usize, observer: anytype) Error!std.json.Value {
    // Most report objects are small. Buffer a few fields on the stack and
    // allocate their final map once, avoiding successive arena-backed growth.
    const Field = struct { key: []const u8, value: std.json.Value };
    var small: [4]Field = undefined;
    var count: usize = 0;
    var object: std.json.ObjectMap = .empty;
    var large = false;
    while (true) {
        const token_next = try next(a, source, max, observer);
        const key = switch (token_next) {
            .object_end => break,
            .string, .allocated_string => |text| text,
            else => return error.UnexpectedToken,
        };
        const item = try read(a, temporary, source, max, try next(a, source, max, observer), observer);
        // Finish the value before duplicate detection to preserve diagnostics.
        if (!large) {
            {
                const stamp = begin(observer, .duplicate_check);
                defer end(observer, .duplicate_check, stamp);
                for (small[0..count]) |*field| if (std.mem.eql(u8, field.key, key)) return error.DuplicateField;
            }
            if (count < small.len) {
                small[count] = .{ .key = key, .value = item };
                count += 1;
                continue;
            }
            {
                const stamp = begin(observer, .object_finish);
                defer end(observer, .object_finish, stamp);
                try object.ensureTotalCapacity(a, count + 1);
                for (small[0..count]) |*field| object.putAssumeCapacityNoClobber(field.key, field.value);
            }
            large = true;
        }
        const stamp = begin(observer, .object_insert);
        defer end(observer, .object_insert, stamp);
        const entry = try object.getOrPut(a, key);
        if (entry.found_existing) return error.DuplicateField;
        entry.value_ptr.* = item;
    }
    if (!large and count != 0) {
        const stamp = begin(observer, .object_finish);
        defer end(observer, .object_finish, stamp);
        // Public entry storage supports exact capacity. Rebuild any required
        // index through the map API before inserting the buffered fields.
        try object.entries.setCapacity(a, count);
        try object.entries.resize(a, count);
        const entries = object.entries.slice();
        for (small[0..count], 0..) |*field, index| {
            entries.items(.key)[index] = field.key;
            entries.items(.value)[index] = field.value;
        }
        try object.reIndex(a);
    }
    return .{ .object = object };
}
