//! Shared ordering and group construction over validated keys. Rows and children
//! are borrowed; the caller chooses the lifetime and allocator for group arrays.
const std = @import("std");
const number = @import("number.zig");
const json_order = @import("json_order.zig");
const Value = std.json.Value;

pub const Row = struct { value: Value, key: Value };

pub fn sort(rows: []Row) void {
    // Stable, in-place, and infallible after key validation.
    std.sort.block(Row, rows, {}, less);
}

pub fn sortStructural(rows: []Row) void {
    std.sort.block(Row, rows, {}, struct {
        fn less(_: void, a: Row, b: Row) bool {
            return json_order.compare(a.key, b.key) == .lt;
        }
    }.less);
}

fn less(_: void, a: Row, b: Row) bool {
    return if (a.key == .number_string)
        (number.compare(a.key.number_string, b.key.number_string) catch unreachable) == .lt
    else
        std.mem.order(u8, a.key.string, b.key.string) == .lt;
}

/// Compare before changing scratch so callers can distinguish comparison errors
/// from allocator or retention-budget failures.
pub fn group(allocator: std.mem.Allocator, rows: []const Row, visited: []bool, start: usize, evaluator: anytype, offset: usize) error{ EvaluationFailed, OutOfMemory }!Value {
    var values = std.json.Array.init(allocator);
    for (rows[start..], start..) |row, index| {
        if (visited[index]) continue;
        if (try evaluator.equal(rows[start].key, row.key, offset, 0)) {
            visited[index] = true;
            try values.append(row.value);
        }
    }
    return .{ .array = values };
}
