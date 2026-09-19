const std = @import("std");

pub const Limits = struct {
    max_identifier_bytes: usize = 256,
    max_key_bytes: usize = 768,
    max_text_bytes: usize = 4096,
    max_json_bytes: usize = 64 * 1024,
    max_json_depth: usize = 16,
    max_json_nodes: usize = 2048,
    max_actions_per_canvas: usize = 32,
    max_registry_entries: usize = 128,
    max_instances: usize = 64,
    max_pending_operations: usize = 128,
};

const identity_capacity = 256;

fn Identifier(comptime role_name: []const u8) type {
    return struct {
        storage: [identity_capacity]u8 = undefined,
        len: u16,

        const Self = @This();

        pub fn init(value: []const u8, limits: Limits) !Self {
            if (value.len == 0) return error.EmptyIdentifier;
            if (value.len > limits.max_identifier_bytes or
                value.len > identity_capacity)
            {
                return error.IdentifierTooLong;
            }
            if (!std.unicode.utf8ValidateSlice(value))
                return error.InvalidIdentifierUtf8;
            var result: Self = .{ .len = @intCast(value.len) };
            @memcpy(result.storage[0..value.len], value);
            return result;
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.storage[0..self.len];
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            return std.mem.eql(u8, self.bytes(), other.bytes());
        }

        pub fn role() []const u8 {
            return role_name;
        }
    };
}

pub const ExtensionId = Identifier("extension");
pub const CanvasId = Identifier("canvas");
pub const InstanceId = Identifier("instance");
pub const ActionName = Identifier("action");

pub const CanvasKeyView = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
};

pub const KeyView = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    instance_id: []const u8,
};

pub const CanvasKey = struct {
    extension_id: ExtensionId,
    canvas_id: CanvasId,

    pub fn init(input: CanvasKeyView, limits: Limits) !CanvasKey {
        if (input.extension_id.len + input.canvas_id.len > limits.max_key_bytes)
            return error.KeyTooLong;
        return .{
            .extension_id = try ExtensionId.init(input.extension_id, limits),
            .canvas_id = try CanvasId.init(input.canvas_id, limits),
        };
    }

    pub fn view(self: *const CanvasKey) CanvasKeyView {
        return .{
            .extension_id = self.extension_id.bytes(),
            .canvas_id = self.canvas_id.bytes(),
        };
    }

    pub fn eqlView(self: *const CanvasKey, other: CanvasKeyView) bool {
        return std.mem.eql(u8, self.extension_id.bytes(), other.extension_id) and
            std.mem.eql(u8, self.canvas_id.bytes(), other.canvas_id);
    }
};

pub const InstanceKey = struct {
    canvas: CanvasKey,
    instance_id: InstanceId,

    pub fn init(input: KeyView, limits: Limits) !InstanceKey {
        if (input.extension_id.len +
            input.canvas_id.len +
            input.instance_id.len >
            limits.max_key_bytes)
        {
            return error.KeyTooLong;
        }
        return .{
            .canvas = try CanvasKey.init(.{
                .extension_id = input.extension_id,
                .canvas_id = input.canvas_id,
            }, limits),
            .instance_id = try InstanceId.init(input.instance_id, limits),
        };
    }

    pub fn view(self: *const InstanceKey) KeyView {
        return .{
            .extension_id = self.canvas.extension_id.bytes(),
            .canvas_id = self.canvas.canvas_id.bytes(),
            .instance_id = self.instance_id.bytes(),
        };
    }

    pub fn eqlView(self: *const InstanceKey, other: KeyView) bool {
        return self.canvas.eqlView(.{
            .extension_id = other.extension_id,
            .canvas_id = other.canvas_id,
        }) and std.mem.eql(u8, self.instance_id.bytes(), other.instance_id);
    }
};

const JsonRole = enum {
    schema,
    open_input,
    action_input,
    action_result,
};

fn JsonDocument(comptime role: JsonRole) type {
    return struct {
        bytes: []u8,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            value: []const u8,
            limits: Limits,
        ) !Self {
            if (value.len == 0) return error.EmptyJsonDocument;
            if (value.len > limits.max_json_bytes)
                return error.JsonDocumentTooLong;
            if (!std.unicode.utf8ValidateSlice(value))
                return error.InvalidJsonUtf8;
            try validateJson(allocator, value, role, limits);
            return .{ .bytes = try allocator.dupe(u8, value) };
        }

        pub fn clone(
            self: Self,
            allocator: std.mem.Allocator,
            limits: Limits,
        ) !Self {
            return init(allocator, self.bytes, limits);
        }

        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(u8, self.bytes, other.bytes);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };
}

pub const SchemaDocument = JsonDocument(.schema);
pub const OpenInputDocument = JsonDocument(.open_input);
pub const ActionInputDocument = JsonDocument(.action_input);
pub const ActionResultDocument = JsonDocument(.action_result);

fn validateJson(
    allocator: std.mem.Allocator,
    value: []const u8,
    role: JsonRole,
    limits: Limits,
) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, value);
    defer scanner.deinit();
    var depth: usize = 0;
    var nodes: usize = 0;
    var first = true;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidJson,
        };
        if (first) {
            first = false;
            switch (role) {
                .schema => switch (token) {
                    .object_begin, .true, .false => {},
                    else => return error.InvalidSchemaDocument,
                },
                .open_input, .action_input => switch (token) {
                    .object_begin, .null => {},
                    else => return error.InvalidInputDocument,
                },
                .action_result => if (token == .end_of_document)
                    return error.InvalidJson,
            }
        }
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_json_depth)
                    return error.JsonDepthExceeded;
                nodes += 1;
            },
            .object_end, .array_end => depth -= 1,
            .true, .false, .null, .number, .string => nodes += 1,
            .end_of_document => break,
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            .allocated_number,
            .allocated_string,
            => return error.InvalidJson,
        }
        if (nodes > limits.max_json_nodes)
            return error.JsonNodeLimitExceeded;
    }
}

fn cloneText(
    allocator: std.mem.Allocator,
    value: []const u8,
    limits: Limits,
) ![]u8 {
    if (value.len > limits.max_text_bytes) return error.TextTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidTextUtf8;
    return allocator.dupe(u8, value);
}

pub const ActionDeclarationInput = struct {
    name: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    input_schema_json: ?[]const u8 = null,
};

pub const ActionDeclaration = struct {
    name: ActionName,
    display_name: []u8,
    description: []u8,
    input_schema: ?SchemaDocument,

    pub fn init(
        allocator: std.mem.Allocator,
        input: ActionDeclarationInput,
        limits: Limits,
    ) !ActionDeclaration {
        const name = try ActionName.init(input.name, limits);
        const display_name = try cloneText(allocator, input.display_name, limits);
        errdefer allocator.free(display_name);
        const description = try cloneText(allocator, input.description, limits);
        errdefer allocator.free(description);
        return .{
            .name = name,
            .display_name = display_name,
            .description = description,
            .input_schema = if (input.input_schema_json) |json|
                try SchemaDocument.init(allocator, json, limits)
            else
                null,
        };
    }

    pub fn clone(
        self: ActionDeclaration,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !ActionDeclaration {
        const display_name = try allocator.dupe(u8, self.display_name);
        errdefer allocator.free(display_name);
        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);
        return .{
            .name = self.name,
            .display_name = display_name,
            .description = description,
            .input_schema = if (self.input_schema) |schema|
                try schema.clone(allocator, limits)
            else
                null,
        };
    }

    pub fn deinit(
        self: *ActionDeclaration,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.display_name);
        allocator.free(self.description);
        if (self.input_schema) |*schema| schema.deinit(allocator);
        self.* = undefined;
    }
};

pub const CanvasDeclarationInput = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    input_schema_json: ?[]const u8 = null,
    actions: []const ActionDeclarationInput = &.{},
};

pub const CanvasDeclaration = struct {
    key: CanvasKey,
    display_name: []u8,
    description: []u8,
    input_schema: ?SchemaDocument,
    actions: []ActionDeclaration,

    pub fn init(
        allocator: std.mem.Allocator,
        input: CanvasDeclarationInput,
        limits: Limits,
    ) !CanvasDeclaration {
        if (input.actions.len > limits.max_actions_per_canvas)
            return error.TooManyActions;
        const key = try CanvasKey.init(.{
            .extension_id = input.extension_id,
            .canvas_id = input.canvas_id,
        }, limits);
        const display_name = try cloneText(allocator, input.display_name, limits);
        errdefer allocator.free(display_name);
        const description = try cloneText(allocator, input.description, limits);
        errdefer allocator.free(description);
        var input_schema = if (input.input_schema_json) |json|
            try SchemaDocument.init(allocator, json, limits)
        else
            null;
        errdefer if (input_schema) |*schema| schema.deinit(allocator);
        const actions = try allocator.alloc(ActionDeclaration, input.actions.len);
        errdefer allocator.free(actions);
        var initialized: usize = 0;
        errdefer for (actions[0..initialized]) |*action| action.deinit(allocator);
        for (input.actions, 0..) |action_input, index| {
            for (actions[0..index]) |*existing| {
                if (std.mem.eql(
                    u8,
                    existing.name.bytes(),
                    action_input.name,
                )) return error.DuplicateAction;
            }
            actions[index] = try ActionDeclaration.init(
                allocator,
                action_input,
                limits,
            );
            initialized += 1;
        }
        return .{
            .key = key,
            .display_name = display_name,
            .description = description,
            .input_schema = input_schema,
            .actions = actions,
        };
    }

    pub fn clone(
        self: CanvasDeclaration,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !CanvasDeclaration {
        const display_name = try allocator.dupe(u8, self.display_name);
        errdefer allocator.free(display_name);
        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);
        var input_schema = if (self.input_schema) |schema|
            try schema.clone(allocator, limits)
        else
            null;
        errdefer if (input_schema) |*schema| schema.deinit(allocator);
        const actions = try allocator.alloc(ActionDeclaration, self.actions.len);
        errdefer allocator.free(actions);
        var initialized: usize = 0;
        errdefer for (actions[0..initialized]) |*action| action.deinit(allocator);
        for (self.actions, 0..) |action, index| {
            actions[index] = try action.clone(allocator, limits);
            initialized += 1;
        }
        return .{
            .key = self.key,
            .display_name = display_name,
            .description = description,
            .input_schema = input_schema,
            .actions = actions,
        };
    }

    pub fn hasAction(self: *const CanvasDeclaration, name: []const u8) bool {
        for (self.actions) |*action| {
            if (std.mem.eql(u8, action.name.bytes(), name)) return true;
        }
        return false;
    }

    pub fn deinit(
        self: *CanvasDeclaration,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.display_name);
        allocator.free(self.description);
        if (self.input_schema) |*schema| schema.deinit(allocator);
        for (self.actions) |*action| action.deinit(allocator);
        allocator.free(self.actions);
        self.* = undefined;
    }
};

pub const RegistryDeltaInput = struct {
    upserted: []const CanvasDeclarationInput = &.{},
    removed: []const CanvasKeyView = &.{},
};

pub const RegistryUpdate = union(enum) {
    replacement: []const CanvasDeclarationInput,
    incremental: RegistryDeltaInput,
};

const Registry = struct {
    entries: std.ArrayList(CanvasDeclaration) = .empty,

    fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn clone(
        self: Registry,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !Registry {
        var result: Registry = .{};
        errdefer result.deinit(allocator);
        try result.entries.ensureUnusedCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| {
            result.entries.appendAssumeCapacity(
                try entry.clone(allocator, limits),
            );
        }
        return result;
    }

    fn find(self: Registry, key: CanvasKeyView) ?usize {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.key.eqlView(key)) return index;
        }
        return null;
    }
};

pub const CapabilityState = enum {
    unknown,
    unsupported,
    supported,
};

pub const OperationId = enum(u64) {
    _,

    pub fn value(self: OperationId) u64 {
        return @intFromEnum(self);
    }
};

pub const Generation = enum(u64) {
    _,

    pub fn value(self: Generation) u64 {
        return @intFromEnum(self);
    }
};

pub const OperationKind = enum {
    open,
    close,
    action,
};

pub const OperationToken = struct {
    id: OperationId,
    generation: Generation,
    kind: OperationKind,

    pub fn eql(self: OperationToken, other: OperationToken) bool {
        return self.id == other.id and
            self.generation == other.generation and
            self.kind == other.kind;
    }
};

pub const OpenRequest = struct {
    key: KeyView,
    input: ?*const OpenInputDocument = null,
};

pub const CloseRequest = struct {
    key: KeyView,
};

pub const InvokeActionRequest = struct {
    key: KeyView,
    action_name: []const u8,
    input: ?*const ActionInputDocument = null,
};

pub const OpenResultInput = struct {
    title: ?[]const u8 = null,
    location: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub const OperationFailure = enum {
    rejected,
    unavailable,
    cancelled,
    resource_exhausted,
    protocol_error,
};

pub const OpenOutcome = union(enum) {
    succeeded: OpenResultInput,
    failed: OperationFailure,
};

pub const CloseOutcome = union(enum) {
    succeeded,
    failed: OperationFailure,
};

pub const ActionOutcome = union(enum) {
    succeeded: *const ActionResultDocument,
    failed: OperationFailure,
};

pub const CompletionDisposition = enum {
    applied,
    ignored_stale,
};

pub const CancelDisposition = enum {
    cancelled,
    ignored_stale,
};

pub const EffectView = union(enum) {
    start_open: struct {
        token: OperationToken,
        key: KeyView,
        input_json: ?[]const u8,
    },
    start_close: struct {
        token: OperationToken,
        key: KeyView,
    },
    invoke_action: struct {
        token: OperationToken,
        key: KeyView,
        action_name: []const u8,
        input_json: ?[]const u8,
    },
    cancel: OperationToken,
};

pub const PublishError = error{
    EffectRejected,
    EffectUnavailable,
    OutOfMemory,
};

pub const EffectPublisher = struct {
    context: *anyopaque,
    publish_atomic_fn: *const fn (
        context: *anyopaque,
        effects: []const EffectView,
    ) PublishError!void,

    /// Success means every effect was copied and accepted. Failure means none
    /// was accepted. The publisher must not complete an operation reentrantly.
    pub fn publishAtomic(
        self: EffectPublisher,
        effects: []const EffectView,
    ) PublishError!void {
        return self.publish_atomic_fn(self.context, effects);
    }
};

const OpenedState = struct {
    generation: Generation,
    title: ?[]u8,
    location: ?[]u8,
    status: ?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        generation: Generation,
        input: OpenResultInput,
        limits: Limits,
    ) !OpenedState {
        const title = if (input.title) |value|
            try cloneText(allocator, value, limits)
        else
            null;
        errdefer if (title) |value| allocator.free(value);
        const location = if (input.location) |value|
            try cloneText(allocator, value, limits)
        else
            null;
        errdefer if (location) |value| allocator.free(value);
        return .{
            .generation = generation,
            .title = title,
            .location = location,
            .status = if (input.status) |value|
                try cloneText(allocator, value, limits)
            else
                null,
        };
    }

    fn clone(self: OpenedState, allocator: std.mem.Allocator) !OpenedState {
        const title = if (self.title) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (title) |value| allocator.free(value);
        const location = if (self.location) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (location) |value| allocator.free(value);
        return .{
            .generation = self.generation,
            .title = title,
            .location = location,
            .status = if (self.status) |value|
                try allocator.dupe(u8, value)
            else
                null,
        };
    }

    fn deinit(self: *OpenedState, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.location) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        self.* = undefined;
    }
};

const PendingOpen = struct {
    token: OperationToken,
    input: ?OpenInputDocument,

    fn clone(
        self: PendingOpen,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !PendingOpen {
        return .{
            .token = self.token,
            .input = if (self.input) |value|
                try value.clone(allocator, limits)
            else
                null,
        };
    }

    fn deinit(self: *PendingOpen, allocator: std.mem.Allocator) void {
        if (self.input) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

const PendingClose = struct {
    token: OperationToken,
    prior: OpenedState,

    fn clone(self: PendingClose, allocator: std.mem.Allocator) !PendingClose {
        return .{
            .token = self.token,
            .prior = try self.prior.clone(allocator),
        };
    }

    fn deinit(self: *PendingClose, allocator: std.mem.Allocator) void {
        self.prior.deinit(allocator);
        self.* = undefined;
    }
};

pub const RuntimeTag = enum {
    closed,
    opening,
    opened,
    closing,
    unavailable,
};

const RuntimeState = union(RuntimeTag) {
    closed,
    opening: PendingOpen,
    opened: OpenedState,
    closing: PendingClose,
    unavailable,

    fn clone(
        self: RuntimeState,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !RuntimeState {
        return switch (self) {
            .closed => .closed,
            .opening => |value| .{
                .opening = try value.clone(allocator, limits),
            },
            .opened => |value| .{ .opened = try value.clone(allocator) },
            .closing => |value| .{ .closing = try value.clone(allocator) },
            .unavailable => .unavailable,
        };
    }

    fn tag(self: RuntimeState) RuntimeTag {
        return std.meta.activeTag(self);
    }

    fn deinit(self: *RuntimeState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .opening => |*value| value.deinit(allocator),
            .opened => |*value| value.deinit(allocator),
            .closing => |*value| value.deinit(allocator),
            .closed, .unavailable => {},
        }
        self.* = undefined;
    }
};

pub const RecordTag = enum {
    recorded,
    removed,
};

const RecordedState = struct {
    title: ?[]u8,
    input: ?OpenInputDocument,

    fn init(
        allocator: std.mem.Allocator,
        title: ?[]const u8,
        input: ?*const OpenInputDocument,
        limits: Limits,
    ) !RecordedState {
        const owned_title = if (title) |value|
            try cloneText(allocator, value, limits)
        else
            null;
        errdefer if (owned_title) |value| allocator.free(value);
        return .{
            .title = owned_title,
            .input = if (input) |value|
                try value.clone(allocator, limits)
            else
                null,
        };
    }

    fn clone(
        self: RecordedState,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !RecordedState {
        const title = if (self.title) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (title) |value| allocator.free(value);
        return .{
            .title = title,
            .input = if (self.input) |value|
                try value.clone(allocator, limits)
            else
                null,
        };
    }

    fn deinit(self: *RecordedState, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.input) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

const RecordState = union(RecordTag) {
    recorded: RecordedState,
    removed,

    fn clone(
        self: RecordState,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !RecordState {
        return switch (self) {
            .recorded => |value| .{
                .recorded = try value.clone(allocator, limits),
            },
            .removed => .removed,
        };
    }

    fn tag(self: RecordState) RecordTag {
        return std.meta.activeTag(self);
    }

    fn deinit(self: *RecordState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .recorded => |*value| value.deinit(allocator),
            .removed => {},
        }
        self.* = undefined;
    }
};

const PendingAction = struct {
    token: OperationToken,
    name: ActionName,
    input: ?ActionInputDocument,

    fn clone(
        self: PendingAction,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !PendingAction {
        return .{
            .token = self.token,
            .name = self.name,
            .input = if (self.input) |value|
                try value.clone(allocator, limits)
            else
                null,
        };
    }

    fn deinit(self: *PendingAction, allocator: std.mem.Allocator) void {
        if (self.input) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const Degradation = enum {
    declaration_removed,
    invalid_signal,
    limit_exceeded,
    backpressure,
    host_failure,
};

const Instance = struct {
    key: InstanceKey,
    runtime: RuntimeState = .closed,
    record: RecordState = .removed,
    pending_actions: std.ArrayList(PendingAction) = .empty,
    degradation: ?Degradation = null,

    fn init(key: KeyView, limits: Limits) !Instance {
        return .{ .key = try InstanceKey.init(key, limits) };
    }

    fn clone(
        self: Instance,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !Instance {
        var runtime = try self.runtime.clone(allocator, limits);
        errdefer runtime.deinit(allocator);
        var record = try self.record.clone(allocator, limits);
        errdefer record.deinit(allocator);
        var actions: std.ArrayList(PendingAction) = .empty;
        errdefer {
            for (actions.items) |*action| action.deinit(allocator);
            actions.deinit(allocator);
        }
        try actions.ensureUnusedCapacity(
            allocator,
            self.pending_actions.items.len,
        );
        for (self.pending_actions.items) |action| {
            actions.appendAssumeCapacity(try action.clone(allocator, limits));
        }
        return .{
            .key = self.key,
            .runtime = runtime,
            .record = record,
            .pending_actions = actions,
            .degradation = self.degradation,
        };
    }

    fn replaceRuntime(
        self: *Instance,
        allocator: std.mem.Allocator,
        next: RuntimeState,
    ) void {
        self.runtime.deinit(allocator);
        self.runtime = next;
    }

    fn clearActions(self: *Instance, allocator: std.mem.Allocator) void {
        for (self.pending_actions.items) |*action| action.deinit(allocator);
        self.pending_actions.clearRetainingCapacity();
    }

    fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        self.runtime.deinit(allocator);
        self.record.deinit(allocator);
        for (self.pending_actions.items) |*action| action.deinit(allocator);
        self.pending_actions.deinit(allocator);
        self.* = undefined;
    }

    fn snapshot(
        self: *const Instance,
        allocator: std.mem.Allocator,
    ) !InstanceSnapshot {
        const opened: ?OpenedState = switch (self.runtime) {
            .opened => |value| value,
            .closing => |value| value.prior,
            else => null,
        };
        const title = if (opened) |value|
            if (value.title) |text| try allocator.dupe(u8, text) else null
        else
            null;
        errdefer if (title) |text| allocator.free(text);
        const location = if (opened) |value|
            if (value.location) |text| try allocator.dupe(u8, text) else null
        else
            null;
        errdefer if (location) |text| allocator.free(text);
        return .{
            .key = self.key,
            .runtime = self.runtime.tag(),
            .record = self.record.tag(),
            .generation = runtimeGeneration(self.runtime),
            .title = title,
            .location = location,
            .status = if (opened) |value|
                if (value.status) |text|
                    try allocator.dupe(u8, text)
                else
                    null
            else
                null,
            .pending_actions = self.pending_actions.items.len,
            .degradation = self.degradation,
        };
    }

    fn resumeCanvas(
        self: *const Instance,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !?ResumeCanvas {
        const recorded = switch (self.record) {
            .recorded => |value| value,
            .removed => return null,
        };
        const title = if (recorded.title) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (title) |value| allocator.free(value);
        return .{
            .key = self.key,
            .title = title,
            .input = if (recorded.input) |value|
                try value.clone(allocator, limits)
            else
                null,
        };
    }
};

pub const InstanceSnapshot = struct {
    key: InstanceKey,
    runtime: RuntimeTag,
    record: RecordTag,
    generation: ?Generation,
    title: ?[]u8,
    location: ?[]u8,
    status: ?[]u8,
    pending_actions: usize,
    degradation: ?Degradation,

    pub fn deinit(
        self: *InstanceSnapshot,
        allocator: std.mem.Allocator,
    ) void {
        if (self.title) |value| allocator.free(value);
        if (self.location) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    capability: CapabilityState,
    declarations: []CanvasDeclaration,
    instances: []InstanceSnapshot,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.declarations) |*declaration| declaration.deinit(allocator);
        allocator.free(self.declarations);
        for (self.instances) |*instance| instance.deinit(allocator);
        allocator.free(self.instances);
        self.* = undefined;
    }
};

pub const ResumeCanvas = struct {
    key: InstanceKey,
    title: ?[]u8,
    input: ?OpenInputDocument,

    pub fn deinit(self: *ResumeCanvas, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.input) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResumeProjection = union(enum) {
    omitted,
    canvases: []ResumeCanvas,

    pub fn deinit(
        self: *ResumeProjection,
        allocator: std.mem.Allocator,
    ) void {
        switch (self.*) {
            .omitted => {},
            .canvases => |canvases| {
                for (canvases) |*canvas| canvas.deinit(allocator);
                allocator.free(canvases);
            },
        }
        self.* = undefined;
    }
};

pub const Domain = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    capability: CapabilityState = .unknown,
    registry: Registry = .{},
    instances: std.ArrayList(Instance) = .empty,
    next_operation_id: u64 = 1,
    next_generation: u64 = 1,
    shutdown_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Domain {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Domain) void {
        self.registry.deinit(self.allocator);
        for (self.instances.items) |*instance| instance.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setCapability(
        self: *Domain,
        capability: CapabilityState,
    ) void {
        self.capability = capability;
    }

    pub fn applyRegistry(
        self: *Domain,
        update: RegistryUpdate,
    ) !void {
        if (self.shutdown_requested) return error.Shutdown;
        const candidate = switch (update) {
            .replacement => |inputs| try self.buildRegistry(inputs),
            .incremental => |delta| try self.buildIncrementalRegistry(delta),
        };
        self.registry.deinit(self.allocator);
        self.registry = candidate;
    }

    pub fn open(
        self: *Domain,
        request: OpenRequest,
        publisher: EffectPublisher,
    ) !OperationToken {
        try self.requireOperational();
        if (self.capability != .supported) return error.CanvasUnsupported;
        if (self.registry.find(.{
            .extension_id = request.key.extension_id,
            .canvas_id = request.key.canvas_id,
        }) == null) return error.CanvasUnavailable;
        const existing_index = self.findInstance(request.key);
        if (existing_index) |index| switch (self.instances.items[index].runtime) {
            .opened => return error.CanvasAlreadyOpen,
            .closing => return error.CanvasClosing,
            .closed, .opening, .unavailable => {},
        };
        const replaced_pending = if (existing_index) |index|
            instancePendingCount(&self.instances.items[index])
        else
            0;
        if (self.pendingCount() - replaced_pending + 1 >
            self.limits.max_pending_operations)
        {
            return error.Backpressure;
        }
        const token = try self.peekOpenToken();

        var candidate = if (existing_index) |index|
            try self.instances.items[index].clone(self.allocator, self.limits)
        else
            try Instance.init(request.key, self.limits);
        errdefer candidate.deinit(self.allocator);
        if (existing_index == null) {
            if (self.instances.items.len >= self.limits.max_instances)
                return error.TooManyInstances;
            try self.instances.ensureUnusedCapacity(self.allocator, 1);
        }

        var effects: std.ArrayList(EffectView) = .empty;
        defer effects.deinit(self.allocator);
        try self.appendCancellationEffects(&candidate, &effects);
        candidate.clearActions(self.allocator);
        var input = if (request.input) |value|
            try value.clone(self.allocator, self.limits)
        else
            null;
        errdefer if (input) |*value| value.deinit(self.allocator);
        candidate.replaceRuntime(self.allocator, .{ .opening = .{
            .token = token,
            .input = input,
        } });
        candidate.degradation = null;
        input = null;
        try effects.append(self.allocator, .{ .start_open = .{
            .token = token,
            .key = candidate.key.view(),
            .input_json = if (candidate.runtime.opening.input) |value|
                value.bytes
            else
                null,
        } });

        try publisher.publishAtomic(effects.items);
        self.commitOpenToken();
        if (existing_index) |index| {
            self.instances.items[index].deinit(self.allocator);
            self.instances.items[index] = candidate;
        } else {
            self.instances.appendAssumeCapacity(candidate);
        }
        return token;
    }

    pub fn close(
        self: *Domain,
        request: CloseRequest,
        publisher: EffectPublisher,
    ) !OperationToken {
        try self.requireOperational();
        const index = self.findInstance(request.key) orelse
            return error.CanvasNotOpen;
        const action_count = self.instances.items[index].pending_actions.items.len;
        if (self.pendingCount() - action_count + 1 >
            self.limits.max_pending_operations)
        {
            return error.Backpressure;
        }
        var candidate = try self.instances.items[index].clone(
            self.allocator,
            self.limits,
        );
        errdefer candidate.deinit(self.allocator);
        const opened = switch (candidate.runtime) {
            .opened => |value| value,
            else => return error.CanvasNotOpen,
        };
        const token = try self.peekToken(.close, opened.generation);
        var effects: std.ArrayList(EffectView) = .empty;
        defer effects.deinit(self.allocator);
        try effects.ensureUnusedCapacity(self.allocator, action_count + 1);
        for (candidate.pending_actions.items) |action| {
            effects.appendAssumeCapacity(.{ .cancel = action.token });
        }
        candidate.clearActions(self.allocator);
        candidate.runtime = .closed;
        candidate.replaceRuntime(self.allocator, .{ .closing = .{
            .token = token,
            .prior = opened,
        } });
        effects.appendAssumeCapacity(.{ .start_close = .{
            .token = token,
            .key = candidate.key.view(),
        } });
        try publisher.publishAtomic(effects.items);
        self.commitOperation();
        self.instances.items[index].deinit(self.allocator);
        self.instances.items[index] = candidate;
        return token;
    }

    pub fn invokeAction(
        self: *Domain,
        request: InvokeActionRequest,
        publisher: EffectPublisher,
    ) !OperationToken {
        try self.requireOperational();
        try self.requirePendingCapacity(1);
        const declaration_index = self.registry.find(.{
            .extension_id = request.key.extension_id,
            .canvas_id = request.key.canvas_id,
        }) orelse return error.CanvasUnavailable;
        if (!self.registry.entries.items[declaration_index].hasAction(
            request.action_name,
        )) return error.ActionUnavailable;
        const index = self.findInstance(request.key) orelse
            return error.CanvasNotOpen;
        if (self.instances.items[index].runtime.tag() != .opened)
            return error.CanvasNotOpen;

        var candidate = try self.instances.items[index].clone(
            self.allocator,
            self.limits,
        );
        errdefer candidate.deinit(self.allocator);
        const generation = switch (candidate.runtime) {
            .opened => |value| value.generation,
            else => unreachable,
        };
        const token = try self.peekToken(.action, generation);
        const name = try ActionName.init(request.action_name, self.limits);
        var input = if (request.input) |value|
            try value.clone(self.allocator, self.limits)
        else
            null;
        errdefer if (input) |*value| value.deinit(self.allocator);
        try candidate.pending_actions.ensureUnusedCapacity(self.allocator, 1);
        candidate.pending_actions.appendAssumeCapacity(.{
            .token = token,
            .name = name,
            .input = input,
        });
        input = null;
        const pending = &candidate.pending_actions.items[
            candidate.pending_actions.items.len - 1
        ];
        const effect = EffectView{ .invoke_action = .{
            .token = token,
            .key = candidate.key.view(),
            .action_name = pending.name.bytes(),
            .input_json = if (pending.input) |value| value.bytes else null,
        } };
        try publisher.publishAtomic(&.{effect});
        self.commitOperation();
        self.instances.items[index].deinit(self.allocator);
        self.instances.items[index] = candidate;
        return token;
    }

    pub fn cancel(
        self: *Domain,
        token: OperationToken,
        publisher: EffectPublisher,
    ) !CancelDisposition {
        try self.requireOperational();
        const location = self.findToken(token) orelse return .ignored_stale;
        var candidate = try self.instances.items[location.instance_index]
            .clone(self.allocator, self.limits);
        errdefer candidate.deinit(self.allocator);
        switch (location.kind) {
            .open => candidate.replaceRuntime(self.allocator, .closed),
            .close => {
                const closing = candidate.runtime.closing;
                candidate.runtime = .closed;
                candidate.replaceRuntime(
                    self.allocator,
                    .{ .opened = closing.prior },
                );
            },
            .action => {
                var removed = candidate.pending_actions.orderedRemove(
                    location.action_index.?,
                );
                removed.deinit(self.allocator);
            },
        }
        const effect = EffectView{ .cancel = token };
        try publisher.publishAtomic(&.{effect});
        self.instances.items[location.instance_index].deinit(self.allocator);
        self.instances.items[location.instance_index] = candidate;
        return .cancelled;
    }

    pub fn completeOpen(
        self: *Domain,
        token: OperationToken,
        outcome: OpenOutcome,
    ) !CompletionDisposition {
        const location = self.findToken(token) orelse return .ignored_stale;
        if (location.kind != .open) return .ignored_stale;
        var candidate = try self.instances.items[location.instance_index]
            .clone(self.allocator, self.limits);
        errdefer candidate.deinit(self.allocator);
        switch (outcome) {
            .succeeded => |result| {
                var opened = try OpenedState.init(
                    self.allocator,
                    token.generation,
                    result,
                    self.limits,
                );
                errdefer opened.deinit(self.allocator);
                candidate.replaceRuntime(
                    self.allocator,
                    .{ .opened = opened },
                );
                candidate.degradation = null;
            },
            .failed => {
                candidate.replaceRuntime(self.allocator, .closed);
                candidate.degradation = .host_failure;
            },
        }
        self.instances.items[location.instance_index].deinit(self.allocator);
        self.instances.items[location.instance_index] = candidate;
        return .applied;
    }

    pub fn completeClose(
        self: *Domain,
        token: OperationToken,
        outcome: CloseOutcome,
    ) !CompletionDisposition {
        const location = self.findToken(token) orelse return .ignored_stale;
        if (location.kind != .close) return .ignored_stale;
        var candidate = try self.instances.items[location.instance_index]
            .clone(self.allocator, self.limits);
        errdefer candidate.deinit(self.allocator);
        switch (outcome) {
            .succeeded => {
                candidate.replaceRuntime(self.allocator, .closed);
                candidate.degradation = null;
            },
            .failed => {
                const closing = candidate.runtime.closing;
                candidate.runtime = .closed;
                candidate.replaceRuntime(
                    self.allocator,
                    .{ .opened = closing.prior },
                );
                candidate.degradation = .host_failure;
            },
        }
        self.instances.items[location.instance_index].deinit(self.allocator);
        self.instances.items[location.instance_index] = candidate;
        return .applied;
    }

    pub fn completeAction(
        self: *Domain,
        token: OperationToken,
        outcome: ActionOutcome,
    ) !CompletionDisposition {
        const location = self.findToken(token) orelse return .ignored_stale;
        if (location.kind != .action) return .ignored_stale;
        var candidate = try self.instances.items[location.instance_index]
            .clone(self.allocator, self.limits);
        errdefer candidate.deinit(self.allocator);
        switch (outcome) {
            .succeeded => |result| {
                var checked = try result.clone(self.allocator, self.limits);
                checked.deinit(self.allocator);
                candidate.degradation = null;
            },
            .failed => candidate.degradation = .host_failure,
        }
        var removed = candidate.pending_actions.orderedRemove(
            location.action_index.?,
        );
        removed.deinit(self.allocator);
        self.instances.items[location.instance_index].deinit(self.allocator);
        self.instances.items[location.instance_index] = candidate;
        return .applied;
    }

    pub fn markUnavailable(
        self: *Domain,
        key: KeyView,
        publisher: EffectPublisher,
    ) !void {
        try self.requireOperational();
        const index = self.findInstance(key) orelse {
            if (self.instances.items.len >= self.limits.max_instances)
                return error.TooManyInstances;
            var instance = try Instance.init(key, self.limits);
            errdefer instance.deinit(self.allocator);
            try self.instances.ensureUnusedCapacity(self.allocator, 1);
            instance.runtime = .unavailable;
            instance.degradation = .declaration_removed;
            self.instances.appendAssumeCapacity(instance);
            return;
        };
        var candidate = try self.instances.items[index].clone(
            self.allocator,
            self.limits,
        );
        errdefer candidate.deinit(self.allocator);
        var effects: std.ArrayList(EffectView) = .empty;
        defer effects.deinit(self.allocator);
        try self.appendCancellationEffects(&candidate, &effects);
        candidate.clearActions(self.allocator);
        candidate.replaceRuntime(self.allocator, .unavailable);
        candidate.degradation = .declaration_removed;
        if (effects.items.len > 0) try publisher.publishAtomic(effects.items);
        self.instances.items[index].deinit(self.allocator);
        self.instances.items[index] = candidate;
    }

    pub fn record(
        self: *Domain,
        key: KeyView,
        title: ?[]const u8,
        input: ?*const OpenInputDocument,
    ) !void {
        try self.requireOperational();
        const index = self.findInstance(key) orelse {
            if (self.instances.items.len >= self.limits.max_instances)
                return error.TooManyInstances;
            var instance = try Instance.init(key, self.limits);
            errdefer instance.deinit(self.allocator);
            try self.instances.ensureUnusedCapacity(self.allocator, 1);
            instance.record = .{ .recorded = try RecordedState.init(
                self.allocator,
                title,
                input,
                self.limits,
            ) };
            self.instances.appendAssumeCapacity(instance);
            return;
        };
        var candidate = try self.instances.items[index].clone(
            self.allocator,
            self.limits,
        );
        errdefer candidate.deinit(self.allocator);
        const recorded = try RecordedState.init(
            self.allocator,
            title,
            input,
            self.limits,
        );
        candidate.record.deinit(self.allocator);
        candidate.record = .{ .recorded = recorded };
        self.instances.items[index].deinit(self.allocator);
        self.instances.items[index] = candidate;
    }

    pub fn removeRecord(self: *Domain, key: KeyView) !void {
        try self.requireOperational();
        const index = self.findInstance(key) orelse return;
        self.instances.items[index].record.deinit(self.allocator);
        self.instances.items[index].record = .removed;
    }

    pub fn shutdown(
        self: *Domain,
        publisher: EffectPublisher,
    ) !void {
        if (self.shutdown_requested) return;
        var effects: std.ArrayList(EffectView) = .empty;
        defer effects.deinit(self.allocator);
        for (self.instances.items) |*instance| {
            try self.appendCancellationEffects(instance, &effects);
        }
        if (effects.items.len > 0) try publisher.publishAtomic(effects.items);
        for (self.instances.items) |*instance| {
            instance.clearActions(self.allocator);
            switch (instance.runtime) {
                .closing => {
                    const closing = instance.runtime.closing;
                    instance.runtime = .closed;
                    instance.replaceRuntime(
                        self.allocator,
                        .{ .opened = closing.prior },
                    );
                },
                else => instance.replaceRuntime(self.allocator, .closed),
            }
        }
        self.shutdown_requested = true;
    }

    pub fn snapshot(
        self: *const Domain,
        allocator: std.mem.Allocator,
    ) !Snapshot {
        const declarations = try allocator.alloc(
            CanvasDeclaration,
            self.registry.entries.items.len,
        );
        errdefer allocator.free(declarations);
        var declaration_count: usize = 0;
        errdefer for (declarations[0..declaration_count]) |*declaration| {
            declaration.deinit(allocator);
        };
        for (self.registry.entries.items, 0..) |declaration, index| {
            declarations[index] = try declaration.clone(allocator, self.limits);
            declaration_count += 1;
        }

        const instances = try allocator.alloc(
            InstanceSnapshot,
            self.instances.items.len,
        );
        errdefer allocator.free(instances);
        var instance_count: usize = 0;
        errdefer for (instances[0..instance_count]) |*instance| {
            instance.deinit(allocator);
        };
        for (self.instances.items, 0..) |*instance, index| {
            instances[index] = try instance.snapshot(allocator);
            instance_count += 1;
        }
        return .{
            .capability = self.capability,
            .declarations = declarations,
            .instances = instances,
        };
    }

    pub fn resumeProjection(
        self: *const Domain,
        allocator: std.mem.Allocator,
        capability_known: bool,
    ) !ResumeProjection {
        if (!capability_known) return .omitted;
        var count: usize = 0;
        for (self.instances.items) |instance| {
            if (instance.record.tag() == .recorded) count += 1;
        }
        const canvases = try allocator.alloc(ResumeCanvas, count);
        errdefer allocator.free(canvases);
        var initialized: usize = 0;
        errdefer for (canvases[0..initialized]) |*canvas| {
            canvas.deinit(allocator);
        };
        for (self.instances.items) |instance| {
            canvases[initialized] =
                try instance.resumeCanvas(allocator, self.limits) orelse continue;
            initialized += 1;
        }
        return .{ .canvases = canvases };
    }

    pub fn runtimeTag(self: Domain, key: KeyView) ?RuntimeTag {
        const index = self.findInstance(key) orelse return null;
        return self.instances.items[index].runtime.tag();
    }

    pub fn recordTag(self: Domain, key: KeyView) ?RecordTag {
        const index = self.findInstance(key) orelse return null;
        return self.instances.items[index].record.tag();
    }

    pub fn pendingCount(self: Domain) usize {
        var count: usize = 0;
        for (self.instances.items) |instance| {
            count += instance.pending_actions.items.len;
            switch (instance.runtime) {
                .opening, .closing => count += 1,
                else => {},
            }
        }
        return count;
    }

    pub fn hasPendingToken(
        self: Domain,
        token: OperationToken,
    ) bool {
        return self.findToken(token) != null;
    }

    fn requireOperational(self: Domain) !void {
        if (self.shutdown_requested) return error.Shutdown;
    }

    fn requirePendingCapacity(self: Domain, additional: usize) !void {
        if (self.pendingCount() + additional >
            self.limits.max_pending_operations)
        {
            return error.Backpressure;
        }
    }

    fn peekOpenToken(self: Domain) !OperationToken {
        if (self.next_operation_id == std.math.maxInt(u64) or
            self.next_generation == std.math.maxInt(u64))
        {
            return error.OperationCounterExhausted;
        }
        return .{
            .id = @enumFromInt(self.next_operation_id),
            .generation = @enumFromInt(self.next_generation),
            .kind = .open,
        };
    }

    fn peekToken(
        self: Domain,
        kind: OperationKind,
        generation: Generation,
    ) !OperationToken {
        if (self.next_operation_id == std.math.maxInt(u64))
            return error.OperationCounterExhausted;
        return .{
            .id = @enumFromInt(self.next_operation_id),
            .generation = generation,
            .kind = kind,
        };
    }

    fn commitOpenToken(self: *Domain) void {
        self.next_operation_id += 1;
        self.next_generation += 1;
    }

    fn commitOperation(self: *Domain) void {
        self.next_operation_id += 1;
    }

    fn findInstance(self: Domain, key: KeyView) ?usize {
        for (self.instances.items, 0..) |*instance, index| {
            if (instance.key.eqlView(key)) return index;
        }
        return null;
    }

    const TokenLocation = struct {
        instance_index: usize,
        kind: OperationKind,
        action_index: ?usize = null,
    };

    fn findToken(
        self: Domain,
        token: OperationToken,
    ) ?TokenLocation {
        for (self.instances.items, 0..) |instance, instance_index| {
            switch (instance.runtime) {
                .opening => |value| if (value.token.eql(token)) return .{
                    .instance_index = instance_index,
                    .kind = .open,
                },
                .closing => |value| if (value.token.eql(token)) return .{
                    .instance_index = instance_index,
                    .kind = .close,
                },
                else => {},
            }
            for (instance.pending_actions.items, 0..) |action, action_index| {
                if (action.token.eql(token)) return .{
                    .instance_index = instance_index,
                    .kind = .action,
                    .action_index = action_index,
                };
            }
        }
        return null;
    }

    fn appendCancellationEffects(
        self: Domain,
        instance: *const Instance,
        effects: *std.ArrayList(EffectView),
    ) !void {
        switch (instance.runtime) {
            .opening => |value| try effects.append(
                self.allocator,
                .{ .cancel = value.token },
            ),
            .closing => |value| try effects.append(
                self.allocator,
                .{ .cancel = value.token },
            ),
            else => {},
        }
        for (instance.pending_actions.items) |action| {
            try effects.append(
                self.allocator,
                .{ .cancel = action.token },
            );
        }
    }

    fn buildRegistry(
        self: *Domain,
        inputs: []const CanvasDeclarationInput,
    ) !Registry {
        if (inputs.len > self.limits.max_registry_entries)
            return error.TooManyRegistryEntries;
        var result: Registry = .{};
        errdefer result.deinit(self.allocator);
        try result.entries.ensureUnusedCapacity(self.allocator, inputs.len);
        for (inputs) |input| {
            if (result.find(.{
                .extension_id = input.extension_id,
                .canvas_id = input.canvas_id,
            }) != null) return error.DuplicateCanvas;
            result.entries.appendAssumeCapacity(try CanvasDeclaration.init(
                self.allocator,
                input,
                self.limits,
            ));
        }
        return result;
    }

    fn buildIncrementalRegistry(
        self: *Domain,
        delta: RegistryDeltaInput,
    ) !Registry {
        var result = try self.registry.clone(self.allocator, self.limits);
        errdefer result.deinit(self.allocator);
        for (delta.removed) |removed| {
            if (result.find(removed)) |index| {
                var declaration = result.entries.orderedRemove(index);
                declaration.deinit(self.allocator);
            }
        }
        for (delta.upserted) |input| {
            var declaration = try CanvasDeclaration.init(
                self.allocator,
                input,
                self.limits,
            );
            var declaration_owned = true;
            errdefer if (declaration_owned) declaration.deinit(self.allocator);
            const key = CanvasKeyView{
                .extension_id = input.extension_id,
                .canvas_id = input.canvas_id,
            };
            if (result.find(key)) |index| {
                result.entries.items[index].deinit(self.allocator);
                result.entries.items[index] = declaration;
                declaration_owned = false;
            } else {
                if (result.entries.items.len >=
                    self.limits.max_registry_entries)
                {
                    return error.TooManyRegistryEntries;
                }
                try result.entries.append(self.allocator, declaration);
                declaration_owned = false;
            }
        }
        return result;
    }
};

fn runtimeGeneration(runtime: RuntimeState) ?Generation {
    return switch (runtime) {
        .opening => |value| value.token.generation,
        .opened => |value| value.generation,
        .closing => |value| value.token.generation,
        .closed, .unavailable => null,
    };
}

fn instancePendingCount(instance: *const Instance) usize {
    return instance.pending_actions.items.len + switch (instance.runtime) {
        .opening, .closing => @as(usize, 1),
        else => 0,
    };
}

const fixture_key: KeyView = .{
    .extension_id = "fixture.extension",
    .canvas_id = "review",
    .instance_id = "review:main",
};

const fixture_actions = [_]ActionDeclarationInput{.{
    .name = "refresh",
    .display_name = "Refresh",
    .input_schema_json = "{\"type\":\"object\"}",
}};

const fixture_declaration: CanvasDeclarationInput = .{
    .extension_id = "fixture.extension",
    .canvas_id = "review",
    .display_name = "Review",
    .description = "Review changes",
    .input_schema_json = "{\"type\":\"object\"}",
    .actions = &fixture_actions,
};

const TestPublisher = struct {
    fail: bool = false,
    calls: usize = 0,
    effect_count: usize = 0,
    tokens: [8]OperationToken = undefined,

    fn publisher(self: *TestPublisher) EffectPublisher {
        return .{
            .context = self,
            .publish_atomic_fn = publish,
        };
    }

    fn publish(
        context: *anyopaque,
        effects: []const EffectView,
    ) PublishError!void {
        const self: *TestPublisher = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.fail) return error.EffectRejected;
        self.effect_count = effects.len;
        for (effects, 0..) |effect, index| {
            self.tokens[index] = switch (effect) {
                .start_open => |value| value.token,
                .start_close => |value| value.token,
                .invoke_action => |value| value.token,
                .cancel => |value| value,
            };
        }
    }
};

fn fixtureDomain(allocator: std.mem.Allocator) !Domain {
    var domain = Domain.init(allocator, .{});
    errdefer domain.deinit();
    domain.setCapability(.supported);
    try domain.applyRegistry(.{
        .replacement = &.{fixture_declaration},
    });
    return domain;
}

test "bounded identities and role documents validate their own shapes" {
    try std.testing.expectError(
        error.EmptyIdentifier,
        ExtensionId.init("", .{}),
    );
    try std.testing.expectError(
        error.IdentifierTooLong,
        CanvasId.init("abcd", .{ .max_identifier_bytes = 3 }),
    );
    try std.testing.expectError(
        error.InvalidIdentifierUtf8,
        InstanceId.init("\xff", .{}),
    );
    const extension = try ExtensionId.init("fixture.extension", .{});
    try std.testing.expectEqualStrings(
        "fixture.extension",
        extension.bytes(),
    );
    try std.testing.expectEqualStrings("extension", ExtensionId.role());
    try std.testing.expectEqualStrings("action", ActionName.role());
    try std.testing.expect(ExtensionId != CanvasId);

    var schema = try SchemaDocument.init(
        std.testing.allocator,
        "{\"type\":\"object\"}",
        .{},
    );
    defer schema.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidSchemaDocument,
        SchemaDocument.init(std.testing.allocator, "[]", .{}),
    );
    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "null",
        .{},
    );
    defer input.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidInputDocument,
        ActionInputDocument.init(std.testing.allocator, "\"raw\"", .{}),
    );
    try std.testing.expectError(
        error.JsonDepthExceeded,
        ActionResultDocument.init(
            std.testing.allocator,
            "[[[true]]]",
            .{ .max_json_depth = 2 },
        ),
    );
    try std.testing.expectError(
        error.JsonNodeLimitExceeded,
        ActionResultDocument.init(
            std.testing.allocator,
            "{\"one\":1,\"two\":2}",
            .{ .max_json_nodes = 2 },
        ),
    );
}

test "registry replacement and incremental update are distinct and atomic" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    const second: CanvasDeclarationInput = .{
        .extension_id = "fixture.extension",
        .canvas_id = "preview",
        .display_name = "Preview",
    };
    try domain.applyRegistry(.{ .incremental = .{
        .upserted = &.{second},
    } });
    try std.testing.expectEqual(
        @as(usize, 2),
        domain.registry.entries.items.len,
    );

    var invalid = fixture_declaration;
    const duplicate_actions = [_]ActionDeclarationInput{
        .{ .name = "same", .display_name = "One" },
        .{ .name = "same", .display_name = "Two" },
    };
    invalid.actions = &duplicate_actions;
    try std.testing.expectError(
        error.DuplicateAction,
        domain.applyRegistry(.{ .replacement = &.{invalid} }),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        domain.registry.entries.items.len,
    );

    try domain.applyRegistry(.{ .replacement = &.{second} });
    try std.testing.expectEqual(
        @as(usize, 1),
        domain.registry.entries.items.len,
    );
}

test "fixture drives open action close and stale completion semantics" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    var open_input = try OpenInputDocument.init(
        std.testing.allocator,
        "{\"selection\":\"backend/src/root.zig\"}",
        .{},
    );
    defer open_input.deinit(std.testing.allocator);
    const open = try domain.open(.{
        .key = fixture_key,
        .input = &open_input,
    }, publisher.publisher());
    try std.testing.expectEqual(RuntimeTag.opening, domain.runtimeTag(fixture_key).?);
    try std.testing.expect(domain.hasPendingToken(open));
    try std.testing.expectEqual(
        CompletionDisposition.applied,
        try domain.completeOpen(open, .{ .succeeded = .{
            .title = "Review",
            .location = "opaque:review",
            .status = "ready",
        } }),
    );
    try std.testing.expectEqual(RuntimeTag.opened, domain.runtimeTag(fixture_key).?);

    const action = try domain.invokeAction(.{
        .key = fixture_key,
        .action_name = "refresh",
    }, publisher.publisher());
    try std.testing.expectEqual(open.generation, action.generation);
    var action_result = try ActionResultDocument.init(
        std.testing.allocator,
        "{\"refreshed\":true}",
        .{},
    );
    defer action_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        CompletionDisposition.applied,
        try domain.completeAction(action, .{ .succeeded = &action_result }),
    );

    const close = try domain.close(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    try std.testing.expectEqual(open.generation, close.generation);
    try std.testing.expectEqual(RuntimeTag.closing, domain.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(
        CompletionDisposition.ignored_stale,
        try domain.completeOpen(open, .{ .failed = .cancelled }),
    );
    try std.testing.expectEqual(
        CompletionDisposition.applied,
        try domain.completeClose(close, .succeeded),
    );
    try std.testing.expectEqual(RuntimeTag.closed, domain.runtimeTag(fixture_key).?);
}

test "open rejects live instances instead of discarding renderer state" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const open = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeOpen(open, .{ .succeeded = .{
        .title = "Review",
    } });
    try std.testing.expectError(
        error.CanvasAlreadyOpen,
        domain.open(.{ .key = fixture_key }, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.opened, domain.runtimeTag(fixture_key).?);

    const close = try domain.close(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    try std.testing.expectError(
        error.CanvasClosing,
        domain.open(.{ .key = fixture_key }, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.closing, domain.runtimeTag(fixture_key).?);
    try std.testing.expect(domain.hasPendingToken(close));
}

test "operation boundaries revalidate mutable document storage" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "{}",
        .{},
    );
    defer input.deinit(std.testing.allocator);
    input.bytes[0] = '[';
    input.bytes[1] = ']';
    try std.testing.expectError(
        error.InvalidInputDocument,
        domain.open(.{
            .key = fixture_key,
            .input = &input,
        }, publisher.publisher()),
    );
    try std.testing.expect(domain.runtimeTag(fixture_key) == null);

    const open = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeOpen(open, .{ .succeeded = .{} });
    const action = try domain.invokeAction(.{
        .key = fixture_key,
        .action_name = "refresh",
    }, publisher.publisher());
    var result = try ActionResultDocument.init(
        std.testing.allocator,
        "{}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    result.bytes[0] = '{';
    result.bytes[1] = 'x';
    try std.testing.expectError(
        error.InvalidJson,
        domain.completeAction(action, .{ .succeeded = &result }),
    );
    try std.testing.expect(domain.hasPendingToken(action));
}

test "publication failure leaves opening transition unchanged" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{ .fail = true };
    try std.testing.expectError(
        error.EffectRejected,
        domain.open(.{ .key = fixture_key }, publisher.publisher()),
    );
    try std.testing.expect(domain.runtimeTag(fixture_key) == null);
    try std.testing.expectEqual(@as(usize, 0), domain.pendingCount());
}

test "superseding open publication failure retains original live token" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const original = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    publisher.fail = true;
    try std.testing.expectError(
        error.EffectRejected,
        domain.open(.{ .key = fixture_key }, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.opening, domain.runtimeTag(fixture_key).?);
    try std.testing.expect(domain.hasPendingToken(original));
    try std.testing.expectEqual(@as(usize, 1), domain.pendingCount());
}

fn supersedingOpenAllocationLifecycle(
    allocator: std.mem.Allocator,
) !void {
    var domain = try fixtureDomain(allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const original = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    ) catch |err| {
        try std.testing.expectEqual(
            RuntimeTag.opening,
            domain.runtimeTag(fixture_key).?,
        );
        try std.testing.expect(domain.hasPendingToken(original));
        try std.testing.expectEqual(@as(usize, 1), domain.pendingCount());
        return err;
    };
}

test "allocation failure cannot orphan a superseded opening token" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        supersedingOpenAllocationLifecycle,
        .{},
    );
}

test "cancel failure retains pending state and successful cancel is stable" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const token = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    publisher.fail = true;
    try std.testing.expectError(
        error.EffectRejected,
        domain.cancel(token, publisher.publisher()),
    );
    try std.testing.expect(domain.hasPendingToken(token));
    try std.testing.expectEqual(RuntimeTag.opening, domain.runtimeTag(fixture_key).?);

    publisher.fail = false;
    try std.testing.expectEqual(
        CancelDisposition.cancelled,
        try domain.cancel(token, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.closed, domain.runtimeTag(fixture_key).?);
    try std.testing.expect(!domain.hasPendingToken(token));
    try std.testing.expectEqual(
        CancelDisposition.ignored_stale,
        try domain.cancel(token, publisher.publisher()),
    );
}

fn cancelAllocationLifecycle(allocator: std.mem.Allocator) !void {
    var domain = try fixtureDomain(allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const token = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = domain.cancel(token, publisher.publisher()) catch |err| {
        try std.testing.expectEqual(
            RuntimeTag.opening,
            domain.runtimeTag(fixture_key).?,
        );
        try std.testing.expect(domain.hasPendingToken(token));
        return err;
    };
}

test "cancel allocation failure retains the exact pending state" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        cancelAllocationLifecycle,
        .{},
    );
}

test "close and action publication failures leave stable prior state" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const open = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeOpen(open, .{ .succeeded = .{
        .title = "Review",
    } });

    publisher.fail = true;
    try std.testing.expectError(
        error.EffectRejected,
        domain.close(.{ .key = fixture_key }, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.opened, domain.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(@as(usize, 0), domain.pendingCount());
    try std.testing.expectError(
        error.EffectRejected,
        domain.invokeAction(.{
            .key = fixture_key,
            .action_name = "refresh",
        }, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.opened, domain.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(@as(usize, 0), domain.pendingCount());
}

test "close cancels pending actions before closing the instance" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const open = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeOpen(open, .{ .succeeded = .{} });
    const action = try domain.invokeAction(.{
        .key = fixture_key,
        .action_name = "refresh",
    }, publisher.publisher());

    const close = try domain.close(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    try std.testing.expectEqual(@as(usize, 2), publisher.effect_count);
    try std.testing.expect(publisher.tokens[0].eql(action));
    try std.testing.expect(publisher.tokens[1].eql(close));
    try std.testing.expectEqual(@as(usize, 1), domain.pendingCount());
    try std.testing.expectEqual(
        CompletionDisposition.ignored_stale,
        try domain.completeAction(action, .{ .failed = .cancelled }),
    );
    _ = try domain.completeClose(close, .succeeded);
    try std.testing.expectEqual(@as(usize, 0), domain.pendingCount());
    try std.testing.expectEqual(RuntimeTag.closed, domain.runtimeTag(fixture_key).?);
}

test "close failure restores the prior opened state transactionally" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const open = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeOpen(open, .{ .succeeded = .{
        .title = "Review",
    } });
    const close = try domain.close(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeClose(close, .{ .failed = .unavailable });
    try std.testing.expectEqual(RuntimeTag.opened, domain.runtimeTag(fixture_key).?);
    try std.testing.expect(!domain.hasPendingToken(close));
}

test "unavailable publication failure retains the exact pending operation" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const token = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    publisher.fail = true;
    try std.testing.expectError(
        error.EffectRejected,
        domain.markUnavailable(fixture_key, publisher.publisher()),
    );
    try std.testing.expectEqual(RuntimeTag.opening, domain.runtimeTag(fixture_key).?);
    try std.testing.expect(domain.hasPendingToken(token));
}

fn openCompletionAllocationLifecycle(
    allocator: std.mem.Allocator,
) !void {
    var domain = try fixtureDomain(allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const token = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = domain.completeOpen(token, .{ .succeeded = .{
        .title = "Review",
        .location = "opaque:review",
        .status = "ready",
    } }) catch |err| {
        try std.testing.expectEqual(
            RuntimeTag.opening,
            domain.runtimeTag(fixture_key).?,
        );
        try std.testing.expect(domain.hasPendingToken(token));
        return err;
    };
}

test "open completion allocation failure retains its live token" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        openCompletionAllocationLifecycle,
        .{},
    );
}

test "recording and resume projection exclude transient runtime metadata" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "{\"selection\":\"backend/src/root.zig\"}",
        .{},
    );
    defer input.deinit(std.testing.allocator);
    try domain.record(fixture_key, "Recorded review", &input);
    var projection = try domain.resumeProjection(
        std.testing.allocator,
        true,
    );
    defer projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), projection.canvases.len);
    try std.testing.expectEqualStrings(
        "Recorded review",
        projection.canvases[0].title.?,
    );
    try std.testing.expectEqualStrings(
        input.bytes,
        projection.canvases[0].input.?.bytes,
    );
    try std.testing.expect(!@hasField(ResumeCanvas, "location"));
    try std.testing.expect(!@hasField(ResumeCanvas, "status"));
    try std.testing.expect(!@hasField(ResumeCanvas, "generation"));
}

fn projectionAllocationLifecycle(allocator: std.mem.Allocator) !void {
    var domain = try fixtureDomain(allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const token = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    _ = try domain.completeOpen(token, .{ .succeeded = .{
        .title = "Review",
        .location = "opaque:review",
        .status = "ready",
    } });
    var input = try OpenInputDocument.init(
        allocator,
        "{\"selection\":\"backend/src/root.zig\"}",
        .{},
    );
    defer input.deinit(allocator);
    try domain.record(fixture_key, "Recorded review", &input);

    var snapshot = try domain.snapshot(allocator);
    defer snapshot.deinit(allocator);
    var projection = try domain.resumeProjection(allocator, true);
    defer projection.deinit(allocator);
}

test "snapshot and resume ownership survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        projectionAllocationLifecycle,
        .{},
    );
}

test "shutdown publication failure is retryable and success is idempotent" {
    var domain = try fixtureDomain(std.testing.allocator);
    defer domain.deinit();
    var publisher: TestPublisher = .{};
    const token = try domain.open(
        .{ .key = fixture_key },
        publisher.publisher(),
    );
    publisher.fail = true;
    try std.testing.expectError(
        error.EffectRejected,
        domain.shutdown(publisher.publisher()),
    );
    try std.testing.expect(domain.hasPendingToken(token));
    try std.testing.expect(!domain.shutdown_requested);

    publisher.fail = false;
    try domain.shutdown(publisher.publisher());
    try domain.shutdown(publisher.publisher());
    try std.testing.expect(domain.shutdown_requested);
    try std.testing.expectEqual(@as(usize, 0), domain.pendingCount());
    try std.testing.expectEqual(RuntimeTag.closed, domain.runtimeTag(fixture_key).?);
}
