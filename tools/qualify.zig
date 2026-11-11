//! Reproducible qualification from sanitized data. Never reads session storage
//! or executes shell text; process/file ownership comes from test-support.
const std = @import("std");
const builtin = @import("builtin");
const S = @import("test_support");
const number = @import("exact_number");
const options = @import("qualification_options");
const A = std.mem.Allocator;
const Io = std.Io;
const V = std.json.Value;

const Expected = struct { exit_code: i32 = 0, values: []const V = &.{}, raw: ?[]const u8 = null };
const Invocation = struct { query: []const u8, flags: []const []const u8 = &.{}, files: []const []const u8 = &.{}, stdin: ?[]const u8 = null, expected: Expected };
const Origin = struct { session: []const u8, record: usize, prefix: []const u8 = "" };
const Scope = enum { observed, component, probe, scale };
const Classification = enum { equivalent, intentional, unsupported };
const Case = struct { id: []const u8, scope: Scope = .observed, classification: Classification = .equivalent, origin: Origin, jq: Invocation, jqz: ?Invocation = null, measure: bool = true, note: []const u8 = "" };
const FixtureSpec = struct { id: []const u8, path: ?[]const u8 = null, generator: ?enum { commands, backend } = null, rows: usize = 0 };
const Manifest = struct { schema_version: u32, fixtures: []const FixtureSpec, cases: []const Case };
const Source = struct { session: []const u8, record: usize, query: []const u8, flags: []const []const u8 };
const Provenance = struct { schema_version: u32, sessions: struct { backend: []const u8, compiler: []const u8 }, origins: []const Source };
const Fixture = struct { id: []const u8, path: []const u8, label: []const u8, rows: usize, bytes: usize, sha256: []const u8 };
const Tool = struct { name: []const u8, path: []const u8, version: []const u8, sha256: []const u8 };
const Outcome = struct { exit_code: i32, stdout_bytes: usize, stdout_sha256: []const u8, elapsed_ns: u64, peak_rss_bytes: ?u64 };
const Review = struct { id: []const u8, scope: Scope, classification: Classification, origin: Origin, original_query: []const u8, note: []const u8, reference_invocation: Invocation, candidate_invocation: ?Invocation, jq: Outcome, jqz: ?Outcome, measured: bool };
const Sample = struct { case: []const u8, tool: []const u8, iteration: usize, elapsed_ns: u64, peak_rss_bytes: ?u64, stdout_bytes: usize, stdout_sha256: []const u8, exit_code: i32 };
const Stats = struct { samples: usize, min: u64, median: u64, max: u64 };
const Summary = struct { case: []const u8, tool: []const u8, wall_ns: Stats, peak_rss_bytes: ?Stats };
const Hash = struct { path: []const u8, sha256: []const u8 };
const Coverage = struct { observed: usize = 0, translated: usize = 0, unsupported: usize = 0, invocation_adaptations: usize = 0, components: usize = 0, semantic_probes: usize = 0, scale_cases: usize = 0, measured_cases: usize = 0 };

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.LinuxPeakRssRequired;
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var repeats: usize = 5;
    var jq_path: []const u8 = "/usr/bin/jq";
    var jq_version: []const u8 = "jq-1.7";
    var manifest_path: []const u8 = "tests/qualification/cases.json";
    var provenance_path: []const u8 = "tests/qualification/provenance.json";
    var out: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("qualify [--repeat N] [--jq PATH] [--jq-version EXACT] [--manifest FILE] [--provenance FILE] [--out FILE]\n", .{});
            return;
        }
        if (index + 1 == args.len) return error.MissingOptionValue;
        const key = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, key, "--repeat")) repeats = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--jq")) jq_path = value else if (std.mem.eql(u8, key, "--jq-version")) jq_version = value else if (std.mem.eql(u8, key, "--manifest")) manifest_path = value else if (std.mem.eql(u8, key, "--provenance")) provenance_path = value else if (std.mem.eql(u8, key, "--out")) out = value else return error.UnknownOption;
    }
    if (repeats == 0 or repeats > 20) return error.InvalidRepetitionCount;
    const manifest = try read(Manifest, a, io, manifest_path);
    const provenance = try read(Provenance, a, io, provenance_path);
    if (manifest.schema_version != 1 or provenance.schema_version != 1) return error.UnknownCorpusSchema;
    var source_hashes: std.ArrayList(Hash) = .empty;
    for ([_][]const u8{ "build.zig", "build.zig.zon", "src/main.zig", "src/root.zig", "src/parser.zig", "src/evaluator.zig", "src/execution.zig", "src/number.zig", "src/statistics.zig", "src/buffered.zig", "src/rows.zig", "src/json_order.zig", "src/collection_budget.zig", "src/diagnostic.zig", "tools/qualify.zig", manifest_path, provenance_path, "vendor/SHA256SUMS" }) |path| try source_hashes.append(a, .{ .path = path, .sha256 = try digestFile(a, io, path) });
    const tools = [_]Tool{ try pin(a, io, "jqz", options.exe, "jqz " ++ options.version), try pin(a, io, "jq", jq_path, jq_version) };
    const time = try pinVersion(a, io, "/usr/bin/time");
    const time_hash = try digestFile(a, io, "/usr/bin/time");
    var workspace = try S.Workspace.init(a, io, .{ .prefix = "jqz-qualification-" });
    defer workspace.close(.success) catch {};
    var fixtures: std.ArrayList(Fixture) = .empty;
    for (manifest.fixtures, 0..) |spec, at| {
        if (!safeId(spec.id)) return error.InvalidFixtureId;
        for (manifest.fixtures[0..at]) |previous| if (std.mem.eql(u8, spec.id, previous.id)) return error.DuplicateFixture;
        if ((spec.path == null) == (spec.generator == null)) return error.InvalidFixture;
        const bytes = if (spec.path) |path| blk: {
            if (!safePath(path)) return error.UnsafeFixturePath;
            break :blk try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024));
        } else try generate(a, spec);
        const path = if (spec.path) |path| path else try std.fs.path.join(a, &.{ workspace.path, spec.id });
        if (spec.path == null) try S.files.writeAtomic(io, .{ .path = path, .replace = false }, &.{bytes});
        try fixtures.append(a, .{ .id = spec.id, .path = path, .label = spec.path orelse spec.id, .rows = spec.rows, .bytes = bytes.len, .sha256 = try digest(a, bytes) });
    }
    var reviews: std.ArrayList(Review) = .empty;
    var samples: std.ArrayList(Sample) = .empty;
    var coverage: Coverage = .{};
    // Preflight every case against frozen expectations before timing any case.
    for (manifest.cases, 0..) |case, at| {
        for (manifest.cases[0..at]) |previous| if (std.mem.eql(u8, case.id, previous.id)) return error.DuplicateCase;
        const source = try sourceFor(provenance, case.origin);
        if (case.classification == .unsupported and (case.jqz != null or case.note.len == 0)) return error.InvalidUnsupportedCase;
        if (case.classification != .unsupported and case.jqz == null) return error.MissingTranslation;
        if ((case.classification == .intentional) != (case.scope == .probe)) return error.InvalidProbeScope;
        if (case.jqz) |own| {
            const same = try expectationsEqual(case.jq.expected, own.expected);
            if ((case.classification == .equivalent) != same) return error.InvalidEquivalenceDeclaration;
        }
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const reference = try execute(arena.allocator(), io, tools[1], case.jq, fixtures.items, case.id, false);
        const candidate = if (case.jqz) |invocation| try execute(arena.allocator(), io, tools[0], invocation, fixtures.items, case.id, false) else null;
        const measured = case.classification == .equivalent and case.measure and case.scope != .probe;
        try reviews.append(a, .{ .id = case.id, .scope = case.scope, .classification = case.classification, .origin = case.origin, .original_query = source.query, .note = case.note, .reference_invocation = case.jq, .candidate_invocation = case.jqz, .jq = try ownOutcome(a, reference), .jqz = if (candidate) |value| try ownOutcome(a, value) else null, .measured = measured });
        switch (case.scope) {
            .observed => {
                coverage.observed += 1;
                if (case.classification == .equivalent) coverage.translated += 1;
                if (case.classification == .unsupported) coverage.unsupported += 1;
                if (case.classification == .equivalent and !case.measure) coverage.invocation_adaptations += 1;
            },
            .component => coverage.components += 1,
            .probe => coverage.semantic_probes += 1,
            .scale => coverage.scale_cases += 1,
        }
        if (measured) coverage.measured_cases += 1;
    }
    for (manifest.cases, reviews.items) |case, review| {
        if (!review.measured) continue;
        for (0..repeats) |iteration| for (0..tools.len) |position| {
            const tool = tools[(position + iteration) % tools.len];
            const invocation = if (std.mem.eql(u8, tool.name, "jqz")) case.jqz.? else case.jq;
            var arena = std.heap.ArenaAllocator.init(init.gpa);
            defer arena.deinit();
            const sample = try execute(arena.allocator(), io, tool, invocation, fixtures.items, case.id, true);
            try samples.append(a, .{ .case = case.id, .tool = tool.name, .iteration = iteration, .elapsed_ns = sample.elapsed_ns, .peak_rss_bytes = sample.peak_rss_bytes, .stdout_bytes = sample.stdout_bytes, .stdout_sha256 = try a.dupe(u8, sample.stdout_sha256), .exit_code = sample.exit_code });
        };
    }
    var summaries: std.ArrayList(Summary) = .empty;
    for (reviews.items) |review| {
        if (!review.measured) continue;
        for (tools) |tool| {
            var wall: std.ArrayList(u64) = .empty;
            var rss: std.ArrayList(u64) = .empty;
            for (samples.items) |sample| if (std.mem.eql(u8, sample.case, review.id) and std.mem.eql(u8, sample.tool, tool.name)) {
                try wall.append(a, sample.elapsed_ns);
                if (sample.peak_rss_bytes) |value| try rss.append(a, value);
            };
            try summaries.append(a, .{ .case = review.id, .tool = tool.name, .wall_ns = stats(wall.items), .peak_rss_bytes = if (rss.items.len != 0) stats(rss.items) else null });
        }
    }
    var fixture_evidence: std.ArrayList(struct { id: []const u8, input: []const u8, rows: usize, bytes: usize, sha256: []const u8 }) = .empty;
    for (fixtures.items) |fixture| try fixture_evidence.append(a, .{ .id = fixture.id, .input = fixture.label, .rows = fixture.rows, .bytes = fixture.bytes, .sha256 = fixture.sha256 });
    for (source_hashes.items) |source| if (!std.mem.eql(u8, source.sha256, try digestFile(a, io, source.path))) return error.SourceChangedDuringRun;
    for (fixtures.items) |fixture| if (!std.mem.eql(u8, fixture.sha256, try digestFile(a, io, fixture.path))) return error.FixtureChangedDuringRun;
    for (tools) |tool| if (!std.mem.eql(u8, tool.sha256, try digestFile(a, io, tool.path))) return error.ToolChangedDuringRun;
    if (!std.mem.eql(u8, time_hash, try digestFile(a, io, "/usr/bin/time"))) return error.ToolChangedDuringRun;
    var json = Io.Writer.Allocating.init(a);
    try std.json.Stringify.value(.{
        .schema_version = 1,
        .version = options.version,
        .zig = builtin.zig_version_string,
        .target = options.target,
        .optimization = @tagName(builtin.mode),
        .cpu_model = builtin.cpu.model.name,
        .measured_at_unix_seconds = Io.Clock.real.now(io).toSeconds(),
        .repeat = repeats,
        .tools = .{ .{ .name = tools[0].name, .version = tools[0].version, .sha256 = tools[0].sha256 }, .{ .name = tools[1].name, .version = tools[1].version, .sha256 = tools[1].sha256 } },
        .gnu_time = .{ .version = time, .sha256 = time_hash },
        .method = "Frozen independent output/exit expectations; JSON objects unordered, arrays/results ordered, decimal values exact, raw bytes exact. Preflight warms both tools. Supervised monotonic wall time includes process launch/capture. GNU time child peak RSS is null when zero/unavailable. Rotated tool order. Only equivalent cases timed. Coverage is the hand-selected observed sample, not all session query sites; components/probes/scale cases are separate. No general speed claim.",
        .coverage = coverage,
        .fixtures = fixture_evidence.items,
        .source_hashes = source_hashes.items,
        .cases = reviews.items,
        .samples = samples.items,
        .summaries = summaries.items,
    }, .{ .whitespace = .indent_2 }, &json.writer);
    try json.writer.writeByte('\n');
    if (out) |path| {
        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try S.files.writeAtomic(io, .{ .path = path, .replace = true }, &.{json.written()});
    } else try Io.File.stdout().writeStreamingAll(io, json.written());
    std.debug.print("qualification: {d}/{d} observed translations; {d} unsupported; {d} probes; {d} samples\n", .{ coverage.translated, coverage.observed, coverage.unsupported, coverage.semantic_probes, samples.items.len });
}

fn read(comptime T: type, a: A, io: Io, path: []const u8) !T {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .parse_numbers = false });
}
fn sourceFor(provenance: Provenance, origin: Origin) !Source {
    var found: ?Source = null;
    for (provenance.origins) |source| if (source.record == origin.record and std.mem.eql(u8, source.session, origin.session) and std.mem.startsWith(u8, source.query, origin.prefix)) {
        if (found != null) return error.AmbiguousSourceRecord;
        found = source;
    };
    return found orelse error.MissingSourceRecord;
}
fn safePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "tests/qualification/") and std.mem.indexOf(u8, path, "..") == null and std.mem.indexOfScalar(u8, path, '\\') == null;
}
fn safeId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}
fn fixturePath(fixtures: []const Fixture, id: []const u8) ![]const u8 {
    for (fixtures) |fixture| if (std.mem.eql(u8, id, fixture.id)) return fixture.path;
    return error.UnknownFixture;
}
fn pinVersion(a: A, io: Io, path: []const u8) ![]const u8 {
    const report = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = &.{ path, "--version" } }, .timeout_ms = 5000, .stdout_limit = 4096, .stderr_limit = 4096 } });
    defer report.deinit(a);
    try S.Diagnostic.expectExit(report, .{ .assertion = "qualification tool version", .code = 0 });
    const version = std.mem.trim(u8, report.stdout, " \r\n");
    return a.dupe(u8, version[0..(std.mem.indexOfScalar(u8, version, '\n') orelse version.len)]);
}
fn pin(a: A, io: Io, name: []const u8, path: []const u8, expected: []const u8) !Tool {
    const version = try pinVersion(a, io, path);
    if (!std.mem.eql(u8, version, expected)) return error.ToolVersionMismatch;
    return .{ .name = name, .path = path, .version = version, .sha256 = try digestFile(a, io, path) };
}
fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn digestFile(a: A, io: Io, path: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(try S.files.sha256(io, path), .lower));
}
fn ownOutcome(a: A, outcome: Outcome) !Outcome {
    var result = outcome;
    result.stdout_sha256 = try a.dupe(u8, outcome.stdout_sha256);
    return result;
}
fn peakRss(stderr: []const u8) !?u64 {
    const prefix = "jqz_qualification_peak_rss_kib=";
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    var found: ?u64 = null;
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        if (found != null) return error.DuplicatePeakRss;
        found = try std.fmt.parseInt(u64, std.mem.trim(u8, line[prefix.len..], " \r"), 10);
    };
    const kib = found orelse return error.PeakRssUnavailable;
    return if (kib == 0) null else try std.math.mul(u64, kib, 1024);
}
fn execute(a: A, io: Io, tool: Tool, invocation: Invocation, fixtures: []const Fixture, id: []const u8, measured: bool) !Outcome {
    var argv: std.ArrayList([]const u8) = .empty;
    if (measured) try argv.appendSlice(a, &.{ "/usr/bin/time", "-f", "jqz_qualification_peak_rss_kib=%M", "--" });
    try argv.append(a, tool.path);
    if (std.mem.eql(u8, tool.name, "jq")) try argv.append(a, "-c");
    try argv.appendSlice(a, invocation.flags);
    try argv.append(a, invocation.query);
    for (invocation.files) |file| try argv.append(a, try fixturePath(fixtures, file));
    const start = Io.Clock.awake.now(io);
    const report = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = argv.items }, .timeout_ms = 10000, .stdout_limit = 16 * 1024 * 1024, .stderr_limit = 8192 }, .stdin = invocation.stdin });
    defer report.deinit(a);
    const elapsed = start.untilNow(io, .awake).nanoseconds;
    const label = try std.fmt.allocPrint(a, "{s}/{s}", .{ id, tool.name });
    try S.Diagnostic.expectExit(report, .{ .assertion = label, .code = invocation.expected.exit_code });
    validateOutput(a, report.stdout, invocation.expected) catch |err| {
        std.debug.print("{s}: {s}; stdout: {s}\n", .{ label, @errorName(err), report.stdout[0..@min(2048, report.stdout.len)] });
        return err;
    };
    return .{ .exit_code = S.command.code(report.term.?), .stdout_bytes = report.stdout.len, .stdout_sha256 = try digest(a, report.stdout), .elapsed_ns = if (measured) @intCast(elapsed) else 0, .peak_rss_bytes = if (measured) try peakRss(report.stderr) else null };
}
fn validateOutput(a: A, stdout: []const u8, expected: Expected) !void {
    if (expected.raw) |raw| {
        if (!std.mem.eql(u8, stdout, raw)) return error.RawOutputMismatch;
        return;
    }
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.peek() != null) return error.BlankResultLine;
            continue;
        }
        if (index == expected.values.len) return error.TooManyResults;
        const value = try std.json.parseFromSliceLeaky(V, a, line, .{ .parse_numbers = false });
        if (!try equal(value, expected.values[index], 0)) return error.JsonOutputMismatch;
        index += 1;
    }
    if (index != expected.values.len) return error.TooFewResults;
}
fn expectationsEqual(a: Expected, b: Expected) !bool {
    if (a.exit_code != b.exit_code) return false;
    if (a.raw) |raw| return b.raw != null and std.mem.eql(u8, raw, b.raw.?);
    if (b.raw != null or a.values.len != b.values.len) return false;
    for (a.values, b.values) |lhs, rhs| if (!try equal(lhs, rhs, 0)) return false;
    return true;
}
fn equal(a: V, b: V, depth: usize) !bool {
    if (depth > 128) return error.EvidenceTooDeep;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .string => |value| std.mem.eql(u8, value, b.string),
        .number_string => |value| (try number.compare(value, b.number_string)) == .eq,
        .array => |value| blk: {
            if (value.items.len != b.array.items.len) break :blk false;
            for (value.items, b.array.items) |lhs, rhs| if (!try equal(lhs, rhs, depth + 1)) break :blk false;
            break :blk true;
        },
        .object => |value| blk: {
            if (value.count() != b.object.count()) break :blk false;
            for (value.keys(), value.values()) |key, child| if (!try equal(child, b.object.get(key) orelse break :blk false, depth + 1)) break :blk false;
            break :blk true;
        },
        .integer, .float => unreachable,
    };
}
fn stats(values: []u64) Stats {
    std.debug.assert(values.len != 0);
    std.sort.pdq(u64, values, {}, struct {
        fn less(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.less);
    const middle = values.len / 2;
    return .{ .samples = values.len, .min = values[0], .median = if (values.len % 2 == 1) values[middle] else values[middle - 1] + (values[middle] - values[middle - 1]) / 2, .max = values[values.len - 1] };
}
fn generate(a: A, spec: FixtureSpec) ![]const u8 {
    if (spec.rows == 0 or spec.rows > 100000) return error.InvalidGeneratedRowCount;
    var output = Io.Writer.Allocating.init(a);
    if (spec.generator.? == .commands) {
        try output.writer.writeByte('[');
        for (0..spec.rows) |index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"argv\":[\"bin/z_llvm\",\"compile\",\"unit.zig\"],\"cwd\":\"workspace\",\"returncode\":0,\"wall_ns\":1000000,\"timeout_ms\":5000,\"stdout\":\"\",\"stderr\":\"\",\"outcome\":\"exited\",\"actual_returncode\":0}");
        }
        try output.writer.writeAll("]\n");
    } else {
        try output.writer.writeAll("{\"passed\":true,\"cleanup_passed\":true,\"result\":{\"code\":0},\"http\":[");
        for (0..spec.rows) |index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"case\":\"check\",\"path\":\"/health\",\"status\":200}");
        }
        try output.writer.writeAll("],\"fixtures\":[");
        for (0..spec.rows) |index| {
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.writeAll("{\"case\":\"compile\",\"result\":{\"code\":0}}");
        }
        try output.writer.writeAll("]}\n");
    }
    return output.written();
}

test "qualification comparison preserves decimal precision and array order" {
    const t = std.testing;
    const a = try std.json.parseFromSlice(V, t.allocator, "{\"n\":9007199254740993,\"a\":[1,2]}", .{ .parse_numbers = false });
    defer a.deinit();
    const b = try std.json.parseFromSlice(V, t.allocator, "{\"a\":[1.0,2e0],\"n\":9007199254740993.0}", .{ .parse_numbers = false });
    defer b.deinit();
    const c = try std.json.parseFromSlice(V, t.allocator, "{\"n\":9007199254740992,\"a\":[1,2]}", .{ .parse_numbers = false });
    defer c.deinit();
    const d = try std.json.parseFromSlice(V, t.allocator, "{\"n\":9007199254740993,\"a\":[2,1]}", .{ .parse_numbers = false });
    defer d.deinit();
    try t.expect(try equal(a.value, b.value, 0));
    try t.expect(!try equal(a.value, c.value, 0));
    try t.expect(!try equal(a.value, d.value, 0));
    try t.expect(!safePath("tests/qualification/../private.json"));
}
test "qualification RSS parsing distinguishes missing zero malformed and valid values" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 2048), try peakRss("noise\njqz_qualification_peak_rss_kib=2\n"));
    try t.expectEqual(@as(?u64, null), try peakRss("jqz_qualification_peak_rss_kib=0\n"));
    try t.expectError(error.PeakRssUnavailable, peakRss("noise"));
    try t.expectError(error.InvalidCharacter, peakRss("jqz_qualification_peak_rss_kib=bad\n"));
    try t.expectError(error.DuplicatePeakRss, peakRss("jqz_qualification_peak_rss_kib=0\njqz_qualification_peak_rss_kib=1\n"));
}

test "qualification output checks enforce result cardinality protocol and exact raw bytes" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const expected: Expected = .{ .values = &.{.{ .number_string = "1.0" }} };
    try validateOutput(arena.allocator(), "1\n", expected);
    try t.expectError(error.TooFewResults, validateOutput(arena.allocator(), "", expected));
    try t.expectError(error.TooManyResults, validateOutput(arena.allocator(), "1\n2\n", expected));
    try t.expectError(error.BlankResultLine, validateOutput(arena.allocator(), "\n1\n", expected));
    try t.expectError(error.BlankResultLine, validateOutput(arena.allocator(), "1\n\n", expected));
    try validateOutput(arena.allocator(), "\n", .{ .raw = "\n" });
    try t.expectError(error.RawOutputMismatch, validateOutput(arena.allocator(), "false\n", .{ .raw = "false" }));
    try t.expect(!safeId("../escape"));
}
