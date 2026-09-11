const std = @import("std");
const backend = @import("vivi_backend");
const highlight = @import("highlight.zig");
const markdown = @import("markdown.zig");
const tool_renderer = @import("tool_renderer.zig");
const vaxis = @import("vaxis");

const TextInput = vaxis.widgets.TextInput;

const accent = vaxis.Color{ .rgb = .{ 110, 231, 183 } };
const user_color = vaxis.Color{ .rgb = .{ 125, 211, 252 } };
const assistant_color = vaxis.Color{ .rgb = .{ 196, 181, 253 } };
const reasoning_color = vaxis.Color{ .rgb = .{ 148, 163, 184 } };
const composer_background = vaxis.Color{ .index = 236 };
const menu_background = vaxis.Color{ .index = 234 };
const tool_detail_background = vaxis.Color{ .index = 234 };
const menu_selected_background = vaxis.Color{ .index = 238 };
const syntax_comment = vaxis.Color{ .rgb = .{ 148, 163, 184 } };
const syntax_string = vaxis.Color{ .rgb = .{ 134, 239, 172 } };
const syntax_number = vaxis.Color{ .rgb = .{ 253, 186, 116 } };
const syntax_keyword = vaxis.Color{ .rgb = .{ 196, 181, 253 } };
const syntax_function = vaxis.Color{ .rgb = .{ 125, 211, 252 } };
const syntax_property = vaxis.Color{ .rgb = .{ 253, 224, 71 } };
const syntax_operator = vaxis.Color{ .rgb = .{ 244, 114, 182 } };

const AppEvent = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    conversation_wake,
};

fn isMouseWheel(mouse: vaxis.Mouse) bool {
    return mouse.type == .press and
        (mouse.button == .wheel_up or mouse.button == .wheel_down);
}

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

const MessageEntry = struct {
    role: Role,
    text: std.ArrayList(u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        role: Role,
        text: []const u8,
    ) !MessageEntry {
        var entry: MessageEntry = .{ .role = role };
        errdefer entry.text.deinit(allocator);
        try entry.text.appendSlice(allocator, text);
        return entry;
    }

    fn deinit(self: *MessageEntry, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

const ToolEntry = struct {
    call_id: backend.ToolCallId,
    invocation_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    completion: ?Completion = null,
    compact: []u8,
    input: []u8,
    input_display: []u8,
    output: ?[]u8 = null,
    output_display: ?[]u8 = null,
    input_highlights: []highlight.Span,
    output_highlights: ?[]highlight.Span = null,
    output_language: ?highlight.Language,
    expanded: bool = false,

    const Completion = union(enum) {
        succeeded: [std.crypto.hash.sha2.Sha256.digest_length]u8,
        failed: [std.crypto.hash.sha2.Sha256.digest_length]u8,

        fn eql(self: Completion, other: Completion) bool {
            return switch (self) {
                .succeeded => |hash| switch (other) {
                    .succeeded => |candidate| std.mem.eql(
                        u8,
                        hash[0..],
                        candidate[0..],
                    ),
                    .failed => false,
                },
                .failed => |hash| switch (other) {
                    .succeeded => false,
                    .failed => |candidate| std.mem.eql(
                        u8,
                        hash[0..],
                        candidate[0..],
                    ),
                },
            };
        }
    };

    fn init(
        allocator: std.mem.Allocator,
        started: *const backend.ToolStarted,
    ) !ToolEntry {
        const call_id = try started.call_id.clone(allocator);
        errdefer {
            var mutable = call_id;
            mutable.deinit(allocator);
        }
        const input = try allocator.dupe(u8, started.invocation.arguments_json);
        errdefer allocator.free(input);
        const input_display = try tool_renderer.renderArguments(allocator, input);
        errdefer allocator.free(input_display);
        const input_highlights = switch (started.invocation.summary) {
            .bash => |summary| try highlightBashInput(
                allocator,
                input_display,
                summary.command,
            ),
            else => try allocator.alloc(highlight.Span, 0),
        };
        errdefer allocator.free(input_highlights);
        return .{
            .call_id = call_id,
            .input = input,
            .input_display = input_display,
            .input_highlights = input_highlights,
            .output_language = switch (started.invocation.summary) {
                .read => |summary| highlight.Language.fromPath(summary.path),
                else => null,
            },
            .invocation_hash = hashToolInvocation(started),
            .compact = try tool_renderer.renderCompact(
                allocator,
                started.invocation.summary,
                .running,
            ),
        };
    }

    fn matchesStart(
        self: ToolEntry,
        started: *const backend.ToolStarted,
    ) bool {
        const invocation_hash = hashToolInvocation(started);
        return self.call_id.eql(started.call_id) and
            std.mem.eql(
                u8,
                self.invocation_hash[0..],
                invocation_hash[0..],
            );
    }

    fn finish(
        self: *ToolEntry,
        allocator: std.mem.Allocator,
        finished: *const backend.ToolFinished,
    ) !void {
        if (!self.call_id.eql(finished.call_id)) {
            return error.MismatchedToolCall;
        }
        const completion: Completion = switch (finished.result) {
            .succeeded => |text| .{
                .succeeded = hashToolPayload(text),
            },
            .failed => |text| .{
                .failed = hashToolPayload(text),
            },
        };
        if (self.completion) |existing| {
            if (!existing.eql(completion)) {
                return error.ConflictingToolCompletion;
            }
            return;
        }
        const text = switch (finished.result) {
            .succeeded, .failed => |text| text,
        };
        const output = try allocator.dupe(u8, text);
        errdefer allocator.free(output);
        const output_display = try tool_renderer.renderLiteral(allocator, output);
        errdefer allocator.free(output_display);
        self.output = output;
        self.output_display = output_display;
        self.completion = completion;
        const marker = switch (completion) {
            .succeeded => "✓",
            .failed => "✗",
        };
        std.debug.assert(std.mem.startsWith(u8, self.compact, "◌"));
        @memcpy(self.compact[0..marker.len], marker);
    }

    fn ensureOutputHighlights(
        self: *ToolEntry,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.output_highlights != null) return;
        const output = self.output_display orelse return;
        self.output_highlights = if (self.output_language) |language|
            try highlight.spans(allocator, language, output)
        else
            try allocator.alloc(highlight.Span, 0);
    }

    fn deinit(self: *ToolEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.compact);
        allocator.free(self.input);
        allocator.free(self.input_display);
        allocator.free(self.input_highlights);
        if (self.output) |output| allocator.free(output);
        if (self.output_display) |output| allocator.free(output);
        if (self.output_highlights) |spans| allocator.free(spans);
        self.call_id.deinit(allocator);
        self.* = undefined;
    }
};

fn highlightBashInput(
    allocator: std.mem.Allocator,
    display: []const u8,
    command: []const u8,
) ![]highlight.Span {
    const prefix = "Command: ";
    if (!std.mem.startsWith(u8, display, prefix)) {
        return allocator.alloc(highlight.Span, 0);
    }
    const command_spans = try highlight.spans(allocator, .bash, command);
    defer allocator.free(command_spans);
    const result = try allocator.alloc(highlight.Span, command_spans.len);
    for (command_spans, result) |span, *mapped| {
        mapped.* = .{
            .start = prefix.len + commandDisplayOffset(command, span.start),
            .end = prefix.len + commandDisplayOffset(command, span.end),
            .token = span.token,
        };
    }
    return result;
}

fn commandDisplayOffset(command: []const u8, end: usize) usize {
    var source_offset: usize = 0;
    var display_offset: usize = 0;
    while (source_offset < @min(end, command.len)) {
        const byte = command[source_offset];
        if (byte == '\n') {
            source_offset += 1;
            display_offset += 3;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        const codepoint = if (length > 0 and
            source_offset + length <= command.len)
            std.unicode.utf8Decode(
                command[source_offset..][0..length],
            ) catch null
        else
            null;
        if (codepoint) |value| {
            if (value >= 0x20 and value != 0x7f and
                !(value >= 0x80 and value <= 0x9f) and
                !(value >= 0x202a and value <= 0x202e) and
                !(value >= 0x2066 and value <= 0x2069))
            {
                source_offset += length;
                display_offset += length;
                continue;
            }
        }
        source_offset += 1;
        display_offset += 4;
    }
    return display_offset;
}

fn hashToolInvocation(
    started: *const backend.ToolStarted,
) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(@tagName(started.invocation.summary));
    switch (started.invocation.summary) {
        .other => |summary| {
            const name_len: u64 = @intCast(summary.name.len);
            hasher.update(std.mem.asBytes(&name_len));
            hasher.update(summary.name);
        },
        else => {},
    }
    hasher.update(&.{0});
    hasher.update(started.invocation.arguments_json);
    return hasher.finalResult();
}

fn hashToolPayload(payload: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    return digest;
}

fn syntaxStyle(base: vaxis.Style, token: highlight.Token) vaxis.Style {
    var style = base;
    style.fg = switch (token) {
        .comment => syntax_comment,
        .string => syntax_string,
        .number, .constant => syntax_number,
        .keyword => syntax_keyword,
        .function => syntax_function,
        .property => syntax_property,
        .operator => syntax_operator,
    };
    return style;
}

fn drawHighlightedRange(
    window: vaxis.Window,
    row: u16,
    column: u16,
    text: []const u8,
    start: usize,
    end: usize,
    highlights: []const highlight.Span,
    base_style: vaxis.Style,
) void {
    var offset = start;
    var current_column = column;
    for (highlights) |span| {
        if (span.end <= start) continue;
        if (span.start >= end) break;
        const span_start = @max(span.start, start);
        const span_end = @min(span.end, end);
        if (offset < span_start) {
            const plain = text[offset..span_start];
            var segments = [_]vaxis.Segment{.{
                .text = plain,
                .style = base_style,
            }};
            _ = window.print(&segments, .{
                .row_offset = row,
                .col_offset = current_column,
                .wrap = .none,
            });
            current_column +|= window.gwidth(plain);
        }
        const colored = text[span_start..span_end];
        var segments = [_]vaxis.Segment{.{
            .text = colored,
            .style = syntaxStyle(base_style, span.token),
        }};
        _ = window.print(&segments, .{
            .row_offset = row,
            .col_offset = current_column,
            .wrap = .none,
        });
        current_column +|= window.gwidth(colored);
        offset = span_end;
    }
    if (offset < end) {
        var segments = [_]vaxis.Segment{.{
            .text = text[offset..end],
            .style = base_style,
        }};
        _ = window.print(&segments, .{
            .row_offset = row,
            .col_offset = current_column,
            .wrap = .none,
        });
    }
}

const Entry = union(enum) {
    message: MessageEntry,
    tool: ToolEntry,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .message => |*message| message.deinit(allocator),
            .tool => |*tool| tool.deinit(allocator),
        }
        self.* = undefined;
    }

    fn messageValue(self: *Entry) ?*MessageEntry {
        return switch (self.*) {
            .message => |*message| message,
            .tool => null,
        };
    }

    fn constMessage(self: *const Entry) ?*const MessageEntry {
        return switch (self.*) {
            .message => |*message| message,
            .tool => null,
        };
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
        const message = try MessageEntry.init(allocator, role, text);
        errdefer {
            var mutable = message;
            mutable.deinit(allocator);
        }
        try self.entries.append(allocator, .{ .message = message });
    }

    fn appendBeforeQueued(
        self: *Transcript,
        allocator: std.mem.Allocator,
        role: Role,
        text: []const u8,
    ) !void {
        const message = try MessageEntry.init(allocator, role, text);
        errdefer {
            var mutable = message;
            mutable.deinit(allocator);
        }
        const index = for (self.entries.items, 0..) |existing, queued_index| {
            const existing_message = existing.constMessage() orelse continue;
            if (existing_message.role == .queued) break queued_index;
        } else self.entries.items.len;
        try self.entries.insert(allocator, index, .{ .message = message });
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
        try self.entries.items[index].messageValue().?.text.appendSlice(
            allocator,
            text,
        );
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
        try self.entries.items[index].messageValue().?.text.appendSlice(
            allocator,
            text,
        );
    }

    fn startEntry(
        self: *Transcript,
        allocator: std.mem.Allocator,
        role: Role,
    ) !usize {
        const message = try MessageEntry.init(allocator, role, "");
        errdefer {
            var mutable = message;
            mutable.deinit(allocator);
        }
        const index = for (self.entries.items, 0..) |existing, queued_index| {
            const existing_message = existing.constMessage() orelse continue;
            if (existing_message.role == .queued) break queued_index;
        } else self.entries.items.len;
        try self.entries.insert(allocator, index, .{ .message = message });
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
        const message = self.entries.items[index].messageValue().?;
        message.text.clearRetainingCapacity();
        try message.text.appendSlice(allocator, text);
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
        const message = self.entries.items[index].messageValue().?;
        message.text.clearRetainingCapacity();
        try message.text.appendSlice(allocator, text);
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
            const message = entry.constMessage() orelse continue;
            if (message.role == .queued) break index;
        } else return;

        var selected = self.entries.orderedRemove(selected_index);
        selected.message.role = .user;
        self.entries.appendAssumeCapacity(selected);

        var index: usize = 0;
        var remaining = self.entries.items.len;
        while (index < remaining) {
            const message = self.entries.items[index].messageValue() orelse {
                index += 1;
                continue;
            };
            if (message.role != .queued) {
                index += 1;
                continue;
            }
            const queued = self.entries.orderedRemove(index);
            self.entries.appendAssumeCapacity(queued);
            remaining -= 1;
        }
    }

    fn applyToolActivity(
        self: *Transcript,
        allocator: std.mem.Allocator,
        update: *const backend.ToolActivityUpdate,
    ) !void {
        switch (update.*) {
            .started => |*started| {
                if (self.findTool(started.call_id)) |tool| {
                    if (tool.matchesStart(started)) return;
                    return error.ConflictingToolStart;
                }
                self.finishTurn();
                const tool = try ToolEntry.init(
                    allocator,
                    started,
                );
                errdefer {
                    var mutable = tool;
                    mutable.deinit(allocator);
                }
                try self.insertBeforeQueued(
                    allocator,
                    .{ .tool = tool },
                );
            },
            .finished => |*finished| {
                const tool = self.findTool(finished.call_id) orelse
                    return error.UnknownToolCall;
                try tool.finish(allocator, finished);
            },
        }
    }

    fn findTool(
        self: *Transcript,
        call_id: backend.ToolCallId,
    ) ?*ToolEntry {
        for (self.entries.items) |*entry| {
            switch (entry.*) {
                .message => {},
                .tool => |*tool| {
                    if (tool.call_id.eql(call_id)) return tool;
                },
            }
        }
        return null;
    }

    fn insertBeforeQueued(
        self: *Transcript,
        allocator: std.mem.Allocator,
        entry: Entry,
    ) !void {
        const index = for (self.entries.items, 0..) |existing, queued_index| {
            const message = existing.constMessage() orelse continue;
            if (message.role == .queued) break queued_index;
        } else self.entries.items.len;
        try self.entries.insert(allocator, index, entry);
    }

    fn messageAt(self: *const Transcript, index: usize) *const MessageEntry {
        return self.entries.items[index].constMessage().?;
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
    resuming,
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
            .resuming => "Resuming session...",
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

    fn contains(self: Region, col: i16, row: i16) bool {
        if (col < 0 or row < 0) return false;
        const x: usize = @intCast(col);
        const y: usize = @intCast(row);
        return x >= self.x and
            x < @as(usize, self.x) + self.width and
            y >= self.y and
            y < @as(usize, self.y) + self.height;
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
    markdown,
    status,
    tool,
    tool_input_label,
    tool_input,
    tool_output_label,
    tool_output,
};

const RenderLine = struct {
    kind: LineKind,
    entry_index: usize,
    start: usize = 0,
    end: usize = 0,
};

const Projection = struct {
    lines: std.ArrayList(RenderLine) = .empty,
    markdown_lines: std.ArrayList(markdown.Line) = .empty,

    fn deinit(self: *Projection, allocator: std.mem.Allocator) void {
        for (self.markdown_lines.items) |*line| line.deinit(allocator);
        self.markdown_lines.deinit(allocator);
        self.lines.deinit(allocator);
        self.* = undefined;
    }

    fn build(
        allocator: std.mem.Allocator,
        transcript: *Transcript,
        window: vaxis.Window,
    ) !Projection {
        var projection: Projection = .{};
        errdefer projection.deinit(allocator);

        for (transcript.entries.items, 0..) |*entry, entry_index| {
            if (projection.lines.items.len > 0) {
                try projection.lines.append(allocator, .{
                    .kind = .blank,
                    .entry_index = entry_index,
                });
            }
            switch (entry.*) {
                .message => |*message| switch (message.role) {
                    .reasoning, .assistant => {
                        try projection.lines.append(allocator, .{
                            .kind = .role,
                            .entry_index = entry_index,
                        });
                        var layout = try markdown.Layout.init(
                            allocator,
                            message.text.items,
                            window,
                            @max(window.width -| 2, 1),
                        );
                        defer layout.deinit();
                        for (layout.lines.items) |*line| {
                            const markdown_index =
                                projection.markdown_lines.items.len;
                            try projection.markdown_lines.append(
                                allocator,
                                line.*,
                            );
                            line.* = .{};
                            try projection.lines.append(allocator, .{
                                .kind = .markdown,
                                .entry_index = entry_index,
                                .start = markdown_index,
                            });
                        }
                        layout.lines.clearRetainingCapacity();
                    },
                    .user, .queued, .question => {
                        try projection.lines.append(allocator, .{
                            .kind = .role,
                            .entry_index = entry_index,
                        });
                        try projection.appendWrapped(
                            allocator,
                            entry_index,
                            message.text.items,
                            window,
                            .body,
                            2,
                        );
                    },
                    .status => try projection.appendWrapped(
                        allocator,
                        entry_index,
                        message.text.items,
                        window,
                        .status,
                        2,
                    ),
                },
                .tool => |*tool| {
                    try projection.appendWrapped(
                        allocator,
                        entry_index,
                        tool.compact,
                        window,
                        .tool,
                        4,
                    );
                    if (tool.expanded) {
                        try tool.ensureOutputHighlights(allocator);
                        try projection.lines.append(allocator, .{
                            .kind = .tool_input_label,
                            .entry_index = entry_index,
                        });
                        try projection.appendWrapped(allocator, entry_index, tool.input_display, window, .tool_input, 4);
                        try projection.lines.append(allocator, .{
                            .kind = .tool_output_label,
                            .entry_index = entry_index,
                        });
                        try projection.appendWrapped(allocator, entry_index, tool.output_display orelse "Running…", window, .tool_output, 4);
                    }
                },
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

const mouse_wheel_rows: usize = 3;

const MenuDetail = union(enum) {
    text: []const u8,
    model: struct {
        context_tokens: u64,
        output_tokens: u64,
        supports_vision: bool,
    },
    session: struct {
        model_id: []const u8,
        last_used_unix_ms: i64,
    },
};

const MenuIdentity = union(enum) {
    text: []const u8,
    number: u64,

    fn eql(left: MenuIdentity, right: MenuIdentity) bool {
        return switch (left) {
            .text => |value| switch (right) {
                .text => |other| std.mem.eql(u8, value, other),
                .number => false,
            },
            .number => |value| switch (right) {
                .text => false,
                .number => |other| value == other,
            },
        };
    }
};

const MenuEntry = struct {
    identity: MenuIdentity,
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
        const previous_identity = if (self.selected()) |entry|
            entry.identity
        else
            null;
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
        if (previous_identity) |identity| {
            for (self.matches.items, 0..) |entry_index, match_index| {
                if (self.entries.items[entry_index].identity.eql(identity)) {
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
            .session => |session| asciiContainsIgnoreCase(
                session.model_id,
                query,
            ),
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

fn uniqueWorkspaceLabel(
    sessions: []const backend.SessionSummary,
    session_index: usize,
) []const u8 {
    const path = sessions[session_index].working_directory;
    var start = path.len - std.fs.path.basename(path).len;
    while (true) {
        const candidate = path[start..];
        var collision = false;
        for (sessions, 0..) |other, other_index| {
            if (other_index == session_index) continue;
            if (pathEndsWithComponent(other.working_directory, candidate)) {
                collision = true;
                break;
            }
        }
        if (!collision or start == 0) return candidate;
        start = previousPathComponentStart(path, start);
    }
}

fn pathEndsWithComponent(path: []const u8, suffix: []const u8) bool {
    if (!std.mem.endsWith(u8, path, suffix)) return false;
    if (path.len == suffix.len) return true;
    return isPathSeparator(path[path.len - suffix.len - 1]);
}

fn previousPathComponentStart(path: []const u8, current_start: usize) usize {
    var end = current_start;
    while (end > 0 and isPathSeparator(path[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !isPathSeparator(path[start - 1])) start -= 1;
    return start;
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
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
    loading_sessions,
    sessions,
};

const ChatUi = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    input: TextInput,
    transcript: Transcript = .{},
    cwd: []u8,
    phase: UiPhase = .connecting,
    commands: ?backend.CommandCatalog = null,
    models: ?backend.ModelCatalog = null,
    sessions: ?backend.SessionCatalog = null,
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
    last_transcript_region: Region = .{},
    tool_hits: std.ArrayList(?usize) = .empty,
    tool_anchor: ?struct { entry_index: usize, row: usize } = null,
    // Borrowed from the transcript; call IDs survive entry insertion and growth.
    focused_tool: ?[]const u8 = null,
    reveal_tool_focus: bool = false,

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
            .io = io,
            .input = TextInput.init(allocator),
            .cwd = cwd,
        };
    }

    fn deinit(self: *ChatUi) void {
        self.tool_hits.deinit(self.allocator);
        self.menu.deinit(self.allocator);
        if (self.saved_input) |*input| input.deinit();
        if (self.pending_user_input) |*request| request.deinit();
        if (self.models) |*catalog| catalog.deinit();
        if (self.sessions) |*catalog| catalog.deinit();
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
            self.clearToolFocus();
            if (key.matches(vaxis.Key.escape, .{})) {
                self.menu_mode = .closed;
                self.dismissed_revision = self.input_revision;
                return .keep_running;
            }
            if (self.menu_mode != .loading_models and
                self.menu_mode != .loading_sessions and
                key.matches(vaxis.Key.up, .{}))
            {
                self.menu.move(.previous);
                return .keep_running;
            }
            if (self.menu_mode != .loading_models and
                self.menu_mode != .loading_sessions and
                key.matches(vaxis.Key.down, .{}))
            {
                self.menu.move(.next);
                return .keep_running;
            }
            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.phase != .ready or
                    self.menu_mode == .loading_models or
                    self.menu_mode == .loading_sessions)
                {
                    return .keep_running;
                }
                try self.activateMenu(conversation);
                return .keep_running;
            }
        }
        if (self.phase == .awaiting_input) {
            self.clearToolFocus();
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
        if (self.phase != .ready and
            self.phase != .responding and
            self.phase != .loading_commands)
        {
            return .keep_running;
        }

        if (self.handleToolKey(key)) return .keep_running;

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
        if (self.phase == .ready or self.phase == .loading_commands) {
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

    fn clearToolFocus(self: *ChatUi) void {
        self.focused_tool = null;
        self.reveal_tool_focus = false;
    }

    fn focusedToolIndex(self: *const ChatUi) ?usize {
        const call_id = self.focused_tool orelse return null;
        for (self.transcript.entries.items, 0..) |entry, index| {
            if (entry == .tool and std.mem.eql(u8, entry.tool.call_id.bytes, call_id))
                return index;
        }
        return null;
    }

    fn focusTool(self: *ChatUi, index: usize) void {
        self.focused_tool = self.transcript.entries.items[index].tool.call_id.bytes;
        self.reveal_tool_focus = true;
    }

    fn handleToolKey(self: *ChatUi, key: vaxis.Key) bool {
        if (self.menu_mode != .closed or
            (self.phase != .ready and self.phase != .responding and self.phase != .loading_commands))
            return false;
        const focused = self.focusedToolIndex();
        if (key.matches(vaxis.Key.f6, .{})) {
            if (focused != null) {
                self.clearToolFocus();
            } else {
                for (self.tool_hits.items) |hit| {
                    if (hit) |index| {
                        self.focusTool(index);
                        return true;
                    }
                }
                for (self.transcript.entries.items, 0..) |entry, index| {
                    if (entry == .tool) {
                        self.focusTool(index);
                        break;
                    }
                }
            }
            return true;
        }
        const index = focused orelse {
            self.clearToolFocus();
            return false;
        };
        if (key.matches(vaxis.Key.escape, .{})) {
            self.clearToolFocus();
        } else if (key.matches(vaxis.Key.up, .{})) {
            var previous = index;
            while (previous > 0) {
                previous -= 1;
                if (self.transcript.entries.items[previous] == .tool) {
                    self.focusTool(previous);
                    break;
                }
            }
            self.reveal_tool_focus = true;
        } else if (key.matches(vaxis.Key.down, .{})) {
            for (index + 1..self.transcript.entries.items.len) |next| {
                if (self.transcript.entries.items[next] == .tool) {
                    self.focusTool(next);
                    break;
                }
            }
            self.reveal_tool_focus = true;
        } else if (key.matches(vaxis.Key.enter, .{}) or key.matches(' ', .{})) {
            const tool = &self.transcript.entries.items[index].tool;
            tool.expanded = !tool.expanded;
            self.reveal_tool_focus = true;
        }
        return true;
    }

    fn handleMouse(self: *ChatUi, mouse: vaxis.Mouse) bool {
        if (!self.last_transcript_region.contains(mouse.col, mouse.row))
            return false;

        if (mouse.type != .press) return false;
        return switch (mouse.button) {
            .wheel_up => self.scrollUp(mouse_wheel_rows),
            .wheel_down => self.scrollDown(mouse_wheel_rows),
            .left => blk: {
                var row: usize = @as(usize, @intCast(mouse.row)) - self.last_transcript_region.y;
                if (row >= self.tool_hits.items.len) break :blk false;
                const entry_index = self.tool_hits.items[row] orelse break :blk false;
                if (entry_index >= self.transcript.entries.items.len) break :blk false;
                const entry = &self.transcript.entries.items[entry_index];
                if (entry.* != .tool) break :blk false;
                self.clearToolFocus();
                while (row > 0 and self.tool_hits.items[row - 1] == entry_index) row -= 1;
                entry.tool.expanded = !entry.tool.expanded;
                self.tool_anchor = .{ .entry_index = entry_index, .row = row };
                break :blk true;
            },
            else => false,
        };
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
        if (self.menu_mode == .loading_models or
            self.menu_mode == .loading_sessions)
        {
            return;
        }
        if (self.menu_mode == .models) {
            return self.rebuildModelMenu();
        }
        if (self.menu_mode == .sessions) {
            return self.rebuildSessionMenu();
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
                .identity = .{ .text = command.name },
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
                .identity = .{ .text = model.id },
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

    fn rebuildSessionMenu(self: *ChatUi) !void {
        const catalog = self.sessions orelse return;
        const query = try self.input.toOwnedContents(self.allocator);
        defer self.allocator.free(query);
        const entries = try self.allocator.alloc(
            MenuEntry,
            catalog.sessions.len,
        );
        defer self.allocator.free(entries);
        for (catalog.sessions, 0..) |session, index| {
            entries[index] = .{
                .identity = .{ .number = session.key },
                .key = session.working_directory,
                .primary = uniqueWorkspaceLabel(catalog.sessions, index),
                .detail = .{ .session = .{
                    .model_id = session.model_id,
                    .last_used_unix_ms = session.last_used_unix_ms,
                } },
                .current = session.current,
                .enabled = !session.current,
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
                if (std.ascii.eqlIgnoreCase(command.name, "resume")) {
                    self.input.clearRetainingCapacity();
                    self.menu_mode = .loading_sessions;
                    conversation.refreshSessions() catch |err| switch (err) {
                        error.Busy => {
                            self.menu_mode = .closed;
                            return;
                        },
                        else => return err,
                    };
                    self.phase = .resuming;
                    return;
                }
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
            .sessions => {
                const catalog = self.sessions orelse return;
                const target = catalog.sessions[selected.source_index];
                conversation.resumeSession(target.key) catch |err| switch (err) {
                    error.Busy => return,
                    else => return err,
                };
                self.input.clearRetainingCapacity();
                self.menu_mode = .closed;
                self.phase = .resuming;
            },
            .closed, .loading_models, .loading_sessions => {},
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
                self.clearToolFocus();
                self.tool_anchor = null;
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
            .session_catalog => |catalog| {
                if (self.phase == .stopping) {
                    self.menu_mode = .closed;
                    return .keep_running;
                }
                const replacement = try catalog.clone(self.allocator);
                if (self.sessions) |*current| current.deinit();
                self.sessions = replacement;
                self.phase = .ready;
                if (self.menu_mode == .loading_sessions) {
                    self.menu_mode = .sessions;
                    try self.rebuildSessionMenu();
                    if (catalog.skipped_invalid_shards) {
                        try self.transcript.append(
                            self.allocator,
                            .status,
                            "Some saved sessions could not be listed.",
                        );
                    }
                }
            },
            .session_catalog_failed => |failure| {
                if (self.phase == .stopping) {
                    self.menu_mode = .closed;
                    return .keep_running;
                }
                self.phase = .ready;
                self.menu_mode = .closed;
                try self.transcript.append(
                    self.allocator,
                    .status,
                    failure.bytes,
                );
            },
            .session_tracking_failed => |failure| {
                try self.transcript.append(
                    self.allocator,
                    .status,
                    failure.bytes,
                );
            },
            .session_resume => |result| {
                self.clearToolFocus();
                self.tool_anchor = null;
                if (self.phase == .resuming) self.phase = .ready;
                self.menu_mode = .closed;
                switch (result) {
                    .resumed => |success| {
                        const resumed_cwd = try self.allocator.dupe(
                            u8,
                            success.session.working_directory,
                        );
                        self.allocator.free(self.cwd);
                        self.cwd = resumed_cwd;
                        try self.updateSelectedModel(success.session.model_id);
                        const message = try std.fmt.allocPrint(
                            self.allocator,
                            "Resumed {s}. Copilot history now comes from that session; the visible Vivi transcript remains.{s}",
                            .{
                                success.session.working_directory,
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
            .tool_activity => |*update| {
                try self.transcript.applyToolActivity(
                    self.allocator,
                    update,
                );
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

    fn draw(self: *ChatUi, root: vaxis.Window) !?Projection {
        var projection: ?Projection = null;
        errdefer if (projection) |*value| value.deinit(self.allocator);

        const desired_menu_rows: u16 = if (self.phase == .awaiting_input)
            self.userInputPanelRows(root)
        else switch (self.menu_mode) {
            .commands, .models, .sessions => @intCast(@min(
                @max(self.menu.matches.items.len, 1),
                8,
            )),
            .closed, .loading_models, .loading_sessions => 0,
        };
        const layout = FrameLayout.compute(
            root.width,
            root.height,
            desired_menu_rows,
        );
        self.last_transcript_region = layout.transcript;
        self.tool_hits.clearRetainingCapacity();
        if (layout.transcript.height > 0) {
            const transcript_window = layout.transcript.child(root);
            if (self.transcript.entries.items.len == 0) {
                self.drawWelcome(transcript_window);
                self.last_total_rows = 0;
                self.last_viewport_rows = transcript_window.height;
            } else {
                projection = try Projection.build(
                    self.allocator,
                    &self.transcript,
                    transcript_window,
                );
                try self.drawTranscript(transcript_window, &projection.?);
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
        return projection;
    }

    fn drawMenu(self: *ChatUi, window: vaxis.Window) void {
        window.fill(.{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = .{ .bg = menu_background },
        });
        if (self.menu.matches.items.len == 0) {
            const text = if (self.menu_mode == .sessions)
                sessionMenuEmptyMessage(blk: {
                    const catalog = self.sessions orelse break :blk false;
                    for (catalog.sessions) |session| {
                        if (!session.current) break :blk true;
                    }
                    break :blk false;
                })
            else
                "No matches.";
            var segments = [_]vaxis.Segment{.{
                .text = text,
                .style = .{
                    .bg = menu_background,
                    .dim = true,
                },
            }};
            _ = window.print(&segments, .{
                .row_offset = 0,
                .col_offset = 2,
                .wrap = .none,
            });
            return;
        }
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

    fn sessionMenuEmptyMessage(has_resumable_sessions: bool) []const u8 {
        return if (has_resumable_sessions)
            "No matching sessions."
        else
            "No resumable sessions yet.";
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
            .session => |session| {
                var age_buffer: [24]u8 = undefined;
                const age_ms = @max(
                    @as(i64, 0),
                    std.Io.Timestamp.now(self.io, .real).toMilliseconds() -
                        session.last_used_unix_ms,
                );
                const age = if (age_ms < 60 * 1000)
                    "now"
                else if (age_ms < 60 * 60 * 1000)
                    std.fmt.bufPrint(
                        &age_buffer,
                        "{d}m ago",
                        .{@divTrunc(age_ms, 60 * 1000)},
                    ) catch "recently"
                else if (age_ms < 24 * 60 * 60 * 1000)
                    std.fmt.bufPrint(
                        &age_buffer,
                        "{d}h ago",
                        .{@divTrunc(age_ms, 60 * 60 * 1000)},
                    ) catch "earlier"
                else
                    std.fmt.bufPrint(
                        &age_buffer,
                        "{d}d ago",
                        .{@divTrunc(age_ms, 24 * 60 * 60 * 1000)},
                    ) catch "earlier";
                const detail_col = @min(window.width / 2, 36);
                const age_width = window.gwidth(age);
                const separator = " · ";
                const separator_width = window.gwidth(separator);
                const model_width = window.width -| detail_col -|
                    age_width -| separator_width;
                if (model_width > 0) {
                    const model_window = window.child(.{
                        .x_off = @intCast(detail_col),
                        .y_off = @intCast(row),
                        .width = model_width,
                        .height = 1,
                    });
                    var model_segments = [_]vaxis.Segment{.{
                        .text = session.model_id,
                        .style = .{ .bg = style.bg, .dim = true },
                    }};
                    _ = model_window.print(&model_segments, .{ .wrap = .none });
                }
                var trailing_segments = [_]vaxis.Segment{
                    .{
                        .text = separator,
                        .style = .{ .bg = style.bg, .dim = true },
                    },
                    .{
                        .text = age,
                        .style = .{ .bg = style.bg, .dim = true },
                    },
                };
                _ = window.print(&trailing_segments, .{
                    .row_offset = row,
                    .col_offset = detail_col + model_width,
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
    ) !void {
        const total_rows = projection.lines.items.len;
        const viewport_rows: usize = window.height;
        if (self.tool_anchor) |anchor| {
            for (projection.lines.items, 0..) |line, index| {
                if (line.entry_index == anchor.entry_index and line.kind == .tool) {
                    self.rows_from_tail = (total_rows -| viewport_rows) -| (index -| anchor.row);
                    break;
                }
            }
            self.tool_anchor = null;
        } else if (self.rows_from_tail > 0 and total_rows > self.last_total_rows) {
            self.rows_from_tail += total_rows - self.last_total_rows;
        }
        const max_scroll = total_rows -| @min(total_rows, viewport_rows);
        self.rows_from_tail = @min(self.rows_from_tail, max_scroll);
        if (self.reveal_tool_focus) {
            if (self.focusedToolIndex()) |focused| {
                for (projection.lines.items, 0..) |line, index| {
                    if (line.entry_index != focused or line.kind != .tool) continue;
                    const first = max_scroll - self.rows_from_tail;
                    if (index < first) {
                        self.rows_from_tail = max_scroll -| index;
                    } else if (index >= first + viewport_rows) {
                        self.rows_from_tail = max_scroll -| (index + 1 -| viewport_rows);
                    }
                    break;
                }
            }
            self.reveal_tool_focus = false;
        }
        const visible_rows = @min(total_rows, viewport_rows);
        const first_row = total_rows - visible_rows - self.rows_from_tail;
        const last_row = @min(first_row + viewport_rows, total_rows);

        for (projection.lines.items[first_row..last_row], 0..) |line, row| {
            try self.tool_hits.append(self.allocator, switch (line.kind) {
                .tool, .tool_input_label, .tool_input, .tool_output_label, .tool_output => line.entry_index,
                else => null,
            });
            self.drawTranscriptLine(
                window,
                @intCast(row),
                projection,
                line,
            );
        }
        self.last_total_rows = total_rows;
        self.last_viewport_rows = viewport_rows;
    }

    fn drawTranscriptLine(
        self: *ChatUi,
        window: vaxis.Window,
        row: u16,
        projection: *const Projection,
        line: RenderLine,
    ) void {
        const entry = self.transcript.entries.items[line.entry_index];
        switch (line.kind) {
            .blank => {},
            .role => {
                const message = entry.constMessage().?;
                const role_text = switch (message.role) {
                    .user => "You",
                    .queued => "Queued",
                    .reasoning => "Thinking",
                    .assistant => "Vivi",
                    .question => "Question",
                    .status => unreachable,
                };
                const role_color = switch (message.role) {
                    .user => user_color,
                    .queued => accent,
                    .reasoning => reasoning_color,
                    .assistant => assistant_color,
                    .question => accent,
                    .status => unreachable,
                };
                var segments = [_]vaxis.Segment{.{
                    .text = role_text,
                    .style = if (message.role == .reasoning)
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
                const message = entry.constMessage().?;
                var segments = [_]vaxis.Segment{.{
                    .text = message.text.items[line.start..line.end],
                    .style = if (message.role == .reasoning)
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
            .markdown => {
                const message = entry.constMessage().?;
                const base_style: vaxis.Style =
                    if (message.role == .reasoning)
                        .{
                            .fg = reasoning_color,
                            .dim = true,
                            .italic = true,
                        }
                    else
                        .{};
                const markdown_line = projection.markdown_lines.items[line.start];
                var column: u16 = if (window.width >= 4) 2 else 0;
                for (markdown_line.segments.items) |segment| {
                    var segments = [_]vaxis.Segment{.{
                        .text = segment.text,
                        .style = markdown.combineStyle(
                            base_style,
                            segment.style,
                        ),
                        .link = if (segment.uri) |uri|
                            .{ .uri = uri }
                        else
                            .{},
                    }};
                    _ = window.print(&segments, .{
                        .row_offset = row,
                        .col_offset = column,
                        .wrap = .none,
                    });
                    column +|= window.gwidth(segment.text);
                }
            },
            .status => {
                const message = entry.constMessage().?;
                var segments = [_]vaxis.Segment{
                    .{
                        .text = "• ",
                        .style = .{ .fg = accent, .dim = true },
                    },
                    .{
                        .text = message.text.items[line.start..line.end],
                        .style = .{ .dim = true },
                    },
                };
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .wrap = .none,
                });
            },
            .tool => {
                const tool = &entry.tool;
                const focused = self.focusedToolIndex() == line.entry_index;
                const color = if (tool.completion) |completion|
                    switch (completion) {
                        .succeeded => accent,
                        .failed => vaxis.Color{ .index = 203 },
                    }
                else
                    reasoning_color;
                var segments = [_]vaxis.Segment{.{
                    .text = tool.compact[line.start..line.end],
                    .style = .{ .fg = color, .dim = !focused, .bold = focused, .reverse = focused },
                }};
                _ = window.print(&segments, .{
                    .row_offset = row,
                    .col_offset = @min(window.width -| 1, 4),
                    .wrap = .none,
                });
                if (line.start == 0) {
                    if (focused) {
                        var marker = [_]vaxis.Segment{.{
                            .text = ">",
                            .style = .{ .fg = accent, .bold = true },
                        }};
                        _ = window.print(&marker, .{ .row_offset = row, .wrap = .none });
                    }
                    var disclosure = [_]vaxis.Segment{.{
                        .text = if (tool.expanded) "▾" else "▸",
                        .style = .{ .fg = color },
                    }};
                    _ = window.print(&disclosure, .{
                        .row_offset = row,
                        .col_offset = if (window.width >= 4) 2 else 0,
                        .wrap = .none,
                    });
                }
            },
            .tool_input_label, .tool_output_label, .tool_input, .tool_output => {
                window.child(.{ .y_off = row, .height = 1 }).fill(.{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = tool_detail_background },
                });
                const tool = &entry.tool;
                const label = line.kind == .tool_input_label or line.kind == .tool_output_label;
                const output: []const u8 = tool.output_display orelse "Running…";
                const text = switch (line.kind) {
                    .tool_input_label => "Input",
                    .tool_output_label => if (tool.completion) |completion| switch (completion) {
                        .succeeded => "Output",
                        .failed => "Output (failed)",
                    } else "Output (running)",
                    .tool_input => tool.input_display[line.start..line.end],
                    .tool_output => output[line.start..line.end],
                    else => unreachable,
                };
                var segments = [_]vaxis.Segment{.{
                    .text = text,
                    .style = .{ .bold = label, .fg = reasoning_color, .bg = tool_detail_background },
                }};
                if (label) {
                    _ = window.print(&segments, .{
                        .row_offset = row,
                        .col_offset = @min(window.width -| 1, 4),
                        .wrap = .none,
                    });
                } else {
                    const highlights = if (line.kind == .tool_input)
                        tool.input_highlights
                    else
                        tool.output_highlights orelse &.{};
                    drawHighlightedRange(
                        window,
                        row,
                        @min(window.width -| 1, 4),
                        if (line.kind == .tool_input) tool.input_display else output,
                        line.start,
                        line.end,
                        highlights,
                        .{ .fg = reasoning_color, .bg = tool_detail_background },
                    );
                }
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
            if (self.focused_tool != null) content.hideCursor();
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
        const hints = if (self.focused_tool != null)
            if (window.width >= 44)
                "↑/↓ tools · Enter/Space toggle · Esc compose"
            else
                "↑/↓ · Enter · Esc input"
        else if (window.width >= 48)
            switch (self.phase) {
                .ready => "Enter send · F6 tools · Wheel/PgUp/PgDn scroll · Ctrl-C quit",
                .responding => "Enter steer · F6 tools · Ctrl+Enter queue · PgUp/PgDn scroll · Ctrl-C stop",
                .awaiting_input => if (self.hasInputChoices())
                    if (self.hasFreeformChoice())
                        "↑/↓ select  ·  Enter accept  ·  type for other  ·  Ctrl-C stop"
                    else
                        "↑/↓ select  ·  Enter accept  ·  Ctrl-C stop"
                else
                    "Enter answer  ·  Wheel/PgUp/PgDn scroll  ·  Ctrl-C stop",
                .connecting, .loading_commands, .running_command, .switching, .resuming => "Wheel/PgUp/PgDn scroll  ·  Ctrl-C stop",
                .stopping => "Ctrl-C again force exit",
            }
        else if (window.width >= 24)
            switch (self.phase) {
                .ready => "Enter send · F6 tools",
                .responding => "Enter steer · F6 tools",
                .awaiting_input => if (self.hasInputChoices())
                    "↑/↓ select  ·  Enter accept"
                else
                    "Enter answer  ·  Ctrl-C stop",
                .connecting, .loading_commands, .running_command, .switching, .resuming => "Ctrl-C stop",
                .stopping => "Ctrl-C again force exit",
            }
        else switch (self.phase) {
            .ready => "Ctrl-C quit",
            .responding => "Enter steer",
            .awaiting_input => if (self.hasInputChoices())
                "Enter choice"
            else
                "Enter answer",
            .connecting, .loading_commands, .running_command, .switching, .resuming => "Ctrl-C stop",
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
        _ = self.scrollUp(page_rows);
    }

    fn pageDown(self: *ChatUi) void {
        const page_rows = @max(self.last_viewport_rows -| 1, 1);
        _ = self.scrollDown(page_rows);
    }

    fn scrollUp(self: *ChatUi, rows: usize) bool {
        const previous = self.rows_from_tail;
        const max_scroll = self.last_total_rows -|
            @min(self.last_total_rows, self.last_viewport_rows);
        self.rows_from_tail = @min(
            self.rows_from_tail + rows,
            max_scroll,
        );
        return self.rows_from_tail != previous;
    }

    fn scrollDown(self: *ChatUi, rows: usize) bool {
        const previous = self.rows_from_tail;
        self.rows_from_tail -|= rows;
        return self.rows_from_tail != previous;
    }

    fn followTail(self: *ChatUi) void {
        self.clearToolFocus();
        self.rows_from_tail = 0;
    }
};

fn handleMouseBatch(
    ui: *ChatUi,
    loop: *vaxis.Loop(AppEvent),
    first: vaxis.Mouse,
) !struct { redraw: bool, next: ?AppEvent = null } {
    var redraw = ui.handleMouse(first);
    if (!isMouseWheel(first)) return .{ .redraw = redraw };

    // Bound each batch so continuous wheel input cannot starve rendering or backend events.
    for (1..512) |_| {
        const event = try loop.tryEvent() orelse break;
        if (event != .mouse or !isMouseWheel(event.mouse))
            return .{ .redraw = redraw, .next = event };
        redraw = ui.handleMouse(event.mouse) or redraw;
    }
    return .{ .redraw = redraw };
}

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
        sessions_directory: ?[]const u8,
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
                .sessions_directory = sessions_directory,
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
        try self.vx.setMouseMode(self.tty.writer(), true);
        const use_signal_resize = !self.vx.state.in_band_resize;
        if (use_signal_resize) try self.loop.installResizeHandler();
        defer if (use_signal_resize) self.loop.uninstallResizeHandler();
        try self.render();

        var pending: ?AppEvent = null;
        while (!self.closed) {
            const event = pending orelse try self.loop.nextEvent();
            pending = null;
            var redraw = true;
            switch (event) {
                .key_press => |key| switch (try self.ui.handleKey(key, &self.conversation)) {
                    .keep_running => {},
                    .force_exit => self.hardExit(),
                },
                .mouse => |mouse| {
                    const batch = try handleMouseBatch(&self.ui, &self.loop, mouse);
                    redraw = batch.redraw;
                    pending = batch.next;
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
            const conversation_changed = try self.drainConversation();
            if (!self.closed and (redraw or conversation_changed))
                try self.render();
        }
    }

    fn drainConversation(self: *App) !bool {
        var changed = false;
        while (try self.conversation.tryTakeEvent()) |event_value| {
            changed = true;
            var event = event_value;
            defer event.deinit();
            if (try self.ui.applyConversationEvent(&event) == .close) {
                self.closed = true;
            }
        }
        return changed;
    }

    fn render(self: *App) !void {
        const root = self.vx.window();
        root.clear();
        var projection = try self.ui.draw(root);
        defer if (projection) |*value| value.deinit(self.allocator);
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
    sessions_directory: ?[]const u8,
) !void {
    const app = try init.gpa.create(App);
    defer init.gpa.destroy(app);
    try app.init(init, model, settings_path, sessions_directory);
    defer app.deinit();
    try app.run();
}

fn toolStarted(
    call_id: []const u8,
    arguments_json: []const u8,
    summary: backend.ToolSummary,
) !backend.ToolStarted {
    return backend.ToolStarted.init(
        std.testing.allocator,
        call_id,
        arguments_json,
        summary,
    );
}

fn toolFinished(
    call_id: []const u8,
    result: union(enum) {
        succeeded: []const u8,
        failed: []const u8,
    },
) !backend.ToolFinished {
    return switch (result) {
        .succeeded => |value| backend.ToolFinished.init(
            std.testing.allocator,
            call_id,
            .{ .succeeded = value },
        ),
        .failed => |value| backend.ToolFinished.init(
            std.testing.allocator,
            call_id,
            .{ .failed = value },
        ),
    };
}

test "tool details highlight shell input and supported read output" {
    var bash_started = try toolStarted(
        "bash-highlight",
        "{\"command\":\"printf '%s\\\\n' ready\"}",
        .{ .bash = .{ .command = "printf '%s\\n' ready" } },
    );
    defer bash_started.deinit();
    var bash_entry = try ToolEntry.init(std.testing.allocator, &bash_started);
    defer bash_entry.deinit(std.testing.allocator);
    try std.testing.expect(bash_entry.input_highlights.len > 0);
    const command_name = bash_entry.input_highlights[0];
    try std.testing.expectEqualStrings(
        "printf",
        bash_entry.input_display[command_name.start..command_name.end],
    );

    var read_started = try toolStarted(
        "read-highlight",
        "{\"path\":\"sample.zig\"}",
        .{ .read = .{
            .path = "sample.zig",
            .offset = null,
            .limit = null,
        } },
    );
    defer read_started.deinit();
    var read_entry = try ToolEntry.init(std.testing.allocator, &read_started);
    defer read_entry.deinit(std.testing.allocator);
    var finished = try toolFinished(
        "read-highlight",
        .{ .succeeded = "const answer = 42;" },
    );
    defer finished.deinit();
    try read_entry.finish(std.testing.allocator, &finished);
    try std.testing.expect(read_entry.output_highlights == null);
    try read_entry.ensureOutputHighlights(std.testing.allocator);
    try std.testing.expect(read_entry.output_highlights.?.len > 0);
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
        transcript.messageAt(0).text.items,
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
        transcript.messageAt(0).text.items,
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
        transcript.messageAt(0).text.items,
    );
    try std.testing.expectEqualStrings(
        "queued",
        transcript.messageAt(1).text.items,
    );
    try std.testing.expectEqualStrings(
        "second",
        transcript.messageAt(2).text.items,
    );
}

test "queued prompts are promoted in FIFO order" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.append(std.testing.allocator, .queued, "first");
    try transcript.append(std.testing.allocator, .queued, "second");

    transcript.promoteNextQueuedPrompt();
    try std.testing.expectEqual(Role.user, transcript.messageAt(0).role);
    try std.testing.expectEqual(Role.queued, transcript.messageAt(1).role);

    transcript.promoteNextQueuedPrompt();
    try std.testing.expectEqual(Role.user, transcript.messageAt(1).role);
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
        transcript.messageAt(1).text.items,
    );
    try std.testing.expectEqual(Role.user, transcript.messageAt(2).role);
    try std.testing.expectEqualStrings(
        "queued prompt",
        transcript.messageAt(2).text.items,
    );
}

test "response arriving after queue submission is inserted before the queue" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.append(std.testing.allocator, .user, "first prompt");
    try transcript.append(std.testing.allocator, .queued, "queued prompt");
    try transcript.appendDelta(std.testing.allocator, "first response");

    try std.testing.expectEqual(3, transcript.entries.items.len);
    try std.testing.expectEqual(Role.assistant, transcript.messageAt(1).role);
    try std.testing.expectEqualStrings(
        "first response",
        transcript.messageAt(1).text.items,
    );
    try std.testing.expectEqual(Role.queued, transcript.messageAt(2).role);
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
    try std.testing.expectEqual(Role.reasoning, transcript.messageAt(1).role);
    try std.testing.expectEqualStrings(
        "thought through",
        transcript.messageAt(1).text.items,
    );
    try std.testing.expectEqual(Role.assistant, transcript.messageAt(2).role);
    try std.testing.expectEqualStrings(
        "first response",
        transcript.messageAt(2).text.items,
    );
    try std.testing.expectEqual(Role.user, transcript.messageAt(3).role);
    try std.testing.expectEqualStrings(
        "queued prompt",
        transcript.messageAt(3).text.items,
    );
    try std.testing.expectEqual(Role.assistant, transcript.messageAt(4).role);
    try std.testing.expectEqualStrings(
        "queued response",
        transcript.messageAt(4).text.items,
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
    try std.testing.expectEqual(Role.reasoning, transcript.messageAt(0).role);
    try std.testing.expectEqual(Role.question, transcript.messageAt(1).role);
    try std.testing.expectEqual(Role.user, transcript.messageAt(2).role);
    try std.testing.expectEqual(Role.assistant, transcript.messageAt(3).role);
    try std.testing.expectEqual(Role.queued, transcript.messageAt(4).role);
    try std.testing.expectEqualStrings(
        "after answer",
        transcript.messageAt(3).text.items,
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
    try std.testing.expectEqual(Role.reasoning, transcript.messageAt(0).role);
    try std.testing.expectEqualStrings(
        "complete thought",
        transcript.messageAt(0).text.items,
    );
    try std.testing.expectEqual(Role.assistant, transcript.messageAt(1).role);
    try std.testing.expectEqualStrings(
        "answer!",
        transcript.messageAt(1).text.items,
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

test "tool completions update interleaved rows in reverse order" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    var first = try toolStarted(
        "call-1",
        "{\"path\":\"one\"}",
        .{ .read = .{ .path = "one", .offset = null, .limit = null } },
    );
    defer first.deinit();
    var second = try toolStarted(
        "call-2",
        "{\"command\":\"two\"}",
        .{ .bash = .{ .command = "two" } },
    );
    defer second.deinit();
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = first },
    );
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = second },
    );

    var second_finished = try toolFinished(
        "call-2",
        .{ .succeeded = "second" },
    );
    defer second_finished.deinit();
    var first_finished = try toolFinished(
        "call-1",
        .{ .failed = "first" },
    );
    defer first_finished.deinit();
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .finished = second_finished },
    );
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .finished = first_finished },
    );

    try std.testing.expectEqual(@as(usize, 2), transcript.entries.items.len);
    try std.testing.expectEqualStrings(
        "call-1",
        transcript.entries.items[0].tool.call_id.bytes,
    );
    try std.testing.expect(
        transcript.entries.items[0].tool.completion.? == .failed,
    );
    try std.testing.expectEqualStrings(
        "call-2",
        transcript.entries.items[1].tool.call_id.bytes,
    );
    try std.testing.expect(
        transcript.entries.items[1].tool.completion.? == .succeeded,
    );
}

test "equal tool updates are idempotent and conflicts fail" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    var started = try toolStarted(
        "call-1",
        "{\"path\":\"one\"}",
        .{ .read = .{ .path = "one", .offset = null, .limit = null } },
    );
    defer started.deinit();
    var duplicate = try toolStarted(
        "call-1",
        "{\"path\":\"one\"}",
        .{ .read = .{ .path = "one", .offset = null, .limit = null } },
    );
    defer duplicate.deinit();
    var conflict = try toolStarted(
        "call-1",
        "{\"path\":\"two\"}",
        .{ .read = .{ .path = "two", .offset = null, .limit = null } },
    );
    defer conflict.deinit();

    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = started },
    );
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = duplicate },
    );
    try std.testing.expectEqual(@as(usize, 1), transcript.entries.items.len);
    try std.testing.expectError(
        error.ConflictingToolStart,
        transcript.applyToolActivity(
            std.testing.allocator,
            &.{ .started = conflict },
        ),
    );

    var finished = try toolFinished("call-1", .{ .succeeded = "ok" });
    defer finished.deinit();
    var finished_duplicate = try toolFinished(
        "call-1",
        .{ .succeeded = "ok" },
    );
    defer finished_duplicate.deinit();
    var finished_conflict = try toolFinished(
        "call-1",
        .{ .failed = "no" },
    );
    defer finished_conflict.deinit();
    var unknown = try toolFinished("missing", .{ .succeeded = "ok" });
    defer unknown.deinit();
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .finished = finished },
    );
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .finished = finished_duplicate },
    );
    try std.testing.expectError(
        error.ConflictingToolCompletion,
        transcript.applyToolActivity(
            std.testing.allocator,
            &.{ .finished = finished_conflict },
        ),
    );
    try std.testing.expectError(
        error.UnknownToolCall,
        transcript.applyToolActivity(
            std.testing.allocator,
            &.{ .finished = unknown },
        ),
    );
}

test "fallback tool names are part of duplicate start identity" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    var search = try toolStarted(
        "call-1",
        "{}",
        .{ .other = .{ .name = "search" } },
    );
    defer search.deinit();
    var fetch = try toolStarted(
        "call-1",
        "{}",
        .{ .other = .{ .name = "fetch" } },
    );
    defer fetch.deinit();

    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = search },
    );
    try std.testing.expectError(
        error.ConflictingToolStart,
        transcript.applyToolActivity(
            std.testing.allocator,
            &.{ .started = fetch },
        ),
    );
}

test "tool row preserves queued ordering and splits assistant output" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    try transcript.append(std.testing.allocator, .queued, "later");
    try transcript.appendDelta(std.testing.allocator, "before");
    var started = try toolStarted(
        "call-1",
        "{\"command\":\"true\"}",
        .{ .bash = .{ .command = "true" } },
    );
    defer started.deinit();
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = started },
    );
    try transcript.appendDelta(std.testing.allocator, "after");

    try std.testing.expectEqual(@as(usize, 4), transcript.entries.items.len);
    try std.testing.expectEqualStrings("before", transcript.messageAt(0).text.items);
    try std.testing.expect(transcript.entries.items[1] == .tool);
    try std.testing.expectEqualStrings("after", transcript.messageAt(2).text.items);
    try std.testing.expectEqual(Role.queued, transcript.messageAt(3).role);
}

test "compact tool rows wrap by grapheme width with one entry index" {
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);
    var started = try toolStarted(
        "call-1",
        "{\"command\":\"printf αβγδεζηθ\"}",
        .{ .bash = .{ .command = "printf αβγδεζηθ" } },
    );
    defer started.deinit();
    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = started },
    );
    var screen: vaxis.Screen = .{ .width_method = .unicode };
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 10,
        .height = 20,
        .screen = &screen,
    };
    var projection = try Projection.build(
        std.testing.allocator,
        &transcript,
        window,
    );
    defer projection.deinit(std.testing.allocator);

    try std.testing.expect(projection.lines.items.len > 1);
    for (projection.lines.items) |line| {
        try std.testing.expectEqual(LineKind.tool, line.kind);
        try std.testing.expectEqual(@as(usize, 0), line.entry_index);
        try std.testing.expect(std.unicode.utf8ValidateSlice(
            transcript.entries.items[0].tool.compact[line.start..line.end],
        ));
    }
}

test "tool entries retain full owned payloads with bounded compact summaries" {
    const command = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(command);
    @memset(command, 'a');
    const arguments = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"command\":\"{s}\"}}",
        .{command},
    );
    defer std.testing.allocator.free(arguments);
    var started = try toolStarted(
        "call-1",
        arguments,
        .{ .bash = .{ .command = command } },
    );
    defer started.deinit();
    var transcript: Transcript = .{};
    defer transcript.deinit(std.testing.allocator);

    try transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = started },
    );

    const tool = transcript.entries.items[0].tool;
    try std.testing.expect(tool.compact.len < 256);
    try std.testing.expect(!tool.expanded);
    try std.testing.expectEqualStrings(arguments, tool.input);
    try std.testing.expect(std.mem.startsWith(u8, tool.input_display, "Command: "));
    try std.testing.expectEqualStrings(command, tool.input_display["Command: ".len..]);
    try std.testing.expectEqual(
        @as(usize, std.crypto.hash.sha2.Sha256.digest_length),
        tool.invocation_hash.len,
    );
    var finished = try backend.ToolFinished.init(
        std.testing.allocator,
        "call-1",
        .{ .succeeded = command },
    );
    try transcript.applyToolActivity(std.testing.allocator, &.{ .finished = finished });
    finished.deinit();
    try std.testing.expectEqualStrings(command, transcript.entries.items[0].tool.output.?);
    try std.testing.expectEqualStrings(command, transcript.entries.items[0].tool.output_display.?);
}

fn toolAllocationLifecycle(allocator: std.mem.Allocator) !void {
    var started = try toolStarted("allocation", "{\"path\":\"file\"}", .{
        .read = .{ .path = "file", .offset = null, .limit = null },
    });
    defer started.deinit();
    var tool = try ToolEntry.init(allocator, &started);
    defer tool.deinit(allocator);
    var finished = try backend.ToolFinished.init(std.testing.allocator, "allocation", .{
        .succeeded = "output\n\x1b[31m",
    });
    defer finished.deinit();
    tool.expanded = true;
    tool.finish(allocator, &finished) catch |err| {
        try std.testing.expect(tool.completion == null);
        try std.testing.expect(tool.output == null and tool.output_display == null);
        try std.testing.expect(std.mem.startsWith(u8, tool.compact, "◌"));
        return err;
    };
    try std.testing.expect(tool.expanded);
}

test "tool owned payload lifecycle is atomic under allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, toolAllocationLifecycle, .{});
}

test "tool keyboard focus preserves composer and respects menus and pending questions" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .phase = .ready,
    };
    defer ui.deinit();
    var conversation: backend.Conversation = undefined;
    const f6: vaxis.Key = .{ .codepoint = vaxis.Key.f6 };
    _ = try ui.handleKey(f6, &conversation);
    try std.testing.expectEqual(null, ui.focused_tool);
    _ = try ui.handleKey(.{ .codepoint = 'x', .text = "x" }, &conversation);
    var started = try toolStarted("keyboard", "{\"command\":\"pwd\"}", .{ .bash = .{ .command = "pwd" } });
    defer started.deinit();
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .started = started });
    _ = try ui.handleKey(f6, &conversation);
    try std.testing.expectEqual(@as(?usize, 0), ui.focusedToolIndex());
    _ = try ui.handleKey(.{ .codepoint = vaxis.Key.enter }, &conversation);
    try std.testing.expect(ui.transcript.entries.items[0].tool.expanded);
    _ = try ui.handleKey(.{ .codepoint = ' ', .text = " " }, &conversation);
    try std.testing.expect(!ui.transcript.entries.items[0].tool.expanded);
    _ = try ui.handleKey(.{ .codepoint = 'z', .text = "z" }, &conversation);
    _ = try ui.handleKey(.{ .codepoint = vaxis.Key.escape }, &conversation);
    try std.testing.expectEqual(null, ui.focused_tool);
    _ = try ui.handleKey(.{ .codepoint = ' ', .text = " " }, &conversation);
    const draft = try ui.input.toOwnedContents(std.testing.allocator);
    defer std.testing.allocator.free(draft);
    try std.testing.expectEqualStrings("x ", draft);
    ui.menu_mode = .commands;
    try std.testing.expect(!ui.handleToolKey(f6));
    ui.menu_mode = .closed;
    ui.phase = .awaiting_input;
    try std.testing.expect(!ui.handleToolKey(f6));
    ui.phase = .responding;
    _ = try ui.handleKey(f6, &conversation);
    try std.testing.expect(ui.focused_tool != null);
    _ = try ui.handleKey(f6, &conversation);
    try std.testing.expectEqual(null, ui.focused_tool);
    _ = try ui.handleKey(f6, &conversation);
    ui.followTail();
    try std.testing.expectEqual(null, ui.focused_tool);
}

test "tool keyboard navigation reveals focused headers and retains focus through streaming" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .phase = .responding,
    };
    defer ui.deinit();
    var first = try toolStarted("first", "{\"command\":\"pwd\"}", .{ .bash = .{ .command = "pwd" } });
    defer first.deinit();
    var second = try toolStarted("second", "{\"command\":\"ls\"}", .{ .bash = .{ .command = "ls" } });
    defer second.deinit();
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .started = first });
    try ui.transcript.append(std.testing.allocator, .assistant, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .started = second });
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 6,
        .cols = 40,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    var projection = try Projection.build(std.testing.allocator, &ui.transcript, window);
    defer projection.deinit(std.testing.allocator);
    try ui.drawTranscript(window, &projection);
    try std.testing.expect(ui.handleToolKey(.{ .codepoint = vaxis.Key.f6 }));
    try std.testing.expectEqual(@as(?usize, 2), ui.focusedToolIndex());
    try std.testing.expect(ui.handleToolKey(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expectEqual(@as(?usize, 0), ui.focusedToolIndex());
    try ui.drawTranscript(window, &projection);
    try std.testing.expect(ui.rows_from_tail > 0);
    try std.testing.expectEqualStrings(">", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expect(screen.readCell(4, 0).?.style.reverse);
    _ = ui.handleToolKey(.{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqual(@as(?usize, 0), ui.focusedToolIndex());
    _ = ui.handleToolKey(.{ .codepoint = vaxis.Key.down });
    _ = ui.handleToolKey(.{ .codepoint = vaxis.Key.down });
    try std.testing.expectEqual(@as(?usize, 2), ui.focusedToolIndex());
    _ = ui.handleToolKey(.{ .codepoint = vaxis.Key.enter });
    var finished = try toolFinished("second", .{ .succeeded = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight" });
    defer finished.deinit();
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .finished = finished });
    window.width = 24;
    var expanded = try Projection.build(std.testing.allocator, &ui.transcript, window);
    defer expanded.deinit(std.testing.allocator);
    try ui.drawTranscript(window, &expanded);
    try std.testing.expectEqual(@as(?usize, 2), ui.focusedToolIndex());
    try std.testing.expect(ui.transcript.entries.items[2].tool.expanded);
    const first_visible = expanded.lines.items.len - window.height - ui.rows_from_tail;
    const header = for (expanded.lines.items, 0..) |line, index| {
        if (line.entry_index == 2 and line.kind == .tool) break index;
    } else unreachable;
    try std.testing.expect(header >= first_visible and header < first_visible + window.height);
    try std.testing.expect(ui.scrollDown(2));
    const scrolled = ui.rows_from_tail;
    try ui.drawTranscript(window, &expanded);
    try std.testing.expectEqual(scrolled, ui.rows_from_tail);
    var resume_event: backend.ConversationEvent = .{ .session_resume = .{
        .failed = try backend.OwnedText.init(std.testing.allocator, "failed"),
    } };
    defer resume_event.deinit();
    _ = try ui.applyConversationEvent(&resume_event);
    try std.testing.expectEqual(null, ui.focused_tool);
}

test "tool disclosure hit mapping follows wrapping scrolling resizing and completion" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
    };
    defer ui.deinit();
    var started = try toolStarted(
        "disclosure",
        "{\"command\":\"printf 'actual input, not the summary'\\n\\n\"}",
        .{ .bash = .{ .command = "a long summary that wraps across several terminal rows" } },
    );
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .started = started });
    started.deinit();
    try ui.transcript.append(std.testing.allocator, .status, "after");
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 18,
        .cols = 32,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    var projection = (try ui.draw(window)).?;
    projection.deinit(std.testing.allocator);
    const click: vaxis.Mouse = .{
        .col = @intCast(ui.last_transcript_region.x + 2),
        .row = 1,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    try std.testing.expectEqual(@as(?usize, 0), ui.tool_hits.items[1]);
    try std.testing.expect(ui.handleMouse(click));
    try std.testing.expect(ui.transcript.entries.items[0].tool.expanded);
    projection = (try ui.draw(window)).?;
    try std.testing.expectEqual(@as(?usize, 0), ui.tool_hits.items[0]);
    var saw_input = false;
    var saw_output = false;
    for (projection.lines.items) |line| {
        saw_input = saw_input or line.kind == .tool_input;
        saw_output = saw_output or line.kind == .tool_output;
        if (line.kind == .tool_input or line.kind == .tool_output or
            line.kind == .tool_input_label or line.kind == .tool_output_label)
        {
            ui.drawTranscriptLine(window, 0, &projection, line);
            for (0..window.width) |col| {
                try std.testing.expectEqual(tool_detail_background, screen.readCell(@intCast(col), 0).?.style.bg);
            }
            if (line.kind == .tool_input_label or line.kind == .tool_output_label)
                try std.testing.expectEqual(reasoning_color, screen.readCell(4, 0).?.style.fg);
        }
    }
    try std.testing.expect(saw_input and saw_output);
    projection.deinit(std.testing.allocator);

    var finished = try backend.ToolFinished.init(
        std.testing.allocator,
        "disclosure",
        .{ .failed = "# literal failure\n\x1b[31mactual output" },
    );
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .finished = finished });
    try ui.transcript.applyToolActivity(std.testing.allocator, &.{ .finished = finished });
    finished.deinit();
    try std.testing.expect(ui.transcript.entries.items[0].tool.expanded);
    try std.testing.expectEqualStrings("# literal failure\n\x1b[31mactual output", ui.transcript.entries.items[0].tool.output.?);
    try std.testing.expectEqualStrings("# literal failure\n\\x1b[31mactual output", ui.transcript.entries.items[0].tool.output_display.?);
    window.width = 20;
    projection = (try ui.draw(window)).?;
    projection.deinit(std.testing.allocator);
    _ = ui.scrollDown(3);
    projection = (try ui.draw(window)).?;
    projection.deinit(std.testing.allocator);
    var release = click;
    release.type = .release;
    try std.testing.expect(!ui.handleMouse(release));
    try std.testing.expect(ui.handleMouse(click));
    try std.testing.expect(!ui.transcript.entries.items[0].tool.expanded);
    projection = (try ui.draw(window)).?;
    defer projection.deinit(std.testing.allocator);
    for (projection.lines.items) |line| {
        try std.testing.expect(line.kind != .tool_input and line.kind != .tool_output);
    }
    try std.testing.expect(!std.meta.eql(tool_detail_background, screen.readCell(4, 0).?.style.bg));
    try std.testing.expectEqual(@as(?usize, 0), ui.tool_hits.items[0]);
}

test "tool events preserve a scrolled transcript position" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .rows_from_tail = 5,
    };
    defer ui.deinit();
    var started_event: backend.ConversationEvent = .{
        .tool_activity = .{
            .started = try toolStarted(
                "call-1",
                "{\"command\":\"true\"}",
                .{ .bash = .{ .command = "true" } },
            ),
        },
    };
    defer started_event.deinit();

    _ = try ui.applyConversationEvent(&started_event);
    try std.testing.expectEqual(@as(usize, 5), ui.rows_from_tail);

    var finished_event: backend.ConversationEvent = .{
        .tool_activity = .{
            .finished = try toolFinished(
                "call-1",
                .{ .succeeded = "ok" },
            ),
        },
    };
    defer finished_event.deinit();

    _ = try ui.applyConversationEvent(&finished_event);
    try std.testing.expectEqual(@as(usize, 5), ui.rows_from_tail);
}

test "mouse wheel scrolls the transcript within its bounds" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .last_total_rows = 20,
        .last_viewport_rows = 8,
        .last_transcript_region = .{
            .x = 2,
            .width = 96,
            .height = 8,
        },
    };
    defer ui.deinit();

    try std.testing.expect(ui.handleMouse(.{
        .col = 2,
        .row = 4,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expectEqual(mouse_wheel_rows, ui.rows_from_tail);

    try std.testing.expect(ui.handleMouse(.{
        .col = 2,
        .row = 4,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expectEqual(@as(usize, 0), ui.rows_from_tail);

    for (0..10) |_| {
        _ = ui.handleMouse(.{
            .col = 2,
            .row = 4,
            .button = .wheel_up,
            .mods = .{},
            .type = .press,
        });
    }
    try std.testing.expectEqual(@as(usize, 12), ui.rows_from_tail);
}

test "mouse wheel batch preserves bounds direction and following input" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .last_total_rows = 20,
        .last_viewport_rows = 8,
        .last_transcript_region = .{ .width = 96, .height = 8 },
    };
    defer ui.deinit();
    var tty: vaxis.Tty = undefined;
    var vx: vaxis.Vaxis = undefined;
    var loop = vaxis.Loop(AppEvent).init(std.testing.io, &tty, &vx);
    const up: vaxis.Mouse = .{
        .col = 2,
        .row = 4,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    };
    var down = up;
    down.button = .wheel_down;
    const barriers: []const AppEvent = &.{
        .{ .key_press = .{ .codepoint = 'x' } },
        .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } },
        .{ .mouse = .{ .col = 2, .row = 4, .button = .left, .mods = .{}, .type = .press } },
        .{ .winsize = .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 } },
        .conversation_wake,
    };
    for (barriers) |barrier| {
        ui.rows_from_tail = 0;
        for (0..200) |_| try loop.postEvent(.{ .mouse = up });
        try loop.postEvent(.{ .mouse = down });
        var outside = up;
        outside.row = 9;
        try loop.postEvent(.{ .mouse = outside });
        try loop.postEvent(barrier);
        try loop.postEvent(.{ .mouse = down });

        const batch = try handleMouseBatch(&ui, &loop, up);
        try std.testing.expect(batch.redraw);
        try std.testing.expectEqual(@as(usize, 12) - mouse_wheel_rows, ui.rows_from_tail);
        try std.testing.expectEqualDeep(barrier, batch.next.?);
        try std.testing.expectEqualDeep(AppEvent{ .mouse = down }, (try loop.tryEvent()).?);
        try std.testing.expectEqual(null, try loop.tryEvent());
    }
}

test "mouse wheel batch is bounded and does not drain after clicks" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
    };
    defer ui.deinit();
    var tty: vaxis.Tty = undefined;
    var vx: vaxis.Vaxis = undefined;
    var loop = vaxis.Loop(AppEvent).init(std.testing.io, &tty, &vx);
    const up: vaxis.Mouse = .{
        .col = 2,
        .row = 4,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    };
    for (0..512) |_| try loop.postEvent(.{ .mouse = up });
    const batch = try handleMouseBatch(&ui, &loop, up);
    try std.testing.expect(!batch.redraw);
    try std.testing.expectEqual(null, batch.next);
    var click = up;
    click.button = .left;
    _ = try handleMouseBatch(&ui, &loop, click);
    try std.testing.expectEqualDeep(AppEvent{ .mouse = up }, (try loop.tryEvent()).?);
    try std.testing.expectEqual(null, try loop.tryEvent());
}

test "mouse wheel outside the transcript does not scroll" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
        .last_total_rows = 20,
        .last_viewport_rows = 8,
        .last_transcript_region = .{
            .x = 2,
            .width = 96,
            .height = 8,
        },
    };
    defer ui.deinit();

    try std.testing.expect(!ui.handleMouse(.{
        .col = 2,
        .row = 8,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expect(!ui.handleMouse(.{
        .col = 1,
        .row = 4,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expect(!ui.handleMouse(.{
        .col = 2,
        .row = 4,
        .button = .none,
        .mods = .{},
        .type = .motion,
    }));
    try std.testing.expectEqual(@as(usize, 0), ui.rows_from_tail);
}

test "tool activity draws its compact row to the terminal screen" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
    };
    defer ui.deinit();
    var started = try toolStarted(
        "call-1",
        "{\"path\":\"README.md\",\"limit\":1}",
        .{ .read = .{ .path = "README.md", .offset = null, .limit = 1 } },
    );
    defer started.deinit();
    try ui.transcript.applyToolActivity(
        std.testing.allocator,
        &.{ .started = started },
    );
    try ui.transcript.appendDelta(std.testing.allocator, "READ_DONE");

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 12,
        .cols = 50,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    var projection = try ui.draw(window);
    defer if (projection) |*value| value.deinit(std.testing.allocator);

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    for (0..screen.height) |row| {
        for (0..screen.width) |column| {
            const cell = screen.readCell(
                @intCast(column),
                @intCast(row),
            ).?;
            try rendered.appendSlice(std.testing.allocator, cell.char.grapheme);
        }

        try rendered.append(std.testing.allocator, '\n');
    }
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.items,
        "Read README.md first 1 line",
    ) != null);
}

test "Markdown draw storage remains valid while screen cells are consumed" {
    var ui: ChatUi = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .input = TextInput.init(std.testing.allocator),
        .cwd = try std.testing.allocator.dupe(u8, "."),
    };
    defer ui.deinit();
    try ui.transcript.append(
        std.testing.allocator,
        .assistant,
        "# Render Test\n\n**Styled** `code`\n\n" ++
            "| Feature | Status |\n| --- | --- |\n| Tables | Readable |",
    );

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 16,
        .cols = 60,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    var projection = try ui.draw(window);
    defer if (projection) |*value| value.deinit(std.testing.allocator);

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(std.testing.allocator);
    for (0..screen.height) |row| {
        for (0..screen.width) |column| {
            const cell = screen.readCell(
                @intCast(column),
                @intCast(row),
            ).?;
            try rendered.appendSlice(std.testing.allocator, cell.char.grapheme);
        }
        try rendered.append(std.testing.allocator, '\n');
    }
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.items,
        "Render Test",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rendered.items,
        "Tables",
    ) != null);
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
        .io = std.testing.io,
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
        .io = std.testing.io,
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
        .io = std.testing.io,
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
            .identity = .{ .text = "model" },
            .key = "model",
            .primary = "Model",
            .detail = .{ .text = "Switch the active model" },
            .source_index = 0,
        },
        .{
            .identity = .{ .text = "memory" },
            .key = "memory",
            .primary = "Memory",
            .detail = .{ .text = "Manage memories" },
            .source_index = 1,
        },
        .{
            .identity = .{ .text = "show-model" },
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
        .identity = .{ .text = "omlx/qwen" },
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
        .identity = .{ .text = "copilot/gpt-5.6-sol" },
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

test "session menu preserves duplicate workspace selection by session key" {
    const entries = [_]MenuEntry{
        .{
            .identity = .{ .number = 41 },
            .key = "/work/project",
            .primary = "project",
            .detail = .{ .session = .{
                .model_id = "copilot/first",
                .last_used_unix_ms = 20,
            } },
            .source_index = 0,
        },
        .{
            .identity = .{ .number = 42 },
            .key = "/work/project",
            .primary = "project",
            .detail = .{ .session = .{
                .model_id = "copilot/second",
                .last_used_unix_ms = 10,
            } },
            .source_index = 1,
        },
    };
    var menu: MenuState = .{};
    defer menu.deinit(std.testing.allocator);

    try menu.rebuild(std.testing.allocator, &entries, "");
    menu.move(.next);
    try std.testing.expectEqual(@as(usize, 1), menu.selected().?.source_index);
    try menu.rebuild(std.testing.allocator, &entries, "project");
    try std.testing.expectEqual(@as(usize, 1), menu.selected().?.source_index);
}

test "session menu labels colliding workspaces with unique path suffixes" {
    var first_path = "/teams/a/project".*;
    var second_path = "/teams/b/project".*;
    var unique_path = "/other/unique".*;
    var first_model = "copilot/first".*;
    var second_model = "copilot/second".*;
    var third_model = "copilot/third".*;
    const sessions = [_]backend.SessionSummary{
        .{
            .allocator = undefined,
            .key = 1,
            .working_directory = &first_path,
            .model_id = &first_model,
            .last_used_unix_ms = 20,
            .current = false,
        },
        .{
            .allocator = undefined,
            .key = 2,
            .working_directory = &second_path,
            .model_id = &second_model,
            .last_used_unix_ms = 10,
            .current = false,
        },
        .{
            .allocator = undefined,
            .key = 3,
            .working_directory = &unique_path,
            .model_id = &third_model,
            .last_used_unix_ms = 5,
            .current = false,
        },
    };

    try std.testing.expectEqualStrings(
        "a/project",
        uniqueWorkspaceLabel(&sessions, 0),
    );
    try std.testing.expectEqualStrings(
        "b/project",
        uniqueWorkspaceLabel(&sessions, 1),
    );
    try std.testing.expectEqualStrings(
        "unique",
        uniqueWorkspaceLabel(&sessions, 2),
    );
}

test "session catalog failure closes stale cached finder" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var ui = try ChatUi.init(
        std.testing.allocator,
        std.testing.io,
        &environment,
    );
    defer ui.deinit();
    ui.phase = .resuming;
    ui.menu_mode = .loading_sessions;
    ui.sessions = .{
        .allocator = std.testing.allocator,
        .sessions = try std.testing.allocator.alloc(
            backend.SessionSummary,
            0,
        ),
        .skipped_invalid_shards = false,
    };

    var event: backend.ConversationEvent = .{
        .session_catalog_failed = try backend.OwnedText.init(
            std.testing.allocator,
            "Unable to load saved sessions.",
        ),
    };
    defer event.deinit();
    try std.testing.expectEqual(
        ConversationOutcome.keep_running,
        try ui.applyConversationEvent(&event),
    );
    try std.testing.expectEqual(UiPhase.ready, ui.phase);
    try std.testing.expectEqual(MenuMode.closed, ui.menu_mode);
    try std.testing.expectEqualStrings(
        "Unable to load saved sessions.",
        ui.transcript.messageAt(0).text.items,
    );
}

test "session tracking failure preserves conversation state" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var ui = try ChatUi.init(
        std.testing.allocator,
        std.testing.io,
        &environment,
    );
    defer ui.deinit();
    ui.phase = .ready;

    var event: backend.ConversationEvent = .{
        .session_tracking_failed = try backend.OwnedText.init(
            std.testing.allocator,
            "Session tracking disabled: AccessDenied",
        ),
    };
    defer event.deinit();
    try std.testing.expectEqual(
        ConversationOutcome.keep_running,
        try ui.applyConversationEvent(&event),
    );
    try std.testing.expectEqual(UiPhase.ready, ui.phase);
    try std.testing.expectEqualStrings(
        "Session tracking disabled: AccessDenied",
        ui.transcript.messageAt(0).text.items,
    );
}

test "session catalog completion restores ready after finder dismissal" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var ui = try ChatUi.init(
        std.testing.allocator,
        std.testing.io,
        &environment,
    );
    defer ui.deinit();
    ui.phase = .resuming;
    ui.menu_mode = .closed;

    var event: backend.ConversationEvent = .{
        .session_catalog = .{
            .allocator = std.testing.allocator,
            .sessions = try std.testing.allocator.alloc(
                backend.SessionSummary,
                0,
            ),
            .skipped_invalid_shards = false,
        },
    };
    defer event.deinit();
    try std.testing.expectEqual(
        ConversationOutcome.keep_running,
        try ui.applyConversationEvent(&event),
    );
    try std.testing.expectEqual(UiPhase.ready, ui.phase);
    try std.testing.expectEqual(MenuMode.closed, ui.menu_mode);
}

test "late session catalog preserves stopping phase" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var ui = try ChatUi.init(
        std.testing.allocator,
        std.testing.io,
        &environment,
    );
    defer ui.deinit();
    ui.phase = .stopping;
    ui.menu_mode = .loading_sessions;

    var event: backend.ConversationEvent = .{
        .session_catalog = .{
            .allocator = std.testing.allocator,
            .sessions = try std.testing.allocator.alloc(
                backend.SessionSummary,
                0,
            ),
            .skipped_invalid_shards = false,
        },
    };
    defer event.deinit();
    try std.testing.expectEqual(
        ConversationOutcome.keep_running,
        try ui.applyConversationEvent(&event),
    );
    try std.testing.expectEqual(UiPhase.stopping, ui.phase);
    try std.testing.expectEqual(MenuMode.closed, ui.menu_mode);
    try std.testing.expect(ui.sessions == null);
}

test "late session resume preserves stopping phase" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var ui = try ChatUi.init(
        std.testing.allocator,
        std.testing.io,
        &environment,
    );
    defer ui.deinit();
    ui.phase = .stopping;
    ui.menu_mode = .sessions;

    var event: backend.ConversationEvent = .{
        .session_resume = .{
            .failed = try backend.OwnedText.init(
                std.testing.allocator,
                "resume failed",
            ),
        },
    };
    defer event.deinit();
    try std.testing.expectEqual(
        ConversationOutcome.keep_running,
        try ui.applyConversationEvent(&event),
    );
    try std.testing.expectEqual(UiPhase.stopping, ui.phase);
    try std.testing.expectEqual(MenuMode.closed, ui.menu_mode);
}

test "session finder distinguishes empty catalog from empty filter" {
    try std.testing.expectEqualStrings(
        "No resumable sessions yet.",
        ChatUi.sessionMenuEmptyMessage(false),
    );
    try std.testing.expectEqualStrings(
        "No matching sessions.",
        ChatUi.sessionMenuEmptyMessage(true),
    );
}
