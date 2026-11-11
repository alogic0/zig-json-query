const std = @import("std");
const regex = @import("regex");
const syntax = @import("parser.zig");
const number = @import("number.zig");
const statistics = @import("statistics.zig");
const row_ops = @import("rows.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Path = @import("diagnostic.zig").Path;
const Value = std.json.Value;
const Node = syntax.Node;
const A = std.mem.Allocator;
const Error = error{ EvaluationFailed, OutOfMemory };

pub const Evaluator = struct {
    patterns: []const regex.Compiled,
    diagnostic: *Diagnostic,
    path: Path = .{},
    input_filename: ?[]const u8 = null,

    fn fail(self: *Evaluator, offset: usize, message: []const u8) Error {
        self.diagnostic.set(offset, message);
        return error.EvaluationFailed;
    }

    pub fn required(self: *Evaluator, value: ?Value, offset: usize) Error!Value {
        return value orelse self.fail(offset, "missing value: use ?? to supply a default or exists(...) to test presence");
    }

    pub fn boolean(self: *Evaluator, slot: ?Value, offset: usize) Error!bool {
        const value = try self.required(slot, offset);
        if (value != .bool) return self.fail(offset, "expected a boolean; comparisons and where do not use implicit truthiness");
        return value.bool;
    }

    pub fn eval(self: *Evaluator, allocator: A, node: *const Node, input: Value) Error!?Value {
        return self.evalInner(allocator, node, input) catch |err| {
            if (err == error.EvaluationFailed and !self.diagnostic.path_reported) self.locate(node);
            return err;
        };
    }

    pub fn locate(self: *Evaluator, node: *const Node) void {
        self.diagnostic.path = self.pathFor(node);
        self.diagnostic.path_reported = true;
    }

    pub fn evalRequired(self: *Evaluator, allocator: A, node: *const Node, input: Value) Error!Value {
        return self.requiredAt(try self.eval(allocator, node, input), node);
    }

    fn requiredAt(self: *Evaluator, value: ?Value, node: *const Node) Error!Value {
        return self.required(value, node.offset) catch |err| {
            self.locate(node);
            return err;
        };
    }

    pub fn booleanAt(self: *Evaluator, value: ?Value, node: *const Node) Error!bool {
        return self.boolean(value, node.offset) catch |err| {
            self.locate(node);
            return err;
        };
    }

    fn integerAt(self: *Evaluator, value: Value, node: *const Node) Error!i128 {
        return self.integer(value, node.offset) catch |err| {
            self.locate(node);
            return err;
        };
    }

    pub fn pathFor(self: *const Evaluator, node: *const Node) Path {
        return switch (node.data) {
            .current => self.path,
            .access => |access| blk: {
                var path = self.pathFor(access.base);
                if (path.len == 0) break :blk path;
                switch (access.key) {
                    .field => |key| path.field(key),
                    .index => |index| if (index.negative) path.indexFromEnd(index.magnitude) else path.index(index.magnitude),
                    .slice => return .{},
                }
                break :blk path;
            },
            else => .{}, // Constructed/computed values have no single source path.
        };
    }

    fn evalInner(self: *Evaluator, allocator: A, node: *const Node, input: Value) Error!?Value {
        return switch (node.data) {
            .current => input,
            .input_filename => if (self.input_filename) |name| Value{ .string = name } else Value.null,
            .literal => |value| value,
            .access => |access| blk: {
                // Missing from an earlier optional access propagates. Explicit
                // JSON null and other wrong container types remain type errors.
                const base = (try self.eval(allocator, access.base, input)) orelse break :blk null;
                const found: ?Value = switch (access.key) {
                    .field => |key| if (base == .object) base.object.get(key) else return self.fail(node.offset, "field access expects an object (including optional access)"),
                    .index => |index| if (base == .array) (if (index.resolve(base.array.items.len)) |absolute| base.array.items[absolute] else null) else return self.fail(node.offset, "index access expects an array (including optional access)"),
                    .slice => |slice| blk_slice: {
                        if (base != .array) return self.typeFailure(node, access.base, "slice access expects an array (including optional access)");
                        const len = base.array.items.len;
                        const start = if (slice.start) |bound| bound.clamp(len) else 0;
                        const end = if (slice.end) |bound| bound.clamp(len) else len;
                        // This view borrows children for the current synchronous
                        // stage lifetime; retaining stages already deep-copy.
                        var view = std.json.Array.init(allocator);
                        view.items = base.array.items[start..@max(start, end)];
                        view.capacity = view.items.len;
                        break :blk_slice Value{ .array = view };
                    },
                };
                if (found == null and !access.optional) return self.fail(node.offset, "field or index is absent; append ? for optional access");
                break :blk found;
            },
            .binary => |binary| blk: {
                const lhs = try self.eval(allocator, binary.lhs, input);
                switch (binary.op) {
                    .coalesce => {
                        if (lhs) |value| if (value != .null) break :blk value;
                        break :blk try self.eval(allocator, binary.rhs, input);
                    },
                    .logical_and => if (!try self.booleanAt(lhs, binary.lhs)) break :blk Value{ .bool = false },
                    .logical_or => if (try self.booleanAt(lhs, binary.lhs)) break :blk Value{ .bool = true },
                    else => {},
                }
                const rhs = try self.eval(allocator, binary.rhs, input);
                if (binary.op == .logical_and or binary.op == .logical_or) break :blk Value{ .bool = try self.booleanAt(rhs, binary.rhs) };
                const a = try self.requiredAt(lhs, binary.lhs);
                const b = try self.requiredAt(rhs, binary.rhs);
                const arithmetic_op: ?number.Arithmetic = switch (binary.op) {
                    .add => .add,
                    .subtract => .subtract,
                    .multiply => .multiply,
                    .divide => .divide,
                    .remainder => .remainder,
                    else => null,
                };
                if (arithmetic_op) |op| {
                    const result = number.arithmetic(op, try self.integerAt(a, binary.lhs), try self.integerAt(b, binary.rhs)) catch |err| return self.integerFailure(node.offset, err);
                    break :blk try integerValue(allocator, result);
                }
                if (binary.op == .eq or binary.op == .ne) {
                    const is_equal = self.equal(a, b, node.offset, 0) catch |err| {
                        self.locate(binary.lhs);
                        return err;
                    };
                    break :blk Value{ .bool = if (binary.op == .eq) is_equal else !is_equal };
                }
                const order = self.compare(a, b, node.offset) catch |err| {
                    self.locate(binary.lhs);
                    return err;
                };
                break :blk Value{ .bool = switch (binary.op) {
                    .lt => order == .lt,
                    .le => order != .gt,
                    .gt => order == .gt,
                    .ge => order != .lt,
                    else => unreachable,
                } };
            },
            .logical_not => |child| Value{ .bool = !try self.booleanAt(try self.eval(allocator, child, input), child) },
            .negate => |child| blk: {
                const value = try self.evalRequired(allocator, child, input);
                const result = number.arithmetic(.subtract, 0, try self.integerAt(value, child)) catch |err| return self.integerFailure(node.offset, err);
                break :blk try integerValue(allocator, result);
            },
            .exists => |child| Value{ .bool = (try self.eval(allocator, child, input)) != null },
            .length => |child| blk: {
                const value = try self.evalRequired(allocator, child, input);
                const length = switch (value) {
                    .array => |array| array.items.len,
                    .object => |object| object.count(),
                    .string => |string| std.unicode.utf8CountCodepoints(string) catch return self.typeFailure(node, child, "length expects a valid UTF-8 string"),
                    else => return self.typeFailure(node, child, "length expects an array, object, or string"),
                };
                break :blk try integerValue(allocator, @intCast(length));
            },
            .byte_length => |child| blk: {
                const value = try self.evalRequired(allocator, child, input);
                if (value != .string) return self.typeFailure(node, child, "byte_length expects a string");
                break :blk try integerValue(allocator, @intCast(value.string.len));
            },
            .tojson => |child| blk: {
                const value = try self.evalRequired(allocator, child, input);
                if (!withinDepth(value, 0)) return self.typeFailure(node, child, "serialization nesting exceeds 128 levels");
                break :blk Value{ .string = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
            },
            .keys => |child| blk: {
                const value = try self.evalRequired(allocator, child, input);
                var array = std.json.Array.init(allocator);
                switch (value) {
                    .object => |object| {
                        try array.ensureTotalCapacity(object.count());
                        for (object.keys()) |key| array.appendAssumeCapacity(.{ .string = key });
                        std.sort.pdq(Value, array.items, {}, struct {
                            fn less(_: void, a: Value, b: Value) bool {
                                return std.mem.lessThan(u8, a.string, b.string);
                            }
                        }.less);
                    },
                    .array => |items| {
                        try array.ensureTotalCapacity(items.items.len);
                        for (0..items.items.len) |index| array.appendAssumeCapacity(try integerValue(allocator, @intCast(index)));
                    },
                    else => return self.typeFailure(node, child, "keys expects an object or array"),
                }
                break :blk Value{ .array = array };
            },
            .sum => |child| blk: {
                const source = try self.evalRequired(allocator, child, input);
                if (source != .array) return self.typeFailure(node, child, "sum expects an array of integers");
                const array_path = self.pathFor(child);
                var total: i128 = 0;
                for (source.array.items, 0..) |value, index| {
                    var path = array_path;
                    if (path.len != 0) path.index(index);
                    const term = self.integer(value, node.offset) catch |err| {
                        self.diagnostic.path = path;
                        self.diagnostic.path_reported = true;
                        return err;
                    };
                    total = number.arithmetic(.add, total, term) catch |err| {
                        const failure = self.integerFailure(node.offset, err);
                        self.diagnostic.path = path;
                        self.diagnostic.path_reported = true;
                        return failure;
                    };
                }
                break :blk try integerValue(allocator, total);
            },
            .transform => |transform| blk: {
                const source = try self.evalRequired(allocator, transform.array, input);
                if (source != .array) return self.typeFailure(node, transform.array, "array function expects an array");
                var result = std.json.Array.init(allocator);
                if (transform.kind == .map or transform.kind == .filter) try result.ensureTotalCapacity(source.array.items.len);
                const caller_path = self.path;
                defer self.path = caller_path;
                const array_path = self.pathFor(transform.array);
                for (source.array.items, 0..) |item, index| {
                    self.path = array_path;
                    if (self.path.len != 0) self.path.index(index);
                    switch (transform.kind) {
                        .map => result.appendAssumeCapacity(try self.evalRequired(allocator, transform.body, item)),
                        .filter => if (try self.booleanAt(try self.eval(allocator, transform.body, item), transform.body)) {
                            result.appendAssumeCapacity(item);
                        },
                        .all => if (!try self.booleanAt(try self.eval(allocator, transform.body, item), transform.body)) break :blk Value{ .bool = false },
                        .any => if (try self.booleanAt(try self.eval(allocator, transform.body, item), transform.body)) break :blk Value{ .bool = true },
                    }
                }
                break :blk switch (transform.kind) {
                    .all => Value{ .bool = true },
                    .any => Value{ .bool = false },
                    .map, .filter => Value{ .array = result },
                };
            },
            .keyed_array => |operation| try self.keyedArray(allocator, node, input, operation),
            .edit => |edit| blk: {
                const value = try self.evalRequired(allocator, edit.base, input);
                break :blk try self.editValue(allocator, edit, value, 0, self.pathFor(edit.base));
            },
            .mean => |mean| blk: {
                const source = try self.evalRequired(allocator, mean.array, input);
                if (source != .array) return self.typeFailure(node, mean.array, "mean expects an array of numbers");
                if (source.array.items.len == 0) break :blk Value.null;
                const array_path = self.pathFor(mean.array);
                var accumulator: statistics.Mean = .{};
                for (source.array.items, 0..) |value, index| {
                    var path = array_path;
                    if (path.len != 0) path.index(index);
                    if (value != .number_string) return self.failPath(node.offset, "mean expects an array of numbers", path);
                    accumulator.add(value.number_string) catch |err| return self.decimalFailure(node.offset, err, path);
                }
                const token = accumulator.finish(allocator, mean.places) catch |err| return self.decimalFailure(node.offset, err, array_path);
                break :blk Value{ .number_string = token };
            },
            .decimal_divide => |division| blk: {
                const lhs = try self.evalRequired(allocator, division.lhs, input);
                if (lhs != .number_string) return self.typeFailure(node, division.lhs, "divide expects numeric operands");
                const a = statistics.decimal(lhs.number_string) catch |err| return self.decimalFailure(node.offset, err, self.pathFor(division.lhs));
                const rhs = try self.evalRequired(allocator, division.rhs, input);
                if (rhs != .number_string) return self.typeFailure(node, division.rhs, "divide expects numeric operands");
                const b = statistics.decimal(rhs.number_string) catch |err| return self.decimalFailure(node.offset, err, self.pathFor(division.rhs));
                const token = statistics.divide(allocator, a, b, division.places) catch |err| return self.decimalFailure(node.offset, err, if (err == error.DivisionByZero) self.pathFor(division.rhs) else .{});
                break :blk Value{ .number_string = token };
            },
            .matches => |match| blk: {
                const value = try self.evalRequired(allocator, match.value, input);
                if (value != .string) {
                    const err = self.fail(node.offset, "matches expects a string value");
                    self.locate(match.value);
                    return err;
                }
                const matched = self.patterns[match.pattern].isMatch(value.string) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return self.fail(node.offset, "regex evaluation failed"),
                };
                break :blk Value{ .bool = matched };
            },
            .object => |fields| blk: {
                var object: std.json.ObjectMap = .empty;
                for (fields) |field| {
                    const value = try self.evalRequired(allocator, field.value, input);
                    try object.put(allocator, field.name, value);
                }
                break :blk Value{ .object = object };
            },
            .array => |children| blk: {
                var array = std.json.Array.init(allocator);
                for (children) |child| try array.append(try self.evalRequired(allocator, child, input));
                break :blk Value{ .array = array };
            },
        };
    }

    fn editValue(self: *Evaluator, allocator: A, edit: syntax.Edit, value: Value, position: usize, base_path: Path) Error!Value {
        const step = edit.path[position];
        var path = base_path;
        const selected: ?Value = switch (step.key) {
            .field => |key| blk: {
                if (path.len != 0) path.field(key);
                if (value != .object) return self.failPath(step.offset, "edit field path expects an object", path);
                break :blk value.object.get(key);
            },
            .index => |index| blk: {
                if (path.len != 0) {
                    if (index.negative) path.indexFromEnd(index.magnitude) else path.index(index.magnitude);
                }
                if (value != .array) return self.failPath(step.offset, "edit index path expects an array", path);
                break :blk if (index.resolve(value.array.items.len)) |absolute| value.array.items[absolute] else null;
            },
            .slice => unreachable,
        };
        const child = selected orelse return self.failPath(step.offset, "edit field or index is absent", path);
        const replacement: ?Value = if (position + 1 < edit.path.len)
            try self.editValue(allocator, edit, child, position + 1, path)
        else if (edit.body) |body| blk: {
            const caller_path = self.path;
            defer self.path = caller_path;
            self.path = path;
            break :blk try self.evalRequired(allocator, body, child);
        } else null;
        return switch (step.key) {
            .field => |key| blk: {
                var result: std.json.ObjectMap = .empty;
                var iterator = value.object.iterator();
                while (iterator.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                        if (replacement) |item| try result.put(allocator, entry.key_ptr.*, item);
                    } else try result.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
                break :blk .{ .object = result };
            },
            .index => |index| blk: {
                const absolute = index.resolve(value.array.items.len).?;
                var result = std.json.Array.init(allocator);
                try result.ensureTotalCapacity(value.array.items.len - @intFromBool(replacement == null));
                for (value.array.items, 0..) |item, i| {
                    if (i == absolute) {
                        if (replacement) |next| result.appendAssumeCapacity(next);
                    } else result.appendAssumeCapacity(item);
                }
                break :blk .{ .array = result };
            },
            .slice => unreachable,
        };
    }

    fn keyedArray(self: *Evaluator, allocator: A, node: *const Node, input: Value, operation: syntax.KeyedArray) Error!Value {
        const source = try self.evalRequired(allocator, operation.array, input);
        if (source != .array) return self.typeFailure(node, operation.array, "scalar sort_by/group_by expects an array");
        const rows = try allocator.alloc(row_ops.Row, source.array.items.len);
        const caller_path = self.path;
        defer self.path = caller_path;
        const array_path = self.pathFor(operation.array);
        for (source.array.items, 0..) |item, index| {
            self.path = array_path;
            if (self.path.len != 0) self.path.index(index);
            const key = try self.evalRequired(allocator, operation.key, item);
            self.validateKey(key, if (index == 0) null else rows[0].key, node.offset, operation.kind == .sort) catch |err| {
                self.locate(operation.key);
                return err;
            };
            rows[index] = .{ .value = item, .key = key };
        }
        self.path = caller_path;
        var result = std.json.Array.init(allocator);
        if (operation.kind == .sort) {
            row_ops.sort(rows);
            try result.ensureTotalCapacity(rows.len);
            for (rows) |row| result.appendAssumeCapacity(row.value);
        } else {
            const visited = try allocator.alloc(bool, rows.len);
            @memset(visited, false);
            for (rows, 0..) |_, start| {
                if (!visited[start]) try result.append(try row_ops.group(allocator, rows, visited, start, self, node.offset));
            }
        }
        return .{ .array = result };
    }

    pub fn validateKey(self: *Evaluator, key: Value, first: ?Value, offset: usize, sorting: bool) Error!void {
        if (sorting) {
            if (key != .number_string and key != .string) return self.fail(offset, "sort keys must all be numbers or all strings");
            if (first) |initial| if (std.meta.activeTag(key) != std.meta.activeTag(initial)) return self.fail(offset, "sort keys must all be numbers or all strings");
            _ = try self.compare(key, key, offset);
        } else {
            // Validate nested numeric exponents even for a single group key.
            _ = try self.equal(key, key, offset, 0);
        }
    }

    fn typeFailure(self: *Evaluator, node: *const Node, argument: *const Node, message: []const u8) Error {
        const err = self.fail(node.offset, message);
        self.locate(argument);
        return err;
    }

    fn failPath(self: *Evaluator, offset: usize, message: []const u8, path: Path) Error {
        const err = self.fail(offset, message);
        self.diagnostic.path = path;
        self.diagnostic.path_reported = true;
        return err;
    }

    fn decimalFailure(self: *Evaluator, offset: usize, err: statistics.ResultError, path: Path) Error {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return self.failPath(offset, switch (err) {
            error.DecimalRange => "decimal statistics require i128 coefficients and at most 18 fractional places; input or rounded result is out of range",
            error.DivisionByZero => "decimal division by zero",
            error.InvalidPrecision => "decimal precision must be from 0 through 18",
            error.OutOfMemory => unreachable,
        }, path);
    }

    pub fn integer(self: *Evaluator, value: Value, offset: usize) Error!i128 {
        if (value != .number_string) return self.fail(offset, "integer arithmetic expects a number; types are not coerced");
        return number.integer(value.number_string) catch |err| self.integerFailure(offset, err);
    }

    pub fn integerFailure(self: *Evaluator, offset: usize, err: number.IntegerError) Error {
        return self.fail(offset, switch (err) {
            error.IntegerRange => "integer arithmetic exceeds the supported signed 128-bit range",
            error.FractionalNumber => "integer arithmetic rejects fractional numbers",
            error.DivisionByZero => "division or remainder by zero",
            error.InexactDivision => "division must be exact; rounding is not implicit",
        });
    }

    pub fn compare(self: *Evaluator, a: Value, b: Value, offset: usize) Error!std.math.Order {
        if (a == .number_string and b == .number_string) return number.compare(a.number_string, b.number_string) catch return self.fail(offset, "numeric comparison exponent is outside the supported i64 range");
        if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
        return self.fail(offset, "ordering expects two numbers or two strings; types are not coerced");
    }

    pub fn equal(self: *Evaluator, a: Value, b: Value, offset: usize, depth: usize) Error!bool {
        if (depth > 128 or (depth == 128 and (a == .array or a == .object or b == .array or b == .object))) return self.fail(offset, "comparison nesting exceeds 128 levels");
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .bool => |value| value == b.bool,
            .string => |value| std.mem.eql(u8, value, b.string),
            .number_string => (try self.compare(a, b, offset)) == .eq,
            .array => |array| blk: {
                if (array.items.len != b.array.items.len) break :blk false;
                for (array.items, b.array.items) |av, bv| if (!try self.equal(av, bv, offset, depth + 1)) break :blk false;
                break :blk true;
            },
            .object => |object| blk: {
                if (object.count() != b.object.count()) break :blk false;
                var it = object.iterator();
                while (it.next()) |entry| {
                    const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                    if (!try self.equal(entry.value_ptr.*, other, offset, depth + 1)) break :blk false;
                }
                break :blk true;
            },
            // Program inputs and query literals always use parse_numbers=false.
            .integer, .float => unreachable,
        };
    }
};

fn integerValue(allocator: A, value: i128) Error!Value {
    return .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{value}) };
}

pub fn withinDepth(value: Value, depth: usize) bool {
    if (depth > 128 or (depth == 128 and (value == .array or value == .object))) return false;
    switch (value) {
        .array => |array| for (array.items) |item| {
            if (!withinDepth(item, depth + 1)) return false;
        },
        .object => |object| for (object.values()) |item| {
            if (!withinDepth(item, depth + 1)) return false;
        },
        else => {},
    }
    return true;
}
