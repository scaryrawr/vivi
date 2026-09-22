const std = @import("std");
const backend = @import("vivi_backend");
const highlight = backend.syntax;
const vaxis = @import("vaxis");
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

const emphasis_stack_limit = 8;

const EmphasisOpener = struct {
    marker: u8 = 0,
    start: usize = 0,
    run: usize = 0,
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

fn isPunctByte(byte: u8) bool {
    return byte < 0x80 and std.ascii.isPunctuation(byte);
}

const DelimiterFlanking = struct {
    left: bool,
    right: bool,
};

fn delimiterFlanking(before: u8, after: u8) DelimiterFlanking {
    return .{
        .left = !isSpaceByte(after) and
            (isSpaceByte(before) or isPunctByte(before) or !isPunctByte(after)),
        .right = !isSpaceByte(before) and
            (isSpaceByte(after) or isPunctByte(after) or !isPunctByte(before)),
    };
}

/// Scans inline Markdown for one line, OR-ing style bits into the absolute
/// positions of `flags`. Unmatched markers are left unstyled (literal).
fn scanInline(
    flags: []u8,
    delimiter_pairs: []const usize,
    text: []const u8,
    lo: usize,
    hi: usize,
    depth: u8,
) void {
    var i = lo;
    var emphasis_openers: [emphasis_stack_limit]EmphasisOpener =
        @splat(.{ .marker = 0, .start = 0, .run = 0 });
    var emphasis_depth: usize = 0;

    while (i < hi) {
        switch (text[i]) {
            '\\' => {
                i += if (i + 1 < hi) 2 else 1;
            },
            '`' => {
                const run = countRun(text, i, hi, '`');
                var j = i + run;
                var closed: ?usize = null;
                while (j + run <= hi) {
                    if (text[j] != '`') {
                        j += 1;
                        continue;
                    }
                    const crun = countRun(text, j, hi, '`');
                    if (crun == run and j > i + run) {
                        closed = j;
                        break;
                    }
                    j += @max(crun, 1);
                }
                if (closed) |at| markRange(flags, i, at + run, flag_code);
                i = if (closed) |at| at + run else i + run;
            },
            '[', '!' => {
                const image = text[i] == '!' and i + 1 < hi and text[i + 1] == '[';
                if (!image and text[i] != '[') {
                    i += 1;
                    continue;
                }
                const label_open = if (image) i + 1 else i;
                if (linkAt(delimiter_pairs, text, hi, label_open)) |link| {
                    markRange(flags, i, link.dest_end + 1, flag_link);
                    if (depth < 4) {
                        scanInline(
                            flags,
                            delimiter_pairs,
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
            '~' => {
                if (i + 1 < hi and text[i + 1] == '~' and (i + 2 >= hi or text[i + 2] != '~')) {
                    const closed = findDouble(text, i + 2, hi, '~');
                    if (closed) |at| {
                        markRange(flags, i, at + 2, flag_strikethrough);
                        if (depth < 4) {
                            scanInline(flags, delimiter_pairs, text, i + 2, at, depth + 2);
                        }
                        i = at + 2;
                    } else {
                        i += 2;
                    }
                } else {
                    i += 1;
                }
            },
            '*', '_' => {
                const marker = text[i];
                const run = countRun(text, i, hi, marker);
                const before = if (i > lo) text[i - 1] else '\n';
                const after = if (i + run < hi) text[i + run] else '\n';
                const flanking = delimiterFlanking(before, after);
                const can_open = flanking.left and
                    (marker == '*' or !flanking.right or isPunctByte(before));
                const delimiter_can_close = flanking.right and
                    (marker == '*' or !flanking.left or isPunctByte(after));
                const can_close = emphasis_depth > 0 and
                    emphasis_openers[emphasis_depth - 1].marker == marker and
                    i > emphasis_openers[emphasis_depth - 1].start + emphasis_openers[emphasis_depth - 1].run and
                    delimiter_can_close;

                if (can_close) {
                    const opener = emphasis_openers[emphasis_depth - 1];
                    const closer_run = @min(run, opener.run);
                    if (closer_run >= 2) markRange(flags, opener.start, i + closer_run, flag_bold);
                    if (closer_run == 1 or opener.run >= 3) {
                        markRange(flags, opener.start, i + closer_run, flag_italic);
                    }
                    emphasis_depth -= 1;
                    i += closer_run;
                } else if (can_open and emphasis_depth < emphasis_stack_limit) {
                    emphasis_openers[emphasis_depth] = .{ .marker = marker, .start = i, .run = run };
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

fn pairDelimiters(
    pairs: []usize,
    stack: []usize,
    text: []const u8,
    lo: usize,
    hi: usize,
    open: u8,
    close: u8,
) void {
    var depth: usize = 0;
    var i = lo;
    while (i < hi) {
        if (text[i] == '\\') {
            i += if (i + 1 < hi) 2 else 1;
            continue;
        }
        if (text[i] == open) {
            stack[depth] = i;
            depth += 1;
        } else if (text[i] == close and depth > 0) {
            depth -= 1;
            pairs[stack[depth]] = i;
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

fn linkAt(
    delimiter_pairs: []const usize,
    text: []const u8,
    hi: usize,
    label_open: usize,
) ?LinkMatch {
    const label_close = delimiter_pairs[label_open];
    if (label_close == std.math.maxInt(usize) or
        label_close + 1 >= hi or
        text[label_close + 1] != '(')
    {
        return null;
    }
    const dest_end = delimiter_pairs[label_close + 1];
    if (dest_end == std.math.maxInt(usize)) return null;
    return .{ .label_close = label_close, .dest_end = dest_end };
}

fn findDouble(text: []const u8, from: usize, hi: usize, byte: u8) ?usize {
    var j = from;
    while (j + 1 < hi) {
        if (text[j] == byte and text[j + 1] == byte) return j;
        j += 1;
    }
    return null;
}

fn lineSpan(text: []const u8, from: usize) struct { end: usize, next: usize } {
    const newline = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
    var end = newline;
    if (end > from and text[end - 1] == '\r') end -= 1;
    return .{ .end = end, .next = newline +| 1 };
}

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
    const delimiter_pairs = try allocator.alloc(usize, source.len);
    defer allocator.free(delimiter_pairs);
    @memset(delimiter_pairs, std.math.maxInt(usize));
    const delimiter_stack = try allocator.alloc(usize, source.len);
    defer allocator.free(delimiter_stack);

    var fence: u8 = 0;
    var fence_len: usize = 0;
    var pos: usize = 0;
    while (pos < source.len) {
        const line = lineSpan(source, pos);
        var body = pos;
        while (body < line.end and source[body] == ' ' and body - pos < 3) body += 1;

        if (fence != 0) {
            markRange(flags, pos, line.end, flag_code);
            if (body < line.end and source[body] == fence) {
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
        } else if (body < line.end and
            (source[body] == '`' or source[body] == '~') and
            countRun(source, body, line.end, source[body]) >= 3)
        {
            fence = source[body];
            fence_len = countRun(source, body, line.end, source[body]);
            markRange(flags, pos, line.end, flag_code);
        } else if (body < line.end and source[body] == '#') {
            const hashes = countRun(source, body, line.end, '#');
            const at_end = body + hashes >= line.end;
            const next = if (at_end) '\n' else source[body + hashes];
            if (hashes >= 1 and hashes <= 6 and (at_end or next == ' ' or next == '\t')) {
                markRange(flags, pos, line.end, flag_heading);
            } else {
                prepareInlinePairs(delimiter_pairs, delimiter_stack, source, pos, line.end);
                scanInline(flags, delimiter_pairs, source, pos, line.end, 0);
            }
        } else {
            prepareInlinePairs(delimiter_pairs, delimiter_stack, source, pos, line.end);
            scanInline(flags, delimiter_pairs, source, pos, line.end, 0);
        }
        pos = line.next;
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
