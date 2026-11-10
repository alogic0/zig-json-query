//! Small JSON query language. Program owns query text, AST and regexes.
//! A stream accepts JSON values and emits synchronous newline-delimited JSON.
const std = @import("std");
const regex = @import("regex");
const syntax = @import("parser.zig");
const Execution = @import("execution.zig");
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const StreamOptions = Execution.Options;
pub const max_input_bytes = 64 * 1024 * 1024;
pub const version = "0.1.0";

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    stages: []const syntax.Stage,
    patterns: []regex.Compiled,

    pub fn compile(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) !Program {
        diagnostic.* = .{};
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        if (source.len > 64 * 1024) {
            diagnostic.set(0, "query exceeds 64 KiB");
            return error.InvalidQuery;
        }
        const owned_source = try arena.allocator().dupe(u8, source);
        var parser: syntax.Parser = .{
            .allocator = arena.allocator(),
            .regex_allocator = allocator,
            .source = owned_source,
            .diagnostic = diagnostic,
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

    /// Returns whether another input value is needed. Once take is satisfied,
    /// later inputs are ignored without parsing. Never call after finish/failure.
    /// Input bytes are borrowed only for this call; collect keeps owned copies.
    pub fn feed(self: *Stream, input: []const u8) !bool {
        try self.execution.checkActive();
        self.execution.evaluator.diagnostic.* = .{};
        if (!self.needsInput()) return false;
        errdefer self.execution.abort();
        if (input.len > max_input_bytes) return error.InputTooLarge;
        try checkInputDepth(input, self.execution.evaluator.diagnostic);
        var scanner = std.json.Scanner.initCompleteInput(self.execution.allocator, input);
        defer scanner.deinit();
        var json_diagnostic: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&json_diagnostic);
        const parsed = std.json.parseFromTokenSource(std.json.Value, self.execution.allocator, &scanner, .{ .parse_numbers = false }) catch |err| {
            const diagnostic = self.execution.evaluator.diagnostic;
            diagnostic.input_offset = @intCast(json_diagnostic.getByteOffset());
            diagnostic.input_line = json_diagnostic.getLine();
            diagnostic.input_column = json_diagnostic.getColumn();
            return err;
        };
        defer parsed.deinit();
        try self.execution.push(parsed.value);
        return self.needsInput();
    }

    /// Finish ordered aggregates after EOF or early termination. Repeating this
    /// after success is a no-op. Failed sessions cannot emit buffered results.
    pub fn finish(self: *Stream) !void {
        self.execution.evaluator.diagnostic.* = .{};
        try self.execution.finish();
    }
};

fn checkInputDepth(input: []const u8, diagnostic: *Diagnostic) error{InputTooDeep}!void {
    var in_string = false;
    var escaped = false;
    var depth: usize = 0;
    var line: u64 = 1;
    var column: u64 = 0;
    for (input, 0..) |byte, offset| {
        column += 1;
        if (byte == '\n') {
            line += 1;
            column = 0;
        }
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
        } else switch (byte) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > 128) {
                    diagnostic.input_offset = offset;
                    diagnostic.input_line = line;
                    diagnostic.input_column = column;
                    return error.InputTooDeep;
                }
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
}

test {
    _ = @import("number.zig");
    _ = @import("tests.zig");
    _ = @import("stream_tests.zig");
    _ = @import("followup_tests.zig");
    _ = @import("property_tests.zig");
    _ = @import("fuzz_tests.zig");
}
