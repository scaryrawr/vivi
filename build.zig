const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "llvm", "Override compiler backend selection");
    const macos_sdk = b.option(
        []const u8,
        "macos-sdk",
        "macOS SDK root used for explicit compatibility targets",
    );
    // Zig 0.16's default x86_64 backend crashes compiling the image decoder.
    const cli_use_llvm = use_llvm orelse true;
    const backend_linkage = b.option(
        std.builtin.LinkMode,
        "backend-linkage",
        "C ABI library linkage",
    ) orelse .static;

    const sdk = b.dependency("copilot_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const syntax_dependencies = SyntaxDependencies{
        .core = b.dependency("tree_sitter_core", .{}),
        .bash = b.dependency("tree_sitter_bash", .{}),
        .json = b.dependency("tree_sitter_json", .{}),
        .yaml = b.dependency("tree_sitter_yaml", .{}),
        .diff = b.dependency("tree_sitter_diff", .{}),
        .javascript = b.dependency("tree_sitter_javascript", .{}),
        .typescript = b.dependency("tree_sitter_typescript", .{}),
        .rust = b.dependency("tree_sitter_rust", .{}),
        .c = b.dependency("tree_sitter_c", .{}),
        .cpp = b.dependency("tree_sitter_cpp", .{}),
        .go = b.dependency("tree_sitter_go", .{}),
        .java = b.dependency("tree_sitter_java", .{}),
        .lua = b.dependency("tree_sitter_lua", .{}),
        .python = b.dependency("tree_sitter_python", .{}),
    };
    const version = b.option(
        []const u8,
        "version",
        "Version reported by vivi and the SDK client (release builds pass the tag here)",
    ) orelse "0.1.0";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const backend = b.addModule("vivi_backend", .{
        .root_source_file = b.path("backend/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend.addImport("copilot_sdk", sdk.module("copilot_sdk"));
    backend.addOptions("build_options", build_options);
    addPty(b, backend, target);
    addSyntaxHighlighting(b, backend, syntax_dependencies);

    const c_api = b.createModule(.{
        .root_source_file = b.path("backend/src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_api.addImport("vivi_backend", backend);
    c_api.addIncludePath(b.path("backend/include"));

    const library = b.addLibrary(.{
        .name = "vivi_backend",
        .root_module = c_api,
        .linkage = backend_linkage,
        .use_llvm = use_llvm,
    });
    library.bundle_compiler_rt = true;
    library.bundle_ubsan_rt = true;
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
        .link_libc = true,
    });
    cli_module.addImport("vivi_backend", backend);
    cli_module.addImport("vaxis", vaxis.module("vaxis"));
    addClipboard(b, cli_module, target, macos_sdk);
    cli_module.addIncludePath(b.path("third_party/md4c"));
    cli_module.addCSourceFile(.{
        .file = b.path("third_party/md4c/md4c.c"),
        .flags = &.{"-std=c99"},
    });
    cli_module.addCSourceFile(.{
        .file = b.path("third_party/md4c/entity.c"),
        .flags = &.{"-std=c99"},
    });

    const cli = b.addExecutable(.{
        .name = "vivi",
        .root_module = cli_module,
        .use_llvm = cli_use_llvm,
    });
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the vivi CLI");
    run_step.dependOn(&run_cli.step);

    const build_native: *std.Build.Step = if (builtin.os.tag == .macos) build: {
        const command = b.addSystemCommand(&.{
            "sh",
            b.pathFromRoot("scripts/build-native.sh"),
        });
        break :build &command.step;
    } else fail: {
        const unsupported = b.addFail(
            "zig build native requires macOS and Xcode",
        );
        break :fail &unsupported.step;
    };
    const native_step = b.step(
        "native",
        "Build the Debug macOS Vivi app from this worktree",
    );
    native_step.dependOn(build_native);

    const run_native = b.addSystemCommand(&.{
        b.getInstallPath(.bin, "vivi"),
        "chat",
        "--native",
    });
    run_native.setCwd(b.path("."));
    run_native.setEnvironmentVariable(
        "VIVI_APP_PATH",
        b.pathFromRoot("zig-out/xcode/Debug/Vivi.app"),
    );
    run_native.step.dependOn(&install_cli.step);
    run_native.step.dependOn(build_native);
    const native_run_step = b.step(
        "native-run",
        "Build and launch this worktree's macOS Vivi app",
    );
    native_run_step.dependOn(&run_native.step);

    const backend_tests = b.addTest(.{ .root_module = backend, .use_llvm = use_llvm });
    const run_backend_tests = b.addRunArtifact(backend_tests);

    const canvas_tests_module = b.createModule(.{
        .root_source_file = b.path("backend/src/canvas.zig"),
        .target = target,
        .optimize = optimize,
    });
    const canvas_tests = b.addTest(.{
        .root_module = canvas_tests_module,
        .use_llvm = use_llvm,
    });
    const run_canvas_tests = b.addRunArtifact(canvas_tests);

    const c_api_tests = b.addTest(.{ .root_module = c_api, .use_llvm = use_llvm });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);

    const cli_tests = b.addTest(.{ .root_module = cli_module, .use_llvm = cli_use_llvm });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const chat_tests_module = b.createModule(.{
        .root_source_file = b.path("cli/src/chat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    chat_tests_module.addImport("vivi_backend", backend);
    chat_tests_module.addImport("vaxis", vaxis.module("vaxis"));
    addClipboard(b, chat_tests_module, target, macos_sdk);
    chat_tests_module.addIncludePath(b.path("third_party/md4c"));
    chat_tests_module.addCSourceFile(.{
        .file = b.path("third_party/md4c/md4c.c"),
        .flags = &.{"-std=c99"},
    });
    chat_tests_module.addCSourceFile(.{
        .file = b.path("third_party/md4c/entity.c"),
        .flags = &.{"-std=c99"},
    });
    const chat_tests = b.addTest(.{
        .root_module = chat_tests_module,
        .use_llvm = cli_use_llvm,
    });
    const run_chat_tests = b.addRunArtifact(chat_tests);

    const tool_tests_module = b.createModule(.{
        .root_source_file = b.path("cli/src/tool_renderer.zig"),
        .target = target,
        .optimize = optimize,
    });
    tool_tests_module.addImport("vivi_backend", backend);
    tool_tests_module.addImport("vaxis", vaxis.module("vaxis"));
    const tool_tests = b.addTest(.{ .root_module = tool_tests_module, .use_llvm = use_llvm });
    const run_tool_tests = b.addRunArtifact(tool_tests);

    const markdown_tests_module = b.createModule(.{
        .root_source_file = b.path("cli/src/markdown.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    markdown_tests_module.addImport("vivi_backend", backend);
    markdown_tests_module.addImport("vaxis", vaxis.module("vaxis"));
    markdown_tests_module.addIncludePath(b.path("third_party/md4c"));
    markdown_tests_module.addCSourceFile(.{
        .file = b.path("third_party/md4c/md4c.c"),
        .flags = &.{"-std=c99"},
    });
    markdown_tests_module.addCSourceFile(.{
        .file = b.path("third_party/md4c/entity.c"),
        .flags = &.{"-std=c99"},
    });
    const markdown_tests = b.addTest(.{
        .root_module = markdown_tests_module,
        .use_llvm = use_llvm,
    });
    const run_markdown_tests = b.addRunArtifact(markdown_tests);

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
        .use_llvm = use_llvm,
    });
    c_smoke.root_module.linkLibrary(library);
    const run_c_smoke = b.addRunArtifact(c_smoke);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_canvas_tests.step);
    test_step.dependOn(&run_c_api_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_chat_tests.step);
    test_step.dependOn(&run_tool_tests.step);
    test_step.dependOn(&run_markdown_tests.step);
    test_step.dependOn(&run_c_smoke.step);

    const install_c_api = b.step(
        "install-c-api",
        "Install the C-compatible backend library and headers",
    );
    install_c_api.dependOn(&install_library.step);
}

fn addClipboard(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    macos_sdk: ?[]const u8,
) void {
    if (target.result.os.tag != .macos) return;
    if (macos_sdk) |sdk| {
        module.addSystemIncludePath(.{
            .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }),
        });
        module.addSystemFrameworkPath(.{
            .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }),
        });
    }
    module.addCSourceFile(.{
        .file = b.path("cli/src/clipboard_macos.m"),
        .flags = &.{"-fobjc-arc"},
    });
    module.linkFramework("AppKit", .{});
}

fn addPty(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    module.addIncludePath(b.path("backend/src/pty"));
    switch (target.result.os.tag) {
        .linux, .macos => {
            module.link_libc = true;
            module.addCSourceFile(.{
                .file = b.path("backend/src/pty/posix.c"),
                .flags = &.{"-std=c11"},
            });
            if (target.result.os.tag == .linux) {
                module.linkSystemLibrary("util", .{});
            }
        },
        .windows => {},
        else => @panic("Vivi requires a PTY implementation for this target"),
    }
}

const SyntaxDependencies = struct {
    core: *std.Build.Dependency,
    bash: *std.Build.Dependency,
    json: *std.Build.Dependency,
    yaml: *std.Build.Dependency,
    diff: *std.Build.Dependency,
    javascript: *std.Build.Dependency,
    typescript: *std.Build.Dependency,
    rust: *std.Build.Dependency,
    c: *std.Build.Dependency,
    cpp: *std.Build.Dependency,
    go: *std.Build.Dependency,
    java: *std.Build.Dependency,
    lua: *std.Build.Dependency,
    python: *std.Build.Dependency,
};

fn addSyntaxHighlighting(
    b: *std.Build,
    module: *std.Build.Module,
    dependencies: SyntaxDependencies,
) void {
    const c_flags = &.{"-std=c11"};
    const core_c_flags = &.{
        "-std=c11",
        "-D_POSIX_C_SOURCE=200112L",
        "-D_DEFAULT_SOURCE",
    };
    module.link_libc = true;
    module.addIncludePath(dependencies.core.path("include"));
    module.addIncludePath(dependencies.core.path("src"));
    module.addIncludePath(b.path("third_party/tree-sitter-zig"));
    module.addCSourceFile(.{
        .file = dependencies.core.path("src/lib.c"),
        .flags = core_c_flags,
    });
    module.addCSourceFile(.{
        .file = b.path("third_party/tree-sitter-zig/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.bash.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.bash.path("src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.json.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.yaml.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.yaml.path("src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.diff.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.javascript.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.javascript.path("src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.typescript.path("typescript/src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.typescript.path("typescript/src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.typescript.path("tsx/src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.typescript.path("tsx/src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.rust.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.rust.path("src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.c.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.cpp.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.cpp.path("src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.go.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.java.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.lua.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.lua.path("src/scanner.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.python.path("src/parser.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dependencies.python.path("src/scanner.c"),
        .flags = c_flags,
    });
}
