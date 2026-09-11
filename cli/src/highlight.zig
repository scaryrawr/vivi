const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_bash() callconv(.c) *const ts.Language;
extern fn tree_sitter_json() callconv(.c) *const ts.Language;

pub const Language = enum {
    zig,
    bash,
    json,

    pub fn fromPath(path: []const u8) ?Language {
        const extension = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(extension, ".zig") or
            std.ascii.eqlIgnoreCase(extension, ".zon"))
        {
            return .zig;
        }
        if (std.ascii.eqlIgnoreCase(extension, ".sh") or
            std.ascii.eqlIgnoreCase(extension, ".bash") or
            std.ascii.eqlIgnoreCase(extension, ".zsh"))
        {
            return .bash;
        }
        if (std.ascii.eqlIgnoreCase(extension, ".json") or
            std.ascii.eqlIgnoreCase(extension, ".jsonl"))
        {
            return .json;
        }
        return null;
    }

    pub fn fromMarkdownName(name: []const u8) ?Language {
        if (std.ascii.eqlIgnoreCase(name, "zig") or
            std.ascii.eqlIgnoreCase(name, "zon"))
        {
            return .zig;
        }
        if (std.ascii.eqlIgnoreCase(name, "bash") or
            std.ascii.eqlIgnoreCase(name, "sh") or
            std.ascii.eqlIgnoreCase(name, "shell") or
            std.ascii.eqlIgnoreCase(name, "zsh"))
        {
            return .bash;
        }
        if (std.ascii.eqlIgnoreCase(name, "json") or
            std.ascii.eqlIgnoreCase(name, "jsonl"))
        {
            return .json;
        }
        return null;
    }

    fn treeSitterLanguage(self: Language) *const ts.Language {
        return switch (self) {
            .zig => tree_sitter_zig(),
            .bash => tree_sitter_bash(),
            .json => tree_sitter_json(),
        };
    }

    fn query(self: Language) []const u8 {
        return switch (self) {
            .zig =>
            \\(comment) @comment
            \\[(string) (multiline_string)] @string
            \\[(integer) (float)] @number
            \\["true" "false" "null" "unreachable" "undefined"] @constant
            \\(builtin_identifier) @function
            \\["asm" "defer" "errdefer" "test" "error" "const" "var"
            \\ "struct" "union" "enum" "opaque" "async" "await" "suspend"
            \\ "nosuspend" "resume" "fn"
            \\ "and" "or" "orelse" "return" "if" "else" "switch" "for" "while"
            \\ "break" "continue" "usingnamespace" "export" "try" "catch"
            \\ "volatile" "allowzero" "noalias" "addrspace" "align" "callconv"
            \\ "linksection" "pub" "inline" "noinline" "extern" "comptime"
            \\ "packed" "threadlocal"] @keyword
            ,
            .bash =>
            \\[(string) (raw_string) (heredoc_body) (heredoc_start)] @string
            \\[(command_name) (function_definition name: (word))] @function
            \\(variable_name) @property
            \\["case" "do" "done" "elif" "else" "esac" "export" "fi" "for"
            \\ "function" "if" "in" "select" "then" "unset" "until" "while"] @keyword
            \\(comment) @comment
            \\(file_descriptor) @number
            \\["$" "&&" ">" ">>" "<" "|"] @operator
            ,
            .json =>
            \\(pair key: (_) @property)
            \\(string) @string
            \\(number) @number
            \\[(null) (true) (false)] @constant
            \\(escape_sequence) @operator
            \\(comment) @comment
            ,
        };
    }
};

pub const Token = enum {
    comment,
    string,
    number,
    constant,
    keyword,
    function,
    property,
    operator,
};

pub const Span = struct {
    start: usize,
    end: usize,
    token: Token,
};

pub const max_source_bytes = 256 * 1024;

pub fn spans(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
) ![]Span {
    const bounded_source = source[0..@min(source.len, max_source_bytes)];
    if (bounded_source.len == 0) {
        return allocator.alloc(Span, 0);
    }

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(language.treeSitterLanguage());
    const tree = parser.parseString(bounded_source, null) orelse
        return allocator.alloc(Span, 0);
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = try ts.Query.create(
        language.treeSitterLanguage(),
        language.query(),
        &error_offset,
    );
    defer query.destroy();

    const tokens = try allocator.alloc(?Token, bounded_source.len);
    defer allocator.free(tokens);
    @memset(tokens, null);

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, tree.rootNode());
    while (cursor.nextCapture()) |result| {
        const capture = result[1].captures[result[0]];
        const name = query.captureNameForId(capture.index) orelse continue;
        const token = std.meta.stringToEnum(Token, name) orelse continue;
        const start: usize = @intCast(capture.node.startByte());
        const end: usize = @min(
            @as(usize, @intCast(capture.node.endByte())),
            bounded_source.len,
        );
        if (start >= end) continue;
        @memset(tokens[start..end], token);
    }

    var result: std.ArrayList(Span) = .empty;
    errdefer result.deinit(allocator);
    var start: usize = 0;
    while (start < tokens.len) {
        const token = tokens[start] orelse {
            start += 1;
            continue;
        };
        var end = start + 1;
        while (end < tokens.len and tokens[end] == token) : (end += 1) {}
        try result.append(allocator, .{
            .start = start,
            .end = end,
            .token = token,
        });
        start = end;
    }
    return result.toOwnedSlice(allocator);
}

test "language detection covers supported file and fence names" {
    try std.testing.expectEqual(Language.zig, Language.fromPath("build.zig.zon").?);
    try std.testing.expectEqual(Language.bash, Language.fromPath("script.sh").?);
    try std.testing.expectEqual(Language.json, Language.fromMarkdownName("JSON").?);
    try std.testing.expect(Language.fromPath("README.md") == null);
}

test "tree-sitter produces semantic spans" {
    const source = "const answer = 42; // done";
    const highlighted = try spans(std.testing.allocator, .zig, source);
    defer std.testing.allocator.free(highlighted);

    var saw_keyword = false;
    var saw_number = false;
    var saw_comment = false;
    for (highlighted) |span| {
        saw_keyword = saw_keyword or span.token == .keyword;
        saw_number = saw_number or span.token == .number;
        saw_comment = saw_comment or span.token == .comment;
    }
    try std.testing.expect(saw_keyword and saw_number and saw_comment);

    const json = try spans(
        std.testing.allocator,
        .json,
        "{\"ready\": true, \"count\": 2}",
    );
    defer std.testing.allocator.free(json);
    try std.testing.expect(json.len > 0);
}

test "highlighting is bounded for large sources" {
    const source = try std.testing.allocator.alloc(u8, max_source_bytes + 1024);
    defer std.testing.allocator.free(source);
    @memset(source, '1');
    const highlighted = try spans(std.testing.allocator, .json, source);
    defer std.testing.allocator.free(highlighted);
    for (highlighted) |span| {
        try std.testing.expect(span.end <= max_source_bytes);
    }
}
