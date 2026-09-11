//! ChatGPT-subscription adapter, the way Codex CLI (and OpenClaw, pi)
//! do it: Codex's public OAuth client signs the user in with PKCE on a
//! fixed loopback redirect, and replies stream from the Codex Responses
//! backend with the account id taken from the access token. None of it
//! is a documented public API, so every value that could change on
//! OpenAI's side lives in this file and nowhere else.

const std = @import("std");
const domain = @import("domain.zig");
const provider = @import("provider.zig");

const Message = domain.Message;
const StreamEvent = domain.StreamEvent;

pub const issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
/// Registered for the client; the port cannot be chosen.
pub const callback_port: u16 = 1455;
pub const callback_path = "/auth/callback";
pub const redirect_uri = "http://localhost:1455/auth/callback";
pub const token_url = issuer ++ "/oauth/token";
pub const base_url = "https://chatgpt.com/backend-api/codex";
/// "Fast and affordable" in Codex's own catalog
/// (codex-rs/models-manager/models.json); a pet's small talk needs no
/// frontier model. Users can type any slug in Settings.
pub const default_model = "gpt-5.6-luna";
const scope = "openid profile email offline_access";
/// Sent as-is so OpenAI can tell Petdex traffic apart from Codex's.
const originator = "petdex";
const auth_claim = "https://api.openai.com/auth";
/// Refresh ahead of expiry so a reply never starts on a dying token.
const refresh_slack_ms: i64 = 5 * 60 * 1000;

// ── Inference ─────────────────────────────────────────────────────────

pub fn buildRequest(target: provider.Target, auth: provider.Auth, persona: []const u8, history: []const Message, bufs: *provider.Bufs) ?provider.Request {
    if (auth.bearer.len == 0 or auth.account_id.len == 0) return null;
    const url = provider.joinUrl(bufs, target.base_url, "/responses") orelse return null;
    var headers: provider.HeaderList = .{ .bufs = bufs };
    headers.add("authorization", provider.bearerValue(bufs, auth.bearer) orelse return null);
    headers.add("chatgpt-account-id", auth.account_id);
    headers.add("openai-beta", "responses=experimental");
    headers.add("originator", originator);
    headers.add("accept", "text/event-stream");
    headers.add("content-type", "application/json");

    var w: std.Io.Writer = .fixed(&bufs.body);
    writeBody(&w, target, persona, history) catch return null;
    return .{ .url = url, .headers = headers.slice(), .body = w.buffered() };
}

fn writeBody(w: *std.Io.Writer, target: provider.Target, persona: []const u8, history: []const Message) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("model");
    try s.write(target.model);
    try s.objectField("store");
    try s.write(false);
    try s.objectField("stream");
    try s.write(true);
    try s.objectField("instructions");
    try s.write(persona);
    try s.objectField("input");
    try s.beginArray();
    for (history) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.wireName());
        try s.objectField("content");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write(@as([]const u8, if (m.role == .user) "input_text" else "output_text"));
        try s.objectField("text");
        try s.write(m.text);
        try s.endObject();
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("text");
    try s.beginObject();
    try s.objectField("verbosity");
    try s.write(@as([]const u8, "low"));
    try s.endObject();
    if (target.cache_key.len > 0) {
        try s.objectField("prompt_cache_key");
        try s.write(target.cache_key);
    }
    try s.endObject();
}

const DeltaEvent = struct { delta: []const u8 = "" };
const FailedEvent = struct {
    response: struct {
        @"error": ?struct { message: []const u8 = "" } = null,
    } = .{},
};
const ErrorEvent = struct {
    message: []const u8 = "",
    @"error": ?struct { message: []const u8 = "" } = null,
};

pub fn parseLine(line: []const u8, scratch: []u8) ?StreamEvent {
    const data = provider.sseData(line) orelse return null;
    // Read the type before parsing anything: `response.completed` repeats
    // the whole reply and can exceed the SDK's line bound, and nothing in
    // it is needed — the reply already arrived as deltas.
    const kind = eventType(data) orelse return null;
    if (std.mem.eql(u8, kind, "response.output_text.delta")) {
        const ev = parseJson(DeltaEvent, data, scratch) orelse return null;
        return if (ev.delta.len > 0) .{ .delta = ev.delta } else null;
    }
    if (std.mem.eql(u8, kind, "response.completed") or
        std.mem.eql(u8, kind, "response.done") or
        std.mem.eql(u8, kind, "response.incomplete")) return .done;
    if (std.mem.eql(u8, kind, "response.failed")) {
        const ev = parseJson(FailedEvent, data, scratch) orelse return .{ .failed = generic_failure };
        const err = ev.response.@"error" orelse return .{ .failed = generic_failure };
        return .{ .failed = if (err.message.len > 0) err.message else generic_failure };
    }
    if (std.mem.eql(u8, kind, "error")) {
        const ev = parseJson(ErrorEvent, data, scratch) orelse return .{ .failed = generic_failure };
        if (ev.message.len > 0) return .{ .failed = ev.message };
        if (ev.@"error") |err| if (err.message.len > 0) return .{ .failed = err.message };
        return .{ .failed = generic_failure };
    }
    return null;
}

const generic_failure = "ChatGPT could not finish the reply.";

/// The type leads every event, so even a truncated line says whether it
/// was a text delta.
pub fn carriesText(line: []const u8) bool {
    const data = provider.sseData(line) orelse return false;
    const kind = eventType(data) orelse return false;
    return std.mem.eql(u8, kind, "response.output_text.delta");
}

/// The top-level `"type"` value. OpenAI serializes it first, so the
/// first occurrence is the event's own, never a nested one.
fn eventType(data: []const u8) ?[]const u8 {
    const key = "\"type\":";
    const at = std.mem.indexOf(u8, data, key) orelse return null;
    var rest = std.mem.trimStart(u8, data[at + key.len ..], " ");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn parseJson(comptime T: type, data: []const u8, scratch: []u8) ?T {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return std.json.parseFromSliceLeaky(T, fba.allocator(), data, .{ .ignore_unknown_fields = true }) catch null;
}

// ── Sign-in ───────────────────────────────────────────────────────────

pub fn authorizeUrl(buf: []u8, challenge: []const u8, state: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeAuthorizeUrl(&w, challenge, state) catch return null;
    return w.buffered();
}

fn writeAuthorizeUrl(w: *std.Io.Writer, challenge: []const u8, state: []const u8) !void {
    try w.print("{s}/oauth/authorize?response_type=code&client_id={s}&redirect_uri=", .{ issuer, client_id });
    try percentEncode(w, redirect_uri);
    try w.writeAll("&scope=");
    try percentEncode(w, scope);
    try w.writeAll("&code_challenge=");
    try percentEncode(w, challenge);
    try w.writeAll("&code_challenge_method=S256&id_token_add_organizations=true&codex_cli_simplified_flow=true&state=");
    try percentEncode(w, state);
    try w.print("&originator={s}", .{originator});
}

/// Form body for exchanging the callback's code.
pub fn tokenBody(buf: []u8, code: []const u8, verifier: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeForm(&w, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", code },
        .{ "redirect_uri", redirect_uri },
        .{ "client_id", client_id },
        .{ "code_verifier", verifier },
    }) catch return null;
    return w.buffered();
}

pub fn refreshBody(buf: []u8, refresh_token: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeForm(&w, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", refresh_token },
        .{ "client_id", client_id },
    }) catch return null;
    return w.buffered();
}

fn writeForm(w: *std.Io.Writer, fields: []const [2][]const u8) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try w.writeByte('&');
        try w.writeAll(field[0]);
        try w.writeByte('=');
        try percentEncode(w, field[1]);
    }
}

fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// A refresh the server refused for good (revoked, expired, or rotated
/// away by another client such as Codex CLI): retrying cannot help.
pub fn isDeadRefresh(body: []const u8) bool {
    for ([_][]const u8{ "invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated" }) |code| {
        if (std.mem.indexOf(u8, body, code) != null) return true;
    }
    return false;
}

// ── Credentials ───────────────────────────────────────────────────────

/// Fixed-size so it can sit in the Model.
pub const Credentials = struct {
    access: [8192]u8 = undefined,
    access_len: usize = 0,
    refresh: [4096]u8 = undefined,
    refresh_len: usize = 0,
    account_id: [128]u8 = undefined,
    account_id_len: usize = 0,
    /// Access-token expiry in wall-clock ms; 0 when unknown.
    expires_ms: i64 = 0,

    pub fn accessToken(self: *const Credentials) []const u8 {
        return self.access[0..self.access_len];
    }

    pub fn refreshToken(self: *const Credentials) []const u8 {
        return self.refresh[0..self.refresh_len];
    }

    pub fn accountId(self: *const Credentials) []const u8 {
        return self.account_id[0..self.account_id_len];
    }

    pub fn signedIn(self: *const Credentials) bool {
        return self.access_len > 0 and self.account_id_len > 0;
    }

    pub fn expiresSoon(self: *const Credentials, now_ms: i64) bool {
        return self.expires_ms != 0 and now_ms + refresh_slack_ms >= self.expires_ms;
    }

    pub fn auth(self: *const Credentials) provider.Auth {
        return .{ .bearer = self.accessToken(), .account_id = self.accountId() };
    }

    pub fn clear(self: *Credentials) void {
        self.* = .{};
    }

    /// All-or-nothing: on false the credentials are unchanged.
    fn set(self: *Credentials, access: []const u8, refresh: ?[]const u8, fallback: Fallback, now_ms: i64) bool {
        if (access.len == 0 or access.len > self.access.len) return false;
        if (refresh) |r| if (r.len > self.refresh.len) return false;
        var scratch: [16 * 1024]u8 = undefined;
        const claims = jwtClaims(access, &scratch) orelse Claims{};
        var id_scratch: [16 * 1024]u8 = undefined;
        const account = claims.account_id orelse
            (if (fallback.id_token) |t| (jwtClaims(t, &id_scratch) orelse Claims{}).account_id else null) orelse
            fallback.account_id orelse return false;
        if (account.len == 0 or account.len > self.account_id.len) return false;

        @memcpy(self.access[0..access.len], access);
        self.access_len = access.len;
        if (refresh) |r| {
            @memcpy(self.refresh[0..r.len], r);
            self.refresh_len = r.len;
        }
        @memcpy(self.account_id[0..account.len], account);
        self.account_id_len = account.len;
        self.expires_ms = if (claims.exp_s > 0)
            claims.exp_s * 1000
        else if (fallback.expires_in) |s| now_ms + s * 1000 else 0;
        return true;
    }
};

const Fallback = struct {
    id_token: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    expires_in: ?i64 = null,
};

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    expires_in: ?i64 = null,
};

/// A token-endpoint reply (exchange or refresh). A refresh reply may omit
/// the refresh token, in which case the current one stays.
pub fn applyTokenResponse(c: *Credentials, allocator: std.mem.Allocator, body: []const u8, now_ms: i64) bool {
    var parsed = std.json.parseFromSlice(TokenResponse, allocator, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const v = parsed.value;
    return c.set(v.access_token, v.refresh_token, .{ .id_token = v.id_token, .expires_in = v.expires_in }, now_ms);
}

const CodexAuthFile = struct {
    tokens: ?struct {
        access_token: []const u8 = "",
        refresh_token: []const u8 = "",
        account_id: ?[]const u8 = null,
    } = null,
};

/// Seed from Codex CLI's `auth.json`. A one-time copy: whichever client
/// refreshes first may rotate the other's refresh token away.
pub fn importCodexAuth(c: *Credentials, allocator: std.mem.Allocator, body: []const u8, now_ms: i64) bool {
    var parsed = std.json.parseFromSlice(CodexAuthFile, allocator, body, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const tokens = parsed.value.tokens orelse return false;
    if (tokens.refresh_token.len == 0) return false;
    return c.set(tokens.access_token, tokens.refresh_token, .{ .account_id = tokens.account_id }, now_ms);
}

const Stored = struct {
    access: []const u8 = "",
    refresh: []const u8 = "",
    account_id: []const u8 = "",
    expires_ms: i64 = 0,
};

/// The secret_store payload.
pub fn serialize(c: *const Credentials, out: []u8) ?[]const u8 {
    if (!c.signedIn()) return null;
    var w: std.Io.Writer = .fixed(out);
    std.json.Stringify.value(Stored{
        .access = c.accessToken(),
        .refresh = c.refreshToken(),
        .account_id = c.accountId(),
        .expires_ms = c.expires_ms,
    }, .{}, &w) catch return null;
    return w.buffered();
}

pub fn deserialize(c: *Credentials, allocator: std.mem.Allocator, bytes: []const u8) bool {
    var parsed = std.json.parseFromSlice(Stored, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const v = parsed.value;
    if (v.access.len == 0 or v.access.len > c.access.len or v.refresh.len > c.refresh.len) return false;
    if (v.account_id.len == 0 or v.account_id.len > c.account_id.len) return false;
    c.* = .{};
    @memcpy(c.access[0..v.access.len], v.access);
    c.access_len = v.access.len;
    @memcpy(c.refresh[0..v.refresh.len], v.refresh);
    c.refresh_len = v.refresh.len;
    @memcpy(c.account_id[0..v.account_id.len], v.account_id);
    c.account_id_len = v.account_id.len;
    c.expires_ms = v.expires_ms;
    return true;
}

pub const Claims = struct {
    account_id: ?[]const u8 = null,
    exp_s: i64 = 0,
};

const JwtPayload = struct {
    exp: i64 = 0,
    @"https://api.openai.com/auth": ?struct {
        chatgpt_account_id: ?[]const u8 = null,
    } = null,
};

/// Unverified read of an access or id token's payload. The token came
/// straight from OpenAI over TLS, and nothing here is a trust decision —
/// the backend checks the signature on every request.
pub fn jwtClaims(token: []const u8, scratch: []u8) ?Claims {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload = std.mem.trimEnd(u8, parts.next() orelse return null, "=");
    _ = parts.next() orelse return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const n = decoder.calcSizeForSlice(payload) catch return null;
    if (n * 2 > scratch.len) return null;
    decoder.decode(scratch[0..n], payload) catch return null;
    var fba = std.heap.FixedBufferAllocator.init(scratch[n..]);
    const p = std.json.parseFromSliceLeaky(JwtPayload, fba.allocator(), scratch[0..n], .{ .ignore_unknown_fields = true }) catch return null;
    const account = if (p.@"https://api.openai.com/auth") |a| a.chatgpt_account_id else null;
    return .{ .account_id = account, .exp_s = p.exp };
}

comptime {
    std.debug.assert(std.mem.eql(u8, auth_claim, "https://api.openai.com/auth"));
}

// ── Tests ─────────────────────────────────────────────────────────────

fn testJwt(buf: []u8, payload_json: []const u8) []const u8 {
    const header = "eyJhbGciOiJub25lIn0"; // {"alg":"none"}
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.calcSize(payload_json.len);
    @memcpy(buf[0..header.len], header);
    buf[header.len] = '.';
    _ = enc.encode(buf[header.len + 1 ..][0..n], payload_json);
    const tail = ".sig";
    @memcpy(buf[header.len + 1 + n ..][0..tail.len], tail);
    return buf[0 .. header.len + 1 + n + tail.len];
}

test "responses body maps roles to input_text and output_text" {
    const t = std.testing;
    var bufs: provider.Bufs = .{};
    const history = [_]Message{
        .{ .role = .user, .text = "おはよう" },
        .{ .role = .assistant, .text = "ふわぁ…\"おはよ\"" },
        .{ .role = .user, .text = "元気？" },
    };
    const req = buildRequest(
        .{ .base_url = base_url, .model = "gpt-test", .cache_key = "petdex-boba" },
        .{ .bearer = "tok", .account_id = "acct" },
        "You are Boba.",
        &history,
        &bufs,
    ).?;
    try t.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", req.url);
    try t.expectEqualStrings(
        "{\"model\":\"gpt-test\",\"store\":false,\"stream\":true,\"instructions\":\"You are Boba.\",\"input\":[" ++
            "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"おはよう\"}]}," ++
            "{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ふわぁ…\\\"おはよ\\\"\"}]}," ++
            "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"元気？\"}]}]," ++
            "\"text\":{\"verbosity\":\"low\"},\"prompt_cache_key\":\"petdex-boba\"}",
        req.body,
    );
    try t.expectEqual(@as(usize, provider.max_headers), req.headers.len);
    try t.expectEqualStrings("Bearer tok", req.headers[0].value);
    try t.expectEqualStrings("acct", req.headers[1].value);
}

test "a request without credentials is refused" {
    var bufs: provider.Bufs = .{};
    const history = [_]Message{.{ .role = .user, .text = "hi" }};
    try std.testing.expect(buildRequest(.{ .base_url = base_url, .model = "m" }, .{ .bearer = "tok" }, "p", &history, &bufs) == null);
    try std.testing.expect(buildRequest(.{ .base_url = base_url, .model = "m" }, .{ .account_id = "a" }, "p", &history, &bufs) == null);
}

test "stream events map to deltas, done and failures" {
    const t = std.testing;
    var scratch: [4096]u8 = undefined;
    try t.expectEqualStrings("にゃ", parseLine("data: {\"type\":\"response.output_text.delta\",\"item_id\":\"m\",\"output_index\":0,\"delta\":\"\\u306b\\u3083\"}", &scratch).?.delta);
    try t.expectEqualStrings("😀", parseLine("data: {\"type\":\"response.output_text.delta\",\"delta\":\"\\ud83d\\ude00\"}", &scratch).?.delta);
    try t.expectEqualStrings("say \"hi\"", parseLine("data: {\"type\": \"response.output_text.delta\", \"delta\": \"say \\\"hi\\\"\"}", &scratch).?.delta);
    try t.expect(parseLine("data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\"}]}}", &scratch).? == .done);
    try t.expect(parseLine("data: {\"type\":\"response.incomplete\"}", &scratch).? == .done);
    try t.expectEqualStrings("Rate limited", parseLine("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"rate_limit\",\"message\":\"Rate limited\"}}}", &scratch).?.failed);
    try t.expectEqualStrings(generic_failure, parseLine("data: {\"type\":\"response.failed\",\"response\":{}}", &scratch).?.failed);
    try t.expectEqualStrings("bad model", parseLine("data: {\"type\":\"error\",\"message\":\"bad model\"}", &scratch).?.failed);
    try t.expectEqualStrings("nested", parseLine("data: {\"type\":\"error\",\"error\":{\"message\":\"nested\"}}", &scratch).?.failed);
    try t.expect(parseLine("data: {\"type\":\"response.created\",\"response\":{}}", &scratch) == null);
    try t.expect(parseLine("event: response.output_text.delta", &scratch) == null);
    // A truncated line is dropped, never misread.
    try t.expect(parseLine("data: {\"type\":\"response.output_text.delta\",\"delta\":\"abc", &scratch) == null);
    try t.expect(parseLine("data: {\"type\":", &scratch) == null);
}

test "authorize URL carries every parameter the Codex client expects" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    const url = authorizeUrl(&buf, "CHALLENGE", "STATE").?;
    try t.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&"));
    for ([_][]const u8{
        "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
        "scope=openid%20profile%20email%20offline_access",
        "code_challenge=CHALLENGE",
        "code_challenge_method=S256",
        "id_token_add_organizations=true",
        "codex_cli_simplified_flow=true",
        "state=STATE",
        "originator=petdex",
    }) |part| try t.expect(std.mem.indexOf(u8, url, part) != null);
}

test "token and refresh bodies are form-encoded" {
    const t = std.testing;
    var buf: [1024]u8 = undefined;
    try t.expectEqualStrings(
        "grant_type=authorization_code&code=a%2Fb&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=v-1_x",
        tokenBody(&buf, "a/b", "v-1_x").?,
    );
    try t.expectEqualStrings(
        "grant_type=refresh_token&refresh_token=rt%2B1&client_id=app_EMoamEEZ73f0CkXaXp7hrann",
        refreshBody(&buf, "rt+1").?,
    );
    try t.expect(isDeadRefresh("{\"error\":\"invalid_grant\"}"));
    try t.expect(!isDeadRefresh("{\"error\":\"server_error\"}"));
}

test "JWT claims yield the account id and expiry" {
    const t = std.testing;
    var jwt_buf: [512]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const token = testJwt(&jwt_buf, "{\"exp\":1900000000,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-1\"}}");
    const claims = jwtClaims(token, &scratch).?;
    try t.expectEqualStrings("acct-1", claims.account_id.?);
    try t.expectEqual(@as(i64, 1900000000), claims.exp_s);
    try t.expect(jwtClaims("not-a-jwt", &scratch) == null);
    try t.expect(jwtClaims("a.@@@.c", &scratch) == null);
    const bare = jwtClaims(testJwt(&jwt_buf, "{\"sub\":\"x\"}"), &scratch).?;
    try t.expect(bare.account_id == null);
}

test "token responses fill credentials and keep the refresh token when omitted" {
    const t = std.testing;
    var jwt_buf: [512]u8 = undefined;
    const access = testJwt(&jwt_buf, "{\"exp\":1900000000,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-1\"}}");
    var body_buf: [1024]u8 = undefined;

    var c: Credentials = .{};
    const first = try std.fmt.bufPrint(&body_buf, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt-1\",\"expires_in\":3600}}", .{access});
    try t.expect(applyTokenResponse(&c, t.allocator, first, 0));
    try t.expect(c.signedIn());
    try t.expectEqualStrings("acct-1", c.accountId());
    try t.expectEqualStrings("rt-1", c.refreshToken());
    try t.expectEqual(@as(i64, 1900000000 * 1000), c.expires_ms);
    try t.expect(!c.expiresSoon(1900000000 * 1000 - 10 * 60 * 1000));
    try t.expect(c.expiresSoon(1900000000 * 1000 - 60 * 1000));

    const refreshed = try std.fmt.bufPrint(&body_buf, "{{\"access_token\":\"{s}\"}}", .{access});
    try t.expect(applyTokenResponse(&c, t.allocator, refreshed, 0));
    try t.expectEqualStrings("rt-1", c.refreshToken());

    // No account id anywhere: refused, and the credentials are untouched.
    const anonymous = testJwt(&jwt_buf, "{\"exp\":1}");
    const bad = try std.fmt.bufPrint(&body_buf, "{{\"access_token\":\"{s}\",\"refresh_token\":\"rt-2\"}}", .{anonymous});
    try t.expect(!applyTokenResponse(&c, t.allocator, bad, 0));
    try t.expectEqualStrings("rt-1", c.refreshToken());
    try t.expectEqualStrings("acct-1", c.accountId());
}

test "Codex CLI auth.json seeds credentials" {
    const t = std.testing;
    var jwt_buf: [512]u8 = undefined;
    const access = testJwt(&jwt_buf, "{\"exp\":1900000000}");
    var body_buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"OPENAI_API_KEY\":null,\"tokens\":{{\"id_token\":\"x.y.z\",\"access_token\":\"{s}\",\"refresh_token\":\"rt-codex\",\"account_id\":\"acct-file\"}},\"last_refresh\":\"2026-09-01T00:00:00Z\"}}", .{access});
    var c: Credentials = .{};
    try t.expect(importCodexAuth(&c, t.allocator, body, 0));
    try t.expectEqualStrings("acct-file", c.accountId());
    try t.expectEqualStrings("rt-codex", c.refreshToken());
    try t.expect(!importCodexAuth(&c, t.allocator, "{\"OPENAI_API_KEY\":\"sk-x\",\"tokens\":null}", 0));
    try t.expect(!importCodexAuth(&c, t.allocator, "garbage", 0));
}

test "credentials round-trip through the stored form" {
    const t = std.testing;
    var c: Credentials = .{};
    var jwt_buf: [512]u8 = undefined;
    const access = testJwt(&jwt_buf, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct\"}}");
    try t.expect(c.set(access, "rt", .{ .expires_in = 60 }, 1000));
    try t.expectEqual(@as(i64, 61_000), c.expires_ms);
    var out: [2048]u8 = undefined;
    const stored = serialize(&c, &out).?;
    var back: Credentials = .{};
    try t.expect(deserialize(&back, t.allocator, stored));
    try t.expectEqualStrings(access, back.accessToken());
    try t.expectEqualStrings("rt", back.refreshToken());
    try t.expectEqualStrings("acct", back.accountId());
    try t.expectEqual(c.expires_ms, back.expires_ms);
    try t.expect(!deserialize(&back, t.allocator, "{}"));
    try t.expect(serialize(&Credentials{}, &out) == null);
}
