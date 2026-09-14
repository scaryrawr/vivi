// Derived from tree-sitter/zig-tree-sitter. See third_party/zig-tree-sitter/LICENSE.
pub const Language = opaque {};

pub const Parser = opaque {
    pub fn create() *Parser {
        return ts_parser_new();
    }

    pub fn destroy(self: *Parser) void {
        ts_parser_delete(self);
    }

    pub fn setLanguage(
        self: *Parser,
        language: *const Language,
    ) error{IncompatibleLanguage}!void {
        if (!ts_parser_set_language(self, language)) {
            return error.IncompatibleLanguage;
        }
    }

    pub fn parseString(
        self: *Parser,
        source: []const u8,
        old_tree: ?*const Tree,
    ) ?*Tree {
        return ts_parser_parse_string(
            self,
            old_tree,
            source.ptr,
            @intCast(source.len),
        );
    }
};

pub const Tree = opaque {
    pub fn destroy(self: *Tree) void {
        ts_tree_delete(self);
    }

    pub fn rootNode(self: *const Tree) Node {
        return ts_tree_root_node(self);
    }
};

pub const Node = extern struct {
    context: [4]u32,
    id: *const anyopaque,
    tree: *const Tree,

    pub fn startByte(self: Node) u32 {
        return ts_node_start_byte(self);
    }

    pub fn endByte(self: Node) u32 {
        return ts_node_end_byte(self);
    }
};

const QueryError = enum(c_uint) {
    none,
    syntax,
    node_type,
    field,
    capture,
    structure,
    language,
};

pub const Query = opaque {
    pub const Error = error{
        InvalidSyntax,
        InvalidNodeType,
        InvalidField,
        InvalidCapture,
        InvalidStructure,
        InvalidLanguage,
    };

    pub const Capture = extern struct {
        node: Node,
        index: u32,
    };

    pub const Match = struct {
        id: u32,
        pattern_index: u16,
        captures: []const Capture,
    };

    pub fn create(
        language: *const Language,
        source: []const u8,
        error_offset: *u32,
    ) Error!*Query {
        var error_type: QueryError = .none;
        return ts_query_new(
            language,
            source.ptr,
            @intCast(source.len),
            error_offset,
            &error_type,
        ) orelse switch (error_type) {
            .syntax => error.InvalidSyntax,
            .node_type => error.InvalidNodeType,
            .field => error.InvalidField,
            .capture => error.InvalidCapture,
            .structure => error.InvalidStructure,
            .language => error.InvalidLanguage,
            .none => unreachable,
        };
    }

    pub fn destroy(self: *Query) void {
        ts_query_delete(self);
    }

    pub fn captureNameForId(self: *const Query, index: u32) ?[]const u8 {
        var length: u32 = 0;
        const name = ts_query_capture_name_for_id(self, index, &length);
        return if (length == 0) null else name[0..length];
    }
};

const QueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*c]const Query.Capture,

    fn into(self: QueryMatch) Query.Match {
        return .{
            .id = self.id,
            .pattern_index = self.pattern_index,
            .captures = if (self.capture_count == 0)
                &.{}
            else
                self.captures[0..self.capture_count],
        };
    }
};

pub const QueryCursor = opaque {
    pub fn create() *QueryCursor {
        return ts_query_cursor_new();
    }

    pub fn destroy(self: *QueryCursor) void {
        ts_query_cursor_delete(self);
    }

    pub fn exec(self: *QueryCursor, query: *const Query, node: Node) void {
        ts_query_cursor_exec(self, query, node);
    }

    pub fn nextCapture(self: *QueryCursor) ?struct { u32, Query.Match } {
        var index: u32 = 0;
        var match: QueryMatch = undefined;
        if (!ts_query_cursor_next_capture(self, &match, &index)) return null;
        return .{ index, match.into() };
    }
};

extern fn ts_parser_new() *Parser;
extern fn ts_parser_delete(parser: *Parser) void;
extern fn ts_parser_set_language(
    parser: *Parser,
    language: *const Language,
) bool;
extern fn ts_parser_parse_string(
    parser: *Parser,
    old_tree: ?*const Tree,
    source: [*c]const u8,
    length: u32,
) ?*Tree;

extern fn ts_tree_delete(tree: *Tree) void;
extern fn ts_tree_root_node(tree: *const Tree) Node;
extern fn ts_node_start_byte(node: Node) u32;
extern fn ts_node_end_byte(node: Node) u32;

extern fn ts_query_new(
    language: *const Language,
    source: [*c]const u8,
    source_len: u32,
    error_offset: *u32,
    error_type: *QueryError,
) ?*Query;
extern fn ts_query_delete(query: *Query) void;
extern fn ts_query_capture_name_for_id(
    query: *const Query,
    index: u32,
    length: *u32,
) [*c]const u8;

extern fn ts_query_cursor_new() *QueryCursor;
extern fn ts_query_cursor_delete(cursor: *QueryCursor) void;
extern fn ts_query_cursor_exec(
    cursor: *QueryCursor,
    query: *const Query,
    node: Node,
) void;
extern fn ts_query_cursor_next_capture(
    cursor: *QueryCursor,
    match: *QueryMatch,
    capture_index: *u32,
) bool;
