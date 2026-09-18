const std = @import("std");
const terminal_browser = @import("terminal_browser");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedAbsoluteTerminalBrowserPath;

    var executable = try terminal_browser.TrustedExecutable.init(
        init.gpa,
        init.io,
        args[1],
    );
    defer executable.deinit(init.gpa);
    try terminal_browser.verifyVersion(
        init.gpa,
        init.io,
        init.environ_map,
        executable,
        .{},
    );
    try terminal_browser.verifyHelpContract(
        init.gpa,
        init.io,
        init.environ_map,
        executable,
        .{},
    );

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"version\":\"{s}\",\"tag\":\"{s}\",\"commit\":\"{s}\",\"commands\":\"verified\",\"ownership\":\"unproven\",\"result\":\"probe-only-no-go\"}}\n",
        .{
            terminal_browser.supported_version,
            terminal_browser.supported_tag,
            terminal_browser.supported_commit,
        },
    );
    try stdout.flush();
}
