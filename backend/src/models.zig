const std = @import("std");

pub const default_omlx_base_url = "http://localhost:8000";
pub const default_context_window_tokens: u64 = 131_072;
pub const default_max_output_tokens: u64 = 32_768;

pub const OmlxOptions = struct {
    base_url: []const u8 = default_omlx_base_url,
    api_key: ?[]const u8 = "omlx",
};

pub fn omlxServerRoot(base_url: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    return if (std.mem.endsWith(u8, trimmed, "/v1"))
        trimmed[0 .. trimmed.len - 3]
    else
        trimmed;
}

pub const Model = struct {
    id: []u8,
    provider_model_id: []u8,
    display_name: []u8,
    max_context_window_tokens: u64,
    max_output_tokens: u64,
    supports_vision: bool,

    fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provider_model_id);
        allocator.free(self.display_name);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    models: []Model,

    pub fn deinit(self: *Catalog) void {
        for (self.models) |*model| model.deinit(self.allocator);
        self.allocator.free(self.models);
        self.* = undefined;
    }

    pub fn find(self: *const Catalog, id: []const u8) ?*const Model {
        for (self.models) |*model| {
            if (std.mem.eql(u8, model.id, id)) return model;
        }
        return null;
    }
};

pub fn discoverOmlx(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: OmlxOptions,
) !Catalog {
    const base_url = omlxServerRoot(options.base_url);
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/v1/models/status",
        .{base_url},
    );
    defer allocator.free(url);

    const authorization = if (options.api_key) |api_key|
        try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key})
    else
        null;
    defer if (authorization) |value| allocator.free(value);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const body_buffer = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(body_buffer);
    var body_writer = std.Io.Writer.fixed(body_buffer);

    const headers: []const std.http.Header = if (authorization) |value|
        &.{.{ .name = "Authorization", .value = value }}
    else
        &.{};
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body_writer,
        .extra_headers = headers,
    });
    if (response.status != .ok) return error.OmlxDiscoveryFailed;

    return parseOmlxCatalog(allocator, body_writer.buffered());
}

pub fn parseOmlxCatalog(
    allocator: std.mem.Allocator,
    body: []const u8,
) !Catalog {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{},
    );
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidOmlxResponse,
    };
    const models_value = root.get("models") orelse
        return error.InvalidOmlxResponse;
    const source_models = switch (models_value) {
        .array => |array| array.items,
        else => return error.InvalidOmlxResponse,
    };

    var models: std.ArrayList(Model) = .empty;
    errdefer {
        for (models.items) |*model| model.deinit(allocator);
        models.deinit(allocator);
    }

    for (source_models) |source_model| {
        const object = switch (source_model) {
            .object => |object| object,
            else => continue,
        };
        const provider_model_id = stringField(object, "id") orelse continue;
        if (provider_model_id.len == 0) continue;
        const model_type = stringField(object, "model_type") orelse continue;
        if (!std.mem.eql(u8, model_type, "llm") and
            !std.mem.eql(u8, model_type, "vlm"))
        {
            continue;
        }
        const display_name = stringField(object, "display_name") orelse
            provider_model_id;
        const context_window = positiveInteger(
            object.get("max_context_window"),
        ) orelse default_context_window_tokens;
        const max_output = positiveInteger(object.get("max_tokens")) orelse
            default_max_output_tokens;

        const id = try std.fmt.allocPrint(
            allocator,
            "omlx/{s}",
            .{provider_model_id},
        );
        errdefer allocator.free(id);
        const owned_provider_model_id = try allocator.dupe(
            u8,
            provider_model_id,
        );
        errdefer allocator.free(owned_provider_model_id);
        const owned_display_name = try allocator.dupe(u8, display_name);
        errdefer allocator.free(owned_display_name);

        try models.append(allocator, .{
            .id = id,
            .provider_model_id = owned_provider_model_id,
            .display_name = owned_display_name,
            .max_context_window_tokens = context_window,
            .max_output_tokens = max_output,
            .supports_vision = std.mem.eql(u8, model_type, "vlm"),
        });
    }

    return .{
        .allocator = allocator,
        .models = try models.toOwnedSlice(allocator),
    };
}

fn stringField(
    object: std.json.ObjectMap,
    name: []const u8,
) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn positiveInteger(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |integer| if (integer > 0)
            @intCast(integer)
        else
            null,
        .string => |string| blk: {
            const integer = std.fmt.parseInt(u64, string, 10) catch break :blk null;
            break :blk if (integer > 0) integer else null;
        },
        else => null,
    };
}

test "OMLX discovery preserves context, output, and vision metadata" {
    var catalog = try parseOmlxCatalog(std.testing.allocator,
        \\{"models":[
        \\  {"id":"Qwen3.5-9B-mxfp4","display_name":"Qwen 3.5 9B","model_type":"llm","max_context_window":262144,"max_tokens":49152},
        \\  {"id":"Qwen-VL","model_type":"vlm","max_context_window":"65536","max_tokens":"8192"},
        \\  {"id":"embed","model_type":"embedding"}
        \\]}
    );
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 2), catalog.models.len);
    try std.testing.expectEqualStrings(
        "omlx/Qwen3.5-9B-mxfp4",
        catalog.models[0].id,
    );
    try std.testing.expectEqual(
        @as(u64, 262_144),
        catalog.models[0].max_context_window_tokens,
    );
    try std.testing.expectEqual(
        @as(u64, 49_152),
        catalog.models[0].max_output_tokens,
    );
    try std.testing.expect(!catalog.models[0].supports_vision);
    try std.testing.expect(catalog.models[1].supports_vision);
}

test "OMLX discovery uses conservative token defaults" {
    var catalog = try parseOmlxCatalog(std.testing.allocator,
        \\{"models":[{"id":"local-model","model_type":"llm"}]}
    );
    defer catalog.deinit();

    try std.testing.expectEqual(
        default_context_window_tokens,
        catalog.models[0].max_context_window_tokens,
    );
    try std.testing.expectEqual(
        default_max_output_tokens,
        catalog.models[0].max_output_tokens,
    );
}

test "OMLX base URL accepts server roots and v1 endpoints" {
    try std.testing.expectEqualStrings(
        "http://localhost:8000",
        omlxServerRoot("http://localhost:8000/"),
    );
    try std.testing.expectEqualStrings(
        "http://localhost:8000",
        omlxServerRoot("http://localhost:8000/v1"),
    );
}
