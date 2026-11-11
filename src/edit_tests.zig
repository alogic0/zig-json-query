const std = @import("std");
const query = @import("root.zig");
const t = std.testing;

fn expectOutput(source: []const u8, input: []const u8, expected: []const u8, options: query.StreamOptions) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    var stream = try program.start(t.allocator, &output.writer, &diagnostic, options);
    defer stream.deinit();
    _ = try stream.feed(input);
    try stream.finish();
    try t.expectEqualStrings(expected, output.written());
}

fn expectFailure(source: []const u8, input: []const u8, message: []const u8, path: []const u8) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(t.allocator, source, &diagnostic);
    defer program.deinit();
    var output = std.Io.Writer.Allocating.init(t.allocator);
    defer output.deinit();
    try t.expectError(error.EvaluationFailed, program.run(t.allocator, input, &output.writer, &diagnostic));
    try t.expect(std.mem.indexOf(u8, diagnostic.message, message) != null);
    try t.expectEqualStrings(path, diagnostic.path.bytes[0..diagnostic.path.len]);
    try t.expectEqualStrings("", output.written());
}

test "edits filter selected arrays while preserving arbitrary outer fields and insertion order" {
    try expectOutput("update(., .groups, filter(., .id != \"remove\"))", "{\"meta\":{\"unknown\":true},\"groups\":[{\"id\":\"remove\"},{\"id\":\"keep\",\"extra\":null}],\"id\":9007199254740993}", "{\"meta\":{\"unknown\":true},\"groups\":[{\"id\":\"keep\",\"extra\":null}],\"id\":9007199254740993}\n", .{});
    try expectOutput("update(., .groups, filter(., false))", "{\"groups\":[],\"other\":0}", "{\"groups\":[],\"other\":0}\n", .{});
}

test "edits copy ancestors without mutating siblings or subsequent access to the original" {
    try expectOutput("[update(., .rows[-1][\"a-b\"], .+1), .]", "{\"rows\":[{\"a-b\":1},{\"a-b\":2}],\"other\":1.00}", "[{\"rows\":[{\"a-b\":1},{\"a-b\":3}],\"other\":1.00},{\"rows\":[{\"a-b\":1},{\"a-b\":2}],\"other\":1.00}]\n", .{});
    try expectOutput("{edited:update(.,.outer,update(.,.value, .+2)),name}", "{\"name\":\"outer\",\"outer\":{\"value\":1,\"unknown\":false}}", "{\"edited\":{\"name\":\"outer\",\"outer\":{\"value\":3,\"unknown\":false}},\"name\":\"outer\"}\n", .{});
    try expectOutput("update(.,.[0],null)[0] == null", "[false]", "true\n", .{});
}

test "edits delete fields null members and signed array indexes" {
    try expectOutput("[del(.,.a),.]", "{\"a\":null,\"b\":1}", "[{\"b\":1},{\"a\":null,\"b\":1}]\n", .{});
    try expectOutput("del(.,.outer[1].drop)", "{\"outer\":[{}, {\"drop\":0,\"keep\":true}]}", "{\"outer\":[{},{\"keep\":true}]}\n", .{});
    try expectOutput("[del(.,.[-1]),del(.,.[-0]),del(.,.[1])]", "[0,1,2]", "[[0,1],[1,2],[0,2]]\n", .{});
    try expectOutput("del(.,.[0])", "[null]", "[]\n", .{});
}

test "edits track nested selected scopes and restore the caller path" {
    try expectFailure("map(.groups,update(.,.rows, map(.,.missing)))", "{\"groups\":[{\"rows\":[{}]}]}", "absent", "$[\"groups\"][0][\"rows\"][0][\"missing\"]");
    try expectFailure("update(.,.rows[-1],.missing)", "{\"rows\":[{}]}", "absent", "$[\"rows\"][-1][\"missing\"]");
    try expectFailure("{changed:update(.,.x,1),missing}", "{\"x\":0}", "absent", "$[\"missing\"]");
    try expectFailure("update({x:0},.x,.missing)", "null", "expects an object", "");
}

test "edits reject missing targets wrong containers and missing replacement values" {
    try expectFailure("del(.,.absent)", "{}", "absent", "$[\"absent\"]");
    try expectFailure("update(.,.x.y,0)", "{\"x\":null}", "expects an object", "$[\"x\"][\"y\"]");
    try expectFailure("del(.,.x[0])", "{\"x\":{}}", "expects an array", "$[\"x\"][0]");
    try expectFailure("del(.,.[-2])", "[1]", "absent", "$[-2]");
    try expectFailure("update(.,.x,.missing?)", "{\"x\":{}}", "missing value", "$[\"x\"][\"missing\"]");
}

test "edits reject dynamic optional sliced root and malformed paths" {
    for ([_][]const u8{
        "update(.,.x)",     "del(.)",      "del(.,.)",      "update(.,.,1)", "del(.,.x?)", "del(.,.[1:2])",
        "del(.,length(.))", "del(.,.x+1)", "update(.,.x,)", "del(.,.x,1)",   "del(.,[0])", "update(.,.x,. | each)",
    }) |source| {
        var diagnostic: query.Diagnostic = .{};
        try t.expectError(error.InvalidQuery, query.Program.compile(t.allocator, source, &diagnostic));
    }
}

test "edits sorted-key output is recursive stable and preserves exact number tokens and raw strings" {
    try expectOutput(".", "{\"é\":0,\"z\":[{\"y\":1.00,\"a\":9007199254740993}],\"A\":-0}", "{\"A\":-0,\"z\":[{\"a\":9007199254740993,\"y\":1.00}],\"é\":0}\n", .{ .sort_keys = true });
    try expectOutput(".", "\"{\\\"z\\\":1,\\\"a\\\":2}\"", "{\"z\":1,\"a\":2}\n", .{ .sort_keys = true, .raw_output = true });
    try expectOutput(".", "{\"z\":{},\"a\":[]}", "{\"a\":[],\"z\":{}}\n", .{ .sort_keys = true, .max_collect_bytes = 0 });
    try expectOutput("tojson(.)", "{\"z\":1,\"a\":2}", "{\"z\":1,\"a\":2}\n", .{ .sort_keys = true, .raw_output = true });
}

test "edits generated filtered configurations match an independent index model" {
    for (0..32) |length| {
        var input = std.Io.Writer.Allocating.init(t.allocator);
        defer input.deinit();
        var expected = std.Io.Writer.Allocating.init(t.allocator);
        defer expected.deinit();
        try input.writer.writeAll("{\"unknown\":9007199254740993,\"items\":[");
        try expected.writer.writeAll("{\"unknown\":9007199254740993,\"items\":[");
        for (0..length) |index| {
            if (index != 0) try input.writer.writeByte(',');
            try input.writer.print("{{\"id\":{d}}}", .{index});
            if (index & 1 == 0) {
                if (index != 0) try expected.writer.writeByte(',');
                try expected.writer.print("{{\"id\":{d}}}", .{index});
            }
        }
        try input.writer.writeAll("]}");
        try expected.writer.writeAll("]}\n");
        try expectOutput("update(.,.items,filter(.,.id % 2 == 0))", input.written(), expected.written(), .{});
    }
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var diagnostic: query.Diagnostic = .{};
    var program = try query.Program.compile(allocator, "{updated:update(.,.items[-1].n,.+1),deleted:del(.,.meta.debug)} | collect", &diagnostic);
    defer program.deinit();
    var bytes: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var stream = try program.start(allocator, &output, &diagnostic, .{ .sort_keys = true });
    defer stream.deinit();
    var input = "{\"meta\":{\"x\":0,\"debug\":true},\"items\":[{\"n\":1},{\"n\":2}]}".*;
    _ = try stream.feed(&input);
    @memset(&input, 'x');
    try stream.finish();
    try t.expectEqualStrings("[{\"deleted\":{\"items\":[{\"n\":1},{\"n\":2}],\"meta\":{\"x\":0}},\"updated\":{\"items\":[{\"n\":1},{\"n\":3}],\"meta\":{\"debug\":true,\"x\":0}}}]\n", output.buffered());
}

test "edits allocation failures release copied ancestors sorted objects and retained children" {
    var baseline = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try allocationScenario(baseline.allocator());
    try t.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index, .resize_fail_index = 0 });
        try t.expectError(error.OutOfMemory, allocationScenario(failing.allocator()));
        try t.expect(failing.has_induced_failure);
        try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
