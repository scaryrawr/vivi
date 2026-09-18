const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const scenario = init.environ_map.get("VIVI_TB_FIXTURE_SCENARIO") orelse "success";

    if (std.mem.eql(u8, scenario, "timeout")) {
        try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        return;
    }
    if (std.mem.eql(u8, scenario, "crash")) std.process.exit(7);
    if (std.mem.eql(u8, scenario, "nonzero")) {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        try stderr_writer.interface.writeAll("terminal-browser: fixture failure\n");
        try stderr_writer.interface.flush();
        std.process.exit(1);
    }
    if (std.mem.eql(u8, scenario, "overflow")) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        for (0..1024) |_| try stdout.writeAll("0123456789abcdef");
        try stdout.flush();
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (args.len == 3 and std.mem.eql(u8, args[2], "--help")) {
        if (std.mem.eql(u8, args[1], "open")) {
            try stdout.writeAll(
                "Usage: terminal-browser open [url] [options]\n--no-merge\n--allow-clipboard-read\n",
            );
        } else if (std.mem.eql(u8, args[1], "new-tab")) {
            try stdout.writeAll(
                "Usage: terminal-browser new-tab [url] [options]\n--browser <key>\n",
            );
        } else if (std.mem.eql(u8, args[1], "ls")) {
            try stdout.writeAll(
                "Usage: terminal-browser ls [options]\n--all\n--json\n",
            );
        } else if (std.mem.eql(u8, args[1], "action")) {
            try stdout.writeAll(
                "Usage: terminal-browser action [selectors] -- <command>\n--browser <key>\n--tab <id>\n--target <id>\n",
            );
        } else {
            std.process.exit(2);
        }
        try stdout.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        if (std.mem.eql(u8, scenario, "wrong-version")) {
            try stdout.writeAll("terminal-browser v0.12.0\n");
        } else {
            try stdout.writeAll("terminal-browser v0.11.1\n");
        }
        try stdout.flush();
        return;
    }

    if (args.len == 3 and
        std.mem.eql(u8, args[1], "ls") and
        std.mem.eql(u8, args[2], "--json"))
    {
        if (std.mem.eql(u8, scenario, "malformed-json")) {
            try stdout.writeAll("{");
        } else if (std.mem.eql(u8, scenario, "invalid-utf8")) {
            try stdout.writeAll(&.{0xff});
        } else if (std.mem.eql(u8, scenario, "unknown-schema")) {
            try stdout.writeAll(
                \\{"self":null,"browsers":[],"futureField":true}
            );
        } else if (std.mem.eql(u8, scenario, "duplicate-identifiers")) {
            try stdout.writeAll(duplicate_list);
        } else if (std.mem.eql(u8, scenario, "duplicate-tabs")) {
            try stdout.writeAll(duplicate_tabs_list);
        } else {
            try stdout.writeAll(valid_list);
        }
        try stdout.writeByte('\n');
        try stdout.flush();
        return;
    }

    if (args.len == 3 and
        std.mem.eql(u8, args[1], "open") and
        std.mem.eql(u8, args[2], "--app-mode"))
    {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        try stderr_writer.interface.writeAll(
            "terminal-browser: app mode was removed; migrate to zenbu-labs/pixel\n",
        );
        try stderr_writer.interface.flush();
        std.process.exit(1);
    }

    if (args.len == 5 and
        std.mem.eql(u8, args[1], "new-tab") and
        std.mem.eql(u8, args[3], "--browser"))
    {
        try stdout.writeAll(valid_new_tab);
        try stdout.writeByte('\n');
        try stdout.flush();
        return;
    }

    if (args.len == 4 and
        std.mem.eql(u8, args[1], "open") and
        std.mem.eql(u8, args[2], "--no-merge"))
    {
        if (!std.mem.eql(u8, scenario, "partial-startup"))
            std.process.exit(2);
        try std.Io.sleep(init.io, .fromSeconds(10), .awake);
        return;
    }

    if (args.len == 9 and
        std.mem.eql(u8, args[1], "action") and
        std.mem.eql(u8, args[2], "--browser") and
        std.mem.eql(u8, args[4], "--tab") and
        std.mem.eql(u8, args[6], "--") and
        std.mem.eql(u8, args[7], "tab") and
        std.mem.eql(u8, args[8], "close"))
    {
        try stdout.writeAll("{}\n");
        try stdout.flush();
        return;
    }

    std.process.exit(2);
}

const valid_list =
    \\{"self":{"tab":"terminal-tab","pane":"terminal-pane"},"browsers":[{"key":"100-1","pid":100,"cdpPort":9222,"socket":"/fixture/100-1.sock","tty":"/dev/ttys001","pane":{"tab":"terminal-tab","pane":"terminal-pane"},"splitDir":"right","parentTty":"/dev/ttys000","inCurrentTab":true,"viewport":{"width":1200,"height":800},"tabs":[{"id":1,"url":"http://127.0.0.1:43117/canvas","title":"Canvas","active":true,"targetId":"target-1","timeOrigin":1.0,"agentControlled":false}]}]}
;

const duplicate_list =
    \\{"self":null,"browsers":[{"key":"100-1","pid":100,"cdpPort":null,"socket":"/fixture/a.sock","tty":null,"pane":{"tab":null,"pane":null},"splitDir":null,"parentTty":null,"inCurrentTab":false,"viewport":null,"tabs":[]},{"key":"100-1","pid":101,"cdpPort":null,"socket":"/fixture/b.sock","tty":null,"pane":{"tab":null,"pane":null},"splitDir":null,"parentTty":null,"inCurrentTab":false,"viewport":null,"tabs":[]}]}
;

const duplicate_tabs_list =
    \\{"self":null,"browsers":[{"key":"100-1","pid":100,"cdpPort":null,"socket":"/fixture/a.sock","tty":null,"pane":{"tab":null,"pane":null},"splitDir":null,"parentTty":null,"inCurrentTab":false,"viewport":null,"tabs":[{"id":1,"url":"http://127.0.0.1:43117/a","title":"","active":true,"targetId":null,"timeOrigin":null,"agentControlled":false},{"id":1,"url":"http://127.0.0.1:43117/b","title":"","active":false,"targetId":null,"timeOrigin":null,"agentControlled":false}]}]}
;

const valid_new_tab =
    \\{"key":"100-1","pid":100,"cdpPort":9222,"socket":"/fixture/100-1.sock","tty":"/dev/ttys001","pane":{"tab":"terminal-tab","pane":"terminal-pane"},"splitDir":"right","parentTty":"/dev/ttys000","inCurrentTab":true,"viewport":{"width":1200,"height":800},"openedTab":2,"tabs":[{"id":1,"url":"http://127.0.0.1:43117/canvas","title":"Canvas","active":false,"targetId":"target-1","timeOrigin":1.0,"agentControlled":false},{"id":2,"url":"http://127.0.0.1:43117/second","title":"","active":true,"targetId":"target-2","timeOrigin":2.0,"agentControlled":false}]}
;
