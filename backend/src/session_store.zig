const std = @import("std");
const builtin = @import("builtin");
const ReasoningEffort = @import("reasoning.zig").Effort;
const session_title = @import("session_title.zig");

pub const version: u32 = 4;
pub const max_records_per_shard: usize = 200;
const legacy_max_title_bytes: usize = 512;
const max_record_text_bytes =
    512 + std.Io.Dir.max_path_bytes + 512 + 512;
const max_json_expansion = 6;
const max_serialized_record_bytes =
    max_record_text_bytes * max_json_expansion + 256;
const max_shard_bytes =
    max_records_per_shard * max_serialized_record_bytes + 1024;
const writer_id_bytes: usize = 16;
const writer_id_hex_len: usize = writer_id_bytes * 2;
const lock_filename = ".lock";
const private_file_permissions: std.Io.File.Permissions =
    if (builtin.os.tag == .windows)
        .default_file
    else
        .fromMode(0o600);
const private_directory_permissions: std.Io.Dir.Permissions =
    if (builtin.os.tag == .windows)
        .default_dir
    else
        .fromMode(0o700);

pub const Record = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    working_directory: []u8,
    model_id: []u8,
    title: ?[]u8,
    reasoning: ReasoningEffort,
    last_used_unix_ms: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        working_directory: []const u8,
        model_id: []const u8,
        reasoning: ReasoningEffort,
        last_used_unix_ms: i64,
    ) !Record {
        return initWithTitle(
            allocator,
            id,
            working_directory,
            model_id,
            null,
            reasoning,
            last_used_unix_ms,
        );
    }

    pub fn initWithTitle(
        allocator: std.mem.Allocator,
        id: []const u8,
        working_directory: []const u8,
        model_id: []const u8,
        title: ?[]const u8,
        reasoning: ReasoningEffort,
        last_used_unix_ms: i64,
    ) !Record {
        try validateText(id, 512);
        try validateWorkingDirectory(working_directory);
        try validateText(model_id, 512);
        if (title) |value| if (!session_title.isCanonical(value))
            return error.InvalidSessionText;
        if (last_used_unix_ms < 0) return error.InvalidSessionTimestamp;

        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_working_directory = try allocator.dupe(
            u8,
            working_directory,
        );
        errdefer allocator.free(owned_working_directory);
        const owned_model_id = try allocator.dupe(u8, model_id);
        errdefer allocator.free(owned_model_id);
        return .{
            .allocator = allocator,
            .id = owned_id,
            .working_directory = owned_working_directory,
            .model_id = owned_model_id,
            .title = if (title) |value|
                try allocator.dupe(u8, value)
            else
                null,
            .reasoning = reasoning,
            .last_used_unix_ms = last_used_unix_ms,
        };
    }

    pub fn clone(
        self: *const Record,
        allocator: std.mem.Allocator,
    ) !Record {
        return initWithTitle(
            allocator,
            self.id,
            self.working_directory,
            self.model_id,
            self.title,
            self.reasoning,
            self.last_used_unix_ms,
        );
    }

    pub fn deinit(self: *Record) void {
        self.allocator.free(self.id);
        self.allocator.free(self.working_directory);
        self.allocator.free(self.model_id);
        if (self.title) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    records: []Record,
    skipped_invalid_shards: bool = false,

    pub fn deinit(self: *Index) void {
        for (self.records) |*record| record.deinit();
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

const DocumentRecordV1 = struct {
    id: []const u8,
    working_directory: []const u8,
    model_id: []const u8,
    last_used_unix_ms: i64,
};

const DocumentV1 = struct {
    version: u32,
    writer_id: []const u8,
    sessions: []const DocumentRecordV1,
};

const DocumentRecordV2 = struct {
    id: []const u8,
    working_directory: []const u8,
    model_id: []const u8,
    reasoning: ReasoningEffort,
    last_used_unix_ms: i64,
};

const DocumentV2 = struct {
    version: u32,
    writer_id: []const u8,
    sessions: []const DocumentRecordV2,
};

const DocumentRecordV3 = struct {
    id: []const u8,
    working_directory: []const u8,
    model_id: []const u8,
    title: ?[]const u8 = null,
    reasoning: ReasoningEffort,
    last_used_unix_ms: i64,
};

const DocumentV3 = struct {
    version: u32,
    writer_id: []const u8,
    sessions: []const DocumentRecordV3,
};

const DocumentRecordV4 = struct {
    id: []const u8,
    working_directory: []const u8,
    model_id: []const u8,
    title: ?[]const u8 = null,
    reasoning: ReasoningEffort,
    last_used_unix_ms: i64,
};

const DocumentV4 = struct {
    version: u32,
    writer_id: []const u8,
    sessions: []const DocumentRecordV4,
};

const VersionHeader = struct {
    version: u32,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []u8,
    writer_id: [writer_id_hex_len]u8,
    shard_path: []u8,
    lock_path: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: []const u8,
    ) !Store {
        var random_bytes: [writer_id_bytes]u8 = undefined;
        std.Io.randomSecure(io, &random_bytes) catch
            std.Io.random(io, &random_bytes);
        return initWithWriterId(
            allocator,
            io,
            directory,
            std.fmt.bytesToHex(random_bytes, .lower),
        );
    }

    fn initWithWriterId(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: []const u8,
        writer_id: [writer_id_hex_len]u8,
    ) !Store {
        const owned_directory = try allocator.dupe(u8, directory);
        errdefer allocator.free(owned_directory);
        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}.json",
            .{writer_id},
        );
        defer allocator.free(filename);
        const shard_path = try std.fs.path.join(
            allocator,
            &.{ directory, filename },
        );
        errdefer allocator.free(shard_path);
        const lock_path = try std.fs.path.join(
            allocator,
            &.{ directory, lock_filename },
        );
        return .{
            .allocator = allocator,
            .io = io,
            .directory = owned_directory,
            .writer_id = writer_id,
            .shard_path = shard_path,
            .lock_path = lock_path,
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.shard_path);
        self.allocator.free(self.lock_path);
        self.* = undefined;
    }

    pub fn recordCreated(
        self: *Store,
        id: []const u8,
        working_directory: []const u8,
        model_id: []const u8,
        reasoning: ReasoningEffort,
        now_unix_ms: i64,
    ) !void {
        var record = try Record.init(
            self.allocator,
            id,
            working_directory,
            model_id,
            reasoning,
            now_unix_ms,
        );
        defer record.deinit();
        try self.upsert(&record);
    }

    pub fn touch(self: *Store, record: *const Record, now_unix_ms: i64) !void {
        var touched = try Record.initWithTitle(
            self.allocator,
            record.id,
            record.working_directory,
            record.model_id,
            record.title,
            record.reasoning,
            now_unix_ms,
        );
        defer touched.deinit();
        try self.upsert(&touched);
    }

    pub fn updateTitle(
        self: *Store,
        id: []const u8,
        title: []const u8,
    ) !void {
        if (!session_title.isCanonical(title)) return error.InvalidSessionText;
        const lock = try self.acquireLock();
        defer lock.close(self.io);

        var index = try self.loadMerged();
        defer index.deinit();
        for (index.records) |*record| {
            if (!std.mem.eql(u8, record.id, id)) continue;
            const owned_title = try self.allocator.dupe(u8, title);
            if (record.title) |value| self.allocator.free(value);
            record.title = owned_title;
            try self.compact(index.records);
            return;
        }
        return error.SessionNotFound;
    }

    pub fn list(self: *Store) !Index {
        const lock = try self.acquireLock();
        defer lock.close(self.io);

        var index = try self.loadMerged();
        errdefer index.deinit();
        try self.compact(index.records);
        return index;
    }

    fn loadMerged(self: *Store) !Index {
        var merged: std.ArrayList(Record) = .empty;
        errdefer {
            for (merged.items) |*record| record.deinit();
            merged.deinit(self.allocator);
        }

        var directory = std.Io.Dir.openDirAbsolute(
            self.io,
            self.directory,
            .{ .iterate = true },
        ) catch |err| switch (err) {
            error.FileNotFound => return .{
                .allocator = self.allocator,
                .records = try self.allocator.alloc(Record, 0),
            },
            else => return err,
        };
        defer directory.close(self.io);

        var skipped_invalid = false;
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json") or
                !try isRegularFile(
                    directory,
                    self.io,
                    entry.name,
                    entry.kind,
                ))
            {
                continue;
            }
            const content = directory.readFileAlloc(
                self.io,
                entry.name,
                self.allocator,
                .limited(max_shard_bytes),
            ) catch |err| switch (err) {
                error.StreamTooLong => return error.SessionShardTooLarge,
                else => return err,
            };
            defer self.allocator.free(content);
            var header = std.json.parseFromSlice(
                VersionHeader,
                self.allocator,
                content,
                .{ .ignore_unknown_fields = true },
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    skipped_invalid = true;
                    continue;
                },
            };
            defer header.deinit();
            switch (header.value.version) {
                1 => {
                    var parsed = std.json.parseFromSlice(
                        DocumentV1,
                        self.allocator,
                        content,
                        .{ .ignore_unknown_fields = true },
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            skipped_invalid = true;
                            continue;
                        },
                    };
                    defer parsed.deinit();
                    if (!validDocument(entry.name, parsed.value)) {
                        skipped_invalid = true;
                        continue;
                    }
                    for (parsed.value.sessions) |stored| {
                        var record = Record.init(
                            self.allocator,
                            stored.id,
                            stored.working_directory,
                            stored.model_id,
                            .off,
                            stored.last_used_unix_ms,
                        ) catch |err| switch (err) {
                            error.InvalidSessionText,
                            error.InvalidSessionTimestamp,
                            => {
                                skipped_invalid = true;
                                continue;
                            },
                            else => return err,
                        };
                        errdefer record.deinit();
                        try mergeRecord(self.allocator, &merged, record);
                        trimRecords(&merged);
                    }
                },
                2 => {
                    var parsed = std.json.parseFromSlice(
                        DocumentV2,
                        self.allocator,
                        content,
                        .{ .ignore_unknown_fields = true },
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            skipped_invalid = true;
                            continue;
                        },
                    };
                    defer parsed.deinit();
                    if (!validDocument(entry.name, parsed.value)) {
                        skipped_invalid = true;
                        continue;
                    }
                    for (parsed.value.sessions) |stored| {
                        var record = Record.init(
                            self.allocator,
                            stored.id,
                            stored.working_directory,
                            stored.model_id,
                            stored.reasoning,
                            stored.last_used_unix_ms,
                        ) catch |err| switch (err) {
                            error.InvalidSessionText,
                            error.InvalidSessionTimestamp,
                            => {
                                skipped_invalid = true;
                                continue;
                            },
                            else => return err,
                        };
                        errdefer record.deinit();
                        try mergeRecord(self.allocator, &merged, record);
                        trimRecords(&merged);
                    }
                },
                3 => {
                    var parsed = std.json.parseFromSlice(
                        DocumentV3,
                        self.allocator,
                        content,
                        .{},
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            skipped_invalid = true;
                            continue;
                        },
                    };
                    defer parsed.deinit();
                    if (!validDocument(entry.name, parsed.value)) {
                        skipped_invalid = true;
                        continue;
                    }
                    for (parsed.value.sessions) |stored| {
                        if (stored.title) |title| {
                            if (title.len > legacy_max_title_bytes) {
                                skipped_invalid = true;
                                continue;
                            }
                        }
                        const canonical_title = if (stored.title) |title|
                            try session_title.canonicalize(self.allocator, title)
                        else
                            null;
                        defer if (canonical_title) |title| {
                            self.allocator.free(title);
                        };
                        var record = Record.initWithTitle(
                            self.allocator,
                            stored.id,
                            stored.working_directory,
                            stored.model_id,
                            canonical_title,
                            stored.reasoning,
                            stored.last_used_unix_ms,
                        ) catch |err| switch (err) {
                            error.InvalidSessionText,
                            error.InvalidSessionTimestamp,
                            => {
                                skipped_invalid = true;
                                continue;
                            },
                            else => return err,
                        };
                        errdefer record.deinit();
                        try mergeRecord(self.allocator, &merged, record);
                        trimRecords(&merged);
                    }
                },
                4 => {
                    var parsed = std.json.parseFromSlice(
                        DocumentV4,
                        self.allocator,
                        content,
                        .{},
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            skipped_invalid = true;
                            continue;
                        },
                    };
                    defer parsed.deinit();
                    if (!validDocument(entry.name, parsed.value)) {
                        skipped_invalid = true;
                        continue;
                    }
                    for (parsed.value.sessions) |stored| {
                        var record = Record.initWithTitle(
                            self.allocator,
                            stored.id,
                            stored.working_directory,
                            stored.model_id,
                            stored.title,
                            stored.reasoning,
                            stored.last_used_unix_ms,
                        ) catch |err| switch (err) {
                            error.InvalidSessionText,
                            error.InvalidSessionTimestamp,
                            => {
                                skipped_invalid = true;
                                continue;
                            },
                            else => return err,
                        };
                        errdefer record.deinit();
                        try mergeRecord(self.allocator, &merged, record);
                        trimRecords(&merged);
                    }
                },
                else => return error.UnsupportedSessionShardVersion,
            }
        }

        sortRecords(merged.items);
        while (merged.items.len > max_records_per_shard) {
            var removed = merged.pop().?;
            removed.deinit();
        }
        return .{
            .allocator = self.allocator,
            .records = try merged.toOwnedSlice(self.allocator),
            .skipped_invalid_shards = skipped_invalid,
        };
    }

    fn upsert(self: *Store, record: *const Record) !void {
        const lock = try self.acquireLock();
        defer lock.close(self.io);

        var index = try self.loadMerged();
        defer index.deinit();
        var replacement = try record.clone(self.allocator);
        var replacement_moved = false;
        errdefer if (!replacement_moved) replacement.deinit();
        var records = std.ArrayList(Record).fromOwnedSlice(index.records);
        index.records = &.{};
        defer {
            for (records.items) |*value| value.deinit();
            records.deinit(self.allocator);
        }
        try mergeRecord(self.allocator, &records, replacement);
        replacement_moved = true;
        trimRecords(&records);
        try self.compact(records.items);
    }

    fn acquireLock(self: *Store) !std.Io.File {
        _ = try std.Io.Dir.cwd().createDirPathStatus(
            self.io,
            self.directory,
            private_directory_permissions,
        );
        if (builtin.os.tag != .windows) {
            var directory = try std.Io.Dir.openDirAbsolute(
                self.io,
                self.directory,
                .{ .iterate = true },
            );
            defer directory.close(self.io);
            try directory.setPermissions(
                self.io,
                private_directory_permissions,
            );
        }
        const lock = try std.Io.Dir.createFileAbsolute(
            self.io,
            self.lock_path,
            .{
                .truncate = false,
                .lock = .exclusive,
                .permissions = private_file_permissions,
            },
        );
        errdefer lock.close(self.io);
        if (builtin.os.tag != .windows) {
            try lock.setPermissions(self.io, private_file_permissions);
        }
        return lock;
    }

    fn compact(self: *Store, records: []const Record) !void {
        try self.save(records);
        self.removeSiblingShards() catch {};
    }

    fn removeSiblingShards(self: *Store) !void {
        var directory = try std.Io.Dir.openDirAbsolute(
            self.io,
            self.directory,
            .{ .iterate = true },
        );
        defer directory.close(self.io);
        const own_filename = std.fs.path.basename(self.shard_path);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json") or
                std.mem.eql(u8, entry.name, own_filename) or
                !try isRegularFile(
                    directory,
                    self.io,
                    entry.name,
                    entry.kind,
                ))
            {
                continue;
            }
            directory.deleteFile(self.io, entry.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    fn save(self: *Store, records: []const Record) !void {
        var document_records = try self.allocator.alloc(
            DocumentRecordV4,
            records.len,
        );
        defer self.allocator.free(document_records);
        for (records, 0..) |record, index| {
            document_records[index] = .{
                .id = record.id,
                .working_directory = record.working_directory,
                .model_id = record.model_id,
                .title = record.title,
                .reasoning = record.reasoning,
                .last_used_unix_ms = record.last_used_unix_ms,
            };
        }
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            DocumentV4{
                .version = version,
                .writer_id = &self.writer_id,
                .sessions = document_records,
            },
            .{ .whitespace = .indent_2 },
        );
        defer self.allocator.free(encoded);

        var atomic_file = try std.Io.Dir.cwd().createFileAtomic(
            self.io,
            self.shard_path,
            .{
                .permissions = private_file_permissions,
                .make_path = true,
                .replace = true,
            },
        );
        defer atomic_file.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic_file.file.writer(self.io, &buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        try writer.flush();
        try atomic_file.file.sync(self.io);
        try atomic_file.replace(self.io);
    }
};

fn isRegularFile(
    directory: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    kind: std.Io.File.Kind,
) !bool {
    const resolved_kind = if (kind == .unknown)
        (try directory.statFile(
            io,
            name,
            .{ .follow_symlinks = false },
        )).kind
    else
        kind;
    return resolved_kind == .file;
}

fn validateText(value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > maximum or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.indexOfScalar(u8, value, 0) != null or
        std.mem.trim(u8, value, " \t\r\n").len != value.len)
    {
        return error.InvalidSessionText;
    }
}

fn validateWorkingDirectory(value: []const u8) !void {
    if (value.len == 0 or value.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return error.InvalidSessionText;
    }
}

fn validDocument(filename: []const u8, document: anytype) bool {
    if (document.writer_id.len != writer_id_hex_len or
        document.sessions.len > max_records_per_shard)
    {
        return false;
    }
    for (document.writer_id) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return filename.len == writer_id_hex_len + ".json".len and
        std.mem.eql(
            u8,
            filename[0..writer_id_hex_len],
            document.writer_id,
        );
}

fn mergeRecord(
    allocator: std.mem.Allocator,
    records: *std.ArrayList(Record),
    candidate: Record,
) !void {
    for (records.items) |*record| {
        if (!std.mem.eql(u8, record.id, candidate.id)) continue;
        if (candidate.last_used_unix_ms > record.last_used_unix_ms or
            (candidate.last_used_unix_ms == record.last_used_unix_ms and
                record.title == null and candidate.title != null))
        {
            var replacement = candidate;
            if (replacement.title == null) {
                replacement.title = if (record.title) |title|
                    try allocator.dupe(u8, title)
                else
                    null;
            }
            record.deinit();
            record.* = replacement;
        } else {
            var discarded = candidate;
            if (record.title == null and discarded.title != null) {
                record.title = discarded.title;
                discarded.title = null;
            }
            discarded.deinit();
        }
        return;
    }
    try records.append(allocator, candidate);
}

fn sortRecords(records: []Record) void {
    std.mem.sort(Record, records, {}, struct {
        fn lessThan(_: void, left: Record, right: Record) bool {
            if (left.last_used_unix_ms != right.last_used_unix_ms) {
                return left.last_used_unix_ms > right.last_used_unix_ms;
            }
            return std.mem.order(u8, left.id, right.id) == .lt;
        }
    }.lessThan);
}

fn trimRecords(records: *std.ArrayList(Record)) void {
    sortRecords(records.items);
    while (records.items.len > max_records_per_shard) {
        var removed = records.pop().?;
        removed.deinit();
    }
}

test "session store merges shards and keeps newest record" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);

    var first = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'1'} ** writer_id_hex_len,
    );
    defer first.deinit();
    var second = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'2'} ** writer_id_hex_len,
    );
    defer second.deinit();

    try first.recordCreated("session-a", "/work/a", "copilot/default", .off, 10);
    try second.recordCreated("session-b", "/work/b", "copilot/model", .high, 20);
    var first_index = try first.list();
    defer first_index.deinit();
    const session_a = for (first_index.records) |*record| {
        if (std.mem.eql(u8, record.id, "session-a")) break record;
    } else return error.MissingSession;
    try second.touch(session_a, 30);

    var merged = try first.list();
    defer merged.deinit();
    try std.testing.expectEqual(@as(usize, 2), merged.records.len);
    try std.testing.expectEqualStrings("session-a", merged.records[0].id);
    try std.testing.expectEqual(@as(i64, 30), merged.records[0].last_used_unix_ms);

    var sessions = try temporary.dir.openDir(
        std.testing.io,
        "sessions",
        .{ .iterate = true },
    );
    defer sessions.close(std.testing.io);
    var shard_count: usize = 0;
    var iterator = sessions.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file and
            std.mem.endsWith(u8, entry.name, ".json"))
        {
            shard_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), shard_count);
}

test "session store resolves unknown directory entry kinds" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "shard.json",
        .data = "",
    });
    try temporary.dir.createDir(std.testing.io, "directory.json", .default_dir);

    try std.testing.expect(try isRegularFile(
        temporary.dir,
        std.testing.io,
        "shard.json",
        .unknown,
    ));
    try std.testing.expect(!try isRegularFile(
        temporary.dir,
        std.testing.io,
        "directory.json",
        .unknown,
    ));
}

test "session store skips corrupt sibling shards" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'a'} ** writer_id_hex_len,
    );
    defer store.deinit();
    try store.recordCreated("session-a", "/work/a", "copilot/default", .off, 10);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        .data = "not json",
    });

    var index = try store.list();
    defer index.deinit();
    try std.testing.expect(index.skipped_invalid_shards);
    try std.testing.expectEqual(@as(usize, 1), index.records.len);
}

test "session store migrates version one shards with reasoning off" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        .data =
        \\{
        \\  "version": 1,
        \\  "writer_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "sessions": [{
        \\    "id": "session-a",
        \\    "working_directory": "/work/a",
        \\    "model_id": "copilot/model-a",
        \\    "last_used_unix_ms": 10
        \\  }]
        \\}
        ,
    });
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'b'} ** writer_id_hex_len,
    );
    defer store.deinit();

    var migrated = try store.list();
    defer migrated.deinit();
    try std.testing.expectEqual(@as(usize, 1), migrated.records.len);
    try std.testing.expectEqual(
        ReasoningEffort.off,
        migrated.records[0].reasoning,
    );

    try store.touch(&migrated.records[0], 20);
    const content = try temporary.dir.readFileAlloc(
        std.testing.io,
        "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        std.testing.allocator,
        .limited(max_shard_bytes),
    );
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "\"version\": 4",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "\"reasoning\": \"off\"",
    ) != null);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(
            std.testing.io,
            "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
            .{},
        ),
    );
}

test "session store migrates version two shards without titles" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        .data =
        \\{
        \\  "version": 2,
        \\  "writer_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "sessions": [{
        \\    "id": "session-a",
        \\    "working_directory": "/work/a",
        \\    "model_id": "copilot/model-a",
        \\    "reasoning": "medium",
        \\    "last_used_unix_ms": 10
        \\  }]
        \\}
        ,
    });
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'b'} ** writer_id_hex_len,
    );
    defer store.deinit();

    var migrated = try store.list();
    defer migrated.deinit();
    try std.testing.expectEqual(@as(usize, 1), migrated.records.len);
    try std.testing.expectEqual(
        ReasoningEffort.medium,
        migrated.records[0].reasoning,
    );
    try std.testing.expectEqual(null, migrated.records[0].title);
}

test "session store canonicalizes version three titles on compaction" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        .data =
        \\{
        \\  "version": 3,
        \\  "writer_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "sessions": [{
        \\    "id": "session-a",
        \\    "working_directory": "/work/a",
        \\    "model_id": "copilot/model-a",
        \\    "title": "  Legacy\n title   with\u0001 controls  ",
        \\    "reasoning": "medium",
        \\    "last_used_unix_ms": 10
        \\  }]
        \\}
        ,
    });
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'b'} ** writer_id_hex_len,
    );
    defer store.deinit();

    var migrated = try store.list();
    defer migrated.deinit();
    try std.testing.expectEqual(@as(usize, 1), migrated.records.len);
    try std.testing.expectEqualStrings(
        "Legacy title with controls",
        migrated.records[0].title.?,
    );

    const content = try temporary.dir.readFileAlloc(
        std.testing.io,
        "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        std.testing.allocator,
        .limited(max_shard_bytes),
    );
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "\"version\": 4",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "\"title\": \"Legacy title with controls\"",
    ) != null);
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(
            std.testing.io,
            "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
            .{},
        ),
    );
}

test "session store migrates maximum length version three title" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    const legacy_title = [_]u8{'x'} ** legacy_max_title_bytes;
    const records = [_]DocumentRecordV3{.{
        .id = "session-a",
        .working_directory = "/work/a",
        .model_id = "copilot/model-a",
        .title = &legacy_title,
        .reasoning = .medium,
        .last_used_unix_ms = 10,
    }};
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        DocumentV3{
            .version = 3,
            .writer_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .sessions = &records,
        },
        .{ .whitespace = .indent_2 },
    );
    defer std.testing.allocator.free(encoded);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        .data = encoded,
    });
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'b'} ** writer_id_hex_len,
    );
    defer store.deinit();

    var migrated = try store.list();
    defer migrated.deinit();
    try std.testing.expectEqual(@as(usize, 1), migrated.records.len);
    const title = migrated.records[0].title.?;
    try std.testing.expect(session_title.isCanonical(title));
    try std.testing.expectEqual(
        session_title.max_characters,
        std.unicode.utf8CountCodepoints(title) catch unreachable,
    );
    try std.testing.expect(std.mem.endsWith(u8, title, "…"));
}

test "session store rejects noncanonical version four titles" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        .data =
        \\{
        \\  "version": 4,
        \\  "writer_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "sessions": [{
        \\    "id": "session-a",
        \\    "working_directory": "/work/a",
        \\    "model_id": "copilot/model-a",
        \\    "title": "two  spaces",
        \\    "reasoning": "medium",
        \\    "last_used_unix_ms": 10
        \\  }]
        \\}
        ,
    });
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'b'} ** writer_id_hex_len,
    );
    defer store.deinit();

    var index = try store.list();
    defer index.deinit();
    try std.testing.expect(index.skipped_invalid_shards);
    try std.testing.expectEqual(@as(usize, 0), index.records.len);
}

test "session store persists generated titles" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'a'} ** writer_id_hex_len,
    );
    defer store.deinit();

    try store.recordCreated("session-a", "/work/a", "copilot/default", .off, 10);
    try store.updateTitle("session-a", "Fix resume picker");
    try std.testing.expectError(
        error.InvalidSessionText,
        store.updateTitle("session-a", "unsafe\x1b[2J"),
    );
    try store.recordCreated("session-a", "/work/a", "copilot/default", .off, 20);

    var index = try store.list();
    defer index.deinit();
    try std.testing.expectEqualStrings(
        "Fix resume picker",
        index.records[0].title.?,
    );
    try std.testing.expectEqual(@as(i64, 20), index.records[0].last_used_unix_ms);
    const content = try temporary.dir.readFileAlloc(
        std.testing.io,
        "sessions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        std.testing.allocator,
        .limited(max_shard_bytes),
    );
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "\"version\": 4",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        content,
        "\"title\": \"Fix resume picker\"",
    ) != null);
}

test "session store promotes a titled remote record" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'a'} ** writer_id_hex_len,
    );
    defer store.deinit();
    var remote = try Record.initWithTitle(
        std.testing.allocator,
        "session-a",
        "/work/a",
        "copilot/default",
        "Remote session",
        .off,
        10,
    );
    defer remote.deinit();

    try store.touch(&remote, 20);

    var index = try store.list();
    defer index.deinit();
    try std.testing.expectEqualStrings("Remote session", index.records[0].title.?);
}

test "session store keeps a title from an equal-timestamp shard" {
    var records: std.ArrayList(Record) = .empty;
    defer {
        for (records.items) |*record| record.deinit();
        records.deinit(std.testing.allocator);
    }
    try records.append(
        std.testing.allocator,
        try Record.init(
            std.testing.allocator,
            "session-a",
            "/work/a",
            "copilot/default",
            .off,
            10,
        ),
    );
    const titled = try Record.initWithTitle(
        std.testing.allocator,
        "session-a",
        "/work/a",
        "copilot/default",
        "Remote session",
        .off,
        10,
    );

    try mergeRecord(std.testing.allocator, &records, titled);

    try std.testing.expectEqualStrings("Remote session", records.items[0].title.?);
}

test "session store keeps a title from an older mixed-version shard" {
    var records: std.ArrayList(Record) = .empty;
    defer {
        for (records.items) |*record| record.deinit();
        records.deinit(std.testing.allocator);
    }
    try records.append(
        std.testing.allocator,
        try Record.init(
            std.testing.allocator,
            "session-a",
            "/work/a",
            "copilot/default",
            .off,
            20,
        ),
    );
    const older_titled = try Record.initWithTitle(
        std.testing.allocator,
        "session-a",
        "/work/a",
        "copilot/default",
        "Remote session",
        .off,
        10,
    );

    try mergeRecord(std.testing.allocator, &records, older_titled);

    try std.testing.expectEqual(@as(i64, 20), records.items[0].last_used_unix_ms);
    try std.testing.expectEqualStrings("Remote session", records.items[0].title.?);
}

test "session store rejects mismatched writer identity" {
    const document = DocumentV4{
        .version = version,
        .writer_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .sessions = &.{},
    };
    try std.testing.expect(!validDocument(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        document,
    ));
}

test "session store preserves unsupported version shards" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'a'} ** writer_id_hex_len,
    );
    defer store.deinit();
    try store.recordCreated("session-a", "/work/a", "copilot/default", .off, 10);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        .data =
        \\{
        \\  "version": 5
        \\}
        ,
    });

    try std.testing.expectError(
        error.UnsupportedSessionShardVersion,
        store.list(),
    );
    var future = try temporary.dir.openFile(
        std.testing.io,
        "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        .{},
    );
    future.close(std.testing.io);
}

test "session store preserves oversized shards before version inspection" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "sessions");
    const directory = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "sessions",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(directory);
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'a'} ** writer_id_hex_len,
    );
    defer store.deinit();
    try store.recordCreated("session-a", "/work/a", "copilot/default", .off, 10);

    const prefix = "{\"version\":4,\"padding\":\"";
    const suffix = "\"}";
    const content = try std.testing.allocator.alloc(u8, max_shard_bytes + 1);
    defer std.testing.allocator.free(content);
    @memcpy(content[0..prefix.len], prefix);
    @memset(content[prefix.len .. content.len - suffix.len], 'x');
    @memcpy(content[content.len - suffix.len ..], suffix);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        .data = content,
    });

    try std.testing.expectError(error.SessionShardTooLarge, store.list());
    var future = try temporary.dir.openFile(
        std.testing.io,
        "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        .{},
    );
    future.close(std.testing.io);
}

test "session store releases moved records when saving fails" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "regular-file",
        .data = "",
    });
    const regular_file = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        "regular-file",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(regular_file);
    const directory = try std.fs.path.join(
        std.testing.allocator,
        &.{ regular_file, "sessions" },
    );
    defer std.testing.allocator.free(directory);

    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'c'} ** writer_id_hex_len,
    );
    defer store.deinit();
    if (store.recordCreated(
        "session-a",
        "/work/a",
        "copilot/default",
        .off,
        10,
    )) |_| {
        return error.ExpectedSaveFailure;
    } else |_| {}
}

test "session store read cap accepts maximum serialized shard" {
    const id = [_]u8{1} ** 512;
    const working_directory =
        [_]u8{1} ** std.Io.Dir.max_path_bytes;
    const model_id = [_]u8{1} ** 512;
    const title = [_]u8{1} ** 512;
    const records = try std.testing.allocator.alloc(
        DocumentRecordV4,
        max_records_per_shard,
    );
    defer std.testing.allocator.free(records);
    for (records) |*record| {
        record.* = .{
            .id = &id,
            .working_directory = &working_directory,
            .model_id = &model_id,
            .title = &title,
            .reasoning = .medium,
            .last_used_unix_ms = std.math.maxInt(i64),
        };
    }
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        DocumentV4{
            .version = version,
            .writer_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .sessions = records,
        },
        .{ .whitespace = .indent_2 },
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len <= max_shard_bytes);
}

test "session store preserves filesystem-significant path whitespace" {
    var record = try Record.init(
        std.testing.allocator,
        "session-a",
        "/work/project \t",
        "copilot/default",
        .off,
        10,
    );
    defer record.deinit();
    try std.testing.expectEqualStrings(
        "/work/project \t",
        record.working_directory,
    );
    try std.testing.expectError(
        error.InvalidSessionText,
        Record.init(
            std.testing.allocator,
            " session-a",
            "/work/project",
            "copilot/default",
            .off,
            10,
        ),
    );
}

test "session store uses owner-only POSIX permissions" {
    if (builtin.os.tag == .windows) return;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const temporary_root = try temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(temporary_root);
    const directory = try std.fs.path.join(
        std.testing.allocator,
        &.{ temporary_root, "sessions" },
    );
    defer std.testing.allocator.free(directory);
    var store = try Store.initWithWriterId(
        std.testing.allocator,
        std.testing.io,
        directory,
        [_]u8{'a'} ** writer_id_hex_len,
    );
    defer store.deinit();
    try store.recordCreated("session-a", "/work/a", "copilot/default", .off, 10);

    var sessions = try std.Io.Dir.openDirAbsolute(
        std.testing.io,
        directory,
        .{ .iterate = true },
    );
    defer sessions.close(std.testing.io);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o700),
        (try sessions.stat(std.testing.io)).permissions.toMode() & 0o777,
    );
    var shard = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        store.shard_path,
        .{},
    );
    defer shard.close(std.testing.io);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        (try shard.stat(std.testing.io)).permissions.toMode() & 0o777,
    );
    var lock = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        store.lock_path,
        .{},
    );
    defer lock.close(std.testing.io);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        (try lock.stat(std.testing.io)).permissions.toMode() & 0o777,
    );
}
