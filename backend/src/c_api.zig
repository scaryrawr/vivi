const std = @import("std");
const backend = @import("vivi_backend");
const c = @cImport({
    @cInclude("vivi_backend.h");
});

comptime {
    if (c.VIVI_BACKEND_ATTACHMENT_MAX_COUNT != backend.max_attachment_count or
        c.VIVI_BACKEND_ATTACHMENT_MAX_BYTES != backend.max_attachment_bytes or
        c.VIVI_BACKEND_ATTACHMENT_IDENTITY_MAX_BYTES !=
            backend.max_attachment_identity_bytes or
        c.VIVI_BACKEND_ATTACHMENT_DISPLAY_NAME_MAX_BYTES !=
            backend.max_attachment_display_name_bytes)
    {
        @compileError("C attachment limits must match the backend domain");
    }
}

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
        refresh_sessions,
        resume_session,
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
        error.TooManyAttachments,
        error.AttachmentsTooLarge,
        error.DuplicateAttachmentIdentity,
        error.InvalidAttachmentIdentity,
        error.InvalidAttachmentDisplayName,
        error.EmptyAttachment,
        error.AttachmentTooLarge,
        error.AttachmentMediaMismatch,
        error.EmptyModel,
        error.InvalidReasoningEffort,
        error.InvalidSessionKey,
        error.EmptyAnswer,
        error.EmptyUserInputRequestId,
        error.InvalidUserInputUtf8,
        error.UserInputTextTooLong,
        error.StaleUserInputRequest,
        error.InvalidUserInputChoice,
        error.FreeformUserInputNotAllowed,
        error.NotAwaitingInput,
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

const Submission = struct {
    prompt: []const u8,
    attachments: []backend.AttachmentInput,

    fn deinit(self: Submission) void {
        std.heap.c_allocator.free(self.attachments);
    }
};

fn attachmentMediaType(
    raw: c.vivi_backend_attachment_media_type_t,
) ?backend.ImageFormat {
    return switch (raw) {
        c.VIVI_BACKEND_ATTACHMENT_PNG => .png,
        c.VIVI_BACKEND_ATTACHMENT_JPEG => .jpeg,
        c.VIVI_BACKEND_ATTACHMENT_GIF => .gif,
        c.VIVI_BACKEND_ATTACHMENT_WEBP => .webp,
        else => null,
    };
}

fn requiredBytes(pointer: ?[*]const u8, length: u32) ?[]const u8 {
    if (length == 0) return null;
    return (pointer orelse return null)[0..length];
}

const SubmissionParseError = error{
    InvalidSubmission,
    OutOfMemory,
};

fn parseSubmission(
    input: ?*const c.vivi_backend_submission_t,
) SubmissionParseError!Submission {
    const submission = input orelse return error.InvalidSubmission;
    if (submission.struct_size < @sizeOf(c.vivi_backend_submission_t) or
        submission.reserved != 0 or
        submission.attachment_count > backend.max_attachment_count)
    {
        return error.InvalidSubmission;
    }
    const prompt = if (submission.prompt_length == 0)
        ""
    else
        requiredBytes(submission.prompt, submission.prompt_length) orelse
            return error.InvalidSubmission;
    if (!std.unicode.utf8ValidateSlice(prompt)) return error.InvalidSubmission;
    const descriptors = if (submission.attachment_count == 0)
        &[_]c.vivi_backend_submission_attachment_t{}
    else blk: {
        if (submission.attachments == null) return error.InvalidSubmission;
        const pointer: [*]const c.vivi_backend_submission_attachment_t =
            @ptrCast(submission.attachments);
        break :blk pointer[0..submission.attachment_count];
    };
    const attachments = try std.heap.c_allocator.alloc(
        backend.AttachmentInput,
        descriptors.len,
    );
    errdefer std.heap.c_allocator.free(attachments);
    for (descriptors, attachments) |descriptor, *attachment| {
        if (descriptor.struct_size != @sizeOf(c.vivi_backend_submission_attachment_t) or
            descriptor.reserved != 0)
        {
            return error.InvalidSubmission;
        }
        attachment.* = .{
            .identity = requiredBytes(
                descriptor.identity,
                descriptor.identity_length,
            ) orelse return error.InvalidSubmission,
            .display_name = requiredBytes(
                descriptor.display_name,
                descriptor.display_name_length,
            ) orelse return error.InvalidSubmission,
            .media_type = attachmentMediaType(descriptor.media_type) orelse
                return error.InvalidSubmission,
            .bytes = requiredBytes(descriptor.bytes, descriptor.byte_length) orelse
                return error.InvalidSubmission,
        };
    }
    return .{ .prompt = prompt, .attachments = attachments };
}

export fn vivi_backend_submit(
    conversation: ?*c.vivi_backend_conversation_t,
    submission: ?*const c.vivi_backend_submission_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const parsed = parseSubmission(submission) catch |err| return switch (err) {
        error.InvalidSubmission => c.VIVI_BACKEND_INVALID_ARGUMENT,
        error.OutOfMemory => c.VIVI_BACKEND_FAILED,
    };
    defer parsed.deinit();
    if (self.control_operation != .none) return c.VIVI_BACKEND_BUSY;
    if (!self.accepting_prompt.swap(false, .acq_rel)) {
        return c.VIVI_BACKEND_BUSY;
    }
    self.conversation.submit(
        .{ .text = parsed.prompt, .attachments = parsed.attachments },
        .enqueue,
    ) catch |err| {
        if (err != error.Stopping and err != error.Closed) {
            self.accepting_prompt.store(true, .release);
        }
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

test "submission descriptors decode typed caller-owned attachments" {
    const bytes = "\x89PNG\r\n\x1a\n";
    var attachment = std.mem.zeroInit(c.vivi_backend_submission_attachment_t, .{
        .struct_size = @sizeOf(c.vivi_backend_submission_attachment_t),
        .media_type = c.VIVI_BACKEND_ATTACHMENT_PNG,
        .identity = "image-1",
        .identity_length = 7,
        .display_name = "image.png",
        .display_name_length = 9,
        .bytes = bytes,
        .byte_length = bytes.len,
    });
    var submission = std.mem.zeroInit(c.vivi_backend_submission_t, .{
        .struct_size = @sizeOf(c.vivi_backend_submission_t),
        .prompt = "describe",
        .prompt_length = 8,
        .attachments = &attachment,
        .attachment_count = 1,
    });
    const parsed = try parseSubmission(&submission);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("describe", parsed.prompt);
    try std.testing.expectEqualStrings("image-1", parsed.attachments[0].identity);
    try std.testing.expectEqual(backend.ImageFormat.png, parsed.attachments[0].media_type);

    attachment.reserved = 1;
    try std.testing.expectError(error.InvalidSubmission, parseSubmission(&submission));
    attachment.reserved = 0;
    attachment.struct_size += 8;
    try std.testing.expectError(error.InvalidSubmission, parseSubmission(&submission));
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

export fn vivi_backend_refresh_sessions(
    conversation: ?*c.vivi_backend_conversation_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (self.control_operation != .none) return c.VIVI_BACKEND_BUSY;
    self.control_operation = .refresh_sessions;
    self.conversation.refreshSessions() catch |err| {
        self.control_operation = .none;
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

export fn vivi_backend_resume_session(
    conversation: ?*c.vivi_backend_conversation_t,
    key: c.vivi_backend_resume_key_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    if (key.generation == 0 or key.reserved != 0) {
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    }
    if (self.control_operation != .none) return c.VIVI_BACKEND_BUSY;
    self.control_operation = .resume_session;
    self.conversation.resumeSession(.{
        .generation = key.generation,
        .slot = key.slot,
    }) catch |err| {
        self.control_operation = .none;
        return result(err);
    };
    return c.VIVI_BACKEND_OK;
}

fn userInputResponse(
    response: *const c.vivi_backend_user_input_response_t,
) ?backend.UserInputResponse {
    if (response.struct_size < @sizeOf(c.vivi_backend_user_input_response_t) or
        response.reserved != 0 or
        response.request_id_length == 0 or
        response.request_id_length > backend.max_user_input_request_id_bytes or
        response.answer_length == 0 or
        response.answer_length > backend.max_user_input_answer_bytes)
    {
        return null;
    }
    if (response.request_id == null or response.answer == null) {
        return null;
    }
    const request_id = response.request_id[0..response.request_id_length];
    const answer = response.answer[0..response.answer_length];
    if (!std.unicode.utf8ValidateSlice(request_id) or
        !std.unicode.utf8ValidateSlice(answer) or
        std.mem.trim(u8, answer, " \t\r\n").len == 0)
    {
        return null;
    }
    const typed_answer: backend.UserInputAnswer = switch (response.answer_kind) {
        c.VIVI_BACKEND_USER_INPUT_ANSWER_CHOICE => .{ .choice = answer },
        c.VIVI_BACKEND_USER_INPUT_ANSWER_FREEFORM => .{ .freeform = answer },
        else => return null,
    };
    return .{
        .request_id = request_id,
        .answer = typed_answer,
    };
}

export fn vivi_backend_respond_to_user_input(
    conversation: ?*c.vivi_backend_conversation_t,
    response_value: ?*const c.vivi_backend_user_input_response_t,
) callconv(.c) c.vivi_backend_result_t {
    const self = handle(conversation) orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const raw = response_value orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const response = userInputResponse(raw) orelse
        return c.VIVI_BACKEND_INVALID_ARGUMENT;
    self.conversation.respondToUserInput(response) catch |err| return result(err);
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

fn cLanguage(value: backend.PresentationLanguage) c.vivi_backend_language_t {
    return switch (value) {
        .zig => c.VIVI_BACKEND_LANGUAGE_ZIG,
        .bash => c.VIVI_BACKEND_LANGUAGE_BASH,
        .json => c.VIVI_BACKEND_LANGUAGE_JSON,
        .yaml => c.VIVI_BACKEND_LANGUAGE_YAML,
        .diff => c.VIVI_BACKEND_LANGUAGE_DIFF,
        .javascript => c.VIVI_BACKEND_LANGUAGE_JAVASCRIPT,
        .typescript => c.VIVI_BACKEND_LANGUAGE_TYPESCRIPT,
        .tsx => c.VIVI_BACKEND_LANGUAGE_TSX,
        .rust => c.VIVI_BACKEND_LANGUAGE_RUST,
        .c => c.VIVI_BACKEND_LANGUAGE_C,
        .cpp => c.VIVI_BACKEND_LANGUAGE_CPP,
        .go => c.VIVI_BACKEND_LANGUAGE_GO,
        .java => c.VIVI_BACKEND_LANGUAGE_JAVA,
        .lua => c.VIVI_BACKEND_LANGUAGE_LUA,
        .python => c.VIVI_BACKEND_LANGUAGE_PYTHON,
    };
}

fn cToken(value: backend.SemanticToken) c.vivi_backend_semantic_token_t {
    return switch (value) {
        .comment => c.VIVI_BACKEND_TOKEN_COMMENT,
        .string => c.VIVI_BACKEND_TOKEN_STRING,
        .number => c.VIVI_BACKEND_TOKEN_NUMBER,
        .constant => c.VIVI_BACKEND_TOKEN_CONSTANT,
        .keyword => c.VIVI_BACKEND_TOKEN_KEYWORD,
        .function => c.VIVI_BACKEND_TOKEN_FUNCTION,
        .property => c.VIVI_BACKEND_TOKEN_PROPERTY,
        .operator => c.VIVI_BACKEND_TOKEN_OPERATOR,
        .inserted => c.VIVI_BACKEND_TOKEN_INSERTED,
        .deleted => c.VIVI_BACKEND_TOKEN_DELETED,
        .meta => c.VIVI_BACKEND_TOKEN_META,
    };
}

fn presentationSpanCount(value: *const backend.Presentation) u32 {
    return switch (value.content) {
        .source => |source| @intCast(source.tokens.len),
        .literal, .markdown => 0,
    };
}

fn presentationMetadata(
    value: *const backend.Presentation,
    content_offset: u32,
    semantic_offset: u32,
) c.vivi_backend_presentation_t {
    return .{
        .content = .{
            .offset = content_offset,
            .length = @intCast(value.text.len),
        },
        .kind = switch (value.content) {
            .literal => c.VIVI_BACKEND_PRESENTATION_LITERAL,
            .markdown => c.VIVI_BACKEND_PRESENTATION_MARKDOWN,
            .source => c.VIVI_BACKEND_PRESENTATION_SOURCE,
        },
        .language = switch (value.content) {
            .source => |source| cLanguage(source.language),
            .literal, .markdown => c.VIVI_BACKEND_LANGUAGE_NONE,
        },
        .semantic_span_offset = semantic_offset,
        .semantic_span_count = presentationSpanCount(value),
        .reserved = 0,
    };
}

fn copyPresentationSpans(
    value: *const backend.Presentation,
    content_offset: u32,
    destination: []c.vivi_backend_semantic_span_t,
    semantic_offset: *u32,
) void {
    switch (value.content) {
        .source => |source| for (source.tokens) |span| {
            destination[semantic_offset.*] = .{
                .bytes = .{
                    .offset = content_offset + @as(u32, @intCast(span.start)),
                    .length = @intCast(span.end - span.start),
                },
                .token = cToken(span.token),
                .reserved = 0,
            };
            semantic_offset.* += 1;
        },
        .literal, .markdown => {},
    }
}

export fn vivi_backend_present_code_fragment(
    language_name: ?[*]const u8,
    language_name_length: u32,
    input: ?[*]const u8,
    input_length: u32,
    out_presentation: ?*c.vivi_backend_presentation_t,
    output: ?[*]u8,
    output_capacity: u32,
    semantic_spans: ?[*]c.vivi_backend_semantic_span_t,
    semantic_span_capacity: u32,
) callconv(.c) c.vivi_backend_result_t {
    const descriptor = out_presentation orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const language = if (language_name_length == 0)
        ""
    else
        (language_name orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..language_name_length];
    const source = if (input_length == 0)
        ""
    else
        (input orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..input_length];
    var presented = backend.presentCodeFragment(
        std.heap.c_allocator,
        language,
        source,
    ) catch return c.VIVI_BACKEND_FAILED;
    defer presented.deinit();
    if (presented.text.len > std.math.maxInt(u32)) return c.VIVI_BACKEND_FAILED;
    const span_count = presentationSpanCount(&presented);
    descriptor.* = presentationMetadata(&presented, 0, 0);
    if (output_capacity < presented.text.len or semantic_span_capacity < span_count) {
        return c.VIVI_BACKEND_BUFFER_TOO_SMALL;
    }
    var empty_bytes: [0]u8 = .{};
    var empty_spans: [0]c.vivi_backend_semantic_span_t = .{};
    const byte_destination: []u8 = if (presented.text.len > 0)
        (output orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..presented.text.len]
    else
        &empty_bytes;
    const span_destination: []c.vivi_backend_semantic_span_t = if (span_count > 0)
        (semantic_spans orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..span_count]
    else
        &empty_spans;
    @memcpy(byte_destination, presented.text);
    var semantic_offset: u32 = 0;
    copyPresentationSpans(&presented, 0, span_destination, &semantic_offset);
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
    input_presentation: ?*const backend.Presentation = null,
    output_presentation: ?*const backend.Presentation = null,
    tool_result: c.vivi_backend_tool_result_t = c.VIVI_BACKEND_TOOL_RESULT_NONE,
    selected_reasoning: c.vivi_backend_reasoning_effort_t = c.VIVI_BACKEND_REASONING_NONE,
    models: []const backend.ModelInfo = &.{},
    model: ?*const backend.ModelInfo = null,
    switch_outcome: c.vivi_backend_model_switch_outcome_t = c.VIVI_BACKEND_MODEL_SWITCH_NONE,
    history_effect: c.vivi_backend_history_effect_t = c.VIVI_BACKEND_HISTORY_NONE,
    default_saved: bool = false,
    cleanup_failed: bool = false,
    session_resume_outcome: c.vivi_backend_session_resume_outcome_t =
        c.VIVI_BACKEND_SESSION_RESUME_NONE,
    sessions: []const backend.SessionSummary = &.{},
    resumed_session: ?*const backend.SessionSummary = null,
    transcript: []const backend.TranscriptItem = &.{},
    user_input_request_id: []const u8 = "",
    user_input_question: []const u8 = "",
    user_input_choices: []const []u8 = &.{},
    allow_freeform: bool = false,
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
        .session_title => |text| if (backend.isCanonicalSessionTitle(text.bytes))
            .{
                .kind = c.VIVI_BACKEND_EVENT_SESSION_TITLE,
                .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
                .text = text.bytes,
            }
        else
            null,
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
                    .input_presentation = &started.input_presentation,
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
                .output_presentation = &finished.output_presentation,
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
        .session_catalog => |*catalog| if (hasCanonicalSessionTitles(catalog.sessions))
            .{
                .kind = c.VIVI_BACKEND_EVENT_SESSION_CATALOG,
                .content_kind = c.VIVI_BACKEND_CONTENT_SESSION_CATALOG,
                .sessions = catalog.sessions,
            }
        else
            null,
        .session_catalog_failed => |text| .{
            .kind = c.VIVI_BACKEND_EVENT_SESSION_CATALOG_FAILURE,
            .content_kind = c.VIVI_BACKEND_CONTENT_TEXT,
            .text = text.bytes,
        },
        .session_resume => |*resume_result| switch (resume_result.*) {
            .resumed => |*resumed| if (hasCanonicalSessionTitle(&resumed.session))
                .{
                    .kind = c.VIVI_BACKEND_EVENT_SESSION_RESUME,
                    .content_kind = c.VIVI_BACKEND_CONTENT_SESSION_RESUME,
                    .session_resume_outcome = c.VIVI_BACKEND_SESSION_RESUME_RESUMED,
                    .resumed_session = &resumed.session,
                    .transcript = resumed.transcript.items,
                    .cleanup_failed = resumed.cleanup_failed,
                }
            else
                null,
            .failed => |text| .{
                .kind = c.VIVI_BACKEND_EVENT_SESSION_RESUME,
                .content_kind = c.VIVI_BACKEND_CONTENT_SESSION_RESUME,
                .text = text.bytes,
                .session_resume_outcome = c.VIVI_BACKEND_SESSION_RESUME_FAILED,
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
        .user_input_requested => |request| .{
            .kind = c.VIVI_BACKEND_EVENT_USER_INPUT_REQUEST,
            .content_kind = c.VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST,
            .user_input_request_id = request.request_id,
            .user_input_question = request.question,
            .user_input_choices = request.choices,
            .allow_freeform = request.allow_freeform,
        },
        .command_catalog,
        .command_completed,
        => null,
    };
}

fn hasCanonicalSessionTitles(sessions: []const backend.SessionSummary) bool {
    for (sessions) |session| {
        if (!hasCanonicalSessionTitle(&session)) return false;
    }
    return true;
}

fn hasCanonicalSessionTitle(session: *const backend.SessionSummary) bool {
    const title = session.title orelse return true;
    return backend.isCanonicalSessionTitle(title);
}

fn byteCount(projected: Projected) !u32 {
    var total: u64 = 0;
    const values = [_][]const u8{
        projected.text,
        projected.selected_model_id,
        projected.tool_call_id,
        projected.tool_title,
        projected.tool_detail,
        projected.tool_input,
        projected.user_input_request_id,
        projected.user_input_question,
    };
    for (values) |value| {
        total = std.math.add(u64, total, value.len) catch
            return error.EventTooLarge;
    }
    if (projected.input_presentation) |value| {
        total = std.math.add(u64, total, value.text.len) catch
            return error.EventTooLarge;
    }
    if (projected.output_presentation) |value| {
        total = std.math.add(u64, total, value.text.len) catch
            return error.EventTooLarge;
    }
    for (projected.models) |model| {
        total = std.math.add(u64, total, model.id.len) catch
            return error.EventTooLarge;
        total = std.math.add(u64, total, model.display_name.len) catch
            return error.EventTooLarge;
    }
    if (projected.model) |model| {
        total = std.math.add(u64, total, model.id.len) catch
            return error.EventTooLarge;
        total = std.math.add(u64, total, model.display_name.len) catch
            return error.EventTooLarge;
    }
    for (projected.sessions) |session| {
        total = try addSessionBytes(total, &session);
    }
    if (projected.resumed_session) |session| {
        total = try addSessionBytes(total, session);
    }
    for (projected.transcript) |item| {
        total = std.math.add(u64, total, item.text.len) catch
            return error.EventTooLarge;
    }
    for (projected.user_input_choices) |choice| {
        total = std.math.add(u64, total, choice.len) catch
            return error.EventTooLarge;
    }
    if (total > std.math.maxInt(u32)) return error.EventTooLarge;
    return @intCast(total);
}

fn addSessionBytes(total_value: u64, session: *const backend.SessionSummary) !u64 {
    var total = total_value;
    total = std.math.add(u64, total, session.working_directory.len) catch
        return error.EventTooLarge;
    if (session.title) |title| {
        total = std.math.add(u64, total, title.len) catch
            return error.EventTooLarge;
    }
    return total;
}

fn modelCount(projected: Projected) !u32 {
    const count = std.math.add(
        usize,
        projected.models.len,
        @intFromBool(projected.model != null),
    ) catch return error.EventTooLarge;
    return std.math.cast(u32, count) orelse error.EventTooLarge;
}

fn sessionCount(projected: Projected) !u32 {
    const count = std.math.add(
        usize,
        projected.sessions.len,
        @intFromBool(projected.resumed_session != null),
    ) catch return error.EventTooLarge;
    return std.math.cast(u32, count) orelse error.EventTooLarge;
}

fn transcriptItemCount(projected: Projected) !u32 {
    return std.math.cast(u32, projected.transcript.len) orelse
        error.EventTooLarge;
}

fn userInputChoiceCount(projected: Projected) !u32 {
    return std.math.cast(u32, projected.user_input_choices.len) orelse
        error.EventTooLarge;
}

fn semanticSpanCount(projected: Projected) !u32 {
    const input_count = if (projected.input_presentation) |value|
        presentationSpanCount(value)
    else
        0;
    const output_count = if (projected.output_presentation) |value|
        presentationSpanCount(value)
    else
        0;
    return std.math.add(u32, input_count, output_count) catch
        error.EventTooLarge;
}

fn emptyPresentation() c.vivi_backend_presentation_t {
    return .{
        .content = .{ .offset = 0, .length = 0 },
        .kind = c.VIVI_BACKEND_PRESENTATION_NONE,
        .language = c.VIVI_BACKEND_LANGUAGE_NONE,
        .semantic_span_offset = 0,
        .semantic_span_count = 0,
        .reserved = 0,
    };
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

fn appendOptionalBytes(
    destination: []u8,
    offset: *u32,
    value: []const u8,
) c.vivi_backend_span_t {
    if (value.len == 0) return .{ .offset = 0, .length = 0 };
    return appendBytes(destination, offset, value);
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

fn writeSessionSummary(
    destination: []u8,
    offset: *u32,
    session: *const backend.SessionSummary,
) c.vivi_backend_session_summary_t {
    var flags: u32 = 0;
    const title = if (session.title) |value| blk: {
        flags |= @intCast(c.VIVI_BACKEND_SESSION_TITLE_PRESENT);
        break :blk appendBytes(destination, offset, value);
    } else std.mem.zeroes(c.vivi_backend_span_t);
    if (session.current) flags |= @intCast(c.VIVI_BACKEND_SESSION_CURRENT);
    return .{
        .key = .{
            .generation = session.key.generation,
            .slot = session.key.slot,
            .reserved = 0,
        },
        .working_directory = appendBytes(
            destination,
            offset,
            session.working_directory,
        ),
        .title = title,
        .flags = flags,
        .reserved = 0,
    };
}

fn cTranscriptRole(
    role: backend.TranscriptRole,
) c.vivi_backend_transcript_role_t {
    return switch (role) {
        .user => c.VIVI_BACKEND_TRANSCRIPT_USER,
        .assistant => c.VIVI_BACKEND_TRANSCRIPT_ASSISTANT,
        .reasoning => c.VIVI_BACKEND_TRANSCRIPT_REASONING,
    };
}

fn writeTranscriptItem(
    destination: []u8,
    offset: *u32,
    item: *const backend.TranscriptItem,
) c.vivi_backend_transcript_item_t {
    return .{
        .text = appendBytes(destination, offset, item.text),
        .role = cTranscriptRole(item.role),
        .reserved = 0,
    };
}

fn writeUserInputChoice(
    destination: []u8,
    offset: *u32,
    choice: []const u8,
) c.vivi_backend_user_input_choice_t {
    return .{
        .text = appendBytes(destination, offset, choice),
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
    return copyProjectedWithSpans(
        projected,
        output,
        bytes,
        byte_capacity,
        models,
        model_capacity,
        null,
        0,
    );
}

fn copyProjectedWithSpans(
    projected: Projected,
    output: *c.vivi_backend_event_t,
    bytes: ?[*]u8,
    byte_capacity: u32,
    models: ?[*]c.vivi_backend_model_t,
    model_capacity: u32,
    semantic_spans: ?[*]c.vivi_backend_semantic_span_t,
    semantic_span_capacity: u32,
) c.vivi_backend_result_t {
    return copyProjectedFull(
        projected,
        output,
        bytes,
        byte_capacity,
        models,
        model_capacity,
        semantic_spans,
        semantic_span_capacity,
        null,
        0,
        null,
        0,
        null,
        0,
    );
}

fn copyProjectedFull(
    projected: Projected,
    output: *c.vivi_backend_event_t,
    bytes: ?[*]u8,
    byte_capacity: u32,
    models: ?[*]c.vivi_backend_model_t,
    model_capacity: u32,
    semantic_spans: ?[*]c.vivi_backend_semantic_span_t,
    semantic_span_capacity: u32,
    sessions: ?[*]c.vivi_backend_session_summary_t,
    session_capacity: u32,
    transcript_items: ?[*]c.vivi_backend_transcript_item_t,
    transcript_item_capacity: u32,
    user_input_choices: ?[*]c.vivi_backend_user_input_choice_t,
    user_input_choice_capacity: u32,
) c.vivi_backend_result_t {
    const required_bytes = byteCount(projected) catch return c.VIVI_BACKEND_FAILED;
    const required_models = modelCount(projected) catch return c.VIVI_BACKEND_FAILED;
    const required_semantic_spans = semanticSpanCount(projected) catch
        return c.VIVI_BACKEND_FAILED;
    const required_sessions = sessionCount(projected) catch
        return c.VIVI_BACKEND_FAILED;
    const required_transcript_items = transcriptItemCount(projected) catch
        return c.VIVI_BACKEND_FAILED;
    const required_user_input_choices = userInputChoiceCount(projected) catch
        return c.VIVI_BACKEND_FAILED;
    output.* = .{
        .kind = projected.kind,
        .content_kind = projected.content_kind,
        .byte_count = required_bytes,
        .model_count = required_models,
        .semantic_span_count = required_semantic_spans,
        .session_count = required_sessions,
        .transcript_item_count = required_transcript_items,
        .user_input_choice_count = required_user_input_choices,
        .content = .{ .offset = 0, .length = @intCast(projected.text.len) },
        .selected_model_id = if (projected.selected_model_id.len == 0)
            .{ .offset = 0, .length = 0 }
        else
            .{
                .offset = @intCast(projected.text.len),
                .length = @intCast(projected.selected_model_id.len),
            },
        .tool_call_id = .{ .offset = 0, .length = 0 },
        .tool_title = .{ .offset = 0, .length = 0 },
        .tool_detail = .{ .offset = 0, .length = 0 },
        .tool_input = .{ .offset = 0, .length = 0 },
        .user_input_request_id = .{ .offset = 0, .length = 0 },
        .user_input_question = .{ .offset = 0, .length = 0 },
        .tool_input_presentation = emptyPresentation(),
        .tool_output_presentation = emptyPresentation(),
        .tool_result = projected.tool_result,
        .selected_reasoning = projected.selected_reasoning,
        .switch_outcome = projected.switch_outcome,
        .history_effect = projected.history_effect,
        .session_resume_outcome = projected.session_resume_outcome,
        .default_saved = @intFromBool(projected.default_saved),
        .cleanup_failed = @intFromBool(projected.cleanup_failed),
        .allow_freeform = @intFromBool(projected.allow_freeform),
        .event_reserved = 0,
        .reserved = 0,
    };
    if (byte_capacity < required_bytes or model_capacity < required_models or
        semantic_span_capacity < required_semantic_spans or
        session_capacity < required_sessions or
        transcript_item_capacity < required_transcript_items or
        user_input_choice_capacity < required_user_input_choices)
    {
        return c.VIVI_BACKEND_BUFFER_TOO_SMALL;
    }
    var empty_bytes: [0]u8 = .{};
    var empty_models: [0]c.vivi_backend_model_t = .{};
    var empty_semantic_spans: [0]c.vivi_backend_semantic_span_t = .{};
    var empty_sessions: [0]c.vivi_backend_session_summary_t = .{};
    var empty_transcript_items: [0]c.vivi_backend_transcript_item_t = .{};
    var empty_user_input_choices: [0]c.vivi_backend_user_input_choice_t = .{};
    const byte_destination: []u8 = if (required_bytes > 0)
        (bytes orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_bytes]
    else
        &empty_bytes;
    const model_destination: []c.vivi_backend_model_t = if (required_models > 0)
        (models orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_models]
    else
        &empty_models;
    const semantic_destination: []c.vivi_backend_semantic_span_t =
        if (required_semantic_spans > 0)
            (semantic_spans orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_semantic_spans]
        else
            &empty_semantic_spans;
    const session_destination: []c.vivi_backend_session_summary_t =
        if (required_sessions > 0)
            (sessions orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_sessions]
        else
            &empty_sessions;
    const transcript_destination: []c.vivi_backend_transcript_item_t =
        if (required_transcript_items > 0)
            (transcript_items orelse return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_transcript_items]
        else
            &empty_transcript_items;
    const user_input_choice_destination: []c.vivi_backend_user_input_choice_t =
        if (required_user_input_choices > 0)
            (user_input_choices orelse
                return c.VIVI_BACKEND_INVALID_ARGUMENT)[0..required_user_input_choices]
        else
            &empty_user_input_choices;
    var offset: u32 = 0;
    output.content = appendBytes(byte_destination, &offset, projected.text);
    output.selected_model_id = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.selected_model_id,
    );
    output.tool_call_id = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.tool_call_id,
    );
    output.tool_title = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.tool_title,
    );
    output.tool_detail = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.tool_detail,
    );
    output.tool_input = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.tool_input,
    );
    output.user_input_request_id = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.user_input_request_id,
    );
    output.user_input_question = appendOptionalBytes(
        byte_destination,
        &offset,
        projected.user_input_question,
    );
    var semantic_offset: u32 = 0;
    if (projected.input_presentation) |value| {
        const content_offset = offset;
        output.tool_input_presentation = presentationMetadata(
            value,
            content_offset,
            semantic_offset,
        );
        _ = appendBytes(byte_destination, &offset, value.text);
        copyPresentationSpans(
            value,
            content_offset,
            semantic_destination,
            &semantic_offset,
        );
    }
    if (projected.output_presentation) |value| {
        const content_offset = offset;
        output.tool_output_presentation = presentationMetadata(
            value,
            content_offset,
            semantic_offset,
        );
        _ = appendBytes(byte_destination, &offset, value.text);
        copyPresentationSpans(
            value,
            content_offset,
            semantic_destination,
            &semantic_offset,
        );
    }
    var model_index: usize = 0;
    for (projected.models) |*model| {
        model_destination[model_index] = writeModel(byte_destination, &offset, model);
        model_index += 1;
    }
    if (projected.model) |model| {
        model_destination[model_index] = writeModel(byte_destination, &offset, model);
    }
    var session_index: usize = 0;
    for (projected.sessions) |*session| {
        session_destination[session_index] = writeSessionSummary(
            byte_destination,
            &offset,
            session,
        );
        session_index += 1;
    }
    if (projected.resumed_session) |session| {
        session_destination[session_index] = writeSessionSummary(
            byte_destination,
            &offset,
            session,
        );
    }
    for (projected.transcript, 0..) |*item, index| {
        transcript_destination[index] = writeTranscriptItem(
            byte_destination,
            &offset,
            item,
        );
    }
    for (projected.user_input_choices, 0..) |choice, index| {
        user_input_choice_destination[index] = writeUserInputChoice(
            byte_destination,
            &offset,
            choice,
        );
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
    semantic_spans: ?[*]c.vivi_backend_semantic_span_t,
    semantic_span_capacity: u32,
    sessions: ?[*]c.vivi_backend_session_summary_t,
    session_capacity: u32,
    transcript_items: ?[*]c.vivi_backend_transcript_item_t,
    transcript_item_capacity: u32,
    user_input_choices: ?[*]c.vivi_backend_user_input_choice_t,
    user_input_choice_capacity: u32,
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
            .semantic_span_count = 0,
            .session_count = 0,
            .transcript_item_count = 0,
            .user_input_choice_count = 0,
            .content = .{ .offset = 0, .length = 0 },
            .selected_model_id = .{ .offset = 0, .length = 0 },
            .tool_call_id = .{ .offset = 0, .length = 0 },
            .tool_title = .{ .offset = 0, .length = 0 },
            .tool_detail = .{ .offset = 0, .length = 0 },
            .tool_input = .{ .offset = 0, .length = 0 },
            .user_input_request_id = .{ .offset = 0, .length = 0 },
            .user_input_question = .{ .offset = 0, .length = 0 },
            .tool_input_presentation = emptyPresentation(),
            .tool_output_presentation = emptyPresentation(),
            .tool_result = c.VIVI_BACKEND_TOOL_RESULT_NONE,
            .selected_reasoning = c.VIVI_BACKEND_REASONING_NONE,
            .switch_outcome = c.VIVI_BACKEND_MODEL_SWITCH_NONE,
            .history_effect = c.VIVI_BACKEND_HISTORY_NONE,
            .session_resume_outcome = c.VIVI_BACKEND_SESSION_RESUME_NONE,
            .default_saved = 0,
            .cleanup_failed = 0,
            .allow_freeform = 0,
            .event_reserved = 0,
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
    const copied = copyProjectedFull(
        projected,
        output,
        bytes,
        byte_capacity,
        models,
        model_capacity,
        semantic_spans,
        semantic_span_capacity,
        sessions,
        session_capacity,
        transcript_items,
        transcript_item_capacity,
        user_input_choices,
        user_input_choice_capacity,
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
    } else if ((projected.kind == c.VIVI_BACKEND_EVENT_SESSION_CATALOG or
        projected.kind == c.VIVI_BACKEND_EVENT_SESSION_CATALOG_FAILURE) and
        self.control_operation == .refresh_sessions)
    {
        self.control_operation = .none;
    } else if (projected.kind == c.VIVI_BACKEND_EVENT_SESSION_RESUME and
        self.control_operation == .resume_session)
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

test "C fenced fragment presentation uses atomic caller-owned buffers" {
    const input = "const café = true;\r\n";
    var descriptor: c.vivi_backend_presentation_t = undefined;
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            vivi_backend_present_code_fragment(
                "zig",
                3,
                input,
                input.len,
                &descriptor,
                null,
                0,
                null,
                0,
            ),
    );
    try std.testing.expect(
        descriptor.kind == c.VIVI_BACKEND_PRESENTATION_SOURCE,
    );
    try std.testing.expect(
        descriptor.language == c.VIVI_BACKEND_LANGUAGE_ZIG,
    );
    var bytes = [_]u8{0xaa} ** 64;
    var spans = [_]c.vivi_backend_semantic_span_t{
        std.mem.zeroes(c.vivi_backend_semantic_span_t),
    } ** 16;
    const required_bytes = descriptor.content.length;
    const required_spans = descriptor.semantic_span_count;
    try std.testing.expect(required_spans > 0);
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            vivi_backend_present_code_fragment(
                "zig",
                3,
                input,
                input.len,
                &descriptor,
                &bytes,
                required_bytes,
                &spans,
                required_spans - 1,
            ),
    );
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
    try std.testing.expectEqual(@as(u32, 0), spans[0].bytes.length);
    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            vivi_backend_present_code_fragment(
                "zig",
                3,
                input,
                input.len,
                &descriptor,
                &bytes,
                required_bytes,
                &spans,
                required_spans,
            ),
    );
    try std.testing.expectEqualStrings(
        "const café = true;\n",
        bytes[0..required_bytes],
    );
    for (spans[0..required_spans]) |span| {
        try std.testing.expectEqual(@as(u32, 0), span.reserved);
        try std.testing.expect(span.bytes.length > 0);
        try std.testing.expect(
            span.bytes.offset + span.bytes.length <= required_bytes,
        );
    }
}

test "C event presentation copy is atomic across bytes models and spans" {
    const allocator = std.testing.allocator;
    var started = try backend.ToolStarted.init(
        allocator,
        "call-bash",
        "{\"command\":\"echo ready\"}",
        .{ .bash = .{ .run = .{ .command = "echo ready" } } },
    );
    var event: backend.ConversationEvent = .{
        .tool_activity = .{ .started = started },
    };
    started = undefined;
    defer event.deinit();

    const projected = project(&event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    var bytes = [_]u8{0xaa} ** 128;
    var models = [_]c.vivi_backend_model_t{
        std.mem.zeroes(c.vivi_backend_model_t),
    };
    var spans = [_]c.vivi_backend_semantic_span_t{
        std.mem.zeroes(c.vivi_backend_semantic_span_t),
    } ** 16;
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            copyProjectedWithSpans(
                projected,
                &metadata,
                &bytes,
                bytes.len,
                &models,
                models.len,
                &spans,
                0,
            ),
    );
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
    try std.testing.expectEqual(@as(u32, 0), models[0].id.length);
    try std.testing.expectEqual(@as(u32, 0), spans[0].bytes.length);
    try std.testing.expect(metadata.semantic_span_count > 0);

    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjectedWithSpans(
                projected,
                &metadata,
                &bytes,
                bytes.len,
                &models,
                models.len,
                &spans,
                metadata.semantic_span_count,
            ),
    );
    try std.testing.expect(
        metadata.tool_input_presentation.kind ==
            c.VIVI_BACKEND_PRESENTATION_SOURCE,
    );
    try std.testing.expect(
        metadata.tool_input_presentation.language ==
            c.VIVI_BACKEND_LANGUAGE_BASH,
    );
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
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_request_id.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_request_id.length);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_question.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_question.length);
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
    try std.testing.expectEqual(@as(u32, 1), try modelCount(projected));
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
    try std.testing.expectEqual(@as(u32, 0), try modelCount(projected_failure));
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

test "C user input request copy is atomic with caller-owned choice spans" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{
        .user_input_requested = try backend.UserInputRequest.init(
            allocator,
            "user-input-7",
            "Choose a deployment",
            &.{ "Staging", "Production" },
            true,
        ),
    };
    defer event.deinit();
    const projected = project(&event).?;

    const required_bytes = try byteCount(projected);
    var metadata = std.mem.zeroes(c.vivi_backend_event_t);
    metadata.kind = 255;
    const too_short = try allocator.alloc(u8, required_bytes - 1);
    defer allocator.free(too_short);
    @memset(too_short, 0xaa);
    var choices: [2]c.vivi_backend_user_input_choice_t = undefined;
    @memset(std.mem.asBytes(&choices), 0xbb);
    try std.testing.expectEqual(
        @as(c.vivi_backend_result_t, c.VIVI_BACKEND_BUFFER_TOO_SMALL),
        copyProjectedFull(
            projected,
            &metadata,
            too_short.ptr,
            @intCast(too_short.len),
            null,
            0,
            null,
            0,
            null,
            0,
            null,
            0,
            &choices,
            choices.len,
        ),
    );
    try std.testing.expect(
        metadata.kind == c.VIVI_BACKEND_EVENT_USER_INPUT_REQUEST,
    );
    try std.testing.expectEqual(@as(u32, 2), metadata.user_input_choice_count);
    try std.testing.expect(std.mem.allEqual(u8, too_short, 0xaa));
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&choices), 0xbb));

    const bytes = try allocator.alloc(u8, required_bytes);
    defer allocator.free(bytes);
    try std.testing.expectEqual(
        @as(c.vivi_backend_result_t, c.VIVI_BACKEND_OK),
        copyProjectedFull(
            projected,
            &metadata,
            bytes.ptr,
            @intCast(bytes.len),
            null,
            0,
            null,
            0,
            null,
            0,
            null,
            0,
            &choices,
            choices.len,
        ),
    );
    try std.testing.expect(
        metadata.kind == c.VIVI_BACKEND_EVENT_USER_INPUT_REQUEST,
    );
    try std.testing.expect(
        metadata.content_kind == c.VIVI_BACKEND_CONTENT_USER_INPUT_REQUEST,
    );
    try std.testing.expectEqual(@as(u32, 2), metadata.user_input_choice_count);
    try std.testing.expectEqual(@as(u8, 1), metadata.allow_freeform);
    try std.testing.expectEqualStrings(
        "user-input-7",
        bytes[metadata.user_input_request_id.offset..][0..metadata.user_input_request_id.length],
    );
    try std.testing.expectEqualStrings(
        "Choose a deployment",
        bytes[metadata.user_input_question.offset..][0..metadata.user_input_question.length],
    );
    try std.testing.expectEqualStrings(
        "Staging",
        bytes[choices[0].text.offset..][0..choices[0].text.length],
    );
    try std.testing.expectEqualStrings(
        "Production",
        bytes[choices[1].text.offset..][0..choices[1].text.length],
    );
}

test "C user input response parser rejects malformed typed controls" {
    var raw = std.mem.zeroes(c.vivi_backend_user_input_response_t);
    raw.struct_size = @sizeOf(c.vivi_backend_user_input_response_t);
    raw.answer_kind = c.VIVI_BACKEND_USER_INPUT_ANSWER_CHOICE;
    raw.request_id = "user-input-1";
    raw.request_id_length = "user-input-1".len;
    raw.answer = "Beta";
    raw.answer_length = "Beta".len;

    const parsed = userInputResponse(&raw).?;
    try std.testing.expectEqualStrings("user-input-1", parsed.request_id);
    try std.testing.expect(parsed.answer == .choice);
    try std.testing.expectEqualStrings("Beta", parsed.answer.text());

    raw.reserved = 1;
    try std.testing.expect(userInputResponse(&raw) == null);
    raw.reserved = 0;
    raw.answer_kind = 99;
    try std.testing.expect(userInputResponse(&raw) == null);
    raw.answer_kind = c.VIVI_BACKEND_USER_INPUT_ANSWER_FREEFORM;
    raw.answer = " \t";
    raw.answer_length = 2;
    try std.testing.expect(userInputResponse(&raw) == null);
    raw.answer = "\xff";
    raw.answer_length = 1;
    try std.testing.expect(userInputResponse(&raw) == null);
    raw.answer = "Custom";
    raw.answer_length = "Custom".len;
    raw.request_id = null;
    try std.testing.expect(userInputResponse(&raw) == null);
}

test "C session title projection rejects noncanonical text" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{
        .session_title = try backend.OwnedText.init(
            allocator,
            "Native\n title",
        ),
    };
    defer event.deinit();
    try std.testing.expectEqual(null, project(&event));
}

test "C session catalog copy is atomic and preserves opaque keys" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{ .session_catalog = .{
        .allocator = allocator,
        .sessions = try allocator.alloc(backend.SessionSummary, 1),
    } };
    defer event.deinit();
    event.session_catalog.sessions[0] = .{
        .allocator = allocator,
        .key = .{ .generation = 41, .slot = 7 },
        .working_directory = try allocator.dupe(u8, "/tmp/other"),
        .title = try allocator.dupe(u8, "Other session"),
        .current = false,
    };

    const projected = project(&event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    var bytes = [_]u8{0xaa} ** 64;
    var sessions = [_]c.vivi_backend_session_summary_t{
        std.mem.zeroes(c.vivi_backend_session_summary_t),
    };
    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            copyProjectedFull(
                projected,
                &metadata,
                &bytes,
                bytes.len,
                null,
                0,
                null,
                0,
                &sessions,
                0,
                null,
                0,
                null,
                0,
            ),
    );
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
    try std.testing.expectEqual(@as(u64, 0), sessions[0].key.generation);
    try std.testing.expectEqual(@as(u32, 1), metadata.session_count);

    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjectedFull(
                projected,
                &metadata,
                &bytes,
                bytes.len,
                null,
                0,
                null,
                0,
                &sessions,
                sessions.len,
                null,
                0,
                null,
                0,
            ),
    );
    try std.testing.expect(
        metadata.kind == c.VIVI_BACKEND_EVENT_SESSION_CATALOG,
    );
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_request_id.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_request_id.length);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_question.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_question.length);
    try std.testing.expectEqual(@as(u64, 41), sessions[0].key.generation);
    try std.testing.expectEqual(@as(u32, 7), sessions[0].key.slot);
    try std.testing.expect(
        sessions[0].flags & c.VIVI_BACKEND_SESSION_TITLE_PRESENT != 0,
    );
    try std.testing.expectEqualStrings(
        "/tmp/other",
        bytes[sessions[0].working_directory.offset..][0..sessions[0].working_directory.length],
    );
}

test "C session catalog projection rejects noncanonical titles" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{ .session_catalog = .{
        .allocator = allocator,
        .sessions = try allocator.alloc(backend.SessionSummary, 1),
    } };
    defer event.deinit();
    event.session_catalog.sessions[0] = .{
        .allocator = allocator,
        .key = .{ .generation = 41, .slot = 7 },
        .working_directory = try allocator.dupe(u8, "/tmp/other"),
        .title = try allocator.dupe(u8, "Other\nsession"),
        .current = false,
    };
    try std.testing.expectEqual(null, project(&event));
}

test "C session resume copies summary and ordered transcript atomically" {
    const allocator = std.testing.allocator;
    const items = try allocator.alloc(backend.TranscriptItem, 3);
    items[0] = try backend.TranscriptItem.init(allocator, .user, "");
    items[1] = try backend.TranscriptItem.init(allocator, .reasoning, "thinking");
    items[2] = try backend.TranscriptItem.init(allocator, .assistant, "answer");
    var event: backend.ConversationEvent = .{ .session_resume = .{ .resumed = .{
        .session = .{
            .allocator = allocator,
            .key = .{ .generation = 9, .slot = 2 },
            .working_directory = try allocator.dupe(u8, "/tmp/project"),
            .title = null,
            .current = false,
        },
        .transcript = .{ .allocator = allocator, .items = items },
        .cleanup_failed = true,
    } } };
    defer event.deinit();

    const projected = project(&event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    const bytes = try allocator.alloc(u8, try byteCount(projected));
    defer allocator.free(bytes);
    var sessions = [_]c.vivi_backend_session_summary_t{
        std.mem.zeroes(c.vivi_backend_session_summary_t),
    };
    var transcript = [_]c.vivi_backend_transcript_item_t{
        std.mem.zeroes(c.vivi_backend_transcript_item_t),
    } ** 3;

    try std.testing.expect(
        c.VIVI_BACKEND_BUFFER_TOO_SMALL ==
            copyProjectedFull(
                projected,
                &metadata,
                bytes.ptr,
                @intCast(bytes.len),
                null,
                0,
                null,
                0,
                &sessions,
                sessions.len,
                &transcript,
                2,
                null,
                0,
            ),
    );
    try std.testing.expectEqual(@as(u64, 0), sessions[0].key.generation);
    try std.testing.expectEqual(@as(u32, 0), transcript[0].text.length);

    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjectedFull(
                projected,
                &metadata,
                bytes.ptr,
                @intCast(bytes.len),
                null,
                0,
                null,
                0,
                &sessions,
                sessions.len,
                &transcript,
                transcript.len,
                null,
                0,
            ),
    );
    try std.testing.expect(
        metadata.session_resume_outcome ==
            c.VIVI_BACKEND_SESSION_RESUME_RESUMED,
    );
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_request_id.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_request_id.length);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_question.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.user_input_question.length);
    try std.testing.expectEqual(@as(u8, 1), metadata.cleanup_failed);
    try std.testing.expectEqual(@as(u32, 3), metadata.transcript_item_count);
    try std.testing.expect(
        transcript[0].role == c.VIVI_BACKEND_TRANSCRIPT_USER,
    );
    try std.testing.expectEqual(@as(u32, 0), transcript[0].text.length);
    try std.testing.expect(
        transcript[1].role == c.VIVI_BACKEND_TRANSCRIPT_REASONING,
    );
    try std.testing.expectEqualStrings(
        "thinking",
        bytes[transcript[1].text.offset..][0..transcript[1].text.length],
    );
}

test "C failed session resume keeps optional metadata neutral" {
    const allocator = std.testing.allocator;
    var event: backend.ConversationEvent = .{
        .session_resume = .{
            .failed = try backend.OwnedText.init(
                allocator,
                "The selected session is no longer available.",
            ),
        },
    };
    defer event.deinit();

    const projected = project(&event).?;
    var metadata: c.vivi_backend_event_t = undefined;
    const bytes = try allocator.alloc(u8, try byteCount(projected));
    defer allocator.free(bytes);

    try std.testing.expect(
        c.VIVI_BACKEND_OK ==
            copyProjectedFull(
                projected,
                &metadata,
                bytes.ptr,
                @intCast(bytes.len),
                null,
                0,
                null,
                0,
                null,
                0,
                null,
                0,
                null,
                0,
            ),
    );
    try std.testing.expect(
        metadata.session_resume_outcome ==
            c.VIVI_BACKEND_SESSION_RESUME_FAILED,
    );
    try std.testing.expectEqual(@as(u32, 0), metadata.selected_model_id.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.selected_model_id.length);
    try std.testing.expectEqual(@as(u32, 0), metadata.tool_call_id.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.tool_title.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.tool_detail.offset);
    try std.testing.expectEqual(@as(u32, 0), metadata.tool_input.offset);
    try std.testing.expectEqualStrings(
        "The selected session is no longer available.",
        bytes[metadata.content.offset..][0..metadata.content.length],
    );
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
