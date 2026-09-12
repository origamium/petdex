//! Small per-account secrets (OAuth sessions, API keys).
//!
//! macOS keeps them in the login Keychain as generic passwords under one
//! service, one item per account. Linux and Windows have no store the
//! app can reach without extra dependencies, so they fall back to
//! `~/.petdex/secrets/<account>` with a 0700 directory and 0600 file —
//! the same protection Codex CLI gives ~/.codex/auth.json. On Windows the
//! modes degrade to the inherited ACL (see plat.writeFileMode).

const std = @import("std");
const builtin = @import("builtin");
const plat = @import("plat.zig");

pub const service = "dev.petdex.desktop-native";
const use_keychain = builtin.os.tag == .macos;

pub fn load(home: []const u8, account: []const u8, out: []u8) ?[]const u8 {
    if (!accountOk(account)) return null;
    if (use_keychain) return keychain.load(account, out);
    return fileLoad(home, account, out);
}

pub fn save(home: []const u8, account: []const u8, bytes: []const u8) bool {
    if (!accountOk(account) or bytes.len == 0) return false;
    if (use_keychain) return keychain.save(account, bytes);
    return fileSave(home, account, bytes);
}

/// True when nothing is stored afterwards (including "was never there").
pub fn delete(home: []const u8, account: []const u8) bool {
    if (!accountOk(account)) return false;
    if (use_keychain) return keychain.delete(account);
    return fileDelete(home, account);
}

/// Account names become file names on the fallback path, so keep them to
/// a charset that cannot traverse or collide.
fn accountOk(account: []const u8) bool {
    if (account.len == 0 or account.len > 64) return false;
    for (account) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

fn filePath(buf: []u8, home: []const u8, account: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.petdex/secrets/{s}", .{ home, account }) catch null;
}

fn fileLoad(home: []const u8, account: []const u8, out: []u8) ?[]const u8 {
    var buf: [1024]u8 = undefined;
    return plat.readFile(filePath(&buf, home, account) orelse return null, out);
}

fn fileSave(home: []const u8, account: []const u8, bytes: []const u8) bool {
    var dir_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/.petdex/secrets", .{home}) catch return false;
    if (home.len == 0 or !plat.makeDirMode(dir, 0o700)) return false;
    var buf: [1024]u8 = undefined;
    return plat.writeFileMode(filePath(&buf, home, account) orelse return false, bytes, 0o600);
}

fn fileDelete(home: []const u8, account: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const path = filePath(&buf, home, account) orelse return false;
    plat.deleteFile(path);
    return !plat.fileExists(path);
}

const keychain = struct {
    const err_sec_success: c_int = 0;
    const err_sec_item_not_found: c_int = -25300;

    extern "c" fn SecKeychainFindGenericPassword(
        keychain_or_array: ?*const anyopaque,
        service_name_length: u32,
        service_name: [*]const u8,
        account_name_length: u32,
        account_name: [*]const u8,
        password_length: ?*u32,
        password_data: ?*?*anyopaque,
        item_ref: ?*?*anyopaque,
    ) c_int;
    extern "c" fn SecKeychainAddGenericPassword(
        keychain: ?*const anyopaque,
        service_name_length: u32,
        service_name: [*]const u8,
        account_name_length: u32,
        account_name: [*]const u8,
        password_length: u32,
        password_data: *const anyopaque,
        item_ref: ?*?*anyopaque,
    ) c_int;
    extern "c" fn SecKeychainItemModifyAttributesAndData(item_ref: *anyopaque, attr_list: ?*const anyopaque, length: u32, data: *const anyopaque) c_int;
    extern "c" fn SecKeychainItemDelete(item_ref: *anyopaque) c_int;
    extern "c" fn SecKeychainItemFreeContent(attr_list: ?*anyopaque, data: ?*anyopaque) c_int;
    extern "c" fn CFRelease(value: *const anyopaque) void;

    fn load(account: []const u8, out: []u8) ?[]const u8 {
        var password_len: u32 = 0;
        var password_data: ?*anyopaque = null;
        var item_ref: ?*anyopaque = null;
        const status = SecKeychainFindGenericPassword(null, service.len, service.ptr, @intCast(account.len), account.ptr, &password_len, &password_data, &item_ref);
        defer {
            if (password_data != null) _ = SecKeychainItemFreeContent(null, password_data);
            if (item_ref) |item| CFRelease(item);
        }
        if (status != err_sec_success or password_len == 0 or password_len > out.len) return null;
        const source: [*]const u8 = @ptrCast(password_data.?);
        @memcpy(out[0..password_len], source[0..password_len]);
        return out[0..password_len];
    }

    fn save(account: []const u8, bytes: []const u8) bool {
        if (bytes.len > std.math.maxInt(u32)) return false;
        var item_ref: ?*anyopaque = null;
        const status = SecKeychainFindGenericPassword(null, service.len, service.ptr, @intCast(account.len), account.ptr, null, null, &item_ref);
        if (status == err_sec_success) {
            defer CFRelease(item_ref.?);
            return SecKeychainItemModifyAttributesAndData(item_ref.?, null, @intCast(bytes.len), bytes.ptr) == err_sec_success;
        }
        if (status != err_sec_item_not_found) return false;
        return SecKeychainAddGenericPassword(null, service.len, service.ptr, @intCast(account.len), account.ptr, @intCast(bytes.len), bytes.ptr, null) == err_sec_success;
    }

    fn delete(account: []const u8) bool {
        var item_ref: ?*anyopaque = null;
        const status = SecKeychainFindGenericPassword(null, service.len, service.ptr, @intCast(account.len), account.ptr, null, null, &item_ref);
        if (status == err_sec_item_not_found) return true;
        if (status != err_sec_success) return false;
        defer CFRelease(item_ref.?);
        return SecKeychainItemDelete(item_ref.?) == err_sec_success;
    }
};

test "account names are limited to a path-safe charset" {
    try std.testing.expect(accountOk("oauth"));
    try std.testing.expect(accountOk("openai-compat-key"));
    try std.testing.expect(!accountOk(""));
    try std.testing.expect(!accountOk("../oauth"));
    try std.testing.expect(!accountOk("a/b"));
    try std.testing.expect(!accountOk("a.b"));
}

test "file fallback round-trips with owner-only permissions" {
    const t = std.testing;
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var home_buf: [256]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{test_dir.sub_path[0..]});

    var out: [64]u8 = undefined;
    try t.expect(fileLoad(home, "chatgpt", &out) == null);
    try t.expect(fileSave(home, "chatgpt", "{\"refresh\":\"r\"}"));
    try t.expectEqualStrings("{\"refresh\":\"r\"}", fileLoad(home, "chatgpt", &out).?);
    try t.expect(fileSave(home, "chatgpt", "second"));
    try t.expectEqualStrings("second", fileLoad(home, "chatgpt", &out).?);

    if (builtin.os.tag != .windows) {
        var path_buf: [512]u8 = undefined;
        const path = filePath(&path_buf, home, "chatgpt").?;
        var scope = plat.Scope.init();
        defer scope.deinit();
        const stat = try std.Io.Dir.cwd().statFile(scope.io(), path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intFromEnum(stat.permissions)) & 0o777);
    }

    try t.expect(fileDelete(home, "chatgpt"));
    try t.expect(fileDelete(home, "chatgpt"));
    try t.expect(fileLoad(home, "chatgpt", &out) == null);
}
