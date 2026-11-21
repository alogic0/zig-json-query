const std = @import("std");

/// Bounded JSONPath. Truncation is explicit, and never retains input bytes.
pub const Path = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn root() Path {
        var result: Path = .{};
        result.bytes[0] = '$';
        result.len = 1;
        return result;
    }

    pub fn field(self: *Path, key: []const u8) void {
        if (self.truncated) return;
        var writer = std.Io.Writer.fixed(self.bytes[self.len..]);
        writeField(&writer, key) catch {
            self.truncated = true;
            return;
        };
        self.len += writer.end;
    }

    fn writeField(writer: *std.Io.Writer, key: []const u8) !void {
        try writer.writeByte('[');
        try std.json.Stringify.value(key, .{}, writer);
        try writer.writeByte(']');
    }

    pub fn index(self: *Path, value: usize) void {
        self.writeIndex(value, false);
    }

    pub fn indexFromEnd(self: *Path, value: usize) void {
        self.writeIndex(value, true);
    }

    fn writeIndex(self: *Path, value: usize, negative: bool) void {
        if (self.truncated) return;
        const bytes = std.fmt.bufPrint(self.bytes[self.len..], "[{s}{d}]", .{ if (negative) "-" else "", value }) catch {
            self.truncated = true;
            return;
        };
        self.len += bytes.len;
    }

    pub fn write(self: *const Path, writer: *std.Io.Writer) !void {
        try writer.writeAll(self.bytes[0..self.len]);
        if (self.truncated) try writer.writeAll("...");
    }
};

pub const Diagnostic = struct {
    /// Compact JSON owned by the diagnostic. An oversized object has no partial detail.
    pub const Assertion = struct {
        pub const max_bytes = 4096;
        bytes: [max_bytes]u8 = undefined,
        len: ?usize = null,

        pub fn detail(self: *const Assertion) ?[]const u8 {
            const length = self.len orelse return null;
            return self.bytes[0..length];
        }

        pub fn write(self: *const Assertion, writer: *std.Io.Writer) !void {
            if (self.detail()) |json| {
                try writer.writeAll("{\"kind\":\"assertion_failed\",\"detail\":");
                try writer.writeAll(json);
                try writer.writeAll("}\n");
            } else try writer.writeAll("{\"kind\":\"assertion_failed\",\"truncated\":true}\n");
        }
    };
    pub const BudgetKind = enum { retained, slurp };
    pub const BudgetFailure = struct { kind: BudgetKind, limit: usize, retained: usize, requested: usize };
    offset: usize = 0,
    message: []const u8 = "",
    input_offset: ?usize = null,
    input_line: u64 = 1,
    input_column: u64 = 1,
    path: Path = .{},
    path_reported: bool = false,
    element_index: ?usize = null,
    budget: ?BudgetFailure = null,
    assertion: ?Assertion = null,

    pub fn setAssertion(self: *Diagnostic, offset: usize, path: Path, object: std.json.Value) void {
        self.* = .{ .offset = offset, .message = "assertion failed", .path = path, .path_reported = true, .assertion = .{} };
        const failure = &self.assertion.?;
        var writer = std.Io.Writer.fixed(&failure.bytes);
        // This writer can only fail when its fixed storage is full.
        std.json.Stringify.value(object, .{}, &writer) catch return;
        failure.len = writer.end;
    }

    pub fn set(self: *Diagnostic, offset: usize, message: []const u8) void {
        self.* = .{ .offset = offset, .message = message };
    }

    pub fn setBudget(self: *Diagnostic, offset: usize, message: []const u8, failure: BudgetFailure) void {
        self.set(offset, message);
        self.budget = failure;
    }

    pub fn writeBudget(self: Diagnostic, writer: *std.Io.Writer) !void {
        const failure = self.budget orelse return;
        try writer.print("{s} allocation budget: limit={d} bytes, retained={d} bytes, requested={d} bytes\n", .{ @tagName(failure.kind), failure.limit, failure.retained, failure.requested });
        try writer.writeAll(switch (failure.kind) {
            .retained => "increase --max-retained-bytes or reduce retained data\n",
            .slurp => "increase --max-slurp-bytes or avoid -s when stream stages suffice\n",
        });
    }

    pub fn write(self: Diagnostic, source: []const u8, writer: *std.Io.Writer) !void {
        try self.writeNamed(source, "query", writer);
    }

    pub fn writeNamed(self: Diagnostic, source: []const u8, label: []const u8, writer: *std.Io.Writer) !void {
        const offset = @min(self.offset, source.len);
        var line: usize = 1;
        var start: usize = 0;
        for (source[0..offset], 0..) |byte, index| {
            if (byte == '\n') {
                line += 1;
                start = index + 1;
            }
        }
        const end = if (std.mem.indexOfScalarPos(u8, source, offset, '\n')) |n| n else source.len;
        try writer.print("{s}:{d}:{d}: {s}\n", .{ label, line, offset - start + 1, self.message });
        try excerpt(source, offset, start, end, writer);
        if (self.path.len != 0) {
            try writer.writeAll("input path: ");
            try self.path.write(writer);
            try writer.writeByte('\n');
        }
        if (self.element_index) |index| try writer.print("array element index: {d}\n", .{index});
        try self.writeBudget(writer);
    }

    pub fn writeInput(self: Diagnostic, input: []const u8, writer: *std.Io.Writer) !void {
        const offset = @min(self.input_offset orelse 0, input.len);
        const start = if (std.mem.lastIndexOfScalar(u8, input[0..offset], '\n')) |n| n + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, input, offset, '\n') orelse input.len;
        try excerpt(input, offset, start, end, writer);
    }

    fn excerpt(source: []const u8, offset: usize, line_start: usize, line_end: usize, writer: *std.Io.Writer) !void {
        const start = @max(line_start, offset -| 80);
        const end = @min(line_end, start +| 160);
        try writer.print("  {s}\n  ", .{source[start..end]});
        for (source[start..offset]) |byte| try writer.writeByte(if (byte == '\t') '\t' else ' ');
        try writer.writeAll("^\n");
    }
};
