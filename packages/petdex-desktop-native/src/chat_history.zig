//! Chat history in SQLite (`~/.petdex/petdex.db`), one thread per pet.
//!
//! Bounded by construction — the #773 lesson is that every file the app
//! writes needs a ceiling: each pet keeps its newest `per_pet_limit`
//! messages, the table its newest `total_limit`, and freed pages return
//! to the OS through incremental vacuum. Schema changes go through
//! `migrations` and `PRAGMA user_version`. When the system SQLite cannot
//! be loaded, `open` returns null and the chat keeps its in-memory
//! transcript only.

const std = @import("std");
const plat = @import("plat.zig");
const sqlite = @import("sqlite.zig");
const domain = @import("chat/domain.zig");
const session = @import("chat/session.zig");

pub const per_pet_limit = 400;
pub const total_limit = 10_000;

/// Append only; entry N brings the schema to user_version N+1.
const migrations = [_][:0]const u8{
    \\CREATE TABLE message (
    \\  id INTEGER PRIMARY KEY,
    \\  pet TEXT NOT NULL,
    \\  role TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
    \\  content TEXT NOT NULL,
    \\  provider TEXT NOT NULL,
    \\  created_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX message_pet_id ON message (pet, id);
};

pub const History = struct {
    db: sqlite.Db,

    /// Null when SQLite is unavailable, the file cannot be opened, or it
    /// was written by a newer app (no downgrade path).
    pub fn open(path: [:0]const u8) ?History {
        if (!sqlite.load()) return null;
        // SQLite keeps an existing file's mode (and the -wal/-shm files
        // copy it), so create it owner-only before SQLite does.
        if (!std.mem.eql(u8, path, ":memory:") and !plat.fileExists(path)) {
            if (!plat.writeFileMode(path, "", 0o600)) return null;
        }
        var db = sqlite.Db.open(path) catch return null;
        migrate(&db) catch {
            db.close();
            return null;
        };
        return .{ .db = db };
    }

    pub fn close(self: *History) void {
        self.db.close();
    }

    pub fn append(self: *History, pet: []const u8, role: domain.Role, content: []const u8, kind: domain.ProviderKind, now_ms: i64) bool {
        var stmt = self.db.prepare("INSERT INTO message (pet, role, content, provider, created_ms) VALUES (?1, ?2, ?3, ?4, ?5)") catch return false;
        defer stmt.finalize();
        stmt.bindText(1, pet) catch return false;
        stmt.bindText(2, role.wireName()) catch return false;
        stmt.bindText(3, content) catch return false;
        stmt.bindText(4, @tagName(kind)) catch return false;
        stmt.bindInt(5, now_ms) catch return false;
        _ = stmt.step() catch return false;
        return true;
    }

    /// Keep this pet's newest `per_pet_limit` messages. With fewer rows
    /// the subquery is NULL and nothing matches.
    pub fn prune(self: *History, pet: []const u8) void {
        var stmt = self.db.prepare("DELETE FROM message WHERE pet = ?1 AND id < (SELECT id FROM message WHERE pet = ?1 ORDER BY id DESC LIMIT 1 OFFSET ?2)") catch return;
        defer stmt.finalize();
        stmt.bindText(1, pet) catch return;
        stmt.bindInt(2, per_pet_limit - 1) catch return;
        _ = stmt.step() catch {};
    }

    /// At boot: the global cap, then give freed pages back and truncate
    /// the WAL.
    pub fn maintain(self: *History) void {
        self.trim(total_limit);
        self.db.exec("PRAGMA incremental_vacuum(2000); PRAGMA wal_checkpoint(TRUNCATE);") catch {};
    }

    fn trim(self: *History, limit: i64) void {
        var stmt = self.db.prepare("DELETE FROM message WHERE id < (SELECT id FROM message ORDER BY id DESC LIMIT 1 OFFSET ?1)") catch return;
        defer stmt.finalize();
        stmt.bindInt(1, limit - 1) catch return;
        _ = stmt.step() catch {};
    }

    pub fn clear(self: *History, pet: []const u8) void {
        var stmt = self.db.prepare("DELETE FROM message WHERE pet = ?1") catch return;
        defer stmt.finalize();
        stmt.bindText(1, pet) catch return;
        _ = stmt.step() catch return;
        self.db.exec("PRAGMA incremental_vacuum(2000);") catch {};
    }

    /// Refill `transcript` with the pet's newest messages, oldest first.
    /// The transcript's own eviction keeps the newest if they overflow it.
    pub fn loadInto(self: *History, pet: []const u8, transcript: *session.Transcript) void {
        transcript.clear();
        var stmt = self.db.prepare("SELECT role, content FROM (SELECT id, role, content FROM message WHERE pet = ?1 ORDER BY id DESC LIMIT ?2) ORDER BY id") catch return;
        defer stmt.finalize();
        stmt.bindText(1, pet) catch return;
        stmt.bindInt(2, session.max_messages) catch return;
        while (stmt.step() catch false) {
            const role = domain.Role.fromWireName(stmt.text(0)) orelse continue;
            transcript.append(role, stmt.text(1));
        }
    }
};

fn migrate(db: *sqlite.Db) !void {
    try db.exec("PRAGMA busy_timeout=2000;");
    const version = try db.scalarInt("PRAGMA user_version");
    if (version < 0 or version > migrations.len) return error.Sqlite;
    // Only takes effect before the first table exists.
    if (version == 0) try db.exec("PRAGMA auto_vacuum=INCREMENTAL;");
    try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA journal_size_limit=4194304;");
    for (migrations[@intCast(version)..], @as(usize, @intCast(version))..) |sql, i| {
        var set_version: [64]u8 = undefined;
        const bump = try std.fmt.bufPrintZ(&set_version, "PRAGMA user_version={d};", .{i + 1});
        try db.exec("BEGIN IMMEDIATE;");
        errdefer db.exec("ROLLBACK;") catch {};
        try db.exec(sql);
        try db.exec(bump);
        try db.exec("COMMIT;");
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

const t = std.testing;

fn testPath(buf: []u8, dir: *const std.testing.TmpDir) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/petdex.db", .{dir.sub_path[0..]});
}

fn count(h: *History, pet: []const u8) i64 {
    var stmt = h.db.prepare("SELECT count(*) FROM message WHERE pet = ?1") catch return -1;
    defer stmt.finalize();
    stmt.bindText(1, pet) catch return -1;
    _ = stmt.step() catch return -1;
    return stmt.int(0);
}

test "opening migrates once, owner-only, with incremental vacuum and WAL" {
    if (!sqlite.load()) return error.SkipZigTest;
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    var buf: [256]u8 = undefined;
    const path = try testPath(&buf, &dir);

    var h = History.open(path).?;
    try t.expectEqual(@as(i64, 1), try h.db.scalarInt("PRAGMA user_version"));
    try t.expectEqual(@as(i64, 2), try h.db.scalarInt("PRAGMA auto_vacuum"));
    var mode = try h.db.prepare("PRAGMA journal_mode");
    try t.expect(try mode.step());
    try t.expectEqualStrings("wal", mode.text(0));
    mode.finalize();
    try t.expect(h.append("boba", .user, "hi", .openai_compat, 1));
    h.close();

    var again = History.open(path).?;
    defer again.close();
    try t.expectEqual(@as(i64, 1), count(&again, "boba"));

    if (@import("builtin").os.tag != .windows) {
        var scope = plat.Scope.init();
        defer scope.deinit();
        const stat = try std.Io.Dir.cwd().statFile(scope.io(), path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(stat.permissions)) & 0o777);
    }
}

test "a database from a newer app is left alone" {
    if (!sqlite.load()) return error.SkipZigTest;
    var dir = t.tmpDir(.{});
    defer dir.cleanup();
    var buf: [256]u8 = undefined;
    const path = try testPath(&buf, &dir);
    var h = History.open(path).?;
    try h.db.exec("PRAGMA user_version=99;");
    h.close();
    try t.expect(History.open(path) == null);
}

test "each pet keeps only its newest messages" {
    if (!sqlite.load()) return error.SkipZigTest;
    var h = History.open(":memory:").?;
    defer h.close();
    try h.db.exec("BEGIN;");
    for (0..per_pet_limit + 50) |i| {
        var text: [16]u8 = undefined;
        try t.expect(h.append("boba", if (i % 2 == 0) .user else .assistant, try std.fmt.bufPrint(&text, "m{d}", .{i}), .codex, @intCast(i)));
    }
    for (0..3) |_| try t.expect(h.append("droid", .user, "hey", .codex, 0));
    try h.db.exec("COMMIT;");
    h.prune("boba");
    h.prune("droid");
    try t.expectEqual(@as(i64, per_pet_limit), count(&h, "boba"));
    try t.expectEqual(@as(i64, 3), count(&h, "droid"));

    const tr = try t.allocator.create(session.Transcript);
    defer t.allocator.destroy(tr);
    tr.* = .{};
    h.loadInto("boba", tr);
    try t.expectEqual(@as(usize, session.max_messages), tr.len());
    var last_buf: [16]u8 = undefined;
    try t.expectEqualStrings(try std.fmt.bufPrint(&last_buf, "m{d}", .{per_pet_limit + 49}), tr.last().?.text);
    try t.expectEqual(domain.Role.assistant, tr.last().?.role);
}

test "the global cap and clear" {
    if (!sqlite.load()) return error.SkipZigTest;
    var h = History.open(":memory:").?;
    defer h.close();
    for (0..4) |_| _ = h.append("a", .user, "x", .codex, 0);
    for (0..4) |_| _ = h.append("b", .user, "y", .codex, 0);
    h.trim(5);
    try t.expectEqual(@as(i64, 1), count(&h, "a"));
    try t.expectEqual(@as(i64, 4), count(&h, "b"));
    h.maintain();
    h.clear("b");
    try t.expectEqual(@as(i64, 0), count(&h, "b"));
    try t.expectEqual(@as(i64, 1), count(&h, "a"));
}
