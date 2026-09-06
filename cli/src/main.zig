const std = @import("std");
const backend = @import("vivi_backend");

const Command = enum {
    help,
    version,

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
    }
    try stdout.flush();
}

fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: vivi [--help] [--version]
        \\
        \\Vivi command-line interface.
        \\Copilot operations are not implemented in this scaffold.
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
}

test "command parser rejects product commands" {
    try std.testing.expectError(
        error.InvalidArguments,
        Command.parse(&.{ "vivi", "chat" }),
    );
}
