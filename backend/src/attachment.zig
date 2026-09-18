const std = @import("std");
const image = @import("image.zig");

pub const max_count: usize = 32;
pub const max_bytes: usize = image.max_bytes;
pub const max_identity_bytes: usize = 256;
pub const max_display_name_bytes: usize = 1024;

pub const Input = struct {
    identity: []const u8,
    display_name: []const u8,
    media_type: image.Format,
    bytes: []const u8,
};

pub const Snapshot = struct {
    identity: []u8,
    display_name: []u8,
    media_type: image.Format,
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, input: Input) !Snapshot {
        try validate(input);
        const identity = try allocator.dupe(u8, input.identity);
        errdefer allocator.free(identity);
        const display_name = try allocator.dupe(u8, input.display_name);
        errdefer allocator.free(display_name);
        return .{
            .identity = identity,
            .display_name = display_name,
            .media_type = input.media_type,
            .bytes = try allocator.dupe(u8, input.bytes),
        };
    }

    pub fn fromFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        identity: []const u8,
        path: []const u8,
    ) !Snapshot {
        var value = try image.Image.fromFile(allocator, io, path);
        errdefer value.deinit(allocator);
        const input: Input = .{
            .identity = identity,
            .display_name = value.description,
            .media_type = value.format,
            .bytes = value.bytes,
        };
        try validate(input);
        return .{
            .identity = try allocator.dupe(u8, identity),
            .display_name = @constCast(value.description),
            .media_type = value.format,
            .bytes = @constCast(value.bytes),
        };
    }

    pub fn borrow(self: Snapshot) Input {
        return .{
            .identity = self.identity,
            .display_name = self.display_name,
            .media_type = self.media_type,
            .bytes = self.bytes,
        };
    }

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.identity);
        allocator.free(self.display_name);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn snapshotAll(
    allocator: std.mem.Allocator,
    inputs: []const Input,
) ![]Snapshot {
    if (inputs.len > max_count) return error.TooManyAttachments;
    var total_bytes: usize = 0;
    for (inputs, 0..) |input, index| {
        try validate(input);
        for (inputs[0..index]) |previous| {
            if (std.mem.eql(u8, previous.identity, input.identity)) {
                return error.DuplicateAttachmentIdentity;
            }
        }
        total_bytes = std.math.add(usize, total_bytes, input.bytes.len) catch
            return error.AttachmentsTooLarge;
        if (total_bytes > max_bytes) return error.AttachmentsTooLarge;
    }

    const snapshots = try allocator.alloc(Snapshot, inputs.len);
    errdefer allocator.free(snapshots);
    var initialized: usize = 0;
    errdefer for (snapshots[0..initialized]) |*snapshot| snapshot.deinit(allocator);
    for (inputs, snapshots) |input, *snapshot| {
        snapshot.* = try Snapshot.init(allocator, input);
        initialized += 1;
    }
    return snapshots;
}

pub fn deinitAll(allocator: std.mem.Allocator, snapshots: []Snapshot) void {
    for (snapshots) |*snapshot| snapshot.deinit(allocator);
    allocator.free(snapshots);
}

fn validate(input: Input) !void {
    try validateText(input.identity, max_identity_bytes, error.InvalidAttachmentIdentity);
    try validateText(
        input.display_name,
        max_display_name_bytes,
        error.InvalidAttachmentDisplayName,
    );
    if (input.bytes.len == 0) return error.EmptyAttachment;
    if (input.bytes.len > max_bytes) return error.AttachmentTooLarge;
    if (image.detect(input.bytes) != input.media_type) {
        return error.AttachmentMediaMismatch;
    }
}

fn validateText(value: []const u8, limit: usize, invalid: anyerror) !void {
    if (value.len == 0 or value.len > limit or
        std.mem.indexOfScalar(u8, value, 0) != null or
        !std.unicode.utf8ValidateSlice(value))
    {
        return invalid;
    }
}

test "attachment snapshots own validated bytes and metadata" {
    var identity = [_]u8{ 'i', 'd' };
    var display_name = [_]u8{ 'a', '.', 'p', 'n', 'g' };
    var bytes = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    const inputs = [_]Input{.{
        .identity = &identity,
        .display_name = &display_name,
        .media_type = .png,
        .bytes = &bytes,
    }};
    const snapshots = try snapshotAll(std.testing.allocator, &inputs);
    defer deinitAll(std.testing.allocator, snapshots);

    identity[0] = 'x';
    display_name[0] = 'x';
    bytes[1] = 'x';
    try std.testing.expectEqualStrings("id", snapshots[0].identity);
    try std.testing.expectEqualStrings("a.png", snapshots[0].display_name);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", snapshots[0].bytes);
}

test "attachment validation rejects mismatched and excessive inputs atomically" {
    const png = "\x89PNG\r\n\x1a\n";
    try std.testing.expectError(error.AttachmentMediaMismatch, snapshotAll(
        std.testing.allocator,
        &.{.{
            .identity = "one",
            .display_name = "one.jpg",
            .media_type = .jpeg,
            .bytes = png,
        }},
    ));

    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.AttachmentTooLarge, snapshotAll(
        std.testing.allocator,
        &.{.{
            .identity = "large",
            .display_name = "large.png",
            .media_type = .png,
            .bytes = oversized,
        }},
    ));

    var too_many: [max_count + 1]Input = undefined;
    for (&too_many, 0..) |*input, index| {
        input.* = .{
            .identity = if (index == 0) "first" else "next",
            .display_name = "image.png",
            .media_type = .png,
            .bytes = png,
        };
    }
    try std.testing.expectError(
        error.TooManyAttachments,
        snapshotAll(std.testing.allocator, &too_many),
    );

    const half = try std.testing.allocator.alloc(u8, max_bytes / 2 + 1);
    defer std.testing.allocator.free(half);
    @memset(half, 0);
    @memcpy(half[0..8], png);
    try std.testing.expectError(error.AttachmentsTooLarge, snapshotAll(
        std.testing.allocator,
        &.{
            .{
                .identity = "first",
                .display_name = "first.png",
                .media_type = .png,
                .bytes = half,
            },
            .{
                .identity = "second",
                .display_name = "second.png",
                .media_type = .png,
                .bytes = half,
            },
        },
    ));

    try std.testing.expectError(error.DuplicateAttachmentIdentity, snapshotAll(
        std.testing.allocator,
        &.{
            .{
                .identity = "same",
                .display_name = "first.png",
                .media_type = .png,
                .bytes = png,
            },
            .{
                .identity = "same",
                .display_name = "second.png",
                .media_type = .png,
                .bytes = png,
            },
        },
    ));
}
