const std = @import("std");

pub const max_characters: usize = 80;
pub const max_input_bytes: usize = 512;
const suffix = "…";

pub fn canonicalize(
    allocator: std.mem.Allocator,
    input: []const u8,
) !?[]u8 {
    if (input.len == 0 or input.len > max_input_bytes or
        !std.unicode.utf8ValidateSlice(input))
    {
        return null;
    }

    var normalized: [max_characters * 4]u8 = undefined;
    var normalized_len: usize = 0;
    var normalized_count: usize = 0;
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
            pending_space = normalized_count > 0;
            continue;
        }
        if (isControl(codepoint)) continue;
        if (pending_space) {
            normalized_count += 1;
            if (normalized_count <= max_characters) {
                normalized[normalized_len] = ' ';
                normalized_len += 1;
            }
            pending_space = false;
        }
        normalized_count += 1;
        if (normalized_count <= max_characters) {
            @memcpy(
                normalized[normalized_len..][0..length],
                input[index - length .. index],
            );
            normalized_len += length;
        }
    }
    if (normalized_count == 0) return null;

    const retained = normalized[0..normalized_len];
    if (normalized_count <= max_characters) {
        return try allocator.dupe(u8, retained);
    }

    const content_limit = max_characters - 1;
    const hard_end = byteOffsetAfterScalars(retained, content_limit);
    const prefix = retained[0..hard_end];
    const boundary = std.mem.lastIndexOfScalar(u8, prefix, ' ');
    const content_end = boundary orelse hard_end;
    var result = try std.ArrayList(u8).initCapacity(
        allocator,
        content_end + suffix.len,
    );
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, retained[0..content_end]);
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
        (codepoint >= 0x007f and codepoint <= 0x009f) or
        codepoint == 0x061c or
        (codepoint >= 0x200e and codepoint <= 0x200f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
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

test "canonical title bounds normalization and allocation at legacy input limit" {
    const ascii = [_]u8{'a'} ** max_input_bytes;
    var ascii_memory: [max_characters * 4]u8 = undefined;
    var ascii_allocator = std.heap.FixedBufferAllocator.init(&ascii_memory);
    const ascii_title = (try canonicalize(
        ascii_allocator.allocator(),
        &ascii,
    )).?;
    try std.testing.expectEqual(
        @as(usize, max_characters),
        countScalars(ascii_title),
    );
    try std.testing.expect(std.mem.endsWith(u8, ascii_title, suffix));

    const multibyte = "é" ** (max_input_bytes / 2);
    var multibyte_memory: [max_characters * 4]u8 = undefined;
    var multibyte_allocator = std.heap.FixedBufferAllocator.init(
        &multibyte_memory,
    );
    const multibyte_title = (try canonicalize(
        multibyte_allocator.allocator(),
        multibyte,
    )).?;
    try std.testing.expectEqual(
        @as(usize, max_characters),
        countScalars(multibyte_title),
    );
    try std.testing.expect(std.mem.endsWith(u8, multibyte_title, suffix));

    const whitespace = ("word " ** 102) ++ "wo";
    try std.testing.expectEqual(@as(usize, max_input_bytes), whitespace.len);
    var whitespace_memory: [max_characters * 4]u8 = undefined;
    var whitespace_allocator = std.heap.FixedBufferAllocator.init(
        &whitespace_memory,
    );
    const whitespace_title = (try canonicalize(
        whitespace_allocator.allocator(),
        whitespace,
    )).?;
    try std.testing.expectEqualStrings(
        ("word " ** 14) ++ "word…",
        whitespace_title,
    );
}

test "canonical title rejects input above legacy byte limit before allocation" {
    const ascii = [_]u8{'a'} ** (max_input_bytes + 1);
    try std.testing.expectEqual(
        null,
        try canonicalize(std.testing.failing_allocator, &ascii),
    );

    const multibyte = "é" ** ((max_input_bytes / 2) + 1);
    try std.testing.expectEqual(
        null,
        try canonicalize(std.testing.failing_allocator, multibyte),
    );

    const whitespace = [_]u8{' '} ** (max_input_bytes + 1);
    try std.testing.expectEqual(
        null,
        try canonicalize(std.testing.failing_allocator, &whitespace),
    );
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
    try std.testing.expect(!isCanonical("arabic\u{061c}mark"));
    try std.testing.expect(!isCanonical("left\u{200e}mark"));
    try std.testing.expect(!isCanonical("right\u{200f}mark"));
    try std.testing.expect(!isCanonical("right\u{202e}left"));
    try std.testing.expect(!isCanonical("isolate\u{2066}text\u{2069}"));
    const oversized = [_]u8{'x'} ** (max_characters + 1);
    try std.testing.expect(!isCanonical(&oversized));
}

test "canonical title removes bidirectional formatting controls" {
    const title = (try canonicalize(
        std.testing.allocator,
        "safe\u{061c}\u{200e}\u{200f}" ++
            "\u{202a}\u{202b}\u{202c}\u{202d}\u{202e}" ++
            "\u{2066}\u{2067}\u{2068}\u{2069} title",
    )).?;
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("safe title", title);
    try std.testing.expect(isCanonical(title));
}
