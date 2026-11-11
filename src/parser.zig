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
    kind: enum { map, filter },
    array: *const Node,
    body: *const Node,
};
pub const Node = struct {
    offset: usize,
    height: usize,
    data: union(enum) {
        current,
        input_filename,
        literal: std.json.Value,
        access: struct { base: *const Node, key: Key, optional: bool },
        binary: struct { op: Op, lhs: *const Node, rhs: *const Node },
        logical_not: *const Node,
        negate: *const Node,
        object: []const Field,
        array: []const *const Node,
        exists: *const Node,
        length: *const Node,
        keys: *const Node,
        transform: Transform,
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
            } else if (self.word("count") or self.word("collect") or self.word("sum") or self.word("sort")) {
                const stage: Stage = if (self.word("count")) .{ .count = self.token.start } else if (self.word("sum")) .{ .sum = self.token.start } else if (self.word("sort")) .{ .sort = .{ .offset = self.token.start, .key = null } } else .{ .collect = self.token.start };
                try self.advance();
                try stages.append(self.allocator, stage);
            } else if (self.word("sort_by") or self.word("group_by")) {
                const offset = self.token.start;
                const sorting = self.word("sort_by");
                try self.advance();
                try self.expect(.lparen, "expected ( before key expression");
                const key = try self.expression(0);
                try self.expect(.rparen, "expected ) after key expression");
                try stages.append(self.allocator, if (sorting) .{ .sort = .{ .offset = offset, .key = key } } else .{ .group = .{ .offset = offset, .key = key } });
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
        var lhs = try self.postfix(try self.primary());
        while (self.operator()) |op| {
            if (op.precedence < min_precedence) break;
            const offset = self.token.start;
            try self.advance();
            const rhs = try self.expression(op.precedence + @as(u8, if (op.op == .coalesce) 0 else 1));
            lhs = try self.make(offset, .{ .binary = .{ .op = op.op, .lhs = lhs, .rhs = rhs } }, @max(lhs.height, rhs.height) + 1);
        }
        return lhs;
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
                if (self.word("input_filename")) {
                    try self.advance();
                    try self.expect(.lparen, "expected ( after input_filename");
                    try self.expect(.rparen, "input_filename takes no arguments");
                    return self.make(offset, .input_filename, 1);
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
                const keys = self.word("keys");
                const mapping = self.word("map");
                const filtering = self.word("filter");
                if (!exists and !matches and !length and !keys and !mapping and !filtering) return self.fail(offset, "unknown expression; fields start with .");
                try self.advance();
                try self.expect(.lparen, "expected ( after function name");
                const value = try self.expression(0);
                if (exists or length or keys) {
                    try self.expect(.rparen, "expected ) after function argument");
                    return self.make(offset, if (exists) .{ .exists = value } else if (length) .{ .length = value } else .{ .keys = value }, value.height + 1);
                }
                if (mapping or filtering) {
                    try self.expect(.comma, "map/filter expects an array and a per-element expression");
                    const body = try self.expression(0);
                    try self.expect(.rparen, "expected ) after per-element expression");
                    return self.make(offset, .{ .transform = .{ .kind = if (mapping) .map else .filter, .array = value, .body = body } }, @max(value.height, body.height) + 1);
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
