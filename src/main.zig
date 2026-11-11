const std = @import("std");
const query = @import("query");

const usage =
    \\Usage: jqz [OPTIONS] QUERY [FILE|-]
    \\       jqz [OPTIONS] -f QUERY_FILE [FILE|-]
    \\
    \\Read one JSON document, or all NDJSON records as one stream.
    \\Without FILE, read stdin. Output is one JSON value per line.
    \\
    \\  --ndjson                  Parse one JSON record per nonblank line
    \\  -r, --raw-output          Write strings raw; other values as JSON
    \\  -e, --exit-status         Status 1 for false/null, 4 for no output
    \\  -f, --from-file FILE      Read the query from FILE (only once)
    \\  --                       End options (e.g. before a negative query)
    \\  -h, --help               Show this help
    \\  --version                Show the package version
    \\
    \\With -f, the sole positional argument is the input file. -f - reads
    \\the query from stdin and requires a separate, explicit input file.
    \\
    \\Examples:
    \\  .users | each | where(.age >= 18) | {name: .name}
    \\  .enabled? ?? true
    \\  where(.level == "error") | count
    \\  each | .amount | sum
    \\  each | sort_by(.name) | take(10) | collect
    \\  each | group_by(.team)
    \\
    \\Stages: expressions, each, where(boolean), count, collect, take(n),
    \\        sum, sort, sort_by(key), group_by(key)
    \\Arithmetic: checked i128 + - * / %, unary -; division must be exact.
    \\Limits: query 64 KiB; document 64 MiB; NDJSON line 1 MiB; nesting 128.
    \\        Retaining stages share 64 MiB; no disk spilling.
    \\take stops upstream work; skipped records are not validated.
    \\Exit: 0 success (including no matches), 2 query/input/evaluation/IO error.
    \\With -e: last output determines 0/1/4; errors still return 2.
    \\
;

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        std.debug.print("jqz: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    var error_buffer: [4096]u8 = undefined;
    var errors = std.Io.File.stderr().writer(io, &error_buffer);
    var ndjson = false;
    var raw_output = false;
    var exit_status = false;
    var options = true;
    var query_file: ?[]const u8 = null;
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, arg, "--version")) {
            try output.interface.print("jqz {s}\n", .{query.version});
            try output.interface.flush();
            return 0;
        } else if (options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            try output.interface.writeAll(usage);
            try output.interface.flush();
            return 0;
        } else if (options and std.mem.eql(u8, arg, "--ndjson")) {
            ndjson = true;
        } else if (options and (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--raw-output"))) {
            raw_output = true;
        } else if (options and (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exit-status"))) {
            exit_status = true;
        } else if (options and (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--from-file"))) {
            if (query_file != null) return argumentError(&errors.interface, "only one -f query source is allowed");
            index += 1;
            if (index == args.len) return argumentError(&errors.interface, "-f requires a query filename");
            query_file = args[index];
        } else if (options and arg.len > 1 and arg[0] == '-') {
            try errors.interface.print("jqz: unknown option {s}; use -- before a query beginning with -\n", .{arg});
            try errors.interface.flush();
            return 2;
        } else {
            if (positional_count == positional.len) return argumentError(&errors.interface, "expected one query source and at most one input file");
            positional[positional_count] = arg;
            positional_count += 1;
        }
    }
    if (query_file == null and positional_count == 0) return argumentError(&errors.interface, usage);
    if (query_file != null and positional_count > 1) return argumentError(&errors.interface, "with -f, supply only the input filename; inline queries cannot be combined with -f");
    const path: ?[]const u8 = if (query_file != null)
        (if (positional_count == 1) positional[0] else null)
    else if (positional_count == 2) positional[1] else null;
    const from_stdin = path == null or std.mem.eql(u8, path.?, "-");
    const label = if (from_stdin) "<stdin>" else path.?;
    const query_label = query_file orelse "query";
    var query_bytes: ?[]u8 = null;
    defer if (query_bytes) |bytes| allocator.free(bytes);
    const source = if (query_file) |query_path| blk: {
        const query_stdin = std.mem.eql(u8, query_path, "-");
        if (query_stdin and from_stdin) return argumentError(&errors.interface, "-f - requires an explicit non-stdin input file");
        const file = if (query_stdin) std.Io.File.stdin() else std.Io.Dir.cwd().openFile(io, query_path, .{}) catch |err| return fileError(&errors.interface, query_path, "open query file", err);
        defer if (!query_stdin) file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        query_bytes = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |err| return fileError(&errors.interface, query_path, "read query (limit 64 KiB)", err);
        break :blk query_bytes.?;
    } else positional[0];
    var diagnostic: query.Diagnostic = .{};
    var program = query.Program.compile(allocator, source, &diagnostic) catch |err| {
        if (err == error.InvalidQuery) {
            try diagnostic.writeNamed(source, query_label, &errors.interface);
            try errors.interface.flush();
            return 2;
        }
        return err;
    };
    defer program.deinit();
    var stream = try program.start(allocator, &output.interface, &diagnostic, .{ .raw_output = raw_output });
    defer stream.deinit();
    var runner: Runner = .{ .stream = &stream, .source = source, .query_label = query_label, .diagnostic = &diagnostic, .label = label, .output = &output.interface, .errors = &errors.interface, .exit_status = exit_status };
    if (!stream.needsInput()) return runner.finish();
    const file = if (from_stdin) std.Io.File.stdin() else std.Io.Dir.cwd().openFile(io, path.?, .{}) catch |err| return fileError(&errors.interface, label, "open input file", err);
    defer if (!from_stdin) file.close(io);
    const max_line = 1024 * 1024;
    const buffer = try allocator.alloc(u8, if (ndjson) max_line + 1 else 16 * 1024);
    defer allocator.free(buffer);
    var reader = file.reader(io, buffer);
    if (!ndjson) {
        const bytes = reader.interface.allocRemaining(allocator, .limited(query.max_input_bytes)) catch |err| return fileError(&errors.interface, label, "read JSON document (limit 64 MiB)", err);
        defer allocator.free(bytes);
        const code = try runner.evaluate(bytes, 1);
        if (code != 0) return code;
        return runner.finish();
    }
    var line: usize = 0;
    while (stream.needsInput()) {
        const bytes = (reader.interface.takeDelimiter('\n') catch |err| {
            try errors.interface.print("{s}:{d}: cannot read NDJSON record: {s} (line limit 1 MiB)\n", .{ label, line + 1, @errorName(err) });
            try errors.interface.flush();
            return 2;
        }) orelse break;
        line += 1;
        if (bytes.len > max_line) {
            try errors.interface.print("{s}:{d}: NDJSON record exceeds 1 MiB\n", .{ label, line });
            try errors.interface.flush();
            return 2;
        }
        if (std.mem.trim(u8, bytes, " \t\r").len == 0) continue;
        const code = try runner.evaluate(bytes, line);
        output.interface.flush() catch |err| return fileError(&errors.interface, label, "write output", err);
        if (code != 0) return code;
    }
    return runner.finish();
}

fn argumentError(errors: *std.Io.Writer, message: []const u8) !u8 {
    try errors.print("jqz: {s}\n", .{message});
    try errors.flush();
    return 2;
}

fn fileError(errors: *std.Io.Writer, label: []const u8, operation: []const u8, err: anyerror) !u8 {
    try errors.print("{s}: cannot {s}: {s}\n", .{ label, operation, @errorName(err) });
    try errors.flush();
    return 2;
}

const Runner = struct {
    stream: *query.Stream,
    source: []const u8,
    query_label: []const u8,
    diagnostic: *const query.Diagnostic,
    label: []const u8,
    output: *std.Io.Writer,
    errors: *std.Io.Writer,
    exit_status: bool,

    fn evaluate(self: *Runner, bytes: []const u8, line: usize) !u8 {
        _ = self.stream.feed(bytes) catch |err| return self.report(err, bytes, line);
        return 0;
    }

    fn finish(self: *Runner) !u8 {
        self.stream.finish() catch |err| return self.report(err, "", null);
        self.output.flush() catch |err| return fileError(self.errors, self.label, "write output", err);
        return if (self.exit_status) self.stream.predicateStatus() else 0;
    }

    fn report(self: *Runner, err: anyerror, input: []const u8, line: ?usize) !u8 {
        self.output.flush() catch |write_err| return fileError(self.errors, self.label, "write output", write_err);
        const diagnostic = self.diagnostic.*;
        if (line) |record_line| {
            if (diagnostic.input_offset != null) {
                try self.errors.print("{s}:{d}:{d}: {s}\n", .{ self.label, record_line + diagnostic.input_line - 1, diagnostic.input_column, @errorName(err) });
                try diagnostic.writeInput(input, self.errors);
            } else try self.errors.print("{s}:{d}: {s}\n", .{ self.label, record_line, @errorName(err) });
        } else try self.errors.print("{s}:EOF: {s}\n", .{ self.label, @errorName(err) });
        if (err == error.EvaluationFailed) try diagnostic.writeNamed(self.source, self.query_label, self.errors);
        try self.errors.flush();
        return 2;
    }
};
