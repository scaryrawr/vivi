const std = @import("std");
const build_options = @import("build_options");
const copilot = @import("copilot_sdk");
const conversation = @import("conversation.zig");
const models = @import("models.zig");
const session_store = @import("session_store.zig");
const settings = @import("settings.zig");
const tool_activity = @import("tool_activity.zig");
const tools = @import("tools.zig");

pub const version = build_options.version;
pub const abi_version: u32 = 1;
pub const Conversation = conversation.Conversation;
pub const ConversationEvent = conversation.Event;
pub const ConversationWake = conversation.Wake;
pub const OwnedText = conversation.OwnedText;
pub const PromptDelivery = conversation.PromptDelivery;
pub const Prompt = conversation.Prompt;
pub const CommandCatalog = conversation.CommandCatalog;
pub const UserInputRequest = conversation.UserInputRequest;
pub const ModelCatalog = conversation.ModelCatalog;
pub const ModelInfo = conversation.ModelInfo;
pub const ModelSelection = conversation.ModelSelection;
pub const OwnedModelSelection = conversation.OwnedModelSelection;
pub const ReasoningEffort = conversation.ReasoningEffort;
pub const ReasoningEffortSet = conversation.ReasoningEffortSet;
pub const ReasoningProfile = conversation.ReasoningProfile;
pub const SessionCatalog = conversation.SessionCatalog;
pub const SessionSummary = conversation.SessionSummary;
pub const SessionCatalogRequest = conversation.SessionCatalogRequest;
pub const SessionCatalogScope = conversation.SessionCatalogScope;
pub const ResumeKey = conversation.ResumeKey;
pub const TranscriptSnapshot = conversation.TranscriptSnapshot;
pub const TranscriptItem = conversation.TranscriptItem;
pub const ToolActivity = tool_activity.ToolActivity;
pub const ToolActivityUpdate = tool_activity.ToolActivityUpdate;
pub const ToolStarted = tool_activity.ToolStarted;
pub const ToolFinished = tool_activity.ToolFinished;
pub const ToolCallId = tool_activity.ToolCallId;
pub const ToolLifecycle = tool_activity.ToolLifecycle;
pub const Image = @import("image.zig").Image;
pub const max_image_bytes = @import("image.zig").max_bytes;
pub const ToolSummary = tool_activity.ToolSummary;
pub const ReadToolSummary = tool_activity.ReadSummary;
pub const BashToolSummary = tool_activity.BashSummary;
pub const EditToolSummary = tool_activity.EditSummary;
pub const WriteToolSummary = tool_activity.WriteSummary;
pub const OtherToolSummary = tool_activity.OtherSummary;
pub const OmlxCatalog = models.Catalog;
pub const OmlxModel = models.Model;
pub const OmlxOptions = models.OmlxOptions;
pub const default_omlx_base_url = models.default_omlx_base_url;
pub const Settings = settings.Settings;
pub const loadSettings = settings.load;
pub const saveDefaultSelection = settings.saveDefaultSelection;

pub const Lifecycle = enum(u32) {
    scaffold = 0,
};

pub const Status = struct {
    abi_version: u32 = abi_version,
    lifecycle: Lifecycle = .scaffold,
};

pub fn scaffoldStatus() Status {
    return .{};
}

pub const ConversationOptions = struct {
    model: ?[]const u8 = null,
    reasoning: ?ReasoningEffort = null,
    settings_path: ?[]const u8 = null,
    sessions_directory: ?[]const u8 = null,
    omlx: OmlxOptions = .{},
};

const ConversationContext = struct {
    model: ?[]u8,
    reasoning: ?ReasoningEffort,
    settings_path: ?[]u8,
    sessions_directory: ?[]u8,
    omlx_base_url: []u8,
    omlx_api_key: ?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        options: ConversationOptions,
    ) !*ConversationContext {
        const context = try allocator.create(ConversationContext);
        errdefer allocator.destroy(context);

        const model = if (options.model) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (model) |value| allocator.free(value);
        const settings_path = if (options.settings_path) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (settings_path) |value| allocator.free(value);
        const sessions_directory = if (options.sessions_directory) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (sessions_directory) |value| allocator.free(value);

        context.* = .{
            .model = model,
            .reasoning = options.reasoning,
            .settings_path = settings_path,
            .sessions_directory = sessions_directory,
            .omlx_base_url = undefined,
            .omlx_api_key = null,
        };
        context.omlx_base_url = try allocator.dupe(
            u8,
            options.omlx.base_url,
        );
        errdefer allocator.free(context.omlx_base_url);
        context.omlx_api_key = if (options.omlx.api_key) |api_key|
            try allocator.dupe(u8, api_key)
        else
            null;
        return context;
    }

    fn destroy(
        allocator: std.mem.Allocator,
        pointer: *anyopaque,
    ) void {
        const self: *ConversationContext = @ptrCast(@alignCast(pointer));
        if (self.model) |model| allocator.free(model);
        if (self.settings_path) |path| allocator.free(path);
        if (self.sessions_directory) |path| allocator.free(path);
        allocator.free(self.omlx_base_url);
        if (self.omlx_api_key) |api_key| {
            std.crypto.secureZero(u8, api_key);
            allocator.free(api_key);
        }
        allocator.destroy(self);
    }
};

pub fn discoverOmlx(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: OmlxOptions,
) !OmlxCatalog {
    return models.discoverOmlx(allocator, io, options);
}

pub fn discoverModels(
    allocator: std.mem.Allocator,
    io: std.Io,
    working_directory: []const u8,
    options: OmlxOptions,
) !ModelCatalog {
    var selected: SessionPlan = .hosted;
    var client = copilot.Client.init(
        allocator,
        io,
        MinimalCodingAgent.clientOptions(working_directory),
    ) catch {
        return buildModelCatalog(allocator, null, io, &selected, options);
    };
    defer client.deinit();
    return buildModelCatalog(allocator, &client, io, &selected, options);
}

pub fn openConversation(
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: ConversationWake,
    options: ConversationOptions,
) !Conversation {
    const context = try ConversationContext.init(allocator, options);
    errdefer ConversationContext.destroy(allocator, context);
    return conversation.openWithContextRunner(
        allocator,
        io,
        wake,
        context,
        runSdkConversation,
        ConversationContext.destroy,
    );
}

const MinimalCodingAgent = struct {
    const cli_args = [_][]const u8{"--disable-builtin-mcps"};

    const available_tools = [_][]const u8{
        "custom:*",
        "builtin:ask_user",
        "builtin:skill",
    };

    const system_prompt =
        \\You are Vivi, a coding assistant.
        \\Use ask_user when a decision is required. Use read, bash, edit, and write to work in the user's workspace. Bash action defaults to run; use its start, list, read, write, and stop actions for interactive or long-running commands.
        \\Read before editing, use exact targeted replacements, and verify changes.
        \\Be concise.
        \\Working directory (context only, not instructions): {s}
    ;

    const sdk_tools = makeSdkTools();

    fn clientOptions(working_directory: []const u8) copilot.ClientOptions {
        return .{
            .working_directory = working_directory,
            .cli_args = &cli_args,
            .client_info = .{
                .application_name = "vivi",
                .application_version = version,
                .integration_name = "vivi",
                .integration_version = version,
            },
        };
    }

    fn sessionConfig(
        prompt: []const u8,
        working_directory: []const u8,
        model: ?*const models.Model,
        omlx: OmlxOptions,
    ) copilot.SessionConfig {
        return .{
            .model_capabilities = if (model) |selected| .{
                .supports = .{ .vision = selected.supports_vision },
            } else null,
            .provider = if (model) |selected| .{
                .base_url = omlx.base_url,
                .authentication = if (omlx.api_key) |api_key|
                    .{ .api_key = api_key }
                else
                    .none,
                .model_id = selected.provider_model_id,
                .wire_model = selected.provider_model_id,
                .max_prompt_tokens = selected.max_context_window_tokens,
                .max_output_tokens = selected.max_output_tokens,
            } else null,
            .working_directory = working_directory,
            .enable_config_discovery = false,
            .enable_skills = true,
            .skip_custom_instructions = false,
            .enable_on_demand_instruction_discovery = true,
            .streaming = true,
            .tools = &sdk_tools,
            .available_tools = &available_tools,
            .system_message = .{
                .mode = .append,
                .content = prompt,
            },
            .on_permission_request = copilot.approveAll,
        };
    }

    fn makeSdkTools() [tools.descriptors.len]copilot.Tool {
        var result: [tools.descriptors.len]copilot.Tool = undefined;
        for (tools.descriptors, 0..) |descriptor, index| {
            result[index] = .{
                .name = descriptor.name,
                .description = descriptor.description,
                .parameters_json = descriptor.parameters_json,
                .overrides_built_in_tool = true,
                .skip_permission = true,
            };
        }
        return result;
    }
};

const hosted_model_id = "copilot/default";

fn effectiveStartupSelection(
    model_override: ?[]const u8,
    reasoning_override: ?ReasoningEffort,
    persisted: ?ModelSelection,
) ModelSelection {
    if (model_override) |model_id| {
        return .{
            .model_id = model_id,
            .reasoning = reasoning_override orelse .off,
        };
    }
    if (persisted) |selection| {
        return .{
            .model_id = selection.model_id,
            .reasoning = reasoning_override orelse selection.reasoning,
        };
    }
    return .{
        .model_id = hosted_model_id,
        .reasoning = reasoning_override orelse .off,
    };
}

const SameModelAction = enum {
    unchanged,
    update_default,
};

fn sameSelectionAction(
    active: ModelSelection,
    persisted: ?ModelSelection,
    requested: ModelSelection,
    can_persist: bool,
) ?SameModelAction {
    if (!sameSelection(active, requested)) return null;
    if (!can_persist) return .unchanged;
    if (persisted) |value| {
        if (sameSelection(value, requested)) return .unchanged;
    }
    return .update_default;
}

fn sameSelection(left: ModelSelection, right: ModelSelection) bool {
    return left.reasoning == right.reasoning and
        std.mem.eql(u8, left.model_id, right.model_id);
}

fn settingsFailure(
    allocator: std.mem.Allocator,
    path: []const u8,
    err: anyerror,
) !conversation.OwnedText {
    const message = try std.fmt.allocPrint(
        allocator,
        "Unable to update Vivi settings at {s}: {s}",
        .{ path, @errorName(err) },
    );
    defer allocator.free(message);
    return conversation.OwnedText.init(allocator, message);
}

fn sendPrompt(
    session: copilot.Session,
    prompt: conversation.PromptContent,
    delivery: conversation.PromptDelivery,
) !void {
    const attachments = try sdkImageAttachments(session.client.allocator, prompt.images);
    defer freeSdkImageAttachments(session.client.allocator, attachments);
    const message_id = try session.send(.{
        .prompt = prompt.text,
        .mode = switch (delivery) {
            .immediate => .immediate,
            .enqueue => .enqueue,
        },
        .message_attachments = attachments,
    });
    session.client.allocator.free(message_id);
}

fn sdkImageAttachments(
    allocator: std.mem.Allocator,
    values: []const Image,
) ![]copilot.MessageAttachment {
    const attachments = try allocator.alloc(copilot.MessageAttachment, values.len);
    errdefer allocator.free(attachments);
    var initialized: usize = 0;
    errdefer for (attachments[0..initialized]) |attachment| {
        allocator.free(attachment.blob.data);
    };
    const encoder = std.base64.standard.Encoder;
    for (values, attachments) |value, *attachment| {
        const encoded = try allocator.alloc(u8, encoder.calcSize(value.bytes.len));
        _ = encoder.encode(encoded, value.bytes);
        attachment.* = .{ .blob = .{
            .data = encoded,
            .mime_type = value.format.mimeType(),
            .display_name = value.description,
        } };
        initialized += 1;
    }
    return attachments;
}

fn freeSdkImageAttachments(
    allocator: std.mem.Allocator,
    attachments: []const copilot.MessageAttachment,
) void {
    for (attachments) |attachment| switch (attachment) {
        .blob => |blob| allocator.free(blob.data),
        else => unreachable,
    };
    allocator.free(attachments);
}

test "image attachments use the SDK blob message shape" {
    const values = [_]Image{.{
        .bytes = "pixels",
        .format = .png,
        .description = "image.png",
    }};
    const attachments = try sdkImageAttachments(std.testing.allocator, &values);
    defer freeSdkImageAttachments(std.testing.allocator, attachments);
    switch (attachments[0]) {
        .blob => |blob| {
            try std.testing.expectEqualStrings("cGl4ZWxz", blob.data);
            try std.testing.expectEqualStrings("image/png", blob.mime_type);
            try std.testing.expectEqualStrings("image.png", blob.display_name.?);
        },
        else => unreachable,
    }
}

fn imageToolResultJson(
    allocator: std.mem.Allocator,
    value: Image,
) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(value.bytes.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, value.bytes);
    return std.json.Stringify.valueAlloc(allocator, .{
        .textResultForLlm = value.description,
        .resultType = "success",
        .binaryResultsForLlm = .{.{
            .type = "image",
            .mimeType = value.format.mimeType(),
            .data = encoded,
            .description = value.description,
        }},
    }, .{});
}

const ForwardResult = enum {
    none,
    sent,
    stop,
};

fn forwardImmediatePrompts(
    worker: *conversation.Worker,
    session: copilot.Session,
) !ForwardResult {
    var result: ForwardResult = .none;
    while (worker.tryTakeImmediateCommand()) |command_value| {
        var command = command_value;
        defer command.deinit();
        switch (command) {
            .prompt => |prompt| {
                try sendPrompt(
                    session,
                    prompt.message.borrow(),
                    prompt.delivery,
                );
                result = .sent;
            },
            .stop => return .stop,
            .refresh_commands,
            .refresh_models,
            .refresh_sessions,
            .switch_model,
            .resume_session,
            .execute_command,
            .user_input_response,
            => {
                return error.UnexpectedStreamingCommand;
            },
        }
    }
    return result;
}

fn startNextQueuedPrompt(
    worker: *conversation.Worker,
    session: copilot.Session,
) !ForwardResult {
    const command_value = worker.tryTakeCommand() orelse return .none;
    var command = command_value;
    defer command.deinit();
    switch (command) {
        .prompt => |prompt| {
            try sendPrompt(session, prompt.message.borrow(), .immediate);
            try worker.assistantStarted();
            return .sent;
        },
        .stop => return .stop,
        .refresh_commands,
        .refresh_models,
        .refresh_sessions,
        .switch_model,
        .resume_session,
        .execute_command,
        .user_input_response,
        => {
            return error.UnexpectedStreamingCommand;
        },
    }
}

const SubcommandSelection = struct {
    allocator: std.mem.Allocator,
    command: []u8,
    title: []u8,
    options: [][]u8,

    fn init(
        allocator: std.mem.Allocator,
        command: []const u8,
        title: []const u8,
        options: []const []const u8,
    ) !SubcommandSelection {
        const owned_options = try allocator.alloc([]u8, options.len);
        errdefer allocator.free(owned_options);
        var initialized: usize = 0;
        errdefer for (owned_options[0..initialized]) |option| {
            allocator.free(option);
        };
        for (options, 0..) |option, index| {
            owned_options[index] = try allocator.dupe(u8, option);
            initialized += 1;
        }
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        return .{
            .allocator = allocator,
            .command = owned_command,
            .title = try allocator.dupe(u8, title),
            .options = owned_options,
        };
    }

    fn deinit(self: *SubcommandSelection) void {
        self.allocator.free(self.command);
        self.allocator.free(self.title);
        for (self.options) |option| self.allocator.free(option);
        self.allocator.free(self.options);
        self.* = undefined;
    }
};

const InvokedCommand = union(enum) {
    completed: []u8,
    agent_prompt: []u8,
    select_subcommand: SubcommandSelection,

    fn deinit(self: *InvokedCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed, .agent_prompt => |text| allocator.free(text),
            .select_subcommand => |*selection| selection.deinit(),
        }
        self.* = undefined;
    }
};

fn executeSdkCommand(
    allocator: std.mem.Allocator,
    client: anytype,
    session: anytype,
    input: []const u8,
) !InvokedCommand {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const command = if (trimmed.len > 0 and trimmed[0] == '/')
        trimmed[1..]
    else
        trimmed;
    const separator = std.mem.indexOfAny(u8, command, " \t\r\n");
    const name = if (separator) |index| command[0..index] else command;
    const args = if (separator) |index|
        std.mem.trim(u8, command[index..], " \t\r\n")
    else
        "";
    if (name.len == 0) return error.EmptyCommand;

    var result = try client.callRpc(
        struct {
            kind: []const u8,
            text: ?[]const u8 = null,
            message: ?[]const u8 = null,
            notice: ?[]const u8 = null,
            prompt: ?[]const u8 = null,
            command: ?[]const u8 = null,
            title: ?[]const u8 = null,
            options: ?[]const struct {
                name: []const u8,
                description: ?[]const u8 = null,
                group: ?[]const u8 = null,
            } = null,
        },
        "session.commands.invoke",
        .{
            .sessionId = session.id,
            .name = name,
            .input = args,
        },
    );
    defer result.deinit();
    if (std.mem.eql(u8, result.value.kind, "agent-prompt")) {
        const prompt = result.value.prompt orelse
            return error.MissingCommandPrompt;
        return .{ .agent_prompt = try allocator.dupe(u8, prompt) };
    }
    if (std.mem.eql(u8, result.value.kind, "select-subcommand")) {
        const parent = result.value.command orelse
            return error.MissingSubcommandParent;
        const title = result.value.title orelse
            return error.MissingSubcommandTitle;
        const options = result.value.options orelse
            return error.MissingSubcommandOptions;
        if (options.len == 0) return error.EmptySubcommandOptions;
        const names = try allocator.alloc([]const u8, options.len);
        defer allocator.free(names);
        for (options, 0..) |option, index| names[index] = option.name;
        return .{
            .select_subcommand = try SubcommandSelection.init(
                allocator,
                parent,
                title,
                names,
            ),
        };
    }
    if (result.value.message orelse
        result.value.notice orelse
        result.value.text) |message|
    {
        return .{ .completed = try allocator.dupe(u8, message) };
    }

    if (!std.mem.eql(u8, result.value.kind, "completed")) {
        return .{
            .completed = try std.fmt.allocPrint(
                allocator,
                "/{s} returned unsupported result \"{s}\".",
                .{ name, result.value.kind },
            ),
        };
    }
    return .{
        .completed = try std.fmt.allocPrint(
            allocator,
            "/{s} completed.",
            .{name},
        ),
    };
}

fn selectedSubcommandInput(
    allocator: std.mem.Allocator,
    selection: SubcommandSelection,
    answer: []const u8,
) ![]u8 {
    for (selection.options) |option| {
        if (std.mem.eql(u8, option, answer)) {
            return std.fmt.allocPrint(
                allocator,
                "{s} {s}",
                .{ selection.command, option },
            );
        }
    }
    return error.InvalidSubcommandSelection;
}

fn handleSdkUserInput(
    allocator: std.mem.Allocator,
    request: copilot.UserInputRequest,
    context: ?*anyopaque,
) !copilot.UserInputResponse {
    const worker: *conversation.Worker = @ptrCast(
        @alignCast(context orelse return error.MissingUserInputContext),
    );
    try worker.userInputRequested(try conversation.UserInputRequest.init(
        allocator,
        request.session_id,
        request.question,
        request.choices orelse &.{},
        request.allow_freeform orelse true,
    ));

    var command = worker.waitUserInputResponse();
    defer command.deinit();
    switch (command) {
        .user_input_response => |response| {
            if (!std.mem.eql(
                u8,
                response.request_id.bytes,
                request.session_id,
            )) {
                return error.UnexpectedUserInputResponse;
            }
            return .{
                .answer = try allocator.dupe(
                    u8,
                    response.answer.bytes,
                ),
                .was_freeform = response.was_freeform,
            };
        },
        .stop => return error.UserInputCancelled,
        else => return error.UnexpectedUserInputCommand,
    }
}

const SessionPlan = union(enum) {
    hosted,
    copilot: struct {
        id: []u8,
        provider_model_id: []u8,
        display_name: []u8,
        max_context_window_tokens: u64,
        max_output_tokens: u64,
        supports_vision: bool,
        reasoning: ReasoningProfile,
        selected_reasoning: ReasoningEffort,
    },
    omlx: struct {
        id: []u8,
        provider_model_id: []u8,
        display_name: []u8,
        provider_base_url: []u8,
        max_context_window_tokens: u64,
        max_output_tokens: u64,
        supports_vision: bool,
        reasoning: ReasoningProfile,
        selected_reasoning: ReasoningEffort,
    },

    fn deinit(self: *SessionPlan, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .hosted => {},
            .copilot => |value| {
                allocator.free(value.id);
                allocator.free(value.provider_model_id);
                allocator.free(value.display_name);
            },
            .omlx => |value| {
                allocator.free(value.id);
                allocator.free(value.provider_model_id);
                allocator.free(value.display_name);
                allocator.free(value.provider_base_url);
            },
        }
        self.* = undefined;
    }

    fn id(self: *const SessionPlan) []const u8 {
        return switch (self.*) {
            .hosted => hosted_model_id,
            .copilot => |value| value.id,
            .omlx => |value| value.id,
        };
    }

    fn selection(self: *const SessionPlan) ModelSelection {
        return .{
            .model_id = self.id(),
            .reasoning = switch (self.*) {
                .hosted => .off,
                .copilot => |value| value.selected_reasoning,
                .omlx => |value| value.selected_reasoning,
            },
        };
    }

    fn info(
        self: *const SessionPlan,
        allocator: std.mem.Allocator,
    ) !conversation.ModelInfo {
        const owned_id = try allocator.dupe(u8, self.id());
        errdefer allocator.free(owned_id);
        return switch (self.*) {
            .hosted => .{
                .allocator = allocator,
                .id = owned_id,
                .display_name = try allocator.dupe(u8, "Copilot default"),
                .max_context_window_tokens = 0,
                .max_output_tokens = 0,
                .supports_vision = false,
                .reasoning = offOnlyReasoningProfile(),
            },
            .copilot => |value| .{
                .allocator = allocator,
                .id = owned_id,
                .display_name = try allocator.dupe(u8, value.display_name),
                .max_context_window_tokens = value.max_context_window_tokens,
                .max_output_tokens = value.max_output_tokens,
                .supports_vision = value.supports_vision,
                .reasoning = value.reasoning,
            },
            .omlx => |value| .{
                .allocator = allocator,
                .id = owned_id,
                .display_name = try allocator.dupe(u8, value.display_name),
                .max_context_window_tokens = value.max_context_window_tokens,
                .max_output_tokens = value.max_output_tokens,
                .supports_vision = value.supports_vision,
                .reasoning = value.reasoning,
            },
        };
    }
};

fn resolveSessionPlan(
    allocator: std.mem.Allocator,
    client: *copilot.Client,
    io: std.Io,
    requested: ModelSelection,
    omlx: OmlxOptions,
) !SessionPlan {
    const model_id = requested.model_id;
    if (requested.reasoning != .off and
        std.mem.eql(u8, model_id, hosted_model_id))
    {
        return error.UnsupportedReasoningEffort;
    }
    if (std.mem.eql(u8, model_id, hosted_model_id)) return .hosted;
    if (std.mem.startsWith(u8, model_id, "copilot/")) {
        const provider_model_id = model_id["copilot/".len..];
        if (provider_model_id.len == 0) return error.SelectedModelUnavailable;
        var listed = try client.listModels(.{});
        defer listed.deinit();
        for (listed.value.models) |model| {
            if (isUsableHostedModel(model) and
                std.mem.eql(u8, provider_model_id, model.id))
            {
                return copilotSessionPlan(
                    allocator,
                    model,
                    requested.reasoning,
                );
            }
        }
        return error.SelectedModelUnavailable;
    }
    if (!std.mem.startsWith(u8, model_id, "omlx/")) {
        return error.UnsupportedModelProvider;
    }

    var catalog = try models.discoverOmlx(allocator, io, omlx);
    defer catalog.deinit();
    const selected = catalog.find(model_id) orelse
        return error.SelectedModelUnavailable;
    if (!localReasoningProfile().selectable.contains(requested.reasoning)) {
        return error.UnsupportedReasoningEffort;
    }
    const base_url = try std.fmt.allocPrint(
        allocator,
        "{s}/v1",
        .{models.omlxServerRoot(omlx.base_url)},
    );
    errdefer allocator.free(base_url);
    const id = try allocator.dupe(u8, selected.id);
    errdefer allocator.free(id);
    const provider_model_id = try allocator.dupe(
        u8,
        selected.provider_model_id,
    );
    errdefer allocator.free(provider_model_id);
    const display_name = try allocator.dupe(u8, selected.display_name);

    return .{ .omlx = .{
        .id = id,
        .provider_model_id = provider_model_id,
        .display_name = display_name,
        .provider_base_url = base_url,
        .max_context_window_tokens = selected.max_context_window_tokens,
        .max_output_tokens = selected.max_output_tokens,
        .supports_vision = selected.supports_vision,
        .reasoning = localReasoningProfile(),
        .selected_reasoning = requested.reasoning,
    } };
}

fn copilotSessionPlan(
    allocator: std.mem.Allocator,
    model: copilot.Model,
    selected_reasoning: ReasoningEffort,
) !SessionPlan {
    const reasoning = hostedReasoningProfile(model);
    if (!reasoning.selectable.contains(selected_reasoning)) {
        return error.UnsupportedReasoningEffort;
    }
    const id = try std.fmt.allocPrint(
        allocator,
        "copilot/{s}",
        .{model.id},
    );
    errdefer allocator.free(id);
    const provider_model_id = try allocator.dupe(u8, model.id);
    errdefer allocator.free(provider_model_id);
    const display_name = try allocator.dupe(
        u8,
        if (model.name.len == 0) model.id else model.name,
    );
    const limits = model.capabilities.limits;
    const supports = model.capabilities.supports;
    return .{ .copilot = .{
        .id = id,
        .provider_model_id = provider_model_id,
        .display_name = display_name,
        .max_context_window_tokens = if (limits) |value|
            value.max_context_window_tokens orelse
                value.max_prompt_tokens orelse 0
        else
            0,
        .max_output_tokens = if (limits) |value|
            value.max_output_tokens orelse 0
        else
            0,
        .supports_vision = if (supports) |value|
            value.vision orelse false
        else
            false,
        .reasoning = reasoning,
        .selected_reasoning = selected_reasoning,
    } };
}

fn offOnlyReasoningProfile() ReasoningProfile {
    return .{
        .selectable = .{ .off = true },
        .advertised_default = null,
    };
}

fn localReasoningProfile() ReasoningProfile {
    return .{
        .selectable = .{
            .off = true,
            .low = true,
            .medium = true,
            .high = true,
            .xhigh = true,
        },
        .advertised_default = .off,
    };
}

fn hostedReasoningProfile(model: copilot.Model) ReasoningProfile {
    var profile = offOnlyReasoningProfile();
    if (model.capabilities.supports) |supports| {
        if (supports.reasoningEffort == false) return profile;
    }
    if (model.supportedReasoningEfforts) |efforts| {
        for (efforts) |value| {
            if (parseSdkReasoningEffort(value)) |effort| {
                setReasoningEffort(&profile.selectable, effort);
            }
        }
    }
    if (model.defaultReasoningEffort) |value| {
        if (parseSdkReasoningEffort(value)) |effort| {
            profile.advertised_default = effort;
        }
    }
    return profile;
}

fn parseSdkReasoningEffort(value: []const u8) ?ReasoningEffort {
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

fn setReasoningEffort(
    values: *ReasoningEffortSet,
    effort: ReasoningEffort,
) void {
    switch (effort) {
        .off => values.off = true,
        .low => values.low = true,
        .medium => values.medium = true,
        .high => values.high = true,
        .xhigh => values.xhigh = true,
        .max => values.max = true,
    }
}

fn sdkReasoningEffort(
    effort: ReasoningEffort,
) ?copilot.ReasoningEffort {
    return switch (effort) {
        .off => null,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
        .max => .max,
    };
}

fn createSdkSession(
    worker: *conversation.Worker,
    client: *copilot.Client,
    system_prompt: []const u8,
    working_directory: []const u8,
    plan: *const SessionPlan,
    api_key: ?[]const u8,
) !copilot.Session {
    var directories = try WorkspaceCustomizationDirectories.init(
        worker.allocator(),
        working_directory,
    );
    defer directories.deinit();
    var config = sessionConfigForPlan(
        system_prompt,
        working_directory,
        plan,
        api_key,
    );
    directories.apply(&config);
    config.on_user_input_request = handleSdkUserInput;
    config.user_input_context = worker;
    return client.createSession(config);
}

fn joinSdkSession(
    worker: *conversation.Worker,
    client: *copilot.Client,
    session_id: []const u8,
    system_prompt: []const u8,
    working_directory: []const u8,
    plan: *const SessionPlan,
    api_key: ?[]const u8,
) !copilot.Session {
    var directories = try WorkspaceCustomizationDirectories.init(
        worker.allocator(),
        working_directory,
    );
    defer directories.deinit();
    var config = sessionConfigForPlan(
        system_prompt,
        working_directory,
        plan,
        api_key,
    );
    directories.apply(&config);
    config.on_user_input_request = handleSdkUserInput;
    config.user_input_context = worker;
    return client.joinSession(session_id, config);
}

fn sessionConfigForPlan(
    system_prompt: []const u8,
    working_directory: []const u8,
    plan: *const SessionPlan,
    api_key: ?[]const u8,
) copilot.SessionConfig {
    const selected: ?models.Model = switch (plan.*) {
        .hosted, .copilot => null,
        .omlx => |value| .{
            .id = value.id,
            .provider_model_id = value.provider_model_id,
            .display_name = value.display_name,
            .max_context_window_tokens = value.max_context_window_tokens,
            .max_output_tokens = value.max_output_tokens,
            .supports_vision = value.supports_vision,
        },
    };
    var config = MinimalCodingAgent.sessionConfig(
        system_prompt,
        working_directory,
        if (selected) |*model| model else null,
        .{
            .base_url = switch (plan.*) {
                .hosted, .copilot => default_omlx_base_url,
                .omlx => |value| value.provider_base_url,
            },
            .api_key = api_key,
        },
    );
    switch (plan.*) {
        .copilot => |value| config.model = value.provider_model_id,
        .hosted, .omlx => {},
    }
    config.reasoning_effort = sdkReasoningEffort(plan.selection().reasoning);
    return config;
}

fn buildModelCatalog(
    allocator: std.mem.Allocator,
    client: ?*copilot.Client,
    io: std.Io,
    selected: *const SessionPlan,
    omlx: OmlxOptions,
) !conversation.ModelCatalog {
    var listed = if (client) |value|
        value.listModels(.{}) catch null
    else
        null;
    defer if (listed) |*value| value.deinit();
    var discovered = models.discoverOmlx(allocator, io, omlx) catch null;
    defer if (discovered) |*value| value.deinit();

    const values = try allocator.alloc(
        conversation.ModelInfo,
        1 + usableHostedModelCount(listed) +
            if (discovered) |value| value.models.len else 0,
    );
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |*value| value.deinit();

    var hosted_plan: SessionPlan = .hosted;
    values[0] = try hosted_plan.info(allocator);
    initialized += 1;

    if (listed) |value| {
        for (value.value.models, 0..) |model, source_index| {
            if (!isUsableHostedModel(model) or
                isDuplicateHostedModel(
                    value.value.models[0..source_index],
                    model.id,
                ))
            {
                continue;
            }
            var plan = try copilotSessionPlan(allocator, model, .off);
            defer plan.deinit(allocator);
            values[initialized] = try plan.info(allocator);
            initialized += 1;
        }
    }

    if (discovered) |value| for (value.models) |model| {
        values[initialized] = .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, model.id),
            .display_name = undefined,
            .max_context_window_tokens = model.max_context_window_tokens,
            .max_output_tokens = model.max_output_tokens,
            .supports_vision = model.supports_vision,
            .reasoning = localReasoningProfile(),
        };
        errdefer allocator.free(values[initialized].id);
        values[initialized].display_name = try allocator.dupe(
            u8,
            model.display_name,
        );
        initialized += 1;
    };
    return .{
        .allocator = allocator,
        .selected = try conversation.OwnedModelSelection.init(
            allocator,
            selected.selection(),
        ),
        .models = values,
    };
}

fn usableHostedModelCount(
    listed: ?std.json.Parsed(copilot.ModelList),
) usize {
    const value = listed orelse return 0;
    var count: usize = 0;
    for (value.value.models, 0..) |model, index| {
        if (isUsableHostedModel(model) and
            !isDuplicateHostedModel(value.value.models[0..index], model.id))
        {
            count += 1;
        }
    }
    return count;
}

fn isUsableHostedModel(model: copilot.Model) bool {
    if (model.id.len == 0 or std.mem.eql(u8, model.id, "default")) {
        return false;
    }
    return model.policy == null or model.policy.?.state == .enabled;
}

fn isDuplicateHostedModel(
    previous: []const copilot.Model,
    id: []const u8,
) bool {
    for (previous) |model| {
        if (isUsableHostedModel(model) and
            std.mem.eql(u8, model.id, id))
        {
            return true;
        }
    }
    return false;
}

fn buildCommandCatalog(
    allocator: std.mem.Allocator,
    client: *copilot.Client,
    session: copilot.Session,
) !conversation.CommandCatalog {
    const RpcCommand = struct {
        name: []const u8,
        description: []const u8 = "",
    };
    var listed = try client.callRpc(
        struct { commands: []const RpcCommand },
        "session.commands.list",
        .{
            .sessionId = session.id,
            .includeBuiltins = true,
            .includeSkills = true,
            .includeClientCommands = true,
        },
    );
    defer listed.deinit();
    const sdk_commands = listed.value.commands;

    var count: usize = 2;
    for (sdk_commands) |command| {
        if (!std.ascii.eqlIgnoreCase(command.name, "model") and
            !std.ascii.eqlIgnoreCase(command.name, "resume"))
        {
            count += 1;
        }
    }
    const commands = try allocator.alloc(conversation.CommandInfo, count);
    errdefer allocator.free(commands);
    var initialized: usize = 0;
    errdefer for (commands[0..initialized]) |*command| {
        allocator.free(command.name);
        allocator.free(command.description);
    };

    const sdk_model = for (sdk_commands) |command| {
        if (std.ascii.eqlIgnoreCase(command.name, "model")) break command;
    } else null;
    commands[initialized] = try initCommandInfo(
        allocator,
        "model",
        if (sdk_model) |command|
            command.description
        else
            "Switch the model for new turns",
    );
    initialized += 1;
    commands[initialized] = try initCommandInfo(
        allocator,
        "resume",
        "Resume a previous Vivi session",
    );
    initialized += 1;
    for (sdk_commands) |command| {
        if (std.ascii.eqlIgnoreCase(command.name, "model") or
            std.ascii.eqlIgnoreCase(command.name, "resume"))
        {
            continue;
        }
        commands[initialized] = try initCommandInfo(
            allocator,
            command.name,
            command.description,
        );
        initialized += 1;
    }
    return .{ .allocator = allocator, .commands = commands };
}

fn buildFallbackCommandCatalog(
    allocator: std.mem.Allocator,
) !conversation.CommandCatalog {
    const commands = try allocator.alloc(conversation.CommandInfo, 2);
    errdefer allocator.free(commands);
    var initialized: usize = 0;
    errdefer for (commands[0..initialized]) |*command| {
        allocator.free(command.name);
        allocator.free(command.description);
    };
    commands[initialized] = try initCommandInfo(
        allocator,
        "model",
        "Switch the model for new turns",
    );
    initialized += 1;
    commands[initialized] = try initCommandInfo(
        allocator,
        "resume",
        "Resume a previous Vivi session",
    );
    return .{ .allocator = allocator, .commands = commands };
}

fn initCommandInfo(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
) !conversation.CommandInfo {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    return .{
        .name = owned_name,
        .description = try allocator.dupe(u8, description),
    };
}

fn buildSessionCatalog(
    allocator: std.mem.Allocator,
    index: *const session_store.Index,
    active_session_id: []const u8,
    generation: u64,
) !conversation.SessionCatalog {
    const sessions = try allocator.alloc(
        conversation.SessionSummary,
        index.records.len,
    );
    errdefer allocator.free(sessions);
    var initialized: usize = 0;
    errdefer for (sessions[0..initialized]) |*session| session.deinit();
    for (index.records, 0..) |record, record_index| {
        const working_directory = try allocator.dupe(
            u8,
            record.working_directory,
        );
        errdefer allocator.free(working_directory);
        sessions[record_index] = .{
            .allocator = allocator,
            .key = .{
                .generation = generation,
                .slot = @intCast(record_index),
                .scope = .local,
            },
            .working_directory = working_directory,
            .model_id = try allocator.dupe(u8, record.model_id),
            .reasoning = record.reasoning,
            .last_used_unix_ms = record.last_used_unix_ms,
            .current = std.mem.eql(u8, active_session_id, record.id),
        };
        initialized += 1;
    }
    return .{
        .allocator = allocator,
        .scope = .local,
        .label = try allocator.dupe(
            u8,
            conversation.SessionCatalogScope.local.label(),
        ),
        .sessions = sessions,
        .skipped_invalid_shards = index.skipped_invalid_shards,
    };
}

const RemoteResumeTarget = struct {
    id: []u8,
    working_directory: []u8,
    title: ?[]u8,
    modified_time: []u8,

    fn deinit(self: *RemoteResumeTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.working_directory);
        if (self.title) |value| allocator.free(value);
        allocator.free(self.modified_time);
        self.* = undefined;
    }
};

const ResumeTargets = union(enum) {
    local: session_store.Index,
    broader: []RemoteResumeTarget,

    fn deinit(self: *ResumeTargets, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .local => |*index| index.deinit(),
            .broader => |targets| {
                for (targets) |*target| target.deinit(allocator);
                allocator.free(targets);
            },
        }
        self.* = undefined;
    }
};

fn buildBroaderSessionCatalog(
    allocator: std.mem.Allocator,
    client: *copilot.Client,
    active_working_directory: []const u8,
    active_session_id: []const u8,
    active_model_id: []const u8,
    active_reasoning: ReasoningEffort,
    generation: u64,
) !struct {
    catalog: conversation.SessionCatalog,
    targets: ResumeTargets,
} {
    var listed = try client.listSessions(.{
        .cwd = active_working_directory,
    });
    defer listed.deinit();

    var remote = std.ArrayList(RemoteResumeTarget).empty;
    errdefer {
        for (remote.items) |*target| target.deinit(allocator);
        remote.deinit(allocator);
    }
    for (listed.sessions) |metadata| {
        const context = metadata.context orelse continue;
        if (!std.mem.eql(u8, context.cwd, active_working_directory)) continue;
        var target = blk: {
            const id = try allocator.dupe(u8, metadata.session_id);
            errdefer allocator.free(id);
            const working_directory = try allocator.dupe(u8, context.cwd);
            errdefer allocator.free(working_directory);
            const modified_time = try allocator.dupe(
                u8,
                metadata.modified_time,
            );
            errdefer allocator.free(modified_time);
            var value = RemoteResumeTarget{
                .id = id,
                .working_directory = working_directory,
                .title = null,
                .modified_time = modified_time,
            };
            errdefer value.deinit(allocator);
            if (metadata.summary) |summary| {
                value.title = try allocator.dupe(u8, summary);
            }
            break :blk value;
        };
        errdefer target.deinit(allocator);
        try remote.append(allocator, target);
    }

    const targets = try remote.toOwnedSlice(allocator);
    errdefer {
        for (targets) |*target| target.deinit(allocator);
        allocator.free(targets);
    }
    const sessions = try allocator.alloc(conversation.SessionSummary, targets.len);
    errdefer allocator.free(sessions);
    var initialized: usize = 0;
    errdefer for (sessions[0..initialized]) |*session| session.deinit();
    for (targets, 0..) |target, index| {
        var summary = blk: {
            const working_directory = try allocator.dupe(
                u8,
                target.working_directory,
            );
            errdefer allocator.free(working_directory);
            const model_id = try allocator.dupe(u8, active_model_id);
            errdefer allocator.free(model_id);
            var value = conversation.SessionSummary{
                .allocator = allocator,
                .key = .{
                    .generation = generation,
                    .slot = @intCast(index),
                    .scope = .broader,
                },
                .working_directory = working_directory,
                .model_id = model_id,
                .reasoning = active_reasoning,
                .title = null,
                .summary = null,
                .last_used_unix_ms = unixMilliseconds(client.io),
                .current = std.mem.eql(u8, target.id, active_session_id),
            };
            errdefer value.deinit();
            if (target.title) |title| {
                value.title = try allocator.dupe(u8, title);
            }
            value.summary = try std.fmt.allocPrint(
                allocator,
                "Updated {s}",
                .{target.modified_time},
            );
            break :blk value;
        };
        errdefer summary.deinit();
        sessions[index] = summary;
        initialized += 1;
    }
    return .{
        .catalog = .{
            .allocator = allocator,
            .scope = .broader,
            .label = try allocator.dupe(
                u8,
                conversation.SessionCatalogScope.broader.label(),
            ),
            .sessions = sessions,
            .skipped_invalid_shards = false,
        },
        .targets = .{ .broader = targets },
    };
}

fn projectTranscriptSnapshot(
    allocator: std.mem.Allocator,
    history: *const copilot.SessionEventHistory,
) !conversation.TranscriptSnapshot {
    var items = std.ArrayList(conversation.TranscriptItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit();
        items.deinit(allocator);
    }
    try items.ensureTotalCapacity(allocator, history.events.len);
    for (history.events) |event| switch (event) {
        .user_message => |message| items.appendAssumeCapacity(
            try conversation.TranscriptItem.init(
                allocator,
                .user,
                message.data.content,
            ),
        ),
        .assistant_message => |message| items.appendAssumeCapacity(
            try conversation.TranscriptItem.init(
                allocator,
                .assistant,
                message.content,
            ),
        ),
        .assistant_reasoning => |reasoning| items.appendAssumeCapacity(
            try conversation.TranscriptItem.init(
                allocator,
                .reasoning,
                reasoning.content,
            ),
        ),
        else => {},
    };
    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn projectTranscriptSnapshotFromRawHistory(
    allocator: std.mem.Allocator,
    events: []const std.json.Value,
) !conversation.TranscriptSnapshot {
    var items = std.ArrayList(conversation.TranscriptItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit();
        items.deinit(allocator);
    }
    try items.ensureTotalCapacity(allocator, events.len);
    for (events) |event| {
        const object = switch (event) {
            .object => |value| value,
            else => continue,
        };
        const event_type = switch (object.get("type") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const data = switch (object.get("data") orelse continue) {
            .object => |value| value,
            else => continue,
        };
        const content = switch (data.get("content") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const role: conversation.TranscriptRole = if (std.mem.eql(
            u8,
            event_type,
            "user.message",
        ))
            .user
        else if (std.mem.eql(u8, event_type, "assistant.message"))
            .assistant
        else if (std.mem.eql(u8, event_type, "assistant.reasoning"))
            .reasoning
        else
            continue;
        items.appendAssumeCapacity(
            try conversation.TranscriptItem.init(allocator, role, content),
        );
    }
    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn hydrateTranscriptSnapshot(
    allocator: std.mem.Allocator,
    client: *copilot.Client,
    session: copilot.Session,
) !conversation.TranscriptSnapshot {
    var history = session.getEvents() catch |err| {
        if (err != error.InvalidSessionEvent) return err;
        const RawHistory = struct {
            events: []const std.json.Value,
        };
        var raw = try client.callRpc(
            RawHistory,
            "session.getMessages",
            .{ .sessionId = session.id },
        );
        defer raw.deinit();
        return projectTranscriptSnapshotFromRawHistory(
            allocator,
            raw.value.events,
        );
    };
    defer history.deinit();
    return projectTranscriptSnapshot(allocator, &history);
}

test "raw history projection ignores malformed events" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        \\{"events":[{"type":"user.message","data":{"content":"question"}},{"type":"assistant.message","data":{"content":"answer"}},{"type":"assistant.message","data":{"missing":"content"}},{"type":"tool.execution_start","data":{"toolName":"read"}}]}
    ,
        .{},
    );
    defer parsed.deinit();
    const events = parsed.value.object.get("events").?.array.items;
    var snapshot = try projectTranscriptSnapshotFromRawHistory(
        std.testing.allocator,
        events,
    );
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(.user, snapshot.items[0].role);
    try std.testing.expectEqualStrings("question", snapshot.items[0].text);
    try std.testing.expectEqual(.assistant, snapshot.items[1].role);
    try std.testing.expectEqualStrings("answer", snapshot.items[1].text);
}

fn sessionSummaryFromRecord(
    allocator: std.mem.Allocator,
    key: conversation.ResumeKey,
    record: *const session_store.Record,
    current: bool,
) !conversation.SessionSummary {
    const working_directory = try allocator.dupe(u8, record.working_directory);
    errdefer allocator.free(working_directory);
    return .{
        .allocator = allocator,
        .key = key,
        .working_directory = working_directory,
        .model_id = try allocator.dupe(u8, record.model_id),
        .reasoning = record.reasoning,
        .last_used_unix_ms = record.last_used_unix_ms,
        .current = current,
    };
}

fn unixMilliseconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn recordSessionRecency(
    worker: *conversation.Worker,
    store: ?*session_store.Store,
    tracking_enabled: *bool,
    session_id: []const u8,
    working_directory: []const u8,
    model_id: []const u8,
    reasoning: ReasoningEffort,
) void {
    if (!tracking_enabled.*) return;
    const value = store orelse return;
    value.recordCreated(
        session_id,
        working_directory,
        model_id,
        reasoning,
        unixMilliseconds(worker.io()),
    ) catch |err| {
        tracking_enabled.* = false;
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(
            &buffer,
            "Session tracking disabled: {s}",
            .{@errorName(err)},
        ) catch "Session tracking disabled.";
        worker.sessionTrackingFailed(message) catch {};
    };
}

const StreamResult = enum {
    idle,
    stopped,
    failed,
};

const WorkspaceCustomizationDirectories = struct {
    allocator: std.mem.Allocator,
    skills: [3][]u8,
    instructions: [1][]u8,

    fn init(
        allocator: std.mem.Allocator,
        working_directory: []const u8,
    ) !WorkspaceCustomizationDirectories {
        const instructions = try allocator.dupe(u8, working_directory);
        errdefer allocator.free(instructions);
        const github_skills = try std.fs.path.join(
            allocator,
            &.{ working_directory, ".github/skills" },
        );
        errdefer allocator.free(github_skills);
        const agents_skills = try std.fs.path.join(
            allocator,
            &.{ working_directory, ".agents/skills" },
        );
        errdefer allocator.free(agents_skills);
        const claude_skills = try std.fs.path.join(
            allocator,
            &.{ working_directory, ".claude/skills" },
        );

        return .{
            .allocator = allocator,
            .skills = .{ github_skills, agents_skills, claude_skills },
            .instructions = .{instructions},
        };
    }

    fn deinit(self: *WorkspaceCustomizationDirectories) void {
        for (self.skills) |directory| self.allocator.free(directory);
        for (self.instructions) |directory| self.allocator.free(directory);
    }

    fn apply(
        self: *const WorkspaceCustomizationDirectories,
        config: *copilot.SessionConfig,
    ) void {
        config.skill_directories = &self.skills;
        config.instruction_directories = &self.instructions;
    }
};

fn automaticPermissionFailure(
    handling: copilot.AutomaticPermissionHandling,
) ?[]const u8 {
    return switch (handling) {
        .handled => null,
        .not_configured => "Copilot requested permission without an automatic handler.",
        .no_result => "Copilot requires manual permission approval, which vivi does not support yet.",
        .handler_failed, .delivery_failed => |err| @errorName(err),
    };
}

fn isViviTool(name: []const u8) bool {
    inline for (tools.descriptors) |descriptor| {
        if (std.mem.eql(u8, name, descriptor.name)) return true;
    }
    return false;
}

fn containsToolCall(ids: []const []const u8, call_id: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, call_id)) return true;
    }
    return false;
}

fn emitTypedToolStart(
    worker: *conversation.Worker,
    active_calls: *std.ArrayList([]u8),
    call_id: []const u8,
    tool_name: []const u8,
) !void {
    if (isViviTool(tool_name) or containsToolCall(active_calls.items, call_id)) {
        return;
    }
    const started = try tool_activity.ToolStarted.init(
        worker.allocator(),
        call_id,
        "{}",
        .{ .other = .{ .name = tool_name } },
    );
    try worker.toolActivity(.{ .started = started });
    const call_id_copy = try worker.allocator().dupe(u8, call_id);
    errdefer worker.allocator().free(call_id_copy);
    try active_calls.append(worker.allocator(), call_id_copy);
}

fn emitTypedToolComplete(
    worker: *conversation.Worker,
    active_calls: *std.ArrayList([]u8),
    complete: anytype,
) !void {
    const index = for (active_calls.items, 0..) |call_id, index| {
        if (std.mem.eql(u8, call_id, complete.tool_call_id)) break index;
    } else return;
    defer worker.allocator().free(active_calls.orderedRemove(index));
    const output = if (complete.success)
        if (complete.result) |result| result.content else "Completed."
    else if (complete.error_) |failure|
        failure.message
    else
        "Failed.";
    const finished = try tool_activity.ToolFinished.init(
        worker.allocator(),
        complete.tool_call_id,
        if (complete.success)
            .{ .succeeded = output }
        else
            .{ .failed = output },
    );
    try worker.toolActivity(.{ .finished = finished });
}

fn reportStreamStatus(
    worker: *conversation.Worker,
    message: []const u8,
    failure_message: []const u8,
) bool {
    worker.status(message) catch {
        worker.closeFailure(.stream, failure_message);
        return false;
    };
    return true;
}

test "typed stream tool projection leaves Vivi tools to external events" {
    try std.testing.expect(isViviTool("read"));
    try std.testing.expect(isViviTool("bash"));
    try std.testing.expect(!isViviTool("github-mcp-server-search_code"));
    try std.testing.expect(containsToolCall(
        &.{ "call-one", "call-two" },
        "call-two",
    ));
}

fn refreshCommandCatalog(
    worker: *conversation.Worker,
    client: *copilot.Client,
    session: copilot.Session,
) void {
    if (buildCommandCatalog(
        worker.allocator(),
        client,
        session,
    )) |catalog| {
        worker.commandCatalog(catalog) catch {};
    } else |_| {}
}

fn streamSessionResponse(
    worker: *conversation.Worker,
    client: *copilot.Client,
    session: copilot.Session,
    tool_service: *tools.Service,
) StreamResult {
    var typed_tool_calls = std.ArrayList([]u8).empty;
    defer {
        for (typed_tool_calls.items) |call_id| worker.allocator().free(call_id);
        typed_tool_calls.deinit(worker.allocator());
    }
    while (true) {
        var event = session.nextEvent() catch |err| {
            worker.closeFailure(.stream, @errorName(err));
            return .failed;
        };
        defer event.deinit(worker.allocator());

        switch (event) {
            .assistant_message_delta => |delta| {
                worker.assistantDelta(delta.delta_content) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver streamed output.",
                    );
                    return .failed;
                };
            },
            .assistant_message => |message| {
                worker.assistantComplete(message.content) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver the completed response.",
                    );
                    return .failed;
                };
            },
            .assistant_reasoning => |reasoning| {
                worker.reasoningComplete(reasoning.content) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver completed reasoning.",
                    );
                    return .failed;
                };
            },
            .assistant_reasoning_delta => |delta| {
                worker.reasoningDelta(delta.delta_content) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver streamed reasoning.",
                    );
                    return .failed;
                };
            },
            .session_idle => |idle| {
                if (idle.mode != null and
                    std.mem.eql(u8, idle.mode.?, "autopilot"))
                {
                    continue;
                }
                switch (startNextQueuedPrompt(
                    worker,
                    session,
                ) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                }) {
                    .sent => continue,
                    .stop => {
                        session.disconnect() catch |err| {
                            worker.closeFailure(
                                .stream,
                                @errorName(err),
                            );
                            return .failed;
                        };
                        worker.closeRequested();
                        return .stopped;
                    },
                    .none => {},
                }
                worker.idle() catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to finish the streamed response.",
                    );
                    return .failed;
                };
                return .idle;
            },
            .session_error => |failure| {
                worker.closeFailure(.stream, failure.message);
                return .failed;
            },
            .permission_requested => |request| {
                if (automaticPermissionFailure(request.automatic_handling)) |message| {
                    worker.closeFailure(.stream, message);
                    return .failed;
                }
            },
            .external_tool_requested => |request| {
                var prepared = tool_service.prepare(
                    request.tool_name,
                    request.arguments_json,
                ) catch |err| {
                    session.respondToToolError(
                        request.request_id,
                        @errorName(err),
                    ) catch |respond_err| {
                        worker.closeFailure(
                            .stream,
                            @errorName(respond_err),
                        );
                        return .failed;
                    };
                    continue;
                };
                defer prepared.deinit();
                const started = prepared.started(
                    worker.allocator(),
                    request.tool_call_id,
                ) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                };
                worker.toolActivity(.{ .started = started }) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                };
                var result = tool_service.execute(&prepared) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                };
                defer result.deinit(worker.allocator());
                const finished = tool_activity.ToolFinished.init(
                    worker.allocator(),
                    request.tool_call_id,
                    switch (result) {
                        .text => |text| .{ .succeeded = text },
                        .image => |value| .{ .image = value },
                        .failure => |message| .{ .failed = message },
                    },
                ) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                };
                worker.toolActivity(.{ .finished = finished }) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                };
                switch (result) {
                    .image => {
                        const json = imageToolResultJson(
                            worker.allocator(),
                            result.image,
                        ) catch |err| {
                            worker.closeFailure(.stream, @errorName(err));
                            return .failed;
                        };
                        defer worker.allocator().free(json);
                        session.respondToToolResultJson(
                            request.request_id,
                            json,
                        ) catch |err| {
                            worker.closeFailure(.stream, @errorName(err));
                            return .failed;
                        };
                    },
                    .text => |text| session.respondToTool(
                        request.request_id,
                        text,
                    ) catch |err| {
                        worker.closeFailure(.stream, @errorName(err));
                        return .failed;
                    },
                    .failure => |message| session.respondToToolError(
                        request.request_id,
                        message,
                    ) catch |err| {
                        worker.closeFailure(.stream, @errorName(err));
                        return .failed;
                    },
                }
            },
            .commands_changed => refreshCommandCatalog(
                worker,
                client,
                session,
            ),
            .tool_execution_start => |started| emitTypedToolStart(
                worker,
                &typed_tool_calls,
                started.data.tool_call_id,
                started.data.tool_name,
            ) catch {
                worker.closeFailure(.stream, "Unable to display tool activity.");
                return .failed;
            },
            .tool_execution_progress => |progress| {
                const message = std.fmt.allocPrint(
                    worker.allocator(),
                    "Tool progress: {s}",
                    .{progress.data.progress_message},
                ) catch {
                    worker.closeFailure(.stream, "Unable to display tool progress.");
                    return .failed;
                };
                defer worker.allocator().free(message);
                if (!reportStreamStatus(
                    worker,
                    message,
                    "Unable to display tool progress.",
                )) return .failed;
            },
            .tool_execution_partial_result => {},
            .tool_execution_complete => |complete| emitTypedToolComplete(
                worker,
                &typed_tool_calls,
                complete.data,
            ) catch {
                worker.closeFailure(.stream, "Unable to display tool completion.");
                return .failed;
            },
            .subagent_started => |started| {
                const message = std.fmt.allocPrint(
                    worker.allocator(),
                    "Subagent started: {s}.",
                    .{started.data.agent_display_name},
                ) catch {
                    worker.closeFailure(.stream, "Unable to display subagent status.");
                    return .failed;
                };
                defer worker.allocator().free(message);
                if (!reportStreamStatus(
                    worker,
                    message,
                    "Unable to display subagent status.",
                )) return .failed;
            },
            .subagent_completed => |completed| {
                const message = std.fmt.allocPrint(
                    worker.allocator(),
                    "Subagent completed: {s}.",
                    .{completed.data.agent_display_name},
                ) catch {
                    worker.closeFailure(.stream, "Unable to display subagent status.");
                    return .failed;
                };
                defer worker.allocator().free(message);
                if (!reportStreamStatus(
                    worker,
                    message,
                    "Unable to display subagent status.",
                )) return .failed;
            },
            .subagent_failed => |failed| {
                const message = std.fmt.allocPrint(
                    worker.allocator(),
                    "Subagent failed: {s}: {s}",
                    .{ failed.data.agent_display_name, failed.data.error_ },
                ) catch {
                    worker.closeFailure(.stream, "Unable to display subagent status.");
                    return .failed;
                };
                defer worker.allocator().free(message);
                if (!reportStreamStatus(
                    worker,
                    message,
                    "Unable to display subagent status.",
                )) return .failed;
            },
            .session_warning => |warning| {
                const message = std.fmt.allocPrint(
                    worker.allocator(),
                    "Warning ({s}): {s}",
                    .{ warning.data.warning_type, warning.data.message },
                ) catch {
                    worker.closeFailure(.stream, "Unable to display warning.");
                    return .failed;
                };
                defer worker.allocator().free(message);
                if (!reportStreamStatus(
                    worker,
                    message,
                    "Unable to display warning.",
                )) return .failed;
            },
            .session_title_changed => |title| {
                const message = std.fmt.allocPrint(
                    worker.allocator(),
                    "Session title: {s}",
                    .{title.data.title},
                ) catch {
                    worker.closeFailure(.stream, "Unable to display session title.");
                    return .failed;
                };
                defer worker.allocator().free(message);
                if (!reportStreamStatus(
                    worker,
                    message,
                    "Unable to display session title.",
                )) return .failed;
            },
            .session_context_changed => {
                if (!reportStreamStatus(
                    worker,
                    "Session context updated.",
                    "Unable to display session context.",
                )) return .failed;
            },
            .session_context_cleared => {
                if (!reportStreamStatus(
                    worker,
                    "Session context cleared.",
                    "Unable to display session context.",
                )) return .failed;
            },
            .session_session_limits_changed => {
                if (!reportStreamStatus(
                    worker,
                    "Session limits updated.",
                    "Unable to display session limits.",
                )) return .failed;
            },
            .session_limits_exhausted_requested => {
                if (!reportStreamStatus(
                    worker,
                    "Session limits exhausted.",
                    "Unable to display session limits.",
                )) return .failed;
            },
            .unknown => |unknown| {
                if (std.mem.eql(
                    u8,
                    unknown.event_type,
                    "commands.changed",
                )) {
                    refreshCommandCatalog(worker, client, session);
                }
            },
            else => {},
        }

        switch (forwardImmediatePrompts(
            worker,
            session,
        ) catch |err| {
            worker.closeFailure(.stream, @errorName(err));
            return .failed;
        }) {
            .none, .sent => {},
            .stop => {
                session.disconnect() catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return .failed;
                };
                worker.closeRequested();
                return .stopped;
            },
        }
    }
}

fn runSdkConversation(
    worker: *conversation.Worker,
    opaque_context: *anyopaque,
) void {
    const context: *ConversationContext = @ptrCast(
        @alignCast(opaque_context),
    );
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(
        worker.io(),
        &cwd_buffer,
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    var active_working_directory = worker.allocator().dupe(
        u8,
        cwd_buffer[0..cwd_len],
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer worker.allocator().free(active_working_directory);
    var tool_service = tools.Service.init(
        worker.allocator(),
        worker.io(),
        active_working_directory,
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer tool_service.deinit();

    var client = copilot.Client.init(
        worker.allocator(),
        worker.io(),
        MinimalCodingAgent.clientOptions(active_working_directory),
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer client.deinit();
    const system_prompt = std.fmt.allocPrint(
        worker.allocator(),
        MinimalCodingAgent.system_prompt,
        .{active_working_directory},
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer worker.allocator().free(system_prompt);

    const omlx_options = OmlxOptions{
        .base_url = context.omlx_base_url,
        .api_key = context.omlx_api_key,
    };
    var store = if (context.sessions_directory) |directory|
        session_store.Store.init(
            worker.allocator(),
            worker.io(),
            directory,
        ) catch |err| {
            worker.closeFailure(.startup, @errorName(err));
            return;
        }
    else
        null;
    defer if (store) |*value| value.deinit();
    var resume_targets: ?ResumeTargets = null;
    defer if (resume_targets) |*targets| targets.deinit(worker.allocator());
    var resume_generation: u64 = 0;
    var persisted_settings = if (context.settings_path) |path|
        settings.load(worker.allocator(), worker.io(), path) catch |err| {
            const message = std.fmt.allocPrint(
                worker.allocator(),
                "Unable to load Vivi settings at {s}: {s}",
                .{ path, @errorName(err) },
            ) catch {
                worker.closeFailure(.startup, @errorName(err));
                return;
            };
            defer worker.allocator().free(message);
            worker.closeFailure(.startup, message);
            return;
        }
    else
        settings.Settings{ .allocator = worker.allocator() };
    defer persisted_settings.deinit();

    const persisted_startup = if (persisted_settings.default_selection) |*value|
        value.view()
    else
        null;
    var active_plan = resolveSessionPlan(
        worker.allocator(),
        &client,
        worker.io(),
        effectiveStartupSelection(
            context.model,
            context.reasoning,
            persisted_startup,
        ),
        omlx_options,
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer active_plan.deinit(worker.allocator());

    var session = createSdkSession(
        worker,
        &client,
        system_prompt,
        active_working_directory,
        &active_plan,
        context.omlx_api_key,
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    var session_connected = true;
    defer if (session_connected) session.disconnect() catch {};
    if (store) |*value| {
        value.recordCreated(
            session.id,
            active_working_directory,
            active_plan.id(),
            active_plan.selection().reasoning,
            unixMilliseconds(worker.io()),
        ) catch |err| {
            session.disconnect() catch {};
            session_connected = false;
            worker.closeFailure(.startup, @errorName(err));
            return;
        };
    }
    var session_tracking_enabled = store != null;

    if (!(worker.ready() catch {
        worker.closeFailure(.startup, "Unable to publish conversation readiness.");
        return;
    })) {
        session.disconnect() catch {};
        session_connected = false;
        worker.closeRequested();
        return;
    }

    const initial_commands = buildCommandCatalog(
        worker.allocator(),
        &client,
        session,
    ) catch buildFallbackCommandCatalog(worker.allocator()) catch null;
    if (initial_commands) |catalog| worker.commandCatalog(catalog) catch {};
    if (buildModelCatalog(
        worker.allocator(),
        &client,
        worker.io(),
        &active_plan,
        omlx_options,
    )) |catalog| {
        worker.modelCatalog(catalog) catch {};
    } else |_| {}

    while (true) {
        var command = worker.waitCommand();
        defer command.deinit();
        switch (command) {
            .stop => {
                session.disconnect() catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                session_connected = false;
                worker.closeRequested();
                return;
            },
            .refresh_commands => {
                const catalog = buildCommandCatalog(
                    worker.allocator(),
                    &client,
                    session,
                ) catch buildFallbackCommandCatalog(
                    worker.allocator(),
                ) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                worker.completeCommandRefresh(catalog) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver slash commands.",
                    );
                    return;
                };
            },
            .refresh_models => {
                const catalog = buildModelCatalog(
                    worker.allocator(),
                    &client,
                    worker.io(),
                    &active_plan,
                    omlx_options,
                ) catch |err| {
                    worker.completeModelRefreshFailure(@errorName(err)) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                worker.completeModelRefresh(catalog) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver the model catalog.",
                    );
                    return;
                };
            },
            .refresh_sessions => |request| {
                resume_generation +%= 1;
                if (resume_generation == 0) resume_generation = 1;
                if (request == .local) {
                    var new_index: session_store.Index = if (store) |*value|
                        value.list() catch |err| {
                            worker.completeSessionRefreshFailure(
                                @errorName(err),
                            ) catch {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            };
                            continue;
                        }
                    else
                        .{
                            .allocator = worker.allocator(),
                            .records = worker.allocator().alloc(
                                session_store.Record,
                                0,
                            ) catch |err| {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            },
                        };
                    const catalog = buildSessionCatalog(
                        worker.allocator(),
                        &new_index,
                        session.id,
                        resume_generation,
                    ) catch |err| {
                        new_index.deinit();
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    worker.completeSessionRefresh(catalog) catch {
                        new_index.deinit();
                        worker.closeFailure(
                            .stream,
                            "Unable to deliver the session catalog.",
                        );
                        return;
                    };
                    if (resume_targets) |*targets| targets.deinit(worker.allocator());
                    resume_targets = .{ .local = new_index };
                } else {
                    const result = buildBroaderSessionCatalog(
                        worker.allocator(),
                        &client,
                        active_working_directory,
                        session.id,
                        active_plan.id(),
                        active_plan.selection().reasoning,
                        resume_generation,
                    ) catch |err| {
                        worker.completeSessionRefreshFailure(
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        continue;
                    };
                    worker.completeSessionRefresh(result.catalog) catch {
                        var targets = result.targets;
                        targets.deinit(worker.allocator());
                        worker.closeFailure(
                            .stream,
                            "Unable to deliver the session catalog.",
                        );
                        return;
                    };
                    if (resume_targets) |*targets| targets.deinit(worker.allocator());
                    resume_targets = result.targets;
                }
            },
            .resume_session => |key| {
                const targets = if (resume_targets) |*value| value else {
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            "Refresh the session list before resuming.",
                        ) catch {
                            worker.closeFailure(.stream, "Out of memory.");
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, "Unable to report resume failure.");
                        return;
                    };
                    continue;
                };
                if (key.generation != resume_generation) {
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            "The selected session is no longer available.",
                        ) catch {
                            worker.closeFailure(.stream, "Out of memory.");
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, "Unable to report resume failure.");
                        return;
                    };
                    continue;
                }
                const broader = key.scope == .broader;
                var target: session_store.Record = switch (targets.*) {
                    .local => |index| blk: {
                        if (key.scope != .local or key.slot >= index.records.len) {
                            worker.completeSessionResume(.{
                                .failed = conversation.OwnedText.init(
                                    worker.allocator(),
                                    "The selected session is no longer available.",
                                ) catch {
                                    worker.closeFailure(.stream, "Out of memory.");
                                    return;
                                },
                            }) catch {
                                worker.closeFailure(.stream, "Unable to report resume failure.");
                                return;
                            };
                            continue;
                        }
                        break :blk index.records[key.slot].clone(worker.allocator()) catch |err| {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                    },
                    .broader => |records| blk: {
                        if (key.scope != .broader or key.slot >= records.len) {
                            worker.completeSessionResume(.{
                                .failed = conversation.OwnedText.init(
                                    worker.allocator(),
                                    "The selected session is no longer available.",
                                ) catch {
                                    worker.closeFailure(.stream, "Out of memory.");
                                    return;
                                },
                            }) catch {
                                worker.closeFailure(.stream, "Unable to report resume failure.");
                                return;
                            };
                            continue;
                        }
                        const record = records[key.slot];
                        break :blk session_store.Record.init(
                            worker.allocator(),
                            record.id,
                            record.working_directory,
                            active_plan.id(),
                            active_plan.selection().reasoning,
                            0,
                        ) catch |err| {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                    },
                };
                defer target.deinit();
                if (std.mem.eql(u8, target.id, session.id)) {
                    const snapshot = hydrateTranscriptSnapshot(
                        worker.allocator(),
                        &client,
                        session,
                    ) catch |err| {
                        worker.completeSessionResume(.{
                            .failed = conversation.OwnedText.init(
                                worker.allocator(),
                                @errorName(err),
                            ) catch {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            },
                        }) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        continue;
                    };
                    const now = unixMilliseconds(worker.io());
                    target.last_used_unix_ms = now;
                    if (store) |*value| (if (broader)
                        value.recordCreated(
                            target.id,
                            target.working_directory,
                            target.model_id,
                            target.reasoning,
                            now,
                        )
                    else
                        value.touch(&target, now)) catch |err| {
                        var mutable = snapshot;
                        mutable.deinit();
                        worker.completeSessionResume(.{
                            .failed = conversation.OwnedText.init(
                                worker.allocator(),
                                @errorName(err),
                            ) catch {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            },
                        }) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        continue;
                    };
                    const summary = sessionSummaryFromRecord(
                        worker.allocator(),
                        key,
                        &target,
                        true,
                    ) catch |err| {
                        var mutable = snapshot;
                        mutable.deinit();
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    worker.completeSessionResume(.{ .resumed = .{
                        .session = summary,
                        .transcript = snapshot,
                        .cleanup_failed = false,
                    } }) catch {
                        worker.closeFailure(.stream, "Unable to report resumed session.");
                        return;
                    };
                    continue;
                }

                var target_plan = resolveSessionPlan(
                    worker.allocator(),
                    &client,
                    worker.io(),
                    .{
                        .model_id = target.model_id,
                        .reasoning = target.reasoning,
                    },
                    omlx_options,
                ) catch |err| {
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                var candidate_tools = tools.Service.init(
                    worker.allocator(),
                    worker.io(),
                    target.working_directory,
                ) catch |err| {
                    target_plan.deinit(worker.allocator());
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                const candidate_prompt = std.fmt.allocPrint(
                    worker.allocator(),
                    MinimalCodingAgent.system_prompt,
                    .{target.working_directory},
                ) catch |err| {
                    candidate_tools.deinit();
                    target_plan.deinit(worker.allocator());
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                defer worker.allocator().free(candidate_prompt);
                var candidate = joinSdkSession(
                    worker,
                    &client,
                    target.id,
                    candidate_prompt,
                    target.working_directory,
                    &target_plan,
                    context.omlx_api_key,
                ) catch |err| {
                    candidate_tools.deinit();
                    target_plan.deinit(worker.allocator());
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                const snapshot = hydrateTranscriptSnapshot(
                    worker.allocator(),
                    &client,
                    candidate,
                ) catch |err| {
                    candidate.disconnect() catch {};
                    candidate_tools.deinit();
                    target_plan.deinit(worker.allocator());
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                const now = unixMilliseconds(worker.io());
                target.last_used_unix_ms = now;
                const candidate_working_directory = worker.allocator().dupe(
                    u8,
                    target.working_directory,
                ) catch |err| {
                    var mutable = snapshot;
                    mutable.deinit();
                    candidate.disconnect() catch {};
                    candidate_tools.deinit();
                    target_plan.deinit(worker.allocator());
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                const summary = sessionSummaryFromRecord(
                    worker.allocator(),
                    key,
                    &target,
                    true,
                ) catch |err| {
                    var mutable = snapshot;
                    mutable.deinit();
                    worker.allocator().free(candidate_working_directory);
                    candidate.disconnect() catch {};
                    candidate_tools.deinit();
                    target_plan.deinit(worker.allocator());
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                if (store) |*value| (if (broader)
                    value.recordCreated(
                        target.id,
                        target.working_directory,
                        target.model_id,
                        target.reasoning,
                        now,
                    )
                else
                    value.touch(&target, now)) catch |err| {
                    var mutable_summary = summary;
                    mutable_summary.deinit();
                    var mutable_snapshot = snapshot;
                    mutable_snapshot.deinit();
                    worker.allocator().free(candidate_working_directory);
                    candidate.disconnect() catch {};
                    candidate_tools.deinit();
                    target_plan.deinit(worker.allocator());
                    worker.completeSessionResume(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };

                const previous_session = session;
                var previous_tools = tool_service;
                const previous_working_directory = active_working_directory;
                var previous_plan = active_plan;
                session_connected = false;
                session = candidate;
                tool_service = candidate_tools;
                active_working_directory = candidate_working_directory;
                active_plan = target_plan;
                session_connected = true;
                const cleanup_failed = if (previous_session.disconnect())
                    false
                else |_|
                    true;
                previous_tools.deinit();
                worker.allocator().free(previous_working_directory);
                previous_plan.deinit(worker.allocator());
                worker.completeSessionResume(.{ .resumed = .{
                    .session = summary,
                    .transcript = snapshot,
                    .cleanup_failed = cleanup_failed,
                } }) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to report the resumed session.",
                    );
                    return;
                };
                if (buildCommandCatalog(
                    worker.allocator(),
                    &client,
                    session,
                )) |catalog| {
                    worker.commandCatalog(catalog) catch {};
                } else |_| {}
            },
            .execute_command => |requested| {
                var command_input = worker.allocator().dupe(
                    u8,
                    requested.bytes,
                ) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                defer worker.allocator().free(command_input);
                command_execution: while (true) {
                    var result = executeSdkCommand(
                        worker.allocator(),
                        &client,
                        session,
                        command_input,
                    ) catch |err| {
                        worker.commandCompleted(@errorName(err)) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        break :command_execution;
                    };
                    defer result.deinit(worker.allocator());
                    switch (result) {
                        .completed => |message| {
                            worker.commandCompleted(message) catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to report slash command completion.",
                                );
                                return;
                            };
                            break :command_execution;
                        },
                        .agent_prompt => |prompt| {
                            sendPrompt(session, .{ .text = prompt }, .immediate) catch |err| {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            };
                            worker.assistantStarted() catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to start the command response.",
                                );
                                return;
                            };
                            switch (streamSessionResponse(
                                worker,
                                &client,
                                session,
                                &tool_service,
                            )) {
                                .idle => {},
                                .stopped => {
                                    session_connected = false;
                                    return;
                                },
                                .failed => return,
                            }
                            recordSessionRecency(
                                worker,
                                if (store) |*value| value else null,
                                &session_tracking_enabled,
                                session.id,
                                active_working_directory,
                                active_plan.id(),
                                active_plan.selection().reasoning,
                            );
                            break :command_execution;
                        },
                        .select_subcommand => |selection| {
                            const request = conversation.UserInputRequest.init(
                                worker.allocator(),
                                session.id,
                                selection.title,
                                selection.options,
                                false,
                            ) catch |err| {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            };
                            worker.userInputRequested(request) catch |err| {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            };
                            var response = worker.waitUserInputResponse();
                            defer response.deinit();
                            switch (response) {
                                .stop => {
                                    session.disconnect() catch |err| {
                                        worker.closeFailure(
                                            .stream,
                                            @errorName(err),
                                        );
                                        return;
                                    };
                                    session_connected = false;
                                    worker.closeRequested();
                                    return;
                                },
                                .user_input_response => |answer| {
                                    if (!std.mem.eql(
                                        u8,
                                        answer.request_id.bytes,
                                        session.id,
                                    )) {
                                        worker.closeFailure(
                                            .stream,
                                            "Subcommand response ID mismatch.",
                                        );
                                        return;
                                    }
                                    const next_input = selectedSubcommandInput(
                                        worker.allocator(),
                                        selection,
                                        answer.answer.bytes,
                                    ) catch |err| {
                                        worker.commandCompleted(
                                            @errorName(err),
                                        ) catch {
                                            worker.closeFailure(
                                                .stream,
                                                @errorName(err),
                                            );
                                            return;
                                        };
                                        break :command_execution;
                                    };
                                    worker.allocator().free(command_input);
                                    command_input = next_input;
                                    continue :command_execution;
                                },
                                .prompt,
                                .refresh_commands,
                                .refresh_models,
                                .refresh_sessions,
                                .switch_model,
                                .resume_session,
                                .execute_command,
                                => unreachable,
                            }
                        },
                    }
                }
            },
            .user_input_response => {
                worker.closeFailure(
                    .stream,
                    "Received a user-input response without a pending question.",
                );
                return;
            },
            .switch_model => |requested| {
                var target_plan = resolveSessionPlan(
                    worker.allocator(),
                    &client,
                    worker.io(),
                    requested.view(),
                    omlx_options,
                ) catch |err| {
                    worker.completeModelSwitch(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                if (context.settings_path) |path| {
                    const current_settings = settings.load(
                        worker.allocator(),
                        worker.io(),
                        path,
                    ) catch |err| {
                        target_plan.deinit(worker.allocator());
                        worker.completeModelSwitch(.{
                            .failed = settingsFailure(
                                worker.allocator(),
                                path,
                                err,
                            ) catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to report the settings failure.",
                                );
                                return;
                            },
                        }) catch {
                            worker.closeFailure(
                                .stream,
                                "Unable to report the settings failure.",
                            );
                            return;
                        };
                        continue;
                    };
                    persisted_settings.deinit();
                    persisted_settings = current_settings;
                }
                const persisted_selection =
                    if (persisted_settings.default_selection) |*value|
                        value.view()
                    else
                        null;
                if (sameSelectionAction(
                    active_plan.selection(),
                    persisted_selection,
                    target_plan.selection(),
                    context.settings_path != null,
                )) |action| {
                    const info = target_plan.info(worker.allocator()) catch |err| {
                        target_plan.deinit(worker.allocator());
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    var selected = conversation.OwnedModelSelection.init(
                        worker.allocator(),
                        target_plan.selection(),
                    ) catch |err| {
                        target_plan.deinit(worker.allocator());
                        var mutable = info;
                        mutable.deinit();
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    if (action == .update_default) {
                        const path = context.settings_path.?;
                        const persisted_value = selected.clone(
                            worker.allocator(),
                        ) catch |err| {
                            target_plan.deinit(worker.allocator());
                            var mutable = info;
                            mutable.deinit();
                            selected.deinit();
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        settings.saveDefaultSelection(
                            worker.allocator(),
                            worker.io(),
                            path,
                            target_plan.selection(),
                        ) catch |err| {
                            var mutable_persisted = persisted_value;
                            mutable_persisted.deinit();
                            target_plan.deinit(worker.allocator());
                            var mutable = info;
                            mutable.deinit();
                            selected.deinit();
                            worker.completeModelSwitch(.{
                                .failed = settingsFailure(
                                    worker.allocator(),
                                    path,
                                    err,
                                ) catch {
                                    worker.closeFailure(
                                        .stream,
                                        "Unable to report the settings failure.",
                                    );
                                    return;
                                },
                            }) catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to report the settings failure.",
                                );
                                return;
                            };
                            continue;
                        };
                        if (persisted_settings.default_selection) |*current| {
                            current.deinit();
                        }
                        persisted_settings.default_selection = persisted_value;
                    }
                    target_plan.deinit(worker.allocator());
                    worker.completeModelSwitch(if (action == .unchanged)
                        .{ .unchanged = .{
                            .model = info,
                            .selection = selected,
                        } }
                    else
                        .{ .default_updated = .{
                            .model = info,
                            .selection = selected,
                        } }) catch {
                        worker.closeFailure(
                            .stream,
                            "Unable to report the selected model.",
                        );
                        return;
                    };
                    continue;
                }

                const candidate_prompt = std.fmt.allocPrint(
                    worker.allocator(),
                    MinimalCodingAgent.system_prompt,
                    .{active_working_directory},
                ) catch |err| {
                    target_plan.deinit(worker.allocator());
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                defer worker.allocator().free(candidate_prompt);
                var candidate = createSdkSession(
                    worker,
                    &client,
                    candidate_prompt,
                    active_working_directory,
                    &target_plan,
                    context.omlx_api_key,
                ) catch |err| {
                    target_plan.deinit(worker.allocator());
                    worker.completeModelSwitch(.{
                        .failed = conversation.OwnedText.init(
                            worker.allocator(),
                            @errorName(err),
                        ) catch {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        },
                    }) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
                };
                const info = target_plan.info(worker.allocator()) catch |err| {
                    candidate.disconnect() catch {};
                    target_plan.deinit(worker.allocator());
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                var selected = conversation.OwnedModelSelection.init(
                    worker.allocator(),
                    target_plan.selection(),
                ) catch |err| {
                    candidate.disconnect() catch {};
                    target_plan.deinit(worker.allocator());
                    var mutable = info;
                    mutable.deinit();
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                var settings_update: ?settings.DefaultSelectionUpdate = null;
                const persisted_value = if (context.settings_path) |path| blk: {
                    const value = selected.clone(worker.allocator()) catch |err| {
                        candidate.disconnect() catch {};
                        target_plan.deinit(worker.allocator());
                        var mutable = info;
                        mutable.deinit();
                        selected.deinit();
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    settings_update = settings.updateDefaultSelection(
                        worker.allocator(),
                        worker.io(),
                        path,
                        target_plan.selection(),
                    ) catch |err| {
                        var mutable_value = value;
                        mutable_value.deinit();
                        candidate.disconnect() catch {};
                        target_plan.deinit(worker.allocator());
                        var mutable = info;
                        mutable.deinit();
                        selected.deinit();
                        worker.completeModelSwitch(.{
                            .failed = settingsFailure(
                                worker.allocator(),
                                path,
                                err,
                            ) catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to report the settings failure.",
                                );
                                return;
                            },
                        }) catch {
                            worker.closeFailure(
                                .stream,
                                "Unable to report the settings failure.",
                            );
                            return;
                        };
                        continue;
                    };
                    break :blk value;
                } else null;
                if (session_tracking_enabled) {
                    if (store) |*value| {
                        value.recordCreated(
                            candidate.id,
                            active_working_directory,
                            target_plan.id(),
                            target_plan.selection().reasoning,
                            unixMilliseconds(worker.io()),
                        ) catch |err| {
                            if (settings_update) |*update| {
                                _ = settings.rollbackDefaultSelection(
                                    worker.allocator(),
                                    worker.io(),
                                    context.settings_path.?,
                                    update,
                                ) catch |rollback_err| {
                                    update.deinit();
                                    settings_update = null;
                                    candidate.disconnect() catch {};
                                    target_plan.deinit(worker.allocator());
                                    var mutable = info;
                                    mutable.deinit();
                                    selected.deinit();
                                    if (persisted_value) |saved| {
                                        var mutable_value = saved;
                                        mutable_value.deinit();
                                    }
                                    worker.closeFailure(
                                        .stream,
                                        @errorName(rollback_err),
                                    );
                                    return;
                                };
                                update.deinit();
                                settings_update = null;
                            }
                            candidate.disconnect() catch {};
                            target_plan.deinit(worker.allocator());
                            var mutable = info;
                            mutable.deinit();
                            selected.deinit();
                            if (persisted_value) |saved| {
                                var mutable_value = saved;
                                mutable_value.deinit();
                            }
                            worker.completeModelSwitch(.{
                                .failed = conversation.OwnedText.init(
                                    worker.allocator(),
                                    @errorName(err),
                                ) catch {
                                    worker.closeFailure(.stream, @errorName(err));
                                    return;
                                },
                            }) catch {
                                worker.closeFailure(.stream, @errorName(err));
                                return;
                            };
                            continue;
                        };
                    }
                }
                if (settings_update) |*update| {
                    update.deinit();
                    settings_update = null;
                }

                const previous_session = session;
                session_connected = false;
                session = candidate;
                session_connected = true;
                active_plan.deinit(worker.allocator());
                active_plan = target_plan;
                if (persisted_value) |value| {
                    if (persisted_settings.default_selection) |*current| {
                        current.deinit();
                    }
                    persisted_settings.default_selection = value;
                }
                const cleanup_failed = if (previous_session.disconnect())
                    false
                else |_|
                    true;
                worker.completeModelSwitch(.{ .switched = .{
                    .model = info,
                    .selection = selected,
                    .history = .reset_visible_transcript_preserved,
                    .default_saved = persisted_value != null,
                    .cleanup_failed = cleanup_failed,
                } }) catch {
                    worker.closeFailure(
                        .stream,
                        "Unable to report the model switch.",
                    );
                    return;
                };
                if (buildCommandCatalog(
                    worker.allocator(),
                    &client,
                    session,
                )) |catalog| {
                    worker.commandCatalog(catalog) catch {};
                } else |_| {}
            },
            .prompt => |prompt| {
                sendPrompt(
                    session,
                    prompt.message.borrow(),
                    prompt.delivery,
                ) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                if (prompt.delivery == .enqueue) {
                    worker.assistantStarted() catch {
                        worker.closeFailure(
                            .stream,
                            "Unable to start the queued response.",
                        );
                        return;
                    };
                }
                switch (streamSessionResponse(
                    worker,
                    &client,
                    session,
                    &tool_service,
                )) {
                    .idle => {},
                    .stopped => {
                        session_connected = false;
                        return;
                    },
                    .failed => return,
                }
                recordSessionRecency(
                    worker,
                    if (store) |*value| value else null,
                    &session_tracking_enabled,
                    session.id,
                    active_working_directory,
                    active_plan.id(),
                    active_plan.selection().reasoning,
                );
            },
        }
    }
}

test "scaffold status is stable" {
    const status = scaffoldStatus();

    try std.testing.expectEqual(abi_version, status.abi_version);
    try std.testing.expectEqual(Lifecycle.scaffold, status.lifecycle);
}

test "image tool result serializes binary content for Copilot, not the transcript" {
    const allocator = std.testing.allocator;
    var result: tools.Result = .{ .image = .{
        .bytes = try allocator.dupe(u8, "\x89PNG\r\n\x1a\n\x00"),
        .format = .png,
        .description = try allocator.dupe(u8, "Image: sample.png"),
    } };
    defer result.deinit(allocator);
    const json = try imageToolResultJson(allocator, result.image);
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("success", object.get("resultType").?.string);
    try std.testing.expectEqualStrings("Image: sample.png", object.get("textResultForLlm").?.string);
    const binary = object.get("binaryResultsForLlm").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), binary.len);
    try std.testing.expectEqualStrings("image", binary[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", binary[0].object.get("mimeType").?.string);
    const encoded = binary[0].object.get("data").?.string;
    const decoder = std.base64.standard.Decoder;
    const decoded = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    defer allocator.free(decoded);
    try decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, result.image.bytes, decoded);
}

test "Copilot SDK dependency is compile-visible" {
    _ = copilot.Client;
    _ = copilot.ProviderConfig;
    _ = copilot.ModelList;
    _ = copilot.ModelPolicyState;
    _ = copilot.Client.listModels;
    _ = copilot.Client.callRpc;
}

test "automatic hosted model is a selectable no-provider plan" {
    const plan: SessionPlan = .hosted;
    try std.testing.expectEqualStrings(hosted_model_id, plan.id());
    var info = try plan.info(std.testing.allocator);
    defer info.deinit();
    try std.testing.expectEqualStrings(hosted_model_id, info.id);
    try std.testing.expectEqualStrings("Copilot default", info.display_name);
    try std.testing.expectEqual(@as(u64, 0), info.max_context_window_tokens);
}

test "startup selection keeps model and reasoning coherent" {
    const persisted = ModelSelection{
        .model_id = "omlx/persisted",
        .reasoning = .high,
    };
    const overridden = effectiveStartupSelection(
        "copilot/override",
        null,
        persisted,
    );
    try std.testing.expectEqualStrings(
        "copilot/override",
        overridden.model_id,
    );
    try std.testing.expectEqual(ReasoningEffort.off, overridden.reasoning);
    const inherited = effectiveStartupSelection(null, null, persisted);
    try std.testing.expectEqualStrings(
        "omlx/persisted",
        inherited.model_id,
    );
    try std.testing.expectEqual(ReasoningEffort.high, inherited.reasoning);
}

test "active launch override can be promoted to the default" {
    try std.testing.expectEqual(
        SameModelAction.update_default,
        sameSelectionAction(
            .{ .model_id = "copilot/override", .reasoning = .high },
            .{ .model_id = "omlx/persisted", .reasoning = .off },
            .{ .model_id = "copilot/override", .reasoning = .high },
            true,
        ).?,
    );
    try std.testing.expectEqual(
        SameModelAction.unchanged,
        sameSelectionAction(
            .{ .model_id = "copilot/override", .reasoning = .high },
            .{ .model_id = "copilot/override", .reasoning = .high },
            .{ .model_id = "copilot/override", .reasoning = .high },
            true,
        ).?,
    );
    try std.testing.expectEqual(
        SameModelAction.unchanged,
        sameSelectionAction(
            .{ .model_id = "copilot/override", .reasoning = .high },
            null,
            .{ .model_id = "copilot/override", .reasoning = .high },
            false,
        ).?,
    );
    try std.testing.expect(
        sameSelectionAction(
            .{ .model_id = "copilot/current", .reasoning = .off },
            null,
            .{ .model_id = "copilot/other", .reasoning = .off },
            true,
        ) == null,
    );
}

test "hosted model mapping preserves raw SDK identity and capabilities" {
    const sdk_model: copilot.Model = .{
        .id = "gpt-test",
        .name = "GPT Test",
        .capabilities = .{
            .supports = .{ .vision = true, .reasoningEffort = true },
            .limits = .{
                .max_prompt_tokens = 200_000,
                .max_output_tokens = 32_000,
            },
        },
        .supportedReasoningEfforts = &.{ "low", "high", "future" },
        .defaultReasoningEffort = "high",
        .policy = .{ .state = .enabled },
    };

    try std.testing.expect(isUsableHostedModel(sdk_model));
    var plan = try copilotSessionPlan(
        std.testing.allocator,
        sdk_model,
        .high,
    );
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("copilot/gpt-test", plan.id());

    var info = try plan.info(std.testing.allocator);
    defer info.deinit();
    try std.testing.expectEqualStrings("GPT Test", info.display_name);
    try std.testing.expectEqual(@as(u64, 200_000), info.max_context_window_tokens);
    try std.testing.expectEqual(@as(u64, 32_000), info.max_output_tokens);
    try std.testing.expect(info.supports_vision);
    try std.testing.expect(info.reasoning.selectable.off);
    try std.testing.expect(info.reasoning.selectable.low);
    try std.testing.expect(info.reasoning.selectable.high);
    try std.testing.expect(!info.reasoning.selectable.medium);
    try std.testing.expectEqual(
        ReasoningEffort.high,
        info.reasoning.advertised_default.?,
    );

    const config = sessionConfigForPlan(
        "prompt",
        "/workspace",
        &plan,
        null,
    );
    try std.testing.expectEqualStrings("gpt-test", config.model.?);
    try std.testing.expect(config.provider == null);
    try std.testing.expectEqual(copilot.ReasoningEffort.high, config.reasoning_effort.?);
}

test "local models expose the product reasoning profile" {
    const profile = localReasoningProfile();
    try std.testing.expect(profile.selectable.off);
    try std.testing.expect(profile.selectable.low);
    try std.testing.expect(profile.selectable.medium);
    try std.testing.expect(profile.selectable.high);
    try std.testing.expect(profile.selectable.xhigh);
    try std.testing.expect(!profile.selectable.max);
    try std.testing.expectEqual(
        ReasoningEffort.off,
        profile.advertised_default.?,
    );
}

test "hosted models without reasoning advertise off only" {
    const sdk_model: copilot.Model = .{
        .id = "plain",
        .name = "Plain",
        .capabilities = .{
            .supports = .{ .reasoningEffort = false },
        },
        .supportedReasoningEfforts = &.{"high"},
        .defaultReasoningEffort = "high",
    };
    const profile = hostedReasoningProfile(sdk_model);
    try std.testing.expect(profile.selectable.off);
    try std.testing.expectEqual(@as(usize, 1), profile.selectable.count());
    try std.testing.expect(profile.advertised_default == null);
    try std.testing.expectError(
        error.UnsupportedReasoningEffort,
        copilotSessionPlan(std.testing.allocator, sdk_model, .high),
    );
}

test "hosted model policy and reserved identities are filtered" {
    const disabled: copilot.Model = .{
        .id = "disabled",
        .name = "Disabled",
        .capabilities = .{},
        .policy = .{ .state = .disabled },
    };
    const unconfigured: copilot.Model = .{
        .id = "unconfigured",
        .name = "Unconfigured",
        .capabilities = .{},
        .policy = .{ .state = .unconfigured },
    };
    const reserved: copilot.Model = .{
        .id = "default",
        .name = "Default",
        .capabilities = .{},
    };

    try std.testing.expect(!isUsableHostedModel(disabled));
    try std.testing.expect(!isUsableHostedModel(unconfigured));
    try std.testing.expect(!isUsableHostedModel(reserved));
}

test "Copilot SDK exposes typed local provider configuration" {
    const provider: copilot.ProviderConfig = .{
        .base_url = "http://localhost:11434/v1",
        .model_id = "qwen3-coder:30b",
        .max_prompt_tokens = 131_072,
        .max_output_tokens = 32_768,
    };

    try std.testing.expectEqualStrings(
        "http://localhost:11434/v1",
        provider.base_url,
    );
    try std.testing.expectEqualStrings(
        "qwen3-coder:30b",
        provider.model_id.?,
    );
    try std.testing.expectEqual(
        @as(?u64, 131_072),
        provider.max_prompt_tokens,
    );
    try std.testing.expectEqual(
        @as(?u64, 32_768),
        provider.max_output_tokens,
    );
    switch (provider.protocol) {
        .openai => |api| try std.testing.expect(api == .completions),
        else => return error.UnexpectedProviderProtocol,
    }
    try std.testing.expect(provider.authentication == .none);
}

test "minimal coding agent limits hosted tools to simplified subset" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{"--disable-builtin-mcps"},
        &MinimalCodingAgent.cli_args,
    );

    const options = MinimalCodingAgent.clientOptions("/workspace");
    try std.testing.expectEqualStrings(
        "/workspace",
        options.working_directory.?,
    );

    try std.testing.expectEqualSlices(
        []const u8,
        &.{
            "custom:*",
            "builtin:ask_user",
            "builtin:skill",
        },
        MinimalCodingAgent.sessionConfig(
            "minimal system prompt",
            "/workspace",
            null,
            .{},
        ).available_tools.?,
    );
}

test "minimal coding agent limits local tools to simplified subset" {
    const model = models.Model{
        .id = @constCast("omlx/local"),
        .provider_model_id = @constCast("local"),
        .display_name = @constCast("Local"),
        .max_context_window_tokens = 131_072,
        .max_output_tokens = 32_768,
        .supports_vision = false,
    };
    const config = MinimalCodingAgent.sessionConfig(
        "minimal system prompt",
        "/workspace",
        &model,
        .{},
    );

    try std.testing.expectEqualSlices(
        []const u8,
        &.{
            "custom:*",
            "builtin:ask_user",
            "builtin:skill",
        },
        config.available_tools.?,
    );
}

test "minimal coding agent appends Vivi tools to discovered instructions" {
    const config = MinimalCodingAgent.sessionConfig(
        "minimal system prompt",
        "/workspace",
        null,
        .{},
    );

    try std.testing.expect(config.streaming);
    try std.testing.expect(config.model_capabilities == null);
    try std.testing.expectEqual(@as(usize, 4), config.tools.len);
    try std.testing.expect(!config.request_permission);
    try std.testing.expect(config.on_permission_request.? == copilot.approveAll);
    const names = [_][]const u8{
        "read",
        "bash",
        "edit",
        "write",
    };
    for (config.tools, &names) |tool, name| {
        try std.testing.expectEqualStrings(name, tool.name);
        try std.testing.expect(tool.overrides_built_in_tool);
        try std.testing.expect(tool.skip_permission);
        try std.testing.expect(tool.handler == null);
        try std.testing.expect(!tool.is_terminal);
    }

    try std.testing.expectEqualStrings(
        "/workspace",
        config.working_directory.?,
    );
    try std.testing.expectEqual(false, config.enable_config_discovery.?);
    try std.testing.expectEqual(true, config.enable_skills.?);
    try std.testing.expect(config.skill_directories == null);
    try std.testing.expect(config.instruction_directories == null);
    try std.testing.expectEqual(false, config.skip_custom_instructions.?);
    try std.testing.expectEqual(
        true,
        config.enable_on_demand_instruction_discovery.?,
    );
    try std.testing.expectEqual(
        copilot.SystemMessageMode.append,
        config.system_message.?.mode,
    );
    try std.testing.expectEqualStrings(
        "minimal system prompt",
        config.system_message.?.content,
    );
}

test "workspace customization uses explicit absolute directories" {
    var directories = try WorkspaceCustomizationDirectories.init(
        std.testing.allocator,
        "/workspace",
    );
    defer directories.deinit();
    var config = copilot.SessionConfig{};
    directories.apply(&config);

    const expected_github = try std.fs.path.join(
        std.testing.allocator,
        &.{ "/workspace", ".github/skills" },
    );
    defer std.testing.allocator.free(expected_github);
    const expected_agents = try std.fs.path.join(
        std.testing.allocator,
        &.{ "/workspace", ".agents/skills" },
    );
    defer std.testing.allocator.free(expected_agents);
    const expected_claude = try std.fs.path.join(
        std.testing.allocator,
        &.{ "/workspace", ".claude/skills" },
    );
    defer std.testing.allocator.free(expected_claude);
    const expected_skills = [_][]const u8{
        expected_github,
        expected_agents,
        expected_claude,
    };
    for (expected_skills, config.skill_directories.?) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqualStrings(
        "/workspace",
        config.instruction_directories.?[0],
    );
}

test "automatic permission outcomes continue only after a handled decision" {
    try std.testing.expect(automaticPermissionFailure(.handled) == null);
    try std.testing.expectEqualStrings(
        "Copilot requested permission without an automatic handler.",
        automaticPermissionFailure(.not_configured).?,
    );
    try std.testing.expectEqualStrings(
        "Copilot requires manual permission approval, which vivi does not support yet.",
        automaticPermissionFailure(.no_result).?,
    );
    try std.testing.expectEqualStrings(
        "ApproveAllWithManagedSettings",
        automaticPermissionFailure(.{
            .handler_failed = error.ApproveAllWithManagedSettings,
        }).?,
    );
    try std.testing.expectEqualStrings(
        "PermissionDecisionNotAccepted",
        automaticPermissionFailure(.{
            .delivery_failed = error.PermissionDecisionNotAccepted,
        }).?,
    );
}

const FakeCommandClient = struct {
    allocator: std.mem.Allocator,
    response_json: []const u8,
    expected_name: []const u8,
    expected_input: []const u8,

    fn callRpc(
        self: *FakeCommandClient,
        comptime Result: type,
        method: []const u8,
        params: anytype,
    ) !std.json.Parsed(Result) {
        try std.testing.expectEqualStrings(
            "session.commands.invoke",
            method,
        );
        try std.testing.expectEqualStrings("session-1", params.sessionId);
        try std.testing.expectEqualStrings(self.expected_name, params.name);
        try std.testing.expectEqualStrings(self.expected_input, params.input);
        return std.json.parseFromSlice(
            Result,
            self.allocator,
            self.response_json,
            .{ .ignore_unknown_fields = true },
        );
    }
};

test "slash command invocation handles all interactive result kinds" {
    const session = .{ .id = "session-1" };
    var completed_client = FakeCommandClient{
        .allocator = std.testing.allocator,
        .response_json =
        \\{"kind":"completed","message":"Autopilot enabled"}
        ,
        .expected_name = "autopilot",
        .expected_input = "thorough",
    };
    var completed = try executeSdkCommand(
        std.testing.allocator,
        &completed_client,
        session,
        "/autopilot thorough",
    );
    defer completed.deinit(std.testing.allocator);
    switch (completed) {
        .completed => |message| try std.testing.expectEqualStrings(
            "Autopilot enabled",
            message,
        ),
        .agent_prompt => return error.UnexpectedAgentPrompt,
        .select_subcommand => return error.UnexpectedSubcommandSelection,
    }

    var prompt_client = FakeCommandClient{
        .allocator = std.testing.allocator,
        .response_json =
        \\{"kind":"agent-prompt","prompt":"Continue in autopilot mode"}
        ,
        .expected_name = "autopilot",
        .expected_input = "thorough",
    };
    var prompt = try executeSdkCommand(
        std.testing.allocator,
        &prompt_client,
        session,
        "/autopilot thorough",
    );
    defer prompt.deinit(std.testing.allocator);
    switch (prompt) {
        .completed => return error.UnexpectedCompletedCommand,
        .agent_prompt => |text| try std.testing.expectEqualStrings(
            "Continue in autopilot mode",
            text,
        ),
        .select_subcommand => return error.UnexpectedSubcommandSelection,
    }

    var select_client = FakeCommandClient{
        .allocator = std.testing.allocator,
        .response_json =
        \\{"kind":"select-subcommand","command":"chronicle","title":"Chronicle","options":[{"name":"list","description":"List entries"},{"name":"show","description":"Show an entry"}]}
        ,
        .expected_name = "chronicle",
        .expected_input = "",
    };
    var selected = try executeSdkCommand(
        std.testing.allocator,
        &select_client,
        session,
        "/chronicle",
    );
    defer selected.deinit(std.testing.allocator);
    switch (selected) {
        .completed => return error.UnexpectedCompletedCommand,
        .agent_prompt => return error.UnexpectedAgentPrompt,
        .select_subcommand => |selection| {
            try std.testing.expectEqualStrings(
                "chronicle",
                selection.command,
            );
            try std.testing.expectEqualStrings("Chronicle", selection.title);
            try std.testing.expectEqual(@as(usize, 2), selection.options.len);
            const next_input = try selectedSubcommandInput(
                std.testing.allocator,
                selection,
                "show",
            );
            defer std.testing.allocator.free(next_input);
            try std.testing.expectEqualStrings("chronicle show", next_input);
        },
    }
}

test "OMLX model configuration carries detected token limits and vision capability" {
    var model = models.Model{
        .id = @constCast("omlx/Qwen3.5-9B-mxfp4"),
        .provider_model_id = @constCast("Qwen3.5-9B-mxfp4"),
        .display_name = @constCast("Qwen 3.5 9B"),
        .max_context_window_tokens = 262_144,
        .max_output_tokens = 49_152,
        .supports_vision = false,
    };
    const config = MinimalCodingAgent.sessionConfig(
        "prompt",
        "/workspace",
        &model,
        .{
            .base_url = "http://localhost:8000/v1",
            .api_key = "omlx",
        },
    );

    const provider = config.provider.?;
    try std.testing.expectEqualStrings(
        "Qwen3.5-9B-mxfp4",
        provider.model_id.?,
    );
    try std.testing.expectEqual(
        @as(?u64, 262_144),
        provider.max_prompt_tokens,
    );
    try std.testing.expectEqual(
        @as(?u64, 49_152),
        provider.max_output_tokens,
    );
    try std.testing.expectEqual(false, config.model_capabilities.?.supports.?.vision.?);
    model.supports_vision = true;
    const vision_config = MinimalCodingAgent.sessionConfig("prompt", "/workspace", &model, .{});
    try std.testing.expectEqual(true, vision_config.model_capabilities.?.supports.?.vision.?);
    try std.testing.expectEqualStrings("Qwen3.5-9B-mxfp4", vision_config.provider.?.wire_model.?);
}
