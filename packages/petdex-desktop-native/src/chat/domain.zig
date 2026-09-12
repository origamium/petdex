//! Chat domain types.

const std = @import("std");

pub const Role = enum {
    user,
    assistant,

    pub fn wireName(self: Role) []const u8 {
        return @tagName(self);
    }

    pub fn fromWireName(name: []const u8) ?Role {
        return std.meta.stringToEnum(Role, name);
    }
};

pub const Message = struct {
    role: Role,
    text: []const u8,
};

/// The closed set of backends. Persisted by name in chat.json and in
/// the history table, so rename a tag only with a migration.
pub const ProviderKind = enum {
    /// ChatGPT subscription through the Codex Responses backend.
    codex,
    /// Any OpenAI-compatible /chat/completions server: LM Studio,
    /// Ollama, llama.cpp.
    openai_compat,
};

pub const StreamEvent = union(enum) {
    delta: []const u8,
    done,
    failed: []const u8,
};

/// Longest prefix of `s` that fits in `max` bytes without splitting a
/// UTF-8 sequence. Every place the chat cuts text goes through this.
pub fn utf8Floor(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

test "utf8Floor never splits a code point" {
    const t = std.testing;
    try t.expectEqualStrings("abc", utf8Floor("abc", 8));
    try t.expectEqualStrings("ab", utf8Floor("abc", 2));
    try t.expectEqualStrings("あ", utf8Floor("あい", 4));
    try t.expectEqualStrings("あ", utf8Floor("あい", 5));
    try t.expectEqualStrings("あい", utf8Floor("あい", 6));
    try t.expectEqualStrings("", utf8Floor("あ", 2));
}

test "roles round-trip through their wire names" {
    try std.testing.expectEqual(Role.assistant, Role.fromWireName(Role.assistant.wireName()).?);
    try std.testing.expect(Role.fromWireName("system") == null);
}
