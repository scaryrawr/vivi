const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_bash() callconv(.c) *const ts.Language;
extern fn tree_sitter_json() callconv(.c) *const ts.Language;
extern fn tree_sitter_yaml() callconv(.c) *const ts.Language;
extern fn tree_sitter_diff() callconv(.c) *const ts.Language;

pub const Language = enum {
    zig,
    bash,
    json,
    yaml,
    diff,

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
        if (std.ascii.eqlIgnoreCase(extension, ".yaml") or
            std.ascii.eqlIgnoreCase(extension, ".yml"))
        {
            return .yaml;
        }
        if (std.ascii.eqlIgnoreCase(extension, ".diff") or
            std.ascii.eqlIgnoreCase(extension, ".patch"))
        {
            return .diff;
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
        if (std.ascii.eqlIgnoreCase(name, "yaml") or
            std.ascii.eqlIgnoreCase(name, "yml"))
        {
            return .yaml;
        }
        if (std.ascii.eqlIgnoreCase(name, "diff") or
            std.ascii.eqlIgnoreCase(name, "patch"))
        {
            return .diff;
        }
        return null;
    }

    fn definition(self: Language) Definition {
        return switch (self) {
            .zig => .{
                .language = tree_sitter_zig(),
                .color_query =
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
            },
            .bash => .{
                .language = tree_sitter_bash(),
                .color_query =
                \\[(string) (raw_string) (heredoc_body) (heredoc_start)] @string
                \\(command_name) @function
                \\(function_definition name: (word) @function)
                \\(variable_name) @property
                \\["case" "do" "done" "elif" "else" "esac" "export" "fi" "for"
                \\ "function" "if" "in" "select" "then" "unset" "until" "while"] @keyword
                \\(comment) @comment
                \\(file_descriptor) @number
                \\["$" "&&" ">" ">>" "<" "|"] @operator
                ,
            },
            .json => .{
                .language = tree_sitter_json(),
                .color_query =
                \\(string) @string
                \\(pair key: (_) @property)
                \\(number) @number
                \\[(null) (true) (false)] @constant
                \\(escape_sequence) @operator
                \\(comment) @comment
                ,
            },
            .yaml => .{
                .language = tree_sitter_yaml(),
                .color_query =
                \\(comment) @comment
                \\[(double_quote_scalar) (single_quote_scalar)
                \\ (block_scalar) (string_scalar)] @string
                \\[(integer_scalar) (float_scalar)] @number
                \\[(boolean_scalar) (null_scalar)] @constant
                \\[(anchor_name) (alias_name) (tag)] @operator
                \\(block_mapping_pair
                \\  key: (flow_node
                \\    [(double_quote_scalar) (single_quote_scalar)] @property))
                \\(block_mapping_pair
                \\  key: (flow_node
                \\    (plain_scalar (string_scalar) @property)))
                \\(flow_mapping
                \\  (_ key: (flow_node
                \\    [(double_quote_scalar) (single_quote_scalar)] @property)))
                \\(flow_mapping
                \\  (_ key: (flow_node
                \\    (plain_scalar (string_scalar) @property))))
                ,
            },
            .diff => .{
                .language = tree_sitter_diff(),
                .color_query =
                \\(comment) @comment
                \\[(addition) (new_file)] @inserted
                \\[(deletion) (old_file)] @deleted
                \\[(change) (location)] @meta
                \\(commit) @constant
                \\(filename) @string
                \\(command "diff" @function)
                \\(mode) @number
                \\(index "index" @keyword)
                ,
                .invalid_query = "(unrecognized) @invalid",
                .required_query = "(command (argument) @signature)",
                .required_text = "--git",
            },
        };
    }
};

const Definition = struct {
    language: *const ts.Language,
    color_query: []const u8,
    invalid_query: ?[]const u8 = null,
    required_query: ?[]const u8 = null,
    required_text: ?[]const u8 = null,
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
    inserted,
    deleted,
    meta,
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
    return parseSpans(allocator, language, source, false);
}

pub fn completeSpans(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
) ![]Span {
    return parseSpans(allocator, language, source, true);
}

fn parseSpans(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
    require_complete: bool,
) ![]Span {
    const bounded_source = source[0..@min(source.len, max_source_bytes)];
    if (bounded_source.len == 0) {
        return allocator.alloc(Span, 0);
    }

    const definition = language.definition();
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(definition.language);
    const tree = parser.parseString(bounded_source, null) orelse
        return allocator.alloc(Span, 0);
    defer tree.destroy();
    const root = tree.rootNode();
    if (require_complete and
        (root.hasError() or
            try capturesAny(
                definition,
                definition.invalid_query,
                bounded_source,
                root,
                null,
            ) or
            !try satisfiesRequirement(definition, bounded_source, root)))
    {
        return allocator.alloc(Span, 0);
    }

    var error_offset: u32 = 0;
    const query = try ts.Query.create(
        definition.language,
        definition.color_query,
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

fn satisfiesRequirement(
    definition: Definition,
    source: []const u8,
    root: ts.Node,
) !bool {
    const query_source = definition.required_query orelse return true;
    return capturesAny(
        definition,
        query_source,
        source,
        root,
        definition.required_text,
    );
}

fn capturesAny(
    definition: Definition,
    query_source: ?[]const u8,
    source: []const u8,
    root: ts.Node,
    required_text: ?[]const u8,
) !bool {
    const text = query_source orelse return false;
    var error_offset: u32 = 0;
    const query = try ts.Query.create(
        definition.language,
        text,
        &error_offset,
    );
    defer query.destroy();
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, root);
    while (cursor.nextCapture()) |result| {
        if (required_text == null) return true;
        const capture = result[1].captures[result[0]];
        const start: usize = @intCast(capture.node.startByte());
        const end: usize = @intCast(capture.node.endByte());
        if (end <= source.len and
            std.mem.eql(u8, source[start..end], required_text.?))
        {
            return true;
        }
    }
    return false;
}

test "language detection covers supported file and fence names" {
    try std.testing.expectEqual(Language.zig, Language.fromPath("build.zig.zon").?);
    try std.testing.expectEqual(Language.bash, Language.fromPath("script.sh").?);
    try std.testing.expectEqual(Language.json, Language.fromMarkdownName("JSON").?);
    try std.testing.expectEqual(Language.yaml, Language.fromPath("workflow.YML").?);
    try std.testing.expectEqual(Language.diff, Language.fromMarkdownName("patch").?);
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

    const json_source = "{\"ready\": \"yes\", \"count\": 2}";
    const json = try spans(
        std.testing.allocator,
        .json,
        json_source,
    );
    defer std.testing.allocator.free(json);
    var saw_property = false;
    var saw_string_value = false;
    for (json) |span| {
        const text = json_source[span.start..span.end];
        saw_property = saw_property or
            (span.token == .property and std.mem.eql(u8, text, "\"ready\""));
        saw_string_value = saw_string_value or
            (span.token == .string and std.mem.eql(u8, text, "\"yes\""));
    }
    try std.testing.expect(saw_property and saw_string_value);
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

test "Bash function styling is limited to the function name" {
    const source = "greet() { if true; then printf hi; fi; }";
    const highlighted = try spans(std.testing.allocator, .bash, source);
    defer std.testing.allocator.free(highlighted);

    var saw_function_name = false;
    var saw_body_keyword = false;
    for (highlighted) |span| {
        const text = source[span.start..span.end];
        saw_function_name = saw_function_name or
            (span.token == .function and std.mem.eql(u8, text, "greet"));
        saw_body_keyword = saw_body_keyword or
            (span.token == .keyword and std.mem.eql(u8, text, "if"));
        if (span.token == .function) {
            try std.testing.expect(std.mem.indexOfScalar(u8, text, '{') == null);
        }
    }
    try std.testing.expect(saw_function_name and saw_body_keyword);
}

test "complete parsing rejects syntax that tolerant snippets retain" {
    const source = "const =";
    const tolerant = try spans(std.testing.allocator, .zig, source);
    defer std.testing.allocator.free(tolerant);
    const complete = try completeSpans(std.testing.allocator, .zig, source);
    defer std.testing.allocator.free(complete);

    try std.testing.expect(tolerant.len > 0);
    try std.testing.expectEqual(@as(usize, 0), complete.len);
}

test "YAML complete parsing produces semantic spans and rejects errors" {
    const source =
        \\name: vivi
        \\ready: true
        \\count: 2
        \\# note
    ;
    const highlighted = try completeSpans(std.testing.allocator, .yaml, source);
    defer std.testing.allocator.free(highlighted);
    var saw_property = false;
    var saw_constant = false;
    var saw_comment = false;
    for (highlighted) |span| {
        const text = source[span.start..span.end];
        saw_property = saw_property or
            (span.token == .property and std.mem.eql(u8, text, "name"));
        saw_constant = saw_constant or
            (span.token == .constant and std.mem.eql(u8, text, "true"));
        saw_comment = saw_comment or
            (span.token == .comment and std.mem.eql(u8, text, "# note"));
    }
    try std.testing.expect(saw_property and saw_constant and saw_comment);

    const rejected = try completeSpans(
        std.testing.allocator,
        .yaml,
        "items: [one, two",
    );
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqual(@as(usize, 0), rejected.len);
}

test "diff complete parsing requires a git signature and rejects unknown text" {
    const source =
        \\diff --git a/file.txt b/file.txt
        \\index 3367afd..4a58007 100644
        \\--- a/file.txt
        \\+++ b/file.txt
        \\@@ -1 +1 @@
        \\-old
        \\+new
    ++ "\n";
    const highlighted = try completeSpans(std.testing.allocator, .diff, source);
    defer std.testing.allocator.free(highlighted);
    var saw_inserted = false;
    var saw_deleted = false;
    var saw_meta = false;
    for (highlighted) |span| {
        const text = source[span.start..span.end];
        saw_inserted = saw_inserted or
            (span.token == .inserted and std.mem.eql(u8, text, "+new"));
        saw_deleted = saw_deleted or
            (span.token == .deleted and std.mem.eql(u8, text, "-old"));
        saw_meta = saw_meta or
            (span.token == .meta and std.mem.startsWith(u8, text, "@@"));
    }
    try std.testing.expect(saw_inserted and saw_deleted and saw_meta);

    for ([_][]const u8{
        "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n",
        "fatal: bad revision",
    }) |invalid| {
        const rejected = try completeSpans(
            std.testing.allocator,
            .diff,
            invalid,
        );
        defer std.testing.allocator.free(rejected);
        try std.testing.expectEqual(@as(usize, 0), rejected.len);
    }
}
