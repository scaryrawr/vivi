const std = @import("std");
const build_options = @import("build_options");
const copilot = @import("copilot_sdk");
const conversation = @import("conversation.zig");
const tools = @import("tools.zig");

pub const version = build_options.version;
pub const abi_version: u32 = 1;
pub const Conversation = conversation.Conversation;
pub const ConversationEvent = conversation.Event;
pub const ConversationWake = conversation.Wake;

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

pub fn openConversation(
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: ConversationWake,
) !Conversation {
    return conversation.openWithRunner(allocator, io, wake, runSdkConversation);
}

const MinimalCodingAgent = struct {
    const cli_args = [_][]const u8{
        "--excluded-tools=builtin:*",
        "--disable-builtin-mcps",
        "--no-custom-instructions",
        "--no-ask-user",
    };

    const system_prompt =
        \\You are Vivi, a coding assistant.
        \\Use read, bash, edit, and write to work in the user's workspace.
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
    ) copilot.SessionConfig {
        return .{
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

fn runSdkConversation(worker: *conversation.Worker) void {
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

    var session = client.createSession(
        MinimalCodingAgent.sessionConfig(system_prompt, working_directory),
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
            .prompt => |prompt| {
                const message_id = session.send(.{
                    .prompt = prompt.bytes,
                }) catch |err| {
                    worker.closeFailure(.stream, @errorName(err));
                    return;
                };
                worker.allocator().free(message_id);

                while (true) {
                    var event = session.nextEvent() catch |err| {
                        worker.closeFailure(.stream, @errorName(err));
                        return;
                    };
                    defer event.deinit(worker.allocator());

                    switch (event) {
                        .assistant_message_delta => |delta| {
                            worker.assistantDelta(delta.delta_content) catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to deliver streamed output.",
                                );
                                return;
                            };
                        },
                        .assistant_message => |message| {
                            worker.assistantComplete(message.content) catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to deliver the completed response.",
                                );
                                return;
                            };
                        },
                        .session_idle => |idle| {
                            if (idle.mode != null and
                                std.mem.eql(
                                    u8,
                                    idle.mode.?,
                                    "autopilot",
                                ))
                            {
                                continue;
                            }
                            worker.idle() catch {
                                worker.closeFailure(
                                    .stream,
                                    "Unable to finish the streamed response.",
                                );
                                return;
                            };
                            break;
                        },
                        .session_error => |failure| {
                            worker.closeFailure(.stream, failure.message);
                            return;
                        },
                        .permission_requested => {
                            worker.closeFailure(
                                .stream,
                                "Copilot requested a permission that vivi cannot handle yet.",
                            );
                            return;
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
                                    return;
                                };
                                continue;
                            };
                            defer result.deinit(worker.allocator());
                            switch (result) {
                                .text => |text| session.respondToTool(
                                    request.request_id,
                                    text,
                                ) catch |err| {
                                    worker.closeFailure(
                                        .stream,
                                        @errorName(err),
                                    );
                                    return;
                                },
                                .failure => |message| session.respondToToolError(
                                    request.request_id,
                                    message,
                                ) catch |err| {
                                    worker.closeFailure(
                                        .stream,
                                        @errorName(err),
                                    );
                                    return;
                                },
                            }
                        },
                        .unknown => {},
                    }

                    if (worker.stopRequested()) {
                        session.disconnect() catch |err| {
                            worker.closeFailure(.stream, @errorName(err));
                            return;
                        };
                        session_connected = false;
                        worker.closeRequested();
                        return;
                    }
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
}

test "minimal coding agent disables ambient Copilot capabilities" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{
            "--excluded-tools=builtin:*",
            "--disable-builtin-mcps",
            "--no-custom-instructions",
            "--no-ask-user",
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
