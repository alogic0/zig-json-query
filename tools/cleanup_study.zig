//! Portable checks and allocation measurements for cleanup query workflows.
const std = @import("std");
const query = @import("query");
const Meter = @import("allocation_meter.zig");
const A = std.mem.Allocator;
const Measurement = struct { records: usize, keys: usize, payload_bytes: usize, retained_bytes: usize, owner_delta_bytes: u64, peak_including_transient_bytes: u64, requested_bytes: u64, cleanup_live_bytes: u64 };
const IndexMeasurement = struct { records: usize, matched_left_records: usize, lookup_calls: usize, hash_index_present: bool, retained_bytes: usize, lookup_requested_bytes: u64, cleanup_live_bytes: u64 };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const cases = [_]Measurement{
        try measure(init.gpa, 32, 16, 4),    try measure(init.gpa, 4096, 16, 4),
        try measure(init.gpa, 32, 4096, 4),  try measure(init.gpa, 4096, 4096, 4),
        try measure(init.gpa, 4096, 16, 64),
    };
    for (cases[0..4]) |case| if (case.retained_bytes != cases[0].retained_bytes) return error.RetentionGrewWithRecordsOrPayload;
    if (cases[4].retained_bytes <= cases[0].retained_bytes) return error.MissingDistinctKeyStorage;
    const indexes = [_]IndexMeasurement{ try measureIndex(init.gpa, 16, 256), try measureIndex(init.gpa, 4096, 65536) };
    const Hash = struct { path: []const u8, sha256: []const u8 };
    var hashes: std.ArrayList(Hash) = .empty;
    for ([_][]const u8{ "src/root.zig", "src/execution.zig", "src/group_totals.zig", "src/key_index.zig", "src/parser.zig", "src/evaluator.zig", "src/collection_budget.zig", "tools/cleanup_study.zig", "tools/allocation_meter.zig" }) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(1024 * 1024));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        try hashes.append(a, .{ .path = path, .sha256 = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) });
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(.{
        .schema_version = 1,
        .version = query.version,
        .optimization = @tagName(@import("builtin").mode),
        .method = "Existing allocation meter wraps session allocation requests. Group comparisons disable in-place resize/remap through the existing failing-allocator helper (allocations succeed), making arena capacity independent of backing-allocator placement. Program/input text and fixed output buffer excluded. Retained capacity sampled after every feed, after parsed input and scalar temporaries are freed. Peak/requested bytes include transient parsing. Completed results checked independently. Index checks reuse an existing ObjectMap hash index for two successful lookups per repeated left key, with zero allocation during lookup/completion. Counts describe requested capacity, not RSS; no timing claim.",
        .source_hashes = hashes.items,
        .grouped_totals = cases,
        .keyed_lookups = indexes,
    }, .{ .whitespace = .indent_2 }, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn measureIndex(a: A, records: usize, matches: usize) !IndexMeasurement {
    var keys = std.Io.Writer.Allocating.init(a);
    defer keys.deinit();
    try keys.writer.writeByte('[');
    for (0..matches) |index| {
        if (index != 0) try keys.writer.writeByte(',');
        try keys.writer.print("\"p{d}\"", .{records - 1});
    }
    try keys.writer.writeByte(']');
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compileWithBindings(a, "index_by(.path) | all($keys,root()[.].path == . and root()[.].size == 9007199254740993)", &.{.{ .name = "keys", .value = .{ .json = keys.written() } }}, &diagnostic);
    defer program.deinit();
    var meter: Meter = .{ .backing = a };
    var result: IndexMeasurement = undefined;
    {
        var bytes: [8]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        var stream = try program.start(meter.allocator(), &output, &diagnostic, .{});
        defer stream.deinit();
        const baseline = meter.counters.live_bytes;
        var input: [128]u8 = undefined;
        for (0..records) |index| {
            const text = try std.fmt.bufPrint(&input, "{{\"path\":\"p{d}\",\"size\":{d}}}", .{ index, if (index == records - 1) @as(u64, 9007199254740993) else @as(u64, @intCast(index)) });
            _ = try stream.feed(text);
            @memset(&input, 'x');
        }
        const indexed = &stream.execution.states[0].index.entries;
        if (indexed.count() != records or indexed.index_header == null) return error.MissingBuiltHashIndex;
        const retained = stream.execution.budget.used;
        if (meter.counters.live_bytes - baseline != retained) return error.UnaccountedIndexAllocation;
        const before = meter.begin();
        try stream.finish();
        const lookups = meter.end(before);
        if (!std.mem.eql(u8, "true\n", output.buffered())) return error.IndexLookupMismatch;
        if (lookups.requested_bytes != 0) return error.LookupRebuiltOrAllocatedStorage;
        if (meter.counters.live_bytes != baseline or stream.execution.budget.used != 0) return error.IndexCompletionLeak;
        result = .{ .records = records, .matched_left_records = matches, .lookup_calls = matches * 2, .hash_index_present = true, .retained_bytes = retained, .lookup_requested_bytes = lookups.requested_bytes, .cleanup_live_bytes = 0 };
    }
    if (meter.counters.live_bytes != 0) return error.IndexSessionLeak;
    return result;
}

fn measure(a: A, records: usize, payload_bytes: usize, keys: usize) !Measurement {
    // Arena growth may otherwise depend on the backing allocator's placement.
    var fixed_growth = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(a, "sum_by(.group,.bytes)", &diagnostic);
    defer program.deinit();
    var inputs: std.ArrayList([]u8) = .empty;
    defer {
        for (inputs.items) |text| a.free(text);
        inputs.deinit(a);
    }
    const payload = try a.alloc(u8, payload_bytes);
    defer a.free(payload);
    @memset(payload, 'x');
    for (0..keys) |key| {
        const text = try a.print("{{\"group\":\"g{d}\",\"bytes\":1,\"payload\":\"{s}\"}}", .{ key, payload });
        errdefer a.free(text);
        try inputs.append(a, text);
    }
    var meter: Meter = .{ .backing = fixed_growth.allocator() };
    var result: Measurement = undefined;
    {
        var bytes: [16 * 1024]u8 = undefined;
        var output = std.Io.Writer.fixed(&bytes);
        var stream = try program.start(meter.allocator(), &output, &diagnostic, .{ .max_collect_bytes = 64 * 1024 });
        defer stream.deinit();
        const before = meter.begin();
        var retained: usize = 0;
        for (0..records) |index| {
            _ = try stream.feed(inputs.items[index % keys]);
            if (index == keys - 1) retained = stream.execution.budget.used;
            if (index >= keys and stream.execution.budget.used != retained) return error.RetentionGrewWithRecords;
        }
        const after_feeds = meter.end(before);
        const owner_delta = after_feeds.end_live_bytes - before.live_bytes;
        if (owner_delta != retained) return error.UnaccountedRetainedAllocation;
        try stream.finish();
        if (stream.execution.budget.used != 0 or meter.counters.live_bytes != before.live_bytes) return error.CompletionLeak;
        var expected = std.Io.Writer.Allocating.init(a);
        defer expected.deinit();
        for (0..keys) |key| try expected.writer.print("{{\"key\":\"g{d}\",\"count\":{d},\"sum\":{d}}}\n", .{ key, records / keys, records / keys });
        if (!std.mem.eql(u8, expected.written(), output.buffered())) return error.TotalsMismatch;
        result = .{ .records = records, .keys = keys, .payload_bytes = payload_bytes, .retained_bytes = retained, .owner_delta_bytes = owner_delta, .peak_including_transient_bytes = after_feeds.peak_live_bytes, .requested_bytes = after_feeds.requested_bytes, .cleanup_live_bytes = 0 };
    }
    if (meter.counters.live_bytes != 0 or fixed_growth.allocated_bytes != fixed_growth.freed_bytes) return error.SessionLeak;
    return result;
}
