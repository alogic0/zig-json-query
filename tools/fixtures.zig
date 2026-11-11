//! Shared deterministic scale inputs for qualification and phase profiling.
const std = @import("std");
pub const Kind = enum { commands, backend };

pub fn generate(a: std.mem.Allocator, kind: Kind, rows: usize) ![]const u8 {
    if (rows == 0 or rows > 100000) return error.InvalidGeneratedRowCount;
    var output = std.Io.Writer.Allocating.init(a);
    defer output.deinit();
    if (kind == .commands) {
        try output.writer.writeByte('[');
        for (0..rows) |index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"argv\":[\"bin/z_llvm\",\"compile\",\"unit.zig\"],\"cwd\":\"workspace\",\"returncode\":0,\"wall_ns\":1000000,\"timeout_ms\":5000,\"stdout\":\"\",\"stderr\":\"\",\"outcome\":\"exited\",\"actual_returncode\":0}");
        }
        try output.writer.writeAll("]\n");
    } else {
        try output.writer.writeAll("{\"passed\":true,\"cleanup_passed\":true,\"result\":{\"code\":0},\"http\":[");
        for (0..rows) |index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"case\":\"check\",\"path\":\"/health\",\"status\":200}");
        }
        try output.writer.writeAll("],\"fixtures\":[");
        for (0..rows) |index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"case\":\"compile\",\"result\":{\"code\":0}}");
        }
        try output.writer.writeAll("]}\n");
    }
    return output.toOwnedSlice();
}
