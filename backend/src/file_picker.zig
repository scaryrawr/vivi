const std = @import("std");

pub const Wake = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) void,
};

pub const Limits = struct {
    max_results: u16 = 100,
    max_query_bytes: usize = 4096,
    max_catalog_paths: usize = 2_000_000,
    max_catalog_bytes: usize = 256 * 1024 * 1024,
    max_cached_bytes: usize = 384 * 1024 * 1024,
    max_single_path_bytes: usize = 32 * 1024,
    max_cached_workspaces: u8 = 3,
};

pub const Desired = struct {
    workspace: []const u8,
    query: []const u8,
};

pub const Failure = enum {
    git_unavailable,
    enumeration_failed,
    catalog_too_large,
};

pub const Results = struct {
    allocator: std.mem.Allocator,
    paths: [][]u8,
    refreshing: bool,
    truncated: bool,

    pub fn deinit(self: *Results) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

pub const Update = union(enum) {
    loading,
    results: Results,
    unavailable: Failure,

    pub fn deinit(self: *Update) void {
        switch (self.*) {
            .results => |*results| results.deinit(),
            .loading, .unavailable => {},
        }
        self.* = undefined;
    }
};

const Tags = struct {
    workspace: u64,
    query: u64,

    fn eql(left: Tags, right: Tags) bool {
        return left.workspace == right.workspace and left.query == right.query;
    }
};

const OwnedDesired = struct {
    allocator: std.mem.Allocator,
    workspace: []u8,
    query: []u8,
    tags: Tags,
    open_epoch: u64,

    fn clone(self: OwnedDesired) !OwnedDesired {
        const workspace = try self.allocator.dupe(u8, self.workspace);
        errdefer self.allocator.free(workspace);
        return .{
            .allocator = self.allocator,
            .workspace = workspace,
            .query = try self.allocator.dupe(u8, self.query),
            .tags = self.tags,
            .open_epoch = self.open_epoch,
        };
    }

    fn deinit(self: *OwnedDesired) void {
        self.allocator.free(self.workspace);
        self.allocator.free(self.query);
        self.* = undefined;
    }
};

const TaggedUpdate = struct {
    tags: Tags,
    update: Update,

    fn deinit(self: *TaggedUpdate) void {
        self.update.deinit();
        self.* = undefined;
    }
};

const PathSpan = struct {
    offset: u32,
    len: u32,
};

const Catalog = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    paths: []PathSpan,

    fn path(self: Catalog, index: usize) []const u8 {
        const span = self.paths[index];
        return self.bytes[span.offset..][0..span.len];
    }

    fn footprint(self: Catalog) usize {
        return self.bytes.len + self.paths.len * @sizeOf(PathSpan);
    }

    fn deinit(self: *Catalog) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

const CatalogBuilder = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    bytes: std.ArrayList(u8) = .empty,
    paths: std.ArrayList(PathSpan) = .empty,
    partial: std.ArrayList(u8) = .empty,

    fn deinit(self: *CatalogBuilder) void {
        self.bytes.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.partial.deinit(self.allocator);
        self.* = undefined;
    }

    fn feed(self: *CatalogBuilder, chunk: []const u8) !void {
        var remaining = chunk;
        while (std.mem.indexOfScalar(u8, remaining, 0)) |end| {
            if (self.partial.items.len + end >
                self.limits.max_single_path_bytes)
            {
                return error.CatalogTooLarge;
            }
            try self.partial.appendSlice(self.allocator, remaining[0..end]);
            try self.finishPath();
            remaining = remaining[end + 1 ..];
        }
        if (remaining.len > 0) {
            if (self.partial.items.len + remaining.len >
                self.limits.max_single_path_bytes)
            {
                return error.CatalogTooLarge;
            }
            try self.partial.appendSlice(self.allocator, remaining);
        }
    }

    fn finishPath(self: *CatalogBuilder) !void {
        defer self.partial.clearRetainingCapacity();
        const path = self.partial.items;
        if (path.len == 0 or isVcsMetadataPath(path)) return;
        const projected_bytes = self.bytes.items.len + path.len;
        const projected_path_count = self.paths.items.len + 1;
        if (path.len > self.limits.max_single_path_bytes or
            self.paths.items.len >= self.limits.max_catalog_paths or
            projected_bytes > self.limits.max_catalog_bytes or
            projected_bytes > std.math.maxInt(u32) or
            projected_path_count >
                (self.limits.max_catalog_bytes - projected_bytes) /
                    @sizeOf(PathSpan))
        {
            return error.CatalogTooLarge;
        }
        const offset: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(self.allocator, path);
        try self.paths.append(self.allocator, .{
            .offset = offset,
            .len = @intCast(path.len),
        });
    }

    fn finish(self: *CatalogBuilder) !Catalog {
        if (self.partial.items.len != 0) return error.InvalidCatalogOutput;
        const Context = struct {
            bytes: []const u8,

            fn lessThan(context: @This(), left: PathSpan, right: PathSpan) bool {
                const left_path = context.bytes[left.offset..][0..left.len];
                const right_path = context.bytes[right.offset..][0..right.len];
                return std.mem.order(u8, left_path, right_path) == .lt;
            }
        };
        std.mem.sort(
            PathSpan,
            self.paths.items,
            Context{ .bytes = self.bytes.items },
            Context.lessThan,
        );
        const bytes = try self.bytes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(bytes);
        return .{
            .allocator = self.allocator,
            .bytes = bytes,
            .paths = try self.paths.toOwnedSlice(self.allocator),
        };
    }
};

const CacheEntry = struct {
    allocator: std.mem.Allocator,
    workspace: []u8,
    catalog: Catalog,
    used: u64,

    fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.workspace);
        self.catalog.deinit();
        self.* = undefined;
    }
};

const Cache = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    entries: std.ArrayList(CacheEntry) = .empty,
    bytes: usize = 0,
    tick: u64 = 0,

    fn deinit(self: *Cache) void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn find(self: *Cache, workspace: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.workspace, workspace)) return index;
        }
        return null;
    }

    fn touch(self: *Cache, index: usize) *Catalog {
        self.tick +%= 1;
        self.entries.items[index].used = self.tick;
        return &self.entries.items[index].catalog;
    }

    fn admit(self: *Cache, workspace: []const u8, catalog: Catalog) !void {
        var owned_catalog = catalog;
        errdefer owned_catalog.deinit();
        if (self.find(workspace)) |index| {
            self.bytes -= self.entries.items[index].catalog.footprint();
            self.entries.items[index].catalog.deinit();
            self.entries.items[index].catalog = owned_catalog;
            self.bytes += owned_catalog.footprint();
            _ = self.touch(index);
        } else {
            const owned_workspace = try self.allocator.dupe(u8, workspace);
            errdefer self.allocator.free(owned_workspace);
            self.tick +%= 1;
            try self.entries.append(self.allocator, .{
                .allocator = self.allocator,
                .workspace = owned_workspace,
                .catalog = owned_catalog,
                .used = self.tick,
            });
            self.bytes += owned_catalog.footprint();
        }
        while (self.entries.items.len > self.limits.max_cached_workspaces or
            (self.bytes > self.limits.max_cached_bytes and
                self.entries.items.len > 1))
        {
            var oldest_index: usize = 0;
            for (self.entries.items[1..], 1..) |entry, index| {
                if (entry.used < self.entries.items[oldest_index].used)
                    oldest_index = index;
            }
            var removed = self.entries.orderedRemove(oldest_index);
            self.bytes -= removed.catalog.footprint();
            removed.deinit();
        }
    }
};

const Enumeration = union(enum) {
    completed: struct {
        allocator: std.mem.Allocator,
        workspace: []u8,
        workspace_generation: u64,
        catalog: Catalog,

        fn deinit(self: *@This()) void {
            self.allocator.free(self.workspace);
            self.catalog.deinit();
            self.* = undefined;
        }
    },
    failed: struct {
        allocator: std.mem.Allocator,
        workspace: []u8,
        workspace_generation: u64,
        failure: Failure,

        fn deinit(self: *@This()) void {
            self.allocator.free(self.workspace);
            self.* = undefined;
        }
    },

    fn deinit(self: *Enumeration) void {
        switch (self.*) {
            .completed => |*completed| completed.deinit(),
            .failed => |*failed| failed.deinit(),
        }
        self.* = undefined;
    }
};

const Source = *const fn (
    context: *EnumerationContext,
    builder: *CatalogBuilder,
) anyerror!void;

const EnumerationContext = struct {
    core: *Core,
    workspace: []u8,
    workspace_generation: u64,
};

const Core = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    limits: Limits,
    source: Source,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    desired: ?OwnedDesired = null,
    desired_changed: bool = false,
    latest_tags: ?Tags = null,
    next_workspace_generation: u64 = 1,
    next_query_generation: u64 = 1,
    next_open_epoch: u64 = 1,
    pending_update: ?TaggedUpdate = null,
    enumeration: ?Enumeration = null,
    active_child: ?*std.process.Child = null,
    active_child_workspace: ?[]const u8 = null,
    wake_pending: bool = false,
    stop_requested: bool = false,
    coordinator: ?std.Io.Future(void) = null,
};

pub const FilePicker = struct {
    core: *Core,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        wake: Wake,
        limits: Limits,
    ) !FilePicker {
        return openWithSource(allocator, io, wake, limits, enumerateGit);
    }

    fn openWithSource(
        allocator: std.mem.Allocator,
        io: std.Io,
        wake: Wake,
        limits: Limits,
        source: Source,
    ) !FilePicker {
        if (limits.max_results == 0 or
            limits.max_catalog_paths == 0 or
            limits.max_catalog_bytes == 0 or
            limits.max_cached_bytes < limits.max_catalog_bytes or
            limits.max_single_path_bytes == 0 or
            limits.max_cached_workspaces == 0 or
            limits.max_single_path_bytes > limits.max_catalog_bytes or
            limits.max_catalog_bytes > std.math.maxInt(u32))
        {
            return error.InvalidLimits;
        }
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);
        core.* = .{
            .allocator = allocator,
            .io = io,
            .wake = wake,
            .limits = limits,
            .source = source,
        };
        core.coordinator = try io.concurrent(runCoordinator, .{core});
        return .{ .core = core };
    }

    pub fn setDesired(self: *FilePicker, desired: ?Desired) !void {
        var workspace: ?[]u8 = null;
        var query: ?[]u8 = null;
        defer if (workspace) |bytes| self.core.allocator.free(bytes);
        defer if (query) |bytes| self.core.allocator.free(bytes);
        if (desired) |value| {
            if (value.workspace.len == 0 or
                value.query.len > self.core.limits.max_query_bytes)
            {
                return error.InvalidDesired;
            }
            workspace = try self.core.allocator.dupe(u8, value.workspace);
            query = try self.core.allocator.dupe(u8, value.query);
        }

        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);
        if (self.core.stop_requested) return error.Stopping;

        const workspace_changed = blk: {
            const current = self.core.desired orelse
                break :blk desired != null;
            const value = desired orelse break :blk true;
            break :blk !std.mem.eql(u8, current.workspace, value.workspace);
        };
        const opening = self.core.desired == null and desired != null;
        const query_changed = blk: {
            const current = self.core.desired orelse
                break :blk desired != null;
            const value = desired orelse break :blk true;
            break :blk !std.mem.eql(u8, current.query, value.query);
        };
        const current_open_epoch = if (self.core.desired) |current|
            current.open_epoch
        else
            self.core.next_open_epoch;
        if (!workspace_changed and !query_changed) return;

        if (self.core.desired) |*current| current.deinit();
        if (desired) |_| {
            if (workspace_changed) {
                self.core.next_workspace_generation +%= 1;
                if (self.core.next_workspace_generation == 0)
                    self.core.next_workspace_generation = 1;
            }
            self.core.next_query_generation +%= 1;
            if (self.core.next_query_generation == 0)
                self.core.next_query_generation = 1;
            self.core.desired = .{
                .allocator = self.core.allocator,
                .workspace = workspace.?,
                .query = query.?,
                .tags = .{
                    .workspace = self.core.next_workspace_generation,
                    .query = self.core.next_query_generation,
                },
                .open_epoch = if (opening) blk: {
                    self.core.next_open_epoch +%= 1;
                    if (self.core.next_open_epoch == 0)
                        self.core.next_open_epoch = 1;
                    break :blk self.core.next_open_epoch;
                } else current_open_epoch,
            };
            workspace = null;
            query = null;
            self.core.latest_tags = self.core.desired.?.tags;
        } else {
            self.core.desired = null;
            self.core.next_query_generation +%= 1;
            self.core.latest_tags = null;
        }
        self.core.desired_changed = true;
        if (desired) |value| {
            if (self.core.active_child) |child| {
                if (!std.mem.eql(
                    u8,
                    self.core.active_child_workspace.?,
                    value.workspace,
                )) child.kill(self.core.io);
            }
        }
        self.core.changed.signal(self.core.io);
    }

    pub fn tryTakeUpdate(self: *FilePicker) !?Update {
        try self.core.mutex.lock(self.core.io);
        defer self.core.mutex.unlock(self.core.io);
        while (self.core.pending_update) |tagged| {
            self.core.pending_update = null;
            if (self.core.latest_tags) |latest| {
                if (tagged.tags.eql(latest)) {
                    self.core.wake_pending = false;
                    return tagged.update;
                }
            }
            var stale = tagged;
            stale.deinit();
        }
        self.core.wake_pending = false;
        return null;
    }

    pub fn deinit(self: *FilePicker) void {
        self.core.mutex.lock(self.core.io) catch return;
        self.core.stop_requested = true;
        if (self.core.active_child) |child| child.kill(self.core.io);
        self.core.changed.signal(self.core.io);
        self.core.mutex.unlock(self.core.io);

        if (self.core.coordinator) |*coordinator|
            coordinator.await(self.core.io);
        if (self.core.desired) |*desired| desired.deinit();
        if (self.core.pending_update) |*update| update.deinit();
        if (self.core.enumeration) |*enumeration| enumeration.deinit();
        const allocator = self.core.allocator;
        allocator.destroy(self.core);
        self.* = undefined;
    }
};

fn publish(core: *Core, tags: Tags, update: Update) void {
    var owned = update;
    core.mutex.lock(core.io) catch {
        owned.deinit();
        return;
    };
    if (core.stop_requested or
        core.latest_tags == null or
        !tags.eql(core.latest_tags.?))
    {
        core.mutex.unlock(core.io);
        owned.deinit();
        return;
    }
    if (core.pending_update) |*previous| previous.deinit();
    core.pending_update = .{ .tags = tags, .update = owned };
    const should_wake = !core.wake_pending;
    core.wake_pending = true;
    core.mutex.unlock(core.io);
    if (should_wake) core.wake.notify(core.wake.context);
}

const DesiredChange = union(enum) {
    none,
    closed,
    desired: OwnedDesired,
    unavailable: Tags,
};

fn takeDesired(core: *Core) DesiredChange {
    core.mutex.lock(core.io) catch return .none;
    defer core.mutex.unlock(core.io);
    if (!core.desired_changed) return .none;
    const desired = core.desired orelse {
        core.desired_changed = false;
        return .closed;
    };
    const cloned = desired.clone() catch {
        core.desired_changed = false;
        return .{ .unavailable = desired.tags };
    };
    core.desired_changed = false;
    return .{ .desired = cloned };
}

fn takeEnumeration(core: *Core) ?Enumeration {
    core.mutex.lock(core.io) catch return null;
    defer core.mutex.unlock(core.io);
    const result = core.enumeration orelse return null;
    core.enumeration = null;
    return result;
}

fn shouldStop(core: *Core) bool {
    core.mutex.lock(core.io) catch return true;
    defer core.mutex.unlock(core.io);
    return core.stop_requested;
}

fn waitForWork(core: *Core) bool {
    core.mutex.lock(core.io) catch return false;
    defer core.mutex.unlock(core.io);
    while (!core.stop_requested and
        !core.desired_changed and
        core.enumeration == null)
    {
        core.changed.wait(core.io, &core.mutex) catch return false;
    }
    return !core.stop_requested;
}

fn runCoordinator(core: *Core) void {
    var cache: Cache = .{
        .allocator = core.allocator,
        .limits = core.limits,
    };
    defer cache.deinit();
    var active: ?OwnedDesired = null;
    defer if (active) |*desired| desired.deinit();
    var enumeration_worker: ?std.Io.Future(void) = null;
    var refresh_requested = false;

    while (waitForWork(core)) {
        if (takeEnumeration(core)) |value| {
            var enumeration = value;
            if (enumeration_worker) |*worker| worker.await(core.io);
            enumeration_worker = null;
            switch (enumeration) {
                .completed => |*completed| {
                    const active_matches = if (active) |desired|
                        std.mem.eql(
                            u8,
                            desired.workspace,
                            completed.workspace,
                        )
                    else
                        false;
                    if (cache.admit(
                        completed.workspace,
                        completed.catalog,
                    )) |_| {
                        if (active) |desired| {
                            if (active_matches)
                                searchAndPublish(core, &cache, desired, false);
                        }
                    } else |_| {
                        if (active) |desired| {
                            if (active_matches)
                                publish(
                                    core,
                                    desired.tags,
                                    .{ .unavailable = .enumeration_failed },
                                );
                        }
                    }
                    core.allocator.free(completed.workspace);
                    enumeration = undefined;
                },
                .failed => |*failed| {
                    if (active) |desired| {
                        if (desired.tags.workspace == failed.workspace_generation) {
                            if (cache.find(desired.workspace)) |_| {
                                searchAndPublish(core, &cache, desired, false);
                            } else {
                                publish(
                                    core,
                                    desired.tags,
                                    .{ .unavailable = failed.failure },
                                );
                            }
                        }
                    }
                    failed.deinit();
                    enumeration = undefined;
                },
            }
        }

        switch (takeDesired(core)) {
            .none => {},
            .closed => {
                if (active) |*current| current.deinit();
                active = null;
            },
            .unavailable => |tags| {
                publish(core, tags, .{ .unavailable = .enumeration_failed });
            },
            .desired => |value| {
                const was_open = active != null;
                const workspace_changed = if (active) |current|
                    !std.mem.eql(u8, current.workspace, value.workspace)
                else
                    true;
                const reopened = if (active) |current|
                    current.open_epoch != value.open_epoch
                else
                    true;
                if (active) |*current| current.deinit();
                active = value;
                if (!was_open or workspace_changed or reopened)
                    refresh_requested = true;
                if (cache.find(value.workspace)) |_| {
                    searchAndPublish(
                        core,
                        &cache,
                        value,
                        refresh_requested or enumeration_worker != null,
                    );
                } else {
                    publish(core, value.tags, .loading);
                }
            },
        }

        if (refresh_requested and enumeration_worker == null) {
            if (active) |desired| {
                const context = core.allocator.create(EnumerationContext) catch {
                    publish(core, desired.tags, .{ .unavailable = .catalog_too_large });
                    refresh_requested = false;
                    continue;
                };
                context.* = .{
                    .core = core,
                    .workspace = core.allocator.dupe(
                        u8,
                        desired.workspace,
                    ) catch {
                        core.allocator.destroy(context);
                        publish(core, desired.tags, .{ .unavailable = .catalog_too_large });
                        refresh_requested = false;
                        continue;
                    },
                    .workspace_generation = desired.tags.workspace,
                };
                enumeration_worker = core.io.concurrent(
                    runEnumerator,
                    .{context},
                ) catch {
                    core.allocator.free(context.workspace);
                    core.allocator.destroy(context);
                    publish(core, desired.tags, .{ .unavailable = .enumeration_failed });
                    refresh_requested = false;
                    continue;
                };
            }
            refresh_requested = false;
        }
    }

    core.mutex.lock(core.io) catch return;
    if (core.active_child) |child| child.kill(core.io);
    core.mutex.unlock(core.io);
    if (enumeration_worker) |*worker| worker.await(core.io);
}

fn runEnumerator(context: *EnumerationContext) void {
    defer context.core.allocator.destroy(context);
    var builder: CatalogBuilder = .{
        .allocator = context.core.allocator,
        .limits = context.core.limits,
    };
    defer builder.deinit();
    const failure: ?Failure = blk: {
        context.core.source(context, &builder) catch |err| {
            break :blk switch (err) {
                error.FileNotFound => .git_unavailable,
                error.CatalogTooLarge => .catalog_too_large,
                else => .enumeration_failed,
            };
        };
        break :blk null;
    };
    const workspace = context.workspace;
    var result: Enumeration = if (failure) |value|
        .{ .failed = .{
            .allocator = context.core.allocator,
            .workspace = workspace,
            .workspace_generation = context.workspace_generation,
            .failure = value,
        } }
    else completed: {
        const catalog = builder.finish() catch {
            break :completed .{ .failed = .{
                .allocator = context.core.allocator,
                .workspace = workspace,
                .workspace_generation = context.workspace_generation,
                .failure = .enumeration_failed,
            } };
        };
        break :completed .{ .completed = .{
            .allocator = context.core.allocator,
            .workspace = workspace,
            .workspace_generation = context.workspace_generation,
            .catalog = catalog,
        } };
    };

    context.core.mutex.lock(context.core.io) catch {
        result.deinit();
        return;
    };
    defer context.core.mutex.unlock(context.core.io);
    if (context.core.stop_requested) {
        result.deinit();
        return;
    }
    if (context.core.enumeration) |*previous| previous.deinit();
    context.core.enumeration = result;
    context.core.changed.signal(context.core.io);
}

fn enumerateGit(
    context: *EnumerationContext,
    builder: *CatalogBuilder,
) !void {
    var child = try std.process.spawn(context.core.io, .{
        .argv = &.{
            "git",
            "-C",
            context.workspace,
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    defer child.kill(context.core.io);

    try context.core.mutex.lock(context.core.io);
    const wrong_workspace = if (context.core.desired) |desired|
        !std.mem.eql(u8, desired.workspace, context.workspace)
    else
        false;
    if (context.core.stop_requested or wrong_workspace) {
        context.core.mutex.unlock(context.core.io);
        return error.Cancelled;
    }
    context.core.active_child = &child;
    context.core.active_child_workspace = context.workspace;
    context.core.mutex.unlock(context.core.io);
    var child_registered = true;
    defer if (child_registered) unregisterChild(context.core, &child);

    var reader_buffer: [64 * 1024]u8 = undefined;
    var chunk: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(
        context.core.io,
        &reader_buffer,
    );
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        try builder.feed(chunk[0..count]);
    }

    try context.core.mutex.lock(context.core.io);
    if (context.core.active_child == &child) {
        context.core.active_child = null;
        context.core.active_child_workspace = null;
    }
    child_registered = false;
    const cancelled = context.core.stop_requested or
        if (context.core.desired) |desired|
            !std.mem.eql(u8, desired.workspace, context.workspace)
        else
            false;
    context.core.mutex.unlock(context.core.io);
    if (cancelled) {
        child.kill(context.core.io);
        return error.Cancelled;
    }
    const term = try child.wait(context.core.io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn unregisterChild(core: *Core, child: *std.process.Child) void {
    core.mutex.lock(core.io) catch return;
    defer core.mutex.unlock(core.io);
    if (core.active_child == child) {
        core.active_child = null;
        core.active_child_workspace = null;
    }
}

const Candidate = struct {
    rank: u2,
    path_index: u32,
};

fn better(catalog: Catalog, left: Candidate, right: Candidate) bool {
    if (left.rank != right.rank) return left.rank < right.rank;
    return std.mem.order(
        u8,
        catalog.path(left.path_index),
        catalog.path(right.path_index),
    ) == .lt;
}

fn siftUp(catalog: Catalog, heap: []Candidate, start: usize) void {
    var index = start;
    while (index > 0) {
        const parent = (index - 1) / 2;
        if (!better(catalog, heap[parent], heap[index])) break;
        std.mem.swap(Candidate, &heap[parent], &heap[index]);
        index = parent;
    }
}

fn siftDown(catalog: Catalog, heap: []Candidate, start: usize) void {
    var index = start;
    while (true) {
        const left = index * 2 + 1;
        if (left >= heap.len) return;
        const right = left + 1;
        var worse = left;
        if (right < heap.len and better(catalog, heap[left], heap[right]))
            worse = right;
        if (!better(catalog, heap[index], heap[worse])) return;
        std.mem.swap(Candidate, &heap[index], &heap[worse]);
        index = worse;
    }
}

fn searchAndPublish(
    core: *Core,
    cache: *Cache,
    desired: OwnedDesired,
    refreshing: bool,
) void {
    const index = cache.find(desired.workspace) orelse return;
    const catalog = cache.touch(index).*;
    var matches: std.ArrayList(Candidate) = .empty;
    defer matches.deinit(core.allocator);
    matches.ensureTotalCapacity(
        core.allocator,
        core.limits.max_results,
    ) catch return;
    var total_matches: usize = 0;
    for (catalog.paths, 0..) |_, path_index| {
        if (path_index % 4096 == 0 and !tagsCurrent(core, desired.tags))
            return;
        const rank = matchRank(catalog.path(path_index), desired.query) orelse
            continue;
        total_matches += 1;
        const candidate = Candidate{
            .rank = rank,
            .path_index = @intCast(path_index),
        };
        if (matches.items.len < core.limits.max_results) {
            matches.appendAssumeCapacity(candidate);
            siftUp(catalog, matches.items, matches.items.len - 1);
        } else if (better(catalog, candidate, matches.items[0])) {
            matches.items[0] = candidate;
            siftDown(catalog, matches.items, 0);
        }
    }
    const Context = struct {
        catalog: Catalog,
        fn lessThan(context: @This(), left: Candidate, right: Candidate) bool {
            return better(context.catalog, left, right);
        }
    };
    std.mem.sort(
        Candidate,
        matches.items,
        Context{ .catalog = catalog },
        Context.lessThan,
    );
    const paths = core.allocator.alloc([]u8, matches.items.len) catch return;
    var owned_count: usize = 0;
    for (matches.items, 0..) |match, output_index| {
        paths[output_index] = core.allocator.dupe(
            u8,
            catalog.path(match.path_index),
        ) catch {
            for (paths[0..owned_count]) |path| core.allocator.free(path);
            core.allocator.free(paths);
            return;
        };
        owned_count += 1;
    }
    publish(core, desired.tags, .{ .results = .{
        .allocator = core.allocator,
        .paths = paths,
        .refreshing = refreshing,
        .truncated = total_matches > paths.len,
    } });
}

fn tagsCurrent(core: *Core, tags: Tags) bool {
    core.mutex.lock(core.io) catch return false;
    defer core.mutex.unlock(core.io);
    return !core.stop_requested and
        core.latest_tags != null and
        tags.eql(core.latest_tags.?);
}

fn matchRank(path: []const u8, query: []const u8) ?u2 {
    if (query.len == 0) return 0;
    if (asciiStartsWithIgnoreCase(path, query)) return 0;
    var component_start = true;
    for (path, 0..) |byte, index| {
        if (component_start and index + query.len <= path.len and
            std.ascii.eqlIgnoreCase(path[index .. index + query.len], query))
        {
            return 1;
        }
        component_start = byte == '/' or byte == '\\' or
            byte == '-' or byte == '_' or byte == ' ';
    }
    if (asciiContainsIgnoreCase(path, query)) return 2;
    return null;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and
        std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn asciiContainsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    for (0..value.len - needle.len + 1) |index| {
        if (std.ascii.eqlIgnoreCase(
            value[index .. index + needle.len],
            needle,
        )) return true;
    }
    return false;
}

fn isVcsMetadataPath(path: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        inline for (.{ ".git", ".hg", ".svn", ".bzr", "_darcs", "CVS" }) |name| {
            if (std.mem.eql(u8, component, name)) return true;
        }
    }
    return false;
}

test "catalog builder streams hidden files and filters VCS metadata" {
    var builder: CatalogBuilder = .{
        .allocator = std.testing.allocator,
        .limits = .{},
    };
    defer builder.deinit();
    try builder.feed(".env\x00src/ma");
    try builder.feed("in.zig\x00nested/.svn/entries\x00.gitignore\x00");
    var catalog = try builder.finish();
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 3), catalog.paths.len);
    try std.testing.expectEqualStrings(".env", catalog.path(0));
    try std.testing.expectEqualStrings(".gitignore", catalog.path(1));
    try std.testing.expectEqualStrings("src/main.zig", catalog.path(2));
}

test "catalog builder enforces single path limit across chunks" {
    var builder: CatalogBuilder = .{
        .allocator = std.testing.allocator,
        .limits = .{
            .max_single_path_bytes = 4,
            .max_catalog_bytes = 8,
            .max_cached_bytes = 8,
        },
    };
    defer builder.deinit();
    try builder.feed("123");
    try std.testing.expectError(error.CatalogTooLarge, builder.feed("45"));
}

test "catalog builder counts path spans against the byte limit" {
    var builder: CatalogBuilder = .{
        .allocator = std.testing.allocator,
        .limits = .{
            .max_catalog_bytes = @sizeOf(PathSpan),
            .max_cached_bytes = @sizeOf(PathSpan),
        },
    };
    defer builder.deinit();
    try std.testing.expectError(error.CatalogTooLarge, builder.feed("a\x00"));
}

test "match ranking favors full and component prefixes" {
    try std.testing.expectEqual(@as(?u2, 0), matchRank("src/main.zig", "src"));
    try std.testing.expectEqual(@as(?u2, 1), matchRank("src/main.zig", "main"));
    try std.testing.expectEqual(@as(?u2, 2), matchRank("src/main.zig", "ain"));
    try std.testing.expect(matchRank("src/main.zig", "missing") == null);
}

test "picker publishes only the latest bounded query results" {
    const Fixture = struct {
        fn enumerate(
            _: *EnumerationContext,
            builder: *CatalogBuilder,
        ) !void {
            try builder.feed(
                ".hidden\x00README.md\x00src/main.zig\x00src/markdown.zig\x00",
            );
        }

        fn wake(_: *anyopaque) void {}
    };

    var picker = try FilePicker.openWithSource(
        std.testing.allocator,
        std.testing.io,
        .{ .context = undefined, .notify = Fixture.wake },
        .{
            .max_results = 1,
            .max_catalog_bytes = 1024,
            .max_cached_bytes = 1024,
            .max_single_path_bytes = 256,
        },
        Fixture.enumerate,
    );
    defer picker.deinit();

    try picker.setDesired(.{ .workspace = "/repo", .query = "src" });
    try picker.setDesired(.{ .workspace = "/repo", .query = "markdown" });
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (try picker.tryTakeUpdate()) |value| {
            var update = value;
            defer update.deinit();
            switch (update) {
                .results => |results| {
                    try std.testing.expectEqual(@as(usize, 1), results.paths.len);
                    try std.testing.expectEqualStrings(
                        "src/markdown.zig",
                        results.paths[0],
                    );
                    return;
                },
                .loading, .unavailable => {},
            }
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

test "reopening serves cached results while refresh runs" {
    const Fixture = struct {
        calls: std.atomic.Value(usize) = .init(0),

        fn enumerate(
            context: *EnumerationContext,
            builder: *CatalogBuilder,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context.core.wake.context));
            const call = self.calls.fetchAdd(1, .monotonic);
            if (call > 0)
                try context.core.io.sleep(.fromMilliseconds(50), .awake);
            try builder.feed("README.md\x00src/main.zig\x00");
        }

        fn wake(_: *anyopaque) void {}
    };

    var fixture: Fixture = .{};
    var picker = try FilePicker.openWithSource(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &fixture, .notify = Fixture.wake },
        .{
            .max_results = 10,
            .max_catalog_bytes = 1024,
            .max_cached_bytes = 1024,
            .max_single_path_bytes = 256,
        },
        Fixture.enumerate,
    );
    defer picker.deinit();

    try picker.setDesired(.{ .workspace = "/repo", .query = "README" });
    var first_ready = false;
    while (!first_ready) {
        if (try picker.tryTakeUpdate()) |value| {
            var update = value;
            defer update.deinit();
            switch (update) {
                .results => first_ready = true,
                .loading, .unavailable => {},
            }
        } else {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    try picker.setDesired(null);
    try picker.setDesired(.{ .workspace = "/repo", .query = "main" });
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (try picker.tryTakeUpdate()) |value| {
            var update = value;
            defer update.deinit();
            switch (update) {
                .results => |results| {
                    try std.testing.expect(results.refreshing);
                    try std.testing.expectEqualStrings(
                        "src/main.zig",
                        results.paths[0],
                    );
                    try std.testing.expect(
                        fixture.calls.load(.monotonic) >= 2,
                    );
                    return;
                },
                .loading, .unavailable => {},
            }
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}

test "closing during enumeration still admits a reusable catalog" {
    const Fixture = struct {
        calls: std.atomic.Value(usize) = .init(0),

        fn enumerate(
            context: *EnumerationContext,
            builder: *CatalogBuilder,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(context.core.wake.context));
            _ = self.calls.fetchAdd(1, .monotonic);
            try context.core.io.sleep(.fromMilliseconds(20), .awake);
            try builder.feed("README.md\x00src/main.zig\x00");
        }

        fn wake(_: *anyopaque) void {}
    };

    var fixture: Fixture = .{};
    var picker = try FilePicker.openWithSource(
        std.testing.allocator,
        std.testing.io,
        .{ .context = &fixture, .notify = Fixture.wake },
        .{
            .max_results = 10,
            .max_catalog_bytes = 1024,
            .max_cached_bytes = 1024,
            .max_single_path_bytes = 256,
        },
        Fixture.enumerate,
    );
    defer picker.deinit();

    try picker.setDesired(.{ .workspace = "/repo", .query = "README" });
    try std.testing.io.sleep(.fromMilliseconds(2), .awake);
    try picker.setDesired(null);
    try picker.setDesired(.{ .workspace = "/repo", .query = "main" });

    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (try picker.tryTakeUpdate()) |value| {
            var update = value;
            defer update.deinit();
            switch (update) {
                .results => |results| {
                    try std.testing.expectEqualStrings(
                        "src/main.zig",
                        results.paths[0],
                    );
                    try std.testing.expect(
                        fixture.calls.load(.monotonic) >= 1,
                    );
                    return;
                },
                .loading, .unavailable => {},
            }
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TestUnexpectedResult;
}
