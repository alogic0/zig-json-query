//! Bounded decimal statistics. Input tokens must already be valid JSON numbers.
//! Normalized coefficients fit i128 and scales fit 0..18. Wide intermediates
//! remain below 512 bits even for usize-max array counts; no floating point.
const std = @import("std");
const number = @import("number.zig");
const A = std.mem.Allocator;
pub const Error = error{ DecimalRange, DivisionByZero, InvalidPrecision };
pub const ResultError = Error || error{OutOfMemory};
pub const Fixed = struct { coefficient: i128, scale: u8 };

pub fn decimal(token: []const u8) Error!Fixed {
    const parsed = number.Decimal.parse(token) catch return error.DecimalRange;
    if (parsed.digits.len == 0) return .{ .coefficient = 0, .scale = 0 };
    var digits: usize = 0;
    var significant: usize = 0;
    for (parsed.digits) |digit| {
        if (digit == '.') continue;
        digits += 1;
        if (digit != '0') significant = digits;
    }
    if (significant > 39) return error.DecimalRange;
    const exponent = @as(i128, parsed.magnitude) - @as(i128, @intCast(significant));
    if (exponent < -18 or exponent > 38) return error.DecimalRange;
    var coefficient: i512 = 0;
    var position: usize = 0;
    for (parsed.digits) |digit| {
        if (digit == '.') continue;
        if (position == significant) break;
        coefficient = coefficient * 10 + (digit - '0');
        position += 1;
    }
    if (exponent > 0) coefficient *= power(@intCast(exponent));
    if (parsed.negative) coefficient = -coefficient;
    return .{
        .coefficient = std.math.cast(i128, coefficient) orelse return error.DecimalRange,
        .scale = if (exponent < 0) @intCast(-exponent) else 0,
    };
}

fn power(exponent: usize) i512 {
    std.debug.assert(exponent <= 38);
    var result: i512 = 1;
    for (0..exponent) |_| result *= 10;
    return result;
}

pub fn divide(allocator: A, a: Fixed, b: Fixed, places: u8) ResultError![]u8 {
    if (places > 18) return error.InvalidPrecision;
    return rounded(allocator, @as(i512, a.coefficient) * power(@as(usize, b.scale) + places), @as(i512, b.coefficient) * power(a.scale), places);
}

pub const Mean = struct {
    total: i512 = 0,
    count: usize = 0,

    pub fn add(self: *Mean, token: []const u8) Error!void {
        const value = try decimal(token);
        const count = std.math.add(usize, self.count, 1) catch return error.DecimalRange;
        // At most 187 bits per aligned value and 64 bits of native counts.
        self.total += @as(i512, value.coefficient) * power(18 - value.scale);
        self.count = count;
    }

    /// Caller handles the empty-array result (JSON null) before finishing.
    pub fn finish(self: Mean, allocator: A, places: u8) ResultError![]u8 {
        if (places > 18) return error.InvalidPrecision;
        std.debug.assert(self.count != 0);
        return rounded(allocator, self.total * power(places), @as(i512, @intCast(self.count)) * power(18), places);
    }
};

fn rounded(allocator: A, numerator: i512, denominator: i512, places: u8) ResultError![]u8 {
    if (denominator == 0) return error.DivisionByZero;
    const negative = (numerator < 0) != (denominator < 0);
    const n: u512 = @abs(numerator);
    const d: u512 = @abs(denominator);
    var quotient = @divTrunc(n, d);
    const remainder = @rem(n, d);
    if (remainder * 2 > d or (remainder * 2 == d and quotient % 2 != 0)) quotient += 1;
    const minimum_magnitude: u512 = @as(u512, 1) << 127;
    const limit = if (negative) minimum_magnitude else minimum_magnitude - 1;
    if (quotient > limit) return error.DecimalRange;
    const coefficient: i128 = if (negative and quotient == minimum_magnitude)
        std.math.minInt(i128)
    else if (negative)
        -@as(i128, @intCast(quotient))
    else
        @intCast(quotient);
    return render(allocator, coefficient, places);
}

fn render(allocator: A, coefficient: i128, places: u8) error{OutOfMemory}![]u8 {
    const magnitude: u128 = @abs(coefficient);
    const factor: u128 = @intCast(power(places));
    var buffer: [80]u8 = undefined;
    var len: usize = 0;
    if (coefficient < 0) {
        buffer[0] = '-';
        len = 1;
    }
    const integer = std.fmt.bufPrint(buffer[len..], "{d}", .{magnitude / factor}) catch unreachable;
    len += integer.len;
    if (places != 0) {
        buffer[len] = '.';
        len += 1;
        var fraction = magnitude % factor;
        var index: usize = places;
        while (index != 0) {
            index -= 1;
            buffer[len + index] = '0' + @as(u8, @intCast(fraction % 10));
            fraction /= 10;
        }
        len += places;
    }
    return allocator.dupe(u8, buffer[0..len]);
}
