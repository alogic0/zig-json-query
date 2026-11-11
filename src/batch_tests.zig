const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

test "batch named feeds own retained metadata and clear it for completion and anonymous input" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{file: input_filename(), id: .id} | collect | {records: ., at_end: input_filename()}", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    var filename = "first.json".*;
    var input = "{\"id\":9007199254740993}".*;
    _ = try stream.feedNamed(&input, &filename);
    @memset(&filename, 'x');
    @memset(&input, 'x');
    _ = try stream.feedNamed("{\"id\":2}", "second.json");
    _ = try stream.feed("{\"id\":3}");
    try stream.finish();
    try t.expectEqualStrings("{\"records\":[{\"file\":\"first.json\",\"id\":9007199254740993},{\"file\":\"second.json\",\"id\":2},{\"file\":null,\"id\":3}],\"at_end\":null}\n", output.written());
}

test "batch slurp owns values after source reuse and downstream retention owns its copies" {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "each | {value: ., file: input_filename()} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    {
        const slurp = try query.Slurp.init(t.allocator, query.max_input_bytes);
        defer slurp.deinit();
        var bytes = "{\"number\":9007199254740993,\"name\":\"first\"}".*;
        try slurp.append(&bytes, &diagnostic);
        @memset(&bytes, 'x');
        try slurp.append("1.2300e-4", &diagnostic);
        _ = try stream.feedSlurp(slurp);
    }
    try stream.finish();
    try t.expectEqualStrings("[{\"value\":{\"number\":9007199254740993,\"name\":\"first\"},\"file\":null},{\"value\":1.2300e-4,\"file\":null}]\n", output.written());
}

test "batch empty slurp supplies one empty array without collection allocations" {
    var diagnostic: query.Diagnostic = .{};
    const slurp = try query.Slurp.init(t.allocator, 0);
    defer slurp.deinit();
    for ([_][]const u8{ "length(.)", "each | count" }) |source| {
        var program = try query.Program.compile(t.allocator, source, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.Allocating.init(t.allocator);
        defer output.deinit();
        var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
        defer stream.deinit();
        _ = try stream.feedSlurp(slurp);
        try stream.finish();
        try t.expectEqualStrings("0\n", output.written());
    }
}

test "batch slurp rejects budget failures and cannot emit partial input afterwards" {
    var diagnostic: query.Diagnostic = .{};
    const slurp = try query.Slurp.init(t.allocator, 0);
    defer slurp.deinit();
    try t.expectError(error.SlurpTooLarge, slurp.append("null", &diagnostic));
    try t.expectError(error.StreamFailed, slurp.append("1", &diagnostic));
    var program = try query.Program.compile(t.allocator, ".", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    try t.expectError(error.StreamFailed, stream.feedSlurp(slurp));
    try t.expectError(error.StreamFailed, stream.finish());
    try t.expectEqualStrings("", output.written());
}

test "batch slurp validation includes wrapper depth duplicate keys and located syntax errors" {
    var diagnostic: query.Diagnostic = .{};
    var arrays: [256]u8 = undefined;
    @memset(arrays[0..128], '[');
    @memset(arrays[128..], ']');
    const accepted = try query.Slurp.init(t.allocator, query.max_input_bytes);
    defer accepted.deinit();
    try accepted.append(arrays[1..255], &diagnostic);
    const deep = try query.Slurp.init(t.allocator, query.max_input_bytes);
    defer deep.deinit();
    try t.expectError(error.InputTooDeep, deep.append(&arrays, &diagnostic));
    const duplicate = try query.Slurp.init(t.allocator, query.max_input_bytes);
    defer duplicate.deinit();
    try t.expectError(error.DuplicateField, duplicate.append("{\"x\":1,\"x\":2}", &diagnostic));
    const broken = try query.Slurp.init(t.allocator, query.max_input_bytes);
    defer broken.deinit();
    try t.expectError(error.SyntaxError, broken.append("{\n\"x\":bad\n}", &diagnostic));
    try t.expectEqual(@as(u64, 2), diagnostic.input_line);
    try t.expect(diagnostic.input_offset != null);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(allocator, "each | {tag: $tag, value: .} | collect", &.{.{ .name = "tag", .value = .{ .string = "batch" } }}, &diagnostic);
    defer program.deinit();
    const slurp = try query.Slurp.init(allocator, query.max_input_bytes);
    defer slurp.deinit();
    try slurp.append("{\"name\":\"one\",\"value\":9007199254740993}", &diagnostic);
    try slurp.append("[false,null,1.2300e-4]", &diagnostic);
    var bytes: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(allocator, &output, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feedSlurp(slurp);
    try stream.finish();
    try t.expectEqualStrings("[{\"tag\":\"batch\",\"value\":{\"name\":\"one\",\"value\":9007199254740993}},{\"tag\":\"batch\",\"value\":[false,null,1.2300e-4]}]\n", output.buffered());
}

test "batch allocation failures release shared parser slurp and downstream collectors" {
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
