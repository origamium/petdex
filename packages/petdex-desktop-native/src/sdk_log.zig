//! Keeps the Native SDK trace log bounded (#773, #714).
//!
//! The SDK's file sink appends every trace record to native-sdk.jsonl
//! with no rotation and no cap. Release builds pass `-Dtrace=off` since
//! #715, but builds that shipped before it grew the file to tens of GB,
//! and nothing ever removes what they left behind. The app cannot see
//! the build's trace mode (the SDK hands build options to its runner,
//! not to the app), so it bounds the file itself: over the cap, the
//! file is deleted. Deleting mid-run is safe because the sink reopens
//! the path for every record.
//!
//! The path mirrors the SDK's `debug.resolveLogPaths` over `app_dirs`
//! for `.logs`, keyed by the bundle id. If the SDK ever moves the file,
//! this simply stops finding it; nothing else depends on it.

const std = @import("std");
const builtin = @import("builtin");
const plat = @import("plat.zig");

const bundle_id = "dev.petdex.desktop-native";
const file_name = "native-sdk.jsonl";
const max_bytes: u64 = 32 * 1024 * 1024;
const check_interval_ms: i64 = 10 * 60 * 1000;

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
    /// NATIVE_SDK_LOG_DIR, which replaces the whole log directory.
    log_dir: ?[]const u8 = null,
};

var env: Env = .{};
var last_check_ms: i64 = 0;

/// Once from main(), so a leftover multi-GB file from an older build is
/// gone on the first launch after updating.
pub fn init(e: Env) void {
    env = e;
    last_check_ms = plat.nowMs();
    check();
}

/// From poll_tick. A build that traces (a dev build) keeps growing the
/// file while it runs, so boot alone is not enough.
pub fn tick(now_ms: i64) void {
    if (now_ms - last_check_ms < check_interval_ms) return;
    last_check_ms = now_ms;
    check();
}

fn check() void {
    var buf: [1024]u8 = undefined;
    const log_path = path(&buf, builtin.os.tag, env) orelse return;
    _ = enforceCap(log_path, max_bytes);
}

pub fn path(buf: []u8, os: std.Target.Os.Tag, e: Env) ?[]const u8 {
    const sep: u8 = if (os == .windows) '\\' else '/';
    if (e.log_dir) |dir| return join(buf, sep, &.{ dir, file_name });
    return switch (os) {
        .macos => join(buf, sep, &.{ e.home orelse return null, "Library", "Logs", bundle_id, file_name }),
        .windows => join(buf, sep, &.{ e.local_app_data orelse return null, bundle_id, "Logs", file_name }),
        else => if (e.xdg_state_home) |root|
            join(buf, sep, &.{ root, bundle_id, "logs", file_name })
        else
            join(buf, sep, &.{ e.home orelse return null, ".local", "state", bundle_id, "logs", file_name }),
    };
}

/// Deletes `file_path` when it is larger than `limit`. True if it did.
pub fn enforceCap(file_path: []const u8, limit: u64) bool {
    const size = plat.fileSize(file_path) orelse return false;
    if (size <= limit) return false;
    plat.deleteFile(file_path);
    return true;
}

/// Same rules as the SDK's `app_dirs.join`: empty parts are skipped and a
/// part that already ends in the separator does not get a second one.
fn join(buf: []u8, sep: u8, parts: []const []const u8) ?[]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        if (part.len == 0) continue;
        if (len > 0 and buf[len - 1] != sep) {
            if (len >= buf.len) return null;
            buf[len] = sep;
            len += 1;
        }
        if (len + part.len > buf.len) return null;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    return buf[0..len];
}

test "log path follows the SDK's per-platform log directory" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings(
        "/Users/a/Library/Logs/dev.petdex.desktop-native/native-sdk.jsonl",
        path(&buf, .macos, .{ .home = "/Users/a" }).?,
    );
    try t.expectEqualStrings(
        "/home/a/.local/state/dev.petdex.desktop-native/logs/native-sdk.jsonl",
        path(&buf, .linux, .{ .home = "/home/a" }).?,
    );
    try t.expectEqualStrings(
        "/xdg/state/dev.petdex.desktop-native/logs/native-sdk.jsonl",
        path(&buf, .linux, .{ .home = "/home/a", .xdg_state_home = "/xdg/state/" }).?,
    );
    try t.expectEqualStrings(
        "C:\\Users\\a\\AppData\\Local\\dev.petdex.desktop-native\\Logs\\native-sdk.jsonl",
        path(&buf, .windows, .{ .local_app_data = "C:\\Users\\a\\AppData\\Local" }).?,
    );
    try t.expectEqualStrings(
        "/tmp/logs/native-sdk.jsonl",
        path(&buf, .macos, .{ .home = "/Users/a", .log_dir = "/tmp/logs" }).?,
    );
    try t.expect(path(&buf, .macos, .{}) == null);
    try t.expect(path(&buf, .windows, .{ .home = "C:\\Users\\a" }) == null);
    var tiny: [8]u8 = undefined;
    try t.expect(path(&tiny, .macos, .{ .home = "/Users/a" }) == null);
}

test "enforceCap deletes only an oversized log" {
    const t = std.testing;
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var path_buf: [256]u8 = undefined;
    const p = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/native-sdk.jsonl", .{test_dir.sub_path[0..]});

    try t.expect(!enforceCap(p, 4));
    try t.expect(plat.writeFile(p, "1234"));
    try t.expect(!enforceCap(p, 4));
    try t.expect(plat.fileExists(p));
    try t.expect(plat.writeFile(p, "12345"));
    try t.expect(enforceCap(p, 4));
    try t.expect(!plat.fileExists(p));
}
