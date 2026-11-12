//! Small JSON query language. Program owns query text, AST and regexes.
//! A stream accepts JSON values and emits synchronous JSON/raw output.
//! Results are newline-delimited unless joined output is requested.
const std = @import("std");
const regex = @import("regex");
const syntax = @import("parser.zig");
const Execution = @import("execution.zig");
const Budget = @import("collection_budget.zig");
const Buffered = @import("buffered.zig");
const scalar = @import("evaluator.zig");
const input_json = @import("input.zig");
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const StreamOptions = Execution.Options;
pub const max_input_bytes = input_json.max_bytes;
pub const version = "0.33.0";

/// Owned by Program after compilation; caller buffers are only borrowed during
/// compileWithBindings. JSON values retain exact number tokens.
pub const Binding = struct {
    name: []const u8,
    value: union(enum) { string: []const u8, json: []const u8 },
};

fn invalidBinding(diagnostic: *Diagnostic, message: []const u8) error{InvalidBinding} {
    diagnostic.set(0, message);
    return error.InvalidBinding;
}

fn bindingName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    stages: []const syntax.Stage,
    patterns: []regex.Compiled,

    pub fn compile(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !Program {
        return compileWithBindings(allocator, source, &.{}, diagnostic);
    }

    pub fn compileWithBindings(allocator: std.mem.Allocator, source: []const u8, bindings: []const Binding, diagnostic: *Diagnostic) !Program {
        diagnostic.* = .{};
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        if (source.len > 64 * 1024) {
            diagnostic.set(0, "query exceeds 64 KiB");
            return error.InvalidQuery;
        }
        const owned_source = try arena.allocator().dupe(u8, source);
        if (bindings.len > 128) return invalidBinding(diagnostic, "at most 128 external bindings are allowed");
        const values = try arena.allocator().alloc(syntax.BoundValue, bindings.len);
        var total: usize = 0;
        for (bindings, 0..) |binding, index| {
            if (!bindingName(binding.name)) return invalidBinding(diagnostic, "binding names must match [A-Za-z_][A-Za-z0-9_]*");
            for (bindings[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, binding.name)) return invalidBinding(diagnostic, "duplicate external binding name");
            const text = switch (binding.value) {
                inline else => |value| value,
            };
            if (text.len > max_input_bytes - total) return invalidBinding(diagnostic, "external binding value text exceeds 64 MiB");
            total += text.len;
            const owned = try arena.allocator().dupe(u8, text);
            const value: std.json.Value = switch (binding.value) {
                .string => blk: {
                    if (!std.unicode.utf8ValidateSlice(owned)) return invalidBinding(diagnostic, "string bindings must contain valid UTF-8");
                    break :blk .{ .string = owned };
                },
                .json => blk: {
                    checkInputDepth(owned, diagnostic) catch return invalidBinding(diagnostic, "JSON binding nesting exceeds 128 levels");
                    break :blk std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), owned, .{ .parse_numbers = false }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return invalidBinding(diagnostic, "JSON bindings require one valid JSON value without duplicate keys"),
                    };
                },
            };
            values[index] = .{ .name = try arena.allocator().dupe(u8, binding.name), .value = value };
        }
        var parser: syntax.Parser = .{
            .allocator = arena.allocator(),
            .regex_allocator = allocator,
            .source = owned_source,
            .diagnostic = diagnostic,
            .bindings = values,
        };
        errdefer parser.deinitPatterns();
        const stages = try parser.parse();
        return .{
            .allocator = allocator,
            .arena = arena,
            .source = owned_source,
            .stages = stages,
            .patterns = try parser.patterns.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Program) void {
        for (self.patterns) |*pattern| pattern.deinit();
        self.allocator.free(self.patterns);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Create an independent session. The program, writer and diagnostic must
    /// outlive the stream. Finish on EOF/early termination, then deinit once.
    pub fn start(self: *const Program, allocator: std.mem.Allocator, writer: *std.Io.Writer, diagnostic: *Diagnostic, options: StreamOptions) !Stream {
        diagnostic.* = .{};
        return .{ .execution = try Execution.init(allocator, self.stages, self.patterns, writer, diagnostic, options) };
    }

    /// One-document convenience: create a session, feed one value, then finish.
    pub fn run(self: *const Program, allocator: std.mem.Allocator, input: []const u8, writer: *std.Io.Writer, diagnostic: *Diagnostic) !void {
        var stream = try self.start(allocator, writer, diagnostic, .{});
        defer stream.deinit();
        _ = try stream.feed(input);
        try stream.finish();
    }
};

pub const Stream = struct {
    execution: *Execution,

    pub fn deinit(self: *Stream) void {
        self.execution.deinit();
        self.* = undefined;
    }

    pub fn needsInput(self: *const Stream) bool {
        return self.execution.needsInput();
    }

    /// After successful completion: 0 for a last value other than false/null,
    /// 1 for false/null, 4 for no output. Execution/IO failures take precedence.
    pub fn predicateStatus(self: *const Stream) u8 {
        return self.execution.predicateStatus();
    }

    /// Returns whether another input value is needed. Once take is satisfied,
    /// later inputs are ignored without parsing. Never call after finish/failure.
    /// Input bytes are borrowed only for this call; collect keeps owned copies.
    pub fn feed(self: *Stream, input: []const u8) !bool {
        return self.feedNamed(input, null);
    }

    /// Filename metadata is borrowed only until this call returns; retained
    /// results own copies. A null name means no unique source filename.
    pub fn feedNamed(self: *Stream, input: []const u8, filename: ?[]const u8) !bool {
        try self.execution.checkActive();
        self.execution.evaluator.diagnostic.* = .{};
        if (!self.needsInput()) return false;
        errdefer self.execution.abort();
        const parsed = try parseInput(self.execution.allocator, input, self.execution.evaluator.diagnostic);
        defer parsed.deinit();
        self.execution.evaluator.input_filename = filename;
        defer self.execution.evaluator.input_filename = null;
        try self.execution.push(parsed.value);
        return self.needsInput();
    }

    /// Feed one validated, owned array. Slurped input has no unique filename.
    /// The collector must remain alive until this synchronous call returns.
    pub fn feedSlurp(self: *Stream, slurp: *const Slurp) !bool {
        try self.execution.checkActive();
        self.execution.evaluator.diagnostic.* = .{};
        if (!self.needsInput()) return false;
        errdefer self.execution.abort();
        if (slurp.failed) return error.StreamFailed;
        var view = std.json.Array.init(self.execution.allocator);
        view.items = slurp.items.items;
        view.capacity = view.items.len;
        try self.execution.push(.{ .array = view });
        return self.needsInput();
    }

    /// Finish ordered aggregates after EOF or early termination. Repeating this
    /// after success is a no-op. Failed sessions cannot emit buffered results.
    pub fn finish(self: *Stream) !void {
        self.execution.evaluator.diagnostic.* = .{};
        try self.execution.finish();
    }
};

/// Owned input array with a separate retained-allocation budget. Pointer identity
/// is stable because the arena allocator borrows the embedded budget.
pub const Slurp = struct {
    backing: std.mem.Allocator,
    budget: Budget,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(std.json.Value) = .empty,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) !*Slurp {
        const self = try allocator.create(Slurp);
        self.* = .{ .backing = allocator, .budget = .{ .backing = allocator, .limit = max_bytes }, .arena = undefined };
        self.arena = .init(self.budget.allocator());
        return self;
    }

    pub fn deinit(self: *Slurp) void {
        self.arena.deinit();
        std.debug.assert(self.budget.used == 0);
        const allocator = self.backing;
        allocator.destroy(self);
    }

    pub fn append(self: *Slurp, input: []const u8, diagnostic: *Diagnostic) !void {
        diagnostic.* = .{};
        if (self.failed) return error.StreamFailed;
        errdefer self.failed = true;
        const parsed = try parseInput(self.backing, input, diagnostic);
        defer parsed.deinit();
        if (!scalar.withinDepth(parsed.value, 1)) return error.InputTooDeep;
        self.budget.denied = false;
        self.appendOwned(parsed.value) catch |err| {
            if (self.budget.denied) {
                diagnostic.setBudget(0, "slurp exceeded the owned-input memory limit", .{ .kind = .slurp, .limit = self.budget.limit, .retained = self.budget.denied_used, .requested = self.budget.denied_request });
                return error.SlurpTooLarge;
            }
            return err;
        };
    }

    fn appendOwned(self: *Slurp, value: std.json.Value) !void {
        const allocator = self.arena.allocator();
        try self.items.append(allocator, try Buffered.clone(allocator, value));
    }
};

const parseInput = input_json.parse;
const checkInputDepth = input_json.checkDepth;

test {
    _ = @import("number.zig");
    _ = @import("tests.zig");
    _ = @import("stream_tests.zig");
    _ = @import("followup_tests.zig");
    _ = @import("summary_tests.zig");
    _ = @import("automation_tests.zig");
    _ = @import("batch_tests.zig");
    _ = @import("predicate_tests.zig");
    _ = @import("statistics_tests.zig");
    _ = @import("aggregate_tests.zig");
    _ = @import("serialization_tests.zig");
    _ = @import("edit_tests.zig");
    _ = @import("structural_tests.zig");
    _ = @import("memory_tests.zig");
    _ = @import("group_totals_tests.zig");
    _ = @import("key_index_tests.zig");
    _ = @import("input_tests.zig");
    _ = @import("property_tests.zig");
    _ = @import("fuzz_tests.zig");
}
