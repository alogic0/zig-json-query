const std = @import("std");
const S = @import("test_support");
const exe = @import("test_options").exe;
const t = std.testing;

test "CLI shared descriptors preserve prefixes and sequential stdout and stderr" {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const output_cases = [_][]const []const u8{
        &.{ exe, "-n", "111111111" },          &.{ exe, "-n", "2" },
        &.{ exe, "-nr", "\"raw\\né\"" },
        &.{ exe, "-nj", "\"joined\\u0000\"" }, &.{ exe, "--help" },
        &.{ exe, "--version" },
    };
    const error_cases = [_][]const []const u8{ &.{ exe, "-n", ".missing" }, &.{ exe, "--bad" } };
    for ([_]bool{ false, true }) |errors| {
        const name = if (errors) "errors" else "output";
        const file = try temporary.dir.createFile(t.io, name, .{});
        defer file.close(t.io);
        const prefix = "prewritten prefix\n";
        try file.writeStreamingAll(t.io, prefix);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(t.allocator);
        try expected.appendSlice(t.allocator, prefix);
        for (if (errors) &error_cases else &output_cases) |argv| {
            const captured = try S.command.runReport(t.allocator, t.io, .{ .run = .{ .spawn = .{ .argv = argv }, .timeout_ms = 5000 } });
            defer captured.deinit(t.allocator);
            try S.Diagnostic.expectExit(captured, .{ .assertion = "pipe output", .code = if (errors) 2 else 0 });
            try expected.appendSlice(t.allocator, if (errors) captured.stderr else captured.stdout);
            const report = try S.command.File.run(t.allocator, t.io, .{ .spawn = .{
                .argv = argv,
                .stdout = if (errors) .ignore else .{ .file = file },
                .stderr = if (errors) .{ .file = file } else .ignore,
            }, .timeout_ms = 5000 });
            try t.expect(report.outcome == .completed and report.cleanup_failure == null);
            try t.expectEqual(@as(i32, if (errors) 2 else 0), S.command.code(report.term.?));
        }
        const actual = try temporary.dir.readFileAlloc(t.io, name, t.allocator, .limited(64 * 1024));
        defer t.allocator.free(actual);
        try t.expectEqualStrings(expected.items, actual);
    }
}

test "CLI shell shared and append redirection retain all records" {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const path = try std.fs.path.join(t.allocator, &.{ root, "output" });
    defer t.allocator.free(path);
    const report = try S.command.runReport(t.allocator, t.io, .{ .run = .{ .spawn = .{ .argv = &.{
        "/bin/bash",                                                                                                         "-c",
        "set -e; { printf 'prefix\\n'; \"$1\" -n 111; \"$1\" -n 2; } > \"$2\"; \"$1\" -nr '\"tail\"' >> \"$2\"; cat \"$2\"", "jqz-descriptor-test",
        exe,                                                                                                                 path,
    } }, .timeout_ms = 5000 } });
    defer report.deinit(t.allocator);
    try S.Diagnostic.expectExit(report, .{ .assertion = "shell redirection", .code = 0 });
    try t.expectEqualStrings("prefix\n111\n2\ntail\n", report.stdout);
    try t.expectEqualStrings("", report.stderr);
}
