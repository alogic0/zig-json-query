//! Narrow builder observations are instrumented experiments, not additive CPU
//! budgets for the ordinary parser. Full-parser controls determine acceptance.
const std = @import("std");
const engine = @import("profile_engine");
const M = @import("study_support.zig");
const reference_builder = @import("reference_value_builder.zig");
const generated = @import("fixtures.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Event = engine.ValueBuilder.Event;
const Variant = enum { reference, control, current, current_control, counters, timed };
const Operation = struct {
    name: Event,
    calls: u64 = 0,
    elapsed_ns: ?u64 = null,
    logical_allocations: u64 = 0,
    logical_resize_attempts: u64 = 0,
    logical_remap_attempts: u64 = 0,
    logical_requested_bytes: u64 = 0,
    temporary_allocations: u64 = 0,
    temporary_resize_attempts: u64 = 0,
    temporary_remap_attempts: u64 = 0,
    temporary_requested_bytes: u64 = 0,
    backing_allocations: u64 = 0,
    backing_requested_bytes: u64 = 0,
};
const Instrumentation = struct { operations: []const Operation, temporary: M.Meter.Counters };
const Observation = struct { case: []const u8, variant: []const u8, iteration: usize, operations: []const Operation, temporary: M.Meter.Counters };

fn Probe(comptime timed: bool) type {
    return struct {
        const Self = @This();
        pub const Stamp = struct { logical: M.Meter.Counters, temporary: M.Meter.Counters, backing: M.Meter.Counters, start: if (timed) Io.Timestamp else void };
        io: Io,
        logical: *M.Meter,
        temporary: *M.Meter,
        backing: *M.Meter,
        operations: [std.enums.values(Event).len]Operation = initial(),

        fn initial() [std.enums.values(Event).len]Operation {
            var result: [std.enums.values(Event).len]Operation = undefined;
            for (std.enums.values(Event), 0..) |event, index| result[index] = .{ .name = event, .elapsed_ns = if (timed) 0 else null };
            return result;
        }

        pub fn begin(self: *Self, _: Event) Stamp {
            return .{ .logical = self.logical.counters, .temporary = self.temporary.counters, .backing = self.backing.counters, .start = if (timed) Io.Clock.awake.now(self.io) else {} };
        }

        pub fn end(self: *Self, event: Event, stamp: Stamp) void {
            const duration = if (timed) M.elapsed(stamp.start, self.io) else 0;
            const operation = &self.operations[@backingInt(event)];
            operation.calls += 1;
            if (timed) operation.elapsed_ns.? += duration;
            operation.logical_allocations += self.logical.counters.allocations - stamp.logical.allocations;
            operation.logical_resize_attempts += self.logical.counters.resize_attempts - stamp.logical.resize_attempts;
            operation.logical_remap_attempts += self.logical.counters.remap_attempts - stamp.logical.remap_attempts;
            operation.logical_requested_bytes += self.logical.counters.requested_bytes - stamp.logical.requested_bytes;
            operation.temporary_allocations += self.temporary.counters.allocations - stamp.temporary.allocations;
            operation.temporary_resize_attempts += self.temporary.counters.resize_attempts - stamp.temporary.resize_attempts;
            operation.temporary_remap_attempts += self.temporary.counters.remap_attempts - stamp.temporary.remap_attempts;
            operation.temporary_requested_bytes += self.temporary.counters.requested_bytes - stamp.temporary.requested_bytes;
            operation.backing_allocations += self.backing.counters.allocations - stamp.backing.allocations;
            operation.backing_requested_bytes += self.backing.counters.requested_bytes - stamp.backing.requested_bytes;
        }
    };
}

pub fn reference(a: A, bytes: []const u8, diagnostic: *engine.Diagnostic) !std.json.Parsed(std.json.Value) {
    if (bytes.len > engine.input.max_bytes) return error.InputTooLarge;
    try engine.input.checkDepth(bytes, diagnostic);
    var scanner = std.json.Scanner.initCompleteInput(a, bytes);
    defer scanner.deinit();
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    const parsed = std.json.parseFromTokenSource(reference_builder, a, &scanner, .{ .parse_numbers = false }) catch |err| {
        location(diagnostic, position);
        return err;
    };
    return .{ .arena = parsed.arena, .value = parsed.value.value };
}

fn location(diagnostic: *engine.Diagnostic, position: std.json.Diagnostics) void {
    diagnostic.input_offset = @intCast(position.getByteOffset());
    diagnostic.input_line = position.getLine();
    diagnostic.input_column = position.getColumn();
}

fn observed(a: A, scanner_a: A, bytes: []const u8, diagnostic: *engine.Diagnostic, probe: anytype) !std.json.Value {
    if (bytes.len > engine.input.max_bytes) return error.InputTooLarge;
    try engine.input.checkDepth(bytes, diagnostic);
    var scanner = std.json.Scanner.initCompleteInput(scanner_a, bytes);
    defer scanner.deinit();
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    const value = engine.ValueBuilder.build(a, scanner_a, &scanner, bytes.len, probe) catch |err| {
        location(diagnostic, position);
        return err;
    };
    const eof = scanner.next() catch |err| {
        location(diagnostic, position);
        return err;
    };
    std.debug.assert(eof == .end_of_document);
    return value;
}

fn verify(a: A, value: std.json.Value, expected: []const u8) !void {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(text);
    if (!std.mem.eql(u8, text, expected)) return error.BuilderOutputMismatch;
}

fn instrumented(comptime timed: bool, report_a: A, meter: *M.Meter, io: Io, bytes: []const u8, diagnostic: *engine.Diagnostic, expected: []const u8, record: *M.Record) !Instrumentation {
    const a = meter.allocator();
    const arena = try a.create(std.heap.ArenaAllocator);
    defer a.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var logical: M.Meter = .{ .backing = arena.allocator() };
    var temporary: M.Meter = .{ .backing = a };
    var probe: Probe(timed) = .{ .io = io, .logical = &logical, .temporary = &temporary, .backing = meter };
    const start = Io.Clock.awake.now(io);
    const value = try observed(logical.allocator(), temporary.allocator(), bytes, diagnostic, &probe);
    record.elapsed_ns = M.elapsed(start, io);
    record.logical = logical.counters;
    try verify(report_a, value, expected);
    if (temporary.counters.live_bytes != 0) return error.TemporaryAllocationLeak;
    return .{ .operations = try report_a.dupe(Operation, &probe.operations), .temporary = temporary.counters };
}

fn measure(report_a: A, backing: A, io: Io, id: []const u8, bytes: []const u8, expected: []const u8, variant: Variant, iteration: usize) !struct { record: M.Record, observation: ?Observation } {
    var meter: M.Meter = .{ .backing = backing };
    var diagnostic: engine.Diagnostic = .{};
    const before = meter.begin();
    var record: M.Record = .{ .case = id, .variant = @tagName(variant), .iteration = iteration, .elapsed_ns = 0, .memory = null };
    var instrumentation: ?Instrumentation = null;
    switch (variant) {
        .reference, .control, .current, .current_control => {
            const start = Io.Clock.awake.now(io);
            const parsed = if (variant == .reference or variant == .control) try reference(meter.allocator(), bytes, &diagnostic) else try engine.input.parse(meter.allocator(), bytes, &diagnostic);
            defer parsed.deinit();
            record.elapsed_ns = M.elapsed(start, io);
            try verify(report_a, parsed.value, expected);
        },
        .counters => instrumentation = try instrumented(false, report_a, &meter, io, bytes, &diagnostic, expected, &record),
        .timed => instrumentation = try instrumented(true, report_a, &meter, io, bytes, &diagnostic, expected, &record),
    }
    record.memory = meter.end(before);
    if (record.memory.?.end_live_bytes != 0) return error.StudyAllocationLeak;
    return .{ .record = record, .observation = if (instrumentation) |details| .{ .case = id, .variant = @tagName(variant), .iteration = iteration, .operations = details.operations, .temporary = details.temporary } else null };
}

pub fn run(init: std.process.Init, repeat: usize, out: ?[]const u8) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var guard = try M.Run.init(a, init.io, args[0], &.{ "tools/builder_study.zig", "tools/reference_value_builder.zig", "tools/parser_study.zig", "tests/qualification/backend.json" });
    const inputs = [_][]const u8{ "null", try Io.Dir.cwd().readFileAlloc(init.io, "tests/qualification/backend.json", a, .limited(4096)), try generated.generate(a, .commands, 2837), try generated.generate(a, .backend, 10000), try @import("parser_study.zig").variation(a), try variation(a, .flat), try variation(a, .nested), try variation(a, .wide) };
    const ids = [_][]const u8{ "null", "small-report", "commands", "backend", "escaped-nested-long-numbers", "flat-array", "nested-arrays", "wide-object" };
    var records: std.ArrayList(M.Record) = .empty;
    var observations: std.ArrayList(Observation) = .empty;
    const Check = struct { case: []const u8, bytes: usize, input_sha256: []const u8, output_sha256: []const u8 };
    var checks: std.ArrayList(Check) = .empty;
    var expected: std.ArrayList([]const u8) = .empty;
    for (inputs, ids) |bytes, id| {
        var diagnostic: engine.Diagnostic = .{};
        const parsed = try reference(a, bytes, &diagnostic);
        defer parsed.deinit();
        const text = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
        try expected.append(a, text);
        try checks.append(a, .{ .case = id, .bytes = bytes.len, .input_sha256 = try M.digest(a, bytes), .output_sha256 = try M.digest(a, text) });
        for (std.enums.values(Variant)) |variant| _ = try measure(a, init.gpa, init.io, id, bytes, text, variant, 0);
    }
    for (0..repeat) |iteration| for (inputs, ids, expected.items) |bytes, id, text| {
        for (0..std.enums.values(Variant).len) |step| {
            const variant = std.enums.values(Variant)[(iteration + step) % std.enums.values(Variant).len];
            const result = try measure(a, init.gpa, init.io, id, bytes, text, variant, iteration);
            try records.append(a, result.record);
            if (result.observation) |observation| try observations.append(a, observation);
        }
    };
    try guard.publish("builder", repeat, "One warm-up; rotated six variants. reference/control freeze the 0.22.0 builder; current/current_control use ordinary production parsing. counters/timed observe that same production builder above its arena; timed adds per-operation clocks. Logical operations are exclusive: recursive child parsing is outside append/object intervals. Indexed insertion includes hashing, duplicate lookup and any growth. EOF/depth/owner work is outside operation buckets. Narrow timings include instrumentation and are not an additive uninstrumented CPU budget; full-parser controls govern acceptance. Observed timing excludes arena-owner setup; ordinary timing includes it. Output checks and cleanup are outside timers. Backing allocation counts include the owner/scanner and must reach zero; logical arena requests are bulk reclaimed. Temporary counters independently wrap the caller allocator used by the scanner and temporary builder storage; temporary live bytes must return to zero. Compare arena plus temporary traffic when storage moves between owners. No production clocks or counters.", records.items, .{ .checks = checks.items, .observations = observations.items }, out);
}

fn variation(a: A, kind: enum { flat, nested, wide }) ![]const u8 {
    var text = Io.Writer.Allocating.init(a);
    defer text.deinit();
    try text.writer.writeByte(if (kind == .wide) '{' else '[');
    const length: usize = if (kind == .wide) 256 else 8192;
    for (0..length) |index| {
        if (index != 0) try text.writer.writeByte(',');
        switch (kind) {
            .flat => try text.writer.print("{d}", .{index}),
            .nested => try text.writer.writeAll("[0,1]"),
            .wide => try text.writer.print("\"field-{d}\":[0,1]", .{index}),
        }
    }
    try text.writer.writeByte(if (kind == .wide) '}' else ']');
    return text.toOwnedSlice();
}

test "builder observations preserve values diagnostics and classify all logical requests" {
    const t = std.testing;
    for ([_][]const u8{ "null", "{\"b\":[1,2],\"a\":\"é\\n\"}", "{\"a\":0,\"\\u0061\":[2]}", "[1,]", "{} []", "\"\\uD800\"", "{\"unused\":\"\xff\"}" }) |bytes| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var backing: M.Meter = .{ .backing = t.allocator };
        var region = std.heap.ArenaAllocator.init(backing.allocator());
        defer region.deinit();
        var logical: M.Meter = .{ .backing = region.allocator() };
        var temporary: M.Meter = .{ .backing = backing.allocator() };
        var probe: Probe(false) = .{ .io = t.io, .logical = &logical, .temporary = &temporary, .backing = &backing };
        var expected_diagnostic: engine.Diagnostic = .{};
        var actual_diagnostic: engine.Diagnostic = .{};
        const parsed = reference(t.allocator, bytes, &expected_diagnostic) catch |err| {
            try t.expectError(err, observed(logical.allocator(), temporary.allocator(), bytes, &actual_diagnostic, &probe));
            try t.expectEqual(expected_diagnostic.input_offset, actual_diagnostic.input_offset);
            try t.expectEqual(expected_diagnostic.input_line, actual_diagnostic.input_line);
            try t.expectEqual(expected_diagnostic.input_column, actual_diagnostic.input_column);
            try t.expectEqual(@as(u64, 0), temporary.counters.live_bytes);
            continue;
        };
        defer parsed.deinit();
        const value = try observed(logical.allocator(), temporary.allocator(), bytes, &actual_diagnostic, &probe);
        const expected = try std.json.Stringify.valueAlloc(arena.allocator(), parsed.value, .{});
        try verify(t.allocator, value, expected);
        var bytes_counted: u64 = 0;
        var allocations: u64 = 0;
        var temporary_bytes: u64 = 0;
        for (probe.operations) |operation| {
            bytes_counted += operation.logical_requested_bytes;
            allocations += operation.logical_allocations;
            temporary_bytes += operation.temporary_requested_bytes;
            try t.expectEqual(null, operation.elapsed_ns);
        }
        try t.expectEqual(logical.counters.requested_bytes, bytes_counted);
        try t.expectEqual(logical.counters.allocations, allocations);
        try t.expectEqual(temporary.counters.requested_bytes, temporary_bytes);
        try t.expectEqual(@as(u64, 0), temporary.counters.live_bytes);
    }
}

test "builder observations cover growth duplicate insertion finalization and arena seeding" {
    const t = std.testing;
    var report = std.heap.ArenaAllocator.init(t.allocator);
    defer report.deinit();
    var text = Io.Writer.Allocating.init(t.allocator);
    defer text.deinit();
    try text.writer.writeAll("{\"array\":[0,1,2],\"a\":0,\"b\":0,\"c\":0,\"d\":0,\"escaped\":\"\\u0061\",\"payload\":\"");
    for (0..64 * 1024) |_| try text.writer.writeByte('x');
    try text.writer.writeAll("\"}");
    var diagnostic: engine.Diagnostic = .{};
    const parsed = try reference(t.allocator, text.written(), &diagnostic);
    defer parsed.deinit();
    const expected = try std.json.Stringify.valueAlloc(report.allocator(), parsed.value, .{});
    const result = try measure(report.allocator(), t.allocator, t.io, "coverage", text.written(), expected, .counters, 0);
    var requests: u64 = 0;
    var allocations: u64 = 0;
    for (result.observation.?.operations) |operation| {
        try t.expect(operation.calls > 0);
        requests += operation.logical_requested_bytes;
        allocations += operation.logical_allocations;
    }
    try t.expectEqual(result.record.logical.?.requested_bytes, requests);
    try t.expectEqual(result.record.logical.?.allocations, allocations);
    try t.expectEqual(@as(u64, 0), result.record.memory.?.end_live_bytes);
}

test "builder instrumented allocation failures release every backing request" {
    const t = std.testing;
    for ([_]Variant{ .counters, .timed }) |variant| {
        var report = std.heap.ArenaAllocator.init(t.allocator);
        defer report.deinit();
        var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
        _ = try measure(report.allocator(), baseline.allocator(), t.io, "test", "{\"a\":[1,\"é\\n\"]}", "{\"a\":[1,\"é\\n\"]}", variant, 0);
        try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
        for (0..baseline.alloc_index) |index| {
            var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
            try t.expectError(error.OutOfMemory, measure(report.allocator(), failing.allocator(), t.io, "test", "{\"a\":[1,\"é\\n\"]}", "{\"a\":[1,\"é\\n\"]}", variant, 0));
            try t.expect(failing.has_induced_failure);
            try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
