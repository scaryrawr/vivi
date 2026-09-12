const std = @import("std");
const image = @import("image.zig");

pub const ToolCallId = struct {
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, value: []const u8) !ToolCallId {
        if (value.len == 0) return error.EmptyToolCallId;
        return .{ .bytes = try allocator.dupe(u8, value) };
    }

    pub fn clone(self: ToolCallId, allocator: std.mem.Allocator) !ToolCallId {
        return init(allocator, self.bytes);
    }

    pub fn eql(self: ToolCallId, other: ToolCallId) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }

    pub fn deinit(self: *ToolCallId, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const ReadSummary = struct {
    path: []const u8,
    offset: ?usize,
    limit: ?usize,
};

pub const BashSummary = struct {
    command: []const u8,
};

pub const EditSummary = struct {
    path: []const u8,
    replacement_count: usize,
};

pub const WriteSummary = struct {
    path: []const u8,
    byte_count: usize,
};

pub const OtherSummary = struct {
    name: []const u8,
};

pub const ToolSummary = union(enum) {
    read: ReadSummary,
    bash: BashSummary,
    edit: EditSummary,
    write: WriteSummary,
    other: OtherSummary,

    pub fn clone(self: ToolSummary, allocator: std.mem.Allocator) !ToolSummary {
        return switch (self) {
            .read => |summary| .{ .read = .{
                .path = try allocator.dupe(u8, summary.path),
                .offset = summary.offset,
                .limit = summary.limit,
            } },
            .bash => |summary| .{ .bash = .{
                .command = try allocator.dupe(u8, summary.command),
            } },
            .edit => |summary| .{ .edit = .{
                .path = try allocator.dupe(u8, summary.path),
                .replacement_count = summary.replacement_count,
            } },
            .write => |summary| .{ .write = .{
                .path = try allocator.dupe(u8, summary.path),
                .byte_count = summary.byte_count,
            } },
            .other => |summary| .{ .other = .{
                .name = try allocator.dupe(u8, summary.name),
            } },
        };
    }

    pub fn eql(self: ToolSummary, other: ToolSummary) bool {
        return switch (self) {
            .read => |value| switch (other) {
                .read => |candidate| std.mem.eql(u8, value.path, candidate.path) and
                    value.offset == candidate.offset and value.limit == candidate.limit,
                else => false,
            },
            .bash => |value| switch (other) {
                .bash => |candidate| std.mem.eql(u8, value.command, candidate.command),
                else => false,
            },
            .edit => |value| switch (other) {
                .edit => |candidate| std.mem.eql(u8, value.path, candidate.path) and
                    value.replacement_count == candidate.replacement_count,
                else => false,
            },
            .write => |value| switch (other) {
                .write => |candidate| std.mem.eql(u8, value.path, candidate.path) and
                    value.byte_count == candidate.byte_count,
                else => false,
            },
            .other => |value| switch (other) {
                .other => |candidate| std.mem.eql(u8, value.name, candidate.name),
                else => false,
            },
        };
    }

    pub fn deinit(self: *ToolSummary, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .read => |summary| allocator.free(summary.path),
            .bash => |summary| allocator.free(summary.command),
            .edit => |summary| allocator.free(summary.path),
            .write => |summary| allocator.free(summary.path),
            .other => |summary| allocator.free(summary.name),
        }
        self.* = undefined;
    }
};

pub const ToolInvocation = struct {
    arguments_json: []u8,
    summary: ToolSummary,

    pub fn clone(
        self: ToolInvocation,
        allocator: std.mem.Allocator,
    ) !ToolInvocation {
        const arguments_json = try allocator.dupe(u8, self.arguments_json);
        errdefer allocator.free(arguments_json);
        return .{
            .arguments_json = arguments_json,
            .summary = try self.summary.clone(allocator),
        };
    }

    pub fn eql(self: ToolInvocation, other: ToolInvocation) bool {
        return std.mem.eql(u8, self.arguments_json, other.arguments_json) and
            self.summary.eql(other.summary);
    }

    pub fn deinit(
        self: *ToolInvocation,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.arguments_json);
        self.summary.deinit(allocator);
        self.* = undefined;
    }
};

pub const ToolResult = union(enum) {
    succeeded: []u8,
    image: image.Image,
    failed: []u8,

    pub fn clone(self: ToolResult, allocator: std.mem.Allocator) !ToolResult {
        return switch (self) {
            .succeeded => |text| .{ .succeeded = try allocator.dupe(u8, text) },
            .image => |value| .{ .image = try value.clone(allocator) },
            .failed => |text| .{ .failed = try allocator.dupe(u8, text) },
        };
    }

    pub fn eql(self: ToolResult, other: ToolResult) bool {
        return switch (self) {
            .succeeded => |text| switch (other) {
                .succeeded => |candidate| std.mem.eql(u8, text, candidate),
                .failed, .image => false,
            },
            .failed => |text| switch (other) {
                .succeeded, .image => false,
                .failed => |candidate| std.mem.eql(u8, text, candidate),
            },
            .image => |value| switch (other) {
                .image => |candidate| value.eql(candidate),
                .succeeded, .failed => false,
            },
        };
    }

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .succeeded, .failed => |text| allocator.free(text),
            .image => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ToolLifecycle = union(enum) {
    running,
    finished: ToolResult,
};

pub const ToolStarted = struct {
    allocator: std.mem.Allocator,
    call_id: ToolCallId,
    invocation: ToolInvocation,

    pub fn init(
        allocator: std.mem.Allocator,
        call_id: []const u8,
        arguments_json: []const u8,
        summary: ToolSummary,
    ) !ToolStarted {
        const owned_call_id = try ToolCallId.init(allocator, call_id);
        errdefer {
            var mutable = owned_call_id;
            mutable.deinit(allocator);
        }
        const owned_arguments = try allocator.dupe(u8, arguments_json);
        errdefer allocator.free(owned_arguments);
        return .{
            .allocator = allocator,
            .call_id = owned_call_id,
            .invocation = .{
                .arguments_json = owned_arguments,
                .summary = try summary.clone(allocator),
            },
        };
    }

    pub fn eql(self: ToolStarted, other: ToolStarted) bool {
        return self.call_id.eql(other.call_id) and
            self.invocation.eql(other.invocation);
    }

    pub fn deinit(self: *ToolStarted) void {
        self.call_id.deinit(self.allocator);
        self.invocation.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const ToolFinished = struct {
    allocator: std.mem.Allocator,
    call_id: ToolCallId,
    result: ToolResult,

    pub fn init(
        allocator: std.mem.Allocator,
        call_id: []const u8,
        result: union(enum) {
            succeeded: []const u8,
            image: image.Image,
            failed: []const u8,
        },
    ) !ToolFinished {
        const owned_call_id = try ToolCallId.init(allocator, call_id);
        errdefer {
            var mutable = owned_call_id;
            mutable.deinit(allocator);
        }
        return .{
            .allocator = allocator,
            .call_id = owned_call_id,
            .result = switch (result) {
                .succeeded => |text| .{
                    .succeeded = try allocator.dupe(u8, text),
                },
                .image => |value| .{ .image = try value.clone(allocator) },
                .failed => |text| .{
                    .failed = try allocator.dupe(u8, text),
                },
            },
        };
    }

    pub fn eql(self: ToolFinished, other: ToolFinished) bool {
        return self.call_id.eql(other.call_id) and self.result.eql(other.result);
    }

    pub fn deinit(self: *ToolFinished) void {
        self.call_id.deinit(self.allocator);
        self.result.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const ToolActivityUpdate = union(enum) {
    started: ToolStarted,
    finished: ToolFinished,

    pub fn deinit(self: *ToolActivityUpdate) void {
        switch (self.*) {
            .started => |*value| value.deinit(),
            .finished => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

pub const ToolActivity = struct {
    allocator: std.mem.Allocator,
    call_id: ToolCallId,
    invocation: ToolInvocation,
    lifecycle: ToolLifecycle = .running,

    pub fn init(
        allocator: std.mem.Allocator,
        started: *const ToolStarted,
    ) !ToolActivity {
        const call_id = try started.call_id.clone(allocator);
        errdefer {
            var mutable = call_id;
            mutable.deinit(allocator);
        }
        return .{
            .allocator = allocator,
            .call_id = call_id,
            .invocation = try started.invocation.clone(allocator),
        };
    }

    pub fn matchesStart(
        self: ToolActivity,
        started: *const ToolStarted,
    ) bool {
        return self.call_id.eql(started.call_id) and
            self.invocation.eql(started.invocation);
    }

    pub fn finish(
        self: *ToolActivity,
        update: *const ToolFinished,
    ) !void {
        if (!self.call_id.eql(update.call_id)) return error.MismatchedToolCall;
        switch (self.lifecycle) {
            .running => {
                self.lifecycle = .{
                    .finished = try update.result.clone(self.allocator),
                };
            },
            .finished => |result| {
                if (!result.eql(update.result)) {
                    return error.ConflictingToolCompletion;
                }
            },
        }
    }

    pub fn deinit(self: *ToolActivity) void {
        self.call_id.deinit(self.allocator);
        self.invocation.deinit(self.allocator);
        switch (self.lifecycle) {
            .running => {},
            .finished => |*result| result.deinit(self.allocator),
        }
        self.* = undefined;
    }
};

test "image tool completion owns bytes and compares image content" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, "original pixels");
    var finished = try ToolFinished.init(allocator, "read-image", .{ .image = .{
        .bytes = bytes,
        .format = .png,
        .description = "picture.png",
    } });
    defer finished.deinit();
    allocator.free(bytes);
    var copied = try finished.result.clone(allocator);
    defer copied.deinit(allocator);
    try std.testing.expectEqualStrings("original pixels", copied.image.bytes);
    try std.testing.expect(finished.result.eql(copied));
    var different = try ToolFinished.init(allocator, "read-image", .{ .image = .{
        .bytes = "different pixels",
        .format = .png,
        .description = "picture.png",
    } });
    defer different.deinit();
    try std.testing.expect(!finished.eql(different));
}

test "tool activity accepts equal duplicate finish and rejects conflict" {
    const summary = ToolSummary{ .other = .{ .name = "search" } };
    var started = try ToolStarted.init(
        std.testing.allocator,
        "call-1",
        "{}",
        summary,
    );
    defer started.deinit();
    var activity = try ToolActivity.init(std.testing.allocator, &started);
    defer activity.deinit();
    var first = try ToolFinished.init(
        std.testing.allocator,
        "call-1",
        .{ .succeeded = "ok" },
    );
    defer first.deinit();
    var duplicate = try ToolFinished.init(
        std.testing.allocator,
        "call-1",
        .{ .succeeded = "ok" },
    );
    defer duplicate.deinit();
    var conflict = try ToolFinished.init(
        std.testing.allocator,
        "call-1",
        .{ .failed = "no" },
    );
    defer conflict.deinit();

    try activity.finish(&first);
    try activity.finish(&duplicate);
    try std.testing.expectError(
        error.ConflictingToolCompletion,
        activity.finish(&conflict),
    );
}
