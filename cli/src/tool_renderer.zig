const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const summary_text_graphemes = 80;
const summary_text_bytes = 240;
const ellipsis = "…";

pub fn renderArguments(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        const literal = try renderLiteral(allocator, text);
        defer allocator.free(literal);
        return std.fmt.allocPrint(allocator, "Unparsed input (invalid JSON):\n{s}", .{literal});
    };
    defer parsed.deinit();
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    try appendArgument(allocator, &result, parsed.value, if (parsed.value == .object) "" else "Value", 0);
    return result.toOwnedSlice(allocator);
}

fn appendArgument(allocator: std.mem.Allocator, result: *std.ArrayList(u8), value: std.json.Value, name: []const u8, depth: usize) error{OutOfMemory}!void {
    if (result.items.len > 0) try result.append(allocator, '\n');
    try result.appendNTimes(allocator, ' ', depth * 2);
    if (name.len > 0) {
        const safe = try renderLiteral(allocator, name);
        defer allocator.free(safe);
        for (safe, 0..) |byte, index| {
            if (byte == '\n') {
                try result.appendSlice(allocator, "\\n");
            } else {
                try result.append(allocator, if (index == 0) std.ascii.toUpper(byte) else byte);
            }
        }
        try result.appendSlice(allocator, ": ");
    }
    switch (value) {
        .object => |object| {
            if (object.count() == 0) try result.appendSlice(allocator, "(empty object)");
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try appendArgument(allocator, result, entry.value_ptr.*, if (entry.key_ptr.*.len == 0) "(empty key)" else entry.key_ptr.*, if (name.len == 0) depth else depth + 1);
            }
        },
        .array => |array| {
            if (array.items.len == 0) try result.appendSlice(allocator, "(empty array)");
            for (array.items, 0..) |item, index| {
                var buffer: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&buffer, "[{d}]", .{index}) catch unreachable;
                try appendArgument(allocator, result, item, label, depth + 1);
            }
        },
        .string => |string| {
            if (string.len == 0) {
                try result.appendSlice(allocator, "(empty string)");
            } else {
                const literal = try renderLiteral(allocator, string);
                defer allocator.free(literal);
                for (literal) |byte| {
                    try result.append(allocator, byte);
                    if (byte == '\n') try result.appendNTimes(allocator, ' ', (depth + 1) * 2);
                }
            }
        },
        .number_string => |number| try result.appendSlice(allocator, number),
        .bool => |boolean| try result.appendSlice(allocator, if (boolean) "true" else "false"),
        .null => try result.appendSlice(allocator, "null"),
        else => unreachable,
    }
}

test "tool argument display decodes builtins without dropping fields" {
    const rendered = try renderArguments(std.testing.allocator,
        \\{"command":"cd \"my dir\"\ngit diff","timeout":120,"path":"a.zig","offset":2,"content":"first\nsecond","edits":[{"old":"a","new":"b"}]}
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Command: cd \"my dir\"\n  git diff\nTimeout: 120\nPath: a.zig\nOffset: 2\nContent: first\n  second\nEdits: \n  [0]: \n    Old: a\n    New: b", rendered);
}

test "tool argument display handles controls nested values and malformed input explicitly" {
    const cases = [_][2][]const u8{
        .{ "{\"x\":\"\\u001b[31m\\t\",\"nested\":{\"flag\":true,\"missing\":null,\"list\":[],\"obj\":{},\"empty\":\"\"}}", "X: \\x1b[31m\\x09\nNested: \n  Flag: true\n  Missing: null\n  List: (empty array)\n  Obj: (empty object)\n  Empty: (empty string)" },
        .{ "{\"broken\":", "Unparsed input (invalid JSON):\n{\"broken\":" },
        .{ "{\"x\":1,\"x\":2}", "Unparsed input (invalid JSON):\n{\"x\":1,\"x\":2}" },
        .{ "{}", "(empty object)" },
        .{ "1e999", "Value: 1e999" },
        .{ "{\"\":\"value\"}", "(empty key): value" },
    };
    for (cases) |case| {
        const rendered = try renderArguments(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(case[1], rendered);
    }
}

fn argumentAllocationLifecycle(allocator: std.mem.Allocator) !void {
    for ([_][]const u8{ "{\"nested\":[{\"content\":\"a\\nb\",\"timeout\":120}]}", "{bad" }) |input| {
        const rendered = try renderArguments(allocator, input);
        allocator.free(rendered);
    }
}

test "tool argument parsing and fallback release all allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, argumentAllocationLifecycle, .{});
}

pub fn renderLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        const codepoint = if (length > 0 and index + length <= text.len)
            std.unicode.utf8Decode(text[index..][0..length]) catch null
        else
            null;
        if (codepoint) |value| {
            if (value == '\n' or (value >= 0x20 and value != 0x7f and
                !(value >= 0x80 and value <= 0x9f) and
                !(value >= 0x202a and value <= 0x202e) and
                !(value >= 0x2066 and value <= 0x2069)))
            {
                try result.appendSlice(allocator, text[index..][0..length]);
                index += length;
                continue;
            }
        }
        var buffer: [4]u8 = undefined;
        const escaped = std.fmt.bufPrint(&buffer, "\\x{x:0>2}", .{byte}) catch unreachable;
        try result.appendSlice(allocator, escaped);
        index += 1;
    }
    return result.toOwnedSlice(allocator);
}

test "tool literal display preserves multiline markdown and escapes unsafe bytes" {
    const rendered = try renderLiteral(std.testing.allocator, "# Heading\n**literal**\t\x1b[31m\r\x00\x7f\xff\xc2\x9b\u{202e}終");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "# Heading\n**literal**\\x09\\x1b[31m\\x0d\\x00\\x7f\\xff\\xc2\\x9b\\xe2\\x80\\xae終",
        rendered,
    );
}

test "tool output keeps JSON literal rather than presenting arguments" {
    const output = "{\"path\":\"a\\nb\",\"ok\":true}";
    const rendered = try renderLiteral(std.testing.allocator, output);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(output, rendered);
}

pub const ToolStatus = enum {
    running,
    succeeded,
    failed,
};

pub fn renderCompact(
    allocator: std.mem.Allocator,
    summary: backend.ToolSummary,
    status: ToolStatus,
) ![]u8 {
    const marker = switch (status) {
        .running => "◌",
        .succeeded => "✓",
        .failed => "✗",
    };

    return switch (summary) {
        .read => |read_summary| renderRead(allocator, marker, read_summary),
        .bash => |bash_summary| renderBash(allocator, marker, bash_summary),
        .edit => |edit_summary| renderEdit(allocator, marker, edit_summary),
        .write => |write_summary| renderWrite(allocator, marker, write_summary),
        .other => |other_summary| renderOther(allocator, marker, other_summary),
    };
}

fn renderRead(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.ReadToolSummary,
) ![]u8 {
    const path = try compactDisplayText(allocator, summary.path);
    defer allocator.free(path);
    if (summary.offset) |offset| {
        if (summary.limit) |limit| {
            return std.fmt.allocPrint(
                allocator,
                "{s} Read {s} lines {d}-{d}",
                .{ marker, path, offset, offset +| (limit -| 1) },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{s} Read {s} from line {d}",
            .{ marker, path, offset },
        );
    }
    if (summary.limit) |limit| {
        return std.fmt.allocPrint(
            allocator,
            "{s} Read {s} first {d} line{s}",
            .{ marker, path, limit, if (limit == 1) "" else "s" },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s} Read {s}",
        .{ marker, path },
    );
}

fn renderBash(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.BashToolSummary,
) ![]u8 {
    const preview = try compactDisplayText(allocator, summary.command);
    defer allocator.free(preview);
    return std.fmt.allocPrint(
        allocator,
        "{s} Run {s}",
        .{ marker, preview },
    );
}

fn renderEdit(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.EditToolSummary,
) ![]u8 {
    const path = try compactDisplayText(allocator, summary.path);
    defer allocator.free(path);
    return std.fmt.allocPrint(
        allocator,
        "{s} Edit {s}, {d} replacement{s}",
        .{
            marker,
            path,
            summary.replacement_count,
            if (summary.replacement_count == 1) "" else "s",
        },
    );
}

fn renderWrite(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.WriteToolSummary,
) ![]u8 {
    const path = try compactDisplayText(allocator, summary.path);
    defer allocator.free(path);
    return std.fmt.allocPrint(
        allocator,
        "{s} Write {s}, {d} byte{s}",
        .{
            marker,
            path,
            summary.byte_count,
            if (summary.byte_count == 1) "" else "s",
        },
    );
}

fn renderOther(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.OtherToolSummary,
) ![]u8 {
    const name = try compactDisplayText(allocator, summary.name);
    defer allocator.free(name);
    return std.fmt.allocPrint(
        allocator,
        "{s} Tool {s}",
        .{ marker, name },
    );
}

fn compactDisplayText(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]u8 {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(allocator);
    const hex = "0123456789abcdef";
    for (text) |byte| {
        switch (byte) {
            '\n' => try compact.appendSlice(allocator, "\\n"),
            '\r' => try compact.appendSlice(allocator, "\\r"),
            '\t' => try compact.appendSlice(allocator, "\\t"),
            0x0b => try compact.appendSlice(allocator, "\\v"),
            0x0c => try compact.appendSlice(allocator, "\\f"),
            else => if (byte < 0x20 or byte == 0x7f) {
                try compact.appendSlice(allocator, "\\x");
                try compact.append(allocator, hex[byte >> 4]);
                try compact.append(allocator, hex[byte & 0x0f]);
            } else {
                try compact.append(allocator, byte);
            },
        }
    }

    var iterator = vaxis.unicode.graphemeIterator(compact.items);
    var count: usize = 0;
    var end = compact.items.len;
    const content_byte_limit = summary_text_bytes - ellipsis.len;
    while (iterator.next()) |grapheme| {
        if (count == summary_text_graphemes or
            grapheme.start + grapheme.len > content_byte_limit)
        {
            end = grapheme.start;
            break;
        }
        count += 1;
    }
    if (end == compact.items.len) return compact.toOwnedSlice(allocator);
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ compact.items[0..end], ellipsis },
    );
}

test "built-in summaries and lifecycle chrome are distinct" {
    const cases = [_]struct {
        summary: backend.ToolSummary,
        expected: []const u8,
    }{
        .{
            .summary = .{ .read = .{
                .path = "src/main.zig",
                .offset = 10,
                .limit = 20,
            } },
            .expected = "◌ Read src/main.zig lines 10-29",
        },
        .{
            .summary = .{ .bash = .{
                .command = "zig\n  build\t test",
            } },
            .expected = "◌ Run zig\\n  build\\t test",
        },
        .{
            .summary = .{ .edit = .{
                .path = "src/main.zig",
                .replacement_count = 2,
            } },
            .expected = "◌ Edit src/main.zig, 2 replacements",
        },
        .{
            .summary = .{ .write = .{
                .path = "notes.txt",
                .byte_count = 1,
            } },
            .expected = "◌ Write notes.txt, 1 byte",
        },
        .{
            .summary = .{ .other = .{ .name = "search" } },
            .expected = "◌ Tool search",
        },
    };

    for (cases) |case| {
        const rendered = try renderCompact(
            std.testing.allocator,
            case.summary,
            .running,
        );
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(case.expected, rendered);
    }
}

test "read ranges saturate after computing their zero-based span" {
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "◌ Read large.txt lines {d}-{d}",
        .{ std.math.maxInt(usize), std.math.maxInt(usize) },
    );
    defer std.testing.allocator.free(expected);
    const rendered = try renderCompact(
        std.testing.allocator,
        .{ .read = .{
            .path = "large.txt",
            .offset = std.math.maxInt(usize),
            .limit = 1,
        } },
        .running,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(expected, rendered);
}

test "bash preview preserves spaces and escapes control whitespace" {
    const preview = try compactDisplayText(
        std.testing.allocator,
        "printf 'a  b'\nrm file\targ",
    );
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings(
        "printf 'a  b'\\nrm file\\targ",
        preview,
    );
}

test "bash preview is grapheme bounded" {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(std.testing.allocator);
    for (0..81) |_| try command.appendSlice(std.testing.allocator, "e\u{301}");
    const preview = try compactDisplayText(std.testing.allocator, command.items);
    defer std.testing.allocator.free(preview);

    try std.testing.expect(std.mem.endsWith(u8, preview, "…"));
    var iterator = vaxis.unicode.graphemeIterator(preview);
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    try std.testing.expectEqual(@min(summary_text_graphemes, (summary_text_bytes - ellipsis.len) / "e\u{301}".len) + 1, count);
}

test "display text is byte bounded at a grapheme boundary" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.append(std.testing.allocator, 'e');
    for (0..256) |_| {
        try text.appendSlice(std.testing.allocator, "\u{301}");
    }

    const compact = try compactDisplayText(
        std.testing.allocator,
        text.items,
    );
    defer std.testing.allocator.free(compact);

    try std.testing.expectEqualStrings(ellipsis, compact);
    try std.testing.expect(compact.len <= summary_text_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(compact));
}

test "all dynamic summary text is escaped and grapheme bounded" {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(std.testing.allocator);
    try path.appendSlice(std.testing.allocator, "line\n");
    for (0..81) |_| try path.appendSlice(std.testing.allocator, "é");

    const rendered = try renderCompact(
        std.testing.allocator,
        .{ .read = .{
            .path = path.items,
            .offset = null,
            .limit = null,
        } },
        .running,
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(
        u8,
        rendered,
        "◌ Read line\\n",
    ));
    try std.testing.expect(std.mem.endsWith(u8, rendered, "…"));
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, '\n') == null);
}

test "lifecycle chrome distinguishes success and failure" {
    const success_text = try renderCompact(
        std.testing.allocator,
        .{ .other = .{ .name = "search" } },
        .succeeded,
    );
    defer std.testing.allocator.free(success_text);
    try std.testing.expectEqualStrings("✓ Tool search", success_text);

    const failure_text = try renderCompact(
        std.testing.allocator,
        .{ .other = .{ .name = "search" } },
        .failed,
    );
    defer std.testing.allocator.free(failure_text);
    try std.testing.expectEqualStrings("✗ Tool search", failure_text);
}
