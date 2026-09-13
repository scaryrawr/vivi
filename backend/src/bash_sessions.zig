const std = @import("std");
const platform = @import("pty/platform.zig");

pub const max_sessions = 8;
pub const max_output_bytes = 256 * 1024;
pub const max_read_bytes = 32 * 1024;
pub const default_read_bytes = 16 * 1024;
pub const max_write_bytes = 16 * 1024;
pub const max_queued_input_bytes = 64 * 1024;
pub const default_wait_ms: u32 = 100;
pub const max_wait_ms: u32 = 5_000;

pub const Options = struct {
    initial_wait_ms: u32 = 200,
    stop_grace_ms: u32 = 750,
    rows: u16 = 40,
    columns: u16 = 120,
};

pub const ShellId = struct {
    bytes: [16]u8,

    pub fn parse(text: []const u8) !ShellId {
        if (text.len != 37 or !std.mem.eql(u8, text[0..5], "bash_"))
            return error.InvalidShellId;
        var result: ShellId = undefined;
        for (0..16) |index| {
            result.bytes[index] = (try hexNibble(text[5 + index * 2]) << 4) |
                try hexNibble(text[6 + index * 2]);
        }
        return result;
    }

    pub fn format(self: ShellId, buffer: *[37]u8) []const u8 {
        const hex = "0123456789abcdef";
        @memcpy(buffer[0..5], "bash_");
        for (self.bytes, 0..) |byte, index| {
            buffer[5 + index * 2] = hex[byte >> 4];
            buffer[6 + index * 2] = hex[byte & 0x0f];
        }
        return buffer;
    }

    fn hexNibble(byte: u8) !u8 {
        return switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => error.InvalidShellId,
        };
    }
};

pub const Exit = platform.Exit;

pub const State = union(enum) {
    running,
    exited: Exit,
};

pub const Encoding = enum {
    utf8,
    base64,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    encoding: Encoding,
    more: bool,
    dropped_bytes: u64,

    pub fn deinit(self: *Output) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const StartOptions = struct {
    command: []const u8,
    rows: u16 = 40,
    columns: u16 = 120,
};

pub const StartResult = struct {
    id: ShellId,
    state: State,
    output: Output,
};

pub const Snapshot = struct {
    id: ShellId,
    state: State,
    unread_bytes: usize,
    dropped_bytes: u64,
};

pub const ReadResult = struct {
    id: ShellId,
    state: State,
    output: Output,
};

pub const WriteResult = struct {
    id: ShellId,
    state: State,
    accepted_bytes: usize,
};

pub const StopResult = struct {
    id: ShellId,
    was_present: bool,
};

const Lifecycle = enum {
    starting,
    running,
    stopping,
    exited,
};

const ByteRing = struct {
    storage: []u8,
    head: usize = 0,
    len: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) !ByteRing {
        return .{ .storage = try allocator.alloc(u8, capacity) };
    }

    fn deinit(self: *ByteRing, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }

    fn appendDroppingOldest(self: *ByteRing, bytes: []const u8) u64 {
        if (self.storage.len == 0) return bytes.len;
        var dropped: u64 = 0;
        var source = bytes;
        if (source.len >= self.storage.len) {
            dropped = @intCast(self.len + source.len - self.storage.len);
            source = source[source.len - self.storage.len ..];
            self.head = 0;
            self.len = 0;
        } else if (self.len + source.len > self.storage.len) {
            const overflow = self.len + source.len - self.storage.len;
            self.discard(overflow);
            dropped = @intCast(overflow);
        }
        const tail = (self.head + self.len) % self.storage.len;
        const first = @min(source.len, self.storage.len - tail);
        @memcpy(self.storage[tail..][0..first], source[0..first]);
        @memcpy(self.storage[0 .. source.len - first], source[first..]);
        self.len += source.len;
        return dropped;
    }

    fn appendExact(self: *ByteRing, bytes: []const u8) !void {
        if (bytes.len > self.storage.len - self.len)
            return error.InputBackpressure;
        if (bytes.len == 0) return;
        const tail = (self.head + self.len) % self.storage.len;
        const first = @min(bytes.len, self.storage.len - tail);
        @memcpy(self.storage[tail..][0..first], bytes[0..first]);
        @memcpy(self.storage[0 .. bytes.len - first], bytes[first..]);
        self.len += bytes.len;
    }

    fn copyPrefix(self: *const ByteRing, destination: []u8) usize {
        const amount = @min(destination.len, self.len);
        if (amount == 0) return 0;
        const first = @min(amount, self.storage.len - self.head);
        @memcpy(destination[0..first], self.storage[self.head..][0..first]);
        @memcpy(destination[first..amount], self.storage[0 .. amount - first]);
        return amount;
    }

    fn take(
        self: *ByteRing,
        allocator: std.mem.Allocator,
        limit: usize,
    ) ![]u8 {
        const result = try allocator.alloc(u8, @min(limit, self.len));
        _ = self.copyPrefix(result);
        self.discard(result.len);
        return result;
    }

    fn discard(self: *ByteRing, count: usize) void {
        std.debug.assert(count <= self.len);
        if (count == 0) return;
        self.head = (self.head + count) % self.storage.len;
        self.len -= count;
        if (self.len == 0) self.head = 0;
    }
};

const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    id: ShellId,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    lifecycle: Lifecycle = .starting,
    exit: ?Exit = null,
    output_eof: bool = false,
    termination_requested: bool = false,
    output: ByteRing,
    input: ByteRing,
    dropped_bytes: u64 = 0,
    endpoint: platform.Endpoint,
    reader: ?std.Thread = null,
    writer: ?std.Thread = null,
    waiter: ?std.Thread = null,

    fn state(self: *const Session) State {
        return if (self.lifecycle == .exited)
            .{ .exited = self.exit orelse .unknown }
        else
            .running;
    }

    fn publishExitIfComplete(self: *Session) void {
        if (self.output_eof and self.exit != null and
            self.lifecycle != .stopping and self.lifecycle != .exited)
        {
            self.lifecycle = .exited;
            self.changed.broadcast(self.io);
        }
    }

    fn requestTermination(self: *Session, grace_ms: u32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.termination_requested) {
            return;
        }
        try self.endpoint.terminateTree(grace_ms);
        self.termination_requested = true;
    }

    fn readerMain(self: *Session) void {
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const read_result = self.endpoint.read(&buffer) catch {
                _ = self.requestTermination(0) catch {};
                self.mutex.lockUncancelable(self.io);
                self.output_eof = true;
                self.publishExitIfComplete();
                self.changed.broadcast(self.io);
                self.mutex.unlock(self.io);
                return;
            };
            switch (read_result) {
                .data => |amount| {
                    self.mutex.lockUncancelable(self.io);
                    self.dropped_bytes +|= self.output.appendDroppingOldest(
                        buffer[0..amount],
                    );
                    self.changed.broadcast(self.io);
                    self.mutex.unlock(self.io);
                },
                .eof => {
                    self.mutex.lockUncancelable(self.io);
                    self.output_eof = true;
                    self.publishExitIfComplete();
                    self.changed.broadcast(self.io);
                    self.mutex.unlock(self.io);
                    return;
                },
            }
        }
    }

    fn writerMain(self: *Session) void {
        var buffer: [max_write_bytes]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.input.len == 0 and
                self.lifecycle != .stopping and
                self.lifecycle != .exited)
            {
                self.changed.waitUncancelable(self.io, &self.mutex);
            }
            if (self.lifecycle == .stopping or self.lifecycle == .exited) {
                self.mutex.unlock(self.io);
                return;
            }
            const amount = self.input.copyPrefix(&buffer);
            self.mutex.unlock(self.io);

            self.endpoint.writeAll(buffer[0..amount]) catch {
                _ = self.requestTermination(0) catch {};
                return;
            };

            self.mutex.lockUncancelable(self.io);
            self.input.discard(amount);
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
        }
    }

    fn waiterMain(self: *Session) void {
        const exit = self.endpoint.wait() catch blk: {
            _ = self.requestTermination(0) catch {};
            break :blk Exit.unknown;
        };
        self.mutex.lockUncancelable(self.io);
        self.exit = exit;
        self.publishExitIfComplete();
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
    }

    fn deinit(self: *Session) void {
        self.endpoint.deinit();
        self.output.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace: []u8,
    options: Options,
    mutex: std.Io.Mutex = .init,
    sessions: std.AutoHashMap(ShellId, *Session),
    shutting_down: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        workspace: []const u8,
        options: Options,
    ) !Manager {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace = try allocator.dupe(u8, workspace),
            .options = options,
            .sessions = std.AutoHashMap(ShellId, *Session).init(allocator),
        };
    }

    pub fn start(self: *Manager, options: StartOptions) !StartResult {
        if (options.command.len == 0) return error.EmptyCommand;
        if (std.mem.indexOfScalar(u8, options.command, 0) != null)
            return error.InvalidCommand;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutting_down) return error.ServiceShuttingDown;
        if (self.sessions.count() >= max_sessions) return error.TooManyBashSessions;
        try self.sessions.ensureUnusedCapacity(1);

        var id: ShellId = undefined;
        while (true) {
            self.io.random(&id.bytes);
            if (!self.sessions.contains(id)) break;
        }

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .id = id,
            .output = try ByteRing.init(self.allocator, max_output_bytes),
            .input = undefined,
            .endpoint = undefined,
        };
        errdefer session.output.deinit(self.allocator);
        session.input = try ByteRing.init(self.allocator, max_queued_input_bytes);
        errdefer session.input.deinit(self.allocator);
        session.endpoint = try platform.spawn(self.allocator, .{
            .cwd = self.workspace,
            .command = options.command,
            .rows = options.rows,
            .columns = options.columns,
        });
        errdefer session.endpoint.deinit();

        session.waiter = std.Thread.spawn(.{}, Session.waiterMain, .{session}) catch |err| {
            _ = session.endpoint.terminateTree(0) catch {};
            _ = session.endpoint.wait() catch {};
            return err;
        };
        session.reader = std.Thread.spawn(.{}, Session.readerMain, .{session}) catch |err| {
            _ = session.endpoint.terminateTree(0) catch {};
            session.waiter.?.join();
            return err;
        };
        session.writer = std.Thread.spawn(.{}, Session.writerMain, .{session}) catch |err| {
            session.mutex.lockUncancelable(self.io);
            session.lifecycle = .stopping;
            session.changed.broadcast(self.io);
            session.mutex.unlock(self.io);
            _ = session.endpoint.terminateTree(0) catch {};
            session.waiter.?.join();
            session.reader.?.join();
            return err;
        };
        session.mutex.lockUncancelable(self.io);
        if (session.lifecycle == .starting) session.lifecycle = .running;
        session.changed.broadcast(self.io);
        session.mutex.unlock(self.io);
        self.sessions.putAssumeCapacity(id, session);

        errdefer _ = self.stopLocked(id) catch {};
        try waitForOutput(session, self.options.initial_wait_ms);
        const read_result = try takeOutput(
            session,
            self.allocator,
            default_read_bytes,
        );
        return .{
            .id = id,
            .state = read_result.state,
            .output = read_result.output,
        };
    }

    pub fn list(
        self: *Manager,
        allocator: std.mem.Allocator,
    ) ![]Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const snapshots = try allocator.alloc(Snapshot, self.sessions.count());
        errdefer allocator.free(snapshots);
        var iterator = self.sessions.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |pointer| : (index += 1) {
            const session = pointer.*;
            session.mutex.lockUncancelable(self.io);
            snapshots[index] = .{
                .id = session.id,
                .state = session.state(),
                .unread_bytes = session.output.len,
                .dropped_bytes = session.dropped_bytes,
            };
            session.mutex.unlock(self.io);
        }
        return snapshots;
    }

    pub fn read(
        self: *Manager,
        allocator: std.mem.Allocator,
        id: ShellId,
        limit: usize,
        wait_ms: u32,
    ) !ReadResult {
        if (limit == 0 or limit > max_read_bytes) return error.InvalidReadLimit;
        if (wait_ms > max_wait_ms) return error.InvalidWait;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutting_down) return error.ServiceShuttingDown;
        const session = self.sessions.get(id) orelse return error.UnknownShell;
        try waitForOutput(session, wait_ms);
        return takeOutput(session, allocator, limit);
    }

    pub fn write(
        self: *Manager,
        id: ShellId,
        bytes: []const u8,
    ) !WriteResult {
        if (bytes.len > max_write_bytes) return error.InputTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutting_down) return error.ServiceShuttingDown;
        const session = self.sessions.get(id) orelse return error.UnknownShell;
        session.mutex.lockUncancelable(self.io);
        defer session.mutex.unlock(self.io);
        if (session.lifecycle != .running) return error.ShellNotRunning;
        try session.input.appendExact(bytes);
        session.changed.broadcast(self.io);
        return .{
            .id = id,
            .state = session.state(),
            .accepted_bytes = bytes.len,
        };
    }

    pub fn stop(self: *Manager, id: ShellId) !StopResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stopLocked(id);
    }

    fn stopLocked(self: *Manager, id: ShellId) !StopResult {
        const session = self.sessions.get(id) orelse {
            return .{ .id = id, .was_present = false };
        };
        session.mutex.lockUncancelable(self.io);
        session.lifecycle = .stopping;
        session.changed.broadcast(self.io);
        session.mutex.unlock(self.io);

        try session.requestTermination(self.options.stop_grace_ms);
        if (session.waiter) |thread| thread.join();
        if (session.reader) |thread| thread.join();
        session.mutex.lockUncancelable(self.io);
        session.changed.broadcast(self.io);
        session.mutex.unlock(self.io);
        if (session.writer) |thread| thread.join();

        _ = self.sessions.remove(id);
        session.deinit();
        self.allocator.destroy(session);
        return .{ .id = id, .was_present = true };
    }

    pub fn deinit(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        self.shutting_down = true;
        var ids: [max_sessions]ShellId = undefined;
        var count: usize = 0;
        var iterator = self.sessions.keyIterator();
        while (iterator.next()) |id| {
            ids[count] = id.*;
            count += 1;
        }
        self.mutex.unlock(self.io);
        for (ids[0..count]) |id| _ = self.stop(id) catch {};
        self.sessions.deinit();
        self.allocator.free(self.workspace);
        self.* = undefined;
    }
};

fn waitForOutput(session: *Session, wait_ms: u32) !void {
    var remaining = wait_ms;
    while (true) {
        session.mutex.lockUncancelable(session.io);
        const done = session.output.len != 0 or session.lifecycle == .exited;
        session.mutex.unlock(session.io);
        if (done or remaining == 0) return;
        const step: u32 = @min(remaining, 10);
        try session.io.sleep(.fromMilliseconds(step), .awake);
        remaining -= step;
    }
}

fn takeOutput(
    session: *Session,
    allocator: std.mem.Allocator,
    limit: usize,
) !ReadResult {
    session.mutex.lockUncancelable(session.io);
    defer session.mutex.unlock(session.io);
    const raw = try session.output.take(allocator, limit);
    errdefer allocator.free(raw);
    const more = session.output.len != 0;
    const output = try encodeOutput(allocator, raw, more, session.dropped_bytes);
    return .{
        .id = session.id,
        .state = session.state(),
        .output = output,
    };
}

fn encodeOutput(
    allocator: std.mem.Allocator,
    raw: []u8,
    more: bool,
    dropped_bytes: u64,
) !Output {
    if (std.unicode.utf8ValidateSlice(raw)) {
        return .{
            .allocator = allocator,
            .bytes = raw,
            .encoding = .utf8,
            .more = more,
            .dropped_bytes = dropped_bytes,
        };
    }
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(raw.len));
    _ = encoder.encode(encoded, raw);
    allocator.free(raw);
    return .{
        .allocator = allocator,
        .bytes = encoded,
        .encoding = .base64,
        .more = more,
        .dropped_bytes = dropped_bytes,
    };
}

test "shell IDs round trip and reject malformed text" {
    const id = ShellId{ .bytes = [_]u8{0xab} ** 16 };
    var buffer: [37]u8 = undefined;
    const text = id.format(&buffer);
    try std.testing.expectEqual(id, try ShellId.parse(text));
    try std.testing.expectError(error.InvalidShellId, ShellId.parse("bash_no"));
}

test "byte ring reports exact overwrite and exact append backpressure" {
    var ring = try ByteRing.init(std.testing.allocator, 4);
    defer ring.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), ring.appendDroppingOldest("abc"));
    try std.testing.expectEqual(@as(u64, 2), ring.appendDroppingOldest("def"));
    const value = try ring.take(std.testing.allocator, 4);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("cdef", value);

    try ring.appendExact("1234");
    try std.testing.expectError(error.InputBackpressure, ring.appendExact("5"));
}

test "output uses base64 only when bytes are not UTF-8" {
    const utf8_raw = try std.testing.allocator.dupe(u8, "hello");
    var utf8 = try encodeOutput(
        std.testing.allocator,
        utf8_raw,
        false,
        0,
    );
    defer utf8.deinit();
    try std.testing.expectEqual(Encoding.utf8, utf8.encoding);
    try std.testing.expectEqualStrings("hello", utf8.bytes);

    const binary_raw = try std.testing.allocator.dupe(u8, "\xff");
    var binary = try encodeOutput(
        std.testing.allocator,
        binary_raw,
        true,
        4,
    );
    defer binary.deinit();
    try std.testing.expectEqual(Encoding.base64, binary.encoding);
    try std.testing.expectEqualStrings("/w==", binary.bytes);
    try std.testing.expect(binary.more);
    try std.testing.expectEqual(@as(u64, 4), binary.dropped_bytes);
}

test "PTY session is a terminal and accepts later input" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var manager = try Manager.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
        .{},
    );
    defer manager.deinit();

    var started = try manager.start(.{
        .command = "test -t 0 && test -t 1 && test -t 2 && read line && printf 'PTY:%s\\n' \"$line\"",
    });
    defer started.output.deinit();
    _ = try manager.write(started.id, "ready\n");

    var found = false;
    for (0..30) |_| {
        var result = try manager.read(
            std.testing.allocator,
            started.id,
            max_read_bytes,
            100,
        );
        defer result.output.deinit();
        if (std.mem.indexOf(u8, result.output.bytes, "PTY:ready") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect((try manager.stop(started.id)).was_present);
    try std.testing.expect(!(try manager.stop(started.id)).was_present);
}

test "natural exit is published after final PTY output is drained" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var manager = try Manager.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
        .{},
    );
    defer manager.deinit();

    var started = try manager.start(.{ .command = "printf FINAL_OUTPUT" });
    defer started.output.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try output.appendSlice(std.testing.allocator, started.output.bytes);
    var exited = started.state == .exited;
    for (0..30) |_| {
        if (exited) break;
        var result = try manager.read(
            std.testing.allocator,
            started.id,
            max_read_bytes,
            100,
        );
        defer result.output.deinit();
        try output.appendSlice(std.testing.allocator, result.output.bytes);
        exited = result.state == .exited;
    }
    try std.testing.expect(exited);
    try std.testing.expect(
        std.mem.indexOf(u8, output.items, "FINAL_OUTPUT") != null,
    );
}

test "stopping a PTY session terminates its POSIX process group" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var manager = try Manager.init(
        std.testing.allocator,
        std.testing.io,
        path_buffer[0..path_len],
        .{},
    );
    defer manager.deinit();

    var started = try manager.start(.{
        .command = "sleep 30 & echo $! > child.pid; wait",
    });
    defer started.output.deinit();

    var child_pid: std.posix.pid_t = 0;
    for (0..50) |_| {
        const text = temporary.dir.readFileAlloc(
            std.testing.io,
            "child.pid",
            std.testing.allocator,
            .limited(64),
        ) catch {
            try std.testing.io.sleep(.fromMilliseconds(10), .awake);
            continue;
        };
        defer std.testing.allocator.free(text);
        child_pid = try std.fmt.parseInt(
            std.posix.pid_t,
            std.mem.trim(u8, text, " \r\n"),
            10,
        );
        break;
    }
    try std.testing.expect(child_pid > 0);
    try std.testing.expect((try manager.stop(started.id)).was_present);
    try std.testing.expectError(
        error.ProcessNotFound,
        std.posix.kill(child_pid, std.posix.SIG.CONT),
    );
}
