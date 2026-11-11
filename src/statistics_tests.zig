const std = @import("std");
const query = @import("root.zig");
const statistics = @import("statistics.zig");
const number = @import("number.zig");
const t = std.testing;

fn expectOutput(source: []const u8, input: []const u8, expected: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try program.run(t.allocator, input, &output.writer, &diagnostic);
    try t.expectEqualStrings(expected, output.written());
}

fn expectFailure(source: []const u8, input: []const u8, message: []const u8, path: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, input, &output.writer, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
    try t.expectEqualStrings(path, diagnostic.path.bytes[0..diagnostic.path.len]);
}

test "statistics division rounds exact halfway values to even for both signs" {
    try expectOutput("[divide(5,2,0),divide(7,2,0),divide(-5,2,0),divide(-7,2,0),divide(5,-2,0),divide(-7,-2,0)]", "null", "[2,4,-2,-4,-2,4]\n");
    try expectOutput("[divide(1,8,2),divide(3,8,2),divide(-1,8,2),divide(-3,8,2),divide(1999,200,2)]", "null", "[0.12,0.38,-0.12,-0.38,10.00]\n");
    try expectOutput("[divide(0.124999999999999999,1,2),divide(0.125000000000000001,1,2)]", "null", "[0.12,0.13]\n");
}

test "statistics division retains requested fractional digits normalizes zero and handles exponents" {
    try expectOutput("[divide(1,3,6),divide(2,3,6),divide(1,3,18),divide(-1,1000,2),divide(-0.00,1,3),divide(0e999999999999999999999,1,2)]", "null", "[0.333333,0.666667,0.333333333333333333,0.00,0.000,0.00]\n");
    try expectOutput("[divide(1.25e1,2.5,3),divide(1e-18,1,18),divide(1,1e-18,0)]", "null", "[5.000,0.000000000000000001,1000000000000000000]\n");
    try expectOutput("divide(.ns,1000000,6)", "{\"ns\":9007199254740993}", "9007199254.740993\n");
}

test "statistics means align decimals sum exactly and use the same rounding contract" {
    try expectOutput("[mean([1,2],3),mean([0.1,0.2],18),mean([1,2,2],2),mean([2,3],0),mean([3,4],0),mean([-2,-3],0),mean([-3,-4],0),mean([],6)]", "null", "[1.500,0.150000000000000000,1.67,2,4,-2,-4,null]\n");
    try expectOutput("[mean([1e-18,0],18),mean([1e-18,2e-18],18)]", "null", "[0.000000000000000000,0.000000000000000002]\n");
    try expectOutput("mean([9007199254740993,9007199254740995],0)", "null", "9007199254740994\n");
    try expectOutput("mean([170141183460469231731687303715884105727,170141183460469231731687303715884105727],0)", "null", "170141183460469231731687303715884105727\n");
    try expectOutput("mean([-170141183460469231731687303715884105728,-170141183460469231731687303715884105728],0)", "null", "-170141183460469231731687303715884105728\n");
    try expectOutput("mean([-170141183460469231731687303715884105728,170141183460469231731687303715884105727],1)", "null", "-0.5\n");
}

test "statistics bounded decimals normalize insignificant zeros before range checks" {
    try expectOutput("divide(1000000000000000000000000000000000000000e-1,1,0)", "null", "100000000000000000000000000000000000000\n");
    try expectOutput("divide(0.100000000000000000000000000000000000000,1,2)", "null", "0.10\n");
    try expectOutput("divide(-170141183460469231731687303715884105728,1,0)", "null", "-170141183460469231731687303715884105728\n");
    try expectFailure("divide(-170141183460469231731687303715884105728,-1,0)", "null", "out of range", "");
    try expectFailure("divide(170141183460469231731687303715884105728,1,0)", "null", "out of range", "");
    try expectFailure("divide(1e-19,1,6)", "null", "out of range", "");
    try expectFailure("divide(1e39,1,6)", "null", "out of range", "");
    try expectFailure("mean([170141183460469231731687303715884105727],1)", "null", "out of range", "");
}

test "statistics errors identify operands or source array items without coercion" {
    try expectFailure("mean(.samples,6)", "{\"samples\":[1,null]}", "array of numbers", "$[\"samples\"][1]");
    try expectFailure("mean(.samples,6)", "{\"samples\":[1,1e-19]}", "out of range", "$[\"samples\"][1]");
    try expectFailure("mean(.samples[:],6)", "{\"samples\":[false]}", "array of numbers", "");
    try expectFailure("mean(.samples?,6)", "{}", "missing value", "$[\"samples\"]");
    try expectFailure("mean(.samples,6)", "{\"samples\":false}", "array of numbers", "$[\"samples\"]");
    try expectFailure("divide(.a,.b,6)", "{\"a\":null,\"b\":1}", "numeric operands", "$[\"a\"]");
    try expectFailure("divide(.a,.b,6)", "{\"a\":1,\"b\":\"2\"}", "numeric operands", "$[\"b\"]");
    try expectFailure("divide(.a,.b,6)", "{\"a\":1e-19,\"b\":1}", "out of range", "$[\"a\"]");
    try expectFailure("divide(.a,.b,6)", "{\"a\":1,\"b\":0}", "division by zero", "$[\"b\"]");
    try expectFailure("divide(.a?,.b,6)", "{\"b\":1}", "missing value", "$[\"a\"]");
}

test "statistics compose with mapping external values comparisons and exact integer operators" {
    try expectOutput("{mean_ms: mean(map(.samples, divide(.,1000000,6)),6), samples: length(.samples)}", "{\"samples\":[1000001,2000002,3000003]}", "{\"mean_ms\":2.000002,\"samples\":3}\n");
    try expectOutput("mean(map(.samples, divide(.,1000000,6)),6)", "{\"samples\":[]}", "null\n");
    try expectOutput("[divide(6,3,3)+1,divide(1,2,3) == 0.5]", "null", "[3,true]\n");
    try expectFailure("mean([1,2],1)+1", "null", "fractional", "");
    try expectFailure("1/2", "null", "must be exact", "");
}

test "statistics precision is a required constant integer from zero through eighteen" {
    for ([_][]const u8{ "mean(.)", "mean(.,-1)", "mean(.,19)", "mean(.,1.0)", "mean(.,1e0)", "mean(.,00)", "mean(.,$places)", "mean(.,6,7)", "divide(1,2)", "divide(1,2,256)", "divide(1,2,1+1)", "divide(1,2,6,7)" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

// Independent bounded reference: examine candidate scaled integers and choose
// the closest rational value, with even ties. No quotient/remainder algorithm.
fn nearestBySearch(numerator: i64, denominator: i64) i64 {
    var best: i64 = 0;
    var distance: u64 = @abs(numerator);
    var candidate: i64 = -1250;
    while (candidate <= 1250) : (candidate += 1) {
        const delta: u64 = @abs(candidate * denominator - numerator);
        if (delta < distance or (delta == distance and @rem(candidate, 2) == 0)) {
            best = candidate;
            distance = delta;
        }
    }
    return best;
}

test "statistics generated division agrees with independent nearest-value search" {
    for (0..3) |precision| {
        var scale: i64 = 1;
        for (0..precision) |_| scale *= 10;
        for (0..25) |n| for (1..8) |d| for ([_]i64{ -1, 1 }) |sign| {
            const numerator: i64 = @as(i64, @intCast(n)) - 12;
            const denominator: i64 = @as(i64, @intCast(d)) * sign;
            const expected = nearestBySearch(numerator * scale, denominator);
            var n_buffer: [32]u8 = undefined;
            var d_buffer: [32]u8 = undefined;
            const a = try statistics.decimal(try std.fmt.bufPrint(&n_buffer, "{d}", .{numerator}));
            const b = try statistics.decimal(try std.fmt.bufPrint(&d_buffer, "{d}", .{denominator}));
            const actual = try statistics.divide(t.allocator, a, b, @intCast(precision));
            defer t.allocator.free(actual);
            var expected_buffer: [64]u8 = undefined;
            const token = try std.fmt.bufPrint(&expected_buffer, "{d}e-{d}", .{ expected, precision });
            try t.expectEqual(std.math.Order.eq, try number.compare(actual, token));
        };
    }
}

test "statistics generated means agree with independent nearest-value search" {
    for (0..5) |a| for (0..5) |b| for (0..5) |c| {
        var mean: statistics.Mean = .{};
        var sum: i64 = 0;
        for ([_]usize{ a, b, c }) |value| {
            const signed: i64 = @as(i64, @intCast(value)) - 2;
            sum += signed;
            var buffer: [32]u8 = undefined;
            try mean.add(try std.fmt.bufPrint(&buffer, "{d}", .{signed}));
        }
        const expected = nearestBySearch(sum * 100, 3);
        const actual = try mean.finish(t.allocator, 2);
        defer t.allocator.free(actual);
        var expected_buffer: [64]u8 = undefined;
        const token = try std.fmt.bufPrint(&expected_buffer, "{d}e-2", .{expected});
        try t.expectEqual(std.math.Order.eq, try number.compare(actual, token));
    };
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(allocator, "{mean: mean(map(.samples, divide(.,1000000,6)),6), ratio: divide($n,$d,18)} | collect", &.{
        .{ .name = "n", .value = .{ .json = "1" } },
        .{ .name = "d", .value = .{ .json = "3" } },
    }, &diagnostic);
    defer program.deinit();
    var bytes: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    try program.run(allocator, "{\"samples\":[1000000,3000000]}", &output, &diagnostic);
    try t.expectEqualStrings("[{\"mean\":2.000000,\"ratio\":0.333333333333333333}]\n", output.buffered());
}

test "statistics allocation failures release decimal tokens bindings and retained results" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try allocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, allocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
