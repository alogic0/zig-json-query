const std = @import("std");
const query = @import("query");
const file_bindings = @import("file_bindings.zig");

const usage =
    \\Usage: jqz [OPTIONS] QUERY [FILE|- ...]
    \\       jqz [OPTIONS] -f QUERY_FILE [FILE|- ...]
    \\
    \\Read one JSON document per file, or all NDJSON records as one stream.
    \\Without FILE, read stdin. Output is one value per line unless -j is set.
    \\
    \\  -n, --null-input          Run once with null; read no input data
    \\  --ndjson                  Parse one JSON record per nonblank line
    \\  -s, --slurp               Query one array containing all input values
    \\  -r, --raw-output          Write strings raw; other values as JSON
    \\  -j, --join-output         Raw strings; no trailing output newlines
    \\  -S, --sort-keys           Sort object names recursively in JSON output
    \\  -e, --exit-status         Status 1 for false/null, 4 for no output
    \\  --arg NAME VALUE         Bind $NAME to a string
    \\  --argjson NAME JSON      Bind $NAME to one exact JSON value
    \\  --slurpfile NAME FILE    Bind $NAME to all JSON values from FILE
    \\  --rawfile NAME FILE      Bind $NAME to exact UTF-8 file text
    \\  -f, --from-file FILE      Read the query from FILE (only once)
    \\  --                       End options (e.g. before a negative query)
    \\  -h, --help               Show this help
    \\  --version                Show the package version
    \\
    \\With -f, positional arguments are input files. -f - reads the query
    \\from stdin and requires explicit named input files unless -n is set.
    \\With -n, data filenames, --slurp and --ndjson are ignored; -f - can
    \\still read the query from stdin. input_filename() returns null.
    \\No-argument short flags n/s/r/j/S/e may be bundled (e.g. -nj or -jr).
    \\Binding files are named paths; - is a literal filename. Bound source
    \\text and prepared values each share a 64 MiB cap across all bindings.
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
    \\Statistics: mean(array, PLACES), divide(a, b, PLACES); PLACES 0..18,
    \\            bounded exact decimals, nearest/ties-to-even rounding.
    \\Limits: query 64 KiB; document 64 MiB; NDJSON line 1 MiB; nesting 128.
    \\        Retaining stages share 64 MiB; no disk spilling.
    \\        Slurp has a separate 64 MiB owned input-collection budget.
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
    // Inherited descriptors share their current offset with the invoking shell.
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    var error_buffer: [4096]u8 = undefined;
    var errors = std.Io.File.stderr().writerStreaming(io, &error_buffer);
    var ndjson = false;
    var null_input = false;
    var raw_output = false;
    var join_output = false;
    var sort_keys = false;
    var exit_status = false;
    var slurp_input = false;
    var options = true;
    var query_file: ?[]const u8 = null;
    var bindings: std.ArrayList(query.Binding) = .empty;
    defer bindings.deinit(allocator);
    var binding_files: std.ArrayList(file_bindings.Spec) = .empty;
    defer binding_files.deinit(allocator);
    var prepared: std.ArrayList([]u8) = .empty;
    defer {
        for (prepared.items) |bytes| allocator.free(bytes);
        prepared.deinit(allocator);
    }
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(allocator);
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
        } else if (options and (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--null-input"))) {
            null_input = true;
        } else if (options and std.mem.eql(u8, arg, "--ndjson")) {
            ndjson = true;
        } else if (options and (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--slurp"))) {
            slurp_input = true;
        } else if (options and (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--raw-output"))) {
            raw_output = true;
        } else if (options and (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--join-output"))) {
            join_output = true;
        } else if (options and (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--sort-keys"))) {
            sort_keys = true;
        } else if (options and (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exit-status"))) {
            exit_status = true;
        } else if (options and (std.mem.eql(u8, arg, "--arg") or std.mem.eql(u8, arg, "--argjson"))) {
            if (index + 2 >= args.len) return argumentError(&errors.interface, "--arg/--argjson requires a NAME and VALUE");
            try bindings.append(allocator, .{ .name = args[index + 1], .value = if (std.mem.eql(u8, arg, "--arg")) .{ .string = args[index + 2] } else .{ .json = args[index + 2] } });
            index += 2;
        } else if (options and (std.mem.eql(u8, arg, "--slurpfile") or std.mem.eql(u8, arg, "--rawfile"))) {
            if (index + 2 >= args.len) return argumentError(&errors.interface, "--slurpfile/--rawfile requires a NAME and FILE");
            try binding_files.append(allocator, .{ .index = bindings.items.len, .kind = if (std.mem.eql(u8, arg, "--slurpfile")) .json else .raw, .path = args[index + 2] });
            try bindings.append(allocator, .{ .name = args[index + 1], .value = .{ .string = "" } });
            index += 2;
        } else if (options and (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--from-file"))) {
            if (query_file != null) return argumentError(&errors.interface, "only one -f query source is allowed");
            index += 1;
            if (index == args.len) return argumentError(&errors.interface, "-f requires a query filename");
            query_file = args[index];
        } else if (options and arg.len > 1 and arg[0] == '-') {
            if (arg.len > 2 and arg[1] != '-') {
                var valid_bundle = true;
                for (arg[1..]) |flag| if (std.mem.indexOfScalar(u8, "nsrjSe", flag) == null) {
                    valid_bundle = false;
                    break;
                };
                if (valid_bundle) {
                    for (arg[1..]) |flag| switch (flag) {
                        'n' => null_input = true,
                        's' => slurp_input = true,
                        'r' => raw_output = true,
                        'j' => join_output = true,
                        'S' => sort_keys = true,
                        'e' => exit_status = true,
                        else => unreachable,
                    };
                    continue;
                }
            }
            try errors.interface.print("jqz: unknown option {s}; use -- before a query beginning with -\n", .{arg});
            try errors.interface.flush();
            return 2;
        } else {
            try positional.append(allocator, arg);
        }
    }
    if (query_file == null and positional.items.len == 0) return argumentError(&errors.interface, usage);
    const paths = if (query_file != null) positional.items else positional.items[1..];
    const default_input = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (null_input) &.{} else if (paths.len == 0) &default_input else paths;
    var stdin_count: usize = 0;
    for (inputs) |path| if (std.mem.eql(u8, path, "-")) {
        stdin_count += 1;
    };
    if (stdin_count > 1) return argumentError(&errors.interface, "stdin may be used as input at most once");
    const query_label = query_file orelse "query";
    var query_bytes: ?[]u8 = null;
    defer if (query_bytes) |bytes| allocator.free(bytes);
    const source = if (query_file) |query_path| blk: {
        const query_stdin = std.mem.eql(u8, query_path, "-");
        if (query_stdin and !null_input and (paths.len == 0 or stdin_count != 0)) return argumentError(&errors.interface, "-f - requires explicit non-stdin input files");
        const file = if (query_stdin) std.Io.File.stdin() else std.Io.Dir.cwd().openFile(io, query_path, .{}) catch |err| return fileError(&errors.interface, query_path, "open query file", err);
        defer if (!query_stdin) file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        query_bytes = reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |err| return fileError(&errors.interface, query_path, "read query (limit 64 KiB)", err);
        break :blk query_bytes.?;
    } else positional.items[0];
    var source_bytes: usize = 0;
    for (bindings.items) |binding| {
        const bytes = switch (binding.value) {
            inline else => |text| text,
        };
        if (bytes.len > query.max_input_bytes - source_bytes) return argumentError(&errors.interface, "external binding value text exceeds 64 MiB");
        source_bytes += bytes.len;
    }
    var prepared_bytes = source_bytes;
    for (binding_files.items) |spec| {
        const bytes = file_bindings.readNamed(allocator, io, spec.path, query.max_input_bytes - source_bytes) catch |err| return fileError(&errors.interface, spec.path, "read binding file (shared limit 64 MiB)", err);
        source_bytes += bytes.len;
        const value = switch (spec.kind) {
            .raw => blk: {
                if (bytes.len > query.max_input_bytes - prepared_bytes) {
                    allocator.free(bytes);
                    return fileError(&errors.interface, spec.path, "prepare binding value (shared limit 64 MiB)", error.FileBindingTooLarge);
                }
                break :blk bytes;
            },
            .json => blk: {
                defer allocator.free(bytes);
                break :blk file_bindings.jsonArray(allocator, bytes, query.max_input_bytes - prepared_bytes) catch |err| return fileError(&errors.interface, spec.path, "parse JSON binding sequence", err);
            },
        };
        prepared.append(allocator, value) catch |err| {
            allocator.free(value);
            return err;
        };
        prepared_bytes += value.len;
        bindings.items[spec.index].value = switch (spec.kind) {
            .raw => .{ .string = value },
            .json => .{ .json = value },
        };
    }
    var diagnostic: query.Diagnostic = .{};
    var program = query.Program.compileWithBindings(allocator, source, bindings.items, &diagnostic) catch |err| {
        if (err == error.InvalidBinding) return argumentError(&errors.interface, diagnostic.message);
        if (err == error.InvalidQuery) {
            try diagnostic.writeNamed(source, query_label, &errors.interface);
            try errors.interface.flush();
            return 2;
        }
        return err;
    };
    defer program.deinit();
    // Compilation owns the values; input IO and evaluation need no file buffers.
    for (prepared.items) |bytes| allocator.free(bytes);
    prepared.clearRetainingCapacity();
    var stream = try program.start(allocator, &output.interface, &diagnostic, .{ .raw_output = raw_output, .join_output = join_output, .sort_keys = sort_keys });
    defer stream.deinit();
    const slurp = if (slurp_input and !null_input and stream.needsInput()) try query.Slurp.init(allocator, query.max_input_bytes) else null;
    defer if (slurp) |collector| collector.deinit();
    var runner: Runner = .{ .stream = &stream, .source = source, .query_label = query_label, .diagnostic = &diagnostic, .label = "<stdin>", .output = &output.interface, .errors = &errors.interface, .exit_status = exit_status, .slurp = slurp };
    if (null_input) {
        runner.label = "<null>";
        if (stream.needsInput()) _ = stream.feed("null") catch |err| return runner.report(err, "null", 1);
        return runner.finish();
    }
    if (!stream.needsInput()) return runner.finish();
    for (inputs) |path| {
        if (!stream.needsInput()) break;
        runner.label = if (std.mem.eql(u8, path, "-")) "<stdin>" else path;
        const code = try readInput(io, allocator, path, ndjson, &runner);
        if (code != 0) return code;
        runner.output.flush() catch |err| return fileError(runner.errors, runner.label, "write output", err);
    }
    if (slurp != null) runner.label = "<slurp>";
    return runner.finish();
}

fn readInput(io: std.Io, allocator: std.mem.Allocator, path: []const u8, ndjson: bool, runner: *Runner) !u8 {
    const from_stdin = std.mem.eql(u8, path, "-");
    const label = runner.label;
    const file = if (from_stdin) std.Io.File.stdin() else std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return fileError(runner.errors, label, "open input file", err);
    defer if (!from_stdin) file.close(io);
    const max_line = 1024 * 1024;
    const buffer = try allocator.alloc(u8, if (ndjson) max_line + 1 else 16 * 1024);
    defer allocator.free(buffer);
    var reader = file.reader(io, buffer);
    if (!ndjson) {
        const bytes = reader.interface.allocRemaining(allocator, .limited(query.max_input_bytes)) catch |err| return fileError(runner.errors, label, "read JSON document (limit 64 MiB)", err);
        defer allocator.free(bytes);
        const code = try runner.evaluate(bytes, 1);
        if (code != 0) return code;
        return 0;
    }
    var line: usize = 0;
    while (runner.stream.needsInput()) {
        const bytes = (reader.interface.takeDelimiter('\n') catch |err| {
            try runner.errors.print("{s}:{d}: cannot read NDJSON record: {s} (line limit 1 MiB)\n", .{ label, line + 1, @errorName(err) });
            try runner.errors.flush();
            return 2;
        }) orelse break;
        line += 1;
        if (bytes.len > max_line) {
            try runner.errors.print("{s}:{d}: NDJSON record exceeds 1 MiB\n", .{ label, line });
            try runner.errors.flush();
            return 2;
        }
        if (std.mem.trim(u8, bytes, " \t\r").len == 0) continue;
        const code = try runner.evaluate(bytes, line);
        runner.output.flush() catch |err| return fileError(runner.errors, label, "write output", err);
        if (code != 0) return code;
    }
    return 0;
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
    diagnostic: *query.Diagnostic,
    label: []const u8,
    output: *std.Io.Writer,
    errors: *std.Io.Writer,
    exit_status: bool,
    slurp: ?*query.Slurp,

    fn evaluate(self: *Runner, bytes: []const u8, line: usize) !u8 {
        if (self.slurp) |collector| {
            collector.append(bytes, self.diagnostic) catch |err| return self.report(err, bytes, line);
        } else _ = self.stream.feedNamed(bytes, self.label) catch |err| return self.report(err, bytes, line);
        return 0;
    }

    fn finish(self: *Runner) !u8 {
        if (self.slurp) |collector| _ = self.stream.feedSlurp(collector) catch |err| return self.report(err, "", null);
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
