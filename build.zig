const std = @import("std");
const dist_layout = @import("tools/dist_layout.zig");

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
    const binding_input_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/file_bindings.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const run_binding_input_tests = b.addRunArtifact(binding_input_tests);
    tests.dependOn(&run_binding_input_tests.step);
    b.step("test-file-bindings", "Check bounded file reads and exact JSON sequence framing").dependOn(&run_binding_input_tests.step);
    b.step("check", "Compile the CLI").dependOn(&exe.step);

    const cleanup_study = b.addExecutable(.{ .name = "query-cleanup-study", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/cleanup_study.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "query", .module = query }},
    }) });
    const run_cleanup_study = b.addRunArtifact(cleanup_study);
    run_cleanup_study.setCwd(b.path("."));
    run_cleanup_study.has_side_effects = true;
    b.step("study-cleanup", "Check portable cleanup workloads and retained allocation growth").dependOn(&run_cleanup_study.step);

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

    const qualification_options = b.addOptions();
    qualification_options.addOptionPath("exe", exe.getEmittedBin());
    qualification_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    qualification_options.addOption([]const u8, "target", b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) }));
    const exact_number = b.createModule(.{ .root_source_file = b.path("src/number.zig"), .target = b.graph.host, .optimize = optimize });
    const qualification_module = b.createModule(.{
        .root_source_file = b.path("tools/qualify.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "test_support", .module = support }, .{ .name = "exact_number", .module = exact_number } },
    });
    qualification_module.addOptions("qualification_options", qualification_options);
    const qualification = b.addExecutable(.{ .name = "query-qualify", .root_module = qualification_module });
    const run_qualification = b.addRunArtifact(qualification);
    run_qualification.setCwd(b.path("."));
    run_qualification.addPassthruArgs();
    b.step("qualify", "Qualify sanitized session workflows against jq and record Debug timing/RSS").dependOn(&run_qualification.step);
    const qualification_tests = b.addTest(.{ .root_module = qualification_module });
    const run_qualification_tests = b.addRunArtifact(qualification_tests);
    tests.dependOn(&run_qualification_tests.step);

    const profile_options = b.addOptions();
    for ([_]bool{ false, true }) |echo| {
        const launch_options = b.addOptions();
        launch_options.addOption(bool, "echo", echo);
        const launch_module = b.createModule(.{ .root_source_file = b.path("tools/launch_fixture.zig"), .target = b.graph.host, .optimize = optimize });
        launch_module.addOptions("launch_options", launch_options);
        const launch_fixture = b.addExecutable(.{ .name = if (echo) "profile-echo" else "profile-exit", .root_module = launch_module });
        profile_options.addOptionPath(if (echo) "echo_probe" else "exit_probe", launch_fixture.getEmittedBin());
    }
    profile_options.addOptionPath("exe", exe.getEmittedBin());
    profile_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    profile_options.addOption([]const u8, "compiler", b.graph.zig_exe);
    profile_options.addOption([]const u8, "target", b.fmt("{s}-{s}-{s}", .{ @tagName(b.graph.host.result.cpu.arch), @tagName(b.graph.host.result.os.tag), @tagName(b.graph.host.result.abi) }));
    const profile_engine = b.createModule(.{
        .root_source_file = b.path("src/profile_engine.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "regex", .module = regex }},
    });
    const profile_module = b.createModule(.{
        .root_source_file = b.path("tools/profile.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "test_support", .module = support }, .{ .name = "profile_engine", .module = profile_engine } },
    });
    profile_module.addOptions("profile_options", profile_options);
    const profiler = b.addExecutable(.{ .name = "query-profile", .root_module = profile_module });
    const run_profile = b.addRunArtifact(profiler);
    run_profile.setCwd(b.path("."));
    run_profile.addPassthruArgs();
    b.step("profile", "Measure native Debug engine phases and allocator requests").dependOn(&run_profile.step);
    const profile_tests = b.addTest(.{ .root_module = profile_module });
    const run_profile_tests = b.addRunArtifact(profile_tests);
    tests.dependOn(&run_profile_tests.step);
    b.step("test-profile", "Check phase measurements and allocation accounting").dependOn(&run_profile_tests.step);

    const dist_options = b.addOptions();
    dist_options.addOption([]const u8, "root", b.root.joinString(b.allocator, "") catch @panic("OOM"));
    dist_options.addOption([]const u8, "compiler", b.graph.zig_exe);
    dist_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    dist_options.addOption([]const u8, "archive_name", "zig-json-query-" ++ @import("build.zig.zon").version ++ ".tar.gz");
    dist_options.addOption(bool, "native_requested", target.query.isNative());
    const dist_module = b.createModule(.{
        .root_source_file = b.path("tools/verify_dist.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "test_support", .module = support }},
    });
    dist_module.addOptions("dist_options", dist_options);
    const verifier = b.addExecutable(.{ .name = "verify-dist", .root_module = dist_module });
    const run_verifier = b.addRunArtifact(verifier);
    run_verifier.setCwd(b.path("."));
    run_verifier.addPassthruArgs();
    run_verifier.has_side_effects = true;
    b.step("verify-dist", "Verify a standalone source archive, isolated corpus replay and consumer (native Debug)").dependOn(&run_verifier.step);
    const verifier_tests = b.addTest(.{ .root_module = dist_module });
    const run_verifier_tests = b.addRunArtifact(verifier_tests);
    tests.dependOn(&run_verifier_tests.step);
    b.step("test-verify-dist", "Check distribution validation, cleanup and failure gating without full qualification").dependOn(&run_verifier_tests.step);

    const archive = b.addSystemCommand(&.{
        "tar", "--format=gnu", "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner", "--mode=u+rwX,go+rX,go-w",
    });
    for (dist_layout.excluded) |name| archive.addArg(b.fmt("--exclude={s}", .{name}));
    archive.addArg("-czf");
    archive.setCwd(b.path("."));
    archive.has_side_effects = true;
    const source_archive = archive.addOutputFileArg("zig-json-query-0.37.0.tar.gz");
    archive.addArgs(dist_layout.roots);
    const install_archive = b.addInstallFileWithDir(source_archive, .prefix, "dist/zig-json-query-0.37.0.tar.gz");
    b.step("dist", "Package deterministic standalone sources (requires GNU tar)").dependOn(&install_archive.step);
}
