const std = @import("std");
const regex = @import("regex");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const A = std.mem.Allocator;
const Error = error{ InvalidQuery, OutOfMemory };

pub const Op = enum { coalesce, eq, ne, lt, le, gt, ge, logical_and, logical_or, add, subtract, multiply, divide, remainder };
pub const Index = struct {
    magnitude: usize,
    negative: bool,

    pub fn resolve(self: Index, len: usize) ?usize {
        if (self.negative) return if (self.magnitude <= len) len - self.magnitude else null;
        return if (self.magnitude < len) self.magnitude else null;
    }

    pub fn clamp(self: Index, len: usize) usize {
        return if (self.negative) len -| self.magnitude else @min(self.magnitude, len);
    }
};
pub const Slice = struct { start: ?Index, end: ?Index };
pub const Key = union(enum) { field: []const u8, index: Index, slice: Slice };
pub const Field = struct { name: []const u8, value: *const Node };
pub const BoundValue = struct { name: []const u8, value: std.json.Value };
pub const Transform = struct {
    kind: enum { map, filter, all, any },
    array: *const Node,
    body: *const Node,
};
pub const KeyedArray = struct {
    kind: enum { sort, group },
    array: *const Node,
    key: *const Node,
};
pub const EditStep = struct { key: Key, offset: usize };
pub const Edit = struct { base: *const Node, path: []const EditStep, body: ?*const Node };
pub const Node = struct {
    offset: usize,
    height: usize,
    data: union(enum) {
        current,
        scope_root,
        input_filename,
        literal: std.json.Value,
        access: struct { base: *const Node, key: Key, optional: bool },
        lookup: struct { base: *const Node, key: *const Node, optional: bool },
        binary: struct { op: Op, lhs: *const Node, rhs: *const Node },
        logical_not: *const Node,
        negate: *const Node,
        object: []const Field,
        array: []const *const Node,
        assertion: struct { predicate: *const Node, detail: *const Node },
        exists: *const Node,
        length: *const Node,
        byte_length: *const Node,
        concat: *const Node,
        tojson: *const Node,
        fromjson: struct { value: *const Node, fallible: bool },
        structural: struct { array: *const Node, unique: bool },
        keys: *const Node,
        sum: *const Node,
        transform: Transform,
        keyed_array: KeyedArray,
        edit: Edit,
        mean: struct { array: *const Node, places: u8 },
        decimal_divide: struct { lhs: *const Node, rhs: *const Node, places: u8 },
        matches: struct { value: *const Node, pattern: usize },
    },
};
pub const Stage = union(enum) {
    expression: *const Node,
    each: usize,
    where: *const Node,
    count: usize,
    sum: usize,
    collect: usize,
    sort: struct { offset: usize, key: ?*const Node },
    group: struct { offset: usize, key: *const Node },
    totals: struct { offset: usize, key: *const Node, value: ?*const Node },
    index: struct { offset: usize, key: *const Node },
    take: struct { offset: usize, limit: u64 },
};

const Tag = enum {
    eof,
    identifier,
    number,
    string,
    dot,
    pipe,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    colon,
    comma,
    question,
    coalesce,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    plus,
    minus,
    star,
    slash,
    percent,
    dollar,
};
const Token = struct { tag: Tag, start: usize, end: usize };

pub const Parser = struct {
    allocator: A,
    regex_allocator: A,
    source: []const u8,
    diagnostic: *Diagnostic,
    bindings: []const BoundValue = &.{},
    cursor: usize = 0,
    token: Token = .{ .tag = .eof, .start = 0, .end = 0 },
    recursion: usize = 0,
    node_count: usize = 0,
    patterns: std.ArrayList(regex.Compiled) = .empty,

    pub fn deinitPatterns(self: *Parser) void {
        for (self.patterns.items) |*pattern| pattern.deinit();
        self.patterns.deinit(self.regex_allocator);
    }

    fn fail(self: *Parser, offset: usize, message: []const u8) Error {
        self.diagnostic.set(offset, message);
        return error.InvalidQuery;
    }

    fn text(self: *const Parser) []const u8 {
        return self.source[self.token.start..self.token.end];
    }

    fn word(self: *const Parser, expected: []const u8) bool {
        return self.token.tag == .identifier and std.mem.eql(u8, self.text(), expected);
    }

    fn followedByCall(self: *const Parser) Error!bool {
        var lookahead = self.*;
        try lookahead.advance();
        return lookahead.token.tag == .lparen;
    }

    fn advance(self: *Parser) Error!void {
        while (self.cursor < self.source.len) {
            if (std.ascii.isWhitespace(self.source[self.cursor])) {
                self.cursor += 1;
            } else if (self.source[self.cursor] == '#') {
                while (self.cursor < self.source.len and self.source[self.cursor] != '\n') self.cursor += 1;
            } else break;
        }
        const start = self.cursor;
        if (start == self.source.len) {
            self.token = .{ .tag = .eof, .start = start, .end = start };
            return;
        }
        const byte = self.source[self.cursor];
        self.cursor += 1;
        const tag: Tag = tag: {
            if (std.ascii.isAlphabetic(byte) or byte == '_') {
                while (self.cursor < self.source.len) {
                    const next = self.source[self.cursor];
                    if (!std.ascii.isAlphanumeric(next) and next != '_') break;
                    self.cursor += 1;
                }
                break :tag .identifier;
            }
            if (std.ascii.isDigit(byte)) {
                while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) self.cursor += 1;
                if (self.consume('.')) while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) {
                    self.cursor += 1;
                };
                if (self.consume('e') or self.consume('E')) {
                    _ = self.consume('+') or self.consume('-');
                    while (self.cursor < self.source.len and std.ascii.isDigit(self.source[self.cursor])) self.cursor += 1;
                }
                break :tag .number;
            }
            if (byte == '"') {
                while (self.cursor < self.source.len) {
                    const next = self.source[self.cursor];
                    self.cursor += 1;
                    if (next == '"') break :tag .string;
                    if (next == '\\' and self.cursor < self.source.len) self.cursor += 1;
                }
                return self.fail(start, "unterminated JSON string literal");
            }
            break :tag switch (byte) {
                '.' => .dot,
                '|' => .pipe,
                '(' => .lparen,
                ')' => .rparen,
                '[' => .lbracket,
                ']' => .rbracket,
                '{' => .lbrace,
                '}' => .rbrace,
                ':' => .colon,
                ',' => .comma,
                '?' => if (self.consume('=')) return self.fail(start, "use ?? for a missing-or-null default") else if (self.consume('?')) .coalesce else .question,
                '=' => if (self.consume('=')) .eq else return self.fail(start, "equality uses =="),
                '!' => if (self.consume('=')) .ne else return self.fail(start, "use not for boolean negation"),
                '<' => if (self.consume('=')) .le else .lt,
                '>' => if (self.consume('=')) .ge else .gt,
                '+' => .plus,
                '-' => .minus,
                '*' => .star,
                '/' => .slash,
                '%' => .percent,
                '$' => .dollar,
                else => return self.fail(start, "unexpected character"),
            };
        };
        self.token = .{ .tag = tag, .start = start, .end = self.cursor };
    }

    fn consume(self: *Parser, byte: u8) bool {
        if (self.cursor < self.source.len and self.source[self.cursor] == byte) {
            self.cursor += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: Tag, message: []const u8) Error!void {
        if (self.token.tag != tag) return self.fail(self.token.start, message);
        try self.advance();
    }

    fn make(self: *Parser, offset: usize, data: @FieldType(Node, "data"), height: usize) Error!*const Node {
        if (height > 128 or self.node_count == 4096) return self.fail(offset, "query is too complex (128 nesting levels / 4096 expressions)");
        self.node_count += 1;
        const node = try self.allocator.create(Node);
        node.* = .{ .offset = offset, .height = height, .data = data };
        return node;
    }

    pub fn parse(self: *Parser) Error![]const Stage {
        if (self.source.len > 64 * 1024) return self.fail(0, "query exceeds 64 KiB");
        try self.advance();
        var stages: std.ArrayList(Stage) = .empty;
        while (true) {
            if (stages.items.len == 128) return self.fail(self.token.start, "query exceeds 128 stages");
            if (self.word("each")) {
                const offset = self.token.start;
                try self.advance();
                try stages.append(self.allocator, .{ .each = offset });
            } else if (self.word("count") or self.word("collect") or (self.word("sum") and !try self.followedByCall()) or self.word("sort")) {
                const stage: Stage = if (self.word("count")) .{ .count = self.token.start } else if (self.word("sum")) .{ .sum = self.token.start } else if (self.word("sort")) .{ .sort = .{ .offset = self.token.start, .key = null } } else .{ .collect = self.token.start };
                try self.advance();
                try stages.append(self.allocator, stage);
            } else if (self.word("sort_by") or self.word("group_by")) {
                const offset = self.token.start;
                const sorting = self.word("sort_by");
                try self.advance();
                try self.expect(.lparen, "expected ( before key expression");
                const key = try self.expression(0);
                if (self.token.tag == .comma) {
                    const value = try self.keyedArrayTail(offset, if (sorting) .sort else .group, key);
                    try stages.append(self.allocator, .{ .expression = try self.expressionTail(value, 0) });
                } else {
                    try self.expect(.rparen, "expected ) after key expression");
                    try stages.append(self.allocator, if (sorting) .{ .sort = .{ .offset = offset, .key = key } } else .{ .group = .{ .offset = offset, .key = key } });
                }
            } else if (self.word("index_by")) {
                const offset = self.token.start;
                try self.advance();
                try self.expect(.lparen, "expected ( before index key");
                const key = try self.expression(0);
                try self.expect(.rparen, "index_by expects one per-record string key");
                try stages.append(self.allocator, .{ .index = .{ .offset = offset, .key = key } });
            } else if (self.word("count_by") or self.word("sum_by")) {
                const offset = self.token.start;
                const summing = self.word("sum_by");
                try self.advance();
                try self.expect(.lparen, "expected ( before grouped-total key");
                const key = try self.expression(0);
                const value = if (summing) blk: {
                    try self.expect(.comma, "sum_by expects a key and an integer value expression");
                    break :blk try self.expression(0);
                } else null;
                try self.expect(.rparen, "expected ) after grouped-total arguments");
                try stages.append(self.allocator, .{ .totals = .{ .offset = offset, .key = key, .value = value } });
            } else if (self.word("take")) {
                const offset = self.token.start;
                try self.advance();
                try self.expect(.lparen, "expected ( after take");
                if (self.token.tag != .number or self.text()[0] == '-') return self.fail(self.token.start, "take expects a constant nonnegative integer fitting u64");
                _ = try self.jsonLiteral();
                const limit = std.fmt.parseInt(u64, self.text(), 10) catch return self.fail(self.token.start, "take expects a constant nonnegative integer fitting u64");
                try self.advance();
                try self.expect(.rparen, "expected ) after take limit");
                try stages.append(self.allocator, .{ .take = .{ .offset = offset, .limit = limit } });
            } else if (self.word("where")) {
                try self.advance();
                try self.expect(.lparen, "expected ( after where");
                const condition = try self.expression(0);
                try self.expect(.rparen, "expected ) after where condition");
                try stages.append(self.allocator, .{ .where = condition });
            } else {
                try stages.append(self.allocator, .{ .expression = try self.expression(0) });
            }
            if (self.token.tag == .eof) break;
            try self.expect(.pipe, "expected | or end of query; array expansion uses | each");
        }
        return stages.toOwnedSlice(self.allocator);
    }

    fn operator(self: *const Parser) ?struct { op: Op, precedence: u8 } {
        return switch (self.token.tag) {
            .coalesce => .{ .op = .coalesce, .precedence = 1 },
            .eq => .{ .op = .eq, .precedence = 4 },
            .ne => .{ .op = .ne, .precedence = 4 },
            .lt => .{ .op = .lt, .precedence = 5 },
            .le => .{ .op = .le, .precedence = 5 },
            .gt => .{ .op = .gt, .precedence = 5 },
            .ge => .{ .op = .ge, .precedence = 5 },
            .plus => .{ .op = .add, .precedence = 6 },
            .minus => .{ .op = .subtract, .precedence = 6 },
            .star => .{ .op = .multiply, .precedence = 7 },
            .slash => .{ .op = .divide, .precedence = 7 },
            .percent => .{ .op = .remainder, .precedence = 7 },
            .identifier => if (self.word("or")) .{ .op = .logical_or, .precedence = 2 } else if (self.word("and")) .{ .op = .logical_and, .precedence = 3 } else null,
            else => null,
        };
    }

    fn expression(self: *Parser, min_precedence: u8) Error!*const Node {
        self.recursion += 1;
        defer self.recursion -= 1;
        if (self.recursion > 128) return self.fail(self.token.start, "expression nesting exceeds 128 levels");
        return self.expressionTail(try self.primary(), min_precedence);
    }

    fn expressionTail(self: *Parser, initial: *const Node, min_precedence: u8) Error!*const Node {
        var lhs = try self.postfix(initial);
        while (self.operator()) |op| {
            if (op.precedence < min_precedence) break;
            const offset = self.token.start;
            try self.advance();
            const rhs = try self.expression(op.precedence + @as(u8, if (op.op == .coalesce) 0 else 1));
            lhs = try self.make(offset, .{ .binary = .{ .op = op.op, .lhs = lhs, .rhs = rhs } }, @max(lhs.height, rhs.height) + 1);
        }
        return lhs;
    }

    fn keyedArrayTail(self: *Parser, offset: usize, kind: @FieldType(KeyedArray, "kind"), source: *const Node) Error!*const Node {
        try self.expect(.comma, "scalar sort_by/group_by expects an array and a per-element key");
        const key = try self.expression(0);
        try self.expect(.rparen, "expected ) after array key expression");
        return self.make(offset, .{ .keyed_array = .{ .kind = kind, .array = source, .key = key } }, @max(source.height, key.height) + 1);
    }

    fn editPath(self: *Parser, node: *const Node, steps: *std.ArrayList(EditStep)) Error!void {
        switch (node.data) {
            .current => {},
            .access => |access| {
                if (access.optional or access.key == .slice) return self.fail(node.offset, "edit paths require literal fields/indexes without optional access or slices");
                try self.editPath(access.base, steps);
                try steps.append(self.allocator, .{ .key = access.key, .offset = node.offset });
            },
            else => return self.fail(node.offset, "edit path must start at . and contain only literal fields/indexes"),
        }
    }

    fn jsonLiteral(self: *Parser) Error!std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator, self.text(), .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.fail(self.token.start, "invalid JSON literal"),
        };
    }

    fn primary(self: *Parser) Error!*const Node {
        const offset = self.token.start;
        switch (self.token.tag) {
            .dollar => {
                try self.advance();
                if (self.token.tag != .identifier or self.token.start != offset + 1) return self.fail(offset, "expected a variable name immediately after $");
                const name = self.text();
                for (self.bindings) |binding| {
                    if (!std.mem.eql(u8, name, binding.name)) continue;
                    try self.advance();
                    return self.make(offset, .{ .literal = binding.value }, 1);
                }
                return self.fail(offset, "unbound variable; supply it with --arg or --argjson");
            },
            .minus => {
                try self.advance();
                if (self.token.tag == .number and self.token.start == offset + 1) {
                    const value = std.json.parseFromSliceLeaky(std.json.Value, self.allocator, self.source[offset..self.token.end], .{ .parse_numbers = false }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return self.fail(offset, "invalid JSON literal"),
                    };
                    try self.advance();
                    return self.make(offset, .{ .literal = value }, 1);
                }
                const child = try self.expression(8);
                return self.make(offset, .{ .negate = child }, child.height + 1);
            },
            .dot => {
                try self.advance();
                const current = try self.make(offset, .current, 1);
                if (self.token.tag == .identifier and self.token.start == offset + 1) return self.fieldAccess(current);
                return current;
            },
            .number, .string => {
                const value = try self.jsonLiteral();
                try self.advance();
                return self.make(offset, .{ .literal = value }, 1);
            },
            .lparen => {
                try self.advance();
                const value = try self.expression(0);
                try self.expect(.rparen, "expected )");
                return value;
            },
            .lbrace => return self.object(),
            .lbracket => return self.array(),
            .identifier => {
                if (self.word("concat")) {
                    try self.advance();
                    try self.expect(.lparen, "expected ( after concat");
                    const parts = try self.expression(0);
                    try self.expect(.rparen, "concat expects one array argument");
                    return self.make(offset, .{ .concat = parts }, parts.height + 1);
                }
                if (self.word("assert")) {
                    try self.advance();
                    try self.expect(.lparen, "expected ( after assert");
                    const predicate = try self.expression(0);
                    try self.expect(.comma, "assert expects a predicate and a detail object");
                    const detail = try self.expression(0);
                    try self.expect(.rparen, "expected ) after assertion detail");
                    return self.make(offset, .{ .assertion = .{ .predicate = predicate, .detail = detail } }, @max(predicate.height, detail.height) + 1);
                }
                if (self.word("root")) {
                    try self.advance();
                    try self.expect(.lparen, "expected ( after root");
                    try self.expect(.rparen, "root takes no arguments");
                    return self.make(offset, .scope_root, 1);
                }
                if (self.word("update") or self.word("del")) {
                    const updating = self.word("update");
                    try self.advance();
                    try self.expect(.lparen, "expected ( after edit function");
                    const base = try self.expression(0);
                    try self.expect(.comma, "edit expects a value and a literal path");
                    const path = try self.expression(0);
                    var steps: std.ArrayList(EditStep) = .empty;
                    try self.editPath(path, &steps);
                    if (steps.items.len == 0) return self.fail(path.offset, "edit path must select at least one field or index");
                    const body = if (updating) blk: {
                        try self.expect(.comma, "update expects a replacement expression");
                        break :blk try self.expression(0);
                    } else null;
                    try self.expect(.rparen, "expected ) after edit arguments");
                    return self.make(offset, .{ .edit = .{ .base = base, .path = try steps.toOwnedSlice(self.allocator), .body = body } }, @max(@max(base.height, path.height), if (body) |child| child.height else 0) + 1);
                }
                if (self.word("input_filename")) {
                    try self.advance();
                    try self.expect(.lparen, "expected ( after input_filename");
                    try self.expect(.rparen, "input_filename takes no arguments");
                    return self.make(offset, .input_filename, 1);
                }
                if (self.word("sort_by") or self.word("group_by")) {
                    const sorting = self.word("sort_by");
                    try self.advance();
                    try self.expect(.lparen, "expected ( before array expression");
                    return self.keyedArrayTail(offset, if (sorting) .sort else .group, try self.expression(0));
                }
                if (self.word("mean") or self.word("divide")) {
                    const division = self.word("divide");
                    try self.advance();
                    try self.expect(.lparen, "expected ( after numeric function");
                    const lhs = try self.expression(0);
                    try self.expect(.comma, "expected comma after numeric argument");
                    const rhs = if (division) try self.expression(0) else null;
                    if (division) try self.expect(.comma, "expected comma before decimal precision");
                    const places = try self.precision();
                    try self.expect(.rparen, "expected ) after decimal precision");
                    return if (rhs) |divisor|
                        self.make(offset, .{ .decimal_divide = .{ .lhs = lhs, .rhs = divisor, .places = places } }, @max(lhs.height, divisor.height) + 1)
                    else
                        self.make(offset, .{ .mean = .{ .array = lhs, .places = places } }, lhs.height + 1);
                }
                if (self.word("true") or self.word("false") or self.word("null")) {
                    const value = try self.jsonLiteral();
                    try self.advance();
                    return self.make(offset, .{ .literal = value }, 1);
                }
                if (self.word("not")) {
                    try self.advance();
                    const child = try self.expression(8);
                    return self.make(offset, .{ .logical_not = child }, child.height + 1);
                }
                const exists = self.word("exists");
                const matches = self.word("matches");
                const length = self.word("length");
                const byte_length = self.word("byte_length");
                const tojson = self.word("tojson");
                const fromjson = self.word("fromjson");
                const try_fromjson = self.word("try_fromjson");
                const structural = self.word("sort_values") or self.word("unique");
                const unique = self.word("unique");
                const keys = self.word("keys");
                const sum = self.word("sum");
                const mapping = self.word("map");
                const filtering = self.word("filter");
                const all = self.word("all");
                const any = self.word("any");
                if (!exists and !matches and !length and !byte_length and !tojson and !fromjson and !try_fromjson and !structural and !keys and !sum and !mapping and !filtering and !all and !any) return self.fail(offset, "unknown expression; fields start with .");
                try self.advance();
                if ((tojson or fromjson or try_fromjson) and self.token.tag != .lparen) {
                    const current = try self.make(offset, .current, 1);
                    return self.make(offset, if (tojson) .{ .tojson = current } else .{ .fromjson = .{ .value = current, .fallible = try_fromjson } }, current.height + 1);
                }
                try self.expect(.lparen, "expected ( after function name");
                const value = try self.expression(0);
                if (exists or length or byte_length or tojson or fromjson or try_fromjson or structural or keys or sum) {
                    try self.expect(.rparen, "expected ) after function argument");
                    if (structural) return self.make(offset, .{ .structural = .{ .array = value, .unique = unique } }, value.height + 1);
                    if (fromjson or try_fromjson) return self.make(offset, .{ .fromjson = .{ .value = value, .fallible = try_fromjson } }, value.height + 1);
                    return self.make(offset, if (exists) .{ .exists = value } else if (length) .{ .length = value } else if (byte_length) .{ .byte_length = value } else if (tojson) .{ .tojson = value } else if (keys) .{ .keys = value } else .{ .sum = value }, value.height + 1);
                }
                if (mapping or filtering or all or any) {
                    try self.expect(.comma, "array function expects an array and a per-element expression");
                    const body = try self.expression(0);
                    try self.expect(.rparen, "expected ) after per-element expression");
                    return self.make(offset, .{ .transform = .{ .kind = if (mapping) .map else if (filtering) .filter else if (all) .all else .any, .array = value, .body = body } }, @max(value.height, body.height) + 1);
                }
                try self.expect(.comma, "matches expects a value and a constant JSON string pattern");
                if (self.token.tag != .string) return self.fail(self.token.start, "regex pattern must be a constant JSON string");
                const pattern = (try self.jsonLiteral()).string;
                if (pattern.len > 1024) return self.fail(self.token.start, "regex pattern exceeds 1024 bytes");
                var compiled = regex.compileRe(self.regex_allocator, pattern, .{ .max_instructions = 4096, .multiline = true }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return self.fail(self.token.start, "invalid or unsupported regex pattern"),
                };
                self.patterns.append(self.regex_allocator, compiled) catch |err| {
                    compiled.deinit();
                    return err;
                };
                const pattern_index = self.patterns.items.len - 1;
                try self.advance();
                try self.expect(.rparen, "expected ) after regex pattern");
                return self.make(offset, .{ .matches = .{ .value = value, .pattern = pattern_index } }, value.height + 1);
            },
            else => return self.fail(offset, "expected a field path, literal, object, array, or function"),
        }
    }

    fn optional(self: *Parser) Error!bool {
        if (self.token.tag != .question) return false;
        try self.advance();
        return true;
    }

    fn precision(self: *Parser) Error!u8 {
        const message = "precision must be a constant integer from 0 through 18";
        if (self.token.tag != .number) return self.fail(self.token.start, message);
        _ = try self.jsonLiteral();
        const places = std.fmt.parseInt(u8, self.text(), 10) catch return self.fail(self.token.start, message);
        if (places > 18) return self.fail(self.token.start, message);
        try self.advance();
        return places;
    }

    fn fieldAccess(self: *Parser, base: *const Node) Error!*const Node {
        const offset = self.token.start;
        if (self.token.tag != .identifier) return self.fail(offset, "expected field name after .");
        const key = self.text();
        try self.advance();
        return self.make(offset, .{ .access = .{ .base = base, .key = .{ .field = key }, .optional = try self.optional() } }, base.height + 1);
    }

    fn indexLiteral(self: *Parser) Error!Index {
        const negative = self.token.tag == .minus;
        if (negative) try self.advance();
        if (self.token.tag != .number) return self.fail(self.token.start, "expected a literal integer index or slice bound; use | each to expand an array");
        const magnitude = std.fmt.parseInt(usize, self.text(), 10) catch return self.fail(self.token.start, "index or slice bound must be an integer magnitude fitting usize");
        try self.advance();
        return .{ .magnitude = magnitude, .negative = negative and magnitude != 0 };
    }

    fn postfix(self: *Parser, initial: *const Node) Error!*const Node {
        var value = initial;
        while (true) {
            if (self.token.tag == .dot) {
                try self.advance();
                value = try self.fieldAccess(value);
            } else if (self.token.tag == .lbracket) {
                const offset = self.token.start;
                try self.advance();
                const literal_key = switch (self.token.tag) {
                    .number, .minus, .colon => true,
                    .string => blk: {
                        var lookahead = self.*;
                        try lookahead.advance();
                        break :blk lookahead.token.tag == .rbracket;
                    },
                    else => false,
                };
                if (!literal_key) {
                    const key = try self.expression(0);
                    try self.expect(.rbracket, "expected ] after computed string key");
                    value = try self.make(offset, .{ .lookup = .{ .base = value, .key = key, .optional = try self.optional() } }, @max(value.height, key.height) + 1);
                    continue;
                }
                const key: Key = if (self.token.tag == .string) blk: {
                    const field = (try self.jsonLiteral()).string;
                    try self.advance();
                    break :blk .{ .field = field };
                } else blk: {
                    const start = if (self.token.tag == .colon) null else try self.indexLiteral();
                    if (self.token.tag == .colon) {
                        try self.advance();
                        const end = if (self.token.tag == .rbracket) null else try self.indexLiteral();
                        break :blk .{ .slice = .{ .start = start, .end = end } };
                    }
                    break :blk .{ .index = start.? };
                };
                try self.expect(.rbracket, "expected ] after key or index");
                value = try self.make(offset, .{ .access = .{ .base = value, .key = key, .optional = try self.optional() } }, value.height + 1);
            } else break;
        }
        return value;
    }

    fn object(self: *Parser) Error!*const Node {
        const offset = self.token.start;
        try self.advance();
        var fields: std.ArrayList(Field) = .empty;
        var height: usize = 1;
        while (self.token.tag != .rbrace) {
            const key_offset = self.token.start;
            const key = switch (self.token.tag) {
                .identifier => self.text(),
                .string => (try self.jsonLiteral()).string,
                else => return self.fail(self.token.start, "expected object field name"),
            };
            for (fields.items) |field| if (std.mem.eql(u8, field.name, key)) return self.fail(self.token.start, "duplicate object field");
            try self.advance();
            const value = if (self.token.tag == .colon) blk: {
                try self.advance();
                break :blk try self.expression(0);
            } else blk: {
                if (self.token.tag != .comma and self.token.tag != .rbrace) return self.fail(self.token.start, "expected :, comma or } after object field name");
                const current = try self.make(key_offset, .current, 1);
                break :blk try self.make(key_offset, .{ .access = .{ .base = current, .key = .{ .field = key }, .optional = false } }, 2);
            };
            height = @max(height, value.height + 1);
            try fields.append(self.allocator, .{ .name = key, .value = value });
            if (self.token.tag != .comma) break;
            try self.advance();
            if (self.token.tag == .rbrace) return self.fail(self.token.start, "trailing comma is not allowed");
        }
        try self.expect(.rbrace, "expected } after object fields");
        return self.make(offset, .{ .object = try fields.toOwnedSlice(self.allocator) }, height);
    }

    fn array(self: *Parser) Error!*const Node {
        const offset = self.token.start;
        try self.advance();
        var values: std.ArrayList(*const Node) = .empty;
        var height: usize = 1;
        while (self.token.tag != .rbracket) {
            const value = try self.expression(0);
            height = @max(height, value.height + 1);
            try values.append(self.allocator, value);
            if (self.token.tag != .comma) break;
            try self.advance();
            if (self.token.tag == .rbracket) return self.fail(self.token.start, "trailing comma is not allowed");
        }
        try self.expect(.rbracket, "expected ] after array items");
        return self.make(offset, .{ .array = try values.toOwnedSlice(self.allocator) }, height);
    }
};
