//! Matched component models isolate storage/sort changes. Separate actual
//! evaluator intervals expose the AST/path work excluded from those models.
const std = @import("std");
const engine = @import("profile_engine");
const M = @import("study_support.zig");
const generated = @import("fixtures.zig");
const structural = @import("structural_study.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const Variant = enum { reference, control, current, current_control, actual, actual_control };
const Case = struct { id: []const u8, bytes: []const u8, schemas: bool = false, source: []const u8 = ".items", query: []const u8 = "unique(.items)" };

// Frozen 0.22.0 known-size reservation and stable structural sorting.
fn referenceStorage(a: A, count: usize) !std.json.Array {
    var array = std.json.Array.init(a);
    try array.ensureTotalCapacity(count);
    return array;
}

fn referenceSort(rows: []engine.RowOps.Row) void {
    std.sort.block(engine.RowOps.Row, rows, {}, struct {
        fn less(_: void, a: engine.RowOps.Row, b: engine.RowOps.Row) bool {
            return engine.JsonOrder.compare(a.key, b.key) == .lt;
        }
    }.less);
}

fn sourceModel(comptime current: bool, a: A, input: Value, schemas: bool) !Value {
    const values = input.object.get(if (schemas) "fixtures" else "items").?;
    if (!schemas) return values;
    var result = if (current) try engine.ArrayStorage.init(a, values.array.items.len) else try referenceStorage(a, values.array.items.len);
    for (values.array.items) |value| {
        var keys = if (current) try engine.ArrayStorage.init(a, value.object.count()) else try referenceStorage(a, value.object.count());
        for (value.object.keys()) |key| keys.appendAssumeCapacity(.{ .string = key });
        std.sort.pdq(Value, keys.items, {}, struct {
            fn less(_: void, x: Value, y: Value) bool {
                return std.mem.lessThan(u8, x.string, y.string);
            }
        }.less);
        result.appendAssumeCapacity(.{ .array = keys });
    }
    return .{ .array = result };
}

fn verify(a: A, value: Value, expected: []const u8) !void {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(text);
    if (!std.mem.eql(u8, text, expected)) return error.CollectionOutputMismatch;
}

fn pipeline(comptime current: bool, a: A, report_a: A, evaluator: *engine.Evaluator, input: Value, schemas: bool, source_expected: []const u8, trace: *structural.Trace) !Value {
    trace.begin();
    const source = try sourceModel(current, a, input, schemas);
    try trace.end("source");
    try verify(report_a, source, source_expected);
    trace.begin();
    const rows = try a.alloc(engine.RowOps.Row, source.array.items.len);
    for (source.array.items, 0..) |item, index| {
        _ = try evaluator.equal(item, item, 0, 0);
        rows[index] = .{ .value = item, .key = try engine.JsonOrder.ordered(a, item) };
    }
    try trace.end("prepare");
    trace.begin();
    if (current) engine.RowOps.sortStructural(rows) else referenceSort(rows);
    try trace.end("sort");
    trace.begin();
    const selected = engine.RowOps.distinct(rows);
    try trace.end("compact");
    trace.begin();
    var result = std.json.Array.init(a);
    try result.ensureTotalCapacity(selected.len);
    for (selected) |row| result.appendAssumeCapacity(row.value);
    try trace.end("result");
    return .{ .array = result };
}

fn components(comptime current: bool, report_a: A, backing: A, io: Io, case: Case, input: Value, expected_source: []const u8, expected: []const u8, variant: Variant, iteration: usize, records: *std.ArrayList(M.Record)) !void {
    var meter: M.Meter = .{ .backing = backing };
    var arena = std.heap.ArenaAllocator.init(meter.allocator());
    var live = true;
    defer if (live) arena.deinit();
    var logical: M.Meter = .{ .backing = arena.allocator() };
    var diagnostic: engine.Diagnostic = .{};
    var evaluator: engine.Evaluator = .{ .patterns = &.{}, .diagnostic = &diagnostic, .path = .root() };
    var trace: structural.Trace = .{ .backing = &meter, .logical = &logical, .io = io, .report_a = report_a, .records = records, .id = case.id, .variant = @tagName(variant), .iteration = iteration };
    const result = try pipeline(current, logical.allocator(), report_a, &evaluator, input, case.schemas, expected_source, &trace);
    try verify(report_a, result, expected);
    trace.begin();
    arena.deinit();
    live = false;
    try trace.end("release");
    if (meter.counters.live_bytes != 0) return error.StudyAllocationLeak;
}

// Full sort controls use actual source evaluation and current storage on both
// sides, freezing only the sorter. Path setup on a successful outer unique node
// is omitted; the separately timed ordinary evaluator retains that boundary.
fn fullSort(a: A, evaluator: *engine.Evaluator, source_node: anytype, input: Value, current: bool) !Value {
    const source = try evaluator.evalRequired(a, source_node, input);
    const rows = try a.alloc(engine.RowOps.Row, source.array.items.len);
    for (source.array.items, 0..) |item, index| {
        _ = try evaluator.equal(item, item, 0, 0);
        rows[index] = .{ .value = item, .key = try engine.JsonOrder.ordered(a, item) };
    }
    if (current) engine.RowOps.sortStructural(rows) else referenceSort(rows);
    const selected = engine.RowOps.distinct(rows);
    var result = std.json.Array.init(a);
    try result.ensureTotalCapacity(selected.len);
    for (selected) |row| result.appendAssumeCapacity(row.value);
    return .{ .array = result };
}

fn actual(report_a: A, backing: A, io: Io, case: Case, input: Value, program: *const engine.Program, expected: []const u8, variant: Variant, phase: []const u8, sort_override: ?bool, iteration: usize, records: *std.ArrayList(M.Record)) !void {
    var meter: M.Meter = .{ .backing = backing };
    var arena = std.heap.ArenaAllocator.init(meter.allocator());
    var live = true;
    defer if (live) arena.deinit();
    var logical: M.Meter = .{ .backing = arena.allocator() };
    var diagnostic: engine.Diagnostic = .{};
    var evaluator: engine.Evaluator = .{ .patterns = program.patterns, .diagnostic = &diagnostic, .path = .root() };
    const before = meter.begin();
    const start = Io.Clock.awake.now(io);
    const value = if (sort_override) |current| try fullSort(logical.allocator(), &evaluator, program.stages[0].expression, input, current) else try evaluator.evalRequired(logical.allocator(), program.stages[0].expression, input);
    const duration = M.elapsed(start, io);
    try verify(report_a, value, expected);
    const requests = logical.counters;
    arena.deinit();
    live = false;
    try records.append(report_a, .{ .case = case.id, .variant = try std.fmt.allocPrint(report_a, "{s}/{s}", .{ @tagName(variant), phase }), .iteration = iteration, .elapsed_ns = duration, .memory = meter.end(before), .logical = requests });
    if (meter.counters.live_bytes != 0) return error.StudyAllocationLeak;
}

fn measure(report_a: A, backing: A, io: Io, case: Case, input: Value, source_program: *const engine.Program, program: *const engine.Program, expected_source: []const u8, expected: []const u8, variant: Variant, iteration: usize, records: *std.ArrayList(M.Record)) !void {
    switch (variant) {
        .reference, .control => {
            try components(false, report_a, backing, io, case, input, expected_source, expected, variant, iteration, records);
            try actual(report_a, backing, io, case, input, source_program, expected, variant, "full-sort", false, iteration, records);
        },
        .current, .current_control => {
            try components(true, report_a, backing, io, case, input, expected_source, expected, variant, iteration, records);
            try actual(report_a, backing, io, case, input, source_program, expected, variant, "full-sort", true, iteration, records);
        },
        .actual, .actual_control => {
            try actual(report_a, backing, io, case, input, source_program, expected_source, variant, "source", null, iteration, records);
            try actual(report_a, backing, io, case, input, program, expected, variant, "full", null, iteration, records);
        },
    }
}

fn output(a: A, bytes: []const u8, program: *const engine.Program) ![]const u8 {
    var diagnostic: engine.Diagnostic = .{};
    var writer = Io.Writer.Allocating.init(a);
    try program.run(a, bytes, &writer.writer, &diagnostic);
    return writer.written()[0 .. writer.written().len - 1];
}

pub fn run(init: std.process.Init, repeat: usize, out: ?[]const u8) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var guard = try M.Run.init(a, init.io, args[0], &.{ "tools/collection_study.zig", "tools/structural_study.zig" });
    const cases = [_]Case{
        .{ .id = "repeated-schema", .bytes = try generated.generate(a, .backend, 10000), .schemas = true, .source = "map(.fixtures,keys(.))", .query = "unique(map(.fixtures,keys(.)))" },
        .{ .id = "all-distinct", .bytes = try structural.variation(a, .distinct), .schemas = true, .source = "map(.fixtures,keys(.))", .query = "unique(map(.fixtures,keys(.)))" },
        .{ .id = "mixed", .bytes = try structural.variation(a, .mixed) },
        .{ .id = "nested-ordered", .bytes = try structural.variation(a, .ordered) },
        .{ .id = "nested-unordered", .bytes = try structural.variation(a, .unordered) },
        .{ .id = "sorted", .bytes = try variation(a, .sorted) },
        .{ .id = "reverse", .bytes = try variation(a, .reverse) },
        .{ .id = "late-inversion", .bytes = try variation(a, .late) },
    };
    const Check = struct { case: []const u8, query: []const u8, source_query: []const u8, bytes: usize, input_sha256: []const u8, output_sha256: []const u8, source_output_sha256: []const u8 };
    var checks: std.ArrayList(Check) = .empty;
    var records: std.ArrayList(M.Record) = .empty;
    for (cases) |case| {
        var diagnostic: engine.Diagnostic = .{};
        const parsed = try engine.input.parse(init.gpa, case.bytes, &diagnostic);
        defer parsed.deinit();
        var source_program = try engine.Program.compile(a, case.source, &diagnostic);
        defer source_program.deinit();
        var program = try engine.Program.compile(a, case.query, &diagnostic);
        defer program.deinit();
        const source_expected = try output(a, case.bytes, &source_program);
        const expected = try output(a, case.bytes, &program);
        try checks.append(a, .{ .case = case.id, .query = case.query, .source_query = case.source, .bytes = case.bytes.len, .input_sha256 = try M.digest(a, case.bytes), .output_sha256 = try M.digest(a, expected), .source_output_sha256 = try M.digest(a, source_expected) });
        var warm: std.ArrayList(M.Record) = .empty;
        for (std.enums.values(Variant)) |variant| try measure(a, init.gpa, init.io, case, parsed.value, &source_program, &program, source_expected, expected, variant, 0, &warm);
        for (0..repeat) |iteration| for (0..std.enums.values(Variant).len) |step| try measure(a, init.gpa, init.io, case, parsed.value, &source_program, &program, source_expected, expected, M.balancedVariant(Variant, iteration, step), iteration, &records);
    }
    try guard.publish("collections", repeat, "One warm-up; six-variant sequences balance positions and directed predecessors per six repetitions. reference/control component models freeze 0.22.0 keys/map reservation and stable block sorting; current/current_control use production storage/sort helpers. All models share validated canonical keys, stable distinct compaction and existing result reservation. Paired full-sort controls use actual source evaluation and current storage on both sides, freezing only the sorter; successful outer unique path setup is omitted. Actual source/full evaluator intervals retain ordinary boundaries in separate fresh arenas. Component models omit AST/path traversal: their times are not substituted for actual full-query times, and intervals are not summed. Inputs parsed, ASTs compiled and ordinary outputs captured before measurement. Every model source/result and actual output matches public execution bytes. Encoding/checks/cleanup excluded from whole-query timers; component gaps include report work outside phase timers. Logical request deltas are above the temporary region, backing peaks include earlier live phases and cleanup reaches zero. Parse cost is outside these intervals; matched public CLI evidence covers complete invocations.", records.items, .{ .checks = checks.items }, out);
}

fn variation(a: A, kind: enum { sorted, reverse, late }) ![]const u8 {
    var writer = Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writer.writer.writeAll("{\"items\":[");
    for (0..10000) |index| {
        if (index != 0) try writer.writer.writeByte(',');
        const value = switch (kind) {
            .sorted => index,
            .reverse => 9999 - index,
            .late => if (index == 9998) @as(usize, 9999) else if (index == 9999) @as(usize, 9998) else index,
        };
        try writer.writer.print("{d}", .{value});
    }
    try writer.writer.writeAll("]}");
    return writer.toOwnedSlice();
}

test "collection components and actual evaluator preserve Unicode schemas and stable representatives" {
    const t = std.testing;
    const cases = [_]Case{
        .{ .id = "schemas", .bytes = "{\"fixtures\":[{\"z\":0,\"a\":1.0},{\"a\":1e0,\"z\":0},{\"é\":0}]}", .schemas = true, .source = "map(.fixtures,keys(.))", .query = "unique(map(.fixtures,keys(.)))" },
        .{ .id = "values", .bytes = "{\"items\":[{\"z\":0,\"a\":1.0},{\"a\":1e0,\"z\":0},-0,0.00,true]}" },
    };
    const sources = [_][]const u8{ "[[\"a\",\"z\"],[\"a\",\"z\"],[\"é\"]]", "[{\"z\":0,\"a\":1.0},{\"a\":1e0,\"z\":0},-0,0.00,true]" };
    const outputs = [_][]const u8{ "[[\"a\",\"z\"],[\"é\"]]", "[true,-0,{\"z\":0,\"a\":1.0}]" };
    var report = std.heap.ArenaAllocator.init(t.allocator);
    defer report.deinit();
    for (cases, sources, outputs) |case, source_expected, expected| {
        var diagnostic: engine.Diagnostic = .{};
        const parsed = try engine.input.parse(t.allocator, case.bytes, &diagnostic);
        defer parsed.deinit();
        var source_program = try engine.Program.compile(t.allocator, case.source, &diagnostic);
        defer source_program.deinit();
        var program = try engine.Program.compile(t.allocator, case.query, &diagnostic);
        defer program.deinit();
        var records: std.ArrayList(M.Record) = .empty;
        for (std.enums.values(Variant)) |variant| try measure(report.allocator(), t.allocator, t.io, case, parsed.value, &source_program, &program, source_expected, expected, variant, 0, &records);
        for (records.items) |record| if (std.mem.endsWith(u8, record.variant, "/release") or std.mem.endsWith(u8, record.variant, "/full-sort") or std.mem.startsWith(u8, record.variant, "actual")) try t.expectEqual(@as(u64, 0), record.memory.?.end_live_bytes);
    }
}
