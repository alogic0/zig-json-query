//! Linux benchmark orchestration. Existing process/file helpers own capture,
//! timeouts, temporary directories and hashing. GNU time observes child peak RSS.
const std = @import("std");
const builtin = @import("builtin");
const S = @import("test_support");
const exe = @import("test_options").exe;
const A = std.mem.Allocator;
const Io = std.Io;

const Tool = struct { name: []const u8, path: []const u8, version: []const u8, sha256: []const u8 };
const Case = struct {
    name: []const u8,
    own_query: []const u8,
    jq_query: []const u8,
    fixture: enum { small, document, ndjson, precision, large },
    own_flags: []const []const u8 = &.{},
    jq_flags: []const []const u8 = &.{"-c"},
    note: []const u8 = "",
};
const cases = [_]Case{
    .{ .name = "startup", .own_query = ".", .jq_query = ".", .fixture = .small },
    .{ .name = "projection", .own_query = ".users | each | .name", .jq_query = ".users[] | .name", .fixture = .document },
    .{ .name = "filter", .own_query = ".users | each | where(.age >= 18) | {id:.id,name:.name}", .jq_query = ".users[] | select(.age >= 18) | {id:.id,name:.name}", .fixture = .document },
    .{ .name = "regex", .own_query = ".users | each | where(matches(.name, \"^A\")) | .id", .jq_query = ".users[] | select(.name | test(\"^A\")) | .id", .fixture = .document },
    .{ .name = "numeric_precision", .own_query = ".users | each | where(.id > 9007199254740992) | .id", .jq_query = ".users[] | select(.id > 9007199254740992) | .id", .fixture = .precision, .note = "Precision fixture; differing output is a semantic difference, not an equivalent performance comparison." },
    .{ .name = "ndjson", .own_query = "where(.age >= 18) | count", .jq_query = "reduce inputs as $row (0; if $row.age >= 18 then .+1 else . end)", .fixture = .ndjson, .own_flags = &.{"--ndjson"}, .jq_flags = &.{ "-c", "-n" }, .note = "Both queries count incrementally; JSON inputs are one record per line." },
    .{ .name = "large_document", .own_query = ".users | each | .id", .jq_query = ".users[] | .id", .fixture = .large, .note = "Single-document parsing; fixture has four times the requested row count." },
};
const Record = struct {
    case: []const u8,
    tool: []const u8,
    iteration: usize,
    input_bytes: usize,
    input_sha256: []const u8,
    query: []const u8,
    flags: []const []const u8,
    elapsed_ns: u64,
    peak_rss_bytes: ?u64,
    output_bytes: usize,
    output_sha256: []const u8,
    equivalent: bool,
    note: []const u8,
};
const Measurement = struct { output: []const u8, elapsed_ns: u64, peak_rss_bytes: u64 };

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.LinuxPeakRssRequired;
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var rows: usize = 10000;
    var repeat: usize = 3;
    var jq: []const u8 = "/usr/bin/jq";
    var jq_version: []const u8 = "jq-1.7";
    var jaq: ?[]const u8 = null;
    var jaq_version: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("query-bench [--rows N] [--repeat N] [--jq PATH] [--jq-version VERSION] [--jaq PATH --jaq-version VERSION] [--out FILE]\n", .{});
            return;
        }
        if (index + 1 == args.len) return error.MissingOptionValue;
        const key = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, key, "--rows")) {
            rows = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "--repeat")) {
            repeat = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, key, "--jq")) {
            jq = value;
        } else if (std.mem.eql(u8, key, "--jq-version")) {
            jq_version = value;
        } else if (std.mem.eql(u8, key, "--jaq")) {
            jaq = value;
        } else if (std.mem.eql(u8, key, "--jaq-version")) {
            jaq_version = value;
        } else if (std.mem.eql(u8, key, "--out")) {
            output_path = value;
        } else return error.UnknownOption;
    }
    if (rows == 0 or rows > 100000 or repeat == 0 or repeat > 100) return error.InvalidBenchmarkSize;
    if ((jaq == null) != (jaq_version == null)) return error.JaqPathAndPinnedVersionRequired;
    var tools: std.ArrayList(Tool) = .empty;
    try tools.append(a, try pin(a, io, "jqz", exe, "jqz 0.3.1"));
    try tools.append(a, try pin(a, io, "jq", jq, jq_version));
    if (jaq) |path| try tools.append(a, try pin(a, io, "jaq", path, jaq_version.?));
    const time_hash = try hex(a, try S.files.sha256(io, "/usr/bin/time"));
    var workspace = try S.Workspace.init(a, io, .{ .prefix = "jqz-bench-" });
    defer workspace.close(.success) catch {};
    var records: std.ArrayList(Record) = .empty;
    for (cases) |case| {
        const bytes = try fixture(a, rows, case.fixture);
        const path = try std.fs.path.join(a, &.{ workspace.path, case.name });
        try S.files.writeAtomic(io, .{ .path = path, .replace = false }, &.{bytes});
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const input_hash = try hex(a, digest);
        // One untimed warmup of the reference creates an output oracle.
        var warmup_arena = std.heap.ArenaAllocator.init(init.gpa);
        defer warmup_arena.deinit();
        const warmup = try measure(warmup_arena.allocator(), io, tools.items[0], case, path);
        for (0..repeat) |iteration| {
            // Rotate order to reduce systematic first/last process bias.
            for (0..tools.items.len) |position| {
                const tool = tools.items[(position + iteration) % tools.items.len];
                var sample_arena = std.heap.ArenaAllocator.init(init.gpa);
                defer sample_arena.deinit();
                const sample = try measure(sample_arena.allocator(), io, tool, case, path);
                const equivalent = std.mem.eql(u8, sample.output, warmup.output);
                if (!equivalent and case.fixture != .precision) return error.BenchmarkOutputMismatch;
                std.crypto.hash.sha2.Sha256.hash(sample.output, &digest, .{});
                const own = std.mem.eql(u8, tool.name, "jqz");
                try records.append(a, .{
                    .case = case.name,
                    .tool = tool.name,
                    .iteration = iteration,
                    .input_bytes = bytes.len,
                    .input_sha256 = input_hash,
                    .query = if (own) case.own_query else case.jq_query,
                    .flags = if (own) case.own_flags else case.jq_flags,
                    .elapsed_ns = sample.elapsed_ns,
                    .peak_rss_bytes = if (sample.peak_rss_bytes == 0) null else sample.peak_rss_bytes,
                    .output_bytes = sample.output.len,
                    .output_sha256 = try hex(a, digest),
                    .equivalent = equivalent,
                    .note = case.note,
                });
            }
        }
    }
    var json = std.Io.Writer.Allocating.init(a);
    try std.json.Stringify.value(.{
        .schema_version = 1,
        .zig = builtin.zig_version_string,
        .target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi),
        .optimization = @tagName(builtin.mode),
        .rows = rows,
        .repeat = repeat,
        .measured_at_unix_seconds = Io.Clock.real.now(io).toSeconds(),
        .tools = tools.items,
        .gnu_time_sha256 = time_hash,
        .method = "Monotonic wall time includes process supervision and capture; GNU time %M is child peak RSS (null if the OS reports zero). One reference warmup per case; rotated tool order. Non-precision output mismatches fail the run. Compare only equivalent=true results. No throughput advantage is claimed.",
        .skipped = if (jaq == null) @as([]const []const u8, &.{"jaq: not configured; supply --jaq PATH --jaq-version EXACT_VERSION"}) else &.{},
        .results = records.items,
    }, .{ .whitespace = .indent_2 }, &json.writer);
    try json.writer.writeByte('\n');
    if (output_path) |path| {
        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try S.files.writeAtomic(io, .{ .path = path, .replace = true }, &.{json.written()});
    } else try Io.File.stdout().writeStreamingAll(io, json.written());
}

fn pin(a: A, io: Io, name: []const u8, path: []const u8, expected: []const u8) !Tool {
    const report = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = &.{ path, "--version" } }, .timeout_ms = 5000, .stdout_limit = 4096, .stderr_limit = 4096 } });
    defer report.deinit(a);
    if (!report.success()) {
        std.debug.print("benchmark tool {s} is unavailable at {s}\n", .{ name, path });
        return error.BenchmarkToolUnavailable;
    }
    const version = std.mem.trim(u8, report.stdout, " \t\r\n");
    if (!std.mem.eql(u8, version, expected)) {
        std.debug.print("{s}: expected version {s}, found {s}\n", .{ name, expected, version });
        return error.BenchmarkVersionMismatch;
    }
    return .{ .name = name, .path = path, .version = try a.dupe(u8, version), .sha256 = try hex(a, try S.files.sha256(io, path)) };
}

fn measure(a: A, io: Io, tool: Tool, case: Case, path: []const u8) !Measurement {
    const own = std.mem.eql(u8, tool.name, "jqz");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "/usr/bin/time", "-f", "json_query_peak_rss_kib=%M", "--", tool.path });
    try argv.appendSlice(a, if (own) case.own_flags else case.jq_flags);
    try argv.appendSlice(a, &.{ if (own) case.own_query else case.jq_query, path });
    const start = Io.Clock.awake.now(io);
    const report = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = argv.items }, .timeout_ms = 60000, .stdout_limit = 32 * 1024 * 1024, .stderr_limit = 8192 } });
    const elapsed = start.untilNow(io, .awake).nanoseconds;
    if (!report.success()) {
        std.debug.print("benchmark {s}/{s} failed: {s}\n", .{ case.name, tool.name, report.stderr });
        return error.BenchmarkFailed;
    }
    const prefix = "json_query_peak_rss_kib=";
    const at = std.mem.lastIndexOf(u8, report.stderr, prefix) orelse return error.PeakRssUnavailable;
    const text = std.mem.trim(u8, report.stderr[at + prefix.len ..], " \r\n");
    const kib = try std.fmt.parseInt(u64, text, 10);
    return .{ .output = report.stdout, .elapsed_ns = @intCast(elapsed), .peak_rss_bytes = kib * 1024 };
}

fn hex(a: A, digest: [32]u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

fn fixture(a: A, rows: usize, kind: @FieldType(Case, "fixture")) ![]const u8 {
    if (kind == .small) return "null\n";
    var writer = Io.Writer.Allocating.init(a);
    const count = if (kind == .large) rows * 4 else if (kind == .precision) 8 else rows;
    if (kind != .ndjson) try writer.writer.writeAll("{\"users\":[");
    for (0..count) |index| {
        if (index != 0 and kind != .ndjson) try writer.writer.writeByte(',');
        const id = if (kind == .precision) 9007199254740990 + index else index;
        try writer.writer.print("{{\"id\":{d},\"name\":\"{s}\",\"age\":{d}}}", .{ id, if (index % 2 == 0) "Ada" else "Ben", index % 80 });
        if (kind == .ndjson) try writer.writer.writeByte('\n');
    }
    if (kind != .ndjson) try writer.writer.writeAll("]}\n");
    return writer.written();
}
