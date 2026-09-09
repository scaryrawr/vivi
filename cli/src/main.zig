const std = @import("std");
const backend = @import("vivi_backend");
const chat = @import("chat.zig");

const ChatOptions = struct {
    model: ?[]const u8 = null,
};

const Command = union(enum) {
    help,
    version,
    models,
    chat: ChatOptions,

    fn parse(args: []const []const u8) error{InvalidArguments}!Command {
        if (args.len <= 1) return .help;

        if (args.len == 2 and
            (std.mem.eql(u8, args[1], "--help") or
                std.mem.eql(u8, args[1], "-h")))
        {
            return .help;
        }
        if (args.len == 2 and
            (std.mem.eql(u8, args[1], "--version") or
                std.mem.eql(u8, args[1], "-V")))
        {
            return .version;
        }
        if (args.len == 2 and std.mem.eql(u8, args[1], "models")) {
            return .models;
        }
        if (std.mem.eql(u8, args[1], "chat")) {
            if (args.len == 2) return .{ .chat = .{} };
            if (args.len == 4 and
                std.mem.eql(u8, args[2], "--model"))
            {
                return .{ .chat = .{ .model = args[3] } };
            }
        }
        return error.InvalidArguments;
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer =
        .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const command = Command.parse(args) catch {
        try writeHelp(stdout);
        try stdout.flush();
        return error.InvalidArguments;
    };

    switch (command) {
        .help => try writeHelp(stdout),
        .version => try stdout.print("vivi {s}\n", .{backend.version}),
        .models => try listModels(init, stdout),
        .chat => |options| {
            try stdout.flush();
            const settings_path = try defaultSettingsPath(
                init.gpa,
                init.environ_map,
            );
            defer if (settings_path) |path| init.gpa.free(path);
            const sessions_directory = try defaultSessionsDirectory(
                init.gpa,
                init.environ_map,
            );
            defer if (sessions_directory) |path| init.gpa.free(path);
            return chat.run(
                init,
                options.model,
                settings_path,
                sessions_directory,
            );
        },
    }
    try stdout.flush();
}

fn defaultSessionsDirectory(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    const home = usableHome(environ_map.get("HOME")) orelse
        usableHome(environ_map.get("USERPROFILE")) orelse return null;
    return @as(
        ?[]u8,
        try std.fs.path.join(
            allocator,
            &.{ home, ".vivi", "sessions" },
        ),
    );
}

fn defaultSettingsPath(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !?[]u8 {
    const home = usableHome(environ_map.get("HOME")) orelse
        usableHome(environ_map.get("USERPROFILE")) orelse return null;
    return @as(
        ?[]u8,
        try std.fs.path.join(
            allocator,
            &.{ home, ".vivi", "settings.json" },
        ),
    );
}

fn usableHome(value: ?[]const u8) ?[]const u8 {
    const path = value orelse return null;
    return if (path.len == 0) null else path;
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: vivi [--help] [--version] [models] [chat [--model MODEL]]
        \\
        \\Vivi command-line interface.
        \\
        \\Commands:
        \\  models     List available Copilot and OMLX models.
        \\  chat       Start an interactive streaming Vivi chat.
        \\
    );
}

fn listModels(init: std.process.Init, writer: *std.Io.Writer) !void {
    var catalog = try backend.discoverModels(
        init.gpa,
        init.io,
        init.environ_map.get("PWD") orelse ".",
        .{
            .base_url = init.environ_map.get("OMLX_BASE_URL") orelse
                backend.default_omlx_base_url,
            .api_key = init.environ_map.get("OMLX_API_KEY") orelse "omlx",
        },
    );
    defer catalog.deinit();

    for (catalog.models) |model| {
        try writer.print(
            "{s}\t{s}\tcontext={d}\toutput={d}\tvision={s}\n",
            .{
                model.id,
                model.display_name,
                model.max_context_window_tokens,
                model.max_output_tokens,
                if (model.supports_vision) "yes" else "no",
            },
        );
    }
}

test "command parser accepts scaffold commands" {
    try std.testing.expectEqual(
        Command.help,
        try Command.parse(&.{"vivi"}),
    );
    try std.testing.expectEqual(
        Command.help,
        try Command.parse(&.{ "vivi", "--help" }),
    );
    try std.testing.expectEqual(
        Command.version,
        try Command.parse(&.{ "vivi", "--version" }),
    );
    try std.testing.expectEqual(
        Command{ .chat = .{} },
        try Command.parse(&.{ "vivi", "chat" }),
    );
    try std.testing.expectEqual(
        Command.models,
        try Command.parse(&.{ "vivi", "models" }),
    );
    const chat_model = try Command.parse(
        &.{ "vivi", "chat", "--model", "omlx/model" },
    );
    try std.testing.expectEqualStrings(
        "omlx/model",
        chat_model.chat.model.?,
    );
}

test "settings path uses the supplied home directory" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/tmp/vivi-home");
    const path = try defaultSettingsPath(std.testing.allocator, &environment);
    defer std.testing.allocator.free(path.?);
    try std.testing.expectEqualStrings(
        "/tmp/vivi-home/.vivi/settings.json",
        path.?,
    );
}

test "settings persistence is optional without a home directory" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try std.testing.expect(
        try defaultSettingsPath(std.testing.allocator, &environment) == null,
    );
}

test "sessions directory uses the supplied home directory" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "/tmp/vivi-home");
    const path = try defaultSessionsDirectory(
        std.testing.allocator,
        &environment,
    );
    defer std.testing.allocator.free(path.?);
    try std.testing.expectEqualStrings(
        "/tmp/vivi-home/.vivi/sessions",
        path.?,
    );
}

test "empty HOME falls back to USERPROFILE" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", "");
    try environment.put("USERPROFILE", "C:\\Users\\vivi");
    const path = try defaultSettingsPath(std.testing.allocator, &environment);
    defer std.testing.allocator.free(path.?);
    try std.testing.expectEqualStrings(
        "C:\\Users\\vivi/.vivi/settings.json",
        path.?,
    );
}
