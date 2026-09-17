const std = @import("std");
pub const syntax = @import("presentation/syntax.zig");

pub const Language = syntax.Language;
pub const SemanticToken = syntax.Token;
pub const SemanticSpan = syntax.Span;
pub const PresentationKind = enum { literal, markdown, source };

pub const Presentation = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    content: union(enum) {
        literal,
        markdown,
        source: struct {
            language: Language,
            tokens: []SemanticSpan,
        },
    },

    pub fn clone(self: Presentation, allocator: std.mem.Allocator) !Presentation {
        const text = try allocator.dupe(u8, self.text);
        errdefer allocator.free(text);
        return .{
            .allocator = allocator,
            .text = text,
            .content = switch (self.content) {
                .literal => .literal,
                .markdown => .markdown,
                .source => |source| .{ .source = .{
                    .language = source.language,
                    .tokens = try allocator.dupe(SemanticSpan, source.tokens),
                } },
            },
        };
    }

    pub fn eql(self: Presentation, other: Presentation) bool {
        if (!std.mem.eql(u8, self.text, other.text)) return false;
        return switch (self.content) {
            .literal => std.meta.activeTag(other.content) == .literal,
            .markdown => std.meta.activeTag(other.content) == .markdown,
            .source => |source| switch (other.content) {
                .source => |candidate| blk: {
                    if (source.language != candidate.language or
                        source.tokens.len != candidate.tokens.len)
                    {
                        break :blk false;
                    }
                    for (source.tokens, candidate.tokens) |left, right| {
                        if (left.start != right.start or left.end != right.end or
                            left.token != right.token)
                        {
                            break :blk false;
                        }
                    }
                    break :blk true;
                },
                else => false,
            },
        };
    }

    pub fn deinit(self: *Presentation) void {
        switch (self.content) {
            .source => |source| self.allocator.free(source.tokens),
            .literal, .markdown => {},
        }

        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn kind(self: Presentation) PresentationKind {
        return switch (self.content) {
            .literal => .literal,
            .markdown => .markdown,
            .source => .source,
        };
    }
};

pub const ToolOutcome = enum {
    succeeded,
    failed,
    image,
};

const ParseMode = enum {
    complete,
    document,
    fragment,
};

const Plan = union(enum) {
    literal,
    markdown,
    source: struct {
        language: Language,
        mode: ParseMode,
    },
};

pub fn presentToolInput(
    allocator: std.mem.Allocator,
    summary: anytype,
    raw_arguments_json: []const u8,
) !Presentation {
    const command = switch (summary) {
        .bash => |bash| switch (bash) {
            .run => |value| value.command,
            .start => |value| value.command,
            else => null,
        },
        else => null,
    };
    if (command) |source| {
        return presentSource(allocator, .bash, .fragment, source);
    }
    return .{
        .allocator = allocator,
        .text = try renderLiteral(allocator, raw_arguments_json),
        .content = .literal,
    };
}

pub fn presentToolResult(
    allocator: std.mem.Allocator,
    summary: anytype,
    outcome: ToolOutcome,
    raw: []const u8,
) !Presentation {
    if (outcome != .succeeded) {
        return .{
            .allocator = allocator,
            .text = try renderOutput(allocator, raw),
            .content = .literal,
        };
    }
    return switch (try planForSummary(allocator, summary)) {
        .literal => .{
            .allocator = allocator,
            .text = try renderOutput(allocator, raw),
            .content = .literal,
        },
        .markdown => .{
            .allocator = allocator,
            .text = try renderMarkdown(allocator, raw),
            .content = .markdown,
        },
        .source => |source| presentSource(
            allocator,
            source.language,
            source.mode,
            raw,
        ),
    };
}

pub fn presentCodeFragment(
    allocator: std.mem.Allocator,
    language_name: []const u8,
    raw: []const u8,
) !Presentation {
    const language = Language.fromMarkdownName(language_name) orelse {
        return .{
            .allocator = allocator,
            .text = try renderLiteral(allocator, raw),
            .content = .literal,
        };
    };
    return presentSource(allocator, language, .fragment, raw);
}

fn presentSource(
    allocator: std.mem.Allocator,
    language: Language,
    mode: ParseMode,
    raw: []const u8,
) !Presentation {
    const text = try renderSource(allocator, raw);
    errdefer allocator.free(text);
    const maybe_tokens = switch (mode) {
        .complete => try syntax.completeSpansChecked(allocator, language, text),
        .document => try syntax.completeDocumentSpansChecked(allocator, language, text),
        .fragment => try syntax.spans(allocator, language, text),
    };
    const tokens = maybe_tokens orelse {
        allocator.free(text);
        return .{
            .allocator = allocator,
            .text = try renderOutput(allocator, raw),
            .content = .literal,
        };
    };
    return .{
        .allocator = allocator,
        .text = text,
        .content = .{ .source = .{
            .language = language,
            .tokens = tokens,
        } },
    };
}

fn planForSummary(allocator: std.mem.Allocator, summary: anytype) !Plan {
    return switch (summary) {
        .read => |read| planForPath(
            read.path,
            read.offset == null and read.limit == null,
        ),
        .bash => |bash| switch (bash) {
            .run => |run| planForCommand(allocator, run.command),
            .start, .list, .read, .write, .stop => .literal,
        },
        .edit, .write, .other => .literal,
    };
}

fn planForCommand(allocator: std.mem.Allocator, command: []const u8) !Plan {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const words = parseSimpleCommand(arena_state.allocator(), command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedCommand => return .literal,
    };
    if (words.len == 0) return .literal;
    if (std.mem.eql(u8, words[0], "cat")) return inferCat(words) orelse .literal;
    if (std.mem.eql(u8, words[0], "git")) return inferGit(words) orelse .literal;
    return .literal;
}

const max_command_bytes = 16 * 1024;
const max_command_words = 64;

fn parseSimpleCommand(
    allocator: std.mem.Allocator,
    source: []const u8,
) error{ OutOfMemory, UnsupportedCommand }![]const []const u8 {
    if (source.len > max_command_bytes or !std.unicode.utf8ValidateSlice(source)) {
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
                    if (source[index] < 0x20 or source[index] == 0x7f)
                        return error.UnsupportedCommand;
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
                    if (quoted == '$' or quoted == '`' or quoted < 0x20 or quoted == 0x7f)
                        return error.UnsupportedCommand;
                    if (quoted == '\\') {
                        index += 1;
                        if (index == source.len or source[index] < 0x20 or
                            source[index] == 0x7f)
                            return error.UnsupportedCommand;
                        if (std.mem.indexOfScalar(u8, "$`\"\\", source[index]) == null)
                            try word.append(allocator, '\\');
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
                if (index == source.len or source[index] < 0x20 or source[index] == 0x7f)
                    return error.UnsupportedCommand;
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
    if (words.items.len == max_command_words) return error.UnsupportedCommand;
    try words.append(allocator, try allocator.dupe(u8, word));
}

fn isRejectedShellByte(byte: u8) bool {
    return byte < 0x20 or byte == 0x7f or
        std.mem.indexOfScalar(u8, "|&;<>`()$*?[]{}#!", byte) != null;
}

fn inferCat(words: []const []const u8) ?Plan {
    const path = if (words.len == 2)
        words[1]
    else if (words.len == 3 and std.mem.eql(u8, words[1], "--"))
        words[2]
    else
        return null;
    if (path.len == 0 or path[0] == '-') return null;
    return planForPath(path, true);
}

fn inferGit(words: []const []const u8) ?Plan {
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
    if (index == words.len or !std.mem.eql(u8, words[index], "diff")) return null;
    index += 1;
    while (index < words.len) : (index += 1) {
        const word = words[index];
        if (std.mem.eql(u8, word, "--")) {
            return .{ .source = .{ .language = .diff, .mode = .complete } };
        }
        if (!std.mem.eql(u8, word, "--cached") and
            !std.mem.eql(u8, word, "--staged") and
            !std.mem.eql(u8, word, "--no-ext-diff") and
            !std.mem.eql(u8, word, "--no-color"))
            return null;
    }
    return .{ .source = .{ .language = .diff, .mode = .complete } };
}

fn planForPath(path: []const u8, complete: bool) Plan {
    if (isMarkdownPath(path)) return .markdown;
    if (Language.fromPath(path)) |language| {
        const require_complete = complete and
            !std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".jsonl");
        return .{ .source = .{
            .language = language,
            .mode = if (!require_complete)
                .fragment
            else if (language == .diff)
                .document
            else
                .complete,
        } };
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

const TestBashSummary = union(enum) {
    run: struct { command: []const u8 },
    start: struct { command: []const u8 },
    list,
    read,
    write,
    stop,
};

const TestSummary = union(enum) {
    read: struct {
        path: []const u8,
        offset: ?usize,
        limit: ?usize,
    },
    bash: TestBashSummary,
    edit,
    write,
    other,
};

test "strict source rejection rerenders the raw payload as literal" {
    var value = try presentToolResult(
        std.testing.allocator,
        TestSummary{ .read = .{
            .path = "broken.yaml",
            .offset = null,
            .limit = null,
        } },
        .succeeded,
        "items: [one,\t two\r\n",
    );
    defer value.deinit();
    try std.testing.expect(std.meta.activeTag(value.content) == .literal);
    try std.testing.expectEqualStrings(
        "items: [one,\\x09 two\\x0d\n",
        value.text,
    );
}

test "tool result presentation classifies paths and command producers" {
    const cases = [_]struct {
        summary: TestSummary,
        raw: []const u8,
        kind: PresentationKind,
    }{
        .{
            .summary = .{ .read = .{
                .path = "guide.MARKDOWN",
                .offset = null,
                .limit = null,
            } },
            .raw = "# Guide",
            .kind = .markdown,
        },
        .{
            .summary = .{ .read = .{
                .path = "main.zig",
                .offset = null,
                .limit = null,
            } },
            .raw = "const answer = 42;",
            .kind = .source,
        },
        .{
            .summary = .{ .read = .{
                .path = "example.py",
                .offset = 2,
                .limit = 1,
            } },
            .raw = "    return 1\n",
            .kind = .source,
        },
        .{
            .summary = .{ .read = .{
                .path = "records.jsonl",
                .offset = null,
                .limit = null,
            } },
            .raw = "{\"first\": true}\n{\"second\": false}\n",
            .kind = .source,
        },
        .{
            .summary = .{ .read = .{
                .path = "changes.patch",
                .offset = null,
                .limit = null,
            } },
            .raw = "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
            .kind = .source,
        },
        .{
            .summary = .{ .read = .{
                .path = "changes.diff",
                .offset = null,
                .limit = null,
            } },
            .raw = "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
            .kind = .source,
        },
        .{
            .summary = .{ .bash = .{ .run = .{
                .command = "cat -- 'workflow.yaml'",
            } } },
            .raw = "name: vivi\n",
            .kind = .source,
        },
        .{
            .summary = .{ .bash = .{ .run = .{
                .command = "cat \"workflow.yaml\"",
            } } },
            .raw = "name: vivi\n",
            .kind = .source,
        },
        .{
            .summary = .{ .bash = .{ .run = .{
                .command = "git -C repo --no-pager --no-ext-diff diff --cached --no-color --",
            } } },
            .raw = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
            .kind = .source,
        },
        .{
            .summary = .{ .bash = .{ .run = .{ .command = "git diff --stat" } } },
            .raw = "a | 1 +",
            .kind = .literal,
        },
    };
    for (cases) |case| {
        var value = try presentToolResult(
            std.testing.allocator,
            case.summary,
            .succeeded,
            case.raw,
        );
        defer value.deinit();
        try std.testing.expectEqual(case.kind, value.kind());
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
        var value = try presentToolResult(
            std.testing.allocator,
            TestSummary{ .bash = .{ .run = .{ .command = command } } },
            .succeeded,
            "name: value\n",
        );
        defer value.deinit();
        try std.testing.expectEqual(PresentationKind.literal, value.kind());
    }
}

test "fragment and diff document presentations retain semantic tokens" {
    const cases = [_]struct {
        summary: TestSummary,
        raw: []const u8,
        token: SemanticToken,
        text: []const u8,
        count: usize,
    }{
        .{
            .summary = .{ .read = .{
                .path = "example.py",
                .offset = 2,
                .limit = 1,
            } },
            .raw = "    return 1\n",
            .token = .keyword,
            .text = "return",
            .count = 1,
        },
        .{
            .summary = .{ .read = .{
                .path = "records.jsonl",
                .offset = null,
                .limit = null,
            } },
            .raw = "{\"first\": true}\n{\"second\": false}\n",
            .token = .property,
            .text = "",
            .count = 2,
        },
        .{
            .summary = .{ .read = .{
                .path = "changes.patch",
                .offset = null,
                .limit = null,
            } },
            .raw = "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
            .token = .inserted,
            .text = "+new",
            .count = 1,
        },
    };
    for (cases) |case| {
        var value = try presentToolResult(
            std.testing.allocator,
            case.summary,
            .succeeded,
            case.raw,
        );
        defer value.deinit();
        const source = value.content.source;
        var matches: usize = 0;
        for (source.tokens) |span| {
            if (span.token == case.token and
                (case.text.len == 0 or
                    std.mem.eql(u8, value.text[span.start..span.end], case.text)))
            {
                matches += 1;
            }
        }
        try std.testing.expectEqual(case.count, matches);
    }
}

test "Bash input and known fenced fragments share semantic tokens" {
    var input = try presentToolInput(
        std.testing.allocator,
        TestSummary{ .bash = .{ .run = .{ .command = "printf '%s' ready" } } },
        "{}",
    );
    defer input.deinit();
    try std.testing.expect(input.kind() == .source);
    try std.testing.expect(input.content.source.tokens.len > 0);

    var fragment = try presentCodeFragment(
        std.testing.allocator,
        "PYTHON3",
        "return \"héllo\"\n",
    );
    defer fragment.deinit();
    try std.testing.expect(fragment.kind() == .source);
    for (fragment.content.source.tokens) |span| {
        try std.testing.expect(span.start < span.end);
        try std.testing.expect(span.end <= fragment.text.len);
    }

    var unknown = try presentCodeFragment(
        std.testing.allocator,
        "unknown-language",
        "\x1b[31mtext",
    );
    defer unknown.deinit();
    try std.testing.expect(unknown.kind() == .literal);
    try std.testing.expectEqualStrings("\\x1b[31mtext", unknown.text);
}
