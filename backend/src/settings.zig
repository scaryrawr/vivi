const std = @import("std");

pub const version: u32 = 1;

pub const Settings = struct {
    allocator: std.mem.Allocator,
    default_model: ?[]u8 = null,

    pub fn deinit(self: *Settings) void {
        if (self.default_model) |model| self.allocator.free(model);
        self.* = undefined;
    }
};

const Document = struct {
    version: u32,
    default_model: ?[]const u8 = null,
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
    };
}

pub fn saveDefaultModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    model_id: []const u8,
) !void {
    if (!std.unicode.utf8ValidateSlice(model_id) or
        std.mem.trim(u8, model_id, " \t\r\n").len != model_id.len or
        model_id.len == 0)
    {
        return error.InvalidSettingsModel;
    }

    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        Document{
            .version = version,
            .default_model = model_id,
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
