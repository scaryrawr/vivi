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
    const ControlOperation = enum {
        none,
        refresh_models,
        switch_model,
    };

    io_threaded: std.Io.Threaded,
    conversation: backend.Conversation,
    wake: c.vivi_backend_wake_fn,
    wake_context: ?*anyopaque,
    armed: std.atomic.Value(bool) = .init(false),
    pending_wake: std.atomic.Value(bool) = .init(false),
    accepting_prompt: std.atomic.Value(bool) = .init(false),
    control_operation: ControlOperation = .none,
    pending: ?backend.ConversationEvent = null,
    emit_closed_after_failure: bool = false,

    fn notify(pointer: *anyopaque) void {
        const self: *Handle = @ptrCast(@alignCast(pointer));
        if (!self.armed.load(.acquire)) {
            self.pending_wake.store(true, .release);
            if (!self.armed.load(.acquire)) return;
        }
        _ = self.pending_wake.swap(false, .acq_rel);
        if (self.wake) |wake| wake(self.wake_context);
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
        error.EmptyPrompt,
        error.EmptyModel,
        error.InvalidReasoningEffort,
        => c.VIVI_BACKEND_INVALID_ARGUMENT,
        else => c.VIVI_BACKEND_FAILED,
    };
}

fn handle(pointer: ?*c.vivi_backend_conversation_t) ?*Handle {
    const value = pointer orelse return null;
    return @ptrCast(@alignCast(value));
}

fn copilotCliLaunch(
    raw: c.vivi_backend_copilot_cli_launch_t,
) ?backend.CopilotCliLaunch {
    return switch (raw) {
        c.VIVI_BACKEND_COPILOT_CLI_SDK_DEFAULT => .sdk_default,
        c.VIVI_BACKEND_COPILOT_CLI_EXPLICIT_PATH => .explicit_path,
        else => null,
    };
}

fn optionalAbsolutePath(
    pointer: ?[*]const u8,
    length: u32,
) error{InvalidPath}!?[]const u8 {
    if (length == 0) return null;
    const bytes = (pointer orelse return error.InvalidPath)[0..length];
    if (!std.fs.path.isAbsolute(bytes)) return error.InvalidPath;
    return bytes;
}

export fn vivi_backend_open(
    options: ?*const c.vivi_backend_conversation_options_t,
    out_conversation: ?*?*c.vivi_backend_conversation_t,
) callconv(.c) c.vivi_backend_result_t {
    const input = options orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const output = out_conversation orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    output.* = null;
    if (input.abi_version != c.VIVI_BACKEND_ABI_VERSION or
        input.struct_size < @sizeOf(c.vivi_backend_conversation_options_t))
    {
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    }
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
    const settings_path = (optionalAbsolutePath(
        input.settings_path,
        input.settings_path_length,
    ) catch return c.VIVI_BACKEND_INVALID_ARGUMENT) orelse
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const copilot_cli_path = optionalAbsolutePath(
        input.copilot_cli_path,
        input.copilot_cli_path_length,
    ) catch return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const launch = copilotCliLaunch(input.copilot_cli_launch) orelse
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if ((launch == .explicit_path) != (copilot_cli_path != null)) {
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
    self.control_operation = .none;
    self.pending = null;
    self.emit_closed_after_failure = false;
    self.conversation = backend.openConversation(
        std.heap.c_allocator,
        self.io_threaded.io(),
        .{ .context = self, .notify = Handle.notify },
        .{
            .working_directory = working_directory,
            .settings_path = settings_path,
            .copilot_cli_path = copilot_cli_path,
            .copilot_cli_launch = launch,
        },
    ) catch {
        self.io_threaded.deinit();
        std.heap.c_allocator.destroy(self);
        return c.VIVI_BACKEND_FAILED;
    };
    output.* = @ptrCast(self);
    self.armed.store(true, .release);
    if (self.pending_wake.swap(false, .acq_rel)) {
        if (self.wake) |wake| wake(self.wake_context);
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
    if (self.control_operation != .none) return c.VIVI_BACKEND_BUSY;
    if (!self.accepting_prompt.swap(false, .acq_rel)) {
        return c.VIVI_BACKEND_BUSY;
    }
    self.conversation.submit(
        .{ .text = bytes[0..prompt_length] },
        .enqueue,
    ) catch |err| {
        if (err != error.Stopping and err != error.Closed) {
            self.accepting_prompt.store(true, .release);
        }
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

fn reasoning(raw: c.vivi_backend_reasoning_effort_t) ?backend.ReasoningEffort {
    return switch (raw) {
        c.VIVI_BACKEND_REASONING_OFF => .off,
        c.VIVI_BACKEND_REASONING_LOW => .low,
        c.VIVI_BACKEND_REASONING_MEDIUM => .medium,
        c.VIVI_BACKEND_REASONING_HIGH => .high,
        c.VIVI_BACKEND_REASONING_XHIGH => .xhigh,
        c.VIVI_BACKEND_REASONING_MAX => .max,
        else => null,
    };
}

fn cReasoning(value: backend.ReasoningEffort) c.vivi_backend_reasoning_effort_t {
    return switch (value) {
        .off => c.VIVI_BACKEND_REASONING_OFF,
        .low => c.VIVI_BACKEND_REASONING_LOW,
        .medium => c.VIVI_BACKEND_REASONING_MEDIUM,
        .high => c.VIVI_BACKEND_REASONING_HIGH,
        .xhigh => c.VIVI_BACKEND_REASONING_XHIGH,
        .max => c.VIVI_BACKEND_REASONING_MAX,
    };
}

export fn vivi_backend_refresh_models(
    conversation: ?*c.vivi_backend_conversation_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (self.control_operation != .none) return c.VIVI_BACKEND_BUSY;
    self.control_operation = .refresh_models;
    self.conversation.refreshModels() catch |err| {
        self.control_operation = .none;
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_switch_model(
    conversation: ?*c.vivi_backend_conversation_t,
    model_id: ?[*]const u8,
    model_id_length: u32,
    reasoning_value: c.vivi_backend_reasoning_effort_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const bytes = model_id orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (model_id_length == 0) return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const selected_reasoning = reasoning(reasoning_value) orelse
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (self.control_operation != .none) return c.VIVI_BACKEND_BUSY;
    self.control_operation = .switch_model;
    self.conversation.switchModel(.{
        .model_id = bytes[0..model_id_length],
        .reasoning = selected_reasoning,
    }) catch |err| {
        self.control_operation = .none;
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_sanitize_tool_markdown(
    input: ?[*]const u8,
    input_length: u32,
    output: ?[*]u8,
    output_capacity: u32,
    out_length: ?*u32,
) callconv(.c) c.vivi_backend_result_t {
    const required = out_length orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const source: []const u8 = if (input_length > 0)
        (input orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..input_length]
    else
        "";
    const rendered = backend.renderMarkdown(
        std.heap.c_allocator,
        source,
    ) catch return c.VIVI_BACKEND_FAILED;
    defer std.heap.c_allocator.free(rendered);
    if (rendered.len > std.math.maxInt(u32)) return c.VIVI_BACKEND_FAILED;
    required.* = @intCast(rendered.len);
    if (output_capacity < rendered.len) return c.VIVI_BACKEND_BUFFER_TOO_SMALL;
    if (rendered.len > 0) {
        const destination = (output orelse
            return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..rendered.len];
        @memcpy(destination, rendered);
    }
    return c.VIVI_BACKEND_OK;
}

const Projected = struct {
    kind: c.vivi_backend_event_kind_t,
    content_kind: c.vivi_backend_content_kind_t = c.VIVI_BACKEND_CONTENT_NONE,
    text: []const u8 = "",
    selected_model_id: []const u8 = "",
    tool_call_id: []const u8 = "",
    tool_title: []const u8 = "",
    tool_detail: []const u8 = "",
    tool_input: []const u8 = "",
    tool_result: c.vivi_backend_tool_result_t = c.VIVI_BACKEND_TOOL_RESULT_NONE,
    selected_reasoning: c.vivi_backend_reasoning_effort_t = c.VIVI_BACKEND_REASONING_NONE,
    models: []const backend.ModelInfo = &.{},
    model: ?*const backend.ModelInfo = null,
    switch_outcome: c.vivi_backend_model_switch_outcome_t = c.VIVI_BACKEND_MODEL_SWITCH_NONE,
    history_effect: c.vivi_backend_history_effect_t = c.VIVI_BACKEND_HISTORY_NONE,
    default_saved: bool = false,
    cleanup_failed: bool = false,
};

const ToolDisplay = struct {
    title: []const u8,
    detail: []const u8 = "",
};

fn toolDisplay(summary: backend.ToolSummary) ToolDisplay {
    return switch (summary) {
        .read => |value| .{ .title = "Read file", .detail = value.path },
        .bash => |value| switch (value) {
            .run => |run| .{ .title = "Run command", .detail = run.command },
            .start => |start| .{ .title = "Start command", .detail = start.command },
            .list => .{ .title = "List Bash sessions" },
            .read => |read| .{ .title = "Read Bash", .detail = read.shell_id },
            .write => |write| .{ .title = "Write Bash", .detail = write.shell_id },
            .stop => |stop| .{ .title = "Stop Bash", .detail = stop.shell_id },
        },
        .edit => |value| .{ .title = "Edit file", .detail = value.path },
        .write => |value| .{ .title = "Write file", .detail = value.path },
        .other => |value| .{ .title = value.name },
    };
}

fn project(event: *const backend.ConversationEvent) ?Projected {
    return switch (event.*) {
        .ready => .{ .kind = c.VIVI_BACKEND_EVENT_READY },
        .status => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_STATUS,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .session_title => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_SESSION_TITLE,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .assistant_started => .{ .kind = c.VIVI_BACKEND_EVENT_ASSISTANT_STARTED },
        .reasoning_delta => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_REASONING_DELTA,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .reasoning_complete => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_REASONING_COMPLETE,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .assistant_delta => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_ASSISTANT_DELTA,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .assistant_complete => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_ASSISTANT_COMPLETE,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .tool_activity => |*update| switch (update.*) {
            .started => |*started| blk: {
                const display = toolDisplay(started.invocation.summary);
                break :blk .{
                    .kind = c.VIVI_BACKEND_EVENT_TOOL_STARTED,
                    .content_kind = c.VIVI_BACKEND_CONTENT_TOOL,
                    .tool_call_id = started.call_id.bytes,
                    .tool_title = display.title,
                    .tool_detail = display.detail,
                    .tool_input = started.invocation.arguments_json,
                    .tool_result = c.VIVI_BACKEND_TOOL_RESULT_RUNNING,
                };
            },
            .finished => |*finished| .{
                .kind = c.VIVI_BACKEND_EVENT_TOOL_FINISHED,
                .content_kind = c.VIVI_BACKEND_CONTENT_TOOL,
                .text = switch (finished.result) {
                    .succeeded, .failed => |text| text,
                    .image => |value| value.description,
                },
                .tool_call_id = finished.call_id.bytes,
                .tool_result = switch (finished.result) {
                    .succeeded => c.VIVI_BACKEND_TOOL_RESULT_SUCCEEDED,
                    .failed => c.VIVI_BACKEND_TOOL_RESULT_FAILED,
                    .image => c.VIVI_BACKEND_TOOL_RESULT_IMAGE,
                },
            },
        },
        .model_catalog => |*catalog| .{
            .kind = c.VIVI_BACKEND_EVENT_MODEL_CATALOG,
            .content_kind = c.VIVI_BACKEND_CONTENT_MODEL_CATALOG,
            .selected_model_id = catalog.selected.model_id,
            .selected_reasoning = cReasoning(catalog.selected.reasoning),
            .models = catalog.models,
        },
        .model_catalog_failed => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_MODEL_CATALOG_FAILURE,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .model_switch => |*switch_result| switch (switch_result.*) {
            .unchanged => |*success| .{
                .kind = c.VIVI_BACKEND_EVENT_MODEL_SWITCH,
                .content_kind = c.VIVI_BACKEND_CONTENT_MODEL_SWITCH,
                .selected_model_id = success.selection.model_id,
                .selected_reasoning = cReasoning(success.selection.reasoning),
                .model = &success.model,
                .switch_outcome = c.VIVI_BACKEND_MODEL_SWITCH_UNCHANGED,
                .history_effect = c.VIVI_BACKEND_HISTORY_PRESERVED,
            },
            .default_updated => |*success| .{
                .kind = c.VIVI_BACKEND_EVENT_MODEL_SWITCH,
                .content_kind = c.VIVI_BACKEND_CONTENT_MODEL_SWITCH,
                .selected_model_id = success.selection.model_id,
                .selected_reasoning = cReasoning(success.selection.reasoning),
                .model = &success.model,
                .switch_outcome = c.VIVI_BACKEND_MODEL_SWITCH_DEFAULT_UPDATED,
                .history_effect = c.VIVI_BACKEND_HISTORY_PRESERVED,
                .default_saved = true,
            },
            .switched => |*success| .{
                .kind = c.VIVI_BACKEND_EVENT_MODEL_SWITCH,
                .content_kind = c.VIVI_BACKEND_CONTENT_MODEL_SWITCH,
                .selected_model_id = success.selection.model_id,
                .selected_reasoning = cReasoning(success.selection.reasoning),
                .model = &success.model,
                .switch_outcome = c.VIVI_BACKEND_MODEL_SWITCH_SWITCHED,
                .history_effect = switch (success.history) {
                    .preserved => c.VIVI_BACKEND_HISTORY_PRESERVED,
                    .reset_visible_transcript_preserved => c.VIVI_BACKEND_HISTORY_RESET_VISIBLE_TRANSCRIPT_PRESERVED,
                },
                .default_saved = success.default_saved,
                .cleanup_failed = success.cleanup_failed,
            },
            .failed => |failure| .{
                .kind = c.VIVI_BACKEND_EVENT_MODEL_SWITCH,
                .content_kind = c.VIVI_BACKEND_CONTENT_MODEL_SWITCH,
                .text = failure.bytes,
                .switch_outcome = c.VIVI_BACKEND_MODEL_SWITCH_FAILED,
            },
        },
        .idle => .{ .kind = c.VIVI_BACKEND_EVENT_IDLE },
        .closed => |closed| switch (closed) {
            .requested => .{ .kind = c.VIVI_BACKEND_EVENT_CLOSED },
            .failed => |failure| .{
                .kind = c.VIVI_BACKEND_EVENT_FAILURE,
                .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
                .text = failure.message.bytes,
            },
        },
        .user_input_requested => .{
            .kind = c.VIVI_BACKEND_EVENT_FAILURE,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = "Native chat cannot answer agent questions yet.",
        },
        .command_catalog,
        .session_catalog,
        .session_catalog_failed,
        .session_resume,
        .command_completed,
        => null,
    };
}

fn byteCount(projected: Projected) !u32 {
    var total: u64 = projected.text.len + projected.selected_model_id.len +
        projected.tool_call_id.len + projected.tool_title.len +
        projected.tool_detail.len + projected.tool_input.len;
    for (projected.models) |model| {
        total += model.id.len + model.display_name.len;
    }
    if (projected.model) |model| {
        total += model.id.len + model.display_name.len;
    }
    if (total > std.math.maxInt(u32)) return error.EventTooLarge;
    return @intCast(total);
}

fn modelCount(projected: Projected) u32 {
    return @intCast(projected.models.len + @intFromBool(projected.model != null));
}

fn appendBytes(
    destination: []u8,
    offset: *u32,
    value: []const u8,
) c.vivi_backend_span_t {
    const start = offset.*;
    @memcpy(destination[start .. start + value.len], value);
    offset.* += @intCast(value.len);
    return .{ .offset = start, .length = @intCast(value.len) };
}

fn writeModel(
    destination: []u8,
    offset: *u32,
    model: *const backend.ModelInfo,
) c.vivi_backend_model_t {
    return .{
        .id = appendBytes(destination, offset, model.id),
        .display_name = appendBytes(destination, offset, model.display_name),
        .max_context_window_tokens = model.max_context_window_tokens,
        .max_output_tokens = model.max_output_tokens,
        .supports_vision = @intFromBool(model.supports_vision),
        .reasoning_mask = @bitCast(model.reasoning.selectable),
        .advertised_default_reasoning = if (model.reasoning.advertised_default) |value|
            @intCast(cReasoning(value))
        else
            @intCast(c.VIVI_BACKEND_REASONING_NONE),
        .reserved = 0,
    };
}

fn copyProjected(
    projected: Projected,
    output: *c.vivi_backend_event_t,
    bytes: ?[*]u8,
    byte_capacity: u32,
    models: ?[*]c.vivi_backend_model_t,
    model_capacity: u32,
) c.vivi_backend_result_t {
    const required_bytes = byteCount(projected) catch return c.VIVI_BACKEND_FAILED;
    const required_models = modelCount(projected);
    output.* = .{
        .kind = projected.kind,
        .content_kind = projected.content_kind,
        .byte_count = required_bytes,
        .model_count = required_models,
        .content = .{ .offset = 0, .length = @intCast(projected.text.len) },
        .selected_model_id = .{
            .offset = @intCast(projected.text.len),
            .length = @intCast(projected.selected_model_id.len),
        },
        .tool_call_id = .{ .offset = 0, .length = 0 },
        .tool_title = .{ .offset = 0, .length = 0 },
        .tool_detail = .{ .offset = 0, .length = 0 },
        .tool_input = .{ .offset = 0, .length = 0 },
        .tool_result = projected.tool_result,
        .selected_reasoning = projected.selected_reasoning,
        .switch_outcome = projected.switch_outcome,
        .history_effect = projected.history_effect,
        .default_saved = @intFromBool(projected.default_saved),
        .cleanup_failed = @intFromBool(projected.cleanup_failed),
        .reserved = 0,
    };
    if (byte_capacity < required_bytes or model_capacity < required_models) {
        return c.VIVI_BACKEND_BUFFER_TOO_SMALL;
    }
    var empty_bytes: [0]u8 = .{};
    var empty_models: [0]c.vivi_backend_model_t = .{};
    const byte_destination: []u8 = if (required_bytes > 0)
        (bytes orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_bytes]
    else
        &empty_bytes;
    const model_destination: []c.vivi_backend_model_t = if (required_models > 0)
        (models orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_models]
    else
        &empty_models;
    var offset: u32 = 0;
    output.content = appendBytes(byte_destination, &offset, projected.text);
    output.selected_model_id = appendBytes(
        byte_destination,
        &offset,
        projected.selected_model_id,
    );
    output.tool_call_id = appendBytes(
        byte_destination,
        &offset,
        projected.tool_call_id,
    );
    output.tool_title = appendBytes(
        byte_destination,
        &offset,
        projected.tool_title,
    );
    output.tool_detail = appendBytes(
        byte_destination,
        &offset,
        projected.tool_detail,
    );
    output.tool_input = appendBytes(
        byte_destination,
        &offset,
        projected.tool_input,
    );
    var model_index: usize = 0;
    for (projected.models) |*model| {
        model_destination[model_index] = writeModel(byte_destination, &offset, model);
        model_index += 1;
    }
    if (projected.model) |model| {
        model_destination[model_index] = writeModel(byte_destination, &offset, model);
    }
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_next_event(
    conversation: ?*c.vivi_backend_conversation_t,
    out_event: ?*c.vivi_backend_event_t,
    bytes: ?[*]u8,
    byte_capacity: u32,
    models: ?[*]c.vivi_backend_model_t,
    model_capacity: u32,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const output = out_event orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (self.emit_closed_after_failure) {
        self.emit_closed_after_failure = false;
        output.* = .{
            .kind = c.VIVI_BACKEND_EVENT_CLOSED,
            .content_kind = c.VIVI_BACKEND_CONTENT_NONE,
            .byte_count = 0,
            .model_count = 0,
            .content = .{ .offset = 0, .length = 0 },
            .selected_model_id = .{ .offset = 0, .length = 0 },
            .tool_call_id = .{ .offset = 0, .length = 0 },
            .tool_title = .{ .offset = 0, .length = 0 },
            .tool_detail = .{ .offset = 0, .length = 0 },
            .tool_input = .{ .offset = 0, .length = 0 },
            .tool_result = c.VIVI_BACKEND_TOOL_RESULT_NONE,
            .selected_reasoning = c.VIVI_BACKEND_REASONING_NONE,
            .switch_outcome = c.VIVI_BACKEND_MODEL_SWITCH_NONE,
            .history_effect = c.VIVI_BACKEND_HISTORY_NONE,
            .default_saved = 0,
            .cleanup_failed = 0,
            .reserved = 0,
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
    const copied = copyProjected(
        projected,
        output,
        bytes,
        byte_capacity,
        models,
        model_capacity,
    );
    if (copied != c.VIVI_BACKEND_OK) return copied;
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
    if ((projected.kind == c.VIVI_BACKEND_EVENT_MODEL_CATALOG or
        projected.kind == c.VIVI_BACKEND_EVENT_MODEL_CATALOG_FAILURE) and
        self.control_operation == .refresh_models)
    {
        self.control_operation = .none;
    } else if (projected.kind == c.VIVI_BACKEND_EVENT_MODEL_SWITCH and
        self.control_operation == .switch_model)
    {
        self.control_operation = .none;
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

test "C launch policy rejects unknown values" {
    const invalid: c.vivi_backend_copilot_cli_launch_t = 99;
    try std.testing.expect(copilotCliLaunch(invalid) == null);
}

test "C wake coalesces before arming and schedules after arming" {
    const Counter = struct {
        fn wake(context: ?*anyopaque) callconv(.c) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };

    var count: usize = 0;
    var value: Handle = undefined;
    value.wake = Counter.wake;
    value.wake_context = &count;
    value.armed = .init(false);
    value.pending_wake = .init(false);
    Handle.notify(&value);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expect(value.pending_wake.load(.acquire));

    value.armed.store(true, .release);
    Handle.notify(&value);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(!value.pending_wake.load(.acquire));
}

test "C tool Markdown sanitizer uses atomic caller-owned copy" {
    const input = "\x1b[32m# Result\x1b[0m\r\n";
    var required: u32 = 0;
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            vivi_backend_sanitize_tool_markdown(
                input,
                input.len,
                null,
                0,
                &required,
            ),
    );
    var bytes: [64]u8 = undefined;
    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            vivi_backend_sanitize_tool_markdown(
                input,
                input.len,
                &bytes,
                bytes.len,
                &required,
            ),
    );
    try std.testing.expectEqualStrings("# Result\n", bytes[0..required]);
}

test "C model catalog copy-out is atomic and uses checked spans" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{ .model_catalog = .{
        .allocator = allocator,
        .selected = try backend.OwnedModelSelection.init(allocator, .{
            .model_id = "copilot/gpt-5",
            .reasoning = .high,
        }),
        .models = try allocator.alloc(backend.ModelInfo, 1),
    } };
    defer event.deinit();
    event.model_catalog.models[0] = .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, "copilot/gpt-5"),
        .display_name = try allocator.dupe(u8, "GPT-5"),
        .max_context_window_tokens = 128_000,
        .max_output_tokens = 16_000,
        .supports_vision = true,
        .reasoning = .{
            .selectable = .{ .off = true, .high = true },
            .advertised_default = .high,
        },
    };

    const projected = project(&event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    var untouched_bytes = [_]u8{0xaa} ** 32;
    var untouched_models = [_]c.vivi_backend_model_t{std.mem.zeroes(c.vivi_backend_model_t)};
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            copyProjected(
                projected,
                &metadata,
                &untouched_bytes,
                1,
                &untouched_models,
                0,
            ),
    );
    try std.testing.expectEqual(@as(u8, 0xaa), untouched_bytes[0]);
    try std.testing.expectEqual(@as(u32, 0), untouched_models[0].id.length);
    try std.testing.expectEqual(@as(u32, 1), metadata.model_count);

    const bytes = try allocator.alloc(u8, metadata.byte_count);
    defer allocator.free(bytes);
    const records = try allocator.alloc(c.vivi_backend_model_t, metadata.model_count);
    defer allocator.free(records);
    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjected(
                projected,
                &metadata,
                bytes.ptr,
                @intCast(bytes.len),
                records.ptr,
                @intCast(records.len),
            ),
    );
    try std.testing.expectEqualStrings(
        "copilot/gpt-5",
        bytes[metadata.selected_model_id.offset..][0..metadata.selected_model_id.length],
    );
    try std.testing.expectEqualStrings(
        "GPT-5",
        bytes[records[0].display_name.offset..][0..records[0].display_name.length],
    );
    try std.testing.expectEqual(@as(u8, 0b0000_1001), records[0].reasoning_mask);
    try std.testing.expectEqual(@as(u8, 1), records[0].supports_vision);
}

test "C model switch projection reports authoritative outcome facts" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{ .model_switch = .{ .switched = .{
        .model = .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, "omlx/local"),
            .display_name = try allocator.dupe(u8, "Local"),
            .max_context_window_tokens = 32_000,
            .max_output_tokens = 4_000,
            .supports_vision = false,
            .reasoning = .{
                .selectable = .{ .off = true, .max = true },
                .advertised_default = .max,
            },
        },
        .selection = try backend.OwnedModelSelection.init(allocator, .{
            .model_id = "omlx/local",
            .reasoning = .max,
        }),
        .history = .reset_visible_transcript_preserved,
        .default_saved = true,
        .cleanup_failed = true,
    } } };
    defer event.deinit();

    const projected = project(&event).?;
    try std.testing.expect(
        c.VIVI_BACKEND_MODEL_SWITCH_SWITCHED == projected.switch_outcome,
    );
    try std.testing.expect(
        c.VIVI_BACKEND_HISTORY_RESET_VISIBLE_TRANSCRIPT_PRESERVED ==
            projected.history_effect,
    );
    try std.testing.expect(projected.default_saved);
    try std.testing.expect(projected.cleanup_failed);
    try std.testing.expectEqual(@as(u32, 1), modelCount(projected));
}

test "C model switch projection distinguishes non-replacement outcomes" {
    const allocator = std.testing.allocator;
    var unchanged: backend.ConversationEvent = .{ .model_switch = .{ .unchanged = .{
        .model = .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, "copilot/default"),
            .display_name = try allocator.dupe(u8, "Copilot default"),
            .max_context_window_tokens = 0,
            .max_output_tokens = 0,
            .supports_vision = false,
            .reasoning = .{
                .selectable = .{ .off = true },
                .advertised_default = .off,
            },
        },
        .selection = try backend.OwnedModelSelection.init(allocator, .{
            .model_id = "copilot/default",
            .reasoning = .off,
        }),
    } } };
    defer unchanged.deinit();
    try std.testing.expect(
        project(&unchanged).?.switch_outcome ==
            c.VIVI_BACKEND_MODEL_SWITCH_UNCHANGED,
    );

    var default_updated: backend.ConversationEvent = .{ .model_switch = .{ .default_updated = .{
        .model = try unchanged.model_switch.unchanged.model.clone(allocator),
        .selection = try unchanged.model_switch.unchanged.selection.clone(allocator),
    } } };
    defer default_updated.deinit();
    const updated = project(&default_updated).?;
    try std.testing.expect(
        updated.switch_outcome ==
            c.VIVI_BACKEND_MODEL_SWITCH_DEFAULT_UPDATED,
    );
    try std.testing.expect(updated.default_saved);

    var failed: backend.ConversationEvent = .{ .model_switch = .{
        .failed = try backend.OwnedText.init(allocator, "SelectedModelUnavailable"),
    } };
    defer failed.deinit();
    const projected_failure = project(&failed).?;
    try std.testing.expect(
        projected_failure.switch_outcome ==
            c.VIVI_BACKEND_MODEL_SWITCH_FAILED,
    );
    try std.testing.expectEqualStrings(
        "SelectedModelUnavailable",
        projected_failure.text,
    );
    try std.testing.expectEqual(@as(u32, 0), modelCount(projected_failure));
}

test "C session title is a distinct typed text event" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{
        .session_title = try backend.OwnedText.init(allocator, "Native title"),
    };
    defer event.deinit();
    const projected = project(&event).?;
    try std.testing.expect(projected.kind == c.VIVI_BACKEND_EVENT_SESSION_TITLE);
    try std.testing.expectEqualStrings("Native title", projected.text);
}

test "C tool start copy-out is atomic and includes display fields" {
    const allocator = std.testing.allocator;
    var started = try backend.ToolStarted.init(
        allocator,
        "call-read",
        "{\"path\":\"README.md\"}",
        .{ .read = .{ .path = "README.md", .offset = null, .limit = null } },
    );
    var event: backend.ConversationEvent = .{
        .tool_activity = .{ .started = started },
    };
    started = undefined;
    defer event.deinit();

    const projected = project(&event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    var untouched = [_]u8{0xaa} ** 8;
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            copyProjected(projected, &metadata, &untouched, 1, null, 0),
    );
    try std.testing.expectEqual(@as(u8, 0xaa), untouched[0]);
    try std.testing.expect(metadata.kind == c.VIVI_BACKEND_EVENT_TOOL_STARTED);
    try std.testing.expect(
        metadata.tool_result == c.VIVI_BACKEND_TOOL_RESULT_RUNNING,
    );

    const bytes = try allocator.alloc(u8, metadata.byte_count);
    defer allocator.free(bytes);
    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjected(
                projected,
                &metadata,
                bytes.ptr,
                @intCast(bytes.len),
                null,
                0,
            ),
    );
    try std.testing.expectEqualStrings(
        "call-read",
        bytes[metadata.tool_call_id.offset..][0..metadata.tool_call_id.length],
    );
    try std.testing.expectEqualStrings(
        "Read file",
        bytes[metadata.tool_title.offset..][0..metadata.tool_title.length],
    );
    try std.testing.expectEqualStrings(
        "README.md",
        bytes[metadata.tool_detail.offset..][0..metadata.tool_detail.length],
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"README.md\"}",
        bytes[metadata.tool_input.offset..][0..metadata.tool_input.length],
    );
}

fn expectToolCompletionCopyOut(
    allocator: std.mem.Allocator,
    event: *const backend.ConversationEvent,
    expected: c.vivi_backend_tool_result_t,
    expected_output: []const u8,
) !void {
    const projected = project(event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    const bytes = try allocator.alloc(u8, try byteCount(projected));
    defer allocator.free(bytes);
    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjected(
                projected,
                &metadata,
                bytes.ptr,
                @intCast(bytes.len),
                null,
                0,
            ),
    );
    try std.testing.expect(
        metadata.kind == c.VIVI_BACKEND_EVENT_TOOL_FINISHED,
    );
    try std.testing.expect(metadata.tool_result == expected);
    try std.testing.expectEqualStrings(
        expected_output,
        bytes[metadata.content.offset..][0..metadata.content.length],
    );
    try std.testing.expectEqualStrings(
        "call-1",
        bytes[metadata.tool_call_id.offset..][0..metadata.tool_call_id.length],
    );
}

test "C tool completion copy-out distinguishes text failure and image" {
    const allocator = std.testing.allocator;
    {
        var finished = try backend.ToolFinished.init(
            allocator,
            "call-1",
            .{ .succeeded = "**done**" },
        );
        var event: backend.ConversationEvent = .{
            .tool_activity = .{ .finished = finished },
        };
        finished = undefined;
        defer event.deinit();
        try expectToolCompletionCopyOut(
            allocator,
            &event,
            c.VIVI_BACKEND_TOOL_RESULT_SUCCEEDED,
            "**done**",
        );
    }
    {
        var finished = try backend.ToolFinished.init(
            allocator,
            "call-1",
            .{ .failed = "permission denied" },
        );
        var event: backend.ConversationEvent = .{
            .tool_activity = .{ .finished = finished },
        };
        finished = undefined;
        defer event.deinit();
        try expectToolCompletionCopyOut(
            allocator,
            &event,
            c.VIVI_BACKEND_TOOL_RESULT_FAILED,
            "permission denied",
        );
    }
    {
        var finished = try backend.ToolFinished.init(
            allocator,
            "call-1",
            .{ .image = .{
                .bytes = "png",
                .format = .png,
                .description = "chart.png",
            } },
        );
        var event: backend.ConversationEvent = .{
            .tool_activity = .{ .finished = finished },
        };
        finished = undefined;
        defer event.deinit();
        try expectToolCompletionCopyOut(
            allocator,
            &event,
            c.VIVI_BACKEND_TOOL_RESULT_IMAGE,
            "chart.png",
        );
    }
}
