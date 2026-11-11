//! Exact decimal comparison without conversion through floating point.
//! Inputs must be valid JSON number tokens. Exponents must fit i64, including
//! the adjusted digit position. Passthrough serialization has no such bound.
const std = @import("std");
const Order = std.math.Order;

pub const Decimal = struct {
    negative: bool,
    digits: []const u8,
    magnitude: i64,

    pub fn parse(token: []const u8) error{NumericRange}!Decimal {
        const negative = token[0] == '-';
        const unsigned = token[@intFromBool(negative)..];
        const end = std.mem.indexOfAny(u8, unsigned, "eE") orelse unsigned.len;
        const mantissa = unsigned[0..end];
        var first: ?usize = null;
        var position: i64 = 0;
        var first_position: i64 = 0;
        var decimal_position: ?i64 = null;
        for (mantissa, 0..) |byte, index| {
            if (byte == '.') {
                decimal_position = position;
            } else {
                if (first == null and byte != '0') {
                    first = index;
                    first_position = position;
                }
                position += 1;
            }
        }
        // All representations of zero are equal, regardless of exponent.
        const first_index = first orelse return .{ .negative = false, .digits = "", .magnitude = 0 };
        const exponent = if (end < unsigned.len)
            std.fmt.parseInt(i64, unsigned[end + 1 ..], 10) catch return error.NumericRange
        else
            0;
        const magnitude = std.math.add(i64, exponent, (decimal_position orelse position) - first_position) catch return error.NumericRange;
        return .{ .negative = negative, .digits = mantissa[first_index..], .magnitude = magnitude };
    }
};

fn nextDigit(bytes: []const u8, index: *usize) ?u8 {
    while (index.* < bytes.len) {
        const byte = bytes[index.*];
        index.* += 1;
        if (byte != '.') return byte;
    }
    return null;
}

pub fn compare(lhs: []const u8, rhs: []const u8) error{NumericRange}!Order {
    const a = try Decimal.parse(lhs);
    const b = try Decimal.parse(rhs);
    if (a.digits.len == 0 and b.digits.len == 0) return .eq;
    if (a.negative != b.negative) return if (a.negative) .lt else .gt;
    const order: Order = order: {
        if (a.digits.len == 0) break :order .lt;
        if (b.digits.len == 0) break :order .gt;
        if (a.magnitude != b.magnitude) break :order std.math.order(a.magnitude, b.magnitude);
        var ai: usize = 0;
        var bi: usize = 0;
        while (true) {
            const ad = nextDigit(a.digits, &ai);
            const bd = nextDigit(b.digits, &bi);
            if (ad == null and bd == null) break :order .eq;
            const digit_order = std.math.order(ad orelse '0', bd orelse '0');
            if (digit_order != .eq) break :order digit_order;
        }
    };
    return if (a.negative) switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    } else order;
}

pub const IntegerError = error{ IntegerRange, FractionalNumber, DivisionByZero, InexactDivision };
pub const Arithmetic = enum { add, subtract, multiply, divide, remainder };

/// Convert a valid JSON token only when its mathematical value is an i128.
/// Decimal spellings are normalized without passing through floating point.
pub fn integer(token: []const u8) IntegerError!i128 {
    const decimal = Decimal.parse(token) catch return error.IntegerRange;
    if (decimal.digits.len == 0) return 0;
    if (decimal.magnitude <= 0) return error.FractionalNumber;
    if (decimal.magnitude > 39) return error.IntegerRange;
    var position: i64 = 0;
    for (decimal.digits) |digit| {
        if (digit == '.') continue;
        if (position >= decimal.magnitude and digit != '0') return error.FractionalNumber;
        position += 1;
    }
    var index: usize = 0;
    var unsigned: u128 = 0;
    for (0..@intCast(decimal.magnitude)) |_| {
        const digit = (nextDigit(decimal.digits, &index) orelse '0') - '0';
        unsigned = std.math.mul(u128, unsigned, 10) catch return error.IntegerRange;
        unsigned = std.math.add(u128, unsigned, digit) catch return error.IntegerRange;
    }
    const minimum_magnitude: u128 = @as(u128, 1) << 127;
    if (decimal.negative and unsigned == minimum_magnitude) return std.math.minInt(i128);
    if (unsigned >= minimum_magnitude) return error.IntegerRange;
    const signed: i128 = @intCast(unsigned);
    return if (decimal.negative) -signed else signed;
}

pub fn arithmetic(op: Arithmetic, a: i128, b: i128) IntegerError!i128 {
    return switch (op) {
        .add => std.math.add(i128, a, b) catch error.IntegerRange,
        .subtract => std.math.sub(i128, a, b) catch error.IntegerRange,
        .multiply => std.math.mul(i128, a, b) catch error.IntegerRange,
        .divide, .remainder => blk: {
            if (b == 0) return error.DivisionByZero;
            if (a == std.math.minInt(i128) and b == -1) {
                if (op == .remainder) break :blk 0;
                return error.IntegerRange;
            }
            const remainder = @rem(a, b);
            if (op == .remainder) break :blk remainder;
            if (remainder != 0) return error.InexactDivision;
            break :blk @divTrunc(a, b);
        },
    };
}

test "decimal comparison retains large integers and normalizes spelling" {
    const cases = .{
        .{ "9007199254740993", "9007199254740992", Order.gt },
        .{ "1", "1.000e0", Order.eq },
        .{ "1000", "1e3", Order.eq },
        .{ "0.001", "1e-3", Order.eq },
        .{ "-0", "0e999999999999999999999", Order.eq },
        .{ "-1.5", "-1.49", Order.lt },
        .{ "-1e1000", "-1e999", Order.lt },
        .{ "0", "1e-1000", Order.lt },
        .{ "-1e-1000", "0", Order.lt },
        .{ "1.001", "1.01", Order.lt },
        .{ "12.30", "1.23e+1", Order.eq },
    };
    inline for (cases) |case| try std.testing.expectEqual(case[2], try compare(case[0], case[1]));
    try std.testing.expectError(error.NumericRange, compare("1e999999999999999999999", "1"));
}
