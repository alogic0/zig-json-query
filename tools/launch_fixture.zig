//! Matched native Debug startup controls, without query parsing or evaluation.
const std = @import("std");
const echo = @import("launch_options").echo;

pub fn main(init: std.process.Init) !void {
    if (!echo) return;
    var buffer: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const bytes = try reader.interface.allocRemaining(init.gpa, .limited(1024));
    defer init.gpa.free(bytes);
    if (!std.mem.eql(u8, bytes, "null\n")) return error.UnexpectedInput;
    var output_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try writer.interface.writeAll("null\n");
    try writer.interface.flush();
}
