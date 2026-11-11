const std = @import("std");
const S = @import("test_support");
const engine = @import("profile_engine");
const options = @import("profile_options");
const M = @import("study_support.zig");
const generated = @import("fixtures.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const query = "{passed,cleanup_passed,result,http_count:length(.http)}";
const documents = 16;

fn invoke(a: A, io: Io, argv: []const []const u8, input: []const u8, expected: []const u8) !u64 {
    const start = Io.Clock.awake.now(io);
    const report = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = argv }, .timeout_ms = 5000, .stdout_limit = 256 * 1024, .stderr_limit = 8192 }, .stdin = input });
    defer report.deinit(a);
    const elapsed = M.elapsed(start, io);
    try S.Diagnostic.expectExit(report, .{ .assertion = "invocation experiment", .code = 0 });
    if (!std.mem.eql(u8, report.stdout, expected) or report.stderr.len != 0) return error.InvocationOutputMismatch;
    return elapsed;
}

fn reused(a: A, io: Io, input: []const u8, expected: []const u8, one_session: bool, iteration: usize) !M.Record {
    var meter: M.Meter = .{ .backing = a };
    const allocator = meter.allocator();
    const before = meter.begin();
    const start = Io.Clock.awake.now(io);
    var diagnostic: engine.Diagnostic = .{};
    var program = try engine.Program.compile(allocator, query, &diagnostic);
    var program_live = true;
    defer if (program_live) program.deinit();
    var output = Io.Writer.Allocating.init(allocator);
    var output_live = true;
    defer if (output_live) output.deinit();
    if (one_session) {
        var stream = try program.start(allocator, &output.writer, &diagnostic, .{});
        defer stream.deinit();
        for (0..documents) |_| _ = try stream.feed(input);
        try stream.finish();
    } else for (0..documents) |_| try program.run(allocator, input, &output.writer, &diagnostic);
    if (!std.mem.eql(u8, expected, output.written())) return error.InvocationOutputMismatch;
    output.deinit();
    output_live = false;
    program.deinit();
    program_live = false;
    const duration = M.elapsed(start, io);
    if (meter.counters.live_bytes != 0) return error.StudyAllocationLeak;
    return .{ .case = "sixteen-reports", .variant = if (one_session) "program-one-session" else "program-reused-sessions", .iteration = iteration, .elapsed_ns = duration, .memory = meter.end(before) };
}

pub fn run(init: std.process.Init, repeat: usize, out: ?[]const u8, reference_cli: ?[]const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var guard = try M.Run.init(a, io, args[0], &.{ "tools/invocation_study.zig", "tools/launch_fixture.zig", "tests/qualification/backend.json" });
    try guard.tool(options.exit_probe);
    try guard.tool(options.echo_probe);
    if (reference_cli) |path| try guard.tool(path);
    const source = try Io.Dir.cwd().readFileAlloc(io, "tests/qualification/backend.json", a, .limited(4096));
    var diagnostic: engine.Diagnostic = .{};
    const parsed = try engine.input.parse(a, source, &diagnostic);
    defer parsed.deinit();
    const input = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    var program = try engine.Program.compile(a, query, &diagnostic);
    defer program.deinit();
    var one = Io.Writer.Allocating.init(a);
    try program.run(a, input, &one.writer, &diagnostic);
    var batch = Io.Writer.Allocating.init(a);
    var expected = Io.Writer.Allocating.init(a);
    for (0..documents) |_| {
        try batch.writer.writeAll(input);
        try batch.writer.writeByte('\n');
        try expected.writer.writeAll(one.written());
    }
    var workspace = try S.Workspace.init(a, io, .{ .prefix = "jqz-invocation-" });
    defer workspace.close(.success) catch {};
    const path = try std.fs.path.join(a, &.{ workspace.path, "report.json" });
    try S.files.writeAtomic(io, .{ .path = path, .replace = false }, &.{input});
    var files: std.ArrayList([]const u8) = .empty;
    try files.appendSlice(a, &.{ options.exe, query });
    for (0..documents) |_| try files.append(a, path);
    const Tiny = struct { name: []const u8, argv: []const []const u8, input: []const u8, expected: []const u8 };
    var tiny: std.ArrayList(Tiny) = .empty;
    try tiny.appendSlice(a, &.{
        .{ .name = "empty-zig", .argv = &.{options.exit_probe}, .input = "", .expected = "" },
        .{ .name = "matched-echo", .argv = &.{options.echo_probe}, .input = "null\n", .expected = "null\n" },
        .{ .name = "version", .argv = &.{ options.exe, "--version" }, .input = "", .expected = "jqz " ++ options.version ++ "\n" },
        .{ .name = "null", .argv = &.{ options.exe, "." }, .input = "null\n", .expected = "null\n" },
        .{ .name = "null-control", .argv = &.{ options.exe, "." }, .input = "null\n", .expected = "null\n" },
    });
    if (reference_cli) |reference| try tiny.append(a, .{ .name = "reference-null", .argv = &.{ reference, "." }, .input = "null\n", .expected = "null\n" });
    var records: std.ArrayList(M.Record) = .empty;
    for (0..repeat + 1) |round| {
        for (0..tiny.items.len) |step| {
            const case = tiny.items[(round + step) % tiny.items.len];
            const duration = try invoke(a, io, case.argv, case.input, case.expected);
            if (round != 0) try records.append(a, .{ .case = "tiny-launch", .variant = case.name, .iteration = round - 1, .elapsed_ns = duration, .memory = null });
        }
        for (0..5) |step| {
            const variant = (round + step) % 5;
            var record: M.Record = .{ .case = "sixteen-reports", .variant = undefined, .iteration = round -| 1, .elapsed_ns = 0, .memory = null };
            switch (variant) {
                0 => {
                    record.variant = "separate-processes";
                    for (0..documents) |_| record.elapsed_ns += try invoke(a, io, &.{ options.exe, query }, input, one.written());
                },
                1 => {
                    record.variant = "multi-file";
                    record.elapsed_ns = try invoke(a, io, files.items, "", expected.written());
                },
                2 => {
                    record.variant = "ndjson";
                    record.elapsed_ns = try invoke(a, io, &.{ options.exe, "--ndjson", query }, batch.written(), expected.written());
                },
                3, 4 => record = try reused(init.gpa, io, input, expected.written(), variant == 4, round -| 1),
                else => unreachable,
            }
            if (round != 0) try records.append(a, record);
        }
    }
    const LargeCheck = struct { case: []const u8, query: []const u8, bytes: usize, input_sha256: []const u8, output_sha256: []const u8 };
    var large_checks: std.ArrayList(LargeCheck) = .empty;
    if (reference_cli) |reference| {
        for ([_]generated.Kind{ .commands, .backend }) |kind| {
            const bytes = try generated.generate(a, kind, if (kind == .commands) 2837 else 10000);
            const expression = if (kind == .commands) "{commands:length(.),last:.[-1].argv}" else query;
            var compiled = try engine.Program.compile(a, expression, &diagnostic);
            defer compiled.deinit();
            var wanted = Io.Writer.Allocating.init(a);
            try compiled.run(a, bytes, &wanted.writer, &diagnostic);
            const id = if (kind == .commands) "large-commands-cli" else "large-backend-cli";
            try large_checks.append(a, .{ .case = id, .query = expression, .bytes = bytes.len, .input_sha256 = try M.digest(a, bytes), .output_sha256 = try M.digest(a, wanted.written()) });
            for (0..repeat + 1) |round| for (0..3) |step| {
                const variant = (round + step) % 3;
                const binary = if (variant == 0) reference else options.exe;
                const duration = try invoke(a, io, &.{ binary, expression }, bytes, wanted.written());
                if (round != 0) try records.append(a, .{ .case = id, .variant = if (variant == 0) "reference" else if (variant == 1) "current" else "current-control", .iteration = round - 1, .elapsed_ns = duration, .memory = null });
            };
        }
    }
    try guard.publish("invocation", repeat, "One warm-up; rotated variants. Native Debug empty/echo baselines use the same std.process.Init type and buffering conventions; their work differs explicitly. Parent supervised wall time includes child lifetime and IO capture, excludes output validation/report release. Separate-process time sums identical per-document intervals. No loader-only or child self-time claim. Sixteen identical compact reports, same projection without aggregates/early stops, byte-identical ordered output. Reused Program intervals include one compile, all feeds/outputs and cleanup; in-process validation is included. Optional reference CLI also enables matched large command/backend input comparisons, checking both outputs against ordinary execution. Parent allocator/RSS are not inferred from child intervals (memory=null).", records.items, .{
        .documents = documents,
        .query = query,
        .input_sha256 = try M.digest(a, input),
        .output_sha256 = try M.digest(a, expected.written()),
        .output_bytes = expected.written().len,
        .reference_cli = reference_cli,
        .large_checks = large_checks.items,
    }, out);
}

test "invocation reuse variants preserve all documents and release owners" {
    const t = std.testing;
    const input = "{\"passed\":true,\"cleanup_passed\":false,\"result\":null,\"http\":[]}";
    var expected = Io.Writer.Allocating.init(t.allocator);
    defer expected.deinit();
    for (0..documents) |_| try expected.writer.writeAll("{\"passed\":true,\"cleanup_passed\":false,\"result\":null,\"http_count\":0}\n");
    for ([_]bool{ false, true }) |one_session| {
        const record = try reused(t.allocator, t.io, input, expected.written(), one_session, 0);
        try t.expectEqual(@as(u64, 0), record.memory.?.end_live_bytes);
        try t.expectError(error.InvocationOutputMismatch, reused(t.allocator, t.io, input, "bad", one_session, 0));
    }
}
