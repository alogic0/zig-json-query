//! Explicit live CLI checks. Reads retained compiler inputs; never runs history
//! text or compiler workloads, and publishes identities rather than payloads.
const std = @import("std");
const S = @import("test_support");
const A = std.mem.Allocator;
const Io = std.Io;
const J = S.json;
const File = struct { path: []const u8, bytes: u64, sha256: []const u8 };
const Check = struct { id: []const u8, source_record: usize, inputs: []const File, jq_argv: []const []const u8, jqz_argv: []const []const u8, jq_exit: ?i32, jqz_exit: ?i32, jq_outcome: []const u8, jqz_outcome: []const u8, jq_stdout_bytes: usize, jqz_stdout_bytes: usize, jq_stdout_sha256: []const u8, jqz_stdout_sha256: []const u8, stderr_empty: bool, byte_identical: bool, inputs_unchanged: bool, passed: bool };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.UsageBinaryAndOutput;
    const binary = try Io.Dir.cwd().realPathFileAlloc(io, args[1], a);
    const root = "/home/oleg/prog/z_llvm";
    const prior_path = "docs/qualification/2026-11-11-zllvm-translations.json";
    const prior = (try J.parse(a, try S.files.read(a, io, .{ .path = prior_path, .limit = 1024 * 1024 }))).value;
    const version = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = &.{ binary, "--version" } }, .timeout_ms = 5000 } });
    if (!version.success()) return error.VersionFailed;
    const binary_hash = try fileHash(a, io, binary);
    const reference_hash = try fileHash(a, io, "/usr/bin/jq");
    var checks: std.ArrayList(Check) = .empty;
    const query_file = try Io.Dir.cwd().realPathFileAlloc(io, "examples/zllvm/nul-paths.query", a);
    for (try J.arr(prior, "checks")) |source| {
        if (!J.is(try J.field(source, "id"), "nul-path-protocol")) continue;
        var inputs: std.ArrayList(File) = .empty;
        var reference: std.ArrayList([]const u8) = .empty;
        var candidate: std.ArrayList([]const u8) = .empty;
        try reference.appendSlice(a, &.{ "/usr/bin/jq", "-jr", ".files|keys[]|.,\"\\u0000\"" });
        try candidate.appendSlice(a, &.{ binary, "-jr", "-f", query_file });
        for (try J.arr(source, "inputs")) |input| {
            const path = try std.fs.path.resolve(a, &.{ root, try J.str(input, "path") });
            if (!std.mem.startsWith(u8, path, root ++ "/")) return error.UnsafeInputPath;
            try inputs.append(a, try describe(a, io, path));
            try reference.append(a, path);
            try candidate.append(a, path);
        }
        if (inputs.items.len == 0) return error.MissingInput;
        try checks.append(a, try pair(a, io, "nul-path-protocol", @intCast(try J.integer(try J.field(source, "record"))), inputs.items, reference.items, candidate.items));
    }
    if (checks.items.len != 3) return error.IncompleteLiveCases;
    if (!std.mem.eql(u8, binary_hash, try fileHash(a, io, binary)) or !std.mem.eql(u8, reference_hash, try fileHash(a, io, "/usr/bin/jq"))) return error.ToolChanged;
    if (std.fs.path.dirname(args[2])) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try S.json.writeAtomic(a, io, .{ .path = args[2], .replace = true }, .{
        .schema_version = 1,
        .version = std.mem.trim(u8, version.stdout, " \r\n"),
        .optimization = @tagName(@import("builtin").mode),
        .jq_sha256 = reference_hash,
        .jqz_sha256 = binary_hash,
        .helper_sha256 = try fileHash(a, io, "docs/experiments/cli_features.zig"),
        .query_sha256 = try fileHash(a, io, query_file),
        .source_evidence_sha256 = try fileHash(a, io, prior_path),
        .method = "Explicit argv, 10-second deadlines, 8 MiB capture limits; retained input files capped at 32 MiB and hashed before/after each pair. No historical command text is executed. Raw output/status compared exactly; report payloads discarded. Original 0.28.0 evidence remains unchanged.",
        .checks = checks.items,
    });
    for (checks.items) |check| if (!check.passed) return error.LiveCheckFailed;
}

fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn fileHash(a: A, io: Io, path: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(try S.files.sha256(io, path), .lower));
}
fn describe(a: A, io: Io, path: []const u8) !File {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size > 32 * 1024 * 1024) return error.InputOutsideLimits;
    return .{ .path = path, .bytes = stat.size, .sha256 = try fileHash(a, io, path) };
}
fn pair(a: A, io: Io, id: []const u8, record: usize, inputs: []const File, reference: []const []const u8, candidate: []const []const u8) !Check {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const r = try S.command.runReport(scratch, io, .{ .run = .{ .spawn = .{ .argv = reference }, .timeout_ms = 10000, .stdout_limit = 8 * 1024 * 1024, .stderr_limit = 8192 } });
    const c = try S.command.runReport(scratch, io, .{ .run = .{ .spawn = .{ .argv = candidate }, .timeout_ms = 10000, .stdout_limit = 8 * 1024 * 1024, .stderr_limit = 8192 } });
    var unchanged = true;
    for (inputs) |input| if (!std.mem.eql(u8, input.sha256, try fileHash(a, io, input.path))) {
        unchanged = false;
        break;
    };
    const identical = std.mem.eql(u8, r.stdout, c.stdout);
    const quiet = r.stderr.len == 0 and c.stderr.len == 0;
    const passed = r.success() and c.success() and identical and quiet and unchanged;
    std.debug.print("{s}: {s} (record {d}, {d}/{d} bytes)\n", .{ id, if (passed) "passed" else "failed", record, r.stdout.len, c.stdout.len });
    return .{ .id = id, .source_record = record, .inputs = inputs, .jq_argv = reference, .jqz_argv = candidate, .jq_exit = if (r.term) |term| S.command.code(term) else null, .jqz_exit = if (c.term) |term| S.command.code(term) else null, .jq_outcome = @tagName(r.outcome), .jqz_outcome = @tagName(c.outcome), .jq_stdout_bytes = r.stdout.len, .jqz_stdout_bytes = c.stdout.len, .jq_stdout_sha256 = try digest(a, r.stdout), .jqz_stdout_sha256 = try digest(a, c.stdout), .stderr_empty = quiet, .byte_identical = identical, .inputs_unchanged = unchanged, .passed = passed };
}
