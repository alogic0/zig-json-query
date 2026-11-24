//! CLI file access. The public BindingBudget frames captured JSON bytes.
const std = @import("std");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Kind = enum { json, raw };
pub const Spec = struct { index: usize, kind: Kind, path: []const u8 };

pub fn readNamed(a: A, io: Io, path: []const u8, limit: usize) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(limit));
}

test "named file reads enforce their bound even for non-positional sources" {
    try std.testing.expectError(error.StreamTooLong, readNamed(std.testing.allocator, std.testing.io, "/dev/zero", 8));
}
