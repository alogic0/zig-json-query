const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const regex = b.dependency("regex", .{ .target = target, .optimize = optimize }).module("regex");
    const query = b.addModule("query", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "regex", .module = regex }},
    });
    const exe = b.addExecutable(.{
        .name = "jqz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "query", .module = query }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the JSON query prototype").dependOn(&run.step);

    const filter = b.option([]const u8, "test-filter", "Run matching unit tests");
    const unit = b.addTest(.{ .root_module = query, .filters = if (filter) |f| &.{f} else &.{} });
    const run_unit = b.addRunArtifact(unit);
    const tests = b.step("test", "Run language and CLI tests");
    tests.dependOn(&run_unit.step);
    b.step("test-unit", "Run language tests").dependOn(&run_unit.step);
    const fuzz_filter = b.option([]const u8, "fuzz-target", "Select fuzz parser or fuzz evaluator") orelse "fuzz ";
    const fuzz = b.addTest(.{ .root_module = query, .filters = &.{fuzz_filter}, .use_llvm = true });
    const run_fuzz = b.addRunArtifact(fuzz);
    b.step("fuzz", "Fuzz bounded parser and evaluator inputs (--fuzz=N)").dependOn(&run_fuzz.step);

    const support = b.dependency("test_support", .{ .target = b.graph.host, .optimize = optimize }).module("test_support");
    const options = b.addOptions();
    options.addOptionPath("exe", exe.getEmittedBin());
    const cli_module = b.createModule(.{
        .root_source_file = b.path("tests/cli.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "test_support", .module = support }},
    });
    cli_module.addOptions("test_options", options);
    const cli = b.addTest(.{ .root_module = cli_module });
    const run_cli = b.addRunArtifact(cli);
    tests.dependOn(&run_cli.step);
    b.step("test-cli", "Run native CLI acceptance tests").dependOn(&run_cli.step);
    b.step("check", "Compile the CLI").dependOn(&exe.step);

    const version_package = b.dependency("package_version", .{ .target = b.graph.host, .optimize = optimize });
    const version_cli = version_package.artifact("zig-package-version");
    const run_version = b.addRunArtifact(version_cli);
    run_version.setCwd(b.path("."));
    run_version.addArg("--config");
    run_version.addFileArg(b.path("tools/versions.json"));
    run_version.addPassthruArgs();
    run_version.has_side_effects = true;
    b.step("version", "Check or synchronize release versions using zig-package-version").dependOn(&run_version.step);

    const version_options = b.addOptions();
    version_options.addOptionPath("exe", version_cli.getEmittedBin());
    version_options.addOptionPath("config", b.path("tools/versions.json"));
    version_options.addOptionPath("manifest", b.path("build.zig.zon"));
    version_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const version_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/version.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "test_support", .module = support },
            .{ .name = "package_version", .module = version_package.module("package_version") },
        },
    });
    version_tests_module.addOptions("version_options", version_options);
    const version_tests = b.addTest(.{ .root_module = version_tests_module });
    const run_version_tests = b.addRunArtifact(version_tests);
    run_version_tests.setCwd(b.path("."));
    run_version_tests.has_side_effects = true;
    tests.dependOn(&run_version_tests.step);
    b.step("test-package-version", "Check release synchronization and fixture-based get/set/preflight").dependOn(&run_version_tests.step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "test_support", .module = support }},
    });
    bench_module.addOptions("test_options", options);
    const bench = b.addExecutable(.{ .name = "query-bench", .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Compare pinned jq/jaq tools, output equivalence, elapsed time and peak RSS").dependOn(&run_bench.step);

    const archive = b.addSystemCommand(&.{
        "tar",                  "--format=gnu",      "--sort=name",       "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner", "--mode=u+rwX,go+rX,go-w",
        "--exclude=.zig-cache", "--exclude=zig-pkg", "--exclude=zig-out", "-czf",
    });
    archive.setCwd(b.path("."));
    archive.has_side_effects = true;
    const source_archive = archive.addOutputFileArg("zig-json-query-0.4.0.tar.gz");
    archive.addArgs(&.{ "build.zig", "build.zig.zon", ".zigversion", ".gitignore", "AGENTS.md", "src", "tests", "examples", "docs", "tools", "vendor", "README.md", "DESIGN.md" });
    const install_archive = b.addInstallFileWithDir(source_archive, .prefix, "dist/zig-json-query-0.4.0.tar.gz");
    b.step("dist", "Package deterministic standalone sources (requires GNU tar)").dependOn(&install_archive.step);
}
