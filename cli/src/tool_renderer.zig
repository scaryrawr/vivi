const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const bash_preview_graphemes = 80;

pub fn renderCompact(
    allocator: std.mem.Allocator,
    activity: *const backend.ToolActivity,
) ![]u8 {
    const marker = switch (activity.lifecycle) {
        .running => "◌",
        .finished => |result| switch (result) {
            .succeeded => "✓",
            .failed => "✗",
        },
    };

    return switch (activity.invocation.summary) {
        .read => |summary| renderRead(allocator, marker, summary),
        .bash => |summary| renderBash(allocator, marker, summary),
        .edit => |summary| std.fmt.allocPrint(
            allocator,
            "{s} Edit {s}, {d} replacement{s}",
            .{
                marker,
                summary.path,
                summary.replacement_count,
                if (summary.replacement_count == 1) "" else "s",
            },
        ),
        .write => |summary| std.fmt.allocPrint(
            allocator,
            "{s} Write {s}, {d} bytes",
            .{ marker, summary.path, summary.byte_count },
        ),
        .other => |summary| std.fmt.allocPrint(
            allocator,
            "{s} Tool {s}",
            .{ marker, summary.name },
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
                .{ marker, summary.path, offset, offset +| limit -| 1 },
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
            "{s} Read {s} first {d} lines",
            .{ marker, summary.path, limit },
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
    var in_whitespace = true;
    for (command) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            in_whitespace = true;
            continue;
        }
        if (in_whitespace and compact.items.len > 0) {
            try compact.append(allocator, ' ');
        }
        try compact.append(allocator, byte);
        in_whitespace = false;
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

fn testActivity(
    allocator: std.mem.Allocator,
    summary: backend.ToolSummary,
    lifecycle: backend.ToolLifecycle,
) !backend.ToolActivity {
    var started = try backend.ToolStarted.init(
        allocator,
        "call",
        "{}",
        summary,
    );
    defer started.deinit();
    var activity = try backend.ToolActivity.init(allocator, &started);
    activity.lifecycle = lifecycle;
    return activity;
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
            .expected = "◌ Run zig build test",
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
                .byte_count = 5,
            } },
            .expected = "◌ Write notes.txt, 5 bytes",
        },
        .{
            .summary = .{ .other = .{ .name = "search" } },
            .expected = "◌ Tool search",
        },
    };

    for (cases) |case| {
        var activity = try testActivity(
            std.testing.allocator,
            case.summary,
            .running,
        );
        defer activity.deinit();
        const rendered = try renderCompact(std.testing.allocator, &activity);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(case.expected, rendered);
    }
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
    var success = try testActivity(
        std.testing.allocator,
        .{ .other = .{ .name = "search" } },
        .running,
    );
    defer success.deinit();
    var success_update = try backend.ToolFinished.init(
        std.testing.allocator,
        "call",
        .{ .succeeded = "ok" },
    );
    defer success_update.deinit();
    try success.finish(&success_update);
    const success_text = try renderCompact(std.testing.allocator, &success);
    defer std.testing.allocator.free(success_text);
    try std.testing.expectEqualStrings("✓ Tool search", success_text);

    var failure = try testActivity(
        std.testing.allocator,
        .{ .other = .{ .name = "search" } },
        .running,
    );
    defer failure.deinit();
    var failure_update = try backend.ToolFinished.init(
        std.testing.allocator,
        "call",
        .{ .failed = "no" },
    );
    defer failure_update.deinit();
    try failure.finish(&failure_update);
    const failure_text = try renderCompact(std.testing.allocator, &failure);
    defer std.testing.allocator.free(failure_text);
    try std.testing.expectEqualStrings("✗ Tool search", failure_text);
}
