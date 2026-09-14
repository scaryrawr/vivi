const std = @import("std");
const conversation = @import("conversation.zig");

pub const version: u32 = 2;

pub const Settings = struct {
    allocator: std.mem.Allocator,
    default_selection: ?conversation.OwnedModelSelection = null,
    write_id: ?[write_id_hex_len]u8 = null,

    pub fn deinit(self: *Settings) void {
        if (self.default_selection) |*selection| selection.deinit();
        self.* = undefined;
    }
};

const DocumentV1 = struct {
    version: u32,
    default_model: ?[]const u8 = null,
    write_id: ?[]const u8 = null,
};

const DocumentSelection = struct {
    model_id: []const u8,
    reasoning: conversation.ReasoningEffort,
};

const DocumentV2 = struct {
    version: u32,
    default_selection: ?DocumentSelection = null,
    write_id: ?[]const u8 = null,
};

const VersionHeader = struct {
    version: u32,
};

const write_id_bytes: usize = 16;
const write_id_hex_len: usize = write_id_bytes * 2;

pub const DefaultSelectionUpdate = struct {
    allocator: std.mem.Allocator,
    previous_selection: ?conversation.OwnedModelSelection,
    written_id: [write_id_hex_len]u8,

    pub fn deinit(self: *DefaultSelectionUpdate) void {
        if (self.previous_selection) |*selection| selection.deinit();
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !Settings {
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = allocator },
        else => return err,
    };
    defer allocator.free(content);

    const header = try std.json.parseFromSlice(
        VersionHeader,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    );
    defer header.deinit();
    return switch (header.value.version) {
        1 => loadV1(allocator, content),
        version => loadV2(allocator, content),
        else => error.UnsupportedSettingsVersion,
    };
}

fn loadV1(allocator: std.mem.Allocator, content: []const u8) !Settings {
    const parsed = try std.json.parseFromSlice(
        DocumentV1,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const write_id = try parseWriteId(parsed.value.write_id);
    const selection = if (parsed.value.default_model) |model| blk: {
        try validateModel(model);
        break :blk try conversation.OwnedModelSelection.init(allocator, .{
            .model_id = model,
            .reasoning = .off,
        });
    } else null;
    return .{
        .allocator = allocator,
        .default_selection = selection,
        .write_id = write_id,
    };
}

fn loadV2(allocator: std.mem.Allocator, content: []const u8) !Settings {
    const parsed = try std.json.parseFromSlice(
        DocumentV2,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    const write_id = try parseWriteId(parsed.value.write_id);
    const selection = if (parsed.value.default_selection) |value| blk: {
        try validateModel(value.model_id);
        break :blk try conversation.OwnedModelSelection.init(allocator, .{
            .model_id = value.model_id,
            .reasoning = value.reasoning,
        });
    } else null;
    return .{
        .allocator = allocator,
        .default_selection = selection,
        .write_id = write_id,
    };
}

pub fn saveDefaultSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    selection: ?conversation.ModelSelection,
) !void {
    var update = try updateDefaultSelection(allocator, io, path, selection);
    update.deinit();
}

pub fn updateDefaultSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    selection: ?conversation.ModelSelection,
) !DefaultSelectionUpdate {
    const lock = try acquireLock(allocator, io, path);
    defer lock.close(io);
    var current = try load(allocator, io, path);
    errdefer current.deinit();
    const write_id = newWriteId(io);
    try saveDefaultSelectionUnlocked(allocator, io, path, selection, write_id);
    const previous_selection = current.default_selection;
    current.default_selection = null;
    current.deinit();
    return .{
        .allocator = allocator,
        .previous_selection = previous_selection,
        .written_id = write_id,
    };
}

pub fn rollbackDefaultSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    update: *const DefaultSelectionUpdate,
) !bool {
    const lock = try acquireLock(allocator, io, path);
    defer lock.close(io);
    var current = try load(allocator, io, path);
    defer current.deinit();
    const current_write_id = current.write_id orelse return false;
    if (!std.mem.eql(u8, &current_write_id, &update.written_id)) return false;
    try saveDefaultSelectionUnlocked(
        allocator,
        io,
        path,
        if (update.previous_selection) |*selection|
            selection.view()
        else
            null,
        newWriteId(io),
    );
    return true;
}

fn saveDefaultSelectionUnlocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    selection: ?conversation.ModelSelection,
    write_id: [write_id_hex_len]u8,
) !void {
    if (selection) |value| try validateModel(value.model_id);

    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        DocumentV2{
            .version = version,
            .default_selection = if (selection) |value| .{
                .model_id = value.model_id,
                .reasoning = value.reasoning,
            } else null,
            .write_id = &write_id,
        },
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(encoded);

    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.writeByte('\n');
    try writer.flush();
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
}

fn validateModel(value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value) or
        std.mem.trim(u8, value, " \t\r\n").len != value.len or
        value.len == 0)
    {
        return error.InvalidSettingsModel;
    }
}

fn acquireLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !std.Io.File {
    if (std.fs.path.dirname(path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io, directory);
    }
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    defer allocator.free(lock_path);
    return std.Io.Dir.cwd().createFile(
        io,
        lock_path,
        .{ .truncate = false, .lock = .exclusive },
    );
}

fn newWriteId(io: std.Io) [write_id_hex_len]u8 {
    var random_bytes: [write_id_bytes]u8 = undefined;
    std.Io.randomSecure(io, &random_bytes) catch
        std.Io.random(io, &random_bytes);
    return std.fmt.bytesToHex(random_bytes, .lower);
}

fn parseWriteId(value: ?[]const u8) !?[write_id_hex_len]u8 {
    const bytes = value orelse return null;
    if (bytes.len != write_id_hex_len) return error.InvalidSettingsWriteId;
    for (bytes) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.InvalidSettingsWriteId;
        }
    }
    var write_id: [write_id_hex_len]u8 = undefined;
    @memcpy(&write_id, bytes);
    return write_id;
}

fn temporaryPath(
    allocator: std.mem.Allocator,
    directory: std.Io.Dir,
    sub_path: []const u8,
) ![]u8 {
    const root = try directory.realPathFileAlloc(
        std.testing.io,
        ".",
        allocator,
    );
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, sub_path });
}

test "missing settings use no explicit default selection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(
        std.testing.allocator,
        temporary.dir,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var value = try load(std.testing.allocator, std.testing.io, path);
    defer value.deinit();
    try std.testing.expect(value.default_selection == null);
}

test "settings round trip a model and reasoning selection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(
        std.testing.allocator,
        temporary.dir,
        "nested/settings.json",
    );
    defer std.testing.allocator.free(path);

    try saveDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        .{
            .model_id = "omlx/Qwen3.5-9B",
            .reasoning = .high,
        },
    );
    var value = try load(std.testing.allocator, std.testing.io, path);
    defer value.deinit();
    try std.testing.expectEqualStrings(
        "omlx/Qwen3.5-9B",
        value.default_selection.?.model_id,
    );
    try std.testing.expectEqual(
        conversation.ReasoningEffort.high,
        value.default_selection.?.reasoning,
    );

    try saveDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        null,
    );
    var cleared = try load(std.testing.allocator, std.testing.io, path);
    defer cleared.deinit();
    try std.testing.expect(cleared.default_selection == null);
}

test "settings load legacy model as reasoning off" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data = "{\"version\":1,\"default_model\":\"copilot/test\"}",
    });
    const path = try temporaryPath(
        std.testing.allocator,
        temporary.dir,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var value = try load(std.testing.allocator, std.testing.io, path);
    defer value.deinit();
    try std.testing.expectEqualStrings(
        "copilot/test",
        value.default_selection.?.model_id,
    );
    try std.testing.expectEqual(
        conversation.ReasoningEffort.off,
        value.default_selection.?.reasoning,
    );

    try saveDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        value.default_selection.?.view(),
    );
    var rewritten = try load(std.testing.allocator, std.testing.io, path);
    defer rewritten.deinit();
    try std.testing.expectEqualStrings(
        "copilot/test",
        rewritten.default_selection.?.model_id,
    );
    try std.testing.expectEqual(
        conversation.ReasoningEffort.off,
        rewritten.default_selection.?.reasoning,
    );
}

test "settings reject malformed write IDs before allocating selections" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(
        std.testing.allocator,
        temporary.dir,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data =
        \\{"version":1,"default_model":"copilot/test","write_id":"invalid"}
        ,
    });
    try std.testing.expectError(
        error.InvalidSettingsWriteId,
        load(std.testing.allocator, std.testing.io, path),
    );

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data =
        \\{"version":2,"default_selection":{"model_id":"copilot/test","reasoning":"high"},"write_id":"invalid"}
        ,
    });
    try std.testing.expectError(
        error.InvalidSettingsWriteId,
        load(std.testing.allocator, std.testing.io, path),
    );
}

test "settings rollback only replaces its exact write" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(
        std.testing.allocator,
        temporary.dir,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var update_a = try updateDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        .{ .model_id = "copilot/model-a", .reasoning = .low },
    );
    defer update_a.deinit();
    var update_b = try updateDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        .{ .model_id = "copilot/model-b", .reasoning = .medium },
    );
    defer update_b.deinit();
    try saveDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        .{ .model_id = "copilot/model-c", .reasoning = .high },
    );
    try std.testing.expect(!try rollbackDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        &update_b,
    ));
    var preserved = try load(std.testing.allocator, std.testing.io, path);
    defer preserved.deinit();
    try std.testing.expectEqualStrings(
        "copilot/model-c",
        preserved.default_selection.?.model_id,
    );

    var update_d = try updateDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        .{ .model_id = "copilot/model-d", .reasoning = .xhigh },
    );
    defer update_d.deinit();
    try std.testing.expect(try rollbackDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        &update_d,
    ));
    var restored = try load(std.testing.allocator, std.testing.io, path);
    defer restored.deinit();
    try std.testing.expectEqualStrings(
        "copilot/model-c",
        restored.default_selection.?.model_id,
    );
    try std.testing.expectEqual(
        conversation.ReasoningEffort.high,
        restored.default_selection.?.reasoning,
    );
}

test "settings rollback refuses a legacy rewrite" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporaryPath(
        std.testing.allocator,
        temporary.dir,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var update = try updateDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        .{ .model_id = "copilot/model-a", .reasoning = .low },
    );
    defer update.deinit();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data =
        \\{
        \\  "version": 1,
        \\  "default_model": "copilot/model-b"
        \\}
        ,
    });

    try std.testing.expect(!try rollbackDefaultSelection(
        std.testing.allocator,
        std.testing.io,
        path,
        &update,
    ));
    var preserved = try load(std.testing.allocator, std.testing.io, path);
    defer preserved.deinit();
    try std.testing.expectEqualStrings(
        "copilot/model-b",
        preserved.default_selection.?.model_id,
    );
    try std.testing.expectEqual(
        conversation.ReasoningEffort.off,
        preserved.default_selection.?.reasoning,
    );
}
