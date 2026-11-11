//! Shared strict document parsing used by ordinary feeds and phase profiling.
const std = @import("std");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const ValueBuilder = @import("value_builder.zig");
pub const max_bytes = 64 * 1024 * 1024;

pub fn parse(allocator: std.mem.Allocator, input: []const u8, diagnostic: *Diagnostic) !std.json.Parsed(std.json.Value) {
    if (input.len > max_bytes) return error.InputTooLarge;
    try checkDepth(input, diagnostic);
    var scanner = std.json.Scanner.initCompleteInput(allocator, input);
    defer scanner.deinit();
    var json_diagnostic: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&json_diagnostic);
    const parsed = std.json.parseFromTokenSource(ValueBuilder, allocator, &scanner, .{ .parse_numbers = false }) catch |err| {
        diagnostic.input_offset = @intCast(json_diagnostic.getByteOffset());
        diagnostic.input_line = json_diagnostic.getLine();
        diagnostic.input_column = json_diagnostic.getColumn();
        return err;
    };
    return .{ .arena = parsed.arena, .value = parsed.value.value };
}

pub fn checkDepth(input: []const u8, diagnostic: *Diagnostic) error{InputTooDeep}!void {
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
