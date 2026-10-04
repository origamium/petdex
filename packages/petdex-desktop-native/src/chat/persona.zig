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

const max_thinking_lines = 16;

/// Lines the pet shows while a reply is on its way. `thinking` wins;
/// `alt` / `altText` (a string or a list) is the same text under the
/// name pet files already use. Otherwise the review, waiting, and
/// thinking states' own `alt` lines, then idle, then any other state.
/// Parsed apart from petInfo, so a bad value costs only itself.
/// Strings live in `scratch`.
pub fn thinkingLines(pet_json: []const u8, scratch: []u8) []const []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const alloc = fba.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, pet_json, .{ .ignore_unknown_fields = true }) catch return &.{};
    if (root != .object) return &.{};
    var buf: [max_thinking_lines][]const u8 = undefined;
    var n: usize = 0;
    takeLines(&n, &buf, root.object.get("thinking"));
    if (n == 0) takeLines(&n, &buf, root.object.get("alt"));
    if (n == 0) takeLines(&n, &buf, root.object.get("altText"));
    if (n == 0) if (root.object.get("states")) |states| takeStateAlts(&n, &buf, states);
    if (n == 0) return &.{};
    const out = alloc.alloc([]const u8, n) catch return &.{};
    @memcpy(out, buf[0..n]);
    return out;
}

fn takeLines(n: *usize, buf: *[max_thinking_lines][]const u8, value: ?std.json.Value) void {
    const v = value orelse return;
    switch (v) {
        .string => |s| pushLine(n, buf, s),
        .array => |list| {
            for (list.items) |item| if (item == .string) pushLine(n, buf, item.string);
        },
        else => {},
    }
}

fn pushLine(n: *usize, buf: *[max_thinking_lines][]const u8, raw: []const u8) void {
    if (n.* == buf.len) return;
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return;
    buf[n.*] = line;
    n.* += 1;
}

const AltRank = enum { preferred, idle, other };

fn altRank(name: []const u8) AltRank {
    if (std.mem.eql(u8, name, "review") or std.mem.eql(u8, name, "waiting") or std.mem.eql(u8, name, "thinking")) return .preferred;
    if (std.mem.eql(u8, name, "idle")) return .idle;
    return .other;
}

fn stateAlt(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .object => |obj| blk: {
            if (obj.get("alt")) |v| if (v == .string) break :blk v.string;
            if (obj.get("altText")) |v| if (v == .string) break :blk v.string;
            break :blk null;
        },
        else => null,
    };
}

fn stateId(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    const obj = value.object;
    if (obj.get("id")) |v| if (v == .string) return v.string;
    if (obj.get("name")) |v| if (v == .string) return v.string;
    if (obj.get("state")) |v| if (v == .string) return v.string;
    return "";
}

fn takeStateAlts(n: *usize, buf: *[max_thinking_lines][]const u8, states: std.json.Value) void {
    var preferred: [max_thinking_lines][]const u8 = undefined;
    var idle: [max_thinking_lines][]const u8 = undefined;
    var other: [max_thinking_lines][]const u8 = undefined;
    var counts = [_]usize{ 0, 0, 0 };
    const put = struct {
        fn put(rank: AltRank, line: []const u8, preferred_buf: *[max_thinking_lines][]const u8, idle_buf: *[max_thinking_lines][]const u8, other_buf: *[max_thinking_lines][]const u8, counts_out: *[3]usize) void {
            const slot: *usize = switch (rank) {
                .preferred => &counts_out[0],
                .idle => &counts_out[1],
                .other => &counts_out[2],
            };
            const dest: *[max_thinking_lines][]const u8 = switch (rank) {
                .preferred => preferred_buf,
                .idle => idle_buf,
                .other => other_buf,
            };
            pushLine(slot, dest, line);
        }
    }.put;
    switch (states) {
        .array => |list| {
            for (list.items) |item| {
                const line = stateAlt(item) orelse continue;
                put(altRank(stateId(item)), line, &preferred, &idle, &other, &counts);
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const line = stateAlt(entry.value_ptr.*) orelse continue;
                put(altRank(entry.key_ptr.*), line, &preferred, &idle, &other, &counts);
            }
        },
        else => return,
    }
    const chosen: []const []const u8 = if (counts[0] > 0) preferred[0..counts[0]] else if (counts[1] > 0) idle[0..counts[1]] else other[0..counts[2]];
    for (chosen) |line| pushLine(n, buf, line);
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = std.mem.trim(u8, value orelse return null, " \t\r\n");
    return if (v.len == 0) null else v;
}

/// A fixed writer can fill the buffer halfway through a code point.
/// utf8Floor cannot repair that: it expects the full, uncut input.
fn finish(w: *std.Io.Writer) []const u8 {
    const text = w.buffered();
    if (text.len == 0) return text;
    var start = text.len - 1;
    while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
    const width = std.unicode.utf8ByteSequenceLength(text[start]) catch return text[0..start];
    return if (text.len - start < width) text[0..start] else text;
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
    w.writeAll("\n\nConversation style:\n" ++
        "Your character sheet defines your identity, relationships, preferences, and voice. " ++
        "A person's stated relationship to you takes precedence over general traits about strangers. " ++
        "Preserve its first-person pronoun, way of addressing the user, register, sentence endings, " ++
        "and emotional tone whenever specified. These are part of your character, not repetitive filler. " ++
        "Keep traits such as reserve, bluntness, or shyness; do not replace them with a generic cheerful helper voice. " ++
        "Character fidelity takes priority over variety and any suggested conversational angle. " ++
        "Express your personality through your perspective and reactions. A catchphrase need not appear every turn. " ++
        "Respond to the user's specific words and conversational intent. " ++
        "Vary thoughts and phrasing within your established voice. Your recurring interests may come up again " ++
        "with a fresh detail; avoid merely paraphrasing a recent line or recycling the same joke or imagery. " ++
        "A simple reaction can be enough; not every reply needs advice or a question. " ++
        "Follow an ongoing topic naturally, and repeat facts or wording when the user needs that. " ++
        "Keep your identity, established preferences, and shared facts consistent. " ++
        "Do not invent shared memories or claim to see screen contents, activity, or surroundings " ++
        "that the user or app has not provided. " ++
        "When the app appends a Right now block, use it only if the user asks how things are or it changes your answer. " ++
        "Do not recite it on an ordinary reply. Do not add agents, times, or memories that are not in that block " ++
        "or in the things they asked you to remember.") catch {};
    if (nonEmpty(character)) |sheet| {
        w.print("\n\nYour character:\n{s}", .{sheet}) catch {};
    } else if (info.description) |d| {
        w.print("\nAbout you: {s}", .{domain.utf8Floor(d, max_description_bytes)}) catch {};
    }
    return finish(&w);
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
        // Not "nothing to report": their usage limits may still be news.
        w.writeAll("No coding agent session is active right now.") catch {};
    } else {
        w.writeAll("Their coding agents right now:") catch {};
        for (notes) |n| writeNote(&w, n);
    }
    return finish(&w);
}

pub fn writeNote(w: *std.Io.Writer, n: Note) void {
    w.print("\n- {s}, {s}", .{ n.agent, n.state }) catch {};
    if (n.project.len > 0) w.print(", in {s}", .{n.project}) catch {};
    if (n.title.len > 0) w.print(": {s}", .{n.title}) catch {};
    if (n.text.len > 0) w.print(" — {s}", .{n.text}) catch {};
}

/// A coding agent started waiting on the user: the pet tells them, once,
/// in its own voice. The only turn, with the pet's last lines quoted.
pub fn nudge(out: []u8, notes: []const Note, recent: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("(From the app, not the user.) A coding agent of theirs is waiting on them. " ++
        "In character, tell them in one short sentence, so they go and take a look. " ++
        "Plain text, in the language of your last lines below, " ++
        "or of your description if there are none.\nWaiting now:") catch {};
    for (notes) |n| writeNote(&w, n);
    lastLines(&w, recent);
    return finish(&w);
}

test "a nudge names what waits before the pet's last lines" {
    const t = std.testing;
    var out: [1024]u8 = undefined;
    const n = nudge(&out, &.{.{ .agent = "claude", .state = "waiting", .title = "Allow Bash?", .project = "petdex" }}, &.{"眠い…"});
    try t.expect(std.mem.startsWith(u8, n, "(From the app, not the user.)"));
    try t.expect(std.mem.endsWith(u8, n, "Waiting now:\n- claude, waiting, in petdex: Allow Bash?\nYour last lines, not to repeat:\n- 眠い…"));
}

/// A gentle suggestion for small talk, never a change to the character.
pub const ChatterAngle = enum {
    feeling,
    imagination,
    preference,
    humor,

    pub fn hint(self: ChatterAngle) []const u8 {
        return switch (self) {
            .feeling => "Share a simple personal reaction or passing feeling.",
            .imagination => "Offer a small, clearly imaginary what-if that fits your character.",
            .preference => "Explore a fresh side of an established interest or preference.",
            .humor => "Try a gentle, playful thought in your own voice.",
        };
    }
};

pub const ChatterTopic = enum { contextual, casual };

/// One of three equally likely slots is reserved for everyday small talk.
pub fn chatterTopic(entropy: u64) ChatterTopic {
    return if (entropy % 3 == 0) .casual else .contextual;
}

/// Sample from all angles except the previous one. Entropy comes from
/// the shell; accepting it here keeps selection deterministic in tests.
pub fn nextChatterAngle(previous: ?ChatterAngle, entropy: u64) ChatterAngle {
    const count = std.meta.fields(ChatterAngle).len;
    var index = entropy % @as(u64, if (previous != null) count - 1 else count);
    if (previous) |last| {
        if (index >= @intFromEnum(last)) index += 1;
    }
    return @enumFromInt(index);
}

/// Unprompted small talk after a bounded conversation window. The last
/// lines are also quoted when the window has no user turn to start on.
pub fn chatter(out: []u8, recent: []const []const u8, angle: ChatterAngle, topic: ChatterTopic) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("(From the app, not the user: nobody asked you anything.) " ++
        "In character, say one short line of small talk to the user. ") catch {};
    w.writeAll(switch (topic) {
        .contextual => "Earlier messages are background, not a new request to answer again. " ++
            "You may touch on a fresh side of the conversation if it fits, but need not recap it. ",
        .casual => "Share a simple personal thought about your own interests, tastes, or imagined everyday moments. " ++
            "Keep the subject on yourself. Leave the user's condition and habits out of this line: no check-ins, questions, or advice. " ++
            "Keep this line away from coding agents, work status, tasks, usage limits, quotas, and productivity advice. ",
    }) catch {};
    w.writeAll("Don't ask them to do anything. One sentence of plain text, " ++
        "in the user's most recent language in the conversation, else the language of your last lines below, " ++
        "or of your character sheet or description if there are none. " ++
        "Your recurring interests may come up again with a fresh detail. Keep your established voice. " ++
        "The following angle is optional: ignore it if it conflicts with your character or the conversation.\n") catch {};
    w.writeAll(angle.hint()) catch {};
    // Even a quote labelled "do not repeat" can pull the model back to
    // work. The casual slot takes its material only from the character.
    if (topic == .contextual) lastLines(&w, recent);
    return finish(&w);
}

fn lastLines(w: *std.Io.Writer, recent: []const []const u8) void {
    if (recent.len == 0) return;
    w.writeAll("\nYour last lines, not to repeat:") catch {};
    for (recent) |line| w.print("\n- {s}", .{line}) catch {};
}

test "small talk asks for one unprompted line and quotes the last ones" {
    const t = std.testing;
    var out: [1024]u8 = undefined;
    const c = chatter(&out, &.{ "おはよう、先生。", "眠い…" }, .feeling, .contextual);
    try t.expect(std.mem.startsWith(u8, c, "(From the app, not the user"));
    try t.expect(std.mem.endsWith(u8, c, "\n- おはよう、先生。\n- 眠い…"));
    try t.expect(std.mem.indexOf(u8, chatter(&out, &.{}, .imagination, .contextual), "not to repeat") == null);
}

test "every small-talk angle is reachable without repeating the previous one" {
    const t = std.testing;
    const angles = std.enums.values(ChatterAngle);
    for (angles, 0..) |angle, index| {
        try t.expectEqual(angle, nextChatterAngle(null, index));
        var seen = [_]bool{false} ** angles.len;
        for (0..angles.len - 1) |entropy| {
            const next = nextChatterAngle(angle, entropy);
            try t.expect(next != angle);
            seen[@intFromEnum(next)] = true;
        }
        for (angles) |candidate| try t.expectEqual(candidate != angle, seen[@intFromEnum(candidate)]);
        try t.expect(nextChatterAngle(angle, std.math.maxInt(u64)) != angle);
    }
}

test "small-talk hints keep the request and Japanese text within the buffer" {
    const t = std.testing;
    var out: [1024]u8 = undefined;
    for (std.enums.values(ChatterTopic)) |topic| {
        for (std.enums.values(ChatterAngle)) |angle| {
            const prompt = chatter(&out, &.{"あ" ** 400}, angle, topic);
            try t.expect(std.mem.indexOf(u8, prompt, angle.hint()) != null);
            try t.expect(std.mem.indexOf(u8, prompt, "One sentence of plain text") != null);
            try t.expect(std.unicode.utf8ValidateSlice(prompt));
            try t.expect(prompt.len <= out.len);
        }
    }
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
    try t.expect(std.mem.endsWith(u8, briefing(&out, &.{}), "No coding agent session is active right now."));

    // A short buffer keeps the request and cuts the list on a UTF-8 boundary.
    var small: [600]u8 = undefined;
    const cut = briefing(&small, &.{.{ .agent = "claude", .state = "waiting", .text = "あ" ** 200 }});
    try t.expect(std.mem.indexOf(u8, cut, "what you two last talked about") != null);
    try t.expect(std.unicode.utf8ValidateSlice(cut));
}

test "thinking lines come from pet.json, and a bad value costs nothing else" {
    const t = std.testing;
    var scratch: [2048]u8 = undefined;
    const lines = thinkingLines("{\"displayName\":\"Ui\",\"thinking\":[\"眠いなあ…\",\"先生、何考えてるんだろう…\"]}", &scratch);
    try t.expectEqual(@as(usize, 2), lines.len);
    try t.expectEqualStrings("眠いなあ…", lines[0]);
    try t.expectEqualStrings("先生、何考えてるんだろう…", lines[1]);
    try t.expectEqual(@as(usize, 0), thinkingLines("{\"displayName\":\"Ui\"}", &scratch).len);

    const alt = thinkingLines("{\"displayName\":\"Ui\",\"alt\":\"  頁をめくっている  \"}", &scratch);
    try t.expectEqual(@as(usize, 1), alt.len);
    try t.expectEqualStrings("頁をめくっている", alt[0]);
    // thinking wins when both are present.
    const both = thinkingLines("{\"thinking\":[\"こっち\"],\"alt\":[\"あっち\"]}", &scratch);
    try t.expectEqualStrings("こっち", both[0]);

    const states = thinkingLines("{\"states\":[{\"id\":\"idle\",\"alt\":\"まばたき\"},{\"id\":\"running\",\"alt\":\"走っている\"},{\"name\":\"review\",\"alt\":\"頁をめくっている\"}]}", &scratch);
    try t.expectEqual(@as(usize, 1), states.len);
    try t.expectEqualStrings("頁をめくっている", states[0]);
    const idle_only = thinkingLines("{\"states\":{\"idle\":\"まばたき\",\"running-right\":{\"altText\":\"右へ\"}}}", &scratch);
    try t.expectEqual(@as(usize, 1), idle_only.len);
    try t.expectEqualStrings("まばたき", idle_only[0]);

    const broken = "{\"displayName\":\"Ui\",\"thinking\":1}";
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
    try t.expect(std.mem.indexOf(u8, cut, "Conversation style:") != null);
    try t.expect(std.mem.indexOf(u8, cut, "Do not invent shared memories") != null);
}
