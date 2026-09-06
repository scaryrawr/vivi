const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend_linkage = b.option(
        std.builtin.LinkMode,
        "backend-linkage",
        "C ABI library linkage",
    ) orelse .static;

    const sdk = b.dependency("copilot_sdk", .{
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", "0.1.0");

    const backend = b.addModule("vivi_backend", .{
        .root_source_file = b.path("backend/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend.addImport("copilot_sdk", sdk.module("copilot_sdk"));
    backend.addOptions("build_options", build_options);

    const c_api = b.createModule(.{
        .root_source_file = b.path("backend/src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_api.addImport("vivi_backend", backend);
    c_api.addIncludePath(b.path("backend/include"));

    const library = b.addLibrary(.{
        .name = "vivi_backend",
        .root_module = c_api,
        .linkage = backend_linkage,
    });
    library.installHeader(
        b.path("backend/include/vivi_backend.h"),
        "vivi_backend.h",
    );
    library.installHeader(
        b.path("backend/include/module.modulemap"),
        "module.modulemap",
    );
    const install_library = b.addInstallArtifact(library, .{});
    b.getInstallStep().dependOn(&install_library.step);

    const cli_module = b.createModule(.{
        .root_source_file = b.path("cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("vivi_backend", backend);

    const cli = b.addExecutable(.{
        .name = "vivi",
        .root_module = cli_module,
    });
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the vivi CLI");
    run_step.dependOn(&run_cli.step);

    const backend_tests = b.addTest(.{ .root_module = backend });
    const run_backend_tests = b.addRunArtifact(backend_tests);

    const cli_tests = b.addTest(.{ .root_module = cli_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const c_smoke_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_smoke_module.addCSourceFile(.{
        .file = b.path("backend/test/c_abi_smoke.c"),
        .flags = &.{},
    });
    c_smoke_module.addIncludePath(b.path("backend/include"));

    const c_smoke = b.addExecutable(.{
        .name = "vivi-c-abi-smoke",
        .root_module = c_smoke_module,
    });
    c_smoke.root_module.linkLibrary(library);
    const run_c_smoke = b.addRunArtifact(c_smoke);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_c_smoke.step);

    const install_c_api = b.step(
        "install-c-api",
        "Install the C-compatible backend library and headers",
    );
    install_c_api.dependOn(&install_library.step);
}
