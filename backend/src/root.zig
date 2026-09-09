const std = @import("std");
const build_options = @import("build_options");
const copilot = @import("copilot_sdk");
const conversation = @import("conversation.zig");
const models = @import("models.zig");
const settings = @import("settings.zig");
const tools = @import("tools.zig");

pub const version = build_options.version;
pub const abi_version: u32 = 1;
pub const Conversation = conversation.Conversation;
pub const ConversationEvent = conversation.Event;
pub const ConversationWake = conversation.Wake;
pub const PromptDelivery = conversation.PromptDelivery;
pub const CommandCatalog = conversation.CommandCatalog;
pub const UserInputRequest = conversation.UserInputRequest;
pub const ModelCatalog = conversation.ModelCatalog;
pub const ModelInfo = conversation.ModelInfo;
pub const OmlxCatalog = models.Catalog;
pub const OmlxModel = models.Model;
pub const OmlxOptions = models.OmlxOptions;
pub const default_omlx_base_url = models.default_omlx_base_url;
pub const Settings = settings.Settings;
pub const loadSettings = settings.load;
pub const saveDefaultModel = settings.saveDefaultModel;

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
    settings_path: ?[]const u8 = null,
    omlx: OmlxOptions = .{},
};

const ConversationContext = struct {
    model: ?[]u8,
    settings_path: ?[]u8,
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

        context.* = .{
            .model = model,
            .settings_path = settings_path,
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
    const cli_args = [_][]const u8{
        "--available-tools=custom:*,builtin:ask_user,builtin:task_complete,builtin:exit_plan_mode,builtin:task,builtin:read_agent,builtin:write_agent,builtin:list_agents,builtin:send_inbox,builtin:context_board,builtin:skill",
        "--disable-builtin-mcps",
        "--no-custom-instructions",
    };

    const system_prompt =
        \\You are Vivi, a coding assistant.
        \\Use ask_user when a decision is required. Use read, bash, edit, and write to work in the user's workspace.
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
            .streaming = true,
            .tools = &sdk_tools,
            .system_message = .{
                .mode = .replace,
                .content = prompt,
            },
            .request_permission = false,
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

fn effectiveStartupModel(
    model_override: ?[]const u8,
    persisted_model: ?[]const u8,
) ?[]const u8 {
    return model_override orelse persisted_model;
}

const SameModelAction = enum {
    unchanged,
    update_default,
};

fn sameModelAction(
    active_model: []const u8,
    persisted_model: ?[]const u8,
    requested_model: []const u8,
    can_persist: bool,
) ?SameModelAction {
    if (!std.mem.eql(u8, active_model, requested_model)) return null;
    if (!can_persist) return .unchanged;
    if (persisted_model) |persisted| {
        if (std.mem.eql(u8, persisted, requested_model)) return .unchanged;
    }
    return .update_default;
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
    prompt: []const u8,
    delivery: conversation.PromptDelivery,
) !void {
    const parsed = try session.client.callRpc(
        struct { messageId: []const u8 },
        "session.send",
        .{
            .sessionId = session.id,
            .prompt = prompt,
            .mode = @tagName(delivery),
        },
    );
    parsed.deinit();
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
                    prompt.text.bytes,
                    prompt.delivery,
                );
                result = .sent;
            },
            .stop => return .stop,
            .refresh_commands,
            .refresh_models,
            .switch_model,
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
            try sendPrompt(session, prompt.text.bytes, .immediate);
            try worker.assistantStarted();
            return .sent;
        },
        .stop => return .stop,
        .refresh_commands,
        .refresh_models,
        .switch_model,
        .execute_command,
        .user_input_response,
        => {
            return error.UnexpectedStreamingCommand;
        },
    }
}

const InvokedCommand = union(enum) {
    completed: []u8,
    agent_prompt: []u8,

    fn deinit(self: *InvokedCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed, .agent_prompt => |text| allocator.free(text),
        }
        self.* = undefined;
    }
};

fn executeSdkCommand(
    allocator: std.mem.Allocator,
    client: *copilot.Client,
    session: copilot.Session,
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
    },
    omlx: struct {
        id: []u8,
        provider_model_id: []u8,
        display_name: []u8,
        provider_base_url: []u8,
        max_context_window_tokens: u64,
        max_output_tokens: u64,
        supports_vision: bool,
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
            },
            .copilot => |value| .{
                .allocator = allocator,
                .id = owned_id,
                .display_name = try allocator.dupe(u8, value.display_name),
                .max_context_window_tokens = value.max_context_window_tokens,
                .max_output_tokens = value.max_output_tokens,
                .supports_vision = value.supports_vision,
            },
            .omlx => |value| .{
                .allocator = allocator,
                .id = owned_id,
                .display_name = try allocator.dupe(u8, value.display_name),
                .max_context_window_tokens = value.max_context_window_tokens,
                .max_output_tokens = value.max_output_tokens,
                .supports_vision = value.supports_vision,
            },
        };
    }
};

fn resolveSessionPlan(
    allocator: std.mem.Allocator,
    client: *copilot.Client,
    io: std.Io,
    requested_model: ?[]const u8,
    omlx: OmlxOptions,
) !SessionPlan {
    const model_id = requested_model orelse return .hosted;
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
                return copilotSessionPlan(allocator, model);
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
    } };
}

fn copilotSessionPlan(
    allocator: std.mem.Allocator,
    model: copilot.Model,
) !SessionPlan {
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
    } };
}

fn createSdkSession(
    worker: *conversation.Worker,
    client: *copilot.Client,
    system_prompt: []const u8,
    working_directory: []const u8,
    plan: *const SessionPlan,
    api_key: ?[]const u8,
) !copilot.Session {
    var config = sessionConfigForPlan(
        system_prompt,
        working_directory,
        plan,
        api_key,
    );
    config.on_user_input_request = handleSdkUserInput;
    config.user_input_context = worker;
    return client.createSession(config);
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
            var plan = try copilotSessionPlan(allocator, model);
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
        .selected_id = try allocator.dupe(u8, selected.id()),
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

    var count: usize = 1;
    for (sdk_commands) |command| {
        if (!std.ascii.eqlIgnoreCase(command.name, "model")) count += 1;
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
    const model_name = try allocator.dupe(u8, "model");
    errdefer allocator.free(model_name);
    const model_description = try allocator.dupe(
        u8,
        if (sdk_model) |command|
            command.description
        else
            "Switch the model for new turns",
    );
    commands[0] = .{
        .name = model_name,
        .description = model_description,
    };
    initialized += 1;
    for (sdk_commands) |command| {
        if (std.ascii.eqlIgnoreCase(command.name, "model")) continue;
        commands[initialized] = .{
            .name = try allocator.dupe(u8, command.name),
            .description = undefined,
        };
        errdefer allocator.free(commands[initialized].name);
        commands[initialized].description = try allocator.dupe(
            u8,
            command.description,
        );
        initialized += 1;
    }
    return .{ .allocator = allocator, .commands = commands };
}

fn buildFallbackCommandCatalog(
    allocator: std.mem.Allocator,
) !conversation.CommandCatalog {
    const commands = try allocator.alloc(conversation.CommandInfo, 1);
    errdefer allocator.free(commands);
    const name = try allocator.dupe(u8, "model");
    errdefer allocator.free(name);
    commands[0] = .{
        .name = name,
        .description = try allocator.dupe(
            u8,
            "Switch the model for new turns",
        ),
    };
    return .{ .allocator = allocator, .commands = commands };
}

const StreamResult = enum {
    idle,
    stopped,
    failed,
};

fn streamSessionResponse(
    worker: *conversation.Worker,
    client: *copilot.Client,
    session: copilot.Session,
    tool_service: *tools.Service,
) StreamResult {
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
            .permission_requested => {
                worker.closeFailure(
                    .stream,
                    "Copilot requested a permission that vivi cannot handle yet.",
                );
                return .failed;
            },
            .external_tool_requested => |request| {
                var result = tool_service.executeJson(
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
                defer result.deinit(worker.allocator());
                switch (result) {
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
            .unknown => |unknown| {
                if (std.mem.eql(
                    u8,
                    unknown.event_type,
                    "commands.changed",
                )) {
                    if (buildCommandCatalog(
                        worker.allocator(),
                        client,
                        session,
                    )) |catalog| {
                        worker.commandCatalog(catalog) catch {
                            var mutable = catalog;
                            mutable.deinit();
                        };
                    } else |_| {}
                }
            },
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
    const working_directory = cwd_buffer[0..cwd_len];
    var tool_service = tools.Service.init(
        worker.allocator(),
        worker.io(),
        working_directory,
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer tool_service.deinit();

    var client = copilot.Client.init(
        worker.allocator(),
        worker.io(),
        MinimalCodingAgent.clientOptions(working_directory),
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer client.deinit();
    const system_prompt = std.fmt.allocPrint(
        worker.allocator(),
        MinimalCodingAgent.system_prompt,
        .{working_directory},
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    defer worker.allocator().free(system_prompt);

    const omlx_options = OmlxOptions{
        .base_url = context.omlx_base_url,
        .api_key = context.omlx_api_key,
    };
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

    var active_plan = resolveSessionPlan(
        worker.allocator(),
        &client,
        worker.io(),
        effectiveStartupModel(context.model, persisted_settings.default_model),
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
        working_directory,
        &active_plan,
        context.omlx_api_key,
    ) catch |err| {
        worker.closeFailure(.startup, @errorName(err));
        return;
    };
    var session_connected = true;
    defer if (session_connected) session.disconnect() catch {};

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
    if (initial_commands) |catalog| worker.commandCatalog(catalog) catch {
        var mutable = catalog;
        mutable.deinit();
    };
    if (buildModelCatalog(
        worker.allocator(),
        &client,
        worker.io(),
        &active_plan,
        omlx_options,
    )) |catalog| {
        worker.modelCatalog(catalog) catch {
            var mutable = catalog;
            mutable.deinit();
        };
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
                    var mutable = catalog;
                    mutable.deinit();
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
                    var mutable = catalog;
                    mutable.deinit();
                    worker.closeFailure(
                        .stream,
                        "Unable to deliver the model catalog.",
                    );
                    return;
                };
            },
            .execute_command => |requested| {
                var result = executeSdkCommand(
                    worker.allocator(),
                    &client,
                    session,
                    requested.bytes,
                ) catch |err| {
                    worker.commandCompleted(@errorName(err)) catch {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    continue;
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
                    },
                    .agent_prompt => |prompt| {
                        sendPrompt(session, prompt, .immediate) catch |err| {
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
                    },
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
                    requested.bytes,
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
                if (sameModelAction(
                    active_plan.id(),
                    persisted_settings.default_model,
                    target_plan.id(),
                    context.settings_path != null,
                )) |action| {
                    const info = target_plan.info(worker.allocator()) catch |err| {
                        target_plan.deinit(worker.allocator());
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    if (action == .update_default) {
                        const path = context.settings_path.?;
                        const persisted_model = worker.allocator().dupe(
                            u8,
                            target_plan.id(),
                        ) catch |err| {
                            target_plan.deinit(worker.allocator());
                            var mutable = info;
                            mutable.deinit();
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        settings.saveDefaultModel(
                            worker.allocator(),
                            worker.io(),
                            path,
                            target_plan.id(),
                        ) catch |err| {
                            worker.allocator().free(persisted_model);
                            target_plan.deinit(worker.allocator());
                            var mutable = info;
                            mutable.deinit();
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
                        if (persisted_settings.default_model) |current| {
                            worker.allocator().free(current);
                        }
                        persisted_settings.default_model = persisted_model;
                    }
                    target_plan.deinit(worker.allocator());
                    worker.completeModelSwitch(if (action == .unchanged)
                        .{ .unchanged = info }
                    else
                        .{ .default_updated = info }) catch {
                        var mutable = info;
                        mutable.deinit();
                        worker.closeFailure(
                            .stream,
                            "Unable to report the selected model.",
                        );
                        return;
                    };
                    continue;
                }

                var candidate = createSdkSession(
                    worker,
                    &client,
                    system_prompt,
                    working_directory,
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
                const persisted_model = if (context.settings_path) |path| blk: {
                    const value = worker.allocator().dupe(
                        u8,
                        target_plan.id(),
                    ) catch |err| {
                        candidate.disconnect() catch {};
                        target_plan.deinit(worker.allocator());
                        var mutable = info;
                        mutable.deinit();
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    settings.saveDefaultModel(
                        worker.allocator(),
                        worker.io(),
                        path,
                        target_plan.id(),
                    ) catch |err| {
                        worker.allocator().free(value);
                        candidate.disconnect() catch {};
                        target_plan.deinit(worker.allocator());
                        var mutable = info;
                        mutable.deinit();
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

                const previous_session = session;
                session_connected = false;
                session = candidate;
                session_connected = true;
                active_plan.deinit(worker.allocator());
                active_plan = target_plan;
                if (persisted_model) |value| {
                    if (persisted_settings.default_model) |current| {
                        worker.allocator().free(current);
                    }
                    persisted_settings.default_model = value;
                }
                const cleanup_failed = if (previous_session.disconnect())
                    false
                else |_|
                    true;
                worker.completeModelSwitch(.{ .switched = .{
                    .model = info,
                    .history = .reset_visible_transcript_preserved,
                    .default_saved = persisted_model != null,
                    .cleanup_failed = cleanup_failed,
                } }) catch {
                    var mutable = info;
                    mutable.deinit();
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
                    worker.commandCatalog(catalog) catch {
                        var mutable = catalog;
                        mutable.deinit();
                    };
                } else |_| {}
            },
            .prompt => |prompt| {
                sendPrompt(
                    session,
                    prompt.text.bytes,
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
            },
        }
    }
}

test "scaffold status is stable" {
    const status = scaffoldStatus();

    try std.testing.expectEqual(abi_version, status.abi_version);
    try std.testing.expectEqual(Lifecycle.scaffold, status.lifecycle);
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

test "explicit model overrides persisted startup default" {
    try std.testing.expectEqualStrings(
        "copilot/override",
        effectiveStartupModel(
            "copilot/override",
            "omlx/persisted",
        ).?,
    );
    try std.testing.expectEqualStrings(
        "omlx/persisted",
        effectiveStartupModel(null, "omlx/persisted").?,
    );
}

test "active launch override can be promoted to the default" {
    try std.testing.expectEqual(
        SameModelAction.update_default,
        sameModelAction(
            "copilot/override",
            "omlx/persisted",
            "copilot/override",
            true,
        ).?,
    );
    try std.testing.expectEqual(
        SameModelAction.unchanged,
        sameModelAction(
            "copilot/override",
            "copilot/override",
            "copilot/override",
            true,
        ).?,
    );
    try std.testing.expectEqual(
        SameModelAction.unchanged,
        sameModelAction(
            "copilot/override",
            null,
            "copilot/override",
            false,
        ).?,
    );
    try std.testing.expect(
        sameModelAction(
            "copilot/current",
            null,
            "copilot/other",
            true,
        ) == null,
    );
}

test "hosted model mapping preserves raw SDK identity and capabilities" {
    const sdk_model: copilot.Model = .{
        .id = "gpt-test",
        .name = "GPT Test",
        .capabilities = .{
            .supports = .{ .vision = true },
            .limits = .{
                .max_prompt_tokens = 200_000,
                .max_output_tokens = 32_000,
            },
        },
        .policy = .{ .state = .enabled },
    };

    try std.testing.expect(isUsableHostedModel(sdk_model));
    var plan = try copilotSessionPlan(std.testing.allocator, sdk_model);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("copilot/gpt-test", plan.id());

    var info = try plan.info(std.testing.allocator);
    defer info.deinit();
    try std.testing.expectEqualStrings("GPT Test", info.display_name);
    try std.testing.expectEqual(@as(u64, 200_000), info.max_context_window_tokens);
    try std.testing.expectEqual(@as(u64, 32_000), info.max_output_tokens);
    try std.testing.expect(info.supports_vision);

    const config = sessionConfigForPlan(
        "prompt",
        "/workspace",
        &plan,
        null,
    );
    try std.testing.expectEqualStrings("gpt-test", config.model.?);
    try std.testing.expect(config.provider == null);
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

test "minimal coding agent enables isolated builtins" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{
            "--available-tools=custom:*,builtin:ask_user,builtin:task_complete,builtin:exit_plan_mode,builtin:task,builtin:read_agent,builtin:write_agent,builtin:list_agents,builtin:send_inbox,builtin:context_board,builtin:skill",
            "--disable-builtin-mcps",
            "--no-custom-instructions",
        },
        &MinimalCodingAgent.cli_args,
    );

    const options = MinimalCodingAgent.clientOptions("/workspace");
    try std.testing.expectEqualStrings(
        "/workspace",
        options.working_directory.?,
    );
}

test "minimal coding agent replaces the system prompt with Vivi tools" {
    const config = MinimalCodingAgent.sessionConfig(
        "minimal system prompt",
        "/workspace",
        null,
        .{},
    );

    try std.testing.expect(config.streaming);
    try std.testing.expectEqual(@as(usize, 4), config.tools.len);
    try std.testing.expect(!config.request_permission);
    const names = [_][]const u8{ "read", "bash", "edit", "write" };
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
    try std.testing.expectEqual(
        copilot.SystemMessageMode.replace,
        config.system_message.?.mode,
    );
    try std.testing.expectEqualStrings(
        "minimal system prompt",
        config.system_message.?.content,
    );
}

test "OMLX model configuration carries detected token limits" {
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
}
