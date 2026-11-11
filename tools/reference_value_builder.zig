//! Frozen jqz 0.22.0 builder from 9a5c90b, before construction observations.
//! Complete-input DOM construction over Zig's validating JSON Scanner. Plain
//! token text borrows input; decoded escapes and containers use the parsed arena.
//! Input must outlive the Parsed value, as it does during synchronous feeds.
const std = @import("std");
const A = std.mem.Allocator;
const Scanner = std.json.Scanner;
const Error = std.json.ParseError(Scanner);

value: std.json.Value,

pub fn jsonParse(a: A, source: *Scanner, options: std.json.ParseOptions) Error!@This() {
    std.debug.assert(source.is_end_of_input);
    std.debug.assert(!options.parse_numbers and options.duplicate_field_behavior == .@"error");
    // A bounded initial region avoids many tiny arena growth attempts on large
    // documents. Free the reservation immediately so DOM storage can reuse it.
    if (options.max_value_len.? >= 64 * 1024) {
        const reservation = try a.alloc(u8, 16 * 1024);
        a.free(reservation);
    }
    return .{ .value = try read(a, source, options.max_value_len.?, try source.nextAllocMax(a, .alloc_if_needed, options.max_value_len.?)) };
}

fn read(a: A, source: *Scanner, max: usize, token: std.json.Token) Error!std.json.Value {
    return switch (token) {
        .null => .null,
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .string, .allocated_string => |text| .{ .string = text },
        .number, .allocated_number => |text| .{ .number_string = text },
        .array_begin => blk: {
            var array = std.json.Array.init(a);
            while (true) {
                const next = try source.nextAllocMax(a, .alloc_if_needed, max);
                if (next == .array_end) break;
                try array.append(try read(a, source, max, next));
            }
            break :blk .{ .array = array };
        },
        .object_begin => try readObject(a, source, max),
        else => error.UnexpectedToken,
    };
}

fn readObject(a: A, source: *Scanner, max: usize) Error!std.json.Value {
    // Most report objects are small. Buffer a few fields on the stack and
    // allocate their final map once, avoiding successive arena-backed growth.
    const Field = struct { key: []const u8, value: std.json.Value };
    var small: [4]Field = undefined;
    var count: usize = 0;
    var object: std.json.ObjectMap = .empty;
    var large = false;
    while (true) {
        const next = try source.nextAllocMax(a, .alloc_if_needed, max);
        const key = switch (next) {
            .object_end => break,
            .string, .allocated_string => |text| text,
            else => return error.UnexpectedToken,
        };
        const item = try read(a, source, max, try source.nextAllocMax(a, .alloc_if_needed, max));
        // Finish the value before duplicate detection to preserve diagnostics.
        if (!large) {
            for (small[0..count]) |*field| if (std.mem.eql(u8, field.key, key)) return error.DuplicateField;
            if (count < small.len) {
                small[count] = .{ .key = key, .value = item };
                count += 1;
                continue;
            }
            try object.ensureTotalCapacity(a, count + 1);
            for (small[0..count]) |*field| object.putAssumeCapacityNoClobber(field.key, field.value);
            large = true;
        }
        const entry = try object.getOrPut(a, key);
        if (entry.found_existing) return error.DuplicateField;
        entry.value_ptr.* = item;
    }
    if (!large and count != 0) {
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
