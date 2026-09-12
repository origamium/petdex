//! One conversation's state machine: idle, refreshing credentials,
//! streaming a reply, or failed, plus the transcript on screen. It
//! returns Actions and chat_shell turns them into fetches, refreshes,
//! database writes and pet animations — the remote_runtime pattern, so
//! every transition is testable without the SDK.

const std = @import("std");
const domain = @import("domain.zig");
const provider = @import("provider.zig");
const i18n = @import("../i18n.zig");

const Role = domain.Role;
const Message = domain.Message;
const ProviderKind = domain.ProviderKind;

pub const max_messages = 64;
pub const arena_bytes = 64 * 1024;
pub const max_message_bytes = 16 * 1024;
/// One request carries the newest turns that fit both budgets.
pub const context_messages = 20;
pub const context_bytes = 24 * 1024;
/// Far above main.zig's hand-numbered keys and remote_runtime's 1<<40 band.
pub const stream_key_base: u64 = @as(u64, 1) << 41;

pub const Phase = enum { idle, refreshing, streaming, failed };

/// What the app asks the pet for when it speaks first; `none` for a reply
/// to the user.
pub const Prompt = enum {
    none,
    /// A double tap: catch the user up.
    briefing,
    /// Unprompted small talk, on the chatter clock.
    chatter,
    /// A coding agent started waiting on the user.
    nudge,
};

pub const Action = enum {
    none,
    /// Build the request from `context()` and start streaming it.
    request,
    /// Refresh the provider credential, then call `onRefreshed`.
    refresh,
    /// The reply in `lastReply()` is complete.
    done,
    /// `errorText()` says why.
    failed,
};

/// Messages in order over one text arena; the oldest are evicted (and the
/// arena compacted) when either the count or the bytes run out.
pub const Transcript = struct {
    roles: [max_messages]Role = undefined,
    starts: [max_messages]u32 = undefined,
    lens: [max_messages]u32 = undefined,
    count: usize = 0,
    used: usize = 0,
    text: [arena_bytes]u8 = undefined,

    pub fn len(self: *const Transcript) usize {
        return self.count;
    }

    pub fn get(self: *const Transcript, i: usize) Message {
        return .{ .role = self.roles[i], .text = self.text[self.starts[i]..][0..self.lens[i]] };
    }

    pub fn last(self: *const Transcript) ?Message {
        return if (self.count == 0) null else self.get(self.count - 1);
    }

    pub fn clear(self: *Transcript) void {
        self.count = 0;
        self.used = 0;
    }

    pub fn append(self: *Transcript, role: Role, text: []const u8) void {
        const kept = domain.utf8Floor(text, max_message_bytes);
        while (self.count == max_messages or self.used + kept.len > arena_bytes) self.dropOldest();
        self.roles[self.count] = role;
        self.starts[self.count] = @intCast(self.used);
        self.lens[self.count] = @intCast(kept.len);
        @memcpy(self.text[self.used..][0..kept.len], kept);
        self.used += kept.len;
        self.count += 1;
    }

    /// Grows the newest message (it always ends the arena). False when
    /// the per-message cap cut `text`.
    pub fn extendLast(self: *Transcript, text: []const u8) bool {
        if (self.count == 0) return false;
        const room = max_message_bytes - self.lens[self.count - 1];
        const kept = domain.utf8Floor(text, room);
        while (self.used + kept.len > arena_bytes and self.count > 1) self.dropOldest();
        @memcpy(self.text[self.used..][0..kept.len], kept);
        self.lens[self.count - 1] += @intCast(kept.len);
        self.used += kept.len;
        return kept.len == text.len;
    }

    pub fn dropLast(self: *Transcript) void {
        if (self.count == 0) return;
        self.count -= 1;
        self.used = self.starts[self.count];
    }

    fn dropOldest(self: *Transcript) void {
        if (self.count == 0) return;
        const cut: usize = self.lens[0];
        std.mem.copyForwards(u8, self.text[0 .. self.used - cut], self.text[cut..self.used]);
        self.used -= cut;
        for (1..self.count) |i| {
            self.roles[i - 1] = self.roles[i];
            self.starts[i - 1] = self.starts[i] - @as(u32, @intCast(cut));
            self.lens[i - 1] = self.lens[i];
        }
        self.count -= 1;
    }

    /// The newest messages within both budgets, starting on a user turn
    /// (APIs reject, and models misread, a history that opens mid-reply).
    pub fn window(self: *const Transcript, out: []Message, max_count: usize, max_bytes: usize) []Message {
        const limit = @min(max_count, out.len);
        var first = self.count;
        var bytes: usize = 0;
        while (first > 0 and self.count - first < limit) {
            const size = self.lens[first - 1];
            if (bytes + size > max_bytes) break;
            bytes += size;
            first -= 1;
        }
        while (first < self.count and self.roles[first] != .user) first += 1;
        for (first..self.count, 0..) |i, j| out[j] = self.get(i);
        return out[0 .. self.count - first];
    }
};

pub const Session = struct {
    phase: Phase = .idle,
    transcript: Transcript = .{},
    request_id: u32 = 0,
    /// The newest message is the reply being streamed.
    pending: bool = false,
    /// One refresh per request; a second 401 is a failure.
    retried: bool = false,
    /// The provider reported a failure inside a 2xx stream.
    stream_failed: bool = false,
    /// Part of the last reply was lost to the SDK's line bounds.
    lost_text: bool = false,
    /// The pet speaks first: the shell ends the request with the app's
    /// prompt of this kind, and no user turn enters the transcript.
    prompt: Prompt = .none,
    /// The key of the request still open on the wire, until its terminal
    /// Msg arrives. A stopped or reset request keeps it: its fetch winds
    /// down asynchronously, and nothing new goes out before it has, so the
    /// server never answers two at once.
    wire: ?u64 = null,
    err_buf: [192]u8 = undefined,
    err_len: usize = 0,

    pub fn busy(self: *const Session) bool {
        return self.phase == .streaming or self.phase == .refreshing;
    }

    /// Nothing streaming, refreshing, or still winding down.
    fn canSend(self: *const Session) bool {
        return !self.busy() and self.wire == null;
    }

    /// The fetch with `key` has ended, a cancelled one included.
    pub fn settle(self: *Session, key: u64) void {
        if (self.wire == key) self.wire = null;
    }

    /// Nothing on screen asked for this request: the pet spoke unprompted.
    pub fn proactive(self: *const Session) bool {
        return self.prompt == .chatter or self.prompt == .nudge;
    }

    /// Let a failed unprompted request pass as if it never went out: no
    /// error row and no Retry for something the user never asked for.
    pub fn quiet(self: *Session) void {
        if (self.phase == .failed) self.phase = .idle;
        self.err_len = 0;
        self.prompt = .none;
    }

    /// The effect key of the current stream. Anything tagged with an
    /// older key (a stopped or superseded stream) is ignored.
    pub fn streamKey(self: *const Session) u64 {
        return stream_key_base + self.request_id;
    }

    pub fn errorText(self: *const Session) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    /// Waiting for the first words of a reply.
    pub fn thinking(self: *const Session) bool {
        return self.busy() and !self.pending;
    }

    pub fn context(self: *const Session, out: *[context_messages]Message) []const Message {
        return self.transcript.window(out, context_messages, context_bytes);
    }

    pub fn lastReply(self: *const Session) ?[]const u8 {
        const m = self.transcript.last() orelse return null;
        return if (m.role == .assistant) m.text else null;
    }

    /// The reply the pet is saying now: the one streaming, or the last
    /// one once idle. None while a request waits for its first words
    /// (a briefing leaves the previous reply newest) or after a failure.
    pub fn currentReply(self: *const Session) ?[]const u8 {
        if (self.phase == .failed or self.thinking()) return null;
        return self.lastReply();
    }

    /// Replace the transcript (history restored, pet switched).
    pub fn load(self: *Session, messages: []const Message) void {
        self.* = .{ .request_id = self.request_id +% 1, .wire = self.wire };
        for (messages) |m| self.transcript.append(m.role, m.text);
    }

    pub fn submit(self: *Session, text: []const u8, needs_refresh: bool) Action {
        if (!self.canSend()) return .none;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return .none;
        self.transcript.append(.user, trimmed);
        self.prompt = .none;
        return self.begin(needs_refresh);
    }

    /// Re-send after a failure: the user's message is still the newest,
    /// or the failed request was a briefing.
    pub fn retry(self: *Session, needs_refresh: bool) Action {
        if (self.phase != .failed or !self.canSend()) return .none;
        if (self.prompt == .none) {
            const m = self.transcript.last() orelse return .none;
            if (m.role != .user) return .none;
        }
        return self.begin(needs_refresh);
    }

    /// Let the pet speak first: a request with no new user turn, which
    /// the shell completes with the app's `prompt`. The reply lands like
    /// any other.
    pub fn brief(self: *Session, prompt: Prompt, needs_refresh: bool) Action {
        if (!self.canSend()) return .none;
        self.prompt = prompt;
        return self.begin(needs_refresh);
    }

    pub fn onLine(self: *Session, kind: ProviderKind, key: u64, line: []const u8, truncated: bool, dropped: bool, scratch: []u8) void {
        if (key != self.streamKey() or self.phase != .streaming) return;
        if (dropped) self.lost_text = true;
        if (truncated) {
            // Only a cut delta loses words; codex's closing event repeats
            // the whole reply and is routinely longer than the bound.
            if (provider.carriesText(kind, line)) self.lost_text = true;
            return;
        }
        const event = provider.parseLine(kind, line, scratch) orelse {
            // A non-2xx reply arrives as ordinary lines: keep its start
            // for the error row.
            if (!provider.isSseFraming(line) and self.err_len == 0) self.setError(line);
            return;
        };
        switch (event) {
            .delta => |text| {
                if (!self.pending) {
                    self.transcript.append(.assistant, "");
                    self.pending = true;
                }
                if (!self.transcript.extendLast(text)) self.lost_text = true;
            },
            .done => {},
            .failed => |message| {
                self.stream_failed = true;
                self.setError(message);
            },
        }
    }

    /// The fetch's terminal Msg. `transport_error` is set when no HTTP
    /// status arrived at all (refused, timed out, TLS).
    pub fn onResponse(self: *Session, kind: ProviderKind, key: u64, status: u16, transport_error: ?[]const u8) Action {
        self.settle(key);
        if (key != self.streamKey() or self.phase != .streaming) return .none;
        if (transport_error) |message| return self.fail(message);
        if (status >= 200 and status < 300 and !self.stream_failed) {
            if (!self.pending) return self.fail(i18n.t("The reply was empty.", "返事が空でした。"));
            self.pending = false;
            self.phase = .idle;
            return .done;
        }
        if (provider.authExpired(kind, status) and !self.retried) {
            self.retried = true;
            self.dropPending();
            self.err_len = 0;
            self.phase = .refreshing;
            return .refresh;
        }
        if (self.err_len == 0) {
            var buf: [64]u8 = undefined;
            self.setError(i18n.bufPrint(&buf, "The server answered HTTP {d}.", "サーバーがHTTP {d}を返しました。", .{status}) catch i18n.t("The request failed.", "リクエストに失敗しました。"));
        }
        return self.fail(null);
    }

    pub fn onRefreshed(self: *Session, ok: bool, failure: []const u8) Action {
        if (self.phase != .refreshing) return .none;
        if (!ok) return self.fail(failure);
        return self.startRequest();
    }

    /// Stop. What already arrived stays on screen but is not saved.
    pub fn cancel(self: *Session) void {
        if (!self.busy()) return;
        self.request_id +%= 1;
        self.pending = false;
        self.phase = .idle;
    }

    fn begin(self: *Session, needs_refresh: bool) Action {
        self.retried = false;
        self.lost_text = false;
        self.err_len = 0;
        if (needs_refresh) {
            self.phase = .refreshing;
            return .refresh;
        }
        return self.startRequest();
    }

    fn startRequest(self: *Session) Action {
        self.request_id +%= 1;
        self.stream_failed = false;
        self.phase = .streaming;
        self.wire = self.streamKey();
        return .request;
    }

    fn fail(self: *Session, message: ?[]const u8) Action {
        if (message) |m| self.setError(m);
        self.dropPending();
        self.phase = .failed;
        return .failed;
    }

    fn dropPending(self: *Session) void {
        if (self.pending) self.transcript.dropLast();
        self.pending = false;
    }

    fn setError(self: *Session, message: []const u8) void {
        const kept = domain.utf8Floor(std.mem.trim(u8, message, " \t\r\n"), self.err_buf.len);
        @memcpy(self.err_buf[0..kept.len], kept);
        self.err_len = kept.len;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

const t = std.testing;

fn deltaLine(buf: []u8, text: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}", .{text}) catch unreachable;
}

fn newSession() *Session {
    const s = t.allocator.create(Session) catch unreachable;
    s.* = .{};
    return s;
}

test "the current reply is the one being said, none while thinking or failed" {
    const s = newSession();
    defer t.allocator.destroy(s);
    s.transcript.append(.user, "hi");
    s.transcript.append(.assistant, "hey");
    try t.expectEqualStrings("hey", s.currentReply().?);
    _ = s.brief(.briefing, false);
    try t.expect(s.currentReply() == null);
    _ = s.onResponse(.openai_compat, s.streamKey(), 0, "down");
    try t.expect(s.currentReply() == null);
    try t.expectEqualStrings("hey", s.lastReply().?);
}

test "a briefing streams a reply without a user turn and can be retried" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    var line: [256]u8 = undefined;

    s.transcript.append(.user, "hi");
    s.transcript.append(.assistant, "hey");
    try t.expectEqual(Action.request, s.brief(.briefing, false));
    try t.expectEqual(Prompt.briefing, s.prompt);
    try t.expectEqual(@as(usize, 2), s.transcript.len());
    try t.expectEqual(Action.failed, s.onResponse(.openai_compat, s.streamKey(), 0, "down"));
    try t.expectEqual(Action.request, s.retry(false));
    const key = s.streamKey();
    s.onLine(.openai_compat, key, deltaLine(&line, "Claude is waiting."), false, false, &scratch);
    try t.expectEqual(Action.done, s.onResponse(.openai_compat, key, 200, null));
    try t.expectEqualStrings("Claude is waiting.", s.lastReply().?);
    try t.expectEqual(Action.request, s.submit("thanks", false));
    try t.expectEqual(Prompt.none, s.prompt);
}

test "unprompted small talk that fails passes quietly" {
    const s = newSession();
    defer t.allocator.destroy(s);
    s.transcript.append(.user, "hi");
    s.transcript.append(.assistant, "hey");
    try t.expectEqual(Action.request, s.brief(.chatter, false));
    try t.expect(s.proactive());
    try t.expectEqual(Action.failed, s.onResponse(.openai_compat, s.streamKey(), 0, "down"));
    s.quiet();
    try t.expectEqual(Phase.idle, s.phase);
    try t.expectEqualStrings("", s.errorText());
    try t.expectEqual(Action.none, s.retry(false));
    try t.expectEqualStrings("hey", s.currentReply().?);
}

test "one request on the wire at a time" {
    const s = newSession();
    defer t.allocator.destroy(s);

    try t.expectEqual(Action.request, s.submit("hi", false));
    const first = s.streamKey();
    // A double tap while the reply streams.
    try t.expectEqual(Action.none, s.brief(.briefing, false));
    // Stopped, but its fetch has not wound down yet.
    s.cancel();
    try t.expectEqual(Action.none, s.submit("again", false));
    try t.expectEqual(Action.none, s.brief(.briefing, false));
    // New Chat and a pet switch reset the transcript, not the wire.
    s.load(&.{});
    try t.expectEqual(Action.none, s.submit("again", false));
    s.settle(first);
    try t.expectEqual(Action.request, s.submit("again", false));
}

test "a reply streams into the transcript and completes" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    var line: [256]u8 = undefined;

    try t.expectEqual(Action.none, s.submit("   ", false));
    try t.expectEqual(Action.request, s.submit(" hi ", false));
    try t.expectEqual(Phase.streaming, s.phase);
    try t.expect(s.thinking());
    const key = s.streamKey();
    s.onLine(.openai_compat, key, "", false, false, &scratch);
    s.onLine(.openai_compat, key, deltaLine(&line, "Hel"), false, false, &scratch);
    try t.expect(!s.thinking());
    s.onLine(.openai_compat, key, deltaLine(&line, "lo"), false, false, &scratch);
    s.onLine(.openai_compat, key, "data: [DONE]", false, false, &scratch);
    try t.expectEqual(Action.done, s.onResponse(.openai_compat, key, 200, null));
    try t.expectEqual(Phase.idle, s.phase);
    try t.expectEqualStrings("Hello", s.lastReply().?);
    try t.expectEqualStrings("hi", s.transcript.get(0).text);
    try t.expect(!s.lost_text);
}

test "a codex 401 refreshes once and retries; a second 401 fails" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;

    try t.expectEqual(Action.request, s.submit("hi", false));
    const first = s.streamKey();
    s.onLine(.codex, first, "{\"detail\":\"Unauthorized\"}", false, false, &scratch);
    try t.expectEqual(Action.refresh, s.onResponse(.codex, first, 401, null));
    try t.expectEqual(Phase.refreshing, s.phase);
    try t.expectEqualStrings("", s.errorText());
    try t.expectEqual(Action.request, s.onRefreshed(true, ""));
    const second = s.streamKey();
    try t.expect(second != first);
    try t.expectEqual(Action.failed, s.onResponse(.codex, second, 401, null));
    try t.expectEqual(Phase.failed, s.phase);
    try t.expectEqualStrings("The server answered HTTP 401.", s.errorText());
}

test "a local 401 fails immediately and keeps the server's message" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    _ = s.submit("hi", false);
    const key = s.streamKey();
    s.onLine(.openai_compat, key, "{\"error\":\"Invalid API key\"}", false, false, &scratch);
    try t.expectEqual(Action.failed, s.onResponse(.openai_compat, key, 401, null));
    try t.expectEqualStrings("{\"error\":\"Invalid API key\"}", s.errorText());
}

test "expiring credentials refresh before the first request" {
    const s = newSession();
    defer t.allocator.destroy(s);
    try t.expectEqual(Action.refresh, s.submit("hi", true));
    try t.expectEqual(Action.none, s.submit("again", false));
    try t.expectEqual(Action.failed, s.onRefreshed(false, "Sign in to ChatGPT again."));
    try t.expectEqualStrings("Sign in to ChatGPT again.", s.errorText());
    try t.expectEqual(Action.request, s.retry(false));
}

test "stale keys are ignored after stop" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    var line: [256]u8 = undefined;
    _ = s.submit("hi", false);
    const key = s.streamKey();
    s.onLine(.openai_compat, key, deltaLine(&line, "partial"), false, false, &scratch);
    s.cancel();
    try t.expectEqual(Phase.idle, s.phase);
    s.onLine(.openai_compat, key, deltaLine(&line, " more"), false, false, &scratch);
    try t.expectEqual(Action.none, s.onResponse(.openai_compat, key, 200, null));
    try t.expectEqualStrings("partial", s.lastReply().?);
}

test "empty replies, transport errors and in-stream failures fail and drop the partial" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    var line: [256]u8 = undefined;

    _ = s.submit("hi", false);
    try t.expectEqual(Action.failed, s.onResponse(.openai_compat, s.streamKey(), 200, null));
    try t.expectEqualStrings("The reply was empty.", s.errorText());

    try t.expectEqual(Action.request, s.retry(false));
    s.onLine(.openai_compat, s.streamKey(), deltaLine(&line, "half"), false, false, &scratch);
    try t.expectEqual(Action.failed, s.onResponse(.openai_compat, s.streamKey(), 0, "Could not reach the server."));
    try t.expectEqual(Role.user, s.transcript.last().?.role);

    try t.expectEqual(Action.request, s.retry(false));
    s.onLine(.codex, s.streamKey(), "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Usage limit reached\"}}}", false, false, &scratch);
    try t.expectEqual(Action.failed, s.onResponse(.codex, s.streamKey(), 200, null));
    try t.expectEqualStrings("Usage limit reached", s.errorText());
}

test "truncated and dropped lines are flagged, never parsed" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    var line: [256]u8 = undefined;
    _ = s.submit("hi", false);
    s.onLine(.openai_compat, s.streamKey(), "data: {\"choices\":[{\"delta\":{\"content\":\"cut", true, false, &scratch);
    try t.expect(s.lost_text);
    s.onLine(.openai_compat, s.streamKey(), deltaLine(&line, "ok"), false, true, &scratch);
    try t.expectEqual(Action.done, s.onResponse(.openai_compat, s.streamKey(), 200, null));
    try t.expectEqualStrings("ok", s.lastReply().?);
}

test "transcript evicts by count and by bytes, and caps a message on a UTF-8 boundary" {
    const tr = try t.allocator.create(Transcript);
    defer t.allocator.destroy(tr);
    tr.* = .{};
    for (0..max_messages + 5) |i| tr.append(if (i % 2 == 0) .user else .assistant, "x");
    try t.expectEqual(@as(usize, max_messages), tr.len());

    tr.clear();
    const big = "a" ** (max_message_bytes);
    for (0..5) |_| tr.append(.user, big);
    try t.expectEqual(@as(usize, arena_bytes / max_message_bytes), tr.len());
    try t.expect(tr.used <= arena_bytes);

    tr.clear();
    tr.append(.assistant, "");
    const kana = "あ" ** (max_message_bytes / 3 + 1);
    try t.expect(!tr.extendLast(kana));
    try t.expect(tr.last().?.text.len <= max_message_bytes);
    try t.expect(std.unicode.utf8ValidateSlice(tr.last().?.text));
}

test "extending the newest message evicts older ones, not itself" {
    const tr = try t.allocator.create(Transcript);
    defer t.allocator.destroy(tr);
    tr.* = .{};
    const chunk = "b" ** (max_message_bytes);
    for (0..3) |_| tr.append(.user, chunk);
    tr.append(.assistant, "");
    try t.expect(tr.extendLast(chunk));
    try t.expectEqual(Role.assistant, tr.last().?.role);
    try t.expectEqual(@as(usize, max_message_bytes), tr.last().?.text.len);
    try t.expectEqualStrings(chunk, tr.get(0).text);
}

test "the context window respects both budgets and opens on a user turn" {
    const tr = try t.allocator.create(Transcript);
    defer t.allocator.destroy(tr);
    tr.* = .{};
    // 31 turns ending on a user one: the newest 20 open on an assistant
    // turn, which is dropped.
    for (0..31) |i| tr.append(if (i % 2 == 0) .user else .assistant, "m");
    var out: [context_messages]Message = undefined;
    const w = tr.window(&out, context_messages, context_bytes);
    try t.expectEqual(@as(usize, context_messages - 1), w.len);
    try t.expectEqual(Role.user, w[0].role);

    tr.clear();
    tr.append(.user, "a" ** 10);
    tr.append(.assistant, "b" ** 10);
    tr.append(.user, "c" ** 10);
    const tight = tr.window(&out, context_messages, 25);
    try t.expectEqual(@as(usize, 1), tight.len);
    try t.expectEqualStrings("c" ** 10, tight[0].text);
}

test "a truncated closing event is not lost text; a truncated delta is" {
    const s = newSession();
    defer t.allocator.destroy(s);
    var scratch: [1024]u8 = undefined;
    _ = s.submit("hi", false);
    s.onLine(.codex, s.streamKey(), "data: {\"type\":\"response.completed\",\"response\":{\"output\":[", true, false, &scratch);
    try t.expect(!s.lost_text);
    s.onLine(.codex, s.streamKey(), "data: {\"type\":\"response.output_text.delta\",\"delta\":\"abc", true, false, &scratch);
    try t.expect(s.lost_text);
}

test "load replaces the transcript and invalidates any stream" {
    const s = newSession();
    defer t.allocator.destroy(s);
    _ = s.submit("hi", false);
    const old = s.streamKey();
    s.load(&.{ .{ .role = .user, .text = "q" }, .{ .role = .assistant, .text = "a" } });
    try t.expectEqual(Phase.idle, s.phase);
    try t.expect(s.streamKey() != old);
    try t.expectEqual(@as(usize, 2), s.transcript.len());
    try t.expectEqualStrings("a", s.lastReply().?);
}
