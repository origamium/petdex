//! The effects side of the pet chat. Turns chat/session Actions into
//! fetches and pet animations, keeps chat.json, the ChatGPT credentials
//! and the history database, and runs ChatGPT sign-in. The only chat
//! module that knows the SDK, the Model or the filesystem; the rules it
//! executes live in src/chat/, which stays pure.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const app = @import("main.zig");
const chat_view = @import("chat_view.zig");
const plat = @import("plat.zig");
const hook_server = @import("hook_server.zig");
const catalog_mod = @import("catalog.zig");
const pkce = @import("pkce.zig");
const secret_store = @import("secret_store.zig");
const chat_history = @import("chat_history.zig");
const chat = @import("chat/chat.zig");

const domain = chat.domain;
const provider = chat.provider;
const codex = chat.codex;
const openai_compat = chat.openai_compat;
const session = chat.session;
const persona = chat.persona;
const config = chat.config;

const Model = app.Model;
const Msg = app.Msg;
const Effects = app.Effects;

pub const window_label = "chat";
pub const canvas_label = "chat-canvas";
/// A second tap on the pet within this window asks for a briefing.
pub const double_tap_ms: i64 = 350;
/// The most exchanges the chat bubble can keep on screen (Settings).
pub const max_stack: u8 = 6;
/// From the tail's tip to the pet window's edge.
const pet_gap: f64 = 4;
/// Where the tail points, as a fraction of the pet's height: its head.
const head_frac: f64 = 0.3;
/// After a screen edge pushed the bubble left of the pet, how far left
/// the pet has to move before the right side is tried again.
const side_hysteresis: f64 = 40;

const token_key: u64 = 50;
const models_key: u64 = 51;
/// The SDK's fetch timeout covers the whole stream, not just the wait
/// for the first byte, and a local model can take minutes.
const stream_timeout_ms: u32 = 5 * 60 * 1000;
const chatgpt_account = "chatgpt";
const reply_wave_ms: u32 = 1500;
const failed_ms: u32 = 2500;
const excerpt_bytes = 190;

pub const ChatgptPhase = enum { signed_out, authorizing, exchanging, signed_in, failed };
const TokenPurpose = enum { none, sign_in, refresh };

/// Where the chat bubble sits beside the pet; `follow` keeps it there.
pub const Place = struct {
    /// Left of the pet, and the pet's x when the right side ran out.
    left: bool = false,
    left_at_x: f64 = 0,
    /// The last target; NaN until the first placement.
    want_x: f64 = std.math.nan(f64),
    want_y: f64 = std.math.nan(f64),
    /// Where the window landed after the screen clamp.
    at_x: f64 = 0,
    at_y: f64 = 0,
    /// The height last applied, and the tail's center in the window.
    h: f32 = 0,
    tail_y: f32 = 0,

    pub fn placed(self: Place) bool {
        return !std.math.isNan(self.want_x);
    }
};

/// Everything the chat keeps in the Model. Fixed-size, like the rest.
pub const State = struct {
    open: bool = false,
    session: session.Session = .{},
    /// The pet the transcript belongs to.
    pet: [64]u8 = undefined,
    pet_len: usize = 0,
    pet_name: [96]u8 = undefined,
    pet_name_len: usize = 0,
    /// Text fields mirror the runtime editor (selection and IME
    /// composition too), so rebuilds keep the caret where it is.
    input: canvas.TextBuffer(2048) = .{},
    /// Backend of the stream in flight; the setting may change mid-reply.
    stream_kind: domain.ProviderKind = .openai_compat,
    kind: domain.ProviderKind = .openai_compat,
    local_url: canvas.TextBuffer(256) = .{},
    local_model: canvas.TextBuffer(128) = .{},
    codex_model: canvas.TextBuffer(128) = .{},
    bubble_excerpt: bool = true,
    /// Recent exchanges stacked above the reply, 1 to max_stack.
    stack: u8 = 3,
    /// The line shown until the reply's first words, picked per request
    /// from the pet's `thinking` lines.
    thinking: [192]u8 = undefined,
    thinking_len: usize = 0,
    creds: codex.Credentials = .{},
    chatgpt: ChatgptPhase = .signed_out,
    verifier: [pkce.verifier_len]u8 = undefined,
    oauth_state: [pkce.state_len]u8 = undefined,
    token_purpose: TokenPurpose = .none,
    detecting: bool = false,
    /// One line of feedback under the chat settings.
    note: [192]u8 = undefined,
    note_len: usize = 0,
    last_tap_ms: i64 = 0,
    /// Transcript scroll offset, echoed back from on_scroll: secondary
    /// windows keep scroll model-driven. 0 shows the newest exchange.
    scroll: f32 = 0,
    /// Past exchanges instead of the latest reply.
    history: bool = false,
    place: Place = .{},

    pub fn petSlug(self: *const State) []const u8 {
        return self.pet[0..self.pet_len];
    }

    pub fn petName(self: *const State) []const u8 {
        return if (self.pet_name_len > 0) self.pet_name[0..self.pet_name_len] else "your pet";
    }

    pub fn inputText(self: *const State) []const u8 {
        return self.input.text();
    }

    pub fn localUrl(self: *const State) []const u8 {
        return self.local_url.text();
    }

    pub fn localModel(self: *const State) []const u8 {
        return self.local_model.text();
    }

    pub fn codexModel(self: *const State) []const u8 {
        return self.codex_model.text();
    }

    pub fn thinkingText(self: *const State) []const u8 {
        return if (self.thinking_len > 0) self.thinking[0..self.thinking_len] else "Thinking…";
    }

    pub fn noteText(self: *const State) []const u8 {
        return self.note[0..self.note_len];
    }

    /// Whether a message can be sent right now with this backend.
    pub fn ready(self: *const State) bool {
        return switch (self.kind) {
            .codex => self.creds.signedIn(),
            .openai_compat => self.local_url.len > 0,
        };
    }
};

var bufs: provider.Bufs = .{};
var parse_scratch: [32 * 1024]u8 = undefined;
var file_buf: [64 * 1024]u8 = undefined;
var character_buf: [persona.max_bytes]u8 = undefined;
var persona_buf: [persona.max_bytes]u8 = undefined;
var persona_len: usize = 0;
/// The active pet's `thinking` lines, copied out of the parse scratch.
var thinking_pool: [2048]u8 = undefined;
var thinking_lines: [16][]const u8 = undefined;
var thinking_count: usize = 0;
var history: ?chat_history.History = null;
var history_tried = false;
/// CODEX_HOME, read in main(): where Codex CLI keeps auth.json.
pub var env_codex_home: ?[]const u8 = null;

// ── Lifecycle ─────────────────────────────────────────────────────────

pub fn boot(model: *Model) void {
    loadConfig(&model.chat);
    loadCredentials(&model.chat);
}

/// From poll_tick: follow pet switches while the window is open, and
/// pick up the ChatGPT sign-in callback.
pub fn poll(model: *Model, fx: *Effects) void {
    if (model.chat.open) syncPet(model, fx);
    follow(model, fx);
    const callback = hook_server.chatgpt_mailbox.take() orelse return;
    const st = &model.chat;
    if (st.chatgpt != .authorizing) return;
    if (callback.error_len > 0) return failSignIn(st, callback.errorSlice());
    if (!std.mem.eql(u8, callback.stateSlice(), &st.oauth_state)) return failSignIn(st, "ChatGPT sent back a sign-in for another attempt. Try again.");
    var body_buf: [8192]u8 = undefined;
    const body = codex.tokenBody(&body_buf, callback.codeSlice(), &st.verifier) orelse return failSignIn(st, "The sign-in code was too long.");
    st.chatgpt = .exchanging;
    st.token_purpose = .sign_in;
    postToken(fx, body);
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    const st = &model.chat;
    switch (msg) {
        .open_chat => open(model, fx),
        .show_chat => show(model, fx),
        .chat_brief => brief(model, fx),
        .chat_closed => st.open = false,
        .chat_input => |edit| st.input.apply(edit),
        .chat_submit => submit(model, fx),
        .chat_stop => stop(model, fx),
        .chat_clear => clear(model, fx),
        .chat_retry => begin(model, st.session.retry(needsRefresh(st, fx)), fx),
        .chat_toggle_history => {
            st.history = !st.history;
            st.scroll = 0;
        },
        .chat_scrolled => |scroll| st.scroll = scroll.offset,
        .chat_line => |line| st.session.onLine(st.stream_kind, line.key, line.line, line.truncated, line.dropped_before > 0, &parse_scratch),
        .chat_response => |response| onResponse(model, response, fx),
        .set_chat_stack => |raw| {
            st.stack = @intCast(std.math.clamp(raw, 1, max_stack));
            saveConfig(st);
        },
        .set_chat_provider => |raw| {
            st.kind = std.enums.fromInt(domain.ProviderKind, raw) orelse return;
            st.note_len = 0;
            saveConfig(st);
        },
        .chat_model_input => |edit| {
            switch (st.kind) {
                .codex => st.codex_model.apply(edit),
                .openai_compat => st.local_model.apply(edit),
            }
            saveConfig(st);
        },
        .chat_url_input => |edit| {
            st.local_url.apply(edit);
            saveConfig(st);
        },
        .chat_detect_models => detectModels(st, fx),
        .chat_models_response => |response| onModels(st, response),
        .chatgpt_sign_in => signIn(st),
        .chatgpt_import => importCodex(st, fx),
        .chatgpt_sign_out => signOut(st),
        .chatgpt_token_response => |response| onToken(model, response, fx),
        else => {},
    }
}

/// Cmd+K, the tray and the pet's menu toggle the chat.
fn open(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    if (st.open) {
        st.open = false;
        return;
    }
    syncPet(model, fx);
    st.scroll = 0;
    st.history = false;
    st.place = .{};
    app.registerTail(model.dark, fx);
    st.open = true;
}

/// The chat bubble is up beside the pet, where the hook stack must not
/// cover it (main.bubbleWantX).
pub fn besidePet(st: *const State) bool {
    return st.open and chat_view.bubble and st.place.placed();
}

/// A tap on the pet opens the chat, or leaves it open.
fn show(model: *Model, fx: *Effects) void {
    if (!model.chat.open) open(model, fx);
}

/// A double tap: the pet catches the user up on their coding agents and
/// the last conversation, in its own voice, as a reply in the chat.
fn brief(model: *Model, fx: *Effects) void {
    show(model, fx);
    const st = &model.chat;
    // Unconfigured, the reply card already points at Settings.
    if (!st.ready() or st.session.busy()) return;
    const action = st.session.brief(needsRefresh(st, fx));
    if (action == .none) return;
    st.history = false;
    st.scroll = 0;
    begin(model, action, fx);
}

var brief_buf: [4096]u8 = undefined;

/// The briefing prompt, from the hook bubbles on screen right now.
fn briefingPrompt(model: *const Model) []const u8 {
    var notes: [hook_server.max_bubbles]persona.Note = undefined;
    var n: usize = 0;
    for (model.bubbles[0..model.bubbles_len]) |*b| {
        const agent = b.agent[0..b.agent_len];
        // The chat's own reply excerpts are not news.
        if (std.mem.eql(u8, agent, "petdex")) continue;
        notes[n] = .{
            .agent = agent,
            .state = if (b.agent_state_len > 0) b.agentStateSlice() else if (b.busy) "working" else "finished",
            .title = b.title[0..b.title_len],
            .text = b.text[0..b.text_len],
            .project = std.fs.path.basename(b.cwdSlice()),
        };
        n += 1;
    }
    return persona.briefing(&brief_buf, notes[0..n]);
}

const Pet = struct { x: f64, y: f64, w: f64, h: f64 };
const Point = struct { x: f64, y: f64 };

/// The window origin beside the pet that puts the reply card's top level
/// with the pet's top; `speech_top` is that card's offset in the window,
/// below the stacked exchanges.
fn originBeside(pet: Pet, left: bool, speech_top: f32) Point {
    return .{
        .x = if (left) pet.x - pet_gap - chat_view.window_w else pet.x + pet.w + pet_gap,
        .y = pet.y - speech_top,
    };
}

/// Stay left until the pet has moved clearly away from the edge that
/// pushed the bubble there, so it cannot flap at the threshold.
fn keepLeft(p: Place, pet_x: f64) bool {
    return p.left and pet_x >= p.left_at_x - side_hysteresis;
}

/// The tail's center in window space: at the pet's head, kept on the
/// reply card's straight edge (the card spans card_top..card_top+card_h),
/// clear of its corner radius.
fn tailY(pet_y: f64, pet_h: f64, win_y: f64, card_top: f32, card_h: f32) f32 {
    const r = app.bubble_card_radius + @as(f32, @floatFromInt(app.tail_w)) / 2;
    const aim: f32 = @floatCast(pet_y + pet_h * head_frac - win_y);
    return std.math.clamp(aim, card_top + r, card_top + @max(r, card_h - r));
}

/// Keep the bubble beside the pet: on every frame the pet may move, and
/// on poll ticks. Moves only when the target changed or the window was
/// nudged (AppKit settles a new window after its first frame), and
/// switches sides when the screen clamp stops it short. Descriptor
/// coordinates are only a creation hint, so this also does the first
/// placement.
pub fn follow(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    // Linux has no window move or resize.
    if (!st.open or builtin.os.tag == .linux) return;
    const p = &st.place;
    // A titled window (Windows) is placed once and then belongs to the user.
    if (!chat_view.bubble and p.placed()) return;
    var cur = fx.moveWindow(window_label, 0, 0, false) orelse return; // not created yet
    const h = chat_view.windowHeight(model);
    if (chat_view.bubble and h != p.h) {
        // AppKit keeps the bottom edge on resize; the move below puts
        // the top back beside the pet's head.
        _ = fx.resizeWindow(window_label, chat_view.window_w, h, .top_left);
        p.h = h;
        p.want_x = std.math.nan(f64);
        cur = fx.moveWindow(window_label, 0, 0, false) orelse return;
    }
    const pet = Pet{
        .x = model.pet_x,
        .y = model.pet_y,
        .w = app.frame_w * model.scale,
        .h = app.frame_h * model.scale,
    };
    if (!keepLeft(p.*, pet.x)) p.left = false;
    const speech_top = chat_view.speechTop(model);
    var want = originBeside(pet, p.left, speech_top);
    if (want.x == p.want_x and want.y == p.want_y and @abs(cur.x - p.at_x) < 1 and @abs(cur.y - p.at_y) < 1) return;
    var landed = cur;
    for (0..2) |pass| {
        // Unclamped first so a pet on another display pulls the bubble
        // across, then clamped to that display.
        if (app.bubbleMovePlan(landed.x, landed.y, want.x, want.y)) |m| _ = fx.moveWindow(window_label, m.dx, m.dy, false) orelse return;
        landed = fx.moveWindow(window_label, 0, 0, true) orelse return;
        // A zero-delta clamp only reports where the window should be;
        // apply it (settleBubbleWindow does the same for the hook bubble).
        const actual = fx.moveWindow(window_label, 0, 0, false) orelse return;
        if (app.bubbleMovePlan(actual.x, actual.y, landed.x, landed.y)) |m| _ = fx.moveWindow(window_label, m.dx, m.dy, false) orelse return;
        // ponytail: with no room on either side (a screen under ~900pt
        // wide) the second side stands, overlapping the pet.
        if (!landed.hit_x or pass == 1) break;
        p.left = !p.left;
        if (p.left) p.left_at_x = pet.x;
        want = originBeside(pet, p.left, speech_top);
    }
    p.want_x = want.x;
    p.want_y = want.y;
    p.at_x = landed.x;
    p.at_y = landed.y;
    p.tail_y = tailY(pet.y, pet.h, landed.y, speech_top, chat_view.cardHeight(model));
}

/// Point the conversation at the active pet: its transcript from the
/// database and a persona built from its pet.json.
fn syncPet(model: *Model, fx: *Effects) void {
    if (model.active_pet >= catalog_mod.catalog_len) return;
    const entry = &catalog_mod.catalog[model.active_pet];
    const st = &model.chat;
    if (std.mem.eql(u8, entry.slice(), st.petSlug())) return;
    if (st.session.busy()) fx.cancel(st.session.streamKey());
    st.session.load(&.{});
    setField(&st.pet, &st.pet_len, entry.slice());
    if (ensureHistory()) |h| h.loadInto(st.petSlug(), &st.session.transcript);
    buildPersona(st, entry.rootSlice());
}

fn buildPersona(st: *State, root: []const u8) void {
    var info: persona.PetInfo = .{};
    var character: ?[]const u8 = null;
    thinking_count = 0;
    if (app.env_home) |home| {
        var path_buf: [640]u8 = undefined;
        if (std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/pet.json", .{ home, root, st.petSlug() })) |path| {
            if (plat.readFile(path, &file_buf)) |json| {
                const half = parse_scratch.len / 2;
                info = persona.petInfo(json, parse_scratch[0..half]);
                keepThinking(persona.thinkingLines(json, parse_scratch[half..]));
            }
        } else |_| {}
        // The character sheet: the user's override, else the pet's own
        // persona.md beside pet.json.
        if (std.fmt.bufPrint(&path_buf, "{s}/.petdex/personas/{s}.md", .{ home, st.petSlug() })) |path| {
            character = plat.readFile(path, &character_buf);
        } else |_| {}
        if (character == null) {
            if (std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/persona.md", .{ home, root, st.petSlug() })) |path| {
                character = plat.readFile(path, &character_buf);
            } else |_| {}
        }
    }
    persona_len = persona.build(&persona_buf, st.petSlug(), info, character).len;
    setField(&st.pet_name, &st.pet_name_len, info.name orelse st.petSlug());
}

/// Copy the pet's thinking lines out of the parse scratch, which the
/// next streamed reply reuses.
fn keepThinking(lines: []const []const u8) void {
    var used: usize = 0;
    for (lines) |raw| {
        if (thinking_count == thinking_lines.len) break;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const kept = domain.utf8Floor(line, @min(@sizeOf(@FieldType(State, "thinking")), thinking_pool.len - used));
        if (kept.len == 0) break;
        @memcpy(thinking_pool[used..][0..kept.len], kept);
        thinking_lines[thinking_count] = thinking_pool[used..][0..kept.len];
        thinking_count += 1;
        used += kept.len;
    }
}

/// One of the pet's thinking lines for this request, at random; none
/// leaves the default.
fn pickThinking(st: *State) void {
    st.thinking_len = 0;
    if (thinking_count == 0) return;
    var seed: [8]u8 = @splat(0);
    plat.fillRandom(&seed) catch {};
    setField(&st.thinking, &st.thinking_len, thinking_lines[std.mem.readInt(u64, &seed, .little) % thinking_count]);
}

// ── Conversation ──────────────────────────────────────────────────────

fn needsRefresh(st: *const State, fx: *Effects) bool {
    return st.kind == .codex and st.creds.expiresSoon(fx.wallMs());
}

fn submit(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    if (st.pet_len == 0) syncPet(model, fx);
    if (st.pet_len == 0) return;
    const action = st.session.submit(st.inputText(), needsRefresh(st, fx));
    if (action == .none) return;
    st.input.clear();
    st.scroll = 0;
    st.history = false;
    if (st.session.transcript.last()) |m| {
        if (ensureHistory()) |h| _ = h.append(st.petSlug(), .user, m.text, st.kind, fx.wallMs());
    }
    begin(model, action, fx);
}

/// Every request starts here (a send, a retry, a briefing): the pet
/// looks busy, and one thinking line holds until the first words, a
/// credential refresh on the way included.
fn begin(model: *Model, action: session.Action, fx: *Effects) void {
    if (action == .none) return;
    pickThinking(&model.chat);
    app.applyState(model, .review, 0, fx);
    run(model, action, fx);
}

fn run(model: *Model, action: session.Action, fx: *Effects) void {
    switch (action) {
        .none => {},
        .request => startRequest(model, fx),
        .refresh => startRefresh(model, fx),
        .done => finishReply(model, fx),
        .failed => app.applyState(model, .failed, failed_ms, fx),
    }
}

fn startRequest(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    st.stream_kind = st.kind;
    var context: [session.context_messages]domain.Message = undefined;
    const recent = st.session.context(&context);
    // A briefing ends the context with the app's prompt, never stored.
    var with_brief: [session.context_messages + 1]domain.Message = undefined;
    const turns: []const domain.Message = if (st.session.briefing) blk: {
        @memcpy(with_brief[0..recent.len], recent);
        with_brief[recent.len] = .{ .role = .user, .text = briefingPrompt(model) };
        break :blk with_brief[0 .. recent.len + 1];
    } else recent;
    var cache_key: [80]u8 = undefined;
    const target: provider.Target = switch (st.kind) {
        .codex => .{
            .base_url = codex.base_url,
            .model = st.codexModel(),
            .cache_key = std.fmt.bufPrint(&cache_key, "petdex-{s}", .{st.petSlug()}) catch "",
        },
        .openai_compat => .{ .base_url = st.localUrl(), .model = st.localModel() },
    };
    const auth: provider.Auth = if (st.kind == .codex) st.creds.auth() else .{};
    const request = provider.buildRequest(st.kind, target, auth, persona_buf[0..persona_len], turns, &bufs) orelse {
        const why: []const u8 = switch (st.kind) {
            .codex => if (st.creds.signedIn()) "The conversation is too long to send." else "Sign in to ChatGPT in Settings first.",
            .openai_compat => if (st.local_url.len == 0) "Set the server URL in Settings first." else "The conversation is too long to send.",
        };
        run(model, st.session.onResponse(st.kind, st.session.streamKey(), 0, why), fx);
        return;
    };
    fx.fetch(.{
        .key = st.session.streamKey(),
        .method = .POST,
        .url = request.url,
        .headers = request.headers,
        .body = request.body,
        .timeout_ms = stream_timeout_ms,
        .response = .stream,
        // The 4 KiB default cuts codex's lifecycle events, which echo the
        // persona; deltas are far below either bound.
        .max_line_bytes = 64 * 1024,
        .on_line = Effects.lineMsg(.chat_line),
        .on_response = Effects.responseMsg(.chat_response),
    });
}

fn onResponse(model: *Model, response: native_sdk.EffectResponse, fx: *Effects) void {
    const st = &model.chat;
    const transport: ?[]const u8 = switch (response.outcome) {
        .ok => null,
        .cancelled => return,
        .timed_out => "The reply took too long.",
        .connect_failed => switch (st.stream_kind) {
            .openai_compat => "Could not reach the local server. Is it running?",
            .codex => "Could not reach ChatGPT.",
        },
        .tls_failed => "A secure connection could not be made.",
        .rejected, .protocol_failed => "The connection failed.",
    };
    run(model, st.session.onResponse(st.stream_kind, response.key, response.status, transport), fx);
}

fn finishReply(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    const reply = st.session.lastReply() orelse return;
    if (ensureHistory()) |h| {
        _ = h.append(st.petSlug(), .assistant, reply, st.stream_kind, fx.wallMs());
        h.prune(st.petSlug());
    }
    app.applyState(model, .waving, reply_wave_ms, fx);
    if (!st.open and st.bubble_excerpt) {
        var buf: [excerpt_bytes + 3]u8 = undefined;
        const cut = domain.utf8Floor(reply, excerpt_bytes);
        const text = if (cut.len < reply.len) std.fmt.bufPrint(&buf, "{s}…", .{cut}) catch cut else cut;
        _ = hook_server.mailbox.setBubble("petdex-chat", text, "petdex", st.petName(), false);
    }
}

fn stop(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    if (!st.session.busy()) return;
    const key = st.session.streamKey();
    st.session.cancel();
    fx.cancel(key);
    app.applyState(model, .idle, 0, fx);
}

fn clear(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    if (st.session.busy()) {
        const key = st.session.streamKey();
        st.session.cancel();
        fx.cancel(key);
    }
    st.session.load(&.{});
    if (ensureHistory()) |h| h.clear(st.petSlug());
}

fn ensureHistory() ?*chat_history.History {
    if (history) |*h| return h;
    if (history_tried) return null;
    history_tried = true;
    const home = app.env_home orelse return null;
    var dir_buf: [512]u8 = undefined;
    plat.makeDir(std.fmt.bufPrint(&dir_buf, "{s}/.petdex", .{home}) catch return null);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.petdex/petdex.db", .{home}) catch return null;
    history = chat_history.History.open(path) orelse {
        std.debug.print("petdex: chat history is off (system SQLite unavailable)\n", .{});
        return null;
    };
    history.?.maintain();
    return &history.?;
}

// ── ChatGPT ───────────────────────────────────────────────────────────

fn signIn(st: *State) void {
    if (st.chatgpt == .exchanging) return;
    const p = pkce.generate() orelse return failSignIn(st, "Could not start ChatGPT sign-in.");
    st.verifier = p.verifier;
    st.oauth_state = p.state;
    var url_buf: [1024]u8 = undefined;
    const url = codex.authorizeUrl(&url_buf, &p.challenge, &p.state) orelse return failSignIn(st, "Could not start ChatGPT sign-in.");
    hook_server.startOAuthListener(codex.callback_port, codex.callback_path, &hook_server.chatgpt_mailbox);
    st.chatgpt = .authorizing;
    st.note_len = 0;
    plat.openExternal(url);
}

fn failSignIn(st: *State, message: []const u8) void {
    st.chatgpt = .failed;
    setNote(st, message);
}

fn startRefresh(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    st.stream_kind = st.kind;
    if (st.creds.refresh_len == 0) {
        run(model, st.session.onRefreshed(false, "Sign in to ChatGPT in Settings."), fx);
        return;
    }
    // A token request already in flight resolves the session when it lands.
    if (st.token_purpose != .none) return;
    var body_buf: [8192]u8 = undefined;
    const body = codex.refreshBody(&body_buf, st.creds.refreshToken()) orelse {
        run(model, st.session.onRefreshed(false, "Sign in to ChatGPT in Settings."), fx);
        return;
    };
    st.token_purpose = .refresh;
    postToken(fx, body);
}

fn postToken(fx: *Effects, body: []const u8) void {
    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
    fx.fetch(.{
        .key = token_key,
        .method = .POST,
        .url = codex.token_url,
        .headers = &headers,
        .body = body,
        .timeout_ms = 15000,
        .on_response = Effects.responseMsg(.chatgpt_token_response),
    });
}

fn onToken(model: *Model, response: native_sdk.EffectResponse, fx: *Effects) void {
    const st = &model.chat;
    const purpose = st.token_purpose;
    st.token_purpose = .none;
    const ok = response.outcome == .ok and response.status == 200 and !response.truncated and
        codex.applyTokenResponse(&st.creds, std.heap.page_allocator, response.body, fx.wallMs());
    if (ok) {
        saveCredentials(st);
        st.chatgpt = .signed_in;
        st.note_len = 0;
    } else if (purpose == .sign_in) {
        failSignIn(st, "ChatGPT sign-in could not complete.");
    } else if (response.outcome == .ok and codex.isDeadRefresh(response.body)) {
        signOut(st);
    }
    if (st.session.phase == .refreshing) {
        run(model, st.session.onRefreshed(ok, "Sign in to ChatGPT again in Settings."), fx);
    }
}

fn importCodex(st: *State, fx: *Effects) void {
    const home = app.env_home orelse return;
    var path_buf: [640]u8 = undefined;
    const path = (if (env_codex_home) |dir|
        std.fmt.bufPrint(&path_buf, "{s}/auth.json", .{dir})
    else
        std.fmt.bufPrint(&path_buf, "{s}/.codex/auth.json", .{home})) catch return;
    const bytes = plat.readFileAlloc(std.heap.page_allocator, path, 256 * 1024) orelse
        return setNote(st, "No Codex CLI sign-in was found.");
    defer std.heap.page_allocator.free(bytes);
    if (!codex.importCodexAuth(&st.creds, std.heap.page_allocator, bytes, fx.wallMs()))
        return setNote(st, "Codex CLI is not signed in with a ChatGPT account.");
    saveCredentials(st);
    st.chatgpt = .signed_in;
    // True, not boilerplate: the copy shares Codex's refresh token, and
    // whichever client refreshes first may sign the other out.
    setNote(st, "Copied from Codex CLI. Codex may ask you to sign in again later.");
}

fn signOut(st: *State) void {
    st.creds.clear();
    if (app.env_home) |home| _ = secret_store.delete(home, chatgpt_account);
    st.chatgpt = .signed_out;
    st.note_len = 0;
}

fn loadCredentials(st: *State) void {
    const home = app.env_home orelse return;
    var buf: [16 * 1024]u8 = undefined;
    const stored = secret_store.load(home, chatgpt_account, &buf) orelse return;
    if (codex.deserialize(&st.creds, std.heap.page_allocator, stored)) st.chatgpt = .signed_in;
}

fn saveCredentials(st: *const State) void {
    const home = app.env_home orelse return;
    var buf: [16 * 1024]u8 = undefined;
    const bytes = codex.serialize(&st.creds, &buf) orelse return;
    if (!secret_store.save(home, chatgpt_account, bytes)) std.debug.print("petdex: could not save the ChatGPT session\n", .{});
}

// ── Local server ──────────────────────────────────────────────────────

fn detectModels(st: *State, fx: *Effects) void {
    if (st.detecting) return;
    var url_buf: [320]u8 = undefined;
    const base = std.mem.trimEnd(u8, st.localUrl(), "/");
    if (base.len == 0) return setNote(st, "Set the server URL first.");
    const url = std.fmt.bufPrint(&url_buf, "{s}/models", .{base}) catch return;
    st.detecting = true;
    st.note_len = 0;
    fx.fetch(.{
        .key = models_key,
        .url = url,
        .timeout_ms = 5000,
        .on_response = Effects.responseMsg(.chat_models_response),
    });
}

fn onModels(st: *State, response: native_sdk.EffectResponse) void {
    st.detecting = false;
    if (response.outcome != .ok) return setNote(st, "Could not reach the server. Is it running?");
    if (response.status != 200) return setNote(st, "The server did not list its models.");
    const scratch = std.heap.page_allocator.alloc(u8, 512 * 1024) catch return;
    defer std.heap.page_allocator.free(scratch);
    const id = openai_compat.firstModelId(response.body, scratch) orelse return setNote(st, "The server has no model loaded.");
    setText(&st.local_model, id);
    saveConfig(st);
}

// ── chat.json ─────────────────────────────────────────────────────────

fn configPath(buf: []u8) ?[]const u8 {
    const home = app.env_home orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.petdex/chat.json", .{home}) catch null;
}

fn loadConfig(st: *State) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var cfg: config.Config = .{};
    var path_buf: [512]u8 = undefined;
    if (configPath(&path_buf)) |path| {
        if (plat.readFileAlloc(arena.allocator(), path, 64 * 1024)) |bytes| cfg = config.parse(arena.allocator(), bytes);
    }
    st.kind = cfg.provider;
    setText(&st.local_url, cfg.openai_compat.base_url);
    setText(&st.local_model, cfg.openai_compat.model);
    setText(&st.codex_model, cfg.codex.model);
    st.bubble_excerpt = cfg.bubble_excerpt;
    st.stack = std.math.clamp(cfg.stack, 1, max_stack);
}

fn saveConfig(st: *const State) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var cfg: config.Config = .{ .provider = st.kind, .bubble_excerpt = st.bubble_excerpt, .stack = st.stack };
    cfg.codex.model = st.codexModel();
    cfg.openai_compat.base_url = st.localUrl();
    cfg.openai_compat.model = st.localModel();
    const bytes = config.stringify(arena.allocator(), cfg) orelse return;
    var path_buf: [512]u8 = undefined;
    const path = configPath(&path_buf) orelse return;
    _ = plat.writeFile(path, bytes);
}

fn setField(buf: []u8, len: *usize, value: []const u8) void {
    const kept = domain.utf8Floor(value, buf.len);
    @memcpy(buf[0..kept.len], kept);
    len.* = kept.len;
}

fn setText(buf: anytype, value: []const u8) void {
    buf.set(domain.utf8Floor(value, buf.storage.len));
}

fn setNote(st: *State, message: []const u8) void {
    setField(&st.note, &st.note_len, message);
}

test {
    _ = chat;
}

test "the chat bubble sits beside the pet, its reply level with the pet's top" {
    const pet = Pet{ .x = 100, .y = 200, .w = 134, .h = 146 };
    const right = originBeside(pet, false, 0);
    try std.testing.expectEqual(@as(f64, 100 + 134 + pet_gap), right.x);
    try std.testing.expectEqual(@as(f64, 200), right.y);
    const left = originBeside(pet, true, 0);
    try std.testing.expectEqual(@as(f64, 100 - pet_gap - chat_view.window_w), left.x);
    try std.testing.expectEqual(@as(f64, 200), left.y);
    // Stacked exchanges rise above the pet.
    try std.testing.expectEqual(@as(f64, 80), originBeside(pet, false, 120).y);
}

test "the chat bubble returns right only after the pet leaves the edge" {
    const p = Place{ .left = true, .left_at_x = 1000 };
    try std.testing.expect(keepLeft(p, 1100));
    try std.testing.expect(keepLeft(p, 961));
    try std.testing.expect(!keepLeft(p, 959));
    try std.testing.expect(!keepLeft(.{}, 1000));
}

test "the chat tail points at the pet's head and stays off the corners" {
    // Level with the pet: 30% down a 200pt pet.
    try std.testing.expectEqual(@as(f32, 60), tailY(500, 200, 500, 0, 300));
    // Pushed up by the screen's bottom edge: still the head.
    try std.testing.expectEqual(@as(f32, 160), tailY(500, 200, 400, 0, 300));
    // The ends stay clear of the corner radius.
    try std.testing.expectEqual(@as(f32, 27), tailY(0, 200, 500, 0, 300));
    try std.testing.expectEqual(@as(f32, 273), tailY(900, 200, 0, 0, 300));
    // A card too short for both corners keeps to the first.
    try std.testing.expectEqual(@as(f32, 27), tailY(500, 200, 500, 0, 40));
    // Below stacked exchanges: the reply card, not the window, bounds it.
    try std.testing.expectEqual(@as(f32, 160), tailY(500, 200, 400, 100, 300));
    try std.testing.expectEqual(@as(f32, 127), tailY(500, 200, 500, 100, 300));
}
