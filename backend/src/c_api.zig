const backend = @import("vivi_backend");
const c = @cImport({
    @cInclude("vivi_backend.h");
});

comptime {
    if (c.VIVI_BACKEND_ABI_VERSION != backend.abi_version) {
        @compileError("C header and Zig backend ABI versions differ");
    }
}

export fn vivi_backend_status(
    out_status: ?*c.vivi_backend_status_t,
) callconv(.c) c.vivi_backend_result_t {
    const output = out_status orelse return c.VIVI_BACKEND_INVALID_ARGUMENT;
    const status = backend.scaffoldStatus();

    output.* = .{
        .abi_version = status.abi_version,
        .lifecycle = @intFromEnum(status.lifecycle),
    };
    return c.VIVI_BACKEND_OK;
}

test "C adapter rejects a null output pointer" {
    const std = @import("std");
    try std.testing.expectEqual(
        c.VIVI_BACKEND_INVALID_ARGUMENT,
        vivi_backend_status(null),
    );
}
