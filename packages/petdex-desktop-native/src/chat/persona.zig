//! The character's system prompt. Built from the pet's own pet.json
//! (displayName, description); `~/.petdex/personas/<slug>.md`, when the
//! shell finds one, replaces it wholesale.

const std = @import("std");
const domain = @import("domain.zig");

pub const max_bytes = 8 * 1024;
const max_description_bytes = 2 * 1024;

pub const PetInfo = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

const PetJson = struct {
    displayName: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Decodes pet.json properly (escapes, `\uXXXX`), which the app's flat
/// scanner does not; descriptions are often Japanese or Chinese.
/// Strings live in `scratch`.
pub fn petInfo(pet_json: []const u8, scratch: []u8) PetInfo {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSliceLeaky(PetJson, fba.allocator(), pet_json, .{ .ignore_unknown_fields = true }) catch return .{};
    return .{ .name = nonEmpty(parsed.displayName), .description = nonEmpty(parsed.description) };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value orelse return null, " \t\r\n");
    return if (v.len == 0) null else v;
}

pub fn build(out: *[max_bytes]u8, slug: []const u8, info: PetInfo, override: ?[]const u8) []const u8 {
    if (nonEmpty(override)) |text| {
        const kept = domain.utf8Floor(text, out.len);
        @memcpy(out[0..kept.len], kept);
        return out[0..kept.len];
    }
    var w: std.Io.Writer = .fixed(out);
    w.print("You are {s}, a small desktop pet who lives on the user's screen next to their work.\n", .{info.name orelse slug}) catch {};
    if (info.description) |d| w.print("About you: {s}\n", .{domain.utf8Floor(d, max_description_bytes)}) catch {};
    w.writeAll("Stay in character. Reply in the language the user writes in, in one to three short sentences of plain text without markdown.") catch {};
    return domain.utf8Floor(w.buffered(), out.len);
}

test "pet.json strings are decoded, including escapes" {
    const t = std.testing;
    var scratch: [1024]u8 = undefined;
    const info = petInfo("{\"id\":\"kozeki-ui\",\"displayName\":\"\\u53e4\\u95a2\\u30a6\\u30a4\",\"description\":\"A \\\"quiet\\\" archivist.\",\"spritesheetPath\":\"spritesheet.webp\"}", &scratch);
    try t.expectEqualStrings("古関ウイ", info.name.?);
    try t.expectEqualStrings("A \"quiet\" archivist.", info.description.?);
}

test "missing or blank fields fall back to the slug" {
    const t = std.testing;
    var scratch: [256]u8 = undefined;
    const info = petInfo("{\"displayName\":\"  \"}", &scratch);
    try t.expect(info.name == null and info.description == null);
    try t.expect(petInfo("not json", &scratch).name == null);

    var out: [max_bytes]u8 = undefined;
    const prompt = build(&out, "boba", info, null);
    try t.expect(std.mem.startsWith(u8, prompt, "You are boba, a small desktop pet"));
    try t.expect(std.mem.indexOf(u8, prompt, "About you") == null);
}

test "the default prompt names the pet and carries its description" {
    const t = std.testing;
    var out: [max_bytes]u8 = undefined;
    const prompt = build(&out, "kozeki-ui", .{ .name = "古関ウイ", .description = "古書館の司書。" }, null);
    try t.expect(std.mem.startsWith(u8, prompt, "You are 古関ウイ,"));
    try t.expect(std.mem.indexOf(u8, prompt, "About you: 古書館の司書。\n") != null);
    try t.expect(std.mem.endsWith(u8, prompt, "without markdown."));
}

test "an override replaces the prompt and is cut on a UTF-8 boundary" {
    const t = std.testing;
    var out: [max_bytes]u8 = undefined;
    try t.expectEqualStrings("You are a grumpy cat.", build(&out, "boba", .{ .name = "Boba" }, "\nYou are a grumpy cat.\n"));
    try t.expect(std.mem.startsWith(u8, build(&out, "boba", .{}, "   "), "You are boba"));

    const long = "あ" ** (max_bytes / 3 + 1);
    const cut = build(&out, "boba", .{}, long);
    try t.expect(cut.len <= max_bytes);
    try t.expect(std.unicode.utf8ValidateSlice(cut));
}
