const build_options = @import("build_options");
const copilot = @import("copilot_sdk");

pub const version = build_options.version;
pub const abi_version: u32 = 1;

pub const Lifecycle = enum(u32) {
    scaffold = 0,
};

pub const Status = struct {
    abi_version: u32 = abi_version,
    lifecycle: Lifecycle = .scaffold,
};

pub fn scaffoldStatus() Status {
    return .{};
}

test "scaffold status is stable" {
    const std = @import("std");
    const status = scaffoldStatus();

    try std.testing.expectEqual(abi_version, status.abi_version);
    try std.testing.expectEqual(Lifecycle.scaffold, status.lifecycle);
}

test "Copilot SDK dependency is compile-visible" {
    _ = copilot.Client;
}
