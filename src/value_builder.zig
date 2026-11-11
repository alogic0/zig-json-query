//! Complete-input DOM construction over Zig's validating JSON Scanner. Plain
//! token text borrows input; decoded escapes and containers use the parsed arena.
//! Input must outlive the Parsed value, as it does during synchronous feeds.
const std = @import("std");
const A = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Error = std.json.ParseError(Scanner);

pub const Event = enum { token, arena_seed, array_growth, array_append, duplicate_check, object_insert, object_finish };

value: std.json.Value,

pub fn jsonParse(a: A, source: *Scanner, options: std.json.ParseOptions) Error!@This() {
    std.debug.assert(source.is_end_of_input);
    std.debug.assert(!options.parse_numbers and options.duplicate_field_behavior == .@"error");
    return .{ .value = try build(a, source, options.max_value_len.?, {}) };
}

/// Internal observation points compile away when observer is void. Observers
/// belong to profiling only; children are parsed outside container intervals.
pub fn build(a: A, source: *Scanner, max: usize, observer: anytype) Error!std.json.Value {
    // A bounded initial region avoids many tiny arena growth attempts on large
    // documents. Free the reservation immediately so DOM storage can reuse it.
    if (max >= 64 * 1024) {
        const stamp = begin(observer, .arena_seed);
        defer end(observer, .arena_seed, stamp);
        const reservation = try a.alloc(u8, 16 * 1024);
        a.free(reservation);
    }
    return read(a, source, max, try next(a, source, max, observer), observer);
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

fn read(a: A, source: *Scanner, max: usize, token: std.json.Token, observer: anytype) Error!std.json.Value {
    return switch (token) {
        .null => .null,
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .string, .allocated_string => |text| .{ .string = text },
        .number, .allocated_number => |text| .{ .number_string = text },
        .array_begin => blk: {
            var array = std.json.Array.init(a);
            while (true) {
                const token_next = try next(a, source, max, observer);
                if (token_next == .array_end) break;
                const item = try read(a, source, max, token_next, observer);
                const event: Event = if (@TypeOf(observer) == void) .array_append else if (array.items.len == array.capacity) .array_growth else .array_append;
                const stamp = begin(observer, event);
                defer end(observer, event, stamp);
                try array.append(item);
            }
            break :blk .{ .array = array };
        },
        .object_begin => try readObject(a, source, max, observer),
        else => error.UnexpectedToken,
    };
}

fn readObject(a: A, source: *Scanner, max: usize, observer: anytype) Error!std.json.Value {
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
        const item = try read(a, source, max, try next(a, source, max, observer), observer);
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
