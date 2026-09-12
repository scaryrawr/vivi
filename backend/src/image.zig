const std = @import("std");
pub const max_bytes = 20 * 1024 * 1024;

pub const Image = struct {
    bytes: []const u8,
    format: Format,
    description: []const u8,

    pub fn fromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Image {
        if (!std.fs.path.isAbsolute(path) or
            std.mem.indexOfScalar(u8, path, 0) != null or
            !std.unicode.utf8ValidateSlice(path)) return error.InvalidImagePath;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ImageTooLarge,
            else => return err,
        };
        errdefer allocator.free(bytes);
        return .{
            .bytes = bytes,
            .format = detect(bytes) orelse return error.UnsupportedImageFormat,
            .description = try allocator.dupe(u8, std.fs.path.basename(path)),
        };
    }

    pub fn clone(self: Image, allocator: std.mem.Allocator) !Image {
        const bytes = try allocator.dupe(u8, self.bytes);
        errdefer allocator.free(bytes);
        return .{
            .bytes = bytes,
            .format = self.format,
            .description = try allocator.dupe(u8, self.description),
        };
    }

    pub fn eql(self: Image, other: Image) bool {
        return self.format == other.format and
            std.mem.eql(u8, self.bytes, other.bytes) and
            std.mem.eql(u8, self.description, other.description);
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const Format = enum {
    png,
    jpeg,
    gif,
    webp,

    pub fn mimeType(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};

pub fn detect(bytes: []const u8) ?Format {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or
        std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return null;
}

test "image formats are identified by content, not filenames" {
    try std.testing.expectEqual(Format.png, detect("\x89PNG\r\n\x1a\n").?);
    try std.testing.expectEqual(Format.jpeg, detect("\xff\xd8\xff\xe0").?);
    try std.testing.expectEqual(Format.gif, detect("GIF87a").?);
    try std.testing.expectEqual(Format.gif, detect("GIF89a").?);
    try std.testing.expectEqual(Format.webp, detect("RIFF\x00\x00\x00\x00WEBP").?);
    try std.testing.expectEqual(@as(?Format, null), detect("RIFF"));
    try std.testing.expectEqual(@as(?Format, null), detect("photo.png"));
    try std.testing.expectEqual(@as(?Format, null), detect(""));
}
