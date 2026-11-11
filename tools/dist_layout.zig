//! Single source of truth for the source distribution's payload and exclusions.
pub const roots: []const []const u8 = &.{ "build.zig", "build.zig.zon", ".zigversion", ".gitignore", "AGENTS.md", "src", "tests", "examples", "docs", "tools", "vendor", "README.md", "DESIGN.md" };
pub const excluded: []const []const u8 = &.{ ".git", ".zig-cache", "zig-pkg", "zig-out" };
