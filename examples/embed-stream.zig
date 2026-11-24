//! zig build example-stream
const std = @import("std");
const query = @import("query");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    var diagnostic: query.Diagnostic = .{};
    var budget = query.BindingBudget.init(128);
    var program = program: {
        const frame = try budget.prepareJson(a, "9007199254740993");
        defer a.free(frame);
        break :program try query.Program.compileWithBindings(a, @embedFile("embed-stream.jqz"), &.{
            .{ .name = "expected", .value = .{ .json = frame } },
        }, &diagnostic);
    };
    defer program.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var stream = try program.start(a, &output.writer, &diagnostic, .{});
    defer stream.deinit();
    _ = try stream.feedNamed("{\"kind\":\"progress\"}", "events.ndjson");
    if (output.written().len != 0) return error.ExpectedNoOutput;
    _ = try stream.feedNamed("{\"kind\":\"result\",\"value\":9007199254740993}", "events.ndjson");
    try stream.finish();
    if (stream.predicateStatus() != 0 or !std.mem.eql(u8, output.written(), "9007199254740993\n")) return error.WrongResult;
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());

    var failing = try program.start(a, &output.writer, &diagnostic, .{});
    defer failing.deinit();
    if (failing.feed("{\"kind\":\"result\",\"value\":1}")) |_| {
        return error.ExpectedAssertion;
    } else |err| {
        if (err != error.AssertionFailed) return err;
        var buf: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buf);
        try diagnostic.assertion.?.write(&stderr.interface);
        try stderr.interface.flush();
    }
}
