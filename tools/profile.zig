//! Native Debug phase measurements. Fixture IO and report allocations are outside
//! measured engine phases; source and generated inputs are shared with qualification.
const std = @import("std");
const builtin = @import("builtin");
const S = @import("test_support");
const engine = @import("profile_engine");
const options = @import("profile_options");
const Meter = @import("allocation_meter.zig");
const generated = @import("fixtures.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const PhaseName = enum { compile_query, session_setup, parse_document, feed_evaluate, release_document, finish_emit, cleanup };
const phase_count = 7;
const Phase = struct { name: PhaseName, elapsed_ns: u64, memory: Meter.Delta };
const Case = struct { id: []const u8, query: []const u8, fixture: enum { tiny, small, commands, backend } };
const Sample = struct { case: []const u8, iteration: usize, phases: [phase_count]Phase };
const Stats = struct { min: u64, median: u64, max: u64 };
const Summary = struct { case: []const u8, phase: PhaseName, wall_ns: Stats, allocations: Stats, requested_bytes: Stats, peak_live_bytes: Stats };
const Hash = struct { path: []const u8, sha256: []const u8 };
const cases = [_]Case{
    .{ .id = "null-startup", .query = ".", .fixture = .tiny },
    .{ .id = "report-small", .query = "{passed,cleanup_passed,result,http_count:length(.http)}", .fixture = .small },
    .{ .id = "command-count-scale", .query = "{commands:length(.),last:.[-1].argv}", .fixture = .commands },
    .{ .id = "report-count-scale", .query = "{passed,cleanup_passed,result,http_count:length(.http)}", .fixture = .backend },
    .{ .id = "report-filter-scale", .query = "length(filter(.fixtures,.result.code != 0))", .fixture = .backend },
    .{ .id = "report-unique-scale", .query = "unique(map(.fixtures,keys(.)))", .fixture = .backend },
    .{ .id = "report-encode-scale", .query = "byte_length(tojson(.))", .fixture = .backend },
};
const source_paths = [_][]const u8{
    "build.zig", "build.zig.zon", "src/main.zig", "src/root.zig", "src/input.zig", "src/value_builder.zig", "src/parser.zig", "src/evaluator.zig", "src/execution.zig", "src/number.zig", "src/statistics.zig", "src/rows.zig", "src/buffered.zig", "src/json_order.zig", "src/diagnostic.zig", "src/collection_budget.zig", "src/profile_engine.zig", "tools/profile.zig", "tools/allocation_meter.zig", "tools/fixtures.zig", "vendor/SHA256SUMS",
};

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux or builtin.mode != .debug) return error.NativeDebugProfilingRequired;
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var repeats: usize = 10;
    var out: ?[]const u8 = null;
    var study: ?[]const u8 = null;
    var reference_cli: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("profile [--study parser|invocation] [--reference-cli PATH] [--repeat N] [--out FILE]\n", .{});
            return;
        }
        if (index + 1 == args.len) return error.MissingOptionValue;
        if (std.mem.eql(u8, args[index], "--repeat")) repeats = try std.fmt.parseInt(usize, args[index + 1], 10) else if (std.mem.eql(u8, args[index], "--out")) out = args[index + 1] else if (std.mem.eql(u8, args[index], "--study")) study = args[index + 1] else if (std.mem.eql(u8, args[index], "--reference-cli")) reference_cli = args[index + 1] else return error.UnknownOption;
    }
    if (repeats < 1 or repeats > 100) return error.InvalidRepetitionCount;
    if (study) |kind| {
        if (std.mem.eql(u8, kind, "parser")) return @import("parser_study.zig").run(init, repeats, out);
        if (std.mem.eql(u8, kind, "invocation")) return @import("invocation_study.zig").run(init, repeats, out, reference_cli);
        return error.UnknownStudy;
    }
    var hashes: std.ArrayList(Hash) = .empty;
    for (source_paths) |path| try hashes.append(a, .{ .path = path, .sha256 = try digestFile(a, io, path) });
    const compiler_hash = try digestFile(a, io, options.compiler);
    const cli_hash = try digestFile(a, io, options.exe);
    const profiler_hash = try digestFile(a, io, args[0]);
    const kernel_release = std.mem.trim(u8, try readStream(a, io, "/proc/sys/kernel/osrelease"), " \r\n");
    if (kernel_release.len == 0) return error.MissingKernelRelease;
    const version = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = &.{ options.exe, "--version" } }, .timeout_ms = 5000 }, .stdin = "" });
    defer version.deinit(a);
    try S.Diagnostic.expectExit(version, .{ .assertion = "profile CLI version", .code = 0 });
    if (!std.mem.eql(u8, version.stdout, "jqz " ++ options.version ++ "\n")) return error.ToolVersionMismatch;

    const inputs = [_][]const u8{
        try Io.Dir.cwd().readFileAlloc(io, "tests/qualification/null.json", a, .limited(1024)),
        try Io.Dir.cwd().readFileAlloc(io, "tests/qualification/backend.json", a, .limited(4096)),
        try generated.generate(a, .commands, 2837),
        try generated.generate(a, .backend, 10000),
    };
    const Fixture = struct { id: []const u8, path: ?[]const u8, rows_per_array: usize, bytes: usize, sha256: []const u8 };
    var fixtures: std.ArrayList(Fixture) = .empty;
    for (inputs, 0..) |input, fixture| try fixtures.append(a, .{
        .id = @tagName(@as(@FieldType(Case, "fixture"), @fromBackingInt(@intCast(fixture)))),
        .path = switch (fixture) {
            0 => "tests/qualification/null.json",
            1 => "tests/qualification/backend.json",
            else => null,
        },
        .rows_per_array = switch (fixture) {
            2 => 2837,
            3 => 10000,
            else => 0,
        },
        .bytes = input.len,
        .sha256 = try digest(a, input),
    });
    const Check = struct { case: []const u8, query: []const u8, fixture: []const u8, output_bytes: usize, output_sha256: []const u8 };
    var checks: std.ArrayList(Check) = .empty;
    var expectations: std.ArrayList([]const u8) = .empty;
    // Preflight every phase path against ordinary public execution before timing.
    for (cases) |case| {
        const input = inputs[@backingInt(case.fixture)];
        const expected = try ordinary(a, case.query, input);
        _ = try runPhases(init.gpa, io, case, input, expected, 0);
        try expectations.append(a, expected);
        try checks.append(a, .{ .case = case.id, .query = case.query, .fixture = @tagName(case.fixture), .output_bytes = expected.len, .output_sha256 = try digest(a, expected) });
    }
    // One additional warm-up of the actual launch/capture path.
    _ = try launch(a, io);
    var samples: std.ArrayList(Sample) = .empty;
    var launch_samples: std.ArrayList(u64) = .empty;
    for (0..repeats) |iteration| {
        // Rotate case order so one query does not always inherit the same caches.
        for (0..cases.len) |step| {
            const at = (iteration + step) % cases.len;
            try samples.append(a, try runPhases(init.gpa, io, cases[at], inputs[@backingInt(cases[at].fixture)], expectations.items[at], iteration));
        }
        try launch_samples.append(a, try launch(a, io));
    }
    var summaries: std.ArrayList(Summary) = .empty;
    for (cases) |case| for (0..phase_count) |phase| {
        var times: std.ArrayList(u64) = .empty;
        var allocations: std.ArrayList(u64) = .empty;
        var requested: std.ArrayList(u64) = .empty;
        var peaks: std.ArrayList(u64) = .empty;
        for (samples.items) |sample| {
            if (!std.mem.eql(u8, sample.case, case.id)) continue;
            const value = sample.phases[phase];
            try times.append(a, value.elapsed_ns);
            try allocations.append(a, value.memory.allocations);
            try requested.append(a, value.memory.requested_bytes);
            try peaks.append(a, value.memory.peak_live_bytes);
        }
        try summaries.append(a, .{ .case = case.id, .phase = @fromBackingInt(@intCast(phase)), .wall_ns = try stats(a, times.items), .allocations = try stats(a, allocations.items), .requested_bytes = try stats(a, requested.items), .peak_live_bytes = try stats(a, peaks.items) });
    };
    for (hashes.items) |hash| if (!std.mem.eql(u8, hash.sha256, try digestFile(a, io, hash.path))) return error.SourceChangedDuringRun;
    for (fixtures.items) |fixture| if (fixture.path) |path| {
        if (!std.mem.eql(u8, fixture.sha256, try digestFile(a, io, path))) return error.FixtureChangedDuringRun;
    };
    if (!std.mem.eql(u8, cli_hash, try digestFile(a, io, options.exe)) or !std.mem.eql(u8, compiler_hash, try digestFile(a, io, options.compiler)) or !std.mem.eql(u8, profiler_hash, try digestFile(a, io, args[0]))) return error.ToolChangedDuringRun;
    var json = Io.Writer.Allocating.init(a);
    try std.json.Stringify.value(.{
        .schema_version = 1,
        .version = options.version,
        .zig = builtin.zig_version_string,
        .target = options.target,
        .cpu_model = builtin.cpu.model.name,
        .kernel_release = kernel_release,
        .optimization = @tagName(builtin.mode),
        .measured_at_unix_seconds = Io.Clock.real.now(io).toSeconds(),
        .repeat = repeats,
        .method = "One preflight/warm-up per case; rotated case order. Same strict parser, execution order and input lifetime as public run, with byte-exact output checks. Preloaded/generated inputs; IO, expected output and report allocations excluded. Seven sequential phases timed with monotonic awake clock: compile, session setup, parse, feed/evaluate, parsed document release, finish/emit, cleanup. Output goes to an allocating writer. Meter wraps the process Init.gpa backing allocator; counts successful requests and positive resize/remap growth, not RSS or allocator metadata. Phase peak includes allocations already live at its start; start/end bytes are recorded and cleanup must reach zero. Debug instrumentation affects timing. Tiny CLI samples include supervised process launch, stdin/output capture, parsing, execution, teardown and scheduling; they do not isolate loader startup. No cold-cache or optimization-mode comparison.",
        .tools = .{ .compiler_sha256 = compiler_hash, .cli_sha256 = cli_hash, .profiler_sha256 = profiler_hash, .cli_version = "jqz " ++ options.version },
        .source_hashes = hashes.items,
        .fixtures = fixtures.items,
        .checks = checks.items,
        .samples = samples.items,
        .summaries = summaries.items,
        .supervised_null_cli = .{ .query = ".", .input = "null\n", .expected_output = "null\n", .elapsed_ns = launch_samples.items, .summary_ns = try stats(a, launch_samples.items) },
    }, .{ .whitespace = .indent_2 }, &json.writer);
    try json.writer.writeByte('\n');
    if (out) |path| {
        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try S.files.writeAtomic(io, .{ .path = path, .replace = true }, &.{json.written()});
    } else try Io.File.stdout().writeStreamingAll(io, json.written());
    std.debug.print("profile: {d} cases, {d} phase samples, {d} supervised launches; all outputs match\n", .{ cases.len, samples.items.len * phase_count, repeats });
}

fn ordinary(a: A, source: []const u8, input: []const u8) ![]const u8 {
    var diagnostic: engine.Diagnostic = .{};
    var program = try engine.Program.compile(a, source, &diagnostic);
    defer program.deinit();
    var output = Io.Writer.Allocating.init(a);
    defer output.deinit();
    try program.run(a, input, &output.writer, &diagnostic);
    return output.toOwnedSlice();
}

fn finishPhase(meter: *const Meter, before: Meter.Counters, start: Io.Timestamp, io: Io, name: PhaseName) Phase {
    return .{ .name = name, .elapsed_ns = @intCast(start.untilNow(io, .awake).nanoseconds), .memory = meter.end(before) };
}

fn runPhases(backing: A, io: Io, case: Case, input: []const u8, expected: []const u8, iteration: usize) !Sample {
    var meter: Meter = .{ .backing = backing };
    const a = meter.allocator();
    var diagnostic: engine.Diagnostic = .{};
    var result: Sample = .{ .case = case.id, .iteration = iteration, .phases = undefined };
    var before = meter.begin();
    var start = Io.Clock.awake.now(io);
    var program = try engine.Program.compile(a, case.query, &diagnostic);
    var program_live = true;
    defer if (program_live) program.deinit();
    result.phases[0] = finishPhase(&meter, before, start, io, .compile_query);
    before = meter.begin();
    start = Io.Clock.awake.now(io);
    var output = Io.Writer.Allocating.init(a);
    var output_live = true;
    defer if (output_live) output.deinit();
    const execution = try engine.Execution.init(a, program.stages, program.patterns, &output.writer, &diagnostic, .{});
    var execution_live = true;
    defer if (execution_live) execution.deinit();
    result.phases[1] = finishPhase(&meter, before, start, io, .session_setup);
    before = meter.begin();
    start = Io.Clock.awake.now(io);
    const parsed = try engine.input.parse(a, input, &diagnostic);
    var parsed_live = true;
    defer if (parsed_live) parsed.deinit();
    result.phases[2] = finishPhase(&meter, before, start, io, .parse_document);
    before = meter.begin();
    start = Io.Clock.awake.now(io);
    // This writer is owned and allocating: its only write failure is OOM.
    execution.push(parsed.value) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    result.phases[3] = finishPhase(&meter, before, start, io, .feed_evaluate);
    before = meter.begin();
    start = Io.Clock.awake.now(io);
    parsed.deinit();
    parsed_live = false;
    result.phases[4] = finishPhase(&meter, before, start, io, .release_document);
    before = meter.begin();
    start = Io.Clock.awake.now(io);
    execution.finish() catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    result.phases[5] = finishPhase(&meter, before, start, io, .finish_emit);
    if (!std.mem.eql(u8, expected, output.written())) return error.ProfileOutputMismatch;
    before = meter.begin();
    start = Io.Clock.awake.now(io);
    execution.deinit();
    execution_live = false;
    output.deinit();
    output_live = false;
    program.deinit();
    program_live = false;
    result.phases[6] = finishPhase(&meter, before, start, io, .cleanup);
    if (meter.counters.live_bytes != 0) return error.ProfileAllocationLeak;
    return result;
}

fn launch(a: A, io: Io) !u64 {
    const start = Io.Clock.awake.now(io);
    const report = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = &.{ options.exe, "." } }, .timeout_ms = 5000, .stdout_limit = 4096, .stderr_limit = 4096 }, .stdin = "null\n" });
    defer report.deinit(a);
    const elapsed: u64 = @intCast(start.untilNow(io, .awake).nanoseconds);
    try S.Diagnostic.expectExit(report, .{ .assertion = "profile supervised null CLI", .code = 0 });
    if (!std.mem.eql(u8, report.stdout, "null\n") or report.stderr.len != 0) return error.ProfileOutputMismatch;
    return elapsed;
}

// procfs files can report a zero stat size while providing nonempty contents.
fn readStream(a: A, io: Io, path: []const u8) ![]const u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(4096));
}

fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn digestFile(a: A, io: Io, path: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(try S.files.sha256(io, path), .lower));
}
fn stats(a: A, input: []const u64) !Stats {
    const values = try a.dupe(u64, input);
    defer a.free(values);
    std.sort.pdq(u64, values, {}, std.sort.asc(u64));
    const mid = values.len / 2;
    return .{ .min = values[0], .median = if (values.len % 2 == 1) values[mid] else values[mid - 1] + (values[mid] - values[mid - 1]) / 2, .max = values[values.len - 1] };
}

test "profile streams kernel metadata from zero-sized virtual files" {
    const t = std.testing;
    const release = try readStream(t.allocator, t.io, "/proc/sys/kernel/osrelease");
    defer t.allocator.free(release);
    try t.expect(std.mem.trim(u8, release, " \r\n").len > 0);
}

test "profile phases match ordinary output and release every tracked allocation" {
    const t = std.testing;
    const case: Case = .{ .id = "test", .query = "unique(.) | collect", .fixture = .tiny };
    const sample = try runPhases(t.allocator, t.io, case, "[[2],[1],[2]]", "[[[1],[2]]]\n", 0);
    try t.expect(sample.phases[2].memory.allocations > 0);
    try t.expect(sample.phases[3].memory.requested_bytes > 0);
    try t.expect(sample.phases[4].memory.end_live_bytes < sample.phases[4].memory.start_live_bytes);
    for (sample.phases[1..], sample.phases[0 .. phase_count - 1]) |next, previous| try t.expectEqual(previous.memory.end_live_bytes, next.memory.start_live_bytes);
    try t.expectEqual(@as(u64, 0), sample.phases[6].memory.end_live_bytes);
    try t.expectError(error.ProfileOutputMismatch, runPhases(t.allocator, t.io, case, "[1]", "wrong", 0));
    try t.expectError(error.DuplicateField, runPhases(t.allocator, t.io, case, "{\"x\":1,\"x\":2}", "", 0));
}

test "profile allocation failures clean up all engine phase owners" {
    const t = std.testing;
    const case: Case = .{ .id = "test", .query = "unique(.) | collect", .fixture = .tiny };
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    _ = try runPhases(baseline.allocator(), t.io, case, "[[2],[1],[2]]", "[[[1],[2]]]\n", 0);
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |at| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = at, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, runPhases(failing.allocator(), t.io, case, "[[2],[1],[2]]", "[[[1],[2]]]\n", 0));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "profile summaries and shared fixture cardinalities are checked" {
    const t = std.testing;
    var values = [_]u64{ 9, 3, 1, 7 };
    try t.expectEqualDeep(Stats{ .min = 1, .median = 5, .max = 9 }, try stats(t.allocator, &values));
    try t.expectEqualSlices(u64, &.{ 9, 3, 1, 7 }, &values);
    const input = try generated.generate(t.allocator, .backend, 3);
    defer t.allocator.free(input);
    var diagnostic: engine.Diagnostic = .{};
    const parsed = try engine.input.parse(t.allocator, input, &diagnostic);
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 3), parsed.value.object.get("http").?.array.items.len);
    try t.expectEqual(@as(usize, 3), parsed.value.object.get("fixtures").?.array.items.len);
    try t.expectError(error.InvalidGeneratedRowCount, generated.generate(t.allocator, .commands, 0));
}

test {
    _ = @import("parser_study.zig");
    _ = @import("study_support.zig");
    _ = @import("invocation_study.zig");
}
