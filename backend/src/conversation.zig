const std = @import("std");
const tool_activity = @import("tool_activity.zig");

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

pub const Failure = struct {
    kind: FailureKind,
    message: OwnedText,

    pub fn deinit(self: *Failure) void {
        self.message.deinit();
        self.* = undefined;
    }
};

pub const CommandInfo = struct {
    name: []u8,
    description: []u8,

    fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
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
                .name = try allocator.dupe(u8, command.name),
                .description = undefined,
            };
            errdefer allocator.free(commands[index].name);
            commands[index].description = try allocator.dupe(
                u8,
                command.description,
            );
            initialized += 1;
        }
        return .{ .allocator = allocator, .commands = commands };
    }
};

pub const ModelInfo = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    display_name: []u8,
    max_context_window_tokens: u64,
    max_output_tokens: u64,
    supports_vision: bool,

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
        };
    }
};

pub const ModelCatalog = struct {
    allocator: std.mem.Allocator,
    selected_id: []u8,
    models: []ModelInfo,

    pub fn deinit(self: *ModelCatalog) void {
        allocatorFreeModels(self.allocator, self.models);
        self.allocator.free(self.selected_id);
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
            .selected_id = try allocator.dupe(u8, self.selected_id),
            .models = values,
        };
    }
};

pub const SessionSummary = struct {
    allocator: std.mem.Allocator,
    key: u64,
    working_directory: []u8,
    model_id: []u8,
    last_used_unix_ms: i64,
    current: bool,

    pub fn deinit(self: *SessionSummary) void {
        self.allocator.free(self.working_directory);
        self.allocator.free(self.model_id);
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
        return .{
            .allocator = allocator,
            .key = self.key,
            .working_directory = working_directory,
            .model_id = try allocator.dupe(u8, self.model_id),
            .last_used_unix_ms = self.last_used_unix_ms,
            .current = self.current,
        };
    }
};

pub const SessionCatalog = struct {
    allocator: std.mem.Allocator,
    sessions: []SessionSummary,
    skipped_invalid_shards: bool,

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
            .skipped_invalid_shards = self.skipped_invalid_shards,
        };
    }
};

pub const SessionResumeResult = union(enum) {
    resumed: struct {
        session: SessionSummary,
        cleanup_failed: bool,
    },
    failed: OwnedText,

    pub fn deinit(self: *SessionResumeResult) void {
        switch (self.*) {
            .resumed => |*result| result.session.deinit(),
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
    unchanged: ModelInfo,
    default_updated: ModelInfo,
    switched: struct {
        model: ModelInfo,
        history: HistoryEffect,
        default_saved: bool,
        cleanup_failed: bool,
    },
    failed: OwnedText,

    pub fn deinit(self: *ModelSwitchResult) void {
        switch (self.*) {
            .unchanged => |*model| model.deinit(),
            .default_updated => |*model| model.deinit(),
            .switched => |*result| result.model.deinit(),
            .failed => |*message| message.deinit(),
        }
        self.* = undefined;
    }
};

pub const PromptDelivery = enum {
    immediate,
    enqueue,
};

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
    command_catalog: CommandCatalog,
    model_catalog: ModelCatalog,
    model_catalog_failed: OwnedText,
    model_switch: ModelSwitchResult,
    session_catalog: SessionCatalog,
    session_catalog_failed: OwnedText,
    session_tracking_failed: OwnedText,
    session_resume: SessionResumeResult,
    assistant_started,
    reasoning_delta: OwnedText,
    reasoning_complete: OwnedText,
    assistant_delta: OwnedText,
    assistant_complete: OwnedText,
    tool_activity: tool_activity.ToolActivityUpdate,
    user_input_requested: UserInputRequest,
    command_completed: OwnedText,
    idle,
    closed: Closed,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .reasoning_delta,
            .reasoning_complete,
            .assistant_delta,
            .assistant_complete,
            .command_completed,
            => |*text| text.deinit(),
            .tool_activity => |*update| update.deinit(),
            .user_input_requested => |*request| request.deinit(),
            .command_catalog => |*catalog| catalog.deinit(),
            .model_catalog => |*catalog| catalog.deinit(),
            .model_catalog_failed => |*text| text.deinit(),
            .model_switch => |*result| result.deinit(),
            .session_catalog => |*catalog| catalog.deinit(),
            .session_catalog_failed => |*text| text.deinit(),
            .session_tracking_failed => |*text| text.deinit(),
            .session_resume => |*result| result.deinit(),
            .closed => |*closed| closed.deinit(),
            .ready, .assistant_started, .idle => {},
        }
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    prompt: struct {
        text: OwnedText,
        delivery: PromptDelivery,
    },
    refresh_commands,
    refresh_models,
    refresh_sessions,
    switch_model: OwnedText,
    resume_session: u64,
    execute_command: OwnedText,
    user_input_response: struct {
        request_id: OwnedText,
        answer: OwnedText,
        was_freeform: bool,
    },
    stop,

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .prompt => |*prompt| prompt.text.deinit(),
            .switch_model, .execute_command => |*text| text.deinit(),
            .user_input_response => |*response| {
                response.request_id.deinit();
                response.answer.deinit();
            },
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

    pub fn commandCatalog(self: *Worker, catalog: CommandCatalog) !void {
        try self.publish(.{ .command_catalog = catalog });
    }

    pub fn userInputRequested(
        self: *Worker,
        request: UserInputRequest,
    ) !void {
        try self.core.mutex.lock(self.core.io);
        if (!self.core.stop_requested) self.core.state = .awaiting_user_input;
        self.core.mutex.unlock(self.core.io);
        try self.publish(.{ .user_input_requested = request });
    }

    pub fn commandCompleted(self: *Worker, message: []const u8) !void {
        try self.completeControl(.{
            .command_completed = try OwnedText.init(
                self.core.allocator,
                message,
            ),
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
        try self.completeControl(.{ .command_catalog = catalog });
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

    pub fn sessionTrackingFailed(
        self: *Worker,
        message: []const u8,
    ) !void {
        try self.publish(.{
            .session_tracking_failed = try OwnedText.init(
                self.core.allocator,
                message,
            ),
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
        prompt: []const u8,
        delivery: PromptDelivery,
    ) !void {
        if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
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
        const owned_prompt = try OwnedText.init(self.core.allocator, prompt);
        errdefer {
            var mutable = owned_prompt;
            mutable.deinit();
        }
        try self.core.commands.append(self.core.allocator, .{
            .prompt = .{
                .text = owned_prompt,
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

    pub fn switchModel(self: *Conversation, model_id: []const u8) !void {
        if (std.mem.trim(u8, model_id, " \t\r\n").len == 0) {
            return error.EmptyModel;
        }
        try self.enqueueControl(.{
            .switch_model = try OwnedText.init(self.core.allocator, model_id),
        });
    }

    pub fn executeCommand(
        self: *Conversation,
        command: []const u8,
    ) !void {
        if (std.mem.trim(u8, command, " \t\r\n").len == 0) {
            return error.EmptyCommand;
        }
        try self.enqueueControl(.{
            .execute_command = try OwnedText.init(
                self.core.allocator,
                command,
            ),
        });
    }

    pub fn resumeSession(self: *Conversation, key: u64) !void {
        if (key == 0) return error.InvalidSessionKey;
        try self.enqueueControl(.{ .resume_session = key });
    }

    pub fn respondToUserInput(
        self: *Conversation,
        request_id: []const u8,
        answer: []const u8,
        was_freeform: bool,
    ) !void {
        if (std.mem.trim(u8, answer, " \t\r\n").len == 0) {
            return error.EmptyAnswer;
        }
        const owned_request_id = try OwnedText.init(
            self.core.allocator,
            request_id,
        );
        errdefer {
            var mutable = owned_request_id;
            mutable.deinit();
        }
        const owned_answer = try OwnedText.init(self.core.allocator, answer);
        errdefer {
            var mutable = owned_answer;
            mutable.deinit();
        }

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);
        if (self.core.state != .awaiting_user_input) return error.NotAwaitingInput;
        try self.core.commands.append(self.core.allocator, .{
            .user_input_response = .{
                .request_id = owned_request_id,
                .answer = owned_answer,
                .was_freeform = was_freeform,
            },
        });
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

    try conversation.submit("hello", .enqueue);
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
            const finished = tool_activity.ToolFinished.init(
                worker.allocator(),
                "call-1",
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
                !std.mem.eql(u8, first_prompt.text.bytes, "first"))
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
                !std.mem.eql(u8, steer_prompt.text.bytes, "steer"))
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
                !std.mem.eql(u8, queued_prompt.text.bytes, "later"))
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

    try conversation.submit("first", .enqueue);
    try conversation.submit("steer", .immediate);
    try conversation.submit("later", .enqueue);
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
            worker.userInputRequested(UserInputRequest.init(
                worker.allocator(),
                "request-1",
                "Choose",
                &.{ "one", "two" },
                false,
            ) catch return) catch return;

            var response = worker.waitCommand();
            defer response.deinit();
            switch (response) {
                .user_input_response => |value| {
                    if (!std.mem.eql(
                        u8,
                        value.request_id.bytes,
                        "request-1",
                    ) or
                        !std.mem.eql(u8, value.answer.bytes, "two") or
                        value.was_freeform)
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
        conversation.respondToUserInput("request-1", "two", false),
    );
    try conversation.submit("ask", .immediate);

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

    try conversation.respondToUserInput("request-1", "two", false);
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
            .text = try OwnedText.init(std.testing.allocator, "later"),
            .delivery = .enqueue,
        },
    });
    try core.commands.append(std.testing.allocator, .{
        .user_input_response = .{
            .request_id = try OwnedText.init(
                std.testing.allocator,
                "request-1",
            ),
            .answer = try OwnedText.init(std.testing.allocator, "two"),
            .was_freeform = false,
        },
    });

    var worker: Worker = .{ .core = &core };
    var response = worker.waitUserInputResponse();
    defer response.deinit();
    try std.testing.expect(response == .user_input_response);

    var queued = worker.tryTakeCommand().?;
    defer queued.deinit();
    try std.testing.expect(queued == .prompt);
    try std.testing.expectEqualStrings("later", queued.prompt.text.bytes);
}
