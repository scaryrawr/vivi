const std = @import("std");

pub const max_characters: usize = 80;
const suffix = "…";

pub fn canonicalize(
    allocator: std.mem.Allocator,
    input: []const u8,
) !?[]u8 {
    if (input.len == 0 or !std.unicode.utf8ValidateSlice(input)) {
        return null;
    }

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);
    var pending_space = false;
    var index: usize = 0;
    while (index < input.len) {
        const length = std.unicode.utf8ByteSequenceLength(input[index]) catch
            return null;
        const codepoint = std.unicode.utf8Decode(
            input[index..][0..length],
        ) catch return null;
        index += length;

        if (isWhitespace(codepoint)) {
            pending_space = normalized.items.len > 0;
            continue;
        }
        if (isControl(codepoint)) continue;
        if (pending_space) {
            try normalized.append(allocator, ' ');
            pending_space = false;
        }
        try normalized.appendSlice(allocator, input[index - length .. index]);
    }
    if (normalized.items.len == 0) return null;

    const count = countScalars(normalized.items);
    if (count <= max_characters) {
        return try normalized.toOwnedSlice(allocator);
    }

    const content_limit = max_characters - 1;
    const hard_end = byteOffsetAfterScalars(normalized.items, content_limit);
    const prefix = normalized.items[0..hard_end];
    const boundary = std.mem.lastIndexOfScalar(u8, prefix, ' ');
    const content_end = boundary orelse hard_end;
    var result = try std.ArrayList(u8).initCapacity(
        allocator,
        content_end + suffix.len,
    );
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, normalized.items[0..content_end]);
    try result.appendSlice(allocator, suffix);
    return try result.toOwnedSlice(allocator);
}

pub fn isCanonical(value: []const u8) bool {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return false;

    var count: usize = 0;
    var previous_space = false;
    var index: usize = 0;
    while (index < value.len) {
        const length = std.unicode.utf8ByteSequenceLength(value[index]) catch
            return false;
        const codepoint = std.unicode.utf8Decode(
            value[index..][0..length],
        ) catch return false;
        index += length;
        count += 1;
        if (count > max_characters or isControl(codepoint)) return false;
        if (isWhitespace(codepoint)) {
            if (codepoint != ' ' or count == 1 or previous_space) return false;
            previous_space = true;
        } else {
            previous_space = false;
        }
    }
    return !previous_space;
}

fn countScalars(value: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (count += 1) {
        const length = std.unicode.utf8ByteSequenceLength(value[index]) catch
            unreachable;
        index += length;
    }
    return count;
}

fn byteOffsetAfterScalars(value: []const u8, scalar_count: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < value.len and count < scalar_count) : (count += 1) {
        const length = std.unicode.utf8ByteSequenceLength(value[index]) catch
            unreachable;
        index += length;
    }
    return index;
}

fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d,
        0x0020,
        0x0085,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn isControl(codepoint: u21) bool {
    return codepoint <= 0x001f or
        (codepoint >= 0x007f and codepoint <= 0x009f);
}

test "canonical title normalizes whitespace and controls" {
    const title = (try canonicalize(
        std.testing.allocator,
        " \tFix\n\x01  session\u{00a0}title\r\n ",
    )).?;
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Fix session title", title);
    try std.testing.expect(isCanonical(title));
}

test "canonical title preserves exact limit" {
    const input = [_]u8{'a'} ** max_characters;
    const title = (try canonicalize(std.testing.allocator, &input)).?;
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualSlices(u8, &input, title);
}

test "canonical title truncates at word boundary with counted suffix" {
    const input = "A readable title " ++ ([_]u8{'x'} ** 80);
    const title = (try canonicalize(std.testing.allocator, input)).?;
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("A readable title…", title);
    try std.testing.expect(countScalars(title) <= max_characters);
}

test "canonical title hard truncation preserves multibyte scalars" {
    const input = "é" ** 81;
    const title = (try canonicalize(std.testing.allocator, input)).?;
    defer std.testing.allocator.free(title);
    try std.testing.expectEqual(@as(usize, max_characters), countScalars(title));
    try std.testing.expect(std.mem.endsWith(u8, title, suffix));
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));
}

test "canonical title rejects invalid and empty results" {
    try std.testing.expectEqual(null, try canonicalize(
        std.testing.allocator,
        &.{ 0xff, 0xfe },
    ));
    try std.testing.expectEqual(null, try canonicalize(
        std.testing.allocator,
        "\x01\x7f",
    ));
}

test "canonical title validation is strict" {
    try std.testing.expect(isCanonical("A canonical title"));
    try std.testing.expect(!isCanonical(" padded"));
    try std.testing.expect(!isCanonical("two  spaces"));
    try std.testing.expect(!isCanonical("line\nbreak"));
    try std.testing.expect(!isCanonical("unicode\u{00a0}space"));
    const oversized = [_]u8{'x'} ** (max_characters + 1);
    try std.testing.expect(!isCanonical(&oversized));
}
