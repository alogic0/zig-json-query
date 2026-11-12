const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

fn run(source: []const u8, inputs: []const []const u8, expected: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    for (inputs) |input| {
        if (!stream.needsInput()) break;
        _ = try stream.feed(input);
    }
    try t.expectEqualStrings("", output.written());
    try stream.finish();
    try stream.finish();
    try t.expectEqualStrings(expected, output.written());
}

test "group totals match materialized grouping with exact integers and first-seen order" {
    const input = "[{\"k\":\"b\",\"n\":9007199254740993},{\"k\":\"a\",\"n\":-2},{\"k\":\"b\",\"n\":-3}]";
    const expected = "{\"key\":\"b\",\"count\":2,\"sum\":9007199254740990}\n{\"key\":\"a\",\"count\":1,\"sum\":-2}\n";
    try run("each | sum_by(.k,.n)", &.{input}, expected);
    try run("each | group_by(.k) | {key:.[0].k,count:length(.),sum:sum(map(.,.n))}", &.{input}, expected);
    try run("each | count_by(.k)", &.{input}, "{\"key\":\"b\",\"count\":2}\n{\"key\":\"a\",\"count\":1}\n");
    try run("sum_by(.missing,.bad) | collect", &.{}, "[]\n");
    try run("count_by(.missing) | collect", &.{}, "[]\n");
}

test "group totals use structural and exact numeric group equality" {
    try run("each | count_by(.)", &.{"[null,false,1.00,1,{\"b\":2,\"a\":[1]},{\"a\":[1.0],\"b\":2},null,\"1\"]"}, "{\"key\":null,\"count\":2}\n{\"key\":false,\"count\":1}\n{\"key\":1.00,\"count\":2}\n{\"key\":{\"b\":2,\"a\":[1]},\"count\":2}\n{\"key\":\"1\",\"count\":1}\n");
}

test "group totals own keys across source reuse and downstream retention" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "sum_by(.key,.n) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var bytes = "{\"key\":[\"é\",false],\"n\":1}".*;
    _ = try stream.feed(&bytes);
    @memset(&bytes, 'x');
    _ = try stream.feed("{\"key\":[\"é\",false],\"n\":2}");
    try stream.finish();
    try t.expectEqualStrings("[{\"key\":[\"é\",false],\"count\":2,\"sum\":3}]\n", output.written());
}

test "group total failures suppress partial totals and preserve integer rules" {
    for ([_][]const u8{
        "[{\"k\":0,\"n\":1},{\"k\":1,\"n\":false}]",
        "[{\"k\":0,\"n\":1},{\"k\":1,\"n\":1.5}]",
        "[{\"k\":0,\"n\":1},{\"k\":1}]",
        "[{\"k\":0,\"n\":170141183460469231731687303715884105727},{\"k\":0,\"n\":1}]",
        "[{\"k\":1e9223372036854775808,\"n\":0}]",
    }) |input| {
        var diagnostic: query.Diagnostic = .{};
        var program = try query.Program.compile(t.allocator, "each | sum_by(.k,.n)", &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.Allocating.init(t.allocator);
        defer output.deinit();
        var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
        defer stream.deinit();
        try t.expectError(error.EvaluationFailed, stream.feed(input));
        try t.expectEqualStrings("", output.written());
        try t.expectError(error.StreamFailed, stream.finish());
    }
    for ([_][]const u8{ "count_by()", "sum_by(.k)", "count_by(.k,.n)", "{n:count_by(.)}" }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
    var deep: [256]u8 = undefined;
    @memset(deep[0..128], '[');
    @memset(deep[128..], ']');
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "count_by(.)", &diagnostic);
    defer program.deinit();
    var bytes: [0]u8 = .{};
    var output = std.Io.Writer.fixed(&bytes);
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, &deep, &output, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "output wrapper") != null);
}

test "group totals honor early stopping completion budgets and failed writes" {
    try run("take(2) | sum_by(.k,.n)", &.{ "{\"k\":1,\"n\":2}", "{\"k\":1,\"n\":3}", "invalid" }, "{\"key\":1,\"count\":2,\"sum\":5}\n");
    try run("count_by(.) | take(0) | collect", &.{"invalid"}, "[]\n");
    try run("count_by(.) | take(1) | collect", &.{ "false", "null" }, "[{\"key\":false,\"count\":1}]\n");
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "count_by(.)", &diagnostic);
    defer program.deinit();
    var bytes: [0]u8 = .{};
    var output = std.Io.Writer.fixed(&bytes);
    var small = try program.start(t.allocator, &output, &diagnostic, .{ .max_collect_bytes = 1 });
    defer small.deinit();
    try t.expectError(error.EvaluationFailed, small.feed("null"));
    try t.expectEqual(@as(usize, 1), diagnostic.budget.?.limit);
    var failed = try program.start(t.allocator, &output, &diagnostic, .{});
    defer failed.deinit();
    _ = try failed.feed("null");
    try t.expectError(error.WriteFailed, failed.finish());
    try t.expectError(error.StreamFailed, failed.finish());
}

test "group count checks u64 overflow before mutating accumulator" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "count_by(.)", &diagnostic);
    defer program.deinit();
    var bytes: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(t.allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("null");
    stream.execution.states[0].totals.rows.items[0].count = std.math.maxInt(u64);
    try t.expectError(error.EvaluationFailed, stream.feed("null"));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, "u64 range") != null);
    try t.expectEqualStrings("", output.buffered());
}

fn allocationScenario(a: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(a, "each | sum_by(.kind,.amount) | collect | each | count_by(.count)", &diagnostic);
    defer program.deinit();
    var bytes: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(a, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feed("[{\"kind\":{\"a\":[\"x\",1]},\"amount\":2},{\"kind\":{\"a\":[\"x\",1.0]},\"amount\":3},{\"kind\":null,\"amount\":-1}]");
    try stream.finish();
    try t.expectEqualStrings("{\"key\":2,\"count\":1}\n{\"key\":1,\"count\":1}\n", output.buffered());
}

test "group totals release every allocation across ownership and completion failures" {
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
