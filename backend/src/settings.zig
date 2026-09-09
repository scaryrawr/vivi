const std = @import("std");

pub const version: u32 = 1;

pub const Settings = struct {
    allocator: std.mem.Allocator,
    default_model: ?[]u8 = null,
    write_id: ?[write_id_hex_len]u8 = null,

    pub fn deinit(self: *Settings) void {
        if (self.default_model) |model| self.allocator.free(model);
        self.* = undefined;
    }
};

const Document = struct {
    version: u32,
    default_model: ?[]const u8 = null,
    write_id: ?[]const u8 = null,
};

const write_id_bytes: usize = 16;
const write_id_hex_len: usize = write_id_bytes * 2;

pub const DefaultModelUpdate = struct {
    allocator: std.mem.Allocator,
    previous_model: ?[]u8,
    written_id: [write_id_hex_len]u8,

    pub fn deinit(self: *DefaultModelUpdate) void {
        if (self.previous_model) |model| self.allocator.free(model);
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

    const parsed = try std.json.parseFromSlice(
        Document,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    if (parsed.value.version != version) return error.UnsupportedSettingsVersion;
    const write_id = try parseWriteId(parsed.value.write_id);

    const model = if (parsed.value.default_model) |value| blk: {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSettingsModel;
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len != value.len) {
            return error.InvalidSettingsModel;
        }
        break :blk try allocator.dupe(u8, value);
    } else null;

    return .{
        .allocator = allocator,
        .default_model = model,
        .write_id = write_id,
    };
}

pub fn saveDefaultModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    model_id: ?[]const u8,
) !void {
    var update = try updateDefaultModel(allocator, io, path, model_id);
    update.deinit();
}

pub fn updateDefaultModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    model_id: ?[]const u8,
) !DefaultModelUpdate {
    const lock = try acquireLock(allocator, io, path);
    defer lock.close(io);
    var current = try load(allocator, io, path);
    errdefer current.deinit();
    const write_id = newWriteId(io);
    try saveDefaultModelUnlocked(allocator, io, path, model_id, write_id);
    const previous_model = current.default_model;
    current.default_model = null;
    current.deinit();
    return .{
        .allocator = allocator,
        .previous_model = previous_model,
        .written_id = write_id,
    };
}

pub fn rollbackDefaultModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    update: *const DefaultModelUpdate,
) !bool {
    const lock = try acquireLock(allocator, io, path);
    defer lock.close(io);
    var current = try load(allocator, io, path);
    defer current.deinit();
    const current_write_id = current.write_id orelse return false;
    if (!std.mem.eql(u8, &current_write_id, &update.written_id)) return false;
    try saveDefaultModelUnlocked(
        allocator,
        io,
        path,
        update.previous_model,
        newWriteId(io),
    );
    return true;
}

fn saveDefaultModelUnlocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    model_id: ?[]const u8,
    write_id: [write_id_hex_len]u8,
) !void {
    if (model_id) |value| {
        if (!std.unicode.utf8ValidateSlice(value) or
            std.mem.trim(u8, value, " \t\r\n").len != value.len or
            value.len == 0)
        {
            return error.InvalidSettingsModel;
        }
    }

    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        Document{
            .version = version,
            .default_model = model_id,
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

test "missing settings use no explicit default model" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathAlloc(
        std.testing.io,
        std.testing.allocator,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var value = try load(std.testing.allocator, std.testing.io, path);
    defer value.deinit();
    try std.testing.expect(value.default_model == null);
}

test "settings round trip a canonical model id" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathAlloc(
        std.testing.io,
        std.testing.allocator,
        "nested/settings.json",
    );
    defer std.testing.allocator.free(path);

    try saveDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        "omlx/Qwen3.5-9B",
    );
    var value = try load(std.testing.allocator, std.testing.io, path);
    defer value.deinit();
    try std.testing.expectEqualStrings(
        "omlx/Qwen3.5-9B",
        value.default_model.?,
    );

    try saveDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        null,
    );
    var cleared = try load(std.testing.allocator, std.testing.io, path);
    defer cleared.deinit();
    try std.testing.expect(cleared.default_model == null);
}

test "settings reject invalid documents" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data = "{\"version\":2,\"default_model\":\"copilot/test\"}",
    });
    const path = try temporary.dir.realPathAlloc(
        std.testing.io,
        std.testing.allocator,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectError(
        error.UnsupportedSettingsVersion,
        load(std.testing.allocator, std.testing.io, path),
    );
}

test "settings rollback only replaces its exact write" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathAlloc(
        std.testing.io,
        std.testing.allocator,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var update_a = try updateDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        "copilot/model-a",
    );
    defer update_a.deinit();
    var update_b = try updateDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        "copilot/model-b",
    );
    defer update_b.deinit();
    try saveDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        "copilot/model-c",
    );
    try std.testing.expect(!try rollbackDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        &update_b,
    ));
    var preserved = try load(std.testing.allocator, std.testing.io, path);
    defer preserved.deinit();
    try std.testing.expectEqualStrings(
        "copilot/model-c",
        preserved.default_model.?,
    );

    var update_d = try updateDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        "copilot/model-d",
    );
    defer update_d.deinit();
    try std.testing.expect(try rollbackDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        &update_d,
    ));
    var restored = try load(std.testing.allocator, std.testing.io, path);
    defer restored.deinit();
    try std.testing.expectEqualStrings(
        "copilot/model-c",
        restored.default_model.?,
    );
}

test "settings rollback refuses a legacy rewrite" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathAlloc(
        std.testing.io,
        std.testing.allocator,
        "settings.json",
    );
    defer std.testing.allocator.free(path);

    var update = try updateDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        "copilot/model-a",
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

    try std.testing.expect(!try rollbackDefaultModel(
        std.testing.allocator,
        std.testing.io,
        path,
        &update,
    ));
    var preserved = try load(std.testing.allocator, std.testing.io, path);
    defer preserved.deinit();
    try std.testing.expectEqualStrings(
        "copilot/model-b",
        preserved.default_model.?,
    );
}
