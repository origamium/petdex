//! MCP config install/detect for agents that speak Model Context Protocol.
//!
//! Shell hooks remain for agents without a usable MCP surface. For Codex,
//! Claude Code, Gemini, Cursor, Junie and Antigravity the Connections
//! Install button writes an MCP server entry that launches
//! `npx -y petdex mcp-server` with `PETDEX_MCP_AGENT` set so bubbles and
//! usage land under the right logo.
//!
//! Config shapes differ (JSON `mcpServers` vs Codex TOML `[mcp_servers.*]`),
//! but every writer preserves foreign entries and only owns the `petdex` key.

const std = @import("std");
const plat = @import("plat.zig");

pub const McpAgent = enum(u8) {
    claude_code,
    codex,
    gemini,
    cursor,
    junie,
    antigravity,

    pub fn displayName(self: McpAgent) []const u8 {
        return switch (self) {
            .claude_code => "Claude Code",
            .codex => "Codex",
            .gemini => "Gemini CLI",
            .cursor => "Cursor",
            .junie => "Junie",
            .antigravity => "Antigravity",
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
const mcp_command = "npx";
const mcp_args = [_][]const u8{ "-y", "petdex", "mcp-server" };

fn dirExists(path: []const u8) bool {
    return plat.dirExists(path);
}

fn fileExists(path: []const u8) bool {
    return plat.fileExists(path);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    return plat.readFileAlloc(allocator, path, max);
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
    var src_buf: [256 * 1024]u8 = undefined;
    const src = plat.readFile(path, &src_buf) orelse return;
    _ = plat.writeFile(bak, src);
}

fn presenceDir(buf: []u8, home: []const u8, kind: McpAgent) ?[]const u8 {
    return switch (kind) {
        .claude_code => std.fmt.bufPrint(buf, "{s}/.claude", .{home}) catch null,
        .codex => std.fmt.bufPrint(buf, "{s}/.codex", .{home}) catch null,
        .gemini => std.fmt.bufPrint(buf, "{s}/.gemini", .{home}) catch null,
        .cursor => std.fmt.bufPrint(buf, "{s}/.cursor", .{home}) catch null,
        .junie => std.fmt.bufPrint(buf, "{s}/.junie", .{home}) catch null,
        .antigravity => std.fmt.bufPrint(buf, "{s}/.gemini", .{home}) catch null,
    };
}

fn configPath(buf: []u8, home: []const u8, kind: McpAgent) ?[]const u8 {
    return switch (kind) {
        .claude_code => std.fmt.bufPrint(buf, "{s}/.claude.json", .{home}) catch null,
        .codex => std.fmt.bufPrint(buf, "{s}/.codex/config.toml", .{home}) catch null,
        .gemini => std.fmt.bufPrint(buf, "{s}/.gemini/settings.json", .{home}) catch null,
        .cursor => std.fmt.bufPrint(buf, "{s}/.cursor/mcp.json", .{home}) catch null,
        .junie => std.fmt.bufPrint(buf, "{s}/.junie/mcp/mcp.json", .{home}) catch null,
        // Prefer the shared Antigravity 2.0 path; fall back is handled at install.
        .antigravity => std.fmt.bufPrint(buf, "{s}/.gemini/config/mcp_config.json", .{home}) catch null,
    };
}

fn antigravityLegacyPath(buf: []u8, home: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.gemini/antigravity/mcp_config.json", .{home}) catch null;
}

fn stdioEntryJson(kind: McpAgent, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        \\{{"command":"{s}","args":["{s}","{s}","{s}"],"env":{{"PETDEX_MCP_AGENT":"{s}"}}}}
    ,
        .{ mcp_command, mcp_args[0], mcp_args[1], mcp_args[2], kind.agentEnv() },
    ) catch null;
}

fn entryLooksCurrent(entry: std.json.Value, kind: McpAgent) bool {
    if (entry != .object) return false;
    const command = entry.object.get("command") orelse return false;
    if (command != .string or !std.mem.eql(u8, command.string, mcp_command)) return false;
    const args = entry.object.get("args") orelse return false;
    if (args != .array or args.array.items.len < 3) return false;
    if (!std.mem.eql(u8, args.array.items[0].string, mcp_args[0])) return false;
    if (!std.mem.eql(u8, args.array.items[1].string, mcp_args[1])) return false;
    if (!std.mem.eql(u8, args.array.items[2].string, mcp_args[2])) return false;
    const env = entry.object.get("env") orelse return true;
    if (env != .object) return false;
    const agent = env.object.get("PETDEX_MCP_AGENT") orelse return false;
    return agent == .string and std.mem.eql(u8, agent.string, kind.agentEnv());
}

fn jsonHasPetdex(content: []const u8, kind: McpAgent, allocator: std.mem.Allocator) Status {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return .none;
    defer parsed.deinit();
    if (parsed.value != .object) return .none;
    const servers = parsed.value.object.get("mcpServers") orelse return .none;
    if (servers != .object) return .none;
    const entry = servers.object.get(server_name) orelse return .none;
    return if (entryLooksCurrent(entry, kind)) .current else .none;
}

fn tomlHasPetdex(content: []const u8, kind: McpAgent) Status {
    const header = "[mcp_servers.petdex]";
    const idx = std.mem.indexOf(u8, content, header) orelse return .none;
    // Include the following [mcp_servers.petdex.env] table in the scan window.
    const rest = content[idx..];
    const next_foreign = blk: {
        var search_from: usize = header.len;
        while (search_from < rest.len) {
            const rel = std.mem.indexOfPos(u8, rest, search_from, "\n[") orelse break :blk rest.len;
            const line_start = rel + 1;
            const line_end = std.mem.indexOfScalar(u8, rest[line_start..], '\n') orelse rest.len - line_start;
            const line = std.mem.trim(u8, rest[line_start .. line_start + line_end], " \t\r");
            if (std.mem.eql(u8, line, "[mcp_servers.petdex.env]")) {
                search_from = line_start + line_end;
                continue;
            }
            break :blk rel;
        }
        break :blk rest.len;
    };
    const block = rest[0..next_foreign];
    if (std.mem.indexOf(u8, block, "mcp-server") == null) return .none;
    if (std.mem.indexOf(u8, block, "\"npx\"") == null and std.mem.indexOf(u8, block, "npx") == null) return .none;
    if (std.mem.indexOf(u8, block, kind.agentEnv()) == null) return .none;
    return .current;
}

pub fn scanOne(allocator: std.mem.Allocator, home: []const u8, kind: McpAgent) Status {
    var dir_buf: [512]u8 = undefined;
    const dir = presenceDir(&dir_buf, home, kind) orelse return .absent;
    if (!dirExists(dir)) return .absent;

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

    const path = configPath(&path_buf, home, kind) orelse return .none;
    const content = readFileAlloc(allocator, path, 512 * 1024) orelse return .none;
    defer allocator.free(content);
    return if (kind == .codex) tomlHasPetdex(content, kind) else jsonHasPetdex(content, kind, allocator);
}

pub fn scan(allocator: std.mem.Allocator, home: []const u8) [agent_count]AgentInfo {
    var out: [agent_count]AgentInfo = .{
        .{ .kind = .claude_code },
        .{ .kind = .codex },
        .{ .kind = .gemini },
        .{ .kind = .cursor },
        .{ .kind = .junie },
        .{ .kind = .antigravity },
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

    const servers_entry = root.object.getOrPut(a, "mcpServers") catch return null;
    if (!servers_entry.found_existing) {
        servers_entry.value_ptr.* = .{ .object = std.json.ObjectMap.init(a, &.{}, &.{}) catch return null };
    } else if (servers_entry.value_ptr.* != .object) return null;

    var entry_buf: [256]u8 = undefined;
    const entry_json = stdioEntryJson(kind, &entry_buf) orelse return null;
    const entry_parsed = std.json.parseFromSlice(std.json.Value, a, entry_json, .{}) catch return null;
    servers_entry.value_ptr.object.put(a, server_name, entry_parsed.value) catch return null;

    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 }) catch null;
}

fn stripJsonPetdex(allocator: std.mem.Allocator, existing: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, a, existing, .{}) catch return null;
    if (parsed.value != .object) return null;
    var root = parsed.value;
    if (root.object.getPtr("mcpServers")) |servers| {
        if (servers.* == .object) {
            _ = servers.object.orderedRemove(server_name);
            if (servers.object.count() == 0) _ = root.object.orderedRemove("mcpServers");
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

fn uninstallJson(allocator: std.mem.Allocator, path: []const u8) bool {
    const existing = readFileAlloc(allocator, path, 1024 * 1024) orelse return true;
    defer allocator.free(existing);
    const stripped = stripJsonPetdex(allocator, existing) orelse return false;
    defer allocator.free(stripped);
    backupBeside(path);
    return writeFile(path, stripped);
}

fn codexMcpBlock(kind: McpAgent, buf: []u8) ?[]const u8 {
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

fn stripCodexPetdex(out: *std.array_list.Managed(u8), content: []const u8) bool {
    out.clearRetainingCapacity();
    var line_start: usize = 0;
    var skipping = false;
    while (line_start <= content.len) {
        const relative_end = std.mem.indexOfScalar(u8, content[line_start..], '\n');
        const line_end = if (relative_end) |end| line_start + end else content.len;
        const line = content[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            skipping = std.mem.eql(u8, trimmed, "[mcp_servers.petdex]") or
                std.mem.eql(u8, trimmed, "[mcp_servers.petdex.env]");
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

fn installCodexToml(allocator: std.mem.Allocator, path: []const u8, kind: McpAgent) bool {
    if (!ensureParentDir(path)) return false;
    const existing = readFileAlloc(allocator, path, 1024 * 1024);
    defer if (existing) |e| allocator.free(e);
    if (existing == null and fileExists(path)) return false;

    var cleaned = std.array_list.Managed(u8).init(allocator);
    defer cleaned.deinit();
    if (existing) |content| {
        if (!stripCodexPetdex(&cleaned, content)) return false;
    }

    var block_buf: [320]u8 = undefined;
    const block = codexMcpBlock(kind, &block_buf) orelse return false;
    cleaned.appendSlice(block) catch return false;
    if (existing) |_| backupBeside(path);
    return writeFile(path, cleaned.items);
}

fn uninstallCodexToml(allocator: std.mem.Allocator, path: []const u8) bool {
    const existing = readFileAlloc(allocator, path, 1024 * 1024) orelse return true;
    defer allocator.free(existing);
    var cleaned = std.array_list.Managed(u8).init(allocator);
    defer cleaned.deinit();
    if (!stripCodexPetdex(&cleaned, existing)) return false;
    backupBeside(path);
    return writeFile(path, cleaned.items);
}

pub fn install(allocator: std.mem.Allocator, home: []const u8, kind: McpAgent) bool {
    var path_buf: [576]u8 = undefined;
    return switch (kind) {
        .codex => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            break :blk installCodexToml(allocator, path, kind);
        },
        .antigravity => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            if (installJson(allocator, path, kind)) break :blk true;
            var legacy_buf: [576]u8 = undefined;
            const legacy = antigravityLegacyPath(&legacy_buf, home) orelse break :blk false;
            break :blk installJson(allocator, legacy, kind);
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
        .codex => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            break :blk uninstallCodexToml(allocator, path);
        },
        .antigravity => blk: {
            var ok = true;
            if (configPath(&path_buf, home, kind)) |path| {
                if (fileExists(path)) ok = uninstallJson(allocator, path) and ok;
            }
            var legacy_buf: [576]u8 = undefined;
            if (antigravityLegacyPath(&legacy_buf, home)) |legacy| {
                if (fileExists(legacy)) ok = uninstallJson(allocator, legacy) and ok;
            }
            break :blk ok;
        },
        else => blk: {
            const path = configPath(&path_buf, home, kind) orelse break :blk false;
            if (!fileExists(path)) break :blk true;
            break :blk uninstallJson(allocator, path);
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

test "absent when agent home missing" {
    const t = std.testing;
    const a = t.allocator;
    const home = ".zig-cache/petdex-agent-mcp-absent";
    plat.makeDir(home);
    _ = plat.deleteTree(home ++ "/.junie");
    try t.expectEqual(Status.absent, scanOne(a, home, .junie));
}
