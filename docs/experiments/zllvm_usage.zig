//! Read-only research helper for the z_llvm usage audit. This is deliberately
//! a conservative word scanner, not a shell interpreter: no historical text is
//! executed. Inputs/commands remain in an ignored private inventory. Published
//! evidence contains query text, counts, source references and output hashes.
const std = @import("std");
const S = @import("test_support");
const Number = @import("exact_number");
const A = std.mem.Allocator;
const Io = std.Io;
const V = std.json.Value;

const Command = struct { record: usize, id: []const u8, cwd: []const u8, command: []const u8, exit_code: ?i32 };
const Token = struct { kind: enum { word, boundary, redirect }, text: []const u8, dynamic: bool = false };
const Invocation = struct { record: usize, cwd: []const u8, tool: []const u8, query: ?[]const u8, query_file: ?[]const u8, flags: []const []const u8, files: []const []const u8, dynamic: bool };
const Inventory = struct { candidate_command_records: usize, project_command_records: usize, invocations: []const Invocation };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 5 and std.mem.eql(u8, args[1], "catalog")) return catalog(a, init.io, args[2], args[3], args[4]);
    if (args.len == 6 and std.mem.eql(u8, args[1], "compare")) return compare(a, init.io, args[2], args[3], args[4], args[5]);
    if (args.len != 4 or !std.mem.eql(u8, args[1], "inventory")) return error.UsageInventoryCatalogOrCompare;
    const bytes = try Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(16 * 1024 * 1024));
    const commands = try std.json.parseFromSliceLeaky([]const Command, a, bytes, .{});
    var invocations: std.ArrayList(Invocation) = .empty;
    var errors: std.ArrayList(struct { record: usize, reason: []const u8 }) = .empty;
    var in_project: usize = 0;
    for (commands) |command| {
        const root = "file:///home/oleg/prog/z_llvm";
        if (!std.mem.eql(u8, command.cwd, root) and !(std.mem.startsWith(u8, command.cwd, root) and command.cwd.len > root.len and command.cwd[root.len] == '/')) continue;
        in_project += 1;
        const tokens = scan(a, command.command) catch |err| {
            try errors.append(a, .{ .record = command.record, .reason = @errorName(err) });
            continue;
        };
        var position = true;
        for (tokens, 0..) |token, at| {
            if (token.kind == .boundary) {
                position = true;
                continue;
            }
            if (token.kind == .redirect) {
                position = false;
                continue;
            }
            if (position and (std.mem.eql(u8, std.fs.path.basename(token.text), "jq") or std.mem.eql(u8, std.fs.path.basename(token.text), "jg"))) {
                try invocations.append(a, try invocation(a, command, tokens, at));
            }
            if (position and (std.mem.indexOfScalar(u8, token.text, '=') != null or keyword(token.text))) continue;
            position = false;
        }
    }
    var output = Io.Writer.Allocating.init(a);
    try std.json.Stringify.value(.{ .schema_version = 1, .candidate_command_records = commands.len, .project_command_records = in_project, .extraction_errors = errors.items, .invocations = invocations.items, .method = "Conservative lexical extraction of literal command-position jq/jg words. Shell expansions are never evaluated; dynamic filters/paths are marked. Heredoc bodies are skipped. This is an inventory of recognized forms, not an exhaustive shell execution trace; wrappers, backticks, scripts and dynamically constructed commands need separate review." }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    const file = try Io.Dir.cwd().createFile(init.io, args[3], .{ .truncate = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, output.written());
}

fn keyword(word: []const u8) bool {
    for ([_][]const u8{ "if", "then", "elif", "else", "do", "while", "until", "!", "command", "exec", "env", "time" }) |name| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

fn invocation(a: A, command: Command, tokens: []const Token, at: usize) !Invocation {
    var result: Invocation = .{ .record = command.record, .cwd = command.cwd[7..], .tool = tokens[at].text, .query = null, .query_file = null, .flags = &.{}, .files = &.{}, .dynamic = false };
    var flags: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var index = at + 1;
    var options = true;
    var query_seen = false;
    while (index < tokens.len and tokens[index].kind == .word) : (index += 1) {
        const token = tokens[index];
        // A numeric file descriptor immediately before redirection is not input.
        if (index + 1 < tokens.len and tokens[index + 1].kind == .redirect and token.text.len > 0 and std.mem.allEqual(u8, token.text, '2')) break;
        result.dynamic = result.dynamic or token.dynamic;
        if (options and std.mem.eql(u8, token.text, "--")) {
            options = false;
            continue;
        }
        if (options and token.text.len > 1 and token.text[0] == '-') {
            try flags.append(a, token.text);
            const count: usize = if (std.mem.eql(u8, token.text, "--arg") or std.mem.eql(u8, token.text, "--argjson") or std.mem.eql(u8, token.text, "--slurpfile") or std.mem.eql(u8, token.text, "--rawfile")) 2 else if (std.mem.eql(u8, token.text, "-f") or std.mem.eql(u8, token.text, "--from-file") or std.mem.eql(u8, token.text, "--indent")) 1 else 0;
            if (index + count >= tokens.len) return result;
            for (0..count) |_| {
                index += 1;
                if (tokens[index].kind != .word) return result;
                result.dynamic = result.dynamic or tokens[index].dynamic;
                try flags.append(a, tokens[index].text);
            }
            if ((std.mem.eql(u8, token.text, "-f") or std.mem.eql(u8, token.text, "--from-file")) and count == 1) result.query_file = tokens[index].text;
        } else if (!query_seen and result.query_file == null) {
            query_seen = true;
            result.query = token.text;
            // A shell-expanded query is intentionally unusable as literal code.
            if (token.dynamic) result.query = null;
        } else try files.append(a, token.text);
    }
    result.flags = flags.items;
    result.files = files.items;
    if (result.query != null and result.query_file != null) result.dynamic = true;
    return result;
}

fn control(byte: u8) bool {
    return std.mem.indexOfScalar(u8, ";|&(){}\n<>", byte) != null;
}

fn scan(a: A, input: []const u8) ![]const Token {
    const Here = struct { delimiter: []const u8, tabs: bool };
    var pending: std.ArrayList(Here) = .empty;
    var expect_here: ?bool = null;
    var tokens: std.ArrayList(Token) = .empty;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        if (byte == ' ' or byte == '\t' or byte == '\r') {
            index += 1;
            continue;
        }
        if (byte == '#') {
            while (index < input.len and input[index] != '\n') : (index += 1) {}
            continue;
        }
        if (byte == '\\' and index + 1 < input.len and input[index + 1] == '\n') {
            index += 2;
            continue;
        }
        if (control(byte)) {
            const start = index;
            index += 1;
            if (byte == '<' and index < input.len and input[index] == '<') {
                index += 1;
                if (index < input.len and input[index] == '<') index += 1 else {
                    expect_here = index < input.len and input[index] == '-';
                    if (expect_here.?) index += 1;
                }
            } else if (index < input.len and input[index] == byte and (byte == '|' or byte == '&' or byte == '>')) index += 1;
            try tokens.append(a, .{ .kind = if (byte == '<' or byte == '>') .redirect else .boundary, .text = input[start..index] });
            if (byte == '\n' and pending.items.len != 0) {
                for (pending.items) |here| {
                    var found = false;
                    while (index < input.len) {
                        const end = if (std.mem.indexOfScalarPos(u8, input, index, '\n')) |next| next else input.len;
                        const line = if (here.tabs) std.mem.trimStart(u8, input[index..end], "\t") else input[index..end];
                        index = if (end < input.len) end + 1 else end;
                        if (std.mem.eql(u8, line, here.delimiter)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.UnterminatedHeredoc;
                }
                pending.clearRetainingCapacity();
            }
            continue;
        }
        var text: std.ArrayList(u8) = .empty;
        var dynamic = false;
        while (index < input.len and !std.ascii.isWhitespace(input[index]) and !control(input[index])) {
            const current = input[index];
            index += 1;
            if (current == '\'' or current == '"' or current == '`') {
                const quote = current;
                if (quote == '`') dynamic = true;
                var closed = false;
                while (index < input.len) {
                    const c = input[index];
                    index += 1;
                    if (c == quote) {
                        closed = true;
                        break;
                    }
                    if (quote != '\'' and c == '\\' and index < input.len and std.mem.indexOfScalar(u8, "$`\"\\\n", input[index]) != null) {
                        if (input[index] != '\n') try text.append(a, input[index]);
                        index += 1;
                    } else {
                        if (quote != '\'' and c == '$') dynamic = true;
                        try text.append(a, c);
                    }
                }
                if (!closed) return error.UnterminatedQuote;
            } else if (current == '\\' and index < input.len) {
                if (input[index] != '\n') try text.append(a, input[index]);
                index += 1;
            } else {
                if (std.mem.indexOfScalar(u8, "$*?[", current) != null) dynamic = true;
                try text.append(a, current);
            }
        }
        const word = try text.toOwnedSlice(a);
        try tokens.append(a, .{ .kind = .word, .text = word, .dynamic = dynamic });
        if (expect_here) |tabs| {
            try pending.append(a, .{ .delimiter = word, .tabs = tabs });
            expect_here = null;
        }
    }
    if (pending.items.len != 0) return error.UnterminatedHeredoc;
    return tokens.items;
}

test "history extraction preserves literal bindings and skips heredoc command text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try scan(a, "cat <<'EOF' > note\njq 'not a command' bad\nEOF\njq -r --arg name literal '.name == $name' report.json; jq \"$dynamic\" file\n");
    var count: usize = 0;
    var position = true;
    const command: Command = .{ .record = 1, .id = "test", .cwd = "file:///project", .command = "", .exit_code = 0 };
    for (tokens, 0..) |token, at| {
        if (token.kind == .boundary) {
            position = true;
            continue;
        }
        if (position and token.kind == .word and std.mem.eql(u8, token.text, "jq")) {
            const item = try invocation(a, command, tokens, at);
            if (count == 0) {
                try std.testing.expectEqualStrings(".name == $name", item.query.?);
                try std.testing.expectEqualStrings("report.json", item.files[0]);
                try std.testing.expect(!item.dynamic);
            } else {
                try std.testing.expect(item.dynamic);
                try std.testing.expect(item.query == null);
                try std.testing.expectEqualStrings("file", item.files[0]);
            }
            count += 1;
        }
        position = false;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "history extraction keeps shell escapes and rejects incomplete text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try scan(a, "jq '.x == \"a\"' a\\ b.json \\\n c.json");
    try std.testing.expectEqualStrings("a b.json", tokens[2].text);
    try std.testing.expectEqualStrings("c.json", tokens[3].text);
    try std.testing.expectError(error.UnterminatedQuote, scan(a, "jq 'broken"));
    try std.testing.expectError(error.UnterminatedHeredoc, scan(a, "cat <<END\nbody\n"));
}

fn readJson(comptime T: type, a: A, io: Io, path: []const u8) !T {
    const bytes = try S.files.read(a, io, .{ .path = path, .limit = 16 * 1024 * 1024 });
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .ignore_unknown_fields = true, .parse_numbers = false });
}

fn catalog(a: A, io: Io, path: []const u8, root: []const u8, out: []const u8) !void {
    const inventory = try readJson(Inventory, a, io, path);
    const Entry = struct { query: []const u8, uses: usize = 0, records: std.ArrayList(usize) = .empty };
    var entries: std.ArrayList(Entry) = .empty;
    var index: std.StringHashMap(usize) = .init(a);
    var dynamic: usize = 0;
    var from_file: usize = 0;
    var jq: usize = 0;
    var jg: usize = 0;
    for (inventory.invocations) |item| {
        if (std.mem.eql(u8, std.fs.path.basename(item.tool), "jq")) jq += 1 else jg += 1;
        if (item.dynamic) dynamic += 1;
        if (item.query_file != null) from_file += 1;
        if (item.query) |query| {
            const at = if (index.get(query)) |at| at else blk: {
                const at = entries.items.len;
                try index.put(query, at);
                try entries.append(a, .{ .query = query });
                break :blk at;
            };
            entries.items[at].uses += 1;
            try entries.items[at].records.append(a, item.record);
        }
    }
    std.sort.pdq(Entry, entries.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return if (x.uses != y.uses) x.uses > y.uses else std.mem.lessThan(u8, x.query, y.query);
        }
    }.less);
    var queries: std.ArrayList(struct { query: []const u8, recognized_uses: usize, records: []const usize }) = .empty;
    for (entries.items) |entry| try queries.append(a, .{ .query = entry.query, .recognized_uses = entry.uses, .records = entry.records.items });
    const Script = struct { path: []const u8, bytes: usize, cues: []const []const u8 };
    var scripts: std.ArrayList(Script) = .empty;
    var dir = try Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ root, "local-state/validations" }), .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jq")) continue;
        const relative = try std.fs.path.join(a, &.{ "local-state/validations", entry.path });
        const text = try S.files.read(a, io, .{ .path = try std.fs.path.join(a, &.{ root, relative }), .limit = 256 * 1024 });
        var cues: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ " as $", "def ", "reduce ", "foreach ", "walk(", "with_entries(", "from_entries", "capture(", "getpath(", "setpath(", "tonumber", "add" }) |cue| if (std.mem.indexOf(u8, text, cue) != null) try cues.append(a, cue);
        try scripts.append(a, .{ .path = relative, .bytes = text.len, .cues = cues.items });
    }
    try S.json.writeAtomic(a, io, .{ .path = out, .replace = true }, .{
        .schema_version = 1,
        .session = "01a1c2a9-b739-7e13-b134-3167995ee5d1",
        .history_snapshot_sha256 = "54ff8b1ba32f9de4ee62eee025eddf8f0e51ecce3b29a57d76fed0c40fe820c1",
        .candidate_command_records = inventory.candidate_command_records,
        .project_command_records = inventory.project_command_records,
        .recognized_invocations = inventory.invocations.len,
        .jq_invocations = jq,
        .jg_invocations = jg,
        .dynamic_contexts = dynamic,
        .query_file_invocations = from_file,
        .distinct_literal_queries = queries.items.len,
        .queries = queries.items,
        .retained_query_scripts = scripts.items,
        .limits = "Conservative lexical recognition, not a full shell parser or an exhaustive execution trace. Record references are physical JSONL line numbers in the fixed snapshot. Dynamic contexts, wrappers, stdin pipelines and query files need separate resolution. Script cues are textual observations, not proof of an untranslatable workflow. No report payloads or binding values are included.",
    });
}

const Mapping = struct { id: []const u8, jq: []const u8, jqz: []const u8, file: ?[]const u8 = null, stream: bool = false, expected_gap: ?[]const u8 = null };
const Input = struct { path: []const u8, bytes: u64, sha256: []const u8 };
const Outcome = struct { code: ?i32, outcome: []const u8, stdout_bytes: usize, stdout_sha256: []const u8, stderr_bytes: usize, stderr_sha256: []const u8, operational: bool };
const Check = struct { id: []const u8, record: usize, cwd: []const u8, inputs: []const Input, input_args: []const []const u8, jq_flags: []const []const u8, jqz_flags: []const []const u8, status: []const u8, reason: ?[]const u8, jq: Outcome, jqz: Outcome, byte_identical: bool, json_equal: ?bool };

fn digest(a: A, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

fn fileHash(a: A, io: Io, path: []const u8) ![]const u8 {
    return a.dupe(u8, &std.fmt.bytesToHex(try S.files.sha256(io, path), .lower));
}

fn compare(a: A, io: Io, inventory_path: []const u8, mappings_path: []const u8, binary_arg: []const u8, out: []const u8) !void {
    const root = "/home/oleg/prog/z_llvm";
    const binary = try Io.Dir.cwd().realPathFileAlloc(io, binary_arg, a);
    const inventory = try readJson(Inventory, a, io, inventory_path);
    const mappings = try readJson([]const Mapping, a, io, mappings_path);
    const binary_hash = try fileHash(a, io, binary);
    const jq_hash = try fileHash(a, io, "/usr/bin/jq");
    const version = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = &.{ binary, "--version" } }, .timeout_ms = 5000 } });
    if (!version.success()) return error.CandidateVersionFailed;
    var checks: std.ArrayList(Check) = .empty;
    const Count = struct { id: []const u8, recognized_matches: usize = 0, dynamic_contexts: usize = 0, unresolved_or_missing_input: usize = 0, unsupported_flags: usize = 0, over_input_limit: usize = 0, executed: usize = 0 };
    var counts: std.ArrayList(Count) = .empty;
    for (mappings) |mapping| {
        if (std.mem.indexOfScalar(u8, mapping.jq, 0) != null or std.mem.indexOfScalar(u8, mapping.jqz, 0) != null) return error.NulInQueryArgument;
        if (mapping.file) |path| {
            const bytes = try S.files.read(a, io, .{ .path = path, .limit = 64 * 1024 });
            if (!std.mem.eql(u8, std.mem.trim(u8, bytes, " \r\n\t"), mapping.jqz)) return error.QueryFileMismatch;
        }
        var count: Count = .{ .id = mapping.id };
        var used_inputs: std.StringHashMap(void) = .init(a);
        for (inventory.invocations) |item| {
            if (item.query == null or !std.mem.eql(u8, item.query.?, mapping.jq) or item.query_file != null) continue;
            count.recognized_matches += 1;
            if (item.dynamic) {
                count.dynamic_contexts += 1;
                continue;
            }
            var flags: std.ArrayList([]const u8) = .empty;
            var raw = false;
            var valid_flags = true;
            for (item.flags) |flag| {
                if (std.mem.eql(u8, flag, "--slurp")) {
                    if (!mapping.stream) try flags.append(a, "-s");
                    continue;
                }
                if (std.mem.eql(u8, flag, "--raw-output")) {
                    raw = true;
                    try flags.append(a, "-r");
                    continue;
                }
                if (flag.len < 2 or flag[0] != '-' or flag[1] == '-') {
                    valid_flags = false;
                    break;
                }
                for (flag[1..]) |byte| switch (byte) {
                    'c' => {}, // jqz is already compact.
                    's' => if (!mapping.stream) {
                        try flags.append(a, "-s");
                    },
                    'r' => {
                        raw = true;
                        try flags.append(a, "-r");
                    },
                    'e' => try flags.append(a, "-e"),
                    'S' => try flags.append(a, "-S"),
                    'n' => try flags.append(a, "-n"),
                    'j' => {
                        if (mapping.expected_gap == null) valid_flags = false;
                    },
                    else => valid_flags = false,
                };
            }
            if (!valid_flags) {
                count.unsupported_flags += 1;
                continue;
            }
            if (item.files.len == 0) {
                count.unresolved_or_missing_input += 1;
                continue;
            }
            var inputs: std.ArrayList(Input) = .empty;
            var missing = false;
            var large = false;
            var ndjson = false;
            for (item.files) |path| {
                if (std.mem.eql(u8, path, "-")) {
                    missing = true;
                    break;
                }
                const full = try std.fs.path.resolve(a, &.{ item.cwd, path });
                if (!std.mem.startsWith(u8, full, root ++ "/")) {
                    missing = true;
                    break;
                }
                const stat = Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch {
                    missing = true;
                    break;
                };
                if (stat.kind != .file) {
                    missing = true;
                    break;
                }
                if (stat.size > 32 * 1024 * 1024) {
                    large = true;
                    break;
                }
                ndjson = ndjson or std.mem.endsWith(u8, path, ".jsonl") or std.mem.endsWith(u8, path, ".ndjson");
                try inputs.append(a, .{ .path = full[root.len + 1 ..], .bytes = stat.size, .sha256 = try fileHash(a, io, full) });
            }
            if (missing) {
                count.unresolved_or_missing_input += 1;
                continue;
            }
            if (large) {
                count.over_input_limit += 1;
                continue;
            }
            const signature = try std.json.Stringify.valueAlloc(a, inputs.items, .{});
            if (used_inputs.contains(signature) or count.executed >= 3) continue;
            try used_inputs.put(signature, {});
            if (ndjson) try flags.append(a, "--ndjson");
            var reference: std.ArrayList([]const u8) = .empty;
            try reference.appendSlice(a, &.{ "/usr/bin/jq", "-c" });
            try reference.appendSlice(a, item.flags);
            try reference.append(a, mapping.jq);
            try reference.appendSlice(a, item.files);
            var candidate: std.ArrayList([]const u8) = .empty;
            try candidate.append(a, binary);
            try candidate.appendSlice(a, flags.items);
            try candidate.append(a, mapping.jqz);
            try candidate.appendSlice(a, item.files);
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const scratch = arena.allocator();
            const r = try run(scratch, io, item.cwd, reference.items);
            const c = try run(scratch, io, item.cwd, candidate.items);
            const before = try outcome(a, r);
            const after = try outcome(a, c);
            const byte_identical = std.mem.eql(u8, r.stdout, c.stdout);
            const json_equal = if (raw) null else jsonLinesEqual(scratch, r.stdout, c.stdout) catch false;
            var unchanged = true;
            for (inputs.items) |input| if (!std.mem.eql(u8, input.sha256, try fileHash(a, io, try std.fs.path.join(a, &.{ root, input.path })))) {
                unchanged = false;
                break;
            };
            const equivalent = before.operational and after.operational and before.code == after.code and before.stderr_bytes == 0 and after.stderr_bytes == 0 and (byte_identical or json_equal == true);
            const status = if (!unchanged) "input_changed" else if (!before.operational or !after.operational) "process_failed" else if (before.code != 0 and before.code != 1 and before.code != 4) "reference_failed" else if (equivalent) "passed" else if (mapping.expected_gap != null) "expected_gap" else "mismatch";
            try checks.append(a, .{ .id = mapping.id, .record = item.record, .cwd = item.cwd, .inputs = inputs.items, .input_args = item.files, .jq_flags = item.flags, .jqz_flags = flags.items, .status = status, .reason = mapping.expected_gap, .jq = before, .jqz = after, .byte_identical = byte_identical, .json_equal = json_equal });
            count.executed += 1;
            std.debug.print("{s}: {s} (record {d}; exits {?d}/{?d})\n", .{ mapping.id, status, item.record, before.code, after.code });
        }
        try counts.append(a, count);
    }
    if (!std.mem.eql(u8, binary_hash, try fileHash(a, io, binary)) or !std.mem.eql(u8, jq_hash, try fileHash(a, io, "/usr/bin/jq"))) return error.ToolChangedDuringAudit;
    try S.json.writeAtomic(a, io, .{ .path = out, .replace = true }, .{
        .schema_version = 1,
        .candidate_version = std.mem.trim(u8, version.stdout, " \r\n"),
        .optimization = "debug",
        .project = "z_llvm",
        .session = "01a1c2a9-b739-7e13-b134-3167995ee5d1",
        .jq_sha256 = jq_hash,
        .jqz_sha256 = binary_hash,
        .mappings_sha256 = try fileHash(a, io, mappings_path),
        .helper_sha256 = try fileHash(a, io, "docs/experiments/zllvm_usage.zig"),
        .maximum_live_inputs_per_query = 3,
        .input_limit_bytes_per_file = 32 * 1024 * 1024,
        .timeout_ms = 10000,
        .capture_limit_bytes_per_stream = 8 * 1024 * 1024,
        .method = "Explicit argv only; historical command text is never executed. Up to three distinct retained input sets per mapped literal filter, in source-record order. jq compact output; jqz compact by default. JSONL uses --ndjson; stream translations drop source -s explicitly. Ordered result sequences, unordered object keys and exact decimal values compared. Raw output compared byte-for-byte. Inputs hashed before/after each pair; tool binaries checked across audit. No report payloads are published. A matched filter or script cue is not itself a compatibility claim.",
        .coverage = counts.items,
        .checks = checks.items,
    });
    for (checks.items) |check| if (!std.mem.eql(u8, check.status, "passed") and !std.mem.eql(u8, check.status, "expected_gap")) return error.TranslationCheckFailed;
}

fn run(a: A, io: Io, cwd: []const u8, argv: []const []const u8) !S.process.Report {
    return S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = argv, .cwd = .{ .path = cwd } }, .timeout_ms = 10000, .stdout_limit = 8 * 1024 * 1024, .stderr_limit = 8 * 1024 * 1024 } });
}

fn outcome(a: A, report: S.process.Report) !Outcome {
    return .{ .code = if (report.term) |term| S.command.code(term) else null, .outcome = @tagName(report.outcome), .stdout_bytes = report.stdout.len, .stdout_sha256 = try digest(a, report.stdout), .stderr_bytes = report.stderr.len, .stderr_sha256 = try digest(a, report.stderr), .operational = report.outcome == .completed and report.term != null and report.cleanup_failure == null };
}

fn jsonLinesEqual(a: A, x: []const u8, y: []const u8) !bool {
    var left = std.mem.splitScalar(u8, if (std.mem.endsWith(u8, x, "\n")) x[0 .. x.len - 1] else x, '\n');
    var right = std.mem.splitScalar(u8, if (std.mem.endsWith(u8, y, "\n")) y[0 .. y.len - 1] else y, '\n');
    if (x.len == 0 or y.len == 0) return x.len == y.len;
    while (left.next()) |line| {
        const other = right.next() orelse return false;
        const lv = try std.json.parseFromSliceLeaky(V, a, line, .{ .parse_numbers = false });
        const rv = try std.json.parseFromSliceLeaky(V, a, other, .{ .parse_numbers = false });
        if (!try equal(lv, rv, 0)) return false;
    }
    return right.next() == null;
}

fn equal(x: V, y: V, depth: usize) !bool {
    if (depth > 128) return error.OutputTooDeep;
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null => true,
        .bool => x.bool == y.bool,
        .string => std.mem.eql(u8, x.string, y.string),
        .number_string => (try Number.compare(x.number_string, y.number_string)) == .eq,
        .array => blk: {
            if (x.array.items.len != y.array.items.len) break :blk false;
            for (x.array.items, y.array.items) |left, right| if (!try equal(left, right, depth + 1)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (x.object.count() != y.object.count()) break :blk false;
            for (x.object.keys(), x.object.values()) |key, value| if (!try equal(value, y.object.get(key) orelse break :blk false, depth + 1)) break :blk false;
            break :blk true;
        },
        .integer, .float => unreachable,
    };
}

test "audit comparison preserves exact decimal values and ordered results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try jsonLinesEqual(a, "{\"n\":9007199254740993,\"a\":1.5}\n", "{\"a\":1.500,\"n\":9007199254740993.0}\n"));
    try std.testing.expect(!try jsonLinesEqual(a, "9007199254740993\n", "9007199254740992\n"));
    try std.testing.expect(!try jsonLinesEqual(a, "1\n2\n", "2\n1\n"));
    try std.testing.expect(!try jsonLinesEqual(a, "1\n", "1\n2\n"));
    try std.testing.expect(!try jsonLinesEqual(a, "1\n\n", "1\n"));
}

const Fixture = struct { id: []const u8, input: []const u8, expected: []const u8, ndjson: bool = false, code: i32 = 0, jq_flags: []const []const u8 = &.{}, jqz_flags: []const []const u8 = &.{}, equivalent: bool = true };

fn fixture(spec: Fixture) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const mappings = try std.json.parseFromSliceLeaky([]const Mapping, a, @embedFile("zllvm_translations.json"), .{});
    var mapping: ?Mapping = null;
    for (mappings) |item| if (std.mem.eql(u8, spec.id, item.id)) {
        mapping = item;
        break;
    };
    const selected = mapping orelse return error.UnknownFixture;
    const binary = try Io.Dir.cwd().realPathFileAlloc(io, "zig-out/bin/jqz", a);
    var reference: std.ArrayList([]const u8) = .empty;
    try reference.appendSlice(a, &.{ "/usr/bin/jq", "-c" });
    if (spec.ndjson) try reference.append(a, "-s");
    try reference.appendSlice(a, spec.jq_flags);
    try reference.append(a, selected.jq);
    var candidate: std.ArrayList([]const u8) = .empty;
    try candidate.append(a, binary);
    if (spec.ndjson) {
        try candidate.append(a, "--ndjson");
        if (!selected.stream) try candidate.append(a, "-s");
    }
    try candidate.appendSlice(a, spec.jqz_flags);
    try candidate.append(a, selected.jqz);
    const r = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = reference.items }, .timeout_ms = 5000 }, .stdin = spec.input });
    const c = try S.command.runReport(a, io, .{ .run = .{ .spawn = .{ .argv = candidate.items }, .timeout_ms = 5000 }, .stdin = spec.input });
    try S.Diagnostic.expectExit(r, .{ .assertion = "independent jq fixture", .code = spec.code });
    try S.Diagnostic.expectExit(c, .{ .assertion = "jqz fixture", .code = spec.code });
    try std.testing.expectEqualStrings("", r.stderr);
    try std.testing.expectEqualStrings("", c.stderr);
    try std.testing.expectEqualStrings(spec.expected, r.stdout);
    if (spec.equivalent) try std.testing.expect(try jsonLinesEqual(a, r.stdout, c.stdout)) else try std.testing.expect(!std.mem.eql(u8, r.stdout, c.stdout));
}

test "compiler translations preserve multiple results and negative gate exits" {
    try fixture(.{ .id = "command-count-and-tail", .input = "[{\"argv\":[\"cc\"],\"returncode\":0},{\"argv\":[\"link\"],\"returncode\":1}]", .expected = "2\n{\"argv\":[\"link\"],\"returncode\":1}\n" });
    try fixture(.{ .id = "negative-toolchain-gate", .input = "{\"zllvm\":\"/bin/true\"}", .expected = "false\n", .code = 1, .jq_flags = &.{"-e"}, .jqz_flags = &.{"-e"} });
}

test "stream census translations preserve jq truthiness and empty completion" {
    const records =
        \\{"event":"function","function":"a","selected":false}
        \\{"event":"function","function":"b","selected":true}
        \\{"event":"function","function":"c"}
        \\{"event":"function","function":"d","selected":null}
        \\{"event":"function","function":"e","selected":0}
        \\{"event":"function","function":"f","selected":"false"}
        \\{"event":"complete"}
        \\
    ;
    try fixture(.{ .id = "census-counts", .input = records, .ndjson = true, .expected = "{\"examined\":6,\"failed\":3}\n" });
    try fixture(.{ .id = "census-progress", .input = records, .ndjson = true, .expected = "{\"completed\":6,\"last\":\"f\"}\n" });
    try fixture(.{ .id = "census-counts", .input = "{\"event\":\"complete\"}\n", .ndjson = true, .expected = "{\"examined\":0,\"failed\":0}\n" });
    try fixture(.{ .id = "census-progress", .input = "{\"event\":\"complete\"}\n", .ndjson = true, .expected = "{\"completed\":0,\"last\":null}\n" });
}

test "grouped compiler translations preserve sorted tie order and null keys" {
    const records =
        \\{"event":"function","selected":false,"selector_detail":"b","function":"b1"}
        \\{"event":"function","selected":false,"selector_detail":"a","function":"a1"}
        \\{"event":"function","selected":false,"function":"n1"}
        \\{"event":"function","selected":false,"selector_detail":"b","function":"b2"}
        \\{"event":"function","selected":false,"selector_detail":"a","function":"a2"}
        \\{"event":"function","selected":false,"function":"n2"}
        \\
    ;
    try fixture(.{ .id = "grouped-rejections", .input = records, .ndjson = true, .expected = "[{\"boundary\":null,\"count\":2,\"examples\":[\"n1\",\"n2\"]},{\"boundary\":\"a\",\"count\":2,\"examples\":[\"a1\",\"a2\"]},{\"boundary\":\"b\",\"count\":2,\"examples\":[\"b1\",\"b2\"]}]\n" });
    try fixture(.{ .id = "grouped-selector-pairs", .input = records, .ndjson = true, .expected = "[{\"tag\":null,\"detail\":null,\"count\":2,\"functions\":[\"n1\",\"n2\"]},{\"tag\":null,\"detail\":\"a\",\"count\":2,\"functions\":[\"a1\",\"a2\"]},{\"tag\":null,\"detail\":\"b\",\"count\":2,\"functions\":[\"b1\",\"b2\"]}]\n" });
}

test "raw path protocol counterexample exposes mandatory newline difference" {
    try fixture(.{ .id = "nul-path-protocol", .input = "{\"files\":{\"a.zig\":\"hash-a\",\"b.zig\":\"hash-b\"}}", .expected = "a.zig\x00b.zig\x00", .jq_flags = &.{"-jr"}, .jqz_flags = &.{"-r"}, .equivalent = false });
}
