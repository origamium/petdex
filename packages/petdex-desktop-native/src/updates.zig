const std = @import("std");
const builtin = @import("builtin");

// The latest published (non-draft, non-prerelease) GitHub release of this
// repository. Releases here are all desktop releases tagged desktop-vX.Y.Z.
pub const endpoint = "https://api.github.com/repos/origamium/petdex/releases/latest";
pub const release_page = "https://github.com/origamium/petdex/releases";
pub const request_headers = [_]std.http.Header{
    .{ .name = "accept", .value = "application/vnd.github+json" },
    .{ .name = "user-agent", .value = "petdex-desktop" },
};
const tag_prefix = "desktop-v";
pub const brew_command = "brew upgrade --cask petdex";
pub const current_version = "0.10.0";

pub const Phase = enum { idle, checking, current, available, failed };
pub const InstallSource = enum { unknown, checking, direct, homebrew };

pub const Latest = struct {
    version: ?[]const u8 = null,
    tag_name: ?[]const u8 = null,
};

fn manifestVersion(source: []const u8) ?[]const u8 {
    const prefix = ".version = \"";
    const start = (std.mem.indexOf(u8, source, prefix) orelse return null) + prefix.len;
    const end = std.mem.indexOfPos(u8, source, start, "\"") orelse return null;
    const value = source[start..end];
    return if (parseVersion(value) == null) null else value;
}

pub fn parseLatest(allocator: std.mem.Allocator, body: []const u8) ?std.json.Parsed(Latest) {
    var parsed = std.json.parseFromSlice(Latest, allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.value.version == null) {
        if (parsed.value.tag_name) |tag| {
            if (std.mem.startsWith(u8, tag, tag_prefix)) parsed.value.version = tag[tag_prefix.len..];
        }
    }
    if (parsed.value.version) |version| {
        if (parseVersion(version) == null) {
            parsed.deinit();
            return null;
        }
    }
    return parsed;
}

const Version = struct { major: u32, minor: u32, patch: u32 };

fn parseVersion(value: []const u8) ?Version {
    var parts = std.mem.splitScalar(u8, value, '.');
    const major_text = parts.next() orelse return null;
    const minor_text = parts.next() orelse return null;
    const patch_text = parts.next() orelse return null;
    if (parts.next() != null or major_text.len == 0 or minor_text.len == 0 or patch_text.len == 0) return null;
    for (value) |byte| if (byte != '.' and !std.ascii.isDigit(byte)) return null;
    return .{
        .major = std.fmt.parseInt(u32, major_text, 10) catch return null,
        .minor = std.fmt.parseInt(u32, minor_text, 10) catch return null,
        .patch = std.fmt.parseInt(u32, patch_text, 10) catch return null,
    };
}

pub fn isValidVersion(value: []const u8) bool {
    return parseVersion(value) != null;
}

pub fn isNewer(latest: []const u8, current: []const u8) bool {
    const a = parseVersion(latest) orelse return false;
    const b = parseVersion(current) orelse return false;
    if (a.major != b.major) return a.major > b.major;
    if (a.minor != b.minor) return a.minor > b.minor;
    return a.patch > b.patch;
}

pub fn downloadUrl() []const u8 {
    // Only the Apple Silicon DMG is published; everything else gets the page.
    return if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)
        "https://github.com/origamium/petdex/releases/latest/download/Petdex-arm64.dmg"
    else
        release_page;
}

test "current version comes from app.zon" {
    var source_buf: [4096]u8 = undefined;
    const source = @import("plat.zig").readFile("app.zon", &source_buf).?;
    try std.testing.expectEqualStrings(manifestVersion(source).?, current_version);
}

test "semantic versions compare numerically" {
    try std.testing.expect(isNewer("0.10.0", "0.9.9"));
    try std.testing.expect(isNewer("1.0.0", "0.99.99"));
    try std.testing.expect(!isNewer("0.7.0", "0.7.0"));
    try std.testing.expect(!isNewer("0.6.9", "0.7.0"));
    try std.testing.expect(!isNewer("0.8.0-beta.1", "0.7.0"));
    try std.testing.expect(parseVersion("v0.8.0") == null);
    try std.testing.expect(parseVersion("0.8.0.1") == null);
    try std.testing.expect(parseVersion("4294967296.0.0") == null);
}

test "latest release payload accepts null and valid versions" {
    var parsed = parseLatest(std.testing.allocator, "{\"version\":\"0.8.0\",\"tag\":\"desktop-v0.8.0\"}").?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0.8.0", parsed.value.version.?);

    var unknown = parseLatest(std.testing.allocator, "{\"version\":null}").?;
    defer unknown.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), unknown.value.version);

    try std.testing.expect(parseLatest(std.testing.allocator, "{\"version\":\"next\"}") == null);
}

test "latest release payload takes the version from a desktop tag" {
    var parsed = parseLatest(std.testing.allocator, "{\"tag_name\":\"desktop-v0.9.2\",\"draft\":false}").?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0.9.2", parsed.value.version.?);

    var other = parseLatest(std.testing.allocator, "{\"tag_name\":\"web-v1.0.0\"}").?;
    defer other.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), other.value.version);

    try std.testing.expect(parseLatest(std.testing.allocator, "{\"tag_name\":\"desktop-v0.9.2-rc.1\"}") == null);
}
