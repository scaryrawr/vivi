const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_bash() callconv(.c) *const ts.Language;
extern fn tree_sitter_json() callconv(.c) *const ts.Language;
extern fn tree_sitter_yaml() callconv(.c) *const ts.Language;
extern fn tree_sitter_diff() callconv(.c) *const ts.Language;
extern fn tree_sitter_javascript() callconv(.c) *const ts.Language;
extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *const ts.Language;
extern fn tree_sitter_rust() callconv(.c) *const ts.Language;
extern fn tree_sitter_c() callconv(.c) *const ts.Language;
extern fn tree_sitter_cpp() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;
extern fn tree_sitter_java() callconv(.c) *const ts.Language;
extern fn tree_sitter_lua() callconv(.c) *const ts.Language;
extern fn tree_sitter_python() callconv(.c) *const ts.Language;

const javascript_query =
    \\(property_identifier) @property
    \\(function_declaration name: (identifier) @function)
    \\(method_definition name: (property_identifier) @function)
    \\(call_expression function: (identifier) @function)
    \\[(true) (false) (null) (undefined)] @constant
    \\[(string) (template_string) (regex)] @string
    \\(number) @number
    \\(comment) @comment
    \\["as" "async" "await" "break" "case" "catch" "class" "const"
    \\ "continue" "default" "delete" "do" "else" "export" "extends" "finally"
    \\ "for" "from" "function" "if" "import" "in" "instanceof" "let" "new"
    \\ "of" "return" "static" "switch" "throw" "try" "typeof" "var" "void"
    \\ "while" "with" "yield"] @keyword
    \\["-" "+" "*" "/" "%" "=" "==" "===" "!" "!=" "!==" "=>"
    \\ "<" "<=" ">" ">=" "&&" "||" "??"] @operator
;

const typescript_query = javascript_query ++
    \\["abstract" "declare" "enum" "implements" "interface" "keyof"
    \\ "namespace" "private" "protected" "public" "type" "readonly"
    \\ "override" "satisfies"] @keyword
;

const rust_query =
    \\(field_identifier) @property
    \\(function_item (identifier) @function)
    \\(call_expression function: (identifier) @function)
    \\[(line_comment) (block_comment)] @comment
    \\[(char_literal) (string_literal) (raw_string_literal)] @string
    \\[(integer_literal) (float_literal)] @number
    \\(boolean_literal) @constant
    \\["as" "async" "await" "break" "const" "continue" "default" "dyn"
    \\ "else" "enum" "extern" "fn" "for" "if" "impl" "in" "let" "loop"
    \\ "match" "mod" "move" "pub" "ref" "return" "static" "struct" "trait"
    \\ "type" "union" "unsafe" "use" "where" "while"] @keyword
    \\["*" "&" "!" "+" "-" "/" "%" "=" "==" "!=" "<" "<=" ">" ">="] @operator
;

const c_query =
    \\(field_identifier) @property
    \\(call_expression function: (identifier) @function)
    \\(function_declarator declarator: (identifier) @function)
    \\(comment) @comment
    \\[(string_literal) (system_lib_string) (char_literal)] @string
    \\(number_literal) @number
    \\(null) @constant
    \\["break" "case" "const" "continue" "default" "do" "else" "enum"
    \\ "extern" "for" "if" "inline" "return" "sizeof" "static" "struct"
    \\ "switch" "typedef" "union" "volatile" "while"
    \\ "#define" "#elif" "#else" "#endif" "#if" "#ifdef" "#ifndef"
    \\ "#include"] @keyword
    \\["--" "-" "-=" "->" "=" "!=" "*" "&" "&&" "+" "++" "+="
    \\ "<" "==" ">" "||"] @operator
;

const cpp_query = c_query ++
    \\(raw_string_literal) @string
    \\(this) @constant
    \\["catch" "class" "co_await" "co_return" "co_yield" "constexpr"
    \\ "constinit" "consteval" "delete" "explicit" "final" "friend" "mutable"
    \\ "namespace" "noexcept" "new" "override" "private" "protected" "public"
    \\ "template" "throw" "try" "typename" "using" "concept" "requires"
    \\ "virtual" "import" "export" "module"] @keyword
;

const go_query =
    \\(field_identifier) @property
    \\(call_expression function: (identifier) @function)
    \\(function_declaration name: (identifier) @function)
    \\(method_declaration name: (field_identifier) @function)
    \\[(interpreted_string_literal) (raw_string_literal) (rune_literal)] @string
    \\[(int_literal) (float_literal) (imaginary_literal)] @number
    \\[(true) (false) (nil) (iota)] @constant
    \\(comment) @comment
    \\["break" "case" "chan" "const" "continue" "default" "defer" "else"
    \\ "fallthrough" "for" "func" "go" "goto" "if" "import" "interface"
    \\ "map" "package" "range" "return" "select" "struct" "switch" "type"
    \\ "var"] @keyword
    \\["--" "-" ":=" "!" "!=" "*" "/" "&" "&&" "%" "^" "+" "++"
    \\ "<-" "<" "<=" "=" "==" ">" ">=" "|" "||"] @operator
;

const java_query =
    \\(method_declaration name: (identifier) @function)
    \\(method_invocation name: (identifier) @function)
    \\[(hex_integer_literal) (decimal_integer_literal) (octal_integer_literal)
    \\ (decimal_floating_point_literal) (hex_floating_point_literal)] @number
    \\[(character_literal) (string_literal)] @string
    \\[(true) (false) (null_literal)] @constant
    \\[(line_comment) (block_comment)] @comment
    \\["abstract" "assert" "break" "case" "catch" "class" "continue"
    \\ "default" "do" "else" "enum" "extends" "final" "finally" "for" "if"
    \\ "implements" "import" "instanceof" "interface" "native" "new"
    \\ "package" "private" "protected" "public" "record" "return" "static"
    \\ "switch" "synchronized" "throw" "throws" "transient" "try" "volatile"
    \\ "while" "yield"] @keyword
    \\"@" @operator
;

const lua_query =
    \\(field name: (identifier) @property)
    \\(dot_index_expression field: (identifier) @property)
    \\(function_declaration name: (identifier) @function)
    \\(function_call name: (identifier) @function)
    \\[(nil) (false) (true)] @constant
    \\(string) @string
    \\(number) @number
    \\(comment) @comment
    \\["return" "goto" "in" "local" "global" "do" "end" "while"
    \\ "repeat" "until" "if" "elseif" "else" "then" "for" "function"] @keyword
    \\["=" "and" "not" "or"] @operator
;

const python_query =
    \\(attribute attribute: (identifier) @property)
    \\(function_definition name: (identifier) @function)
    \\(call function: (identifier) @function)
    \\[(none) (true) (false)] @constant
    \\[(integer) (float)] @number
    \\(comment) @comment
    \\(string) @string
    \\["as" "assert" "async" "await" "break" "class" "continue" "def"
    \\ "del" "elif" "else" "except" "finally" "for" "from" "global" "if"
    \\ "import" "lambda" "nonlocal" "pass" "raise" "return" "try" "while"
    \\ "with" "yield" "match" "case"] @keyword
    \\["-" "!=" "*" "**" "/" "//" "&" "%" "^" "+" "->" "<" "<="
    \\ "=" ":=" "==" ">" ">=" "|" "~" "and" "in" "is" "not" "or"] @operator
;

pub const Language = enum {
    zig,
    bash,
    json,
    yaml,
    diff,
    javascript,
    typescript,
    tsx,
    rust,
    c,
    cpp,
    go,
    java,
    lua,
    python,

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
        if (std.ascii.eqlIgnoreCase(extension, ".js") or
            std.ascii.eqlIgnoreCase(extension, ".jsx") or
            std.ascii.eqlIgnoreCase(extension, ".mjs") or
            std.ascii.eqlIgnoreCase(extension, ".cjs"))
        {
            return .javascript;
        }
        if (std.ascii.eqlIgnoreCase(extension, ".ts")) return .typescript;
        if (std.ascii.eqlIgnoreCase(extension, ".tsx")) return .tsx;
        if (std.ascii.eqlIgnoreCase(extension, ".rs")) return .rust;
        if (std.ascii.eqlIgnoreCase(extension, ".c") or
            std.ascii.eqlIgnoreCase(extension, ".h"))
        {
            return .c;
        }
        if (std.ascii.eqlIgnoreCase(extension, ".cc") or
            std.ascii.eqlIgnoreCase(extension, ".cpp") or
            std.ascii.eqlIgnoreCase(extension, ".cxx") or
            std.ascii.eqlIgnoreCase(extension, ".c++") or
            std.ascii.eqlIgnoreCase(extension, ".hh") or
            std.ascii.eqlIgnoreCase(extension, ".hpp") or
            std.ascii.eqlIgnoreCase(extension, ".hxx") or
            std.ascii.eqlIgnoreCase(extension, ".h++") or
            std.ascii.eqlIgnoreCase(extension, ".ipp") or
            std.ascii.eqlIgnoreCase(extension, ".inl") or
            std.ascii.eqlIgnoreCase(extension, ".ixx") or
            std.ascii.eqlIgnoreCase(extension, ".tcc") or
            std.ascii.eqlIgnoreCase(extension, ".tpp"))
        {
            return .cpp;
        }
        if (std.ascii.eqlIgnoreCase(extension, ".go")) return .go;
        if (std.ascii.eqlIgnoreCase(extension, ".java")) return .java;
        if (std.ascii.eqlIgnoreCase(extension, ".lua")) return .lua;
        if (std.ascii.eqlIgnoreCase(extension, ".py") or
            std.ascii.eqlIgnoreCase(extension, ".pyw"))
        {
            return .python;
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
        if (std.ascii.eqlIgnoreCase(name, "javascript") or
            std.ascii.eqlIgnoreCase(name, "js") or
            std.ascii.eqlIgnoreCase(name, "jsx") or
            std.ascii.eqlIgnoreCase(name, "mjs") or
            std.ascii.eqlIgnoreCase(name, "cjs"))
        {
            return .javascript;
        }
        if (std.ascii.eqlIgnoreCase(name, "typescript") or
            std.ascii.eqlIgnoreCase(name, "ts"))
        {
            return .typescript;
        }
        if (std.ascii.eqlIgnoreCase(name, "tsx")) return .tsx;
        if (std.ascii.eqlIgnoreCase(name, "rust") or
            std.ascii.eqlIgnoreCase(name, "rs"))
        {
            return .rust;
        }
        if (std.ascii.eqlIgnoreCase(name, "c")) return .c;
        if (std.ascii.eqlIgnoreCase(name, "c++") or
            std.ascii.eqlIgnoreCase(name, "cpp") or
            std.ascii.eqlIgnoreCase(name, "cxx") or
            std.ascii.eqlIgnoreCase(name, "cc"))
        {
            return .cpp;
        }
        if (std.ascii.eqlIgnoreCase(name, "go") or
            std.ascii.eqlIgnoreCase(name, "golang"))
        {
            return .go;
        }
        if (std.ascii.eqlIgnoreCase(name, "java")) return .java;
        if (std.ascii.eqlIgnoreCase(name, "lua")) return .lua;
        if (std.ascii.eqlIgnoreCase(name, "python") or
            std.ascii.eqlIgnoreCase(name, "py") or
            std.ascii.eqlIgnoreCase(name, "python3") or
            std.ascii.eqlIgnoreCase(name, "py3"))
        {
            return .python;
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
            .javascript => .{
                .language = tree_sitter_javascript(),
                .color_query = javascript_query,
            },
            .typescript => .{
                .language = tree_sitter_typescript(),
                .color_query = typescript_query,
            },
            .tsx => .{
                .language = tree_sitter_tsx(),
                .color_query = typescript_query,
            },
            .rust => .{
                .language = tree_sitter_rust(),
                .color_query = rust_query,
            },
            .c => .{
                .language = tree_sitter_c(),
                .color_query = c_query,
            },
            .cpp => .{
                .language = tree_sitter_cpp(),
                .color_query = cpp_query,
            },
            .go => .{
                .language = tree_sitter_go(),
                .color_query = go_query,
            },
            .java => .{
                .language = tree_sitter_java(),
                .color_query = java_query,
            },
            .lua => .{
                .language = tree_sitter_lua(),
                .color_query = lua_query,
            },
            .python => .{
                .language = tree_sitter_python(),
                .color_query = python_query,
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
    return (try parseSpans(
        allocator,
        language,
        source,
        false,
        false,
    )) orelse
        unreachable;
}

pub fn completeSpans(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
) ![]Span {
    return (try completeSpansChecked(allocator, language, source)) orelse
        allocator.alloc(Span, 0);
}

pub fn completeSpansChecked(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
) !?[]Span {
    return parseSpans(allocator, language, source, true, true);
}

pub fn completeDocumentSpansChecked(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
) !?[]Span {
    return parseSpans(allocator, language, source, true, false);
}

fn parseSpans(
    allocator: std.mem.Allocator,
    language: Language,
    source: []const u8,
    require_complete: bool,
    require_signature: bool,
) !?[]Span {
    if (require_complete and source.len > max_source_bytes) {
        return null;
    }
    const bounded_source = source[0..@min(source.len, max_source_bytes)];
    if (bounded_source.len == 0) {
        return try allocator.alloc(Span, 0);
    }

    const definition = language.definition();
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(definition.language);
    const tree = parser.parseString(bounded_source, null) orelse {
        if (require_complete) return null;
        return try allocator.alloc(Span, 0);
    };
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
            (require_signature and
                !try satisfiesRequirement(
                    definition,
                    bounded_source,
                    root,
                ))))
    {
        return null;
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
    return try result.toOwnedSlice(allocator);
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
    const path_cases = [_]struct { []const u8, Language }{
        .{ "build.zig.zon", .zig },
        .{ "script.sh", .bash },
        .{ "data.json", .json },
        .{ "workflow.YML", .yaml },
        .{ "change.patch", .diff },
        .{ "app.js", .javascript },
        .{ "component.JSX", .javascript },
        .{ "module.mjs", .javascript },
        .{ "config.cjs", .javascript },
        .{ "types.ts", .typescript },
        .{ "component.tsx", .tsx },
        .{ "main.rs", .rust },
        .{ "main.c", .c },
        .{ "header.h", .c },
        .{ "main.cc", .cpp },
        .{ "main.cpp", .cpp },
        .{ "main.cxx", .cpp },
        .{ "main.c++", .cpp },
        .{ "header.hh", .cpp },
        .{ "header.hpp", .cpp },
        .{ "header.hxx", .cpp },
        .{ "header.h++", .cpp },
        .{ "template.ipp", .cpp },
        .{ "template.inl", .cpp },
        .{ "module.ixx", .cpp },
        .{ "template.tcc", .cpp },
        .{ "template.tpp", .cpp },
        .{ "main.go", .go },
        .{ "Main.java", .java },
        .{ "init.lua", .lua },
        .{ "script.py", .python },
        .{ "window.pyw", .python },
    };
    for (path_cases) |case| {
        try std.testing.expectEqual(case[1], Language.fromPath(case[0]).?);
    }

    const fence_cases = [_]struct { []const u8, Language }{
        .{ "JSON", .json },
        .{ "patch", .diff },
        .{ "javascript", .javascript },
        .{ "js", .javascript },
        .{ "jsx", .javascript },
        .{ "mjs", .javascript },
        .{ "cjs", .javascript },
        .{ "typescript", .typescript },
        .{ "ts", .typescript },
        .{ "tsx", .tsx },
        .{ "rust", .rust },
        .{ "rs", .rust },
        .{ "c", .c },
        .{ "c++", .cpp },
        .{ "cpp", .cpp },
        .{ "cxx", .cpp },
        .{ "cc", .cpp },
        .{ "go", .go },
        .{ "golang", .go },
        .{ "java", .java },
        .{ "lua", .lua },
        .{ "python", .python },
        .{ "py", .python },
        .{ "python3", .python },
        .{ "py3", .python },
    };
    for (fence_cases) |case| {
        try std.testing.expectEqual(
            case[1],
            Language.fromMarkdownName(case[0]).?,
        );
    }

    try std.testing.expect(Language.fromPath("README.md") == null);
}

fn expectTokenSlice(
    language: Language,
    source: []const u8,
    expected_token: Token,
    expected_text: []const u8,
) !void {
    const highlighted = try spans(std.testing.allocator, language, source);
    defer std.testing.allocator.free(highlighted);
    for (highlighted) |span| {
        if (span.token == expected_token and
            std.mem.eql(u8, source[span.start..span.end], expected_text))
        {
            return;
        }
    }
    return error.ExpectedTokenSlice;
}

test "new languages produce semantic spans for literal source slices" {
    try expectTokenSlice(
        .javascript,
        "function greet() { return 1; }",
        .function,
        "greet",
    );
    try expectTokenSlice(
        .typescript,
        "interface User { name: string }",
        .keyword,
        "interface",
    );
    try expectTokenSlice(
        .tsx,
        "const view = <Button title=\"Save\" />;",
        .string,
        "\"Save\"",
    );
    try expectTokenSlice(.rust, "fn greet() -> i32 { 1 }", .function, "greet");
    try expectTokenSlice(.c, "int main(void) { return 0; }", .function, "main");
    try expectTokenSlice(
        .cpp,
        "class Widget { public: int size() { return 1; } };",
        .keyword,
        "class",
    );
    try expectTokenSlice(
        .go,
        "func greet() string { return \"hi\" }",
        .function,
        "greet",
    );
    try expectTokenSlice(
        .java,
        "class App { void greet() {} }",
        .function,
        "greet",
    );
    try expectTokenSlice(
        .lua,
        "function greet() return \"hi\" end",
        .function,
        "greet",
    );
    try expectTokenSlice(
        .python,
        "def greet():\n    return \"hi\"\n",
        .function,
        "greet",
    );
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

    const complete = try completeSpans(std.testing.allocator, .json, source);
    defer std.testing.allocator.free(complete);
    try std.testing.expectEqual(@as(usize, 0), complete.len);
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
