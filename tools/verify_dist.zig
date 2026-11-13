//! Explicit standalone-package qualification. Never invoked by the test target.
const std = @import("std");
const builtin = @import("builtin");
const S = @import("test_support");
const C = @import("dist_checks.zig");
const W = @import("dist_workspace.zig");
const options = @import("dist_options");
const A = std.mem.Allocator;
const Io = std.Io;
const Env = std.process.Environ.Map;
const capture_limit = 8 * 1024 * 1024;

const Tool = struct { path: []const u8, version: []const u8, sha256: []const u8 };
const Command = struct {
    label: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    global_cache: ?[]const u8,
    local_cache: ?[]const u8,
    package_dir: ?[]const u8,
    stdout_log: ?[]const u8,
    stderr_log: ?[]const u8,
    outcome: []const u8,
    exit_code: ?i32,
    cleanup_error: ?[]const u8,
    success: bool,
};
const Quarantine = struct { original: []const u8, moved: ?[]const u8 };
const Artifact = struct { path: []const u8, bytes: u64, sha256: []const u8 };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var requested: []const u8 = "zig-out/verify-dist/evidence.json";
    var timeout: u32 = 600_000;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--help")) {
            std.debug.print("verify-dist [--out FILE] [--timeout-ms N]\nNative x86_64 Linux Debug only. Retains archive, manifest, corpus replay and bounded command logs beside FILE; removes its owned temporary workspace.\n", .{});
            return;
        }
        if (index + 1 >= args.len) return error.MissingOptionValue;
        if (std.mem.eql(u8, args[index], "--out")) requested = args[index + 1] else if (std.mem.eql(u8, args[index], "--timeout-ms")) timeout = try std.fmt.parseInt(u32, args[index + 1], 10) else return error.UnknownOption;
    }
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64 or builtin.mode != .debug or !options.native_requested) return error.NativeX86LinuxDebugRequired;
    if (timeout == 0 or timeout > 3_600_000) return error.InvalidTimeout;
    const root = try Io.Dir.cwd().realPathFileAlloc(io, options.root, a);
    const out = try C.safeOutput(a, io, root, requested);
    const parent = std.fs.path.dirname(out).?;
    try Io.Dir.cwd().createDirPath(io, parent);
    var random: [12]u8 = undefined;
    io.random(&random);
    const artifacts = try C.join(a, parent, try a.print("run-{s}", .{std.fmt.bytesToHex(random, .lower)}));
    try Io.Dir.cwd().createDir(io, artifacts, .fromMode(0o700));
    var env = try init.environ_map.clone(a);
    try env.put("PATH", "/usr/bin:/bin");
    var runner: Runner = .{ .a = a, .io = io, .root = root, .out = out, .artifacts = artifacts, .env = &env, .timeout = timeout, .started = Io.Clock.real.now(io).toSeconds() };
    // Invalidate an older successful latest report before any qualification work.
    try runner.evidence("running", null, null);
    var failure: ?anyerror = null;
    C.execute(&runner) catch |err| {
        failure = err;
    };
    var cleanup_failure: ?anyerror = null;
    if (runner.workspace) |workspace| {
        std.debug.print("verify-dist: cleanup {s}\n", .{workspace.path});
        workspace.cleanup(a, io, &runner) catch |err| {
            cleanup_failure = err;
        };
        if (cleanup_failure == null) runner.cleaned = true;
    }
    const status = if (failure == null and cleanup_failure == null and runner.completed.items.len == std.enums.values(C.Stage).len and runner.cleaned) "verified" else "failed";
    try runner.evidence(status, failure, cleanup_failure);
    std.debug.print("verify-dist: {s}; evidence {s}\n", .{ status, out });
    if (failure) |err| return err;
    if (cleanup_failure) |err| return err;
    if (!std.mem.eql(u8, status, "verified")) return error.IncompleteQualification;
}

const Runner = struct {
    a: A,
    io: Io,
    root: []const u8,
    out: []const u8,
    artifacts: []const u8,
    env: *const Env,
    timeout: u32,
    started: i64,
    workspace: ?W.Owned = null,
    cleaned: bool = false,
    current: ?C.Stage = null,
    completed: std.ArrayList(C.Stage) = .empty,
    commands: std.ArrayList(Command) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    snapshot: ?C.Snapshot = null,
    git_head: ?[]const u8 = null,
    git_status: ?[]const u8 = null,
    archive: ?Artifact = null,
    manifest: ?Artifact = null,
    cli: ?Artifact = null,
    replay: ?Artifact = null,
    replay_summary: ?C.ReplaySummary = null,
    source_tests: ?usize = null,
    consumer_tests: ?usize = null,
    quarantine: std.ArrayList(Quarantine) = .empty,
    source_env: ?Env = null,
    consumer_env: ?Env = null,
    source: []const u8 = "",
    consumer: []const u8 = "",
    source_local: []const u8 = "",
    consumer_local: []const u8 = "",

    pub fn step(self: *Runner, stage: C.Stage) !void {
        self.current = stage;
        std.debug.print("verify-dist: {s}\n", .{@tagName(stage)});
        const a = self.a;
        const io = self.io;
        switch (stage) {
            .payload => {
                self.snapshot = try C.collect(a, io, self.root);
                const path = try self.artifactPath("payload.json");
                try S.json.writeAtomic(a, io, .{ .path = path, .replace = false }, self.snapshot.?);
                self.manifest = try self.describe(path);
                self.workspace = try W.Owned.create(a, io);
                if (C.inside(self.root, self.workspace.?.path) or C.inside(self.workspace.?.path, self.out)) return error.WorkspaceInsideCheckout;
                self.source = try self.workPath("source");
                self.consumer = try self.workPath("consumer");
                self.source_local = try self.workPath("caches/source-local");
                self.consumer_local = try self.workPath("caches/consumer-local");
            },
            .tools => {
                for ([_][]const u8{ options.compiler, "/usr/bin/git", "/usr/bin/tar", "/usr/bin/gzip", "/usr/bin/jq", "/usr/bin/time", "/usr/bin/rm", "/usr/bin/rmdir" }) |path| {
                    const result = try self.command("tool-version", self.root, &.{ path, if (std.mem.eql(u8, path, options.compiler)) "version" else "--version" }, self.env);
                    const version = std.mem.trim(u8, if (result.stdout.len > 0) result.stdout else result.stderr, " \r\n");
                    if (std.mem.eql(u8, path, options.compiler) and !std.mem.eql(u8, version, builtin.zig_version_string)) return error.ToolVersionMismatch;
                    if (std.mem.eql(u8, path, "/usr/bin/tar") and std.mem.indexOf(u8, version, "GNU tar") == null) return error.GnuTarRequired;
                    if (std.mem.eql(u8, path, "/usr/bin/jq") and !std.mem.eql(u8, version, "jq-1.7")) return error.ToolVersionMismatch;
                    try self.tools.append(a, .{ .path = path, .version = version, .sha256 = try C.hashFile(a, io, path) });
                }
                // Git metadata describes the snapshot; the manifest, rather than
                // Git's tracked-file list, defines the actual archive payload.
                const head = try self.command("snapshot-head", self.root, &.{ "/usr/bin/git", "rev-parse", "HEAD" }, self.env);
                self.git_head = std.mem.trim(u8, head.stdout, " \r\n");
                const status = try self.command("snapshot-status", self.root, &.{ "/usr/bin/git", "status", "--porcelain" }, self.env);
                self.git_status = status.stdout;
            },
            .archive_first, .archive_second => {
                _ = try self.command("package", self.root, &.{ options.compiler, "build", "dist" }, self.env);
                const from = try C.join(a, self.root, "zig-out/dist/" ++ options.archive_name);
                const to = try self.artifactPath(if (stage == .archive_first) options.archive_name else "second.tar.gz");
                try Io.Dir.copyFileAbsolute(from, to, io, .{});
                if (stage == .archive_first) self.archive = try self.describe(to) else {
                    try compareFiles(io, self.archive.?.path, to);
                    try C.same(self.snapshot.?, try C.collect(a, io, self.root));
                }
            },
            .archive_validate => {
                const tar_path = try self.workPath("archive.tar");
                try self.inflate(tar_path);
                const metadata = try Io.Dir.cwd().statFile(io, tar_path, .{});
                if (metadata.size > self.snapshot.?.bytes + (self.snapshot.?.files.len + self.snapshot.?.directories.len) * 4096 + 10240) return error.ArchiveTooLarge;
                const file = try Io.Dir.cwd().openFile(io, tar_path, .{});
                defer file.close(io);
                var buffer: [65536]u8 = undefined;
                var reader = file.readerStreaming(io, &buffer);
                try C.validateTar(a, &reader.interface, self.snapshot.?);
            },
            .extract => {
                try Io.Dir.cwd().createDir(io, self.source, .fromMode(0o700));
                var dir = try Io.Dir.cwd().openDir(io, self.source, .{});
                defer dir.close(io);
                const file = try Io.Dir.cwd().openFile(io, try self.workPath("archive.tar"), .{});
                defer file.close(io);
                var buffer: [65536]u8 = undefined;
                var reader = file.readerStreaming(io, &buffer);
                try std.tar.extract(io, dir, &reader.interface, .{});
                try C.same(self.snapshot.?, try C.collect(a, io, self.source));
                try self.checkDependencies();
                _ = try self.command("source-git-init", self.source, &.{ "/usr/bin/git", "init", "-b", "main" }, self.env);
                self.source_env = try self.isolatedEnv("source", self.source_local);
                try self.assertFresh(self.source, self.source_local, self.source_env.?.get("ZIG_GLOBAL_CACHE_DIR").?);
            },
            .source_tests => {
                const result = try self.command("source-tests", self.source, &.{ options.compiler, "build", "test", "--summary", "all", "--cache-dir", self.source_local }, &self.source_env.?);
                self.source_tests = try C.testCount(result.stderr, 220);
            },
            .source_build => {
                _ = try self.command("source-build", self.source, &.{ options.compiler, "build", "--summary", "all", "--cache-dir", self.source_local }, &self.source_env.?);
                const cli = try C.join(a, self.source, "zig-out/bin/jqz");
                const version = try self.command("source-cli-version", self.source, &.{ cli, "--version" }, &self.source_env.?);
                if (!std.mem.eql(u8, version.stdout, "jqz " ++ options.version ++ "\n")) return error.PackageVersionMismatch;
                const retained = try self.artifactPath("jqz");
                try Io.Dir.copyFileAbsolute(cli, retained, io, .{});
                self.cli = try self.describe(retained);
            },
            .corpus => {
                const path = try self.artifactPath("corpus.json");
                _ = try self.command("source-corpus", self.source, &.{ options.compiler, "build", "qualify", "--cache-dir", self.source_local, "--", "--repeat", "1", "--out", path }, &self.source_env.?);
                const cases = try self.read(try C.join(a, self.source, "tests/qualification/cases.json"), 4 * 1024 * 1024);
                self.replay_summary = try C.validateReplay(a, cases, try self.read(path, 16 * 1024 * 1024), self.snapshot.?, options.version, self.cli.?.sha256);
                self.replay = try self.describe(path);
            },
            .source_files => {
                try C.same(self.snapshot.?, try C.collect(a, io, self.source));
                try Io.Dir.cwd().createDir(io, self.consumer, .fromMode(0o700));
                for ([_][]const u8{ "build.zig", "build.zig.zon", "main.zig" }) |name| {
                    const original = try C.join(a, try C.join(a, self.source, "tests/package"), name);
                    const path = try C.join(a, self.consumer, name);
                    const bytes = try self.read(original, 1024 * 1024);
                    if (std.mem.eql(u8, name, "build.zig.zon")) {
                        const needle = ".path = \"../..\"";
                        const offset = std.mem.indexOf(u8, bytes, needle) orelse return error.MissingConsumerDependency;
                        if (std.mem.indexOf(u8, bytes[offset + needle.len ..], needle) != null) return error.AmbiguousConsumerDependency;
                        try S.files.writeAtomic(io, .{ .path = path, .replace = false }, &.{ bytes[0..offset], ".path = \"../source\"", bytes[offset + needle.len ..] });
                    } else try Io.Dir.copyFileAbsolute(original, path, io, .{});
                }
                _ = try self.command("consumer-git-init", self.consumer, &.{ "/usr/bin/git", "init", "-b", "main" }, self.env);
            },
            .quarantine => {
                const quarantine_dir = try self.workPath("quarantined");
                try Io.Dir.cwd().createDir(io, quarantine_dir, .fromMode(0o700));
                for ([_][]const u8{ self.source_local, self.source_env.?.get("ZIG_GLOBAL_CACHE_DIR").?, try C.join(a, self.source, "zig-pkg"), try C.join(a, self.source, "zig-out"), try C.join(a, self.source, ".zig-cache") }, 0..) |path, n| {
                    const metadata = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                        error.FileNotFound => {
                            try self.quarantine.append(a, .{ .original = path, .moved = null });
                            continue;
                        },
                        else => return err,
                    };
                    if (metadata.kind != .directory) return error.InvalidSourceArtifact;
                    const to = try C.join(a, quarantine_dir, try a.print("{d}", .{n}));
                    try Io.Dir.renameAbsolute(path, to, io);
                    try self.quarantine.append(a, .{ .original = path, .moved = to });
                }
            },
            .isolation => {
                try self.assertQuarantined();
                self.consumer_env = try self.isolatedEnv("consumer", self.consumer_local);
                try self.assertFresh(self.consumer, self.consumer_local, self.consumer_env.?.get("ZIG_GLOBAL_CACHE_DIR").?);
            },
            .consumer_tests => {
                const result = try self.command("consumer-tests", self.consumer, &.{ options.compiler, "build", "test", "--summary", "all", "--cache-dir", self.consumer_local }, &self.consumer_env.?);
                self.consumer_tests = try C.testCount(result.stderr, 8);
                try self.assertQuarantined();
            },
            .consumer_files => {
                for ([_][]const u8{ "build.zig", "build.zig.zon", "main.zig" }) |name| {
                    const original = try self.read(try C.join(a, try C.join(a, self.source, "tests/package"), name), 1024 * 1024);
                    const actual = try self.read(try C.join(a, self.consumer, name), 1024 * 1024);
                    const expected = if (std.mem.eql(u8, name, "build.zig.zon")) try std.mem.replaceOwned(u8, a, original, ".path = \"../..\"", ".path = \"../source\"") else original;
                    if (!std.mem.eql(u8, actual, expected)) return error.ConsumerPayloadChanged;
                }
                try C.same(self.snapshot.?, try C.collect(a, io, self.source));
            },
            .unchanged => {
                try C.same(self.snapshot.?, try C.collect(a, io, self.root));
                for (self.tools.items) |tool| if (!std.mem.eql(u8, tool.sha256, try C.hashFile(a, io, tool.path))) return error.ToolChangedDuringRun;
                try compareFiles(io, self.archive.?.path, try self.artifactPath("second.tar.gz"));
                if (!std.mem.eql(u8, self.archive.?.sha256, try C.hashFile(a, io, self.archive.?.path))) return error.ArchiveChangedDuringRun;
            },
        }
        try self.completed.append(a, stage);
        try self.evidence("running", null, null);
    }

    fn workPath(self: *Runner, name: []const u8) ![]const u8 {
        return C.join(self.a, self.workspace.?.path, name);
    }
    fn artifactPath(self: *Runner, name: []const u8) ![]const u8 {
        return C.join(self.a, self.artifacts, name);
    }
    fn read(self: *Runner, path: []const u8, limit: usize) ![]const u8 {
        return S.files.read(self.a, self.io, .{ .path = path, .limit = limit });
    }
    fn describe(self: *Runner, path: []const u8) !Artifact {
        return .{ .path = path, .bytes = (try Io.Dir.cwd().statFile(self.io, path, .{})).size, .sha256 = try C.hashFile(self.a, self.io, path) };
    }

    fn isolatedEnv(self: *Runner, name: []const u8, local: []const u8) !Env {
        var env = try self.env.clone(self.a);
        const global = try self.workPath(try self.a.print("caches/{s}-global", .{name}));
        try Io.Dir.cwd().createDirPath(self.io, global);
        try Io.Dir.cwd().createDirPath(self.io, local);
        try env.put("ZIG_GLOBAL_CACHE_DIR", global);
        try env.put("ZIG_LOCAL_CACHE_DIR", local);
        try env.put("ZIG_LOCAL_PKG_DIR", "zig-pkg");
        return env;
    }

    fn assertFresh(self: *Runner, cwd: []const u8, local: []const u8, global: []const u8) !void {
        for ([_][]const u8{ local, global }) |path| {
            var dir = try Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
            defer dir.close(self.io);
            var iterator = dir.iterate();
            if (try iterator.next(self.io) != null) return error.CacheNotEmpty;
        }
        try absent(self.io, try C.join(self.a, cwd, "zig-pkg"));
        try absent(self.io, try C.join(self.a, cwd, "zig-out"));
        try absent(self.io, try C.join(self.a, cwd, ".zig-cache"));
    }

    fn assertQuarantined(self: *Runner) !void {
        if (self.quarantine.items.len != 5) return error.IncompleteQuarantine;
        for (self.quarantine.items) |entry| try absent(self.io, entry.original);
    }

    fn checkDependencies(self: *Runner) !void {
        const zon = try self.a.dupeSentinel(u8, try self.read(try C.join(self.a, self.source, "build.zig.zon"), 65536), 0);
        try C.checkDependencyPins(self.a, zon);
    }

    fn command(self: *Runner, label: []const u8, cwd: []const u8, argv: []const []const u8, env: *const Env) !S.process.Report {
        const stdout = try self.artifactPath(try self.a.print("{d:0>3}-{s}.stdout.log", .{ self.commands.items.len, label }));
        const stderr = try self.artifactPath(try self.a.print("{d:0>3}-{s}.stderr.log", .{ self.commands.items.len, label }));
        const report = S.command.runReport(self.a, self.io, .{ .run = .{ .spawn = .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = env }, .timeout_ms = self.timeout, .stdout_limit = capture_limit, .stderr_limit = capture_limit } }) catch |err| {
            try self.record(label, cwd, argv, env, null, null, @errorName(err), null, null, false);
            return err;
        };
        try S.files.writeAtomic(self.io, .{ .path = stdout, .replace = false }, &.{report.stdout});
        try S.files.writeAtomic(self.io, .{ .path = stderr, .replace = false }, &.{report.stderr});
        const outcome = if (report.outcome == .failed) @errorName(report.outcome.failed.cause) else @tagName(report.outcome);
        try self.record(label, cwd, argv, env, stdout, stderr, outcome, if (report.term) |term| S.command.code(term) else null, report.cleanup_failure, report.success());
        if (!report.success()) return error.CommandFailed;
        return report;
    }

    fn record(self: *Runner, label: []const u8, cwd: []const u8, argv: []const []const u8, env: *const Env, stdout: ?[]const u8, stderr: ?[]const u8, outcome: []const u8, code: ?i32, cleanup: ?anyerror, success: bool) !void {
        // Callers commonly construct argv arrays on their stack. Evidence
        // outlives those calls and must own both the array and its strings.
        const owned_argv = try self.a.alloc([]const u8, argv.len);
        for (argv, owned_argv) |arg, *owned| owned.* = try self.a.dupe(u8, arg);
        try self.commands.append(self.a, .{ .label = label, .argv = owned_argv, .cwd = cwd, .timeout_ms = self.timeout, .global_cache = env.get("ZIG_GLOBAL_CACHE_DIR"), .local_cache = env.get("ZIG_LOCAL_CACHE_DIR"), .package_dir = env.get("ZIG_LOCAL_PKG_DIR"), .stdout_log = stdout, .stderr_log = stderr, .outcome = outcome, .exit_code = code, .cleanup_error = if (cleanup) |err| @errorName(err) else null, .success = success });
    }

    fn inflate(self: *Runner, path: []const u8) !void {
        const log_path = try self.artifactPath("archive-inflate.stderr.log");
        const argv: []const []const u8 = &.{ "/usr/bin/gzip", "-dc", self.archive.?.path };
        const maximum: usize = @intCast(self.snapshot.?.bytes + (self.snapshot.?.files.len + self.snapshot.?.directories.len) * 4096 + 10240);
        const report = S.command.runReport(self.a, self.io, .{ .run = .{ .spawn = .{ .argv = argv, .cwd = .{ .path = self.root }, .environ_map = self.env }, .timeout_ms = self.timeout, .stdout_limit = maximum, .stderr_limit = capture_limit } }) catch |err| {
            try self.record("archive-inflate", self.root, argv, self.env, null, null, @errorName(err), null, null, false);
            return err;
        };
        try S.files.writeAtomic(self.io, .{ .path = log_path, .replace = false }, &.{report.stderr});
        const outcome = if (report.outcome == .failed) @errorName(report.outcome.failed.cause) else @tagName(report.outcome);
        try self.record("archive-inflate", self.root, argv, self.env, null, log_path, outcome, if (report.term) |term| S.command.code(term) else null, report.cleanup_failure, report.success());
        if (!report.success()) return error.CommandFailed;
        try S.files.writeAtomic(self.io, .{ .path = path, .replace = false }, &.{report.stdout});
    }

    pub fn remove(self: *Runner, argv: []const []const u8) !void {
        _ = try self.command("cleanup", "/", argv, self.env);
    }

    fn evidence(self: *Runner, status: []const u8, failure: ?anyerror, cleanup_failure: ?anyerror) !void {
        const report = .{
            .schema_version = 1,
            .status = status,
            .version = options.version,
            .zig = builtin.zig_version_string,
            .target = "native-x86_64-linux",
            .optimization = @tagName(builtin.mode),
            .started_unix_seconds = self.started,
            .updated_unix_seconds = Io.Clock.real.now(self.io).toSeconds(),
            .snapshot = .{ .root = self.root, .git_head = self.git_head, .git_status_porcelain = self.git_status, .boundary = "Payload captured before the first archive; identical archives and unchanged payload required through qualification. Final evidence is outside that archive.", .files = if (self.snapshot) |snapshot| snapshot.files.len else 0 },
            .current_stage = self.current,
            .completed_stages = self.completed.items,
            .error_name = if (failure) |err| @errorName(err) else null,
            .cleanup_error = if (cleanup_failure) |err| @errorName(err) else null,
            .workspace = .{ .path = if (self.workspace) |workspace| workspace.path else null, .removed = self.cleaned },
            .artifacts = .{ .directory = self.artifacts, .archive = self.archive, .payload_manifest = self.manifest, .cli = self.cli, .corpus = self.replay },
            .source_tests_passed = self.source_tests,
            .consumer_tests_passed = self.consumer_tests,
            .corpus = self.replay_summary,
            .quarantined_source_artifacts = self.quarantine.items,
            .tools = self.tools.items,
            .capture_limit_bytes_per_stream = capture_limit,
            .commands = self.commands.items,
        };
        // Retain the final report with its run, even when a later invocation
        // replaces the convenient latest-report path.
        if (!std.mem.eql(u8, status, "running")) try S.json.writeAtomic(self.a, self.io, .{ .path = try self.artifactPath("evidence.json"), .replace = false }, report);
        try S.json.writeAtomic(self.a, self.io, .{ .path = self.out, .replace = true }, report);
    }
};

fn absent(io: Io, path: []const u8) !void {
    _ = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.SourceArtifactStillPresent;
}

fn compareFiles(io: Io, x_path: []const u8, y_path: []const u8) !void {
    const x = try Io.Dir.cwd().openFile(io, x_path, .{});
    defer x.close(io);
    const y = try Io.Dir.cwd().openFile(io, y_path, .{});
    defer y.close(io);
    var xb: [65536]u8 = undefined;
    var yb: [65536]u8 = undefined;
    var xr = x.readerStreaming(io, &.{});
    var yr = y.readerStreaming(io, &.{});
    while (true) {
        const xn = try xr.interface.readSliceShort(&xb);
        const yn = try yr.interface.readSliceShort(&yb);
        if (xn != yn or !std.mem.eql(u8, xb[0..xn], yb[0..yn])) return error.ArchivesDiffer;
        if (xn == 0) return;
    }
}

test {
    _ = C;
    _ = W;
}

test "distribution command evidence owns arguments after caller mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const owned = try W.Owned.create(a, io);
    const Cleanup = struct {
        pub fn remove(_: *@This(), argv: []const []const u8) !void {
            const report = try S.command.runReport(std.testing.allocator, std.testing.io, .{ .run = .{ .spawn = .{ .argv = argv }, .timeout_ms = 5000 } });
            defer report.deinit(std.testing.allocator);
            if (!report.success()) return error.CleanupFailed;
        }
    };
    var cleanup: Cleanup = .{};
    defer owned.cleanup(a, io, &cleanup) catch @panic("test cleanup failed");
    var env = Env.init(a);
    var runner: Runner = .{ .a = a, .io = io, .root = owned.path, .out = try C.join(a, owned.path, "evidence.json"), .artifacts = owned.path, .env = &env, .timeout = 5000, .started = 0 };
    var message = "caller-owned".*;
    var argv: [3][]const u8 = .{ "/usr/bin/printf", "%s", &message };
    const result = try runner.command("lifetime", owned.path, &argv, &env);
    try std.testing.expectEqualStrings("caller-owned", result.stdout);
    @memset(&message, 'x');
    @memset(&argv, "changed");
    try runner.evidence("running", null, null);
    const evidence = (try S.json.parse(a, try runner.read(runner.out, 65536))).value;
    const commands = try S.json.arr(evidence, "commands");
    const saved = try S.json.arr(commands[0], "argv");
    try std.testing.expectEqualStrings("/usr/bin/printf", try S.json.text(saved[0]));
    try std.testing.expectEqualStrings("caller-owned", try S.json.text(saved[2]));
}
