const std = @import("std");

pub const supported_version = "terminal-browser v0.11.1";
pub const supported_tag = "c53deaa437b704110ab3dc66e8d52bde04de5c1f";
pub const supported_commit = "6d682348f4af469b56fa0fd8331b4eb967030893";

pub const Limits = struct {
    stdout_bytes: usize = 64 * 1024,
    stderr_bytes: usize = 64 * 1024,
    timeout: std.Io.Timeout = .{ .duration = .{
        .raw = .fromSeconds(5),
        .clock = .awake,
    } },
};

pub const TrustedExecutable = struct {
    path: [:0]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        configured_path: []const u8,
    ) !TrustedExecutable {
        if (configured_path.len == 0 or
            !std.unicode.utf8ValidateSlice(configured_path) or
            !std.fs.path.isAbsolute(configured_path))
        {
            return error.UntrustedExecutable;
        }
        const path = std.Io.Dir.realPathFileAbsoluteAlloc(
            io,
            configured_path,
            allocator,
        ) catch return error.UntrustedExecutable;
        errdefer allocator.free(path);
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch
            return error.UntrustedExecutable;
        return .{ .path = path };
    }

    pub fn deinit(self: *TrustedExecutable, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    version,
    open: struct { url: []const u8 },
    new_tab: struct { url: []const u8, browser: []const u8 },
    list,
    close_tab: struct { browser: []const u8, tab: u64 },
    removed_app_mode,
    help_open,
    help_new_tab,
    help_list,
    help_action,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: *Output) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
        self.* = undefined;
    }

    pub fn successful(self: Output) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    executable: TrustedExecutable,
    command: Command,
    limits: Limits,
) !Output {
    return switch (command) {
        .version => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "--version" },
            limits,
        ),
        .open => |input| runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "open", "--no-merge", input.url },
            limits,
        ),
        .new_tab => |input| runArgv(
            allocator,
            io,
            environ,
            &.{
                executable.path,
                "new-tab",
                input.url,
                "--browser",
                input.browser,
            },
            limits,
        ),
        .list => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "ls", "--json" },
            limits,
        ),
        .close_tab => |input| {
            var tab_buffer: [32]u8 = undefined;
            const tab = try std.fmt.bufPrint(&tab_buffer, "{d}", .{input.tab});
            return runArgv(
                allocator,
                io,
                environ,
                &.{
                    executable.path,
                    "action",
                    "--browser",
                    input.browser,
                    "--tab",
                    tab,
                    "--",
                    "tab",
                    "close",
                },
                limits,
            );
        },
        .removed_app_mode => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "open", "--app-mode" },
            limits,
        ),
        .help_open => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "open", "--help" },
            limits,
        ),
        .help_new_tab => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "new-tab", "--help" },
            limits,
        ),
        .help_list => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "ls", "--help" },
            limits,
        ),
        .help_action => runArgv(
            allocator,
            io,
            environ,
            &.{ executable.path, "action", "--help" },
            limits,
        ),
    };
}

pub fn verifyHelpContract(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    executable: TrustedExecutable,
    limits: Limits,
) !void {
    const checks = .{
        .{ Command.help_open, &.{
            "Usage: terminal-browser open",
            "--no-merge",
            "--allow-clipboard-read",
        } },
        .{ Command.help_new_tab, &.{
            "Usage: terminal-browser new-tab",
            "--browser <key>",
        } },
        .{ Command.help_list, &.{
            "Usage: terminal-browser ls",
            "--all",
            "--json",
        } },
        .{ Command.help_action, &.{
            "Usage: terminal-browser action",
            "--browser <key>",
            "--tab <id>",
            "--target <id>",
        } },
    };
    inline for (checks) |check| {
        var output = try run(
            allocator,
            io,
            environ,
            executable,
            check[0],
            limits,
        );
        defer output.deinit();
        if (!output.successful() or
            !std.unicode.utf8ValidateSlice(output.stdout))
        {
            return error.UnsupportedContract;
        }
        inline for (check[1]) |needle| {
            if (std.mem.indexOf(u8, output.stdout, needle) == null)
                return error.UnsupportedContract;
        }
    }
}

pub fn verifyVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    executable: TrustedExecutable,
    limits: Limits,
) !void {
    var output = try run(allocator, io, environ, executable, .version, limits);
    defer output.deinit();
    if (!output.successful()) return error.CommandFailed;
    if (!std.unicode.utf8ValidateSlice(output.stdout) or
        !std.mem.eql(u8, output.stdout, supported_version ++ "\n"))
    {
        return error.UnsupportedVersion;
    }
}

fn runArgv(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    limits: Limits,
) !Output {
    const Selected = union(enum) {
        command: std.process.RunError!std.process.RunResult,
        timeout: std.Io.Cancelable!void,
    };
    var buffer: [2]Selected = undefined;
    var select = std.Io.Select(Selected).init(io, &buffer);
    defer while (select.cancel()) |pending| {
        switch (pending) {
            .command => |result| if (result) |output| {
                allocator.free(output.stdout);
                allocator.free(output.stderr);
            } else |_| {},
            .timeout => {},
        }
    };
    try select.concurrent(.timeout, std.Io.Timeout.sleep, .{ limits.timeout, io });
    try select.concurrent(.command, std.process.run, .{ allocator, io, .{
        .argv = argv,
        .environ_map = environ,
        .stdout_limit = .limited(limits.stdout_bytes),
        .stderr_limit = .limited(limits.stderr_bytes),
    } });
    switch (try select.await()) {
        .timeout => |result| {
            try result;
            return error.CommandTimedOut;
        },
        .command => |result| {
            const output = result catch |err| return switch (err) {
                error.FileNotFound => error.ExecutableMissing,
                error.StreamTooLong => error.OutputTooLarge,
                else => err,
            };
            return .{
                .allocator = allocator,
                .stdout = output.stdout,
                .stderr = output.stderr,
                .term = output.term,
            };
        },
    }
}

const SelfContext = struct {
    tab: []const u8,
    pane: []const u8,
};

const Pane = struct {
    tab: ?[]const u8,
    pane: ?[]const u8,
};

const Viewport = struct {
    width: u32,
    height: u32,
};

const SplitDirection = enum { right, left, down, up };

const Tab = struct {
    id: u64,
    url: []const u8,
    title: []const u8,
    active: bool,
    targetId: ?[]const u8,
    timeOrigin: ?f64,
    agentControlled: bool,
};

const Browser = struct {
    key: []const u8,
    pid: u64,
    cdpPort: ?u16,
    socket: []const u8,
    tty: ?[]const u8,
    pane: Pane,
    splitDir: ?SplitDirection,
    parentTty: ?[]const u8,
    inCurrentTab: bool,
    viewport: ?Viewport,
    tabs: []Tab,
};

const ListResponse = struct {
    self: ?SelfContext,
    browsers: []Browser,
};

const NewTabResponse = struct {
    key: []const u8,
    pid: u64,
    cdpPort: ?u16,
    socket: []const u8,
    tty: ?[]const u8,
    pane: Pane,
    splitDir: ?SplitDirection,
    parentTty: ?[]const u8,
    inCurrentTab: bool,
    viewport: ?Viewport,
    openedTab: u64,
    tabs: []Tab,
};

const OpenResponse = struct {
    adopted: []const u8,
    socket: []const u8,
    tab: u64,
};

pub const ParsedContract = union(enum) {
    list: std.json.Parsed(ListResponse),
    new_tab: std.json.Parsed(NewTabResponse),
    adopted_open: std.json.Parsed(OpenResponse),

    pub fn deinit(self: *ParsedContract) void {
        switch (self.*) {
            inline else => |*parsed| parsed.deinit(),
        }
        self.* = undefined;
    }
};

pub fn parseContract(
    allocator: std.mem.Allocator,
    kind: enum { list, new_tab, adopted_open },
    bytes: []const u8,
) !ParsedContract {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return switch (kind) {
        .list => {
            var parsed = std.json.parseFromSlice(
                ListResponse,
                allocator,
                bytes,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = false },
            ) catch |err| return classifyJsonError(err);
            errdefer parsed.deinit();
            try validateBrowsers(parsed.value.browsers);
            return .{ .list = parsed };
        },
        .new_tab => {
            var parsed = std.json.parseFromSlice(
                NewTabResponse,
                allocator,
                bytes,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = false },
            ) catch |err| return classifyJsonError(err);
            errdefer parsed.deinit();
            try validateBrowser(parsed.value.key, parsed.value.tabs);
            if (!containsTab(parsed.value.tabs, parsed.value.openedTab))
                return error.UnsupportedSchema;
            return .{ .new_tab = parsed };
        },
        .adopted_open => {
            var parsed = std.json.parseFromSlice(
                OpenResponse,
                allocator,
                bytes,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = false },
            ) catch |err| return classifyJsonError(err);
            errdefer parsed.deinit();
            try validateIdentifier(parsed.value.adopted);
            try validateIdentifier(parsed.value.socket);
            if (parsed.value.tab == 0) return error.UnsupportedSchema;
            return .{ .adopted_open = parsed };
        },
    };
}

fn classifyJsonError(err: anyerror) anyerror {
    return switch (err) {
        error.SyntaxError, error.UnexpectedEndOfInput => error.MalformedJson,
        else => error.UnsupportedSchema,
    };
}

fn validateBrowsers(browsers: []const Browser) !void {
    for (browsers, 0..) |browser, index| {
        try validateBrowser(browser.key, browser.tabs);
        for (browsers[0..index]) |previous| {
            if (std.mem.eql(u8, previous.key, browser.key))
                return error.DuplicateIdentifier;
        }
    }
}

fn validateBrowser(key: []const u8, tabs: []const Tab) !void {
    try validateIdentifier(key);
    for (tabs, 0..) |tab, index| {
        if (tab.id == 0) return error.UnsupportedSchema;
        for (tabs[0..index]) |previous| {
            if (previous.id == tab.id) return error.DuplicateIdentifier;
        }
    }
}

fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > 256 or
        std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return error.UnsupportedSchema;
    }
}

fn containsTab(tabs: []const Tab, id: u64) bool {
    for (tabs) |tab| if (tab.id == id) return true;
    return false;
}

pub const Lease = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    instance_id: []const u8,
    generation: u64,
    epoch: u64,

    pub fn valid(self: Lease) bool {
        return self.extension_id.len != 0 and
            self.canvas_id.len != 0 and
            self.instance_id.len != 0 and
            self.generation != 0 and
            self.epoch != 0;
    }

    pub fn eql(a: Lease, b: Lease) bool {
        return a.generation == b.generation and
            a.epoch == b.epoch and
            std.mem.eql(u8, a.extension_id, b.extension_id) and
            std.mem.eql(u8, a.canvas_id, b.canvas_id) and
            std.mem.eql(u8, a.instance_id, b.instance_id);
    }
};

pub const LeaseTracker = struct {
    current: ?Lease = null,
    next_epoch: u64 = 1,

    pub fn open(
        self: *LeaseTracker,
        extension_id: []const u8,
        canvas_id: []const u8,
        instance_id: []const u8,
        generation: u64,
    ) !Lease {
        if (generation == 0 or self.next_epoch == 0) return error.InvalidLease;
        const lease: Lease = .{
            .extension_id = extension_id,
            .canvas_id = canvas_id,
            .instance_id = instance_id,
            .generation = generation,
            .epoch = self.next_epoch,
        };
        self.next_epoch +%= 1;
        if (!lease.valid() or self.next_epoch == 0) return error.InvalidLease;
        self.current = lease;
        return lease;
    }

    pub fn accepts(self: LeaseTracker, lease: Lease) bool {
        return if (self.current) |current| current.eql(lease) else false;
    }

    pub fn close(self: *LeaseTracker, lease: Lease) void {
        if (self.accepts(lease)) self.current = null;
    }

    pub fn reset(self: *LeaseTracker) void {
        self.current = null;
    }
};
