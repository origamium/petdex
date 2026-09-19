//! How much of each coding agent's plan limit is used, for the column
//! beside the pet: one row per agent at its tightest window, and, for the
//! row clicked open, every window with its reset.
//!
//! Claude Code still reports through its statusline relay. Codex limits are
//! written by the MCP `petdex_report_usage` tool or the Stop hook and compared
//! with observations from rollouts under the configured Codex root.
//! Junie's credits sit in the JetBrains IDEs' quota file, a pool
//! Junie shares with AI Assistant. Cursor, Copilot, Grok and Antigravity are
//! fetched by main.zig and parsed here; every other agent can still report
//! through `petdex_report_usage`. No token is ever refreshed: redeeming an
//! agent's refresh token signs that agent out.

const std = @import("std");
const plat = @import("plat.zig");
const sqlite = @import("sqlite.zig");

/// The rows, in the order they are drawn: every installable agent in
/// AgentKind's order, then Copilot, which has no installer of its own. The
/// tags are the names agentIconIndex takes.
pub const Agent = enum { @"claude-code", codex, gemini, opencode, qoder, @"kimi-code", codebuddy, omp, hermes, dsh, cursor, junie, antigravity, devin, grok, copilot, windsurf, amp, droid };
pub const agent_count = @typeInfo(Agent).@"enum".fields.len;

pub fn displayName(agent: Agent) []const u8 {
    return switch (agent) {
        .@"claude-code" => "Claude Code",
        .codex => "Codex",
        .gemini => "Gemini CLI",
        .opencode => "opencode",
        .qoder => "Qoder",
        .@"kimi-code" => "Kimi Code",
        .codebuddy => "CodeBuddy",
        .omp => "OMP",
        .hermes => "Hermes",
        .dsh => "DSH",
        .cursor => "Cursor",
        .junie => "Junie",
        .antigravity => "Antigravity",
        .devin => "Devin",
        .grok => "Grok",
        .copilot => "Copilot",
        .windsurf => "Windsurf / Devin Desktop",
        .amp => "Amp",
        .droid => "Droid",
    };
}

/// Agents with an endpoint source in addition to local observations.
fn fetchedByNet(agent: Agent) bool {
    return switch (agent) {
        .cursor, .copilot, .grok, .antigravity, .gemini => true,
        else => false,
    };
}

pub const five_hour_minutes: u32 = 5 * 60;
pub const week_minutes: u32 = 7 * 24 * 60;
/// Junie, Cursor and Copilot bill by the month.
pub const month_minutes: u32 = 30 * 24 * 60;

/// Each agent's observed windows or absolute credit usage; null is unknown.
pub const State = struct {
    windows: [agent_count]?Windows = @splat(null),
    local: [agent_count]?Windows = @splat(null),
    network: [agent_count]?Windows = @splat(null),
    /// When the windows were last read, epoch seconds: what expiry and
    /// the reset countdown count from.
    now_s: i64 = 0,
    /// The row clicked open.
    selected: ?Agent = null,
    next_file_ms: i64 = 0,
    next_net_ms: i64 = 0,

    pub fn used(self: *const State, agent: Agent) ?u8 {
        const windows = self.snapshot(agent) orelse return null;
        return tightest(windows.slice(), self.now_s);
    }

    pub fn snapshot(self: *const State, agent: Agent) ?Windows {
        return fresh(self.windows[@intFromEnum(agent)], self.now_s);
    }

    pub fn credits(self: *const State, agent: Agent) ?f64 {
        return (self.snapshot(agent) orelse return null).credits_used;
    }

    pub fn visible(self: *const State, agent: Agent) bool {
        return self.snapshot(agent) != null;
    }

    pub fn len(self: *const State) usize {
        var n: usize = 0;
        for (std.enums.values(Agent)) |agent| {
            if (self.visible(agent)) n += 1;
        }
        return n;
    }

    pub fn set(self: *State, agent: Agent, windows: ?Windows) void {
        var observed = windows;
        if (observed) |*w| {
            if (w.observed_at == 0) w.observed_at = self.now_s;
        }
        const index = @intFromEnum(agent);
        self.network[index] = observed;
        self.windows[index] = newestFresh(self.local[index], observed, self.now_s);
    }
};

pub const file_interval_ms: i64 = 60 * 1000;
pub const net_interval_ms: i64 = 5 * 60 * 1000;
/// After a 429 an endpoint is left alone for an hour.
pub const net_backoff_ms: i64 = 60 * 60 * 1000;

/// One limit window: percent used, when it resets (epoch seconds, 0 when
/// unknown), and how long it is (minutes, 0 when unknown).
pub const Window = struct {
    used: f64,
    resets_at: i64 = 0,
    minutes: u32 = 0,
    label_buf: [96]u8 = @splat(0),
    label_len: usize = 0,
    pub fn label(self: *const Window) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    fn setLabel(self: *Window, value: []const u8) void {
        self.label_len = @min(value.len, self.label_buf.len);
        @memcpy(self.label_buf[0..self.label_len], value[0..self.label_len]);
    }
};
pub const max_windows = 16;
pub const observation_ttl_s = 60 * 60;

fn fresh(windows: ?Windows, now_s: i64) ?Windows {
    var out = windows orelse return null;
    if (out.observed_at < 0 or out.observed_at > now_s + 60 or (out.observed_at > 0 and now_s - out.observed_at > observation_ttl_s)) return null;
    var count: usize = 0;
    for (out.slice()) |win| {
        if (win.resets_at != 0 and win.resets_at <= now_s) continue;
        out.items[count] = win;
        count += 1;
    }
    out.len = count;
    if (out.credits_used) |credits| {
        if (!std.math.isFinite(credits) or credits < 0 or (out.credits_resets_at != 0 and out.credits_resets_at <= now_s)) {
            out.credits_used = null;
            out.credits_resets_at = 0;
        }
    }
    return if (count == 0 and out.credits_used == null) null else out;
}

fn newestFresh(a: ?Windows, b: ?Windows, now_s: i64) ?Windows {
    const left = fresh(a, now_s);
    const right = fresh(b, now_s);
    if (left == null) return right;
    if (right == null) return left;
    return if (right.?.observed_at > left.?.observed_at) right else left;
}

pub const Windows = struct {
    items: [max_windows]Window = undefined,
    observed_at: i64 = 0,
    len: usize = 0,
    /// Consumption without a finite allowance. This is never a percentage
    /// and must not be compared with or added to the percentage windows.
    credits_used: ?f64 = null,
    credits_resets_at: i64 = 0,

    pub fn one(used: f64, resets_at: i64, minutes: u32) Windows {
        var out: Windows = .{};
        out.items[0] = .{ .used = used, .resets_at = resets_at, .minutes = minutes };
        out.len = 1;
        return out;
    }

    fn add(self: *Windows, used: ?f64, resets_at: ?f64, minutes: ?f64) void {
        const u = used orelse return;
        if (!std.math.isFinite(u) or u < 0 or u > 100) return;
        if (self.len == self.items.len) return;
        const r = resets_at orelse 0;
        const m = minutes orelse 0;
        self.items[self.len] = .{
            .used = u,
            .resets_at = if (r > 0 and r < 1e12) @intFromFloat(r) else 0,
            .minutes = if (m > 0 and m <= 1e7) @intFromFloat(m) else 0,
        };
        self.len += 1;
    }

    pub fn slice(self: *const Windows) []const Window {
        return self.items[0..self.len];
    }
};

/// The fullest unexpired window. An expired observation is unknown.
pub fn tightest(windows: []const Window, now_s: i64) ?u8 {
    if (windows.len == 0) return null;
    var most: ?f64 = null;
    for (windows) |w| {
        if (w.resets_at != 0 and w.resets_at <= now_s) continue;
        most = @max(most orelse 0, w.used);
    }
    return if (most) |value| percent(value) else null;
}

/// A retained window's reported usage. Callers filter expired observations.
pub fn current(w: Window, now_s: i64) f64 {
    _ = now_s; // Expired observations are filtered out, never inferred as 0%.
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
        const windows = fresh(state.windows[@intFromEnum(agent)], now_s) orelse continue;
        if (!any) w.writeAll("Their coding agents' plan usage right now, from the app:") catch {};
        any = true;
        w.print("\n- {s}:", .{displayName(agent)}) catch {};
        for (windows.slice(), 0..) |win, i| {
            w.writeAll(if (i > 0) "; " else " ") catch {};
            if (win.label_len > 0) w.print("{s} ", .{win.label()}) catch {};
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
        if (windows.credits_used) |credits| {
            w.writeAll(if (windows.len > 0) "; " else " ") catch {};
            w.print("{d} credits used (no percentage limit reported)", .{credits}) catch {};
            if (windows.credits_resets_at > now_s) {
                const c = countdown(windows.credits_resets_at - now_s);
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
        "means now is the time to put the agent to work; one nearly used up means pacing it until the reset. " ++
        "Absolute credits are consumption only: without a reported allowance, do not infer remaining capacity or a percentage.") catch {};
    return w.buffered();
}

/// An ISO calendar date or RFC 3339 timestamp, as epoch seconds. Provider
/// resets and credential expirations can carry a numeric UTC offset.
pub fn parseIso(s: []const u8) ?i64 {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    for (s[0..10], 0..) |c, i| {
        if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return null;
    }
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1) return null;
    const leap = @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
    const days_in_month: i64 = switch (m) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    if (d > days_in_month) return null;
    var secs: i64 = 0;
    if (s.len != 10) {
        if (s.len < 20 or (s[10] != 'T' and s[10] != 't' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
        for (s[11..19], 0..) |c, i| {
            if (i != 2 and i != 5 and !std.ascii.isDigit(c)) return null;
        }
        const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
        const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
        const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
        if (h < 0 or h > 23 or mi < 0 or mi > 59 or se < 0 or se > 59) return null;
        secs = h * 3600 + mi * 60 + se;
        var zone: usize = 19;
        if (s[zone] == '.') {
            zone += 1;
            const start = zone;
            while (zone < s.len and std.ascii.isDigit(s[zone])) : (zone += 1) {}
            if (zone == start or zone == s.len) return null;
        }
        if (s[zone] == 'Z' or s[zone] == 'z') {
            if (zone + 1 != s.len) return null;
        } else {
            if (zone + 6 != s.len or (s[zone] != '+' and s[zone] != '-') or s[zone + 3] != ':') return null;
            for (s[zone + 1 ..], 0..) |c, i| {
                if (i != 2 and !std.ascii.isDigit(c)) return null;
            }
            const oh = std.fmt.parseInt(i64, s[zone + 1 .. zone + 3], 10) catch return null;
            const om = std.fmt.parseInt(i64, s[zone + 4 .. zone + 6], 10) catch return null;
            if (oh < 0 or oh > 23 or om < 0 or om > 59) return null;
            const offset = oh * 3600 + om * 60;
            secs += if (s[zone] == '+') -offset else offset;
        }
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
    var n = (std.fmt.bufPrint(buf, "{{\"observed_at\":{d},\"windows\":[", .{windows.observed_at}) catch return null).len;
    for (windows.slice(), 0..) |w, i| {
        n += (std.fmt.bufPrint(buf[n..], "{s}[{d:.1},{d},{d}]", .{ if (i > 0) "," else "", w.used, w.resets_at, w.minutes }) catch return null).len;
    }
    n += (std.fmt.bufPrint(buf[n..], "]", .{}) catch return null).len;
    if (windows.credits_used) |credits| {
        if (!std.math.isFinite(credits) or credits < 0) return null;
        n += (std.fmt.bufPrint(buf[n..], ",\"credits_used\":{d},\"credits_resets_at\":{d}", .{ credits, windows.credits_resets_at }) catch return null).len;
    }
    n += (std.fmt.bufPrint(buf[n..], "}}", .{}) catch return null).len;
    return buf[0..n];
}

pub fn parseWindows(bytes: []const u8) ?Windows {
    const Root = struct { windows: []const []const f64 = &.{}, observed_at: i64 = 0, credits_used: ?f64 = null, credits_resets_at: i64 = 0 };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var out: Windows = .{};
    out.observed_at = parsed.value.observed_at;
    if (parsed.value.credits_used) |credits| {
        if (std.math.isFinite(credits) and credits >= 0) {
            out.credits_used = credits;
            out.credits_resets_at = parsed.value.credits_resets_at;
        }
    }
    for (parsed.value.windows) |w| {
        if (w.len < 2) continue;
        out.add(w[0], w[1], if (w.len > 2) w[2] else null);
    }
    return out;
}

fn windowsPath(buf: []u8, home: []const u8, agent: Agent) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.petdex/runtime/usage/{s}.json", .{ home, @tagName(agent) }) catch null;
}

/// Atomic snapshot with an observation time; unchanged values still refresh
/// their timestamp when the host reports them again.
pub fn writeWindows(home: []const u8, agent: Agent, windows: Windows) void {
    var path_buf: [512]u8 = undefined;
    const path = windowsPath(&path_buf, home, agent) orelse return;
    var buf: [2048]u8 = undefined;
    var snapshot = windows;
    if (snapshot.observed_at == 0) snapshot.observed_at = plat.nowSeconds();
    const bytes = formatWindows(snapshot, &buf) orelse return;
    var old_buf: [2048]u8 = undefined;
    if (plat.readFile(path, &old_buf)) |old| {
        if (std.mem.eql(u8, old, bytes)) return;
    }
    _ = plat.writeFile(path, bytes);
}

fn windowsFromFile(home: []const u8, agent: Agent) ?Windows {
    var path_buf: [512]u8 = undefined;
    const path = windowsPath(&path_buf, home, agent) orelse return null;
    var buf: [4096]u8 = undefined;
    var windows = parseWindows(plat.readFile(path, &buf) orelse return null) orelse return null;
    if (windows.observed_at == 0) windows.observed_at = @intCast(@divFloor(plat.fileMtime(path) orelse return null, 1_000_000_000));
    return if (windows.len > 0 or windows.credits_used != null) windows else null;
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
    return std.mem.indexOf(u8, line, "token_count") != null and
        std.mem.indexOf(u8, line, "rate_limits") != null and windowsFromCodexLine(line) != null;
}

/// `payload.rate_limits.primary` and `secondary` of a token_count line.
/// Other limit ids (a model's own pool) are not the plan's limit.
pub fn windowsFromCodexLine(line: []const u8) ?Windows {
    const W = struct { used_percent: ?f64 = null, resets_at: ?f64 = null, window_minutes: ?f64 = null };
    const Limits = struct { limit_id: ?[]const u8 = null, primary: ?W = null, secondary: ?W = null };
    const Root = struct { timestamp: ?[]const u8 = null, payload: ?struct { rate_limits: ?Limits = null } = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, line, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const limits = (parsed.value.payload orelse return null).rate_limits orelse return null;
    if (limits.limit_id) |id| {
        if (!std.mem.eql(u8, id, "codex")) return null;
    }
    var out: Windows = .{};
    if (parsed.value.timestamp) |ts| out.observed_at = parseIso(ts) orelse 0;
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
    if (!std.math.isFinite(current_v) or current_v < 0 or !std.math.isFinite(maximum) or maximum <= 0) return null;
    const used = current_v / maximum * 100;
    if (!std.math.isFinite(used)) return null;
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
    return Windows.one(used, resets_at, month_minutes);
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
    var result = windowsFromJetBrainsXml(xml, &scratch) orelse return null;
    result.observed_at = @intCast(@divFloor(newest.mtime, 1_000_000_000));
    return result;
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

/// The local sources, cheap enough for a read every minute: every agent's
/// reported file, plus the on-disk sources Codex and Junie keep on their
/// own. A fetched agent keeps its fetched windows until a report lands.
pub fn readFiles(state: *State, home: []const u8, now_ms: i64) void {
    state.now_s = @divFloor(now_ms, 1000);
    for (std.enums.values(Agent)) |agent| {
        const native = switch (agent) {
            .codex => windowsFromCodexSessions(home, state.now_s),
            .junie => windowsFromJetBrains(home),
            else => null,
        };
        const index = @intFromEnum(agent);
        state.local[index] = newestFresh(windowsFromFile(home, agent), native, state.now_s);
        state.windows[index] = newestFresh(state.local[index], state.network[index], state.now_s);
    }
}

/// Resumed sessions keep their original filenames. Compare observation times,
/// not lexical dates, and skip newer sessions with no account quota at all.
fn windowsFromCodexSessions(home: []const u8, now_s: i64) ?Windows {
    var dir_buf: [512]u8 = undefined;
    const dir = @import("agent_mcp.zig").presenceDir(&dir_buf, home, .codex) orelse return null;
    var root_buf: [768]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, "{s}/sessions", .{dir}) catch return null;
    var best: ?Windows = null;
    findNewestRollout(root, &best, 0, now_s);
    return best;
}

fn findNewestRollout(dir_path: []const u8, best: *?Windows, depth: usize, now_s: i64) void {
    if (depth > 4) return;
    const Ctx = struct {
        parent: []const u8,
        best: *?Windows,
        depth: usize,
        now_s: i64,
        fn visit(self: *@This(), name: []const u8) void {
            if (name.len == 0 or name[0] == '.') return;
            var child_buf: [768]u8 = undefined;
            const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ self.parent, name }) catch return;
            if (plat.dirExists(child)) {
                findNewestRollout(child, self.best, self.depth + 1, self.now_s);
                return;
            }
            if (!std.mem.startsWith(u8, name, "rollout-") or !std.mem.endsWith(u8, name, ".jsonl")) return;
            const mtime: i64 = @intCast(@divFloor(plat.fileMtime(child) orelse return, 1_000_000_000));
            if (self.best.*) |previous| {
                if (mtime < previous.observed_at) return;
            }
            var scan_buf: [64 * 1024]u8 = undefined;
            const line = plat.lastLineMatching(child, &scan_buf, carriesCodexLimits) orelse return;
            var windows = windowsFromCodexLine(line) orelse return;
            if (windows.observed_at == 0) windows.observed_at = mtime;
            windows = fresh(windows, self.now_s) orelse return;
            if (self.best.*) |previous| {
                if (windows.observed_at <= previous.observed_at) return;
            }
            self.best.* = windows;
        }
    };
    var ctx: Ctx = .{ .parent = dir_path, .best = best, .depth = depth, .now_s = now_s };
    plat.forEachEntry(dir_path, &ctx, Ctx.visit);
}

// ------------------------------------------------------------ copilot

pub const copilot_url = "https://api.github.com/copilot_internal/user";

/// The active public GitHub account in the language server's current store.
/// The legacy apps.json file is read only when no auth.db exists: it can
/// remain on disk with an old account long after the language server migrates.
pub fn copilotToken(home: []const u8, out: []u8) ?[]const u8 {
    var dir_buf: [512]u8 = undefined;
    const xdg = @import("agent_mcp.zig").env_xdg_config_home;
    const dir = if (xdg != null and xdg.?.len > 0)
        std.fmt.bufPrint(&dir_buf, "{s}/github-copilot", .{xdg.?}) catch return null
    else
        std.fmt.bufPrint(&dir_buf, "{s}/.config/github-copilot", .{home}) catch return null;
    var path_buf: [768:0]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&path_buf, "{s}/auth.db", .{dir}) catch return null;
    if (plat.fileExists(db_path)) return copilotDatabaseToken(db_path, out);
    const path = std.fmt.bufPrint(&path_buf, "{s}/apps.json", .{dir}) catch return null;
    var buf: [16 * 1024]u8 = undefined;
    defer @memset(&buf, 0);
    return copilotTokenFrom(plat.readFile(path, &buf) orelse return null, out);
}

fn copilotDatabaseToken(path: [:0]const u8, out: []u8) ?[]const u8 {
    if (!sqlite.load()) return null;
    var db = sqlite.Db.openReadOnly(path) catch return null;
    defer db.close();
    // Stored tokens are not necessarily signed in. Follow the newest active
    // editor session, excluding a subsequent sign-out; do not try a different
    // account when the chosen token uses an unsupported encrypted schema.
    var stmt = db.prepare(
        \\SELECT t.token_ciphertext, t.token_schema_version
        \\FROM active_sessions AS s JOIN oauth_tokens AS t ON t.token_id = s.token_id
        \\WHERE t.auth_authority = 'github.com'
        \\AND NOT EXISTS (SELECT 1 FROM editor_signout AS e
        \\  WHERE e.editor_id = s.editor_id AND e.signed_out_at >= s.activated_at)
        \\ORDER BY s.activated_at DESC, t.last_used_at DESC, t.token_id DESC LIMIT 1
    ) catch return null;
    defer stmt.finalize();
    if (!(stmt.step() catch return null) or !std.mem.eql(u8, stmt.text(1), "0")) return null;
    const token = stmt.text(0);
    if (token.len <= 4 or token.len > out.len or
        (!std.mem.startsWith(u8, token, "ghu_") and !std.mem.startsWith(u8, token, "gho_"))) return null;
    for (token[4..]) |c| {
        if (!std.ascii.isAlphanumeric(c)) return null;
    }
    @memcpy(out[0..token.len], token);
    return out[0..token.len];
}

fn copilotTokenFrom(apps_json: []const u8, out: []u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, apps_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const apps = parsed.value.object;
    if (apps.get("github.com:Iv1.b507a08c87ecfe98")) |entry| {
        if (copilotEntryToken(entry, out)) |token| return token;
    }
    var it = apps.iterator();
    while (it.next()) |entry| {
        // An enterprise host's token must never be sent to api.github.com.
        const host = entry.key_ptr.*;
        if (!std.mem.eql(u8, host, "github.com") and !std.mem.startsWith(u8, host, "github.com:")) continue;
        if (copilotEntryToken(entry.value_ptr.*, out)) |token| return token;
    }
    return null;
}

fn copilotEntryToken(entry: std.json.Value, out: []u8) ?[]const u8 {
    if (entry != .object) return null;
    const token = entry.object.get("oauth_token") orelse return null;
    if (token != .string or !headerSafe(token.string) or token.string.len > out.len) return null;
    @memcpy(out[0..token.string.len], token.string);
    return out[0..token.string.len];
}

/// Keep each limited category, including Free's chat/completion allowance.
/// Copilot's current snapshot contract also covers AI-credit billing. An
/// unlimited pooled plan has no percentage denominator, but may report its
/// absolute credit consumption separately from bounded percentage windows.
pub fn windowsFromCopilot(body: []const u8) ?Windows {
    const Snap = struct {
        percent_remaining: ?f64 = null,
        unlimited: ?bool = null,
        entitlement: ?std.json.Value = null,
        quota_reset_at: ?f64 = null,
        credits_used: ?f64 = null,
    };
    const Categories = struct { premium_interactions: ?Snap = null, chat: ?Snap = null, completions: ?Snap = null };
    const Legacy = struct { chat: ?f64 = null, completions: ?f64 = null };
    const Root = struct {
        quota_reset_date_utc: ?[]const u8 = null,
        quota_reset_date: ?[]const u8 = null,
        limited_user_reset_date: ?[]const u8 = null,
        token_based_billing: ?bool = null,
        quota_snapshots: ?Categories = null,
        monthly_quotas: ?Legacy = null,
        limited_user_quotas: ?Legacy = null,
    };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    const snapshots = root.quota_snapshots orelse Categories{};
    const monthly = root.monthly_quotas orelse Legacy{};
    const remaining_quotas = root.limited_user_quotas orelse Legacy{};
    var account_reset: i64 = 0;
    for ([_]?[]const u8{ root.quota_reset_date_utc, root.quota_reset_date, root.limited_user_reset_date }) |date| {
        account_reset = parseIso(date orelse continue) orelse continue;
        break;
    }
    var out: Windows = .{};
    inline for (.{ "premium_interactions", "chat", "completions" }) |category| {
        var used: ?f64 = null;
        var resets_at = account_reset;
        if (@field(snapshots, category)) |snap| {
            if (!(snap.unlimited orelse false)) {
                const entitlement = numberOf(snap.entitlement);
                const allocated = snap.entitlement == null or (entitlement != null and std.math.isFinite(entitlement.?) and entitlement.? > 0);
                if (allocated) {
                    if (snap.percent_remaining) |remaining| {
                        if (std.math.isFinite(remaining) and remaining >= 0 and remaining <= 100) used = 100 - remaining;
                    }
                }
            }
            if (snap.quota_reset_at) |reset| {
                if (std.math.isFinite(reset) and reset > 0 and reset < 1e12) resets_at = @intFromFloat(reset);
            }
            if (comptime std.mem.eql(u8, category, "premium_interactions")) {
                if (snap.unlimited orelse false) {
                    if (snap.credits_used) |credits| {
                        if (std.math.isFinite(credits) and credits >= 0) {
                            out.credits_used = credits;
                            out.credits_resets_at = resets_at;
                        }
                    }
                }
            }
        } else if (comptime !std.mem.eql(u8, category, "premium_interactions")) {
            const limit = @field(monthly, category);
            const remaining = @field(remaining_quotas, category);
            if (limit != null and remaining != null and std.math.isFinite(limit.?) and std.math.isFinite(remaining.?) and limit.? > 0 and remaining.? >= 0 and remaining.? <= limit.?) {
                used = (1 - remaining.? / limit.?) * 100;
            }
        }
        if (used) |value| {
            out.items[out.len] = .{ .used = value, .resets_at = resets_at, .minutes = month_minutes };
            out.items[out.len].setLabel(if (std.mem.eql(u8, category, "premium_interactions"))
                (if (root.token_based_billing orelse false) "Plan credits" else "Premium requests")
            else if (std.mem.eql(u8, category, "chat"))
                (if (root.token_based_billing orelse false) "Chat credits" else "Chat")
            else
                "Completions");
            out.len += 1;
        }
    }
    return if (out.len == 0 and out.credits_used == null) null else out;
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
        const amount = plan.used orelse return null;
        if (!std.math.isFinite(limit) or limit <= 0 or !std.math.isFinite(amount) or amount < 0) return null;
        break :blk amount / limit * 100;
    };
    // A missing or malformed observation is unknown, never an unused plan.
    // Cursor can report overages; keep those and cap only the displayed bar.
    if (!std.math.isFinite(used) or used < 0) return null;
    const resets_at = if (parsed.value.billingCycleEnd) |end| parseIso(end) orelse 0 else 0;
    return Windows.one(used, resets_at, month_minutes);
}

// --------------------------------------------------------------- grok

/// `format=credits` is the rolling weekly product pool Grok Build's /usage
/// shows; the bare endpoint's monthly dollar allowance is a different meter.
pub const grok_url = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";

/// GROK_AUTH_PATH relocates the auth file itself (a file path, unlike the
/// directory GROK_HOME moves).
pub var env_grok_auth_path: ?[]const u8 = null;

pub const GrokCred = struct { token: []const u8, user_id: ?[]const u8 };

/// Grok Build's session token and user id, from its auth file: a map of
/// `issuer::client_id` entries holding `key`, `expires_at` and `user_id`.
/// Only the public consumer issuer counts — a custom enterprise issuer's
/// token does not belong at cli-chat-proxy — and only while unexpired;
/// refreshing the OIDC pair is the CLI's job.
pub fn grokCred(grok_home: []const u8, tok_out: []u8, uid_out: []u8, now_s: i64) ?GrokCred {
    var path_buf: [512]u8 = undefined;
    const path = if (env_grok_auth_path) |p| blk: {
        if (p.len == 0 or p.len > path_buf.len) return null;
        @memcpy(path_buf[0..p.len], p);
        break :blk path_buf[0..p.len];
    } else std.fmt.bufPrint(&path_buf, "{s}/auth.json", .{grok_home}) catch return null;
    var buf: [16 * 1024]u8 = undefined;
    const json = plat.readFile(path, &buf) orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, "https://auth.x.ai::")) continue;
        if (entry.value_ptr.* != .object) continue;
        const key = entry.value_ptr.object.get("key") orelse continue;
        if (key != .string or !headerSafe(key.string) or key.string.len > tok_out.len) continue;
        const expires = entry.value_ptr.object.get("expires_at") orelse continue;
        if (expires != .string) continue;
        const expires_s = parseIso(expires.string) orelse continue;
        if (expires_s <= now_s) continue;
        var user_id: ?[]const u8 = null;
        if (entry.value_ptr.object.get("user_id")) |uid| {
            if (uid == .string and headerSafe(uid.string) and uid.string.len <= uid_out.len) {
                @memcpy(uid_out[0..uid.string.len], uid.string);
                user_id = uid_out[0..uid.string.len];
            }
        }
        @memcpy(tok_out[0..key.string.len], key.string);
        return .{ .token = tok_out[0..key.string.len], .user_id = user_id };
    }
    return null;
}

/// Grok's own version, for the client headers the billing proxy expects.
pub fn grokClientVersion(grok_home: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/version.json", .{grok_home}) catch return null;
    var buf: [1024]u8 = undefined;
    const json = plat.readFile(path, &buf) orelse return null;
    const Root = struct { version: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const version = parsed.value.version orelse return null;
    if (!headerSafe(version) or version.len > out.len) return null;
    @memcpy(out[0..version.len], version);
    return out[0..version.len];
}

/// `config.creditUsagePercent` of `?format=credits`, resetting at
/// `config.currentPeriod.end`.
pub fn windowsFromGrokCredits(body: []const u8) ?Windows {
    const Period = struct { type: ?[]const u8 = null, end: ?[]const u8 = null };
    const Cfg = struct {
        creditUsagePercent: ?f64 = null,
        credit_usage_percent: ?f64 = null,
        currentPeriod: ?Period = null,
        current_period: ?Period = null,
        billingPeriodEnd: ?[]const u8 = null,
        billing_period_end: ?[]const u8 = null,
    };
    const Root = struct { config: ?Cfg = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var bare = std.json.parseFromSlice(Cfg, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer bare.deinit();
    const cfg = parsed.value.config orelse bare.value;
    const pct = cfg.creditUsagePercent orelse cfg.credit_usage_percent orelse return null;
    if (!std.math.isFinite(pct) or pct < 0) return null;
    const period = cfg.currentPeriod orelse cfg.current_period;
    var resets_at: i64 = 0;
    if (period) |p| {
        if (p.end) |end| resets_at = parseIso(end) orelse 0;
    }
    if (resets_at == 0) {
        const end = cfg.billingPeriodEnd orelse cfg.billing_period_end;
        if (end) |e| resets_at = parseIso(e) orelse 0;
    }
    const minutes: u32 = if (period) |p| blk: {
        const period_type = p.type orelse break :blk week_minutes;
        if (std.mem.indexOf(u8, period_type, "MONTH") != null) break :blk month_minutes;
        break :blk week_minutes;
    } else week_minutes;
    return Windows.one(pct, resets_at, minutes);
}

// --------------------------------------------------------- antigravity

/// agy's own quota view: two shared pools (Gemini models, Claude+GPT) with
/// a five-hour and a weekly bucket each. The cloudcode endpoint wants a
/// recognized client UA; the agy binary identifies as "antigravity".
pub const antigravity_url = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary";

pub var env_gemini_force_file_storage: bool = false;

/// Gemini owns gemini-cli-oauth/main-account; Antigravity owns
/// gemini/antigravity. Never substitute one account for the other.
pub fn googleToken(gemini_home: []const u8, out: []u8, now_s: i64) ?[]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    defer @memset(&buf, 0);
    if (!env_gemini_force_file_storage) {
        switch (@import("secret_store.zig").readForeign("gemini-cli-oauth", "main-account", &buf)) {
            .value => |bytes| return googleTokenFrom(bytes, out, now_s),
            .unavailable => return null,
            .missing => {},
        }
    }
    var path_buf: [768]u8 = undefined;
    const encrypted_path = std.fmt.bufPrint(&path_buf, "{s}/gemini-credentials.json", .{gemini_home}) catch return null;
    if (plat.readFile(encrypted_path, &buf)) |encrypted| {
        // Presence of the modern store is authoritative, even if unreadable:
        // falling back to an old account's token would misattribute usage.
        var plain: [32 * 1024]u8 = undefined;
        defer @memset(&plain, 0);
        var salt_buf: [512]u8 = undefined;
        const salt = geminiCredentialSalt(&salt_buf) orelse return null;
        const json = decryptGeminiCredentials(encrypted, salt, &plain) orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const service_obj = parsed.value.object.get("gemini-cli-oauth") orelse return null;
        if (service_obj != .object) return null;
        const account = service_obj.object.get("main-account") orelse return null;
        if (account != .string) return null;
        return googleTokenFrom(account.string, out, now_s);
    }
    if (plat.fileSize(encrypted_path) != null) return null;
    const path = std.fmt.bufPrint(&path_buf, "{s}/oauth_creds.json", .{gemini_home}) catch return null;
    return googleTokenFrom(plat.readFile(path, &buf) orelse return null, out, now_s);
}

pub fn antigravityToken(out: []u8, now_s: i64) ?[]const u8 {
    var buf: [16 * 1024]u8 = undefined;
    defer @memset(&buf, 0);
    const bytes = switch (@import("secret_store.zig").readForeign("gemini", "antigravity", &buf)) {
        .value => |value| value,
        else => return null,
    };
    var decoded: [16 * 1024]u8 = undefined;
    defer @memset(&decoded, 0);
    return googleTokenFrom(decodeGoKeyring(bytes, &decoded) orelse return null, out, now_s);
}

fn decodeGoKeyring(bytes: []const u8, out: []u8) ?[]const u8 {
    const raw = std.mem.trim(u8, bytes, " \t\r\n");
    const b64 = "go-keyring-base64:";
    const hex = "go-keyring-encoded:";
    if (std.mem.startsWith(u8, raw, b64)) {
        const encoded = raw[b64.len..];
        const len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
        if (len > out.len) return null;
        std.base64.standard.Decoder.decode(out[0..len], encoded) catch return null;
        return out[0..len];
    }
    if (std.mem.startsWith(u8, raw, hex)) return std.fmt.hexToBytes(out, raw[hex.len..]) catch null;
    return raw;
}

fn googleTokenFrom(bytes: []const u8, out: []u8, now_s: i64) ?[]const u8 {
    const Token = struct { accessToken: ?[]const u8 = null, expiresAt: ?f64 = null };
    const Root = struct { token: ?Token = null, access_token: ?[]const u8 = null, expiry_date: ?f64 = null, expiry: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    const token = if (root.token) |value| value.accessToken orelse return null else root.access_token orelse return null;
    const ms = if (root.token) |value| value.expiresAt else root.expiry_date;
    const expiry: i64 = if (ms) |value| blk: {
        if (!std.math.isFinite(value) or value <= 0 or value >= 1e15) return null;
        break :blk @intFromFloat(value / 1000);
    } else if (root.expiry) |value| parseIso(value) orelse return null else return null;
    if (expiry <= now_s or !headerSafe(token) or token.len > out.len) return null;
    @memcpy(out[0..token.len], token);
    return out[0..token.len];
}

fn geminiCredentialSalt(out: []u8) ?[]const u8 {
    if (@import("builtin").os.tag != .macos) return null;
    var hostname: [256]u8 = @splat(0);
    if (std.c.gethostname(&hostname, hostname.len - 1) != 0) return null;
    const pw = std.c.getpwuid(std.c.getuid()) orelse return null;
    const user = std.mem.span(pw.name orelse return null);
    return std.fmt.bufPrint(out, "{s}-{s}-gemini-cli", .{ std.mem.sliceTo(&hostname, 0), user }) catch null;
}

/// Gemini's FileKeychain: scrypt(default Node parameters), AES-256-GCM,
/// hex iv:tag:ciphertext. This reader neither migrates nor rewrites the file.
fn decryptGeminiCredentials(encrypted: []const u8, salt: []const u8, out: []u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, encrypted, " \r\n\t"), ':');
    const iv_hex = parts.next() orelse return null;
    const tag_hex = parts.next() orelse return null;
    const cipher_hex = parts.next() orelse return null;
    if (parts.next() != null or iv_hex.len != 24 or tag_hex.len != 32 or cipher_hex.len % 2 != 0 or cipher_hex.len / 2 > out.len) return null;
    var iv: [12]u8 = undefined;
    var tag: [16]u8 = undefined;
    var key: [32]u8 = undefined;
    defer @memset(&key, 0);
    _ = std.fmt.hexToBytes(&iv, iv_hex) catch return null;
    _ = std.fmt.hexToBytes(&tag, tag_hex) catch return null;
    const cipher = std.fmt.hexToBytes(out, cipher_hex) catch return null;
    std.crypto.pwhash.scrypt.kdf(std.heap.page_allocator, &key, "gemini-cli-oauth", salt, .{ .ln = 14, .r = 8, .p = 1 }) catch return null;
    std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(cipher, cipher, tag, "", iv, key) catch return null;
    return cipher;
}

const AntigravityBucket = struct { bucketId: ?[]const u8 = null, resetTime: ?[]const u8 = null, remainingFraction: ?f64 = null };

/// `groups[].buckets[]` (or a flat `buckets[]`), each `remainingFraction`
/// and `resetTime`; a bucket id suffix says how long the window is. The
/// column retains each model/pool identity, up to max_windows.
pub fn windowsFromAntigravityQuota(body: []const u8) ?Windows {
    const Group = struct { buckets: []const AntigravityBucket = &.{} };
    const Root = struct { groups: []const Group = &.{}, buckets: []const AntigravityBucket = &.{} };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var out: Windows = .{};
    addAntigravityBuckets(&out, parsed.value.buckets);
    for (parsed.value.groups) |group| addAntigravityBuckets(&out, group.buckets);
    return if (out.len > 0) out else null;
}

fn addAntigravityBuckets(out: *Windows, buckets: []const AntigravityBucket) void {
    for (buckets) |bucket| {
        const remaining = bucket.remainingFraction orelse continue;
        const used = (1 - remaining) * 100;
        const resets_at = if (bucket.resetTime) |r| parseIso(r) orelse 0 else 0;
        const minutes = bucketMinutes(bucket.bucketId);
        if (out.len < out.items.len and remaining >= 0 and remaining <= 1) {
            out.items[out.len] = .{ .used = used, .resets_at = resets_at, .minutes = minutes };
            out.items[out.len].setLabel(bucket.bucketId orelse "Quota");
            out.len += 1;
        }
    }
}

/// `gemini-5h` is five hours; `3p-weekly` a week. Anything else is unknown.
fn bucketMinutes(bucket_id: ?[]const u8) u32 {
    const id = bucket_id orelse return 0;
    if (std.mem.indexOf(u8, id, "5h") != null) return five_hour_minutes;
    if (std.mem.indexOf(u8, id, "week") != null or std.mem.indexOf(u8, id, "7d") != null) return week_minutes;
    if (std.mem.indexOf(u8, id, "day") != null or std.mem.indexOf(u8, id, "24h") != null) return 24 * 60;
    if (std.mem.indexOf(u8, id, "month") != null) return month_minutes;
    return 0;
}

// -------------------------------------------------------------- gemini

/// Code Assist's two reads: loadCodeAssist resolves the project, then
/// retrieveUserQuota answers its per-model buckets.
pub const gemini_load_url = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
pub const gemini_quota_url = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";

/// `cloudaicompanionProject` of loadCodeAssist: a bare id or `{"id": …}`.
pub fn projectFromCodeAssist(body: []const u8, out: []u8) ?[]const u8 {
    const Root = struct {
        cloudaicompanionProject: ?std.json.Value = null,
    };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const project = parsed.value.cloudaicompanionProject orelse return null;
    const id = switch (project) {
        .string => |s| s,
        .object => |o| if (o.get("id")) |v| switch (v) {
            .string => |s| s,
            else => return null,
        } else return null,
        else => return null,
    };
    if (!headerSafe(id) or id.len > out.len) return null;
    @memcpy(out[0..id.len], id);
    return out[0..id.len];
}

/// `buckets[]` of retrieveUserQuota: per-model `remainingFraction` and
/// `resetTime`. Preserve model labels and individual resets. The periods
/// are unknown, so the windows carry no inferred length.
pub fn windowsFromGeminiQuota(body: []const u8) ?Windows {
    const Bucket = struct { modelId: ?[]const u8 = null, remainingFraction: ?f64 = null, resetTime: ?[]const u8 = null };
    const Root = struct { buckets: []const Bucket = &.{} };
    var parsed = std.json.parseFromSlice(Root, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    var out: Windows = .{};
    for (parsed.value.buckets) |bucket| {
        const remaining = bucket.remainingFraction orelse continue;
        var window: Window = .{
            .used = (1 - remaining) * 100,
            .resets_at = if (bucket.resetTime) |r| parseIso(r) orelse 0 else 0,
        };
        if (remaining < 0 or remaining > 1) continue;
        window.setLabel(bucket.modelId orelse "Quota");
        if (out.len < out.items.len) {
            out.items[out.len] = window;
            out.len += 1;
            continue;
        }
        var smallest: *Window = &out.items[0];
        for (out.items[1..out.len]) |*w| {
            if (w.used < smallest.used) smallest = w;
        }
        if (window.used > smallest.used) smallest.* = window;
    }
    return if (out.len > 0) out else null;
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
    try t.expectEqual(@as(?u8, null), tightest(&windows, 10000));
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
    try t.expectEqual(@as(?u8, null), state.used(.codex));
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
        "\n- Claude Code: 5-hour limit 42% used, resets in 2h 13m; weekly limit 18% used, resets in 3d 4h" ++ "\n"));
    try t.expect(std.mem.indexOf(u8, c, "now is the time") != null);
    try t.expectEqual(Countdown{ .days = 0, .hours = 0, .minutes = 1 }, countdown(1));
}

test "ISO dates and times as epoch seconds" {
    try t.expectEqual(@as(?i64, 0), parseIso("1970-01-01T00:00:00Z"));
    try t.expectEqual(@as(?i64, 1791489670), parseIso("2026-10-08T20:01:10.119Z"));
    try t.expectEqual(@as(?i64, 1790812800), parseIso("2026-10-01"));
    try t.expectEqual(@as(?i64, 951782400), parseIso("2000-02-29"));
    try t.expectEqual(parseIso("2026-10-08T20:01:10Z"), parseIso("2026-10-09T05:01:10.123456+09:00"));
    try t.expectEqual(parseIso("2026-10-08T20:01:10Z"), parseIso("2026-10-08T13:01:10-07:00"));
    try t.expect(parseIso("soon") == null);
    try t.expect(parseIso("2026-13-01") == null);
    for ([_][]const u8{
        "2026-02-29",            "2026-04-31",                "2026-10-01junk",            "2026-10-01T24:00:00Z",
        "2026-10-01T12:60:00Z",  "2026-10-01T12:00:60Z",      "2026-10-01T12:00:00",       "2026-10-01T12x00x00Z",
        "2026-10-01T12:00:00.Z", "2026-10-01T12:00:00+24:00", "2026-10-01T12:00:00+09:60", "2026-10-01T12:00:00Zjunk",
        "2026-+1-01",
    }) |invalid| try t.expect(parseIso(invalid) == null);
}

test "the windows file round-trips" {
    var windows: Windows = .{};
    windows.add(42.5, 1789812651, 300);
    windows.add(3, null, null);
    var buf: [192]u8 = undefined;
    const bytes = formatWindows(windows, &buf).?;
    try t.expectEqualStrings("{\"observed_at\":0,\"windows\":[[42.5,1789812651,300],[3.0,0,0]]}", bytes);
    const back = parseWindows(bytes).?;
    try t.expectEqual(@as(usize, 2), back.len);
    try t.expectEqual(@as(i64, 1789812651), back.items[0].resets_at);
    try t.expectEqual(@as(u32, 300), back.items[0].minutes);
    try t.expectEqual(@as(f64, 3), back.items[1].used);
    const boundary = parseWindows("{\"observed_at\":1,\"windows\":[[10,0,10000000]]}").?;
    try t.expectEqual(@as(u32, 10000000), boundary.items[0].minutes);
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

test "Copilot credentials stay on their public host and respect XDG_CONFIG_HOME" {
    var out: [64]u8 = undefined;
    try t.expect(copilotTokenFrom("{\"enterprise.example.com:Ov23\":{\"oauth_token\":\"private\"}}", &out) == null);
    try t.expect(copilotTokenFrom("{\"github.com.evil:Ov23\":{\"oauth_token\":\"private\"}}", &out) == null);
    try t.expectEqualStrings("public", copilotTokenFrom(
        \\{"enterprise.example.com:Ov23":{"oauth_token":"private"},"github.com:Iv1.b507a08c87ecfe98":{},"github.com:Ov23":{"oauth_token":"public"}}
    , &out).?);
    const mcp = @import("agent_mcp.zig");
    const saved = mcp.env_xdg_config_home;
    defer mcp.env_xdg_config_home = saved;
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{test_dir.sub_path[0..]});
    var path_buf: [300]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/github-copilot/apps.json", .{dir});
    mcp.env_xdg_config_home = dir;
    try t.expect(plat.writeFile(path, "{\"github.com:Ov23\":{\"oauth_token\":\"relocated\"}}"));
    try t.expectEqualStrings("relocated", copilotToken("unused-home", &out).?);
}

test "Copilot current database selects only an active public account and owns fallback" {
    if (!sqlite.load()) return error.SkipZigTest;
    const mcp = @import("agent_mcp.zig");
    const saved = mcp.env_xdg_config_home;
    defer mcp.env_xdg_config_home = saved;
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}", .{test_dir.sub_path[0..]});
    mcp.env_xdg_config_home = dir;
    var path_buf: [512:0]u8 = undefined;
    const legacy_path = try std.fmt.bufPrint(&path_buf, "{s}/github-copilot/apps.json", .{dir});
    try t.expect(plat.writeFile(legacy_path, "{\"github.com:legacy\":{\"oauth_token\":\"gho_legacy\"}}"));
    const db_path = try std.fmt.bufPrintZ(&path_buf, "{s}/github-copilot/auth.db", .{dir});
    var db = try sqlite.Db.open(db_path);
    defer db.close();
    try db.exec(
        \\PRAGMA journal_mode=WAL;
        \\CREATE TABLE oauth_tokens (token_id INTEGER PRIMARY KEY, auth_authority TEXT,
        \\  token_ciphertext BLOB, token_schema_version INTEGER, last_used_at INTEGER);
        \\CREATE TABLE active_sessions (editor_id TEXT PRIMARY KEY, token_id INTEGER, activated_at INTEGER);
        \\CREATE TABLE editor_signout (editor_id TEXT PRIMARY KEY, signed_out_at INTEGER);
        \\INSERT INTO oauth_tokens VALUES (1, 'github.com', 'gho_inactive', 0, 999),
        \\  (2, 'github.com', 'ghu_current', 0, 100),
        \\  (3, 'enterprise.example.com', 'ghu_private', 0, 999);
        \\INSERT INTO active_sessions VALUES ('webstorm', 2, 100), ('other-editor', 3, 999);
    );
    var out: [64]u8 = undefined;
    try t.expectEqualStrings("ghu_current", copilotToken("unused-home", &out).?);
    // An encrypted current token is not a reason to use old plaintext or a
    // stale apps.json account. The reader never refreshes or modifies tokens.
    try db.exec("UPDATE oauth_tokens SET token_schema_version=1 WHERE token_id=2;");
    try t.expect(copilotToken("unused-home", &out) == null);
    try db.exec("UPDATE oauth_tokens SET token_schema_version=0 WHERE token_id=2; INSERT INTO editor_signout VALUES ('webstorm', 100);");
    try t.expect(copilotToken("unused-home", &out) == null);
    try db.exec("DELETE FROM editor_signout; UPDATE oauth_tokens SET token_ciphertext='opaque encrypted data' WHERE token_id=2;");
    try t.expect(copilotToken("unused-home", &out) == null);
    try db.exec("DELETE FROM active_sessions;");
    try t.expect(copilotToken("unused-home", &out) == null);
    try db.exec("DROP TABLE active_sessions;");
    try t.expect(copilotToken("unused-home", &out) == null);
}

test "Grok's weekly credits and its auth file" {
    const body =
        \\{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-14T00:00:00Z","end":"2026-09-21T00:00:00Z"},"creditUsagePercent":26.5}}
    ;
    const windows = windowsFromGrokCredits(body).?;
    try t.expectEqual(@as(?u8, 27), tightest(windows.slice(), 0));
    try t.expectEqual(week_minutes, windows.items[0].minutes);
    try t.expectEqual(@as(i64, 1789948800), windows.items[0].resets_at);
    // A bare config object parses too; no percentage means no row, never 0%.
    try t.expect(windowsFromGrokCredits("{\"creditUsagePercent\":41}").?.items[0].used == 41);
    try t.expect(windowsFromGrokCredits("{\"config\":{}}") == null);
}

test "Copilot credit and Free quotas retain category identity and authoritative resets" {
    const credits = windowsFromCopilot(
        \\{"token_based_billing":true,"quota_reset_date":"2026-09-30","quota_reset_date_utc":"2026-10-01T04:00:00Z","quota_snapshots":{"premium_interactions":{"entitlement":"0","percent_remaining":100},"chat":{"entitlement":"200","has_quota":false,"percent_remaining":75,"quota_reset_at":1790820000},"completions":{"unlimited":true,"percent_remaining":100}}}
    ).?;
    try t.expectEqual(@as(usize, 1), credits.len);
    try t.expectEqualStrings("Chat credits", credits.items[0].label());
    try t.expectEqual(@as(?u8, 25), tightest(credits.slice(), 0));
    try t.expectEqual(@as(i64, 1790820000), credits.items[0].resets_at);
    const utc = windowsFromCopilot(
        \\{"quota_reset_date":"2026-09-30","quota_reset_date_utc":"2026-10-01T04:00:00Z","quota_snapshots":{"premium_interactions":{"percent_remaining":50}}}
    ).?;
    try t.expectEqual(parseIso("2026-10-01T04:00:00Z").?, utc.items[0].resets_at);
    const legacy = windowsFromCopilot(
        \\{"limited_user_reset_date":"2026-10-01","monthly_quotas":{"chat":500,"completions":2000},"limited_user_quotas":{"chat":400,"completions":800}}
    ).?;
    try t.expectEqual(@as(usize, 2), legacy.len);
    try t.expectEqual(@as(?u8, 60), tightest(legacy.slice(), 0));
    try t.expectEqualStrings("Chat", legacy.items[0].label());
    try t.expectEqualStrings("Completions", legacy.items[1].label());
    try t.expectEqual(parseIso("2026-10-01").?, legacy.items[1].resets_at);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"entitlement\":0,\"percent_remaining\":100}}}") == null);
    const unlimited = windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"unlimited\":true,\"credits_used\":42,\"percent_remaining\":100}}}").?;
    try t.expectEqual(@as(usize, 0), unlimited.len);
    try t.expectEqual(@as(?f64, 42), unlimited.credits_used);
    try t.expect(windowsFromCopilot("{\"monthly_quotas\":{\"chat\":500}}") == null);
}

test "Copilot pooled credits stay visible without inventing a percentage" {
    // Shape of a real HTTP 200 quota response, with a synthetic consumption.
    const body =
        \\{"token_based_billing":true,"quota_reset_date":"2026-10-01","quota_reset_date_utc":"2026-10-01T00:00:00.000Z","quota_snapshots":{
        \\"chat":{"percent_remaining":100,"unlimited":true,"entitlement":0,"credits_used":0,"quota_reset_at":0},
        \\"completions":{"percent_remaining":100,"unlimited":true,"entitlement":0,"credits_used":0,"quota_reset_at":0},
        \\"premium_interactions":{"percent_remaining":100,"unlimited":true,"entitlement":0,"credits_used":42.5,"quota_reset_at":0}}}
    ;
    const windows = windowsFromCopilot(body).?;
    try t.expectEqual(@as(usize, 0), windows.len);
    try t.expectEqual(@as(?f64, 42.5), windows.credits_used);
    try t.expectEqual(parseIso("2026-10-01").?, windows.credits_resets_at);
    var state: State = .{ .now_s = 1000 };
    state.set(.copilot, windows);
    try t.expect(state.visible(.copilot));
    try t.expectEqual(@as(usize, 1), state.len());
    try t.expectEqual(@as(?u8, null), state.used(.copilot));
    try t.expectEqual(@as(?f64, 42.5), state.credits(.copilot));
    var out: [1024]u8 = undefined;
    const text = context(&state, 1000, &out);
    try t.expect(std.mem.indexOf(u8, text, "Copilot: 42.5 credits used (no percentage limit reported)") != null);
    try t.expect(std.mem.indexOf(u8, text, "0% used") == null);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"unlimited\":true,\"credits_used\":-1}}}") == null);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"unlimited\":true,\"credits_used\":1e999}}}") == null);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"unlimited\":true}}}") == null);
}

test "absolute credits expire independently from percentage windows and preserve explicit zero" {
    const mixed = windowsFromCopilot(
        \\{"quota_snapshots":{"premium_interactions":{"unlimited":true,"credits_used":0,"quota_reset_at":1050},"chat":{"entitlement":100,"percent_remaining":80,"quota_reset_at":5000}}}
    ).?;
    var state: State = .{ .now_s = 1000 };
    state.set(.copilot, mixed);
    try t.expectEqual(@as(?f64, 0), state.credits(.copilot));
    try t.expectEqual(@as(?u8, 20), state.used(.copilot));
    state.now_s = 1050;
    try t.expect(state.visible(.copilot));
    try t.expectEqual(@as(?f64, null), state.credits(.copilot));
    try t.expectEqual(@as(?u8, 20), state.used(.copilot));
    state.set(.copilot, .{ .credits_used = 0 });
    try t.expect(state.visible(.copilot));
    try t.expectEqual(@as(?f64, 0), state.credits(.copilot));
    try t.expectEqual(@as(?u8, null), state.used(.copilot));
    state.now_s += observation_ttl_s + 1;
    try t.expect(!state.visible(.copilot));
    try t.expect(state.snapshot(.copilot) == null);
    state.set(.copilot, .{ .credits_used = 10, .credits_resets_at = state.now_s });
    try t.expect(!state.visible(.copilot));
    state.set(.copilot, .{ .credits_used = std.math.nan(f64) });
    try t.expect(!state.visible(.copilot));
}

test "absolute credit snapshots round-trip through local storage" {
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var home_buf: [256]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, ".zig-cache/tmp/{s}", .{test_dir.sub_path[0..]});
    const original: Windows = .{ .observed_at = 1000, .credits_used = 42.125, .credits_resets_at = 5000 };
    var buf: [512]u8 = undefined;
    const formatted = formatWindows(original, &buf).?;
    const parsed = parseWindows(formatted).?;
    try t.expectEqual(@as(usize, 0), parsed.len);
    try t.expectEqual(original.credits_used, parsed.credits_used);
    try t.expectEqual(original.credits_resets_at, parsed.credits_resets_at);
    writeWindows(home, .copilot, original);
    var state: State = .{};
    readFiles(&state, home, 1100 * 1000);
    try t.expect(state.visible(.copilot));
    try t.expectEqual(original.credits_used, state.credits(.copilot));
    var combined = Windows.one(25, 4000, month_minutes);
    combined.observed_at = 1000;
    combined.credits_used = 42.5;
    combined.credits_resets_at = 5000;
    const both = parseWindows(formatWindows(combined, &buf).?).?;
    try t.expectEqual(@as(usize, 1), both.len);
    try t.expectEqual(@as(f64, 25), both.items[0].used);
    try t.expectEqual(combined.credits_used, both.credits_used);
    state.set(.grok, parseWindows("{\"observed_at\":1000,\"credits_used\":-1}"));
    try t.expect(!state.visible(.grok));
}

test "Grok's auth file yields only a fresh consumer token" {
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/.grok", .{test_dir.sub_path[0..]});
    var auth_buf: [300]u8 = undefined;
    const auth = try std.fmt.bufPrint(&auth_buf, "{s}/auth.json", .{dir});
    try t.expect(plat.writeFile(auth,
        \\{"https://enterprise.example.com::aaa":{"key":"ent","expires_at":"2999-01-01T00:00:00Z","user_id":"e1"},
        \\"https://auth.x.ai::bbb":{"key":"expired","expires_at":"2000-01-01T00:00:00Z","user_id":"u_old"},
        \\"https://auth.x.ai::ccc":{"key":"ya29.fresh","expires_at":"2999-01-01T00:00:00Z","user_id":"u_42"}}
    ));
    var tok: [64]u8 = undefined;
    var uid: [64]u8 = undefined;
    const cred = grokCred(dir, &tok, &uid, 1750000000).?;
    try t.expectEqualStrings("ya29.fresh", cred.token);
    try t.expectEqualStrings("u_42", cred.user_id.?);
    // Everything expired: nothing.
    try t.expect(plat.writeFile(auth,
        \\{"https://auth.x.ai::ccc":{"key":"old","expires_at":"2000-01-01T00:00:00Z"}}
    ));
    try t.expect(grokCred(dir, &tok, &uid, 1750000000) == null);
}

test "Gemini legacy token is only lent while unexpired" {
    var test_dir = t.tmpDir(.{});
    defer test_dir.cleanup();
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, ".zig-cache/tmp/{s}/.gemini", .{test_dir.sub_path[0..]});
    var creds_buf: [300]u8 = undefined;
    const creds = try std.fmt.bufPrint(&creds_buf, "{s}/oauth_creds.json", .{dir});
    try t.expect(plat.writeFile(creds, "{\"access_token\":\"ya29.ok\",\"expiry_date\":2000000}"));
    var out: [128]u8 = undefined;
    try t.expect(googleToken(dir, &out, 3000) == null);
    try t.expectEqualStrings("ya29.ok", googleToken(dir, &out, 1000).?);
    // No expiry field: freshness cannot be verified, so do not use it.
    try t.expect(plat.writeFile(creds, "{\"access_token\":\"ya29.noexpiry\"}"));
    try t.expect(googleToken(dir, &out, 9999999999) == null);
}

test "Antigravity grouped buckets preserve each pool and period" {
    const body =
        \\{"groups":[{"buckets":[
        \\{"bucketId":"gemini-5h","remainingFraction":0.9,"resetTime":"2026-09-17T20:00:00Z"},
        \\{"bucketId":"gemini-weekly","remainingFraction":0.4,"resetTime":"2026-09-21T00:00:00Z"}]},
        \\{"buckets":[
        \\{"bucketId":"3p-5h","remainingFraction":0.1,"resetTime":"2026-09-17T19:00:00Z"},
        \\{"bucketId":"3p-weekly","remainingFraction":0.7,"resetTime":"2026-09-22T00:00:00Z"}]}]}
    ;
    const windows = windowsFromAntigravityQuota(body).?;
    try t.expectEqual(@as(usize, 4), windows.len);
    // The tighter 5h (3p: 90% used) and tighter weekly (gemini: 60%) win.
    try t.expectEqual(@as(?u8, 90), tightest(windows.slice(), 0));
    try t.expect(windowsFromAntigravityQuota("{}") == null);
    try t.expect(windowsFromAntigravityQuota("{\"buckets\":[{\"bucketId\":\"x\",\"remainingFraction\":0.5}]}").?.items[0].used == 50);
}

test "Gemini's project lookup and per-model buckets" {
    var project: [64]u8 = undefined;
    try t.expectEqualStrings("proj-1", projectFromCodeAssist("{\"cloudaicompanionProject\":\"proj-1\"}", &project).?);
    try t.expectEqualStrings("proj-2", projectFromCodeAssist("{\"cloudaicompanionProject\":{\"id\":\"proj-2\"}}", &project).?);
    try t.expect(projectFromCodeAssist("{}", &project) == null);
    const body =
        \\{"buckets":[{"modelId":"gemini-3-flash","remainingFraction":1.0,"resetTime":"2026-09-18T00:00:00Z"},
        \\{"modelId":"gemini-3-pro","remainingFraction":0.2,"resetTime":"2026-09-18T01:00:00Z"},
        \\{"modelId":"gemini-2.5","remainingFraction":0.5}]}
    ;
    const windows = windowsFromGeminiQuota(body).?;
    try t.expectEqual(@as(usize, 3), windows.len);
    try t.expectEqual(@as(?u8, 80), tightest(windows.slice(), 0));
    try t.expect(windowsFromGeminiQuota("{\"buckets\":[]}") == null);
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

test "missing or invalid endpoint usage is hidden while explicit zero remains visible" {
    try t.expect(windowsFromCursor("{\"individualUsage\":{\"plan\":{\"limit\":2000}}}") == null);
    try t.expect(windowsFromCursor("{\"individualUsage\":{\"plan\":{\"used\":-1,\"limit\":2000}}}") == null);
    try t.expect(windowsFromCursor("{\"individualUsage\":{\"plan\":{\"used\":0,\"limit\":0}}}") == null);
    try t.expect(windowsFromCursor("{\"individualUsage\":{\"plan\":{\"totalPercentUsed\":-1}}}") == null);
    const zero = windowsFromCursor("{\"individualUsage\":{\"plan\":{\"used\":0,\"limit\":2000}}}").?;
    try t.expectEqual(@as(?u8, 0), tightest(zero.slice(), 0));
    const overage = windowsFromCursor("{\"individualUsage\":{\"plan\":{\"totalPercentUsed\":120}}}").?;
    try t.expectEqual(@as(?u8, 100), tightest(overage.slice(), 0));
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{}}}") == null);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"percent_remaining\":101}}}") == null);
    try t.expect(windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"percent_remaining\":-1}}}") == null);
    const unused = windowsFromCopilot("{\"quota_snapshots\":{\"premium_interactions\":{\"percent_remaining\":100}}}").?;
    try t.expectEqual(@as(?u8, 0), tightest(unused.slice(), 0));
    try t.expect(windowsFromGrokCredits("{\"creditUsagePercent\":-1}") == null);
    try t.expectEqual(@as(f64, 0), windowsFromGrokCredits("{\"creditUsagePercent\":0}").?.items[0].used);
    var scratch: [2048]u8 = undefined;
    for ([_][]const u8{
        "<option name=\"quotaInfo\" value=\"{&quot;current&quot;:&quot;-1&quot;,&quot;maximum&quot;:100}\" />",
        "<option name=\"quotaInfo\" value=\"{&quot;current&quot;:&quot;NaN&quot;,&quot;maximum&quot;:100}\" />",
        "<option name=\"quotaInfo\" value=\"{&quot;current&quot;:1,&quot;maximum&quot;:&quot;Infinity&quot;}\" />",
    }) |xml| try t.expect(windowsFromJetBrainsXml(xml, &scratch) == null);
}

test "fresh local reports survive unavailable endpoints and lose to newer observations" {
    var state: State = .{ .now_s = 1000 };
    var report = Windows.one(80, 5000, 300);
    report.observed_at = 990;
    state.local[@intFromEnum(Agent.cursor)] = report;
    state.set(.cursor, null);
    try t.expectEqual(@as(?u8, 80), state.used(.cursor));
    var old = Windows.one(10, 5000, 300);
    old.observed_at = 900;
    state.set(.cursor, old);
    try t.expectEqual(@as(?u8, 80), state.used(.cursor));
    var newer = Windows.one(72, 5000, 300);
    newer.observed_at = 1000;
    state.set(.cursor, newer);
    try t.expectEqual(@as(?u8, 72), state.used(.cursor));
    try t.expect(newestFresh(report, newer, 6000) == null);
    try t.expect(fresh(Windows.one(95, 1, 300), 1000) == null);
}

test "usage rows enforce observation expiry even between file reads" {
    var state: State = .{ .now_s = 1000 };
    state.set(.cursor, Windows.one(42, 10000, month_minutes));
    state.now_s = 4600;
    try t.expectEqual(@as(?u8, 42), state.used(.cursor));
    state.now_s = 4601;
    try t.expectEqual(@as(?u8, null), state.used(.cursor));
    try t.expectEqual(@as(usize, 0), state.len());
    var invalid_time = Windows.one(20, 10000, month_minutes);
    invalid_time.observed_at = -1;
    state.set(.cursor, invalid_time);
    try t.expectEqual(@as(?u8, null), state.used(.cursor));
}

test "Codex reports do not hide newer resumed rollouts and respect CODEX_HOME" {
    const mcp = @import("agent_mcp.zig");
    const saved = mcp.env_codex_home;
    defer mcp.env_codex_home = saved;
    const home = ".zig-cache/petdex-usage-resumed";
    _ = plat.deleteTree(home);
    defer _ = plat.deleteTree(home);
    mcp.env_codex_home = home ++ "/custom-codex";
    const old = "{\"timestamp\":\"2026-09-17T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":20,\"resets_at\":2000000000}}}}\n";
    const resumed = "{\"timestamp\":\"2026-09-17T01:10:00Z\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"primary\":{\"used_percent\":72,\"resets_at\":2000000000}}}}\n";
    try t.expect(plat.writeFile(home ++ "/custom-codex/sessions/rollout-2026-09-17.jsonl", old));
    try t.expect(plat.writeFile(home ++ "/custom-codex/sessions/rollout-2026-09-16.jsonl", resumed));
    // A clock-skewed rollout must not hide fresh usage from another session.
    try t.expect(plat.writeFile(home ++ "/custom-codex/sessions/rollout-future.jsonl",
        \\{"timestamp":"2999-01-01T00:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":99,"resets_at":9999999999}}}}
    ));
    try t.expect(plat.writeFile(home ++ "/.petdex/runtime/usage/codex.json", "{\"observed_at\":100,\"windows\":[[95,1,300]]}"));
    var state: State = .{};
    readFiles(&state, home, parseIso("2026-09-17T01:11:00Z").? * 1000);
    try t.expectEqual(@as(?u8, 72), state.used(.codex));
}

test "Gemini encrypted credentials match an independent Node crypto fixture" {
    const encrypted = "070707070707070707070707:68665ebf9b37da905642ee4a27a2e57f:e50c9d19ab531e45c6dd4fda89ca8aa59bd56f0c0db010e27f9daa66d22762895cc370a505d1ad3b1ee1122cc8282c31f78841f31cb21b6073e6d12eae15ccdc7cbbcf498b2df578c385371c6e2b35be26575715f5c58c146b1a64fae92b800ebf96ed7dcf5133965bb72b284d";
    var out: [512]u8 = undefined;
    const plain = decryptGeminiCredentials(encrypted, "fixture-host-fixture-user-gemini-cli", &out).?;
    try t.expect(std.mem.indexOf(u8, plain, "fixture-token") != null);
    try t.expect(decryptGeminiCredentials(encrypted, "wrong-user", &out) == null);
    try t.expect(decryptGeminiCredentials("invalid", "fixture", &out) == null);
    try t.expectEqualStrings("fresh", googleTokenFrom("{\"token\":{\"accessToken\":\"fresh\",\"expiresAt\":2000000}}", &out, 1000).?);
    try t.expect(googleTokenFrom("{\"token\":{\"accessToken\":\"old\",\"expiresAt\":2000000}}", &out, 3000) == null);
    try t.expectEqualStrings("agy", googleTokenFrom("{\"access_token\":\"agy\",\"expiry\":\"2026-09-18T00:00:00Z\"}", &out, 1000).?);
    try t.expect(googleTokenFrom("{\"access_token\":\"expired-offset\",\"expiry\":\"2026-09-18T09:00:00+09:00\"}", &out, parseIso("2026-09-18T00:01:00Z").?) == null);
}

test "Antigravity go-keyring envelope is decoded before JSON parsing" {
    var out: [64]u8 = undefined;
    try t.expectEqualStrings("{}", decodeGoKeyring("go-keyring-base64:e30=", &out).?);
    try t.expectEqualStrings("{}", decodeGoKeyring("go-keyring-encoded:7b7d", &out).?);
    try t.expect(decodeGoKeyring("go-keyring-base64:!", &out) == null);
}
