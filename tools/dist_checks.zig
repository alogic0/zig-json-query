const std = @import("std");
const S = @import("test_support");
pub const layout = @import("dist_layout.zig");
const A = std.mem.Allocator;
const Io = std.Io;
pub const File = struct { path: []const u8, bytes: u64, sha256: []const u8 };
pub const Snapshot = struct { files: []const File, directories: []const []const u8, bytes: u64 };

pub fn excluded(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| for (layout.excluded) |name| {
        if (std.mem.eql(u8, part, name)) return true;
    };
    return false;
}

pub fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    for (path) |byte| if (byte < 32 or byte == 127) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

pub fn hash(a: A, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn hashFile(a: A, io: Io, path: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(try S.files.sha256(io, path), .lower));
}

pub fn join(a: A, parent: []const u8, child: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ parent, child });
}

/// Preflight immutable download URLs and explicit hashes. Zig validates each
/// dependency's complete manifest entry and content hash during the fresh build.
pub fn checkDependencyPins(a: A, zon: [:0]const u8) !void {
    var tokens = std.zig.Tokenizer.init(zon);
    var urls: usize = 0;
    var hashes: usize = 0;
    while (true) {
        const token = tokens.next();
        if (token.tag == .eof) break;
        if (token.tag != .identifier) continue;
        const name = zon[token.loc.start..token.loc.end];
        const url = std.mem.eql(u8, name, "url");
        if (!url and !std.mem.eql(u8, name, "hash")) continue;
        if (tokens.next().tag != .equal) return error.InvalidDependencyManifest;
        const value = tokens.next();
        if (value.tag != .string_literal) return error.InvalidDependencyManifest;
        const text = try std.zig.string_literal.parseAlloc(a, zon[value.loc.start..value.loc.end]);
        defer a.free(text);
        if (url) {
            const path = std.mem.cutPrefix(u8, text, "git+https://github.com/") orelse return error.UnpinnedDependency;
            var parts = std.mem.splitScalar(u8, path, '/');
            const owner = parts.next() orelse return error.UnpinnedDependency;
            const repository = parts.next() orelse return error.UnpinnedDependency;
            var pinned = std.mem.splitScalar(u8, repository, '#');
            const project = pinned.next() orelse return error.UnpinnedDependency;
            const revision = pinned.next() orelse return error.UnpinnedDependency;
            if (owner.len == 0 or project.len <= 4 or !std.mem.endsWith(u8, project, ".git") or revision.len != 40 or pinned.next() != null or parts.next() != null) return error.UnpinnedDependency;
            for (revision) |byte| if (!std.ascii.isHex(byte)) return error.UnpinnedDependency;
            urls += 1;
        } else {
            if (text.len == 0) return error.UnpinnedDependency;
            hashes += 1;
        }
    }
    if (urls == 0 or urls != hashes) return error.InvalidDependencyManifest;
}

pub fn collect(a: A, io: Io, root: []const u8) !Snapshot {
    var files: std.ArrayList(File) = .empty;
    var directories: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;
    for (layout.roots) |name| {
        const path = try join(a, root, name);
        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (stat.kind == .file) {
            try files.append(a, .{ .path = name, .bytes = stat.size, .sha256 = try hashFile(a, io, path) });
            total += stat.size;
        } else if (stat.kind == .directory) {
            try directories.append(a, name);
            var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walkSelectively(a);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                const relative = try join(a, name, entry.path);
                if (excluded(relative)) continue;
                if (!safeRelative(relative)) return error.UnsafePayloadPath;
                switch (entry.kind) {
                    .directory => {
                        try directories.append(a, relative);
                        try walker.enter(io, entry);
                    },
                    .file => {
                        const full = try join(a, root, relative);
                        const metadata = try Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false });
                        if (metadata.kind != .file) return error.PayloadChanged;
                        try files.append(a, .{ .path = relative, .bytes = metadata.size, .sha256 = try hashFile(a, io, full) });
                        total += metadata.size;
                    },
                    else => return error.UnsupportedPayloadType,
                }
            }
        } else return error.UnsupportedPayloadType;
    }
    if (total > 512 * 1024 * 1024) return error.PayloadTooLarge;
    std.sort.pdq(File, files.items, {}, struct {
        fn less(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    std.sort.pdq([]const u8, directories.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return .{ .files = files.items, .directories = directories.items, .bytes = total };
}

pub fn same(expected: Snapshot, actual: Snapshot) !void {
    if (expected.files.len != actual.files.len or expected.directories.len != actual.directories.len) return error.PayloadChanged;
    for (expected.files, actual.files) |x, y| {
        if (!std.mem.eql(u8, x.path, y.path) or x.bytes != y.bytes or !std.mem.eql(u8, x.sha256, y.sha256)) return error.PayloadChanged;
    }
    for (expected.directories, actual.directories) |x, y| if (!std.mem.eql(u8, x, y)) return error.PayloadChanged;
}

pub fn validateTar(a: A, reader: *Io.Reader, expected: Snapshot) !void {
    var names: [Io.Dir.max_path_bytes]u8 = undefined;
    var links: [Io.Dir.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    const seen_files = try a.alloc(bool, expected.files.len);
    @memset(seen_files, false);
    const seen_dirs = try a.alloc(bool, expected.directories.len);
    @memset(seen_dirs, false);
    var buffer: [65536]u8 = undefined;
    while (try iterator.next()) |file| {
        if (file.kind == .sym_link or file.link_name.len != 0) return error.UnsupportedArchiveType;
        const name = if (file.kind == .directory) std.mem.trimEnd(u8, file.name, "/") else file.name;
        if (!safeRelative(name) or excluded(name)) return error.UnsafeArchivePath;
        if (file.kind == .directory) {
            if (file.size != 0) return error.InvalidArchiveDirectory;
            var found = false;
            for (expected.directories, 0..) |path, i| if (std.mem.eql(u8, path, name)) {
                if (seen_dirs[i]) return error.DuplicateArchiveMember;
                seen_dirs[i] = true;
                found = true;
                break;
            };
            if (!found) return error.UnexpectedArchiveMember;
        } else {
            var found: ?usize = null;
            for (expected.files, 0..) |item, i| if (std.mem.eql(u8, item.path, name)) {
                found = i;
                break;
            };
            const i = found orelse return error.UnexpectedArchiveMember;
            if (seen_files[i]) return error.DuplicateArchiveMember;
            seen_files[i] = true;
            if (file.size != expected.files[i].bytes) return error.ArchiveContentMismatch;
            var digest = std.crypto.hash.sha2.Sha256.init(.{});
            var remaining = file.size;
            while (remaining != 0) {
                const n: usize = @intCast(@min(remaining, buffer.len));
                try reader.readSliceAll(buffer[0..n]);
                digest.update(buffer[0..n]);
                remaining -= n;
            }
            iterator.unread_file_bytes = 0;
            if (!std.mem.eql(u8, expected.files[i].sha256, &std.fmt.bytesToHex(digest.finalResult(), .lower))) return error.ArchiveContentMismatch;
        }
    }
    for (seen_files) |seen| if (!seen) return error.MissingArchiveMember;
    for (seen_dirs) |seen| if (!seen) return error.MissingArchiveMember;
    for (iterator.header_buffer) |byte| if (byte != 0) return error.InvalidArchiveTrailer;
    var trailing: usize = 0;
    while (true) {
        const n = try reader.readSliceShort(&buffer);
        if (n == 0) break;
        for (buffer[0..n]) |byte| if (byte != 0) return error.InvalidArchiveTrailer;
        trailing += n;
    }
    if (trailing < 512 or trailing % 512 != 0) return error.InvalidArchiveTrailer;
}

pub fn inside(parent: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, parent, path) or (std.mem.startsWith(u8, path, parent) and path.len > parent.len and path[parent.len] == '/');
}

pub fn safeOutput(a: A, io: Io, root: []const u8, requested: []const u8) ![]const u8 {
    const path = try std.fs.path.resolve(a, &.{ root, requested });
    if (inside(root, path) and !inside(try join(a, root, "zig-out"), path)) return error.UnsafeOutputPath;
    if (std.mem.eql(u8, path, try join(a, root, "zig-out")) or std.mem.eql(u8, path, "/")) return error.UnsafeOutputPath;
    var end_index: usize = 1;
    while (end_index <= path.len) : (end_index += 1) {
        if (end_index < path.len and path[end_index] != '/') continue;
        const stat = Io.Dir.cwd().statFile(io, path[0..end_index], .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind == .sym_link or (end_index == path.len and stat.kind != .file)) return error.UnsafeOutputPath;
    }
    return path;
}

pub fn testCount(log: []const u8, minimum: usize) !usize {
    const marker = " tests passed";
    const end = std.mem.indexOf(u8, log, marker) orelse return error.MissingTestSummary;
    var start = end;
    while (start > 0 and (std.ascii.isDigit(log[start - 1]) or log[start - 1] == '/')) : (start -= 1) {}
    var fields = std.mem.splitScalar(u8, log[start..end], '/');
    const passed = try std.fmt.parseInt(usize, fields.next() orelse return error.MissingTestSummary, 10);
    const total = try std.fmt.parseInt(usize, fields.next() orelse return error.MissingTestSummary, 10);
    if (fields.next() != null or passed != total or total < minimum) return error.IncompleteTestSummary;
    return total;
}

pub const ReplaySummary = struct { cases: usize, observed: usize, translated: usize, probes: usize, samples: usize };

/// Match every case, frozen invocation, exit and timed sample, rather than
/// treating a successful runner exit as proof of a complete corpus replay.
pub fn validateReplay(a: A, manifest_bytes: []const u8, report_bytes: []const u8, snapshot: Snapshot, version: []const u8, cli_hash: []const u8) !ReplaySummary {
    const J = S.json;
    const manifest = (try J.parse(a, manifest_bytes)).value;
    const report = (try J.parse(a, report_bytes)).value;
    if (try J.integer(try J.field(report, "schema_version")) != 1 or !J.is(try J.field(report, "version"), version) or !J.is(try J.field(report, "optimization"), "debug") or try J.integer(try J.field(report, "repeat")) != 1) return error.InvalidReplayIdentity;
    const tools = try J.arr(report, "tools");
    if (tools.len != 2 or !J.is(try J.field(tools[0], "name"), "jqz") or !J.is(try J.field(tools[0], "sha256"), cli_hash)) return error.InvalidReplayIdentity;
    const cases = try J.arr(manifest, "cases");
    const reviews = try J.arr(report, "cases");
    const samples = try J.arr(report, "samples");
    if (cases.len != reviews.len or cases.len == 0) return error.IncompleteReplay;
    var result: ReplaySummary = .{ .cases = cases.len, .observed = 0, .translated = 0, .probes = 0, .samples = 0 };
    for (cases, reviews, 0..) |case, review, index| {
        const id = try J.str(case, "id");
        for (cases[0..index]) |previous| if (J.is(try J.field(previous, "id"), id)) return error.DuplicateReplayCase;
        if (!J.is(try J.field(review, "id"), id)) return error.IncompleteReplay;
        const scope = if (J.has(case, "scope")) try J.str(case, "scope") else "observed";
        const class = if (J.has(case, "classification")) try J.str(case, "classification") else "equivalent";
        if (!J.is(try J.field(review, "scope"), scope) or !J.is(try J.field(review, "classification"), class)) return error.IncompleteReplay;
        const jq = try J.field(case, "jq");
        const own = if (J.has(case, "jqz")) try J.field(case, "jqz") else @as(J.Value, .null);
        // JSON invocations omit optional defaults in the manifest. Compare the
        // fields supplied there; the existing runner validates output values.
        try invocationMatches(jq, try J.field(review, "reference_invocation"));
        if (own != .null) try invocationMatches(own, try J.field(review, "candidate_invocation"));
        try exitMatches(jq, try J.field(review, "jq"));
        if (own == .null) {
            if (try J.field(review, "jqz") != .null or try J.field(review, "candidate_invocation") != .null) return error.IncompleteReplay;
        } else try exitMatches(own, try J.field(review, "jqz"));
        if (std.mem.eql(u8, scope, "observed")) {
            result.observed += 1;
            if (std.mem.eql(u8, class, "equivalent")) result.translated += 1;
        }
        if (std.mem.eql(u8, scope, "probe")) result.probes += 1;
        const measure = !J.has(case, "measure") or (try J.field(case, "measure") == .bool and (try J.field(case, "measure")).bool);
        const measured = std.mem.eql(u8, class, "equivalent") and measure and !std.mem.eql(u8, scope, "probe");
        const flag = try J.field(review, "measured");
        if (flag != .bool or flag.bool != measured) return error.IncompleteReplay;
        for ([_][]const u8{ "jqz", "jq" }) |tool| {
            var count: usize = 0;
            for (samples) |sample| if (J.is(try J.field(sample, "case"), id) and J.is(try J.field(sample, "tool"), tool)) {
                count += 1;
                if (try J.integer(try J.field(sample, "iteration")) != 0) return error.IncompleteReplay;
                const outcome = try J.field(review, tool);
                if (try J.integer(try J.field(sample, "exit_code")) != try J.integer(try J.field(outcome, "exit_code")) or !J.eql(try J.field(sample, "stdout_sha256"), try J.field(outcome, "stdout_sha256"))) return error.IncompleteReplay;
            };
            if (count != @intFromBool(measured)) return error.IncompleteReplay;
            result.samples += count;
        }
    }
    if (samples.len != result.samples) return error.IncompleteReplay;
    const coverage = try J.field(report, "coverage");
    if (try J.integer(try J.field(coverage, "observed")) != result.observed or try J.integer(try J.field(coverage, "translated")) != result.translated or try J.integer(try J.field(coverage, "semantic_probes")) != result.probes) return error.IncompleteReplay;
    const sources = try J.arr(report, "source_hashes");
    if (sources.len < 4) return error.IncompleteReplay;
    for (sources, 0..) |source, index| {
        const path = try J.str(source, "path");
        for (sources[0..index]) |previous| if (J.is(try J.field(previous, "path"), path)) return error.IncompleteReplay;
        var found = false;
        for (snapshot.files) |file| if (std.mem.eql(u8, file.path, path)) {
            if (!J.is(try J.field(source, "sha256"), file.sha256)) return error.ReplaySourceMismatch;
            found = true;
            break;
        };
        if (!found) return error.ReplaySourceMismatch;
    }
    return result;
}

fn invocationMatches(expected: S.json.Value, actual: S.json.Value) !void {
    if (expected != .object or actual != .object) return error.IncompleteReplay;
    for (expected.object.keys(), expected.object.values()) |key, value| {
        const got = try S.json.field(actual, key);
        if (std.mem.eql(u8, key, "expected")) {
            if (value != .object or got != .object) return error.IncompleteReplay;
            for (value.object.keys(), value.object.values()) |inner, item| if (!S.json.eql(item, try S.json.field(got, inner))) return error.IncompleteReplay;
        } else if (!S.json.eql(value, got)) return error.IncompleteReplay;
    }
}

fn exitMatches(invocation: S.json.Value, outcome: S.json.Value) !void {
    const expected = try S.json.field(invocation, "expected");
    const code = if (S.json.has(expected, "exit_code")) try S.json.integer(try S.json.field(expected, "exit_code")) else 0;
    if (try S.json.integer(try S.json.field(outcome, "exit_code")) != code) return error.IncompleteReplay;
}

pub const Stage = enum { payload, tools, archive_first, archive_second, archive_validate, extract, source_tests, source_build, corpus, source_files, quarantine, isolation, consumer_tests, consumer_files, unchanged };
pub fn execute(driver: anytype) !void {
    for (std.enums.values(Stage)) |stage| try driver.step(stage);
}

test "distribution workflow cannot advance past a failed isolation check" {
    const Fake = struct {
        calls: usize = 0,
        consumer_started: bool = false,
        fn step(self: *@This(), stage: Stage) !void {
            self.calls += 1;
            if (stage == .isolation) return error.IsolationFailed;
            if (stage == .consumer_tests) self.consumer_started = true;
        }
    };
    var fake: Fake = .{};
    try std.testing.expectError(error.IsolationFailed, execute(&fake));
    try std.testing.expect(!fake.consumer_started);
    try std.testing.expectEqual(@as(usize, @backingInt(Stage.isolation) + 1), fake.calls);
}

test "distribution requires immutable remote dependencies with explicit hashes" {
    const t = std.testing;
    const pinned = "git+https://github.com/owner/project.git#0123456789abcdef0123456789abcdef01234567";
    for ([_][]const u8{ pinned, "git+https://github.com/owner/project.git#main", "git+https://github.com/owner/project.git#v1.0.0", "git+http://github.com/owner/project.git#0123456789abcdef0123456789abcdef01234567", "file:vendor/project.tar.gz", "git+https://github.com/owner/project.git#0123456789abcdef0123456789abcdef0123456g", "git+https://github.com/owner/project.git" }, 0..) |url, i| {
        const zon = try t.allocator.printSentinel(".{{ .dependencies = .{{ .project = .{{ .url = \"{s}\", .hash = \"pinned-content-hash\" }} }} }}", .{url}, 0);
        defer t.allocator.free(zon);
        if (i == 0) try checkDependencyPins(t.allocator, zon) else try t.expectError(error.UnpinnedDependency, checkDependencyPins(t.allocator, zon));
    }
    const missing = try t.allocator.printSentinel(".{{ .dependencies = .{{ .project = .{{ .url = \"{s}\" }} }} }}", .{pinned}, 0);
    defer t.allocator.free(missing);
    try t.expectError(error.InvalidDependencyManifest, checkDependencyPins(t.allocator, missing));
    const empty = try t.allocator.printSentinel(".{{ .dependencies = .{{ .project = .{{ .hash = \"\", .url = \"{s}\" }} }} }}", .{pinned}, 0);
    defer t.allocator.free(empty);
    try t.expectError(error.UnpinnedDependency, checkDependencyPins(t.allocator, empty));
    try t.expectError(error.InvalidDependencyManifest, checkDependencyPins(t.allocator, ".{ .dependencies = .{} }"));
}

test "distribution rejects escaping names and incomplete test summaries" {
    for ([_][]const u8{ "", "/tmp/a", "../a", "a/../b", "a//b", "a/./b", "a\\b", "a\nb" }) |path| try std.testing.expect(!safeRelative(path));
    try std.testing.expect(safeRelative("src/root.zig"));
    try std.testing.expect(excluded("tests/package/.zig-cache/a"));
    try std.testing.expectEqual(@as(usize, 228), try testCount("Build Summary: 21/21 steps succeeded; 228/228 tests passed\n", 220));
    try std.testing.expectError(error.MissingTestSummary, testCount("success", 220));
    try std.testing.expectError(error.IncompleteTestSummary, testCount("219/220 tests passed", 220));
}

test "distribution archive requires exact content and complete safe members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snapshot: Snapshot = .{ .files = &.{.{ .path = "src/a", .bytes = 3, .sha256 = try hash(a, "abc") }}, .directories = &.{"src"}, .bytes = 3 };
    const Kind = enum { valid, escape, duplicate, link, wrong_content, missing, extra, trailer };
    for (std.enums.values(Kind)) |kind| {
        var buffer = Io.Writer.Allocating.init(a);
        var tar: std.tar.Writer = .{ .underlying_writer = &buffer.writer };
        try tar.writeDir("src", .{});
        if (kind != .missing) try tar.writeFileBytes(if (kind == .escape) "../a" else "src/a", if (kind == .wrong_content) "abd" else "abc", .{});
        if (kind == .duplicate) try tar.writeFileBytes("src/a", "abc", .{});
        if (kind == .link) try tar.writeLink("link", "/tmp/outside", .{});
        if (kind == .extra) try tar.writeFileBytes("src/b", "extra", .{});
        if (kind != .trailer) try tar.finishPedantically();
        var reader: Io.Reader = .fixed(buffer.written());
        const result = validateTar(a, &reader, snapshot);
        switch (kind) {
            .valid => try result,
            .escape => try std.testing.expectError(error.UnsafeArchivePath, result),
            .duplicate => try std.testing.expectError(error.DuplicateArchiveMember, result),
            .link => try std.testing.expectError(error.UnsupportedArchiveType, result),
            .wrong_content => try std.testing.expectError(error.ArchiveContentMismatch, result),
            .missing => try std.testing.expectError(error.MissingArchiveMember, result),
            .extra => try std.testing.expectError(error.UnexpectedArchiveMember, result),
            .trailer => try std.testing.expectError(error.InvalidArchiveTrailer, result),
        }
    }
}

test "distribution detects payload drift and incomplete replay" {
    const original: Snapshot = .{ .files = &.{.{ .path = "src/a", .bytes = 3, .sha256 = "aaa" }}, .directories = &.{}, .bytes = 3 };
    var changed = original;
    changed.files = &.{.{ .path = "src/a", .bytes = 3, .sha256 = "bbb" }};
    try std.testing.expectError(error.PayloadChanged, same(original, changed));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidReplayIdentity, validateReplay(arena.allocator(), "{}", "{\"schema_version\":2}", original, "0.27.0", "aaa"));
}

test "distribution replay requires every case, exit, sample and source digest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invocation = .{ .query = ".", .expected = .{ .exit_code = 0 } };
    const manifest = try std.json.Stringify.valueAlloc(a, .{ .cases = .{.{ .id = "one", .jq = invocation, .jqz = invocation }} }, .{});
    const hashes = [_]struct { path: []const u8, sha256: []const u8 }{
        .{ .path = "build.zig", .sha256 = "a" }, .{ .path = "src/root.zig", .sha256 = "b" }, .{ .path = "tests/qualification/cases.json", .sha256 = "c" }, .{ .path = "docs/dependencies.md", .sha256 = "d" },
    };
    var files: [4]File = undefined;
    for (hashes, &files) |item, *file| file.* = .{ .path = item.path, .sha256 = item.sha256, .bytes = 0 };
    const snapshot: Snapshot = .{ .files = &files, .directories = &.{}, .bytes = 0 };
    const outcome = .{ .exit_code = 0, .stdout_sha256 = "result" };
    const report = try std.json.Stringify.valueAlloc(a, .{
        .schema_version = 1,
        .version = "fixture",
        .optimization = "debug",
        .repeat = 1,
        .tools = .{ .{ .name = "jqz", .sha256 = "binary" }, .{ .name = "jq", .sha256 = "reference" } },
        .cases = .{.{ .id = "one", .scope = "observed", .classification = "equivalent", .reference_invocation = invocation, .candidate_invocation = invocation, .jq = outcome, .jqz = outcome, .measured = true }},
        .samples = .{ .{ .case = "one", .tool = "jqz", .iteration = 0, .exit_code = 0, .stdout_sha256 = "result" }, .{ .case = "one", .tool = "jq", .iteration = 0, .exit_code = 0, .stdout_sha256 = "result" } },
        .coverage = .{ .observed = 1, .translated = 1, .semantic_probes = 0 },
        .source_hashes = hashes,
    }, .{});
    try std.testing.expectEqual(@as(usize, 2), (try validateReplay(a, manifest, report, snapshot, "fixture", "binary")).samples);
    try std.testing.expectError(error.InvalidReplayIdentity, validateReplay(a, manifest, report, snapshot, "fixture", "wrong-binary"));
    const missing = try std.mem.replaceOwned(u8, a, report, "\"id\":\"one\"", "\"id\":\"missing\"");
    try std.testing.expectError(error.IncompleteReplay, validateReplay(a, manifest, missing, snapshot, "fixture", "binary"));
    const bad_exit = try std.mem.replaceOwned(u8, a, report, "\"exit_code\":0", "\"exit_code\":2");
    try std.testing.expectError(error.IncompleteReplay, validateReplay(a, manifest, bad_exit, snapshot, "fixture", "binary"));
    const bad_sample = try std.mem.replaceOwned(u8, a, report, "\"iteration\":0", "\"iteration\":1");
    try std.testing.expectError(error.IncompleteReplay, validateReplay(a, manifest, bad_sample, snapshot, "fixture", "binary"));
    const bad_source = try std.mem.replaceOwned(u8, a, report, "\"sha256\":\"a\"", "\"sha256\":\"changed\"");
    try std.testing.expectError(error.ReplaySourceMismatch, validateReplay(a, manifest, bad_source, snapshot, "fixture", "binary"));
}
