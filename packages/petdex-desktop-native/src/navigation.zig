//! Daily actions shared by the pet's context menu and the menu-bar extra.
//! Labels describe the next action, derived from the same live model.
const std = @import("std");
const builtin = @import("builtin");
const app = @import("main.zig");
const i18n = @import("i18n.zig");

pub const Action = struct {
    label: []const u8 = "",
    command: []const u8 = "",
    msg: ?app.Msg = null,
    enabled: bool = true,
    separator: bool = false,
};

pub const Actions = struct {
    items: [16]Action = undefined,
    len: usize = 0,

    fn add(self: *Actions, item: Action) void {
        self.items[self.len] = item;
        self.len += 1;
    }

    pub fn slice(self: *const Actions) []const Action {
        return self.items[0..self.len];
    }
};

pub fn quickActions(model: *const app.Model) Actions {
    var result: Actions = .{};
    result.add(.{ .label = if (model.chat.open) i18n.t("Hide Chat", "チャットを隠す") else i18n.t("Show Chat", "チャットを表示"), .command = "petdex.chat", .msg = .open_chat });
    result.add(.{ .label = i18n.t("Chat options…", "チャットの設定…"), .command = "petdex.chat-options", .msg = .open_chat_options });
    result.add(.{ .label = if (model.timer.isVisible(model.chat.open)) i18n.t("Hide Timer", "タイマーを隠す") else i18n.t("Show Timer", "タイマーを表示"), .command = "petdex.timer", .msg = .timer_visibility });
    result.add(.{ .separator = true });
    result.add(.{ .label = if (model.bubbles_enabled) i18n.t("Hide Agent Bubbles", "通知吹き出しを隠す") else i18n.t("Show Agent Bubbles", "通知吹き出しを表示"), .command = "petdex.bubbles", .msg = .toggle_bubbles });
    result.add(.{ .label = if (model.flock.open) i18n.t("Hide Flock", "フロックを隠す") else i18n.t("Show Flock", "フロックを表示"), .command = "petdex.flock", .msg = .toggle_flock_window });
    if (builtin.os.tag == .macos) result.add(.{ .label = if (model.usage_limits) i18n.t("Hide Usage Limits", "利用上限を隠す") else i18n.t("Show Usage Limits", "利用上限を表示"), .command = "petdex.usage-limits", .msg = .toggle_usage_limits });
    result.add(.{ .separator = true });
    result.add(.{ .label = if (model.focus_mode) i18n.t("End Focus Mode", "集中モードを終了") else i18n.t("Start Focus Mode", "集中モードを開始"), .command = "petdex.focus", .msg = .toggle_focus_mode });
    result.add(.{ .label = if (model.waiting_sound) i18n.t("Mute Waiting Sound", "待機中の通知音をオフ") else i18n.t("Enable Waiting Sound", "待機中の通知音をオン"), .command = "petdex.waiting-sound", .msg = .toggle_waiting_sound });
    result.add(.{ .label = i18n.t("Clear Notifications", "通知を消去"), .command = "petdex.clear-notifications", .msg = .clear_notifications, .enabled = model.bubbles_len > 0 });
    result.add(.{ .label = i18n.t("Notification options…", "通知の設定…"), .command = "petdex.notifications", .msg = .{ .set_settings_page = @intFromEnum(app.settings_view.Page.notifications) } });
    return result;
}

pub fn contextMenu(ui: *app.AppUi, model: *const app.Model) []const app.AppUi.ContextMenuItem {
    const actions = quickActions(model);
    const items = ui.arena.alloc(app.AppUi.ContextMenuItem, actions.len + 6) catch return &.{};
    for (actions.slice(), 0..) |action, i| items[i] = .{ .label = action.label, .msg = action.msg, .enabled = action.enabled, .separator = action.separator };
    @memcpy(items[actions.len..], &[_]app.AppUi.ContextMenuItem{
        .{ .separator = true },
        .{ .label = i18n.t("Pets…", "ペット…"), .msg = .{ .set_settings_page = 0 } },
        .{ .label = i18n.t("Settings…", "設定…"), .msg = .open_settings },
        .{ .label = i18n.t("Reset Position", "位置のリセット"), .msg = .reset_position },
        .{ .label = i18n.t("View Pet on Petdex", "Petdexでペットを見る"), .msg = .open_active_pet_page },
        .{ .label = i18n.t("Close Pet", "ペットを閉じる"), .msg = .close_pet },
    });
    return items;
}

test "daily menu actions reflect live visibility and dispatch the same commands" {
    const previous = i18n.current;
    defer i18n.current = previous;
    for ([_]i18n.Lang{ .en, .ja }) |lang| {
        i18n.current = lang;
        var model: app.Model = .{};
        const before = quickActions(&model);
        model.chat.open = true;
        model.flock.open = true;
        model.bubbles_enabled = false;
        model.usage_limits = true;
        model.waiting_sound = true;
        model.focus_mode = true;
        model.bubbles_len = 1;
        const after = quickActions(&model);
        for (before.slice(), after.slice()) |off, on| {
            if (on.separator) continue;
            try std.testing.expectEqual(std.meta.activeTag(on.msg.?), std.meta.activeTag(app.onCommand(on.command).?));
            try std.testing.expect(on.label.len <= 128);
            if (std.mem.eql(u8, on.command, "petdex.clear-notifications")) {
                try std.testing.expect(!off.enabled);
                try std.testing.expect(on.enabled);
            } else if (!std.mem.eql(u8, on.command, "petdex.chat-options") and !std.mem.eql(u8, on.command, "petdex.notifications")) {
                try std.testing.expect(!std.mem.eql(u8, off.label, on.label));
            }
        }
    }
}

test "timer menu reflects both chat visibility and the saved card preference" {
    const previous = i18n.current;
    defer i18n.current = previous;
    for ([_]i18n.Lang{ .en, .ja }) |lang| {
        i18n.current = lang;
        var model: app.Model = .{};
        for ([_]bool{ false, true }) |chat_open| {
            model.chat.open = chat_open;
            for ([_]bool{ false, true }) |timer_visible| {
                model.timer.clock.config.visible = timer_visible;
                const actions = quickActions(&model);
                var found = false;
                for (actions.slice()) |action| {
                    if (!std.mem.eql(u8, action.command, "petdex.timer")) continue;
                    found = true;
                    try std.testing.expectEqualStrings(
                        if (chat_open and timer_visible) i18n.t("Hide Timer", "タイマーを隠す") else i18n.t("Show Timer", "タイマーを表示"),
                        action.label,
                    );
                    try std.testing.expect(action.enabled);
                    try std.testing.expectEqual(app.Msg.timer_visibility, action.msg.?);
                }
                try std.testing.expect(found);
            }
        }
    }
}
