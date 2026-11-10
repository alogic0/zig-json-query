const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("json_query", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "query", .module = dependency.module("query") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Exercise the query library from a separate package").dependOn(&b.addRunArtifact(tests).step);
}
