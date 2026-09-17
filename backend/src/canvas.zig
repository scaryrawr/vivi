const std = @import("std");

pub const Limits = struct {
    max_identifier_bytes: usize = 256,
    max_key_bytes: usize = 768,
    max_text_bytes: usize = 4096,
    max_json_bytes: usize = 64 * 1024,
    max_actions_per_canvas: usize = 32,
    max_registry_entries: usize = 128,
    max_instances: usize = 64,
    max_pending_operations: usize = 128,
    max_registry_bytes: usize = 1024 * 1024,
    max_conversation_bytes: usize = 2 * 1024 * 1024,
};

fn Identifier(comptime kind: []const u8) type {
    return struct {
        bytes: []u8,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            value: []const u8,
            limits: Limits,
        ) !Self {
            if (value.len == 0) return error.EmptyIdentifier;
            if (value.len > limits.max_identifier_bytes)
                return error.IdentifierTooLong;
            if (!std.unicode.utf8ValidateSlice(value))
                return error.InvalidIdentifierUtf8;
            return .{ .bytes = try allocator.dupe(u8, value) };
        }

        pub fn clone(
            self: Self,
            allocator: std.mem.Allocator,
        ) !Self {
            return .{ .bytes = try allocator.dupe(u8, self.bytes) };
        }

        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(u8, self.bytes, other.bytes);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }

        pub fn role() []const u8 {
            return kind;
        }
    };
}

pub const ExtensionId = Identifier("extension");
pub const CanvasId = Identifier("canvas");
pub const InstanceId = Identifier("instance");
pub const ActionName = Identifier("action");

pub const KeyView = struct {
    extension_id: []const u8,
    canvas_id: []const u8,
    instance_id: []const u8,
};

pub const InstanceKey = struct {
    extension_id: ExtensionId,
    canvas_id: CanvasId,
    instance_id: InstanceId,

    pub fn init(
        allocator: std.mem.Allocator,
        key_view: KeyView,
        limits: Limits,
    ) !InstanceKey {
        if (key_view.extension_id.len +
            key_view.canvas_id.len +
            key_view.instance_id.len >
            limits.max_key_bytes)
        {
            return error.KeyTooLong;
        }
        var extension_id = try ExtensionId.init(
            allocator,
            key_view.extension_id,
            limits,
        );
        errdefer extension_id.deinit(allocator);
        var canvas_id = try CanvasId.init(
            allocator,
            key_view.canvas_id,
            limits,
        );
        errdefer canvas_id.deinit(allocator);
        return .{
            .extension_id = extension_id,
            .canvas_id = canvas_id,
            .instance_id = try InstanceId.init(
                allocator,
                key_view.instance_id,
                limits,
            ),
        };
    }

    pub fn clone(
        self: InstanceKey,
        allocator: std.mem.Allocator,
    ) !InstanceKey {
        var extension_id = try self.extension_id.clone(allocator);
        errdefer extension_id.deinit(allocator);
        var canvas_id = try self.canvas_id.clone(allocator);
        errdefer canvas_id.deinit(allocator);
        return .{
            .extension_id = extension_id,
            .canvas_id = canvas_id,
            .instance_id = try self.instance_id.clone(allocator),
        };
    }

    pub fn view(self: InstanceKey) KeyView {
        return .{
            .extension_id = self.extension_id.bytes,
            .canvas_id = self.canvas_id.bytes,
            .instance_id = self.instance_id.bytes,
        };
    }

    pub fn eql(self: InstanceKey, other: InstanceKey) bool {
        return self.extension_id.eql(other.extension_id) and
            self.canvas_id.eql(other.canvas_id) and
            self.instance_id.eql(other.instance_id);
    }

    pub fn eqlView(self: InstanceKey, other: KeyView) bool {
        return std.mem.eql(u8, self.extension_id.bytes, other.extension_id) and
            std.mem.eql(u8, self.canvas_id.bytes, other.canvas_id) and
            std.mem.eql(u8, self.instance_id.bytes, other.instance_id);
    }

    pub fn byteSize(self: InstanceKey) usize {
        return self.extension_id.bytes.len +
            self.canvas_id.bytes.len +
            self.instance_id.bytes.len;
    }

    pub fn deinit(self: *InstanceKey, allocator: std.mem.Allocator) void {
        self.extension_id.deinit(allocator);
        self.canvas_id.deinit(allocator);
        self.instance_id.deinit(allocator);
        self.* = undefined;
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
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                value,
                .{},
            ) catch return error.InvalidJson;
            defer parsed.deinit();
            return .{ .bytes = try allocator.dupe(u8, value) };
        }

        pub fn clone(
            self: Self,
            allocator: std.mem.Allocator,
        ) !Self {
            return .{ .bytes = try allocator.dupe(u8, self.bytes) };
        }

        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(u8, self.bytes, other.bytes);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.* = undefined;
        }

        pub fn documentRole() JsonRole {
            return role;
        }
    };
}

pub const SchemaDocument = JsonDocument(.schema);
pub const OpenInputDocument = JsonDocument(.open_input);
pub const ActionInputDocument = JsonDocument(.action_input);
pub const ActionResultDocument = JsonDocument(.action_result);

fn cloneText(
    allocator: std.mem.Allocator,
    value: []const u8,
    limits: Limits,
) ![]u8 {
    if (value.len > limits.max_text_bytes) return error.TextTooLong;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidTextUtf8;
    return allocator.dupe(u8, value);
}

pub const CapabilityState = enum {
    unknown,
    unsupported,
    supported,

    pub fn supports(self: CapabilityState) bool {
        return self == .supported;
    }
};

pub const ProviderIdentityInput = struct {
    id: []const u8,
    name: []const u8,
};

pub const ProviderIdentity = struct {
    id: ExtensionId,
    name: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        input: ProviderIdentityInput,
        limits: Limits,
    ) !ProviderIdentity {
        var id = try ExtensionId.init(allocator, input.id, limits);
        errdefer id.deinit(allocator);
        return .{
            .id = id,
            .name = try cloneText(allocator, input.name, limits),
        };
    }

    pub fn deinit(
        self: *ProviderIdentity,
        allocator: std.mem.Allocator,
    ) void {
        self.id.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ActionDeclarationInput = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: ?[]const u8 = null,
};

pub const ActionDeclaration = struct {
    name: ActionName,
    description: []u8,
    input_schema: ?SchemaDocument,

    pub fn init(
        allocator: std.mem.Allocator,
        input: ActionDeclarationInput,
        limits: Limits,
    ) !ActionDeclaration {
        var name = try ActionName.init(allocator, input.name, limits);
        errdefer name.deinit(allocator);
        const description = try cloneText(
            allocator,
            input.description,
            limits,
        );
        errdefer allocator.free(description);
        return .{
            .name = name,
            .description = description,
            .input_schema = if (input.input_schema_json) |json|
                try SchemaDocument.init(allocator, json, limits)
            else
                null,
        };
    }

    pub fn byteSize(self: ActionDeclaration) usize {
        return self.name.bytes.len +
            self.description.len +
            if (self.input_schema) |schema| schema.bytes.len else 0;
    }

    pub fn deinit(
        self: *ActionDeclaration,
        allocator: std.mem.Allocator,
    ) void {
        self.name.deinit(allocator);
        allocator.free(self.description);
        if (self.input_schema) |*schema| schema.deinit(allocator);
        self.* = undefined;
    }
};

pub const CanvasDeclarationInput = struct {
    extension_id: []const u8,
    extension_name: []const u8,
    canvas_id: []const u8,
    display_name: []const u8,
    description: []const u8,
    input_schema_json: ?[]const u8 = null,
    actions: []const ActionDeclarationInput = &.{},
};

pub const CanvasDeclaration = struct {
    provider: ProviderIdentity,
    id: CanvasId,
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
        var provider = try ProviderIdentity.init(allocator, .{
            .id = input.extension_id,
            .name = input.extension_name,
        }, limits);
        errdefer provider.deinit(allocator);
        var id = try CanvasId.init(allocator, input.canvas_id, limits);
        errdefer id.deinit(allocator);
        const display_name = try cloneText(
            allocator,
            input.display_name,
            limits,
        );
        errdefer allocator.free(display_name);
        const description = try cloneText(
            allocator,
            input.description,
            limits,
        );
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
            for (actions[0..index]) |existing| {
                if (std.mem.eql(u8, existing.name.bytes, action_input.name))
                    return error.DuplicateAction;
            }
            actions[index] = try ActionDeclaration.init(
                allocator,
                action_input,
                limits,
            );
            initialized += 1;
        }
        return .{
            .provider = provider,
            .id = id,
            .display_name = display_name,
            .description = description,
            .input_schema = input_schema,
            .actions = actions,
        };
    }

    pub fn byteSize(self: CanvasDeclaration) usize {
        var total = self.provider.id.bytes.len +
            self.provider.name.len +
            self.id.bytes.len +
            self.display_name.len +
            self.description.len +
            if (self.input_schema) |schema| schema.bytes.len else 0;
        for (self.actions) |action| total += action.byteSize();
        return total;
    }

    pub fn hasAction(self: CanvasDeclaration, name: []const u8) bool {
        for (self.actions) |action| {
            if (std.mem.eql(u8, action.name.bytes, name)) return true;
        }
        return false;
    }

    pub fn deinit(
        self: *CanvasDeclaration,
        allocator: std.mem.Allocator,
    ) void {
        self.provider.deinit(allocator);
        self.id.deinit(allocator);
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
    removed: []const struct {
        extension_id: []const u8,
        canvas_id: []const u8,
    } = &.{},
};

pub const RegistryUpdate = union(enum) {
    replacement: []const CanvasDeclarationInput,
    incremental: RegistryDeltaInput,
};

const Registry = struct {
    entries: std.ArrayList(CanvasDeclaration) = .empty,
    bytes: usize = 0,

    fn deinit(
        self: *Registry,
        allocator: std.mem.Allocator,
    ) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    fn find(
        self: Registry,
        extension_id: []const u8,
        canvas_id: []const u8,
    ) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.provider.id.bytes, extension_id) and
                std.mem.eql(u8, entry.id.bytes, canvas_id))
            {
                return index;
            }
        }
        return null;
    }

    fn clone(
        self: Registry,
        allocator: std.mem.Allocator,
        limits: Limits,
    ) !Registry {
        var result: Registry = .{};
        errdefer result.deinit(allocator);
        for (self.entries.items) |entry| {
            const actions = try allocator.alloc(
                ActionDeclarationInput,
                entry.actions.len,
            );
            defer allocator.free(actions);
            for (entry.actions, 0..) |action, index| {
                actions[index] = .{
                    .name = action.name.bytes,
                    .description = action.description,
                    .input_schema_json = if (action.input_schema) |schema|
                        schema.bytes
                    else
                        null,
                };
            }
            var cloned = try CanvasDeclaration.init(allocator, .{
                .extension_id = entry.provider.id.bytes,
                .extension_name = entry.provider.name,
                .canvas_id = entry.id.bytes,
                .display_name = entry.display_name,
                .description = entry.description,
                .input_schema_json = if (entry.input_schema) |schema|
                    schema.bytes
                else
                    null,
                .actions = actions,
            }, limits);
            errdefer cloned.deinit(allocator);
            try result.entries.append(allocator, cloned);
            result.bytes += cloned.byteSize();
        }
        return result;
    }
};

pub const OperationId = enum(u64) {
    _,

    pub fn value(self: OperationId) u64 {
        return @intFromEnum(self);
    }
};

pub const RendererGeneration = enum(u64) {
    _,

    pub fn value(self: RendererGeneration) u64 {
        return @intFromEnum(self);
    }
};

pub const OperationToken = struct {
    id: OperationId,
    generation: ?RendererGeneration = null,
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
    url: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

const OpenedState = struct {
    generation: RendererGeneration,
    title: ?[]u8,
    url: ?[]u8,
    status: ?[]u8,

    fn init(
        allocator: std.mem.Allocator,
        generation: RendererGeneration,
        input: OpenResultInput,
        limits: Limits,
    ) !OpenedState {
        const title = if (input.title) |value|
            try cloneText(allocator, value, limits)
        else
            null;
        errdefer if (title) |value| allocator.free(value);
        const url = if (input.url) |value|
            try cloneText(allocator, value, limits)
        else
            null;
        errdefer if (url) |value| allocator.free(value);
        return .{
            .generation = generation,
            .title = title,
            .url = url,
            .status = if (input.status) |value|
                try cloneText(allocator, value, limits)
            else
                null,
        };
    }

    fn byteSize(self: OpenedState) usize {
        return (if (self.title) |value| value.len else 0) +
            (if (self.url) |value| value.len else 0) +
            (if (self.status) |value| value.len else 0);
    }

    fn matches(self: OpenedState, input: OpenResultInput) bool {
        return optionalTextEql(self.title, input.title) and
            optionalTextEql(self.url, input.url) and
            optionalTextEql(self.status, input.status);
    }

    fn deinit(self: *OpenedState, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        self.* = undefined;
    }
};

const LocalWork = struct {
    operation_id: OperationId,
    generation: RendererGeneration,
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
    opening: LocalWork,
    opened: OpenedState,
    closing: LocalWork,
    unavailable,

    fn tag(self: RuntimeState) RuntimeTag {
        return std.meta.activeTag(self);
    }

    fn byteSize(self: RuntimeState) usize {
        return switch (self) {
            .opened => |opened| opened.byteSize(),
            else => 0,
        };
    }

    fn deinit(self: *RuntimeState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .opened => |*opened| opened.deinit(allocator),
            else => {},
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
            .input = if (input) |value| try value.clone(allocator) else null,
        };
    }

    fn byteSize(self: RecordedState) usize {
        return (if (self.title) |value| value.len else 0) +
            (if (self.input) |input| input.bytes.len else 0);
    }

    fn matches(
        self: RecordedState,
        title: ?[]const u8,
        input: ?*const OpenInputDocument,
    ) bool {
        if (!optionalTextEql(self.title, title)) return false;
        return if (self.input) |current|
            if (input) |candidate|
                current.eql(candidate.*)
            else
                false
        else
            input == null;
    }

    fn deinit(self: *RecordedState, allocator: std.mem.Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.input) |*input| input.deinit(allocator);
        self.* = undefined;
    }
};

const RecordState = union(RecordTag) {
    recorded: RecordedState,
    removed,

    fn tag(self: RecordState) RecordTag {
        return std.meta.activeTag(self);
    }

    fn byteSize(self: RecordState) usize {
        return switch (self) {
            .recorded => |recorded| recorded.byteSize(),
            .removed => 0,
        };
    }

    fn deinit(self: *RecordState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .recorded => |*recorded| recorded.deinit(allocator),
            .removed => {},
        }
        self.* = undefined;
    }
};

pub const Degradation = enum {
    invalid_signal,
    limit_exceeded,
    backpressure,
    host_failure,
};

pub const ProtocolScope = union(enum) {
    registry,
    instance: KeyView,
};

const Instance = struct {
    key: InstanceKey,
    open_input: ?OpenInputDocument,
    runtime: RuntimeState = .closed,
    record: RecordState = .removed,
    degradation: ?Degradation = null,

    fn init(
        allocator: std.mem.Allocator,
        key: KeyView,
        input: ?*const OpenInputDocument,
        limits: Limits,
    ) !Instance {
        var owned_key = try InstanceKey.init(allocator, key, limits);
        errdefer owned_key.deinit(allocator);
        return .{
            .key = owned_key,
            .open_input = if (input) |value| try value.clone(allocator) else null,
        };
    }

    fn byteSize(self: Instance) usize {
        return self.key.byteSize() +
            (if (self.open_input) |input| input.bytes.len else 0) +
            self.runtime.byteSize() +
            self.record.byteSize();
    }

    fn replaceOpenInput(
        self: *Instance,
        allocator: std.mem.Allocator,
        input: ?*const OpenInputDocument,
    ) !void {
        var replacement = if (input) |value| try value.clone(allocator) else null;
        errdefer if (replacement) |*value| value.deinit(allocator);
        if (self.open_input) |*current| current.deinit(allocator);
        self.open_input = replacement;
    }

    fn replaceRuntime(
        self: *Instance,
        allocator: std.mem.Allocator,
        runtime: RuntimeState,
    ) void {
        self.runtime.deinit(allocator);
        self.runtime = runtime;
    }

    fn replaceRecord(
        self: *Instance,
        allocator: std.mem.Allocator,
        record: RecordState,
    ) void {
        self.record.deinit(allocator);
        self.record = record;
    }

    fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        if (self.open_input) |*input| input.deinit(allocator);
        self.runtime.deinit(allocator);
        self.record.deinit(allocator);
        self.* = undefined;
    }
};

const PendingKind = union(enum) {
    open: RendererGeneration,
    close: RendererGeneration,
    action,
};

const PendingOperation = struct {
    id: OperationId,
    instance_index: usize,
    kind: PendingKind,
};

pub const OpenOutcome = union(enum) {
    succeeded: OpenResultInput,
    failed,
};

pub const ActionOutcome = union(enum) {
    succeeded: *const ActionResultDocument,
    failed,
};

pub const ProviderSignal = union(enum) {
    opened: struct {
        key: KeyView,
        input: ?*const OpenInputDocument = null,
        result: OpenResultInput = .{},
    },
    closed: KeyView,
    unavailable: KeyView,
    recorded: struct {
        key: KeyView,
        title: ?[]const u8 = null,
        input: ?*const OpenInputDocument = null,
    },
    removed: KeyView,
};

pub const ResumeCanvas = struct {
    key: InstanceKey,
    title: ?[]u8,
    input: ?OpenInputDocument,

    pub fn deinit(
        self: *ResumeCanvas,
        allocator: std.mem.Allocator,
    ) void {
        self.key.deinit(allocator);
        if (self.title) |title| allocator.free(title);
        if (self.input) |*input| input.deinit(allocator);
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

pub const State = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    capability: CapabilityState = .unknown,
    registry: Registry = .{},
    instances: std.ArrayList(Instance) = .empty,
    pending: std.ArrayList(PendingOperation) = .empty,
    next_operation_id: u64 = 1,
    next_renderer_generation: u64 = 1,
    registry_degradation: ?Degradation = null,
    operation_degradation: ?Degradation = null,
    shutdown_requested: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: Limits,
    ) State {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *State) void {
        self.registry.deinit(self.allocator);
        for (self.instances.items) |*instance| {
            instance.deinit(self.allocator);
        }
        self.instances.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setCapability(
        self: *State,
        capability: CapabilityState,
    ) void {
        self.capability = capability;
    }

    pub fn applyRegistry(
        self: *State,
        update: RegistryUpdate,
    ) !void {
        if (self.shutdown_requested) return error.Shutdown;
        var candidate = switch (update) {
            .replacement => |entries| self.buildRegistry(entries),
            .incremental => |delta| self.buildIncrementalRegistry(delta),
        } catch |err| {
            if (err == error.AggregateLimitExceeded or
                err == error.TooManyRegistryEntries or
                err == error.TooManyActions)
            {
                self.registry_degradation = .limit_exceeded;
            } else {
                self.registry_degradation = .invalid_signal;
            }
            return err;
        };
        errdefer candidate.deinit(self.allocator);
        if (candidate.bytes > self.limits.max_registry_bytes or
            self.instanceBytes() + candidate.bytes >
                self.limits.max_conversation_bytes)
        {
            self.registry_degradation = .limit_exceeded;
            return error.AggregateLimitExceeded;
        }
        self.registry.deinit(self.allocator);
        self.registry = candidate;
        self.registry_degradation = null;
        self.markMissingDeclarationsUnavailable();
    }

    pub fn beginOpen(
        self: *State,
        request: OpenRequest,
    ) !OperationToken {
        try self.requireOperational();
        if (!self.capability.supports()) return error.CanvasUnsupported;
        if (self.registry.find(
            request.key.extension_id,
            request.key.canvas_id,
        ) == null) return error.CanvasUnavailable;
        try self.requirePendingCapacity();
        var replacement_input = if (request.input) |input|
            try input.clone(self.allocator)
        else
            null;
        errdefer if (replacement_input) |*input| input.deinit(self.allocator);
        const index = try self.ensureInstance(request.key, null);
        const input_bytes = if (request.input) |input| input.bytes.len else 0;
        const instance = &self.instances.items[index];
        if (self.projectedInstanceBytes(
            index,
            input_bytes,
            instance.runtime.byteSize(),
            instance.record.byteSize(),
        ) > self.limits.max_conversation_bytes) {
            instance.degradation = .limit_exceeded;
            return error.AggregateLimitExceeded;
        }
        self.cancelPendingForInstance(index);
        const id = self.takeOperationId();
        const generation = self.takeRendererGeneration();
        try self.pending.append(self.allocator, .{
            .id = id,
            .instance_index = index,
            .kind = .{ .open = generation },
        });
        if (instance.open_input) |*input| input.deinit(self.allocator);
        instance.open_input = replacement_input;
        instance.replaceRuntime(self.allocator, .{ .opening = .{
            .operation_id = id,
            .generation = generation,
        } });
        instance.degradation = null;
        self.operation_degradation = null;
        return .{ .id = id, .generation = generation };
    }

    pub fn completeOpen(
        self: *State,
        token: OperationToken,
        outcome: OpenOutcome,
    ) !bool {
        const generation = token.generation orelse
            return error.MissingRendererGeneration;
        const pending_index = self.findPending(
            token.id,
            .open,
            generation,
        ) orelse return false;
        const pending = self.pending.orderedRemove(pending_index);
        if (self.shutdown_requested) return false;
        const instance = &self.instances.items[pending.instance_index];
        const current = switch (instance.runtime) {
            .opening => |work| work,
            else => return false,
        };
        if (current.operation_id != token.id or
            current.generation != generation)
        {
            return false;
        }
        switch (outcome) {
            .succeeded => |result| {
                var opened = try OpenedState.init(
                    self.allocator,
                    generation,
                    result,
                    self.limits,
                );
                errdefer opened.deinit(self.allocator);
                if (self.projectedInstanceBytes(
                    pending.instance_index,
                    if (instance.open_input) |input| input.bytes.len else 0,
                    opened.byteSize(),
                    instance.record.byteSize(),
                ) > self.limits.max_conversation_bytes) {
                    instance.degradation = .limit_exceeded;
                    instance.replaceRuntime(self.allocator, .closed);
                    return error.AggregateLimitExceeded;
                }
                instance.replaceRuntime(
                    self.allocator,
                    .{ .opened = opened },
                );
                instance.degradation = null;
            },
            .failed => {
                instance.replaceRuntime(self.allocator, .closed);
                instance.degradation = .host_failure;
            },
        }
        return true;
    }

    pub fn beginClose(
        self: *State,
        request: CloseRequest,
    ) !OperationToken {
        try self.requireOperational();
        try self.requirePendingCapacity();
        const index = self.findInstance(request.key) orelse
            return error.CanvasNotOpen;
        const instance = &self.instances.items[index];
        const generation = switch (instance.runtime) {
            .opened => |opened| opened.generation,
            else => return error.CanvasNotOpen,
        };
        const id = self.takeOperationId();
        try self.pending.append(self.allocator, .{
            .id = id,
            .instance_index = index,
            .kind = .{ .close = generation },
        });
        instance.replaceRuntime(self.allocator, .{ .closing = .{
            .operation_id = id,
            .generation = generation,
        } });
        self.operation_degradation = null;
        return .{ .id = id, .generation = generation };
    }

    pub fn completeClose(
        self: *State,
        token: OperationToken,
        succeeded: bool,
    ) !bool {
        const generation = token.generation orelse
            return error.MissingRendererGeneration;
        const pending_index = self.findPending(
            token.id,
            .close,
            generation,
        ) orelse return false;
        const pending = self.pending.orderedRemove(pending_index);
        if (self.shutdown_requested) return false;
        const instance = &self.instances.items[pending.instance_index];
        const current = switch (instance.runtime) {
            .closing => |work| work,
            else => return false,
        };
        if (current.operation_id != token.id or
            current.generation != generation)
        {
            return false;
        }
        instance.replaceRuntime(self.allocator, if (succeeded)
            .closed
        else
            .unavailable);
        instance.degradation = if (succeeded) null else .host_failure;
        return true;
    }

    pub fn beginAction(
        self: *State,
        request: InvokeActionRequest,
    ) !OperationToken {
        try self.requireOperational();
        var action_name = try ActionName.init(
            self.allocator,
            request.action_name,
            self.limits,
        );
        defer action_name.deinit(self.allocator);
        const declaration_index = self.registry.find(
            request.key.extension_id,
            request.key.canvas_id,
        ) orelse return error.CanvasUnavailable;
        if (!self.registry.entries.items[declaration_index].hasAction(
            request.action_name,
        )) return error.ActionUnavailable;
        const instance_index = self.findInstance(request.key) orelse
            return error.CanvasNotOpen;
        if (self.instances.items[instance_index].runtime.tag() != .opened)
            return error.CanvasNotOpen;
        try self.requirePendingCapacity();
        const id = self.takeOperationId();
        try self.pending.append(self.allocator, .{
            .id = id,
            .instance_index = instance_index,
            .kind = .action,
        });
        self.operation_degradation = null;
        return .{ .id = id };
    }

    pub fn completeAction(
        self: *State,
        token: OperationToken,
        outcome: ActionOutcome,
    ) bool {
        const pending_index = self.findPending(
            token.id,
            .action,
            null,
        ) orelse return false;
        const pending = self.pending.orderedRemove(pending_index);
        if (self.shutdown_requested) return false;
        const instance = &self.instances.items[pending.instance_index];
        if (instance.runtime.tag() != .opened) return false;
        switch (outcome) {
            .succeeded => |result| _ = result,
            .failed => instance.degradation = .host_failure,
        }
        return true;
    }

    pub fn applyProviderSignal(
        self: *State,
        signal: ProviderSignal,
    ) !void {
        if (self.shutdown_requested) return;
        switch (signal) {
            .opened => |opened_signal| {
                if (self.findInstance(opened_signal.key)) |existing_index| {
                    const existing = self.instances.items[existing_index];
                    const same_input = if (existing.open_input) |current|
                        if (opened_signal.input) |candidate|
                            current.eql(candidate.*)
                        else
                            false
                    else
                        opened_signal.input == null;
                    if (same_input) switch (existing.runtime) {
                        .opened => |opened| if (opened.matches(
                            opened_signal.result,
                        )) return,
                        else => {},
                    };
                }
                const index = try self.ensureInstance(
                    opened_signal.key,
                    opened_signal.input,
                );
                const generation = self.takeRendererGeneration();
                var opened = try OpenedState.init(
                    self.allocator,
                    generation,
                    opened_signal.result,
                    self.limits,
                );
                errdefer opened.deinit(self.allocator);
                const instance = &self.instances.items[index];
                if (self.projectedInstanceBytes(
                    index,
                    if (opened_signal.input) |input| input.bytes.len else 0,
                    opened.byteSize(),
                    instance.record.byteSize(),
                ) > self.limits.max_conversation_bytes) {
                    instance.degradation = .limit_exceeded;
                    return error.AggregateLimitExceeded;
                }
                self.cancelPendingForInstance(index);
                try instance.replaceOpenInput(
                    self.allocator,
                    opened_signal.input,
                );
                instance.replaceRuntime(
                    self.allocator,
                    .{ .opened = opened },
                );
                instance.degradation = null;
            },
            .closed => |key| {
                const index = self.findInstance(key) orelse return;
                const instance = &self.instances.items[index];
                if (instance.runtime.tag() == .closed) return;
                self.cancelPendingForInstance(index);
                instance.replaceRuntime(self.allocator, .closed);
            },
            .unavailable => |key| {
                const index = try self.ensureInstance(key, null);
                const instance = &self.instances.items[index];
                if (instance.runtime.tag() == .unavailable) return;
                self.cancelPendingForInstance(index);
                instance.replaceRuntime(self.allocator, .unavailable);
            },
            .recorded => |recorded_signal| {
                const index = try self.ensureInstance(
                    recorded_signal.key,
                    null,
                );
                switch (self.instances.items[index].record) {
                    .recorded => |recorded| if (recorded.matches(
                        recorded_signal.title,
                        recorded_signal.input,
                    )) return,
                    .removed => {},
                }
                var recorded = try RecordedState.init(
                    self.allocator,
                    recorded_signal.title,
                    recorded_signal.input,
                    self.limits,
                );
                errdefer recorded.deinit(self.allocator);
                if (self.projectedInstanceBytes(
                    index,
                    if (self.instances.items[index].open_input) |input|
                        input.bytes.len
                    else
                        0,
                    self.instances.items[index].runtime.byteSize(),
                    recorded.byteSize(),
                ) > self.limits.max_conversation_bytes) {
                    self.instances.items[index].degradation = .limit_exceeded;
                    return error.AggregateLimitExceeded;
                }
                self.instances.items[index].replaceRecord(
                    self.allocator,
                    .{ .recorded = recorded },
                );
            },
            .removed => |key| {
                const index = try self.ensureInstance(key, null);
                const instance = &self.instances.items[index];
                if (instance.record.tag() == .removed) return;
                instance.replaceRecord(self.allocator, .removed);
            },
        }
    }

    pub fn shutdown(self: *State) void {
        if (self.shutdown_requested) return;
        self.shutdown_requested = true;
        self.pending.clearRetainingCapacity();
        for (self.instances.items) |*instance| {
            switch (instance.runtime) {
                .opening, .opened, .closing => {
                    instance.replaceRuntime(self.allocator, .closed);
                },
                .closed, .unavailable => {},
            }
        }
    }

    pub fn noteProtocolViolation(
        self: *State,
        scope: ProtocolScope,
    ) void {
        switch (scope) {
            .registry => self.registry_degradation = .invalid_signal,
            .instance => |key| {
                const index = self.findInstance(key) orelse return;
                self.instances.items[index].degradation = .invalid_signal;
            },
        }
    }

    pub fn resumeProjection(
        self: State,
        allocator: std.mem.Allocator,
        include: bool,
    ) !ResumeProjection {
        if (!include) return .omitted;
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
            const recorded = switch (instance.record) {
                .recorded => |recorded| recorded,
                .removed => continue,
            };
            var key = try instance.key.clone(allocator);
            errdefer key.deinit(allocator);
            const title = if (recorded.title) |title|
                try allocator.dupe(u8, title)
            else
                null;
            errdefer if (title) |value| allocator.free(value);
            canvases[initialized] = .{
                .key = key,
                .title = title,
                .input = if (recorded.input) |input|
                    try input.clone(allocator)
                else
                    null,
            };
            initialized += 1;
        }
        return .{ .canvases = canvases };
    }

    pub fn runtimeTag(
        self: State,
        key: KeyView,
    ) ?RuntimeTag {
        const index = self.findInstance(key) orelse return null;
        return self.instances.items[index].runtime.tag();
    }

    pub fn recordTag(
        self: State,
        key: KeyView,
    ) ?RecordTag {
        const index = self.findInstance(key) orelse return null;
        return self.instances.items[index].record.tag();
    }

    pub fn instanceDegradation(
        self: State,
        key: KeyView,
    ) ?Degradation {
        const index = self.findInstance(key) orelse return null;
        return self.instances.items[index].degradation;
    }

    pub fn registryCount(self: State) usize {
        return self.registry.entries.items.len;
    }

    pub fn pendingCount(self: State) usize {
        return self.pending.items.len;
    }

    fn requireOperational(self: *State) !void {
        if (self.shutdown_requested) return error.Shutdown;
    }

    fn requirePendingCapacity(self: *State) !void {
        if (self.pending.items.len >= self.limits.max_pending_operations) {
            self.operation_degradation = .backpressure;
            return error.Backpressure;
        }
    }

    fn takeOperationId(self: *State) OperationId {
        const value = self.next_operation_id;
        self.next_operation_id += 1;
        return @enumFromInt(value);
    }

    fn takeRendererGeneration(self: *State) RendererGeneration {
        const value = self.next_renderer_generation;
        self.next_renderer_generation += 1;
        return @enumFromInt(value);
    }

    fn findInstance(self: State, key: KeyView) ?usize {
        for (self.instances.items, 0..) |instance, index| {
            if (instance.key.eqlView(key)) return index;
        }
        return null;
    }

    fn ensureInstance(
        self: *State,
        key: KeyView,
        input: ?*const OpenInputDocument,
    ) !usize {
        if (self.findInstance(key)) |index| return index;
        if (self.instances.items.len >= self.limits.max_instances)
            return error.TooManyInstances;
        var instance = try Instance.init(
            self.allocator,
            key,
            input,
            self.limits,
        );
        errdefer instance.deinit(self.allocator);
        if (self.registry.bytes + self.instanceBytes() + instance.byteSize() >
            self.limits.max_conversation_bytes)
        {
            return error.AggregateLimitExceeded;
        }
        try self.instances.append(self.allocator, instance);
        return self.instances.items.len - 1;
    }

    fn findPending(
        self: State,
        id: OperationId,
        comptime wanted: enum { open, close, action },
        generation: ?RendererGeneration,
    ) ?usize {
        for (self.pending.items, 0..) |pending, index| {
            if (pending.id != id) continue;
            const matches = switch (pending.kind) {
                .open => |value| wanted == .open and generation == value,
                .close => |value| wanted == .close and generation == value,
                .action => wanted == .action and generation == null,
            };
            if (matches) return index;
        }
        return null;
    }

    fn cancelPendingForInstance(
        self: *State,
        instance_index: usize,
    ) void {
        var index = self.pending.items.len;
        while (index > 0) {
            index -= 1;
            if (self.pending.items[index].instance_index == instance_index) {
                _ = self.pending.orderedRemove(index);
            }
        }
    }

    fn instanceBytes(self: State) usize {
        var total: usize = 0;
        for (self.instances.items) |instance| total += instance.byteSize();
        return total;
    }

    fn projectedInstanceBytes(
        self: State,
        index: usize,
        open_input_bytes: usize,
        runtime_bytes: usize,
        record_bytes: usize,
    ) usize {
        const instance = self.instances.items[index];
        return self.registry.bytes +
            self.instanceBytes() -
            (if (instance.open_input) |input| input.bytes.len else 0) -
            instance.runtime.byteSize() -
            instance.record.byteSize() +
            open_input_bytes +
            runtime_bytes +
            record_bytes;
    }

    fn buildRegistry(
        self: *State,
        inputs: []const CanvasDeclarationInput,
    ) !Registry {
        if (inputs.len > self.limits.max_registry_entries)
            return error.TooManyRegistryEntries;
        var result: Registry = .{};
        errdefer result.deinit(self.allocator);
        for (inputs) |input| {
            if (result.find(input.extension_id, input.canvas_id) != null)
                return error.DuplicateCanvas;
            var declaration = try CanvasDeclaration.init(
                self.allocator,
                input,
                self.limits,
            );
            errdefer declaration.deinit(self.allocator);
            const projected = result.bytes + declaration.byteSize();
            if (projected > self.limits.max_registry_bytes)
                return error.AggregateLimitExceeded;
            try result.entries.append(self.allocator, declaration);
            result.bytes = projected;
        }
        return result;
    }

    fn buildIncrementalRegistry(
        self: *State,
        delta: RegistryDeltaInput,
    ) !Registry {
        var next = try self.registry.clone(self.allocator, self.limits);
        errdefer next.deinit(self.allocator);
        try self.applyDelta(&next, delta);
        return next;
    }

    fn applyDelta(
        self: *State,
        registry: *Registry,
        delta: RegistryDeltaInput,
    ) !void {
        for (delta.removed) |removed| {
            if (registry.find(
                removed.extension_id,
                removed.canvas_id,
            )) |index| {
                var declaration = registry.entries.orderedRemove(index);
                registry.bytes -= declaration.byteSize();
                declaration.deinit(self.allocator);
            }
        }
        for (delta.upserted) |input| {
            var declaration = try CanvasDeclaration.init(
                self.allocator,
                input,
                self.limits,
            );
            errdefer declaration.deinit(self.allocator);
            if (registry.find(input.extension_id, input.canvas_id)) |index| {
                const previous_size = registry.entries.items[index].byteSize();
                const projected = registry.bytes -
                    previous_size +
                    declaration.byteSize();
                if (projected > self.limits.max_registry_bytes)
                    return error.AggregateLimitExceeded;
                registry.entries.items[index].deinit(self.allocator);
                registry.entries.items[index] = declaration;
                registry.bytes = projected;
            } else {
                if (registry.entries.items.len >=
                    self.limits.max_registry_entries)
                {
                    return error.TooManyRegistryEntries;
                }
                const projected = registry.bytes + declaration.byteSize();
                if (projected > self.limits.max_registry_bytes)
                    return error.AggregateLimitExceeded;
                try registry.entries.append(self.allocator, declaration);
                registry.bytes = projected;
            }
        }
    }

    fn markMissingDeclarationsUnavailable(self: *State) void {
        for (self.instances.items, 0..) |*instance, index| {
            if (self.registry.find(
                instance.key.extension_id.bytes,
                instance.key.canvas_id.bytes,
            ) == null) {
                self.cancelPendingForInstance(index);
                instance.replaceRuntime(self.allocator, .unavailable);
            }
        }
    }
};

fn optionalTextEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub const CanonicalTraceStep = struct {
    operation: enum {
        registry_replacement,
        open_requested,
        open_completed,
        recorded,
        unavailable,
        reopened_with_same_key,
        action_invoked,
        closed,
        removed,
    },
    expected_runtime: ?RuntimeTag,
    expected_record: ?RecordTag,
};

pub const canonical_trace_fixture = [_]CanonicalTraceStep{
    .{
        .operation = .registry_replacement,
        .expected_runtime = null,
        .expected_record = null,
    },
    .{
        .operation = .open_requested,
        .expected_runtime = .opening,
        .expected_record = .removed,
    },
    .{
        .operation = .open_completed,
        .expected_runtime = .opened,
        .expected_record = .removed,
    },
    .{
        .operation = .recorded,
        .expected_runtime = .opened,
        .expected_record = .recorded,
    },
    .{
        .operation = .unavailable,
        .expected_runtime = .unavailable,
        .expected_record = .recorded,
    },
    .{
        .operation = .reopened_with_same_key,
        .expected_runtime = .opened,
        .expected_record = .recorded,
    },
    .{
        .operation = .action_invoked,
        .expected_runtime = .opened,
        .expected_record = .recorded,
    },
    .{
        .operation = .closed,
        .expected_runtime = .closed,
        .expected_record = .recorded,
    },
    .{
        .operation = .removed,
        .expected_runtime = .closed,
        .expected_record = .removed,
    },
};

const fixture_key: KeyView = .{
    .extension_id = "fixture.extension",
    .canvas_id = "review",
    .instance_id = "review:main",
};

const fixture_actions = [_]ActionDeclarationInput{.{
    .name = "refresh",
    .description = "Refresh",
    .input_schema_json = "{\"type\":\"object\"}",
}};

const fixture_declaration: CanvasDeclarationInput = .{
    .extension_id = "fixture.extension",
    .extension_name = "Fixture",
    .canvas_id = "review",
    .display_name = "Review",
    .description = "Review changes",
    .input_schema_json = "{\"type\":\"object\"}",
    .actions = &fixture_actions,
};

fn fixtureState(limits: Limits) !State {
    var state = State.init(std.testing.allocator, limits);
    errdefer state.deinit();
    state.setCapability(.supported);
    try state.applyRegistry(.{ .replacement = &.{fixture_declaration} });
    return state;
}

test "identity roles validate UTF-8 and independent and aggregate limits" {
    const Case = struct {
        value: []const u8,
        limits: Limits = .{},
        expected: ?anyerror,
    };
    const cases = [_]Case{
        .{ .value = "", .expected = error.EmptyIdentifier },
        .{
            .value = "abcd",
            .limits = .{ .max_identifier_bytes = 3 },
            .expected = error.IdentifierTooLong,
        },
        .{ .value = "\xff", .expected = error.InvalidIdentifierUtf8 },
        .{ .value = "valid", .expected = null },
    };
    for (cases) |case| {
        const result = ExtensionId.init(
            std.testing.allocator,
            case.value,
            case.limits,
        );
        if (case.expected) |expected| {
            try std.testing.expectError(expected, result);
        } else {
            var value = try result;
            defer value.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(case.value, value.bytes);
        }
    }

    try std.testing.expectError(error.KeyTooLong, InstanceKey.init(
        std.testing.allocator,
        fixture_key,
        .{ .max_key_bytes = 8 },
    ));
    try std.testing.expectEqualStrings("extension", ExtensionId.role());
    try std.testing.expectEqualStrings("action", ActionName.role());
}

test "role-specific JSON documents validate syntax UTF-8 and limits" {
    const Case = struct {
        json: []const u8,
        expected: ?anyerror,
    };
    const cases = [_]Case{
        .{ .json = "", .expected = error.EmptyJsonDocument },
        .{ .json = "{", .expected = error.InvalidJson },
        .{ .json = "\xff", .expected = error.InvalidJsonUtf8 },
        .{ .json = "{\"ok\":true}", .expected = null },
    };
    for (cases) |case| {
        const result = OpenInputDocument.init(
            std.testing.allocator,
            case.json,
            .{},
        );
        if (case.expected) |expected| {
            try std.testing.expectError(expected, result);
        } else {
            var document = try result;
            defer document.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(case.json, document.bytes);
        }
    }
    try std.testing.expectError(
        error.JsonDocumentTooLong,
        SchemaDocument.init(
            std.testing.allocator,
            "{}",
            .{ .max_json_bytes = 1 },
        ),
    );
    try std.testing.expect(
        SchemaDocument != OpenInputDocument and
            OpenInputDocument != ActionInputDocument and
            ActionInputDocument != ActionResultDocument,
    );
}

test "declaration limits and duplicates are rejected before registry replacement" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const duplicate_actions = [_]ActionDeclarationInput{
        .{ .name = "same", .description = "one" },
        .{ .name = "same", .description = "two" },
    };
    var invalid = fixture_declaration;
    invalid.actions = &duplicate_actions;
    try std.testing.expectError(
        error.DuplicateAction,
        state.applyRegistry(.{ .replacement = &.{invalid} }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.registryCount());

    try std.testing.expectError(
        error.DuplicateCanvas,
        state.applyRegistry(.{
            .replacement = &.{ fixture_declaration, fixture_declaration },
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.registryCount());
}

test "open same-key close and action operations are deterministic" {
    var state = try fixtureState(.{});
    defer state.deinit();
    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "{\"selection\":\"src/main.zig\"}",
        .{},
    );
    defer input.deinit(std.testing.allocator);

    const first = try state.beginOpen(.{ .key = fixture_key, .input = &input });
    try std.testing.expectEqual(RuntimeTag.opening, state.runtimeTag(fixture_key).?);
    try std.testing.expect(try state.completeOpen(first, .{ .succeeded = .{
        .title = "Review",
        .url = "https://example.invalid/review",
        .status = "ready",
    } }));
    try std.testing.expectEqual(RuntimeTag.opened, state.runtimeTag(fixture_key).?);

    const second = try state.beginOpen(.{ .key = fixture_key, .input = &input });
    try std.testing.expect(second.id.value() > first.id.value());
    try std.testing.expect(
        second.generation.?.value() > first.generation.?.value(),
    );
    try std.testing.expect(!(try state.completeOpen(first, .{
        .succeeded = .{},
    })));
    try std.testing.expect(try state.completeOpen(second, .{
        .succeeded = .{ .title = "Reopened" },
    }));

    const action = try state.beginAction(.{
        .key = fixture_key,
        .action_name = "refresh",
    });
    var result = try ActionResultDocument.init(
        std.testing.allocator,
        "{\"refreshed\":true}",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(state.completeAction(
        action,
        .{ .succeeded = &result },
    ));

    const close = try state.beginClose(.{ .key = fixture_key });
    try std.testing.expectEqual(RuntimeTag.closing, state.runtimeTag(fixture_key).?);
    try std.testing.expect(try state.completeClose(close, true));
    try std.testing.expectEqual(RuntimeTag.closed, state.runtimeTag(fixture_key).?);
}

test "unavailable reconnect and recorded removed state are orthogonal" {
    var state = try fixtureState(.{});
    defer state.deinit();
    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "{\"selection\":\"src/main.zig\"}",
        .{},
    );
    defer input.deinit(std.testing.allocator);

    try state.applyProviderSignal(.{ .recorded = .{
        .key = fixture_key,
        .title = "Review",
        .input = &input,
    } });
    try state.applyProviderSignal(.{ .unavailable = fixture_key });
    try std.testing.expectEqual(RuntimeTag.unavailable, state.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(RecordTag.recorded, state.recordTag(fixture_key).?);

    try state.applyProviderSignal(.{ .opened = .{
        .key = fixture_key,
        .input = &input,
        .result = .{ .status = "ready" },
    } });
    try std.testing.expectEqual(RuntimeTag.opened, state.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(RecordTag.recorded, state.recordTag(fixture_key).?);

    try state.applyProviderSignal(.{ .removed = fixture_key });
    try std.testing.expectEqual(RuntimeTag.opened, state.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(RecordTag.removed, state.recordTag(fixture_key).?);
}

test "registry replacement and incremental inputs have distinct semantics" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const second: CanvasDeclarationInput = .{
        .extension_id = "fixture.extension",
        .extension_name = "Fixture",
        .canvas_id = "preview",
        .display_name = "Preview",
        .description = "Preview changes",
    };
    try state.applyRegistry(.{ .incremental = .{
        .upserted = &.{second},
    } });
    try std.testing.expectEqual(@as(usize, 2), state.registryCount());

    try state.applyRegistry(.{ .replacement = &.{second} });
    try std.testing.expectEqual(@as(usize, 1), state.registryCount());

    try state.applyRegistry(.{ .incremental = .{
        .removed = &.{.{
            .extension_id = "fixture.extension",
            .canvas_id = "preview",
        }},
    } });
    try std.testing.expectEqual(@as(usize, 0), state.registryCount());
}

test "failed incremental registry update preserves and releases cloned state" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const duplicate_actions = [_]ActionDeclarationInput{
        .{ .name = "same", .description = "one" },
        .{ .name = "same", .description = "two" },
    };
    var invalid = fixture_declaration;
    invalid.actions = &duplicate_actions;
    try std.testing.expectError(error.DuplicateAction, state.applyRegistry(.{
        .incremental = .{ .upserted = &.{invalid} },
    }));
    try std.testing.expectEqual(@as(usize, 1), state.registryCount());
}

test "duplicate and late provider signals are idempotent by observed state" {
    var state = try fixtureState(.{});
    defer state.deinit();
    try state.applyProviderSignal(.{ .closed = fixture_key });
    try std.testing.expect(state.runtimeTag(fixture_key) == null);

    try state.applyProviderSignal(.{ .opened = .{ .key = fixture_key } });
    const generation = state.next_renderer_generation;
    try state.applyProviderSignal(.{ .opened = .{ .key = fixture_key } });
    try std.testing.expectEqual(generation, state.next_renderer_generation);
    try state.applyProviderSignal(.{ .closed = fixture_key });
    try state.applyProviderSignal(.{ .closed = fixture_key });
    try std.testing.expectEqual(RuntimeTag.closed, state.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(generation, state.next_renderer_generation);

    try state.applyProviderSignal(.{ .removed = fixture_key });
    try state.applyProviderSignal(.{ .removed = fixture_key });
    try std.testing.expectEqual(RecordTag.removed, state.recordTag(fixture_key).?);
}

test "closing races and stale renderer generations reject old host work" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const open = try state.beginOpen(.{ .key = fixture_key });
    try std.testing.expect(try state.completeOpen(open, .{ .succeeded = .{} }));
    const close = try state.beginClose(.{ .key = fixture_key });

    try state.applyProviderSignal(.{ .opened = .{
        .key = fixture_key,
        .result = .{ .title = "Provider reopen" },
    } });
    try std.testing.expect(!(try state.completeClose(close, true)));
    try std.testing.expectEqual(RuntimeTag.opened, state.runtimeTag(fixture_key).?);

    const local_reopen = try state.beginOpen(.{ .key = fixture_key });
    const later_reopen = try state.beginOpen(.{ .key = fixture_key });
    try std.testing.expect(!(try state.completeOpen(local_reopen, .{
        .succeeded = .{},
    })));
    try std.testing.expect(try state.completeOpen(later_reopen, .{
        .succeeded = .{},
    }));
}

test "actions fail closed when declaration or runtime availability is absent" {
    var state = try fixtureState(.{});
    defer state.deinit();
    try std.testing.expectError(error.CanvasNotOpen, state.beginAction(.{
        .key = fixture_key,
        .action_name = "refresh",
    }));
    const open = try state.beginOpen(.{ .key = fixture_key });
    _ = try state.completeOpen(open, .{ .succeeded = .{} });
    try std.testing.expectError(error.ActionUnavailable, state.beginAction(.{
        .key = fixture_key,
        .action_name = "missing",
    }));
    try state.applyProviderSignal(.{ .unavailable = fixture_key });
    try std.testing.expectError(error.CanvasNotOpen, state.beginAction(.{
        .key = fixture_key,
        .action_name = "refresh",
    }));
}

test "scoped degradation and bounded backpressure preserve other state" {
    var state = try fixtureState(.{ .max_pending_operations = 1 });
    defer state.deinit();
    const open = try state.beginOpen(.{ .key = fixture_key });
    try std.testing.expectError(error.Backpressure, state.beginOpen(.{
        .key = fixture_key,
    }));
    try std.testing.expectEqual(
        Degradation.backpressure,
        state.operation_degradation.?,
    );
    try std.testing.expect(state.registry_degradation == null);
    _ = try state.completeOpen(open, .{ .failed = {} });
    try std.testing.expectEqual(
        Degradation.host_failure,
        state.instanceDegradation(fixture_key).?,
    );

    state.noteProtocolViolation(.registry);
    try std.testing.expectEqual(
        Degradation.invalid_signal,
        state.registry_degradation.?,
    );
    state.noteProtocolViolation(.{ .instance = fixture_key });
    try std.testing.expectEqual(
        Degradation.invalid_signal,
        state.instanceDegradation(fixture_key).?,
    );
}

test "aggregate budgets reject replacement before discarding valid state" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const large: CanvasDeclarationInput = .{
        .extension_id = "fixture.extension",
        .extension_name = "Fixture",
        .canvas_id = "large",
        .display_name = "Large",
        .description = "1234567890",
    };
    state.limits.max_registry_bytes = 8;
    try std.testing.expectError(
        error.AggregateLimitExceeded,
        state.applyRegistry(.{ .replacement = &.{large} }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.registryCount());
    try std.testing.expectEqual(
        Degradation.limit_exceeded,
        state.registry_degradation.?,
    );
}

test "open completion budget failure returns runtime to a terminal state" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const open = try state.beginOpen(.{ .key = fixture_key });
    state.limits.max_conversation_bytes =
        state.registry.bytes + state.instanceBytes();
    try std.testing.expectError(
        error.AggregateLimitExceeded,
        state.completeOpen(open, .{ .succeeded = .{
            .title = "This metadata exceeds the remaining budget",
        } }),
    );
    try std.testing.expectEqual(RuntimeTag.closed, state.runtimeTag(fixture_key).?);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
}

test "unavailable transition cancels superseded local work" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const open = try state.beginOpen(.{ .key = fixture_key });
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try state.applyProviderSignal(.{ .unavailable = fixture_key });
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    try std.testing.expect(!(try state.completeOpen(open, .{
        .succeeded = .{},
    })));
}

test "shutdown cancels pending work and rejects later completions" {
    var state = try fixtureState(.{});
    defer state.deinit();
    const open = try state.beginOpen(.{ .key = fixture_key });
    state.shutdown();
    state.shutdown();
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    try std.testing.expectEqual(RuntimeTag.closed, state.runtimeTag(fixture_key).?);
    try std.testing.expect(!(try state.completeOpen(open, .{
        .succeeded = .{},
    })));
    try std.testing.expectError(error.Shutdown, state.beginOpen(.{
        .key = fixture_key,
    }));
}

test "resume projection preserves omitted empty and recorded public fields only" {
    var state = try fixtureState(.{});
    defer state.deinit();
    var omitted = try state.resumeProjection(std.testing.allocator, false);
    defer omitted.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(omitted) == .omitted);

    var empty = try state.resumeProjection(std.testing.allocator, true);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.canvases.len);

    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "{\"selection\":\"src/main.zig\"}",
        .{},
    );
    defer input.deinit(std.testing.allocator);
    try state.applyProviderSignal(.{ .opened = .{
        .key = fixture_key,
        .result = .{
            .title = "Transient title",
            .url = "https://example.invalid/transient",
            .status = "ready",
        },
    } });
    try state.applyProviderSignal(.{ .recorded = .{
        .key = fixture_key,
        .title = "Recorded title",
        .input = &input,
    } });
    var projection = try state.resumeProjection(std.testing.allocator, true);
    defer projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), projection.canvases.len);
    try std.testing.expectEqualStrings(
        "Recorded title",
        projection.canvases[0].title.?,
    );
    try std.testing.expectEqualStrings(
        input.bytes,
        projection.canvases[0].input.?.bytes,
    );
    try std.testing.expect(!@hasField(ResumeCanvas, "url"));
    try std.testing.expect(!@hasField(ResumeCanvas, "status"));
    try std.testing.expect(!@hasField(ResumeCanvas, "generation"));
}

test "canonical trace fixture drives the reducer to every expected state" {
    try std.testing.expectEqual(@as(usize, 9), canonical_trace_fixture.len);
    var state = State.init(std.testing.allocator, .{});
    defer state.deinit();
    state.setCapability(.supported);
    var input = try OpenInputDocument.init(
        std.testing.allocator,
        "{\"selection\":\"src/main.zig\"}",
        .{},
    );
    defer input.deinit(std.testing.allocator);
    var result = try ActionResultDocument.init(
        std.testing.allocator,
        "{\"refreshed\":true}",
        .{},
    );
    defer result.deinit(std.testing.allocator);

    for (canonical_trace_fixture) |step| {
        switch (step.operation) {
            .registry_replacement => try state.applyRegistry(.{
                .replacement = &.{fixture_declaration},
            }),
            .open_requested => {
                _ = try state.beginOpen(.{
                    .key = fixture_key,
                    .input = &input,
                });
            },
            .open_completed => {
                const pending = state.pending.items[0];
                const generation = switch (pending.kind) {
                    .open => |value| value,
                    else => unreachable,
                };
                _ = try state.completeOpen(.{
                    .id = pending.id,
                    .generation = generation,
                }, .{ .succeeded = .{
                    .title = "Review",
                    .status = "ready",
                } });
            },
            .recorded => try state.applyProviderSignal(.{ .recorded = .{
                .key = fixture_key,
                .title = "Review",
                .input = &input,
            } }),
            .unavailable => try state.applyProviderSignal(.{
                .unavailable = fixture_key,
            }),
            .reopened_with_same_key => {
                const open = try state.beginOpen(.{
                    .key = fixture_key,
                    .input = &input,
                });
                _ = try state.completeOpen(open, .{ .succeeded = .{
                    .title = "Review",
                    .status = "ready",
                } });
            },
            .action_invoked => {
                const action = try state.beginAction(.{
                    .key = fixture_key,
                    .action_name = "refresh",
                });
                try std.testing.expect(state.completeAction(
                    action,
                    .{ .succeeded = &result },
                ));
            },
            .closed => {
                const close = try state.beginClose(.{ .key = fixture_key });
                _ = try state.completeClose(close, true);
            },
            .removed => try state.applyProviderSignal(.{
                .removed = fixture_key,
            }),
        }
        try std.testing.expectEqual(
            step.expected_runtime,
            state.runtimeTag(fixture_key),
        );
        try std.testing.expectEqual(
            step.expected_record,
            state.recordTag(fixture_key),
        );
    }
}
