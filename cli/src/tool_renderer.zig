const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const summary_text_graphemes = 80;
const summary_text_bytes = 240;
const max_terminal_sequence_bytes = 4096;
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
    return renderSafeText(allocator, text, false, false);
}

pub fn renderOutput(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return renderSafeText(allocator, text, false, true);
}

pub fn renderMarkdown(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return renderSafeText(allocator, text, true, true);
}

fn renderSafeText(
    allocator: std.mem.Allocator,
    text: []const u8,
    preserve_markdown_whitespace: bool,
    strip_terminal_sequences: bool,
) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (strip_terminal_sequences) {
            if (terminalSequence(text[index..])) |sequence| {
                switch (sequence) {
                    .complete => |length| index += length,
                    .incomplete => |length| {
                        const end = index + length;
                        while (index < end) {
                            try appendSafeUnit(
                                allocator,
                                &result,
                                text[0..end],
                                &index,
                                preserve_markdown_whitespace,
                            );
                        }
                    },
                }
                continue;
            }
        }
        try appendSafeUnit(
            allocator,
            &result,
            text,
            &index,
            preserve_markdown_whitespace,
        );
    }
    return result.toOwnedSlice(allocator);
}

fn appendSafeUnit(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    text: []const u8,
    index: *usize,
    preserve_markdown_whitespace: bool,
) !void {
    const byte = text[index.*];
    if (preserve_markdown_whitespace and byte == '\r') {
        try result.append(allocator, '\n');
        index.* += if (index.* + 1 < text.len and text[index.* + 1] == '\n') 2 else 1;
        return;
    }
    const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
    const codepoint = if (length > 0 and index.* + length <= text.len)
        std.unicode.utf8Decode(text[index.*..][0..length]) catch null
    else
        null;
    if (codepoint) |value| {
        if (value == '\n' or
            (preserve_markdown_whitespace and value == '\t') or
            (value >= 0x20 and value != 0x7f and
                !(value >= 0x80 and value <= 0x9f) and
                !(value >= 0x202a and value <= 0x202e) and
                !(value >= 0x2066 and value <= 0x2069)))
        {
            try result.appendSlice(allocator, text[index.*..][0..length]);
            index.* += length;
            return;
        }
    }
    var buffer: [4]u8 = undefined;
    const escaped = std.fmt.bufPrint(&buffer, "\\x{x:0>2}", .{byte}) catch unreachable;
    try result.appendSlice(allocator, escaped);
    index.* += 1;
}

const TerminalSequence = union(enum) {
    complete: usize,
    incomplete: usize,
};

fn terminalSequence(text: []const u8) ?TerminalSequence {
    if (text.len == 0) return null;
    return switch (text[0]) {
        0x1b => if (text.len < 2)
            .{ .incomplete = 1 }
        else switch (text[1]) {
            '[' => csiSequence(text, 2),
            ']' => stringSequence(text, 2, true),
            'P', 'X', '^', '_' => stringSequence(text, 2, false),
            else => escapeSequence(text),
        },
        0x9b => csiSequence(text, 1),
        0x9d => stringSequence(text, 1, true),
        0x90, 0x98, 0x9e, 0x9f => stringSequence(text, 1, false),
        0x9c => .{ .complete = 1 },
        else => null,
    };
}

fn csiSequence(text: []const u8, introducer_length: usize) TerminalSequence {
    var index = introducer_length;
    const limit = @min(text.len, max_terminal_sequence_bytes);
    while (index < limit and text[index] >= 0x30 and text[index] <= 0x3f) : (index += 1) {}
    while (index < limit and text[index] >= 0x20 and text[index] <= 0x2f) : (index += 1) {}
    if (index < limit and text[index] >= 0x40 and text[index] <= 0x7e)
        return .{ .complete = index + 1 };
    return .{ .incomplete = @max(index, introducer_length) };
}

fn stringSequence(
    text: []const u8,
    introducer_length: usize,
    bell_terminated: bool,
) TerminalSequence {
    var index = introducer_length;
    const limit = @min(text.len, max_terminal_sequence_bytes);
    while (index < limit) {
        if (bell_terminated and text[index] == 0x07)
            return .{ .complete = index + 1 };
        if (text[index] == 0x9c)
            return .{ .complete = index + 1 };
        if (text[index] == 0x18 or text[index] == 0x1a)
            return .{ .incomplete = index + 1 };
        if (text[index] == 0x1b) {
            if (index + 1 < limit and text[index + 1] == '\\')
                return .{ .complete = index + 2 };
            return .{ .incomplete = index };
        }
        const utf8_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 0;
        if (utf8_length > 1 and index + utf8_length <= limit) {
            if (std.unicode.utf8Decode(text[index..][0..utf8_length])) |_| {
                index += utf8_length;
                continue;
            } else |_| {}
        }
        index += 1;
    }
    return .{ .incomplete = limit };
}

fn escapeSequence(text: []const u8) TerminalSequence {
    var index: usize = 1;
    const limit = @min(text.len, max_terminal_sequence_bytes);
    while (index < limit and text[index] >= 0x20 and text[index] <= 0x2f) : (index += 1) {}
    if (index < limit and text[index] >= 0x30 and text[index] <= 0x7e)
        return .{ .complete = index + 1 };
    return .{ .incomplete = index };
}

test "Markdown display preserves structural whitespace and escapes controls" {
    const rendered = try renderMarkdown(
        std.testing.allocator,
        "# Heading\r\n\r\n\tcode\r- item\tcontinued\x1b[31m",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "# Heading\n\n\tcode\n- item\tcontinued",
        rendered,
    );
}

test "tool literal display preserves multiline markdown and escapes unsafe bytes" {
    const rendered = try renderLiteral(std.testing.allocator, "# Heading\n**literal**\t\x1b[31m\r\x00\x7f\xff\xc2\x9b\u{202e}終");
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "# Heading\n**literal**\\x09\\x1b[31m\\x0d\\x00\\x7f\\xff\\xc2\\x9b\\xe2\\x80\\xae終",
        rendered,
    );
}

test "tool output strips terminal sequences without hiding malformed controls" {
    const rendered = try renderOutput(
        std.testing.allocator,
        "\x1b[1;38mname\x1b[m \x1b[32mv8.0.1\x1b[0m \x1b]8;;https://example.test\x07link\x1b]8;;\x1b\\ \x9b31mred\x9b0m \x9dtitle\x9c \x90data\x9c \x1b[31 \x1bPbad\x07",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("name v8.0.1 link red   \\x1b[31 \\x1bPbad\\x07", rendered);
}

test "malformed terminal strings are escaped without overlapping scans" {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..16 * 1024) |_| try input.appendSlice(std.testing.allocator, "\x1b]");

    const rendered = try renderOutput(std.testing.allocator, input.items);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqual(5 * 16 * 1024, rendered.len);
}

test "cancelled terminal strings do not hide subsequent output" {
    const rendered = try renderOutput(
        std.testing.allocator,
        "\x1b]bad\x18visible\x07 \x90bad\x1anext\x9c \x1b]bad\x1b[31mred\x1b[0m",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "\\x1b]bad\\x18visible\\x07 \\x90bad\\x1anext \\x1b]badred",
        rendered,
    );
}

test "UTF-8 continuation bytes do not terminate control strings" {
    const rendered = try renderOutput(
        std.testing.allocator,
        "\x1b]title=Ü hidden\x07visible",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("visible", rendered);
}

test "tool output keeps JSON literal rather than presenting arguments" {
    const output = "{\"path\":\"a\\nb\",\"ok\":true}";
    const rendered = try renderOutput(std.testing.allocator, output);
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
    return switch (summary) {
        .run => |value| renderBashCommand(
            allocator,
            marker,
            "Run",
            value.command,
        ),
        .start => |value| renderBashCommand(
            allocator,
            marker,
            "Start Bash",
            value.command,
        ),
        .list => std.fmt.allocPrint(
            allocator,
            "{s} List Bash sessions",
            .{marker},
        ),
        .read => |value| renderBashSession(
            allocator,
            marker,
            "Read Bash",
            value.shell_id,
        ),
        .write => |value| renderBashSession(
            allocator,
            marker,
            "Write Bash",
            value.shell_id,
        ),
        .stop => |value| renderBashSession(
            allocator,
            marker,
            "Stop Bash",
            value.shell_id,
        ),
    };
}

fn renderBashCommand(
    allocator: std.mem.Allocator,
    marker: []const u8,
    action: []const u8,
    command: []const u8,
) ![]u8 {
    const preview = try compactDisplayText(allocator, command);
    defer allocator.free(preview);
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s}",
        .{ marker, action, preview },
    );
}

fn renderBashSession(
    allocator: std.mem.Allocator,
    marker: []const u8,
    action: []const u8,
    shell_id: []const u8,
) ![]u8 {
    const id = try compactDisplayText(allocator, shell_id);
    defer allocator.free(id);
    return std.fmt.allocPrint(
        allocator,
        "{s} {s} {s}",
        .{ marker, action, id },
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
            .summary = .{ .bash = .{ .run = .{
                .command = "zig\n  build\t test",
            } } },
            .expected = "◌ Run zig\\n  build\\t test",
        },
        .{
            .summary = .{ .bash = .{ .start = .{
                .command = "python3 -q",
            } } },
            .expected = "◌ Start Bash python3 -q",
        },
        .{
            .summary = .{ .bash = .{ .read = .{
                .shell_id = "bash_0123456789abcdef0123456789abcdef",
            } } },
            .expected = "◌ Read Bash bash_0123456789abcdef0123456789abcdef",
        },
        .{
            .summary = .{ .bash = .list },
            .expected = "◌ List Bash sessions",
        },
        .{
            .summary = .{ .bash = .{ .write = .{
                .shell_id = "bash_0123456789abcdef0123456789abcdef",
            } } },
            .expected = "◌ Write Bash bash_0123456789abcdef0123456789abcdef",
        },
        .{
            .summary = .{ .bash = .{ .stop = .{
                .shell_id = "bash_0123456789abcdef0123456789abcdef",
            } } },
            .expected = "◌ Stop Bash bash_0123456789abcdef0123456789abcdef",
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
