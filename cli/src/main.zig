const std = @import("std");
const backend = @import("vivi_backend");
const chat = @import("chat.zig");

const Command = enum {
    help,
    version,
    chat,

    fn parse(args: []const []const u8) error{InvalidArguments}!Command {
        if (args.len <= 1) return .help;
        if (args.len != 2) return error.InvalidArguments;

        if (std.mem.eql(u8, args[1], "--help") or
            std.mem.eql(u8, args[1], "-h"))
        {
            return .help;
        }
        if (std.mem.eql(u8, args[1], "--version") or
            std.mem.eql(u8, args[1], "-V"))
        {
            return .version;
        }
        if (std.mem.eql(u8, args[1], "chat")) return .chat;
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
        .chat => {
            try stdout.flush();
            return chat.run(init);
        },
    }
    try stdout.flush();
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: vivi [--help] [--version] [chat]
        \\
        \\Vivi command-line interface.
        \\
        \\Commands:
        \\  chat       Start an interactive streaming Vivi chat.
        \\
    );
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
        Command.chat,
        try Command.parse(&.{ "vivi", "chat" }),
    );
}
