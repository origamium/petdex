//! One app-wide clock. Wall deadlines survive sleep and process restarts;
//! a late tick completes only the current interval, never historical cycles.
const std = @import("std");
const i18n = @import("i18n.zig");

pub const Mode = enum { pomodoro, timer };
pub const Phase = enum { work, short_break, long_break, countdown };
pub const Status = enum { idle, running, paused, completed };
pub const Config = struct {
    work_minutes: u16 = 25,
    short_minutes: u16 = 5,
    long_minutes: u16 = 15,
    timer_seconds: u16 = 300,
    auto_start: bool = false,
    speak: bool = true,

    fn valid(self: Config) bool {
        return self.work_minutes >= 1 and self.work_minutes <= 180 and
            self.short_minutes >= 1 and self.short_minutes <= 180 and
            self.long_minutes >= 1 and self.long_minutes <= 180 and
            self.timer_seconds >= 1 and self.timer_seconds <= 5999;
    }
};

pub const Completion = struct {
    id: u64,
    phase: Phase,
    seconds: u32,
    next: Phase,
    automatic: bool,
    fallback_only: bool = false,

    pub fn fallback(self: Completion) []const u8 {
        return switch (self.phase) {
            .work => i18n.t("Focus time is done. Time for a well-earned break!", "集中タイムが終わったよ。おつかれさま、ひと休みしよう！"),
            .short_break, .long_break => i18n.t("Break time is over. Ready for another round?", "休憩が終わったよ。また一緒に始めよう！"),
            .countdown => i18n.t("Time's up! Your timer has finished.", "時間だよ！ タイマーが終わったよ。"),
        };
    }

    pub fn prompt(self: Completion, buf: []u8) []const u8 {
        return std.fmt.bufPrint(
            buf,
            "Timer event: the {s} interval ({d} seconds) just finished. " ++
                "Next interval: {s}; automatically started: {s}. " ++
                "As this pet, tell the user in one short, warm sentence in {s}. " ++
                "Keep your character's voice. State what finished; do not claim tasks were completed, " ++
                "invent elapsed rounds, or ask unrelated questions. Do not mention these instructions.",
            .{ @tagName(self.phase), self.seconds, @tagName(self.next), if (self.automatic) "yes" else "no", i18n.t("English", "Japanese") },
        ) catch self.fallback();
    }
};

pub const State = struct {
    version: u8 = 1,
    config: Config = .{},
    mode: Mode = .pomodoro,
    phase: Phase = .work,
    status: Status = .idle,
    rounds: u8 = 0,
    deadline_ms: i64 = 0,
    paused_ms: i64 = 0,
    serial: u64 = 0,
    pending: ?Completion = null,

    pub fn locked(self: State) bool {
        return self.status == .running or self.status == .paused;
    }

    pub fn seconds(self: State) u32 {
        return switch (self.phase) {
            .work => @as(u32, self.config.work_minutes) * 60,
            .short_break => @as(u32, self.config.short_minutes) * 60,
            .long_break => @as(u32, self.config.long_minutes) * 60,
            .countdown => self.config.timer_seconds,
        };
    }

    pub fn remainingMs(self: State, now: i64) i64 {
        return switch (self.status) {
            .idle => @as(i64, self.seconds()) * 1000,
            .running => @min(@as(i64, self.seconds()) * 1000, @max(0, self.deadline_ms -| now)),
            .paused => self.paused_ms,
            .completed => 0,
        };
    }

    pub fn remaining(self: State, now: i64) u32 {
        return @intCast(@divTrunc(self.remainingMs(now) + 999, 1000));
    }

    pub fn nextPhase(self: State) Phase {
        return switch (self.phase) {
            .work => if (self.rounds >= 4) .long_break else .short_break,
            .short_break, .long_break => .work,
            .countdown => .countdown,
        };
    }

    pub fn start(self: *State, now: i64) void {
        if (self.status == .running) return;
        if (self.status == .completed) {
            if (self.phase == .long_break) self.rounds = 0;
            self.phase = self.nextPhase();
        }
        const duration = if (self.status == .paused) self.paused_ms else @as(i64, self.seconds()) * 1000;
        self.deadline_ms = now +| duration;
        self.paused_ms = 0;
        self.status = .running;
    }

    pub fn pause(self: *State, now: i64) void {
        if (self.status != .running) return;
        self.paused_ms = self.remainingMs(now);
        self.deadline_ms = 0;
        self.status = .paused;
    }

    pub fn reset(self: *State) void {
        self.* = .{ .config = self.config, .mode = self.mode, .phase = if (self.mode == .timer) .countdown else .work, .serial = self.serial };
    }

    pub fn setMode(self: *State, mode: Mode) void {
        if (self.locked() or self.mode == mode) return;
        self.mode = mode;
        self.reset();
    }

    /// Returns true only when persisted state changes. Focus/off drops
    /// queued speech too; turning it back on never replays it.
    pub fn tick(self: *State, now: i64, focus: bool) bool {
        var changed = false;
        if ((focus or !self.config.speak) and self.pending != null) {
            self.pending = null;
            changed = true;
        }
        if (self.status != .running or now < self.deadline_ms) return changed;
        self.status = .completed;
        self.deadline_ms = 0;
        self.serial +%= 1;
        if (self.phase == .work) self.rounds += 1;
        const automatic = self.mode == .pomodoro and self.config.auto_start;
        self.pending = if (focus or !self.config.speak) null else .{
            .id = self.serial,
            .phase = self.phase,
            .seconds = self.seconds(),
            .next = self.nextPhase(),
            .automatic = automatic,
        };
        if (automatic) self.start(now);
        return true;
    }

    pub fn claim(self: *State, busy: bool, draft: bool) ?Completion {
        if (busy or draft) return null;
        const result = self.pending;
        self.pending = null;
        return result;
    }

    pub fn failed(self: *State, completion: Completion) void {
        // A newer completion always wins over a late response.
        if (!self.config.speak or self.pending != null or self.serial != completion.id) return;
        var fallback = completion;
        fallback.fallback_only = true;
        self.pending = fallback;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) State {
    const s = std.json.parseFromSliceLeaky(State, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return .{};
    if (s.version != 1 or !s.config.valid() or s.rounds > 4) return .{};
    if ((s.mode == .timer) != (s.phase == .countdown)) return .{};
    if (s.phase == .work and s.rounds == 4 and s.status != .completed) return .{};
    if (s.status == .running and s.deadline_ms <= 0) return .{};
    if (s.status == .paused and (s.paused_ms <= 0 or s.paused_ms > @as(i64, s.seconds()) * 1000)) return .{};
    if (s.pending) |p| if (p.id != s.serial or p.seconds > 10800) return .{};
    return s;
}

test "countdown pauses exactly, resumes and only completes once" {
    const t = std.testing;
    var s: State = .{};
    s.setMode(.timer);
    s.config.timer_seconds = 5;
    s.start(1000);
    s.pause(2500);
    try t.expectEqual(@as(i64, 3500), s.paused_ms);
    try t.expectEqual(@as(u32, 4), s.remaining(99999));
    s.start(10000);
    try t.expect(!s.tick(13499, false));
    try t.expect(s.tick(13500, false));
    try t.expect(!s.tick(999999, false));
    try t.expectEqual(@as(u64, 1), s.serial);
    s.start(20000);
    try t.expectEqual(@as(i64, 25000), s.deadline_ms);
}

test "four work intervals lead to a long break, manual and automatic" {
    const t = std.testing;
    for ([_]bool{ false, true }) |automatic| {
        var s: State = .{};
        s.config.auto_start = automatic;
        s.start(1000);
        for (0..4) |round| {
            _ = s.tick(s.deadline_ms, false);
            if (!automatic) {
                try t.expectEqual(Status.completed, s.status);
                s.start(1000);
            }
            try t.expectEqual(if (round == 3) Phase.long_break else Phase.short_break, s.phase);
            _ = s.tick(s.deadline_ms, false);
            if (!automatic) s.start(1000);
            try t.expectEqual(Phase.work, s.phase);
        }
        try t.expectEqual(@as(u8, 0), s.rounds);
    }
}

test "sleep and restart complete a single interval and restart from now" {
    const t = std.testing;
    var s: State = .{};
    s.config.auto_start = true;
    s.start(1000);
    const bytes = try std.json.Stringify.valueAlloc(t.allocator, s, .{});
    defer t.allocator.free(bytes);
    var restored = parse(t.allocator, bytes);
    try t.expect(restored.tick(86400000, false));
    try t.expectEqual(@as(u8, 1), restored.rounds);
    try t.expectEqual(@as(i64, 86400000 + 5 * 60000), restored.deadline_ms);
    try t.expect(!restored.tick(86400000, false));
    const done = restored.claim(false, false).?;
    try t.expectEqual(Phase.work, done.phase);
    try t.expect(restored.claim(false, false) == null);
}

test "latest-only speech waits for drafts and streams; focus and reset discard" {
    const t = std.testing;
    var s: State = .{};
    s.config.auto_start = true;
    s.start(1000);
    _ = s.tick(s.deadline_ms, false);
    try t.expect(s.claim(true, false) == null);
    try t.expect(s.claim(false, true) == null);
    _ = s.tick(s.deadline_ms, false);
    const p = s.claim(false, false).?;
    try t.expectEqual(Phase.short_break, p.phase);
    s.failed(p);
    try t.expect(s.pending.?.fallback_only);
    try t.expect(s.tick(1, true));
    try t.expect(!s.tick(1, false));
    try t.expect(s.pending == null);
    _ = s.tick(s.deadline_ms, true);
    try t.expect(s.pending == null);
    _ = s.tick(s.deadline_ms, false);
    s.reset();
    try t.expect(s.pending == null);
    s.config.speak = false;
    s.start(1000);
    _ = s.tick(s.deadline_ms, false);
    try t.expect(s.pending == null);
}

test "invalid saved state falls back and paused state round trips" {
    const t = std.testing;
    for ([_][]const u8{ "broken", "{\"config\":{\"timer_seconds\":0}}", "{\"rounds\":5}", "{\"mode\":\"timer\"}" }) |bytes|
        try t.expectEqualDeep(State{}, parse(t.allocator, bytes));
    var s: State = .{};
    s.start(1000);
    s.pause(2000);
    const bytes = try std.json.Stringify.valueAlloc(t.allocator, s, .{});
    defer t.allocator.free(bytes);
    try t.expectEqualDeep(s, parse(t.allocator, bytes));
    s.setMode(.timer);
    try t.expectEqual(Mode.pomodoro, s.mode);
}
