//! The character's system prompt. Built from the pet's own pet.json
//! (displayName, description); a persona.md beside it, or the user's
//! `~/.petdex/personas/<slug>.md`, describes the character instead. The
//! app's framing and reply rules always apply.

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

const ThinkingJson = struct {
    thinking: ?[]const []const u8 = null,
};

/// pet.json's `thinking`: lines the pet shows while a reply is on its
/// way. Parsed apart from petInfo, so a malformed list costs only
/// itself. Strings live in `scratch`.
pub fn thinkingLines(pet_json: []const u8, scratch: []u8) []const []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSliceLeaky(ThinkingJson, fba.allocator(), pet_json, .{ .ignore_unknown_fields = true }) catch return &.{};
    return parsed.thinking orelse &.{};
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value orelse return null, " \t\r\n");
    return if (v.len == 0) null else v;
}

/// The system prompt. `character` is a character sheet in its author's
/// own words (the pet's persona.md, or the user's override) and stands in
/// for pet.json's description. The framing and the reply rules stay the
/// app's, because the bubble shows a few lines of plain text; they come
/// first, so a sheet cut at the budget never costs them.
pub fn build(out: *[max_bytes]u8, slug: []const u8, info: PetInfo, character: ?[]const u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.print("You are {s}, a small desktop pet who lives on the user's screen next to their work.\n", .{info.name orelse slug}) catch {};
    w.writeAll("Stay in character. Reply in the language the user writes in, in one to three short sentences of plain text without markdown.") catch {};
    if (nonEmpty(character)) |sheet| {
        w.print("\n\nYour character:\n{s}", .{sheet}) catch {};
    } else if (info.description) |d| {
        w.print("\nAbout you: {s}", .{domain.utf8Floor(d, max_description_bytes)}) catch {};
    }
    return domain.utf8Floor(w.buffered(), out.len);
}

/// One coding agent's notification, as the pet sums it up.
pub const Note = struct {
    agent: []const u8,
    state: []const u8,
    title: []const u8 = "",
    text: []const u8 = "",
    project: []const u8 = "",
};

/// The app's request that the pet catch the user up: how their coding
/// agents are doing, then what the two of them last talked about. Sent
/// as the newest user turn and never stored; the persona sets the voice.
/// The request comes before the list, so a cut list keeps it.
pub fn briefing(out: []u8, notes: []const Note) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("(From the app, not the user: they double-clicked you to catch up.) " ++
        "In character, tell them how their coding agents are doing, anything waiting on them first, " ++
        "then recap in one sentence what you two last talked about, if you have talked. " ++
        "Two to four short sentences of plain text, in the language of your earlier conversation, " ++
        "or of your description if there is none.\n") catch {};
    if (notes.len == 0) {
        w.writeAll("No coding agent has anything to report right now.") catch {};
    } else {
        w.writeAll("Their coding agents right now:") catch {};
        for (notes) |n| {
            w.print("\n- {s}, {s}", .{ n.agent, n.state }) catch {};
            if (n.project.len > 0) w.print(", in {s}", .{n.project}) catch {};
            if (n.title.len > 0) w.print(": {s}", .{n.title}) catch {};
            if (n.text.len > 0) w.print(" — {s}", .{n.text}) catch {};
        }
    }
    return domain.utf8Floor(w.buffered(), out.len);
}

test "a briefing lists each agent after the request" {
    const t = std.testing;
    var out: [4096]u8 = undefined;
    const b = briefing(&out, &.{
        .{ .agent = "claude", .state = "waiting", .title = "Allow Bash?", .project = "petdex" },
        .{ .agent = "codex", .state = "working", .text = "Refactoring the parser" },
    });
    try t.expect(std.mem.indexOf(u8, b, "what you two last talked about") != null);
    try t.expect(std.mem.indexOf(u8, b, "\n- claude, waiting, in petdex: Allow Bash?") != null);
    try t.expect(std.mem.endsWith(u8, b, "\n- codex, working — Refactoring the parser"));
    try t.expect(std.mem.endsWith(u8, briefing(&out, &.{}), "No coding agent has anything to report right now."));

    // A short buffer keeps the request and cuts the list on a UTF-8 boundary.
    var small: [600]u8 = undefined;
    const cut = briefing(&small, &.{.{ .agent = "claude", .state = "waiting", .text = "あ" ** 200 }});
    try t.expect(std.mem.indexOf(u8, cut, "what you two last talked about") != null);
    try t.expect(std.unicode.utf8ValidateSlice(cut));
}

test "thinking lines come from pet.json, and a bad list costs nothing else" {
    const t = std.testing;
    var scratch: [1024]u8 = undefined;
    const lines = thinkingLines("{\"displayName\":\"Ui\",\"thinking\":[\"眠いなあ…\",\"先生、何考えてるんだろう…\"]}", &scratch);
    try t.expectEqual(@as(usize, 2), lines.len);
    try t.expectEqualStrings("眠いなあ…", lines[0]);
    try t.expectEqualStrings("先生、何考えてるんだろう…", lines[1]);
    try t.expectEqual(@as(usize, 0), thinkingLines("{\"displayName\":\"Ui\"}", &scratch).len);

    const broken = "{\"displayName\":\"Ui\",\"thinking\":\"not a list\"}";
    try t.expectEqual(@as(usize, 0), thinkingLines(broken, &scratch).len);
    try t.expectEqualStrings("Ui", petInfo(broken, &scratch).name.?);
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
    try t.expect(std.mem.indexOf(u8, prompt, "without markdown.") != null);
    try t.expect(std.mem.endsWith(u8, prompt, "About you: 古書館の司書。"));
}

test "a character sheet stands in for the description, under the app's rules" {
    const t = std.testing;
    var out: [max_bytes]u8 = undefined;
    const prompt = build(&out, "boba", .{ .name = "Boba", .description = "A cat." }, "\n# Boba\nA grumpy cat.\n");
    try t.expect(std.mem.startsWith(u8, prompt, "You are Boba,"));
    try t.expect(std.mem.indexOf(u8, prompt, "without markdown.") != null);
    try t.expect(std.mem.endsWith(u8, prompt, "Your character:\n# Boba\nA grumpy cat."));
    try t.expect(std.mem.indexOf(u8, prompt, "A cat.") == null);
    // A blank sheet leaves pet.json's description.
    try t.expect(std.mem.endsWith(u8, build(&out, "boba", .{ .description = "A cat." }, "   "), "About you: A cat."));

    // A sheet past the budget is cut on a UTF-8 boundary; the rules stay.
    const long = "あ" ** (max_bytes / 3 + 1);
    const cut = build(&out, "boba", .{}, long);
    try t.expect(cut.len <= max_bytes);
    try t.expect(std.unicode.utf8ValidateSlice(cut));
    try t.expect(std.mem.indexOf(u8, cut, "without markdown.") != null);
}
