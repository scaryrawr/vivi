const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const TextInput = vaxis.widgets.TextInput;

const accent = vaxis.Color{ .rgb = .{ 110, 231, 183 } };
const user_color = vaxis.Color{ .rgb = .{ 125, 211, 252 } };
const assistant_color = vaxis.Color{ .rgb = .{ 196, 181, 253 } };
const composer_background = vaxis.Color{ .index = 236 };

const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    conversation_wake,
};

const Role = enum {
    user,
    assistant,
    status,
};

const Entry = struct {
    role: Role,
    text: std.ArrayList(u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        role: Role,
        text: []const u8,
    ) !Entry {
        var entry: Entry = .{ .role = role };
        errdefer entry.text.deinit(allocator);
        try entry.text.appendSlice(allocator, text);
        return entry;
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

const Transcript = struct {
    entries: std.ArrayList(Entry) = .empty,
    active_assistant: ?usize = null,

    fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn append(
        self: *Transcript,
        allocator: std.mem.Allocator,
        role: Role,
        text: []const u8,
    ) !void {
        const entry = try Entry.init(allocator, role, text);
        errdefer {
            var mutable = entry;
            mutable.deinit(allocator);
        }
        try self.entries.append(allocator, entry);
    }

    fn appendDelta(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        const index = self.active_assistant orelse blk: {
            try self.append(allocator, .assistant, "");
            const new_index = self.entries.items.len - 1;
            self.active_assistant = new_index;
            break :blk new_index;
        };
        try self.entries.items[index].text.appendSlice(allocator, text);
    }

    fn completeAssistant(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        const index = self.active_assistant orelse blk: {
            try self.append(allocator, .assistant, "");
            const new_index = self.entries.items.len - 1;
            self.active_assistant = new_index;
            break :blk new_index;
        };
        self.entries.items[index].text.clearRetainingCapacity();
        try self.entries.items[index].text.appendSlice(allocator, text);
    }

    fn finishTurn(self: *Transcript) void {
        self.active_assistant = null;
    }
};

const UiPhase = enum {
    connecting,
    ready,
    responding,
    stopping,

    fn label(self: UiPhase) []const u8 {
        return switch (self) {
            .connecting => "Connecting...",
            .ready => "Ready",
            .responding => "Responding...",
            .stopping => "Stopping...",
        };
    }
};

const Region = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    fn child(self: Region, root: vaxis.Window) vaxis.Window {
        return root.child(.{
            .x_off = @intCast(self.x),
            .y_off = @intCast(self.y),
            .width = self.width,
            .height = self.height,
        });
    }
};

const FrameLayout = struct {
    transcript: Region,
    context: ?Region,
    composer: Region,
    footer: ?Region,

    fn compute(width: u16, height: u16) FrameLayout {
        if (width == 0 or height == 0) return .{
            .transcript = .{},
            .context = null,
            .composer = .{},
            .footer = null,
        };

        const composer_height: u16 = if (height >= 8 and width >= 24) 3 else 1;
        const footer_height: u16 = if (height >= 3 and width >= 12) 1 else 0;
        const context_height: u16 = if (height >= 5 and width >= 24) 1 else 0;
        const chrome_height = composer_height + footer_height + context_height;
        const transcript_height = height -| chrome_height;
        const margin: u16 = if (width >= 40) 2 else 0;
        const transcript_width = width -| margin * 2;

        var y = transcript_height;
        const context: ?Region = if (context_height > 0) blk: {
            defer y += context_height;
            break :blk .{
                .y = y,
                .width = width,
                .height = context_height,
            };
        } else null;
        const composer = Region{
            .y = y,
            .width = width,
            .height = composer_height,
        };
        y += composer_height;
        const footer: ?Region = if (footer_height > 0) .{
            .y = y,
            .width = width,
            .height = footer_height,
        } else null;

        return .{
            .transcript = .{
                .x = margin,
                .width = transcript_width,
                .height = transcript_height,
            },
            .context = context,
            .composer = composer,
            .footer = footer,
        };
    }
};

const LineKind = enum {
    blank,
    role,
    body,
    status,
};

const RenderLine = struct {
    kind: LineKind,
    entry_index: usize,
    start: usize = 0,
    end: usize = 0,
};

const Projection = struct {
    lines: std.ArrayList(RenderLine) = .empty,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
        self.* = undefined;
    }

    fn build(
        allocator: std.mem.Allocator,
        transcript: *const Transcript,
        window: vaxis.Window,
    ) !Projection {
        var projection: Projection = .{};
        errdefer projection.deinit(allocator);

        for (transcript.entries.items, 0..) |entry, entry_index| {
            if (projection.lines.items.len > 0) {
                try projection.lines.append(allocator, .{
                    .kind = .blank,
                    .entry_index = entry_index,
                });
            }
            switch (entry.role) {
                .user, .assistant => {
                    try projection.lines.append(allocator, .{
                        .kind = .role,
                        .entry_index = entry_index,
                    });
                    try projection.appendWrapped(
                        allocator,
                        entry_index,
                        entry.text.items,
                        window,
                        .body,
                        2,
                    );
                },
                .status => try projection.appendWrapped(
                    allocator,
                    entry_index,
                    entry.text.items,
                    window,
                    .status,
                    2,
                ),
            }
        }
        return projection;
    }

    fn appendWrapped(
        self: *Projection,
        allocator: std.mem.Allocator,
        entry_index: usize,
        text: []const u8,
        window: vaxis.Window,
        kind: LineKind,
        indent: u16,
    ) !void {
        const available_width = @max(window.width -| indent, 1);
        var iterator = vaxis.unicode.graphemeIterator(text);
        var line_start: usize = 0;
        var line_width: u16 = 0;

        while (iterator.next()) |grapheme| {
            const bytes = grapheme.bytes(text);
            if (std.mem.eql(u8, bytes, "\n")) {
                try self.lines.append(allocator, .{
                    .kind = kind,
                    .entry_index = entry_index,
                    .start = line_start,
                    .end = grapheme.start,
                });
                line_start = grapheme.start + grapheme.len;
                line_width = 0;
                continue;
            }

            const grapheme_width = window.gwidth(bytes);
            if (line_width > 0 and line_width + grapheme_width > available_width) {
                try self.lines.append(allocator, .{
                    .kind = kind,
                    .entry_index = entry_index,
                    .start = line_start,
                    .end = grapheme.start,
                });
                line_start = grapheme.start;
                line_width = 0;
            }
            line_width +|= grapheme_width;
        }

        try self.lines.append(allocator, .{
            .kind = kind,
            .entry_index = entry_index,
            .start = line_start,
            .end = text.len,
        });
    }
};

const ConversationOutcome = enum {
    keep_running,
    close,
};

const KeyOutcome = enum {
    keep_running,
    force_exit,
};

const ChatUi = struct {
    allocator: std.mem.Allocator,
    input: TextInput,
    transcript: Transcript = .{},
    cwd: []u8,
    phase: UiPhase = .connecting,
    rows_from_tail: usize = 0,
    last_total_rows: usize = 0,
    last_viewport_rows: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
    ) !ChatUi {
        const cwd = if (environ_map.get("PWD")) |path|
            try allocator.dupe(u8, path)
        else blk: {
            var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_len = std.Io.Dir.cwd().realPath(io, &cwd_buffer) catch 0;
            break :blk if (cwd_len > 0)
                try allocator.dupe(u8, cwd_buffer[0..cwd_len])
            else
                try allocator.dupe(u8, ".");
        };
        errdefer allocator.free(cwd);

        return .{
            .allocator = allocator,
            .input = TextInput.init(allocator),
            .cwd = cwd,
        };
    }

    fn deinit(self: *ChatUi) void {
        self.allocator.free(self.cwd);
        self.transcript.deinit(self.allocator);
        self.input.deinit();
        self.* = undefined;
    }

    fn handleKey(
        self: *ChatUi,
        key: vaxis.Key,
        conversation: *backend.Conversation,
    ) !KeyOutcome {
        if (key.matches('c', .{ .ctrl = true })) {
            if (self.phase == .stopping) return .force_exit;
            self.phase = .stopping;
            conversation.requestStop();
            try self.transcript.append(
                self.allocator,
                .status,
                "Stopping... press Ctrl-C again to force exit.",
            );
            self.followTail();
            return .keep_running;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            self.pageUp();
            return .keep_running;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            self.pageDown();
            return .keep_running;
        }
        if (self.phase != .ready) return .keep_running;

        if (key.matches(vaxis.Key.enter, .{})) {
            const prompt = try self.input.toOwnedContents(self.allocator);
            defer self.allocator.free(prompt);
            conversation.submit(prompt) catch |err| switch (err) {
                error.EmptyPrompt, error.Busy => return .keep_running,
                else => return err,
            };
            try self.transcript.append(self.allocator, .user, prompt);
            self.input.clearRetainingCapacity();
            self.phase = .responding;
            self.followTail();
            return .keep_running;
        }
        try self.input.update(.{ .key_press = key });
        return .keep_running;
    }

    fn applyConversationEvent(
        self: *ChatUi,
        event: *const backend.ConversationEvent,
    ) !ConversationOutcome {
        switch (event.*) {
            .ready => self.phase = .ready,
            .assistant_delta => |text| {
                try self.transcript.appendDelta(self.allocator, text.bytes);
            },
            .assistant_complete => |text| {
                try self.transcript.completeAssistant(
                    self.allocator,
                    text.bytes,
                );
            },
            .idle => {
                self.transcript.finishTurn();
                self.phase = .ready;
            },
            .closed => |closed| {
                switch (closed) {
                    .requested => {},
                    .failed => |failure| try self.transcript.append(
                        self.allocator,
                        .status,
                        failure.message.bytes,
                    ),
                }
                return .close;
            },
        }
        return .keep_running;
    }

    fn draw(self: *ChatUi, root: vaxis.Window) !void {
        const layout = FrameLayout.compute(root.width, root.height);
        if (layout.transcript.height > 0) {
            const transcript_window = layout.transcript.child(root);
            if (self.transcript.entries.items.len == 0) {
                self.drawWelcome(transcript_window);
                self.last_total_rows = 0;
                self.last_viewport_rows = transcript_window.height;
            } else {
                var projection = try Projection.build(
                    self.allocator,
                    &self.transcript,
                    transcript_window,
                );
                defer projection.deinit(self.allocator);
                self.drawTranscript(transcript_window, &projection);
            }
        }
        if (layout.context) |region| self.drawContext(region.child(root));
        if (layout.composer.height > 0) {
            self.drawComposer(layout.composer.child(root));
        }
        if (layout.footer) |region| self.drawFooter(region.child(root));
    }

    fn drawWelcome(self: *ChatUi, window: vaxis.Window) void {
        _ = self;
        if (window.height == 0) return;
        var title = [_]vaxis.Segment{.{
            .text = "vivi",
            .style = .{ .fg = accent, .bold = true },
        }};
        _ = window.print(&title, .{ .row_offset = 1, .wrap = .none });
        if (window.height < 3) return;
        var subtitle = [_]vaxis.Segment{.{
            .text = "Vivi chat for this workspace",
            .style = .{ .bold = true },
        }};
        _ = window.print(&subtitle, .{ .row_offset = 2, .wrap = .none });
        if (window.height < 5) return;
        var hint = [_]vaxis.Segment{.{
            .text = "Type a message and press Enter.",
            .style = .{ .dim = true },
        }};
        _ = window.print(&hint, .{ .row_offset = 4, .wrap = .none });
    }

    fn drawTranscript(
        self: *ChatUi,
        window: vaxis.Window,
        projection: *const Projection,
    ) void {
        const total_rows = projection.lines.items.len;
        const viewport_rows: usize = window.height;
        if (self.rows_from_tail > 0 and total_rows > self.last_total_rows) {
            self.rows_from_tail += total_rows - self.last_total_rows;
        }
        const max_scroll = total_rows -| @min(total_rows, viewport_rows);
        self.rows_from_tail = @min(self.rows_from_tail, max_scroll);
        const visible_rows = @min(total_rows, viewport_rows);
        const first_row = total_rows - visible_rows - self.rows_from_tail;
        const last_row = @min(first_row + viewport_rows, total_rows);

        for (projection.lines.items[first_row..last_row], 0..) |line, row| {
            self.drawTranscriptLine(window, @intCast(row), line);
        }
        self.last_total_rows = total_rows;
        self.last_viewport_rows = viewport_rows;
    }

    fn drawTranscriptLine(
        self: *ChatUi,
        window: vaxis.Window,
        row: u16,
        line: RenderLine,
    ) void {
        const entry = self.transcript.entries.items[line.entry_index];
        switch (line.kind) {
            .blank => {},
            .role => {
                const role_text = switch (entry.role) {
                    .user => "You",
                    .assistant => "Vivi",
                    .status => unreachable,
                };
                const role_color = switch (entry.role) {
                    .user => user_color,
                    .assistant => assistant_color,
                    .status => unreachable,
                };
                var segments = [_]vaxis.Segment{.{
                    .text = role_text,
                    .style = .{ .fg = role_color, .bold = true },
                }};
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .wrap = .none,
                });
            },
            .body => {
                var segments = [_]vaxis.Segment{.{
                    .text = entry.text.items[line.start..line.end],
                }};
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .col_offset = if (window.width >= 4) 2 else 0,
                    .wrap = .none,
                });
            },
            .status => {
                var segments = [_]vaxis.Segment{
                    .{
                        .text = "• ",
                        .style = .{ .fg = accent, .dim = true },
                    },
                    .{
                        .text = entry.text.items[line.start..line.end],
                        .style = .{ .dim = true },
                    },
                };
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .wrap = .none,
                });
            },
        }
    }

    fn drawContext(self: *ChatUi, window: vaxis.Window) void {
        if (window.width == 0) return;
        const cwd = if (window.width < 40)
            std.fs.path.basename(self.cwd)
        else
            self.cwd;
        var segments = [_]vaxis.Segment{
            .{ .text = cwd, .style = .{ .dim = true } },
            .{ .text = "  ", .style = .{ .dim = true } },
            .{ .text = self.phase.label(), .style = .{ .bold = true } },
        };
        _ = window.print(&segments, .{ .wrap = .none });
    }

    fn drawComposer(self: *ChatUi, window: vaxis.Window) void {
        window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = composer_background },
        });
        const use_accent = window.width >= 4;
        if (use_accent) {
            const accent_window = window.child(.{ .width = 1 });
            accent_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{ .bg = accent },
            });
        }
        const content_x: u16 = if (use_accent) 3 else 0;
        const content_width = window.width -| content_x;
        if (content_width == 0) return;
        const content = window.child(.{
            .x_off = @intCast(content_x),
            .y_off = @intCast((window.height - 1) / 2),
            .width = content_width,
            .height = 1,
        });
        const text_style = vaxis.Style{ .bg = composer_background };
        if (self.phase == .ready) {
            self.input.drawWithStyle(content, text_style);
        } else {
            content.hideCursor();
            var segments = [_]vaxis.Segment{.{
                .text = self.phase.label(),
                .style = .{ .bg = composer_background, .dim = true },
            }};
            _ = content.print(&segments, .{ .wrap = .none });
        }
    }

    fn drawFooter(self: *ChatUi, window: vaxis.Window) void {
        if (window.width == 0) return;
        const hints = if (window.width >= 48)
            switch (self.phase) {
                .ready => "Enter send  ·  PgUp/PgDn scroll  ·  Ctrl-C quit  ·  Vivi",
                .connecting, .responding => "PgUp/PgDn scroll  ·  Ctrl-C stop  ·  Vivi",
                .stopping => "Ctrl-C again force exit  ·  Vivi",
            }
        else if (window.width >= 24)
            switch (self.phase) {
                .ready => "Enter send  ·  Ctrl-C quit",
                .connecting, .responding => "Ctrl-C stop",
                .stopping => "Ctrl-C again force exit",
            }
        else switch (self.phase) {
            .ready => "Ctrl-C quit",
            .connecting, .responding => "Ctrl-C stop",
            .stopping => "Ctrl-C again",
        };
        var segments = [_]vaxis.Segment{.{
            .text = hints,
            .style = .{ .dim = true },
        }};
        _ = window.print(&segments, .{ .wrap = .none });
    }

    fn pageUp(self: *ChatUi) void {
        const page_rows = @max(self.last_viewport_rows -| 1, 1);
        const max_scroll = self.last_total_rows -|
            @min(self.last_total_rows, self.last_viewport_rows);
        self.rows_from_tail = @min(
            self.rows_from_tail + page_rows,
            max_scroll,
        );
    }

    fn pageDown(self: *ChatUi) void {
        const page_rows = @max(self.last_viewport_rows -| 1, 1);
        self.rows_from_tail -|= page_rows;
    }

    fn followTail(self: *ChatUi) void {
        self.rows_from_tail = 0;
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tty_buffer: [1024]u8,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    loop: vaxis.Loop(AppEvent),
    conversation: backend.Conversation,
    ui: ChatUi,
    closed: bool = false,

    fn init(self: *App, init_args: std.process.Init) !void {
        self.allocator = init_args.gpa;
        self.io = init_args.io;

        self.tty = try vaxis.Tty.init(init_args.io, &self.tty_buffer);
        errdefer self.tty.deinit();

        self.vx = try vaxis.init(
            init_args.io,
            init_args.gpa,
            init_args.environ_map,
            .{ .kitty_keyboard_flags = .{ .report_events = true } },
        );
        errdefer self.vx.deinit(init_args.gpa, self.tty.writer());

        self.loop = .init(init_args.io, &self.tty, &self.vx);
        self.ui = try ChatUi.init(
            init_args.gpa,
            init_args.io,
            init_args.environ_map,
        );
        errdefer self.ui.deinit();
        self.closed = false;

        self.conversation = try backend.openConversation(
            init_args.gpa,
            init_args.io,
            .{ .context = self, .notify = wake },
        );
    }

    fn deinit(self: *App) void {
        self.conversation.deinit();
        self.ui.deinit();
        self.loop.stop();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.* = undefined;
    }

    fn wake(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self.loop.tryPostEvent(.conversation_wake) catch false;
    }

    fn run(self: *App) !void {
        try self.loop.start();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), .fromSeconds(1));
        const use_signal_resize = !self.vx.state.in_band_resize;
        if (use_signal_resize) try self.loop.installResizeHandler();
        defer if (use_signal_resize) self.loop.uninstallResizeHandler();
        try self.render();

        while (!self.closed) {
            const event = try self.loop.nextEvent();
            switch (event) {
                .key_press => |key| switch (try self.ui.handleKey(key, &self.conversation)) {
                    .keep_running => {},
                    .force_exit => self.hardExit(),
                },
                .winsize => |winsize| {
                    try self.vx.resize(
                        self.allocator,
                        self.tty.writer(),
                        winsize,
                    );
                },
                .conversation_wake => {},
            }
            try self.drainConversation();
            if (!self.closed) try self.render();
        }
    }

    fn drainConversation(self: *App) !void {
        while (try self.conversation.tryTakeEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (try self.ui.applyConversationEvent(&event) == .close) {
                self.closed = true;
            }
        }
    }

    fn render(self: *App) !void {
        const root = self.vx.window();
        root.clear();
        try self.ui.draw(root);
        try self.vx.render(self.tty.writer());
        try self.tty.writer().flush();
    }

    fn hardExit(self: *App) noreturn {
        self.loop.stop();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        std.process.exit(130);
    }
};

pub fn run(init: std.process.Init) !void {
    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);
    try app.init(init);
    defer app.deinit();
    try app.run();
}

test "transcript replaces streamed draft with completed response" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendDelta(std.testing.allocator, "hel");
    try transcript.appendDelta(std.testing.allocator, "lo?");
    try transcript.completeAssistant(std.testing.allocator, "hello");

    try std.testing.expectEqual(1, transcript.entries.items.len);
    try std.testing.expectEqualStrings(
        "hello",
        transcript.entries.items[0].text.items,
    );
}

test "frame layout keeps chrome in bounds" {
    const sizes = [_]struct { width: u16, height: u16 }{
        .{ .width = 0, .height = 0 },
        .{ .width = 8, .height = 1 },
        .{ .width = 12, .height = 3 },
        .{ .width = 24, .height = 5 },
        .{ .width = 40, .height = 8 },
        .{ .width = 120, .height = 30 },
    };
    for (sizes) |size| {
        const layout = FrameLayout.compute(size.width, size.height);
        try std.testing.expect(
            layout.composer.y + layout.composer.height <= size.height,
        );
        if (layout.context) |context| {
            try std.testing.expect(context.y + context.height <= size.height);
            try std.testing.expect(context.y + context.height <= layout.composer.y);
        }
        if (layout.footer) |footer| {
            try std.testing.expect(footer.y + footer.height <= size.height);
            try std.testing.expect(
                layout.composer.y + layout.composer.height <= footer.y,
            );
        }
    }
}
