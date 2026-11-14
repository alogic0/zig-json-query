const std = @import("std");
const regex = @import("regex");
const syntax = @import("parser.zig");
const scalar = @import("evaluator.zig");
const json_order = @import("json_order.zig");
const Budget = @import("collection_budget.zig");
const Buffered = @import("buffered.zig");
const GroupTotals = @import("group_totals.zig");
const KeyIndex = @import("key_index.zig");
const number = @import("number.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const A = std.mem.Allocator;
const Value = std.json.Value;
const Self = @This();

pub const Options = struct {
    /// Positive source-byte limit for each document fed to the session.
    max_document_bytes: usize = @import("input.zig").max_bytes,
    /// Shared live retained capacity across collection, grouping and index stages.
    max_collect_bytes: usize = 64 * 1024 * 1024,
    raw_output: bool = false,
    /// Raw strings and no separator after any output value.
    join_output: bool = false,
    sort_keys: bool = false,
    /// Format JSON containers with 2-space indentation; conflicts with join_output.
    pretty: bool = false,
};
pub const Error = error{ EvaluationFailed, OutOfMemory, StreamFailed, StreamFinished } || std.Io.Writer.Error;
const Collector = struct { arena: std.heap.ArenaAllocator, items: std.ArrayList(Value) = .empty };
const State = union(enum) { none, count: u64, sum: i128, take: u64, collect: Collector, buffered: Buffered, totals: GroupTotals, index: KeyIndex };

allocator: A,
stages: []const syntax.Stage,
states: []State,
evaluator: scalar.Evaluator,
writer: *std.Io.Writer,
budget: Budget,
max_document_bytes: usize,
raw_output: bool,
join_output: bool,
sort_keys: bool,
pretty: bool,
last_output: enum { none, false_or_null, other } = .none,
lifecycle: enum { active, failed, finished } = .active,
// Exhausting take at index i closes every stage through i. Stages after i can
// still receive its last value and finish their own aggregates.
closed_through: ?usize = null,

pub fn init(allocator: A, stages: []const syntax.Stage, patterns: []const regex.Compiled, writer: *std.Io.Writer, diagnostic: *Diagnostic, options: Options) error{ InvalidOptions, OutOfMemory }!*Self {
    if (options.max_document_bytes == 0) {
        diagnostic.set(0, "document input limit must be positive");
        return error.InvalidOptions;
    }
    if (options.pretty and options.join_output) {
        diagnostic.set(0, "pretty output cannot be combined with join_output");
        return error.InvalidOptions;
    }
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    const states = try allocator.alloc(State, stages.len);
    self.* = .{
        .allocator = allocator,
        .stages = stages,
        .states = states,
        .evaluator = .{ .patterns = patterns, .diagnostic = diagnostic },
        .writer = writer,
        .budget = .{ .backing = allocator, .limit = options.max_collect_bytes },
        .max_document_bytes = options.max_document_bytes,
        .raw_output = options.raw_output or options.join_output,
        .join_output = options.join_output,
        .sort_keys = options.sort_keys,
        .pretty = options.pretty,
    };
    // Self and states have stable addresses before an allocator can borrow them.
    for (stages, states, 0..) |stage_kind, *state, index| {
        state.* = switch (stage_kind) {
            .count => .{ .count = 0 },
            .sum => .{ .sum = 0 },
            .collect => .{ .collect = .{ .arena = .init(self.budget.allocator()) } },
            .sort, .group => .{ .buffered = .init(self.budget.allocator()) },
            .totals => .{ .totals = .init(self.budget.allocator()) },
            .index => .{ .index = .init(self.budget.allocator()) },
            .take => |take| blk: {
                if (take.limit == 0) self.closeThrough(index);
                break :blk .{ .take = 0 };
            },
            else => .none,
        };
    }
    return self;
}

pub fn deinit(self: *Self) void {
    for (0..self.states.len) |index| self.releaseCollector(index);
    std.debug.assert(self.budget.used == 0);
    const allocator = self.allocator;
    allocator.free(self.states);
    allocator.destroy(self);
}

pub fn checkActive(self: *const Self) Error!void {
    switch (self.lifecycle) {
        .active => {},
        .failed => return error.StreamFailed,
        .finished => return error.StreamFinished,
    }
}

pub fn needsInput(self: *const Self) bool {
    return self.lifecycle == .active and self.closed_through == null;
}

pub fn predicateStatus(self: *const Self) u8 {
    return switch (self.last_output) {
        .none => 4,
        .false_or_null => 1,
        .other => 0,
    };
}

pub fn abort(self: *Self) void {
    self.lifecycle = .failed;
    for (0..self.states.len) |index| self.releaseCollector(index);
}

pub fn push(self: *Self, input: Value) Error!void {
    try self.checkActive();
    errdefer self.abort();
    self.evaluator.path = .root();
    try self.stage(0, input);
}

pub fn finish(self: *Self) Error!void {
    if (self.lifecycle == .finished) return;
    try self.checkActive();
    errdefer self.abort();
    // Earlier aggregates feed later stages before those stages receive EOF.
    for (self.stages, 0..) |stage_kind, index| {
        self.evaluator.path = .{};
        if (self.blocked(index)) {
            self.releaseCollector(index);
            continue;
        }
        switch (stage_kind) {
            .count => {
                var buffer: [20]u8 = undefined;
                const token = std.fmt.bufPrint(&buffer, "{d}", .{self.states[index].count}) catch unreachable;
                try self.stage(index + 1, .{ .number_string = token });
            },
            .sum => {
                var buffer: [40]u8 = undefined;
                const token = std.fmt.bufPrint(&buffer, "{d}", .{self.states[index].sum}) catch unreachable;
                try self.stage(index + 1, .{ .number_string = token });
            },
            .collect => {
                const collector = &self.states[index].collect;
                // Borrow this array until synchronous downstream processing
                // returns. Any downstream collector must clone it.
                var view = std.json.Array.init(collector.arena.allocator());
                view.items = collector.items.items;
                view.capacity = collector.items.items.len;
                try self.stage(index + 1, .{ .array = view });
                self.releaseCollector(index);
            },
            .sort => {
                const buffered = &self.states[index].buffered;
                buffered.sort();
                for (buffered.rows.items) |row| {
                    if (self.blocked(index)) break;
                    try self.stage(index + 1, row.value);
                }
                self.releaseCollector(index);
            },
            .group => |group| {
                const buffered = &self.states[index].buffered;
                self.budget.denied = false;
                const visited = buffered.arena.allocator().alloc(bool, buffered.rows.items.len) catch |err| return self.retentionError(group.offset, "group_by exceeded the session memory limit", err);
                @memset(visited, false);
                for (0..buffered.rows.items.len) |start| {
                    if (self.blocked(index)) break;
                    if (visited[start]) continue;
                    self.budget.denied = false;
                    const value = buffered.group(&self.evaluator, visited, start, group.offset) catch |err| return self.retentionError(group.offset, "group_by exceeded the session memory limit", err);
                    try self.stage(index + 1, value);
                }
                self.releaseCollector(index);
            },
            .index => {
                try self.stage(index + 1, .{ .object = self.states[index].index.entries });
                self.releaseCollector(index);
            },
            .totals => |totals| {
                for (self.states[index].totals.rows.items) |row| {
                    if (self.blocked(index)) break;
                    self.budget.denied = false;
                    self.emitTotal(index, row, totals.value != null) catch |err| return self.retentionError(totals.offset, "grouped totals exceeded the session memory limit", err);
                }
                self.releaseCollector(index);
            },
            else => {},
        }
    }
    self.lifecycle = .finished;
}

fn releaseCollector(self: *Self, index: usize) void {
    if (self.states[index] == .collect) {
        self.states[index].collect.arena.deinit();
        self.states[index] = .none;
    } else if (self.states[index] == .buffered) {
        self.states[index].buffered.deinit();
        self.states[index] = .none;
    } else if (self.states[index] == .totals) {
        self.states[index].totals.deinit();
        self.states[index] = .none;
    } else if (self.states[index] == .index) {
        self.states[index].index.deinit();
        self.states[index] = .none;
    }
}

fn closeThrough(self: *Self, index: usize) void {
    self.closed_through = if (self.closed_through) |previous| @max(previous, index) else index;
}

fn blocked(self: *const Self, index: usize) bool {
    return if (self.closed_through) |closed| index <= closed else false;
}

fn fail(self: *Self, offset: usize, message: []const u8) Error {
    self.evaluator.diagnostic.set(offset, message);
    return error.EvaluationFailed;
}

fn stage(self: *Self, index: usize, input: Value) Error!void {
    return self.stageInner(index, input) catch |err| {
        if (err == error.EvaluationFailed and !self.evaluator.diagnostic.path_reported) {
            self.evaluator.diagnostic.path = self.evaluator.path;
            self.evaluator.diagnostic.path_reported = true;
        }
        return err;
    };
}

fn stageInner(self: *Self, index: usize, input: Value) Error!void {
    if (self.blocked(index)) return;
    if (index == self.stages.len) {
        if (!scalar.withinDepth(input, 0)) return self.fail(0, "output nesting exceeds 128 levels");
        const stringify_options: std.json.Stringify.Options = if (self.pretty) .{ .whitespace = .indent_2 } else .{};
        if (self.raw_output and input == .string) {
            try self.writer.writeAll(input.string);
        } else if (self.sort_keys) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            try std.json.Stringify.value(try json_order.ordered(arena.allocator(), input), stringify_options, self.writer);
        } else try std.json.Stringify.value(input, stringify_options, self.writer);
        if (!self.join_output) try self.writer.writeByte('\n');
        self.last_output = switch (input) {
            .null => .false_or_null,
            .bool => |value| if (value) .other else .false_or_null,
            else => .other,
        };
        return;
    }
    switch (self.stages[index]) {
        .each => |offset| {
            if (input != .array) return self.fail(offset, "each expects an array");
            const path = self.evaluator.path;
            defer self.evaluator.path = path;
            for (input.array.items, 0..) |item, item_index| {
                if (self.blocked(index)) break;
                self.evaluator.path = path;
                if (path.len != 0) self.evaluator.path.index(item_index);
                try self.stage(index + 1, item);
            }
        },
        .expression => |node| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const value = try self.evaluator.evalRequired(arena.allocator(), node, input);
            const path = self.evaluator.path;
            defer self.evaluator.path = path;
            self.evaluator.path = self.evaluator.pathFor(node);
            try self.stage(index + 1, value);
        },
        .where => |node| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const keep = try self.evaluator.booleanAt(try self.evaluator.eval(arena.allocator(), node, input), node);
            if (keep) try self.stage(index + 1, input);
        },
        .count => |offset| {
            const state = &self.states[index].count;
            state.* = std.math.add(u64, state.*, 1) catch return self.fail(offset, "count exceeds the supported u64 range");
        },
        .sum => |offset| {
            const value = try self.evaluator.integer(input, offset);
            const state = &self.states[index].sum;
            state.* = number.arithmetic(.add, state.*, value) catch |err| return self.evaluator.integerFailure(offset, err);
        },
        .collect => |offset| {
            if (!scalar.withinDepth(input, 0)) return self.fail(offset, "collected value nesting exceeds 128 levels");
            self.budget.denied = false;
            self.appendCollected(index, input) catch |err| {
                return self.retentionError(offset, "collect exceeded the session memory limit", err);
            };
        },
        .sort => |sort| try self.retain(index, input, sort.key, sort.offset, true),
        .group => |group| try self.retain(index, input, group.key, group.offset, false),
        .index => |spec| {
            var temporary = std.heap.ArenaAllocator.init(self.allocator);
            defer temporary.deinit();
            const key = try self.evaluator.evalRequired(temporary.allocator(), spec.key, input);
            if (key != .string) {
                const err = self.fail(spec.key.offset, "index_by key must be a string");
                self.evaluator.locate(spec.key);
                return err;
            }
            if (!scalar.withinDepth(input, 1)) return self.fail(spec.offset, "indexed record and output wrapper exceed 128 levels");
            const state = &self.states[index].index;
            if (state.entries.contains(key.string)) {
                const err = self.fail(spec.key.offset, "index_by duplicate key; keys must be unique");
                self.evaluator.locate(spec.key);
                return err;
            }
            self.budget.denied = false;
            state.append(key.string, input) catch |err| return self.retentionError(spec.offset, "index_by exceeded the session memory limit", err);
        },
        .totals => |totals| {
            var temporary = std.heap.ArenaAllocator.init(self.allocator);
            defer temporary.deinit();
            const a = temporary.allocator();
            const key = try self.evaluator.evalRequired(a, totals.key, input);
            if (!scalar.withinDepth(key, 1)) return self.fail(totals.offset, "grouped-total key and output wrapper exceed 128 levels");
            try self.evaluator.validateKey(key, null, totals.key.offset, false);
            const amount = if (totals.value) |node| self.evaluator.integer(try self.evaluator.evalRequired(a, node, input), node.offset) catch |err| {
                self.evaluator.locate(node);
                return err;
            } else null;
            self.budget.denied = false;
            self.states[index].totals.add(&self.evaluator, key, amount, totals.offset) catch |err| return self.retentionError(totals.offset, "grouped totals exceeded the session memory limit", err);
        },
        .take => |take| {
            const received = &self.states[index].take;
            // A zero/exhausted limit was already handled by blocked().
            received.* += 1;
            if (received.* == take.limit) self.closeThrough(index);
            try self.stage(index + 1, input);
        },
    }
}

fn appendCollected(self: *Self, index: usize, input: Value) error{OutOfMemory}!void {
    const collector = &self.states[index].collect;
    const allocator = collector.arena.allocator();
    try collector.items.append(allocator, try Buffered.clone(allocator, input));
}

fn emitTotal(self: *Self, index: usize, row: GroupTotals.Row, summing: bool) Error!void {
    const a = self.budget.allocator();
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(a);
    var count_buffer: [20]u8 = undefined;
    var sum_buffer: [40]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buffer, "{d}", .{row.count}) catch unreachable;
    const sum = std.fmt.bufPrint(&sum_buffer, "{d}", .{row.sum}) catch unreachable;
    try object.put(a, "key", row.key);
    try object.put(a, "count", .{ .number_string = count });
    if (summing) try object.put(a, "sum", .{ .number_string = sum });
    try self.stage(index + 1, .{ .object = object });
}

fn retain(self: *Self, index: usize, input: Value, key_node: ?*const syntax.Node, offset: usize, sorting: bool) Error!void {
    if (!scalar.withinDepth(input, 0)) return self.fail(offset, "retained value nesting exceeds 128 levels");
    var temporary = std.heap.ArenaAllocator.init(self.allocator);
    defer temporary.deinit();
    const key = if (key_node) |node| try self.evaluator.evalRequired(temporary.allocator(), node, input) else input;
    if (!scalar.withinDepth(key, 0)) return self.fail(offset, "key nesting exceeds 128 levels");
    const buffered = &self.states[index].buffered;
    try self.evaluator.validateKey(key, if (buffered.rows.items.len == 0) null else buffered.rows.items[0].key, offset, sorting);
    self.budget.denied = false;
    buffered.append(input, key) catch |err| return self.retentionError(offset, if (sorting) "sort exceeded the session memory limit" else "group_by exceeded the session memory limit", err);
}

fn retentionError(self: *Self, offset: usize, message: []const u8, err: Error) Error {
    if (self.budget.denied and err == error.OutOfMemory) {
        self.evaluator.diagnostic.setBudget(offset, message, .{ .kind = .retained, .limit = self.budget.limit, .retained = self.budget.denied_used, .requested = self.budget.denied_request });
        return error.EvaluationFailed;
    }
    return err;
}
