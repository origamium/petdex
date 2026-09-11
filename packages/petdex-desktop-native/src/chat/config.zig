//! `~/.petdex/chat.json`: which backend the pet talks through and its
//! non-secret settings. Kept out of desktop-native-settings.json on
//! purpose: that file is a fixed-size hand-written format. Secrets
//! (tokens, API keys) never land here; they go to secret_store.

const std = @import("std");
const domain = @import("domain.zig");
const codex = @import("codex.zig");
const openai_compat = @import("openai_compat.zig");

pub const Config = struct {
    provider: domain.ProviderKind = .openai_compat,
    codex: struct {
        model: []const u8 = codex.default_model,
    } = .{},
    openai_compat: struct {
        base_url: []const u8 = openai_compat.default_base_url,
        model: []const u8 = "",
    } = .{},
    /// Show the end of a reply in a bubble when the chat window is closed.
    bubble_excerpt: bool = true,
};

/// A file that does not parse yields the defaults: chat.json is ours to
/// rewrite, and the next save replaces the garbage.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Config {
    return std.json.parseFromSliceLeaky(Config, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{};
}

pub fn stringify(allocator: std.mem.Allocator, config: Config) ?[]u8 {
    return std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 }) catch null;
}

test "missing, partial and broken files fall back to defaults" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = parse(a, "{}");
    try t.expectEqual(domain.ProviderKind.openai_compat, empty.provider);
    try t.expectEqualStrings(openai_compat.default_base_url, empty.openai_compat.base_url);
    try t.expectEqualStrings(codex.default_model, empty.codex.model);
    try t.expect(empty.bubble_excerpt);

    const partial = parse(a, "{\"provider\":\"codex\",\"openai_compat\":{\"model\":\"qwen3\"},\"future\":1}");
    try t.expectEqual(domain.ProviderKind.codex, partial.provider);
    try t.expectEqualStrings("qwen3", partial.openai_compat.model);
    try t.expectEqualStrings(openai_compat.default_base_url, partial.openai_compat.base_url);

    try t.expectEqual(domain.ProviderKind.openai_compat, parse(a, "{\"provider\":\"gemini\"}").provider);
    try t.expectEqual(domain.ProviderKind.openai_compat, parse(a, "garbage").provider);
}

test "config round-trips" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var config: Config = .{ .provider = .codex, .bubble_excerpt = false };
    config.openai_compat.base_url = "http://localhost:11434/v1";
    const bytes = stringify(a, config).?;
    const back = parse(a, bytes);
    try t.expectEqual(domain.ProviderKind.codex, back.provider);
    try t.expectEqualStrings("http://localhost:11434/v1", back.openai_compat.base_url);
    try t.expect(!back.bubble_excerpt);
}
