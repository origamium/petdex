//! Timer persistence and editor state; the clock itself has no SDK dependency.
const std = @import("std");
const canvas = @import("native_sdk").canvas;
const app = @import("main.zig");
const plat = @import("plat.zig");
const timer = @import("timer.zig");
const chat_shell = @import("chat_shell.zig");

pub const State = struct {
    clock: timer.State = .{},
    now_ms: i64 = 0,
    options_open: bool = false,
    scroll: f32 = 0,
    work: canvas.TextBuffer(3) = .{},
    short: canvas.TextBuffer(3) = .{},
    long: canvas.TextBuffer(3) = .{},
    minutes: canvas.TextBuffer(2) = .{},
    seconds: canvas.TextBuffer(2) = .{},
    invalid: bool = false,
    save_failed: bool = false,
    // A completed generation waits here if the user started drafting.
    generated: [2048]u8 = undefined,
    generated_len: usize = 0,
    generated_id: u64 = 0,

    pub fn isVisible(self: *const State, chat_open: bool) bool {
        return chat_open and self.clock.config.visible;
    }
};

pub fn boot(model: *app.Model) void {
    const st = &model.timer;
    if (app.env_home) |home| {
        var path_buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&path_buf, "{s}/.petdex/timer.json", .{home})) |path| {
            var buf: [8192]u8 = undefined;
            if (plat.readFile(path, &buf)) |bytes| {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                st.clock = timer.parse(arena.allocator(), bytes);
            }
        } else |_| {}
    }
    syncFields(st);
}

pub fn save(st: *State) void {
    st.save_failed = true;
    const home = app.env_home orelse return;
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.petdex/timer.json", .{home}) catch return;
    const bytes = std.json.Stringify.valueAlloc(std.heap.page_allocator, st.clock, .{ .whitespace = .indent_2 }) catch return;
    defer std.heap.page_allocator.free(bytes);
    st.save_failed = !plat.writeFile(path, bytes);
}

pub fn tick(model: *app.Model, fx: *app.Effects) void {
    const st = &model.timer;
    st.now_ms = fx.wallMs();
    if (st.clock.tick(st.now_ms, model.focus_mode)) save(st);
    if (model.focus_mode or !st.clock.config.speak) {
        st.generated_len = 0;
        chat_shell.cancelTimerSpeech(model, fx);
    }
}

pub fn update(model: *app.Model, msg: app.Msg, fx: *app.Effects) void {
    const st = &model.timer;
    tick(model, fx);
    switch (msg) {
        .timer_visibility => {
            // A closed chat hides the card too: Show Timer must open it,
            // even when the saved visibility preference is already on.
            st.clock.config.visible = !st.isVisible(model.chat.open);
            if (st.clock.config.visible) chat_shell.update(model, .show_chat, fx);
            chat_shell.follow(model, fx);
        },
        .timer_toggle => {
            if (st.invalid) return;
            if (st.clock.status == .running) st.clock.pause(st.now_ms) else st.clock.start(st.now_ms);
        },
        .timer_reset => {
            chat_shell.cancelTimerSpeech(model, fx);
            st.clock.reset();
            st.generated_len = 0;
            syncFields(st);
        },
        .timer_mode => |mode| {
            if (st.clock.locked()) return;
            chat_shell.cancelTimerSpeech(model, fx);
            st.clock.setMode(mode);
            st.generated_len = 0;
            syncFields(st);
        },
        .timer_options => {
            st.options_open = !st.options_open;
            st.scroll = 0;
            return;
        },
        .timer_scrolled => |offset| {
            st.scroll = offset.offset;
            return;
        },
        .timer_auto => st.clock.config.auto_start = !st.clock.config.auto_start,
        .timer_speak => {
            st.clock.config.speak = !st.clock.config.speak;
            if (!st.clock.config.speak) {
                st.clock.pending = null;
                st.generated_len = 0;
                chat_shell.cancelTimerSpeech(model, fx);
            }
        },
        .timer_work, .timer_short, .timer_long, .timer_minutes, .timer_seconds => {
            if (st.clock.locked()) return;
            switch (msg) {
                .timer_work => |edit| st.work.apply(edit),
                .timer_short => |edit| st.short.apply(edit),
                .timer_long => |edit| st.long.apply(edit),
                .timer_minutes => |edit| st.minutes.apply(edit),
                .timer_seconds => |edit| st.seconds.apply(edit),
                else => unreachable,
            }
            if (!applyFields(st)) return;
        },
        else => return,
    }
    save(st);
}

fn syncFields(st: *State) void {
    const c = st.clock.config;
    var buf: [8]u8 = undefined;
    st.work.set(std.fmt.bufPrint(&buf, "{d}", .{c.work_minutes}) catch "25");
    st.short.set(std.fmt.bufPrint(&buf, "{d}", .{c.short_minutes}) catch "5");
    st.long.set(std.fmt.bufPrint(&buf, "{d}", .{c.long_minutes}) catch "15");
    st.minutes.set(std.fmt.bufPrint(&buf, "{d}", .{c.timer_seconds / 60}) catch "5");
    st.seconds.set(std.fmt.bufPrint(&buf, "{d:0>2}", .{c.timer_seconds % 60}) catch "00");
    st.invalid = false;
}

fn number(bytes: []const u8, min: u16, max: u16) ?u16 {
    if (bytes.len == 0) return null;
    for (bytes) |c| if (c < '0' or c > '9') return null;
    const n = std.fmt.parseInt(u16, bytes, 10) catch return null;
    return if (n >= min and n <= max) n else null;
}

fn applyFields(st: *State) bool {
    st.invalid = true;
    var c = st.clock.config;
    if (st.clock.mode == .pomodoro) {
        c.work_minutes = number(st.work.text(), 1, 180) orelse return false;
        c.short_minutes = number(st.short.text(), 1, 180) orelse return false;
        c.long_minutes = number(st.long.text(), 1, 180) orelse return false;
    } else {
        const minutes = number(st.minutes.text(), 0, 99) orelse return false;
        const seconds = number(st.seconds.text(), 0, 59) orelse return false;
        if (minutes == 0 and seconds == 0) return false;
        c.timer_seconds = minutes * 60 + seconds;
    }
    st.clock.config = c;
    st.invalid = false;
    return true;
}

test "duration editor rejects invalid input without changing saved duration" {
    const t = std.testing;
    var s: State = .{};
    syncFields(&s);
    s.work.set("0");
    try t.expect(!applyFields(&s));
    try t.expectEqual(@as(u16, 25), s.clock.config.work_minutes);
    s.work.set("180");
    try t.expect(applyFields(&s));
    s.clock.setMode(.timer);
    s.minutes.set("99");
    s.seconds.set("59");
    try t.expect(applyFields(&s));
    try t.expectEqual(@as(u16, 5999), s.clock.config.timer_seconds);
    s.seconds.set("60");
    try t.expect(!applyFields(&s));
    s.minutes.set("0");
    s.seconds.set("0");
    try t.expect(!applyFields(&s));
}
