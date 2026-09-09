const std = @import("std");
const backend = @import("vivi_backend");
const vaxis = @import("vaxis");

const TextInput = vaxis.widgets.TextInput;

const accent = vaxis.Color{ .rgb = .{ 110, 231, 183 } };
const user_color = vaxis.Color{ .rgb = .{ 125, 211, 252 } };
const assistant_color = vaxis.Color{ .rgb = .{ 196, 181, 253 } };
const reasoning_color = vaxis.Color{ .rgb = .{ 148, 163, 184 } };
const composer_background = vaxis.Color{ .index = 236 };
const menu_background = vaxis.Color{ .index = 234 };
const menu_selected_background = vaxis.Color{ .index = 238 };

const AppEvent = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    conversation_wake,
};

const Role = enum {
    user,
    queued,
    reasoning,
    assistant,
    question,
    status,
};

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

fn slashCommandQuery(input: []const u8) ?[]const u8 {
    if (input.len == 0 or input[0] != '/') return null;
    const command = input[1..];
    const separator = std.mem.indexOfAny(u8, command, " \t\r\n");
    return if (separator) |index| command[0..index] else command;
}

fn commandArgumentSuffix(input: []const u8) []const u8 {
    const separator = std.mem.indexOfAny(u8, input, " \t\r\n");
    return if (separator) |index| input[index..] else "";
}

fn buildCommandInput(
    allocator: std.mem.Allocator,
    command_name: []const u8,
    composer_input: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ command_name, commandArgumentSuffix(composer_input) },
    );
}

fn visibleSelectionRange(
    item_count: usize,
    row_count: usize,
    selected: usize,
) struct { first: usize, last: usize } {
    if (item_count == 0 or row_count == 0) {
        return .{ .first = 0, .last = 0 };
    }
    const visible_count = @min(item_count, row_count);
    const bounded_selected = @min(selected, item_count - 1);
    const first = if (bounded_selected < visible_count)
        0
    else
        bounded_selected - visible_count + 1;
    return .{
        .first = first,
        .last = @min(first + visible_count, item_count),
    };
}

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
    active_reasoning: ?usize = null,
    active_assistant: ?usize = null,
    last_reasoning: ?usize = null,

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

    fn appendBeforeQueued(
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
        const index = for (self.entries.items, 0..) |existing, queued_index| {
            if (existing.role == .queued) break queued_index;
        } else self.entries.items.len;
        try self.entries.insert(allocator, index, entry);
    }

    fn appendDelta(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        if (self.active_assistant == null and isBlank(text)) return;
        self.finishReasoning();
        const index = self.active_assistant orelse
            try self.startEntry(allocator, .assistant);
        try self.entries.items[index].text.appendSlice(allocator, text);
    }

    fn appendReasoningDelta(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        if (self.active_reasoning == null and isBlank(text)) return;
        self.finishAssistant();
        const index = self.active_reasoning orelse
            try self.startEntry(allocator, .reasoning);
        try self.entries.items[index].text.appendSlice(allocator, text);
    }

    fn startEntry(
        self: *Transcript,
        allocator: std.mem.Allocator,
        role: Role,
    ) !usize {
        const entry = try Entry.init(allocator, role, "");
        errdefer {
            var mutable = entry;
            mutable.deinit(allocator);
        }
        const index = for (self.entries.items, 0..) |existing, queued_index| {
            if (existing.role == .queued) break queued_index;
        } else self.entries.items.len;
        try self.entries.insert(allocator, index, entry);
        switch (role) {
            .reasoning => {
                self.active_reasoning = index;
                self.last_reasoning = index;
            },
            .assistant => self.active_assistant = index,
            .user, .queued, .question, .status => unreachable,
        }
        return index;
    }

    fn completeAssistant(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        if (isBlank(text)) return;
        self.finishReasoning();
        const index = self.active_assistant orelse
            try self.startEntry(allocator, .assistant);
        self.entries.items[index].text.clearRetainingCapacity();
        try self.entries.items[index].text.appendSlice(allocator, text);
    }

    fn completeReasoning(
        self: *Transcript,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) !void {
        if (isBlank(text)) return;
        const index = self.active_reasoning orelse self.last_reasoning orelse
            create: {
                self.finishAssistant();
                break :create try self.startEntry(allocator, .reasoning);
            };
        self.entries.items[index].text.clearRetainingCapacity();
        try self.entries.items[index].text.appendSlice(allocator, text);
    }

    fn finishAssistant(self: *Transcript) void {
        self.active_assistant = null;
    }

    fn finishReasoning(self: *Transcript) void {
        self.active_reasoning = null;
    }

    fn finishTurn(self: *Transcript) void {
        self.finishReasoning();
        self.finishAssistant();
    }

    fn endTurn(self: *Transcript) void {
        self.finishTurn();
        self.last_reasoning = null;
    }

    fn beginQueuedTurn(self: *Transcript) void {
        self.finishTurn();
        self.promoteNextQueuedPrompt();
    }

    fn promoteNextQueuedPrompt(self: *Transcript) void {
        const selected_index = for (self.entries.items, 0..) |entry, index| {
            if (entry.role == .queued) break index;
        } else return;

        var selected = self.entries.orderedRemove(selected_index);
        selected.role = .user;
        self.entries.appendAssumeCapacity(selected);

        var index: usize = 0;
        var remaining = self.entries.items.len;
        while (index < remaining) {
            if (self.entries.items[index].role != .queued) {
                index += 1;
                continue;
            }
            const queued = self.entries.orderedRemove(index);
            self.entries.appendAssumeCapacity(queued);
            remaining -= 1;
        }
    }
};

const UiPhase = enum {
    connecting,
    ready,
    loading_commands,
    responding,
    awaiting_input,
    running_command,
    switching,
    stopping,

    fn label(self: UiPhase) []const u8 {
        return switch (self) {
            .connecting => "Connecting...",
            .ready => "Ready",
            .loading_commands => "Refreshing commands...",
            .responding => "Responding...",
            .awaiting_input => "Answer required",
            .running_command => "Running command...",
            .switching => "Switching model...",
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
    menu: ?Region,
    composer: Region,
    footer: ?Region,

    fn compute(width: u16, height: u16, desired_menu_rows: u16) FrameLayout {
        if (width == 0 or height == 0) return .{
            .transcript = .{},
            .context = null,
            .menu = null,
            .composer = .{},
            .footer = null,
        };

        const composer_height: u16 = if (height >= 8 and width >= 24) 3 else 1;
        const footer_height: u16 = if (height >= 3 and width >= 12) 1 else 0;
        const context_height: u16 = if (height >= 5 and width >= 24) 1 else 0;
        const fixed_chrome_height =
            composer_height + footer_height + context_height;
        const menu_height = @min(
            desired_menu_rows,
            height -| fixed_chrome_height -| 1,
        );
        const chrome_height = fixed_chrome_height + menu_height;
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
        const menu: ?Region = if (menu_height > 0) blk: {
            defer y += menu_height;
            break :blk .{
                .y = y,
                .width = width,
                .height = menu_height,
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
            .menu = menu,
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
                .user, .queued, .reasoning, .assistant, .question => {
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

const MenuDetail = union(enum) {
    text: []const u8,
    model: struct {
        context_tokens: u64,
        output_tokens: u64,
        supports_vision: bool,
    },
};

const MenuEntry = struct {
    key: []const u8,
    primary: []const u8,
    detail: MenuDetail,
    current: bool = false,
    enabled: bool = true,
    source_index: usize,
};

const MenuDirection = enum {
    previous,
    next,
};

const MenuState = struct {
    entries: std.ArrayList(MenuEntry) = .empty,
    matches: std.ArrayList(usize) = .empty,
    selected_match: usize = 0,
    first_visible_match: usize = 0,

    fn deinit(self: *MenuState, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.matches.deinit(allocator);
        self.* = undefined;
    }

    fn rebuild(
        self: *MenuState,
        allocator: std.mem.Allocator,
        entries: []const MenuEntry,
        query: []const u8,
    ) !void {
        const previous_key = if (self.selected()) |entry| entry.key else null;
        self.entries.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        try self.entries.appendSlice(allocator, entries);

        var ranks: std.ArrayList(u2) = .empty;
        defer ranks.deinit(allocator);
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.enabled) continue;
            const rank = matchRank(entry, query) orelse continue;
            try self.matches.append(allocator, index);
            try ranks.append(allocator, rank);
        }
        stableRank(self.matches.items, ranks.items);

        self.selected_match = 0;
        if (previous_key) |key| {
            for (self.matches.items, 0..) |entry_index, match_index| {
                if (std.mem.eql(u8, self.entries.items[entry_index].key, key)) {
                    self.selected_match = match_index;
                    break;
                }
            }
        }
        self.first_visible_match = @min(
            self.first_visible_match,
            self.selected_match,
        );
    }

    fn move(self: *MenuState, direction: MenuDirection) void {
        if (self.matches.items.len == 0) return;
        self.selected_match = switch (direction) {
            .previous => if (self.selected_match == 0)
                self.matches.items.len - 1
            else
                self.selected_match - 1,
            .next => (self.selected_match + 1) % self.matches.items.len,
        };
    }

    fn selected(self: *const MenuState) ?MenuEntry {
        if (self.matches.items.len == 0) return null;
        return self.entries.items[self.matches.items[self.selected_match]];
    }

    fn visibleRange(
        self: *MenuState,
        row_count: usize,
    ) struct { first: usize, last: usize } {
        if (row_count == 0 or self.matches.items.len == 0) {
            return .{ .first = 0, .last = 0 };
        }
        if (self.selected_match < self.first_visible_match) {
            self.first_visible_match = self.selected_match;
        } else if (self.selected_match >= self.first_visible_match + row_count) {
            self.first_visible_match = self.selected_match - row_count + 1;
        }
        const last = @min(
            self.first_visible_match + row_count,
            self.matches.items.len,
        );
        return .{ .first = self.first_visible_match, .last = last };
    }
};

fn matchRank(entry: MenuEntry, query: []const u8) ?u2 {
    if (query.len == 0) return 0;
    if (asciiStartsWithIgnoreCase(entry.key, query)) return 0;
    if (wordStartsWithIgnoreCase(entry.primary, query)) return 1;
    if (asciiContainsIgnoreCase(entry.key, query) or
        asciiContainsIgnoreCase(entry.primary, query) or
        switch (entry.detail) {
            .text => |text| asciiContainsIgnoreCase(text, query),
            .model => false,
        })
    {
        return 2;
    }
    return null;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and
        std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn asciiContainsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(
            value[index .. index + needle.len],
            needle,
        )) return true;
    }
    return false;
}

fn wordStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    var at_word_start = true;
    for (value, 0..) |byte, index| {
        if (at_word_start and index + prefix.len <= value.len and
            std.ascii.eqlIgnoreCase(value[index .. index + prefix.len], prefix))
        {
            return true;
        }
        at_word_start = byte == ' ' or byte == '-' or byte == '_';
    }
    return false;
}

fn stableRank(indices: []usize, ranks: []u2) void {
    var index: usize = 1;
    while (index < indices.len) : (index += 1) {
        const saved_index = indices[index];
        const saved_rank = ranks[index];
        var insertion = index;
        while (insertion > 0 and ranks[insertion - 1] > saved_rank) {
            indices[insertion] = indices[insertion - 1];
            ranks[insertion] = ranks[insertion - 1];
            insertion -= 1;
        }
        indices[insertion] = saved_index;
        ranks[insertion] = saved_rank;
    }
}

const MenuMode = enum {
    closed,
    commands,
    loading_models,
    models,
};

const ChatUi = struct {
    allocator: std.mem.Allocator,
    input: TextInput,
    transcript: Transcript = .{},
    cwd: []u8,
    phase: UiPhase = .connecting,
    commands: ?backend.CommandCatalog = null,
    models: ?backend.ModelCatalog = null,
    pending_user_input: ?backend.UserInputRequest = null,
    saved_input: ?TextInput = null,
    selected_user_input_choice: usize = 0,
    invalid_user_input: bool = false,
    menu_mode: MenuMode = .closed,
    menu: MenuState = .{},
    input_revision: u64 = 0,
    dismissed_revision: ?u64 = null,
    menu_detail_storage: [8][96]u8 = undefined,
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
        self.menu.deinit(self.allocator);
        if (self.saved_input) |*input| input.deinit();
        if (self.pending_user_input) |*request| request.deinit();
        if (self.models) |*catalog| catalog.deinit();
        if (self.commands) |*catalog| catalog.deinit();
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
        if (self.menu_mode != .closed) {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.menu_mode = .closed;
                self.dismissed_revision = self.input_revision;
                return .keep_running;
            }
            if (self.menu_mode != .loading_models and
                key.matches(vaxis.Key.up, .{}))
            {
                self.menu.move(.previous);
                return .keep_running;
            }
            if (self.menu_mode != .loading_models and
                key.matches(vaxis.Key.down, .{}))
            {
                self.menu.move(.next);
                return .keep_running;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.phase != .ready or
                    self.menu_mode == .loading_models)
                {
                    return .keep_running;
                }
                try self.activateMenu(conversation);
                return .keep_running;
            }
        }
        if (self.phase == .awaiting_input) {
            if (key.matches(vaxis.Key.up, .{})) {
                self.moveUserInputSelection(.previous);
            } else if (key.matches(vaxis.Key.down, .{})) {
                self.moveUserInputSelection(.next);
            } else if (key.matches(vaxis.Key.enter, .{})) {
                try self.submitSelectedUserInput(conversation);
            } else {
                try self.input.update(.{ .key_press = key });
                self.invalid_user_input = false;
                const contents = try self.input.toOwnedContents(self.allocator);
                defer self.allocator.free(contents);
                if (self.hasFreeformChoice() and !isBlank(contents)) {
                    self.selected_user_input_choice =
                        self.pending_user_input.?.choices.len;
                }
            }
            return .keep_running;
        }
        if (self.phase != .ready and self.phase != .responding) {
            return .keep_running;
        }

        if (key.matches(vaxis.Key.enter, .{})) {
            const prompt = try self.input.toOwnedContents(self.allocator);
            defer self.allocator.free(prompt);
            conversation.submit(prompt, .immediate) catch |err| switch (err) {
                error.EmptyPrompt, error.Busy => return .keep_running,
                else => return err,
            };
            try self.transcript.append(self.allocator, .user, prompt);
            self.input.clearRetainingCapacity();
            self.phase = .responding;
            self.followTail();
            return .keep_running;
        }

        if (key.matches(vaxis.Key.enter, .{ .ctrl = true })) {
            const prompt = try self.input.toOwnedContents(self.allocator);
            defer self.allocator.free(prompt);
            conversation.submit(prompt, .enqueue) catch |err| switch (err) {
                error.EmptyPrompt, error.Busy => return .keep_running,
                else => return err,
            };
            try self.transcript.append(self.allocator, .queued, prompt);
            self.input.clearRetainingCapacity();
            self.phase = .responding;
            self.followTail();
            return .keep_running;
        }
        const previous_menu_mode = self.menu_mode;
        try self.input.update(.{ .key_press = key });
        self.input_revision +%= 1;
        if (self.phase == .ready) {
            try self.syncSlashMenu();
        } else {
            self.menu_mode = .closed;
        }
        if (previous_menu_mode == .closed and self.menu_mode == .commands) {
            conversation.refreshCommands() catch |err| switch (err) {
                error.Busy => return .keep_running,
                else => return err,
            };
            self.phase = .loading_commands;
        }
        return .keep_running;
    }

    fn submitUserInput(
        self: *ChatUi,
        conversation: *backend.Conversation,
    ) !void {
        const request = self.pending_user_input orelse return;
        const answer = try self.input.toOwnedContents(self.allocator);
        defer self.allocator.free(answer);
        const trimmed_answer = std.mem.trim(u8, answer, " \t\r\n");
        if (trimmed_answer.len == 0) return;

        var submitted_answer: []const u8 = trimmed_answer;
        var was_freeform = true;
        for (request.choices) |choice| {
            if (std.mem.eql(u8, trimmed_answer, choice)) {
                was_freeform = false;
                break;
            }
        }
        if (was_freeform and request.choices.len > 0) {
            const selected = std.fmt.parseUnsigned(
                usize,
                trimmed_answer,
                10,
            ) catch 0;
            if (selected > 0 and selected <= request.choices.len) {
                submitted_answer = request.choices[selected - 1];
                was_freeform = false;
            }
        }
        if (was_freeform and !request.allow_freeform and
            request.choices.len > 0)
        {
            self.invalid_user_input = true;
            return;
        }
        try self.completeUserInput(
            conversation,
            request,
            submitted_answer,
            was_freeform,
        );
    }

    fn submitSelectedUserInput(
        self: *ChatUi,
        conversation: *backend.Conversation,
    ) !void {
        const contents = try self.input.toOwnedContents(self.allocator);
        defer self.allocator.free(contents);
        if (!isBlank(contents)) return self.submitUserInput(conversation);

        const request = self.pending_user_input orelse return;
        if (self.selected_user_input_choice >= request.choices.len) return;
        try self.completeUserInput(
            conversation,
            request,
            request.choices[self.selected_user_input_choice],
            false,
        );
    }

    fn completeUserInput(
        self: *ChatUi,
        conversation: *backend.Conversation,
        request: backend.UserInputRequest,
        answer: []const u8,
        was_freeform: bool,
    ) !void {
        conversation.respondToUserInput(
            request.request_id,
            answer,
            was_freeform,
        ) catch |err| switch (err) {
            error.EmptyAnswer, error.NotAwaitingInput => return,
            else => return err,
        };
        self.transcript.endTurn();
        try self.appendUserInputQuestion(request);
        try self.transcript.appendBeforeQueued(
            self.allocator,
            .user,
            answer,
        );
        self.restoreInputAfterUserInput();
        var completed = self.pending_user_input.?;
        completed.deinit();
        self.pending_user_input = null;
        self.selected_user_input_choice = 0;
        self.invalid_user_input = false;
        self.phase = .responding;
        self.followTail();
    }

    fn appendUserInputQuestion(
        self: *ChatUi,
        request: backend.UserInputRequest,
    ) !void {
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(self.allocator);
        try message.appendSlice(self.allocator, request.question);
        for (request.choices, 0..) |choice, index| {
            const line = try std.fmt.allocPrint(
                self.allocator,
                "\n  {d}. {s}",
                .{ index + 1, choice },
            );
            defer self.allocator.free(line);
            try message.appendSlice(self.allocator, line);
        }
        try self.transcript.appendBeforeQueued(
            self.allocator,
            .question,
            message.items,
        );
    }

    fn moveUserInputSelection(
        self: *ChatUi,
        direction: MenuDirection,
    ) void {
        const option_count = self.userInputOptionCount();
        if (option_count == 0) return;
        self.input.clearRetainingCapacity();
        self.selected_user_input_choice = switch (direction) {
            .previous => if (self.selected_user_input_choice == 0)
                option_count - 1
            else
                self.selected_user_input_choice - 1,
            .next => (self.selected_user_input_choice + 1) % option_count,
        };
        self.invalid_user_input = false;
    }

    fn prepareInputForUserQuestion(self: *ChatUi) void {
        if (self.saved_input != null) {
            self.input.clearRetainingCapacity();
            return;
        }
        self.saved_input = self.input;
        self.input = TextInput.init(self.allocator);
    }

    fn restoreInputAfterUserInput(self: *ChatUi) void {
        self.input.deinit();
        if (self.saved_input) |saved| {
            self.input = saved;
            self.saved_input = null;
        } else {
            self.input = TextInput.init(self.allocator);
        }
    }

    fn syncSlashMenu(self: *ChatUi) !void {
        if (self.menu_mode == .loading_models) return;
        if (self.menu_mode == .models) {
            return self.rebuildModelMenu();
        }
        const contents = try self.input.toOwnedContents(self.allocator);
        defer self.allocator.free(contents);
        const query = slashCommandQuery(contents) orelse {
            self.menu_mode = .closed;
            return;
        };
        if (self.dismissed_revision == self.input_revision) {
            self.menu_mode = .closed;
            return;
        }
        self.menu_mode = .commands;
        try self.rebuildCommandMenu(query);
    }

    fn rebuildCommandMenu(self: *ChatUi, query: []const u8) !void {
        const catalog = self.commands orelse return;
        const entries = try self.allocator.alloc(
            MenuEntry,
            catalog.commands.len,
        );
        defer self.allocator.free(entries);
        for (catalog.commands, 0..) |command, index| {
            entries[index] = .{
                .key = command.name,
                .primary = command.name,
                .detail = .{ .text = command.description },
                .source_index = index,
            };
        }
        try self.menu.rebuild(self.allocator, entries, query);
    }

    fn rebuildModelMenu(self: *ChatUi) !void {
        const catalog = self.models orelse return;
        const query = try self.input.toOwnedContents(self.allocator);
        defer self.allocator.free(query);
        const entries = try self.allocator.alloc(MenuEntry, catalog.models.len);
        defer self.allocator.free(entries);
        for (catalog.models, 0..) |model, index| {
            entries[index] = .{
                .key = model.id,
                .primary = model.display_name,
                .detail = .{ .model = .{
                    .context_tokens = model.max_context_window_tokens,
                    .output_tokens = model.max_output_tokens,
                    .supports_vision = model.supports_vision,
                } },
                .current = std.mem.eql(u8, catalog.selected_id, model.id),
                .source_index = index,
            };
        }
        try self.menu.rebuild(self.allocator, entries, query);
    }

    fn activateMenu(
        self: *ChatUi,
        conversation: *backend.Conversation,
    ) !void {
        const selected = self.menu.selected() orelse return;
        switch (self.menu_mode) {
            .commands => {
                const catalog = self.commands orelse return;
                const command = catalog.commands[selected.source_index];
                if (!std.ascii.eqlIgnoreCase(command.name, "model")) {
                    const contents = try self.input.toOwnedContents(
                        self.allocator,
                    );
                    defer self.allocator.free(contents);
                    const command_input = try buildCommandInput(
                        self.allocator,
                        command.name,
                        contents,
                    );
                    defer self.allocator.free(command_input);
                    conversation.executeCommand(command_input) catch |err| switch (err) {
                        error.EmptyCommand, error.Busy => return,
                        else => return err,
                    };
                    self.input.clearRetainingCapacity();
                    self.menu_mode = .closed;
                    self.phase = .running_command;
                    return;
                }
                self.input.clearRetainingCapacity();
                self.menu_mode = .loading_models;
                conversation.refreshModels() catch |err| switch (err) {
                    error.Busy => {
                        self.menu_mode = .closed;
                        return;
                    },
                    else => return err,
                };
            },
            .models => {
                const catalog = self.models orelse return;
                const model = catalog.models[selected.source_index];
                conversation.switchModel(model.id) catch |err| switch (err) {
                    error.Busy => return,
                    else => return err,
                };
                self.input.clearRetainingCapacity();
                self.menu_mode = .closed;
                self.phase = .switching;
            },
            .closed, .loading_models => {},
        }
    }

    fn applyConversationEvent(
        self: *ChatUi,
        event: *const backend.ConversationEvent,
    ) !ConversationOutcome {
        switch (event.*) {
            .ready => self.phase = .ready,
            .command_catalog => |catalog| {
                const replacement = try catalog.clone(self.allocator);
                if (self.commands) |*current| current.deinit();
                self.commands = replacement;
                if (self.phase == .loading_commands) self.phase = .ready;
                if (self.menu_mode == .commands) try self.syncSlashMenu();
            },
            .model_catalog => |catalog| {
                const replacement = try catalog.clone(self.allocator);
                if (self.models) |*current| current.deinit();
                self.models = replacement;
                if (self.menu_mode == .loading_models) {
                    self.menu_mode = .models;
                    self.phase = .ready;
                    try self.rebuildModelMenu();
                } else if (self.menu_mode == .models) {
                    try self.rebuildModelMenu();
                }
            },
            .model_catalog_failed => |failure| {
                self.phase = .ready;
                if (self.models != null and
                    self.menu_mode == .loading_models)
                {
                    self.menu_mode = .models;
                    try self.rebuildModelMenu();
                } else {
                    self.menu_mode = .closed;
                }
                try self.transcript.append(
                    self.allocator,
                    .status,
                    failure.bytes,
                );
            },
            .model_switch => |result| {
                self.phase = .ready;
                switch (result) {
                    .unchanged => |model| {
                        try self.updateSelectedModel(model.id);
                        try self.transcript.append(
                            self.allocator,
                            .status,
                            "Already using the selected model.",
                        );
                    },
                    .default_updated => |model| {
                        try self.updateSelectedModel(model.id);
                        const message = try std.fmt.allocPrint(
                            self.allocator,
                            "{s} is now the default for future Vivi chats.",
                            .{model.display_name},
                        );
                        defer self.allocator.free(message);
                        try self.transcript.append(
                            self.allocator,
                            .status,
                            message,
                        );
                    },
                    .switched => |success| {
                        try self.updateSelectedModel(success.model.id);
                        const message = try std.fmt.allocPrint(
                            self.allocator,
                            "Switched to {s}{s}. Server-side conversation history was reset; the visible Vivi transcript remains.{s}",
                            .{
                                success.model.display_name,
                                if (success.default_saved)
                                    " and saved it as the default"
                                else
                                    "",
                                if (success.cleanup_failed)
                                    " The previous session could not be detached cleanly."
                                else
                                    "",
                            },
                        );
                        defer self.allocator.free(message);
                        try self.transcript.append(
                            self.allocator,
                            .status,
                            message,
                        );
                    },
                    .failed => |failure| try self.transcript.append(
                        self.allocator,
                        .status,
                        failure.bytes,
                    ),
                }
            },
            .assistant_started => {
                self.phase = .responding;
                self.transcript.beginQueuedTurn();
            },
            .reasoning_delta => |text| {
                try self.transcript.appendReasoningDelta(
                    self.allocator,
                    text.bytes,
                );
            },
            .reasoning_complete => |text| {
                try self.transcript.completeReasoning(
                    self.allocator,
                    text.bytes,
                );
                if (text.bytes.len > 0) self.transcript.finishReasoning();
            },
            .assistant_delta => |text| {
                try self.transcript.appendDelta(self.allocator, text.bytes);
            },
            .assistant_complete => |text| {
                try self.transcript.completeAssistant(
                    self.allocator,
                    text.bytes,
                );
                if (text.bytes.len > 0) self.transcript.finishTurn();
            },
            .user_input_requested => |request| {
                const replacement = try request.clone(self.allocator);
                if (self.pending_user_input) |*current| current.deinit();
                self.pending_user_input = replacement;
                self.selected_user_input_choice = 0;
                self.invalid_user_input = false;
                self.menu_mode = .closed;
                self.prepareInputForUserQuestion();
                self.phase = .awaiting_input;
                self.followTail();
            },
            .command_completed => |message| {
                self.phase = .ready;
                try self.transcript.append(
                    self.allocator,
                    .status,
                    message.bytes,
                );
            },
            .idle => {
                self.transcript.endTurn();
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

    fn updateSelectedModel(self: *ChatUi, model_id: []const u8) !void {
        if (self.models) |*catalog| {
            const replacement = try self.allocator.dupe(u8, model_id);
            self.allocator.free(catalog.selected_id);
            catalog.selected_id = replacement;
        }
    }

    fn draw(self: *ChatUi, root: vaxis.Window) !void {
        const desired_menu_rows: u16 = if (self.phase == .awaiting_input)
            self.userInputPanelRows(root)
        else switch (self.menu_mode) {
            .commands, .models => @intCast(@min(self.menu.matches.items.len, 8)),
            .closed, .loading_models => 0,
        };
        const layout = FrameLayout.compute(
            root.width,
            root.height,
            desired_menu_rows,
        );
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
        if (layout.context) |region| {
            if (self.phase == .awaiting_input)
                self.drawQuestionDivider(region.child(root))
            else
                self.drawContext(region.child(root));
        }
        if (layout.menu) |region| {
            if (self.phase == .awaiting_input)
                self.drawQuestionPanel(region.child(root))
            else
                self.drawMenu(region.child(root));
        }
        if (layout.composer.height > 0) {
            self.drawComposer(layout.composer.child(root));
        }
        if (layout.footer) |region| self.drawFooter(region.child(root));
    }

    fn drawMenu(self: *ChatUi, window: vaxis.Window) void {
        window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = menu_background },
        });
        const range = self.menu.visibleRange(window.height);
        for (range.first..range.last, 0..) |match_index, row| {
            const entry_index = self.menu.matches.items[match_index];
            const entry = self.menu.entries.items[entry_index];
            const selected = match_index == self.menu.selected_match;
            const style = vaxis.Style{
                .bg = if (selected)
                    menu_selected_background
                else
                    menu_background,
            };
            const marker = if (selected) ">" else if (entry.current) "*" else " ";
            var segments = [_]vaxis.Segment{
                .{ .text = marker, .style = style },
                .{ .text = " ", .style = style },
                .{
                    .text = entry.primary,
                    .style = .{
                        .bg = style.bg,
                        .bold = selected or entry.current,
                    },
                },
            };
            const detail_col: u16 = if (window.width >= 28)
                @min(window.width / 2, 44)
            else
                window.width;
            const label_window = window.child(.{ .width = detail_col -| 1 });
            _ = label_window.print(&segments, .{
                .row_offset = @intCast(row),
                .col_offset = 1,
                .wrap = .none,
            });
            if (window.width < 28) continue;
            self.drawMenuDetail(
                window,
                @intCast(row),
                entry,
                style,
            );
        }
    }

    fn drawQuestionDivider(_: *ChatUi, window: vaxis.Window) void {
        if (window.width == 0) return;
        window.fill(.{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{ .fg = reasoning_color, .dim = true },
        });
        const label = " Answer required ";
        const label_width = window.gwidth(label);
        if (label_width > window.width) return;
        var segments = [_]vaxis.Segment{.{
            .text = label,
            .style = .{ .bold = true },
        }};
        _ = window.print(&segments, .{
            .col_offset = window.width - label_width,
            .wrap = .none,
        });
    }

    fn drawQuestionPanel(self: *ChatUi, window: vaxis.Window) void {
        const request = self.pending_user_input orelse return;
        if (window.height == 0 or window.width == 0) return;

        const option_count = self.userInputOptionCount();
        const error_rows: u16 = @intFromBool(
            self.invalid_user_input and window.height > 2,
        );
        const content_height = window.height -| error_rows;
        const title_rows: u16 = @intFromBool(
            option_count == 0 or content_height >= 2,
        );
        if (title_rows > 0) {
            var title = [_]vaxis.Segment{.{
                .text = "Vivi needs information.",
                .style = .{ .bold = true },
            }};
            _ = window.print(&title, .{
                .row_offset = 0,
                .col_offset = 1,
                .wrap = .none,
            });
        }

        const max_question_rows = if (option_count > 0)
            content_height -| title_rows -| 1
        else
            content_height -| title_rows;
        const question_rows = @min(
            self.userInputQuestionRows(window),
            max_question_rows,
        );
        const question_inset: u16 = @intFromBool(window.width > 2);
        if (question_rows > 0) {
            const question_window = window.child(.{
                .x_off = @intCast(question_inset),
                .y_off = @intCast(title_rows),
                .width = window.width -| question_inset * 2,
                .height = question_rows,
            });
            var question = [_]vaxis.Segment{.{
                .text = request.question,
                .style = .{ .dim = true },
            }};
            _ = question_window.print(&question, .{
                .wrap = .grapheme,
            });
        }

        const room_for_gap =
            content_height > title_rows + question_rows + 1;
        const choice_row = title_rows + question_rows +
            @as(u16, @intFromBool(room_for_gap));
        const choice_rows = content_height -| choice_row;
        const range = visibleSelectionRange(
            option_count,
            choice_rows,
            self.selected_user_input_choice,
        );
        for (range.first..range.last, 0..) |index, visible_index| {
            const choice = if (index < request.choices.len)
                request.choices[index]
            else
                "Other (type your answer)";
            self.drawQuestionChoice(
                window,
                choice_row + @as(u16, @intCast(visible_index)),
                index,
                choice,
            );
        }
        if (error_rows > 0) {
            var error_message = [_]vaxis.Segment{.{
                .text = "Choose one of the listed answers.",
                .style = .{ .fg = assistant_color, .bold = true },
            }};
            _ = window.print(&error_message, .{
                .row_offset = window.height - 1,
                .col_offset = 1,
                .wrap = .none,
            });
        }
    }

    fn drawQuestionChoice(
        self: *const ChatUi,
        window: vaxis.Window,
        row: u16,
        index: usize,
        choice: []const u8,
    ) void {
        const selected = index == self.selected_user_input_choice;
        const choice_style: vaxis.Style = if (selected)
            .{ .fg = accent, .bold = true }
        else
            .{};
        var segments = [_]vaxis.Segment{
            .{
                .text = if (selected) "› " else "  ",
                .style = .{
                    .fg = accent,
                    .bold = selected,
                },
            },
            .{
                .text = choice,
                .style = choice_style,
            },
        };
        _ = window.print(&segments, .{
            .row_offset = row,
            .col_offset = 1,
            .wrap = .none,
        });
    }

    fn drawMenuDetail(
        self: *ChatUi,
        window: vaxis.Window,
        row: u16,
        entry: MenuEntry,
        style: vaxis.Style,
    ) void {
        switch (entry.detail) {
            .text => |detail| {
                var segments = [_]vaxis.Segment{.{
                    .text = detail,
                    .style = .{ .bg = style.bg, .dim = true },
                }};
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .col_offset = @intCast(@min(window.width / 2, 36)),
                    .wrap = .none,
                });
            },
            .model => |model| {
                const buffer = &self.menu_detail_storage[row];
                const rendered = if (model.context_tokens == 0)
                    std.fmt.bufPrint(buffer, "hosted", .{}) catch return
                else if (window.width >= 56)
                    std.fmt.bufPrint(
                        buffer,
                        "context {d}  output {d}{s}",
                        .{
                            model.context_tokens,
                            model.output_tokens,
                            if (model.supports_vision) "  vision" else "",
                        },
                    ) catch return
                else
                    std.fmt.bufPrint(
                        buffer,
                        "{d} / {d}{s}",
                        .{
                            model.context_tokens,
                            model.output_tokens,
                            if (model.supports_vision) "  vision" else "",
                        },
                    ) catch return;
                var segments = [_]vaxis.Segment{.{
                    .text = rendered,
                    .style = .{ .bg = style.bg, .dim = true },
                }};
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .col_offset = @intCast(@min(window.width / 2, 36)),
                    .wrap = .none,
                });
            },
        }
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
                    .queued => "Queued",
                    .reasoning => "Thinking",
                    .assistant => "Vivi",
                    .question => "Question",
                    .status => unreachable,
                };
                const role_color = switch (entry.role) {
                    .user => user_color,
                    .queued => accent,
                    .reasoning => reasoning_color,
                    .assistant => assistant_color,
                    .question => accent,
                    .status => unreachable,
                };
                var segments = [_]vaxis.Segment{.{
                    .text = role_text,
                    .style = if (entry.role == .reasoning)
                        .{ .fg = role_color, .dim = true, .italic = true }
                    else
                        .{ .fg = role_color, .bold = true },
                }};
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .wrap = .none,
                });
            },
            .body => {
                var segments = [_]vaxis.Segment{.{
                    .text = entry.text.items[line.start..line.end],
                    .style = if (entry.role == .reasoning)
                        .{
                            .fg = reasoning_color,
                            .dim = true,
                            .italic = true,
                        }
                    else
                        .{},
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
        const phase = self.phase.label();
        const phase_width = window.gwidth(phase);
        if (phase_width >= window.width) {
            var phase_segment = [_]vaxis.Segment{.{
                .text = phase,
                .style = .{ .bold = true },
            }};
            _ = window.print(&phase_segment, .{ .wrap = .none });
            return;
        }
        const cwd = if (window.width < 40)
            std.fs.path.basename(self.cwd)
        else
            self.cwd;
        const gap: u16 = 2;
        const cwd_width = window.width - phase_width - gap;
        var cwd_segment = [_]vaxis.Segment{.{
            .text = cwd,
            .style = .{ .dim = true },
        }};
        _ = window.child(.{ .width = cwd_width }).print(
            &cwd_segment,
            .{ .wrap = .none },
        );
        var phase_segment = [_]vaxis.Segment{.{
            .text = phase,
            .style = .{ .bold = true },
        }};
        _ = window.print(&phase_segment, .{
            .col_offset = window.width - phase_width,
            .wrap = .none,
        });
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
        if (self.phase == .ready or
            self.phase == .loading_commands or
            self.phase == .responding or
            self.phase == .awaiting_input)
        {
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
                .ready => "Enter send  ·  PgUp/PgDn scroll  ·  Ctrl-C quit",
                .responding => "Enter steer  ·  Ctrl+Enter queue  ·  PgUp/PgDn scroll  ·  Ctrl-C stop",
                .awaiting_input => if (self.hasInputChoices())
                    if (self.hasFreeformChoice())
                        "↑/↓ select  ·  Enter accept  ·  type for other  ·  Ctrl-C stop"
                    else
                        "↑/↓ select  ·  Enter accept  ·  Ctrl-C stop"
                else
                    "Enter answer  ·  PgUp/PgDn scroll  ·  Ctrl-C stop",
                .connecting, .loading_commands, .running_command, .switching => "PgUp/PgDn scroll  ·  Ctrl-C stop",
                .stopping => "Ctrl-C again force exit",
            }
        else if (window.width >= 24)
            switch (self.phase) {
                .ready => "Enter send  ·  Ctrl-C quit",
                .responding => "Enter steer  ·  ^Enter queue",
                .awaiting_input => if (self.hasInputChoices())
                    "↑/↓ select  ·  Enter accept"
                else
                    "Enter answer  ·  Ctrl-C stop",
                .connecting, .loading_commands, .running_command, .switching => "Ctrl-C stop",
                .stopping => "Ctrl-C again force exit",
            }
        else switch (self.phase) {
            .ready => "Ctrl-C quit",
            .responding => "Enter steer",
            .awaiting_input => if (self.hasInputChoices())
                "Enter choice"
            else
                "Enter answer",
            .connecting, .loading_commands, .running_command, .switching => "Ctrl-C stop",
            .stopping => "Ctrl-C again",
        };
        const model_name = self.selectedModelDisplayName();
        const model_width = if (model_name) |name| window.gwidth(name) else 0;
        const model_gap: u16 = if (model_width > 0 and
            model_width + 2 < window.width) 2 else 0;
        const hints_width = if (model_gap > 0)
            window.width - model_width - model_gap
        else
            window.width;
        var hint_segments = [_]vaxis.Segment{.{
            .text = hints,
            .style = .{ .dim = true },
        }};
        if (hints_width > 0) {
            _ = window.child(.{ .width = hints_width }).print(
                &hint_segments,
                .{ .wrap = .none },
            );
        }
        if (model_name) |name| {
            if (model_gap == 0) return;
            var model_segments = [_]vaxis.Segment{.{
                .text = name,
                .style = .{ .dim = true },
            }};
            _ = window.print(&model_segments, .{
                .col_offset = window.width - model_width,
                .wrap = .none,
            });
        }
    }

    fn selectedModelDisplayName(self: *const ChatUi) ?[]const u8 {
        const catalog = self.models orelse return null;
        for (catalog.models) |model| {
            if (std.mem.eql(u8, model.id, catalog.selected_id)) {
                return model.display_name;
            }
        }
        return catalog.selected_id;
    }

    fn hasInputChoices(self: *const ChatUi) bool {
        return if (self.pending_user_input) |request|
            request.choices.len > 0
        else
            false;
    }

    fn hasFreeformChoice(self: *const ChatUi) bool {
        return if (self.pending_user_input) |request|
            request.allow_freeform
        else
            false;
    }

    fn userInputOptionCount(self: *const ChatUi) usize {
        return if (self.pending_user_input) |request|
            request.choices.len + @intFromBool(request.allow_freeform)
        else
            0;
    }

    fn userInputPanelRows(
        self: *const ChatUi,
        window: vaxis.Window,
    ) u16 {
        const rows = 2 + self.userInputQuestionRows(window) +
            self.userInputOptionCount() +
            @intFromBool(self.invalid_user_input);
        return @intCast(@min(rows, std.math.maxInt(u16)));
    }

    fn userInputQuestionRows(
        self: *const ChatUi,
        window: vaxis.Window,
    ) u16 {
        const request = self.pending_user_input orelse return 1;
        const question_inset: u16 = @intFromBool(window.width > 2);
        const available_width = @max(
            window.width -| question_inset * 2,
            1,
        );
        var rows: u16 = 1;
        var line_width: u16 = 0;
        var iterator = vaxis.unicode.graphemeIterator(request.question);
        while (iterator.next()) |grapheme| {
            const bytes = grapheme.bytes(request.question);
            if (std.mem.eql(u8, bytes, "\n")) {
                rows +|= 1;
                line_width = 0;
                continue;
            }
            const grapheme_width = window.gwidth(bytes);
            if (line_width > 0 and
                line_width +| grapheme_width > available_width)
            {
                rows +|= 1;
                line_width = 0;
            }
            line_width +|= grapheme_width;
        }
        return rows;
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

    fn init(
        self: *App,
        init_args: std.process.Init,
        model: ?[]const u8,
        settings_path: ?[]const u8,
    ) !void {
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
            .{
                .model = model,
                .settings_path = settings_path,
                .omlx = .{
                    .base_url = init_args.environ_map.get("OMLX_BASE_URL") orelse
                        backend.default_omlx_base_url,
                    .api_key = init_args.environ_map.get("OMLX_API_KEY") orelse
                        "omlx",
                },
            },
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

pub fn run(
    init: std.process.Init,
    model: ?[]const u8,
    settings_path: ?[]const u8,
) !void {
    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);
    try app.init(init, model, settings_path);
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

test "empty assistant completion does not create or clear a draft" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.completeAssistant(std.testing.allocator, "");
    try std.testing.expectEqual(0, transcript.entries.items.len);
    try transcript.appendDelta(std.testing.allocator, "partial");
    try transcript.completeAssistant(std.testing.allocator, "");
    try transcript.completeAssistant(std.testing.allocator, "hello");

    try std.testing.expectEqual(1, transcript.entries.items.len);
    try std.testing.expectEqualStrings(
        "hello",
        transcript.entries.items[0].text.items,
    );
}

test "assistant message boundary preserves queued turn order" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendDelta(std.testing.allocator, "first");
    transcript.finishTurn();
    try transcript.append(std.testing.allocator, .user, "queued");
    try transcript.appendDelta(std.testing.allocator, "second");
    try transcript.completeAssistant(std.testing.allocator, "second");

    try std.testing.expectEqual(3, transcript.entries.items.len);
    try std.testing.expectEqualStrings(
        "first",
        transcript.entries.items[0].text.items,
    );
    try std.testing.expectEqualStrings(
        "queued",
        transcript.entries.items[1].text.items,
    );
    try std.testing.expectEqualStrings(
        "second",
        transcript.entries.items[2].text.items,
    );
}

test "queued prompts are promoted in FIFO order" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.append(std.testing.allocator, .queued, "first");
    try transcript.append(std.testing.allocator, .queued, "second");

    transcript.promoteNextQueuedPrompt();
    try std.testing.expectEqual(Role.user, transcript.entries.items[0].role);
    try std.testing.expectEqual(Role.queued, transcript.entries.items[1].role);

    transcript.promoteNextQueuedPrompt();
    try std.testing.expectEqual(Role.user, transcript.entries.items[1].role);
}

test "queued prompt moves behind the response it waited for" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.append(std.testing.allocator, .user, "first prompt");
    try transcript.append(std.testing.allocator, .queued, "queued prompt");
    try transcript.appendDelta(std.testing.allocator, "first response");
    transcript.beginQueuedTurn();

    try std.testing.expectEqual(3, transcript.entries.items.len);
    try std.testing.expectEqualStrings(
        "first response",
        transcript.entries.items[1].text.items,
    );
    try std.testing.expectEqual(Role.user, transcript.entries.items[2].role);
    try std.testing.expectEqualStrings(
        "queued prompt",
        transcript.entries.items[2].text.items,
    );
}

test "response arriving after queue submission is inserted before the queue" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.append(std.testing.allocator, .user, "first prompt");
    try transcript.append(std.testing.allocator, .queued, "queued prompt");
    try transcript.appendDelta(std.testing.allocator, "first response");

    try std.testing.expectEqual(3, transcript.entries.items.len);
    try std.testing.expectEqual(Role.assistant, transcript.entries.items[1].role);
    try std.testing.expectEqualStrings(
        "first response",
        transcript.entries.items[1].text.items,
    );
    try std.testing.expectEqual(Role.queued, transcript.entries.items[2].role);
}

test "reasoning and response stay ordered before a queued prompt" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.append(std.testing.allocator, .user, "first prompt");
    try transcript.append(std.testing.allocator, .queued, "queued prompt");
    try transcript.appendReasoningDelta(std.testing.allocator, "thinking");
    try transcript.completeReasoning(std.testing.allocator, "thought through");
    transcript.finishReasoning();
    try transcript.appendDelta(std.testing.allocator, "first response");
    transcript.beginQueuedTurn();
    try transcript.appendDelta(std.testing.allocator, "queued response");

    try std.testing.expectEqual(5, transcript.entries.items.len);
    try std.testing.expectEqual(Role.reasoning, transcript.entries.items[1].role);
    try std.testing.expectEqualStrings(
        "thought through",
        transcript.entries.items[1].text.items,
    );
    try std.testing.expectEqual(Role.assistant, transcript.entries.items[2].role);
    try std.testing.expectEqualStrings(
        "first response",
        transcript.entries.items[2].text.items,
    );
    try std.testing.expectEqual(Role.user, transcript.entries.items[3].role);
    try std.testing.expectEqualStrings(
        "queued prompt",
        transcript.entries.items[3].text.items,
    );
    try std.testing.expectEqual(Role.assistant, transcript.entries.items[4].role);
    try std.testing.expectEqualStrings(
        "queued response",
        transcript.entries.items[4].text.items,
    );
}

test "ask-user exchange separates resumed output from active reasoning" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendReasoningDelta(
        std.testing.allocator,
        "before question",
    );
    try transcript.append(std.testing.allocator, .queued, "later prompt");
    transcript.endTurn();
    try transcript.appendBeforeQueued(
        std.testing.allocator,
        .question,
        "Pick one\n  1. Alpha\n  2. Beta",
    );
    try transcript.appendBeforeQueued(
        std.testing.allocator,
        .user,
        "Beta",
    );
    try transcript.appendDelta(std.testing.allocator, "after answer");

    try std.testing.expectEqual(@as(usize, 5), transcript.entries.items.len);
    try std.testing.expectEqual(Role.reasoning, transcript.entries.items[0].role);
    try std.testing.expectEqual(Role.question, transcript.entries.items[1].role);
    try std.testing.expectEqual(Role.user, transcript.entries.items[2].role);
    try std.testing.expectEqual(Role.assistant, transcript.entries.items[3].role);
    try std.testing.expectEqual(Role.queued, transcript.entries.items[4].role);
    try std.testing.expectEqualStrings(
        "after answer",
        transcript.entries.items[3].text.items,
    );
}

test "late reasoning completion updates its entry before the response" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendReasoningDelta(std.testing.allocator, "partial thought");
    transcript.finishReasoning();
    try transcript.appendDelta(std.testing.allocator, "answer");
    try transcript.completeReasoning(std.testing.allocator, "complete thought");
    try transcript.appendDelta(std.testing.allocator, "!");

    try std.testing.expectEqual(2, transcript.entries.items.len);
    try std.testing.expectEqual(Role.reasoning, transcript.entries.items[0].role);
    try std.testing.expectEqualStrings(
        "complete thought",
        transcript.entries.items[0].text.items,
    );
    try std.testing.expectEqual(Role.assistant, transcript.entries.items[1].role);
    try std.testing.expectEqualStrings(
        "answer!",
        transcript.entries.items[1].text.items,
    );
}

test "blank reasoning and assistant deltas do not create entries" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.appendReasoningDelta(std.testing.allocator, "\n");
    try transcript.completeReasoning(std.testing.allocator, " \t");
    try transcript.appendDelta(std.testing.allocator, "\r\n");
    try transcript.completeAssistant(std.testing.allocator, "");

    try std.testing.expectEqual(0, transcript.entries.items.len);
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
        const layout = FrameLayout.compute(size.width, size.height, 8);
        try std.testing.expect(
            layout.composer.y + layout.composer.height <= size.height,
        );
        if (layout.context) |context| {
            try std.testing.expect(context.y + context.height <= size.height);
            if (layout.menu) |menu| {
                try std.testing.expect(
                    context.y + context.height <= menu.y,
                );
            } else {
                try std.testing.expect(
                    context.y + context.height <= layout.composer.y,
                );
            }
        }
        if (layout.menu) |menu| {
            try std.testing.expect(menu.y + menu.height <= size.height);
            try std.testing.expect(
                menu.y + menu.height <= layout.composer.y,
            );
        }
        if (layout.footer) |footer| {
            try std.testing.expect(footer.y + footer.height <= size.height);
            try std.testing.expect(
                layout.composer.y + layout.composer.height <= footer.y,
            );
        }
    }
}

test "ask-user input preserves the existing composer draft" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
    };
    defer ui.deinit();

    try ui.input.insertSliceAtCursor("unfinished draft");
    ui.prepareInputForUserQuestion();

    const answer_input = try ui.input.toOwnedContents(std.testing.allocator);
    defer std.testing.allocator.free(answer_input);
    try std.testing.expectEqualStrings("", answer_input);

    try ui.input.insertSliceAtCursor("Beta");
    ui.restoreInputAfterUserInput();

    const restored = try ui.input.toOwnedContents(std.testing.allocator);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings("unfinished draft", restored);
}

test "slash command parsing preserves argument suffixes" {
    try std.testing.expectEqualStrings(
        "autopilot",
        slashCommandQuery("/autopilot thorough").?,
    );
    try std.testing.expectEqualStrings(
        " thorough",
        commandArgumentSuffix("/autopilot thorough"),
    );
    const command_input = try buildCommandInput(
        std.testing.allocator,
        "autopilot",
        "/auto thorough",
    );
    defer std.testing.allocator.free(command_input);
    try std.testing.expectEqualStrings("autopilot thorough", command_input);
    try std.testing.expectEqualStrings("", slashCommandQuery("/").?);
    try std.testing.expect(slashCommandQuery("not-a-command") == null);
}

test "arrow selection replaces typed ask-user input" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .pending_user_input = try backend.UserInputRequest.init(
            std.testing.allocator,
            "request-1",
            "Pick one",
            &.{ "Alpha", "Beta" },
            false,
        ),
    };
    defer ui.deinit();

    try ui.input.insertSliceAtCursor("1");
    ui.moveUserInputSelection(.next);

    const contents = try ui.input.toOwnedContents(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("", contents);
    try std.testing.expectEqual(@as(usize, 1), ui.selected_user_input_choice);
}

test "ask-user panel reserves rows for wrapped questions" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .pending_user_input = try backend.UserInputRequest.init(
            std.testing.allocator,
            "request-1",
            "12345678901234567890",
            &.{"Alpha"},
            false,
        ),
    };
    defer ui.deinit();
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 12,
        .height = 20,
        .screen = &screen,
    };

    try std.testing.expectEqual(
        @as(u16, 2),
        ui.userInputQuestionRows(window),
    );
    try std.testing.expectEqual(
        @as(u16, 5),
        ui.userInputPanelRows(window),
    );
}

test "ask-user choice range keeps the selection visible" {
    const first = visibleSelectionRange(8, 3, 0);
    try std.testing.expectEqual(@as(usize, 0), first.first);
    try std.testing.expectEqual(@as(usize, 3), first.last);

    const middle = visibleSelectionRange(8, 3, 4);
    try std.testing.expectEqual(@as(usize, 2), middle.first);
    try std.testing.expectEqual(@as(usize, 5), middle.last);

    const last = visibleSelectionRange(8, 3, 7);
    try std.testing.expectEqual(@as(usize, 5), last.first);
    try std.testing.expectEqual(@as(usize, 8), last.last);
}

test "menu ranks prefixes and preserves deterministic navigation" {
    const entries = [_]MenuEntry{
        .{
            .key = "model",
            .primary = "Model",
            .detail = .{ .text = "Switch the active model" },
            .source_index = 0,
        },
        .{
            .key = "memory",
            .primary = "Memory",
            .detail = .{ .text = "Manage memories" },
            .source_index = 1,
        },
        .{
            .key = "show-model",
            .primary = "Show Model",
            .detail = .{ .text = "Inspect model information" },
            .source_index = 2,
        },
    };
    var menu: MenuState = .{};
    defer menu.deinit(std.testing.allocator);

    try menu.rebuild(std.testing.allocator, &entries, "mod");
    try std.testing.expectEqual(@as(usize, 2), menu.matches.items.len);
    try std.testing.expectEqualStrings("model", menu.selected().?.key);
    menu.move(.next);
    try std.testing.expectEqualStrings("show-model", menu.selected().?.key);
    menu.move(.next);
    try std.testing.expectEqualStrings("model", menu.selected().?.key);
}

test "model menu detail owns no composer text" {
    var menu: MenuState = .{};
    defer menu.deinit(std.testing.allocator);
    var query = [_]u8{ 'q', 'w', 'e', 'n' };
    const entries = [_]MenuEntry{.{
        .key = "omlx/qwen",
        .primary = "Qwen",
        .detail = .{ .model = .{
            .context_tokens = 131_072,
            .output_tokens = 32_768,
            .supports_vision = false,
        } },
        .source_index = 0,
    }};

    try menu.rebuild(std.testing.allocator, &entries, &query);
    @memset(&query, 'x');
    try std.testing.expectEqualStrings("omlx/qwen", menu.selected().?.key);
}

test "model menu matches provider-qualified identifiers" {
    const entries = [_]MenuEntry{.{
        .key = "copilot/gpt-5.6-sol",
        .primary = "GPT-5.6 Sol",
        .detail = .{ .model = .{
            .context_tokens = 1_050_000,
            .output_tokens = 128_000,
            .supports_vision = true,
        } },
        .source_index = 0,
    }};
    var menu: MenuState = .{};
    defer menu.deinit(std.testing.allocator);

    try menu.rebuild(std.testing.allocator, &entries, "gpt-5.6-sol");
    try std.testing.expectEqualStrings(
        "copilot/gpt-5.6-sol",
        menu.selected().?.key,
    );
}
