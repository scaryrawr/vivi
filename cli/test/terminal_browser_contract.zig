const std = @import("std");
const terminal_browser = @import("terminal_browser");
const options = @import("terminal_browser_test_options");

const short_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(100),
    .clock = .awake,
} };

fn executable() !terminal_browser.TrustedExecutable {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        options.fake_executable,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(absolute);
    return terminal_browser.TrustedExecutable.init(
        std.testing.allocator,
        std.testing.io,
        absolute,
    );
}

fn environment(scenario: []const u8) !std.process.Environ.Map {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    errdefer environ.deinit();
    try environ.put("VIVI_TB_FIXTURE_SCENARIO", scenario);
    return environ;
}

test "supported terminal-browser contract is pinned" {
    try std.testing.expectEqualStrings(
        "terminal-browser v0.11.1",
        terminal_browser.supported_version,
    );
    try std.testing.expectEqualStrings(
        "c53deaa437b704110ab3dc66e8d52bde04de5c1f",
        terminal_browser.supported_tag,
    );
    try std.testing.expectEqualStrings(
        "6d682348f4af469b56fa0fd8331b4eb967030893",
        terminal_browser.supported_commit,
    );
}

test "trusted executable requires an absolute existing executable" {
    try std.testing.expectError(
        error.UntrustedExecutable,
        terminal_browser.TrustedExecutable.init(
            std.testing.allocator,
            std.testing.io,
            "terminal-browser",
        ),
    );
    try std.testing.expectError(
        error.UntrustedExecutable,
        terminal_browser.TrustedExecutable.init(
            std.testing.allocator,
            std.testing.io,
            "/vivi-no-such-terminal-browser",
        ),
    );
}

test "version probe accepts only exact v0.11.1 output" {
    var exe = try executable();
    defer exe.deinit(std.testing.allocator);

    var success = try environment("success");
    defer success.deinit();
    try terminal_browser.verifyVersion(
        std.testing.allocator,
        std.testing.io,
        &success,
        exe,
        .{},
    );
    try terminal_browser.verifyHelpContract(
        std.testing.allocator,
        std.testing.io,
        &success,
        exe,
        .{},
    );

    var wrong = try environment("wrong-version");
    defer wrong.deinit();
    try std.testing.expectError(error.UnsupportedVersion, terminal_browser.verifyVersion(
        std.testing.allocator,
        std.testing.io,
        &wrong,
        exe,
        .{},
    ));
}

test "fixed commands decode strict v0.11.1 schemas" {
    var exe = try executable();
    defer exe.deinit(std.testing.allocator);
    var environ = try environment("success");
    defer environ.deinit();

    var list_output = try terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &environ,
        exe,
        .list,
        .{},
    );
    defer list_output.deinit();
    try std.testing.expect(list_output.successful());
    var list = try terminal_browser.parseContract(
        std.testing.allocator,
        .list,
        list_output.stdout,
    );
    list.deinit();

    var tab_output = try terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &environ,
        exe,
        .{ .new_tab = .{
            .url = "http://127.0.0.1:43117/second",
            .browser = "100-1",
        } },
        .{},
    );
    defer tab_output.deinit();
    var tab = try terminal_browser.parseContract(
        std.testing.allocator,
        .new_tab,
        tab_output.stdout,
    );
    tab.deinit();

    var open = try terminal_browser.parseContract(std.testing.allocator, .adopted_open,
        \\{"adopted":"100-1","socket":"/fixture/100-1.sock","tab":1}
    );
    open.deinit();
}

test "malformed unknown and duplicate schemas fail closed" {
    var exe = try executable();
    defer exe.deinit(std.testing.allocator);

    const cases = .{
        .{ "malformed-json", error.MalformedJson },
        .{ "invalid-utf8", error.InvalidUtf8 },
        .{ "unknown-schema", error.UnsupportedSchema },
        .{ "duplicate-identifiers", error.DuplicateIdentifier },
        .{ "duplicate-tabs", error.DuplicateIdentifier },
    };
    inline for (cases) |case| {
        var environ = try environment(case[0]);
        defer environ.deinit();
        var output = try terminal_browser.run(
            std.testing.allocator,
            std.testing.io,
            &environ,
            exe,
            .list,
            .{},
        );
        defer output.deinit();
        try std.testing.expectError(
            case[1],
            terminal_browser.parseContract(
                std.testing.allocator,
                .list,
                output.stdout,
            ),
        );
    }
}

test "timeouts crashes and output bounds are surfaced" {
    var exe = try executable();
    defer exe.deinit(std.testing.allocator);

    var timeout = try environment("timeout");
    defer timeout.deinit();
    try std.testing.expectError(error.CommandTimedOut, terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &timeout,
        exe,
        .version,
        .{ .timeout = short_timeout },
    ));

    var crash = try environment("crash");
    defer crash.deinit();
    var crashed = try terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &crash,
        exe,
        .version,
        .{},
    );
    defer crashed.deinit();
    try std.testing.expect(!crashed.successful());

    var nonzero = try environment("nonzero");
    defer nonzero.deinit();
    var failed = try terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &nonzero,
        exe,
        .version,
        .{},
    );
    defer failed.deinit();
    try std.testing.expect(!failed.successful());
    try std.testing.expectEqualStrings(
        "terminal-browser: fixture failure\n",
        failed.stderr,
    );

    var overflow = try environment("overflow");
    defer overflow.deinit();
    try std.testing.expectError(error.OutputTooLarge, terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &overflow,
        exe,
        .version,
        .{ .stdout_bytes = 32 },
    ));
}

test "partial startup and removed app mode fail without a compatibility fallback" {
    var exe = try executable();
    defer exe.deinit(std.testing.allocator);

    var partial = try environment("partial-startup");
    defer partial.deinit();
    try std.testing.expectError(error.CommandTimedOut, terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &partial,
        exe,
        .{ .open = .{ .url = "http://127.0.0.1:43117/canvas" } },
        .{ .timeout = short_timeout },
    ));

    var success = try environment("success");
    defer success.deinit();
    var removed = try terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &success,
        exe,
        .removed_app_mode,
        .{},
    );
    defer removed.deinit();
    try std.testing.expect(!removed.successful());
    try std.testing.expect(std.mem.indexOf(
        u8,
        removed.stderr,
        "app mode was removed",
    ) != null);
}

test "targeted close uses browser and tab identifiers" {
    var exe = try executable();
    defer exe.deinit(std.testing.allocator);
    var environ = try environment("success");
    defer environ.deinit();

    var output = try terminal_browser.run(
        std.testing.allocator,
        std.testing.io,
        &environ,
        exe,
        .{ .close_tab = .{ .browser = "100-1", .tab = 1 } },
        .{},
    );
    defer output.deinit();
    try std.testing.expect(output.successful());
}

test "lease identity rejects stale close replace and resume callbacks" {
    var tracker: terminal_browser.LeaseTracker = .{};
    const first = try tracker.open("extension", "canvas", "instance", 1);
    try std.testing.expect(tracker.accepts(first));

    const replacement = try tracker.open("extension", "canvas", "instance", 2);
    try std.testing.expect(!tracker.accepts(first));
    try std.testing.expect(tracker.accepts(replacement));

    tracker.close(first);
    try std.testing.expect(tracker.accepts(replacement));
    tracker.close(replacement);
    try std.testing.expect(!tracker.accepts(replacement));

    const resumed = try tracker.open("extension", "canvas", "instance", 2);
    try std.testing.expect(resumed.epoch != replacement.epoch);
    tracker.reset();
    try std.testing.expect(!tracker.accepts(resumed));
}
