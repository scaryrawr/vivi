const std = @import("std");
const session_title = @import("session_title.zig");
const tool_activity = @import("tool_activity.zig");
const attachment = @import("attachment.zig");

pub const Wake = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) void,
};

pub const FailureKind = enum {
    startup,
    stream,
};

pub const OwnedText = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !OwnedText {
        return .{
            .bytes = try allocator.dupe(u8, text),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OwnedText) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Prompt = struct {
    text: []const u8,
    attachments: []const attachment.Input = &.{},
};

pub const PromptContent = struct {
    text: []const u8,
    attachments: []const attachment.Snapshot = &.{},
};

pub const OwnedPrompt = struct {
    text: OwnedText,
    attachments: []attachment.Snapshot = &.{},

    fn init(allocator: std.mem.Allocator, prompt: Prompt) !OwnedPrompt {
        var text = try OwnedText.init(allocator, prompt.text);
        errdefer text.deinit();
        return .{
            .text = text,
            .attachments = try attachment.snapshotAll(allocator, prompt.attachments),
        };
    }

    pub fn borrow(self: *const OwnedPrompt) PromptContent {
        return .{ .text = self.text.bytes, .attachments = self.attachments };
    }

    pub fn deinit(self: *OwnedPrompt) void {
        attachment.deinitAll(self.text.allocator, self.attachments);
        self.text.deinit();
        self.* = undefined;
    }
};

test "prompt owns submitted attachment bytes and metadata" {
    const allocator = std.testing.allocator;
    const text = try allocator.dupe(u8, "look here");
    const bytes = try allocator.dupe(u8, "\x89PNG\r\n\x1a\noriginal");
    const display_name = try allocator.dupe(u8, "image.png");
    var prompt = try OwnedPrompt.init(allocator, .{
        .text = text,
        .attachments = &.{.{
            .identity = "image-1",
            .display_name = display_name,
            .media_type = .png,
            .bytes = bytes,
        }},
    });
    defer prompt.deinit();
    allocator.free(text);
    allocator.free(bytes);
    allocator.free(display_name);
    try std.testing.expectEqualStrings("look here", prompt.borrow().text);
    try std.testing.expectEqualStrings(
        "\x89PNG\r\n\x1a\noriginal",
        prompt.borrow().attachments[0].bytes,
    );
    try std.testing.expectEqualStrings(
        "image.png",
        prompt.borrow().attachments[0].display_name,
    );
}

test "session catalog snapshots retain opaque keys and owned display text" {
    const source_items = try std.testing.allocator.alloc(TranscriptItem, 1);
    var source = TranscriptSnapshot{
        .allocator = std.testing.allocator,
        .items = source_items,
    };
    defer source.deinit();
    source.items[0] = try TranscriptItem.init(
        std.testing.allocator,
        .assistant,
        "persisted answer",
    );
    var snapshot = try source.clone(std.testing.allocator);
    defer snapshot.deinit();

    var summary = SessionSummary{
        .allocator = std.testing.allocator,
        .key = .{ .generation = 4, .slot = 2 },
        .working_directory = try std.testing.allocator.dupe(u8, "/work/vivi"),
        .title = try std.testing.allocator.dupe(u8, "Remote session"),
        .current = false,
    };
    defer summary.deinit();
    try std.testing.expectEqual(@as(u64, 4), summary.key.generation);
    try std.testing.expectEqualStrings("persisted answer", snapshot.items[0].text);
}

pub const Failure = struct {
    kind: FailureKind,
    message: OwnedText,

    pub fn deinit(self: *Failure) void {
        self.message.deinit();
        self.* = undefined;
    }
};

pub const CommandKey = struct {
    generation: u64,
    slot: u32,
};

pub const CommandSource = enum {
    vivi,
    sdk_builtin,
    extension,
};

pub const CommandAction = enum {
    execute,
    open_model_selection,
    open_session_history,
};

pub const CommandArgumentPolicy = enum {
    none,
    optional,
    required,
};

pub const CommandInfo = struct {
    key: CommandKey,
    name: []u8,
    display_name: []u8,
    description: []u8,
    hint: ?[]u8,
    source: CommandSource,
    action: CommandAction,
    argument_policy: CommandArgumentPolicy,

    pub fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.display_name);
        allocator.free(self.description);
        if (self.hint) |hint| allocator.free(hint);
        self.* = undefined;
    }
};

pub const CommandCatalog = struct {
    allocator: std.mem.Allocator,
    commands: []CommandInfo,

    pub fn deinit(self: *CommandCatalog) void {
        for (self.commands) |*command| command.deinit(self.allocator);
        self.allocator.free(self.commands);
        self.* = undefined;
    }

    pub fn clone(
        self: *const CommandCatalog,
        allocator: std.mem.Allocator,
    ) !CommandCatalog {
        const commands = try allocator.alloc(CommandInfo, self.commands.len);
        errdefer allocator.free(commands);
        var initialized: usize = 0;
        errdefer for (commands[0..initialized]) |*command| {
            command.deinit(allocator);
        };
        for (self.commands, 0..) |command, index| {
            commands[index] = .{
                .key = command.key,
                .name = try allocator.dupe(u8, command.name),
                .display_name = undefined,
                .description = undefined,
                .hint = null,
                .source = command.source,
                .action = command.action,
                .argument_policy = command.argument_policy,
            };
            errdefer allocator.free(commands[index].name);
            commands[index].display_name = try allocator.dupe(
                u8,
                command.display_name,
            );
            errdefer allocator.free(commands[index].display_name);
            commands[index].description = try allocator.dupe(
                u8,
                command.description,
            );
            errdefer allocator.free(commands[index].description);
            commands[index].hint = if (command.hint) |hint|
                try allocator.dupe(u8, hint)
            else
                null;
            initialized += 1;
        }
        return .{ .allocator = allocator, .commands = commands };
    }

    pub fn find(self: *const CommandCatalog, key: CommandKey) ?*const CommandInfo {
        if (key.generation == 0 or key.slot == 0) return null;
        const index = std.math.sub(u32, key.slot, 1) catch return null;
        if (index >= self.commands.len) return null;
        const command = &self.commands[index];
        if (command.key.generation != key.generation or
            command.key.slot != key.slot)
        {
            return null;
        }
        return command;
    }
};

pub const CommandCatalogEvent = union(enum) {
    replaced: CommandCatalog,
    failed: OwnedText,

    pub fn deinit(self: *CommandCatalogEvent) void {
        switch (self.*) {
            .replaced => |*catalog| catalog.deinit(),
            .failed => |*message| message.deinit(),
        }
        self.* = undefined;
    }
};

pub const CommandExecutionEvent = union(enum) {
    completed: struct {
        key: CommandKey,
        message: OwnedText,
    },
    failed: struct {
        key: CommandKey,
        message: OwnedText,
    },

    pub fn deinit(self: *CommandExecutionEvent) void {
        switch (self.*) {
            inline else => |*result| result.message.deinit(),
        }
        self.* = undefined;
    }
};

pub const ModelInfo = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    display_name: []u8,
    max_context_window_tokens: u64,
    max_output_tokens: u64,
    supports_vision: bool,
    reasoning: ReasoningProfile,

    pub fn deinit(self: *ModelInfo) void {
        self.allocator.free(self.id);
        self.allocator.free(self.display_name);
        self.* = undefined;
    }

    pub fn clone(
        self: *const ModelInfo,
        allocator: std.mem.Allocator,
    ) !ModelInfo {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        return .{
            .allocator = allocator,
            .id = id,
            .display_name = try allocator.dupe(u8, self.display_name),
            .max_context_window_tokens = self.max_context_window_tokens,
            .max_output_tokens = self.max_output_tokens,
            .supports_vision = self.supports_vision,
            .reasoning = self.reasoning,
        };
    }
};

pub const ReasoningEffort = enum {
    off,
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn parse(value: []const u8) !ReasoningEffort {
        inline for (std.meta.tags(ReasoningEffort)) |effort| {
            if (std.mem.eql(u8, value, @tagName(effort))) return effort;
        }
        return error.InvalidReasoningEffort;
    }
};

pub const ReasoningEffortSet = packed struct(u8) {
    off: bool = false,
    low: bool = false,
    medium: bool = false,
    high: bool = false,
    xhigh: bool = false,
    max: bool = false,
    reserved: u2 = 0,

    pub fn contains(self: ReasoningEffortSet, effort: ReasoningEffort) bool {
        return switch (effort) {
            .off => self.off,
            .low => self.low,
            .medium => self.medium,
            .high => self.high,
            .xhigh => self.xhigh,
            .max => self.max,
        };
    }

    pub fn count(self: ReasoningEffortSet) usize {
        var result: usize = 0;
        inline for (std.meta.tags(ReasoningEffort)) |effort| {
            if (self.contains(effort)) result += 1;
        }
        return result;
    }
};

pub const ReasoningProfile = struct {
    selectable: ReasoningEffortSet,
    advertised_default: ?ReasoningEffort,
};

pub const ModelSelection = struct {
    model_id: []const u8,
    reasoning: ReasoningEffort,
};

pub const OwnedModelSelection = struct {
    allocator: std.mem.Allocator,
    model_id: []u8,
    reasoning: ReasoningEffort,

    pub fn init(
        allocator: std.mem.Allocator,
        selection: ModelSelection,
    ) !OwnedModelSelection {
        return .{
            .allocator = allocator,
            .model_id = try allocator.dupe(u8, selection.model_id),
            .reasoning = selection.reasoning,
        };
    }

    pub fn view(self: *const OwnedModelSelection) ModelSelection {
        return .{
            .model_id = self.model_id,
            .reasoning = self.reasoning,
        };
    }

    pub fn clone(
        self: *const OwnedModelSelection,
        allocator: std.mem.Allocator,
    ) !OwnedModelSelection {
        return init(allocator, self.view());
    }

    pub fn deinit(self: *OwnedModelSelection) void {
        self.allocator.free(self.model_id);
        self.* = undefined;
    }
};

pub const ModelCatalog = struct {
    allocator: std.mem.Allocator,
    selected: OwnedModelSelection,
    models: []ModelInfo,

    pub fn deinit(self: *ModelCatalog) void {
        allocatorFreeModels(self.allocator, self.models);
        self.selected.deinit();
        self.* = undefined;
    }

    pub fn clone(
        self: *const ModelCatalog,
        allocator: std.mem.Allocator,
    ) !ModelCatalog {
        const values = try allocator.alloc(ModelInfo, self.models.len);
        errdefer allocator.free(values);
        var initialized: usize = 0;
        errdefer for (values[0..initialized]) |*value| value.deinit();
        for (self.models, 0..) |model, index| {
            values[index] = try model.clone(allocator);
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .selected = try self.selected.clone(allocator),
            .models = values,
        };
    }
};

pub const SessionSummary = struct {
    allocator: std.mem.Allocator,
    key: ResumeKey,
    working_directory: []u8,
    title: ?[]u8 = null,
    current: bool,

    pub fn deinit(self: *SessionSummary) void {
        self.allocator.free(self.working_directory);
        if (self.title) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn clone(
        self: *const SessionSummary,
        allocator: std.mem.Allocator,
    ) !SessionSummary {
        const working_directory = try allocator.dupe(
            u8,
            self.working_directory,
        );
        errdefer allocator.free(working_directory);
        const title = if (self.title) |value|
            try allocator.dupe(u8, value)
        else
            null;
        return .{
            .allocator = allocator,
            .key = self.key,
            .working_directory = working_directory,
            .title = title,
            .current = self.current,
        };
    }
};

/// A catalog key is valid only for the refresh generation that created it.
/// The SDK session ID never leaves root.zig.
pub const ResumeKey = struct {
    generation: u64,
    slot: u32,
};

pub const SessionCatalog = struct {
    allocator: std.mem.Allocator,
    sessions: []SessionSummary,

    pub fn deinit(self: *SessionCatalog) void {
        for (self.sessions) |*session| session.deinit();
        self.allocator.free(self.sessions);
        self.* = undefined;
    }

    pub fn clone(
        self: *const SessionCatalog,
        allocator: std.mem.Allocator,
    ) !SessionCatalog {
        const sessions = try allocator.alloc(
            SessionSummary,
            self.sessions.len,
        );
        errdefer allocator.free(sessions);
        var initialized: usize = 0;
        errdefer for (sessions[0..initialized]) |*session| session.deinit();
        for (self.sessions, 0..) |session, index| {
            sessions[index] = try session.clone(allocator);
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .sessions = sessions,
        };
    }
};

pub const TranscriptRole = enum {
    user,
    assistant,
    reasoning,
};

pub const TranscriptItem = struct {
    allocator: std.mem.Allocator,
    role: TranscriptRole,
    text: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        role: TranscriptRole,
        text: []const u8,
    ) !TranscriptItem {
        return .{
            .allocator = allocator,
            .role = role,
            .text = try allocator.dupe(u8, text),
        };
    }

    pub fn deinit(self: *TranscriptItem) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn clone(
        self: *const TranscriptItem,
        allocator: std.mem.Allocator,
    ) !TranscriptItem {
        return init(allocator, self.role, self.text);
    }
};

pub const TranscriptSnapshot = struct {
    allocator: std.mem.Allocator,
    items: []TranscriptItem,

    pub fn deinit(self: *TranscriptSnapshot) void {
        for (self.items) |*item| item.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn clone(
        self: *const TranscriptSnapshot,
        allocator: std.mem.Allocator,
    ) !TranscriptSnapshot {
        const items = try allocator.alloc(TranscriptItem, self.items.len);
        errdefer allocator.free(items);
        var initialized: usize = 0;
        errdefer for (items[0..initialized]) |*item| item.deinit();
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            initialized += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }
};

pub const SessionResumeResult = union(enum) {
    resumed: struct {
        session: SessionSummary,
        transcript: TranscriptSnapshot,
        cleanup_failed: bool,
    },
    failed: OwnedText,

    pub fn deinit(self: *SessionResumeResult) void {
        switch (self.*) {
            .resumed => |*result| {
                result.session.deinit();
                result.transcript.deinit();
            },
            .failed => |*message| message.deinit(),
        }
        self.* = undefined;
    }
};

fn allocatorFreeModels(allocator: std.mem.Allocator, values: []ModelInfo) void {
    for (values) |*value| value.deinit();
    allocator.free(values);
}

pub const HistoryEffect = enum {
    preserved,
    reset_visible_transcript_preserved,
};

pub const ModelSwitchResult = union(enum) {
    unchanged: struct {
        model: ModelInfo,
        selection: OwnedModelSelection,
    },
    default_updated: struct {
        model: ModelInfo,
        selection: OwnedModelSelection,
    },
    switched: struct {
        model: ModelInfo,
        selection: OwnedModelSelection,
        history: HistoryEffect,
        default_saved: bool,
        cleanup_failed: bool,
    },
    failed: OwnedText,

    pub fn deinit(self: *ModelSwitchResult) void {
        switch (self.*) {
            .unchanged => |*result| {
                result.model.deinit();
                result.selection.deinit();
            },
            .default_updated => |*result| {
                result.model.deinit();
                result.selection.deinit();
            },
            .switched => |*result| {
                result.model.deinit();
                result.selection.deinit();
            },
            .failed => |*message| message.deinit(),
        }
        self.* = undefined;
    }
};

pub const PromptDelivery = enum {
    immediate,
    enqueue,
};

pub const max_command_argument_bytes = 64 * 1024;
pub const max_user_input_request_id_bytes = 4 * 1024;
pub const max_user_input_question_bytes = 64 * 1024;
pub const max_user_input_choices = 100;
pub const max_user_input_choice_bytes = 16 * 1024;
pub const max_user_input_answer_bytes = 64 * 1024;

fn validateUserInputText(
    text: []const u8,
    max_bytes: usize,
    empty_error: anyerror,
) !void {
    if (text.len == 0) return empty_error;
    if (text.len > max_bytes) return error.UserInputTextTooLong;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUserInputUtf8;
}

pub const UserInputRequest = struct {
    allocator: std.mem.Allocator,
    request_id: []u8,
    question: []u8,
    choices: [][]u8,
    allow_freeform: bool,

    pub fn deinit(self: *UserInputRequest) void {
        self.allocator.free(self.request_id);
        self.allocator.free(self.question);
        for (self.choices) |choice| self.allocator.free(choice);
        self.allocator.free(self.choices);
        self.* = undefined;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        request_id: []const u8,
        question: []const u8,
        choices: []const []const u8,
        allow_freeform: bool,
    ) !UserInputRequest {
        try validateUserInputText(
            request_id,
            max_user_input_request_id_bytes,
            error.EmptyUserInputRequestId,
        );
        try validateUserInputText(
            question,
            max_user_input_question_bytes,
            error.EmptyUserInputQuestion,
        );
        if (choices.len > max_user_input_choices) {
            return error.TooManyUserInputChoices;
        }
        if (choices.len == 0 and !allow_freeform) {
            return error.UserInputRequestHasNoAnswers;
        }
        for (choices, 0..) |choice, index| {
            try validateUserInputText(
                choice,
                max_user_input_choice_bytes,
                error.EmptyUserInputChoice,
            );
            if (std.mem.trim(u8, choice, " \t\r\n").len == 0) {
                return error.EmptyUserInputChoice;
            }
            for (choices[0..index]) |previous| {
                if (std.mem.eql(u8, choice, previous)) {
                    return error.DuplicateUserInputChoice;
                }
            }
        }
        const owned_choices = try allocator.alloc([]u8, choices.len);
        errdefer allocator.free(owned_choices);
        var initialized: usize = 0;
        errdefer for (owned_choices[0..initialized]) |choice| {
            allocator.free(choice);
        };
        for (choices, 0..) |choice, index| {
            owned_choices[index] = try allocator.dupe(u8, choice);
            initialized += 1;
        }
        const owned_request_id = try allocator.dupe(u8, request_id);
        errdefer allocator.free(owned_request_id);
        return .{
            .allocator = allocator,
            .request_id = owned_request_id,
            .question = try allocator.dupe(u8, question),
            .choices = owned_choices,
            .allow_freeform = allow_freeform,
        };
    }

    pub fn clone(
        self: *const UserInputRequest,
        allocator: std.mem.Allocator,
    ) !UserInputRequest {
        return init(
            allocator,
            self.request_id,
            self.question,
            self.choices,
            self.allow_freeform,
        );
    }
};

pub const UserInputAnswer = union(enum) {
    choice: []const u8,
    freeform: []const u8,

    pub fn text(self: UserInputAnswer) []const u8 {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

pub const UserInputResponse = struct {
    request_id: []const u8,
    answer: UserInputAnswer,
};

const OwnedUserInputAnswer = union(enum) {
    choice: OwnedText,
    freeform: OwnedText,

    fn init(allocator: std.mem.Allocator, answer: UserInputAnswer) !OwnedUserInputAnswer {
        return switch (answer) {
            .choice => |value| .{ .choice = try OwnedText.init(allocator, value) },
            .freeform => |value| .{ .freeform = try OwnedText.init(allocator, value) },
        };
    }

    fn view(self: *const OwnedUserInputAnswer) UserInputAnswer {
        return switch (self.*) {
            .choice => |value| .{ .choice = value.bytes },
            .freeform => |value| .{ .freeform = value.bytes },
        };
    }

    fn deinit(self: *OwnedUserInputAnswer) void {
        switch (self.*) {
            inline else => |*value| value.deinit(),
        }
        self.* = undefined;
    }
};

const OwnedUserInputResponse = struct {
    request_id: OwnedText,
    answer: OwnedUserInputAnswer,

    fn init(
        allocator: std.mem.Allocator,
        response: UserInputResponse,
    ) !OwnedUserInputResponse {
        var request_id = try OwnedText.init(allocator, response.request_id);
        errdefer request_id.deinit();
        return .{
            .request_id = request_id,
            .answer = try .init(allocator, response.answer),
        };
    }

    pub fn view(self: *const OwnedUserInputResponse) UserInputResponse {
        return .{
            .request_id = self.request_id.bytes,
            .answer = self.answer.view(),
        };
    }

    fn deinit(self: *OwnedUserInputResponse) void {
        self.request_id.deinit();
        self.answer.deinit();
        self.* = undefined;
    }
};

pub const Closed = union(enum) {
    requested,
    failed: Failure,

    pub fn deinit(self: *Closed) void {
        switch (self.*) {
            .requested => {},
            .failed => |*failure| failure.deinit(),
        }
        self.* = undefined;
    }
};

pub const Event = union(enum) {
    ready,
    command_catalog: CommandCatalogEvent,
    model_catalog: ModelCatalog,
    model_catalog_failed: OwnedText,
    model_switch: ModelSwitchResult,
    session_catalog: SessionCatalog,
    session_catalog_failed: OwnedText,
    session_resume: SessionResumeResult,
    session_title: OwnedText,
    status: OwnedText,
    assistant_started,
    reasoning_delta: OwnedText,
    reasoning_complete: OwnedText,
    assistant_delta: OwnedText,
    assistant_complete: OwnedText,
    tool_activity: tool_activity.ToolActivityUpdate,
    user_input_requested: UserInputRequest,
    command_completed: CommandExecutionEvent,
    idle,
    closed: Closed,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .reasoning_delta,
            .reasoning_complete,
            .assistant_delta,
            .assistant_complete,
            .session_title,
            => |*text| text.deinit(),
            .command_completed => |*result| result.deinit(),
            .tool_activity => |*update| update.deinit(),
            .user_input_requested => |*request| request.deinit(),
            .command_catalog => |*catalog| catalog.deinit(),
            .model_catalog => |*catalog| catalog.deinit(),
            .model_catalog_failed => |*text| text.deinit(),
            .model_switch => |*result| result.deinit(),
            .session_catalog => |*catalog| catalog.deinit(),
            .session_catalog_failed => |*text| text.deinit(),
            .session_resume => |*result| result.deinit(),
            .status => |*text| text.deinit(),
            .closed => |*closed| closed.deinit(),
            .ready, .assistant_started, .idle => {},
        }
        self.* = undefined;
    }
};

const OwnedCommandInvocation = struct {
    key: CommandKey,
    name: OwnedText,
    arguments: OwnedText,

    fn deinit(self: *OwnedCommandInvocation) void {
        self.name.deinit();
        self.arguments.deinit();
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    prompt: struct {
        message: OwnedPrompt,
        delivery: PromptDelivery,
    },
    refresh_commands,
    refresh_models,
    refresh_sessions,
    switch_model: OwnedModelSelection,
    resume_session: ResumeKey,
    execute_command: OwnedCommandInvocation,
    user_input_response: OwnedUserInputResponse,
    stop,

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .prompt => |*prompt| prompt.message.deinit(),
            .switch_model => |*selection| selection.deinit(),
            .execute_command => |*invocation| invocation.deinit(),
            .user_input_response => |*response| response.deinit(),
            .refresh_commands,
            .refresh_models,
            .refresh_sessions,
            .resume_session,
            .stop,
            => {},
        }
        self.* = undefined;
    }
};

const State = enum {
    starting,
    idle,
    streaming,
    controlling,
    awaiting_user_input,
    stopping,
    closed,
};

const Runner = *const fn (worker: *Worker) void;
const ContextRunner = *const fn (worker: *Worker, context: *anyopaque) void;
const ContextDestroy = *const fn (
    allocator: std.mem.Allocator,
    context: *anyopaque,
) void;

const RunnerConfig = union(enum) {
    plain: Runner,
    context: struct {
        pointer: *anyopaque,
        run: ContextRunner,
        destroy: ContextDestroy,
    },
};

const Core = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    runner: RunnerConfig,
    mutex: std.Io.Mutex = .init,
    command_ready: std.Io.Condition = .init,
    state: State = .starting,
    commands: std.ArrayList(Command) = .empty,
    events: std.ArrayList(Event) = .empty,
    pending_user_input: ?UserInputRequest = null,
    command_catalog: ?CommandCatalog = null,
    next_user_input_request_id: u64 = 1,
    wake_pending: bool = false,
    stop_requested: bool = false,
    worker: ?std.Io.Future(void) = null,
};

pub const Worker = struct {
    core: *Core,

    pub fn allocator(self: Worker) std.mem.Allocator {
        return self.core.allocator;
    }

    pub fn io(self: Worker) std.Io {
        return self.core.io;
    }

    pub fn ready(self: *Worker) !bool {
        try self.core.mutex.lock(self.core.io);
        if (self.core.stop_requested) {
            self.core.state = .stopping;
            self.core.mutex.unlock(self.core.io);
            return false;
        }
        self.core.state = .idle;
        self.core.mutex.unlock(self.core.io);
        try self.publish(.ready);
        return true;
    }

    pub fn waitCommand(self: *Worker) Command {
        self.core.mutex.lock(self.core.io) catch return .stop;
        defer self.core.mutex.unlock(self.core.io);

        while (self.core.commands.items.len == 0 and
            !self.core.stop_requested)
        {
            self.core.command_ready.wait(
                self.core.io,
                &self.core.mutex,
            ) catch return .stop;
        }
        if (self.core.stop_requested) return .stop;

        return self.core.commands.orderedRemove(0);
    }

    pub fn waitUserInputResponse(self: *Worker) Command {
        self.core.mutex.lock(self.core.io) catch return .stop;
        defer self.core.mutex.unlock(self.core.io);

        while (true) {
            if (self.core.stop_requested) return .stop;
            for (self.core.commands.items, 0..) |command, index| {
                switch (command) {
                    .user_input_response, .stop => {
                        return self.core.commands.orderedRemove(index);
                    },
                    else => {},
                }
            }
            self.core.command_ready.wait(
                self.core.io,
                &self.core.mutex,
            ) catch return .stop;
        }
    }

    pub fn tryTakeCommand(self: *Worker) ?Command {
        self.core.mutex.lock(self.core.io) catch return .stop;
        defer self.core.mutex.unlock(self.core.io);

        if (self.core.stop_requested) return .stop;
        if (self.core.commands.items.len == 0) return null;
        return self.core.commands.orderedRemove(0);
    }

    pub fn tryTakeImmediateCommand(self: *Worker) ?Command {
        self.core.mutex.lock(self.core.io) catch return .stop;
        defer self.core.mutex.unlock(self.core.io);

        if (self.core.stop_requested) return .stop;
        for (self.core.commands.items, 0..) |command, index| {
            switch (command) {
                .prompt => |prompt| {
                    if (prompt.delivery == .immediate) {
                        return self.core.commands.orderedRemove(index);
                    }
                },
                .stop => return self.core.commands.orderedRemove(index),
                .refresh_commands,
                .refresh_models,
                .refresh_sessions,
                .switch_model,
                .resume_session,
                .execute_command,
                .user_input_response,
                => {},
            }
        }
        return null;
    }

    pub fn assistantDelta(self: *Worker, text: []const u8) !void {
        try self.publish(.{
            .assistant_delta = try OwnedText.init(self.core.allocator, text),
        });
    }

    pub fn reasoningDelta(self: *Worker, text: []const u8) !void {
        try self.publish(.{
            .reasoning_delta = try OwnedText.init(self.core.allocator, text),
        });
    }

    pub fn reasoningComplete(self: *Worker, text: []const u8) !void {
        try self.publish(.{
            .reasoning_complete = try OwnedText.init(
                self.core.allocator,
                text,
            ),
        });
    }

    pub fn assistantStarted(self: *Worker) !void {
        try self.core.mutex.lock(self.core.io);
        if (!self.core.stop_requested) self.core.state = .streaming;
        self.core.mutex.unlock(self.core.io);
        try self.publish(.assistant_started);
    }

    fn installCommandCatalog(
        self: *Worker,
        catalog: *const CommandCatalog,
    ) !void {
        var replacement = try catalog.clone(self.core.allocator);
        errdefer replacement.deinit();
        try self.core.mutex.lock(self.core.io);
        if (self.core.command_catalog) |*current| current.deinit();
        self.core.command_catalog = replacement;
        self.core.mutex.unlock(self.core.io);
    }

    pub fn commandCatalog(self: *Worker, catalog: CommandCatalog) !void {
        try self.installCommandCatalog(&catalog);
        try self.publish(.{ .command_catalog = .{ .replaced = catalog } });
    }

    pub fn commandCatalogFailed(self: *Worker, message: []const u8) !void {
        try self.publish(.{ .command_catalog = .{
            .failed = try OwnedText.init(self.core.allocator, message),
        } });
    }

    pub fn userInputRequested(
        self: *Worker,
        question: []const u8,
        choices: []const []const u8,
        allow_freeform: bool,
    ) !void {
        try self.core.mutex.lock(self.core.io);
        if (self.core.stop_requested) {
            self.core.mutex.unlock(self.core.io);
            return error.Stopping;
        }
        const request_number = self.core.next_user_input_request_id;
        if (request_number == std.math.maxInt(u64)) {
            self.core.mutex.unlock(self.core.io);
            return error.UserInputRequestIdExhausted;
        }
        self.core.next_user_input_request_id += 1;
        self.core.mutex.unlock(self.core.io);

        const request_id = try std.fmt.allocPrint(
            self.core.allocator,
            "user-input-{d}",
            .{request_number},
        );
        defer self.core.allocator.free(request_id);
        var request = try UserInputRequest.init(
            self.core.allocator,
            request_id,
            question,
            choices,
            allow_freeform,
        );
        var request_owned = true;
        defer if (request_owned) request.deinit();
        {
            var pending = try request.clone(self.core.allocator);
            errdefer pending.deinit();
            try self.core.mutex.lock(self.core.io);
            if (self.core.stop_requested) {
                self.core.mutex.unlock(self.core.io);
                return error.Stopping;
            }
            if (self.core.pending_user_input != null) {
                self.core.mutex.unlock(self.core.io);
                return error.AlreadyAwaitingUserInput;
            }
            self.core.pending_user_input = pending;
            self.core.state = .awaiting_user_input;
            self.core.mutex.unlock(self.core.io);
        }
        request_owned = false;
        self.publish(.{ .user_input_requested = request }) catch |err| {
            try self.core.mutex.lock(self.core.io);
            if (self.core.pending_user_input) |*active| active.deinit();
            self.core.pending_user_input = null;
            if (!self.core.stop_requested) self.core.state = .streaming;
            self.core.mutex.unlock(self.core.io);
            return err;
        };
    }

    pub fn commandCompleted(
        self: *Worker,
        key: CommandKey,
        message: []const u8,
    ) !void {
        try self.completeControl(.{
            .command_completed = .{ .completed = .{
                .key = key,
                .message = try OwnedText.init(self.core.allocator, message),
            } },
        });
    }

    pub fn commandFailed(
        self: *Worker,
        key: CommandKey,
        message: []const u8,
    ) !void {
        try self.completeControl(.{
            .command_completed = .{ .failed = .{
                .key = key,
                .message = try OwnedText.init(self.core.allocator, message),
            } },
        });
    }

    pub fn modelCatalog(self: *Worker, catalog: ModelCatalog) !void {
        try self.publish(.{ .model_catalog = catalog });
    }

    pub fn modelCatalogFailed(self: *Worker, message: []const u8) !void {
        try self.publish(.{
            .model_catalog_failed = try OwnedText.init(
                self.core.allocator,
                message,
            ),
        });
    }

    pub fn completeModelRefresh(
        self: *Worker,
        catalog: ModelCatalog,
    ) !void {
        try self.completeControl(.{ .model_catalog = catalog });
    }

    pub fn completeCommandRefresh(
        self: *Worker,
        catalog: CommandCatalog,
    ) !void {
        try self.installCommandCatalog(&catalog);
        try self.completeControl(.{
            .command_catalog = .{ .replaced = catalog },
        });
    }

    pub fn completeModelRefreshFailure(
        self: *Worker,
        message: []const u8,
    ) !void {
        try self.completeControl(.{
            .model_catalog_failed = try OwnedText.init(
                self.core.allocator,
                message,
            ),
        });
    }

    pub fn completeModelSwitch(
        self: *Worker,
        result: ModelSwitchResult,
    ) !void {
        try self.completeControl(.{ .model_switch = result });
    }

    pub fn completeSessionRefresh(
        self: *Worker,
        catalog: SessionCatalog,
    ) !void {
        try self.completeControl(.{ .session_catalog = catalog });
    }

    pub fn completeSessionRefreshFailure(
        self: *Worker,
        message: []const u8,
    ) !void {
        try self.completeControl(.{
            .session_catalog_failed = try OwnedText.init(
                self.core.allocator,
                message,
            ),
        });
    }

    pub fn status(self: *Worker, message: []const u8) !void {
        try self.publish(.{
            .status = try OwnedText.init(self.core.allocator, message),
        });
    }

    pub fn sessionTitle(self: *Worker, title: []const u8) !void {
        if (!session_title.isCanonical(title)) {
            return error.InvalidSessionTitle;
        }
        try self.publish(.{
            .session_title = try OwnedText.init(self.core.allocator, title),
        });
    }

    pub fn completeSessionResume(
        self: *Worker,
        result: SessionResumeResult,
    ) !void {
        try self.completeControl(.{ .session_resume = result });
    }

    pub fn assistantComplete(self: *Worker, text: []const u8) !void {
        try self.publish(.{
            .assistant_complete = try OwnedText.init(self.core.allocator, text),
        });
    }

    pub fn toolActivity(
        self: *Worker,
        update: tool_activity.ToolActivityUpdate,
    ) !void {
        try self.publish(.{ .tool_activity = update });
    }

    pub fn idle(self: *Worker) !void {
        try self.core.mutex.lock(self.core.io);
        if (!self.core.stop_requested) self.core.state = .idle;
        self.core.mutex.unlock(self.core.io);
        try self.publish(.idle);
    }

    fn completeControl(self: *Worker, event: Event) !void {
        self.core.mutex.lock(self.core.io) catch |err| {
            var owned_event = event;
            owned_event.deinit();
            return err;
        };
        if (!self.core.stop_requested) self.core.state = .idle;
        self.core.mutex.unlock(self.core.io);
        return self.publish(event);
    }

    pub fn closeRequested(self: *Worker) void {
        self.close(.requested);
    }

    pub fn closeFailure(
        self: *Worker,
        kind: FailureKind,
        message: []const u8,
    ) void {
        const text = OwnedText.init(self.core.allocator, message) catch return;
        self.close(.{ .failed = .{
            .kind = kind,
            .message = text,
        } });
    }

    fn close(self: *Worker, closed: Closed) void {
        self.core.mutex.lock(self.core.io) catch {
            var mutable = closed;
            mutable.deinit();
            return;
        };
        self.core.state = .closed;
        self.core.mutex.unlock(self.core.io);
        self.publish(.{ .closed = closed }) catch {};
    }

    fn publish(self: *Worker, event: Event) !void {
        var owned_event = event;
        errdefer owned_event.deinit();

        try self.core.mutex.lock(self.core.io);
        const should_wake = !self.core.wake_pending;
        self.core.events.append(
            self.core.allocator,
            owned_event,
        ) catch |err| {
            self.core.mutex.unlock(self.core.io);
            return err;
        };
        self.core.wake_pending = true;
        self.core.mutex.unlock(self.core.io);

        if (should_wake) self.core.wake.notify(self.core.wake.context);
    }
};

pub const Conversation = struct {
    core: *Core,

    pub fn submit(
        self: *Conversation,
        prompt: Prompt,
        delivery: PromptDelivery,
    ) !void {
        if (std.mem.trim(u8, prompt.text, " \t\r\n").len == 0 and prompt.attachments.len == 0) {
            return error.EmptyPrompt;
        }

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);

        switch (self.core.state) {
            .idle, .streaming => {},
            .starting, .controlling, .awaiting_user_input => return error.Busy,
            .stopping => return error.Stopping,
            .closed => return error.Closed,
        }
        const owned_prompt = try OwnedPrompt.init(self.core.allocator, prompt);
        errdefer {
            var mutable = owned_prompt;
            mutable.deinit();
        }
        try self.core.commands.append(self.core.allocator, .{
            .prompt = .{
                .message = owned_prompt,
                .delivery = delivery,
            },
        });
        self.core.state = .streaming;
        self.core.command_ready.signal(self.core.io);
    }

    pub fn refreshModels(self: *Conversation) !void {
        try self.enqueueControl(.refresh_models);
    }

    pub fn refreshCommands(self: *Conversation) !void {
        try self.enqueueControl(.refresh_commands);
    }

    pub fn refreshSessions(self: *Conversation) !void {
        try self.enqueueControl(.refresh_sessions);
    }

    pub fn switchModel(self: *Conversation, selection: ModelSelection) !void {
        if (std.mem.trim(u8, selection.model_id, " \t\r\n").len == 0) {
            return error.EmptyModel;
        }
        try self.enqueueControl(.{
            .switch_model = try OwnedModelSelection.init(
                self.core.allocator,
                selection,
            ),
        });
    }

    pub fn executeCommand(
        self: *Conversation,
        key: CommandKey,
        arguments: []const u8,
    ) !void {
        if (key.generation == 0 or key.slot == 0) return error.InvalidCommandKey;
        if (arguments.len > max_command_argument_bytes) {
            return error.CommandArgumentsTooLong;
        }
        if (!std.unicode.utf8ValidateSlice(arguments)) {
            return error.InvalidCommandArgumentsUtf8;
        }

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);

        switch (self.core.state) {
            .idle => {},
            .starting,
            .streaming,
            .controlling,
            .awaiting_user_input,
            => return error.Busy,
            .stopping => return error.Stopping,
            .closed => return error.Closed,
        }
        const catalog = self.core.command_catalog orelse
            return error.CommandCatalogUnavailable;
        if (catalog.commands.len == 0 or
            catalog.commands[0].key.generation != key.generation)
        {
            return error.StaleCommandKey;
        }
        const command = catalog.find(key) orelse return error.InvalidCommandKey;
        if (command.action != .execute) return error.CommandIsNotExecutable;
        const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
        switch (command.argument_policy) {
            .none => if (trimmed.len != 0) return error.CommandTakesNoArguments,
            .required => if (trimmed.len == 0) return error.CommandRequiresArguments,
            .optional => {},
        }
        var name = try OwnedText.init(self.core.allocator, command.name);
        errdefer name.deinit();
        var owned_arguments = try OwnedText.init(
            self.core.allocator,
            arguments,
        );
        errdefer owned_arguments.deinit();
        try self.core.commands.append(self.core.allocator, .{
            .execute_command = .{
                .key = key,
                .name = name,
                .arguments = owned_arguments,
            },
        });
        self.core.state = .controlling;
        self.core.command_ready.signal(self.core.io);
    }

    pub fn resumeSession(self: *Conversation, key: ResumeKey) !void {
        if (key.generation == 0) return error.InvalidSessionKey;
        try self.enqueueControl(.{ .resume_session = key });
    }

    pub fn respondToUserInput(
        self: *Conversation,
        response: UserInputResponse,
    ) !void {
        try validateUserInputText(
            response.request_id,
            max_user_input_request_id_bytes,
            error.EmptyUserInputRequestId,
        );
        const answer = response.answer.text();
        if (std.mem.trim(u8, answer, " \t\r\n").len == 0) return error.EmptyAnswer;
        if (answer.len > max_user_input_answer_bytes) return error.UserInputTextTooLong;
        if (!std.unicode.utf8ValidateSlice(answer)) return error.InvalidUserInputUtf8;
        var owned_response = try OwnedUserInputResponse.init(
            self.core.allocator,
            response,
        );
        errdefer owned_response.deinit();

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);
        if (self.core.state != .awaiting_user_input) return error.NotAwaitingInput;
        const request = self.core.pending_user_input orelse
            return error.NotAwaitingInput;
        if (!std.mem.eql(u8, request.request_id, response.request_id)) {
            return error.StaleUserInputRequest;
        }
        switch (response.answer) {
            .choice => |choice| {
                for (request.choices) |expected| {
                    if (std.mem.eql(u8, expected, choice)) break;
                } else return error.InvalidUserInputChoice;
            },
            .freeform => {
                if (!request.allow_freeform) return error.FreeformUserInputNotAllowed;
            },
        }
        try self.core.commands.append(self.core.allocator, .{
            .user_input_response = owned_response,
        });
        var completed = self.core.pending_user_input.?;
        completed.deinit();
        self.core.pending_user_input = null;
        self.core.state = .streaming;
        self.core.command_ready.signal(self.core.io);
    }

    fn enqueueControl(self: *Conversation, command: Command) !void {
        var owned_command = command;
        errdefer owned_command.deinit();

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);

        switch (self.core.state) {
            .idle => {},
            .starting,
            .streaming,
            .controlling,
            .awaiting_user_input,
            => return error.Busy,
            .stopping => return error.Stopping,
            .closed => return error.Closed,
        }
        try self.core.commands.append(self.core.allocator, owned_command);
        self.core.state = .controlling;
        self.core.command_ready.signal(self.core.io);
    }

    pub fn tryTakeEvent(self: *Conversation) !?Event {
        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);

        if (self.core.events.items.len == 0) {
            self.core.wake_pending = false;
            return null;
        }
        const event = self.core.events.orderedRemove(0);
        if (self.core.events.items.len == 0) self.core.wake_pending = false;
        return event;
    }

    pub fn requestStop(self: *Conversation) void {
        self.core.mutex.lock(self.core.io) catch return;
        defer self.core.mutex.unlock(self.core.io);

        if (self.core.state == .closed) return;
        self.core.stop_requested = true;
        self.core.state = .stopping;
        self.core.command_ready.signal(self.core.io);
    }

    pub fn deinit(self: *Conversation) void {
        self.requestStop();
        if (self.core.worker) |*worker| {
            worker.await(self.core.io);
        }

        for (self.core.commands.items) |*command| command.deinit();
        self.core.commands.deinit(self.core.allocator);
        for (self.core.events.items) |*event| event.deinit();
        self.core.events.deinit(self.core.allocator);
        if (self.core.pending_user_input) |*request| request.deinit();
        if (self.core.command_catalog) |*catalog| catalog.deinit();
        const allocator = self.core.allocator;
        switch (self.core.runner) {
            .plain => {},
            .context => |context| context.destroy(
                allocator,
                context.pointer,
            ),
        }
        allocator.destroy(self.core);
        self.* = undefined;
    }
};

pub fn openWithRunner(
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    runner: Runner,
) !Conversation {
    const core = try allocator.create(Core);
    errdefer allocator.destroy(core);
    core.* = .{
        .allocator = allocator,
        .io = io,
        .wake = wake,
        .runner = .{ .plain = runner },
    };
    core.worker = try io.concurrent(runWorker, .{core});
    return .{ .core = core };
}

pub fn openWithContextRunner(
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    context: *anyopaque,
    runner: ContextRunner,
    destroy: ContextDestroy,
) !Conversation {
    const core = try allocator.create(Core);
    errdefer allocator.destroy(core);
    core.* = .{
        .allocator = allocator,
        .io = io,
        .wake = wake,
        .runner = .{ .context = .{
            .pointer = context,
            .run = runner,
            .destroy = destroy,
        } },
    };
    core.worker = try io.concurrent(runWorker, .{core});
    return .{ .core = core };
}

fn runWorker(core: *Core) void {
    var worker: Worker = .{ .core = core };
    switch (core.runner) {
        .plain => |runner| runner(&worker),
        .context => |context| context.run(&worker, context.pointer),
    }
}

fn testCommandCatalog(
    allocator: std.mem.Allocator,
    generation: u64,
) !CommandCatalog {
    const commands = try allocator.alloc(CommandInfo, 2);
    errdefer allocator.free(commands);
    commands[0] = .{
        .key = .{ .generation = generation, .slot = 1 },
        .name = try allocator.dupe(u8, "required"),
        .display_name = try allocator.dupe(u8, "required"),
        .description = try allocator.dupe(u8, "Needs input"),
        .hint = try allocator.dupe(u8, "value"),
        .source = .sdk_builtin,
        .action = .execute,
        .argument_policy = .required,
    };
    errdefer commands[0].deinit(allocator);
    commands[1] = .{
        .key = .{ .generation = generation, .slot = 2 },
        .name = try allocator.dupe(u8, "plain"),
        .display_name = try allocator.dupe(u8, "plain"),
        .description = try allocator.dupe(u8, "No input"),
        .hint = null,
        .source = .extension,
        .action = .execute,
        .argument_policy = .none,
    };
    return .{ .allocator = allocator, .commands = commands };
}

test "command admission rejects invalid arguments and stale keys" {
    const Script = struct {
        fn run(worker: *Worker) void {
            if (!(worker.ready() catch return)) return;
            worker.commandCatalog(
                testCommandCatalog(worker.allocator(), 1) catch return,
            ) catch return;
            var command = worker.waitCommand();
            defer command.deinit();
            switch (command) {
                .execute_command => |invocation| {
                    if (invocation.key.generation != 1 or
                        invocation.key.slot != 1 or
                        !std.mem.eql(u8, invocation.name.bytes, "required") or
                        !std.mem.eql(u8, invocation.arguments.bytes, "value"))
                    {
                        worker.closeFailure(.stream, "Unexpected invocation.");
                        return;
                    }
                    worker.commandCompleted(
                        invocation.key,
                        "Command complete.",
                    ) catch return;
                    worker.commandCatalog(
                        testCommandCatalog(worker.allocator(), 2) catch return,
                    ) catch return;
                },
                else => {
                    worker.closeFailure(.stream, "Unexpected command.");
                    return;
                },
            }
            var stop = worker.waitCommand();
            stop.deinit();
            worker.closeRequested();
        }
    };
    const TestWake = struct {
        fn notify(_: *anyopaque) void {}
    };
    var ignored: u8 = 0;
    var conversation = try openWithRunner(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &ignored, .notify = TestWake.notify },
        Script.run,
    );
    defer conversation.deinit();

    var first_catalog_seen = false;
    while (!first_catalog_seen) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event == .command_catalog) {
                first_catalog_seen = event.command_catalog == .replaced;
            }
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    try std.testing.expectError(
        error.CommandRequiresArguments,
        conversation.executeCommand(.{ .generation = 1, .slot = 1 }, ""),
    );
    try std.testing.expectError(
        error.CommandTakesNoArguments,
        conversation.executeCommand(.{ .generation = 1, .slot = 2 }, "extra"),
    );
    try std.testing.expectError(
        error.InvalidCommandArgumentsUtf8,
        conversation.executeCommand(
            .{ .generation = 1, .slot = 1 },
            &.{0xff},
        ),
    );
    try conversation.executeCommand(
        .{ .generation = 1, .slot = 1 },
        "value",
    );

    var second_catalog_seen = false;
    while (!second_catalog_seen) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event == .command_catalog) {
                second_catalog_seen = event.command_catalog == .replaced and
                    event.command_catalog.replaced.commands[0].key.generation == 2;
            }
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    try std.testing.expectError(
        error.StaleCommandKey,
        conversation.executeCommand(.{ .generation = 1, .slot = 1 }, "value"),
    );
}

test "command execution events preserve keys and outcomes" {
    const key = CommandKey{ .generation = 3, .slot = 4 };
    var completed = CommandExecutionEvent{ .completed = .{
        .key = key,
        .message = try OwnedText.init(std.testing.allocator, "done"),
    } };
    defer completed.deinit();
    try std.testing.expectEqual(key, completed.completed.key);
    try std.testing.expectEqualStrings(
        "done",
        completed.completed.message.bytes,
    );

    var failed = CommandExecutionEvent{ .failed = .{
        .key = key,
        .message = try OwnedText.init(std.testing.allocator, "failed"),
    } };
    defer failed.deinit();
    try std.testing.expectEqual(key, failed.failed.key);
    try std.testing.expectEqualStrings(
        "failed",
        failed.failed.message.bytes,
    );
}

test "conversation transfers streamed events without SDK access" {
    const Script = struct {
        fn run(worker: *Worker) void {
            if (!(worker.ready() catch return)) {
                worker.closeRequested();
                return;
            }

            var command = worker.waitCommand();
            defer command.deinit();
            switch (command) {
                .prompt => |prompt| {
                    if (prompt.delivery != .enqueue) {
                        worker.closeFailure(.stream, "Unexpected prompt delivery.");
                        return;
                    }
                    worker.assistantDelta("hel") catch return;
                    worker.assistantComplete("hello") catch return;
                    worker.idle() catch return;
                },
                .stop => {
                    worker.closeRequested();
                    return;
                },
                .refresh_commands,
                .refresh_models,
                .refresh_sessions,
                .switch_model,
                .resume_session,
                .execute_command,
                .user_input_response,
                => {
                    worker.closeFailure(.stream, "Unexpected control command.");
                    return;
                },
            }
            var stop = worker.waitCommand();
            stop.deinit();
            worker.closeRequested();
        }
    };
    const WakeCounter = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };

    var wake_counter: WakeCounter = .{};
    var conversation = try openWithRunner(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &wake_counter, .notify = WakeCounter.notify },
        Script.run,
    );
    defer conversation.deinit();

    var ready_seen = false;
    while (!ready_seen) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            ready_seen = event == .ready;
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    try conversation.submit(.{ .text = "hello" }, .enqueue);
    var received: usize = 0;
    while (received < 3) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            received += 1;
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    try std.testing.expect(wake_counter.count.load(.monotonic) > 0);
}

test "conversation transfers owned tool lifecycle events without SDK access" {
    const Script = struct {
        fn run(worker: *Worker) void {
            const started = tool_activity.ToolStarted.init(
                worker.allocator(),
                "call-1",
                "{\"path\":\"file.txt\"}",
                .{ .read = .{
                    .path = "file.txt",
                    .offset = null,
                    .limit = null,
                } },
            ) catch return;
            worker.toolActivity(.{ .started = started }) catch return;
            const finished = tool_activity.ToolFinished.initPresented(
                worker.allocator(),
                "call-1",
                .{ .read = .{
                    .path = "file.txt",
                    .offset = null,
                    .limit = null,
                } },
                .{ .succeeded = "contents" },
            ) catch return;
            worker.toolActivity(.{ .finished = finished }) catch return;
            var stop = worker.waitCommand();
            stop.deinit();
            worker.closeRequested();
        }
    };
    const WakeCounter = struct {
        fn notify(_: *anyopaque) void {}
    };

    var wake_context: u8 = 0;
    var conversation = try openWithRunner(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &wake_context, .notify = WakeCounter.notify },
        Script.run,
    );
    defer conversation.deinit();

    var started_seen = false;
    var finished_seen = false;
    while (!finished_seen) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            switch (event) {
                .tool_activity => |update| switch (update) {
                    .started => |started| {
                        try std.testing.expectEqualStrings(
                            "call-1",
                            started.call_id.bytes,
                        );
                        try std.testing.expectEqualStrings(
                            "{\"path\":\"file.txt\"}",
                            started.invocation.arguments_json,
                        );
                        started_seen = true;
                    },
                    .finished => |finished| {
                        try std.testing.expect(started_seen);
                        try std.testing.expectEqualStrings(
                            "contents",
                            finished.result.succeeded,
                        );
                        finished_seen = true;
                    },
                },
                else => {},
            }
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }
}

test "conversation accepts steering and queued prompts while streaming" {
    const Script = struct {
        fn run(worker: *Worker) void {
            if (!(worker.ready() catch return)) {
                worker.closeRequested();
                return;
            }
            var first = worker.waitCommand();
            defer first.deinit();
            const first_prompt = switch (first) {
                .prompt => |prompt| prompt,
                else => {
                    worker.closeFailure(.stream, "Expected first prompt.");
                    return;
                },
            };
            if (first_prompt.delivery != .enqueue or
                !std.mem.eql(u8, first_prompt.message.text.bytes, "first"))
            {
                worker.closeFailure(.stream, "Unexpected first prompt.");
                return;
            }

            var steer = worker.waitCommand();
            defer steer.deinit();
            const steer_prompt = switch (steer) {
                .prompt => |prompt| prompt,
                else => {
                    worker.closeFailure(.stream, "Expected steering prompt.");
                    return;
                },
            };
            if (steer_prompt.delivery != .immediate or
                !std.mem.eql(u8, steer_prompt.message.text.bytes, "steer"))
            {
                worker.closeFailure(.stream, "Unexpected steering prompt.");
                return;
            }

            var queued = worker.waitCommand();
            defer queued.deinit();
            const queued_prompt = switch (queued) {
                .prompt => |prompt| prompt,
                else => {
                    worker.closeFailure(.stream, "Expected queued prompt.");
                    return;
                },
            };
            if (queued_prompt.delivery != .enqueue or
                !std.mem.eql(u8, queued_prompt.message.text.bytes, "later"))
            {
                worker.closeFailure(.stream, "Unexpected queued prompt.");
                return;
            }
            worker.idle() catch return;

            var stop = worker.waitCommand();
            stop.deinit();
            worker.closeRequested();
        }
    };
    const WakeCounter = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };

    var wake_counter: WakeCounter = .{};
    var conversation = try openWithRunner(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &wake_counter, .notify = WakeCounter.notify },
        Script.run,
    );
    defer conversation.deinit();

    while (true) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event == .ready) break;
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    try conversation.submit(.{ .text = "first" }, .enqueue);
    try conversation.submit(.{ .text = "steer" }, .immediate);
    try conversation.submit(.{ .text = "later" }, .enqueue);
}

test "conversation accepts an answer only while user input is pending" {
    const Script = struct {
        fn run(worker: *Worker) void {
            if (!(worker.ready() catch return)) {
                worker.closeRequested();
                return;
            }
            var prompt = worker.waitCommand();
            defer prompt.deinit();
            if (prompt != .prompt) {
                worker.closeFailure(.stream, "Expected prompt.");
                return;
            }
            worker.userInputRequested(
                "Choose",
                &.{ "one", "two" },
                false,
            ) catch return;

            var response = worker.waitCommand();
            defer response.deinit();
            switch (response) {
                .user_input_response => |value| {
                    const typed = value.view();
                    if (!std.mem.eql(
                        u8,
                        typed.request_id,
                        "user-input-1",
                    ) or
                        typed.answer != .choice or
                        !std.mem.eql(u8, typed.answer.text(), "two"))
                    {
                        worker.closeFailure(.stream, "Unexpected answer.");
                        return;
                    }
                },
                else => {
                    worker.closeFailure(.stream, "Expected user input.");
                    return;
                },
            }
            worker.idle() catch return;

            var stop = worker.waitCommand();
            stop.deinit();
            worker.closeRequested();
        }
    };
    const WakeCounter = struct {
        count: std.atomic.Value(usize) = .init(0),

        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };

    var wake_counter: WakeCounter = .{};
    var conversation = try openWithRunner(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &wake_counter, .notify = WakeCounter.notify },
        Script.run,
    );
    defer conversation.deinit();

    while (true) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event == .ready) break;
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    try std.testing.expectError(
        error.NotAwaitingInput,
        conversation.respondToUserInput(.{
            .request_id = "user-input-1",
            .answer = .{ .choice = "two" },
        }),
    );
    try conversation.submit(.{ .text = "ask" }, .immediate);

    while (true) {
        if (try conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event == .user_input_requested) {
                try std.testing.expectEqualStrings(
                    "Choose",
                    event.user_input_requested.question,
                );
                break;
            }
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    try std.testing.expectError(
        error.StaleUserInputRequest,
        conversation.respondToUserInput(.{
            .request_id = "user-input-2",
            .answer = .{ .choice = "two" },
        }),
    );
    try std.testing.expectError(
        error.InvalidUserInputChoice,
        conversation.respondToUserInput(.{
            .request_id = "user-input-1",
            .answer = .{ .choice = "three" },
        }),
    );
    try std.testing.expectError(
        error.FreeformUserInputNotAllowed,
        conversation.respondToUserInput(.{
            .request_id = "user-input-1",
            .answer = .{ .freeform = "two" },
        }),
    );
    try conversation.respondToUserInput(.{
        .request_id = "user-input-1",
        .answer = .{ .choice = "two" },
    });
    try std.testing.expectError(
        error.NotAwaitingInput,
        conversation.respondToUserInput(.{
            .request_id = "user-input-1",
            .answer = .{ .choice = "two" },
        }),
    );
}

test "user input request validates typed answer surface" {
    try std.testing.expectError(
        error.EmptyUserInputRequestId,
        UserInputRequest.init(std.testing.allocator, "", "Question?", &.{"yes"}, false),
    );
    try std.testing.expectError(
        error.EmptyUserInputQuestion,
        UserInputRequest.init(std.testing.allocator, "request", "", &.{"yes"}, false),
    );
    try std.testing.expectError(
        error.UserInputRequestHasNoAnswers,
        UserInputRequest.init(std.testing.allocator, "request", "Question?", &.{}, false),
    );
    try std.testing.expectError(
        error.DuplicateUserInputChoice,
        UserInputRequest.init(
            std.testing.allocator,
            "request",
            "Question?",
            &.{ "yes", "yes" },
            false,
        ),
    );
    try std.testing.expectError(
        error.EmptyUserInputChoice,
        UserInputRequest.init(
            std.testing.allocator,
            "request",
            "Question?",
            &.{" \t\r\n"},
            false,
        ),
    );
    try std.testing.expectError(
        error.InvalidUserInputUtf8,
        UserInputRequest.init(
            std.testing.allocator,
            "request",
            "Question?",
            &.{"\xff"},
            false,
        ),
    );
}

test "waiting for user input preserves queued prompts" {
    const Harness = struct {
        fn run(_: *Worker) void {}

        fn notify(_: *anyopaque) void {}
    };

    var wake_context: u8 = 0;
    var core: Core = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .wake = .{
            .context = &wake_context,
            .notify = Harness.notify,
        },
        .runner = .{ .plain = Harness.run },
    };
    defer {
        for (core.commands.items) |*command| command.deinit();
        core.commands.deinit(std.testing.allocator);
    }
    try core.commands.append(std.testing.allocator, .{
        .prompt = .{
            .message = try OwnedPrompt.init(std.testing.allocator, .{ .text = "later" }),
            .delivery = .enqueue,
        },
    });
    try core.commands.append(std.testing.allocator, .{
        .user_input_response = try OwnedUserInputResponse.init(
            std.testing.allocator,
            .{
                .request_id = "request-1",
                .answer = .{ .choice = "two" },
            },
        ),
    });

    var worker: Worker = .{ .core = &core };
    var response = worker.waitUserInputResponse();
    defer response.deinit();
    try std.testing.expect(response == .user_input_response);

    var queued = worker.tryTakeCommand().?;
    defer queued.deinit();
    try std.testing.expect(queued == .prompt);
    try std.testing.expectEqualStrings("later", queued.prompt.message.text.bytes);
}
