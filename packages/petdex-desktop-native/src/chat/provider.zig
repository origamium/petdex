//! The provider port. Every backend is one request builder plus one
//! stream-line parser, dispatched over the closed `ProviderKind`.
//! Adding a backend means a new adapter file and one arm per switch
//! here; the session and the shell never learn backend details.

const std = @import("std");
const domain = @import("domain.zig");
const codex = @import("codex.zig");
const openai_compat = @import("openai_compat.zig");

const ProviderKind = domain.ProviderKind;
const Message = domain.Message;
const StreamEvent = domain.StreamEvent;

/// The SDK copies at most `max_effect_fetch_headers` (8) per fetch.
pub const max_headers = 6;
/// The context window (session.context_bytes) plus persona and JSON
/// framing always fits; a request that would not is refused, not cut.
pub const max_body_bytes = 64 * 1024;

pub const Auth = struct {
    /// Bearer token; empty sends no Authorization header.
    bearer: []const u8 = "",
    /// ChatGPT workspace/account id (codex only).
    account_id: []const u8 = "",
};

pub const Target = struct {
    base_url: []const u8,
    /// Empty lets servers that allow it (LM Studio) use the loaded model.
    model: []const u8,
    /// Server-side prompt cache key (codex only).
    cache_key: []const u8 = "",
};

/// Backing storage for one request. Large, so the shell keeps a single
/// module-level instance; the returned Request borrows from it.
pub const Bufs = struct {
    url: [512]u8 = undefined,
    auth: [8200]u8 = undefined,
    headers: [max_headers]std.http.Header = undefined,
    body: [max_body_bytes]u8 = undefined,
};

pub const Request = struct {
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
};

pub fn buildRequest(kind: ProviderKind, target: Target, auth: Auth, persona: []const u8, history: []const Message, bufs: *Bufs) ?Request {
    return switch (kind) {
        .codex => codex.buildRequest(target, auth, persona, history, bufs),
        .openai_compat => openai_compat.buildRequest(target, auth, persona, history, bufs),
    };
}

/// One line of the streamed response. `scratch` backs decoded text in
/// the returned event; both are valid only until the next call.
pub fn parseLine(kind: ProviderKind, line: []const u8, scratch: []u8) ?StreamEvent {
    return switch (kind) {
        .codex => codex.parseLine(line, scratch),
        .openai_compat => openai_compat.parseLine(line, scratch),
    };
}

/// Whether a (possibly truncated) line is one that carries reply text,
/// so losing its tail loses words.
pub fn carriesText(kind: ProviderKind, line: []const u8) bool {
    return switch (kind) {
        .codex => codex.carriesText(line),
        .openai_compat => sseData(line) != null,
    };
}

/// A status that a credential refresh can fix. Local servers have no
/// refreshable credential, so for them a 401 is a plain failure.
pub fn authExpired(kind: ProviderKind, status: u16) bool {
    return kind == .codex and status == 401;
}

/// Payload of an SSE `data:` line; null for every other line.
pub fn sseData(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (!std.mem.startsWith(u8, trimmed, "data:")) return null;
    const rest = trimmed["data:".len..];
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

/// Part of the SSE framing (a field, a comment or the blank separator).
/// Anything else in a response body is the body of an error reply.
pub fn isSseFraming(line: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len == 0 or trimmed[0] == ':') return true;
    for ([_][]const u8{ "data:", "event:", "id:", "retry:" }) |field| {
        if (std.mem.startsWith(u8, trimmed, field)) return true;
    }
    return false;
}

/// Shared by the adapters: fill `bufs.headers` in order.
pub const HeaderList = struct {
    bufs: *Bufs,
    len: usize = 0,

    pub fn add(self: *HeaderList, name: []const u8, value: []const u8) void {
        std.debug.assert(self.len < max_headers);
        self.bufs.headers[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    pub fn slice(self: *const HeaderList) []const std.http.Header {
        return self.bufs.headers[0..self.len];
    }
};

/// "Bearer <token>" in `bufs.auth`.
pub fn bearerValue(bufs: *Bufs, token: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(&bufs.auth, "Bearer {s}", .{token}) catch null;
}

/// `base` with any trailing slash removed, then `path`.
pub fn joinUrl(bufs: *Bufs, base: []const u8, path: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    if (trimmed.len == 0) return null;
    return std.fmt.bufPrint(&bufs.url, "{s}{s}", .{ trimmed, path }) catch null;
}

test "sseData strips the field name and one optional space" {
    const t = std.testing;
    try t.expectEqualStrings("{\"a\":1}", sseData("data: {\"a\":1}").?);
    try t.expectEqualStrings("{\"a\":1}", sseData("data:{\"a\":1}\r").?);
    try t.expectEqualStrings(" x", sseData("data:  x").?);
    try t.expectEqualStrings("", sseData("data:").?);
    try t.expect(sseData("event: response.created") == null);
    try t.expect(sseData(": keepalive") == null);
    try t.expect(sseData("") == null);
}

test "isSseFraming separates stream framing from error bodies" {
    const t = std.testing;
    try t.expect(isSseFraming(""));
    try t.expect(isSseFraming("\r"));
    try t.expect(isSseFraming("event: response.created"));
    try t.expect(isSseFraming(": ping"));
    try t.expect(isSseFraming("data: {}"));
    try t.expect(!isSseFraming("{\"detail\":\"Unauthorized\"}"));
    try t.expect(!isSseFraming("Bad Gateway"));
}

test "joinUrl tolerates a trailing slash and refuses an empty base" {
    var bufs: Bufs = .{};
    try std.testing.expectEqualStrings("http://h/v1/x", joinUrl(&bufs, "http://h/v1/", "/x").?);
    try std.testing.expectEqualStrings("http://h/v1/x", joinUrl(&bufs, "http://h/v1", "/x").?);
    try std.testing.expect(joinUrl(&bufs, "", "/x") == null);
}

test "only codex treats 401 as refreshable" {
    try std.testing.expect(authExpired(.codex, 401));
    try std.testing.expect(!authExpired(.codex, 403));
    try std.testing.expect(!authExpired(.openai_compat, 401));
}
