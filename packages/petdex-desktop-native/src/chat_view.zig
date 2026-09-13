//! The chat window and the Chat section of Settings. Pure views over
//! `Model.chat`; every interaction is a Msg that chat_shell handles.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const app = @import("main.zig");
const chat_shell = @import("chat_shell.zig");
const chat = @import("chat/chat.zig");
const i18n = @import("i18n.zig");

const Model = app.Model;
const Msg = app.Msg;
const AppUi = app.AppUi;
const State = chat_shell.State;
const Message = chat.domain.Message;

/// Side inset that tells a user turn from a reply without colored
/// chat bubbles.
const turn_inset: f32 = 40;

/// On macOS the chat is a speech bubble beside the pet: the pet's reply
/// in a card whose tail points at it, the user's own capsule below, and
/// a row of small round buttons. Elsewhere the same content sits in a
/// titled window (see the chat descriptor in main.zig).
pub const bubble = builtin.os.tag == .macos;

pub const card_w: f32 = 300;
const tail_len: f32 = @floatFromInt(app.tail_h);
pub const window_w: f32 = if (bubble) card_w + tail_len else 360;
/// The titled window's fixed height off macOS.
const titled_h: f32 = 520;
const card_pad: f32 = 14;
const text_w: f32 = card_w - card_pad * 2;
/// The reply card's line cap; a longer reply scrolls inside it.
const max_lines: usize = 10;
/// Stacked exchanges keep to a few lines each so six still fit a screen.
const older_max_lines: usize = 3;
const user_max_lines: usize = 2;
/// The user's own capsules sit right, narrower than the pet's cards.
const user_max_w: f32 = card_w - 48;
const user_pad: f32 = 10;
/// Room for the tail to clear both corner radii.
const min_card_h: f32 = 56;
const history_card_h: f32 = 340;
const action_gap: f32 = 10;
const action_h: f32 = 28;
const pill_h: f32 = 36;
const row_gap: f32 = 8;
const control_h: f32 = 28;

pub fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    const st = &model.chat;
    // Oldest on top, the reply card last, right above the composer.
    const s = stacked(model);
    const nodes = ui.arena.alloc(AppUi.Node, s.to - s.from + 3) catch return failedNode(ui);
    for (s.from..s.to, 0..) |i, j| nodes[j] = stackedBubble(ui, model, st.session.transcript.get(i));
    nodes[nodes.len - 3] = speechCard(ui, model, st);
    nodes[nodes.len - 2] = composer(ui, model, st);
    nodes[nodes.len - 1] = controls(ui, model, st);
    const body = ui.column(.{ .gap = row_gap }, @as([]const AppUi.Node, nodes));
    if (!bubble) {
        var root = ui.column(.{ .grow = 1 }, .{
            ui.el(.stack, .{ .height = app.companion_header_h, .window_drag = true }, .{}),
            ui.column(.{ .padding = 12, .cross = .center }, .{body}),
        });
        root.widget.style.background = app.settingsBackground(model);
        return root;
    }
    // Right of the pet the tail sits on the card's left edge pointing
    // left, and the other way round. It paints last, over the card's
    // hairline, so card and tail read as one outline.
    const p = st.place;
    const point_left = !p.left;
    const spacer = ui.el(.stack, .{ .width = tail_len }, .{});
    const row = if (point_left) ui.row(.{}, .{ spacer, body }) else ui.row(.{}, .{ body, spacer });
    const tail_x: f32 = if (point_left) 1.5 else card_w - 1.5;
    const tail_top = p.tail_y - @as(f32, @floatFromInt(app.tail_w)) / 2;
    var root = ui.el(.stack, .{ .width = window_w, .height = windowHeight(model) }, .{
        row,
        app.chatTail(ui, point_left, tail_x, tail_top),
    });
    // macOS shows a new window centered first; stay invisible until
    // chat_shell.follow has moved it beside the pet.
    if (!p.placed()) root.widget.opacity = 0;
    return root;
}

/// The window height for the current content. The descriptor uses it at
/// creation and chat_shell.follow resizes to it afterwards.
pub fn windowHeight(model: *const Model) f32 {
    if (!bubble) return titled_h;
    return speechTop(model) + cardHeight(model) + row_gap + pill_h + row_gap + control_h;
}

/// The stacked bubbles' height cap. With the reply card and composer the
/// window then still fits a laptop screen: AppKit clamps a taller window
/// by its top, which would push the composer off the bottom.
/// ponytail: fixed, the SDK does not report screen size; derive it from
/// the visible frame if that ever lands.
const max_stack_h: f32 = 640;

const Stack = struct { from: usize, to: usize, top: f32 };

/// The transcript range stacked above the reply card and the height it
/// takes: the last `st.stack` exchanges, minus the reply the card itself
/// shows, dropping the oldest messages past max_stack_h.
fn stacked(model: *const Model) Stack {
    const st = &model.chat;
    if (st.history) return .{ .from = 0, .to = 0, .top = 0 };
    const tr = &st.session.transcript;
    var to = tr.len();
    if (st.session.currentReply() != null) to -= 1;
    // Each exchange opens on a user turn.
    var from = to;
    var left: usize = st.stack;
    while (from > 0 and left > 0) {
        from -= 1;
        if (tr.get(from).role == .user) left -= 1;
    }
    var top: f32 = 0;
    for (from..to) |i| top += stackedHeight(model, tr.get(i)) + row_gap;
    while (top > max_stack_h and from < to) : (from += 1) top -= stackedHeight(model, tr.get(from)) + row_gap;
    return .{ .from = from, .to = to, .top = top };
}

/// The reply card's top in the window: the stacked bubbles above it.
/// chat_shell.follow lines this up with the pet's top.
pub fn speechTop(model: *const Model) f32 {
    return stacked(model).top;
}

fn stackedHeight(model: *const Model, m: Message) f32 {
    const line_h = lineHeight(model);
    if (m.role == .user) {
        const f = fit(model, m.text, user_max_w - user_pad * 2, user_max_lines);
        return user_pad * 2 + @as(f32, @floatFromInt(f.lines)) * line_h;
    }
    const f = fit(model, m.text, text_w, older_max_lines);
    return card_pad * 2 + @as(f32, @floatFromInt(f.lines)) * line_h;
}

/// One stacked message: the pet's in a card like the reply's, without
/// the tail; the user's in a capsule on the right that hugs short text.
fn stackedBubble(ui: *AppUi, model: *const Model, m: Message) AppUi.Node {
    const h = stackedHeight(model, m);
    if (m.role == .user) {
        const f = fit(model, m.text, user_max_w - user_pad * 2, user_max_lines);
        // One pt over the measured width so the line cannot wrap on rounding.
        const w = if (f.lines > 1) user_max_w else @min(user_max_w, @ceil(textWidth(model, m.text)) + 1 + user_pad * 2);
        var capsule = ui.el(.panel, .{ .padding = user_pad, .width = w, .height = h }, .{
            ui.paragraph(.{}, &.{.{ .text = clipped(ui, m.text, f) }}),
        });
        app.styleSpeechCard(&capsule, model.dark);
        return ui.row(.{ .main = .end }, .{capsule});
    }
    const f = fit(model, m.text, text_w, older_max_lines);
    var card = ui.el(.panel, .{ .padding = card_pad, .width = card_w, .height = h }, .{
        ui.paragraph(.{}, &.{.{ .text = clipped(ui, m.text, f) }}),
    });
    app.styleSpeechCard(&card, model.dark);
    return card;
}

pub fn cardHeight(model: *const Model) f32 {
    const st = &model.chat;
    if (st.history) return history_card_h;
    var buf: [speech_buf_len]u8 = undefined;
    const sp = speech(st, &buf);
    const action: f32 = if (sp.action != null) action_gap + action_h else 0;
    return @max(min_card_h, @ceil(card_pad * 2 + textHeight(model, sp.text) + action));
}

/// Wrapped height of `text` in the reply card, capped at max_lines.
fn textHeight(model: *const Model, text: []const u8) f32 {
    return @as(f32, @floatFromInt(fit(model, text, text_w, max_lines).lines)) * lineHeight(model);
}

/// The SDK's default line height for body text.
fn lineHeight(model: *const Model) f32 {
    return app.petdexTokens(model).typography.body_size * 1.25;
}

fn textWidth(model: *const Model, text: []const u8) f32 {
    const tokens = app.petdexTokens(model);
    const font = canvas.textSpanFontId(.{ .text = "" }, tokens.typography);
    return canvas.measureTextWidthForFont(tokens.text_measure, font, text, tokens.typography.body_size);
}

pub const Fit = struct { lines: usize, cut: usize };

/// How `text` wraps at `width` in body text, up to `max` lines: the line
/// count and the byte where the text must be cut to stay within them.
/// Uses the SDK's own line breaker with the tokens' measurement, so it
/// matches the paragraph painted from it.
fn fit(model: *const Model, text: []const u8, width: f32, comptime max: usize) Fit {
    return fitSized(model, text, width, app.petdexTokens(model).typography.body_size, lineHeight(model), max);
}

/// fit at any text size: the hook bubble's card measures its text at the
/// bubble text size.
pub fn fitSized(model: *const Model, text: []const u8, width: f32, size: f32, line_height: f32, comptime max: usize) Fit {
    const tokens = app.petdexTokens(model);
    var lines: [max + 1]canvas.TextLine = undefined;
    const count = if (canvas.layoutTextRun(.{
        .font_id = canvas.textSpanFontId(.{ .text = "" }, tokens.typography),
        .size = size,
        .origin = .{ .x = 0, .y = 0 },
        .color = tokens.colors.text,
        .text = text,
    }, .{
        .max_width = width,
        .line_height = line_height,
        .measure = tokens.text_measure,
    }, &lines)) |layout| layout.lineCount() else |_| lines.len;
    if (count <= max) return .{ .lines = @max(1, count), .cut = text.len };
    // A full buffer stops the layout with the lines it holds already
    // written; the cut ends the last line that stays.
    const last = lines[max - 1];
    return .{ .lines = max, .cut = last.text_start + last.text_len };
}

/// `text` cut to fit, an ellipsis standing in for the rest.
pub fn clipped(ui: *AppUi, text: []const u8, f: Fit) []const u8 {
    if (f.cut >= text.len) return text;
    // Two characters back, so the ellipsis stays on the last line.
    var cut = f.cut;
    var back: usize = 0;
    while (cut > 0 and back < 2) {
        cut -= 1;
        if (text[cut] & 0xC0 != 0x80) back += 1;
    }
    return ui.fmt("{s}…", .{std.mem.trimEnd(u8, text[0..cut], " \n")});
}

const Tone = enum { speech, quiet, failure };

const Speech = struct {
    text: []const u8,
    tone: Tone = .quiet,
    action: ?Msg = null,
    action_label: []const u8 = "",
};

const speech_buf_len = 192;

/// What the pet's bubble says right now.
fn speech(st: *const State, buf: []u8) Speech {
    const s = &st.session;
    if (s.phase == .failed) return .{ .text = s.errorText(), .tone = .failure, .action = .chat_retry, .action_label = i18n.t("Retry", "再試行") };
    // From the moment a request starts (a send, a retry, a briefing,
    // a credential refresh) until its first words: the thinking line.
    const reply = s.currentReply() orelse "";
    if (s.busy() and reply.len == 0) return .{ .text = st.thinkingText() };
    if (!st.ready()) return .{
        .text = if (st.kind == .codex)
            i18n.bufPrint(buf, "Sign in to ChatGPT in Settings to talk to {s}.", "{s}と話すには、設定でChatGPTにサインインしてください。", .{st.petName()}) catch i18n.t("Sign in to ChatGPT in Settings.", "設定でChatGPTにサインインしてください。")
        else
            i18n.t("Set the local server URL in Settings.", "設定でローカルサーバーのURLを指定してください。"),
        .action = .open_settings,
        .action_label = i18n.t("Open Settings", "設定を開く"),
    };
    if (reply.len > 0) return .{ .text = reply, .tone = .speech };
    if (s.lost_text) return .{ .text = i18n.t("Part of this reply was lost.", "返事の一部が失われました。") };
    return .{ .text = i18n.bufPrint(buf, "Say hello to {s}.", "{s}に話しかけてみましょう。", .{st.petName()}) catch i18n.t("Say hello.", "話しかけてみましょう。") };
}

fn speechCard(ui: *AppUi, model: *const Model, st: *const State) AppUi.Node {
    const content = if (st.history) transcript(ui, st) else speechContent(ui, model, st);
    var card = ui.el(.panel, .{ .padding = card_pad, .width = card_w, .height = cardHeight(model) }, .{content});
    app.styleSpeechCard(&card, model.dark);
    return card;
}

fn speechContent(ui: *AppUi, model: *const Model, st: *const State) AppUi.Node {
    const buf = ui.arena.alloc(u8, speech_buf_len) catch return failedNode(ui);
    const sp = speech(st, buf);
    const para = switch (sp.tone) {
        .speech => ui.paragraph(.{}, &.{.{ .text = sp.text }}),
        .quiet => ui.paragraph(.{ .style_tokens = .{ .foreground = .text_muted } }, &.{.{ .text = sp.text }}),
        .failure => ui.paragraph(.{ .style_tokens = .{ .foreground = .destructive } }, &.{.{ .text = sp.text }}),
    };
    // Sized to the estimate; a reply past max_lines scrolls in place.
    const lines = ui.scroll(.{
        .height = textHeight(model, sp.text),
        .value = st.scroll,
        .on_scroll = AppUi.scrollMsg(.chat_scrolled),
    }, .{para});
    const msg = sp.action orelse return lines;
    return ui.column(.{ .gap = action_gap }, .{
        lines,
        ui.row(.{}, .{ui.button(.{ .size = .sm, .variant = .secondary, .height = action_h, .on_press = msg }, sp.action_label)}),
    });
}

/// Newest exchange first, right under the composer. A secondary window
/// cannot be scrolled to its end from the app (the SDK exposes no
/// content extent there), so the newest words live at offset 0 instead
/// and older exchanges scroll below. Within an exchange the turns read
/// top-down as usual.
fn transcript(ui: *AppUi, st: *const State) AppUi.Node {
    const tr = &st.session.transcript;
    // Each user turn opens an exchange; a leading reply opens its own.
    var starts: [chat.session.max_messages + 1]usize = undefined;
    var count: usize = 0;
    for (0..tr.len()) |i| {
        if (i == 0 or tr.get(i).role == .user) {
            starts[count] = i;
            count += 1;
        }
    }
    starts[count] = tr.len();
    const status = hasStatusRow(st);
    const blocks = ui.arena.alloc(AppUi.Node, count) catch return failedNode(ui);
    for (blocks, 0..) |*block, k| {
        const e = count - 1 - k;
        const first = starts[e];
        const end = starts[e + 1];
        const with_status = k == 0 and status;
        const turns = ui.arena.alloc(AppUi.Node, end - first + @intFromBool(with_status)) catch return failedNode(ui);
        for (first..end, 0..) |i, j| turns[j] = turnRow(ui, tr.get(i));
        if (with_status) turns[end - first] = statusRow(ui, st);
        block.* = ui.column(.{ .gap = 2 }, @as([]const AppUi.Node, turns));
    }
    return ui.scroll(.{
        .grow = 1,
        .value = st.scroll,
        .on_scroll = AppUi.scrollMsg(.chat_scrolled),
    }, .{ui.column(.{ .padding = 8, .gap = 14 }, @as([]const AppUi.Node, blocks))});
}

fn failedNode(ui: *AppUi) AppUi.Node {
    ui.failed = true;
    return ui.column(.{ .grow = 1 }, .{});
}

fn hasStatusRow(st: *const State) bool {
    const s = &st.session;
    return s.thinking() or s.phase == .failed or (s.phase == .idle and s.lost_text);
}

fn turnRow(ui: *AppUi, m: Message) AppUi.Node {
    const card = ui.el(.panel, .{
        .padding = 10,
        .style_tokens = .{
            .background = if (m.role == .user) .surface_subtle else .surface,
            .radius = .md,
        },
    }, .{
        ui.paragraph(.{}, &.{.{ .text = if (m.text.len > 0) m.text else " " }}),
    });
    const inset = ui.el(.stack, .{ .width = turn_inset }, .{});
    return if (m.role == .user)
        ui.row(.{ .padding = 4 }, .{ inset, ui.column(.{ .grow = 1 }, .{card}) })
    else
        ui.row(.{ .padding = 4 }, .{ ui.column(.{ .grow = 1 }, .{card}), inset });
}

fn statusRow(ui: *AppUi, st: *const State) AppUi.Node {
    const s = &st.session;
    if (s.phase == .failed) {
        return ui.column(.{ .padding = 8, .gap = 6 }, .{
            ui.paragraph(.{ .size = .sm, .style_tokens = .{ .foreground = .destructive } }, &.{.{ .text = s.errorText() }}),
            ui.row(.{}, .{
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chat_retry }, i18n.t("Retry", "再試行")),
            }),
        });
    }
    if (s.thinking()) return ui.column(.{ .padding = 8 }, .{muted(ui, st.thinkingText())});
    return ui.column(.{ .padding = 8 }, .{muted(ui, i18n.t("Part of this reply was lost.", "返事の一部が失われました。"))});
}

/// The user's own bubble: a capsule field in the pet bubble's colors,
/// and the send button (Stop while a reply streams).
fn composer(ui: *AppUi, model: *const Model, st: *const State) AppUi.Node {
    var field = ui.el(.input, .{
        .grow = 1,
        .height = pill_h,
        .text = st.inputText(),
        .placeholder = i18n.fmt(ui, "Message {s}", "{s}にメッセージ", .{st.petName()}),
        .on_input = AppUi.inputMsg(.chat_input),
        .on_submit = .chat_submit,
        .autofocus = true,
        .semantics = .{ .label = i18n.t("Message", "メッセージ") },
    }, .{});
    app.styleSpeechCard(&field, model.dark);
    field.widget.style.radius = pill_h / 2;
    const busy = st.session.busy();
    var action = if (busy)
        ui.button(.{ .height = pill_h, .on_press = .chat_stop }, i18n.t("Stop", "停止"))
    else
        ui.button(.{
            .icon = "arrow-up",
            .size = .icon,
            .variant = .primary,
            .width = pill_h,
            .height = pill_h,
            .disabled = st.input.len == 0 or !st.ready(),
            .on_press = .chat_submit,
            .semantics = .{ .label = i18n.t("Send", "送信") },
        }, "");
    if (busy) app.styleSpeechCard(&action, model.dark);
    action.widget.style.radius = pill_h / 2;
    return ui.row(.{ .gap = 8, .cross = .center, .width = card_w }, .{ field, action });
}

/// Small round buttons under the composer. Each wears the bubble surface
/// so it stays legible over any desktop.
fn controls(ui: *AppUi, model: *const Model, st: *const State) AppUi.Node {
    return ui.row(.{ .gap = 6, .width = card_w }, .{
        ui.el(.stack, .{ .grow = 1 }, .{}),
        // Starts over: the conversation and its saved history go.
        roundButton(ui, model, "edit", i18n.t("New Chat", "新しいチャット"), .chat_clear, st.session.transcript.len() == 0 and !st.session.busy()),
        roundButton(ui, model, "clock", if (st.history) i18n.t("Latest Reply", "最新の返事") else i18n.t("Earlier Messages", "以前のメッセージ"), .chat_toggle_history, false),
        roundButton(ui, model, "x", i18n.t("Close Chat", "チャットを閉じる"), .chat_closed, false),
    });
}

fn roundButton(ui: *AppUi, model: *const Model, icon: []const u8, label: []const u8, msg: Msg, disabled: bool) AppUi.Node {
    var button = ui.button(.{
        .icon = icon,
        .size = .icon,
        .width = control_h,
        .height = control_h,
        .disabled = disabled,
        .on_press = msg,
        .semantics = .{ .label = label },
    }, "");
    app.styleSpeechCard(&button, model.dark);
    button.widget.style.radius = control_h / 2;
    return button;
}

// ── Settings ──────────────────────────────────────────────────────────

pub fn settingsSection(ui: *AppUi, model: *const Model) AppUi.Node {
    const st = &model.chat;
    return ui.column(.{ .gap = 10 }, .{
        ui.text(.{ .size = .lg }, i18n.t("Chat", "チャット")),
        panel(ui, ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, i18n.t("Talk to your pet", "ペットと話す")),
                muted(ui, i18n.t("Click the pet to chat; double-click for a catch-up on your agents", "クリックでチャット、ダブルクリックでエージェントの様子を聞けます")),
            }),
            ui.row(.{ .gap = 6 }, .{
                ui.button(.{
                    .size = .sm,
                    .variant = if (st.kind == .codex) .primary else .secondary,
                    .on_press = Msg{ .set_chat_provider = @intFromEnum(chat.domain.ProviderKind.codex) },
                }, "ChatGPT"),
                ui.button(.{
                    .size = .sm,
                    .variant = if (st.kind == .openai_compat) .primary else .secondary,
                    .on_press = Msg{ .set_chat_provider = @intFromEnum(chat.domain.ProviderKind.openai_compat) },
                }, i18n.t("Local", "ローカル")),
            }),
        })),
        switch (st.kind) {
            .codex => chatgptPanel(ui, st),
            .openai_compat => localPanel(ui, st),
        },
        panel(ui, ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, i18n.t("Messages on screen", "画面に残すメッセージ")),
                muted(ui, i18n.t("Recent exchanges the chat bubble keeps", "チャットの吹き出しに残す最近のやりとりの数")),
            }),
            stackPicker(ui, st),
        })),
        panel(ui, ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, i18n.t("Small talk", "ひとりごと")),
                muted(ui, i18n.t("Now and then, your pet says something on its own", "ときどき、ペットが自分から話しかけます")),
            }),
            chatterPicker(ui, st),
        })),
        panel(ui, ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, i18n.t("Speak up when an agent needs you", "対応が必要なとき声をかける")),
                muted(ui, i18n.t("Your pet tells you once when a coding agent waits on you", "エージェントが待っているとき、ペットが一度だけ知らせます")),
            }),
            ui.el(.switch_control, .{
                .selected = st.nudge,
                .on_toggle = .toggle_nudge,
                .semantics = .{ .label = i18n.t("Speak up when an agent needs you", "対応が必要なとき声をかける") },
            }, .{}),
        })),
    });
}

fn chatterPicker(ui: *AppUi, st: *const State) AppUi.Node {
    var buttons: [chat_shell.chatter_choices.len]AppUi.Node = undefined;
    for (&buttons, chat_shell.chatter_choices) |*button, minutes| button.* = ui.button(.{
        .size = .sm,
        .variant = if (st.chatter_minutes == minutes) .primary else .secondary,
        .on_press = Msg{ .set_chatter = minutes },
    }, switch (minutes) {
        0 => i18n.t("Off", "オフ"),
        60 => i18n.t("1 h", "1時間"),
        else => i18n.fmt(ui, "{d} min", "{d}分", .{minutes}),
    });
    return ui.row(.{ .gap = 4 }, @as([]const AppUi.Node, &buttons));
}

fn stackPicker(ui: *AppUi, st: *const State) AppUi.Node {
    var buttons: [chat_shell.max_stack]AppUi.Node = undefined;
    for (&buttons, 1..) |*button, n| button.* = ui.button(.{
        .size = .sm,
        .variant = if (st.stack == n) .primary else .secondary,
        .on_press = Msg{ .set_chat_stack = @intCast(n) },
        .semantics = .{ .label = if (n == 1) i18n.t("1 exchange", "1件のやりとり") else i18n.fmt(ui, "{d} exchanges", "{d}件のやりとり", .{n}) },
    }, ui.fmt("{d}", .{n}));
    return ui.row(.{ .gap = 4 }, @as([]const AppUi.Node, &buttons));
}

fn chatgptPanel(ui: *AppUi, st: *const State) AppUi.Node {
    const status: []const u8 = switch (st.chatgpt) {
        .signed_in => i18n.t("Signed in. Replies use your ChatGPT plan", "サインイン済み。返事にはChatGPTのプランを使います"),
        .authorizing => i18n.t("Finish signing in in your browser", "ブラウザでサインインを完了してください"),
        .exchanging => i18n.t("Signing in…", "サインイン中…"),
        .failed => if (st.note_len > 0) st.noteText() else i18n.t("Sign-in failed", "サインインできませんでした"),
        .signed_out => i18n.t("Uses your Plus or Pro plan; no API key needed", "PlusまたはProのプランを使います。APIキーは不要です"),
    };
    const action = switch (st.chatgpt) {
        .signed_in => ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chatgpt_sign_out }, i18n.t("Sign out", "サインアウト")),
        .exchanging => ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, i18n.t("Sign in", "サインイン")),
        else => ui.button(.{ .size = .sm, .variant = .primary, .on_press = .chatgpt_sign_in }, i18n.t("Sign in", "サインイン")),
    };
    const show_note = st.note_len > 0 and st.chatgpt != .failed;
    return panel(ui, ui.column(.{ .padding = 12, .gap = 8 }, .{
        ui.row(.{ .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, "ChatGPT"),
                muted(ui, status),
            }),
            action,
        }),
        if (st.chatgpt != .signed_in)
            ui.row(.{}, .{ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chatgpt_import }, i18n.t("Use Codex CLI Sign-in", "Codex CLIのサインインを使う"))})
        else
            ui.el(.stack, .{}, .{}),
        if (show_note) muted(ui, st.noteText()) else ui.el(.stack, .{}, .{}),
        ui.text(.{ .size = .sm }, i18n.t("Model", "モデル")),
        ui.el(.input, .{
            .height = 34,
            .text = st.codexModel(),
            .placeholder = chat.codex.default_model,
            .on_input = AppUi.inputMsg(.chat_model_input),
            .semantics = .{ .label = i18n.t("ChatGPT model", "ChatGPTのモデル") },
        }, .{}),
    }));
}

fn localPanel(ui: *AppUi, st: *const State) AppUi.Node {
    return panel(ui, ui.column(.{ .padding = 12, .gap = 8 }, .{
        ui.text(.{}, i18n.t("Local server", "ローカルサーバー")),
        muted(ui, i18n.t("LM Studio, Ollama, or any OpenAI-compatible server", "LM Studio、Ollama、またはOpenAI互換のサーバー")),
        ui.text(.{ .size = .sm }, i18n.t("Server URL", "サーバーのURL")),
        ui.el(.input, .{
            .height = 34,
            .text = st.localUrl(),
            .placeholder = chat.openai_compat.default_base_url,
            .on_input = AppUi.inputMsg(.chat_url_input),
            .semantics = .{ .label = i18n.t("Server URL", "サーバーのURL") },
        }, .{}),
        ui.text(.{ .size = .sm }, i18n.t("Model", "モデル")),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.el(.input, .{
                .grow = 1,
                .height = 34,
                .text = st.localModel(),
                .placeholder = i18n.t("The loaded model", "読み込まれているモデル"),
                .on_input = AppUi.inputMsg(.chat_model_input),
                .semantics = .{ .label = i18n.t("Local model", "ローカルのモデル") },
            }, .{}),
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = st.detecting, .on_press = .chat_detect_models }, i18n.t("Detect", "検出")),
        }),
        if (st.note_len > 0) muted(ui, st.noteText()) else ui.el(.stack, .{}, .{}),
    }));
}

fn panel(ui: *AppUi, content: AppUi.Node) AppUi.Node {
    return ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{content});
}

fn muted(ui: *AppUi, content: []const u8) AppUi.Node {
    return ui.paragraph(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, &.{.{ .text = content }});
}

test "the reply card grows with the reply and stops at ten lines" {
    var model: Model = .{};
    model.chat.local_url.set("http://localhost:1234/v1");
    const tr = &model.chat.session.transcript;
    tr.append(.user, "hi");
    tr.append(.assistant, "hey");
    const short = cardHeight(&model);
    tr.append(.user, "tell me more");
    tr.append(.assistant, "and more " ** 300);
    const long = cardHeight(&model);
    tr.append(.user, "go on");
    tr.append(.assistant, "and more " ** 600);
    try std.testing.expect(long > short);
    try std.testing.expectEqual(long, cardHeight(&model));
    model.chat.history = true;
    try std.testing.expectEqual(history_card_h, cardHeight(&model));
    if (!bubble) try std.testing.expectEqual(titled_h, windowHeight(&model));
}

test "the chat bubble stacks as many exchanges as the setting allows" {
    var model: Model = .{};
    model.chat.local_url.set("http://localhost:1234/v1");
    const tr = &model.chat.session.transcript;
    try std.testing.expectEqual(@as(f32, 0), speechTop(&model));
    for (0..8) |_| {
        tr.append(.user, "hi");
        tr.append(.assistant, "hey");
    }
    model.chat.stack = 1;
    // Just the question the reply card answers.
    const one = speechTop(&model);
    try std.testing.expect(one > 0);
    model.chat.stack = chat_shell.max_stack;
    const six = speechTop(&model);
    try std.testing.expect(six > one);
    // A further exchange pushes the oldest out.
    tr.append(.user, "hi");
    tr.append(.assistant, "hey");
    try std.testing.expectEqual(six, speechTop(&model));
    // The full history replaces the stack.
    model.chat.history = true;
    try std.testing.expectEqual(@as(f32, 0), speechTop(&model));
}

test "a stack of long messages drops its oldest to stay on screen" {
    var model: Model = .{};
    model.chat.local_url.set("http://localhost:1234/v1");
    model.chat.stack = chat_shell.max_stack;
    const tr = &model.chat.session.transcript;
    for (0..8) |_| {
        tr.append(.user, "and more " ** 40);
        tr.append(.assistant, "and more " ** 80);
    }
    const top = speechTop(&model);
    try std.testing.expect(top <= max_stack_h);
    try std.testing.expect(top > max_stack_h / 2);
}

test "stacked bubbles cut long text at their line cap" {
    var model: Model = .{};
    const long = "and more " ** 200;
    const f = fit(&model, long, text_w, older_max_lines);
    try std.testing.expectEqual(older_max_lines, f.lines);
    try std.testing.expect(f.cut > 0 and f.cut < long.len);
    const short = fit(&model, "hey", text_w, older_max_lines);
    try std.testing.expectEqual(@as(usize, 1), short.lines);
    try std.testing.expectEqual(@as(usize, 3), short.cut);
}

test "the reply card thinks until the first words, a briefing included" {
    var model: Model = .{};
    model.chat.local_url.set("http://localhost:1234/v1");
    const st = &model.chat;
    const s = &st.session;
    s.transcript.append(.user, "hi");
    s.transcript.append(.assistant, "hey");
    var buf: [speech_buf_len]u8 = undefined;
    try std.testing.expectEqualStrings("hey", speech(st, &buf).text);
    // A briefing adds no user turn: the old reply joins the stack and
    // the card thinks.
    try std.testing.expectEqual(chat.session.Action.request, s.brief(.briefing, false));
    try std.testing.expectEqualStrings(st.thinkingText(), speech(st, &buf).text);
    try std.testing.expectEqual(@as(usize, 2), stacked(&model).to);
    // The first words replace the thinking line; the old reply stays stacked.
    var scratch: [4096]u8 = undefined;
    s.onLine(.openai_compat, s.streamKey(), "data: {\"choices\":[{\"delta\":{\"content\":\"Claude waits.\"}}]}", false, false, &scratch);
    try std.testing.expectEqualStrings("Claude waits.", speech(st, &buf).text);
    try std.testing.expectEqual(@as(usize, 2), stacked(&model).to);
    // A plain send thinks the same way.
    try std.testing.expectEqual(chat.session.Action.done, s.onResponse(.openai_compat, s.streamKey(), 200, null));
    try std.testing.expectEqual(chat.session.Action.request, s.submit("more?", false));
    try std.testing.expectEqualStrings(st.thinkingText(), speech(st, &buf).text);
}

test "an unconfigured chat bubble points at Settings" {
    var model: Model = .{};
    var buf: [speech_buf_len]u8 = undefined;
    const sp = speech(&model.chat, &buf);
    try std.testing.expect(sp.action.? == .open_settings);
    // The Open Settings button adds to the card.
    const unconfigured = cardHeight(&model);
    model.chat.local_url.set("http://localhost:1234/v1");
    try std.testing.expect(cardHeight(&model) < unconfigured);
}
