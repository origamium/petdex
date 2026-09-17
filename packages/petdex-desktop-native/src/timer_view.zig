//! Compact timer and its inline controls, below the chat composer.
const app = @import("main.zig");
const timer = @import("timer.zig");
const i18n = @import("i18n.zig");
const Ui = app.AppUi;
const base_h: f32 = 158;

pub fn optionsHeight(model: *const app.Model) f32 {
    const screen_h: f32 = if (model.pet_screen) |s| @floatCast(s.h) else 720;
    const desired: f32 = if (model.timer.clock.mode == .timer) 178 else 214;
    return @min(desired, @max(92, screen_h - 430));
}

pub fn height(model: *const app.Model) f32 {
    return base_h + (if (model.timer.options_open) optionsHeight(model) + 10 else @as(f32, 0));
}

pub fn view(ui: *Ui, model: *const app.Model) Ui.Node {
    const st = &model.timer;
    const c = st.clock;
    const remaining = c.remaining(st.now_ms);
    const mode = ui.row(.{ .gap = 4, .cross = .center, .height = 28 }, .{
        ui.button(.{ .size = .sm, .height = 28, .disabled = c.locked(), .variant = if (c.mode == .pomodoro) .primary else .ghost, .on_press = .{ .timer_mode = .pomodoro } }, i18n.t("Pomodoro", "ポモドーロ")),
        ui.button(.{ .size = .sm, .height = 28, .disabled = c.locked(), .variant = if (c.mode == .timer) .primary else .ghost, .on_press = .{ .timer_mode = .timer } }, i18n.t("Timer", "タイマー")),
        ui.el(.stack, .{ .grow = 1 }, .{}),
        ui.button(.{ .icon = "settings", .size = .icon, .width = 28, .height = 28, .variant = if (st.options_open) .secondary else .ghost, .on_press = .timer_options, .semantics = .{ .label = i18n.t("Timer settings", "タイマーの設定") } }, ""),
    });
    const reading = ui.row(.{ .height = 44, .cross = .center, .gap = 12 }, .{
        ui.text(.{ .size = .display, .semantics = .{ .label = i18n.fmt(ui, "Time remaining {d:0>2}:{d:0>2}", "残り時間 {d:0>2}:{d:0>2}", .{ remaining / 60, remaining % 60 }) } }, ui.fmt("{d:0>2}:{d:0>2}", .{ remaining / 60, remaining % 60 })),
        ui.column(.{ .grow = 1, .gap = 2 }, .{
            ui.text(.{ .size = .sm }, phaseLabel(c.phase)),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, if (c.mode == .pomodoro) i18n.fmt(ui, "Round {d} of 4", "{d} / 4 セット", .{@min(@as(u8, 4), c.rounds + @as(u8, if (c.phase == .work and c.status != .completed) 1 else 0))}) else i18n.t("Countdown", "カウントダウン")),
        }),
    });
    const actions = ui.row(.{ .gap = 6, .height = 30 }, .{
        ui.button(.{ .grow = 1, .size = .sm, .height = 30, .variant = .primary, .icon = if (c.status == .running) "pause" else "play", .disabled = st.invalid, .on_press = .timer_toggle }, startLabel(c)),
        ui.button(.{ .size = .sm, .height = 30, .variant = .secondary, .icon = "refresh-cw", .on_press = .timer_reset }, i18n.t("Reset", "リセット")),
    });
    const feedback = ui.text(.{ .size = .sm, .height = 16, .style_tokens = .{ .foreground = if (st.invalid or st.save_failed) .destructive else .text_muted } }, statusLabel(model));
    const base = ui.column(.{ .gap = 6 }, .{ mode, reading, actions, feedback });
    const content = if (st.options_open) ui.column(.{ .gap = 10 }, .{
        base,
        ui.scroll(.{ .height = optionsHeight(model), .value = st.scroll, .on_scroll = Ui.scrollMsg(.timer_scrolled) }, .{options(ui, model)}),
    }) else base;
    var card = ui.el(.panel, .{ .width = 300, .height = height(model), .padding = 11 }, .{content});
    app.styleSpeechCard(&card, model.dark);
    return card;
}

fn phaseLabel(phase: timer.Phase) []const u8 {
    return switch (phase) {
        .work => i18n.t("Focus", "集中"),
        .short_break => i18n.t("Short break", "短い休憩"),
        .long_break => i18n.t("Long break", "長い休憩"),
        .countdown => i18n.t("Timer", "タイマー"),
    };
}

fn startLabel(c: timer.State) []const u8 {
    return switch (c.status) {
        .running => i18n.t("Pause", "一時停止"),
        .paused => i18n.t("Resume", "再開"),
        .idle => i18n.t("Start", "開始"),
        .completed => switch (c.nextPhase()) {
            .work => i18n.t("Start focus", "集中を開始"),
            .short_break, .long_break => i18n.t("Start break", "休憩を開始"),
            .countdown => i18n.t("Start again", "もう一度開始"),
        },
    };
}

fn statusLabel(model: *const app.Model) []const u8 {
    const st = &model.timer;
    if (st.invalid) return i18n.t("Check the duration in timer settings", "設定の時間を確認してください");
    if (st.save_failed) return i18n.t("Timer could not be saved", "タイマーを保存できませんでした");
    if (st.clock.status == .completed) return i18n.t("Finished · ready when you are", "終了しました · 次も自分のペースで");
    if (st.clock.status == .paused) return i18n.t("Paused · reset to edit duration", "一時停止中 · 変更するにはリセット");
    if (model.focus_mode) return i18n.t("Focus mode · pet announcements off", "集中モード中 · ペットのお知らせは休止");
    if (st.clock.status == .running) return i18n.t("Keeps running while hidden", "非表示中も計測を続けます");
    return i18n.t("Make a little time for yourself", "あなたのペースで、ひと区切り");
}

fn field(ui: *Ui, label: []const u8, value: []const u8, disabled: bool, comptime msg: @import("std").meta.Tag(app.Msg)) Ui.Node {
    return ui.column(.{ .grow = 1, .gap = 4 }, .{
        ui.text(.{ .size = .sm }, label),
        ui.el(.input, .{ .height = 30, .text = value, .disabled = disabled, .on_input = Ui.inputMsg(msg), .semantics = .{ .label = label } }, .{}),
    });
}

fn toggle(ui: *Ui, label: []const u8, selected: bool, msg: app.Msg) Ui.Node {
    return ui.row(.{ .height = 28, .gap = 8, .cross = .center }, .{
        ui.text(.{ .grow = 1, .size = .sm }, label),
        ui.el(.switch_control, .{ .selected = selected, .on_toggle = msg, .semantics = .{ .label = label } }, .{}),
    });
}

fn options(ui: *Ui, model: *const app.Model) Ui.Node {
    const st = &model.timer;
    const c = st.clock;
    const durations = if (c.mode == .pomodoro) ui.row(.{ .gap = 8 }, .{
        field(ui, i18n.t("Focus (min)", "集中（分）"), st.work.text(), c.locked(), .timer_work),
        field(ui, i18n.t("Short (min)", "短休憩（分）"), st.short.text(), c.locked(), .timer_short),
        field(ui, i18n.t("Long (min)", "長休憩（分）"), st.long.text(), c.locked(), .timer_long),
    }) else ui.row(.{ .gap = 8 }, .{
        field(ui, i18n.t("Minutes", "分"), st.minutes.text(), c.locked(), .timer_minutes),
        field(ui, i18n.t("Seconds", "秒"), st.seconds.text(), c.locked(), .timer_seconds),
    });
    const auto = if (c.mode == .pomodoro) toggle(ui, i18n.t("Auto-start next interval", "次の区間を自動で開始"), c.config.auto_start, .timer_auto) else ui.el(.stack, .{ .height = 0 }, .{});
    return ui.column(.{ .gap = 8 }, .{
        durations,
        ui.paragraph(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, &.{.{ .text = if (c.mode == .pomodoro) i18n.t("1–180 min · long break every 4 rounds", "1〜180分 · 4セットごとに長い休憩") else i18n.t("From 0:01 to 99:59", "0分01秒〜99分59秒") }}),
        auto,
        toggle(ui, i18n.t("Pet announces when finished", "終了時にペットがお知らせ"), c.config.speak, .timer_speak),
        ui.paragraph(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, &.{.{ .text = i18n.t("A chat bubble, without sound. Quiet in Focus mode.", "音声なしの吹き出しです。集中モード中はお知らせしません。") }}),
    });
}
