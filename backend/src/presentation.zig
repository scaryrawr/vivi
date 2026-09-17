const std = @import("std");

const max_terminal_sequence_bytes = 4096;

pub fn renderLiteral(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return renderSafeText(allocator, text, false, false);
}

pub fn renderOutput(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return renderSafeText(allocator, text, false, true);
}

pub fn renderSource(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return renderSafeText(allocator, text, true, true);
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
    if (index < limit and text[index] >= 0x40 and text[index] <= 0x7e) {
        return .{ .complete = index + 1 };
    }
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
        if (bell_terminated and text[index] == 0x07) return .{ .complete = index + 1 };
        if (text[index] == 0x9c) return .{ .complete = index + 1 };
        if (text[index] == 0x18 or text[index] == 0x1a) {
            return .{ .incomplete = index + 1 };
        }
        if (text[index] == 0x1b) {
            if (index + 1 < limit and text[index + 1] == '\\') {
                return .{ .complete = index + 2 };
            }
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
    if (index < limit and text[index] >= 0x30 and text[index] <= 0x7e) {
        return .{ .complete = index + 1 };
    }
    return .{ .incomplete = index };
}

test "tool output strips terminal sequences and preserves Markdown layout" {
    const rendered = try renderMarkdown(
        std.testing.allocator,
        "# Heading\r\n\r\n\x1b[32m- item\x1b[0m\n",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("# Heading\n\n- item\n", rendered);
}
