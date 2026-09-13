//! The Settings window's view tree: the pet picker, the Agents rows,
//! the install banner, and every Appearance control.
//!
//! Extracted from main.zig (#613). Six of the last seven PRs to touch
//! main.zig added a row here, so this was the busiest contended region
//! in the file. It reads the model and returns nodes; it owns no state
//! and runs no effects, which is what makes it separable at all.
//!
//! The agent-icon atlas is the one exception: those globals live in
//! main.zig beside the registration that fills them, so they arrive as
//! `IconAtlas` rather than being reached across the module boundary.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const app = @import("main.zig");
const Model = app.Model;
const Msg = app.Msg;
const AppUi = app.AppUi;
const custom_font_active = &app.custom_font_active;
const bubble_text_min_px = app.bubble_text_min_px;
const bubble_text_max_px = app.bubble_text_max_px;
const catalog_mod = @import("catalog.zig");
const catalog = &catalog_mod.catalog;
const catalog_len = &catalog_mod.catalog_len;
const max_catalog = catalog_mod.max_catalog;
const agent_hooks = @import("agent_hooks.zig");
const remote_runtime = @import("remote_runtime.zig");
const chat_view = @import("chat_view.zig");
const i18n = @import("i18n.zig");
const settingsBackground = app.settingsBackground;
const companion_header_h = app.companion_header_h;

/// Where the agent logos are, handed in so this file does not reach into
/// main.zig's registration state.
pub const IconAtlas = struct {
    ready: bool,
    image: u64,
    rect: *const fn (usize) geometry.RectF,
};

/// The pet thumbnail atlas, same reasoning as IconAtlas: the pixels and
/// the per-pet ready flags are filled incrementally by main.zig's poll
/// timer, so the view reads them rather than owning them.
pub const ThumbAtlas = struct {
    image: u64,
    ready: []const bool,
    cell_w: f32,
    cell_h: f32,
};

pub const CloudImages = struct {
    avatar_ready: bool,
    avatar_image: u64,
    preview_image: u64,
    preview_ready: []const bool,
    preview_cell: f32,
    preview_columns: usize,
};

/// Secondary copy in a settings row. A plain `ui.text` leaf is always
/// single-line and elides when the trailing control narrows its column.
/// Span paragraphs word-wrap and make the row reserve the resulting
/// height, so the default window width remains fully readable.
fn mutedParagraph(ui: *AppUi, content: []const u8) AppUi.Node {
    return ui.paragraph(.{
        .size = .sm,
        .style_tokens = .{ .foreground = .text_muted },
    }, &.{.{ .text = content }});
}

fn agentStatusCaption(info: agent_hooks.AgentInfo, codex_note: bool, dsh_busy: bool, dsh_error: bool) []const u8 {
    if (info.kind == .dsh) {
        if (dsh_busy) return i18n.t("Running the DSH plugin command", "DSHプラグインのコマンドを実行中");
        if (dsh_error) return i18n.t("Plugin command failed - check npx and network", "プラグインのコマンドが失敗しました。npxとネットワークを確認してください");
        return switch (info.status) {
            .absent => i18n.t("Not detected", "見つかりません"),
            .none => i18n.t("Plugin not installed", "プラグイン未インストール"),
            .node => i18n.t("Restart DSH Web, then start a task", "DSH Webを再起動してからタスクを始めてください"),
            .current => i18n.t("Connected", "接続済み"),
        };
    }
    if (info.kind == .codex and codex_note) return i18n.t("Installed - restart Codex and approve its hooks once", "インストール済み。Codexを再起動して、フックを一度承認してください");
    if (info.kind == .opencode) {
        return switch (info.status) {
            .absent => i18n.t("Not detected", "見つかりません"),
            .none => i18n.t("Plugin not installed", "プラグイン未インストール"),
            .node => i18n.t("Plugin outdated", "プラグインが古くなっています"),
            .current => i18n.t("Connected", "接続済み"),
        };
    }
    return switch (info.status) {
        .absent => i18n.t("Not detected", "見つかりません"),
        .none => i18n.t("Hooks not installed", "フック未インストール"),
        .node => i18n.t("Hooks outdated (CLI runner)", "フックが古くなっています（CLIランナー）"),
        .current => i18n.t("Connected", "接続済み"),
    };
}

var more_label_buf: [48]u8 = undefined;

var install_label_buf: [128]u8 = undefined;

fn petMatchesFilter(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (name.len < filter.len) return false;
    var i: usize = 0;
    while (i + filter.len <= name.len) : (i += 1) {
        var match = true;
        for (filter, 0..) |c, j| {
            if (std.ascii.toLower(name[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn moreLabel(total: usize) []const u8 {
    return i18n.bufPrint(&more_label_buf, "Show all ({d})", "すべて表示（{d}）", .{total}) catch i18n.t("Show all", "すべて表示");
}

/// Download progress and the last failure, in the Settings page the app
/// already has. A deep-link install is otherwise invisible: the pet just
/// appears seconds later with no indication anything was happening.
fn installBanner(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.install.busy()) {
        const slug = model.install.currentSlug();
        const label = switch (model.install.phase) {
            .manifest => i18n.t("Looking up pets\u{2026}", "ペットを検索中\u{2026}"),
            // The pet.json leg is a few hundred bytes and flashes past,
            // so both download legs read as one "Downloading" step
            // rather than flickering between two labels.
            .pet_json, .spritesheet => i18n.bufPrint(&install_label_buf, "Downloading {s}\u{2026}", "{s}をダウンロード中\u{2026}", .{slug}) catch i18n.t("Downloading pet", "ペットをダウンロード中"),
            .idle => unreachable,
        };
        return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .gap = 10, .cross = .center }, .{
                ui.el(.spinner, .{ .width = 16, .height = 16, .semantics = .{ .label = i18n.t("Installing", "インストール中") } }, .{}),
                ui.text(.{ .size = .sm }, label),
            }),
        });
    }
    if (model.install.error_len > 0) {
        var message = ui.text(.{ .size = .sm }, model.install.errorSlice());
        message.widget.style.foreground = app.petdexThemeTokens(model).colors.destructive;
        return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .gap = 10, .cross = .center }, .{
                ui.column(.{ .grow = 1 }, .{message}),
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .dismiss_install_error }, i18n.t("Dismiss", "閉じる")),
            }),
        });
    }
    return ui.el(.stack, .{}, .{});
}

fn agentsSection(ui: *AppUi, model: *const Model, icons: IconAtlas) AppUi.Node {
    var rows: [agent_hooks.agent_count]AppUi.Node = undefined;
    var count: usize = 0;
    for (model.agents, 0..) |info, i| {
        if (info.status == .absent) continue;
        const trailing = if (info.kind == .dsh and model.dsh_busy)
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, i18n.t("Working", "処理中"))
        else if (info.kind == .dsh and info.status == .node)
            ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, i18n.t("Restart DSH", "DSHを再起動"))
        else if (info.status == .current)
            ui.button(.{
                .size = .sm,
                .variant = .secondary,
                .on_press = Msg{ .uninstall_agent = @intCast(i) },
            }, i18n.t("Disconnect", "接続解除"))
        else
            ui.button(.{
                .size = .sm,
                .variant = .primary,
                .on_press = Msg{ .install_agent = @intCast(i) },
            }, if (info.status == .node) i18n.t("Update", "アップデート") else i18n.t("Install", "インストール"));
        var logo = ui.image(.{
            .width = 24,
            .height = 24,
            .image = if (icons.ready) icons.image else 0,
            .semantics = .{ .label = info.kind.displayName() },
        });
        logo.widget.image_src = icons.rect(@intFromEnum(info.kind));
        logo.widget.image_fit = .contain;
        rows[count] = ui.el(.panel, .{
            .padding = 12,
            .gap = 12,
            .cross = .center,
            .style_tokens = .{ .background = .surface, .radius = .md },
            .semantics = .{ .label = info.kind.displayName() },
        }, .{
            ui.row(.{ .gap = 12, .cross = .center }, .{
                logo,
                ui.column(.{ .grow = 1, .main = .center }, .{
                    ui.text(.{}, info.kind.displayName()),
                    mutedParagraph(ui, agentStatusCaption(info, model.codex_trust_note, model.dsh_busy, model.dsh_error)),
                }),
                trailing,
            }),
        });
        count += 1;
    }
    if (count == 0) {
        return ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, i18n.t("No coding agents detected on this machine", "コーディングエージェントが見つかりません")),
        });
    }
    return ui.column(.{ .gap = 12 }, @as([]const AppUi.Node, rows[0..count]));
}

fn herdrSection(ui: *AppUi, model: *const Model, icons: IconAtlas) AppUi.Node {
    if (model.herdr_status == .absent) return ui.el(.stack, .{}, .{});
    var logo = ui.image(.{
        .width = 24,
        .height = 24,
        .image = if (icons.ready) icons.image else 0,
        .semantics = .{ .label = "Herdr" },
    });
    logo.widget.image_src = icons.rect(app.herdr_icon_index);
    logo.widget.image_fit = .contain;
    return ui.el(.panel, .{
        .padding = 12,
        .gap = 12,
        .cross = .center,
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = "Herdr" },
    }, .{
        ui.row(.{ .gap = 12, .cross = .center }, .{
            logo,
            ui.column(.{ .grow = 1, .main = .center }, .{
                ui.text(.{}, "Herdr"),
                mutedParagraph(ui, model.herdr_status.caption()),
            }),
        }),
    });
}

/// SSH remotes running agents whose hooks ride the reverse tunnel.
/// Read-only by design: remotes are declared in
/// ~/.petdex/remote-agents.json and the section only reports what the
/// runtime is doing with them. Hidden entirely when nothing is
/// configured. A user without the feature gets no noise.
fn remoteSection(ui: *AppUi, model: *const Model) AppUi.Node {
    if (model.remote_count == 0) return ui.el(.stack, .{}, .{});
    var rows: [remote_runtime.max_remotes]AppUi.Node = undefined;
    var count: usize = 0;
    for (model.remotes[0..model.remote_count]) |*slot| {
        if (!slot.active) continue;
        rows[count] = ui.el(.panel, .{
            .padding = 12,
            .gap = 12,
            .cross = .center,
            .style_tokens = .{ .background = .surface, .radius = .md },
            .semantics = .{ .label = slot.nameSlice() },
        }, .{
            ui.row(.{ .gap = 12, .cross = .center }, .{
                ui.column(.{ .grow = 1, .main = .center }, .{
                    ui.text(.{}, slot.nameSlice()),
                    mutedParagraph(ui, remote_runtime.statusCaption(slot)),
                }),
                ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, slot.host[0..slot.host_len]),
            }),
        });
        count += 1;
    }
    if (count == 0) return ui.el(.stack, .{}, .{});
    const heading = ui.text(.{ .size = .lg }, i18n.t("Remote Agents", "リモートエージェント"));
    const hint = mutedParagraph(ui, i18n.t("Declared in ~/.petdex/remote-agents.json; sync runs at launch", "~/.petdex/remote-agents.jsonで設定します。同期は起動時に行います"));
    const list = ui.column(.{ .gap = 12 }, @as([]const AppUi.Node, rows[0..count]));
    return ui.column(.{ .gap = 12 }, .{ heading, hint, list });
}

var update_status_buf: [96]u8 = undefined;

fn updatesSection(ui: *AppUi, model: *const Model) AppUi.Node {
    const latest = model.latest_version[0..model.latest_version_len];
    const version_status = switch (model.update_phase) {
        .idle => i18n.bufPrint(&update_status_buf, "{s} · Not checked yet", "{s} · 未確認", .{app.updates.current_version}) catch app.updates.current_version,
        .checking => i18n.bufPrint(&update_status_buf, "{s} · Checking…", "{s} · 確認中…", .{app.updates.current_version}) catch app.updates.current_version,
        .current => i18n.bufPrint(&update_status_buf, "{s} · Up to date", "{s} · 最新", .{app.updates.current_version}) catch app.updates.current_version,
        .available => i18n.bufPrint(&update_status_buf, "{s} installed · {s} available", "{s}をインストール済み · {s}が利用可能", .{ app.updates.current_version, latest }) catch app.updates.current_version,
        .failed => i18n.bufPrint(&update_status_buf, "{s} · Check failed", "{s} · 確認に失敗", .{app.updates.current_version}) catch app.updates.current_version,
    };
    const version_action = if (model.update_phase == .available)
        if (model.install_source == .homebrew)
            ui.button(.{ .variant = .primary, .on_press = .copy_brew_command }, if (model.brew_command_copied) i18n.t("Copied", "コピーしました") else i18n.t("Copy brew upgrade command", "brew upgradeのコマンドをコピー"))
        else
            ui.button(.{ .variant = .primary, .on_press = .download_update }, i18n.t("Download update", "アップデートをダウンロード"))
    else
        ui.button(.{ .variant = .secondary, .on_press = .check_updates, .disabled = model.update_phase == .checking or model.update_cancel_pending }, i18n.t("Check now", "今すぐ確認"));
    const warning_title = if (builtin.os.tag == .macos and model.install_source == .homebrew)
        i18n.t("Homebrew manages updates", "アップデートはHomebrewで管理")
    else
        i18n.t("Updates stay manual", "アップデートは手動");
    const warning_copy = if (builtin.os.tag == .macos)
        if (model.install_source == .homebrew)
            i18n.t("Petdex never runs Brew for you. Update with brew upgrade --cask petdex.", "PetdexがBrewを実行することはありません。brew upgrade --cask petdexでアップデートしてください。")
        else
            i18n.t("Petdex never replaces itself. Homebrew users should install the petdex cask first.", "Petdexが自分自身を置き換えることはありません。Homebrewをお使いの場合は、先にpetdexのcaskをインストールしてください。")
    else
        i18n.t("Petdex can download a release, but never replaces itself automatically.", "Petdexはリリースをダウンロードできますが、自動で置き換えることはありません。");
    var warning = ui.el(.panel, .{ .padding = 12, .style_tokens = .{ .radius = .md } }, .{
        ui.column(.{ .gap = 4 }, .{
            ui.text(.{}, warning_title),
            mutedParagraph(ui, warning_copy),
        }),
    });
    warning.widget.style.background = if (model.dark) canvas.Color.rgb8(48, 38, 22) else canvas.Color.rgb8(255, 246, 214);
    return ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .lg }, i18n.t("Updates", "アップデート")),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Current version", "現在のバージョン")),
                    mutedParagraph(ui, version_status),
                }),
                version_action,
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Check automatically", "自動で確認")),
                    mutedParagraph(ui, i18n.t("Quietly checks once per day", "1日に1回、バックグラウンドで確認します")),
                }),
                ui.el(.switch_control, .{
                    .selected = model.update_checks_enabled,
                    .on_toggle = .toggle_update_checks,
                    .semantics = .{ .label = i18n.t("Check for updates automatically", "アップデートを自動で確認") },
                }, .{}),
            }),
        }),
        warning,
    });
}

fn cloudStatus(status: app.desktop_auth.PetStatus) []const u8 {
    return switch (status) {
        .pending => i18n.t("Pending review", "審査待ち"),
        .approved => i18n.t("Yours", "作成したペット"),
        .rejected => i18n.t("Needs changes", "修正が必要"),
        .caught => i18n.t("Caught", "捕まえたペット"),
    };
}

fn cloudPetRow(ui: *AppUi, pet: *const app.desktop_auth.Pet, cloud_id: u32, preview_cell: ?usize, images: CloudImages) AppUi.Node {
    const installed = catalog_mod.catalogIndexOf(pet.slugSlice()) != null;
    const usable = pet.status == .approved or pet.status == .caught;
    // 「インストール」 is six full-width characters.
    const width: f32 = if (i18n.current == .ja) 84 else 64;
    const action = if (!usable)
        ui.button(.{ .size = .sm, .width = width, .variant = .secondary, .disabled = true }, i18n.t("Review", "審査中"))
    else if (installed)
        ui.button(.{ .size = .sm, .width = width, .variant = .primary, .on_press = Msg{ .auth_install_pet = cloud_id } }, i18n.t("Select", "選択"))
    else
        ui.button(.{ .size = .sm, .width = width, .variant = .primary, .on_press = Msg{ .auth_install_pet = cloud_id } }, i18n.t("Install", "インストール"));
    const cell = preview_cell orelse images.preview_ready.len;
    var thumb = ui.image(.{
        .width = 40,
        .height = 44,
        .image = if (cell < images.preview_ready.len and images.preview_ready[cell]) images.preview_image else 0,
        .semantics = .{ .label = pet.displayName() },
    });
    if (cell < images.preview_ready.len) {
        thumb.widget.image_src = geometry.RectF.init(
            @as(f32, @floatFromInt(cell % images.preview_columns)) * images.preview_cell,
            @as(f32, @floatFromInt(cell / images.preview_columns)) * images.preview_cell,
            images.preview_cell,
            images.preview_cell,
        );
    }
    thumb.widget.image_fit = .contain;
    thumb.widget.image_sampling = .nearest;
    return ui.el(.list_item, .{
        .height = 56,
        .padding = 8,
        .gap = 12,
        .cross = .center,
        .style_tokens = .{ .background = .surface, .radius = .md },
        .semantics = .{ .label = pet.displayName() },
    }, .{
        thumb,
        ui.column(.{ .width = 150, .main = .center }, .{
            ui.text(.{}, pet.displayName()),
            mutedParagraph(ui, cloudStatus(pet.status)),
        }),
        action,
        ui.button(.{ .size = .sm, .width = 54, .variant = .secondary, .on_press = Msg{ .auth_open_pet = cloud_id } }, i18n.t("Open", "開く")),
    });
}

fn cloudLibrarySection(ui: *AppUi, model: *const Model, images: CloudImages) AppUi.Node {
    const auth = &model.auth;
    const action = switch (auth.phase) {
        .signed_out, .failed => ui.button(.{ .size = .sm, .variant = .primary, .on_press = .auth_sign_in }, if (auth.phase == .failed) i18n.t("Try again", "再試行") else i18n.t("Sign in", "サインイン")),
        .signed_in => ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_refresh }, i18n.t("Sync", "同期")),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_sign_out }, i18n.t("Sign out", "サインアウト")),
        }),
        .loading, .authorizing, .exchanging, .syncing => ui.el(.spinner, .{ .width = 18, .height = 18, .semantics = .{ .label = i18n.t("Working", "処理中") } }, .{}),
        .unavailable => ui.button(.{ .size = .sm, .variant = .secondary, .disabled = true }, i18n.t("macOS only", "macOSのみ")),
    };
    const title = if (auth.phase == .signed_in and auth.name_len > 0) auth.nameSlice() else i18n.t("My Petdex", "マイPetdex");
    const caption = switch (auth.phase) {
        .signed_out => i18n.t("See pets you created and caught", "作成したペットと捕まえたペットを表示"),
        .loading => i18n.t("Checking for a saved Petdex session", "保存済みのPetdexセッションを確認中"),
        .authorizing => i18n.t("Finish signing in in your browser", "ブラウザでサインインを完了してください"),
        .exchanging => i18n.t("Completing secure sign-in", "サインインを完了中"),
        .syncing => i18n.t("Syncing your Petdex library", "Petdexライブラリを同期中"),
        .signed_in => if (auth.email_len > 0) auth.emailSlice() else i18n.t("Your cloud pet library", "クラウドのペットライブラリ"),
        .failed => if (auth.error_len > 0) auth.errorSlice() else i18n.t("Petdex sign-in failed", "Petdexにサインインできませんでした"),
        .unavailable => i18n.t("Account sync currently uses macOS Keychain", "アカウントの同期は今のところmacOSのキーチェーンでのみ使えます"),
    };
    var avatar = ui.image(.{
        .width = 36,
        .height = 36,
        .image = if (auth.phase == .signed_in and images.avatar_ready) images.avatar_image else 0,
        .semantics = .{ .label = i18n.t("Profile photo", "プロフィール写真") },
    });
    avatar.widget.image_fit = .cover;
    avatar.widget.style.radius = 18;
    return ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            if (auth.phase == .signed_in) avatar else ui.el(.stack, .{}, .{}),
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, title),
                mutedParagraph(ui, caption),
            }),
            action,
        }),
    });
}

fn petsTop(ui: *AppUi, model: *const Model, filter: []const u8) AppUi.Node {
    const search = ui.el(.search_field, .{
        .height = 34,
        .text = filter,
        .on_input = AppUi.inputMsg(.pet_filter),
        .placeholder = i18n.t("Search pets", "ペットを検索"),
        .semantics = .{ .label = i18n.t("Search pets", "ペットを検索") },
    }, .{});
    const filters = ui.row(.{ .gap = 6 }, .{
        ui.button(.{ .size = .sm, .variant = if (model.pet_source == .installed) .primary else .secondary, .on_press = Msg{ .set_pet_source = @intFromEnum(app.desktop_auth.LibraryView.installed) } }, i18n.t("Installed", "インストール済み")),
        ui.button(.{ .size = .sm, .variant = if (model.pet_source == .yours) .primary else .secondary, .disabled = model.auth.phase != .signed_in, .on_press = Msg{ .set_pet_source = @intFromEnum(app.desktop_auth.LibraryView.yours) } }, i18n.t("Yours", "作成した")),
        ui.button(.{ .size = .sm, .variant = if (model.pet_source == .caught) .primary else .secondary, .disabled = model.auth.phase != .signed_in, .on_press = Msg{ .set_pet_source = @intFromEnum(app.desktop_auth.LibraryView.caught) } }, i18n.t("Caught", "捕まえた")),
        ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_open_community }, i18n.t("Community", "コミュニティ")),
    });
    if (model.install.busy() or model.install.error_len > 0) {
        return ui.column(.{ .gap = 8 }, .{
            ui.text(.{ .size = .lg }, i18n.t("Pets", "ペット")),
            filters,
            installBanner(ui, model),
            search,
        });
    }
    return ui.column(.{ .gap = 8 }, .{
        ui.text(.{ .size = .lg }, i18n.t("Pets", "ペット")),
        filters,
        search,
    });
}

/// Auto follows the system language. English and 日本語 are named in their
/// own language, so either can be found whatever the UI speaks.
fn languagePanel(ui: *AppUi, model: *const Model) AppUi.Node {
    const caption = if (builtin.os.tag != .macos and !custom_font_active.* and model.language != .en)
        i18n.t("Japanese needs a Japanese font in Custom font file below", "日本語を表示するには、下の「カスタムフォントファイル」に日本語フォントを指定してください")
    else if (builtin.os.tag == .macos)
        i18n.t("Auto follows your system language; the menu bar changes after a restart", "自動はシステムの言語に合わせます。メニューバーは再起動後に切り替わります")
    else
        i18n.t("Auto follows your system language", "自動はシステムの言語に合わせます");
    var buttons: [3]AppUi.Node = undefined;
    for (&buttons, [_]i18n.Pref{ .auto, .en, .ja }) |*button, pref| button.* = ui.button(.{
        .size = .sm,
        .variant = if (model.language == pref) .primary else .secondary,
        .on_press = Msg{ .set_language = @intFromEnum(pref) },
    }, switch (pref) {
        .auto => i18n.t("Auto", "自動"),
        .en => "English",
        .ja => "日本語",
    });
    return ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, i18n.t("Language", "言語")),
                mutedParagraph(ui, caption),
            }),
            ui.row(.{ .gap = 6 }, @as([]const AppUi.Node, &buttons)),
        }),
    });
}

/// Auto follows the system's appearance; Light and Dark keep one look.
/// The menus stay the system's either way.
fn themePanel(ui: *AppUi, model: *const Model) AppUi.Node {
    var buttons: [3]AppUi.Node = undefined;
    for (&buttons, [_]app.ThemePref{ .auto, .light, .dark }) |*button, pref| button.* = ui.button(.{
        .size = .sm,
        .variant = if (model.theme == pref) .primary else .secondary,
        .on_press = Msg{ .set_theme = @intFromEnum(pref) },
    }, switch (pref) {
        .auto => i18n.t("Auto", "自動"),
        .light => i18n.t("Light", "ライト"),
        .dark => i18n.t("Dark", "ダーク"),
    });
    return ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
        ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
            ui.column(.{ .grow = 1 }, .{
                ui.text(.{}, i18n.t("Appearance", "外観モード")),
                mutedParagraph(ui, i18n.t("Auto follows your system's appearance", "自動はシステムの外観に合わせます")),
            }),
            ui.row(.{ .gap = 6 }, @as([]const AppUi.Node, &buttons)),
        }),
    });
}

pub fn settingsView(ui: *AppUi, model: *const Model, icons: IconAtlas, thumbs: ThumbAtlas, cloud_images: CloudImages) AppUi.Node {
    var rows: [max_catalog]AppUi.Node = undefined;
    var shown: usize = 0;
    var matches: usize = 0;
    const max_visible: usize = if (model.pet_source == .installed and model.pets_expanded) max_catalog else 6;
    const filter = model.pet_filter[0..model.pet_filter_len];
    if (model.pet_source == .installed) {
        for (catalog[0..@min(catalog_mod.catalog_len, max_catalog)], 0..) |*entry, i| {
            if (!petMatchesFilter(entry.slice(), filter)) continue;
            matches += 1;
            if (shown >= max_visible) continue;
            const active = i == model.active_pet;
            var thumb = ui.image(.{
                .width = 40,
                .height = 44,
                .image = if (thumbs.ready[i]) thumbs.image else 0,
                .semantics = .{ .label = entry.slice() },
            });
            thumb.widget.image_src = geometry.RectF.init(
                @as(f32, @floatFromInt(i)) * thumbs.cell_w,
                0,
                thumbs.cell_w,
                thumbs.cell_h,
            );
            thumb.widget.image_fit = .contain;
            thumb.widget.image_sampling = .nearest;
            rows[shown] = ui.el(.list_item, .{
                .height = 56,
                .padding = 8,
                .gap = 12,
                .cross = .center,
                .on_press = Msg{ .select_pet = @intCast(i) },
                .selected = active,
                .style_tokens = .{ .background = .surface, .radius = .md },
                .semantics = .{ .label = entry.slice() },
            }, .{
                thumb,
                ui.column(.{ .grow = 1, .main = .center }, .{
                    ui.text(.{}, entry.slice()),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, entry.rootSlice()),
                }),
                if (active)
                    ui.button(.{ .size = .sm, .width = 64, .variant = .primary, .disabled = true }, i18n.t("Active", "使用中"))
                else
                    ui.button(.{ .size = .sm, .width = 64, .variant = .primary, .on_press = Msg{ .select_pet = @intCast(i) } }, i18n.t("Select", "選択")),
                ui.button(.{ .size = .sm, .variant = .secondary, .on_press = Msg{ .open_pet_page = @intCast(i) } }, i18n.t("Open", "開く")),
            });
            shown += 1;
        }
    } else {
        const pets = if (model.pet_source == .yours) model.auth.owned[0..model.auth.owned_len] else model.auth.caught[0..model.auth.caught_len];
        for (pets, 0..) |*pet, i| {
            if (!petMatchesFilter(pet.displayName(), filter) and !petMatchesFilter(pet.slugSlice(), filter)) continue;
            matches += 1;
            if (shown >= max_visible) continue;
            const caught_offset: usize = if (model.pet_source == .caught) app.desktop_auth.max_pets else 0;
            const preview_offset: usize = if (model.pet_source == .caught) 6 else 0;
            rows[shown] = cloudPetRow(
                ui,
                pet,
                @intCast(caught_offset + i),
                if (i < 6) preview_offset + i else null,
                cloud_images,
            );
            shown += 1;
        }
    }
    const scale_fraction: f32 = (model.scale - app.min_scale) / (app.max_scale - app.min_scale);
    const bubble_text_fraction: f32 = (model.bubble_text_px - bubble_text_min_px) / (bubble_text_max_px - bubble_text_min_px);
    // One scrollable page: the root scroll takes the window frame and
    // everything - full pet catalog included - flows inside it. No
    // more per-section band budgets.
    const page = ui.scroll(.{ .grow = 1, .value = model.settings_scroll, .on_scroll = AppUi.scrollMsg(.settings_scrolled) }, .{ui.column(.{ .padding = 12, .gap = 10 }, .{
        cloudLibrarySection(ui, model, cloud_images),
        petsTop(ui, model, filter),
        // Search-first catalog: six rows collapsed, the whole catalog
        // expanded - the page itself scrolls, so no nested scroll and
        // the extent stays exact.
        ui.column(.{ .gap = 6 }, @as([]const AppUi.Node, rows[0..shown])),
        if (model.pet_source == .installed and matches > shown)
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .toggle_pets_expanded }, moreLabel(matches))
        else if (model.pet_source == .installed and model.pets_expanded and matches > 6)
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .toggle_pets_expanded }, i18n.t("Show less", "表示を減らす"))
        else if (model.pet_source != .installed and matches > shown)
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .auth_open_library }, i18n.t("Open all on Petdex", "Petdexですべて開く"))
        else if (matches == 0)
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, if (model.pet_source == .installed) i18n.t("No installed pets match your search", "一致するインストール済みのペットはありません") else i18n.t("No pets match your search", "一致するペットはありません"))
        else
            ui.el(.stack, .{}, .{}),
        ui.el(.stack, .{ .height = 10 }, .{}),
        ui.text(.{ .size = .lg }, i18n.t("Agents", "エージェント")),
        agentsSection(ui, model, icons),
        herdrSection(ui, model, icons),
        remoteSection(ui, model),
        ui.el(.stack, .{ .height = 10 }, .{}),
        chat_view.settingsSection(ui, model),
        ui.el(.stack, .{ .height = 10 }, .{}),
        ui.text(.{ .size = .lg }, i18n.t("Appearance", "外観")),
        languagePanel(ui, model),
        themePanel(ui, model),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Pet size", "ペットの大きさ")),
                    mutedParagraph(ui, i18n.t("Adjust the size of your pet", "ペットの表示サイズを調整します")),
                }),
                ui.el(.slider, .{ .width = 150, .value = scale_fraction, .on_value = AppUi.valueMsg(.set_scale), .semantics = .{ .label = i18n.t("Pet size", "ペットの大きさ") } }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Bubble text size", "吹き出しの文字サイズ")),
                    mutedParagraph(ui, i18n.t("Size of the bubble text", "吹き出しに表示する文字の大きさ")),
                }),
                ui.el(.slider, .{ .width = 150, .value = bubble_text_fraction, .on_value = AppUi.valueMsg(.set_bubble_text_size), .semantics = .{ .label = i18n.t("Bubble text size", "吹き出しの文字サイズ") } }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.column(.{ .padding = 12, .gap = 8 }, .{
                ui.text(.{}, i18n.t("Custom font file", "カスタムフォントファイル")),
                mutedParagraph(ui, if (model.font_load_failed)
                    i18n.t("Could not load this TrueType font; the default font is active", "このTrueTypeフォントを読み込めませんでした。標準のフォントを使用しています")
                else if (model.font_path_dirty)
                    i18n.t("Saved; restart Petdex to apply", "保存しました。Petdexを再起動すると反映されます")
                else if (custom_font_active.*)
                    i18n.t("Applied to all app text; restart after changing the path", "アプリのすべての文字に適用中。パスを変えたら再起動してください")
                else
                    i18n.t("Optional local .ttf path; leave empty for the default font", "ローカルの.ttfファイルのパス。空欄なら標準のフォントを使います")),
                ui.el(.input, .{
                    .height = 34,
                    .text = model.font_path.text(),
                    .on_input = AppUi.inputMsg(.font_path_input),
                    .placeholder = "/path/to/font.ttf",
                    .semantics = .{ .label = i18n.t("Custom font file path", "カスタムフォントファイルのパス") },
                }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Show messages", "メッセージを表示")),
                    mutedParagraph(ui, i18n.t("Agent activity bubbles over the pet", "エージェントの動きをペットの吹き出しで表示")),
                }),
                ui.el(.switch_control, .{
                    .selected = model.bubbles_enabled,
                    .on_toggle = .toggle_bubbles,
                    .semantics = .{ .label = i18n.t("Show messages", "メッセージを表示") },
                }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("One bubble per conversation", "会話ごとに吹き出しを分ける")),
                    mutedParagraph(ui, i18n.t("A bubble for each agent; off shows one bubble at a time", "エージェントごとにバブルを出します。オフにするとバブルは1つだけになります")),
                }),
                ui.el(.switch_control, .{
                    .selected = model.bubbles_per_conversation,
                    .on_toggle = .toggle_bubbles_per_conversation,
                    .semantics = .{ .label = i18n.t("One bubble per conversation", "会話ごとに吹き出しを分ける") },
                }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Bubble lifetime", "吹き出しの表示時間")),
                    mutedParagraph(ui, i18n.t("0 keeps bubbles visible; 1–60 seconds enables expiry", "0で表示し続けます。1〜60秒を指定すると自動で消えます")),
                }),
                ui.el(.input, .{
                    .width = 72,
                    .height = 34,
                    .text = model.bubble_lifetime_text[0..model.bubble_lifetime_text_len],
                    .on_input = AppUi.inputMsg(.bubble_lifetime_input),
                    .semantics = .{ .label = i18n.t("Bubble lifetime in seconds", "吹き出しの表示秒数") },
                }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Rotate pet daily", "毎日ペットを入れ替える")),
                    mutedParagraph(ui, i18n.t("Wake up to a different pet each day", "毎日違うペットに会えます")),
                }),
                ui.el(.switch_control, .{
                    .selected = model.rotate_pets,
                    .on_toggle = .toggle_rotate_pets,
                    .semantics = .{ .label = i18n.t("Rotate pet daily", "毎日ペットを入れ替える") },
                }, .{}),
            }),
        }),
        // Login items ride SMAppService, so like the Dock row this one
        // only exists on macOS.
        if (builtin.os.tag == .macos)
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, i18n.t("Launch at login", "ログイン時に起動")),
                        mutedParagraph(ui, i18n.t("Start Petdex when you log in", "ログインしたときにPetdexを起動します")),
                    }),
                    ui.el(.switch_control, .{
                        .selected = model.launch_at_login,
                        .on_toggle = .toggle_launch_at_login,
                        .semantics = .{ .label = i18n.t("Launch at login", "ログイン時に起動") },
                    }, .{}),
                }),
            })
        else
            ui.el(.stack, .{}, .{}),
        // Dock presence is an AppKit concept; other platforms have no
        // equivalent toggle to offer, so the row only exists on macOS.
        if (builtin.os.tag == .macos)
            ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
                ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                    ui.column(.{ .grow = 1 }, .{
                        ui.text(.{}, i18n.t("Hide Dock icon", "Dockにアイコンを表示しない")),
                        mutedParagraph(ui, i18n.t("Petdex lives in the menu bar only", "Petdexはメニューバーにだけ表示されます")),
                    }),
                    ui.el(.switch_control, .{
                        .selected = model.hide_dock,
                        .on_toggle = .toggle_hide_dock,
                        .semantics = .{ .label = i18n.t("Hide Dock icon", "Dockにアイコンを表示しない") },
                    }, .{}),
                }),
            })
        else
            ui.el(.stack, .{}, .{}),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Waiting sound", "待機中の通知音")),
                    mutedParagraph(ui, i18n.t("Play a chime when your agent is waiting for your input", "エージェントが入力を待っているときにチャイムを鳴らします")),
                }),
                ui.el(.switch_control, .{
                    .selected = model.waiting_sound,
                    .on_toggle = .toggle_waiting_sound,
                    .semantics = .{ .label = i18n.t("Waiting sound", "待機中の通知音") },
                }, .{}),
            }),
        }),
        ui.el(.panel, .{ .style_tokens = .{ .background = .surface, .radius = .md } }, .{
            ui.row(.{ .padding = 12, .cross = .center, .gap = 12 }, .{
                ui.column(.{ .grow = 1 }, .{
                    ui.text(.{}, i18n.t("Custom pets", "カスタムペット")),
                    ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "~/.petdex/pets"),
                }),
                ui.button(.{ .on_press = .open_pets_folder }, i18n.t("Open folder", "フォルダを開く")),
            }),
        }),
        ui.el(.stack, .{ .height = 10 }, .{}),
        updatesSection(ui, model),
        // Trailing spacer: the column's own bottom padding is not part
        // of the scroll extent, so the last card needs explicit air.
        ui.el(.stack, .{ .height = 8 }, .{}),
    })});
    var root = ui.column(.{ .grow = 1 }, .{
        ui.el(.stack, .{ .height = companion_header_h, .window_drag = true }, .{}),
        page,
    });
    root.widget.style.background = settingsBackground(model);
    return root;
}

test "settings descriptions use wrapped paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());

    const copy = "A description long enough to wrap beside a control";
    const node = mutedParagraph(&ui, copy);
    try std.testing.expectEqual(@as(usize, 1), node.widget.spans.len);
    try std.testing.expectEqualStrings(copy, node.widget.text);
    try std.testing.expect(!node.widget.text_no_wrap);
}

test "DSH command errors do not ask for a global pnpm install" {
    const info = agent_hooks.AgentInfo{ .kind = .dsh, .status = .none };
    try std.testing.expectEqualStrings(
        "Plugin command failed - check npx and network",
        agentStatusCaption(info, false, false, true),
    );
}
