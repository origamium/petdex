//! English and Japanese UI text. Every call site passes both strings, so
//! nothing can go untranslated, and both format strings are checked
//! against their arguments at compile time. Pure (std only): the chat core
//! imports it too.

const std = @import("std");

pub const Lang = enum { en, ja };

/// The Settings choice; the tag names are what the settings JSON stores.
pub const Pref = enum { auto, en, ja };

/// The language the UI speaks. Written on the UI thread only, at launch
/// and from Settings.
/// ponytail: the hook server thread reads it for its two OAuth errors; a
/// one-byte enum, so the race is harmless.
pub var current: Lang = .en;

pub fn pick(lang: Lang, en: []const u8, ja: []const u8) []const u8 {
    return if (lang == .ja) ja else en;
}

pub fn t(en: []const u8, ja: []const u8) []const u8 {
    return pick(current, en, ja);
}

/// `std.fmt.bufPrint` with a format per language. Japanese word order may
/// need positional arguments (`{0s}`, `{1s}`).
pub fn bufPrint(buf: []u8, comptime en: []const u8, comptime ja: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    return if (current == .ja) std.fmt.bufPrint(buf, ja, args) else std.fmt.bufPrint(buf, en, args);
}

/// `ui.fmt` (the frame arena) with a format per language.
pub fn fmt(ui: anytype, comptime en: []const u8, comptime ja: []const u8, args: anytype) []const u8 {
    return if (current == .ja) ui.fmt(ja, args) else ui.fmt(en, args);
}

/// Auto speaks Japanese only where it can be drawn: macOS falls back
/// through CoreText, elsewhere only a registered custom font carries CJK.
/// An explicit choice always stands.
pub fn resolve(pref: Pref, os_japanese: bool, cjk_capable: bool) Lang {
    return switch (pref) {
        .en => .en,
        .ja => .ja,
        .auto => if (os_japanese and cjk_capable) .ja else .en,
    };
}

/// A language tag ("ja", "ja-JP", "ja_JP.UTF-8", "en-US") as a Lang;
/// null for anything else ("C", "fr-FR", "jam").
pub fn fromTag(tag: []const u8) ?Lang {
    if (tag.len < 2) return null;
    if (tag.len > 2 and std.mem.indexOfScalar(u8, "-_.@", tag[2]) == null) return null;
    if (std.ascii.eqlIgnoreCase(tag[0..2], "ja")) return .ja;
    if (std.ascii.eqlIgnoreCase(tag[0..2], "en")) return .en;
    return null;
}

const testing = std.testing;

test "auto follows a Japanese system only where Japanese can be drawn" {
    try testing.expectEqual(Lang.ja, resolve(.auto, true, true));
    try testing.expectEqual(Lang.en, resolve(.auto, true, false));
    try testing.expectEqual(Lang.en, resolve(.auto, false, true));
    try testing.expectEqual(Lang.ja, resolve(.ja, false, false));
    try testing.expectEqual(Lang.en, resolve(.en, true, true));
}

test "language tags from macOS, Windows and POSIX locales" {
    try testing.expectEqual(@as(?Lang, .ja), fromTag("ja"));
    try testing.expectEqual(@as(?Lang, .ja), fromTag("ja-JP"));
    try testing.expectEqual(@as(?Lang, .ja), fromTag("ja_JP.UTF-8"));
    try testing.expectEqual(@as(?Lang, .ja), fromTag("JA"));
    try testing.expectEqual(@as(?Lang, .en), fromTag("en-US"));
    try testing.expectEqual(@as(?Lang, null), fromTag("jam"));
    try testing.expectEqual(@as(?Lang, null), fromTag("C"));
    try testing.expectEqual(@as(?Lang, null), fromTag("fr-FR"));
    try testing.expectEqual(@as(?Lang, null), fromTag(""));
}

test "text and formats follow the current language" {
    try testing.expectEqualStrings("Settings", t("Settings", "設定"));
    current = .ja;
    defer current = .en;
    try testing.expectEqualStrings("設定", t("Settings", "設定"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("0.10.0が利用可能 · 0.9.1をインストール済み", try bufPrint(&buf, "{s} installed · {s} available", "{1s}が利用可能 · {0s}をインストール済み", .{ "0.9.1", "0.10.0" }));
}
