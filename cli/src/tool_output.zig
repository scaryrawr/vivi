const std = @import("std");
const backend = @import("vivi_backend");
const highlight = @import("highlight.zig");
const tool_renderer = @import("tool_renderer.zig");

pub const Outcome = enum {
    succeeded,
    failed,
    image,
};

pub const OutputPlan = union(enum) {
    literal,
    markdown,
    syntax: highlight.Language,
    syntax_fragment: highlight.Language,

    pub fn fromInvocation(
        allocator: std.mem.Allocator,
        summary: backend.ToolSummary,
    ) !OutputPlan {
        return switch (summary) {
            .read => |read| planForPath(
                read.path,
                read.offset == null and read.limit == null,
            ),
            .bash => |bash| switch (bash) {
                .run => |run| fromCommand(allocator, run.command),
                .start, .list, .read, .write, .stop => .literal,
            },
            .edit, .write, .other => .literal,
        };
    }

    pub fn fromCommand(
        allocator: std.mem.Allocator,
        command: []const u8,
    ) !OutputPlan {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const words = parseSimpleCommand(
            arena_state.allocator(),
            command,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedCommand => return .literal,
        };
        if (words.len == 0) return .literal;
        for (producers) |producer| {
            if (std.mem.eql(u8, words[0], producer.executable)) {
                return producer.infer(words) orelse .literal;
            }
        }
        return .literal;
    }

    pub fn render(
        self: OutputPlan,
        allocator: std.mem.Allocator,
        outcome: Outcome,
        raw: []const u8,
    ) ![]u8 {
        if (outcome != .succeeded) {
            return tool_renderer.renderOutput(allocator, raw);
        }
        return switch (self) {
            .markdown => tool_renderer.renderMarkdown(allocator, raw),
            .syntax, .syntax_fragment => tool_renderer.renderSource(
                allocator,
                raw,
            ),
            .literal => tool_renderer.renderOutput(allocator, raw),
        };
    }

    pub fn spans(
        self: OutputPlan,
        allocator: std.mem.Allocator,
        outcome: Outcome,
        display: []const u8,
    ) ![]highlight.Span {
        if (outcome != .succeeded) {
            return allocator.alloc(highlight.Span, 0);
        }
        return switch (self) {
            .syntax => |language| highlight.completeSpans(
                allocator,
                language,
                display,
            ),
            .syntax_fragment => |language| highlight.spans(
                allocator,
                language,
                display,
            ),
            .literal, .markdown => allocator.alloc(highlight.Span, 0),
        };
    }
};

const Producer = struct {
    executable: []const u8,
    infer: *const fn ([]const []const u8) ?OutputPlan,
};

const producers = [_]Producer{
    .{ .executable = "cat", .infer = inferCat },
    .{ .executable = "git", .infer = inferGit },
};

const max_command_bytes = 16 * 1024;
const max_command_words = 64;

fn parseSimpleCommand(
    allocator: std.mem.Allocator,
    source: []const u8,
) error{ OutOfMemory, UnsupportedCommand }![]const []const u8 {
    if (source.len > max_command_bytes or
        !std.unicode.utf8ValidateSlice(source))
    {
        return error.UnsupportedCommand;
    }

    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var started = false;
    var index: usize = 0;
    while (index < source.len) {
        const byte = source[index];
        if (byte == ' ' or byte == '\t') {
            if (started) {
                try appendWord(allocator, &words, word.items);
                word.clearRetainingCapacity();
                started = false;
            }
            index += 1;
            continue;
        }
        if (isRejectedShellByte(byte)) return error.UnsupportedCommand;
        switch (byte) {
            '\'' => {
                started = true;
                index += 1;
                while (index < source.len and source[index] != '\'') : (index += 1) {
                    if (source[index] < 0x20 or source[index] == 0x7f) {
                        return error.UnsupportedCommand;
                    }
                    try word.append(allocator, source[index]);
                }
                if (index == source.len) return error.UnsupportedCommand;
                index += 1;
            },
            '"' => {
                started = true;
                index += 1;
                while (index < source.len and source[index] != '"') {
                    const quoted = source[index];
                    if (quoted == '$' or quoted == '`' or
                        quoted < 0x20 or quoted == 0x7f)
                    {
                        return error.UnsupportedCommand;
                    }
                    if (quoted == '\\') {
                        index += 1;
                        if (index == source.len or source[index] < 0x20 or
                            source[index] == 0x7f)
                        {
                            return error.UnsupportedCommand;
                        }
                        if (std.mem.indexOfScalar(
                            u8,
                            "$`\"\\",
                            source[index],
                        ) == null) {
                            try word.append(allocator, '\\');
                        }
                    }
                    try word.append(allocator, source[index]);
                    index += 1;
                }
                if (index == source.len) return error.UnsupportedCommand;
                index += 1;
            },
            '\\' => {
                started = true;
                index += 1;
                if (index == source.len or source[index] < 0x20 or
                    source[index] == 0x7f)
                {
                    return error.UnsupportedCommand;
                }
                try word.append(allocator, source[index]);
                index += 1;
            },
            else => {
                started = true;
                try word.append(allocator, byte);
                index += 1;
            },
        }
    }
    if (started) try appendWord(allocator, &words, word.items);
    return words.toOwnedSlice(allocator);
}

fn appendWord(
    allocator: std.mem.Allocator,
    words: *std.ArrayList([]const u8),
    word: []const u8,
) error{ OutOfMemory, UnsupportedCommand }!void {
    if (words.items.len == max_command_words) {
        return error.UnsupportedCommand;
    }
    try words.append(allocator, try allocator.dupe(u8, word));
}

fn isRejectedShellByte(byte: u8) bool {
    return byte < 0x20 or byte == 0x7f or
        std.mem.indexOfScalar(u8, "|&;<>`()$*?[]{}#!", byte) != null;
}

fn inferCat(words: []const []const u8) ?OutputPlan {
    const path = if (words.len == 2)
        words[1]
    else if (words.len == 3 and std.mem.eql(u8, words[1], "--"))
        words[2]
    else
        return null;
    if (path.len == 0 or path[0] == '-') return null;
    return planForPath(path, true);
}

fn inferGit(words: []const []const u8) ?OutputPlan {
    var index: usize = 1;
    while (index < words.len) {
        if (std.mem.eql(u8, words[index], "--no-pager") or
            std.mem.eql(u8, words[index], "--no-ext-diff"))
        {
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, words[index], "-C")) {
            index += 2;
            if (index > words.len) return null;
            continue;
        }
        break;
    }
    if (index == words.len or !std.mem.eql(u8, words[index], "diff")) {
        return null;
    }
    index += 1;
    while (index < words.len) : (index += 1) {
        const word = words[index];
        if (std.mem.eql(u8, word, "--")) return .{ .syntax = .diff };
        if (!std.mem.eql(u8, word, "--cached") and
            !std.mem.eql(u8, word, "--staged") and
            !std.mem.eql(u8, word, "--no-ext-diff") and
            !std.mem.eql(u8, word, "--no-color"))
        {
            return null;
        }
    }
    return .{ .syntax = .diff };
}

fn planForPath(path: []const u8, complete: bool) OutputPlan {
    if (isMarkdownPath(path)) return .markdown;
    if (highlight.Language.fromPath(path)) |language| {
        const require_complete = complete and
            !std.ascii.eqlIgnoreCase(
                std.fs.path.extension(path),
                ".jsonl",
            );
        return if (require_complete)
            .{ .syntax = language }
        else
            .{ .syntax_fragment = language };
    }
    return .literal;
}

fn isMarkdownPath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".md") or
        std.ascii.eqlIgnoreCase(extension, ".markdown") or
        std.ascii.eqlIgnoreCase(extension, ".mdown") or
        std.ascii.eqlIgnoreCase(extension, ".mkdn");
}

test "output plans classify only static homogeneous commands" {
    const cases = [_]struct {
        command: []const u8,
        expected: OutputPlan,
    }{
        .{ .command = "cat .github/workflows/ci.yml", .expected = .{ .syntax = .yaml } },
        .{ .command = "cat -- 'workflow.yaml'", .expected = .{ .syntax = .yaml } },
        .{ .command = "cat records.jsonl", .expected = .{ .syntax_fragment = .json } },
        .{ .command = "git diff", .expected = .{ .syntax = .diff } },
        .{ .command = "git diff --cached", .expected = .{ .syntax = .diff } },
        .{ .command = "git --no-pager diff -- cli/src/chat.zig", .expected = .{ .syntax = .diff } },
        .{ .command = "cat README.md", .expected = .markdown },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            try OutputPlan.fromCommand(std.testing.allocator, case.command),
        );
    }

    const rejected = [_][]const u8{
        "cat a.yml b.yml",
        "cat -n a.yml",
        "cat a.yml | sed s/a/b/",
        "cat a.yml > copy.yml",
        "cat a.yml\nprintf done",
        "cat \"$FILE\"",
        "cat \"workflow.\\yml\"",
        "cat `find . -name ci.yml`",
        "cat workflow.\xffyml",
        "git diff --stat",
        "git diff --color",
        "git diff && echo done",
        "printf 'name: value'",
    };
    for (rejected) |command| {
        try std.testing.expectEqual(
            OutputPlan.literal,
            try OutputPlan.fromCommand(std.testing.allocator, command),
        );
    }
}

test "output plans sanitize before strict syntax highlighting" {
    const plan: OutputPlan = .{ .syntax = .yaml };
    const display = try plan.render(
        std.testing.allocator,
        .succeeded,
        "name: vivi\nready: true\nnote: \x1b[31mred\n",
    );
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings(
        "name: vivi\nready: true\nnote: red\n",
        display,
    );
    const highlighted = try plan.spans(
        std.testing.allocator,
        .succeeded,
        display,
    );
    defer std.testing.allocator.free(highlighted);
    try std.testing.expect(highlighted.len > 0);
    for (highlighted) |span| {
        try std.testing.expect(span.start < span.end);
        try std.testing.expect(span.end <= display.len);
    }
}

test "partial reads use tolerant fragment highlighting" {
    const plan = try OutputPlan.fromInvocation(
        std.testing.allocator,
        .{ .read = .{
            .path = "example.py",
            .offset = 2,
            .limit = 1,
        } },
    );
    try std.testing.expectEqual(
        OutputPlan{ .syntax_fragment = .python },
        plan,
    );

    const source = "    return 1\n";
    const highlighted = try plan.spans(
        std.testing.allocator,
        .succeeded,
        source,
    );
    defer std.testing.allocator.free(highlighted);
    for (highlighted) |span| {
        if (span.token == .keyword and
            std.mem.eql(u8, source[span.start..span.end], "return"))
        {
            return;
        }
    }
    return error.ExpectedReturnKeyword;
}

test "source rendering normalizes CRLF before strict parsing" {
    const plan: OutputPlan = .{ .syntax = .python };
    const display = try plan.render(
        std.testing.allocator,
        .succeeded,
        "def greet():\r\n    return \"hi\"\r\n",
    );
    defer std.testing.allocator.free(display);
    try std.testing.expectEqualStrings(
        "def greet():\n    return \"hi\"\n",
        display,
    );

    const highlighted = try plan.spans(
        std.testing.allocator,
        .succeeded,
        display,
    );
    defer std.testing.allocator.free(highlighted);
    for (highlighted) |span| {
        if (span.token == .function and
            std.mem.eql(u8, display[span.start..span.end], "greet"))
        {
            return;
        }
    }
    return error.ExpectedFunctionName;
}

test "JSONL uses tolerant highlighting for multiple records" {
    const plan = try OutputPlan.fromInvocation(
        std.testing.allocator,
        .{ .read = .{
            .path = "records.jsonl",
            .offset = null,
            .limit = null,
        } },
    );
    try std.testing.expectEqual(
        OutputPlan{ .syntax_fragment = .json },
        plan,
    );

    const source = "{\"first\": true}\n{\"second\": false}\n";
    const highlighted = try plan.spans(
        std.testing.allocator,
        .succeeded,
        source,
    );
    defer std.testing.allocator.free(highlighted);
    var properties: usize = 0;
    for (highlighted) |span| {
        if (span.token == .property) properties += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), properties);
}
