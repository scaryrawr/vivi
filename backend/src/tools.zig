const std = @import("std");
const tool_activity = @import("tool_activity.zig");
const image = @import("image.zig");

pub const Descriptor = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const descriptors = [_]Descriptor{
    .{
        .name = "read",
        .description = "Read UTF-8 text or a PNG, JPEG, GIF, or WebP image from a file. Images are returned as image content, not text. Paths may be absolute or relative to the workspace. For text only, offset is an optional 1-indexed first line and limit is an optional positive number of lines. Returns the selected text without Vivi-side truncation.",
        .parameters_json =
        \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string","minLength":1},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"]}
        ,
    },
    .{
        .name = "bash",
        .description = "Run a Bash command in the workspace. timeout is optional, defaults to 120 seconds, and may not exceed 600 seconds. Returns combined stdout and stderr without Vivi-side truncation.",
        .parameters_json =
        \\{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string","minLength":1},"timeout":{"type":"number","exclusiveMinimum":0,"maximum":600}},"required":["command"]}
        ,
    },
    .{
        .name = "edit",
        .description = "Edit one text file using exact replacements. Every oldText must be non-empty, occur exactly once in the original file, and not overlap another edit. All matches are planned before one write.",
        .parameters_json =
        \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string","minLength":1},"edits":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,"properties":{"oldText":{"type":"string","minLength":1},"newText":{"type":"string"}},"required":["oldText","newText"]}}},"required":["path","edits"]}
        ,
    },
    .{
        .name = "write",
        .description = "Create or overwrite a file with exact content. Paths may be absolute or relative to the workspace. Missing parent directories are created.",
        .parameters_json =
        \\{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string","minLength":1},"content":{"type":"string"}},"required":["path","content"]}
        ,
    },
};

pub const Result = union(enum) {
    text: []u8,
    image: image.Image,
    failure: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text, .failure => |bytes| allocator.free(bytes),
            .image => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

const ReadArguments = struct {
    path: []const u8,
    offset: ?usize = null,
    limit: ?usize = null,
};

const BashArguments = struct {
    command: []const u8,
    timeout: ?f64 = null,
};

const TextEdit = struct {
    oldText: []const u8,
    newText: []const u8,
};

const EditArguments = struct {
    path: []const u8,
    edits: []const TextEdit,
};

const WriteArguments = struct {
    path: []const u8,
    content: []const u8,
};

pub const PreparedCall = struct {
    allocator: std.mem.Allocator,
    arguments_json: []u8,
    operation: Operation,

    const Operation = union(enum) {
        read: std.json.Parsed(ReadArguments),
        bash: std.json.Parsed(BashArguments),
        edit: std.json.Parsed(EditArguments),
        write: std.json.Parsed(WriteArguments),
        rejected: struct {
            tool_name: []u8,
            message: []u8,
        },
    };

    pub fn started(
        self: *const PreparedCall,
        allocator: std.mem.Allocator,
        call_id: []const u8,
    ) !tool_activity.ToolStarted {
        const summary: tool_activity.ToolSummary = switch (self.operation) {
            .read => |parsed| .{ .read = .{
                .path = parsed.value.path,
                .offset = parsed.value.offset,
                .limit = parsed.value.limit,
            } },
            .bash => |parsed| .{ .bash = .{
                .command = parsed.value.command,
            } },
            .edit => |parsed| .{ .edit = .{
                .path = parsed.value.path,
                .replacement_count = parsed.value.edits.len,
            } },
            .write => |parsed| .{ .write = .{
                .path = parsed.value.path,
                .byte_count = parsed.value.content.len,
            } },
            .rejected => |rejected_call| .{ .other = .{
                .name = rejected_call.tool_name,
            } },
        };
        return tool_activity.ToolStarted.init(
            allocator,
            call_id,
            self.arguments_json,
            summary,
        );
    }

    pub fn deinit(self: *PreparedCall) void {
        self.allocator.free(self.arguments_json);
        switch (self.operation) {
            .read => |*parsed| parsed.deinit(),
            .bash => |*parsed| parsed.deinit(),
            .edit => |*parsed| parsed.deinit(),
            .write => |*parsed| parsed.deinit(),
            .rejected => |rejected_call| {
                self.allocator.free(rejected_call.tool_name);
                self.allocator.free(rejected_call.message);
            },
        }
        self.* = undefined;
    }
};

const Replacement = struct {
    start: usize,
    end: usize,
    new_text: []const u8,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace: []const u8,
    ) !Service {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace = try allocator.dupe(u8, workspace),
        };
    }

    pub fn deinit(self: *Service) void {
        self.allocator.free(self.workspace);
        self.* = undefined;
    }

    pub fn prepare(
        self: *Service,
        name: []const u8,
        arguments_json: []const u8,
    ) !PreparedCall {
        const owned_arguments = try self.allocator.dupe(u8, arguments_json);
        errdefer self.allocator.free(owned_arguments);
        if (std.mem.eql(u8, name, "read")) {
            var parsed = self.parse(ReadArguments, arguments_json) catch |err|
                return self.rejectedParse(owned_arguments, name, err);
            validateReadArguments(parsed.value) catch |err| {
                parsed.deinit();
                return self.rejectedExecution(owned_arguments, name, err);
            };
            return .{
                .allocator = self.allocator,
                .arguments_json = owned_arguments,
                .operation = .{ .read = parsed },
            };
        }
        if (std.mem.eql(u8, name, "bash")) {
            var parsed = self.parse(BashArguments, arguments_json) catch |err|
                return self.rejectedParse(owned_arguments, name, err);
            validateBashArguments(parsed.value) catch |err| {
                parsed.deinit();
                return self.rejectedExecution(owned_arguments, name, err);
            };
            return .{
                .allocator = self.allocator,
                .arguments_json = owned_arguments,
                .operation = .{ .bash = parsed },
            };
        }
        if (std.mem.eql(u8, name, "edit")) {
            var parsed = self.parse(EditArguments, arguments_json) catch |err|
                return self.rejectedParse(owned_arguments, name, err);
            validateEditArguments(parsed.value) catch |err| {
                parsed.deinit();
                return self.rejectedExecution(owned_arguments, name, err);
            };
            return .{
                .allocator = self.allocator,
                .arguments_json = owned_arguments,
                .operation = .{ .edit = parsed },
            };
        }
        if (std.mem.eql(u8, name, "write")) {
            var parsed = self.parse(WriteArguments, arguments_json) catch |err|
                return self.rejectedParse(owned_arguments, name, err);
            validateWriteArguments(parsed.value) catch |err| {
                parsed.deinit();
                return self.rejectedExecution(owned_arguments, name, err);
            };
            return .{
                .allocator = self.allocator,
                .arguments_json = owned_arguments,
                .operation = .{ .write = parsed },
            };
        }
        const tool_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(tool_name);
        return .{
            .allocator = self.allocator,
            .arguments_json = owned_arguments,
            .operation = .{ .rejected = .{
                .tool_name = tool_name,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Vivi does not provide tool \"{s}\".",
                    .{name},
                ),
            } },
        };
    }

    pub fn execute(
        self: *Service,
        prepared: *const PreparedCall,
    ) !Result {
        return switch (prepared.operation) {
            .read => |parsed| self.runRead(parsed.value) catch |err|
                self.toolFailure("read", err),
            .bash => |parsed| self.runBash(parsed.value) catch |err|
                self.toolFailure("bash", err),
            .edit => |parsed| self.runEdit(parsed.value) catch |err|
                self.toolFailure("edit", err),
            .write => |parsed| self.runWrite(parsed.value) catch |err|
                self.toolFailure("write", err),
            .rejected => |rejected_call| .{
                .failure = try self.allocator.dupe(u8, rejected_call.message),
            },
        };
    }

    fn parse(
        self: *Service,
        comptime Arguments: type,
        arguments_json: []const u8,
    ) !std.json.Parsed(Arguments) {
        return std.json.parseFromSlice(
            Arguments,
            self.allocator,
            arguments_json,
            .{ .allocate = .alloc_always },
        );
    }

    fn rejectedParse(
        self: *Service,
        arguments_json: []u8,
        name: []const u8,
        err: anyerror,
    ) !PreparedCall {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const tool_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(tool_name);
        return .{
            .allocator = self.allocator,
            .arguments_json = arguments_json,
            .operation = .{ .rejected = .{
                .tool_name = tool_name,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Invalid {s} arguments: {s}.",
                    .{ name, @errorName(err) },
                ),
            } },
        };
    }

    fn rejectedExecution(
        self: *Service,
        arguments_json: []u8,
        name: []const u8,
        err: anyerror,
    ) !PreparedCall {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const tool_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(tool_name);
        return .{
            .allocator = self.allocator,
            .arguments_json = arguments_json,
            .operation = .{ .rejected = .{
                .tool_name = tool_name,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "{s} failed: {s}.",
                    .{ name, @errorName(err) },
                ),
            } },
        };
    }

    fn toolFailure(
        self: *Service,
        name: []const u8,
        err: anyerror,
    ) !Result {
        return self.failure("{s} failed: {s}.", .{ name, @errorName(err) });
    }

    fn resolvePath(self: *Service, input: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(input)) {
            return std.fs.path.resolve(self.allocator, &.{input});
        }
        return std.fs.path.resolve(self.allocator, &.{ self.workspace, input });
    }

    fn runRead(self: *Service, arguments: ReadArguments) !Result {
        const path = try self.resolvePath(arguments.path);
        defer self.allocator.free(path);

        const content = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .unlimited,
        );
        defer self.allocator.free(content);
        if (image.detect(content)) |format| {
            if (content.len > image.max_bytes) return error.ImageTooLarge;
            if (arguments.offset != null or arguments.limit != null) {
                return self.failure(
                    "offset and limit select text lines and cannot be used with images.",
                    .{},
                );
            }
            const description = try std.fmt.allocPrint(
                self.allocator,
                "Image: {s} ({s}, {d} bytes)",
                .{ arguments.path, format.mimeType(), content.len },
            );
            errdefer self.allocator.free(description);
            return .{ .image = .{
                .bytes = try self.allocator.dupe(u8, content),
                .format = format,
                .description = description,
            } };
        }
        if (std.mem.indexOfScalar(u8, content, 0) != null)
            return error.UnsupportedBinaryFile;
        if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;

        const offset = arguments.offset orelse 1;
        const limit = arguments.limit orelse std.math.maxInt(usize);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(self.allocator);
        var iterator = std.mem.splitScalar(u8, content, '\n');
        while (iterator.next()) |line| try lines.append(self.allocator, line);

        if (offset > lines.items.len) {
            return self.failure(
                "Offset {d} is beyond end of file ({d} lines total).",
                .{ offset, lines.items.len },
            );
        }

        const start = offset - 1;
        const end = @min(lines.items.len, start +| limit);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        for (lines.items[start..end], 0..) |line, index| {
            if (index != 0) try output.append(self.allocator, '\n');
            try output.appendSlice(self.allocator, line);
        }
        return .{ .text = try output.toOwnedSlice(self.allocator) };
    }

    fn runBash(self: *Service, arguments: BashArguments) !Result {
        const timeout_seconds = arguments.timeout orelse 120;

        const script = try std.fmt.allocPrint(
            self.allocator,
            "exec 2>&1\n{s}",
            .{arguments.command},
        );
        defer self.allocator.free(script);
        const milliseconds: i64 = @intFromFloat(timeout_seconds * 1000);
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ "bash", "-c", script },
            .cwd = .{ .path = self.workspace },
            .timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(milliseconds),
                .clock = .awake,
            } },
        }) catch |err| {
            if (err == error.Timeout) {
                return self.failure(
                    "Command timed out after {d} seconds.",
                    .{timeout_seconds},
                );
            }
            return error.BashUnavailable;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const output = if (result.stdout.len > 0)
            result.stdout
        else if (result.stderr.len > 0)
            result.stderr
        else
            "(no output)";

        return switch (result.term) {
            .exited => |code| if (code == 0)
                .{ .text = try self.allocator.dupe(u8, output) }
            else
                self.failure(
                    "{s}\n\nCommand exited with code {d}.",
                    .{ output, code },
                ),
            .signal => |signal| self.failure(
                "{s}\n\nCommand terminated by signal {d}.",
                .{ output, @intFromEnum(signal) },
            ),
            .stopped => |signal| self.failure(
                "{s}\n\nCommand stopped by signal {d}.",
                .{ output, @intFromEnum(signal) },
            ),
            .unknown => |status| self.failure(
                "{s}\n\nCommand ended with unknown status {d}.",
                .{ output, status },
            ),
        };
    }

    fn runEdit(self: *Service, arguments: EditArguments) !Result {
        const path = try self.resolvePath(arguments.path);
        defer self.allocator.free(path);

        const raw = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .unlimited,
        );
        defer self.allocator.free(raw);
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;

        const has_bom = std.mem.startsWith(u8, raw, "\xEF\xBB\xBF");
        const content = if (has_bom) raw[3..] else raw;
        const line_ending: []const u8 =
            if (std.mem.indexOf(u8, content, "\r\n") != null) "\r\n" else "\n";
        const normalized = try normalizeLines(self.allocator, content);
        defer self.allocator.free(normalized);

        var replacements: std.ArrayList(Replacement) = .empty;
        defer replacements.deinit(self.allocator);
        for (arguments.edits) |edit_value| {
            const old_text = try normalizeLines(self.allocator, edit_value.oldText);
            defer self.allocator.free(old_text);
            const new_text = try normalizeLines(self.allocator, edit_value.newText);
            errdefer self.allocator.free(new_text);

            const first = std.mem.indexOf(u8, normalized, old_text) orelse
                return error.OldTextNotFound;
            if (std.mem.indexOfPos(u8, normalized, first + old_text.len, old_text) != null) {
                return error.OldTextNotUnique;
            }
            try replacements.append(self.allocator, .{
                .start = first,
                .end = first + old_text.len,
                .new_text = new_text,
            });
        }
        defer for (replacements.items) |replacement|
            self.allocator.free(replacement.new_text);

        std.mem.sort(Replacement, replacements.items, {}, struct {
            fn lessThan(_: void, a: Replacement, b: Replacement) bool {
                return a.start < b.start;
            }
        }.lessThan);
        for (replacements.items[1..], replacements.items[0 .. replacements.items.len - 1]) |
            current,
            previous,
        | {
            if (current.start < previous.end) return error.OverlappingEdits;
        }

        var changed: std.ArrayList(u8) = .empty;
        defer changed.deinit(self.allocator);
        var cursor: usize = 0;
        for (replacements.items) |replacement| {
            try changed.appendSlice(self.allocator, normalized[cursor..replacement.start]);
            try changed.appendSlice(self.allocator, replacement.new_text);
            cursor = replacement.end;
        }
        try changed.appendSlice(self.allocator, normalized[cursor..]);
        if (std.mem.eql(u8, normalized, changed.items)) return error.NoChanges;

        const restored = try restoreLines(self.allocator, changed.items, line_ending);
        defer self.allocator.free(restored);
        var final: std.ArrayList(u8) = .empty;
        defer final.deinit(self.allocator);
        if (has_bom) try final.appendSlice(self.allocator, "\xEF\xBB\xBF");
        try final.appendSlice(self.allocator, restored);
        try writeFile(self.io, path, final.items);

        return self.text(
            "Successfully replaced {d} block(s) in {s}.",
            .{ arguments.edits.len, arguments.path },
        );
    }

    fn runWrite(self: *Service, arguments: WriteArguments) !Result {
        const path = try self.resolvePath(arguments.path);
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
        }
        try writeFile(self.io, path, arguments.content);
        return self.text("Successfully wrote to {s}.", .{arguments.path});
    }

    fn text(self: *Service, comptime format: []const u8, args: anytype) !Result {
        return .{ .text = try std.fmt.allocPrint(self.allocator, format, args) };
    }

    fn failure(self: *Service, comptime format: []const u8, args: anytype) !Result {
        return .{ .failure = try std.fmt.allocPrint(self.allocator, format, args) };
    }
};

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidPath;
    }
}

fn validateReadArguments(arguments: ReadArguments) !void {
    try validatePath(arguments.path);
    if ((arguments.offset orelse 1) == 0 or
        (arguments.limit orelse 1) == 0)
    {
        return error.InvalidLineRange;
    }
}

fn validateBashArguments(arguments: BashArguments) !void {
    if (arguments.command.len == 0) return error.EmptyCommand;
    const timeout_seconds = arguments.timeout orelse 120;
    if (!std.math.isFinite(timeout_seconds) or
        timeout_seconds <= 0 or
        timeout_seconds > 600)
    {
        return error.InvalidTimeout;
    }
}

fn validateEditArguments(arguments: EditArguments) !void {
    try validatePath(arguments.path);
    if (arguments.edits.len == 0) return error.EmptyEdits;
    for (arguments.edits) |edit_value| {
        if (edit_value.oldText.len == 0) return error.EmptyOldText;
    }
}

fn validateWriteArguments(arguments: WriteArguments) !void {
    try validatePath(arguments.path);
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
        .flags = .{},
    });
}

fn normalizeLines(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (input[index] == '\r') {
            try output.append(allocator, '\n');
            if (index + 1 < input.len and input[index + 1] == '\n') index += 1;
        } else {
            try output.append(allocator, input[index]);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn restoreLines(
    allocator: std.mem.Allocator,
    input: []const u8,
    line_ending: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, line_ending, "\n")) return allocator.dupe(u8, input);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        if (byte == '\n') {
            try output.appendSlice(allocator, "\r\n");
        } else {
            try output.append(allocator, byte);
        }
    }
    return output.toOwnedSlice(allocator);
}

test "read selects one-indexed lines without truncation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.txt",
        .data = "one\ntwo\nthree\nfour",
        .flags = .{},
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
    );
    defer service.deinit();

    var prepared = try service.prepare("read",
        \\{"path":"sample.txt","offset":2,"limit":2}
    );
    defer prepared.deinit();
    var result = try service.execute(&prepared);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("two\nthree", result.text);
}

test "read tool returns image bytes and MIME independently of extension" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(std.testing.allocator, std.testing.io, path_buffer[0..path_len]);
    defer service.deinit();

    const cases = .{
        .{ "\x89PNG\r\n\x1a\n\x00", image.Format.png },
        .{ "\xff\xd8\xff\xe0\x00", image.Format.jpeg },
        .{ "GIF89a\x00", image.Format.gif },
        .{ "RIFF\x00\x00\x00\x00WEBP", image.Format.webp },
    };
    inline for (cases) |case| {
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "picture.dat", .data = case[0] });
        var prepared = try service.prepare("read", "{\"path\":\"picture.dat\"}");
        defer prepared.deinit();
        var result = try service.execute(&prepared);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .image);
        try std.testing.expectEqualStrings(case[0], result.image.bytes);
        try std.testing.expectEqual(case[1], result.image.format);
        try std.testing.expect(std.mem.indexOf(u8, result.image.description, "picture.dat") != null);
    }
}

test "read tool rejects image line ranges and unsupported binary data" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(std.testing.allocator, std.testing.io, path_buffer[0..path_len]);
    defer service.deinit();

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "image.png", .data = "\x89PNG\r\n\x1a\n" });
    for ([_][]const u8{
        "{\"path\":\"image.png\",\"offset\":1}",
        "{\"path\":\"image.png\",\"limit\":1}",
    }) |arguments| {
        var prepared = try service.prepare("read", arguments);
        defer prepared.deinit();
        var result = try service.execute(&prepared);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .failure);
        try std.testing.expect(std.mem.indexOf(u8, result.failure, "cannot be used with images") != null);
    }
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "binary", .data = "abc\x00def" });
    var prepared = try service.prepare("read", "{\"path\":\"binary\"}");
    defer prepared.deinit();
    var result = try service.execute(&prepared);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("read failed: UnsupportedBinaryFile.", result.failure);
}

test "edit plans replacements against original content" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.txt",
        .data = "\xEF\xBB\xBFone\r\ntwo\r\n",
        .flags = .{},
    });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
    );
    defer service.deinit();

    var prepared = try service.prepare("edit",
        \\{"path":"sample.txt","edits":[{"oldText":"one","newText":"two"},{"oldText":"two","newText":"three\nfour"}]}
    );
    defer prepared.deinit();
    var result = try service.execute(&prepared);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .text);

    const content = try temporary.dir.readFileAlloc(
        std.testing.io,
        "sample.txt",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBFtwo\r\nthree\r\nfour\r\n",
        content,
    );
}

test "write creates parents and overwrites exact bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
    );
    defer service.deinit();

    var prepared = try service.prepare("write",
        \\{"path":"nested/sample.txt","content":"hello\n"}
    );
    defer prepared.deinit();
    var result = try service.execute(&prepared);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .text);

    const content = try temporary.dir.readFileAlloc(
        std.testing.io,
        "nested/sample.txt",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello\n", content);
}

test "bash returns complete output and status" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
    );
    defer service.deinit();

    var prepared_success = try service.prepare("bash",
        \\{"command":"printf out; printf err >&2"}
    );
    defer prepared_success.deinit();
    var success = try service.execute(&prepared_success);
    defer success.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("outerr", success.text);

    var prepared_failure = try service.prepare("bash",
        \\{"command":"printf nope; exit 7"}
    );
    defer prepared_failure.deinit();
    var failure = try service.execute(&prepared_failure);
    defer failure.deinit(std.testing.allocator);
    try std.testing.expect(failure == .failure);
    try std.testing.expect(std.mem.indexOf(u8, failure.failure, "code 7") != null);
}

test "prepare derives built-in summaries from executable arguments" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();

    const cases = [_]struct {
        name: []const u8,
        arguments: []const u8,
    }{
        .{
            .name = "read",
            .arguments = "{\"path\":\"a.txt\",\"offset\":2,\"limit\":3}",
        },
        .{
            .name = "bash",
            .arguments = "{\"command\":\"printf hi\"}",
        },
        .{
            .name = "edit",
            .arguments = "{\"path\":\"a.txt\",\"edits\":[{\"oldText\":\"a\",\"newText\":\"b\"},{\"oldText\":\"c\",\"newText\":\"d\"}]}",
        },
        .{
            .name = "write",
            .arguments = "{\"path\":\"a.txt\",\"content\":\"hello\"}",
        },
    };

    for (cases, 0..) |case, index| {
        var prepared = try service.prepare(case.name, case.arguments);
        defer prepared.deinit();
        var started = try prepared.started(
            std.testing.allocator,
            "call",
        );
        defer started.deinit();
        try std.testing.expectEqualStrings(
            case.arguments,
            started.invocation.arguments_json,
        );
        switch (index) {
            0 => {
                const summary = started.invocation.summary.read;
                try std.testing.expectEqualStrings("a.txt", summary.path);
                try std.testing.expectEqual(@as(?usize, 2), summary.offset);
                try std.testing.expectEqual(@as(?usize, 3), summary.limit);
            },
            1 => try std.testing.expectEqualStrings(
                "printf hi",
                started.invocation.summary.bash.command,
            ),
            2 => {
                const summary = started.invocation.summary.edit;
                try std.testing.expectEqualStrings("a.txt", summary.path);
                try std.testing.expectEqual(
                    @as(usize, 2),
                    summary.replacement_count,
                );
            },
            3 => {
                const summary = started.invocation.summary.write;
                try std.testing.expectEqualStrings("a.txt", summary.path);
                try std.testing.expectEqual(@as(usize, 5), summary.byte_count);
            },
            else => unreachable,
        }
    }
}

test "prepare keeps malformed and unknown tools visible and failing" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();

    const cases = [_]struct {
        name: []const u8,
        arguments: []const u8,
        failure_prefix: []const u8,
    }{
        .{
            .name = "read",
            .arguments = "{\"path\":",
            .failure_prefix = "Invalid read arguments:",
        },
        .{
            .name = "bash",
            .arguments = "{\"command\":\"\"}",
            .failure_prefix = "bash failed: EmptyCommand.",
        },
        .{
            .name = "search",
            .arguments = "{}",
            .failure_prefix = "Vivi does not provide tool \"search\".",
        },
    };
    for (cases) |case| {
        var prepared = try service.prepare(case.name, case.arguments);
        defer prepared.deinit();
        var started = try prepared.started(std.testing.allocator, "call");
        defer started.deinit();
        try std.testing.expectEqualStrings(
            case.name,
            started.invocation.summary.other.name,
        );
        var result = try service.execute(&prepared);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result == .failure);
        try std.testing.expect(std.mem.startsWith(
            u8,
            result.failure,
            case.failure_prefix,
        ));
    }
}
