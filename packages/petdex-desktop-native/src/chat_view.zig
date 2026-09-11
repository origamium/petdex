//! The chat window and the Chat section of Settings. Pure views over
//! `Model.chat`; every interaction is a Msg that chat_shell handles.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const app = @import("main.zig");
const chat_shell = @import("chat_shell.zig");
const chat = @import("chat/chat.zig");

const Model = app.Model;
const Msg = app.Msg;
const AppUi = app.AppUi;
const State = chat_shell.State;
const Message = chat.domain.Message;

/// Side inset that tells a user turn from a reply without colored
/// chat bubbles.
const turn_inset: f32 = 40;

pub fn view(ui: *AppUi, model: *const Model) AppUi.Node {
    const st = &model.chat;
    var root = ui.column(.{ .grow = 1 }, .{
        ui.el(.stack, .{ .height = app.companion_header_h, .window_drag = true }, .{}),
        header(ui, st),
        composer(ui, st),
        body(ui, st),
    });
    root.widget.style.background = app.settingsBackground(model);
    return root;
}

fn header(ui: *AppUi, st: *const State) AppUi.Node {
    const caption = switch (st.kind) {
        .codex => ui.fmt("ChatGPT · {s}", .{st.codexModel()}),
        .openai_compat => if (st.local_model_len > 0) ui.fmt("Local · {s}", .{st.localModel()}) else "Local server",
    };
    return ui.row(.{ .padding = 12, .gap = 8, .cross = .center }, .{
        ui.column(.{ .grow = 1 }, .{
            ui.text(.{ .size = .lg }, st.petName()),
            muted(ui, caption),
        }),
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .disabled = st.session.transcript.len() == 0,
            .on_press = .chat_clear,
        }, "Clear"),
    });
}

fn body(ui: *AppUi, st: *const State) AppUi.Node {
    const s = &st.session;
    if (s.transcript.len() == 0 and s.phase == .idle) return emptyState(ui, st);
    return transcript(ui, st);
}

fn emptyState(ui: *AppUi, st: *const State) AppUi.Node {
    const ready = st.ready();
    const line = if (ready)
        ui.fmt("Say hello to {s}.", .{st.petName()})
    else if (st.kind == .codex)
        ui.fmt("Sign in to ChatGPT in Settings to talk to {s}.", .{st.petName()})
    else
        "Set the local server URL in Settings.";
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .padding = 24, .gap = 12 }, .{
        muted(ui, line),
        if (ready)
            ui.el(.stack, .{}, .{})
        else
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .open_settings }, "Open Settings"),
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
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chat_retry }, "Retry"),
            }),
        });
    }
    if (s.phase == .refreshing) return ui.column(.{ .padding = 8 }, .{muted(ui, "Reconnecting to ChatGPT…")});
    if (s.thinking()) return ui.column(.{ .padding = 8 }, .{muted(ui, "…")});
    return ui.column(.{ .padding = 8 }, .{muted(ui, "Part of this reply was lost.")});
}

fn composer(ui: *AppUi, st: *const State) AppUi.Node {
    return ui.row(.{ .padding = 12, .gap = 8, .cross = .center }, .{
        ui.el(.input, .{
            .grow = 1,
            .height = 34,
            .text = st.inputText(),
            .placeholder = ui.fmt("Message {s}", .{st.petName()}),
            .on_input = AppUi.inputMsg(.chat_input),
            .on_submit = .chat_submit,
            .autofocus = true,
            .semantics = .{ .label = "Message" },
        }, .{}),
        if (st.session.busy())
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chat_stop }, "Stop")
        else
            ui.button(.{ .size = .sm, .variant = .primary, .disabled = st.input_len == 0 or !st.ready(), .on_press = .chat_submit }, "Send"),
    });
}

// ── Settings ──────────────────────────────────────────────────────────

pub fn settingsSection(ui: *AppUi, model: *const Model) AppUi.Node {
    const st = &model.chat;
    return ui.column(.{ .gap = 10 }, .{
        ui.text(.{ .size = .lg }, "Chat"),
        panel(ui, ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, "Talk to your pet"),
                muted(ui, "Double-click the pet, or choose Chat from its menu"),
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
                }, "Local"),
            }),
        })),
        switch (st.kind) {
            .codex => chatgptPanel(ui, st),
            .openai_compat => localPanel(ui, st),
        },
    });
}

fn chatgptPanel(ui: *AppUi, st: *const State) AppUi.Node {
    const status: []const u8 = switch (st.chatgpt) {
        .signed_in => "Signed in. Replies use your ChatGPT plan",
        .authorizing => "Finish signing in in your browser",
        .exchanging => "Signing in…",
        .failed => if (st.note_len > 0) st.noteText() else "Sign-in failed",
        .signed_out => "Uses your Plus or Pro plan; no API key needed",
    };
    const action = switch (st.chatgpt) {
        .signed_in => ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chatgpt_sign_out }, "Sign out"),
        .exchanging => ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, "Sign in"),
        else => ui.button(.{ .size = .sm, .variant = .primary, .on_press = .chatgpt_sign_in }, "Sign in"),
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
            ui.row(.{}, .{ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .chatgpt_import }, "Use Codex CLI Sign-in")})
        else
            ui.el(.stack, .{}, .{}),
        if (show_note) muted(ui, st.noteText()) else ui.el(.stack, .{}, .{}),
        ui.text(.{ .size = .sm }, "Model"),
        ui.el(.input, .{
            .height = 34,
            .text = st.codexModel(),
            .placeholder = chat.codex.default_model,
            .on_input = AppUi.inputMsg(.chat_model_input),
            .semantics = .{ .label = "ChatGPT model" },
        }, .{}),
    }));
}

fn localPanel(ui: *AppUi, st: *const State) AppUi.Node {
    return panel(ui, ui.column(.{ .padding = 12, .gap = 8 }, .{
        ui.text(.{}, "Local server"),
        muted(ui, "LM Studio, Ollama, or any OpenAI-compatible server"),
        ui.text(.{ .size = .sm }, "Server URL"),
        ui.el(.input, .{
            .height = 34,
            .text = st.localUrl(),
            .placeholder = chat.openai_compat.default_base_url,
            .on_input = AppUi.inputMsg(.chat_url_input),
            .semantics = .{ .label = "Server URL" },
        }, .{}),
        ui.text(.{ .size = .sm }, "Model"),
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.el(.input, .{
                .grow = 1,
                .height = 34,
                .text = st.localModel(),
                .placeholder = "The loaded model",
                .on_input = AppUi.inputMsg(.chat_model_input),
                .semantics = .{ .label = "Local model" },
            }, .{}),
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = st.detecting, .on_press = .chat_detect_models }, "Detect"),
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
