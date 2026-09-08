const std = @import("std");

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
    assistant_started,
    reasoning_delta: OwnedText,
    reasoning_complete: OwnedText,
    assistant_delta: OwnedText,
    assistant_complete: OwnedText,
    idle,
    closed: Closed,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .reasoning_delta,
            .reasoning_complete,
            .assistant_delta,
            .assistant_complete,
            => |*text| text.deinit(),
            .command_catalog => |*catalog| catalog.deinit(),
            .model_catalog => |*catalog| catalog.deinit(),
            .model_catalog_failed => |*text| text.deinit(),
            .model_switch => |*result| result.deinit(),
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
    switch_model: OwnedText,
    stop,

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .prompt => |*prompt| prompt.text.deinit(),
            .switch_model => |*text| text.deinit(),
            .refresh_commands, .refresh_models, .stop => {},
        }
        self.* = undefined;
    }
};

const State = enum {
    starting,
    idle,
    streaming,
    controlling,
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
                .refresh_commands, .refresh_models, .switch_model => {},
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
        try self.publish(.assistant_started);
    }

    pub fn commandCatalog(self: *Worker, catalog: CommandCatalog) !void {
        try self.publish(.{ .command_catalog = catalog });
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

    pub fn assistantComplete(self: *Worker, text: []const u8) !void {
        try self.publish(.{
            .assistant_complete = try OwnedText.init(self.core.allocator, text),
        });
    }

    pub fn idle(self: *Worker) !void {
        try self.core.mutex.lock(self.core.io);
        if (!self.core.stop_requested) self.core.state = .idle;
        self.core.mutex.unlock(self.core.io);
        try self.publish(.idle);
    }

    fn completeControl(self: *Worker, event: Event) !void {
        try self.core.mutex.lock(self.core.io);
        if (!self.core.stop_requested) self.core.state = .idle;
        self.core.mutex.unlock(self.core.io);
        try self.publish(event);
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
            .starting, .controlling => return error.Busy,
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

    pub fn switchModel(self: *Conversation, model_id: []const u8) !void {
        if (std.mem.trim(u8, model_id, " \t\r\n").len == 0) {
            return error.EmptyModel;
        }
        try self.enqueueControl(.{
            .switch_model = try OwnedText.init(self.core.allocator, model_id),
        });
    }

    fn enqueueControl(self: *Conversation, command: Command) !void {
        var owned_command = command;
        errdefer owned_command.deinit();

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);

        switch (self.core.state) {
            .idle => {},
            .starting, .streaming, .controlling => return error.Busy,
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
                .refresh_commands, .refresh_models, .switch_model => {
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
