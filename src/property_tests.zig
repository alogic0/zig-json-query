const std = @import("std");
const query = @import("root.zig");
const t = std.testing;
const Value = std.json.Value;

test "generated aggregate pipelines match an independent batch model" {
    var prng = std.Random.DefaultPrng.init(0x20261109);
    const random = prng.random();
    for (0..2500) |case_index| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var source = std.Io.Writer.Allocating.init(a);
        var model: std.ArrayList(Value) = .empty;
        const count = random.uintLessThan(usize, 9);
        for (0..count) |i| try model.append(a, .{ .integer = @intCast(i) });
        const stages = random.uintLessThan(usize, 12) + 1;
        for (0..stages) |stage| {
            if (stage != 0) try source.writer.writeAll(" | ");
            switch (random.uintLessThan(u8, 9)) {
                0 => try source.writer.writeAll("."),
                1 => {
                    try source.writer.writeAll("count");
                    const length = model.items.len;
                    model = .empty;
                    try model.append(a, .{ .integer = @intCast(length) });
                },
                2 => {
                    try source.writer.writeAll("collect");
                    var array = std.json.Array.init(a);
                    try array.appendSlice(model.items);
                    model = .empty;
                    try model.append(a, .{ .array = array });
                },
                3, 4, 5 => |choice| {
                    const limit: usize = choice - 3;
                    try source.writer.print("take({d})", .{limit});
                    model.shrinkRetainingCapacity(@min(limit, model.items.len));
                },
                6 => {
                    try source.writer.writeAll("where(false)");
                    model = .empty;
                },
                7 => {
                    try source.writer.writeAll("[.]");
                    var next: std.ArrayList(Value) = .empty;
                    for (model.items) |value| {
                        var array = std.json.Array.init(a);
                        try array.append(value);
                        try next.append(a, .{ .array = array });
                    }
                    model = next;
                },
                8 => {
                    var arrays = true;
                    for (model.items) |value| {
                        if (value != .array) arrays = false;
                    }
                    if (arrays) {
                        try source.writer.writeAll("each");
                        var next: std.ArrayList(Value) = .empty;
                        for (model.items) |value| try next.appendSlice(a, value.array.items);
                        model = next;
                    } else try source.writer.writeAll("where(true)");
                },
                else => unreachable,
            }
        }
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source.written(), &diagnostic);
        defer program.deinit();
        var actual = std.Io.Writer.Allocating.init(t.allocator);
        defer actual.deinit();
        var stream = try program.start(t.allocator, &actual.writer, &diagnostic, .{});
        defer stream.deinit();
        for (0..count) |i| {
            if (!stream.needsInput()) break;
            var buffer: [20]u8 = undefined;
            _ = try stream.feed(try std.fmt.bufPrint(&buffer, "{d}", .{i}));
        }
        try stream.finish();
        var expected = std.Io.Writer.Allocating.init(a);
        for (model.items) |value| {
            try std.json.Stringify.value(value, .{}, &expected.writer);
            try expected.writer.writeByte('\n');
        }
        if (!std.mem.eql(u8, expected.written(), actual.written())) {
            std.debug.print("case {d}, input count {d}, query {s}\n", .{ case_index, count, source.written() });
            try t.expectEqualStrings(expected.written(), actual.written());
        }
    }
}

test "generated decimal comparisons match exact scaled integer reference" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "[.a == .b, .a < .b, .a > .b]", &diagnostic);
    defer program.deinit();
    var prng = std.Random.DefaultPrng.init(0x123456789);
    const random = prng.random();
    for (0..2500) |_| {
        const a = random.int(i64);
        const b = random.int(i64);
        const ae: i32 = @as(i32, random.uintLessThan(u8, 19)) - 9;
        const be: i32 = @as(i32, random.uintLessThan(u8, 19)) - 9;
        const minimum = @min(ae, be);
        const av: i128 = @as(i128, a) * std.math.pow(i128, 10, ae - minimum);
        const bv: i128 = @as(i128, b) * std.math.pow(i128, 10, be - minimum);
        var input_buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buffer, "{{\"a\":{d}e{d},\"b\":{d}e{d}}}", .{ a, ae, b, be });
        var actual_buffer: [100]u8 = undefined;
        var actual = std.Io.Writer.fixed(&actual_buffer);
        try program.run(t.allocator, input, &actual, &diagnostic);
        var expected_buffer: [100]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "[{},{},{}]\n", .{ av == bv, av < bv, av > bv });
        try t.expectEqualStrings(expected, actual.buffered());
    }
}

test "generated integer arithmetic matches checked wide integer reference" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "[.a+.b,.a-.b,.a*.b]", &diagnostic);
    defer program.deinit();
    var prng = std.Random.DefaultPrng.init(128);
    const random = prng.random();
    for (0..1000) |_| {
        const a: i128 = random.int(i64);
        const b: i128 = random.int(i64);
        var input_buffer: [160]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buffer, "{{\"a\":{d},\"b\":{d}}}", .{ a, b });
        var actual_buffer: [160]u8 = undefined;
        var actual = std.Io.Writer.fixed(&actual_buffer);
        try program.run(t.allocator, input, &actual, &diagnostic);
        var expected_buffer: [160]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "[{d},{d},{d}]\n", .{ a + b, a - b, a * b });
        try t.expectEqualStrings(expected, actual.buffered());
    }
}

test "generated sort stability and grouping order match a bucket reference" {
    var random = std.Random.DefaultPrng.init(0x5077);
    for ([_][]const u8{ "sort_by(.k) | .seq | collect", "group_by(.k) | each | .seq | collect" }, 0..) |source, mode| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        for (0..50) |_| {
            var keys: [128]u8 = undefined;
            var first_seen: [8]u8 = undefined;
            var seen: [8]bool = @splat(false);
            var distinct: usize = 0;
            var actual = std.Io.Writer.Allocating.init(t.allocator);
            defer actual.deinit();
            var stream = try program.start(t.allocator, &actual.writer, &diagnostic, .{});
            defer stream.deinit();
            for (&keys, 0..) |*key, sequence| {
                key.* = random.random().uintLessThan(u8, 8);
                if (!seen[key.*]) {
                    seen[key.*] = true;
                    first_seen[distinct] = key.*;
                    distinct += 1;
                }
                var bytes: [64]u8 = undefined;
                _ = try stream.feed(try std.fmt.bufPrint(&bytes, "{{\"k\":{d},\"seq\":{d}}}", .{ key.*, sequence }));
            }
            try stream.finish();
            var expected = std.Io.Writer.Allocating.init(t.allocator);
            defer expected.deinit();
            try expected.writer.writeByte('[');
            var written: usize = 0;
            for (0..8) |bucket| {
                if (mode != 0 and bucket >= distinct) break;
                const key = if (mode == 0) @as(u8, @intCast(bucket)) else first_seen[bucket];
                for (keys, 0..) |item, sequence| {
                    if (item != key) continue;
                    if (written != 0) try expected.writer.writeByte(',');
                    try expected.writer.print("{d}", .{sequence});
                    written += 1;
                }
            }
            try expected.writer.writeAll("]\n");
            try t.expectEqualStrings(expected.written(), actual.written());
        }
    }
}
