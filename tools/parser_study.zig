//! Separate experiments; scanner-only work is not a fully validated DOM parse.
const std = @import("std");
const engine = @import("profile_engine");
const M = @import("study_support.zig");
const generated = @import("fixtures.zig");
const A = std.mem.Allocator;
const Io = std.Io;
pub const Variant = enum { depth, scan_copy, scan_borrow, standard_dom, standard, control, current };
const Tokens = struct { total: usize = 0, strings: usize = 0, numbers: usize = 0, containers: usize = 0, allocated_tokens: usize = 0, allocated_bytes: usize = 0 };

fn count(stats: *Tokens, token: std.json.Token) void {
    stats.total += 1;
    switch (token) {
        .string => stats.strings += 1,
        .number => stats.numbers += 1,
        .allocated_string => |text| {
            stats.strings += 1;
            stats.allocated_tokens += 1;
            stats.allocated_bytes += text.len;
        },
        .allocated_number => |text| {
            stats.numbers += 1;
            stats.allocated_tokens += 1;
            stats.allocated_bytes += text.len;
        },
        .array_begin, .object_begin => stats.containers += 1,
        else => {},
    }
}
const Source = struct {
    scanner: *std.json.Scanner,
    meter: *M.Meter,
    tokens: Tokens = .{},
    traffic: M.Traffic = .{},
    pub const NextError = std.json.Scanner.NextError;
    pub const PeekError = std.json.Scanner.PeekError;
    pub const AllocError = std.json.Scanner.AllocError;
    pub fn peekNextTokenType(self: *Source) PeekError!std.json.TokenType {
        return self.scanner.peekNextTokenType();
    }
    pub fn next(self: *Source) NextError!std.json.Token {
        return self.scanner.next();
    }
    pub fn nextAllocMax(self: *Source, a: A, when: std.json.AllocWhen, max: usize) AllocError!std.json.Token {
        const before = self.meter.counters;
        defer {
            self.traffic.allocations += self.meter.counters.allocations - before.allocations;
            self.traffic.requested_bytes += self.meter.counters.requested_bytes - before.requested_bytes;
        }
        const token = try self.scanner.nextAllocMax(a, when, max);
        count(&self.tokens, token);
        return token;
    }
};

// Frozen standard-library boundary equivalent to input.parse in jqz 0.18.1.
pub fn standard(a: A, bytes: []const u8, diagnostic: *engine.Diagnostic) !std.json.Parsed(std.json.Value) {
    if (bytes.len > engine.input.max_bytes) return error.InputTooLarge;
    try engine.input.checkDepth(bytes, diagnostic);
    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    defer scanner.deinit();
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    return std.json.parseFromTokenSource(std.json.Value, a, &scanner, .{ .parse_numbers = false }) catch |err| {
        location(diagnostic, position);
        return err;
    };
}
fn location(diagnostic: *engine.Diagnostic, position: std.json.Diagnostics) void {
    diagnostic.input_offset = @intCast(position.getByteOffset());
    diagnostic.input_line = position.getLine();
    diagnostic.input_column = position.getColumn();
}
fn dom(a: A, scanner_a: A, meter: *M.Meter, bytes: []const u8, diagnostic: *engine.Diagnostic) !struct { value: std.json.Value, traffic: M.Traffic, tokens: Tokens } {
    var scanner = std.json.Scanner.initCompleteInput(scanner_a, bytes);
    defer scanner.deinit();
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    var source: Source = .{ .scanner = &scanner, .meter = meter };
    const value = std.json.parseFromTokenSourceLeaky(std.json.Value, a, &source, .{ .parse_numbers = false, .max_value_len = bytes.len, .allocate = .alloc_if_needed }) catch |err| {
        location(diagnostic, position);
        return err;
    };
    return .{ .value = value, .traffic = source.traffic, .tokens = source.tokens };
}

fn measure(report_a: A, backing: A, io: Io, id: []const u8, bytes: []const u8, expected: []const u8, variant: Variant, iteration: usize) !M.Record {
    var meter: M.Meter = .{ .backing = backing };
    const a = meter.allocator();
    var diagnostic: engine.Diagnostic = .{};
    const before = meter.begin();
    const start = Io.Clock.awake.now(io);
    var record: M.Record = .{ .case = id, .variant = @tagName(variant), .iteration = iteration, .elapsed_ns = 0, .memory = undefined };
    switch (variant) {
        .depth => {
            try engine.input.checkDepth(bytes, &diagnostic);
            record.elapsed_ns = M.elapsed(start, io);
        },
        .scan_copy, .scan_borrow => {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var scanner = std.json.Scanner.initCompleteInput(arena.allocator(), bytes);
            defer scanner.deinit();
            while (try scanner.nextAllocMax(arena.allocator(), if (variant == .scan_copy) .alloc_always else .alloc_if_needed, bytes.len) != .end_of_document) {}
            record.elapsed_ns = M.elapsed(start, io);
        },
        .standard_dom => {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var logical: M.Meter = .{ .backing = arena.allocator() };
            const result = try dom(logical.allocator(), a, &logical, bytes, &diagnostic);
            record.elapsed_ns = M.elapsed(start, io);
            record.logical = logical.counters;
            record.token_traffic = result.traffic;
            const encoded = try std.json.Stringify.valueAlloc(report_a, result.value, .{});
            defer report_a.free(encoded);
            if (!std.mem.eql(u8, encoded, expected)) return error.StudyOutputMismatch;
        },
        .standard, .control, .current => {
            const parsed = if (variant == .current) try engine.input.parse(a, bytes, &diagnostic) else try standard(a, bytes, &diagnostic);
            defer parsed.deinit();
            record.elapsed_ns = M.elapsed(start, io);
            const encoded = try std.json.Stringify.valueAlloc(report_a, parsed.value, .{});
            defer report_a.free(encoded);
            if (!std.mem.eql(u8, encoded, expected)) return error.StudyOutputMismatch;
        },
    }
    record.memory = meter.end(before);
    if (record.memory.?.end_live_bytes != 0) return error.StudyAllocationLeak;
    return record;
}

pub fn run(init: std.process.Init, repeat: usize, out: ?[]const u8) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var guard = try M.Run.init(a, init.io, args[0], &.{ "tools/parser_study.zig", "tests/qualification/backend.json" });
    const inputs = [_][]const u8{ "null", try Io.Dir.cwd().readFileAlloc(init.io, "tests/qualification/backend.json", a, .limited(4096)), try generated.generate(a, .commands, 2837), try generated.generate(a, .backend, 10000), try variation(a) };
    const ids = [_][]const u8{ "null", "small-report", "commands", "backend", "escaped-nested-long-numbers" };
    var records: std.ArrayList(M.Record) = .empty;
    const Check = struct { case: []const u8, bytes: usize, input_sha256: []const u8, output_sha256: []const u8, tokens: Tokens };
    var checks: std.ArrayList(Check) = .empty;
    var expected: std.ArrayList([]const u8) = .empty;
    for (inputs, ids) |bytes, id| {
        var diagnostic: engine.Diagnostic = .{};
        const parsed = try standard(a, bytes, &diagnostic);
        defer parsed.deinit();
        const encoded = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
        try expected.append(a, encoded);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var logical: M.Meter = .{ .backing = arena.allocator() };
        const result = try dom(logical.allocator(), a, &logical, bytes, &diagnostic);
        try checks.append(a, .{ .case = id, .bytes = bytes.len, .input_sha256 = try M.digest(a, bytes), .output_sha256 = try M.digest(a, encoded), .tokens = result.tokens });
        for (std.enums.values(Variant)) |variant| _ = try measure(a, init.gpa, init.io, id, bytes, encoded, variant, 0);
    }
    for (0..repeat) |iteration| for (inputs, ids, expected.items) |bytes, id, encoded| {
        for (0..std.enums.values(Variant).len) |step| {
            const variant = std.enums.values(Variant)[(iteration + step) % std.enums.values(Variant).len];
            try records.append(a, try measure(a, init.gpa, init.io, id, bytes, encoded, variant, iteration));
        }
    };
    try guard.publish("parser", repeat, "One warm-up; rotated variants. standard/control are the same frozen 0.18.1 std.json.Value parser; current is the production boundary. Scan-only/depth experiments overlap full parse and are not additive or fully equivalent validation. standard_dom uses the same Value parser, a counter above its explicit arena and a separate backing counter; token traffic is nested allocation activity, not a timing subtraction. Logical outstanding requests are reclaimed in bulk by arena release; only backing must reach zero. Encoding/checks are outside timers. No production clocks or standard-library changes.", records.items, .{ .checks = checks.items }, out);
}

fn variation(a: A) ![]const u8 {
    var bytes = Io.Writer.Allocating.init(a);
    defer bytes.deinit();
    for (0..32) |_| try bytes.writer.writeByte('[');
    try bytes.writer.writeByte('[');
    for (0..32) |index| {
        if (index != 0) try bytes.writer.writeByte(',');
        try bytes.writer.writeAll("{\"a\\u002db\":\"é😀\\n\\\"\\\\\",\"number\":1");
        for (0..128) |_| try bytes.writer.writeByte('0');
        try bytes.writer.writeAll("e-100,\"items\":[null,true,false]}");
    }
    try bytes.writer.writeByte(']');
    for (0..32) |_| try bytes.writer.writeByte(']');
    return bytes.toOwnedSlice();
}

test "parser probe agrees on exact text and duplicate diagnostics" {
    const t = std.testing;
    for ([_][]const u8{ "null", "{\"z\":9007199254740993,\"a\":\"é\\n\"}", "{\"a\":1,\"\\u0061\":{\"nested\":2}}", "[1,]", "\"\\uD800\"", "1e", "{} []", "" }) |input| {
        var baseline_diagnostic: engine.Diagnostic = .{};
        var measured_diagnostic: engine.Diagnostic = .{};
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var logical: M.Meter = .{ .backing = arena.allocator() };
        const reference = standard(t.allocator, input, &baseline_diagnostic) catch |err| {
            try t.expectError(err, dom(logical.allocator(), t.allocator, &logical, input, &measured_diagnostic));
            try t.expectEqual(baseline_diagnostic.input_offset, measured_diagnostic.input_offset);
            try t.expectEqual(baseline_diagnostic.input_line, measured_diagnostic.input_line);
            try t.expectEqual(baseline_diagnostic.input_column, measured_diagnostic.input_column);
            continue;
        };
        defer reference.deinit();
        const measured = try dom(logical.allocator(), t.allocator, &logical, input, &measured_diagnostic);
        const expected = try std.json.Stringify.valueAlloc(t.allocator, reference.value, .{});
        defer t.allocator.free(expected);
        const actual = try std.json.Stringify.valueAlloc(t.allocator, measured.value, .{});
        defer t.allocator.free(actual);
        try t.expectEqualStrings(expected, actual);
    }
}

test "parser study allocation failures release scanner and explicit arena owners" {
    const t = std.testing;
    for ([_]Variant{ .standard_dom, .standard, .scan_copy }) |variant| {
        var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
        _ = try measure(t.allocator, baseline.allocator(), t.io, "test", "{\"x\":[1,\"é\\n\"]}", "{\"x\":[1,\"é\\n\"]}", variant, 0);
        try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
        for (0..baseline.alloc_index) |index| {
            var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
            try t.expectError(error.OutOfMemory, measure(t.allocator, failing.allocator(), t.io, "test", "{\"x\":[1,\"é\\n\"]}", "{\"x\":[1,\"é\\n\"]}", variant, 0));
            try t.expect(failing.has_induced_failure);
            try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
