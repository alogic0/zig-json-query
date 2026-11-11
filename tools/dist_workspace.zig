//! Cleanup is restricted to an exclusively created, marked workspace. Files and
//! symlinks are removed by plain rm; directories are removed only when empty.
const std = @import("std");
const S = @import("test_support");
const C = @import("dist_checks.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const marker = ".jqz-verify-dist-owner";

pub const Owned = struct {
    path: []const u8,
    token: []const u8,

    pub fn create(a: A, io: Io) !Owned {
        const workspace = try S.Workspace.init(a, io, .{ .prefix = "jqz-verify-dist-", .policy = .retain_on_failure });
        const token = try a.print("{s}\n", .{std.fs.path.basename(workspace.path)});
        try S.files.writeAtomic(io, .{ .path = try C.join(a, workspace.path, marker), .replace = false }, &.{token});
        return .{ .path = workspace.path, .token = token };
    }

    pub fn validate(self: Owned, a: A, io: Io) !void {
        const prefix = "/tmp/jqz-verify-dist-";
        if (!std.mem.startsWith(u8, self.path, prefix) or self.path.len != prefix.len + 24) return error.UnownedWorkspace;
        for (self.path[prefix.len..]) |byte| if (!std.ascii.isHex(byte)) return error.UnownedWorkspace;
        const metadata = try Io.Dir.cwd().statFile(io, self.path, .{ .follow_symlinks = false });
        if (metadata.kind != .directory) return error.UnownedWorkspace;
        const owner_path = try C.join(a, self.path, marker);
        if ((try Io.Dir.cwd().statFile(io, owner_path, .{ .follow_symlinks = false })).kind != .file) return error.UnownedWorkspace;
        const bytes = try S.files.read(a, io, .{ .path = owner_path, .limit = 256 });
        if (!std.mem.eql(u8, bytes, self.token) or !std.mem.eql(u8, self.token, try a.print("{s}\n", .{std.fs.path.basename(self.path)}))) return error.UnownedWorkspace;
    }

    pub fn cleanup(self: Owned, a: A, io: Io, driver: anytype) !void {
        try self.validate(a, io);
        var files: std.ArrayList([]const u8) = .empty;
        var directories: std.ArrayList([]const u8) = .empty;
        var dir = try Io.Dir.cwd().openDir(io, self.path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (std.mem.eql(u8, entry.path, marker)) continue;
            const path = try C.join(a, self.path, entry.path);
            if (entry.kind == .directory) try directories.append(a, path) else try files.append(a, path);
        }
        // A directory symlink is a file in this walk and is never traversed.
        std.sort.pdq([]const u8, directories.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return x.len > y.len;
            }
        }.less);
        try removeBatches(a, driver, "/usr/bin/rm", files.items);
        try removeBatches(a, driver, "/usr/bin/rmdir", directories.items);
        try self.validate(a, io);
        try removeBatches(a, driver, "/usr/bin/rm", &.{try C.join(a, self.path, marker)});
        try removeBatches(a, driver, "/usr/bin/rmdir", &.{self.path});
    }
};

fn removeBatches(a: A, driver: anytype, executable: []const u8, paths: []const []const u8) !void {
    var offset: usize = 0;
    while (offset < paths.len) {
        const count = @min(paths.len - offset, 128);
        const argv = try a.alloc([]const u8, count + 1);
        argv[0] = executable;
        @memcpy(argv[1..], paths[offset..][0..count]);
        try driver.remove(argv);
        offset += count;
    }
}

test "distribution cleanup refuses an unowned root and does not follow symlinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const Driver = struct {
        pub fn remove(_: *@This(), argv: []const []const u8) !void {
            const result = try S.command.runReport(std.testing.allocator, std.testing.io, .{ .run = .{ .spawn = .{ .argv = argv }, .timeout_ms = 5000 } });
            defer result.deinit(std.testing.allocator);
            if (!result.success()) return error.CleanupCommandFailed;
        }
    };
    var driver: Driver = .{};
    const owned = try Owned.create(a, io);
    const outside = try Owned.create(a, io);
    defer outside.cleanup(a, io, &driver) catch @panic("outside cleanup failed");
    const link = try C.join(a, owned.path, "outside");
    try Io.Dir.cwd().symLink(io, outside.path, link, .{ .is_directory = true });
    var wrong = owned;
    wrong.token = "wrong";
    try std.testing.expectError(error.UnownedWorkspace, wrong.cleanup(a, io, &driver));
    try outside.validate(a, io);
    try std.testing.expectError(error.UnsafeOutputPath, C.safeOutput(a, io, owned.path, "AGENTS.md"));
    try std.testing.expectError(error.UnsafeOutputPath, C.safeOutput(a, io, "/unrelated", try C.join(a, link, "evidence.json")));
    try owned.cleanup(a, io, &driver);
    try outside.validate(a, io);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, owned.path, .{}));
}
