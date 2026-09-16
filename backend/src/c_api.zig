const std = @import("std");
const backend = @import("vivi_backend");
const c = @cImport({
    @cInclude("vivi_backend.h");
});

comptime {
    if (c.VIVI_BACKEND_ABI_VERSION != backend.abi_version) {
        @compileError("C header and Zig backend ABI versions differ");
    }
}

const Handle = struct {
    io_threaded: std.Io.Threaded,
    conversation: backend.Conversation,
    wake: ?c.vivi_backend_wake_fn,
    wake_context: ?*anyopaque,
    armed: std.atomic.Value(bool) = .init(false),
    pending_wake: std.atomic.Value(bool) = .init(false),
    accepting_prompt: std.atomic.Value(bool) = .init(false),
    pending: ?backend.ConversationEvent = null,
    emit_closed_after_failure: bool = false,

    fn notify(pointer: *anyopaque) void {
        const self: *Handle = @ptrCast(@alignCast(pointer));
        if (!self.armed.load(.acquire)) {
            self.pending_wake.store(true, .release);
            if (!self.armed.load(.acquire)) return;
        }
        _ = self.pending_wake.swap(false, .acq_rel);
        if (self.wake) |wake| wake.?(self.wake_context);
    }

    fn deinit(self: *Handle) void {
        self.armed.store(false, .release);
        self.conversation.deinit();
        if (self.pending) |*event| event.deinit();
        self.io_threaded.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

fn result(error_value: anyerror) c.vivi_backend_result_t {
    return switch (error_value) {
        error.Busy => c.VIVI_BACKEND_BUSY,
        error.Stopping => c.VIVI_BACKEND_STOPPING,
        error.Closed => c.VIVI_BACKEND_CLOSED,
        error.EmptyPrompt => c.VIVI_BACKEND_INVALID_ARGUMENT,
        else => c.VIVI_BACKEND_FAILED,
    };
}

fn handle(pointer: ?*c.vivi_backend_conversation_t) ?*Handle {
    const value = pointer orelse return null;
    return @ptrCast(@alignCast(value));
}

export fn vivi_backend_open(
    options: ?*const c.vivi_backend_conversation_options_t,
    out_conversation: ?*?*c.vivi_backend_conversation_t,
) callconv(.c) c.vivi_backend_result_t {
    const input = options orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const output = out_conversation orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    output.* = null;
    const working_directory_pointer = input.working_directory orelse
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (input.working_directory_length == 0) {
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    }
    const working_directory =
        working_directory_pointer[0..input.working_directory_length];
    if (!std.fs.path.isAbsolute(working_directory)) {
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    }

    const self = std.heap.c_allocator.create(Handle) catch {
        return c.VIVI_BACKEND_FAILED;
    };
    self.io_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    self.wake = input.wake;
    self.wake_context = input.wake_context;
    self.armed = .init(false);
    self.pending_wake = .init(false);
    self.accepting_prompt = .init(false);
    self.pending = null;
    self.emit_closed_after_failure = false;
    self.conversation = backend.openConversation(
        std.heap.c_allocator,
        self.io_threaded.io(),
        .{ .context = self, .notify = Handle.notify },
        .{ .working_directory = working_directory },
    ) catch {
        self.io_threaded.deinit();
        std.heap.c_allocator.destroy(self);
        return c.VIVI_BACKEND_FAILED;
    };
    output.* = @ptrCast(self);
    self.armed.store(true, .release);
    if (self.pending_wake.swap(false, .acq_rel)) {
        if (self.wake) |wake| wake.?(self.wake_context);
    }
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_submit(
    conversation: ?*c.vivi_backend_conversation_t,
    prompt: ?[*]const u8,
    prompt_length: u32,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const bytes = prompt orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (prompt_length == 0) return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (!self.accepting_prompt.swap(false, .acq_rel)) {
        return c.VIVI_BACKEND_BUSY;
    }
    self.conversation.submit(
        .{ .text = bytes[0..prompt_length] },
        .enqueue,
    ) catch |err| {
        if (err != error.Busy and err != error.Stopping and err != error.Closed) {
            self.accepting_prompt.store(true, .release);
        }
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

fn project(event: *const backend.ConversationEvent) ?struct {
    kind: c.vivi_backend_event_kind_t,
    content: []const u8,
} {
    return switch (event.*) {
        .ready => .{ .kind = c.VIVI_BACKEND_EVENT_READY, .content = "" },
        .status => |text| .{ .kind = c.VIVI_BACKEND_EVENT_STATUS, .content = text.bytes },
        .assistant_started => .{ .kind = c.VIVI_BACKEND_EVENT_ASSISTANT_STARTED, .content = "" },
        .assistant_delta => |text| .{ .kind = c.VIVI_BACKEND_EVENT_ASSISTANT_DELTA, .content = text.bytes },
        .assistant_complete => |text| .{ .kind = c.VIVI_BACKEND_EVENT_ASSISTANT_COMPLETE, .content = text.bytes },
        .idle => .{ .kind = c.VIVI_BACKEND_EVENT_IDLE, .content = "" },
        .closed => |closed| switch (closed) {
            .requested => .{ .kind = c.VIVI_BACKEND_EVENT_CLOSED, .content = "" },
            .failed => |failure| .{ .kind = c.VIVI_BACKEND_EVENT_FAILURE, .content = failure.message.bytes },
        },
        .user_input_requested => .{
            .kind = c.VIVI_BACKEND_EVENT_FAILURE,
            .content = "Native chat cannot answer agent questions yet.",
        },
        .command_catalog,
        .model_catalog,
        .model_catalog_failed,
        .model_switch,
        .session_catalog,
        .session_catalog_failed,
        .session_tracking_failed,
        .session_resume,
        .reasoning_delta,
        .reasoning_complete,
        .tool_activity,
        .command_completed,
        => null,
    };
}

export fn vivi_backend_next_event(
    conversation: ?*c.vivi_backend_conversation_t,
    out_event: ?*c.vivi_backend_event_t,
    content: ?[*]u8,
    content_capacity: u32,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const output = out_event orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (self.emit_closed_after_failure) {
        self.emit_closed_after_failure = false;
        output.* = .{
            .kind = c.VIVI_BACKEND_EVENT_CLOSED,
            .content_kind = c.VIVI_BACKEND_CONTENT_NONE,
            .content_length = 0,
        };
        return c.VIVI_BACKEND_OK;
    }
    while (self.pending == null) {
        self.pending = self.conversation.tryTakeEvent() catch {
            return c.VIVI_BACKEND_FAILED;
        } orelse return c.VIVI_BACKEND_NO_EVENT;
        if (project(&self.pending.?) != null) break;
        self.pending.?.deinit();
        self.pending = null;
    }
    const projected = project(&self.pending.?).?;
    output.* = .{
        .kind = projected.kind,
        .content_kind = if (projected.content.len == 0)
            c.VIVI_BACKEND_CONTENT_NONE
        else
            c.VIVI_BACKEND_CONTENT_TEXT,
        .content_length = @intCast(projected.content.len),
    };
    if (content_capacity < projected.content.len) {
        return c.VIVI_BACKEND_BUFFER_TOO_SMALL;
    }
    if (projected.content.len > 0) {
        const destination = content orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
        @memcpy(destination[0..projected.content.len], projected.content);
    }
    if (projected.kind == c.VIVI_BACKEND_EVENT_FAILURE) {
        self.accepting_prompt.store(false, .release);
        self.emit_closed_after_failure = true;
        self.conversation.requestStop();
    } else if (projected.kind == c.VIVI_BACKEND_EVENT_READY or
        projected.kind == c.VIVI_BACKEND_EVENT_IDLE)
    {
        self.accepting_prompt.store(true, .release);
    } else if (projected.kind == c.VIVI_BACKEND_EVENT_CLOSED) {
        self.accepting_prompt.store(false, .release);
    }
    self.pending.?.deinit();
    self.pending = null;
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_close(
    conversation: ?*c.vivi_backend_conversation_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    self.accepting_prompt.store(false, .release);
    self.conversation.requestStop();
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_destroy(
    conversation: ?*c.vivi_backend_conversation_t,
) callconv(.c) void {
    const self = handle(conversation) orelse return;
    self.deinit();
}
