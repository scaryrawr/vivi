const std = @import("std");
const vaxis = @import("vaxis");

pub const Preview = struct {
    state: union(enum) {
        pending: []u8,
        ready: vaxis.Image,
        unsupported,
        failed: []u8,
    },

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Preview {
        return .{ .state = .{ .pending = try allocator.dupe(u8, bytes) } };
    }

    pub fn deinit(self: *Preview, allocator: std.mem.Allocator) void {
        switch (self.state) {
            .pending, .failed => |bytes| allocator.free(bytes),
            .ready, .unsupported => {},
        }
        self.* = undefined;
    }

    pub fn release(self: *Preview, vx: *vaxis.Vaxis, tty: *std.Io.Writer) void {
        if (self.state == .ready) {
            vx.freeImage(tty, self.state.ready.id);
            self.state = .unsupported;
        }
    }

    pub fn prepare(self: *Preview, allocator: std.mem.Allocator, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
        if (self.state != .pending) return;
        const bytes = self.state.pending;
        defer allocator.free(bytes);
        self.state = .unsupported;
        if (!vx.caps.kitty_graphics) return;
        const image = load(allocator, vx, tty, bytes) catch |err| {
            self.state = .{ .failed = try std.fmt.allocPrint(allocator, "Image preview unavailable: {s}.", .{@errorName(err)}) };
            return;
        };
        self.state = .{ .ready = image };
    }

    fn load(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, tty: *std.Io.Writer, bytes: []const u8) !vaxis.Image {
        var decoded = try vaxis.zigimg.Image.fromMemory(allocator, bytes);
        defer decoded.deinit(allocator);
        if (decoded.width == 0 or decoded.height == 0 or
            decoded.width > std.math.maxInt(u16) or decoded.height > std.math.maxInt(u16))
            return error.InvalidImageDimensions;
        return vx.transmitImage(allocator, tty, &decoded, .png);
    }

    pub fn cellSize(self: Preview, window: vaxis.Window) vaxis.Image.CellSize {
        if (window.width == 0 or window.height == 0) return .{ .rows = 0, .cols = 0 };
        return switch (self.state) {
            .pending => .{ .rows = 0, .cols = 0 },
            .unsupported, .failed => .{ .rows = 1, .cols = window.width },
            .ready => |image| fit(image, window),
        };
    }

    pub fn notice(self: Preview) ?[]const u8 {
        return switch (self.state) {
            .unsupported => "Image preview requires a Kitty-graphics terminal.",
            .failed => |message| message,
            .pending, .ready => null,
        };
    }

    pub fn draw(self: Preview, window: vaxis.Window, size: vaxis.Image.CellSize, first_row: usize) !void {
        if (self.state != .ready or window.width == 0 or window.height == 0 or size.rows == 0) return;
        const image = self.state.ready;
        const last_row = @min(first_row + window.height, size.rows);
        const source_start = first_row * @as(usize, image.height) / size.rows;
        const source_end = last_row * @as(usize, image.height) / size.rows;
        try image.draw(window, .{
            .size = .{ .rows = @intCast(last_row - first_row), .cols = size.cols },
            .clip_region = .{
                .x = 0,
                .y = @intCast(source_start),
                .width = image.width,
                .height = @intCast(@max(1, source_end - source_start)),
            },
        });
    }
};

fn fit(image: vaxis.Image, window: vaxis.Window) vaxis.Image.CellSize {
    const screen = window.screen;
    const cell_width: u64 = if (screen.width_pix > 0 and screen.width > 0)
        std.math.divCeil(u64, screen.width_pix, screen.width) catch unreachable
    else
        8;
    const cell_height: u64 = if (screen.height_pix > 0 and screen.height > 0)
        std.math.divCeil(u64, screen.height_pix, screen.height) catch unreachable
    else
        16;
    const max_cols: u64 = @min(window.width, 60);
    const max_rows: u64 = @min(window.height, 12);
    var width: u64 = @min(image.width, max_cols * cell_width);
    var height: u64 = @max(1, @as(u64, image.height) * width / image.width);
    if (height > max_rows * cell_height) {
        height = max_rows * cell_height;
        width = @max(1, @as(u64, image.width) * height / image.height);
    }
    return .{
        .cols = @intCast(@min(max_cols, (width + cell_width - 1) / cell_width)),
        .rows = @intCast(@min(max_rows, (height + cell_height - 1) / cell_height)),
    };
}

test "image preview fits terminal cells without stretching or exceeding bounds" {
    var screen: vaxis.Screen = .{ .width = 100, .height = 40, .width_pix = 800, .height_pix = 640 };
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 80,
        .height = 30,
        .screen = &screen,
    };
    const preview: Preview = .{ .state = .{ .ready = vaxis.Image.init(1, 800, 400) } };
    try std.testing.expectEqual(vaxis.Image.CellSize{ .rows = 12, .cols = 48 }, preview.cellSize(window));
    try std.testing.expectEqual(vaxis.Image.CellSize{ .rows = 3, .cols = 10 }, preview.cellSize(window.child(.{ .width = 10 })));
    try std.testing.expectEqual(vaxis.Image.CellSize{ .rows = 0, .cols = 0 }, preview.cellSize(window.child(.{ .width = 0 })));
}

test "image preview clips visible source rows and clears its placement on redraw" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .cols = 80, .rows = 24, .x_pixel = 640, .y_pixel = 384 });
    defer screen.deinit(std.testing.allocator);
    const window: vaxis.Window = .{
        .x_off = 2,
        .y_off = 4,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 40,
        .height = 3,
        .screen = &screen,
    };
    const preview: Preview = .{ .state = .{ .ready = vaxis.Image.init(7, 320, 160) } };
    try preview.draw(window, .{ .rows = 10, .cols = 40 }, 4);
    const placement = screen.readCell(2, 4).?.image.?;
    try std.testing.expectEqual(@as(u32, 7), placement.img_id);
    try std.testing.expectEqual(@as(?u16, 3), placement.options.size.?.rows);
    try std.testing.expectEqual(@as(?u16, 40), placement.options.size.?.cols);
    try std.testing.expectEqual(@as(?u16, 64), placement.options.clip_region.?.y);
    try std.testing.expectEqual(@as(?u16, 48), placement.options.clip_region.?.height);
    try std.testing.expect(screen.readCell(2, 3).?.image == null);
    try std.testing.expect(screen.readCell(2, 7).?.image == null);
    screen.clear();
    try std.testing.expect(screen.readCell(2, 4).?.image == null);
}
