const std = @import("std");
const builtin = @import("builtin");

pub const max_image_bytes = @import("vivi_backend").max_image_bytes;
const png_signature = "\x89PNG\r\n\x1a\n";
const command_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(5),
    .clock = .awake,
} };

extern fn vivi_clipboard_read_png(bytes: *?[*]u8, length: *usize, limit: usize) c_int;

/// Reads without changing the clipboard. The caller owns the returned PNG bytes.
pub fn readImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !?[]u8 {
    return switch (builtin.os.tag) {
        .macos => readMacImage(allocator),
        .linux => readLinuxImage(allocator, io, environ),
        .windows => readWindowsImage(allocator, io, environ),
        else => error.ClipboardUnsupportedPlatform,
    };
}

fn validatePng(bytes: []const u8) !void {
    if (bytes.len > max_image_bytes) return error.ClipboardImageTooLarge;
    if (!std.mem.startsWith(u8, bytes, png_signature)) return error.ClipboardInvalidPng;
}

fn readMacImage(allocator: std.mem.Allocator) !?[]u8 {
    var bytes: ?[*]u8 = null;
    var length: usize = 0;
    const status = vivi_clipboard_read_png(&bytes, &length, max_image_bytes);
    defer if (bytes) |ptr| std.c.free(ptr);
    switch (status) {
        0 => return null,
        1 => {},
        -2 => return error.ClipboardImageConversionFailed,
        -3 => return error.ClipboardImageTooLarge,
        -4 => return error.OutOfMemory,
        else => return error.ClipboardUnavailable,
    }
    const image = (bytes orelse return error.ClipboardInvalidPng)[0..length];
    try validatePng(image);
    return try allocator.dupe(u8, image);
}

const LinuxTool = enum { wayland, x11 };

fn linuxTool(environ: *const std.process.Environ.Map) !LinuxTool {
    if (environ.get("WAYLAND_DISPLAY")) |display| {
        if (display.len != 0) return .wayland;
    }
    if (environ.get("DISPLAY")) |display| {
        if (display.len != 0) return .x11;
    }
    return error.ClipboardSessionUnavailable;
}

fn readLinuxImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !?[]u8 {
    const tool = try linuxTool(environ);
    const list_args: []const []const u8 = switch (tool) {
        .wayland => &.{ "wl-paste", "--list-types" },
        .x11 => &.{ "xclip", "-selection", "clipboard", "-out", "-target", "TARGETS" },
    };
    const types = try runCommand(allocator, io, environ, list_args, 64 * 1024, command_timeout);
    defer allocator.free(types.stdout);
    defer allocator.free(types.stderr);
    if (!successful(types.term)) {
        if (emptySelection(tool, types)) return null;
        return error.ClipboardToolFailed;
    }
    if (!hasPngType(types.stdout)) return null;

    const image_args: []const []const u8 = switch (tool) {
        .wayland => &.{ "wl-paste", "--no-newline", "--type", "image/png" },
        .x11 => &.{ "xclip", "-selection", "clipboard", "-out", "-target", "image/png" },
    };
    const image = try runCommand(allocator, io, environ, image_args, max_image_bytes, command_timeout);
    defer allocator.free(image.stderr);
    errdefer allocator.free(image.stdout);
    if (!successful(image.term)) return error.ClipboardToolFailed;
    try validatePng(image.stdout);
    return image.stdout;
}

fn successful(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn hasPngType(types: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, types, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "image/png")) return true;
    }
    return false;
}

fn emptySelection(tool: LinuxTool, result: std.process.RunResult) bool {
    switch (result.term) {
        .exited => |code| if (code != 1) return false,
        else => return false,
    }
    const message = std.mem.trim(u8, result.stderr, " \t\r\n");
    return switch (tool) {
        .wayland => std.mem.eql(u8, message, "Nothing is copied") or
            std.mem.eql(u8, message, "No selection"),
        .x11 => std.mem.eql(u8, message, "Error: target TARGETS not available"),
    };
}

const windows_script =
    \\$ErrorActionPreference = 'Stop'
    \\try {
    \\  Add-Type -AssemblyName System.Windows.Forms
    \\  Add-Type -AssemblyName System.Drawing
    \\  $image = [System.Windows.Forms.Clipboard]::GetImage()
    \\  if ($null -eq $image) { exit 3 }
    \\  try {
    \\    $stream = New-Object System.IO.MemoryStream
    \\    try {
    \\      $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    \\      if ($stream.Length -gt 20971520) { exit 4 }
    \\      [Console]::Out.Write([Convert]::ToBase64String($stream.ToArray()))
    \\    } finally { $stream.Dispose() }
    \\  } finally { $image.Dispose() }
    \\} catch {
    \\  [Console]::Error.WriteLine($_.Exception.Message)
    \\  exit 1
    \\}
;

fn readWindowsImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !?[]u8 {
    const result = try runCommand(
        allocator,
        io,
        environ,
        &.{ "powershell.exe", "-STA", "-NoProfile", "-NonInteractive", "-Command", windows_script },
        std.base64.standard.Encoder.calcSize(max_image_bytes) + 2,
        command_timeout,
    );
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| switch (code) {
            0 => {},
            3 => return null,
            4 => return error.ClipboardImageTooLarge,
            else => return error.ClipboardToolFailed,
        },
        else => return error.ClipboardToolFailed,
    }
    return try decodeWindowsImage(allocator, result.stdout);
}

fn decodeWindowsImage(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    const encoded = std.mem.trim(u8, output, " \t\r\n");
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.ClipboardInvalidPng;
    if (size > max_image_bytes) return error.ClipboardImageTooLarge;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    decoder.decode(bytes, encoded) catch return error.ClipboardInvalidPng;
    try validatePng(bytes);
    return bytes;
}

// Race the entire process, including exit after its pipes close, against a deadline.
fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    limit: usize,
    timeout: std.Io.Timeout,
) !std.process.RunResult {
    const Result = union(enum) {
        command: std.process.RunError!std.process.RunResult,
        timeout: std.Io.Cancelable!void,
    };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer while (select.cancel()) |pending| {
        switch (pending) {
            .command => |result| if (result) |output| {
                allocator.free(output.stdout);
                allocator.free(output.stderr);
            } else |_| {},
            .timeout => {},
        }
    };
    try select.concurrent(.timeout, std.Io.Timeout.sleep, .{ timeout, io });
    try select.concurrent(.command, std.process.run, .{ allocator, io, .{
        .argv = argv,
        .environ_map = environ,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 * 1024),
    } });
    switch (try select.await()) {
        .timeout => |result| {
            try result;
            return error.ClipboardTimedOut;
        },
        .command => |result| return result catch |err| switch (err) {
            error.FileNotFound => error.ClipboardToolUnavailable,
            error.StreamTooLong => error.ClipboardImageTooLarge,
            else => err,
        },
    }
}

test "clipboard validates PNG signature and size" {
    try validatePng(png_signature ++ "payload");
    try std.testing.expectError(error.ClipboardInvalidPng, validatePng("not an image"));
    try std.testing.expectError(error.ClipboardInvalidPng, validatePng(""));
    const oversized = try std.testing.allocator.alloc(u8, max_image_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.ClipboardImageTooLarge, validatePng(oversized));
}

test "clipboard Linux selection and advertised image type" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expectError(error.ClipboardSessionUnavailable, linuxTool(&environ));
    try environ.put("DISPLAY", ":0");
    try std.testing.expectEqual(LinuxTool.x11, try linuxTool(&environ));
    try environ.put("WAYLAND_DISPLAY", "wayland-0");
    try std.testing.expectEqual(LinuxTool.wayland, try linuxTool(&environ));
    try environ.put("WAYLAND_DISPLAY", "");
    try std.testing.expectEqual(LinuxTool.x11, try linuxTool(&environ));
    try std.testing.expect(hasPngType("text/plain\r\nimage/png\r\n"));
    try std.testing.expect(!hasPngType("text/plain\nimage/png-extra\n"));
}

test "clipboard missing selection is distinct from tool and session failures" {
    var stderr = "Nothing is copied\n".*;
    var result: std.process.RunResult = .{
        .term = .{ .exited = 1 },
        .stdout = &.{},
        .stderr = &stderr,
    };
    try std.testing.expect(emptySelection(.wayland, result));
    try std.testing.expect(!emptySelection(.x11, result));
    result.term = .{ .exited = 2 };
    try std.testing.expect(!emptySelection(.wayland, result));
    var connection_error = "Failed to connect to a Wayland server\n".*;
    result.term = .{ .exited = 1 };
    result.stderr = &connection_error;
    try std.testing.expect(!emptySelection(.wayland, result));
}

test "clipboard Windows PNG base64 decoding" {
    const image = try decodeWindowsImage(std.testing.allocator, " iVBORw0KGgo=\r\n");
    defer std.testing.allocator.free(image);
    try std.testing.expectEqualSlices(u8, png_signature, image);
    try std.testing.expectError(error.ClipboardInvalidPng, decodeWindowsImage(std.testing.allocator, "invalid"));
    try std.testing.expectError(error.ClipboardInvalidPng, decodeWindowsImage(std.testing.allocator, "dGV4dA=="));
}

test "clipboard command errors and closed-pipe timeout do not need a clipboard" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expectError(error.ClipboardToolUnavailable, runCommand(
        std.testing.allocator,
        io,
        &environ,
        &.{"/vivi-clipboard-no-such-executable"},
        32,
        command_timeout,
    ));
    try std.testing.expectError(error.ClipboardTimedOut, runCommand(
        std.testing.allocator,
        io,
        &environ,
        &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; exec /bin/sleep 5" },
        32,
        .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } },
    ));
    try std.testing.expectError(error.ClipboardImageTooLarge, runCommand(
        std.testing.allocator,
        io,
        &environ,
        &.{ "/bin/sh", "-c", "printf 123456789" },
        4,
        command_timeout,
    ));
    const result = try runCommand(
        std.testing.allocator,
        io,
        &environ,
        &.{ "/bin/sh", "-c", "printf clipboard" },
        32,
        command_timeout,
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(successful(result.term));
    try std.testing.expectEqualStrings("clipboard", result.stdout);
}

test "clipboard platform implementations compile without accessing clipboard" {
    _ = &readLinuxImage;
    _ = &readWindowsImage;
    if (builtin.os.tag == .macos) _ = &readMacImage;
}
