const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag == .windows) _ = @import("windows.zig");
}

const c = @cImport({
    @cInclude("native.h");
});

pub const Exit = union(enum) {
    code: u32,
    signal: u16,
    terminated,
    unknown,
};

pub const ReadResult = union(enum) {
    data: usize,
    eof,
};

pub const SpawnOptions = struct {
    cwd: []const u8,
    command: []const u8,
    rows: u16,
    columns: u16,
};

pub const Endpoint = struct {
    native: c.vivi_pty_endpoint_t,
    allocator: std.mem.Allocator,

    pub fn read(self: *Endpoint, buffer: []u8) !ReadResult {
        const amount = c.vivi_pty_read(
            &self.native,
            buffer.ptr,
            buffer.len,
        );
        if (amount < 0) return error.PtyReadFailed;
        if (amount == 0) return .eof;
        return .{ .data = @intCast(amount) };
    }

    pub fn writeAll(self: *Endpoint, bytes: []const u8) !void {
        if (c.vivi_pty_write_all(
            &self.native,
            bytes.ptr,
            bytes.len,
        ) != 0) return error.PtyWriteFailed;
    }

    pub fn terminateTree(self: *Endpoint, grace_ms: u32) !void {
        if (c.vivi_pty_terminate(&self.native, grace_ms) != 0)
            return error.PtyTerminateFailed;
    }

    pub fn wait(self: *Endpoint) !Exit {
        var kind: c_int = 0;
        var value: u32 = 0;
        if (c.vivi_pty_wait(&self.native, &kind, &value) != 0)
            return error.PtyWaitFailed;
        return switch (kind) {
            c.VIVI_PTY_EXIT_CODE => .{ .code = value },
            c.VIVI_PTY_EXIT_SIGNAL => .{ .signal = @intCast(@min(value, 65535)) },
            c.VIVI_PTY_EXIT_TERMINATED => .terminated,
            else => .unknown,
        };
    }

    pub fn deinit(self: *Endpoint) void {
        c.vivi_pty_close(&self.native);
        self.* = undefined;
    }
};

pub fn spawn(
    allocator: std.mem.Allocator,
    options: SpawnOptions,
) !Endpoint {
    const cwd = try allocator.dupeZ(u8, options.cwd);
    defer allocator.free(cwd);
    const command = try allocator.dupeZ(u8, options.command);
    defer allocator.free(command);
    var native: c.vivi_pty_endpoint_t = undefined;
    if (c.vivi_pty_spawn(
        cwd.ptr,
        command.ptr,
        options.rows,
        options.columns,
        &native,
    ) != 0) return error.PtySpawnFailed;
    return .{ .native = native, .allocator = allocator };
}
