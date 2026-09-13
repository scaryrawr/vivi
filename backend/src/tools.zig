const std = @import("std");
const bash_sessions = @import("bash_sessions.zig");
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
        .description = "Run commands or manage persistent Bash PTYs. action defaults to run. run requires command and accepts timeout (default 120 seconds, maximum 600). start requires command and returns a shell_id. list takes no other fields. read requires shell_id and accepts max_bytes (default 16384, maximum 32768) and wait_ms (default 100, maximum 5000). write requires shell_id and data, with encoding utf8 (default) or base64; decoded input may not exceed 16384 bytes. stop requires shell_id and is idempotent.",
        .parameters_json =
        \\{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string","enum":["run","start","list","read","write","stop"],"default":"run"},"command":{"type":"string","minLength":1},"timeout":{"type":"number","exclusiveMinimum":0,"maximum":600},"shell_id":{"type":"string","pattern":"^bash_[0-9A-Fa-f]{32}$"},"max_bytes":{"type":"integer","minimum":1,"maximum":32768},"wait_ms":{"type":"integer","minimum":0,"maximum":5000},"data":{"type":"string"},"encoding":{"type":"string","enum":["utf8","base64"]}}}
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

const BashAction = tool_activity.BashAction;

const BashArguments = struct {
    action: BashAction = .run,
    command: ?[]const u8 = null,
    timeout: ?f64 = null,
    shell_id: ?[]const u8 = null,
    max_bytes: ?usize = null,
    wait_ms: ?u32 = null,
    data: ?[]const u8 = null,
    encoding: ?bash_sessions.Encoding = null,
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

const RunBash = struct {
    command: []const u8,
    timeout_seconds: f64,
};

const StartBash = struct {
    command: []const u8,
};

const ReadBash = struct {
    id: bash_sessions.ShellId,
    shell_id: []const u8,
    max_bytes: usize,
    wait_ms: u32,
};

const WriteBash = struct {
    id: bash_sessions.ShellId,
    shell_id: []const u8,
    bytes: []const u8,
};

const StopBash = struct {
    id: bash_sessions.ShellId,
    shell_id: []const u8,
};

const BashOperation = union(BashAction) {
    run: RunBash,
    start: StartBash,
    list: void,
    read: ReadBash,
    write: WriteBash,
    stop: StopBash,
};

const PreparedBash = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(BashArguments),
    decoded_input: ?[]u8,
    operation: BashOperation,

    fn init(
        allocator: std.mem.Allocator,
        parsed_value: std.json.Parsed(BashArguments),
    ) !PreparedBash {
        var parsed = parsed_value;
        errdefer parsed.deinit();
        var decoded_input: ?[]u8 = null;
        errdefer if (decoded_input) |bytes| allocator.free(bytes);
        const arguments = parsed.value;
        const operation: BashOperation = switch (arguments.action) {
            .run => blk: {
                if (arguments.shell_id != null or
                    arguments.max_bytes != null or
                    arguments.wait_ms != null or
                    arguments.data != null or
                    arguments.encoding != null)
                {
                    return error.UnexpectedBashArgument;
                }
                const command = arguments.command orelse
                    return error.MissingCommand;
                try validateCommand(command);
                const timeout_seconds = arguments.timeout orelse 120;
                try validateTimeout(timeout_seconds);
                break :blk .{ .run = .{
                    .command = command,
                    .timeout_seconds = timeout_seconds,
                } };
            },
            .start => blk: {
                if (arguments.timeout != null)
                    return error.AsyncTimeoutUnsupported;
                if (arguments.shell_id != null or
                    arguments.max_bytes != null or
                    arguments.wait_ms != null or
                    arguments.data != null or
                    arguments.encoding != null)
                {
                    return error.UnexpectedBashArgument;
                }
                const command = arguments.command orelse
                    return error.MissingCommand;
                try validateCommand(command);
                break :blk .{ .start = .{ .command = command } };
            },
            .list => blk: {
                if (arguments.command != null or
                    arguments.timeout != null or
                    arguments.shell_id != null or
                    arguments.max_bytes != null or
                    arguments.wait_ms != null or
                    arguments.data != null or
                    arguments.encoding != null)
                {
                    return error.UnexpectedBashArgument;
                }
                break :blk .list;
            },
            .read => blk: {
                if (arguments.command != null or
                    arguments.timeout != null or
                    arguments.data != null or
                    arguments.encoding != null)
                {
                    return error.UnexpectedBashArgument;
                }
                const shell_id = arguments.shell_id orelse
                    return error.MissingShellId;
                const id = try bash_sessions.ShellId.parse(shell_id);
                const max_bytes = arguments.max_bytes orelse
                    bash_sessions.default_read_bytes;
                if (max_bytes == 0 or max_bytes > bash_sessions.max_read_bytes)
                    return error.InvalidReadLimit;
                const wait_ms = arguments.wait_ms orelse
                    bash_sessions.default_wait_ms;
                if (wait_ms > bash_sessions.max_wait_ms)
                    return error.InvalidWait;
                break :blk .{ .read = .{
                    .id = id,
                    .shell_id = shell_id,
                    .max_bytes = max_bytes,
                    .wait_ms = wait_ms,
                } };
            },
            .write => blk: {
                if (arguments.command != null or
                    arguments.timeout != null or
                    arguments.max_bytes != null or
                    arguments.wait_ms != null)
                {
                    return error.UnexpectedBashArgument;
                }
                const shell_id = arguments.shell_id orelse
                    return error.MissingShellId;
                const id = try bash_sessions.ShellId.parse(shell_id);
                const data = arguments.data orelse return error.MissingData;
                const bytes = switch (arguments.encoding orelse .utf8) {
                    .utf8 => data,
                    .base64 => decoded: {
                        const decoder = std.base64.standard.Decoder;
                        if (data.len > std.base64.standard.Encoder.calcSize(
                            bash_sessions.max_write_bytes,
                        )) return error.InputTooLarge;
                        const size = decoder.calcSizeForSlice(data) catch
                            return error.InvalidBase64;
                        if (size > bash_sessions.max_write_bytes)
                            return error.InputTooLarge;
                        const buffer = try allocator.alloc(u8, size);
                        errdefer allocator.free(buffer);
                        decoder.decode(buffer, data) catch
                            return error.InvalidBase64;
                        decoded_input = buffer;
                        break :decoded buffer;
                    },
                };
                if (bytes.len > bash_sessions.max_write_bytes)
                    return error.InputTooLarge;
                break :blk .{ .write = .{
                    .id = id,
                    .shell_id = shell_id,
                    .bytes = bytes,
                } };
            },
            .stop => blk: {
                if (arguments.command != null or
                    arguments.timeout != null or
                    arguments.max_bytes != null or
                    arguments.wait_ms != null or
                    arguments.data != null or
                    arguments.encoding != null)
                {
                    return error.UnexpectedBashArgument;
                }
                const shell_id = arguments.shell_id orelse
                    return error.MissingShellId;
                break :blk .{ .stop = .{
                    .id = try bash_sessions.ShellId.parse(shell_id),
                    .shell_id = shell_id,
                } };
            },
        };
        return .{
            .allocator = allocator,
            .parsed = parsed,
            .decoded_input = decoded_input,
            .operation = operation,
        };
    }

    fn deinit(self: *PreparedBash) void {
        if (self.decoded_input) |bytes| self.allocator.free(bytes);
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const PreparedCall = struct {
    allocator: std.mem.Allocator,
    arguments_json: []u8,
    operation: Operation,

    const Operation = union(enum) {
        read: std.json.Parsed(ReadArguments),
        bash: PreparedBash,
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
            .bash => |prepared| .{ .bash = bashSummary(prepared.operation) },
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
            .bash => |*prepared| prepared.deinit(),
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
    bash_manager: ?*bash_sessions.Manager = null,

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
        if (self.bash_manager) |manager_ptr| {
            manager_ptr.deinit();
            self.allocator.destroy(manager_ptr);
        }
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
            const parsed = self.parse(BashArguments, arguments_json) catch |err|
                return self.rejectedParse(owned_arguments, name, err);
            const prepared = PreparedBash.init(self.allocator, parsed) catch |err| {
                return self.rejectedExecution(owned_arguments, name, err);
            };
            return .{
                .allocator = self.allocator,
                .arguments_json = owned_arguments,
                .operation = .{ .bash = prepared },
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
        call: *const PreparedCall,
    ) !Result {
        return switch (call.operation) {
            .read => |parsed| self.runRead(parsed.value) catch |err|
                self.toolFailure("read", err),
            .bash => |prepared| self.runBash(prepared.operation) catch |err|
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

    fn parsePrepared(
        self: *Service,
        comptime Arguments: type,
        owned_arguments: []u8,
        name: []const u8,
        arguments_json: []const u8,
        comptime tag: std.meta.Tag(PreparedCall.Operation),
    ) !PreparedCall {
        const parsed = self.parse(Arguments, arguments_json) catch |err|
            return self.rejectedParse(owned_arguments, name, err);
        return .{
            .allocator = self.allocator,
            .arguments_json = owned_arguments,
            .operation = @unionInit(PreparedCall.Operation, @tagName(tag), parsed),
        };
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

        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        var prefix_buffer: [12]u8 = undefined;
        var reader = file.reader(self.io, &prefix_buffer);
        const prefix = reader.interface.peek(prefix_buffer.len) catch |err| switch (err) {
            error.EndOfStream => reader.interface.buffered(),
            error.ReadFailed => return reader.err.?,
        };
        const format = image.detect(prefix);
        if (format != null and (try file.stat(self.io)).size > image.max_bytes)
            return error.ImageTooLarge;
        const content = reader.interface.allocRemaining(
            self.allocator,
            if (format != null) .limited(image.max_bytes) else .unlimited,
        ) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => return error.ImageTooLarge,
            error.OutOfMemory => return err,
        };
        defer self.allocator.free(content);
        if (format) |image_format| {
            if (arguments.offset != null or arguments.limit != null) {
                return self.failure(
                    "offset and limit select text lines and cannot be used with images.",
                    .{},
                );
            }
            const description = try std.fmt.allocPrint(
                self.allocator,
                "Image: {s} ({s}, {d} bytes)",
                .{ arguments.path, image_format.mimeType(), content.len },
            );
            errdefer self.allocator.free(description);
            return .{ .image = .{
                .bytes = try self.allocator.dupe(u8, content),
                .format = image_format,
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

    fn runBash(self: *Service, operation: BashOperation) !Result {
        return switch (operation) {
            .run => |arguments| self.runSynchronousBash(
                arguments.command,
                arguments.timeout_seconds,
            ),
            .start => |arguments| self.runAsyncBash(arguments.command),
            .list => self.runListBash(),
            .read => |arguments| self.runReadBash(arguments),
            .write => |arguments| self.runWriteBash(arguments),
            .stop => |arguments| self.runStopBash(arguments),
        };
    }

    fn runSynchronousBash(
        self: *Service,
        command: []const u8,
        timeout_seconds: f64,
    ) !Result {
        const script = try std.fmt.allocPrint(
            self.allocator,
            "exec 2>&1\n{s}",
            .{command},
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

    fn getBashManager(self: *Service) !*bash_sessions.Manager {
        if (self.bash_manager) |manager_ptr| return manager_ptr;
        const manager_ptr = try self.allocator.create(bash_sessions.Manager);
        errdefer self.allocator.destroy(manager_ptr);
        manager_ptr.* = try bash_sessions.Manager.init(
            self.allocator,
            self.io,
            self.workspace,
            .{},
        );
        self.bash_manager = manager_ptr;
        return manager_ptr;
    }

    fn runAsyncBash(
        self: *Service,
        command: []const u8,
    ) !Result {
        const manager_ptr = try self.getBashManager();
        var started = try manager_ptr.start(.{
            .command = command,
        });
        defer started.output.deinit();
        errdefer _ = manager_ptr.stop(started.id) catch {};
        return .{ .text = try formatStart(self.allocator, started) };
    }

    fn runListBash(self: *Service) !Result {
        const manager_ptr = self.bash_manager orelse
            return .{ .text = try self.allocator.dupe(u8, "{\"sessions\":[]}") };
        const snapshots = try manager_ptr.list(self.allocator);
        defer self.allocator.free(snapshots);
        const JsonSnapshot = struct {
            shell_id: []const u8,
            state: []const u8,
            exit: ?JsonExit,
            unread_bytes: usize,
            dropped_bytes: u64,
        };
        const values = try self.allocator.alloc(JsonSnapshot, snapshots.len);
        defer self.allocator.free(values);
        const ids = try self.allocator.alloc([37]u8, snapshots.len);
        defer self.allocator.free(ids);
        for (snapshots, values, ids) |snapshot, *value, *id_buffer| {
            value.* = .{
                .shell_id = snapshot.id.format(id_buffer),
                .state = stateName(snapshot.state),
                .exit = stateExit(snapshot.state),
                .unread_bytes = snapshot.unread_bytes,
                .dropped_bytes = snapshot.dropped_bytes,
            };
        }
        return .{ .text = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .sessions = values },
            .{},
        ) };
    }

    fn runReadBash(
        self: *Service,
        arguments: ReadBash,
    ) !Result {
        const manager_ptr = self.bash_manager orelse return error.UnknownShell;
        var result = try manager_ptr.read(
            self.allocator,
            arguments.id,
            arguments.max_bytes,
            arguments.wait_ms,
        );
        defer result.output.deinit();
        return .{ .text = try formatRead(self.allocator, result) };
    }

    fn runWriteBash(
        self: *Service,
        arguments: WriteBash,
    ) !Result {
        const manager_ptr = self.bash_manager orelse return error.UnknownShell;
        const result = try manager_ptr.write(
            arguments.id,
            arguments.bytes,
        );
        var id_buffer: [37]u8 = undefined;
        return .{ .text = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{
                .shell_id = result.id.format(&id_buffer),
                .state = stateName(result.state),
                .exit = stateExit(result.state),
                .accepted_bytes = result.accepted_bytes,
            },
            .{},
        ) };
    }

    fn runStopBash(
        self: *Service,
        arguments: StopBash,
    ) !Result {
        const stopped = if (self.bash_manager) |manager_ptr|
            try manager_ptr.stop(arguments.id)
        else
            bash_sessions.StopResult{ .id = arguments.id, .was_present = false };
        var id_buffer: [37]u8 = undefined;
        return .{ .text = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{
                .shell_id = stopped.id.format(&id_buffer),
                .was_present = stopped.was_present,
            },
            .{},
        ) };
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

fn validateCommand(command: []const u8) !void {
    if (command.len == 0) return error.EmptyCommand;
    if (std.mem.indexOfScalar(u8, command, 0) != null)
        return error.InvalidCommand;
}

fn validateTimeout(timeout_seconds: f64) !void {
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

const JsonExit = struct {
    kind: []const u8,
    value: ?u32,
};

fn stateName(state: bash_sessions.State) []const u8 {
    return switch (state) {
        .running => "running",
        .exited => "exited",
    };
}

fn bashSummary(operation: BashOperation) tool_activity.BashSummary {
    return switch (operation) {
        .run => |arguments| .{ .run = .{ .command = arguments.command } },
        .start => |arguments| .{ .start = .{ .command = arguments.command } },
        .list => .list,
        .read => |arguments| .{ .read = .{
            .shell_id = arguments.shell_id,
        } },
        .write => |arguments| .{ .write = .{
            .shell_id = arguments.shell_id,
        } },
        .stop => |arguments| .{ .stop = .{
            .shell_id = arguments.shell_id,
        } },
    };
}

fn stateExit(state: bash_sessions.State) ?JsonExit {
    return switch (state) {
        .running => null,
        .exited => |value| switch (value) {
            .code => |code| .{ .kind = "code", .value = code },
            .signal => |signal| .{ .kind = "signal", .value = signal },
            .terminated => .{ .kind = "terminated", .value = null },
            .unknown => .{ .kind = "unknown", .value = null },
        },
    };
}

fn formatStart(
    allocator: std.mem.Allocator,
    result: bash_sessions.StartResult,
) ![]u8 {
    var id_buffer: [37]u8 = undefined;
    return std.json.Stringify.valueAlloc(allocator, .{
        .shell_id = result.id.format(&id_buffer),
        .state = stateName(result.state),
        .exit = stateExit(result.state),
        .output = result.output.bytes,
        .encoding = @tagName(result.output.encoding),
        .more = result.output.more,
        .dropped_bytes = result.output.dropped_bytes,
    }, .{});
}

fn formatRead(
    allocator: std.mem.Allocator,
    result: bash_sessions.ReadResult,
) ![]u8 {
    var id_buffer: [37]u8 = undefined;
    return std.json.Stringify.valueAlloc(allocator, .{
        .shell_id = result.id.format(&id_buffer),
        .state = stateName(result.state),
        .exit = stateExit(result.state),
        .output = result.output.bytes,
        .encoding = @tagName(result.output.encoding),
        .more = result.output.more,
        .dropped_bytes = result.output.dropped_bytes,
    }, .{});
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

test "read rejects oversized images before allocating their contents" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "large.png", .{});
    {
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\n");
        try file.setLength(std.testing.io, image.max_bytes + 1);
    }
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var memory: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var service = try Service.init(fixed.allocator(), std.testing.io, path_buffer[0..path_len]);
    defer service.deinit();
    var prepared = try service.prepare("read", "{\"path\":\"large.png\"}");
    defer prepared.deinit();
    var result = try service.execute(&prepared);
    defer result.deinit(fixed.allocator());
    try std.testing.expectEqualStrings("read failed: ImageTooLarge.", result.failure);
}

test "read text remains unlimited beyond the image byte limit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "large.txt", .{});
    {
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "first\n");
        const block = [_]u8{'a'} ** 4096;
        for (0..image.max_bytes / block.len + 1) |_| try file.writeStreamingAll(std.testing.io, &block);
    }
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var service = try Service.init(std.testing.allocator, std.testing.io, path_buffer[0..path_len]);
    defer service.deinit();
    var prepared = try service.prepare("read", "{\"path\":\"large.txt\",\"limit\":1}");
    defer prepared.deinit();
    var result = try service.execute(&prepared);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first", result.text);
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

test "async bash starts, lists, accepts input, reads, and stops idempotently" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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

    var start_call = try service.prepare("bash",
        \\{"action":"start","command":"read line; printf 'TOOL:%s\\n' \"$line\""}
    );
    defer start_call.deinit();
    var start_result = try service.execute(&start_call);
    defer start_result.deinit(std.testing.allocator);
    try std.testing.expect(start_result == .text);
    var start_json = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        start_result.text,
        .{},
    );
    defer start_json.deinit();
    const shell_id = start_json.value.object.get("shell_id").?.string;
    try std.testing.expectEqual(@as(usize, 37), shell_id.len);

    var list_call = try service.prepare("bash", "{\"action\":\"list\"}");
    defer list_call.deinit();
    var list_result = try service.execute(&list_call);
    defer list_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list_result.text, shell_id) != null);

    const write_arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{ .action = "write", .shell_id = shell_id, .data = "ready\n" },
        .{},
    );
    defer std.testing.allocator.free(write_arguments);
    var write_call = try service.prepare("bash", write_arguments);
    defer write_call.deinit();
    var write_result = try service.execute(&write_call);
    defer write_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        write_result.text,
        "\"accepted_bytes\":6",
    ) != null);

    const read_arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{ .action = "read", .shell_id = shell_id, .wait_ms = 500 },
        .{},
    );
    defer std.testing.allocator.free(read_arguments);
    var found = false;
    for (0..10) |_| {
        var read_call = try service.prepare("bash", read_arguments);
        defer read_call.deinit();
        var read_result = try service.execute(&read_call);
        defer read_result.deinit(std.testing.allocator);
        if (std.mem.indexOf(u8, read_result.text, "TOOL:ready") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    const stop_arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{ .action = "stop", .shell_id = shell_id },
        .{},
    );
    defer std.testing.allocator.free(stop_arguments);
    for ([_]bool{ true, false }) |was_present| {
        var stop_call = try service.prepare("bash", stop_arguments);
        defer stop_call.deinit();
        var stop_result = try service.execute(&stop_call);
        defer stop_result.deinit(std.testing.allocator);
        const expected = if (was_present)
            "\"was_present\":true"
        else
            "\"was_present\":false";
        try std.testing.expect(std.mem.indexOf(
            u8,
            stop_result.text,
            expected,
        ) != null);
    }
}

test "bash prepares every action with defaults" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();

    var sync_call = try service.prepare("bash", "{\"command\":\"printf sync\"}");
    defer sync_call.deinit();
    try std.testing.expectEqual(
        @as(f64, 120),
        sync_call.operation.bash.operation.run.timeout_seconds,
    );

    const shell_id = "bash_0123456789abcdef0123456789abcdef";
    var read_call = try service.prepare(
        "bash",
        "{\"action\":\"read\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\"}",
    );
    defer read_call.deinit();
    try std.testing.expectEqual(
        @as(usize, bash_sessions.default_read_bytes),
        read_call.operation.bash.operation.read.max_bytes,
    );
    try std.testing.expectEqual(
        bash_sessions.default_wait_ms,
        read_call.operation.bash.operation.read.wait_ms,
    );

    var write_call = try service.prepare(
        "bash",
        "{\"action\":\"write\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"data\":\"input\"}",
    );
    defer write_call.deinit();
    try std.testing.expectEqualStrings(
        "input",
        write_call.operation.bash.operation.write.bytes,
    );
    try std.testing.expectEqualStrings(
        shell_id,
        write_call.operation.bash.operation.write.shell_id,
    );
}

test "bash rejects missing and action-forbidden fields during prepare" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();

    const cases = [_]struct {
        arguments: []const u8,
        expected: []const u8,
    }{
        .{ .arguments = "{}", .expected = "bash failed: MissingCommand." },
        .{ .arguments = "{\"action\":\"start\"}", .expected = "bash failed: MissingCommand." },
        .{ .arguments = "{\"action\":\"read\"}", .expected = "bash failed: MissingShellId." },
        .{ .arguments = "{\"action\":\"write\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\"}", .expected = "bash failed: MissingData." },
        .{ .arguments = "{\"action\":\"stop\"}", .expected = "bash failed: MissingShellId." },
        .{ .arguments = "{\"command\":\"true\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\"}", .expected = "bash failed: UnexpectedBashArgument." },
        .{ .arguments = "{\"action\":\"start\",\"command\":\"true\",\"timeout\":1}", .expected = "bash failed: AsyncTimeoutUnsupported." },
        .{ .arguments = "{\"action\":\"list\",\"command\":\"true\"}", .expected = "bash failed: UnexpectedBashArgument." },
        .{ .arguments = "{\"action\":\"read\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"data\":\"x\"}", .expected = "bash failed: UnexpectedBashArgument." },
        .{ .arguments = "{\"action\":\"write\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"data\":\"x\",\"wait_ms\":1}", .expected = "bash failed: UnexpectedBashArgument." },
        .{ .arguments = "{\"action\":\"stop\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"encoding\":\"utf8\"}", .expected = "bash failed: UnexpectedBashArgument." },
    };
    for (cases) |case| {
        var rejected = try service.prepare("bash", case.arguments);
        defer rejected.deinit();
        var result = try service.execute(&rejected);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.failure);
    }
}

test "bash actions expose operation-specific activity summaries" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();
    const shell_id = "bash_0123456789abcdef0123456789abcdef";
    const cases = [_]struct {
        arguments: []const u8,
        action: tool_activity.BashAction,
    }{
        .{
            .arguments = "{\"command\":\"true\"}",
            .action = .run,
        },
        .{
            .arguments = "{\"action\":\"start\",\"command\":\"sleep 1\"}",
            .action = .start,
        },
        .{ .arguments = "{\"action\":\"list\"}", .action = .list },
        .{
            .arguments = "{\"action\":\"read\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\"}",
            .action = .read,
        },
        .{
            .arguments = "{\"action\":\"write\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"data\":\"x\"}",
            .action = .write,
        },
        .{
            .arguments = "{\"action\":\"stop\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\"}",
            .action = .stop,
        },
    };
    for (cases) |case| {
        var prepared = try service.prepare("bash", case.arguments);
        defer prepared.deinit();
        var started = try prepared.started(std.testing.allocator, "call");
        defer started.deinit();
        const summary = started.invocation.summary.bash;
        try std.testing.expectEqual(case.action, std.meta.activeTag(summary));
        switch (summary) {
            .read => |value| {
                try std.testing.expectEqualStrings(shell_id, value.shell_id);
            },
            .write => |value| {
                try std.testing.expectEqualStrings(shell_id, value.shell_id);
            },
            .stop => |value| {
                try std.testing.expectEqualStrings(shell_id, value.shell_id);
            },
            else => {},
        }
    }
}

test "async Bash validates IDs, limits, and base64 before execution" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();
    const cases = [_]struct {
        arguments: []const u8,
        expected: []const u8,
    }{
        .{
            .arguments = "{\"command\":\"true\",\"timeout\":0}",
            .expected = "bash failed: InvalidTimeout.",
        },
        .{
            .arguments = "{\"command\":\"true\",\"timeout\":601}",
            .expected = "bash failed: InvalidTimeout.",
        },
        .{
            .arguments = "{\"action\":\"read\",\"shell_id\":\"bad\",\"wait_ms\":6000}",
            .expected = "bash failed: InvalidShellId.",
        },
        .{
            .arguments = "{\"action\":\"read\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"max_bytes\":0}",
            .expected = "bash failed: InvalidReadLimit.",
        },
        .{
            .arguments = "{\"action\":\"read\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"max_bytes\":32769}",
            .expected = "bash failed: InvalidReadLimit.",
        },
        .{
            .arguments = "{\"action\":\"read\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"wait_ms\":5001}",
            .expected = "bash failed: InvalidWait.",
        },
        .{
            .arguments = "{\"action\":\"write\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"data\":\"%%%\",\"encoding\":\"base64\"}",
            .expected = "bash failed: InvalidBase64.",
        },
    };
    for (cases) |case| {
        var prepared = try service.prepare("bash", case.arguments);
        defer prepared.deinit();
        var result = try service.execute(&prepared);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.failure);
    }

    const oversized = try std.testing.allocator.alloc(
        u8,
        bash_sessions.max_write_bytes + 1,
    );
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    const arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{
            .action = "write",
            .shell_id = "bash_0123456789abcdef0123456789abcdef",
            .data = oversized,
        },
        .{},
    );
    defer std.testing.allocator.free(arguments);
    var rejected = try service.prepare("bash", arguments);
    defer rejected.deinit();
    var result = try service.execute(&rejected);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "bash failed: InputTooLarge.",
        result.failure,
    );

    const oversized_base64 = try std.testing.allocator.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(
            bash_sessions.max_write_bytes,
        ) + 4,
    );
    defer std.testing.allocator.free(oversized_base64);
    @memset(oversized_base64, 'A');
    const base64_arguments = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{
            .action = "write",
            .shell_id = "bash_0123456789abcdef0123456789abcdef",
            .data = oversized_base64,
            .encoding = "base64",
        },
        .{},
    );
    defer std.testing.allocator.free(base64_arguments);
    var rejected_base64 = try service.prepare("bash", base64_arguments);
    defer rejected_base64.deinit();
    var base64_result = try service.execute(&rejected_base64);
    defer base64_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "bash failed: InputTooLarge.",
        base64_result.failure,
    );
}

test "prepared Bash owns parsed strings and decoded base64 input" {
    var service = try Service.init(
        std.testing.allocator,
        std.testing.io,
        ".",
    );
    defer service.deinit();
    const mutable_arguments = try std.testing.allocator.dupe(
        u8,
        "{\"action\":\"write\",\"shell_id\":\"bash_0123456789abcdef0123456789abcdef\",\"data\":\"/w==\",\"encoding\":\"base64\"}",
    );
    var prepared = try service.prepare("bash", mutable_arguments);
    std.testing.allocator.free(mutable_arguments);
    defer prepared.deinit();

    try std.testing.expectEqualSlices(
        u8,
        &.{0xff},
        prepared.operation.bash.operation.write.bytes,
    );
    var started = try prepared.started(std.testing.allocator, "owned");
    defer started.deinit();
    try std.testing.expectEqualStrings(
        "bash_0123456789abcdef0123456789abcdef",
        started.invocation.summary.bash.write.shell_id,
    );
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
                started.invocation.summary.bash.run.command,
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
