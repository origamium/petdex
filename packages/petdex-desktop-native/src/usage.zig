//! How much of each coding agent's plan limit is used, for the column
//! beside the pet: one row per agent at its tightest window, and, for the
//! row clicked open, every window with its reset.
//!
//! Claude Code and Codex report their limits themselves, through the
//! statusline relay and the Stop hook (hook_runner.zig); both land as small
//! files under ~/.petdex/runtime/usage/ (writeWindows). Junie's credits sit
//! in the JetBrains IDEs' quota file, a pool Junie shares with AI Assistant.
//! Copilot and Cursor are fetched by main.zig and parsed here. No token is
//! ever refreshed: redeeming an agent's refresh token signs that agent out.

const std = @import("std");
const plat = @import("plat.zig");
const sqlite = @import("sqlite.zig");

/// The rows, in the order they are drawn. The tags are the names
/// agentIconIndex takes.
pub const Agent = enum { @"claude-code", codex, junie, cursor, copilot };
pub const agent_count = @typeInfo(Agent).@"enum".fields.len;

pub fn displayName(agent: Agent) []const u8 {
    return switch (agent) {
        .@"claude-code" => "Claude Code",
        .codex => "Codex",
        .junie => "Junie",
        .cursor => "Cursor",
        .copilot => "Copilot",
    };
}

pub const five_hour_minutes: u32 = 5 * 60;
pub const week_minutes: u32 = 7 * 24 * 60;
/// Junie, Cursor and Copilot bill by the month.
pub const month_minutes: u32 = 30 * 24 * 60;

/// Each agent's windows; a null hides its row.
pub const State = struct {
    windows: [agent_count]?Windows = @splat(null),
    /// When the windows were last read, epoch seconds: what expiry and
    /// the reset countdown count from.
    now_s: i64 = 0,
    /// The row clicked open.
    selected: ?Agent = null,
    next_file_ms: i64 = 0,
    next_net_ms: i64 = 0,

    pub fn used(self: *const State, agent: Agent) ?u8 {
        const windows = self.windows[@intFromEnum(agent)] orelse return null;
        return tightest(windows.slice(), self.now_s);
    }

    pub fn len(self: *const State) usize {
        var n: usize = 0;
        for (std.enums.values(Agent)) |agent| {
            if (self.used(agent) != null) n += 1;
        }
        return n;
    }

    pub fn set(self: *State, agent: Agent, windows: ?Windows) void {
        self.windows[@intFromEnum(agent)] = windows;
    }
};

pub const file_interval_ms: i64 = 60 * 1000;
pub const net_interval_ms: i64 = 5 * 60 * 1000;
/// After a 429 an endpoint is left alone for an hour.
pub const net_backoff_ms: i64 = 60 * 60 * 1000;

/// One limit window: percent used, when it resets (epoch seconds, 0 when
/// unknown), and how long it is (minutes, 0 when unknown).
pub const Window = struct { used: f64, resets_at: i64 = 0, minutes: u32 = 0 };

pub const Windows = struct {
    items: [2]Window = undefined,
    len: usize = 0,

    pub fn one(used: f64, resets_at: i64, minutes: u32) Windows {
        var out: Windows = .{};
        out.items[0] = .{ .used = used, .resets_at = resets_at, .minutes = minutes };
        out.len = 1;
        return out;
    }

    fn add(self: *Windows, used: ?f64, resets_at: ?f64, minutes: ?f64) void {
        const u = used orelse return;
        if (self.len == self.items.len) return;
        const r = resets_at orelse 0;
        const m = minutes orelse 0;
        self.items[self.len] = .{
            .used = u,
            .resets_at = if (r > 0 and r < 1e12) @intFromFloat(r) else 0,
            .minutes = if (m > 0 and m < 1e7) @intFromFloat(m) else 0,
        };
        self.len += 1;
    }

    pub fn slice(self: *const Windows) []const Window {
        return self.items[0..self.len];
    }
};

/// The fullest window, a window whose reset has passed counting as empty.
pub fn tightest(windows: []const Window, now_s: i64) ?u8 {
    if (windows.len == 0) return null;
    var most: f64 = 0;
    for (windows) |w| most = @max(most, current(w, now_s));
    return percent(most);
}

/// A window's use now: nothing, once its reset has passed.
pub fn current(w: Window, now_s: i64) f64 {
    if (w.resets_at != 0 and w.resets_at <= now_s) return 0;
    return w.used;
}

pub fn percent(v: f64) u8 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@round(std.math.clamp(v, 0, 100)));
}

/// Time left, to the minute rounded up, in days, hours and minutes.
pub const Countdown = struct { days: i64, hours: i64, minutes: i64 };

pub fn countdown(secs: i64) Countdown {
    const mins = @divFloor(@max(secs, 0) + 59, 60);
    return .{ .days = @divFloor(mins, 24 * 60), .hours = @divFloor(@mod(mins, 24 * 60), 60), .minutes = @mod(mins, 60) };
}

/// The limits as the chat's model reads them, for its instructions: English
/// like every prompt the app sends, one line per agent with each window and
/// its reset, then when they are worth bringing up. Empty with nothing known.
pub fn context(state: *const State, now_s: i64, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    var any = false;
    for (std.enums.values(Agent)) |agent| {
        const windows = state.windows[@intFromEnum(agent)] orelse continue;
        if (windows.len == 0) continue;
        if (!any) w.writeAll("Their coding agents' plan usage right now, from the app:") catch {};
        any = true;
        w.print("\n- {s}:", .{displayName(agent)}) catch {};
        for (windows.slice(), 0..) |win, i| {
            w.writeAll(if (i > 0) "; " else " ") catch {};
            switch (win.minutes) {
                five_hour_minutes => w.writeAll("5-hour limit") catch {},
                week_minutes => w.writeAll("weekly limit") catch {},
                month_minutes => w.writeAll("monthly limit") catch {},
                0 => w.writeAll("limit") catch {},
                else => w.print("{d}-hour limit", .{win.minutes / 60}) catch {},
            }
            w.print(" {d}% used", .{percent(current(win, now_s))}) catch {};
            if (win.resets_at > now_s) {
                const c = countdown(win.resets_at - now_s);
                if (c.days > 0) {
                    w.print(", resets in {d}d {d}h", .{ c.days, c.hours }) catch {};
                } else if (c.hours > 0) {
                    w.print(", resets in {d}h {d}m", .{ c.hours, c.minutes }) catch {};
                } else {
                    w.print(", resets in {d}m", .{c.minutes}) catch {};
                }
            }
        }
    }
    if (!any) return "";
    w.writeAll("\nBring these up when they matter, in your own voice: a limit with room to spare that resets soon " ++
        "means now is the time to put the agent to work; one nearly used up means pacing it until the reset.") catch {};
    return w.buffered();
}

/// "2026-10-08T20:01:10.119Z", or a bare date, as epoch seconds.
/// ponytail: UTC only; every source here sends Z or a date.
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    var secs: i64 = 0;
    if (s.len >= 19 and (s[10] == 'T' or s[10] == ' ')) {
        const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
        const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
        const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
        secs = h * 3600 + mi * 60 + se;
    }
    // Days from 1970-01-01, Howard Hinnant's days_from_civil.
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400 + secs;
}

// ------------------------------------------------------ reported windows

/// `{"windows":[[used,resets_at,minutes],...]}`, the file the relay and
/// the hook leave for the app.
pub fn formatWindows(windows: Windows, buf: []u8) ?[]const u8 {
    var n = (std.fmt.bufPrint(buf, "{{\"windows\":[", .{}) catch return null).len;
    for (windows.slice(), 0..) |w, i| {
        n += (std.fmt.bufPrint(buf[n..], "{s}[{d:.1},{d},{d}]", .{ if (i > 0) "," else "", w.used, w.resets_at, w.minutes }) catch return null).len;
    }
    n += (std.fmt.bufPrint(buf[n..], "]}}", .{}) catch return null).len;
    return buf[0..n];
}

pub fn parseWindows(bytes: []const u8) ?Windows {
    const Root = struct { windows: []const []const f64 = &.{} };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var out: Windows = .{};
    for (parsed.value.windows) |w| {
        if (w.len < 2) continue;
        out.add(w[0], w[1], if (w.len > 2) w[2] else null);
    }
    return out;
}

fn windowsPath(buf: []u8, home: []const u8, agent: Agent) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.petdex/runtime/usage/{s}.json", .{ home, @tagName(agent) }) catch null;
}

/// Leave the windows for the app, only when they changed: the statusline
/// runs many times a minute.
pub fn writeWindows(home: []const u8, agent: Agent, windows: Windows) void {
    var path_buf: [512]u8 = undefined;
    const path = windowsPath(&path_buf, home, agent) orelse return;
    var buf: [192]u8 = undefined;
    const bytes = formatWindows(windows, &buf) orelse return;
    var old_buf: [192]u8 = undefined;
    if (plat.readFile(path, &old_buf)) |old| {
        if (std.mem.eql(u8, old, bytes)) return;
    }
    _ = plat.writeFile(path, bytes);
}

fn windowsFromFile(home: []const u8, agent: Agent) ?Windows {
    var path_buf: [512]u8 = undefined;
    const path = windowsPath(&path_buf, home, agent) orelse return null;
    var buf: [256]u8 = undefined;
    const windows = parseWindows(plat.readFile(path, &buf) orelse return null) orelse return null;
    return if (windows.len > 0) windows else null;
}

/// Claude Code's statusline input: `rate_limits.five_hour` and
/// `seven_day`, each `used_percentage` and `resets_at`. Typed, not the
/// hook server's flat scan: `context_window` has a `used_percentage` too.
pub fn windowsFromClaudeStatusline(payload: []const u8) ?Windows {
    const W = struct { used_percentage: ?f64 = null, resets_at: ?f64 = null };
    const Root = struct { rate_limits: ?struct { five_hour: ?W = null, seven_day: ?W = null } = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, payload, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const limits = parsed.value.rate_limits orelse return null;
    var out: Windows = .{};
    if (limits.five_hour) |w| out.add(w.used_percentage, w.resets_at, five_hour_minutes);
    if (limits.seven_day) |w| out.add(w.used_percentage, w.resets_at, week_minutes);
    if (out.len == 0) return null;
    return out;
}

/// A Codex rollout line carrying the account's limits. Lines with
/// `"rate_limits":null` (an API-key session) are passed over.
pub fn carriesCodexLimits(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "\"type\":\"token_count\"") != null and
        std.mem.indexOf(u8, line, "\"rate_limits\":{") != null;
}

/// `payload.rate_limits.primary` and `secondary` of a token_count line.
/// Other limit ids (a model's own pool) are not the plan's limit.
pub fn windowsFromCodexLine(line: []const u8) ?Windows {
    const W = struct { used_percent: ?f64 = null, resets_at: ?f64 = null, window_minutes: ?f64 = null };
    const Limits = struct { limit_id: ?[]const u8 = null, primary: ?W = null, secondary: ?W = null };
    const Root = struct { payload: ?struct { rate_limits: ?Limits = null } = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const limits = (parsed.value.payload orelse return null).rate_limits orelse return null;
    if (limits.limit_id) |id| {
        if (!std.mem.eql(u8, id, "codex")) return null;
    }
    var out: Windows = .{};
    if (limits.primary) |w| out.add(w.used_percent, w.resets_at, w.window_minutes);
    if (limits.secondary) |w| out.add(w.used_percent, w.resets_at, w.window_minutes);
    if (out.len == 0) return null;
    return out;
}

// -------------------------------------------------------------- junie

/// JetBrains AI's `quotaInfo` (`current / maximum`) and `nextRefill.next`:
/// attributes holding XML-escaped JSON whose numbers are strings.
pub fn windowsFromJetBrainsXml(xml: []const u8, scratch: []u8) ?Windows {
    const half = scratch.len / 2;
    var quota = option(xml, "quotaInfo", scratch[0..half]) orelse return null;
    defer quota.deinit();
    if (quota.value != .object) return null;
    const current_v = numberOf(quota.value.object.get("current")) orelse return null;
    const maximum = numberOf(quota.value.object.get("maximum")) orelse return null;
    if (maximum <= 0) return null;
    var resets_at: i64 = 0;
    if (option(xml, "nextRefill", scratch[half..])) |refill_parsed| {
        var refill = refill_parsed;
        defer refill.deinit();
        if (refill.value == .object) {
            if (refill.value.object.get("next")) |next| {
                if (next == .string) resets_at = parseIso(next.string) orelse 0;
            }
        }
    }
    return Windows.one(current_v / maximum * 100, resets_at, month_minutes);
}

fn option(xml: []const u8, comptime name: []const u8, scratch: []u8) ?std.json.Parsed(std.json.Value) {
    const marker = "name=\"" ++ name ++ "\" value=\"";
    const start = (std.mem.indexOf(u8, xml, marker) orelse return null) + marker.len;
    const end = start + (std.mem.indexOfScalar(u8, xml[start..], '"') orelse return null);
    const json = unescapeXml(xml[start..end], scratch) orelse return null;
    return std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch null;
}

fn numberOf(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .string, .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn unescapeXml(src: []const u8, out: []u8) ?[]const u8 {
    const entities = [_]struct { []const u8, u8 }{ .{ "&quot;", '"' }, .{ "&apos;", '\'' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&amp;", '&' }, .{ "&#10;", '\n' }, .{ "&#13;", '\r' }, .{ "&#9;", '\t' } };
    var n: usize = 0;
    var i: usize = 0;
    outer: while (i < src.len) {
        if (n == out.len) return null;
        if (src[i] == '&') {
            for (entities) |e| {
                if (std.mem.startsWith(u8, src[i..], e[0])) {
                    out[n] = e[1];
                    n += 1;
                    i += e[0].len;
                    continue :outer;
                }
            }
        }
        out[n] = src[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// The newest quota file across the JetBrains IDEs: each IDE version
/// keeps its own, and the one written last is the freshest.
fn windowsFromJetBrains(home: []const u8) ?Windows {
    var dir_buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/Library/Application Support/JetBrains", .{home}) catch return null;
    var newest: Newest = .{ .dir = dir };
    plat.forEachEntry(dir, &newest, Newest.visit);
    if (newest.len == 0) return null;
    var xml_buf: [16 * 1024]u8 = undefined;
    var scratch: [16 * 1024]u8 = undefined;
    const xml = plat.readFile(newest.path[0..newest.len], &xml_buf) orelse return null;
    return windowsFromJetBrainsXml(xml, &scratch);
}

const Newest = struct {
    dir: []const u8,
    path: [768]u8 = undefined,
    len: usize = 0,
    mtime: i96 = 0,

    fn visit(self: *Newest, name: []const u8) void {
        var buf: [768]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}/options/AIAssistantQuotaManager2.xml", .{ self.dir, name }) catch return;
        const mtime = plat.fileMtime(path) orelse return;
        if (self.len > 0 and mtime <= self.mtime) return;
        @memcpy(self.path[0..path.len], path);
        self.len = path.len;
        self.mtime = mtime;
    }
};

/// The local sources, cheap enough for a read every minute.
pub fn readFiles(state: *State, home: []const u8, now_ms: i64) void {
    state.now_s = @divFloor(now_ms, 1000);
    state.set(.@"claude-code", windowsFromFile(home, .@"claude-code"));
    state.set(.codex, windowsFromFile(home, .codex));
    state.set(.junie, windowsFromJetBrains(home));
}

// ------------------------------------------------------------ copilot

pub const copilot_url = "https://api.github.com/copilot_internal/user";

/// The GitHub token Copilot's editor plugins keep in apps.json: the VS Code
/// and JetBrains app's when present, the endpoint answers that one.
pub fn copilotToken(home: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/github-copilot/apps.json", .{home}) catch return null;
    var buf: [16 * 1024]u8 = undefined;
    return copilotTokenFrom(plat.readFile(path, &buf) orelse return null, out);
}

fn copilotTokenFrom(apps_json: []const u8, out: []u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, apps_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const apps = parsed.value.object;
    const entry = apps.get("github.com:Iv1.b507a08c87ecfe98") orelse blk: {
        var it = apps.iterator();
        break :blk (it.next() orelse return null).value_ptr.*;
    };
    if (entry != .object) return null;
    const token = entry.object.get("oauth_token") orelse return null;
    if (token != .string or !headerSafe(token.string) or token.string.len > out.len) return null;
    @memcpy(out[0..token.string.len], token.string);
    return out[0..token.string.len];
}

/// `premium_interactions` is the monthly allowance that runs out; chat is
/// unlimited on paid plans.
pub fn windowsFromCopilot(body: []const u8) ?Windows {
    const Snap = struct { percent_remaining: ?f64 = null, unlimited: ?bool = null };
    const Root = struct { quota_reset_date: ?[]const u8 = null, quota_snapshots: ?struct { premium_interactions: ?Snap = null } = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const snap = (parsed.value.quota_snapshots orelse return null).premium_interactions orelse return null;
    if (snap.unlimited orelse false) return null;
    const resets_at = if (parsed.value.quota_reset_date) |date| parseIso(date) orelse 0 else 0;
    return Windows.one(100 - (snap.percent_remaining orelse return null), resets_at, month_minutes);
}

// ------------------------------------------------------------- cursor

pub const cursor_url = "https://cursor.com/api/usage-summary";

/// The Cursor app's session token, from its own settings database.
pub fn cursorToken(home: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [512:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/Library/Application Support/Cursor/User/globalStorage/state.vscdb", .{home}) catch return null;
    if (!plat.fileExists(path) or !sqlite.load()) return null;
    var db = sqlite.Db.openReadOnly(path) catch return null;
    defer db.close();
    var stmt = db.prepare("SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'") catch return null;
    defer stmt.finalize();
    if (!(stmt.step() catch return null)) return null;
    const token = stmt.text(0);
    if (token.len == 0 or token.len > out.len) return null;
    @memcpy(out[0..token.len], token);
    return out[0..token.len];
}

/// The cookie cursor.com takes: the user id (the JWT subject after its
/// last `|`), `::`, and the token.
pub fn cursorCookie(token: []const u8, out: []u8) ?[]const u8 {
    if (!headerSafe(token)) return null;
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next();
    const claims_b64 = parts.next() orelse return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    var claims_buf: [2048]u8 = undefined;
    const size = decoder.calcSizeForSlice(claims_b64) catch return null;
    if (size > claims_buf.len) return null;
    decoder.decode(claims_buf[0..size], claims_b64) catch return null;
    const Claims = struct { sub: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Claims, std.heap.page_allocator, claims_buf[0..size], .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const sub = parsed.value.sub orelse return null;
    const user = sub[if (std.mem.lastIndexOfScalar(u8, sub, '|')) |i| i + 1 else 0..];
    if (user.len == 0) return null;
    for (user) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return null;
    }
    return std.fmt.bufPrint(out, "WorkosCursorSessionToken={s}%3A%3A{s}", .{ user, token }) catch null;
}

/// The plan's share of the billing cycle, which ends at `billingCycleEnd`.
pub fn windowsFromCursor(body: []const u8) ?Windows {
    const Plan = struct { totalPercentUsed: ?f64 = null, used: ?f64 = null, limit: ?f64 = null };
    const Root = struct { billingCycleEnd: ?[]const u8 = null, individualUsage: ?struct { plan: ?Plan = null } = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const plan = (parsed.value.individualUsage orelse return null).plan orelse return null;
    const used = plan.totalPercentUsed orelse blk: {
        const limit = plan.limit orelse return null;
        if (limit <= 0) return null;
        break :blk (plan.used orelse 0) / limit * 100;
    };
    const resets_at = if (parsed.value.billingCycleEnd) |end| parseIso(end) orelse 0 else 0;
    return Windows.one(used, resets_at, month_minutes);
}

/// A value that can go into a request header as is.
fn headerSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c <= ' ' or c >= 0x7f or c == ';' or c == ',') return false;
    }
    return true;
}

// -------------------------------------------------------------- tests

const t = std.testing;

test "the tightest window is the fullest one that has not reset" {
    const windows = [_]Window{ .{ .used = 42.4, .resets_at = 2000 }, .{ .used = 18, .resets_at = 9000 } };
    try t.expectEqual(@as(?u8, 42), tightest(&windows, 1000));
    // The five-hour window reset: the week is what is left.
    try t.expectEqual(@as(?u8, 18), tightest(&windows, 3000));
    try t.expectEqual(@as(?u8, 0), tightest(&windows, 10000));
    try t.expectEqual(@as(?u8, null), tightest(&.{}, 0));
    try t.expectEqual(@as(?u8, 100), tightest(&.{.{ .used = 130 }}, 0));
}

test "a row per agent with windows, at the state's clock" {
    var state: State = .{};
    try t.expectEqual(@as(usize, 0), state.len());
    state.set(.codex, Windows.one(15, 5000, week_minutes));
    state.now_s = 1000;
    try t.expectEqual(@as(?u8, 15), state.used(.codex));
    try t.expectEqual(@as(usize, 1), state.len());
    state.now_s = 6000;
    try t.expectEqual(@as(?u8, 0), state.used(.codex));
    try t.expectEqual(@as(?u8, null), state.used(.cursor));
}

test "the chat reads each agent's windows and resets" {
    var state: State = .{};
    var out: [1024]u8 = undefined;
    try t.expectEqualStrings("", context(&state, 1000, &out));
    var claude: Windows = .{};
    claude.add(42, 1000 + 2 * 3600 + 13 * 60, five_hour_minutes);
    claude.add(18, 1000 + 3 * 86400 + 4 * 3600, week_minutes);
    state.set(.@"claude-code", claude);
    // Reset already: nothing used, no countdown.
    state.set(.junie, Windows.one(80, 500, month_minutes));
    const c = context(&state, 1000, &out);
    try t.expect(std.mem.startsWith(u8, c, "Their coding agents' plan usage right now, from the app:" ++
        "\n- Claude Code: 5-hour limit 42% used, resets in 2h 13m; weekly limit 18% used, resets in 3d 4h" ++
        "\n- Junie: monthly limit 0% used\n"));
    try t.expect(std.mem.indexOf(u8, c, "now is the time") != null);
    try t.expectEqual(Countdown{ .days = 0, .hours = 0, .minutes = 1 }, countdown(1));
}

test "ISO dates and times as epoch seconds" {
    try t.expectEqual(@as(?i64, 0), parseIso("1970-01-01T00:00:00Z"));
    try t.expectEqual(@as(?i64, 1791489670), parseIso("2026-10-08T20:01:10.119Z"));
    try t.expectEqual(@as(?i64, 1790812800), parseIso("2026-10-01"));
    try t.expectEqual(@as(?i64, 951782400), parseIso("2000-02-29"));
    try t.expect(parseIso("soon") == null);
    try t.expect(parseIso("2026-13-01") == null);
}

test "the windows file round-trips" {
    var windows: Windows = .{};
    windows.add(42.5, 1789812651, 300);
    windows.add(3, null, null);
    var buf: [192]u8 = undefined;
    const bytes = formatWindows(windows, &buf).?;
    try t.expectEqualStrings("{\"windows\":[[42.5,1789812651,300],[3.0,0,0]]}", bytes);
    const back = parseWindows(bytes).?;
    try t.expectEqual(@as(usize, 2), back.len);
    try t.expectEqual(@as(i64, 1789812651), back.items[0].resets_at);
    try t.expectEqual(@as(u32, 300), back.items[0].minutes);
    try t.expectEqual(@as(f64, 3), back.items[1].used);
}

test "Claude Code's statusline limits, not its context window" {
    const payload =
        \\{"model":{"id":"claude-opus-5"},"context_window":{"used_percentage":91,"remaining_percentage":9},
        \\"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1789800000},"seven_day":{"used_percentage":61,"resets_at":1790000000}}}
    ;
    const windows = windowsFromClaudeStatusline(payload).?;
    try t.expectEqual(@as(usize, 2), windows.len);
    try t.expectEqual(five_hour_minutes, windows.items[0].minutes);
    try t.expectEqual(week_minutes, windows.items[1].minutes);
    try t.expectEqual(@as(?u8, 61), tightest(windows.slice(), 1789700000));
    // No subscription, no limits: nothing to show.
    try t.expect(windowsFromClaudeStatusline("{\"context_window\":{\"used_percentage\":10}}") == null);
    try t.expect(windowsFromClaudeStatusline("{\"rate_limits\":{}}") == null);
}

test "a Codex token_count line's plan limits" {
    const line =
        \\{"timestamp":"2026-09-13T07:54:43.316Z","ordinal":3442,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1789812651},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"prolite","rate_limit_reached_type":null}}}
    ;
    try t.expect(carriesCodexLimits(line));
    const windows = windowsFromCodexLine(line).?;
    try t.expectEqual(@as(usize, 1), windows.len);
    try t.expectEqual(week_minutes, windows.items[0].minutes);
    try t.expectEqual(@as(?u8, 15), tightest(windows.slice(), 1789000000));
    try t.expect(!carriesCodexLimits("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}"));
    try t.expect(windowsFromCodexLine("{\"payload\":{\"rate_limits\":{\"limit_id\":\"codex_spark\",\"primary\":{\"used_percent\":90}}}}") == null);
}

test "JetBrains AI's quota file" {
    const xml =
        \\<application>
        \\  <component name="AIAssistantQuotaManager2">
        \\    <option name="nextRefill" value="{&#10;    &quot;type&quot;: &quot;Known&quot;,&#10;    &quot;next&quot;: &quot;2026-10-08T20:01:10.119Z&quot;&#10;}" />
        \\    <option name="quotaInfo" value="{&#10;    &quot;type&quot;: &quot;Available&quot;,&#10;    &quot;current&quot;: &quot;56778.7305&quot;,&#10;    &quot;maximum&quot;: &quot;1000000&quot;,&#10;    &quot;until&quot;: &quot;2027-04-05T21:00:00Z&quot;&#10;}" />
        \\  </component>
        \\</application>
    ;
    var scratch: [2048]u8 = undefined;
    const windows = windowsFromJetBrainsXml(xml, &scratch).?;
    try t.expectEqual(@as(?u8, 6), tightest(windows.slice(), 0));
    try t.expectEqual(@as(i64, 1791489670), windows.items[0].resets_at);
    try t.expectEqual(month_minutes, windows.items[0].minutes);
    try t.expect(windowsFromJetBrainsXml("<application/>", &scratch) == null);
}

test "Copilot's premium allowance, used" {
    const body =
        \\{"copilot_plan":"individual","quota_reset_date":"2026-10-01","quota_snapshots":{"chat":{"unlimited":true,"percent_remaining":100},"premium_interactions":{"entitlement":300,"remaining":270,"percent_remaining":90,"unlimited":false}}}
    ;
    const windows = windowsFromCopilot(body).?;
    try t.expectEqual(@as(?u8, 10), tightest(windows.slice(), 0));
    try t.expectEqual(@as(i64, 1790812800), windows.items[0].resets_at);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"unlimited\":true,\"percent_remaining\":100}}}") == null);
    var out: [64]u8 = undefined;
    try t.expectEqualStrings("gho_a", copilotTokenFrom("{\"github.com:Ov23\":{\"oauth_token\":\"gho_b\"},\"github.com:Iv1.b507a08c87ecfe98\":{\"oauth_token\":\"gho_a\"}}", &out).?);
    try t.expectEqualStrings("gho_b", copilotTokenFrom("{\"github.com:Ov23\":{\"oauth_token\":\"gho_b\"}}", &out).?);
}

test "Cursor's plan usage and its session cookie" {
    const windows = windowsFromCursor("{\"billingCycleStart\":\"2026-09-01T00:00:00.000Z\",\"billingCycleEnd\":\"2026-10-01T00:00:00.000Z\",\"individualUsage\":{\"plan\":{\"used\":1500,\"limit\":5000,\"totalPercentUsed\":30.0}}}").?;
    try t.expectEqual(@as(?u8, 30), tightest(windows.slice(), 0));
    try t.expectEqual(@as(i64, 1790812800), windows.items[0].resets_at);
    try t.expectEqual(@as(?u8, 25), tightest(windowsFromCursor("{\"individualUsage\":{\"plan\":{\"used\":500,\"limit\":2000}}}").?.slice(), 0));
    try t.expect(windowsFromCursor("{\"membershipType\":\"hobby\"}") == null);
    // {"sub":"auth0|user_01ABC"}
    const token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyXzAxQUJDIn0.sig";
    var out: [256]u8 = undefined;
    try t.expectEqualStrings("WorkosCursorSessionToken=user_01ABC%3A%3A" ++ token, cursorCookie(token, &out).?);
    try t.expect(cursorCookie("a.b;c", &out) == null);
}
