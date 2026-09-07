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
    assistant_delta: OwnedText,
    assistant_complete: OwnedText,
    idle,
    closed: Closed,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .assistant_delta, .assistant_complete => |*text| text.deinit(),
            .closed => |*closed| closed.deinit(),
            .ready, .idle => {},
        }
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    prompt: OwnedText,
    stop,

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .prompt => |*prompt| prompt.deinit(),
            .stop => {},
        }
        self.* = undefined;
    }
};

const State = enum {
    starting,
    idle,
    streaming,
    stopping,
    closed,
};

const Runner = *const fn (worker: *Worker) void;

const Core = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    runner: Runner,
    mutex: std.Io.Mutex = .init,
    command_ready: std.Io.Condition = .init,
    state: State = .starting,
    command: ?Command = null,
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

        while (self.core.command == null and !self.core.stop_requested) {
            self.core.command_ready.wait(
                self.core.io,
                &self.core.mutex,
            ) catch return .stop;
        }
        if (self.core.stop_requested) return .stop;

        const command = self.core.command.?;
        self.core.command = null;
        return command;
    }

    pub fn stopRequested(self: *Worker) bool {
        self.core.mutex.lock(self.core.io) catch return true;
        defer self.core.mutex.unlock(self.core.io);
        return self.core.stop_requested;
    }

    pub fn assistantDelta(self: *Worker, text: []const u8) !void {
        try self.publish(.{
            .assistant_delta = try OwnedText.init(self.core.allocator, text),
        });
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

    pub fn submit(self: *Conversation, prompt: []const u8) !void {
        if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
            return error.EmptyPrompt;
        }

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);

        switch (self.core.state) {
            .idle => {},
            .starting, .streaming => return error.Busy,
            .stopping => return error.Stopping,
            .closed => return error.Closed,
        }
        std.debug.assert(self.core.command == null);
        self.core.command = .{
            .prompt = try OwnedText.init(self.core.allocator, prompt),
        };
        self.core.state = .streaming;
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

        if (self.core.command) |*command| command.deinit();
        for (self.core.events.items) |*event| event.deinit();
        self.core.events.deinit(self.core.allocator);
        const allocator = self.core.allocator;
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
        .runner = runner,
    };
    core.worker = try io.concurrent(runWorker, .{core});
    return .{ .core = core };
}

fn runWorker(core: *Core) void {
    var worker: Worker = .{ .core = core };
    core.runner(&worker);
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
                .prompt => {
                    worker.assistantDelta("hel") catch return;
                    worker.assistantComplete("hello") catch return;
                    worker.idle() catch return;
                },
                .stop => {
                    worker.closeRequested();
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

    try conversation.submit("hello");
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
