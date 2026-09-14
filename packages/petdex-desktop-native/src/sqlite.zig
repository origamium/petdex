//! The slice of the SQLite C API the app uses, loaded at runtime from the
//! system library rather than vendored. macOS and Windows 10+ ship one
//! and Linux desktops carry libsqlite3.so.0; the SDK build has no hook
//! for app C sources, and the OS copy gets security fixes through OS
//! updates. When loading fails, callers degrade instead of failing.
//!
//! Use from one thread at a time (the app loop).

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{Sqlite};

const sqlite_ok = 0;
const sqlite_row = 100;
const sqlite_done = 101;
const open_readonly = 0x1;
const open_readwrite = 0x2;
const open_create = 0x4;
/// SQLITE_TRANSIENT: SQLite copies bound text before the call returns.
/// Passed as an integer because it is not a valid function pointer.
const transient: isize = -1;

const RawDb = opaque {};
const RawStmt = opaque {};

const Api = struct {
    open_v2: *const fn ([*:0]const u8, *?*RawDb, c_int, ?[*:0]const u8) callconv(.c) c_int,
    close_v2: *const fn (?*RawDb) callconv(.c) c_int,
    exec: *const fn (*RawDb, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int,
    prepare_v2: *const fn (*RawDb, [*]const u8, c_int, *?*RawStmt, ?*?[*]const u8) callconv(.c) c_int,
    step: *const fn (*RawStmt) callconv(.c) c_int,
    reset: *const fn (*RawStmt) callconv(.c) c_int,
    finalize: *const fn (?*RawStmt) callconv(.c) c_int,
    bind_text: *const fn (*RawStmt, c_int, [*]const u8, c_int, isize) callconv(.c) c_int,
    bind_int64: *const fn (*RawStmt, c_int, i64) callconv(.c) c_int,
    column_text: *const fn (*RawStmt, c_int) callconv(.c) ?[*]const u8,
    column_bytes: *const fn (*RawStmt, c_int) callconv(.c) c_int,
    column_int64: *const fn (*RawStmt, c_int) callconv(.c) i64,
    errmsg: *const fn (*RawDb) callconv(.c) [*:0]const u8,
};

var api: Api = undefined;
var load_state: enum { unknown, loaded, unavailable } = .unknown;

const candidates: []const [:0]const u8 = switch (builtin.os.tag) {
    // Resolved from the dyld shared cache; Apple-signed, so the hardened
    // runtime's library validation accepts it.
    .macos => &.{"/usr/lib/libsqlite3.dylib"},
    // System32 only (see Lib.open): a DLL planted next to the app or in
    // the working directory must not win.
    .windows => &.{"winsqlite3.dll"},
    else => &.{ "libsqlite3.so.0", "libsqlite3.so" },
};

/// Loads the library once; later calls return the cached answer.
pub fn load() bool {
    switch (load_state) {
        .loaded => return true,
        .unavailable => return false,
        .unknown => {},
    }
    for (candidates) |path| {
        var lib = Lib.open(path) orelse continue;
        if (resolve(&lib)) {
            load_state = .loaded;
            return true;
        }
    }
    load_state = .unavailable;
    return false;
}

fn resolve(lib: *Lib) bool {
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        @field(api, field.name) = lib.lookup(field.type, "sqlite3_" ++ field.name) orelse return false;
    }
    return true;
}

/// The library handle is kept for the process lifetime: nothing unloads it.
const Lib = if (builtin.os.tag == .windows) struct {
    handle: *anyopaque,

    const load_library_search_system32: u32 = 0x00000800;
    extern "kernel32" fn LoadLibraryExA(name: [*:0]const u8, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

    fn open(path: [:0]const u8) ?@This() {
        return .{ .handle = LoadLibraryExA(path.ptr, null, load_library_search_system32) orelse return null };
    }

    fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(@alignCast(GetProcAddress(self.handle, name.ptr) orelse return null));
    }
} else struct {
    inner: std.DynLib,

    fn open(path: [:0]const u8) ?@This() {
        return .{ .inner = std.DynLib.openZ(path.ptr) catch return null };
    }

    fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

pub const Db = struct {
    handle: *RawDb,

    /// `load()` must have returned true.
    pub fn open(path: [:0]const u8) Error!Db {
        return openFlags(path, open_readwrite | open_create);
    }

    /// Another app's database, read where it is: nothing is created or
    /// written. `load()` must have returned true.
    pub fn openReadOnly(path: [:0]const u8) Error!Db {
        return openFlags(path, open_readonly);
    }

    fn openFlags(path: [:0]const u8, flags: c_int) Error!Db {
        std.debug.assert(load_state == .loaded);
        var handle: ?*RawDb = null;
        if (api.open_v2(path.ptr, &handle, flags, null) != sqlite_ok) {
            _ = api.close_v2(handle);
            return error.Sqlite;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Db) void {
        _ = api.close_v2(self.handle);
    }

    /// One or more statements; result rows are discarded.
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        if (api.exec(self.handle, sql.ptr, null, null, null) != sqlite_ok) return error.Sqlite;
    }

    pub fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        var handle: ?*RawStmt = null;
        if (api.prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &handle, null) != sqlite_ok) return error.Sqlite;
        return .{ .handle = handle orelse return error.Sqlite };
    }

    /// The first column of the first row, for PRAGMA reads.
    pub fn scalarInt(self: *Db, sql: []const u8) Error!i64 {
        var stmt = try self.prepare(sql);
        defer stmt.finalize();
        if (!try stmt.step()) return error.Sqlite;
        return stmt.int(0);
    }

    pub fn errorMessage(self: *Db) []const u8 {
        return std.mem.span(api.errmsg(self.handle));
    }
};

pub const Stmt = struct {
    handle: *RawStmt,

    /// Parameters are 1-based, as in SQL (`?1`).
    pub fn bindText(self: *Stmt, index: c_int, value: []const u8) Error!void {
        if (api.bind_text(self.handle, index, value.ptr, @intCast(value.len), transient) != sqlite_ok) return error.Sqlite;
    }

    pub fn bindInt(self: *Stmt, index: c_int, value: i64) Error!void {
        if (api.bind_int64(self.handle, index, value) != sqlite_ok) return error.Sqlite;
    }

    /// True while there is a row to read.
    pub fn step(self: *Stmt) Error!bool {
        return switch (api.step(self.handle)) {
            sqlite_row => true,
            sqlite_done => false,
            else => error.Sqlite,
        };
    }

    /// Valid until the next step, reset or finalize.
    pub fn text(self: *Stmt, column: c_int) []const u8 {
        const ptr = api.column_text(self.handle, column) orelse return "";
        return ptr[0..@intCast(api.column_bytes(self.handle, column))];
    }

    pub fn int(self: *Stmt, column: c_int) i64 {
        return api.column_int64(self.handle, column);
    }

    pub fn finalize(self: *Stmt) void {
        _ = api.finalize(self.handle);
    }
};

test "the system library loads and round-trips text" {
    if (!load()) return error.SkipZigTest;
    var db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('seed');");
    var insert = try db.prepare("INSERT INTO t (v) VALUES (?1)");
    try insert.bindText(1, "こんにちは");
    try std.testing.expect(!try insert.step());
    insert.finalize();

    var select = try db.prepare("SELECT v FROM t ORDER BY rowid");
    defer select.finalize();
    try std.testing.expect(try select.step());
    try std.testing.expectEqualStrings("seed", select.text(0));
    try std.testing.expect(try select.step());
    try std.testing.expectEqualStrings("こんにちは", select.text(0));
    try std.testing.expect(!try select.step());

    try std.testing.expectEqual(@as(i64, 2), try db.scalarInt("SELECT count(*) FROM t"));
    try std.testing.expectError(error.Sqlite, db.exec("NOT SQL"));
    try std.testing.expect(db.errorMessage().len > 0);
}
