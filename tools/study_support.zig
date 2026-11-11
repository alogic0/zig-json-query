//! Shared evidence and controls for native Debug performance experiments.
const std = @import("std");
const builtin = @import("builtin");
const S = @import("test_support");
const options = @import("profile_options");
pub const Meter = @import("allocation_meter.zig");
pub const A = std.mem.Allocator;
pub const Io = std.Io;
pub const Traffic = struct { allocations: u64 = 0, requested_bytes: u64 = 0 };
pub const Record = struct {
    case: []const u8,
    variant: []const u8,
    iteration: usize,
    elapsed_ns: u64,
    memory: Meter.Delta,
    logical: ?Meter.Counters = null,
    token_traffic: ?Traffic = null,
};
pub const Hash = struct { path: []const u8, sha256: []const u8 };
pub const Stats = struct { min: u64, median: u64, max: u64 };
const Summary = struct { case: []const u8, variant: []const u8, samples: usize, wall_ns: Stats, allocations: Stats, requested_bytes: Stats, peak_live_bytes: Stats };
pub const Run = struct {
    a: A,
    io: Io,
    sources: std.ArrayList(Hash) = .empty,
    tools: std.ArrayList(Hash) = .empty,

    pub fn init(a: A, io: Io, executable: []const u8, extra_paths: []const []const u8) !Run {
        if (builtin.os.tag != .linux or builtin.mode != .debug) return error.NativeDebugProfilingRequired;
        var self: Run = .{ .a = a, .io = io };
        for ([_][]const u8{ "build.zig", "build.zig.zon", "src/root.zig", "src/main.zig", "src/input.zig", "src/value_builder.zig", "src/parser.zig", "src/evaluator.zig", "src/execution.zig", "src/number.zig", "src/statistics.zig", "src/rows.zig", "src/buffered.zig", "src/json_order.zig", "src/collection_budget.zig", "src/diagnostic.zig", "src/profile_engine.zig", "tools/profile.zig", "tools/allocation_meter.zig", "tools/study_support.zig", "tools/fixtures.zig", "vendor/SHA256SUMS" }) |path| try self.source(path);
        for (extra_paths) |path| try self.source(path);
        for ([_][]const u8{ options.compiler, options.exe, executable }) |path| try self.tool(path);
        return self;
    }

    pub fn source(self: *Run, path: []const u8) !void {
        try self.sources.append(self.a, .{ .path = path, .sha256 = try digestFile(self.a, self.io, path) });
    }

    pub fn tool(self: *Run, path: []const u8) !void {
        try self.tools.append(self.a, .{ .path = path, .sha256 = try digestFile(self.a, self.io, path) });
    }

    pub fn publish(self: *Run, kind: []const u8, repeat: usize, method: []const u8, records: []const Record, details: anytype, out: ?[]const u8) !void {
        for (self.sources.items) |source_hash| if (!std.mem.eql(u8, source_hash.sha256, try digestFile(self.a, self.io, source_hash.path))) return error.SourceChangedDuringRun;
        for (self.tools.items) |tool_hash| if (!std.mem.eql(u8, tool_hash.sha256, try digestFile(self.a, self.io, tool_hash.path))) return error.ToolChangedDuringRun;
        var summaries: std.ArrayList(Summary) = .empty;
        for (records, 0..) |record, at| {
            var seen = false;
            for (records[0..at]) |old| if (same(record, old)) {
                seen = true;
                break;
            };
            if (seen) continue;
            var times: std.ArrayList(u64) = .empty;
            var allocations: std.ArrayList(u64) = .empty;
            var requested: std.ArrayList(u64) = .empty;
            var peaks: std.ArrayList(u64) = .empty;
            for (records) |item| if (same(record, item)) {
                try times.append(self.a, item.elapsed_ns);
                try allocations.append(self.a, item.memory.allocations);
                try requested.append(self.a, item.memory.requested_bytes);
                try peaks.append(self.a, item.memory.peak_live_bytes);
            };
            try summaries.append(self.a, .{ .case = record.case, .variant = record.variant, .samples = times.items.len, .wall_ns = try stats(self.a, times.items), .allocations = try stats(self.a, allocations.items), .requested_bytes = try stats(self.a, requested.items), .peak_live_bytes = try stats(self.a, peaks.items) });
        }
        var json = Io.Writer.Allocating.init(self.a);
        try std.json.Stringify.value(.{
            .schema_version = 1,
            .study = kind,
            .version = options.version,
            .zig = builtin.zig_version_string,
            .optimization = @tagName(builtin.mode),
            .target = options.target,
            .cpu_model = builtin.cpu.model.name,
            .kernel_release = try kernel(self.a, self.io),
            .measured_at_unix_seconds = Io.Clock.real.now(self.io).toSeconds(),
            .repeat = repeat,
            .method = method,
            .source_hashes = self.sources.items,
            .tool_hashes = self.tools.items,
            .details = details,
            .samples = records,
            .summaries = summaries.items,
        }, .{ .whitespace = .indent_2 }, &json.writer);
        try json.writer.writeByte('\n');
        if (out) |path| {
            if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(self.io, parent);
            try S.files.writeAtomic(self.io, .{ .path = path, .replace = true }, &.{json.written()});
        } else try Io.File.stdout().writeStreamingAll(self.io, json.written());
        std.debug.print("{s} study: {d} checked samples\n", .{ kind, records.len });
    }
};

fn same(a: Record, b: Record) bool {
    return std.mem.eql(u8, a.case, b.case) and std.mem.eql(u8, a.variant, b.variant);
}
pub fn elapsed(start: Io.Timestamp, io: Io) u64 {
    return @intCast(start.untilNow(io, .awake).nanoseconds);
}
pub fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
pub fn digestFile(a: A, io: Io, path: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(try S.files.sha256(io, path), .lower));
}
pub fn stats(a: A, input: []const u64) !Stats {
    if (input.len == 0) return error.EmptySamples;
    const values = try a.dupe(u64, input);
    defer a.free(values);
    std.sort.pdq(u64, values, {}, std.sort.asc(u64));
    const mid = values.len / 2;
    return .{ .min = values[0], .median = if (values.len % 2 == 1) values[mid] else values[mid - 1] + (values[mid] - values[mid - 1]) / 2, .max = values[values.len - 1] };
}
fn kernel(a: A, io: Io) ![]const u8 {
    const file = try Io.Dir.cwd().openFile(io, "/proc/sys/kernel/osrelease", .{});
    defer file.close(io);
    var bytes: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &bytes);
    const value = std.mem.trim(u8, try reader.interface.allocRemaining(a, .limited(4096)), " \r\n");
    if (value.len == 0) return error.MissingKernelRelease;
    return value;
}

test "study summaries preserve raw order and reject empty samples" {
    const t = std.testing;
    const values = [_]u64{ 9, 1, 7, 3 };
    try t.expectEqualDeep(Stats{ .min = 1, .median = 5, .max = 9 }, try stats(t.allocator, &values));
    try t.expectEqualSlices(u64, &.{ 9, 1, 7, 3 }, &values);
    try t.expectError(error.EmptySamples, stats(t.allocator, &.{}));
}
