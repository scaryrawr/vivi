const std = @import("std");
const builtin = @import("builtin");

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []u8,
    files: std.ArrayList(File) = .empty,

    const File = struct {
        path: []u8,
        token: []u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !Store {
        if (!std.fs.path.isAbsolute(directory)) return error.InvalidImageTemporaryDirectory;
        return .{
            .allocator = allocator,
            .io = io,
            .directory = try allocator.dupe(u8, directory),
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.files.items) |file| {
            self.remove(file.path);
            self.allocator.free(file.path);
            self.allocator.free(file.token);
        }
        self.files.deinit(self.allocator);
        self.allocator.free(self.directory);
        self.* = undefined;
    }

    // The store outlives the conversation worker, including queued sends and tools.
    pub fn save(self: *Store, png: []const u8) ![]const u8 {
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(self.io, &random);
        const filename = "vivi-image-" ++ std.fmt.bytesToHex(random, .lower) ++ ".png";
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, filename });
        errdefer self.allocator.free(path);
        const token = try std.json.Stringify.valueAlloc(self.allocator, path, .{});
        errdefer self.allocator.free(token);
        try self.files.ensureUnusedCapacity(self.allocator, 1);

        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{
            .exclusive = true,
            .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
        });
        errdefer self.remove(path);
        {
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, png);
        }
        self.files.appendAssumeCapacity(.{ .path = path, .token = token });
        return token;
    }

    pub fn selectedPaths(self: *const Store, text: []const u8) ![]const []const u8 {
        var paths: std.ArrayList([]const u8) = .empty;
        errdefer paths.deinit(self.allocator);
        for (self.files.items) |file| {
            if (std.mem.indexOf(u8, text, file.token) != null)
                try paths.append(self.allocator, file.path);
        }
        return paths.toOwnedSlice(self.allocator);
    }

    fn remove(self: *Store, path: []const u8) void {
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("Unable to remove pasted image {s}: {s}", .{ path, @errorName(err) }),
        };
    }
};

test "image paste stores private unique files and selects only visible paths" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var store = try Store.init(std.testing.allocator, std.testing.io, path_buffer[0..len]);
    defer store.deinit();
    const first = try store.save("first");
    const second = try store.save("second");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const text = try std.fmt.allocPrint(std.testing.allocator, "Describe {s} and {s}. Again: {s}", .{ first, second, first });
    defer std.testing.allocator.free(text);
    const selected = try store.selectedPaths(text);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, selected[0], std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("first", contents);
    if (builtin.os.tag != .windows) {
        const file = try std.Io.Dir.cwd().openFile(std.testing.io, selected[0], .{});
        defer file.close(std.testing.io);
        try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(std.testing.io)).permissions.toMode() & 0o777);
    }
    const deleted = try store.selectedPaths("Never mind, no image");
    defer std.testing.allocator.free(deleted);
    try std.testing.expectEqual(@as(usize, 0), deleted.len);
    const edited = try store.selectedPaths(first[1..]);
    defer std.testing.allocator.free(edited);
    try std.testing.expectEqual(@as(usize, 0), edited.len);
}

test "image paste cleanup removes only files owned by this store" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "user.png", .data = "keep" });
    var store = try Store.init(std.testing.allocator, std.testing.io, path_buffer[0..len]);
    _ = try store.save("paste");
    const path = try std.testing.allocator.dupe(u8, store.files.items[0].path);
    defer std.testing.allocator.free(path);
    store.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
    const file = try temporary.dir.openFile(std.testing.io, "user.png", .{});
    file.close(std.testing.io);
}
