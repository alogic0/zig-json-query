const std = @import("std");
const query = @import("query");

test "external consumer owns sessions and composes new stages" {
    const allocator = std.testing.allocator;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "sort_by(.k) | group_by(.k) | each | .v*2 | sum", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var session = try program.start(allocator, &output.writer, &diagnostic, .{ .max_collect_bytes = 8192 });
    defer session.deinit();
    _ = try session.feed("{\"k\":2,\"v\":9007199254740993}");
    _ = try session.feed("{\"k\":1,\"v\":1}");
    try session.finish();
    try std.testing.expectEqualStrings("18014398509481988\n", output.written());
}

test "external consumer requests joined raw output with sorted JSON" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "each", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{ .join_output = true, .sort_keys = true });
    defer stream.deinit();
    _ = try stream.feed("[\"x\\u0000\",{\"z\":1,\"a\":2}]");
    try stream.finish();
    try t.expectEqualStrings("x\x00{\"a\":2,\"z\":1}", output.written());
}

test "external consumer composes scalar totals and ordered groups within a report" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{passed, total: sum(map(.rows,.v)), groups: sort_by(map(group_by(.rows,.k),{key: .[0].k, count: length(.)}),.key)} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var session = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer session.deinit();
    var input = "{\"passed\":false,\"rows\":[{\"k\":2,\"v\":9007199254740993},{\"k\":1,\"v\":1},{\"k\":2,\"v\":2}]}".*;
    _ = try session.feed(&input);
    @memset(&input, 'x');
    try session.finish();
    try t.expectEqualStrings("[{\"passed\":false,\"total\":9007199254740996,\"groups\":[{\"key\":1,\"count\":1},{\"key\":2,\"count\":2}]}]\n", output.written());
}

test "external consumer serializes exact values with explicit Unicode byte sizing" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{text:tojson(.),bytes:byte_length(tojson(.)),characters:length(tojson(.))} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try program.run(t.allocator, "\"é😀\"", &output.writer, &diagnostic);
    try t.expectEqualStrings("[{\"text\":\"\\\"é😀\\\"\",\"bytes\":8,\"characters\":4}]\n", output.written());
}

test "external consumer edits immutable paths and requests recursive sorted output" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "del(update(.,.groups,filter(.,.id != \"remove\")),.debug) | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, .{ .sort_keys = true });
    defer stream.deinit();
    var input = "{\"meta\":{\"z\":1,\"a\":9007199254740993},\"debug\":null,\"groups\":[{\"id\":\"remove\"},{\"id\":\"keep\",\"done\":false}]}".*;
    _ = try stream.feed(&input);
    @memset(&input, 'x');
    try stream.finish();
    try t.expectEqualStrings("[{\"groups\":[{\"done\":false,\"id\":\"keep\"}],\"meta\":{\"a\":9007199254740993,\"z\":1}}]\n", output.written());
}

test "external consumer discovers sorted distinct structural schemas" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "{schemas:unique(map(.fixtures,keys(.))),ordered:sort_values(.values)} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try program.run(t.allocator, "{\"fixtures\":[{\"b\":0},{\"b\":1,\"a\":2},{\"a\":3,\"b\":4}],\"values\":[[2],[1],null]}", &output.writer, &diagnostic);
    try t.expectEqualStrings("[{\"schemas\":[[\"a\",\"b\"],[\"b\"]],\"ordered\":[null,[1],[2]]}]\n", output.written());
}

test "external consumer combines owned bindings named feeds predicates and decimal statistics" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var label = "external".*;
    var program = try query.Program.compileWithBindings(t.allocator, "{label: $label, file: input_filename(), passed: all(.checks,.ok), mean_ms: mean(map(.ns,divide(.,1000000,6)),6)} | collect", &.{.{ .name = "label", .value = .{ .string = &label } }}, &diagnostic);
    defer program.deinit();
    @memset(&label, 'x');
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var session = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer session.deinit();
    var filename = "first.json".*;
    _ = try session.feedNamed("{\"checks\":[{\"ok\":true}],\"ns\":[1000000,2000000]}", &filename);
    @memset(&filename, 'x');
    _ = try session.feedNamed("{\"checks\":[{\"ok\":false}],\"ns\":[]}", "second.json");
    try session.finish();
    try t.expectEqualStrings("[{\"label\":\"external\",\"file\":\"first.json\",\"passed\":true,\"mean_ms\":1.500000},{\"label\":\"external\",\"file\":\"second.json\",\"passed\":false,\"mean_ms\":null}]\n", output.written());
    try t.expectEqual(@as(u8, 0), session.predicateStatus());
}

test "external consumer slurp values survive input reuse and collector destruction" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, "each | {id, file: input_filename()} | collect", &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var session = try program.start(t.allocator, &output.writer, &diagnostic, .{});
    defer session.deinit();
    {
        const collector = try query.Slurp.init(t.allocator, 64 * 1024);
        defer collector.deinit();
        var input = "{\"id\":9007199254740993}".*;
        try collector.append(&input, &diagnostic);
        @memset(&input, 'x');
        try collector.append("{\"id\":2}", &diagnostic);
        _ = try session.feedSlurp(collector);
    }
    try session.finish();
    try t.expectEqualStrings("[{\"id\":9007199254740993,\"file\":null},{\"id\":2,\"file\":null}]\n", output.written());
}

test "external consumer observes predicate statuses and validates unused bindings" {
    const t = std.testing;
    var diagnostic: query.Diagnostic = .{};
    try t.expectError(error.InvalidBinding, query.Program.compileWithBindings(t.allocator, "take(0)", &.{.{ .name = "unused", .value = .{ .json = "{bad}" } }}, &diagnostic));
    for ([_]struct { source: []const u8, expected: u8 }{
        .{ .source = "any(.checks,.ok)", .expected = 1 },
        .{ .source = "where(false)", .expected = 4 },
    }) |case| {
        var program = try query.Program.compile(t.allocator, case.source, &diagnostic);
        defer program.deinit();
        var output = std.Io.Writer.Allocating.init(t.allocator);
        defer output.deinit();
        var session = try program.start(t.allocator, &output.writer, &diagnostic, .{});
        defer session.deinit();
        _ = try session.feed("{\"checks\":[]}");
        try session.finish();
        try t.expectEqual(case.expected, session.predicateStatus());
    }
}
