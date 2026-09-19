//! MCP config install/detect for agents that speak Model Context Protocol.
//!
//! Automatic lifecycle notifications use hooks/plugins (agent_hooks.zig).
//! MCP supplies optional manual tools using the server bundled with this
//! desktop build. Node 20+ is needed for these optional tools, never for
//! native hooks; no npm registry lookup is involved.
//!
//! Config shapes differ (JSON `mcpServers`, OpenCode `mcp.*`, Codex/Grok
//! TOML `[mcp_servers.*]`), but every writer preserves foreign entries and
//! only owns the `petdex` key.

const std = @import("std");
const plat = @import("plat.zig");

pub const McpAgent = enum(u8) {
    claude_code,
    codex,
    gemini,
    cursor,
    junie,
    antigravity,
    opencode,
    devin,
    grok,
    copilot,
    windsurf,
    amp,
    droid,

    pub fn displayName(self: McpAgent) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .codex => "Codex",
            .gemini => "Gemini CLI",
            .cursor => "Cursor",
            .junie => "Junie",
            .antigravity => "Antigravity",
            .opencode => "opencode",
            .devin => "Devin",
            .grok => "Grok",
            .copilot => "Copilot CLI",
            .windsurf => "Windsurf / Devin Desktop",
            .amp => "Amp",
            .droid => "Droid",
        };
    }

    pub fn agentEnv(self: McpAgent) []const u8 {
        return switch (self) {
            .claude_code => "claude-code",
            .codex => "codex",
            .gemini => "gemini",
            .cursor => "cursor",
            .junie => "junie",
            .antigravity => "antigravity",
            .opencode => "opencode",
            .devin => "devin",
            .grok => "grok",
            .copilot => "copilot",
            .windsurf => "windsurf",
            .amp => "amp",
            .droid => "droid",
        };
    }
};

pub const agent_count = @typeInfo(McpAgent).@"enum".fields.len;

pub const Status = enum(u8) {
    absent,
    none,
    current,
};

pub const AgentInfo = struct {
    kind: McpAgent,
    status: Status = .absent,
};

const server_name = "petdex";
const mcp_command = "node";
// Bundled with this desktop build, independent of the published npm CLI.
const mcp_args = [_][]const u8{ "--input-type=commonjs", "-e", "import(require('node:url').pathToFileURL(require('node:path').join(require('node:os').homedir(),'.petdex','bin','petdex-mcp-server.mjs')).href)" };
const server_asset = @embedFile("assets/petdex-mcp-server.mjs");

/// Config-root env overrides, snapshotted once in main() from environ_map
/// (agent_hooks uses the same pattern for its own vars; Zig 0.16 has no
/// global getenv). Skipping one repeats the #601 blind spot: the entry is
/// written where that agent never reads, and the row stays "not installed"
/// after a successful Install.
pub var env_claude_config_dir: ?[]const u8 = null;
pub var env_codex_home: ?[]const u8 = null;
pub var env_gemini_cli_home: ?[]const u8 = null;
pub var env_junie_home: ?[]const u8 = null;
pub var env_xdg_config_home: ?[]const u8 = null;
pub var env_appdata: ?[]const u8 = null;
pub var env_grok_home: ?[]const u8 = null;
pub var env_copilot_home: ?[]const u8 = null;

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn dirExists(path: []const u8) bool {
    return plat.dirExists(path);
}

fn fileExists(path: []const u8) bool {
    return plat.fileExists(path);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    // plat's bounded reader returns a prefix. Config editors must never turn
    // that prefix into a replacement file and silently discard the tail.
    const bytes = plat.readFileAlloc(allocator, path, max + 1) orelse {
        if (plat.fileSize(path)) |size| {
            if (size == 0) return allocator.alloc(u8, 0) catch null;
        }
        return null;
    };
    if (bytes.len > max) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

fn writeFile(path: []const u8, contents: []const u8) bool {
    return plat.writeFile(path, contents);
}

fn ensureParentDir(path: []const u8) bool {
    const dir = std.fs.path.dirname(path) orelse return true;
    plat.makeDir(dir);
    return true;
}

fn backupBeside(path: []const u8) void {
    var bak_buf: [576]u8 = undefined;
    const bak = std.fmt.bufPrint(&bak_buf, "{s}.petdex-bak", .{path}) catch return;
    if (fileExists(bak)) return;
    const allocator = std.heap.page_allocator;
    const src = readFileAlloc(allocator, path, 1024 * 1024) orelse return;
    defer allocator.free(src);
    _ = plat.writeFile(bak, src);
}

/// The directory whose existence marks the agent as installed and which owns
/// its config file. agent_hooks resolves hook-side paths through this too so
/// the two writers can never disagree about which root an env var picked.
/// CLAUDE_CONFIG_DIR, CODEX_HOME, JUNIE_HOME and GROK_HOME replace the whole
/// root; GEMINI_CLI_HOME replaces the home directory so the `.gemini` leaf
/// still applies; opencode's global config follows XDG_CONFIG_HOME.
pub fn presenceDir(buf: []u8, home: []const u8, kind: McpAgent) ?[]const u8 {
    return switch (kind) {
        .claude_code => if (nonEmpty(env_claude_config_dir)) |dir|
            std.fmt.bufPrint(buf, "{s}", .{dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.claude", .{home}) catch null,
        .codex => if (nonEmpty(env_codex_home)) |dir|
            std.fmt.bufPrint(buf, "{s}", .{dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.codex", .{home}) catch null,
        .gemini => if (nonEmpty(env_gemini_cli_home)) |dir|
            std.fmt.bufPrint(buf, "{s}/.gemini", .{dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.gemini", .{home}) catch null,
        .copilot => if (nonEmpty(env_copilot_home)) |dir| std.fmt.bufPrint(buf, "{s}", .{dir}) catch null else std.fmt.bufPrint(buf, "{s}/.copilot", .{home}) catch null,
        .windsurf => std.fmt.bufPrint(buf, "{s}/.codeium/windsurf", .{home}) catch null,
        .amp => if (nonEmpty(env_xdg_config_home)) |dir| std.fmt.bufPrint(buf, "{s}/amp", .{dir}) catch null else std.fmt.bufPrint(buf, "{s}/.config/amp", .{home}) catch null,
        .droid => std.fmt.bufPrint(buf, "{s}/.factory", .{home}) catch null,
        .cursor => std.fmt.bufPrint(buf, "{s}/.cursor", .{home}) catch null,
        .junie => if (nonEmpty(env_junie_home)) |dir|
            std.fmt.bufPrint(buf, "{s}", .{dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.junie", .{home}) catch null,
        .antigravity => std.fmt.bufPrint(buf, "{s}/.gemini", .{home}) catch null,
        .opencode => if (nonEmpty(env_xdg_config_home)) |dir|
            std.fmt.bufPrint(buf, "{s}/opencode", .{dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.config/opencode", .{home}) catch null,
        .devin => if (@import("builtin").os.tag == .windows)
            if (nonEmpty(env_appdata)) |dir| std.fmt.bufPrint(buf, "{s}/devin", .{dir}) catch null else std.fmt.bufPrint(buf, "{s}/AppData/Roaming/devin", .{home}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.config/devin", .{home}) catch null,
        .grok => if (nonEmpty(env_grok_home)) |dir|
            std.fmt.bufPrint(buf, "{s}", .{dir}) catch null
        else
            std.fmt.bufPrint(buf, "{s}/.grok", .{home}) catch null,
    };
}

fn configPath(buf: []u8, home: []const u8, kind: McpAgent) ?[]const u8 {
    // Claude's MCP file sits next to the config dir, not inside it: `~/.claude.json`
    // by default, or `<dir>/.claude.json` when CLAUDE_CONFIG_DIR relocates
    // the install.
    if (kind == .claude_code) {
        const base = nonEmpty(env_claude_config_dir) orelse home;
        return std.fmt.bufPrint(buf, "{s}/.claude.json", .{base}) catch null;
    }
    var root_buf: [512]u8 = undefined;
    const root = presenceDir(&root_buf, home, kind) orelse return null;
    return switch (kind) {
        .codex, .grok => std.fmt.bufPrint(buf, "{s}/config.toml", .{root}) catch null,
        .gemini => std.fmt.bufPrint(buf, "{s}/settings.json", .{root}) catch null,
        .cursor, .droid => std.fmt.bufPrint(buf, "{s}/mcp.json", .{root}) catch null,
        .copilot => std.fmt.bufPrint(buf, "{s}/mcp-config.json", .{root}) catch null,
        .windsurf => std.fmt.bufPrint(buf, "{s}/mcp_config.json", .{root}) catch null,
        .amp => std.fmt.bufPrint(buf, "{s}/settings.json", .{root}) catch null,
        .junie => std.fmt.bufPrint(buf, "{s}/mcp/mcp.json", .{root}) catch null,
        // Prefer the shared Antigravity 2.0 path; fall back is handled at install.
        .antigravity => std.fmt.bufPrint(buf, "{s}/config/mcp_config.json", .{root}) catch null,
        .opencode => std.fmt.bufPrint(buf, "{s}/opencode.json", .{root}) catch null,
        .devin => std.fmt.bufPrint(buf, "{s}/mcp_config.json", .{root}) catch null,
        .claude_code => unreachable,
    };
}

fn antigravityLegacyPath(buf: []u8, home: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.gemini/antigravity/mcp_config.json", .{home}) catch null;
}

fn opencodeJsoncPath(buf: []u8, home: []const u8) ?[]const u8 {
    var root_buf: [512]u8 = undefined;
    const root = presenceDir(&root_buf, home, .opencode) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/opencode.jsonc", .{root}) catch null;
}

fn devinLegacyConfigPath(buf: []u8, home: []const u8) ?[]const u8 {
    var root_buf: [512]u8 = undefined;
    const root = presenceDir(&root_buf, home, .devin) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/config.json", .{root}) catch null;
}

fn usesTomlMcp(kind: McpAgent) bool {
    return kind == .codex or kind == .grok;
}

fn serversKey(kind: McpAgent) []const u8 {
    return if (kind == .amp) "amp.mcpServers" else "mcpServers";
}

fn stdioEntryJson(kind: McpAgent, buf: []u8) ?[]const u8 {
    if (kind == .copilot) return std.fmt.bufPrint(buf,
        \\{{"type":"local","command":"{s}","args":["{s}","{s}","{s}"],"env":{{"PETDEX_MCP_AGENT":"copilot"}},"tools":["*"]}}
    , .{ mcp_command, mcp_args[0], mcp_args[1], mcp_args[2] }) catch null;
    return std.fmt.bufPrint(
        buf,
        \\{{"command":"{s}","args":["{s}","{s}","{s}"],"env":{{"PETDEX_MCP_AGENT":"{s}"}}}}
    ,
        .{ mcp_command, mcp_args[0], mcp_args[1], mcp_args[2], kind.agentEnv() },
    ) catch null;
}

fn opencodeEntryJson(kind: McpAgent, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        \\{{"type":"local","command":["{s}","{s}","{s}","{s}"],"enabled":true,"environment":{{"PETDEX_MCP_AGENT":"{s}"}}}}
    ,
        .{ mcp_command, mcp_args[0], mcp_args[1], mcp_args[2], kind.agentEnv() },
    ) catch null;
}

/// V2 shape: `mcp.servers.<name>` entries speak `disabled` rather than
/// `enabled`, and the strict schema rejects unknown keys — so the mirror
/// entry must not carry the V1 field.
fn opencodeEntryJsonV2(kind: McpAgent, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        \\{{"type":"local","command":["{s}","{s}","{s}","{s}"],"environment":{{"PETDEX_MCP_AGENT":"{s}"}}}}
    ,
        .{ mcp_command, mcp_args[0], mcp_args[1], mcp_args[2], kind.agentEnv() },
    ) catch null;
}

fn entryLooksCurrent(entry: std.json.Value, kind: McpAgent) bool {
    if (entry != .object) return false;
    if (kind == .copilot) {
        const transport = entry.object.get("type") orelse return false;
        if (transport != .string or !std.mem.eql(u8, transport.string, "local")) return false;
        const allowed = entry.object.get("tools") orelse return false;
        if (allowed != .array) return false;
        var all = false;
        for (allowed.array.items) |tool| {
            if (tool == .string and std.mem.eql(u8, tool.string, "*")) all = true;
        }
        if (!all) return false;
    }
    if (entry.object.get("disabled")) |v| {
        if (v != .bool or v.bool) return false;
    }
    if (entry.object.get("enabled")) |v| {
        if (v != .bool or !v.bool) return false;
    }
    if (kind != .copilot) {
        if (entry.object.get("type")) |v| {
            if (v != .string or !std.mem.eql(u8, v.string, "stdio")) return false;
        }
    }
    const command = entry.object.get("command") orelse return false;
    if (command != .string or !std.mem.eql(u8, command.string, mcp_command)) return false;
    const args = entry.object.get("args") orelse return false;
    if (args != .array or args.array.items.len != 3) return false;
    if (args.array.items[0] != .string or !std.mem.eql(u8, args.array.items[0].string, mcp_args[0])) return false;
    if (args.array.items[1] != .string or !std.mem.eql(u8, args.array.items[1].string, mcp_args[1])) return false;
    if (args.array.items[2] != .string or !std.mem.eql(u8, args.array.items[2].string, mcp_args[2])) return false;
    const env = entry.object.get("env") orelse return false;
    if (env != .object) return false;
    const agent = env.object.get("PETDEX_MCP_AGENT") orelse return false;
    return agent == .string and std.mem.eql(u8, agent.string, kind.agentEnv());
}

fn opencodeEntryLooksCurrent(entry: std.json.Value, kind: McpAgent) bool {
    if (entry != .object) return false;
    if (entry.object.get("disabled")) |v| {
        if (v != .bool or v.bool) return false;
    }
    if (entry.object.get("enabled")) |v| {
        if (v != .bool or !v.bool) return false;
    }
    const typ = entry.object.get("type") orelse return false;
    if (typ != .string or !std.mem.eql(u8, typ.string, "local")) return false;
    const command = entry.object.get("command") orelse return false;
    if (command != .array or command.array.items.len != 4) return false;
    if (command.array.items[0] != .string or !std.mem.eql(u8, command.array.items[0].string, mcp_command)) return false;
    if (command.array.items[1] != .string or !std.mem.eql(u8, command.array.items[1].string, mcp_args[0])) return false;
    if (command.array.items[2] != .string or !std.mem.eql(u8, command.array.items[2].string, mcp_args[1])) return false;
    if (command.array.items[3] != .string or !std.mem.eql(u8, command.array.items[3].string, mcp_args[2])) return false;
    const env = entry.object.get("environment") orelse return false;
    if (env != .object) return false;
    const agent = env.object.get("PETDEX_MCP_AGENT") orelse return false;
    return agent == .string and std.mem.eql(u8, agent.string, kind.agentEnv());
}

fn jsonHasPetdex(content: []const u8, kind: McpAgent, allocator: std.mem.Allocator) Status {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .none;
    defer parsed.deinit();
    if (parsed.value != .object) return .none;
    const servers = parsed.value.object.get(serversKey(kind)) orelse return .none;
    if (servers != .object) return .none;
    const entry = servers.object.get(server_name) orelse return .none;
    return if (entryLooksCurrent(entry, kind)) .current else .none;
}

fn opencodeHasPetdex(content: []const u8, kind: McpAgent, allocator: std.mem.Allocator) Status {
    return opencodeOverrideStatus(content, kind, allocator) orelse .none;
}

/// A higher-precedence file with no Petdex entry preserves the lower one.
/// An explicit disabled, old or malformed entry must override it instead.
fn opencodeOverrideStatus(content: []const u8, kind: McpAgent, allocator: std.mem.Allocator) ?Status {
    var parsed = parseJsonc(allocator, content) catch return .none;
    defer parsed.deinit();
    if (parsed.value != .object) return .none;
    const mcp = parsed.value.object.get("mcp") orelse return null;
    if (mcp != .object) return .none;
    // V2: mcp.servers.petdex — V1 (current docs): mcp.petdex
    if (mcp.object.get("servers")) |servers| {
        if (servers == .object) {
            if (servers.object.get(server_name)) |entry| {
                return if (opencodeEntryLooksCurrent(entry, kind)) .current else .none;
            }
        }
    }
    if (mcp.object.get(server_name)) |entry| {
        return if (opencodeEntryLooksCurrent(entry, kind)) .current else .none;
    }
    return null;
}

fn tomlHasPetdex(content: []const u8, kind: McpAgent) Status {
    var buf: [1024]u8 = undefined;
    const expected = tomlMcpBlock(kind, &buf) orelse return .none;
    var expected_lines = std.mem.tokenizeAny(u8, expected, "\n\r");
    var expected_table: TomlTable = .other;
    while (expected_lines.next()) |line| {
        if (line[0] == '[') {
            expected_table = tomlTable(line);
            continue;
        }
        var found = false;
        var actual_table: TomlTable = .other;
        var lines = std.mem.tokenizeAny(u8, content, "\n\r");
        while (lines.next()) |actual| {
            const trimmed = std.mem.trim(u8, actual, " \t");
            if (trimmed.len > 0 and trimmed[0] == '[') actual_table = tomlTable(trimmed);
            if (actual_table == expected_table and std.mem.eql(u8, trimmed, line)) {
                found = true;
                break;
            }
        }
        if (!found) return .none;
    }
    var in_petdex = false;
    var lines = std.mem.tokenizeAny(u8, content, "\n\r");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "[")) in_petdex = tomlTable(line) == .server;
        if (in_petdex and std.mem.startsWith(u8, line, "enabled")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .none;
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.startsWith(u8, value, "false")) return .none;
        }
    }
    return .current;
}

const TomlTable = enum { other, server, env, child };

/// Recognize the table we own, including quoted keys and trailing comments.
fn tomlTable(raw: []const u8) TomlTable {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len < 2 or line[0] != '[' or line[1] == '[') return .other;
    const end = std.mem.indexOfScalar(u8, line, ']') orelse return .other;
    const tail = std.mem.trim(u8, line[end + 1 ..], " \t");
    if (tail.len != 0 and tail[0] != '#') return .other;
    var keys = std.mem.splitScalar(u8, line[1..end], '.');
    const first = std.mem.trim(u8, keys.next() orelse return .other, " \t\"'");
    const second = std.mem.trim(u8, keys.next() orelse return .other, " \t\"'");
    if (!std.mem.eql(u8, first, "mcp_servers") or !std.mem.eql(u8, second, "petdex")) return .other;
    const third = std.mem.trim(u8, keys.next() orelse return .server, " \t\"'");
    return if (std.mem.eql(u8, third, "env") and keys.next() == null) .env else .child;
}

/// True when any Antigravity surface has run here. `~/.gemini` is shared
/// with plain Gemini CLI, so its existence alone proves nothing; the AGY
/// family owns these subdirs. `agy` has no relocation env yet
/// (google-antigravity/antigravity-cli#155), so the root stays fixed.
pub fn antigravityPresent(home: []const u8) bool {
    const subs = [_][]const u8{ "antigravity", "antigravity-cli", "antigravity-ide", "config" };
    for (subs) |sub| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.gemini/{s}", .{ home, sub }) catch continue;
        if (dirExists(path)) return true;
    }
    return false;
}

pub fn scanOne(allocator: std.mem.Allocator, home: []const u8, kind: McpAgent) Status {
    var dir_buf: [512]u8 = undefined;
    if (kind == .antigravity) {
        if (!antigravityPresent(home)) return .absent;
    } else {
        const dir = presenceDir(&dir_buf, home, kind) orelse return .absent;
        if (!dirExists(dir)) return .absent;
    }

    var path_buf: [576]u8 = undefined;
    if (kind == .antigravity) {
        if (configPath(&path_buf, home, kind)) |path| {
            if (readFileAlloc(allocator, path, 512 * 1024)) |content| {
                defer allocator.free(content);
                const status = jsonHasPetdex(content, kind, allocator);
                if (status == .current) return .current;
            }
        }
        var legacy_buf: [576]u8 = undefined;
        if (antigravityLegacyPath(&legacy_buf, home)) |legacy| {
            if (readFileAlloc(allocator, legacy, 512 * 1024)) |content| {
                defer allocator.free(content);
                return jsonHasPetdex(content, kind, allocator);
            }
        }
        return .none;
    }

    if (kind == .opencode) {
        // OpenCode merges .json then .jsonc. Inspect the effective Petdex
        // override first, rather than reporting a shadowed .json as current.
        var jsonc_buf: [576]u8 = undefined;
        if (opencodeJsoncPath(&jsonc_buf, home)) |jsonc| {
            if (readFileAlloc(allocator, jsonc, 512 * 1024)) |content| {
                defer allocator.free(content);
                if (opencodeOverrideStatus(content, kind, allocator)) |status| return status;
            } else if (fileExists(jsonc)) return .none;
        }
        if (configPath(&path_buf, home, kind)) |path| {
            if (readFileAlloc(allocator, path, 512 * 1024)) |content| {
                defer allocator.free(content);
                return opencodeHasPetdex(content, kind, allocator);
            }
        }
        return .none;
    }

    if (kind == .devin) {
        if (configPath(&path_buf, home, kind)) |path| {
            if (readFileAlloc(allocator, path, 512 * 1024)) |content| {
                defer allocator.free(content);
                const status = jsonHasPetdex(content, kind, allocator);
                if (status == .current) return .current;
            }
        }
        var legacy_buf: [576]u8 = undefined;
        if (devinLegacyConfigPath(&legacy_buf, home)) |legacy| {
            if (readFileAlloc(allocator, legacy, 512 * 1024)) |content| {
                defer allocator.free(content);
                return jsonHasPetdex(content, kind, allocator);
            }
        }
        return .none;
    }

    const path = configPath(&path_buf, home, kind) orelse return .none;
    const content = readFileAlloc(allocator, path, 512 * 1024) orelse return .none;
    defer allocator.free(content);
    return if (usesTomlMcp(kind)) tomlHasPetdex(content, kind) else jsonHasPetdex(content, kind, allocator);
}

pub fn scan(allocator: std.mem.Allocator, home: []const u8) [agent_count]AgentInfo {
    var out: [agent_count]AgentInfo = .{
        .{ .kind = .claude_code },
        .{ .kind = .codex },
        .{ .kind = .gemini },
        .{ .kind = .cursor },
        .{ .kind = .junie },
        .{ .kind = .antigravity },
        .{ .kind = .opencode },
        .{ .kind = .devin },
        .{ .kind = .grok },
        .{ .kind = .copilot },
        .{ .kind = .windsurf },
        .{ .kind = .amp },
        .{ .kind = .droid },
    };
    for (&out) |*info| {
        info.status = scanOne(allocator, home, info.kind);
    }
    return out;
}

fn mergeJsonMcpServers(allocator: std.mem.Allocator, existing: ?[]const u8, kind: McpAgent) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root: std.json.Value = .{ .object = std.json.ObjectMap.init(a, &.{}, &.{}) catch return null };
    if (existing) |bytes| {
        if (bytes.len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return null;
            if (parsed.value != .object) return null;
            root = parsed.value;
        }
    }

    const servers_entry = root.object.getOrPut(a, serversKey(kind)) catch return null;
    if (!servers_entry.found_existing) {
        servers_entry.value_ptr.* = .{ .object = std.json.ObjectMap.init(a, &.{}, &.{}) catch return null };
    } else if (servers_entry.value_ptr.* != .object) return null;

    var entry_buf: [1024]u8 = undefined;
    const entry_json = stdioEntryJson(kind, &entry_buf) orelse return null;
    const entry_parsed = std.json.parseFromSlice(std.json.Value, a, entry_json, .{}) catch return null;
    servers_entry.value_ptr.object.put(a, server_name, entry_parsed.value) catch return null;

    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 }) catch null;
}

fn mergeOpencodeMcp(allocator: std.mem.Allocator, existing: ?[]const u8, kind: McpAgent) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root: std.json.Value = .{ .object = std.json.ObjectMap.init(a, &.{}, &.{}) catch return null };
    if (existing) |bytes| {
        if (bytes.len > 0) {
            const parsed = parseJsonc(a, bytes) catch return null;
            if (parsed.value != .object) return null;
            root = parsed.value;
        }
    }

    const mcp_entry = root.object.getOrPut(a, "mcp") catch return null;
    if (!mcp_entry.found_existing) {
        mcp_entry.value_ptr.* = .{ .object = std.json.ObjectMap.init(a, &.{}, &.{}) catch return null };
        // New configs use current OpenCode V2. Existing V1 maps stay V1.
        mcp_entry.value_ptr.object.put(a, "servers", .{ .object = std.json.ObjectMap.init(a, &.{}, &.{}) catch return null }) catch return null;
    } else if (mcp_entry.value_ptr.* != .object) return null;

    var entry_buf: [1024]u8 = undefined;
    const entry_json = opencodeEntryJson(kind, &entry_buf) orelse return null;
    const entry_parsed = std.json.parseFromSlice(std.json.Value, a, entry_json, .{}) catch return null;

    if (mcp_entry.value_ptr.object.getPtr("servers")) |servers| {
        if (servers.* != .object) return null;
        _ = mcp_entry.value_ptr.object.orderedRemove(server_name);
        // Removal may invalidate a map pointer; acquire it again.
        const target = mcp_entry.value_ptr.object.getPtr("servers").?;
        var v2_buf: [1024]u8 = undefined;
        const v2_json = opencodeEntryJsonV2(kind, &v2_buf) orelse return null;
        const again = std.json.parseFromSlice(std.json.Value, a, v2_json, .{}) catch return null;
        target.object.put(a, server_name, again.value) catch return null;
    } else {
        mcp_entry.value_ptr.object.put(a, server_name, entry_parsed.value) catch return null;
    }

    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 }) catch null;
}

fn stripJsonPetdex(allocator: std.mem.Allocator, existing: []const u8, kind: McpAgent) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, a, existing, .{}) catch return null;
    if (parsed.value != .object) return null;
    var root = parsed.value;
    for ([_][]const u8{serversKey(kind)}) |key| {
        if (root.object.getPtr(key)) |servers| {
            if (servers.* == .object) {
                _ = servers.object.orderedRemove(server_name);
                if (servers.object.count() == 0) _ = root.object.orderedRemove(key);
            }
        }
    }
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 }) catch null;
}

fn stripOpencodePetdex(allocator: std.mem.Allocator, existing: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = parseJsonc(a, existing) catch return null;
    if (parsed.value != .object) return null;
    var root = parsed.value;
    if (root.object.getPtr("mcp")) |mcp| {
        if (mcp.* == .object) {
            _ = mcp.object.orderedRemove(server_name);
            if (mcp.object.getPtr("servers")) |servers| {
                if (servers.* == .object) {
                    _ = servers.object.orderedRemove(server_name);
                    if (servers.object.count() == 0) _ = mcp.object.orderedRemove("servers");
                }
            }
            if (mcp.object.count() == 0) _ = root.object.orderedRemove("mcp");
        }
    }
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 }) catch null;
}

fn installJson(allocator: std.mem.Allocator, path: []const u8, kind: McpAgent) bool {
    if (!ensureParentDir(path)) return false;
    const existing = readFileAlloc(allocator, path, 1024 * 1024);
    defer if (existing) |e| allocator.free(e);
    if (existing == null and fileExists(path)) return false;
    const merged = mergeJsonMcpServers(allocator, existing, kind) orelse return false;
    defer allocator.free(merged);
    if (existing) |_| backupBeside(path);
    return writeFile(path, merged);
}

fn installOpencodeJson(allocator: std.mem.Allocator, path: []const u8, kind: McpAgent) bool {
    if (!ensureParentDir(path)) return false;
    const existing = readFileAlloc(allocator, path, 1024 * 1024);
    defer if (existing) |e| allocator.free(e);
    if (existing == null and fileExists(path)) return false;
    const merged = mergeOpencodeMcp(allocator, existing, kind) orelse return false;
    defer allocator.free(merged);
    if (existing) |_| backupBeside(path);
    return writeFile(path, merged);
}

fn uninstallJson(allocator: std.mem.Allocator, path: []const u8, kind: McpAgent) bool {
    const existing = readFileAlloc(allocator, path, 1024 * 1024) orelse return !fileExists(path);
    defer allocator.free(existing);
    const stripped = stripJsonPetdex(allocator, existing, kind) orelse return false;
    defer allocator.free(stripped);
    backupBeside(path);
    return writeFile(path, stripped);
}

fn uninstallOpencodeJson(allocator: std.mem.Allocator, path: []const u8) bool {
    const existing = readFileAlloc(allocator, path, 1024 * 1024) orelse return !fileExists(path);
    defer allocator.free(existing);
    const stripped = stripOpencodePetdex(allocator, existing) orelse return false;
    defer allocator.free(stripped);
    backupBeside(path);
    return writeFile(path, stripped);
}

fn tomlMcpBlock(kind: McpAgent, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        \\
        \\[mcp_servers.petdex]
        \\command = "{s}"
        \\args = ["{s}", "{s}", "{s}"]
        \\
        \\[mcp_servers.petdex.env]
        \\PETDEX_MCP_AGENT = "{s}"
        \\
    ,
        .{ mcp_command, mcp_args[0], mcp_args[1], mcp_args[2], kind.agentEnv() },
    ) catch null;
}

fn stripTomlPetdex(out: *std.array_list.Managed(u8), content: []const u8) bool {
    out.clearRetainingCapacity();
    var line_start: usize = 0;
    var skipping = false;
    while (line_start <= content.len) {
        const relative_end = std.mem.indexOfScalar(u8, content[line_start..], '\n');
        const line_end = if (relative_end) |end| line_start + end else content.len;
        const line = content[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            skipping = tomlTable(trimmed) != .other;
        }
        if (!skipping) {
            out.appendSlice(line) catch return false;
            if (relative_end != null) out.append('\n') catch return false;
        }
        if (relative_end == null) break;
        line_start = line_end + 1;
    }
    return true;
}

fn installTomlMcp(allocator: std.mem.Allocator, path: []const u8, kind: McpAgent) bool {
    if (!ensureParentDir(path)) return false;
    const existing = readFileAlloc(allocator, path, 1024 * 1024);
    defer if (existing) |e| allocator.free(e);
    if (existing == null and fileExists(path)) return false;

    var cleaned = std.array_list.Managed(u8).init(allocator);
    defer cleaned.deinit();
    if (existing) |content| {
        if (!stripTomlPetdex(&cleaned, content)) return false;
    }

    var block_buf: [1024]u8 = undefined;
    const block = tomlMcpBlock(kind, &block_buf) orelse return false;
    cleaned.appendSlice(block) catch return false;
    if (existing) |_| backupBeside(path);
    return writeFile(path, cleaned.items);
}

fn uninstallTomlMcp(allocator: std.mem.Allocator, path: []const u8) bool {
    const existing = readFileAlloc(allocator, path, 1024 * 1024) orelse return !fileExists(path);
    defer allocator.free(existing);
    var cleaned = std.array_list.Managed(u8).init(allocator);
    defer cleaned.deinit();
    if (!stripTomlPetdex(&cleaned, existing)) return false;
    backupBeside(path);
    return writeFile(path, cleaned.items);
}

/// Keep the stable launch path on the desktop's bundled version after upgrades.
/// This writes only Petdex's own asset, never host configuration.
pub fn refreshServer(home: []const u8) bool {
    var asset_buf: [768]u8 = undefined;
    const asset = std.fmt.bufPrint(&asset_buf, "{s}/.petdex/bin/petdex-mcp-server.mjs", .{home}) catch return false;
    if (!ensureParentDir(asset)) return false;
    return plat.writeFileMode(asset, server_asset, 0o600);
}

pub fn install(allocator: std.mem.Allocator, home: []const u8, kind: McpAgent) bool {
    if (!refreshServer(home)) return false;
    var path_buf: [576]u8 = undefined;
    return switch (kind) {
        .codex, .grok => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            break :blk installTomlMcp(allocator, path, kind);
        },
        .antigravity => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            var legacy_buf: [576]u8 = undefined;
            const legacy = antigravityLegacyPath(&legacy_buf, home) orelse break :blk false;
            if (!fileExists(path) and fileExists(legacy)) break :blk installJson(allocator, legacy, kind);
            break :blk installJson(allocator, path, kind);
        },
        .opencode => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            var jsonc_buf: [576]u8 = undefined;
            const jsonc = opencodeJsoncPath(&jsonc_buf, home) orelse break :blk false;
            // JSONC wins when both exist in OpenCode. Never create a shadow file.
            break :blk installOpencodeJson(allocator, if (fileExists(jsonc)) jsonc else path, kind);
        },
        else => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            break :blk installJson(allocator, path, kind);
        },
    };
}

pub fn uninstall(allocator: std.mem.Allocator, home: []const u8, kind: McpAgent) bool {
    var path_buf: [576]u8 = undefined;
    return switch (kind) {
        .codex, .grok => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            break :blk uninstallTomlMcp(allocator, path);
        },
        .antigravity => blk: {
            var ok = true;
            if (configPath(&path_buf, home, kind)) |path| {
                if (fileExists(path)) ok = uninstallJson(allocator, path, kind) and ok;
            }
            var legacy_buf: [576]u8 = undefined;
            if (antigravityLegacyPath(&legacy_buf, home)) |legacy| {
                if (fileExists(legacy)) ok = uninstallJson(allocator, legacy, kind) and ok;
            }
            break :blk ok;
        },
        .opencode => blk: {
            var ok = true;
            if (configPath(&path_buf, home, kind)) |path| {
                if (fileExists(path)) ok = uninstallOpencodeJson(allocator, path) and ok;
            }
            var jsonc_buf: [576]u8 = undefined;
            if (opencodeJsoncPath(&jsonc_buf, home)) |jsonc| {
                if (fileExists(jsonc)) ok = uninstallOpencodeJson(allocator, jsonc) and ok;
            }
            break :blk ok;
        },
        .devin => blk: {
            var ok = true;
            if (configPath(&path_buf, home, kind)) |path| {
                if (fileExists(path)) ok = uninstallJson(allocator, path, kind) and ok;
            }
            var legacy_buf: [576]u8 = undefined;
            if (devinLegacyConfigPath(&legacy_buf, home)) |legacy| {
                if (fileExists(legacy)) ok = uninstallJson(allocator, legacy, kind) and ok;
            }
            break :blk ok;
        },
        else => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            if (!fileExists(path)) break :blk true;
            break :blk uninstallJson(allocator, path, kind);
        },
    };
}

/// Map a hook AgentKind name onto an MCP target when one exists.
pub fn fromHookName(name: []const u8) ?McpAgent {
    if (std.mem.eql(u8, name, "claude-code") or std.mem.eql(u8, name, "claude_code")) return .claude_code;
    if (std.mem.eql(u8, name, "codex")) return .codex;
    if (std.mem.eql(u8, name, "gemini")) return .gemini;
    if (std.mem.eql(u8, name, "cursor") or std.mem.eql(u8, name, "cursor-agent")) return .cursor;
    if (std.mem.eql(u8, name, "junie")) return .junie;
    if (std.mem.eql(u8, name, "antigravity")) return .antigravity;
    if (std.mem.eql(u8, name, "opencode") or std.mem.eql(u8, name, "open-code")) return .opencode;
    if (std.mem.eql(u8, name, "devin")) return .devin;
    if (std.mem.eql(u8, name, "grok")) return .grok;
    return null;
}

test "json merge keeps foreign servers" {
    const t = std.testing;
    const a = t.allocator;
    const merged = mergeJsonMcpServers(a,
        \\{"mcpServers":{"other":{"command":"echo"}}}
    , .junie) orelse return error.TestUnexpectedResult;
    defer a.free(merged);
    try t.expect(std.mem.indexOf(u8, merged, "\"other\"") != null);
    try t.expect(std.mem.indexOf(u8, merged, "\"petdex\"") != null);
    try t.expect(std.mem.indexOf(u8, merged, "PETDEX_MCP_AGENT") != null);
    try t.expect(std.mem.indexOf(u8, merged, "junie") != null);
}

test "codex toml install and uninstall roundtrip" {
    const t = std.testing;
    const a = t.allocator;
    const home = ".zig-cache/petdex-agent-mcp-codex";
    plat.makeDir(home ++ "/.codex");
    plat.deleteFile(home ++ "/.codex/config.toml");

    try t.expect(install(a, home, .codex));
    try t.expectEqual(Status.current, scanOne(a, home, .codex));

    var path_buf: [576]u8 = undefined;
    const path = configPath(&path_buf, home, .codex).?;
    const written = readFileAlloc(a, path, 64 * 1024).?;
    defer a.free(written);
    try t.expect(std.mem.indexOf(u8, written, "[mcp_servers.petdex]") != null);
    try t.expect(std.mem.indexOf(u8, written, "PETDEX_MCP_AGENT") != null);

    try t.expect(uninstall(a, home, .codex));
    try t.expectEqual(Status.none, scanOne(a, home, .codex));
}

test "cursor mcp json install detects current" {
    const t = std.testing;
    const a = t.allocator;
    const home = ".zig-cache/petdex-agent-mcp-cursor";
    plat.makeDir(home ++ "/.cursor");
    plat.deleteFile(home ++ "/.cursor/mcp.json");

    try t.expectEqual(Status.none, scanOne(a, home, .cursor));
    try t.expect(install(a, home, .cursor));
    try t.expectEqual(Status.current, scanOne(a, home, .cursor));
    try t.expect(uninstall(a, home, .cursor));
    try t.expectEqual(Status.none, scanOne(a, home, .cursor));
}

test "opencode mcp uses local command array shape" {
    const t = std.testing;
    const a = t.allocator;
    const home = ".zig-cache/petdex-agent-mcp-opencode";
    plat.makeDir(home ++ "/.config/opencode");
    plat.deleteFile(home ++ "/.config/opencode/opencode.json");

    try t.expect(install(a, home, .opencode));
    try t.expectEqual(Status.current, scanOne(a, home, .opencode));

    var path_buf: [576]u8 = undefined;
    const path = configPath(&path_buf, home, .opencode).?;
    const written = readFileAlloc(a, path, 64 * 1024).?;
    defer a.free(written);
    try t.expect(std.mem.indexOf(u8, written, "\"type\": \"local\"") != null or std.mem.indexOf(u8, written, "\"type\":\"local\"") != null);
    try t.expect(std.mem.indexOf(u8, written, "PETDEX_MCP_AGENT") != null);
    try t.expect(std.mem.indexOf(u8, written, "opencode") != null);

    try t.expect(uninstall(a, home, .opencode));
    try t.expectEqual(Status.none, scanOne(a, home, .opencode));
}

test "devin mcp_config and grok toml install" {
    const t = std.testing;
    const a = t.allocator;
    const home = ".zig-cache/petdex-agent-mcp-devin-grok";
    plat.makeDir(home ++ "/.config/devin");
    plat.makeDir(home ++ "/.grok");
    plat.deleteFile(home ++ "/.config/devin/mcp_config.json");
    plat.deleteFile(home ++ "/.grok/config.toml");

    try t.expect(install(a, home, .devin));
    try t.expectEqual(Status.current, scanOne(a, home, .devin));
    try t.expect(install(a, home, .grok));
    try t.expectEqual(Status.current, scanOne(a, home, .grok));

    try t.expect(uninstall(a, home, .devin));
    try t.expect(uninstall(a, home, .grok));
    try t.expectEqual(Status.none, scanOne(a, home, .devin));
    try t.expectEqual(Status.none, scanOne(a, home, .grok));
}

test "absent when agent home missing" {
    const t = std.testing;
    const a = t.allocator;
    const home = ".zig-cache/petdex-agent-mcp-absent";
    plat.makeDir(home);
    _ = plat.deleteTree(home ++ "/.junie");
    try t.expectEqual(Status.absent, scanOne(a, home, .junie));
}

/// JSONC comments/trailing commas are accepted only for OpenCode config.
/// String contents (URLs, escaped quotes, comment-looking text) are untouched.
fn parseJsonc(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    const clean = try a.dupe(u8, bytes);
    defer a.free(clean);
    var quoted = false;
    var escaped = false;
    var i: usize = 0;
    while (i < clean.len) : (i += 1) {
        const c = clean[i];
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') escaped = true else if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') {
            quoted = true;
            continue;
        }
        if (c == '/' and i + 1 < clean.len and clean[i + 1] == '/') {
            while (i < clean.len and clean[i] != '\n') : (i += 1) clean[i] = ' ';
        } else if (c == '/' and i + 1 < clean.len and clean[i + 1] == '*') {
            clean[i] = ' ';
            clean[i + 1] = ' ';
            i += 2;
            while (i + 1 < clean.len and !(clean[i] == '*' and clean[i + 1] == '/')) : (i += 1) clean[i] = ' ';
            if (i + 1 >= clean.len) return error.InvalidJsonc;
            clean[i] = ' ';
            clean[i + 1] = ' ';
            i += 1;
        }
    }
    quoted = false;
    escaped = false;
    for (clean, 0..) |c, pos| {
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') escaped = true else if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') {
            quoted = true;
            continue;
        }
        if (c == ',') {
            var next = pos + 1;
            while (next < clean.len and std.ascii.isWhitespace(clean[next])) : (next += 1) {}
            if (next < clean.len and (clean[next] == '}' or clean[next] == ']')) clean[pos] = ' ';
        }
    }
    return std.json.parseFromSlice(std.json.Value, a, clean, .{ .allocate = .alloc_always });
}

test "OpenCode JSONC and V2 remain one schema through install and removal" {
    const t = std.testing;
    const source = "{ // retained semantically\n\"mcp\":{\"servers\":{\"other\":{\"type\":\"remote\",\"url\":\"https://example.com/a//b\"},},},}";
    const merged = mergeOpencodeMcp(t.allocator, source, .opencode).?;
    defer t.allocator.free(merged);
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, merged, .{});
    defer parsed.deinit();
    const mcp = parsed.value.object.get("mcp").?.object;
    try t.expect(mcp.get("petdex") == null);
    const server = mcp.get("servers").?.object.get("petdex").?;
    try t.expect(server.object.get("enabled") == null);
    try t.expectEqual(Status.current, opencodeHasPetdex(merged, .opencode, t.allocator));
    const removed = stripOpencodePetdex(t.allocator, merged).?;
    defer t.allocator.free(removed);
    try t.expect(std.mem.indexOf(u8, removed, "https://example.com/a//b") != null);
    try t.expectEqual(Status.none, opencodeHasPetdex(removed, .opencode, t.allocator));
}

test "disabled and malformed MCP entries are never current" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var entry = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), stdioEntryJson(.devin, &buf).?, .{});
    try t.expect(entryLooksCurrent(entry, .devin));
    try entry.object.put(arena.allocator(), "disabled", .{ .bool = true });
    try t.expect(!entryLooksCurrent(entry, .devin));
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"command\":\"node\",\"args\":[null,1,{}]}", .{});
    try t.expect(!entryLooksCurrent(bad, .devin));
    const toml = tomlMcpBlock(.codex, &buf).?;
    const disabled = try std.mem.replaceOwned(u8, t.allocator, toml, "[mcp_servers.petdex]", "[mcp_servers.petdex]\nenabled = false");
    defer t.allocator.free(disabled);
    try t.expectEqual(Status.none, tomlHasPetdex(disabled, .codex));
    const wrong_table = try std.mem.replaceOwned(u8, t.allocator, toml, "command =", "[mcp_servers.other]\ncommand =");
    defer t.allocator.free(wrong_table);
    try t.expectEqual(Status.none, tomlHasPetdex(wrong_table, .codex));
    const quoted = try std.mem.replaceOwned(u8, t.allocator, toml, "[mcp_servers.petdex]", "[mcp_servers.\"petdex\"] # note");
    defer t.allocator.free(quoted);
    try t.expectEqual(Status.current, tomlHasPetdex(quoted, .codex));
    var cleaned = std.array_list.Managed(u8).init(t.allocator);
    defer cleaned.deinit();
    try t.expect(stripTomlPetdex(&cleaned, quoted));
    try t.expectEqualStrings("\n", cleaned.items);
}

test "OpenCode installation edits the active JSONC file without shadow JSON" {
    const t = std.testing;
    const home = ".zig-cache/petdex-mcp-jsonc-only";
    _ = plat.deleteTree(home);
    defer _ = plat.deleteTree(home);
    plat.makeDir(home ++ "/.config/opencode");
    try t.expect(writeFile(home ++ "/.config/opencode/opencode.jsonc", "{ /* note */ \"model\":\"test\",\"mcp\":{},}"));
    try t.expect(install(t.allocator, home, .opencode));
    try t.expect(!fileExists(home ++ "/.config/opencode/opencode.json"));
    try t.expectEqual(Status.current, scanOne(t.allocator, home, .opencode));
    try t.expect(uninstall(t.allocator, home, .opencode));
    try t.expectEqual(Status.none, scanOne(t.allocator, home, .opencode));
}

test "OpenCode diagnostics honor a JSONC override without hiding an inherited entry" {
    const t = std.testing;
    const home = ".zig-cache/petdex-mcp-jsonc-precedence";
    _ = plat.deleteTree(home);
    defer _ = plat.deleteTree(home);
    plat.makeDir(home ++ "/.config/opencode");
    try t.expect(install(t.allocator, home, .opencode));
    const jsonc = home ++ "/.config/opencode/opencode.jsonc";
    try t.expect(writeFile(jsonc, "{\"model\":\"another-model\"}"));
    try t.expectEqual(Status.current, scanOne(t.allocator, home, .opencode));
    try t.expect(writeFile(jsonc, "{\"mcp\":{\"servers\":{\"petdex\":{\"disabled\":true}}}}"));
    try t.expectEqual(Status.none, scanOne(t.allocator, home, .opencode));
    try t.expect(install(t.allocator, home, .opencode));
    try t.expectEqual(Status.current, scanOne(t.allocator, home, .opencode));
    try t.expect(writeFile(jsonc, "invalid jsonc"));
    try t.expectEqual(Status.none, scanOne(t.allocator, home, .opencode));
}

test "MCP removal never reports success for an unreadable existing configuration" {
    const t = std.testing;
    const home = ".zig-cache/petdex-mcp-unreadable";
    _ = plat.deleteTree(home);
    defer _ = plat.deleteTree(home);
    const large = try t.allocator.alloc(u8, 1024 * 1024 + 1);
    defer t.allocator.free(large);
    @memset(large, ' ');
    for ([_]McpAgent{ .cursor, .opencode, .codex }) |kind| {
        var path_buf: [576]u8 = undefined;
        const path = configPath(&path_buf, home, kind).?;
        try t.expect(writeFile(path, large));
        try t.expect(!install(t.allocator, home, kind));
        try t.expect(!uninstall(t.allocator, home, kind));
        const unchanged = readFileAlloc(t.allocator, path, large.len + 1).?;
        defer t.allocator.free(unchanged);
        try t.expectEqualSlices(u8, large, unchanged);
    }
}

test "MCP installation accepts an empty config and preserves the whole backup" {
    const t = std.testing;
    const home = ".zig-cache/petdex-mcp-backup";
    _ = plat.deleteTree(home);
    defer _ = plat.deleteTree(home);
    const path = home ++ "/.codex/config.toml";
    try t.expect(writeFile(path, ""));
    try t.expect(install(t.allocator, home, .codex));
    plat.deleteFile(path ++ ".petdex-bak");
    const large = try t.allocator.alloc(u8, 300 * 1024);
    defer t.allocator.free(large);
    @memset(large, ' ');
    const marker = "model = \"preserved-at-tail\"\n";
    @memcpy(large[large.len - marker.len ..], marker);
    try t.expect(writeFile(path, large));
    try t.expect(install(t.allocator, home, .codex));
    const backup = readFileAlloc(t.allocator, path ++ ".petdex-bak", large.len + 1).?;
    defer t.allocator.free(backup);
    try t.expectEqualSlices(u8, large, backup);
}

test "expanded MCP configs preserve foreign entries and round trip" {
    const t = std.testing;
    const home = ".zig-cache/petdex-expanded-mcp";
    _ = plat.deleteTree(home);
    defer _ = plat.deleteTree(home);
    for ([_]McpAgent{ .copilot, .windsurf, .amp, .droid }) |kind| {
        var dir_buf: [512]u8 = undefined;
        plat.makeDir(presenceDir(&dir_buf, home, kind).?);
        var path_buf: [512]u8 = undefined;
        const path = configPath(&path_buf, home, kind).?;
        const original = if (kind == .amp) "{\"amp.mcpServers\":{\"foreign\":{\"command\":\"my-tool\"}},\"theme\":\"dark\"}" else "{\"mcpServers\":{\"foreign\":{\"command\":\"my-tool\"}},\"theme\":\"dark\"}";
        try t.expect(plat.writeFile(path, original));
        try t.expect(install(t.allocator, home, kind));
        try t.expectEqual(Status.current, scanOne(t.allocator, home, kind));
        try t.expect(uninstall(t.allocator, home, kind));
        try t.expectEqual(Status.none, scanOne(t.allocator, home, kind));
        const removed = readFileAlloc(t.allocator, path, 1024 * 1024).?;
        defer t.allocator.free(removed);
        try t.expect(std.mem.indexOf(u8, removed, "my-tool") != null);
        try t.expect(std.mem.indexOf(u8, removed, "dark") != null);
    }
}
