const std = @import("std");
const S = @import("test_support");
const V = @import("package_version");
const options = @import("version_options");
const project_root = std.fs.path.dirname(options.manifest) orelse ".";
const t = std.testing;
const Config = struct { files: []const V.FileSpec };

fn loadConfig() !std.json.Parsed(Config) {
    const bytes = try S.files.read(t.allocator, t.io, .{ .path = options.config, .limit = 1024 * 1024 });
    defer t.allocator.free(bytes);
    return std.json.parseFromSlice(Config, t.allocator, bytes, .{ .allocate = .alloc_always });
}

const Fixture = struct {
    temporary: t.TmpDir,
    root: [:0]u8,
    config: std.json.Parsed(Config),

    fn init() !Fixture {
        var temporary = t.tmpDir(.{});
        errdefer temporary.cleanup();
        const root = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
        errdefer t.allocator.free(root);
        const config = try loadConfig();
        errdefer config.deinit();
        var fixture: Fixture = .{ .temporary = temporary, .root = root, .config = config };
        const bytes = try S.files.read(t.allocator, t.io, .{ .path = options.config, .limit = 1024 * 1024 });
        defer t.allocator.free(bytes);
        try fixture.write("versions.json", bytes);
        for (config.value.files) |file| {
            const path = try std.fs.path.join(t.allocator, &.{ project_root, file.path });
            defer t.allocator.free(path);
            const contents = try S.files.read(t.allocator, t.io, .{ .path = path, .limit = 1024 * 1024 });
            defer t.allocator.free(contents);
            try fixture.write(file.path, contents);
        }
        try fixture.write("historical-version.txt", "json-query 0.1.0\n");
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        self.config.deinit();
        t.allocator.free(self.root);
        self.temporary.cleanup();
    }

    fn write(self: *Fixture, relative: []const u8, bytes: []const u8) !void {
        const path = try std.fs.path.join(t.allocator, &.{ self.root, relative });
        defer t.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(t.io, parent);
        try S.files.writeAtomic(t.io, .{ .path = path, .replace = true }, &.{bytes});
    }

    fn read(self: *Fixture, relative: []const u8) ![]u8 {
        const path = try std.fs.path.join(t.allocator, &.{ self.root, relative });
        defer t.allocator.free(path);
        return S.files.read(t.allocator, t.io, .{ .path = path, .limit = 1024 * 1024 });
    }

    fn command(self: *Fixture, args: []const []const u8) !S.process.Report {
        const executable = try std.Io.Dir.cwd().realPathFileAlloc(t.io, options.exe, t.allocator);
        defer t.allocator.free(executable);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(t.allocator);
        try argv.appendSlice(t.allocator, &.{ executable, "--config", "versions.json" });
        try argv.appendSlice(t.allocator, args);
        return S.command.runReport(t.allocator, t.io, .{ .run = .{
            .spawn = .{ .argv = argv.items, .cwd = .{ .path = self.root } },
            .timeout_ms = 5000,
            .stdout_limit = 4096,
            .stderr_limit = 8192,
        } });
    }

    fn expectVersions(self: *Fixture, expected: []const u8) !void {
        for (self.config.value.files) |file| {
            const text = try self.read(file.path);
            defer t.allocator.free(text);
            for (file.patterns) |pattern| try t.expectEqualStrings(expected, try V.extractVersion(text, pattern));
        }
    }

    fn hashes(self: *Fixture) ![][32]u8 {
        const result = try t.allocator.alloc([32]u8, self.config.value.files.len);
        errdefer t.allocator.free(result);
        for (self.config.value.files, result) |file, *digest| {
            const text = try self.read(file.path);
            defer t.allocator.free(text);
            std.crypto.hash.sha2.Sha256.hash(text, digest, .{});
        }
        return result;
    }
};

test "release version configuration synchronizes every actual project marker" {
    const config = try loadConfig();
    defer config.deinit();
    try V.validateFiles(config.value.files);
    try t.expectEqual(@as(usize, 4), config.value.files.len);
    var markers: usize = 0;
    for (config.value.files) |file| {
        const path = try std.fs.path.join(t.allocator, &.{ project_root, file.path });
        defer t.allocator.free(path);
        const text = try S.files.read(t.allocator, t.io, .{ .path = path, .limit = 1024 * 1024 });
        defer t.allocator.free(text);
        for (file.patterns) |pattern| {
            try t.expectEqualStrings(options.version, try V.extractVersion(text, pattern));
            markers += 1;
        }
    }
    try t.expectEqual(@as(usize, 5), markers);
}

test "release version CLI gets sets and preserves dependency pins and historical evidence" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const get = try fixture.command(&.{});
    defer get.deinit(t.allocator);
    try S.Diagnostic.expectExit(get, .{ .assertion = "version get", .code = 0 });
    const expected = try std.fmt.allocPrint(t.allocator, "{s}\n", .{options.version});
    defer t.allocator.free(expected);
    try t.expectEqualStrings(expected, get.stdout);
    try t.expectEqualStrings("", get.stderr);

    for ([_][]const u8{ "0.1.0", "0.8.9" }) |next| {
        const set = try fixture.command(&.{ "set", next });
        defer set.deinit(t.allocator);
        try S.Diagnostic.expectExit(set, .{ .assertion = "version set", .code = 0 });
        try fixture.expectVersions(next);
    }
    const zon = try fixture.read("build.zig.zon");
    defer t.allocator.free(zon);
    try t.expect(std.mem.indexOf(u8, zon, "file:vendor/zig-package-version-0.1.0.tar.gz") != null);
    const history = try fixture.read("historical-version.txt");
    defer t.allocator.free(history);
    try t.expectEqualStrings("json-query 0.1.0\n", history);
    const read_back = try fixture.command(&.{"get"});
    defer read_back.deinit(t.allocator);
    try S.Diagnostic.expectExit(read_back, .{ .assertion = "version get after set", .code = 0 });
    try t.expectEqualStrings("0.8.9\n", read_back.stdout);
}

test "release version mismatch is reported and explicit set repairs every location" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const file = fixture.config.value.files[1];
    const text = try fixture.read(file.path);
    defer t.allocator.free(text);
    const changed = try V.replaceVersion(t.allocator, .{ .contents = text, .pattern = file.patterns[0], .expected = options.version, .replacement = "0.8.8" });
    defer t.allocator.free(changed);
    try fixture.write(file.path, changed);
    const get = try fixture.command(&.{"get"});
    defer get.deinit(t.allocator);
    try S.Diagnostic.expectExit(get, .{ .assertion = "version mismatch", .code = 1 });
    try t.expect(std.mem.indexOf(u8, get.stderr, "src/root.zig") != null);
    const set = try fixture.command(&.{ "set", "0.8.9" });
    defer set.deinit(t.allocator);
    try S.Diagnostic.expectExit(set, .{ .assertion = "version repair", .code = 0 });
    try fixture.expectVersions("0.8.9");
}

test "release version preflight and invalid targets never partially update fixtures" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const before = try fixture.hashes();
    defer t.allocator.free(before);
    const invalid = try fixture.command(&.{ "set", "00.2.0" });
    defer invalid.deinit(t.allocator);
    try S.Diagnostic.expectExit(invalid, .{ .assertion = "invalid version", .code = 1 });
    const after_invalid = try fixture.hashes();
    defer t.allocator.free(after_invalid);
    try t.expectEqualSlices([32]u8, before, after_invalid);

    const file = fixture.config.value.files[fixture.config.value.files.len - 1];
    const text = try fixture.read(file.path);
    defer t.allocator.free(text);
    const pattern = file.patterns[0];
    const duplicate = try std.fmt.allocPrint(t.allocator, "{s}\n{s}{s}{s}\n", .{ text, pattern.prefix, options.version, pattern.suffix });
    defer t.allocator.free(duplicate);
    try fixture.write(file.path, duplicate);
    const before_preflight = try fixture.hashes();
    defer t.allocator.free(before_preflight);
    const set = try fixture.command(&.{ "set", "0.8.9" });
    defer set.deinit(t.allocator);
    try S.Diagnostic.expectExit(set, .{ .assertion = "late preflight failure", .code = 1 });
    try t.expect(std.mem.indexOf(u8, set.stderr, "DuplicateVersionMarker") != null);
    const after_preflight = try fixture.hashes();
    defer t.allocator.free(after_preflight);
    try t.expectEqualSlices([32]u8, before_preflight, after_preflight);
}
