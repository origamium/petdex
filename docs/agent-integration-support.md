# AI agent integration support

Updated 2026-09-17. This records the implementation after the [notification audit and repairs](pets-mcp-notification-audit-2026-09-17.md). It describes source/build support, not a claim that every upstream application has been exercised end to end.

## Connection coverage

Desktop now has **19 direct integration rows**, **13 MCP installers**, and usage-report identifiers for all 19. Hooks/plugins deliver automatic events; MCP provides optional controls, usage reports and readback. Existing Herdr relay support for additional agents remains available separately.

| Agent | Automatic integration | MCP installer | Boundary |
| --- | --- | --- | --- |
| Claude Code | Lifecycle hooks | Yes | Global/project disable settings and installed host version govern delivery |
| Codex | Hooks plus hooks feature setting | Yes | Restart required; remote watcher remains a separate fallback |
| Gemini CLI | Lifecycle hooks | Yes | Host notification events determine waiting state |
| OpenCode | Event plugin | Yes | Existing V1/V2 config shape and active JSONC file are retained |
| Qoder | Dedicated hooks across supported config roots | No | Existing hook integration |
| Kimi Code | Dedicated TOML hooks | No | Existing hook integration |
| CodeBuddy | Dedicated JSON hooks | No | Existing hook integration |
| OMP | Extension | No | Existing extension integration |
| Hermes | Hooks and desktop plugin | No | Requires host hook approvals; Windows installer unavailable |
| DeepSeek Harness | DSH plugin | No | macOS; a real event is required for the connected indicator |
| Cursor | Prompt, tool result/failure, stop/session hooks | Yes | General permission-dialog notifications unavailable; no permission decision hooks installed |
| Junie | CLI EAP hooks | Yes | TUI/batch only, no ACP/server/IDE hooks; some events lack session ids; permission decision hook omitted |
| Antigravity | Conversation/tool/stop hooks | Yes | Uses Antigravity's own integration and credentials |
| Devin CLI | Lifecycle hooks | Yes | Windows config uses APPDATA; separate from Devin Desktop |
| Grok Build | Lifecycle hooks | Yes | Uses configured GROK_HOME |
| Copilot CLI | Prompt, tool, notification, error, turn/session hooks | Yes | Local CLI only; restart after hook changes |
| Windsurf / Devin Desktop | Cascade prompt, read/write/command/MCP pre/post, response completion | Yes | IDE user path; JetBrains plugin path is not installed; no general permission-dialog event |
| Amp | Local agent.start, tool.result, agent.end plugin | Yes | No tool.call interception, permission signal or remote-orb forwarding |
| Droid | Prompt, tool, notification, stop/session hooks | Yes | Preserves legacy settings hooks; no undocumented failure events registered |

The new adapters follow the published [Copilot CLI hook contract](https://docs.github.com/en/copilot/reference/hooks-reference), [Cascade hook contract](https://docs.devin.ai/desktop/cascade/hooks), [Amp plugin API](https://ampcode.com/docs/plugin-api), and [Droid hook contract](https://docs.factory.ai/harness/hooks). Approval outcomes are left to the host: observers emit no allow/deny decision, and notification delivery failures do not change tool results.

## New adapters and configuration ownership

| Agent | Automatic events | MCP configuration |
| --- | --- | --- |
| Copilot CLI | `~/.copilot/hooks/petdex.json`, version 1 direct event arrays | `~/.copilot/mcp-config.json`, local command with exposed tools list |
| Windsurf / Devin Desktop | `~/.codeium/windsurf/hooks.json`, direct command arrays | `~/.codeium/windsurf/mcp_config.json` |
| Amp | `~/.config/amp/plugins/petdex.js` | `~/.config/amp/settings.json`, `amp.mcpServers.petdex` |
| Droid | `~/.factory/hooks.json`, unwrapped event map with matcher/hook groups | `~/.factory/mcp.json` |

MCP shapes are based on [Copilot configuration](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers), [Cascade configuration](https://docs.devin.ai/desktop/cascade/mcp), [Amp configuration](https://ampcode.com/docs/customize/mcp), and [Droid configuration](https://docs.factory.ai/harness/mcp). Copilot honors COPILOT_HOME; Amp's root follows XDG_CONFIG_HOME when present. The Amp plugin uses the documented local plugin directory and can be reloaded with `plugins: reload`. See [Amp local plugins](https://ampcode.com/docs/customize/plugins).

Install/update retains foreign JSON keys and hook entries and creates a backup beside edited existing files. Reinstalling is idempotent. Droid's legacy `settings.json.hooks` is copied before creating `hooks.json`, because the latter shadows the former. Malformed input fails without replacing the file. Explicit host hook-disable settings remain disabled. Windows Copilot/Cascade commands use PowerShell stdin forwarding; other platforms use the native POSIX wrapper.

Amp sends bounded display metadata rather than full tool results or file contents. Remote executors and missing thread ids are skipped. Hook/plugin installation is local to the machine running Desktop; the existing SSH integrations do not automatically extend to these four new adapters.

## MCP v0.4.0

The server is bundled with Desktop and runs under Node 20+. No registry download is needed for its startup.

| Tool | Purpose |
| --- | --- |
| `petdex_set_state` | Optional state change for an identified conversation |
| `petdex_show_bubble` | Optional message with host session id and metadata |
| `petdex_report_usage` | Timestamped usage observation for a supported agent |
| `petdex_status` | Reachability, notification enablement and hooks/MCP configuration per agent |
| `petdex_get_sessions` | Current session cards, activity, model/effort, workspace and receipt timestamp |

Status and session readback use `GET /integrations` with the existing local update token, and remain available while notification writes are disabled. Status excludes conversation contents. Session readback defaults to PETDEX_MCP_AGENT; `agent: "*"` requests all current cards. Titles and text are task data, not instructions. The diagnostic endpoint reads integration configuration and current cards; it does not query credential stores or transcripts.

`hooks: "current"` and `mcp: "current"` mean the installed configuration matches, not that the host loaded it. `received_at` is the last accepted card event in epoch seconds; it does not prove the agent process is still alive. Readback is limited to Desktop's current maximum of ten cards, which can expire, be cleared or be evicted. Older Desktop builds support health-only status and return an explicit unavailable error for session readback.

Provider-qualified conversation keys keep identical host ids from different agents separate. Hooks and MCP from the same host must use the same conversation id. `session_key` returned by readback is an opaque Desktop key and must not be reused as a host session_id. Supplemental MCP updates preserve omitted title, terminal, workspace, model and focus metadata for the same conversation.

Cascade trajectory ids, model names and tool metadata are normalized. Copilot result failures and question tools are recognized. Droid authentication notifications are ignored; an idle notification does not pretend that the task completed. Session termination and recoverable execution errors do not falsely announce success.

## Usage and remaining limits

Usage reporting support is distinct from automatic quota acquisition. Windsurf, Amp and Droid accept explicit observations; no new credential scraping or quota polling is claimed for them. Existing macOS quota paths retain freshness checks and credential isolation described in the [Desktop README](../packages/petdex-desktop-native/README.md#usage-limits).

The host's version, trust mode, project overrides and disabled tools can still prevent hooks or MCP from loading. Hooks cannot report events the host does not expose, and MCP invocation by a model cannot guarantee automatic completion or approval notifications. Windows/Linux GUI behavior, live upstream clients, live SSH hosts and account quota endpoints were not exercised as part of this expansion.

## Validation and activation

Regression coverage includes per-host schema round trips, duplicate prevention, foreign-hook preservation, disabled settings, legacy Droid migration, metadata retention, provider session isolation, diagnostic snapshots, authenticated MCP requests, default session filtering, offline behavior, Amp event mapping and Windows command quoting. The bundled server is launched under Node to verify all five tools. CI runs the new Amp tests alongside the MCP protocol tests on all three platforms.

Local checks: native suite **449/449**, CLI hooks plus Amp plugin **86/86**, CLI typecheck/build, macOS native release build, generated MCP asset check and formatting. Windows hooks/server and Linux hooks also pass compile-only checks. These use temporary homes and stubbed host/network boundaries; they do not alter live agent configurations or prove live-provider compatibility.

To activate, use the updated Desktop build, open **Settings → Connections**, install/update the relevant integration, then restart the host (or reload Amp plugins). A hooks-only configuration shows that optional MCP tools are not enabled and offers **Set up MCP**, alongside Disconnect. Restart existing MCP subprocesses after Desktop updates. This development task did not replace or restart the running Desktop application and did not publish a release.
