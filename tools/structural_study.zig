const std = @import("std");
const engine = @import("profile_engine");
const M = @import("study_support.zig");
const generated = @import("fixtures.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const Case = struct { id: []const u8, bytes: []const u8, source_query: []const u8, query: []const u8 };

// Frozen comparison-copy behavior before this plan's structural optimization.
fn referenceOrder(a: A, value: Value) error{OutOfMemory}!Value {
    return switch (value) {
        .object => |object| blk: {
            const keys = try a.dupe([]const u8, object.keys());
            std.sort.pdq([]const u8, keys, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.less);
            var result: std.json.ObjectMap = .empty;
            for (keys) |key| try result.put(a, key, try referenceOrder(a, object.get(key).?));
            break :blk .{ .object = result };
        },
        .array => |array| blk: {
            var result = std.json.Array.init(a);
            try result.ensureTotalCapacity(array.items.len);
            for (array.items) |item| result.appendAssumeCapacity(try referenceOrder(a, item));
            break :blk .{ .array = result };
        },
        else => value,
    };
}

const Trace = struct {
    backing: *M.Meter,
    logical: *M.Meter,
    io: Io,
    report_a: A,
    records: *std.ArrayList(M.Record),
    id: []const u8,
    variant: []const u8,
    iteration: usize,
    before: M.Meter.Counters = .{},
    logical_before: M.Meter.Counters = .{},
    start: Io.Timestamp = undefined,
    pub fn begin(self: *Trace) void {
        self.before = self.backing.begin();
        self.logical_before = self.logical.begin();
        self.start = Io.Clock.awake.now(self.io);
    }
    pub fn end(self: *Trace, phase: []const u8) !void {
        const duration = M.elapsed(self.start, self.io);
        try self.records.append(self.report_a, .{ .case = self.id, .variant = try std.fmt.allocPrint(self.report_a, "{s}/{s}", .{ self.variant, phase }), .iteration = self.iteration, .elapsed_ns = duration, .memory = self.backing.end(self.before), .logical_delta = self.logical.end(self.logical_before) });
    }
};

fn pipeline(comptime trace: bool, a: A, evaluator: *engine.Evaluator, source_node: anytype, input: Value, use_current_order: bool, recorder: *Trace) !Value {
    if (trace) recorder.begin();
    const source = try evaluator.evalRequired(a, source_node, input);
    if (source != .array) return error.ExpectedArray;
    if (trace) try recorder.end("source");
    if (trace) recorder.begin();
    const rows = try a.alloc(engine.RowOps.Row, source.array.items.len);
    for (source.array.items, 0..) |item, index| {
        _ = try evaluator.equal(item, item, 0, 0);
        rows[index] = .{ .value = item, .key = if (use_current_order) try engine.JsonOrder.ordered(a, item) else try referenceOrder(a, item) };
    }
    if (trace) try recorder.end("prepare");
    if (trace) recorder.begin();
    engine.RowOps.sortStructural(rows);
    if (trace) try recorder.end("sort");
    var selected = rows;
    if (use_current_order) {
        if (trace) recorder.begin();
        selected = engine.RowOps.distinct(rows);
        if (trace) try recorder.end("compact");
    }
    if (trace) recorder.begin();
    var result = std.json.Array.init(a);
    try result.ensureTotalCapacity(selected.len);
    if (trace) try recorder.end("reserve");
    if (trace) recorder.begin();
    var previous: ?Value = null;
    for (selected) |row| {
        if (!use_current_order) if (previous) |key| {
            if (engine.JsonOrder.compare(key, row.key) == .eq) continue;
        };
        result.appendAssumeCapacity(row.value);
        previous = row.key;
    }
    if (trace) try recorder.end(if (use_current_order) "fill" else "dedup_fill");
    return .{ .array = result };
}

fn verify(a: A, value: Value, expected: []const u8) !void {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(text);
    if (!std.mem.eql(u8, text, expected)) return error.StructuralOutputMismatch;
}

fn measure(report_a: A, backing: A, io: Io, case: Case, input: Value, source_program: *const engine.Program, full_program: *const engine.Program, expected: []const u8, variant: usize, iteration: usize, records: *std.ArrayList(M.Record)) !void {
    var meter: M.Meter = .{ .backing = backing };
    var arena = std.heap.ArenaAllocator.init(meter.allocator());
    var arena_live = true;
    defer if (arena_live) arena.deinit();
    var logical: M.Meter = .{ .backing = arena.allocator() };
    const a = logical.allocator();
    var diagnostic: engine.Diagnostic = .{};
    var evaluator: engine.Evaluator = .{ .patterns = source_program.patterns, .diagnostic = &diagnostic, .path = .root() };
    var recorder: Trace = .{ .backing = &meter, .logical = &logical, .io = io, .report_a = report_a, .records = records, .id = case.id, .variant = if (variant == 0) "reference" else "current", .iteration = iteration };
    const before = meter.begin();
    const start = Io.Clock.awake.now(io);
    const value = switch (variant) {
        0, 1 => try pipeline(true, a, &evaluator, source_program.stages[0].expression, input, variant == 1, &recorder),
        2, 3 => try pipeline(false, a, &evaluator, source_program.stages[0].expression, input, false, &recorder),
        4 => try evaluator.evalRequired(a, full_program.stages[0].expression, input),
        else => unreachable,
    };
    const duration = M.elapsed(start, io);
    try verify(report_a, value, expected);
    if (variant >= 2) {
        const logical_snapshot = logical.counters;
        arena.deinit();
        arena_live = false;
        try records.append(report_a, .{ .case = case.id, .variant = if (variant == 2) "full-reference" else if (variant == 3) "full-control" else "full-current", .iteration = iteration, .elapsed_ns = duration, .memory = meter.end(before), .logical = logical_snapshot });
    } else {
        recorder.begin();
        arena.deinit();
        arena_live = false;
        try recorder.end("release");
    }
    if (meter.counters.live_bytes != 0) return error.StudyAllocationLeak;
}

pub fn run(init: std.process.Init, repeat: usize, out: ?[]const u8) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var guard = try M.Run.init(a, init.io, args[0], &.{"tools/structural_study.zig"});
    const cases = [_]Case{
        .{ .id = "repeated-schema", .bytes = try generated.generate(a, .backend, 10000), .source_query = "map(.fixtures,keys(.))", .query = "unique(map(.fixtures,keys(.)))" },
        .{ .id = "all-distinct", .bytes = try variation(a, .distinct), .source_query = "map(.fixtures,keys(.))", .query = "unique(map(.fixtures,keys(.)))" },
        .{ .id = "mixed", .bytes = try variation(a, .mixed), .source_query = ".items", .query = "unique(.items)" },
        .{ .id = "nested-ordered", .bytes = try variation(a, .ordered), .source_query = ".items", .query = "unique(.items)" },
        .{ .id = "nested-unordered", .bytes = try variation(a, .unordered), .source_query = ".items", .query = "unique(.items)" },
    };
    const Check = struct { case: []const u8, query: []const u8, input_sha256: []const u8, output_sha256: []const u8, bytes: usize };
    var checks: std.ArrayList(Check) = .empty;
    var records: std.ArrayList(M.Record) = .empty;
    for (cases) |case| {
        var diagnostic: engine.Diagnostic = .{};
        const parsed = try engine.input.parse(init.gpa, case.bytes, &diagnostic);
        defer parsed.deinit();
        var source_program = try engine.Program.compile(a, case.source_query, &diagnostic);
        defer source_program.deinit();
        var program = try engine.Program.compile(a, case.query, &diagnostic);
        defer program.deinit();
        var output = Io.Writer.Allocating.init(a);
        try program.run(a, case.bytes, &output.writer, &diagnostic);
        const expected = output.written()[0 .. output.written().len - 1];
        try checks.append(a, .{ .case = case.id, .query = case.query, .input_sha256 = try M.digest(a, case.bytes), .output_sha256 = try M.digest(a, expected), .bytes = case.bytes.len });
        var warm: std.ArrayList(M.Record) = .empty;
        for (0..5) |variant| try measure(a, init.gpa, init.io, case, parsed.value, &source_program, &program, expected, variant, 0, &warm);
        for (0..repeat) |iteration| for (0..5) |step| try measure(a, init.gpa, init.io, case, parsed.value, &source_program, &program, expected, (iteration + step) % 5, iteration, &records);
    }
    try guard.publish("structural", repeat, "One warm-up; rotated variants for each distribution. Inputs parsed and ASTs compiled before timers. Reference/control freeze deep comparison copies and full-size result reservation; full-current calls the actual evaluator. Components expose source materialization, validated comparison preparation and sorting. Reference reserves full output then deduplicates/fills; current compacts distinct rows, reserves distinct output and fills. Preparation includes validation and rows. Logical phase deltas count requests above the same temporary arena; backing peaks include earlier live phases. Region release frees backing capacity in bulk, not individual logical requests. Full-query intervals include map/keys plus unique and exclude encoding, parse, compilation and cleanup. Every result matches public execution bytes; backing cleanup must reach zero. Components are not summed as independent microbenchmarks or new observed workflows.", records.items, .{ .checks = checks.items }, out);
}

fn variation(a: A, kind: enum { distinct, mixed, ordered, unordered }) ![]const u8 {
    var output = Io.Writer.Allocating.init(a);
    defer output.deinit();
    try output.writer.writeAll(if (kind == .distinct) "{\"fixtures\":[" else "{\"items\":[");
    for (0..1000) |index| {
        if (index != 0) try output.writer.writeByte(',');
        switch (kind) {
            .distinct => try output.writer.print("{{\"field-{d}\":0}}", .{index}),
            .mixed => try output.writer.writeAll(([_][]const u8{ "null", "false", "true", "1.00", "1e0", "-0", "\"é😀\"", "[1,2]", "[2,1]", "{\"z\":[1],\"a\":0}", "{\"a\":0,\"z\":[1]}" })[index % 11]),
            .ordered => try output.writer.writeAll("{\"a\":[{\"a\":0,\"b\":1}],\"b\":[0,1]}"),
            .unordered => try output.writer.writeAll("{\"b\":[0,1],\"a\":[{\"b\":1,\"a\":0}]}"),
        }
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

test "structural component pipeline matches the production evaluator and cleans up" {
    const t = std.testing;
    const case: Case = .{ .id = "test", .bytes = "{\"items\":[{\"z\":0,\"a\":1.0},{\"a\":1e0,\"z\":0},null]}", .source_query = ".items", .query = "unique(.items)" };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: engine.Diagnostic = .{};
    const parsed = try engine.input.parse(t.allocator, case.bytes, &diagnostic);
    defer parsed.deinit();
    var source = try engine.Program.compile(t.allocator, case.source_query, &diagnostic);
    defer source.deinit();
    var program = try engine.Program.compile(t.allocator, case.query, &diagnostic);
    defer program.deinit();
    var records: std.ArrayList(M.Record) = .empty;
    for (0..5) |variant| try measure(a, t.allocator, t.io, case, parsed.value, &source, &program, "[null,{\"z\":0,\"a\":1.0}]", variant, 0, &records);
    for (records.items) |record| if (std.mem.endsWith(u8, record.variant, "release") or std.mem.startsWith(u8, record.variant, "full-")) try t.expectEqual(@as(u64, 0), record.memory.?.end_live_bytes);
}
