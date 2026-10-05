import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const CLI_PACKAGE_DIR = fileURLToPath(new URL("../..", import.meta.url));

function frame(message: unknown, newline: "\r\n" | "\n" = "\r\n"): string {
  const body = JSON.stringify(message);
  return `Content-Length: ${Buffer.byteLength(body, "utf8")}${newline}${newline}${body}`;
}

function parseFrames(output: string): unknown[] {
  const frames: unknown[] = [];
  let rest = Buffer.from(output);
  while (rest.length > 0) {
    const match = rest.toString().match(/^Content-Length:\s*(\d+)\r\n\r\n/);
    if (!match) break;
    const length = Number.parseInt(match[1], 10);
    const bodyStart = match[0].length;
    const body = rest.slice(bodyStart, bodyStart + length);
    frames.push(JSON.parse(body.toString()));
    rest = rest.slice(bodyStart + length);
  }
  return frames;
}

function parseJsonLines(output: string): unknown[] {
  return output
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

async function runServer(
  runtime: "bun" | "node",
  input: string | Uint8Array | Uint8Array[],
  beforeInputDelay = 0,
) {
  const child = spawn(
    runtime === "bun" ? process.execPath : "node",
    runtime === "bun"
      ? [
          "-e",
          'import("./src/hooks/mcp-server.ts").then(({ runMcpServer }) => runMcpServer())',
        ]
      : [
          fileURLToPath(
            new URL(
              "../../../petdex-desktop-native/src/assets/petdex-mcp-server.mjs",
              import.meta.url,
            ),
          ),
        ],
    {
      cwd: CLI_PACKAGE_DIR,
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  if (beforeInputDelay > 0) {
    await new Promise((resolve) => setTimeout(resolve, beforeInputDelay));
  }
  const beforeInputStdout = stdout;
  // Early rejection may close stdin while a test is still writing a large frame.
  child.stdin.on("error", () => {});
  if (Array.isArray(input)) {
    for (const chunk of input) {
      child.stdin.write(chunk);
      await new Promise((resolve) => setTimeout(resolve, 2));
    }
    child.stdin.end();
  } else child.stdin.end(input);
  const code = await new Promise<number | null>((resolve) => {
    child.on("close", resolve);
  });
  return {
    beforeInputStdout,
    code,
    frames: parseFrames(stdout),
    stdout,
    stderr,
  };
}

describe.each([
  "bun",
  "node",
] as const)("Petdex MCP server stdio (%s)", (runtime) => {
  const execute = (input: string | Uint8Array | Uint8Array[], delay = 0) =>
    runServer(runtime, input, delay);
  test("does not write stdout before initialize", async () => {
    const initialize = frame({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-03-26" },
    });

    const result = await execute(initialize, 100);

    expect(result.beforeInputStdout).toBe("");
    expect(result.stderr).toBe("");
    expect(result.code).toBe(0);
    expect(result.frames).toEqual([
      {
        jsonrpc: "2.0",
        id: 1,
        result: {
          protocolVersion: "2025-03-26",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "petdex-mcp-server", version: "0.4.0" },
        },
      },
    ]);
  });

  test("returns framed tools list response", async () => {
    const initialize = frame({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-03-26" },
    });
    const toolsList = frame({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list",
    });

    const result = await execute(initialize + toolsList);

    expect(result.stderr).toBe("");
    expect(result.code).toBe(0);
    expect(result.frames).toHaveLength(2);
    expect(result.frames[1]).toMatchObject({
      jsonrpc: "2.0",
      id: 2,
      result: {
        tools: [
          { name: "petdex_set_state" },
          { name: "petdex_show_bubble" },
          { name: "petdex_report_usage" },
          { name: "petdex_status" },
          { name: "petdex_get_sessions" },
        ],
      },
    });
  });

  test("accepts LF-only client frames", async () => {
    const initialize = frame(
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-03-26" },
      },
      "\n",
    );

    const result = await execute(initialize);

    expect(result.stderr).toBe("");
    expect(result.code).toBe(0);
    expect(result.frames[0]).toMatchObject({
      jsonrpc: "2.0",
      id: 1,
      result: { serverInfo: { name: "petdex-mcp-server" } },
    });
  });

  test("malformed JSONL lines receive errors and do not block subsequent requests", async () => {
    const result = await execute(
      'garbage\nnull\n[]\n{"jsonrpc":"2.0","id":5,"method":"ping","params":"bad"}\n{"jsonrpc":"2.0","id":6,"method":"ping"}',
    );
    const replies = parseJsonLines(result.stdout) as Array<{
      jsonrpc: string;
      error?: { code: number };
      id: number;
      result?: unknown;
    }>;
    expect(result.code).toBe(0);
    expect(replies.map((reply) => reply.error?.code)).toEqual([
      -32700,
      -32600,
      -32600,
      -32602,
      undefined,
    ]);
    expect(replies[4]).toEqual({ jsonrpc: "2.0", id: 6, result: {} });
  });

  test("unicode framed requests and queued replies preserve byte boundaries", async () => {
    const result = await execute(
      frame({ jsonrpc: "2.0", id: "日本語", method: "ping" }) +
        frame({ jsonrpc: "2.0", id: "🦊", method: "ping" }),
    );
    expect(result.frames).toEqual([
      { jsonrpc: "2.0", id: "日本語", result: {} },
      { jsonrpc: "2.0", id: "🦊", result: {} },
    ]);
  });

  test("truncated framed messages fail explicitly at EOF", async () => {
    const result = await execute(
      'Content-Length: 100\r\n\r\n{"jsonrpc":"2.0"}',
    );
    expect(result.code).toBe(1);
    expect(result.frames).toEqual([
      {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: "Incomplete message" },
      },
    ]);
  });

  test("framed clients may send Content-Type before Content-Length", async () => {
    const result = await execute(
      "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" +
        frame({ jsonrpc: "2.0", id: 8, method: "ping" }),
    );
    expect(result.code).toBe(0);
    expect(result.frames).toEqual([{ jsonrpc: "2.0", id: 8, result: {} }]);
  });

  test("invalid frame lengths fail explicitly instead of dispatching a prefix", async () => {
    const body = JSON.stringify({ jsonrpc: "2.0", id: 9, method: "ping" });
    for (const length of [
      `${body.length}junk`,
      `${body.length}\r\nContent-Length: ${body.length}`,
      "-1",
    ]) {
      const result = await execute(`Content-Length: ${length}\r\n\r\n${body}`);
      expect(result.code).toBe(1);
      expect(result.frames).toHaveLength(1);
      expect(result.frames[0]).toMatchObject({
        id: null,
        error: { code: -32700 },
      });
    }
  });

  test("non-finite request ids are invalid and cannot become a null response id", async () => {
    const result = await execute(
      '{"jsonrpc":"2.0","id":1e400,"method":"ping"}\n',
    );
    expect(parseJsonLines(result.stdout)).toEqual([
      {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32600, message: "Invalid Request" },
      },
    ]);
  });

  test("a maximum-size frame can arrive beside a second complete message", async () => {
    const request = {
      jsonrpc: "2.0",
      id: 10,
      method: "ping",
      params: { padding: "" },
    };
    request.params.padding = "x".repeat(
      1024 * 1024 - JSON.stringify(request).length,
    );
    const result = await execute(
      frame(request) + frame({ jsonrpc: "2.0", id: 11, method: "ping" }),
    );
    expect(result.code).toBe(0);
    expect(result.frames).toEqual([
      { jsonrpc: "2.0", id: 10, result: {} },
      { jsonrpc: "2.0", id: 11, result: {} },
    ]);
  });

  test("oversized messages and headers close the transport with an explicit error", async () => {
    for (const input of [
      `Content-Length: ${1024 * 1024 + 1}\r\n\r\n`,
      `Content-Length: 2\r\nX-Padding: ${"x".repeat(8192)}\r\n\r\n{}`,
      `${JSON.stringify({ jsonrpc: "2.0", id: 12, method: "ping", params: { padding: "x".repeat(1024 * 1024) } })}\n`,
    ]) {
      const result = await execute(input);
      expect(result.code).toBe(1);
      const replies = input.startsWith("Content-")
        ? result.frames
        : parseJsonLines(result.stdout);
      expect(replies).toHaveLength(1);
      expect(replies[0]).toMatchObject({ id: null, error: { code: -32700 } });
    }
  });

  test("fragmented headers and Unicode bodies preserve exact request ids", async () => {
    const bytes = Buffer.from(
      frame({ jsonrpc: "2.0", id: "🦊日本語", method: "ping" }),
    );
    const emoji = bytes.indexOf("🦊");
    const result = await execute([
      bytes.subarray(0, 7),
      bytes.subarray(7, emoji + 1),
      bytes.subarray(emoji + 1),
    ]);
    expect(result.code).toBe(0);
    expect(result.frames).toEqual([
      { jsonrpc: "2.0", id: "🦊日本語", result: {} },
    ]);
  });

  test("invalid UTF-8 is rejected without corrupting the next JSONL request", async () => {
    const input = Buffer.concat([
      Buffer.from('{"jsonrpc":"2.0","id":"'),
      Buffer.from([0xff]),
      Buffer.from(
        '","method":"ping"}\n{"jsonrpc":"2.0","id":13,"method":"ping"}\n',
      ),
    ]);
    const result = await execute(input);
    expect(parseJsonLines(result.stdout)).toEqual([
      {
        jsonrpc: "2.0",
        id: null,
        error: { code: -32700, message: "Invalid JSON or UTF-8" },
      },
      { jsonrpc: "2.0", id: 13, result: {} },
    ]);
  });

  test("accepts Antigravity JSONL initialize request", async () => {
    const initialize = `${JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        clientInfo: { name: "antigravity-client", version: "v1.0.0" },
        protocolVersion: "2025-11-25",
        capabilities: {
          elicitation: { form: {}, url: {} },
          roots: { listChanged: true },
        },
      },
    })}\n`;

    const { stdout, stderr, code } = await execute(initialize);
    expect(stderr).toBe("");
    expect(code).toBe(0);
    expect(parseJsonLines(stdout)).toEqual([
      {
        jsonrpc: "2.0",
        id: 1,
        result: {
          protocolVersion: "2025-11-25",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "petdex-mcp-server", version: "0.4.0" },
        },
      },
    ]);
  });
});
