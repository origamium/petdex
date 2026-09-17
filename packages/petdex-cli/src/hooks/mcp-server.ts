/**
 * Petdex MCP Server — stdio Model Context Protocol server for coding agents.
 *
 * Any MCP-capable agent (Codex, Claude Code, Cursor, Gemini, Junie,
 * Antigravity, OpenCode, Devin, Grok, …) can connect and drive the desktop
 * mascot by calling tools.
 * Set `PETDEX_MCP_AGENT` (or pass `agent` on each tool call) so bubbles and
 * usage land under the right logo.
 *
 * Protocol: JSON-RPC 2.0 over stdin/stdout (framed Content-Length or JSONL).
 * No external MCP SDK — the surface is small enough to inline.
 *
 * IMPORTANT: Do not write to stdout until the client sends `initialize`.
 */
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

const HOOK_SERVER_URL = "http://127.0.0.1:7777";
const STATE_URL = `${HOOK_SERVER_URL}/state`;
const BUBBLE_URL = `${HOOK_SERVER_URL}/bubble`;
const TOKEN_PATH = path.join(homedir(), ".petdex", "runtime", "update-token");
const KILLSWITCH_PATH = path.join(
  homedir(),
  ".petdex",
  "runtime",
  "hooks-disabled",
);
const USAGE_DIR = path.join(homedir(), ".petdex", "runtime", "usage");
const VERSION = "0.2.0";

const KNOWN_AGENTS = new Set([
  "claude-code",
  "codex",
  "gemini",
  "opencode",
  "qoder",
  "kimi-code",
  "codebuddy",
  "omp",
  "hermes",
  "dsh",
  "antigravity",
  "cursor",
  "cursor-agent",
  "junie",
  "copilot",
  "devin",
  "droid",
  "kilo",
  "kilocode",
  "kilo-code",
  "grok",
  "mastracode",
  "mastra",
]);

type TransportMode = "framed" | "jsonl";
let transportMode: TransportMode = "framed";

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

function defaultAgent(): string {
  const fromEnv = process.env.PETDEX_MCP_AGENT?.trim();
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  return "mcp";
}

function resolveAgent(args: Record<string, unknown>): string {
  const raw = typeof args.agent === "string" ? args.agent.trim() : "";
  if (raw.length > 0) return raw;
  return defaultAgent();
}

function normalizeUsageAgent(agent: string): string | null {
  const key = agent.trim().toLowerCase();
  if (key === "claude" || key === "claude_code") return "claude-code";
  if (key === "cursor-agent") return "cursor";
  if (key === "kimi" || key === "kimi_code") return "kimi-code";
  if (KNOWN_AGENTS.has(key)) {
    if (key === "claude-code" || key === "codex" || key === "junie" || key === "cursor" || key === "copilot") {
      return key;
    }
  }
  if (key === "claude-code" || key === "codex" || key === "junie" || key === "cursor" || key === "copilot") {
    return key;
  }
  return null;
}

async function readToken(): Promise<string | null> {
  try {
    return (await readFile(TOKEN_PATH, "utf8")).trim();
  } catch {
    return null;
  }
}

async function killswitchActive(): Promise<boolean> {
  try {
    await readFile(KILLSWITCH_PATH);
    return true;
  } catch {
    return false;
  }
}

async function postJson(
  url: string,
  body: Record<string, unknown>,
): Promise<{ ok: boolean; status: number }> {
  const token = await readToken();
  if (!token) return { ok: false, status: 0 };
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Petdex-Update-Token": token,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(300),
    });
    return { ok: res.ok, status: res.status };
  } catch {
    return { ok: false, status: 0 };
  }
}

async function writeUsageWindows(
  agent: string,
  windows: Array<[number, number, number?]>,
): Promise<boolean> {
  const usageAgent = normalizeUsageAgent(agent);
  if (!usageAgent) return false;
  try {
    await mkdir(USAGE_DIR, { recursive: true });
    const payload = {
      windows: windows.map(([used, resetsAt, minutes]) =>
        minutes === undefined ? [used, resetsAt] : [used, resetsAt, minutes],
      ),
    };
    await writeFile(
      path.join(USAGE_DIR, `${usageAgent}.json`),
      JSON.stringify(payload),
      "utf8",
    );
    return true;
  } catch {
    return false;
  }
}

const TOOLS = [
  {
    name: "petdex_set_state",
    description:
      "Set the pet's animation state. Call this before and after every tool use so the desktop mascot reflects agent activity. Prefer this over doing nothing.",
    inputSchema: {
      type: "object",
      properties: {
        state: {
          type: "string",
          description:
            "Animation state: idle, running, running-left, running-right, waving, jumping, failed, review, waiting",
          enum: [
            "idle",
            "running",
            "running-left",
            "running-right",
            "waving",
            "jumping",
            "failed",
            "review",
            "waiting",
          ],
        },
        duration: {
          type: "number",
          description: "Optional duration in ms to hold this state",
        },
        agent: {
          type: "string",
          description:
            "Agent id for the pet logo (codex, claude-code, junie, cursor, …). Defaults to PETDEX_MCP_AGENT.",
        },
      },
      required: ["state"],
    },
  },
  {
    name: "petdex_show_bubble",
    description:
      "Show a speech bubble above the pet with the given text. Call whenever the agent starts or finishes a meaningful step.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "The bubble text to display (e.g. 'Reading server.ts')",
        },
        title: {
          type: "string",
          description: "Optional conversation/session title",
        },
        session_id: {
          type: "string",
          description: "Optional conversation id so multiple sessions keep separate bubbles",
        },
        busy: {
          type: "boolean",
          description: "True while the agent is still working (default true)",
        },
        agent: {
          type: "string",
          description:
            "Agent id for the pet logo. Defaults to PETDEX_MCP_AGENT.",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "petdex_report_usage",
    description:
      "Report this agent's plan usage limits to the Petdex usage column. Call when rate-limit or quota information is available (percent used and reset time).",
    inputSchema: {
      type: "object",
      properties: {
        windows: {
          type: "array",
          description:
            "Usage windows as [used_percent, resets_at_epoch_seconds, window_minutes?]. used_percent is 0–100.",
          items: {
            type: "array",
            items: { type: "number" },
            minItems: 2,
            maxItems: 3,
          },
        },
        agent: {
          type: "string",
          description:
            "Usage row agent: claude-code, codex, junie, cursor, or copilot. Defaults to PETDEX_MCP_AGENT.",
        },
      },
      required: ["windows"],
    },
  },
  {
    name: "petdex_status",
    description:
      "Check if the petdex desktop mascot is reachable. Returns connection status.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
];

function sendMessage(msg: JsonRpcResponse): void {
  const body = JSON.stringify(msg);
  if (transportMode === "jsonl") {
    process.stdout.write(`${body}\n`);
    return;
  }
  const encoded = new TextEncoder().encode(body);
  const header = `Content-Length: ${encoded.length}\r\n\r\n`;
  process.stdout.write(header);
  process.stdout.write(body);
}

function errorResponse(
  id: string | number | null,
  code: number,
  message: string,
): JsonRpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function textResult(id: string | number | null, text: string): JsonRpcResponse {
  return {
    jsonrpc: "2.0",
    id,
    result: {
      content: [{ type: "text", text }],
    },
  };
}

async function handleRequest(req: JsonRpcRequest): Promise<void> {
  const { id, method, params } = req;

  switch (method) {
    case "initialize": {
      const clientVersion =
        (params?.protocolVersion as string | undefined) ?? "2025-03-26";
      sendMessage({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: clientVersion,
          capabilities: {
            tools: {
              listChanged: false,
            },
          },
          serverInfo: {
            name: "petdex-mcp-server",
            version: VERSION,
          },
        },
      });
      return;
    }

    case "tools/list": {
      sendMessage({
        jsonrpc: "2.0",
        id,
        result: { tools: TOOLS },
      });
      return;
    }

    case "tools/call": {
      const toolName = params?.name as string | undefined;
      const args = (params?.arguments ?? {}) as Record<string, unknown>;

      if (await killswitchActive()) {
        sendMessage(
          textResult(
            id,
            "Petdex hooks are disabled. Run /petdex in your agent or `petdex hooks on` to re-enable.",
          ),
        );
        return;
      }

      switch (toolName) {
        case "petdex_set_state": {
          const state = args.state as string;
          if (!state) {
            sendMessage(
              errorResponse(id, -32602, "Missing required argument: state"),
            );
            return;
          }
          const agent = resolveAgent(args);
          const body: Record<string, unknown> = {
            state,
            agent_source: agent,
          };
          if (typeof args.duration === "number") {
            body.duration = args.duration;
          }
          const result = await postJson(STATE_URL, body);
          sendMessage(
            textResult(
              id,
              result.ok
                ? `Pet state set to "${state}" (${agent})`
                : "Desktop hook server unreachable; is Petdex Desktop running?",
            ),
          );
          return;
        }

        case "petdex_show_bubble": {
          const text = args.text as string;
          if (!text) {
            sendMessage(
              errorResponse(id, -32602, "Missing required argument: text"),
            );
            return;
          }
          const agent = resolveAgent(args);
          const body: Record<string, unknown> = {
            text,
            busy: args.busy !== false,
            agent_source: agent,
          };
          if (typeof args.title === "string" && args.title.length > 0) {
            body.title = args.title;
          }
          if (typeof args.session_id === "string" && args.session_id.length > 0) {
            body.session_id = args.session_id;
          }
          const result = await postJson(BUBBLE_URL, body);
          sendMessage(
            textResult(
              id,
              result.ok
                ? `Bubble shown: "${text}" (${agent})`
                : "Desktop hook server unreachable; is Petdex Desktop running?",
            ),
          );
          return;
        }

        case "petdex_report_usage": {
          const windowsRaw = args.windows;
          if (!Array.isArray(windowsRaw) || windowsRaw.length === 0) {
            sendMessage(
              errorResponse(id, -32602, "Missing required argument: windows"),
            );
            return;
          }
          const agent = resolveAgent(args);
          const windows: Array<[number, number, number?]> = [];
          for (const entry of windowsRaw) {
            if (!Array.isArray(entry) || entry.length < 2) continue;
            const used = Number(entry[0]);
            const resets = Number(entry[1]);
            if (!Number.isFinite(used) || !Number.isFinite(resets)) continue;
            const minutes =
              entry.length > 2 && Number.isFinite(Number(entry[2]))
                ? Number(entry[2])
                : undefined;
            windows.push(
              minutes === undefined ? [used, resets] : [used, resets, minutes],
            );
          }
          if (windows.length === 0) {
            sendMessage(
              errorResponse(id, -32602, "windows must contain numeric triples"),
            );
            return;
          }
          const ok = await writeUsageWindows(agent, windows);
          sendMessage(
            textResult(
              id,
              ok
                ? `Usage reported for ${normalizeUsageAgent(agent) ?? agent}`
                : `Cannot report usage for agent "${agent}" (use claude-code, codex, junie, cursor, or copilot)`,
            ),
          );
          return;
        }

        case "petdex_status": {
          let reachable = false;
          try {
            const res = await fetch(`${HOOK_SERVER_URL}/health`, {
              signal: AbortSignal.timeout(500),
            });
            reachable = res.ok;
          } catch {
            reachable = false;
          }
          sendMessage(
            textResult(
              id,
              reachable
                ? `Petdex desktop is reachable (agent=${defaultAgent()}).`
                : "Petdex desktop not detected. Start it with `petdex up`.",
            ),
          );
          return;
        }

        default: {
          sendMessage(errorResponse(id, -32601, `Unknown tool: ${toolName}`));
          return;
        }
      }
    }

    case "notifications/initialized": {
      return;
    }

    default: {
      sendMessage(errorResponse(id, -32601, `Unknown method: ${method}`));
    }
  }
}

export async function runMcpServer(): Promise<void> {
  let buffer = new Uint8Array(0);
  let pending = 0;
  let draining = false;
  const decoder = new TextDecoder();

  function exitWhenDrained() {
    if (pending === 0) process.exit(0);
  }

  process.stdin.on("data", (chunk: Uint8Array | string) => {
    const raw =
      typeof chunk === "string" ? new TextEncoder().encode(chunk) : chunk;
    const newBuf = new Uint8Array(buffer.length + raw.length);
    newBuf.set(buffer);
    newBuf.set(raw, buffer.length);
    buffer = newBuf;

    while (true) {
      const firstByte = firstNonWhitespaceByte(buffer);
      if (firstByte === 0x7b || firstByte === 0x5b) {
        const lineEnd = findSequence(buffer, new Uint8Array([0x0a]));
        if (lineEnd === -1) break;
        const lineBytes = trimTrailingCarriageReturn(buffer.slice(0, lineEnd));
        buffer = buffer.slice(lineEnd + 1);
        const line = decoder.decode(lineBytes).trim();
        if (!line) continue;
        transportMode = "jsonl";
        dispatchRequest(line);
        continue;
      }

      const headerBoundary = findHeaderBoundary(buffer);
      const headerEnd = headerBoundary.index;
      if (headerEnd === -1) break;

      const headerSection = buffer.slice(0, headerEnd);
      const headerStr = decoder.decode(headerSection);
      const contentLengthMatch = headerStr.match(/Content-Length:\s*(\d+)/i);
      if (!contentLengthMatch) {
        buffer = buffer.slice(headerEnd + headerBoundary.length);
        continue;
      }
      const contentLength = parseInt(contentLengthMatch[1], 10);
      const bodyStart = headerEnd + headerBoundary.length;
      const frameEnd = bodyStart + contentLength;

      if (buffer.length < frameEnd) break;

      const bodyBytes = buffer.slice(bodyStart, frameEnd);
      const bodyStr = decoder.decode(bodyBytes);
      buffer = buffer.slice(frameEnd);
      transportMode = "framed";
      dispatchRequest(bodyStr);
    }
  });

  process.stdin.on("end", () => {
    draining = true;
    exitWhenDrained();
    setTimeout(() => process.exit(0), 3000).unref();
  });

  function dispatchRequest(bodyStr: string) {
    try {
      const req = JSON.parse(bodyStr) as JsonRpcRequest;
      pending++;
      handleRequest(req)
        .catch((err) => {
          sendMessage(
            errorResponse(
              req.id,
              -32603,
              `Internal error: ${(err as Error).message}`,
            ),
          );
        })
        .finally(() => {
          pending--;
          if (draining) exitWhenDrained();
        });
    } catch (err) {
      sendMessage({
        jsonrpc: "2.0",
        id: null,
        error: {
          code: -32700,
          message: `Parse error: ${(err as Error).message}`,
        },
      });
    }
  }
}

function findSequence(haystack: Uint8Array, needle: Uint8Array): number {
  outer: for (let i = 0; i <= haystack.length - needle.length; i++) {
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

function findHeaderBoundary(buffer: Uint8Array): {
  index: number;
  length: number;
} {
  const crlf = findSequence(buffer, new Uint8Array([0x0d, 0x0a, 0x0d, 0x0a]));
  if (crlf !== -1) return { index: crlf, length: 4 };
  const lf = findSequence(buffer, new Uint8Array([0x0a, 0x0a]));
  if (lf !== -1) return { index: lf, length: 2 };
  return { index: -1, length: 0 };
}

function firstNonWhitespaceByte(buffer: Uint8Array): number | null {
  for (const byte of buffer) {
    if (byte !== 0x20 && byte !== 0x09 && byte !== 0x0a && byte !== 0x0d) {
      return byte;
    }
  }
  return null;
}

function trimTrailingCarriageReturn(buffer: Uint8Array): Uint8Array {
  if (buffer.at(-1) === 0x0d) return buffer.slice(0, -1);
  return buffer;
}
