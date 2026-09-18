const std = @import("std");
const builtin = @import("builtin");
const backend = @import("vivi_backend");

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []u8,
    files: std.ArrayList(File) = .empty,

    const File = struct {
        path: []u8,
        token: []u8,
    };

    pub const Selection = struct {
        allocator: std.mem.Allocator,
        snapshots: []backend.AttachmentSnapshot,
        inputs: []backend.AttachmentInput,

        pub fn empty(allocator: std.mem.Allocator) !Selection {
            const snapshots = try allocator.alloc(backend.AttachmentSnapshot, 0);
            errdefer allocator.free(snapshots);
            return .{
                .allocator = allocator,
                .snapshots = snapshots,
                .inputs = try allocator.alloc(backend.AttachmentInput, 0),
            };
        }

        pub fn deinit(self: *Selection) void {
            for (self.snapshots) |*snapshot| snapshot.deinit(self.allocator);
            self.allocator.free(self.snapshots);
            self.allocator.free(self.inputs);
            self.* = undefined;
        }
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

    pub fn selectedAttachments(
        self: *const Store,
        text: []const u8,
    ) !Selection {
        var snapshots: std.ArrayList(backend.AttachmentSnapshot) = .empty;
        errdefer {
            for (snapshots.items) |*snapshot| snapshot.deinit(self.allocator);
            snapshots.deinit(self.allocator);
        }
        for (self.files.items) |file| {
            if (std.mem.indexOf(u8, text, file.token) != null) {
                var snapshot = try backend.AttachmentSnapshot.fromFile(
                    self.allocator,
                    self.io,
                    std.fs.path.basename(file.path),
                    file.path,
                );
                snapshots.append(self.allocator, snapshot) catch |err| {
                    snapshot.deinit(self.allocator);
                    return err;
                };
            }
        }
        const owned = try snapshots.toOwnedSlice(self.allocator);
        errdefer {
            for (owned) |*snapshot| snapshot.deinit(self.allocator);
            self.allocator.free(owned);
        }
        const inputs = try self.allocator.alloc(backend.AttachmentInput, owned.len);
        for (owned, inputs) |snapshot, *input| input.* = snapshot.borrow();
        return .{
            .allocator = self.allocator,
            .snapshots = owned,
            .inputs = inputs,
        };
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
    const first = try store.save("\x89PNG\r\n\x1a\nfirst");
    const second = try store.save("\x89PNG\r\n\x1a\nsecond");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const text = try std.fmt.allocPrint(std.testing.allocator, "Describe {s} and {s}. Again: {s}", .{ first, second, first });
    defer std.testing.allocator.free(text);
    var selected = try store.selectedAttachments(text);
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 2), selected.inputs.len);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nfirst", selected.inputs[0].bytes);
    const contents = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        store.files.items[0].path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\nfirst", contents);
    if (builtin.os.tag != .windows) {
        const file = try std.Io.Dir.cwd().openFile(std.testing.io, store.files.items[0].path, .{});
        defer file.close(std.testing.io);
        try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(std.testing.io)).permissions.toMode() & 0o777);
    }
    var deleted = try store.selectedAttachments("Never mind, no image");
    defer deleted.deinit();
    try std.testing.expectEqual(@as(usize, 0), deleted.inputs.len);
    var edited = try store.selectedAttachments(first[1..]);
    defer edited.deinit();
    try std.testing.expectEqual(@as(usize, 0), edited.inputs.len);
}

test "image paste cleanup removes only files owned by this store" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "user.png", .data = "keep" });
    var store = try Store.init(std.testing.allocator, std.testing.io, path_buffer[0..len]);
    _ = try store.save("\x89PNG\r\n\x1a\npaste");
    const path = try std.testing.allocator.dupe(u8, store.files.items[0].path);
    defer std.testing.allocator.free(path);
    store.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
    const file = try temporary.dir.openFile(std.testing.io, "user.png", .{});
    file.close(std.testing.io);
}

test "selected attachment snapshots current temporary file bytes" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var store = try Store.init(std.testing.allocator, std.testing.io, path_buffer[0..len]);
    defer store.deinit();
    const token = try store.save("\x89PNG\r\n\x1a\noriginal");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.files.items[0].path,
        .data = "\x89PNG\r\n\x1a\nchanged",
    });

    var selected = try store.selectedAttachments(token);
    defer selected.deinit();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.files.items[0].path);

    try std.testing.expectEqualStrings(
        "\x89PNG\r\n\x1a\nchanged",
        selected.inputs[0].bytes,
    );
}
