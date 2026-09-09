const std = @import("std");

pub const version: u32 = 1;
pub const max_records_per_shard: usize = 200;
const max_record_text_bytes =
    512 + std.Io.Dir.max_path_bytes + 512;
const max_json_expansion = 6;
const max_serialized_record_bytes =
    max_record_text_bytes * max_json_expansion + 256;
const max_shard_bytes =
    max_records_per_shard * max_serialized_record_bytes + 1024;
const writer_id_bytes: usize = 16;
const writer_id_hex_len: usize = writer_id_bytes * 2;
const lock_filename = ".lock";

pub const Record = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    working_directory: []u8,
    model_id: []u8,
    last_used_unix_ms: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        working_directory: []const u8,
        model_id: []const u8,
        last_used_unix_ms: i64,
    ) !Record {
        try validateText(id, 512);
        try validateWorkingDirectory(working_directory);
        try validateText(model_id, 512);
        if (last_used_unix_ms < 0) return error.InvalidSessionTimestamp;

        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_working_directory = try allocator.dupe(
            u8,
            working_directory,
        );
        errdefer allocator.free(owned_working_directory);
        return .{
            .allocator = allocator,
            .id = owned_id,
            .working_directory = owned_working_directory,
            .model_id = try allocator.dupe(u8, model_id),
            .last_used_unix_ms = last_used_unix_ms,
        };
    }

    pub fn clone(
        self: *const Record,
        allocator: std.mem.Allocator,
    ) !Record {
        return init(
            allocator,
            self.id,
            self.working_directory,
            self.model_id,
            self.last_used_unix_ms,
        );
    }

    pub fn deinit(self: *Record) void {
        self.allocator.free(self.id);
        self.allocator.free(self.working_directory);
        self.allocator.free(self.model_id);
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

const DocumentRecord = struct {
    id: []const u8,
    working_directory: []const u8,
    model_id: []const u8,
    last_used_unix_ms: i64,
};

const Document = struct {
    version: u32,
    writer_id: []const u8,
    sessions: []const DocumentRecord,
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
        now_unix_ms: i64,
    ) !void {
        var record = try Record.init(
            self.allocator,
            id,
            working_directory,
            model_id,
            now_unix_ms,
        );
        defer record.deinit();
        try self.upsert(&record);
    }

    pub fn touch(self: *Store, record: *const Record, now_unix_ms: i64) !void {
        var touched = try Record.init(
            self.allocator,
            record.id,
            record.working_directory,
            record.model_id,
            now_unix_ms,
        );
        defer touched.deinit();
        try self.upsert(&touched);
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
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.name, ".json"))
            {
                continue;
            }
            const content = directory.readFileAlloc(
                self.io,
                entry.name,
                self.allocator,
                .limited(max_shard_bytes),
            ) catch |err| switch (err) {
                error.StreamTooLong => {
                    skipped_invalid = true;
                    continue;
                },
                else => return err,
            };
            defer self.allocator.free(content);
            var parsed = std.json.parseFromSlice(
                Document,
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
        try std.Io.Dir.cwd().createDirPath(self.io, self.directory);
        return std.Io.Dir.createFileAbsolute(
            self.io,
            self.lock_path,
            .{ .truncate = false, .lock = .exclusive },
        );
    }

    fn compact(self: *Store, records: []const Record) !void {
        try self.save(records);

        var directory = try std.Io.Dir.openDirAbsolute(
            self.io,
            self.directory,
            .{ .iterate = true },
        );
        defer directory.close(self.io);
        const own_filename = std.fs.path.basename(self.shard_path);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.name, ".json") or
                std.mem.eql(u8, entry.name, own_filename))
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
            DocumentRecord,
            records.len,
        );
        defer self.allocator.free(document_records);
        for (records, 0..) |record, index| {
            document_records[index] = .{
                .id = record.id,
                .working_directory = record.working_directory,
                .model_id = record.model_id,
                .last_used_unix_ms = record.last_used_unix_ms,
            };
        }
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            Document{
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
            .{ .make_path = true, .replace = true },
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

fn validDocument(filename: []const u8, document: Document) bool {
    if (document.version != version or
        document.writer_id.len != writer_id_hex_len or
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
        if (candidate.last_used_unix_ms > record.last_used_unix_ms) {
            record.deinit();
            record.* = candidate;
        } else {
            var discarded = candidate;
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

    try first.recordCreated("session-a", "/work/a", "copilot/default", 10);
    try second.recordCreated("session-b", "/work/b", "copilot/model", 20);
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
    try store.recordCreated("session-a", "/work/a", "copilot/default", 10);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "sessions/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        .data = "not json",
    });

    var index = try store.list();
    defer index.deinit();
    try std.testing.expect(index.skipped_invalid_shards);
    try std.testing.expectEqual(@as(usize, 1), index.records.len);
}

test "session store rejects mismatched writer identity" {
    const document = Document{
        .version = version,
        .writer_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .sessions = &.{},
    };
    try std.testing.expect(!validDocument(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json",
        document,
    ));
    try std.testing.expect(!validDocument(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json",
        .{
            .version = version + 1,
            .writer_id = document.writer_id,
            .sessions = &.{},
        },
    ));
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
    const records = try std.testing.allocator.alloc(
        DocumentRecord,
        max_records_per_shard,
    );
    defer std.testing.allocator.free(records);
    for (records) |*record| {
        record.* = .{
            .id = &id,
            .working_directory = &working_directory,
            .model_id = &model_id,
            .last_used_unix_ms = std.math.maxInt(i64),
        };
    }
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        Document{
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
            10,
        ),
    );
}
