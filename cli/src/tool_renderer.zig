const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const bash_preview_graphemes = 80;

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
        .edit => |edit_summary| std.fmt.allocPrint(
            allocator,
            "{s} Edit {s}, {d} replacement{s}",
            .{
                marker,
                edit_summary.path,
                edit_summary.replacement_count,
                if (edit_summary.replacement_count == 1) "" else "s",
            },
        ),
        .write => |write_summary| std.fmt.allocPrint(
            allocator,
            "{s} Write {s}, {d} byte{s}",
            .{
                marker,
                write_summary.path,
                write_summary.byte_count,
                if (write_summary.byte_count == 1) "" else "s",
            },
        ),
        .other => |other_summary| std.fmt.allocPrint(
            allocator,
            "{s} Tool {s}",
            .{ marker, other_summary.name },
        ),
    };
}

fn renderRead(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.ReadToolSummary,
) ![]u8 {
    if (summary.offset) |offset| {
        if (summary.limit) |limit| {
            return std.fmt.allocPrint(
                allocator,
                "{s} Read {s} lines {d}-{d}",
                .{ marker, summary.path, offset, offset +| (limit -| 1) },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{s} Read {s} from line {d}",
            .{ marker, summary.path, offset },
        );
    }
    if (summary.limit) |limit| {
        return std.fmt.allocPrint(
            allocator,
            "{s} Read {s} first {d} line{s}",
            .{ marker, summary.path, limit, if (limit == 1) "" else "s" },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s} Read {s}",
        .{ marker, summary.path },
    );
}

fn renderBash(
    allocator: std.mem.Allocator,
    marker: []const u8,
    summary: backend.BashToolSummary,
) ![]u8 {
    const preview = try compactBashPreview(allocator, summary.command);
    defer allocator.free(preview);
    return std.fmt.allocPrint(
        allocator,
        "{s} Run {s}",
        .{ marker, preview },
    );
}

fn compactBashPreview(
    allocator: std.mem.Allocator,
    command: []const u8,
) ![]u8 {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(allocator);
    for (command) |byte| {
        switch (byte) {
            '\n' => try compact.appendSlice(allocator, "\\n"),
            '\r' => try compact.appendSlice(allocator, "\\r"),
            '\t' => try compact.appendSlice(allocator, "\\t"),
            0x0b => try compact.appendSlice(allocator, "\\v"),
            0x0c => try compact.appendSlice(allocator, "\\f"),
            else => try compact.append(allocator, byte),
        }
    }

    var iterator = vaxis.unicode.graphemeIterator(compact.items);
    var count: usize = 0;
    var end = compact.items.len;
    while (iterator.next()) |grapheme| {
        if (count == bash_preview_graphemes) {
            end = grapheme.start;
            break;
        }
        count += 1;
    }
    if (end == compact.items.len) return compact.toOwnedSlice(allocator);
    return std.fmt.allocPrint(allocator, "{s}…", .{compact.items[0..end]});
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
    const preview = try compactBashPreview(
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
    const preview = try compactBashPreview(std.testing.allocator, command.items);
    defer std.testing.allocator.free(preview);

    try std.testing.expect(std.mem.endsWith(u8, preview, "…"));
    var iterator = vaxis.unicode.graphemeIterator(preview);
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 81), count);
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
