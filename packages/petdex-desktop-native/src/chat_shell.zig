//! The effects side of the pet chat. Turns chat/session Actions into
//! fetches and pet animations, keeps chat.json, the ChatGPT credentials
//! and the history database, and runs ChatGPT sign-in. The only chat
//! module that knows the SDK, the Model or the filesystem; the rules it
//! executes live in src/chat/, which stays pure.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const app = @import("main.zig");
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
pub const window_w: f32 = 360;
pub const window_h: f32 = 520;
/// Space between the pet and the chat window it opens beside.
pub const pet_gap: f32 = 12;
/// Two taps on the pet within this window open the chat.
pub const double_tap_ms: i64 = 350;

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
    /// The window was just declared and still needs to be moved beside
    /// the pet (poll does it once the platform has created it).
    place_pending: bool = false,
    place_tries: u8 = 0,
    place_left: bool = false,

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
var override_buf: [persona.max_bytes]u8 = undefined;
var persona_buf: [persona.max_bytes]u8 = undefined;
var persona_len: usize = 0;
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
    if (model.chat.place_pending) placeBesidePet(model, fx);
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
        .chat_closed => st.open = false,
        .chat_input => |edit| st.input.apply(edit),
        .chat_submit => submit(model, fx),
        .chat_stop => stop(model, fx),
        .chat_clear => clear(model, fx),
        .chat_retry => run(model, st.session.retry(needsRefresh(st, fx)), fx),
        .chat_scrolled => |scroll| st.scroll = scroll.offset,
        .chat_line => |line| st.session.onLine(st.stream_kind, line.key, line.line, line.truncated, line.dropped_before > 0, &parse_scratch),
        .chat_response => |response| onResponse(model, response, fx),
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

fn open(model: *Model, fx: *Effects) void {
    syncPet(model, fx);
    const st = &model.chat;
    if (st.open) {
        fx.focusWindow(window_label);
        return;
    }
    st.scroll = 0;
    st.place_pending = true;
    st.place_tries = 0;
    st.place_left = false;
    st.open = true;
}

/// Move the new window beside the pet, bottom-aligned with it. Read
/// both live origins and close the gap, like the bubble does: descriptor
/// coordinates are only a creation hint, and displays can sit at
/// negative offsets. Clamped moves keep it on the pet's screen.
fn placeBesidePet(model: *Model, fx: *Effects) void {
    const st = &model.chat;
    const chat_origin = fx.moveWindow(window_label, 0, 0, false) orelse return; // not created yet
    const pet_origin = fx.moveWindow("main", 0, 0, false) orelse return;
    const pet_w = app.frame_w * model.scale;
    const pet_h = app.frame_h * model.scale;
    // Vertical centers line up. `origin + h/2` is the center whether the
    // host's y axis points up (AppKit) or down, so no per-OS flip.
    const want_y = pet_origin.y + pet_h / 2 - window_h / 2;
    // Right of the pet, or left when the screen edge is in the way.
    const want_x = if (st.place_left)
        pet_origin.x - pet_gap - window_w
    else
        pet_origin.x + pet_w + pet_gap;
    // The platform may still settle a new window after its first frame
    // (AppKit cascades it), which would undo one relative move, so keep
    // closing the gap for a few ticks.
    if ((@abs(chat_origin.x - want_x) < 1 and @abs(chat_origin.y - want_y) < 1) or st.place_tries >= place_try_budget) {
        st.place_pending = false;
        return;
    }
    st.place_tries += 1;
    const moved = fx.moveWindow(window_label, want_x - chat_origin.x, want_y - chat_origin.y, true) orelse return;
    // A clamped move that fell short horizontally means no room on this
    // side: try the other one.
    if (!st.place_left and @abs(moved.x - want_x) >= 1) st.place_left = true;
}

/// Poll ticks (100 ms each) spent placing a newly opened window.
const place_try_budget: u8 = 10;

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
    var override: ?[]const u8 = null;
    if (app.env_home) |home| {
        var path_buf: [640]u8 = undefined;
        if (std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}/pet.json", .{ home, root, st.petSlug() })) |path| {
            if (plat.readFile(path, &file_buf)) |json| info = persona.petInfo(json, &parse_scratch);
        } else |_| {}
        if (std.fmt.bufPrint(&path_buf, "{s}/.petdex/personas/{s}.md", .{ home, st.petSlug() })) |path| {
            override = plat.readFile(path, &override_buf);
        } else |_| {}
    }
    persona_len = persona.build(&persona_buf, st.petSlug(), info, override).len;
    setField(&st.pet_name, &st.pet_name_len, info.name orelse st.petSlug());
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
    if (st.session.transcript.last()) |m| {
        if (ensureHistory()) |h| _ = h.append(st.petSlug(), .user, m.text, st.kind, fx.wallMs());
    }
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
    const turns = st.session.context(&context);
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
}

fn saveConfig(st: *const State) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var cfg: config.Config = .{ .provider = st.kind, .bubble_excerpt = st.bubble_excerpt };
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
