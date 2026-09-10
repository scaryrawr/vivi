const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const summary_text_graphemes = 80;
const summary_text_bytes = 240;
const ellipsis = "…";

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
    try std.testing.expectEqual(@as(usize, 81), count);
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
