const std = @import("std");
const backend = @import("vivi_backend");
const highlight = backend.syntax;
const vaxis = @import("vaxis");
const md4c_unicode_punctuation = @import("md4c_unicode_punctuation.zig");
const c = @cImport({
    @cInclude("md4c.h");
    @cInclude("entity.h");
});

pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    code: bool = false,
    heading: bool = false,
    link: bool = false,
    syntax: ?highlight.Token = null,
};

pub const Segment = struct {
    text: []u8,
    style: Style,
    uri: ?[]u8 = null,

    fn deinit(self: *Segment, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.uri) |uri| allocator.free(uri);
        self.* = undefined;
    }
};

pub const Line = struct {
    segments: std.ArrayList(Segment) = .empty,
    leading_width: u16 = 0,
    continuation_indent: u16 = 0,
    code: bool = false,

    pub fn deinit(self: *Line, allocator: std.mem.Allocator) void {
        for (self.segments.items) |*segment| segment.deinit(allocator);
        self.segments.deinit(allocator);
        self.* = undefined;
    }

    fn append(
        self: *Line,
        allocator: std.mem.Allocator,
        text: []const u8,
        style: Style,
        uri: ?[]const u8,
    ) !void {
        if (text.len == 0) return;
        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);
        const owned_uri = if (uri) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_uri) |value| allocator.free(value);
        try self.segments.append(allocator, .{
            .text = owned_text,
            .style = style,
            .uri = owned_uri,
        });
    }
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    total_rows: usize = 0,

    pub const Allocators = struct {
        result: std.mem.Allocator,
        scratch: std.mem.Allocator,
        cache: std.mem.Allocator,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        window: vaxis.Window,
        width: u16,
    ) !Layout {
        return initCached(allocator, source, window, width, null);
    }

    pub fn initCached(
        allocator: std.mem.Allocator,
        source: []const u8,
        window: vaxis.Window,
        width: u16,
        highlight_cache: ?*HighlightCache,
    ) !Layout {
        return initCachedRange(
            allocator,
            source,
            window,
            width,
            highlight_cache,
            0,
            std.math.maxInt(usize),
        );
    }

    pub fn initCachedRange(
        allocator: std.mem.Allocator,
        source: []const u8,
        window: vaxis.Window,
        width: u16,
        highlight_cache: ?*HighlightCache,
        first_row: usize,
        last_row: usize,
    ) !Layout {
        return initCachedRangeAllocating(
            .{
                .result = allocator,
                .scratch = allocator,
                .cache = allocator,
            },
            source,
            window,
            width,
            highlight_cache,
            first_row,
            last_row,
        );
    }

    pub fn initCachedRangeAllocating(
        allocators: Allocators,
        source: []const u8,
        window: vaxis.Window,
        width: u16,
        highlight_cache: ?*HighlightCache,
        first_row: usize,
        last_row: usize,
    ) !Layout {
        if (source.len > std.math.maxInt(c.MD_SIZE)) {
            return error.MarkdownInputTooLarge;
        }
        var builder = Builder{
            .allocator = allocators.scratch,
            .cache_allocator = allocators.cache,
            .window = window,
            .width = @max(width, 1),
            .highlight_cache = highlight_cache,
        };
        defer builder.deinit();

        var parser = std.mem.zeroes(c.MD_PARSER);
        parser.flags = c.MD_DIALECT_GITHUB | c.MD_FLAG_NOHTML;
        parser.enter_block = enterBlock;
        parser.leave_block = leaveBlock;
        parser.enter_span = enterSpan;
        parser.leave_span = leaveSpan;
        parser.text = textCallback;

        const result = c.md_parse(
            source.ptr,
            @intCast(source.len),
            &parser,
            &builder,
        );
        if (builder.failure) |failure| return failure;
        if (result != 0) return error.MarkdownParseFailed;
        try builder.finishDocument();
        if (highlight_cache) |cache| {
            cache.truncate(allocators.cache, builder.code_block_index);
        }

        var layout = Layout{ .allocator = allocators.result };
        errdefer layout.deinit();
        layout.total_rows = try builder.wrapRangeInto(
            allocators.result,
            &layout.lines,
            first_row,
            last_row,
        );
        return layout;
    }

    pub fn deinit(self: *Layout) void {
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const HighlightCache = struct {
    blocks: std.ArrayList(Block) = .empty,

    const digest_length = std.crypto.hash.sha2.Sha256.digest_length;

    const Block = struct {
        language: highlight.Language,
        digest: [digest_length]u8,
        text: []u8,
        spans: []highlight.Span,

        fn deinit(self: *Block, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            allocator.free(self.spans);
            self.* = undefined;
        }
    };

    const Code = struct {
        text: []const u8,
        spans: []const highlight.Span,
    };

    pub fn deinit(self: *HighlightCache, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(allocator);
        self.blocks.deinit(allocator);
        self.* = undefined;
    }

    fn codeFor(
        self: *HighlightCache,
        allocator: std.mem.Allocator,
        index: usize,
        language: highlight.Language,
        source: []const u8,
    ) !Code {
        var digest: [digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
        if (index < self.blocks.items.len) {
            const block = &self.blocks.items[index];
            if (block.language == language and
                std.mem.eql(u8, &block.digest, &digest))
            {
                return .{ .text = block.text, .spans = block.spans };
            }
            var presented = try fragmentCode(allocator, language, source);
            errdefer presented.deinit(allocator);
            block.deinit(allocator);
            block.* = .{
                .language = language,
                .digest = digest,
                .text = presented.text,
                .spans = presented.spans,
            };
            return .{ .text = block.text, .spans = block.spans };
        }
        std.debug.assert(index == self.blocks.items.len);
        var presented = try fragmentCode(allocator, language, source);
        errdefer presented.deinit(allocator);
        try self.blocks.append(allocator, .{
            .language = language,
            .digest = digest,
            .text = presented.text,
            .spans = presented.spans,
        });
        return .{ .text = presented.text, .spans = presented.spans };
    }

    fn truncate(
        self: *HighlightCache,
        allocator: std.mem.Allocator,
        count: usize,
    ) void {
        while (self.blocks.items.len > count) {
            var block = self.blocks.pop().?;
            block.deinit(allocator);
        }
    }
};

const FragmentCode = struct {
    text: []u8,
    spans: []highlight.Span,

    fn deinit(self: *FragmentCode, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.spans);
        self.* = undefined;
    }
};

fn fragmentCode(
    allocator: std.mem.Allocator,
    language: highlight.Language,
    source: []const u8,
) !FragmentCode {
    var presented = try backend.presentCodeFragment(
        allocator,
        @tagName(language),
        source,
    );
    defer presented.deinit();
    const text = try allocator.dupe(u8, presented.text);
    errdefer allocator.free(text);
    const spans = switch (presented.content) {
        .source => |value| try allocator.dupe(highlight.Span, value.tokens),
        .literal, .markdown => try allocator.alloc(highlight.Span, 0),
    };
    return .{ .text = text, .spans = spans };
}

pub fn combineStyle(base: vaxis.Style, markdown: Style) vaxis.Style {
    var result = base;
    result.bold = result.bold or markdown.bold or markdown.heading;
    result.italic = result.italic or markdown.italic;
    result.strikethrough = result.strikethrough or markdown.strikethrough;
    if (markdown.heading or markdown.link) result.ul_style = .single;
    if (markdown.code) result.bg = .{ .index = 236 };
    if (markdown.syntax) |syntax| result.fg = syntaxColor(syntax);
    return result;
}

/// A style range expressed over the original Markdown source. The bytes in
/// [start, end) keep their literal content (syntax markers included) so an
/// editor can style its buffer in place without moving the cursor: identical
/// bytes mean identical wrap positions and cursor offsets.
pub const SourceSpan = struct {
    start: usize,
    end: usize,
    style: Style,
};

const flag_bold: u8 = 1 << 0;
const flag_italic: u8 = 1 << 1;
const flag_strikethrough: u8 = 1 << 2;
const flag_code: u8 = 1 << 3;
const flag_heading: u8 = 1 << 4;
const flag_link: u8 = 1 << 5;
const delimiter_opener: u8 = 1 << 0;
const delimiter_closer: u8 = 1 << 1;

const max_code_span_delimiter = 32;

const EmphasisOpener = struct {
    marker: u8 = 0,
    start: usize = 0,
    run: usize = 0,
    original_mod3: u2 = 0,
    can_close: bool = false,
    previous_same: usize = std.math.maxInt(usize),
};

const PendingDelimiter = struct {
    start: usize,
    marker: u8,
    run: usize,
    original_mod3: u2,
    can_open: bool,
    can_close: bool,
};

fn markRange(flags: []u8, start: usize, end: usize, bits: u8) void {
    if (start >= end or start >= flags.len) return;
    const stop = @min(end, flags.len);
    for (flags[start..stop]) |*slot| slot.* |= bits;
}

fn styleFromFlags(bits: u8) Style {
    return .{
        .bold = bits & flag_bold != 0,
        .italic = bits & flag_italic != 0,
        .strikethrough = bits & flag_strikethrough != 0,
        .code = bits & flag_code != 0,
        .heading = bits & flag_heading != 0,
        .link = bits & flag_link != 0,
    };
}

fn countRun(text: []const u8, from: usize, limit: usize, byte: u8) usize {
    var n: usize = 0;
    while (from + n < limit and text[from + n] == byte) n += 1;
    return n;
}

fn isSpaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isUnicodePunctuation(codepoint: u21) bool {
    return md4c_unicode_punctuation.contains(codepoint);
}

fn codepointAt(text: []const u8, index: usize) ?u21 {
    if (index >= text.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    if (index + length > text.len) return null;
    return std.unicode.utf8Decode(text[index..][0..length]) catch null;
}

fn codepointBefore(text: []const u8, index: usize) ?u21 {
    if (index == 0 or index > text.len) return null;
    var start = index - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    return codepointAt(text, start);
}

const CharacterClass = enum { whitespace, punctuation, other };

fn characterClass(codepoint: ?u21) CharacterClass {
    const value = codepoint orelse return .whitespace;
    if (isUnicodeWhitespace(value)) return .whitespace;
    return if (isUnicodePunctuation(value)) .punctuation else .other;
}

fn isUnicodeWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x09...0x0d,
        0x20,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn escapedByteCount(text: []const u8, index: usize, hi: usize) usize {
    if (index + 1 < hi and text[index] == '\\' and text[index + 1] < 0x80 and
        std.ascii.isPunctuation(text[index + 1]))
    {
        return 2;
    }
    return 1;
}

const DelimiterFlanking = struct {
    left: bool,
    right: bool,
};

fn delimiterFlanking(before: CharacterClass, after: CharacterClass) DelimiterFlanking {
    return .{
        .left = after != .whitespace and
            (before == .whitespace or before == .punctuation or after != .punctuation),
        .right = before != .whitespace and
            (after == .whitespace or after == .punctuation or before != .punctuation),
    };
}

fn delimiterMarkerSlot(marker: u8) usize {
    return switch (marker) {
        '*' => 0,
        '_' => 1,
        '~' => 2,
        else => unreachable,
    };
}

fn delimiterCloserClass(marker: u8, original_mod3: u2, can_open: bool, run: usize) usize {
    if (marker == '~') return if (run == 1) 0 else 1;
    return @as(usize, original_mod3) * 2 + @intFromBool(can_open);
}

/// Scans inline Markdown for one line, OR-ing style bits into the absolute
/// positions of `flags`. Unmatched markers are left unstyled (literal).
fn scanInline(
    flags: []u8,
    delimiter_roles: []u8,
    delimiter_pairs: []const usize,
    link_states: []const u8,
    link_dest_ends: []const usize,
    emphasis_openers: []EmphasisOpener,
    text: []const u8,
    lo: usize,
    hi: usize,
    depth: u8,
) void {
    var i = lo;
    const opener_stack = emphasis_openers[lo..hi];
    const no_opener = std.math.maxInt(usize);
    var opener_tops: [3]usize = @splat(no_opener);
    var opener_lower_bounds: [3][6]usize = @splat(@splat(no_opener));
    var emphasis_depth: usize = 0;
    var pending_delimiter: ?PendingDelimiter = null;

    while (i < hi) {
        switch (text[i]) {
            '\\' => {
                i += escapedByteCount(text, i, hi);
            },
            '`' => {
                const code_span_end = findCodeSpanEnd(text, i, hi);
                if (code_span_end) |end| markRange(flags, i, end, flag_code);
                i = code_span_end orelse i + countRun(text, i, hi, '`');
            },
            '[', '!' => {
                const image = text[i] == '!' and i + 1 < hi and text[i + 1] == '[';
                if (!image and text[i] != '[') {
                    i += 1;
                    continue;
                }
                const label_open = if (image) i + 1 else i;
                if (link_states[label_open] != 0) {
                    const link: LinkMatch = .{
                        .label_close = delimiter_pairs[label_open],
                        .dest_end = link_dest_ends[label_open],
                    };
                    if (!image and link_states[label_open] == 2) {
                        markRange(flags, i, link.dest_end + 1, flag_link);
                    }
                    if (depth < 4) {
                        scanInline(
                            flags,
                            delimiter_roles,
                            delimiter_pairs,
                            link_states,
                            link_dest_ends,
                            emphasis_openers,
                            text,
                            label_open + 1,
                            link.label_close,
                            depth + 2,
                        );
                    }
                    i = link.dest_end + 1;
                } else {
                    i += if (image) 1 else 1;
                }
            },
            '*', '_', '~' => {
                const marker = text[i];
                const pending = if (pending_delimiter) |value|
                    if (value.start == i and value.marker == marker) value else null
                else
                    null;
                pending_delimiter = null;
                const run = if (pending) |value| value.run else countRun(text, i, hi, marker);
                if (marker == '~' and run > 2) {
                    i += run;
                    continue;
                }
                const before = characterClass(if (i > lo) codepointBefore(text, i) else null);
                const after = characterClass(if (i + run < hi) codepointAt(text, i + run) else null);
                const flanking = delimiterFlanking(before, after);
                const can_open = if (pending) |value|
                    value.can_open
                else if (marker == '~')
                    before != .other
                else
                    flanking.left and
                        (marker == '*' or !flanking.right or before == .punctuation);
                const delimiter_can_close = if (pending) |value|
                    value.can_close
                else if (marker == '~')
                    after != .other
                else
                    flanking.right and
                        (marker == '*' or !flanking.left or after == .punctuation);
                const original_mod3: u2 = if (pending) |value|
                    value.original_mod3
                else
                    @intCast(run % 3);

                var opener_index: ?usize = null;
                if (delimiter_can_close) {
                    const marker_slot = delimiterMarkerSlot(marker);
                    const closer_class = delimiterCloserClass(
                        marker,
                        original_mod3,
                        can_open,
                        run,
                    );
                    const initial_candidate = opener_tops[marker_slot];
                    const lower_bound = opener_lower_bounds[marker_slot][closer_class];
                    var candidate_index = initial_candidate;
                    while (candidate_index != no_opener) {
                        const candidate = opener_stack[candidate_index];
                        if (lower_bound != no_opener and candidate.start <= lower_bound) break;
                        if (marker == '~' and candidate.run != run) {
                            candidate_index = candidate.previous_same;
                            continue;
                        }
                        const rule_of_three_allows_close = marker == '~' or
                            !((candidate.can_close or can_open) and
                                (@as(usize, candidate.original_mod3) +
                                    @as(usize, original_mod3)) % 3 == 0 and
                                (candidate.original_mod3 != 0 or original_mod3 != 0));
                        if (rule_of_three_allows_close) {
                            opener_index = candidate_index;
                            break;
                        }
                        candidate_index = candidate.previous_same;
                    }
                    if (opener_index == null) {
                        opener_lower_bounds[marker_slot][closer_class] =
                            if (initial_candidate == no_opener)
                                i
                            else
                                opener_stack[initial_candidate].start;
                    }
                }

                if (opener_index) |candidate_index| {
                    var opener = &opener_stack[candidate_index];
                    emphasis_depth = candidate_index + 1;
                    if (marker == '~') {
                        markRange(flags, opener.start, i + run, flag_strikethrough);
                        markRange(delimiter_roles, opener.start, opener.start + run, delimiter_opener);
                        markRange(delimiter_roles, i, i + run, delimiter_closer);
                        if (depth < 4) {
                            scanInline(
                                flags,
                                delimiter_roles,
                                delimiter_pairs,
                                link_states,
                                link_dest_ends,
                                emphasis_openers,
                                text,
                                opener.start + run,
                                i,
                                depth + 2,
                            );
                        }
                        emphasis_depth = candidate_index;
                        for (&opener_tops) |*top| {
                            while (top.* != no_opener and top.* >= emphasis_depth) {
                                top.* = opener_stack[top.*].previous_same;
                            }
                        }
                        i += run;
                        continue;
                    }
                    const consumed = @min(run, opener.run);
                    const opener_start = opener.start + opener.run - consumed;
                    if (consumed >= 2) markRange(flags, opener_start, i + consumed, flag_bold);
                    if (consumed % 2 == 1) markRange(flags, opener_start, i + consumed, flag_italic);
                    markRange(
                        delimiter_roles,
                        opener_start,
                        opener_start + consumed,
                        delimiter_opener,
                    );
                    markRange(delimiter_roles, i, i + consumed, delimiter_closer);
                    opener.run -= consumed;
                    if (opener.run == 0) emphasis_depth = candidate_index;
                    for (&opener_tops) |*top| {
                        while (top.* != no_opener and top.* >= emphasis_depth) {
                            top.* = opener_stack[top.*].previous_same;
                        }
                    }
                    if (consumed < run) {
                        pending_delimiter = .{
                            .start = i + consumed,
                            .marker = marker,
                            .run = run - consumed,
                            .original_mod3 = original_mod3,
                            .can_open = can_open,
                            .can_close = delimiter_can_close,
                        };
                    }
                    i += consumed;
                } else if (can_open) {
                    const marker_slot = delimiterMarkerSlot(marker);
                    opener_stack[emphasis_depth] = .{
                        .marker = marker,
                        .start = i,
                        .run = run,
                        .original_mod3 = original_mod3,
                        .can_close = delimiter_can_close,
                        .previous_same = opener_tops[marker_slot],
                    };
                    opener_tops[marker_slot] = emphasis_depth;
                    emphasis_depth += 1;
                    i += run;
                } else {
                    i += run;
                }
            },
            else => i += 1,
        }
    }
}

const LinkMatch = struct { label_close: usize, dest_end: usize };
const LinkCandidate = struct {
    match: LinkMatch,
    destination: []const u8,
};

fn findCodeSpanEnd(text: []const u8, start: usize, hi: usize) ?usize {
    const run = countRun(text, start, hi, '`');
    if (run > max_code_span_delimiter) return null;
    var cursor = start + run;
    while (cursor + run <= hi) {
        if (text[cursor] != '`') {
            cursor += 1;
            continue;
        }
        const closer_run = countRun(text, cursor, hi, '`');
        if (closer_run == run and cursor > start + run) return cursor + run;
        cursor += @max(closer_run, 1);
    }
    return null;
}

fn pairDelimiters(
    pairs: []usize,
    stack: []usize,
    text: []const u8,
    lo: usize,
    hi: usize,
    open: u8,
    close: u8,
) void {
    const dirty_bit: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const index_mask: usize = ~dirty_bit;
    var depth: usize = 0;
    var angle_scan_from = lo;
    var angle_scan_end: ?usize = null;
    var i = lo;
    while (i < hi) {
        if (text[i] == '\\') {
            i += escapedByteCount(text, i, hi);
            continue;
        }
        if (text[i] == '`') {
            i = findCodeSpanEnd(text, i, hi) orelse i + countRun(text, i, hi, '`');
            continue;
        }
        if (open == '(' and text[i] == '<' and depth > 0) {
            if (stack[depth - 1] & dirty_bit == 0) {
                if (angle_scan_from <= i) {
                    var angle_end = i + 1;
                    while (angle_end < hi and text[angle_end] != '>') {
                        angle_end += escapedByteCount(text, angle_end, hi);
                    }
                    angle_scan_end = if (angle_end < hi) angle_end else null;
                    angle_scan_from = if (angle_end < hi) angle_end + 1 else hi;
                }
                if (angle_scan_end) |angle_end| {
                    stack[depth - 1] |= dirty_bit;
                    i = angle_end + 1;
                    continue;
                }
            }
        }
        if (open == '(' and depth > 0 and
            (text[i] == '"' or text[i] == '\'') and
            i > (stack[depth - 1] & index_mask) + 1 and isLinkWhitespace(text[i - 1]))
        {
            const quote = text[i];
            var quote_end = i + 1;
            while (quote_end < hi and text[quote_end] != quote) {
                quote_end += escapedByteCount(text, quote_end, hi);
            }
            if (quote_end < hi) {
                i = quote_end + 1;
                continue;
            }
        }
        if (open == '(' and depth > 0 and !isLinkWhitespace(text[i])) {
            stack[depth - 1] |= dirty_bit;
        }
        if (text[i] == open) {
            stack[depth] = i;
            depth += 1;
        } else if (text[i] == close and depth > 0) {
            depth -= 1;
            pairs[stack[depth] & index_mask] = i;
        }
        i += 1;
    }
}

fn prepareInlinePairs(
    pairs: []usize,
    stack: []usize,
    text: []const u8,
    lo: usize,
    hi: usize,
) void {
    pairDelimiters(pairs, stack, text, lo, hi, '[', ']');
    pairDelimiters(pairs, stack, text, lo, hi, '(', ')');
}

fn startsWithIgnoreCase(text: []const u8, index: usize, prefix: []const u8) bool {
    return index + prefix.len <= text.len and
        std.ascii.eqlIgnoreCase(text[index .. index + prefix.len], prefix);
}

fn autolinkBoundaryBefore(
    delimiter_roles: []const u8,
    text: []const u8,
    index: usize,
    lo: usize,
) bool {
    if (index == lo) return true;
    if (isUnicodeWhitespace(codepointBefore(text, index) orelse return false)) return true;
    return switch (text[index - 1]) {
        '(', '[', '{' => true,
        '*', '_', '~' => delimiter_roles[index - 1] & delimiter_opener != 0,
        else => false,
    };
}

fn autolinkBoundaryAfter(
    delimiter_roles: []const u8,
    text: []const u8,
    index: usize,
    hi: usize,
) bool {
    if (index == hi) return true;
    if (isUnicodeWhitespace(codepointAt(text, index) orelse return false)) return true;
    return switch (text[index]) {
        ')', '}', ']', '.', '!', '?', ',', ';' => true,
        '*', '_', '~' => delimiter_roles[index] & delimiter_closer != 0,
        else => false,
    };
}

fn scanAutolinkComponent(
    text: []const u8,
    start: usize,
    hi: usize,
    start_char: ?u8,
    delimiter: ?u8,
    allowed_inside: []const u8,
    allowed_anywhere: []const u8,
    minimum_components: usize,
    optional_end: ?u8,
) ?usize {
    var cursor = start;
    if (start_char) |byte| {
        if (cursor >= hi or text[cursor] != byte) return start;
        if (minimum_components > 0 and
            (cursor + 1 >= hi or !std.ascii.isAlphanumeric(text[cursor + 1])))
        {
            return start;
        }
        cursor += 1;
    }

    var components: usize = 0;
    var component_length: usize = 0;
    var paren_depth: usize = 0;
    while (cursor < hi) {
        const byte = text[cursor];
        if (std.ascii.isAlphanumeric(byte) or
            std.mem.indexOfScalar(u8, allowed_anywhere, byte) != null)
        {
            if (components == 0) components += 1;
            component_length += 1;
            cursor += 1;
        } else if (component_length > 0 and delimiter != null and byte == delimiter.? and
            cursor + 1 < hi and
            (std.ascii.isAlphanumeric(text[cursor + 1]) or
                std.mem.indexOfScalar(u8, allowed_anywhere, text[cursor + 1]) != null))
        {
            components += 1;
            component_length = 0;
            cursor += 1;
        } else if (std.mem.indexOfScalar(u8, allowed_inside, byte) != null and
            ((cursor > start and
                (std.ascii.isAlphanumeric(text[cursor - 1]) or text[cursor - 1] == ')')) or
                byte == '(') and
            ((cursor + 1 < hi and
                (std.ascii.isAlphanumeric(text[cursor + 1]) or text[cursor + 1] == '(')) or
                byte == ')'))
        {
            if (byte == '(') {
                paren_depth += 1;
            } else if (byte == ')') {
                if (paren_depth == 0) break;
                paren_depth -= 1;
            }
            component_length += 1;
            cursor += 1;
        } else {
            break;
        }
    }
    if (optional_end) |byte| {
        if (cursor < hi and text[cursor] == byte) cursor += 1;
    }
    if (components < minimum_components or paren_depth != 0) return null;
    return cursor;
}

fn scanUrlAutolink(text: []const u8, start: usize, prefix_len: usize, hi: usize) ?usize {
    var cursor = scanAutolinkComponent(
        text,
        start + prefix_len,
        hi,
        null,
        '.',
        ".-_",
        "",
        2,
        null,
    ) orelse return null;
    if (cursor < hi and text[cursor] == '/') {
        cursor = scanAutolinkComponent(
            text,
            cursor,
            hi,
            '/',
            '/',
            "/._",
            "+-",
            0,
            '/',
        ) orelse return null;
    }
    if (cursor < hi and text[cursor] == '?') {
        cursor = scanAutolinkComponent(
            text,
            cursor,
            hi,
            '?',
            '&',
            "&.-+_=()",
            "",
            1,
            null,
        ) orelse return null;
    }
    if (cursor < hi and text[cursor] == '#') {
        cursor = scanAutolinkComponent(
            text,
            cursor,
            hi,
            '#',
            null,
            ".-+_",
            "",
            1,
            null,
        ) orelse return null;
    }
    return cursor;
}

fn scanEmailAutolink(text: []const u8, start: usize, hi: usize) ?usize {
    if (!std.ascii.isAlphanumeric(text[start])) return null;
    var cursor = start + 1;
    while (cursor < hi) {
        if (std.ascii.isAlphanumeric(text[cursor])) {
            cursor += 1;
        } else if (std.mem.indexOfScalar(u8, ".-_+", text[cursor]) != null and
            cursor + 1 < hi and std.ascii.isAlphanumeric(text[cursor - 1]) and
            std.ascii.isAlphanumeric(text[cursor + 1]))
        {
            cursor += 1;
        } else {
            break;
        }
    }
    if (cursor >= hi or text[cursor] != '@') return null;
    return scanAutolinkComponent(
        text,
        cursor + 1,
        hi,
        null,
        '.',
        ".-_",
        "",
        2,
        null,
    );
}

fn scanAngleAutolink(text: []const u8, start: usize, hi: usize) ?usize {
    var close = start + 1;
    while (close < hi and text[close] != '>') {
        if (text[close] == '<' or
            isUnicodeWhitespace(codepointAt(text, close) orelse return null))
        {
            return null;
        }
        close += 1;
    }
    if (close >= hi) return null;

    const contents_start = start + 1;
    const contents_end = close;
    if (safeSourceUri(text[contents_start..contents_end])) {
        var scheme_end = contents_start + 1;
        while (scheme_end < contents_end and scheme_end - contents_start <= 31) {
            const byte = text[scheme_end];
            if (byte == ':' and scheme_end - contents_start >= 2) return close + 1;
            if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') {
                break;
            }
            scheme_end += 1;
        }
    }

    var cursor = contents_start;
    while (cursor < contents_end and
        (std.ascii.isAlphanumeric(text[cursor]) or
            std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", text[cursor]) != null))
    {
        cursor += 1;
    }
    if (cursor == contents_start or cursor >= contents_end or text[cursor] != '@') return null;
    cursor += 1;
    var label_length: usize = 0;
    while (cursor < contents_end) : (cursor += 1) {
        const byte = text[cursor];
        if (std.ascii.isAlphanumeric(byte)) {
            label_length += 1;
        } else if (byte == '-' and label_length > 0) {
            label_length += 1;
        } else if (byte == '.' and label_length > 0 and text[cursor - 1] != '-') {
            label_length = 0;
        } else {
            return null;
        }
        if (label_length > 63) return null;
    }
    if (label_length == 0 or text[contents_end - 1] == '-') return null;
    return close + 1;
}

fn markPermissiveAutolinks(
    flags: []u8,
    delimiter_roles: []const u8,
    delimiter_pairs: []const usize,
    link_states: []const u8,
    link_dest_ends: []const usize,
    text: []const u8,
    lo: usize,
    hi: usize,
) void {
    var cursor = lo;
    while (cursor < hi) {
        const label_open = if (text[cursor] == '[')
            cursor
        else if (text[cursor] == '!' and cursor + 1 < hi and text[cursor + 1] == '[')
            cursor + 1
        else
            null;
        if (label_open) |open_index| {
            if (link_states[open_index] != 0) {
                cursor = link_dest_ends[open_index] + 1;
                continue;
            }
        }
        if (text[cursor] == '(' and cursor > lo and text[cursor - 1] == ']' and
            delimiter_pairs[cursor] != std.math.maxInt(usize))
        {
            cursor = delimiter_pairs[cursor] + 1;
            continue;
        }
        if (text[cursor] == '\\') {
            cursor += escapedByteCount(text, cursor, hi);
            continue;
        }
        if (text[cursor] == '`') {
            cursor = findCodeSpanEnd(text, cursor, hi) orelse
                cursor + countRun(text, cursor, hi, '`');
            continue;
        }
        if (text[cursor] == '<') {
            if (scanAngleAutolink(text, cursor, hi)) |angle_end| {
                markRange(flags, cursor, angle_end, flag_link);
                cursor = angle_end;
                continue;
            }
        }
        if (autolinkBoundaryBefore(delimiter_roles, text, cursor, lo)) {
            var end: ?usize = null;
            if (startsWithIgnoreCase(text, cursor, "https://") or
                startsWithIgnoreCase(text, cursor, "http://"))
            {
                const prefix_len: usize = if (startsWithIgnoreCase(text, cursor, "https://")) 8 else 7;
                end = scanUrlAutolink(text, cursor, prefix_len, hi);
            } else if (startsWithIgnoreCase(text, cursor, "www.")) {
                end = scanUrlAutolink(text, cursor, 0, hi);
            } else if (std.ascii.isAlphanumeric(text[cursor])) {
                end = scanEmailAutolink(text, cursor, hi);
            }
            if (end) |link_end| {
                if (autolinkBoundaryAfter(delimiter_roles, text, link_end, hi)) {
                    markRange(flags, cursor, link_end, flag_link);
                    cursor = link_end;
                    continue;
                }
            }
        }
        cursor += 1;
    }
}

fn analyzeInlineRange(
    flags: []u8,
    delimiter_roles: []u8,
    delimiter_pairs: []usize,
    delimiter_stack: []usize,
    emphasis_openers: []EmphasisOpener,
    link_states: []u8,
    link_dest_ends: []usize,
    source: []const u8,
    start: usize,
    end: usize,
) void {
    if (start >= end) return;
    prepareInlinePairs(delimiter_pairs, delimiter_stack, source, start, end);
    prepareInlineLinks(
        link_states,
        link_dest_ends,
        delimiter_pairs,
        delimiter_stack,
        source,
        start,
        end,
    );
    scanInline(
        flags,
        delimiter_roles,
        delimiter_pairs,
        link_states,
        link_dest_ends,
        emphasis_openers,
        source,
        start,
        end,
        0,
    );
    markPermissiveAutolinks(
        flags,
        delimiter_roles,
        delimiter_pairs,
        link_states,
        link_dest_ends,
        source,
        start,
        end,
    );
}

fn linkCandidateAt(
    delimiter_pairs: []const usize,
    text: []const u8,
    hi: usize,
    label_open: usize,
) ?LinkCandidate {
    const label_close = delimiter_pairs[label_open];
    if (label_close == std.math.maxInt(usize) or
        label_close + 1 >= hi or
        text[label_close + 1] != '(')
    {
        return null;
    }
    const dest_end = delimiter_pairs[label_close + 1];
    const contents = if (dest_end != std.math.maxInt(usize))
        parseInlineLinkContents(text, label_close + 2, dest_end)
    else
        null;
    if (contents == null) return null;
    return .{
        .match = .{ .label_close = label_close, .dest_end = dest_end },
        .destination = contents.?.destination,
    };
}

fn prepareInlineLinks(
    link_states: []u8,
    link_dest_ends: []usize,
    delimiter_pairs: []const usize,
    next_valid_anchor: []usize,
    text: []const u8,
    lo: usize,
    hi: usize,
) void {
    const none: usize = std.math.maxInt(usize);
    var nearest_anchor: usize = none;
    var cursor = hi;
    while (cursor > lo) {
        cursor -= 1;
        next_valid_anchor[cursor] = nearest_anchor;
        if (text[cursor] != '[') continue;
        const candidate = linkCandidateAt(delimiter_pairs, text, hi, cursor) orelse continue;
        const image = isImageLabelOpen(text, cursor, lo);
        if (!image and nearest_anchor < candidate.match.label_close) continue;
        link_states[cursor] = if (safeSourceUri(candidate.destination)) 2 else 1;
        link_dest_ends[cursor] = candidate.match.dest_end;
        if (!image) nearest_anchor = cursor;
    }
}

fn linkAt(
    delimiter_pairs: []const usize,
    link_states: []const u8,
    link_dest_ends: []const usize,
    label_open: usize,
) ?LinkMatch {
    if (link_states[label_open] != 2) return null;
    return .{
        .label_close = delimiter_pairs[label_open],
        .dest_end = link_dest_ends[label_open],
    };
}

fn isEscapedAt(text: []const u8, index: usize, lo: usize) bool {
    if (index == lo) return false;
    var backslashes: usize = 0;
    var cursor = index;
    while (cursor > lo and text[cursor - 1] == '\\') {
        backslashes += 1;
        cursor -= 1;
    }
    return backslashes % 2 == 1;
}

fn isImageLabelOpen(text: []const u8, index: usize, lo: usize) bool {
    return index > lo and text[index - 1] == '!' and
        !isEscapedAt(text, index - 1, lo);
}

fn isLinkWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

const UriSafetyScan = struct {
    prefix: [8]u8 = @splat(0),
    prefix_len: usize = 0,
    total_len: usize = 0,
    safe: bool = true,

    fn feed(self: *UriSafetyScan, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte < 0x20 or byte == 0x7f) self.safe = false;
            if (self.prefix_len < self.prefix.len) {
                self.prefix[self.prefix_len] = byte;
                self.prefix_len += 1;
            }
            self.total_len += 1;
        }
    }

    fn feedCodepoint(self: *UriSafetyScan, codepoint: u32) void {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(
            normalizedCodepoint(codepoint),
            &buffer,
        ) catch return;
        self.feed(buffer[0..length]);
    }
};

fn feedSourceEntity(scan: *UriSafetyScan, entity: []const u8) void {
    if (entity.len > 3 and entity[0] == '&' and entity[1] == '#') {
        const hexadecimal = entity[2] == 'x' or entity[2] == 'X';
        const digits = entity[if (hexadecimal) 3 else 2 .. entity.len - 1];
        const codepoint = std.fmt.parseInt(
            u32,
            digits,
            if (hexadecimal) 16 else 10,
        ) catch {
            scan.feed(entity);
            return;
        };
        scan.feedCodepoint(codepoint);
        return;
    }

    const found = c.entity_lookup(entity.ptr, entity.len);
    if (found) |entry| {
        scan.feedCodepoint(entry[0].codepoints[0]);
        if (entry[0].codepoints[1] != 0) {
            scan.feedCodepoint(entry[0].codepoints[1]);
        }
    } else {
        scan.feed(entity);
    }
}

fn safeSourceUri(raw: []const u8) bool {
    var scan: UriSafetyScan = .{};
    var cursor: usize = 0;
    while (cursor < raw.len) {
        if (raw[cursor] == '\\' and escapedByteCount(raw, cursor, raw.len) == 2) {
            scan.feed(raw[cursor + 1 .. cursor + 2]);
            cursor += 2;
            continue;
        }
        if (raw[cursor] == '&') {
            const entity_limit = @min(raw.len, cursor + 51);
            if (std.mem.indexOfScalarPos(u8, raw[0..entity_limit], cursor + 1, ';')) |semicolon| {
                feedSourceEntity(&scan, raw[cursor .. semicolon + 1]);
                cursor = semicolon + 1;
                continue;
            }
        }
        scan.feed(raw[cursor .. cursor + 1]);
        cursor += 1;
    }
    if (!scan.safe) return false;

    const schemes = [_][]const u8{ "https://", "http://", "mailto:" };
    for (schemes) |scheme| {
        if (scan.total_len >= scheme.len and scan.prefix_len >= scheme.len and
            std.ascii.eqlIgnoreCase(scan.prefix[0..scheme.len], scheme))
        {
            return true;
        }
    }
    return false;
}

fn skipLinkWhitespace(text: []const u8, cursor: *usize, end: usize) void {
    while (cursor.* < end and isLinkWhitespace(text[cursor.*])) cursor.* += 1;
}

const InlineLinkContents = struct {
    destination: []const u8,
};

fn parseInlineLinkContents(text: []const u8, start: usize, end: usize) ?InlineLinkContents {
    var cursor = start;
    skipLinkWhitespace(text, &cursor, end);
    var destination: []const u8 = undefined;

    if (cursor < end and text[cursor] == '<') {
        cursor += 1;
        const destination_start = cursor;
        while (cursor < end and text[cursor] != '>') {
            if (text[cursor] == '\n' or text[cursor] == '\r' or text[cursor] == '<') return null;
            cursor += escapedByteCount(text, cursor, end);
        }
        if (cursor >= end) return null;
        destination = text[destination_start..cursor];
        cursor += 1;
    } else {
        const destination_start = cursor;
        var nesting_depth: usize = 0;
        while (cursor < end and !isLinkWhitespace(text[cursor])) {
            if (text[cursor] < 0x20) return null;
            const escaped_count = escapedByteCount(text, cursor, end);
            if (escaped_count == 2) {
                cursor += escaped_count;
                continue;
            }
            if (text[cursor] == '(') {
                nesting_depth += 1;
                if (nesting_depth > 32) return null;
            } else if (text[cursor] == ')') {
                if (nesting_depth == 0) return null;
                nesting_depth -= 1;
            }
            cursor += 1;
        }
        if (nesting_depth != 0) return null;
        destination = text[destination_start..cursor];
    }

    if (cursor == end) return .{ .destination = destination };
    const whitespace_start = cursor;
    skipLinkWhitespace(text, &cursor, end);
    if (cursor == whitespace_start) return null;
    if (cursor == end) return .{ .destination = destination };

    const title_close: u8 = switch (text[cursor]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    cursor += 1;
    while (cursor < end and text[cursor] != title_close) {
        cursor += escapedByteCount(text, cursor, end);
    }
    if (cursor >= end) return null;
    cursor += 1;
    skipLinkWhitespace(text, &cursor, end);
    if (cursor != end) return null;
    return .{ .destination = destination };
}

fn lineSpan(text: []const u8, from: usize) struct { end: usize, next: usize } {
    const newline = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
    var end = newline;
    if (end > from and text[end - 1] == '\r') end -= 1;
    return .{ .end = end, .next = newline +| 1 };
}

fn validFenceOpener(source: []const u8, body: usize, line_end: usize, marker: u8) bool {
    const run = countRun(source, body, line_end, marker);
    if (run < 3) return false;
    return marker != '`' or
        std.mem.indexOfScalar(u8, source[body + run .. line_end], '`') == null;
}

const LeadingIndent = struct {
    bytes: usize,
    columns: usize,
};

fn leadingIndent(source: []const u8, pos: usize, line_end: usize) LeadingIndent {
    var cursor = pos;
    var columns: usize = 0;
    while (cursor < line_end) : (cursor += 1) {
        switch (source[cursor]) {
            ' ' => columns += 1,
            '\t' => columns = (columns + 4) & ~@as(usize, 3),
            else => break,
        }
    }
    return .{ .bytes = cursor - pos, .columns = columns };
}

fn isSetextUnderline(source: []const u8, pos: usize, line_end: usize) bool {
    const indent = leadingIndent(source, pos, line_end);
    if (indent.columns > 3 or pos + indent.bytes >= line_end) return false;
    const marker = source[pos + indent.bytes];
    if (marker != '=' and marker != '-') return false;
    var count: usize = 0;
    for (source[pos + indent.bytes .. line_end]) |byte| {
        if (byte == marker) {
            count += 1;
        } else if (byte != ' ' and byte != '\t') {
            return false;
        }
    }
    return count > 0;
}

fn isThematicLine(source: []const u8, body: usize, line_end: usize) bool {
    if (body >= line_end) return false;
    const marker = source[body];
    if (marker != '*' and marker != '-' and marker != '_') return false;
    var count: usize = 0;
    var cursor = body;
    while (cursor < line_end) : (cursor += 1) {
        if (source[cursor] == marker) {
            count += 1;
        } else if (source[cursor] != ' ' and source[cursor] != '\t') {
            return false;
        }
    }
    return count >= 3;
}

fn startsParagraphInterrupt(source: []const u8, pos: usize, line_end: usize) bool {
    const indent = leadingIndent(source, pos, line_end);
    const body = pos + indent.bytes;
    if (body >= line_end or indent.columns >= 4) return false;

    if (source[body] == '>') return true;

    if (source[body] == '-' or source[body] == '+' or source[body] == '*') {
        if (body + 1 < line_end and
            (source[body + 1] == ' ' or source[body + 1] == '\t'))
        {
            return true;
        }
    }

    var digits_end = body;
    while (digits_end < line_end and digits_end - body < 9 and
        std.ascii.isDigit(source[digits_end]))
    {
        digits_end += 1;
    }
    if (digits_end > body and digits_end < line_end and
        (source[digits_end] == '.' or source[digits_end] == ')') and
        digits_end + 1 < line_end and
        (source[digits_end + 1] == ' ' or source[digits_end + 1] == '\t'))
    {
        var list_start: usize = 0;
        for (source[body..digits_end]) |digit| {
            list_start = list_start * 10 + digit - '0';
        }
        return list_start == 1;
    }

    return isThematicLine(source, body, line_end);
}

fn startsListItem(source: []const u8, pos: usize, line_end: usize) bool {
    const indent = leadingIndent(source, pos, line_end);
    const body = pos + indent.bytes;
    if (body >= line_end or indent.columns >= 4 or isThematicLine(source, body, line_end)) {
        return false;
    }
    if (source[body] == '-' or source[body] == '+' or source[body] == '*') {
        return body + 1 < line_end and
            (source[body + 1] == ' ' or source[body + 1] == '\t');
    }
    var digits_end = body;
    while (digits_end < line_end and digits_end - body < 9 and
        std.ascii.isDigit(source[digits_end]))
    {
        digits_end += 1;
    }
    return digits_end > body and digits_end < line_end and
        (source[digits_end] == '.' or source[digits_end] == ')') and
        digits_end + 1 < line_end and
        (source[digits_end + 1] == ' ' or source[digits_end + 1] == '\t');
}

fn startsQuoteLine(source: []const u8, pos: usize, line_end: usize) bool {
    const indent = leadingIndent(source, pos, line_end);
    const body = pos + indent.bytes;
    return body < line_end and indent.columns < 4 and source[body] == '>';
}

fn quoteLineHasContent(source: []const u8, pos: usize, line_end: usize) bool {
    const indent = leadingIndent(source, pos, line_end);
    var body = pos + indent.bytes + 1;
    if (body < line_end and (source[body] == ' ' or source[body] == '\t')) body += 1;
    return body < line_end;
}

const InlineContainer = enum {
    plain,
    list,
    quote,
};

/// Analyzes Markdown source without rewriting any bytes: returned spans
/// cover the original text (syntax markers included) so a live editor can
/// style its buffer in place while cursor and wrap offsets stay exact.
pub fn analyzeSource(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]SourceSpan {
    if (source.len == 0) return &.{};
    const flags = try allocator.alloc(u8, source.len);
    defer allocator.free(flags);
    @memset(flags, 0);
    const delimiter_roles = try allocator.alloc(u8, source.len);
    defer allocator.free(delimiter_roles);
    @memset(delimiter_roles, 0);
    const delimiter_pairs = try allocator.alloc(usize, source.len);
    defer allocator.free(delimiter_pairs);
    @memset(delimiter_pairs, std.math.maxInt(usize));
    const delimiter_stack = try allocator.alloc(usize, source.len);
    defer allocator.free(delimiter_stack);
    const emphasis_openers = try allocator.alloc(EmphasisOpener, source.len);
    defer allocator.free(emphasis_openers);
    const link_states = try allocator.alloc(u8, source.len);
    defer allocator.free(link_states);
    @memset(link_states, 0);
    const link_dest_ends = try allocator.alloc(usize, source.len);
    defer allocator.free(link_dest_ends);
    @memset(link_dest_ends, std.math.maxInt(usize));

    var fence: u8 = 0;
    var fence_len: usize = 0;
    var inline_start: ?usize = null;
    var inline_container: InlineContainer = .plain;
    var pos: usize = 0;
    while (pos < source.len) {
        const line = lineSpan(source, pos);
        const indent = leadingIndent(source, pos, line.end);
        const body = pos + indent.bytes;

        if (fence != 0) {
            markRange(flags, pos, line.end, flag_code);
            if (indent.columns <= 3 and body < line.end and source[body] == fence) {
                const run = countRun(source, body, line.end, fence);
                if (run >= fence_len) {
                    // A closing fence may only be followed by whitespace; text
                    // like ```not-a-close keeps the block open, as md4c does.
                    var trailing_ok = true;
                    var closer = body + run;
                    while (closer < line.end) : (closer += 1) {
                        if (source[closer] != ' ' and source[closer] != '\t') {
                            trailing_ok = false;
                            break;
                        }
                    }
                    if (trailing_ok) fence = 0;
                }
            }
        } else if (body == line.end) {
            if (inline_start) |start| {
                analyzeInlineRange(
                    flags,
                    delimiter_roles,
                    delimiter_pairs,
                    delimiter_stack,
                    emphasis_openers,
                    link_states,
                    link_dest_ends,
                    source,
                    start,
                    pos,
                );
                inline_start = null;
            }
        } else if (indent.columns <= 3 and
            (source[body] == '`' or source[body] == '~') and
            validFenceOpener(source, body, line.end, source[body]))
        {
            if (inline_start) |start| {
                analyzeInlineRange(
                    flags,
                    delimiter_roles,
                    delimiter_pairs,
                    delimiter_stack,
                    emphasis_openers,
                    link_states,
                    link_dest_ends,
                    source,
                    start,
                    pos,
                );
                inline_start = null;
            }
            fence = source[body];
            fence_len = countRun(source, body, line.end, source[body]);
            markRange(flags, pos, line.end, flag_code);
        } else if (inline_start != null and inline_container == .plain and
            isSetextUnderline(source, pos, line.end))
        {
            const start = inline_start.?;
            analyzeInlineRange(
                flags,
                delimiter_roles,
                delimiter_pairs,
                delimiter_stack,
                emphasis_openers,
                link_states,
                link_dest_ends,
                source,
                start,
                pos,
            );
            markRange(flags, start, line.end, flag_heading);
            inline_start = null;
        } else if (inline_start == null and indent.columns >= 4) {
            markRange(flags, pos, line.end, flag_code);
        } else if (startsParagraphInterrupt(source, pos, line.end)) {
            const quote_line = startsQuoteLine(source, pos, line.end);
            const quote_has_content = !quote_line or quoteLineHasContent(source, pos, line.end);
            if (!(quote_line and quote_has_content and
                inline_start != null and inline_container == .quote))
            {
                if (inline_start) |start| {
                    analyzeInlineRange(
                        flags,
                        delimiter_roles,
                        delimiter_pairs,
                        delimiter_stack,
                        emphasis_openers,
                        link_states,
                        link_dest_ends,
                        source,
                        start,
                        pos,
                    );
                    inline_start = null;
                }
                if ((quote_line and quote_has_content) or startsListItem(source, pos, line.end)) {
                    inline_start = pos;
                    inline_container = if (quote_line) .quote else .list;
                } else if (!quote_line) {
                    analyzeInlineRange(
                        flags,
                        delimiter_roles,
                        delimiter_pairs,
                        delimiter_stack,
                        emphasis_openers,
                        link_states,
                        link_dest_ends,
                        source,
                        pos,
                        line.end,
                    );
                }
            }
        } else if (indent.columns <= 3 and source[body] == '#') {
            const hashes = countRun(source, body, line.end, '#');
            const at_end = body + hashes >= line.end;
            const next = if (at_end) '\n' else source[body + hashes];
            if (hashes >= 1 and hashes <= 6 and (at_end or next == ' ' or next == '\t')) {
                if (inline_start) |start| {
                    analyzeInlineRange(
                        flags,
                        delimiter_roles,
                        delimiter_pairs,
                        delimiter_stack,
                        emphasis_openers,
                        link_states,
                        link_dest_ends,
                        source,
                        start,
                        pos,
                    );
                    inline_start = null;
                }
                var heading_contents = body + hashes;
                while (heading_contents < line.end and
                    (source[heading_contents] == ' ' or source[heading_contents] == '\t'))
                {
                    heading_contents += 1;
                }
                analyzeInlineRange(
                    flags,
                    delimiter_roles,
                    delimiter_pairs,
                    delimiter_stack,
                    emphasis_openers,
                    link_states,
                    link_dest_ends,
                    source,
                    heading_contents,
                    line.end,
                );
                markRange(flags, pos, line.end, flag_heading);
            } else {
                if (inline_start == null) {
                    inline_start = pos;
                    inline_container = .plain;
                }
            }
        } else {
            if (inline_start == null) inline_start = pos;
        }
        pos = line.next;
    }
    if (inline_start) |start| {
        analyzeInlineRange(
            flags,
            delimiter_roles,
            delimiter_pairs,
            delimiter_stack,
            emphasis_openers,
            link_states,
            link_dest_ends,
            source,
            start,
            source.len,
        );
    }

    var spans: std.ArrayList(SourceSpan) = .empty;
    errdefer spans.deinit(allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (flags[i] == 0) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        // Include UTF-8 continuation bytes so spans never split a code point.
        while (i < source.len and
            (flags[i] == flags[start] or (source[i] & 0xc0) == 0x80)) i += 1;
        try spans.append(allocator, .{
            .start = start,
            .end = i,
            .style = styleFromFlags(flags[start]),
        });
    }
    return spans.toOwnedSlice(allocator);
}

fn syntaxColor(token: highlight.Token) vaxis.Color {
    return switch (token) {
        .comment => .{ .rgb = .{ 148, 163, 184 } },
        .string => .{ .rgb = .{ 134, 239, 172 } },
        .number, .constant => .{ .rgb = .{ 253, 186, 116 } },
        .keyword => .{ .rgb = .{ 196, 181, 253 } },
        .function => .{ .rgb = .{ 125, 211, 252 } },
        .property => .{ .rgb = .{ 253, 224, 71 } },
        .operator => .{ .rgb = .{ 244, 114, 182 } },
        .inserted => .{ .rgb = .{ 134, 239, 172 } },
        .deleted => .{ .rgb = .{ 251, 113, 133 } },
        .meta => .{ .rgb = .{ 125, 211, 252 } },
    };
}

const ListState = struct {
    ordered: bool,
    next: u32,
    tight: bool,
};

const Table = struct {
    columns: usize,
    header_rows: usize,
    first_prefix: Line = .{},
    continuation_prefix: Line = .{},
    emitted_lines: usize = 0,
    rows: std.ArrayList(Row) = .empty,

    const Alignment = enum {
        left,
        center,
        right,
    };

    const Cell = struct {
        line: Line = .{},
        alignment: Alignment = .left,

        fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
            self.line.deinit(allocator);
        }
    };

    const Row = struct {
        cells: std.ArrayList(Cell) = .empty,

        fn deinit(self: *Row, allocator: std.mem.Allocator) void {
            for (self.cells.items) |*cell| cell.deinit(allocator);
            self.cells.deinit(allocator);
        }
    };

    fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.first_prefix.deinit(allocator);
        self.continuation_prefix.deinit(allocator);
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        self.* = undefined;
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    cache_allocator: std.mem.Allocator,
    window: vaxis.Window,
    width: u16,
    lines: std.ArrayList(Line) = .empty,
    current: ?Line = null,
    lists: std.ArrayList(ListState) = .empty,
    list_item_indents: std.ArrayList(u16) = .empty,
    quote_depth: u16 = 0,
    pending_list_prefix: ?[]u8 = null,
    style: Style = .{},
    italic_depth: u16 = 0,
    bold_depth: u16 = 0,
    code_depth: u16 = 0,
    strikethrough_depth: u16 = 0,
    heading_level: u8 = 0,
    code_block: bool = false,
    code_language: ?highlight.Language = null,
    code_source: std.ArrayList(u8) = .empty,
    highlight_cache: ?*HighlightCache = null,
    code_block_index: usize = 0,
    current_code_block_index: usize = 0,
    link_stack: std.ArrayList(?[]u8) = .empty,
    table: ?Table = null,
    current_row: ?Table.Row = null,
    current_cell: ?Table.Cell = null,
    failure: ?anyerror = null,

    fn deinit(self: *Builder) void {
        if (self.current) |*line| line.deinit(self.allocator);
        for (self.lines.items) |*line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.lists.deinit(self.allocator);
        self.list_item_indents.deinit(self.allocator);
        self.code_source.deinit(self.allocator);
        if (self.pending_list_prefix) |prefix| self.allocator.free(prefix);
        for (self.link_stack.items) |uri| {
            if (uri) |value| self.allocator.free(value);
        }
        self.link_stack.deinit(self.allocator);
        if (self.current_cell) |*cell| cell.deinit(self.allocator);
        if (self.current_row) |*row| row.deinit(self.allocator);
        if (self.table) |*table| table.deinit(self.allocator);
    }

    fn fail(self: *Builder, err: anyerror) c_int {
        self.failure = err;
        return 1;
    }

    fn activeUri(self: *const Builder) ?[]const u8 {
        if (self.link_stack.items.len == 0) return null;
        return self.link_stack.items[self.link_stack.items.len - 1];
    }

    fn ensureLine(self: *Builder) !*Line {
        if (self.table != null) {
            if (self.current_cell == null) self.current_cell = .{};
            return &self.current_cell.?.line;
        }
        if (self.current == null) {
            self.current = .{ .code = self.code_block };
            const line = &self.current.?;
            var indent: u16 = 0;
            for (0..self.quote_depth) |_| {
                try line.append(
                    self.allocator,
                    "│ ",
                    .{ .italic = true },
                    null,
                );
                indent +|= 2;
            }
            if (self.pending_list_prefix) |prefix| {
                try line.append(self.allocator, prefix, .{}, null);
                indent +|= self.window.gwidth(prefix);
                self.allocator.free(prefix);
                self.pending_list_prefix = null;
            } else if (self.list_item_indents.items.len > 0) {
                const item_indent =
                    self.list_item_indents.items[self.list_item_indents.items.len - 1];
                try appendIndent(self.allocator, line, item_indent);
                indent +|= item_indent;
            }
            if (self.code_block) {
                try line.append(
                    self.allocator,
                    "  ",
                    .{ .code = true },
                    null,
                );
                indent +|= 2;
            }
            line.leading_width = indent;
            line.continuation_indent = indent;
        }
        return &self.current.?;
    }

    fn appendText(self: *Builder, text: []const u8) !void {
        if (text.len == 0) return;
        if (!self.code_block) {
            const line = try self.ensureLine();
            try line.append(
                self.allocator,
                text,
                self.style,
                self.activeUri(),
            );
            return;
        }
        try self.code_source.appendSlice(self.allocator, text);
    }

    fn flushCodeBlock(self: *Builder) !void {
        const raw_source = self.code_source.items;
        var owned_code: ?FragmentCode = null;
        defer if (owned_code) |*code| code.deinit(self.allocator);
        const code: HighlightCache.Code =
            if (self.code_language) |language|
                if (self.highlight_cache) |cache|
                    try cache.codeFor(
                        self.cache_allocator,
                        self.current_code_block_index,
                        language,
                        raw_source,
                    )
                else blk: {
                    owned_code = try fragmentCode(
                        self.allocator,
                        language,
                        raw_source,
                    );
                    break :blk .{
                        .text = owned_code.?.text,
                        .spans = owned_code.?.spans,
                    };
                }
            else
                .{ .text = raw_source, .spans = &.{} };
        const source = code.text;
        const highlighted = code.spans;

        var line_start: usize = 0;
        while (line_start < source.len) {
            const newline = std.mem.indexOfScalarPos(
                u8,
                source,
                line_start,
                '\n',
            );
            const line_end = newline orelse source.len;
            const line = try self.ensureLine();
            try self.appendCodeRange(
                line,
                source,
                highlighted,
                line_start,
                line_end,
            );
            if (newline == null) break;
            self.finishLine();
            line_start = line_end + 1;
        }
        self.code_source.clearRetainingCapacity();
    }

    fn appendCodeRange(
        self: *Builder,
        line: *Line,
        source: []const u8,
        highlighted: []const highlight.Span,
        start: usize,
        end: usize,
    ) !void {
        if (highlighted.len == 0) {
            try line.append(
                self.allocator,
                source[start..end],
                self.style,
                self.activeUri(),
            );
            return;
        }

        var offset = start;
        for (highlighted) |span| {
            if (span.end <= start) continue;
            if (span.start >= end) break;
            const span_start = @max(span.start, start);
            const span_end = @min(span.end, end);
            if (offset < span_start) {
                try line.append(
                    self.allocator,
                    source[offset..span_start],
                    self.style,
                    self.activeUri(),
                );
            }
            var style = self.style;
            style.syntax = span.token;
            try line.append(
                self.allocator,
                source[span_start..span_end],
                style,
                self.activeUri(),
            );
            offset = span_end;
        }
        if (offset < end) {
            try line.append(
                self.allocator,
                source[offset..end],
                self.style,
                self.activeUri(),
            );
        }
    }

    fn appendLiteral(
        self: *Builder,
        text: []const u8,
        style: Style,
    ) !void {
        const line = try self.ensureLine();
        try line.append(self.allocator, text, style, null);
    }

    fn finishLine(self: *Builder) void {
        if (self.table != null) return;
        if (self.current) |line| {
            self.lines.append(self.allocator, line) catch |err| {
                var mutable = line;
                mutable.deinit(self.allocator);
                self.failure = err;
            };
            self.current = null;
        }
    }

    fn appendBlank(self: *Builder) !void {
        self.finishLine();
        if (self.failure != null) return self.failure.?;
        if (self.lines.items.len == 0 or
            self.lines.items[self.lines.items.len - 1].segments.items.len != 0)
        {
            try self.lines.append(self.allocator, .{});
        }
    }

    fn finishDocument(self: *Builder) !void {
        self.finishLine();
        if (self.failure) |failure| return failure;
        while (self.lines.items.len > 0 and
            self.lines.items[self.lines.items.len - 1].segments.items.len == 0)
        {
            var line = self.lines.pop().?;
            line.deinit(self.allocator);
        }
        if (self.lines.items.len == 0) try self.lines.append(self.allocator, .{});
    }

    fn wrapRangeInto(
        self: *Builder,
        allocator: std.mem.Allocator,
        destination: *std.ArrayList(Line),
        first_row: usize,
        last_row: usize,
    ) !usize {
        var sink = LineSink{
            .allocator = allocator,
            .destination = destination,
            .first = first_row,
            .last = last_row,
        };
        for (self.lines.items) |*line| {
            try wrapLine(
                allocator,
                self.window,
                self.width,
                line,
                &sink,
            );
        }
        return sink.index;
    }

    fn beginListItem(self: *Builder, detail: ?*anyopaque) !void {
        self.finishLine();
        if (self.failure != null) return self.failure.?;
        if (self.pending_list_prefix != null) {
            _ = try self.ensureLine();
            self.finishLine();
            if (self.failure != null) return self.failure.?;
        }
        var prefix: []u8 = undefined;
        const list = &self.lists.items[self.lists.items.len - 1];
        const item: *const c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail.?));
        if (list.ordered) {
            if (item.is_task != 0) {
                prefix = try std.fmt.allocPrint(
                    self.allocator,
                    "{d}. {s} ",
                    .{
                        list.next,
                        if (item.task_mark == 'x' or item.task_mark == 'X')
                            "☑"
                        else
                            "☐",
                    },
                );
            } else {
                prefix = try std.fmt.allocPrint(
                    self.allocator,
                    "{d}. ",
                    .{list.next},
                );
            }
            list.next += 1;
        } else if (item.is_task != 0) {
            prefix = try std.fmt.allocPrint(
                self.allocator,
                "{s} ",
                .{if (item.task_mark == 'x' or item.task_mark == 'X')
                    "☑"
                else
                    "☐"},
            );
        } else {
            prefix = try self.allocator.dupe(u8, "• ");
        }
        const nesting = (self.lists.items.len - 1) * 2;
        if (nesting > 0) {
            const spaces = try self.allocator.alloc(u8, nesting);
            defer self.allocator.free(spaces);
            @memset(spaces, ' ');
            const nested = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ spaces, prefix },
            );
            self.allocator.free(prefix);
            prefix = nested;
        }
        try self.list_item_indents.append(
            self.allocator,
            self.window.gwidth(prefix),
        );
        self.pending_list_prefix = prefix;
    }

    fn beginTable(self: *Builder, detail: ?*anyopaque) !void {
        self.finishLine();
        if (self.failure != null) return self.failure.?;
        const info: *const c.MD_BLOCK_TABLE_DETAIL =
            @ptrCast(@alignCast(detail.?));
        var table = Table{
            .columns = info.col_count,
            .header_rows = info.head_row_count,
        };
        errdefer table.deinit(self.allocator);
        var indent: u16 = 0;
        for (0..self.quote_depth) |_| {
            try table.first_prefix.append(
                self.allocator,
                "│ ",
                .{ .italic = true },
                null,
            );
            try table.continuation_prefix.append(
                self.allocator,
                "│ ",
                .{ .italic = true },
                null,
            );
            indent +|= 2;
        }
        if (self.pending_list_prefix) |prefix| {
            try table.first_prefix.append(self.allocator, prefix, .{}, null);
            const prefix_width = self.window.gwidth(prefix);
            try appendIndent(
                self.allocator,
                &table.continuation_prefix,
                prefix_width,
            );
            indent +|= prefix_width;
            self.allocator.free(prefix);
            self.pending_list_prefix = null;
        } else if (self.list_item_indents.items.len > 0) {
            const item_indent =
                self.list_item_indents.items[self.list_item_indents.items.len - 1];
            try appendIndent(self.allocator, &table.first_prefix, item_indent);
            try appendIndent(
                self.allocator,
                &table.continuation_prefix,
                item_indent,
            );
            indent +|= item_indent;
        }
        table.first_prefix.leading_width = indent;
        table.first_prefix.continuation_indent = indent;
        table.continuation_prefix.leading_width = indent;
        table.continuation_prefix.continuation_indent = indent;
        self.table = table;
    }

    fn finishCell(self: *Builder) !void {
        var row = &self.current_row.?;
        try row.cells.append(self.allocator, self.current_cell orelse .{});
        self.current_cell = null;
    }

    fn beginCell(self: *Builder, detail: ?*anyopaque) void {
        const info: *const c.MD_BLOCK_TD_DETAIL =
            @ptrCast(@alignCast(detail.?));
        self.current_cell = .{
            .alignment = switch (info.@"align") {
                c.MD_ALIGN_CENTER => .center,
                c.MD_ALIGN_RIGHT => .right,
                else => .left,
            },
        };
    }

    fn finishRow(self: *Builder) !void {
        var table = &self.table.?;
        try table.rows.append(self.allocator, self.current_row orelse .{});
        self.current_row = null;
    }

    fn finishTable(self: *Builder) !void {
        var table = self.table.?;
        self.table = null;
        defer table.deinit(self.allocator);

        var widths = try self.allocator.alloc(u16, table.columns);
        defer self.allocator.free(widths);
        @memset(widths, 0);
        for (table.rows.items) |row| {
            for (row.cells.items, 0..) |cell, column| {
                if (column >= widths.len) break;
                widths[column] = @max(
                    widths[column],
                    lineWidth(self.window, cell.line),
                );
            }
        }
        var grid_width: usize = 1;
        for (widths) |cell_width| grid_width += cell_width + 3;
        grid_width += lineWidth(self.window, table.continuation_prefix);
        if (grid_width <= self.width) {
            try self.renderGridTable(&table, widths);
        } else {
            try self.renderStackedTable(&table);
        }
        try self.appendBlank();
    }

    fn renderGridTable(
        self: *Builder,
        table: *Table,
        widths: []const u16,
    ) !void {
        try self.appendTableBorder(table, widths, "┌", "┬", "┐", "─");
        for (table.rows.items, 0..) |row, row_index| {
            try self.beginTableLine(table, true);
            try self.appendLiteral("│ ", .{});
            for (0..table.columns) |column| {
                if (column > 0) try self.appendLiteral(" ", .{});
                if (column < row.cells.items.len) {
                    const cell = row.cells.items[column];
                    const used = lineWidth(self.window, cell.line);
                    const padding = widths[column] -| used;
                    const left_padding: u16 = switch (cell.alignment) {
                        .left => 0,
                        .center => padding / 2,
                        .right => padding,
                    };
                    try self.appendPadding(left_padding);
                    for (cell.line.segments.items) |segment| {
                        var style = segment.style;
                        if (row_index < table.header_rows) style.bold = true;
                        const line = try self.ensureLine();
                        try line.append(
                            self.allocator,
                            segment.text,
                            style,
                            segment.uri,
                        );
                    }
                    try self.appendPadding(padding - left_padding);
                } else {
                    try self.appendPadding(widths[column]);
                }
                try self.appendLiteral(" │", .{});
            }
            self.finishLine();
            if (row_index + 1 == table.header_rows) {
                try self.appendTableBorder(
                    table,
                    widths,
                    "├",
                    "┼",
                    "┤",
                    "─",
                );
            }
        }
        try self.appendTableBorder(table, widths, "└", "┴", "┘", "─");
    }

    fn appendTableBorder(
        self: *Builder,
        table: *Table,
        widths: []const u16,
        left: []const u8,
        middle: []const u8,
        right: []const u8,
        horizontal: []const u8,
    ) !void {
        try self.beginTableLine(table, true);
        try self.appendLiteral(left, .{ .bold = true });
        for (widths, 0..) |cell_width, column| {
            try self.appendLiteral("─", .{ .bold = true });
            for (0..cell_width) |_| {
                try self.appendLiteral(horizontal, .{ .bold = true });
            }
            try self.appendLiteral("─", .{ .bold = true });
            try self.appendLiteral(
                if (column + 1 == widths.len) right else middle,
                .{ .bold = true },
            );
        }
        self.finishLine();
    }

    fn beginTableLine(
        self: *Builder,
        table: *Table,
        code: bool,
    ) !void {
        self.current = .{ .code = code };
        const prefix = if (table.emitted_lines == 0)
            table.first_prefix
        else
            table.continuation_prefix;
        for (prefix.segments.items) |segment| {
            const line = &self.current.?;
            try line.append(
                self.allocator,
                segment.text,
                segment.style,
                segment.uri,
            );
        }
        self.current.?.leading_width = prefix.leading_width;
        self.current.?.continuation_indent = prefix.continuation_indent;
        table.emitted_lines += 1;
    }

    fn appendPadding(self: *Builder, count: u16) !void {
        for (0..count) |_| try self.appendLiteral(" ", .{});
    }

    fn renderStackedTable(self: *Builder, table: *Table) !void {
        if (table.rows.items.len <= table.header_rows) {
            for (table.rows.items) |row| {
                for (row.cells.items) |cell| {
                    try self.beginTableLine(table, false);
                    for (cell.line.segments.items) |segment| {
                        var style = segment.style;
                        style.bold = true;
                        const line = try self.ensureLine();
                        try line.append(
                            self.allocator,
                            segment.text,
                            style,
                            segment.uri,
                        );
                    }
                    self.finishLine();
                }
            }
            return;
        }

        const headers = table.rows.items[0];
        for (table.rows.items[table.header_rows..], 0..) |row, row_index| {
            for (0..table.columns) |column| {
                try self.beginTableLine(table, false);
                if (column < headers.cells.items.len) {
                    for (headers.cells.items[column].line.segments.items) |segment| {
                        var style = segment.style;
                        style.bold = true;
                        const line = try self.ensureLine();
                        try line.append(
                            self.allocator,
                            segment.text,
                            style,
                            segment.uri,
                        );
                    }
                } else {
                    try self.appendLiteral("Column", .{ .bold = true });
                }
                try self.appendLiteral(": ", .{ .bold = true });
                if (column < row.cells.items.len) {
                    for (row.cells.items[column].line.segments.items) |segment| {
                        const line = try self.ensureLine();
                        try line.append(
                            self.allocator,
                            segment.text,
                            segment.style,
                            segment.uri,
                        );
                    }
                }
                self.finishLine();
            }
            if (row_index + 1 < table.rows.items.len - table.header_rows) {
                try self.appendBlank();
            }
        }
    }
};

fn lineWidth(window: vaxis.Window, line: Line) u16 {
    var width: u16 = 0;
    for (line.segments.items) |segment| width +|= window.gwidth(segment.text);
    return width;
}

const LineSink = struct {
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(Line),
    first: usize,
    last: usize,
    index: usize = 0,

    fn append(self: *LineSink, line: Line) !void {
        var owned = line;
        defer self.index += 1;
        if (self.index < self.first or self.index >= self.last) {
            owned.deinit(self.allocator);
            return;
        }
        try self.destination.append(self.allocator, owned);
    }
};

fn wrapLine(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    width: u16,
    source: *const Line,
    destination: *LineSink,
) !void {
    if (source.code) {
        return wrapLineByGrapheme(
            allocator,
            window,
            width,
            source,
            destination,
        );
    }

    var output: Line = .{ .code = source.code };
    errdefer output.deinit(allocator);
    var line_width: u16 = 0;
    var previous_was_whitespace = false;

    for (source.segments.items) |segment| {
        var index: usize = 0;
        while (index < segment.text.len) {
            if (isWrapWhitespace(segment.text[index])) {
                const whitespace_start = index;
                while (index < segment.text.len and
                    isWrapWhitespace(segment.text[index]))
                {
                    index += 1;
                }
                if (line_width < source.leading_width) {
                    const whitespace = segment.text[whitespace_start..index];
                    try output.append(
                        allocator,
                        whitespace,
                        segment.style,
                        segment.uri,
                    );
                    line_width +|= window.gwidth(whitespace);
                    continue;
                }
                if (line_width > 0 and !previous_was_whitespace) {
                    try output.append(
                        allocator,
                        " ",
                        segment.style,
                        segment.uri,
                    );
                    line_width +|= 1;
                    previous_was_whitespace = true;
                }
                continue;
            }

            const word_start = index;
            while (index < segment.text.len and
                !isWrapWhitespace(segment.text[index]))
            {
                index += 1;
            }
            const word = segment.text[word_start..index];
            const word_width = window.gwidth(word);
            if (previous_was_whitespace and
                line_width > source.continuation_indent and
                line_width +| word_width > width)
            {
                removeTrailingWhitespace(&output, allocator);
                try destination.append(output);
                output = .{ .code = source.code };
                const first_grapheme_width = firstGraphemeWidth(window, word);
                const continuation_indent = fitContinuationIndent(
                    width,
                    source.continuation_indent,
                    first_grapheme_width,
                );
                try appendIndent(
                    allocator,
                    &output,
                    continuation_indent,
                );
                line_width = continuation_indent;
            }
            previous_was_whitespace = false;
            try appendGraphemeWrapped(
                allocator,
                window,
                width,
                &output,
                &line_width,
                source.continuation_indent,
                destination,
                word,
                segment.style,
                segment.uri,
            );
        }
    }
    removeTrailingWhitespace(&output, allocator);
    try destination.append(output);
}

fn wrapLineByGrapheme(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    width: u16,
    source: *const Line,
    destination: *LineSink,
) !void {
    var output: Line = .{ .code = true };
    errdefer output.deinit(allocator);
    var line_width: u16 = 0;

    for (source.segments.items) |segment| {
        try appendGraphemeWrapped(
            allocator,
            window,
            width,
            &output,
            &line_width,
            source.continuation_indent,
            destination,
            segment.text,
            segment.style,
            segment.uri,
        );
    }
    try destination.append(output);
}

fn appendGraphemeWrapped(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    width: u16,
    output: *Line,
    line_width: *u16,
    continuation_indent: u16,
    destination: *LineSink,
    text: []const u8,
    style: Style,
    uri: ?[]const u8,
) !void {
    var iterator = vaxis.unicode.graphemeIterator(text);
    var run_start: usize = 0;
    while (iterator.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const grapheme_width = window.gwidth(bytes);
        if (line_width.* > 0 and line_width.* +| grapheme_width > width) {
            if (grapheme.start > run_start) {
                try output.append(
                    allocator,
                    text[run_start..grapheme.start],
                    style,
                    uri,
                );
            }
            try destination.append(output.*);
            output.* = .{ .code = output.code };
            const fitted_indent = fitContinuationIndent(
                width,
                continuation_indent,
                grapheme_width,
            );
            try appendIndent(allocator, output, fitted_indent);
            line_width.* = fitted_indent;
            run_start = grapheme.start;
        }
        line_width.* +|= grapheme_width;
    }
    if (run_start < text.len) {
        try output.append(
            allocator,
            text[run_start..],
            style,
            uri,
        );
    }
}

fn firstGraphemeWidth(window: vaxis.Window, text: []const u8) u16 {
    var iterator = vaxis.unicode.graphemeIterator(text);
    const grapheme = iterator.next() orelse return 0;
    return window.gwidth(grapheme.bytes(text));
}

fn fitContinuationIndent(
    width: u16,
    continuation_indent: u16,
    next_grapheme_width: u16,
) u16 {
    return @min(continuation_indent, width -| next_grapheme_width);
}

fn appendIndent(
    allocator: std.mem.Allocator,
    line: *Line,
    count: u16,
) !void {
    if (count == 0) return;
    const spaces = try allocator.alloc(u8, count);
    defer allocator.free(spaces);
    @memset(spaces, ' ');
    try line.append(allocator, spaces, .{}, null);
}

fn removeTrailingWhitespace(
    line: *Line,
    allocator: std.mem.Allocator,
) void {
    if (line.segments.items.len == 0) return;
    const last = &line.segments.items[line.segments.items.len - 1];
    if (!std.mem.eql(u8, last.text, " ")) return;
    var removed = line.segments.pop().?;
    removed.deinit(allocator);
}

fn isWrapWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn safeUri(uri: []const u8) bool {
    for (uri) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    const schemes = [_][]const u8{ "https://", "http://", "mailto:" };
    for (schemes) |scheme| {
        if (uri.len >= scheme.len and
            std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme))
        {
            return true;
        }
    }
    return false;
}

fn normalizedCodepoint(codepoint: u32) u21 {
    const replacement: u21 = 0xfffd;
    if (codepoint == 0 or codepoint > 0x10ffff or
        (codepoint >= 0xd800 and codepoint <= 0xdfff))
    {
        return replacement;
    }
    if (codepoint >= 0x80 and codepoint <= 0x9f) {
        const replacements = [_]u21{
            0x20ac, 0x0081, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
            0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008d, 0x017d, 0x008f,
            0x0090, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
            0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x009d, 0x017e, 0x0178,
        };
        return replacements[codepoint - 0x80];
    }
    return @intCast(codepoint);
}

fn appendCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u32,
) !void {
    var buffer: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(
        normalizedCodepoint(codepoint),
        &buffer,
    );
    try output.appendSlice(allocator, buffer[0..length]);
}

fn decodeEntity(
    allocator: std.mem.Allocator,
    entity: []const u8,
) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);

    if (entity.len > 3 and entity[0] == '&' and entity[1] == '#') {
        const hexadecimal = entity[2] == 'x' or entity[2] == 'X';
        const digits = entity[if (hexadecimal) 3 else 2 .. entity.len - 1];
        const codepoint = std.fmt.parseInt(
            u32,
            digits,
            if (hexadecimal) 16 else 10,
        ) catch {
            try decoded.appendSlice(allocator, entity);
            return decoded.toOwnedSlice(allocator);
        };
        try appendCodepoint(allocator, &decoded, codepoint);
        return decoded.toOwnedSlice(allocator);
    }

    const found = c.entity_lookup(entity.ptr, entity.len);
    if (found != null) {
        const entry = found[0];
        try appendCodepoint(allocator, &decoded, entry.codepoints[0]);
        if (entry.codepoints[1] != 0) {
            try appendCodepoint(allocator, &decoded, entry.codepoints[1]);
        }
    } else {
        try decoded.appendSlice(allocator, entity);
    }
    return decoded.toOwnedSlice(allocator);
}

fn decodeAttribute(
    allocator: std.mem.Allocator,
    attribute: c.MD_ATTRIBUTE,
) ![]u8 {
    if (attribute.size == 0 or attribute.text == null) {
        return allocator.dupe(u8, "");
    }

    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var index: usize = 0;
    while (attribute.substr_offsets[index] < attribute.size) : (index += 1) {
        const start = attribute.substr_offsets[index];
        const end = attribute.substr_offsets[index + 1];
        const bytes = attribute.text[start..end];
        switch (attribute.substr_types[index]) {
            c.MD_TEXT_ENTITY => {
                const entity = try decodeEntity(allocator, bytes);
                defer allocator.free(entity);
                try decoded.appendSlice(allocator, entity);
            },
            c.MD_TEXT_NULLCHAR => try appendCodepoint(
                allocator,
                &decoded,
                0,
            ),
            else => try decoded.appendSlice(allocator, bytes),
        }
    }
    return decoded.toOwnedSlice(allocator);
}

fn enterBlock(
    block_type: c.MD_BLOCKTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const builder: *Builder = @ptrCast(@alignCast(userdata.?));
    if (builder.failure != null) return 1;
    switch (block_type) {
        c.MD_BLOCK_QUOTE => builder.quote_depth +|= 1,
        c.MD_BLOCK_UL => {
            const info: *const c.MD_BLOCK_UL_DETAIL =
                @ptrCast(@alignCast(detail.?));
            builder.lists.append(
                builder.allocator,
                .{
                    .ordered = false,
                    .next = 1,
                    .tight = info.is_tight != 0,
                },
            ) catch |err| return builder.fail(err);
        },
        c.MD_BLOCK_OL => {
            const info: *const c.MD_BLOCK_OL_DETAIL =
                @ptrCast(@alignCast(detail.?));
            builder.lists.append(
                builder.allocator,
                .{
                    .ordered = true,
                    .next = info.start,
                    .tight = info.is_tight != 0,
                },
            ) catch |err| return builder.fail(err);
        },
        c.MD_BLOCK_LI => builder.beginListItem(detail) catch |err|
            return builder.fail(err),
        c.MD_BLOCK_H => {
            const info: *const c.MD_BLOCK_H_DETAIL =
                @ptrCast(@alignCast(detail.?));
            builder.heading_level = @intCast(info.level);
            builder.style.heading = true;
            builder.finishLine();
        },
        c.MD_BLOCK_CODE => {
            builder.finishLine();
            builder.code_block = true;
            builder.style.code = true;
            builder.code_source.clearRetainingCapacity();
            const info: *const c.MD_BLOCK_CODE_DETAIL =
                @ptrCast(@alignCast(detail.?));
            const language_name = decodeAttribute(
                builder.allocator,
                info.lang,
            ) catch |err| return builder.fail(err);
            defer builder.allocator.free(language_name);
            builder.code_language =
                highlight.Language.fromMarkdownName(language_name);
            if (builder.code_language != null) {
                builder.current_code_block_index = builder.code_block_index;
                builder.code_block_index += 1;
            }
        },
        c.MD_BLOCK_HR => {
            builder.appendText("────────────────") catch |err|
                return builder.fail(err);
            builder.finishLine();
        },
        c.MD_BLOCK_TABLE => builder.beginTable(detail) catch |err|
            return builder.fail(err),
        c.MD_BLOCK_TR => builder.current_row = .{},
        c.MD_BLOCK_TH, c.MD_BLOCK_TD => builder.beginCell(detail),
        else => {},
    }
    return 0;
}

fn leaveBlock(
    block_type: c.MD_BLOCKTYPE,
    _: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const builder: *Builder = @ptrCast(@alignCast(userdata.?));
    if (builder.failure != null) return 1;
    switch (block_type) {
        c.MD_BLOCK_QUOTE => {
            builder.finishLine();
            builder.quote_depth -|= 1;
            builder.appendBlank() catch |err| return builder.fail(err);
        },
        c.MD_BLOCK_UL, c.MD_BLOCK_OL => {
            _ = builder.lists.pop();
            if (builder.lists.items.len == 0) {
                builder.appendBlank() catch |err| return builder.fail(err);
            }
        },
        c.MD_BLOCK_LI => {
            if (builder.pending_list_prefix != null) {
                _ = builder.ensureLine() catch |err| return builder.fail(err);
            }
            builder.finishLine();
            _ = builder.list_item_indents.pop();
        },
        c.MD_BLOCK_H => {
            builder.finishLine();
            builder.style.heading = false;
            builder.heading_level = 0;
            builder.appendBlank() catch |err| return builder.fail(err);
        },
        c.MD_BLOCK_CODE => {
            builder.flushCodeBlock() catch |err| return builder.fail(err);
            builder.finishLine();
            builder.code_block = false;
            builder.code_language = null;
            builder.style.code = false;
            builder.appendBlank() catch |err| return builder.fail(err);
        },
        c.MD_BLOCK_P => {
            builder.finishLine();
            if (builder.table == null and
                (builder.lists.items.len == 0 or
                    !builder.lists.items[builder.lists.items.len - 1].tight))
            {
                builder.appendBlank() catch |err| return builder.fail(err);
            }
        },
        c.MD_BLOCK_TH, c.MD_BLOCK_TD => builder.finishCell() catch |err|
            return builder.fail(err),
        c.MD_BLOCK_TR => builder.finishRow() catch |err|
            return builder.fail(err),
        c.MD_BLOCK_TABLE => builder.finishTable() catch |err|
            return builder.fail(err),
        else => {},
    }
    return 0;
}

fn enterSpan(
    span_type: c.MD_SPANTYPE,
    detail: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const builder: *Builder = @ptrCast(@alignCast(userdata.?));
    if (builder.failure != null) return 1;
    switch (span_type) {
        c.MD_SPAN_EM => {
            builder.italic_depth +|= 1;
            builder.style.italic = true;
        },
        c.MD_SPAN_STRONG => {
            builder.bold_depth +|= 1;
            builder.style.bold = true;
        },
        c.MD_SPAN_CODE => {
            builder.code_depth +|= 1;
            builder.style.code = true;
        },
        c.MD_SPAN_DEL => {
            builder.strikethrough_depth +|= 1;
            builder.style.strikethrough = true;
        },
        c.MD_SPAN_A => {
            const info: *const c.MD_SPAN_A_DETAIL =
                @ptrCast(@alignCast(detail.?));
            const href = decodeAttribute(
                builder.allocator,
                info.href,
            ) catch |err| return builder.fail(err);
            const uri = if (safeUri(href)) href else null;
            if (uri == null) builder.allocator.free(href);
            builder.link_stack.append(builder.allocator, uri) catch |err| {
                if (uri) |value| builder.allocator.free(value);
                return builder.fail(err);
            };
            builder.style.link = uri != null;
        },
        else => {},
    }
    return 0;
}

fn leaveSpan(
    span_type: c.MD_SPANTYPE,
    _: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const builder: *Builder = @ptrCast(@alignCast(userdata.?));
    if (builder.failure != null) return 1;
    switch (span_type) {
        c.MD_SPAN_EM => {
            builder.italic_depth -|= 1;
            builder.style.italic = builder.italic_depth > 0;
        },
        c.MD_SPAN_STRONG => {
            builder.bold_depth -|= 1;
            builder.style.bold = builder.bold_depth > 0;
        },
        c.MD_SPAN_CODE => {
            builder.code_depth -|= 1;
            builder.style.code = builder.code_block or builder.code_depth > 0;
        },
        c.MD_SPAN_DEL => {
            builder.strikethrough_depth -|= 1;
            builder.style.strikethrough = builder.strikethrough_depth > 0;
        },
        c.MD_SPAN_A => {
            if (builder.link_stack.pop()) |uri| {
                if (uri) |value| builder.allocator.free(value);
            }
            builder.style.link = builder.link_stack.items.len > 0 and
                builder.link_stack.items[builder.link_stack.items.len - 1] != null;
        },
        else => {},
    }
    return 0;
}

fn appendTerminalText(builder: *Builder, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte >= 0x20 and byte != 0x7f) continue;
        if (byte == '\n' and builder.code_block) {
            try builder.appendText(text[start .. index + 1]);
            start = index + 1;
            continue;
        }
        if (start < index) try builder.appendText(text[start..index]);

        const codepoint: u21 = if (byte == 0x7f)
            0x2421
        else
            0x2400 + @as(u21, byte);
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &buffer);
        try builder.appendText(buffer[0..length]);
        start = index + 1;
    }
    if (start < text.len) try builder.appendText(text[start..]);
}

fn textCallback(
    text_type: c.MD_TEXTTYPE,
    text: [*c]const c.MD_CHAR,
    size: c.MD_SIZE,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const builder: *Builder = @ptrCast(@alignCast(userdata.?));
    if (builder.failure != null) return 1;
    const bytes = text[0..size];
    switch (text_type) {
        c.MD_TEXT_BR => {
            builder.finishLine();
        },
        c.MD_TEXT_SOFTBR => builder.appendText(" ") catch |err|
            return builder.fail(err),
        c.MD_TEXT_NULLCHAR => builder.appendText("�") catch |err|
            return builder.fail(err),
        c.MD_TEXT_ENTITY => {
            const decoded = decodeEntity(
                builder.allocator,
                bytes,
            ) catch |err| return builder.fail(err);
            defer builder.allocator.free(decoded);
            appendTerminalText(builder, decoded) catch |err|
                return builder.fail(err);
        },
        c.MD_TEXT_HTML => {},
        else => appendTerminalText(builder, bytes) catch |err|
            return builder.fail(err),
    }
    return 0;
}

test "safe link schemes" {
    try std.testing.expect(safeUri("https://example.com"));
    try std.testing.expect(safeUri("HTTP://example.com"));
    try std.testing.expect(safeUri("mailto:test@example.com"));
    try std.testing.expect(!safeUri("https://example.com/\x07"));
    try std.testing.expect(!safeUri("https://example.com/\x1b"));
    try std.testing.expect(!safeUri("javascript:alert(1)"));
    try std.testing.expect(!safeUri("file:///etc/passwd"));
}

fn testWindow(screen: *vaxis.Screen, width: u16) vaxis.Window {
    screen.* = .{ .width_method = .unicode };
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = 100,
        .screen = screen,
    };
}

fn appendLayoutText(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    layout: *const Layout,
) !void {
    for (layout.lines.items, 0..) |line, line_index| {
        if (line_index > 0) try output.append(allocator, '\n');
        for (line.segments.items) |segment| {
            try output.appendSlice(allocator, segment.text);
        }
    }
}

test "core Markdown styles and safe links are retained" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "# Heading\n\n**strong** *emphasis* `code` ~~gone~~ " ++
            "[safe](https://example.com) [unsafe](javascript:alert(1))",
        window,
        98,
    );
    defer layout.deinit();

    var saw_heading = false;
    var saw_strong = false;
    var saw_emphasis = false;
    var saw_code = false;
    var saw_strike = false;
    var saw_safe_link = false;
    var saw_unsafe_link = false;
    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            if (std.mem.eql(u8, segment.text, "Heading")) {
                saw_heading = segment.style.heading;
            } else if (std.mem.eql(u8, segment.text, "strong")) {
                saw_strong = segment.style.bold;
            } else if (std.mem.eql(u8, segment.text, "emphasis")) {
                saw_emphasis = segment.style.italic;
            } else if (std.mem.eql(u8, segment.text, "code")) {
                saw_code = segment.style.code;
            } else if (std.mem.eql(u8, segment.text, "gone")) {
                saw_strike = segment.style.strikethrough;
            } else if (std.mem.eql(u8, segment.text, "safe")) {
                saw_safe_link = segment.uri != null and
                    std.mem.eql(u8, segment.uri.?, "https://example.com");
            } else if (std.mem.eql(u8, segment.text, "unsafe")) {
                saw_unsafe_link = segment.uri != null;
            }
        }
    }
    try std.testing.expect(saw_heading);
    try std.testing.expect(saw_strong);
    try std.testing.expect(saw_emphasis);
    try std.testing.expect(saw_code);
    try std.testing.expect(saw_strike);
    try std.testing.expect(saw_safe_link);
    try std.testing.expect(!saw_unsafe_link);
}

test "nested spans retain their outer styles" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "*outer _inner_ italic-tail* **outer __inner__ bold-tail**",
        window,
        98,
    );
    defer layout.deinit();

    var italic_tail = false;
    var bold_tail = false;
    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            if (std.mem.indexOf(u8, segment.text, "italic-tail") != null) {
                italic_tail = segment.style.italic;
            }
            if (std.mem.indexOf(u8, segment.text, "bold-tail") != null) {
                bold_tail = segment.style.bold;
            }
        }
    }
    try std.testing.expect(italic_tail);
    try std.testing.expect(bold_tail);
}

test "entities are decoded in text and link destinations" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "Fish &amp; Chips &#169; &#x41; " ++
            "[safe](https://example.test/?a=1&amp;b=2)",
        window,
        98,
    );
    defer layout.deinit();

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "Fish & Chips © A") != null,
    );

    var saw_decoded_link = false;
    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            if (segment.uri) |uri| {
                saw_decoded_link =
                    std.mem.eql(u8, uri, "https://example.test/?a=1&b=2");
            }
        }
    }
    try std.testing.expect(saw_decoded_link);
}

test "decoded controls are rejected from link destinations" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "[bell](https://example.test/&#7;) " ++
            "[escape](https://example.test/&#27;)",
        window,
        98,
    );
    defer layout.deinit();

    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            try std.testing.expect(segment.uri == null);
        }
    }
}

test "text controls render as visible control pictures" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "entity: &#27; &NewLine; &Tab; &#127; raw: \x1b\x7f",
        window,
        98,
    );
    defer layout.deinit();

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);
    try std.testing.expectEqualStrings(
        "entity: ␛ ␊ ␉ ␡ raw: ␛␡",
        rendered.items,
    );
}

test "fenced code retains line breaks while escaping controls" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "```\nfirst\x1b\nsecond\n```",
        window,
        98,
    );
    defer layout.deinit();

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "  first␛\n  second") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "␊") == null);
}

test "fenced code applies tree-sitter syntax styles" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "```zig\nconst answer = 42; // ready\n```",
        window,
        98,
    );
    defer layout.deinit();

    var saw_keyword = false;
    var saw_number = false;
    var saw_comment = false;
    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            const token = segment.style.syntax orelse continue;
            saw_keyword = saw_keyword or token == .keyword;
            saw_number = saw_number or token == .number;
            saw_comment = saw_comment or token == .comment;
        }
    }
    try std.testing.expect(saw_keyword and saw_number and saw_comment);
}

test "cached fenced code renders sanitized presentation text" {
    var cache: HighlightCache = .{};
    defer cache.deinit(std.testing.allocator);
    const code = try cache.codeFor(
        std.testing.allocator,
        0,
        .zig,
        "const \x1b[31manswer\x1b[0m = 42;\r\n",
    );
    try std.testing.expectEqualStrings("const answer = 42;\n", code.text);
    for (code.spans) |span| {
        try std.testing.expect(span.end <= code.text.len);
    }
}

test "fenced code parses multiline syntax as one document" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var layout = try Layout.init(
        std.testing.allocator,
        "```bash\ncat <<EOF\nhello from heredoc\nEOF\n```",
        window,
        98,
    );
    defer layout.deinit();

    var heredoc_is_string = false;
    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            if (std.mem.eql(u8, segment.text, "hello from heredoc")) {
                heredoc_is_string = segment.style.syntax == .string;
            }
        }
    }
    try std.testing.expect(heredoc_is_string);
}

test "completed fenced code reuses cached syntax spans" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var cache: HighlightCache = .{};
    defer cache.deinit(std.testing.allocator);
    const source = "```zig\nconst answer = 42;\n```";

    var first = try Layout.initCached(
        std.testing.allocator,
        source,
        window,
        98,
        &cache,
    );
    defer first.deinit();
    const first_spans = cache.blocks.items[0].spans;

    var second = try Layout.initCached(
        std.testing.allocator,
        source,
        window,
        40,
        &cache,
    );
    defer second.deinit();
    try std.testing.expectEqual(
        @intFromPtr(first_spans.ptr),
        @intFromPtr(cache.blocks.items[0].spans.ptr),
    );
}

test "fenced code cache hashes text beyond the parser limit" {
    var cache: HighlightCache = .{};
    defer cache.deinit(std.testing.allocator);
    const first_source = try std.testing.allocator.alloc(
        u8,
        highlight.max_source_bytes + 1,
    );
    defer std.testing.allocator.free(first_source);
    @memset(first_source, ' ');
    first_source[first_source.len - 1] = 'a';
    const second_source = try std.testing.allocator.dupe(u8, first_source);
    defer std.testing.allocator.free(second_source);
    second_source[second_source.len - 1] = 'b';

    const first = try cache.codeFor(
        std.testing.allocator,
        0,
        .zig,
        first_source,
    );
    try std.testing.expectEqual(@as(u8, 'a'), first.text[first.text.len - 1]);
    const second = try cache.codeFor(
        std.testing.allocator,
        0,
        .zig,
        second_source,
    );
    try std.testing.expectEqual(@as(u8, 'b'), second.text[second.text.len - 1]);
}

test "unsupported fences do not offset cached supported blocks" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var cache: HighlightCache = .{};
    defer cache.deinit(std.testing.allocator);
    var layout = try Layout.initCached(
        std.testing.allocator,
        "```unknown\nplain\n```\n\n```zig\nconst answer = 42;\n```",
        window,
        98,
        &cache,
    );
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 1), cache.blocks.items.len);
}

test "incomplete streaming prefixes remain visible" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 40);
    var layout = try Layout.init(
        std.testing.allocator,
        "Visible **unfinished and `partial",
        window,
        38,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expectEqualStrings(
        "Visible **unfinished and `partial",
        rendered.items,
    );
}

test "every Markdown prefix produces a layout" {
    const source =
        "# Heading\n\n**strong** and `code`\n\n" ++
        "| Name | Status |\n| --- | --- |\n| parser | ready |\n\n" ++
        "```zig\nconst answer = 42;\n```";
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 40);

    for (0..source.len + 1) |end| {
        var layout = try Layout.init(
            std.testing.allocator,
            source[0..end],
            window,
            38,
        );
        layout.deinit();
    }
}

test "wrapping uses terminal grapheme widths" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 4);
    var layout = try Layout.init(
        std.testing.allocator,
        "🙂🙂a",
        window,
        4,
    );
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.lines.items.len);
    try std.testing.expectEqualStrings(
        "🙂🙂",
        layout.lines.items[0].segments.items[0].text,
    );
    try std.testing.expectEqualStrings(
        "a",
        layout.lines.items[1].segments.items[0].text,
    );
}

test "prose wraps at word boundaries" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 12);
    var layout = try Layout.init(
        std.testing.allocator,
        "alpha beta gamma",
        window,
        12,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expectEqualStrings("alpha beta\ngamma", rendered.items);
}

test "range layout retains only requested wrapped rows" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 8);
    var layout = try Layout.initCachedRange(
        std.testing.allocator,
        "alpha beta gamma delta epsilon",
        window,
        8,
        null,
        1,
        3,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expectEqual(@as(usize, 5), layout.total_rows);
    try std.testing.expectEqual(@as(usize, 2), layout.lines.items.len);
    try std.testing.expectEqualStrings("beta\ngamma", rendered.items);
}

test "layout result does not borrow parser scratch" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 20);
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    var layout = try Layout.initCachedRangeAllocating(
        .{
            .result = std.testing.allocator,
            .scratch = scratch.allocator(),
            .cache = std.testing.allocator,
        },
        "**retained** [link](https://example.com)",
        window,
        20,
        null,
        0,
        std.math.maxInt(usize),
    );
    scratch.deinit();
    defer layout.deinit();

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);
    try std.testing.expectEqualStrings("retained link", rendered.items);
    var found_uri = false;
    for (layout.lines.items) |line| {
        for (line.segments.items) |segment| {
            if (segment.uri) |uri| {
                try std.testing.expectEqualStrings(
                    "https://example.com",
                    uri,
                );
                found_uri = true;
            }
        }
    }
    try std.testing.expect(found_uri);
}

test "lists blockquotes tasks and code have readable structure" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "> quoted\n\n1. first\n2. second\n\n- [x] done\n- [ ] todo\n\n" ++
            "```text\n  kept  spaces\n```",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "│ quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "1. first") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "2. second") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "☑ done") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "☐ todo") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "    kept  spaces") != null,
    );
}

test "multiline list items retain hanging indentation" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "- first line  \n  continued\n\n  second paragraph",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expectEqualStrings(
        "• first line\n  continued\n\n  second paragraph",
        rendered.items,
    );
}

test "continuation indentation fits narrow nested lists" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 4);
    var layout = try Layout.init(
        std.testing.allocator,
        "-\n  - child",
        window,
        4,
    );
    defer layout.deinit();

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);
    for (layout.lines.items) |line| {
        try std.testing.expect(lineWidth(window, line) <= 4);
    }
    for ("child") |letter| {
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.items, &.{letter}),
        );
    }
}

test "ordered task items advance numbering" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "1. [x] done\n2. next",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "1. ☑ done") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "2. next") != null,
    );
}

test "empty list items do not leak their prefixes" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "-\n-\n\nparagraph",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expect(std.mem.endsWith(u8, rendered.items, "\nparagraph"));
    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "• paragraph") == null,
    );
}

test "empty parent list items retain nested list prefixes" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "-\n  - child\n\nparagraph",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expectEqualStrings(
        "•\n  • child\n\nparagraph",
        rendered.items,
    );
}

test "wide tables render as a grid" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "| Name | Role |\n| --- | --- |\n| Ada | Engineer |",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Ada") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "| ---") == null);

    const expected_width = lineWidth(window, layout.lines.items[0]);
    for (layout.lines.items) |line| {
        try std.testing.expectEqual(expected_width, lineWidth(window, line));
    }
}

test "wide tables honor column alignment" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 80);
    var layout = try Layout.init(
        std.testing.allocator,
        "| Left | Center | Right |\n" ++
            "| :--- | :----: | ---: |\n" ++
            "| x | y | z |",
        window,
        78,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rendered.items,
            "│ x    │   y    │     z │",
        ) != null,
    );
}

test "tables retain enclosing quote and list prefixes" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 100);
    var quoted = try Layout.init(
        std.testing.allocator,
        "> | A | B |\n> | --- | --- |\n> | x | y |",
        window,
        98,
    );
    defer quoted.deinit();
    for (quoted.lines.items) |line| {
        if (line.segments.items.len == 0) continue;
        try std.testing.expectEqualStrings("│ ", line.segments.items[0].text);
    }

    var listed = try Layout.init(
        std.testing.allocator,
        "- | A | B |\n  | --- | --- |\n  | x | y |",
        window,
        98,
    );
    defer listed.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &listed);
    try std.testing.expect(std.mem.startsWith(u8, rendered.items, "• ┌"));
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "\n  │") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "\n  └") != null);
}

test "narrow tables render as stacked header values" {
    var screen: vaxis.Screen = undefined;
    const window = testWindow(&screen, 14);
    var layout = try Layout.init(
        std.testing.allocator,
        "| Name | Role |\n| --- | --- |\n| Ada | Engineer |",
        window,
        12,
    );
    defer layout.deinit();
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    try appendLayoutText(std.testing.allocator, &rendered, &layout);

    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "Name: Ada") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, rendered.items, "Role:\nEngineer") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "┌") == null);
}

test "analyzeSource styles emphasis code and links in place" {
    const source = "**bold** and *em* and `code` and [link](https://example.com) end";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_bold = false;
    var saw_italic = false;
    var saw_code = false;
    var saw_link = false;
    var prev_end: usize = 0;
    for (spans) |span| {
        try std.testing.expect(span.start >= prev_end);
        try std.testing.expect(span.end <= source.len);
        prev_end = span.end;
        const text = source[span.start..span.end];
        if (span.style.bold and std.mem.eql(u8, text, "**bold**")) saw_bold = true;
        if (span.style.italic and std.mem.eql(u8, text, "*em*")) saw_italic = true;
        if (span.style.code and std.mem.eql(u8, text, "`code`")) saw_code = true;
        if (span.style.link and std.mem.eql(u8, text, "[link](https://example.com)")) saw_link = true;
    }
    try std.testing.expect(saw_bold and saw_italic and saw_code and saw_link);
}

test "analyzeSource keeps emphasis nesting intact" {
    const source = "**a *b* c**";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_bold = false;
    var saw_italic = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.bold) saw_bold = true;
        if (span.style.italic and std.mem.indexOf(u8, text, "b") != null) saw_italic = true;
    }
    try std.testing.expect(saw_bold and saw_italic);
}

test "analyzeSource styles deeply nested emphasis" {
    const source = "*a _b *c _d *e _f *g _h *i* h_ g* f_ e* d_ c* b_ a*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    var saw_innermost = false;
    for (spans) |span| {
        if (span.style.italic and
            std.mem.indexOf(u8, source[span.start..span.end], "i") != null)
        {
            saw_innermost = true;
        }
    }
    try std.testing.expect(saw_innermost);
}

test "analyzeSource does not style image syntax as a link" {
    const source = "![*alt*](https://example.com)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_alt_emphasis = false;
    for (spans) |span| {
        try std.testing.expect(!span.style.link);
        if (span.style.italic and
            std.mem.indexOf(u8, source[span.start..span.end], "alt") != null)
        {
            saw_alt_emphasis = true;
        }
    }
    try std.testing.expect(saw_alt_emphasis);

    const url_alt_source = "![https://example.com](https://image.example)";
    const url_alt_spans = try analyzeSource(std.testing.allocator, url_alt_source);
    defer std.testing.allocator.free(url_alt_spans);
    for (url_alt_spans) |span| try std.testing.expect(!span.style.link);
}

test "analyzeSource marks headings and fenced code" {
    const source = "# Title\n\n```zig\nconst x = 1;\n```\nplain text";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_heading = false;
    var saw_fence_open = false;
    var saw_fence_body = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.heading and std.mem.eql(u8, text, "# Title")) saw_heading = true;
        if (span.style.code and std.mem.eql(u8, text, "```zig")) saw_fence_open = true;
        if (span.style.code and std.mem.eql(u8, text, "const x = 1;")) saw_fence_body = true;
    }
    try std.testing.expect(saw_heading and saw_fence_open and saw_fence_body);
}

test "analyzeSource preserves inline styles inside ATX headings" {
    const source = "# *Title* and [link](https://example.com)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_heading_italic = false;
    var saw_heading_link = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.heading and span.style.italic and
            std.mem.indexOf(u8, text, "Title") != null)
        {
            saw_heading_italic = true;
        }
        if (span.style.heading and span.style.link and
            std.mem.indexOf(u8, text, "link") != null)
        {
            saw_heading_link = true;
        }
    }
    try std.testing.expect(saw_heading_italic);
    try std.testing.expect(saw_heading_link);
}

test "analyzeSource leaves unmatched markers and snake_case unstyled" {
    const spans = try analyzeSource(std.testing.allocator, "snake_case_name and **unclosed and a * b *\n");
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "analyzeSource applies the underscore flanking rule like md4c" {
    const source = "_foo_bar_ and snake_case_name";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.italic);
    try std.testing.expect(std.mem.eql(u8, source[spans[0].start..spans[0].end], "_foo_bar_"));

    const punct = "start _emphasis,_ end";
    const punct_spans = try analyzeSource(std.testing.allocator, punct);
    defer std.testing.allocator.free(punct_spans);
    var saw_close = false;
    for (punct_spans) |span| {
        const text = punct[span.start..span.end];
        if (span.style.italic and std.mem.indexOf(u8, text, "emphasis") != null) saw_close = true;
    }
    try std.testing.expect(saw_close);
}

test "analyzeSource applies Unicode punctuation flanking" {
    const source = "_foo_—bar and _baz_˂qux";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_em_dash = false;
    var saw_modifier = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.italic and std.mem.eql(u8, text, "_foo_")) saw_em_dash = true;
        if (span.style.italic and std.mem.eql(u8, text, "_baz_")) saw_modifier = true;
    }
    try std.testing.expect(saw_em_dash);
    try std.testing.expect(saw_modifier);
}

test "analyzeSource applies Unicode whitespace flanking" {
    const source = "_foo_\u{00a0}bar";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.italic);
    try std.testing.expectEqualStrings("_foo_", source[spans[0].start..spans[0].end]);
}

test "analyzeSource applies GFM tilde delimiter rules" {
    const source = "~one~ and ~~two~~ and ~~escaped\\~~";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_single = false;
    var saw_double = false;
    var saw_escaped = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.strikethrough and std.mem.eql(u8, text, "~one~")) saw_single = true;
        if (span.style.strikethrough and std.mem.eql(u8, text, "~~two~~")) saw_double = true;
        if (span.style.strikethrough and std.mem.indexOf(u8, text, "escaped") != null) {
            saw_escaped = true;
        }
    }
    try std.testing.expect(saw_single);
    try std.testing.expect(saw_double);
    try std.testing.expect(!saw_escaped);
}

test "analyzeSource finds the latest eligible opener with the same marker" {
    const source = "*foo _bar* baz_";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_star_span = false;
    var styled_baz = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.italic and std.mem.indexOf(u8, text, "foo") != null) {
            saw_star_span = true;
        }
        if (span.style.italic and std.mem.indexOf(u8, text, "baz") != null) styled_baz = true;
    }
    try std.testing.expect(saw_star_span);
    try std.testing.expect(!styled_baz);
}

test "analyzeSource validates inline link destination and title grammar" {
    const source = "[bad](a b) [good](https://e.test/a \"title\")";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_bad = false;
    var saw_good = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.link and std.mem.indexOf(u8, text, "[bad]") != null) saw_bad = true;
        if (span.style.link and std.mem.indexOf(u8, text, "[good]") != null) saw_good = true;
    }
    try std.testing.expect(!saw_bad);
    try std.testing.expect(saw_good);
}

test "analyzeSource ignores parentheses inside quoted link titles" {
    const source = "[x](https://e.test \"a ) b\")";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.link);
    try std.testing.expectEqualStrings(source, source[spans[0].start..spans[0].end]);
}

test "analyzeSource requires whitespace before angle destination titles" {
    const source = "[x](<https://e.test>\"title\")";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| try std.testing.expect(!span.style.link);
}

test "analyzeSource rejects outer links overlapping nested links" {
    const source = "[outer [inner](https://i)](https://o)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.link);
    try std.testing.expectEqualStrings(
        "[inner](https://i)",
        source[spans[0].start..spans[0].end],
    );

    const image_source = "[outer ![image](https://i)](https://o)";
    const image_spans = try analyzeSource(std.testing.allocator, image_source);
    defer std.testing.allocator.free(image_spans);
    try std.testing.expect(image_spans.len > 0);
    try std.testing.expect(image_spans[0].style.link);
    try std.testing.expectEqual(@as(usize, 0), image_spans[0].start);
    try std.testing.expectEqual(image_source.len, image_spans[image_spans.len - 1].end);
}

test "analyzeSource suppresses autolinks inside unsafe explicit links" {
    const source = "[https://example.com](/relative)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| try std.testing.expect(!span.style.link);
}

test "analyzeSource hides markup inside unsafe link destinations" {
    const source = "[x](javascript:*foo*)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| try std.testing.expect(!span.style.italic);
}

test "analyzeSource resolves deeply nested link candidates once" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "[leaf](https://e)");
    for (0..128) |_| {
        var wrapped: std.ArrayList(u8) = .empty;
        errdefer wrapped.deinit(std.testing.allocator);
        try wrapped.appendSlice(std.testing.allocator, "[x ");
        try wrapped.appendSlice(std.testing.allocator, source.items);
        try wrapped.appendSlice(std.testing.allocator, "](https://e)");
        source.deinit(std.testing.allocator);
        source = wrapped;
    }

    const spans = try analyzeSource(std.testing.allocator, source.items);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.link);
    try std.testing.expectEqualStrings(
        "[leaf](https://e)",
        source.items[spans[0].start..spans[0].end],
    );
}

test "analyzeSource ignores brackets inside code span link labels" {
    const source = "[`]`](https://example.com)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_link = false;
    var saw_code = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.link and std.mem.indexOf(u8, text, "https://") != null) saw_link = true;
        if (span.style.code and std.mem.indexOf(u8, text, "`]`") != null) saw_code = true;
    }
    try std.testing.expect(saw_link);
    try std.testing.expect(saw_code);
}

test "analyzeSource backslashes escape only ASCII punctuation" {
    const source = "[invalid](foo\\ bar) [valid](https://e.test/foo\\(bar\\))";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_invalid = false;
    var saw_valid = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.link and std.mem.indexOf(u8, text, "invalid") != null) saw_invalid = true;
        if (span.style.link and std.mem.indexOf(u8, text, "valid") != null) saw_valid = true;
    }
    try std.testing.expect(!saw_invalid);
    try std.testing.expect(saw_valid);
}

test "analyzeSource applies safe URI policy to links" {
    const source = "[unsafe](javascript:alert(1)) [encoded](jav&#x61;script:alert(1)) [safe](https://e.test)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_unsafe = false;
    var saw_encoded = false;
    var saw_safe = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.link and std.mem.indexOf(u8, text, "unsafe") != null) saw_unsafe = true;
        if (span.style.link and std.mem.indexOf(u8, text, "encoded") != null) saw_encoded = true;
        if (span.style.link and std.mem.indexOf(u8, text, "safe") != null) saw_safe = true;
    }
    try std.testing.expect(!saw_unsafe);
    try std.testing.expect(!saw_encoded);
    try std.testing.expect(saw_safe);
}

test "analyzeSource bounds URI entity scans" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "[x](https://e.test/");
    try source.appendNTimes(std.testing.allocator, '&', 8_000);
    try source.append(std.testing.allocator, ')');

    const spans = try analyzeSource(std.testing.allocator, source.items);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.link);
}

test "analyzeSource styles GFM permissive autolinks" {
    const source = "https://example.com www.example.com user@example.com";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var linked_segments: usize = 0;
    for (spans) |span| {
        if (span.style.link) linked_segments += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), linked_segments);
}

test "analyzeSource matches permissive autolink boundaries and host grammar" {
    const invalid_source = "foo:https://example.com http://x www.";
    const invalid_spans = try analyzeSource(std.testing.allocator, invalid_source);
    defer std.testing.allocator.free(invalid_spans);
    for (invalid_spans) |span| try std.testing.expect(!span.style.link);

    const emphasized_source = "*https://example.com*";
    const emphasized_spans = try analyzeSource(std.testing.allocator, emphasized_source);
    defer std.testing.allocator.free(emphasized_spans);
    var saw_emphasized_link = false;
    for (emphasized_spans) |span| {
        if (span.style.italic and span.style.link) saw_emphasized_link = true;
    }
    try std.testing.expect(saw_emphasized_link);

    const parenthesized_path = try analyzeSource(
        std.testing.allocator,
        "https://example.com/()",
    );
    defer std.testing.allocator.free(parenthesized_path);
    for (parenthesized_path) |span| try std.testing.expect(!span.style.link);

    const trailing_period_source = "https://example.com/foo.";
    const trailing_period_spans = try analyzeSource(
        std.testing.allocator,
        trailing_period_source,
    );
    defer std.testing.allocator.free(trailing_period_spans);
    var saw_trimmed_path = false;
    for (trailing_period_spans) |span| {
        if (span.style.link) {
            try std.testing.expectEqualStrings(
                "https://example.com/foo",
                trailing_period_source[span.start..span.end],
            );
            saw_trimmed_path = true;
        }
    }
    try std.testing.expect(saw_trimmed_path);
}

test "analyzeSource styles safe angle autolinks" {
    const source =
        "<https://example.com> <mailto:user@example.com> " ++
        "<https://localhost> <http://x:8080>";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var linked_segments: usize = 0;
    for (spans) |span| {
        if (span.style.link) linked_segments += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), linked_segments);
}

test "analyzeSource requires resolved delimiter directions at autolink boundaries" {
    const source = "*foo*https://example.com https://example.com*foo*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| try std.testing.expect(!span.style.link);
}

test "analyzeSource bounds malformed angle destination scans" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.append(std.testing.allocator, '(');
    try source.appendNTimes(std.testing.allocator, ' ', 8_000);
    try source.appendNTimes(std.testing.allocator, '<', 8_000);

    const spans = try analyzeSource(std.testing.allocator, source.items);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "analyzeSource bounds mixed-marker delimiter scans" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..2_000) |_| try source.appendSlice(std.testing.allocator, "*a ");
    for (0..2_000) |_| try source.appendSlice(std.testing.allocator, "a_ ");

    const spans = try analyzeSource(std.testing.allocator, source.items);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "analyzeSource bounds same-marker delimiter scans" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..2_000) |_| try source.appendSlice(std.testing.allocator, "*a ");
    for (0..2_000) |_| try source.appendSlice(std.testing.allocator, "a**b ");

    const spans = try analyzeSource(std.testing.allocator, source.items);
    defer std.testing.allocator.free(spans);
}

test "analyzeSource bounds nested malformed angle destinations" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..8_000) |_| try source.appendSlice(std.testing.allocator, "(<");

    const spans = try analyzeSource(std.testing.allocator, source.items);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "analyzeSource permits parentheses inside angle link destinations" {
    const source = "[x](<https://e.test/a(b>)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(spans[0].style.link);
    try std.testing.expectEqualStrings(source, source[spans[0].start..spans[0].end]);
}

test "analyzeSource preserves partially consumed delimiter runs" {
    const source = "***foo** bar*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_bold_italic = false;
    var saw_outer_italic = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.bold and span.style.italic and std.mem.indexOf(u8, text, "foo") != null) {
            saw_bold_italic = true;
        }
        if (!span.style.bold and span.style.italic and std.mem.indexOf(u8, text, "bar") != null) {
            saw_outer_italic = true;
        }
    }
    try std.testing.expect(saw_bold_italic);
    try std.testing.expect(saw_outer_italic);
}

test "analyzeSource preserves the original delimiter modulo after splitting" {
    const source = "a***b**c**d";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_bold_b = false;
    var saw_italic_c = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.bold and std.mem.indexOf(u8, text, "b") != null) saw_bold_b = true;
        if (span.style.italic and std.mem.indexOf(u8, text, "c") != null) saw_italic_c = true;
    }
    try std.testing.expect(saw_bold_b);
    try std.testing.expect(saw_italic_c);
}

test "analyzeSource preserves residual closer delimiter metadata" {
    const source = "**foo***bar**baz*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_bar_italic = false;
    var saw_baz_italic = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.italic and std.mem.indexOf(u8, text, "bar") != null) {
            saw_bar_italic = true;
        }
        if (span.style.italic and std.mem.indexOf(u8, text, "baz") != null) {
            saw_baz_italic = true;
        }
    }
    try std.testing.expect(saw_bar_italic);
    try std.testing.expect(!saw_baz_italic);
}

test "analyzeSource styles inline spans across soft line breaks" {
    const source = "*foo\nbar* and [multi\nline](https://example.com)";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_multiline_emphasis = false;
    var saw_multiline_link = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.italic and std.mem.indexOf(u8, text, "foo") != null) {
            saw_multiline_emphasis = true;
        }
        if (span.style.link and std.mem.indexOf(u8, text, "multi") != null) {
            saw_multiline_link = true;
        }
    }
    try std.testing.expect(saw_multiline_emphasis);
    try std.testing.expect(saw_multiline_link);
}

test "analyzeSource stops inline spans at paragraph-interrupting blocks" {
    const source = "*foo\n- bar*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    for (spans) |span| try std.testing.expect(!span.style.italic);
}

test "analyzeSource matches quote and ordered-list paragraph interruption" {
    const quote_source = "*foo\n>bar*";
    const quote_spans = try analyzeSource(std.testing.allocator, quote_source);
    defer std.testing.allocator.free(quote_spans);
    for (quote_spans) |span| try std.testing.expect(!span.style.italic);

    const ordered_source = "*foo\n2. bar*";
    const ordered_spans = try analyzeSource(std.testing.allocator, ordered_source);
    defer std.testing.allocator.free(ordered_spans);
    var saw_ordered_continuation = false;
    for (ordered_spans) |span| {
        if (span.style.italic and
            std.mem.indexOf(u8, ordered_source[span.start..span.end], "bar") != null)
        {
            saw_ordered_continuation = true;
        }
    }
    try std.testing.expect(saw_ordered_continuation);
}

test "analyzeSource preserves inline spans across list continuations" {
    const source = "- *foo\n  bar*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    var saw_continuation = false;
    for (spans) |span| {
        if (span.style.italic and
            std.mem.indexOf(u8, source[span.start..span.end], "bar") != null)
        {
            saw_continuation = true;
        }
    }
    try std.testing.expect(saw_continuation);
}

test "analyzeSource preserves inline spans across quote continuations" {
    const source = "> *foo\n> bar*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    var saw_continuation = false;
    for (spans) |span| {
        if (span.style.italic and
            std.mem.indexOf(u8, source[span.start..span.end], "bar") != null)
        {
            saw_continuation = true;
        }
    }
    try std.testing.expect(saw_continuation);
}

test "analyzeSource ends quoted paragraphs at blank quote lines" {
    const source = "> *foo\n>\n> bar*";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| try std.testing.expect(!span.style.italic);
}

test "analyzeSource does not promote setext headings across containers" {
    const source = "- item\n---\n\n> quote\n---";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| try std.testing.expect(!span.style.heading);
}

test "analyzeSource distinguishes indented code from paragraph continuation" {
    const code_source = "    *code*";
    const code_spans = try analyzeSource(std.testing.allocator, code_source);
    defer std.testing.allocator.free(code_spans);
    try std.testing.expectEqual(@as(usize, 1), code_spans.len);
    try std.testing.expect(code_spans[0].style.code);
    try std.testing.expect(!code_spans[0].style.italic);

    const paragraph_source = "*foo\n    bar*";
    const paragraph_spans = try analyzeSource(std.testing.allocator, paragraph_source);
    defer std.testing.allocator.free(paragraph_spans);
    var saw_continuation = false;
    for (paragraph_spans) |span| {
        if (span.style.italic and
            std.mem.indexOf(u8, paragraph_source[span.start..span.end], "bar") != null)
        {
            saw_continuation = true;
        }
    }
    try std.testing.expect(saw_continuation);
}

test "analyzeSource expands tabs for indentation and ends paragraphs at blank lines" {
    const tab_source = "\t*code*";
    const tab_spans = try analyzeSource(std.testing.allocator, tab_source);
    defer std.testing.allocator.free(tab_spans);
    try std.testing.expectEqual(@as(usize, 1), tab_spans.len);
    try std.testing.expect(tab_spans[0].style.code);
    try std.testing.expect(!tab_spans[0].style.italic);

    const blank_source = "*foo\n    \nbar*";
    const blank_spans = try analyzeSource(std.testing.allocator, blank_source);
    defer std.testing.allocator.free(blank_spans);
    for (blank_spans) |span| try std.testing.expect(!span.style.italic);
}

test "analyzeSource marks setext heading contents" {
    const source = "*Title*\n===";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_heading_emphasis = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.heading and span.style.italic and
            std.mem.indexOf(u8, text, "Title") != null)
        {
            saw_heading_emphasis = true;
        }
    }
    try std.testing.expect(saw_heading_emphasis);
}

test "analyzeSource enforces link destination nesting limit" {
    var valid: std.ArrayList(u8) = .empty;
    defer valid.deinit(std.testing.allocator);
    try valid.appendSlice(std.testing.allocator, "[ok](https://e.test/");
    try valid.appendNTimes(std.testing.allocator, '(', 32);
    try valid.append(std.testing.allocator, 'x');
    try valid.appendNTimes(std.testing.allocator, ')', 32);
    try valid.append(std.testing.allocator, ')');
    const valid_spans = try analyzeSource(std.testing.allocator, valid.items);
    defer std.testing.allocator.free(valid_spans);
    try std.testing.expectEqual(@as(usize, 1), valid_spans.len);
    try std.testing.expect(valid_spans[0].style.link);

    var invalid: std.ArrayList(u8) = .empty;
    defer invalid.deinit(std.testing.allocator);
    try invalid.appendSlice(std.testing.allocator, "[bad](https://e.test/");
    try invalid.appendNTimes(std.testing.allocator, '(', 33);
    try invalid.append(std.testing.allocator, 'x');
    try invalid.appendNTimes(std.testing.allocator, ')', 33);
    try invalid.append(std.testing.allocator, ')');
    const invalid_spans = try analyzeSource(std.testing.allocator, invalid.items);
    defer std.testing.allocator.free(invalid_spans);
    for (invalid_spans) |span| try std.testing.expect(!span.style.link);
}

test "analyzeSource rejects backtick fences with backticks in the info string" {
    const source = "```zig`bad\nplain\n```\nafter";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    for (spans) |span| {
        const text = source[span.start..span.end];
        if (std.mem.indexOf(u8, text, "plain") != null) {
            try std.testing.expect(!span.style.code);
        }
    }
}

test "analyzeSource scans unmatched link openers once" {
    const source = try std.testing.allocator.alloc(u8, 8_000);
    defer std.testing.allocator.free(source);
    @memset(source, '[');

    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);

    const nested = "[[inner](https://example.com)";
    const nested_spans = try analyzeSource(std.testing.allocator, nested);
    defer std.testing.allocator.free(nested_spans);
    try std.testing.expectEqual(@as(usize, 1), nested_spans.len);
    try std.testing.expect(nested_spans[0].style.link);
    try std.testing.expectEqualStrings(
        "[inner](https://example.com)",
        nested[nested_spans[0].start..nested_spans[0].end],
    );
}

test "analyzeSource rejects inline code delimiters longer than md4c limit" {
    const delimiter = "`" ** 33;
    const source = delimiter ++ "code" ++ delimiter;
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    for (spans) |span| try std.testing.expect(!span.style.code);
}

test "analyzeSource fences close only on an equally long unannotated fence" {
    const source = "````example\n```zig\ninside\n```\nstill inside\n````\nafter";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);

    var saw_inside = false;
    var saw_still = false;
    for (spans) |span| {
        const text = source[span.start..span.end];
        if (span.style.code and std.mem.eql(u8, text, "inside")) saw_inside = true;
        if (span.style.code and std.mem.eql(u8, text, "still inside")) saw_still = true;
    }
    try std.testing.expect(saw_inside and saw_still);

    // Trailing text after a fence marker does not close the block.
    const annotated_text = "```\ncode\n```not-a-close\nmore code\n```\ndone";
    const annotated = try analyzeSource(std.testing.allocator, annotated_text);
    defer std.testing.allocator.free(annotated);
    var saw_more = false;
    var saw_done_code = false;
    for (annotated) |span| {
        const text = annotated_text[span.start..span.end];
        if (span.style.code and std.mem.eql(u8, text, "more code")) saw_more = true;
        if (span.style.code and std.mem.eql(u8, text, "done")) saw_done_code = true;
    }
    try std.testing.expect(saw_more);
    try std.testing.expect(!saw_done_code);
}

test "analyzeSource spans never split code points" {
    const source = "héllo **wörld** ok";
    const spans = try analyzeSource(std.testing.allocator, source);
    defer std.testing.allocator.free(spans);
    for (spans) |span| {
        try std.testing.expect((source[span.start] & 0xc0) != 0x80);
        if (span.end < source.len) {
            try std.testing.expect((source[span.end] & 0xc0) != 0x80);
        }
    }
}
