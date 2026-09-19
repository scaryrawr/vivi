const std = @import("std");

pub const max_argument_bytes = 64 * 1024;

pub const Generation = enum(u64) {
    _,

    pub fn init(raw: u64) !Generation {
        if (raw == 0) return error.InvalidCommandGeneration;
        return @enumFromInt(raw);
    }

    pub fn value(self: Generation) u64 {
        return @intFromEnum(self);
    }

    fn next(self: ?Generation) !Generation {
        const current = if (self) |generation| generation.value() else 0;
        if (current == std.math.maxInt(u64)) {
            return error.CommandGenerationExhausted;
        }
        return init(current + 1);
    }
};

pub const Slot = enum(u32) {
    _,

    pub fn init(raw: u32) !Slot {
        if (raw == 0) return error.InvalidCommandSlot;
        return @enumFromInt(raw);
    }

    pub fn value(self: Slot) u32 {
        return @intFromEnum(self);
    }
};

pub const CommandKey = struct {
    generation: Generation,
    slot: Slot,
};

pub const Source = enum {
    vivi,
    sdk_builtin,
    extension,
};

pub const Action = enum {
    execute,
    open_model_selection,
    start_new_session,
    open_session_history,
};

pub const ArgumentPolicy = enum {
    none,
    optional,
    required,
};

pub const Definition = struct {
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    hint: ?[]const u8 = null,
    source: Source,
    action: Action = .execute,
    argument_policy: ArgumentPolicy,
};

pub const Descriptor = struct {
    key: CommandKey,
    name: []u8,
    display_name: []u8,
    description: []u8,
    hint: ?[]u8,
    source: Source,
    action: Action,
    argument_policy: ArgumentPolicy,

    pub fn deinit(self: *Descriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.display_name);
        allocator.free(self.description);
        if (self.hint) |hint| allocator.free(hint);
        self.* = undefined;
    }

    fn clone(self: Descriptor, allocator: std.mem.Allocator) !Descriptor {
        return initDescriptor(
            allocator,
            self.key,
            .{
                .name = self.name,
                .display_name = self.display_name,
                .description = self.description,
                .hint = self.hint,
                .source = self.source,
                .action = self.action,
                .argument_policy = self.argument_policy,
            },
        );
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    commands: []Descriptor,

    pub fn deinit(self: *Catalog) void {
        for (self.commands) |*command| command.deinit(self.allocator);
        self.allocator.free(self.commands);
        self.* = undefined;
    }

    pub fn clone(self: *const Catalog, allocator: std.mem.Allocator) !Catalog {
        const commands = try allocator.alloc(Descriptor, self.commands.len);
        errdefer allocator.free(commands);
        var initialized: usize = 0;
        errdefer for (commands[0..initialized]) |*command| {
            command.deinit(allocator);
        };
        for (self.commands, 0..) |command, index| {
            commands[index] = try command.clone(allocator);
            initialized += 1;
        }
        return .{ .allocator = allocator, .commands = commands };
    }

    pub fn find(self: *const Catalog, key: CommandKey) ?*const Descriptor {
        const slot = key.slot.value();
        if (slot == 0) return null;
        const index = slot - 1;
        if (index >= self.commands.len) return null;
        const command = &self.commands[index];
        if (!std.meta.eql(command.key, key)) return null;
        return command;
    }
};

pub const Execution = struct {
    allocator: std.mem.Allocator,
    key: CommandKey,
    action: union(Action) {
        execute: struct {
            name: []u8,
            arguments: []u8,
        },
        open_model_selection,
        start_new_session,
        open_session_history,
    },

    pub fn deinit(self: *Execution) void {
        switch (self.action) {
            .execute => |value| {
                self.allocator.free(value.name);
                self.allocator.free(value.arguments);
            },
            .open_model_selection,
            .start_new_session,
            .open_session_history,
            => {},
        }
        self.* = undefined;
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    generation: ?Generation = null,
    catalog: ?Catalog = null,
    active: ?CommandKey = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        if (self.catalog) |*catalog| catalog.deinit();
        self.* = undefined;
    }

    pub fn replace(
        self: *Registry,
        definitions: []const Definition,
    ) !Catalog {
        const generation = try Generation.next(self.generation);
        var replacement = try buildCatalog(
            self.allocator,
            generation,
            definitions,
        );
        errdefer replacement.deinit();
        var event_catalog = try replacement.clone(self.allocator);
        errdefer event_catalog.deinit();

        if (self.catalog) |*catalog| catalog.deinit();
        self.catalog = replacement;
        self.generation = generation;
        return event_catalog;
    }

    pub fn replaceFailClosed(self: *Registry) !Catalog {
        return self.replace(&.{});
    }

    pub fn admit(
        self: *Registry,
        key: CommandKey,
        arguments: []const u8,
    ) !Execution {
        if (self.active != null) return error.CommandAlreadyActive;
        if (arguments.len > max_argument_bytes) {
            return error.CommandArgumentsTooLong;
        }
        if (!std.unicode.utf8ValidateSlice(arguments)) {
            return error.InvalidCommandArgumentsUtf8;
        }
        const catalog = self.catalog orelse return error.CommandCatalogUnavailable;
        if (self.generation == null or key.generation != self.generation.?) {
            return error.StaleCommandKey;
        }
        const command = catalog.find(key) orelse return error.InvalidCommandKey;
        const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
        switch (command.argument_policy) {
            .none => if (trimmed.len != 0) return error.CommandTakesNoArguments,
            .required => if (trimmed.len == 0) return error.CommandRequiresArguments,
            .optional => {},
        }

        const action: ExecutionAction = switch (command.action) {
            .execute => execute: {
                const name = try self.allocator.dupe(u8, command.name);
                errdefer self.allocator.free(name);
                const owned_arguments = try self.allocator.dupe(u8, arguments);
                break :execute .{ .execute = .{
                    .name = name,
                    .arguments = owned_arguments,
                } };
            },
            .open_model_selection => .open_model_selection,
            .start_new_session => .start_new_session,
            .open_session_history => .open_session_history,
        };
        self.active = key;
        return .{
            .allocator = self.allocator,
            .key = key,
            .action = action,
        };
    }

    pub fn finish(self: *Registry, key: CommandKey) !void {
        const active = self.active orelse return error.NoActiveCommand;
        if (!std.meta.eql(active, key)) return error.MismatchedCommandCompletion;
        self.active = null;
    }
};

const ExecutionAction = @FieldType(Execution, "action");

fn buildCatalog(
    allocator: std.mem.Allocator,
    generation: Generation,
    definitions: []const Definition,
) !Catalog {
    if (definitions.len > std.math.maxInt(u32) - 3) {
        return error.TooManyCommands;
    }
    const commands = try allocator.alloc(Descriptor, definitions.len + 3);
    errdefer allocator.free(commands);
    var initialized: usize = 0;
    errdefer for (commands[0..initialized]) |*command| {
        command.deinit(allocator);
    };

    commands[0] = try initDescriptor(allocator, .{
        .generation = generation,
        .slot = try Slot.init(1),
    }, .{
        .name = "model",
        .display_name = "model",
        .description = "Switch the model for new turns",
        .source = .vivi,
        .action = .open_model_selection,
        .argument_policy = .none,
    });
    initialized += 1;
    commands[1] = try initDescriptor(allocator, .{
        .generation = generation,
        .slot = try Slot.init(2),
    }, .{
        .name = "new",
        .display_name = "new",
        .description = "Start a fresh conversation in the current workspace",
        .source = .vivi,
        .action = .start_new_session,
        .argument_policy = .none,
    });
    initialized += 1;
    commands[2] = try initDescriptor(allocator, .{
        .generation = generation,
        .slot = try Slot.init(3),
    }, .{
        .name = "resume",
        .display_name = "resume",
        .description = "Resume a previous Vivi session",
        .source = .vivi,
        .action = .open_session_history,
        .argument_policy = .none,
    });
    initialized += 1;

    for (definitions, 0..) |definition, index| {
        try validateDefinition(definition);
        commands[index + 3] = try initDescriptor(allocator, .{
            .generation = generation,
            .slot = try Slot.init(@intCast(index + 4)),
        }, definition);
        initialized += 1;
    }
    return .{ .allocator = allocator, .commands = commands };
}

fn validateDefinition(definition: Definition) !void {
    if (definition.name.len == 0 or
        definition.name[0] == '/' or
        std.mem.indexOfAny(u8, definition.name, " \t\r\n") != null or
        !std.unicode.utf8ValidateSlice(definition.name) or
        !std.unicode.utf8ValidateSlice(definition.display_name) or
        !std.unicode.utf8ValidateSlice(definition.description) or
        (definition.hint != null and
            !std.unicode.utf8ValidateSlice(definition.hint.?)))
    {
        return error.InvalidCommandDefinition;
    }
    if (std.ascii.eqlIgnoreCase(definition.name, "model") or
        std.ascii.eqlIgnoreCase(definition.name, "new") or
        std.ascii.eqlIgnoreCase(definition.name, "resume"))
    {
        return error.ReservedCommandName;
    }
    switch (definition.source) {
        .vivi => return error.InvalidCommandSource,
        .sdk_builtin, .extension => {},
    }
    if (definition.action != .execute) return error.InvalidCommandAction;
    if (definition.argument_policy == .none and definition.hint != null) {
        return error.InvalidCommandArgumentPolicy;
    }
}

fn initDescriptor(
    allocator: std.mem.Allocator,
    key: CommandKey,
    definition: Definition,
) !Descriptor {
    const name = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(name);
    const display_name = try allocator.dupe(u8, definition.display_name);
    errdefer allocator.free(display_name);
    const description = try allocator.dupe(u8, definition.description);
    errdefer allocator.free(description);
    return .{
        .key = key,
        .name = name,
        .display_name = display_name,
        .description = description,
        .hint = if (definition.hint) |hint|
            try allocator.dupe(u8, hint)
        else
            null,
        .source = definition.source,
        .action = definition.action,
        .argument_policy = definition.argument_policy,
    };
}

test "catalog generations are nonzero and stale keys fail closed" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var first = try registry.replace(&.{.{
        .name = "review",
        .display_name = "Review",
        .description = "Review changes",
        .source = .extension,
        .argument_policy = .optional,
    }});
    defer first.deinit();
    const old_key = first.commands[3].key;
    try std.testing.expectEqual(@as(u64, 1), old_key.generation.value());
    try std.testing.expectEqual(@as(u32, 4), old_key.slot.value());

    var fallback = try registry.replaceFailClosed();
    defer fallback.deinit();
    try std.testing.expectEqual(@as(usize, 3), fallback.commands.len);
    try std.testing.expectEqualStrings("new", fallback.commands[1].name);
    try std.testing.expectEqual(
        Action.start_new_session,
        fallback.commands[1].action,
    );
    var new_execution = try registry.admit(fallback.commands[1].key, "");
    defer new_execution.deinit();
    try std.testing.expect(new_execution.action == .start_new_session);
    try registry.finish(new_execution.key);
    try std.testing.expectError(
        error.StaleCommandKey,
        registry.admit(old_key, ""),
    );
}

test "admission rejects a zero slot in the current generation" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.replace(&.{});
    defer catalog.deinit();
    try std.testing.expectError(
        error.InvalidCommandKey,
        registry.admit(.{
            .generation = catalog.commands[0].key.generation,
            .slot = @enumFromInt(0),
        }, ""),
    );
}

test "admission enforces source action and argument policy" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.replace(&.{
        .{
            .name = "required",
            .display_name = "Required",
            .description = "Needs input",
            .hint = "value",
            .source = .sdk_builtin,
            .argument_policy = .required,
        },
        .{
            .name = "plain",
            .display_name = "Plain",
            .description = "No input",
            .source = .extension,
            .argument_policy = .none,
        },
    });
    defer catalog.deinit();
    try std.testing.expectError(
        error.CommandRequiresArguments,
        registry.admit(catalog.commands[3].key, ""),
    );
    try std.testing.expectError(
        error.CommandTakesNoArguments,
        registry.admit(catalog.commands[4].key, "extra"),
    );
    var execution = try registry.admit(catalog.commands[3].key, " value ");
    defer execution.deinit();
    try std.testing.expectEqualStrings("required", execution.action.execute.name);
    try std.testing.expectEqualStrings(" value ", execution.action.execute.arguments);
    try registry.finish(execution.key);
    try std.testing.expectError(
        error.NoActiveCommand,
        registry.finish(execution.key),
    );
}

test "reserved collisions and invalid matrices are rejected atomically" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var initial = try registry.replace(&.{});
    defer initial.deinit();
    try std.testing.expectError(error.ReservedCommandName, registry.replace(&.{.{
        .name = "MODEL",
        .display_name = "model",
        .description = "collision",
        .source = .sdk_builtin,
        .argument_policy = .none,
    }}));
    try std.testing.expectError(error.InvalidCommandSource, registry.replace(&.{.{
        .name = "local",
        .display_name = "local",
        .description = "invalid",
        .source = .vivi,
        .argument_policy = .none,
    }}));
    var execution = try registry.admit(initial.commands[0].key, "");
    defer execution.deinit();
    try std.testing.expect(execution.action == .open_model_selection);
    try registry.finish(execution.key);
}

test "admission cleans up the command name when argument allocation fails" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.replace(&.{.{
        .name = "review",
        .display_name = "Review",
        .description = "Review changes",
        .source = .extension,
        .argument_policy = .optional,
    }});
    defer catalog.deinit();

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    registry.allocator = failing.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        registry.admit(catalog.commands[3].key, "arguments"),
    );
    registry.allocator = std.testing.allocator;
    try std.testing.expect(registry.active == null);
}
