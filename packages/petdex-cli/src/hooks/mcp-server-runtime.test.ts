import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const server = fileURLToPath(new URL("./mcp-server.ts", import.meta.url));
const call = (id: number, name: string, args: unknown = {}) => ({
  jsonrpc: "2.0",
  id,
  method: "tools/call",
  params: { name, arguments: args },
});

async function fixture(
  messages: unknown[],
  options: {
    disabled?: boolean;
    offline?: boolean;
    snapshot?: unknown;
    refresh?: unknown;
  } = {},
) {
  const home = await mkdtemp(path.join(tmpdir(), "petdex-mcp-regression-"));
  try {
    await mkdir(path.join(home, ".petdex/runtime"), { recursive: true });
    await writeFile(
      path.join(home, ".petdex/runtime/update-token"),
      "fixture-token",
    );
    if (options.disabled)
      await writeFile(path.join(home, ".petdex/runtime/hooks-disabled"), "1");
    const child = Bun.spawn(
      [
        process.execPath,
        "-e",
        `
      import { appendFileSync } from 'node:fs';
      globalThis.fetch = async (url, init) => {
        appendFileSync(${JSON.stringify(path.join(home, "calls.jsonl"))}, JSON.stringify({url, headers:init?.headers, body:init?.body ? JSON.parse(init.body) : null})+'\\n');
        const body = String(url).endsWith('/usage/refresh') ? ${JSON.stringify(JSON.stringify(options.refresh ?? {}))} : ${JSON.stringify(JSON.stringify(options.snapshot ?? {}))};
        return new Response(body, {status:${options.offline ? 503 : 200}});
      };
      process.env.PETDEX_MCP_AGENT='codex';
      const {runMcpServer}=await import(${JSON.stringify(server)});
      await runMcpServer();
    `,
      ],
      {
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
        env: { ...process.env, HOME: home, USERPROFILE: home },
      },
    );
    // No final newline exercises EOF draining, including queued async writes.
    child.stdin.write(messages.map((m) => JSON.stringify(m)).join("\n"));
    child.stdin.end();
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(code).toBe(0);
    expect(stderr).toBe("");
    const responses = stdout
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    const posts = (
      await readFile(path.join(home, "calls.jsonl"), "utf8").catch(() => "")
    )
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    const usage = await readFile(
      path.join(home, ".petdex/runtime/usage/codex.json"),
      "utf8",
    )
      .then(JSON.parse)
      .catch(() => null);
    return { responses, posts, usage };
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

describe("MCP activity and protocol contracts", () => {
  test("negotiates versions, answers ping, and never replies to notifications", async () => {
    const { responses } = await fixture([
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "unknown" },
      },
      {
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: { requestId: 999 },
      },
      { jsonrpc: "2.0", method: "unknown/notification" },
      { jsonrpc: "2.0", id: 2, method: "ping" },
    ]);
    expect(responses).toHaveLength(2);
    expect(responses[0].result.protocolVersion).toBe("2025-11-25");
    expect(responses[1]).toEqual({ jsonrpc: "2.0", id: 2, result: {} });
  });
  test("session state and full host metadata reach separate conversation slots", async () => {
    const { responses, posts } = await fixture([
      call(1, "petdex_show_bubble", {
        text: "Working",
        session_id: "a",
        agent_state: "review",
        model: "m1",
        effort: "high",
        source_app: "vscode",
        source_cwd: "/work",
        source_tty: "/dev/ttys001",
        warp_focus_url: `warp://session/${"a".repeat(32)}`,
      }),
      call(2, "petdex_set_state", { state: "waiting", session_id: "b" }),
      call(3, "petdex_show_bubble", {
        text: "Done",
        session_id: "a",
        busy: false,
      }),
    ]);
    expect(responses.every((r) => r.result.isError === false)).toBe(true);
    const bubbles = posts
      .filter((p) => p.url.endsWith("/bubble"))
      .map((p) => p.body);
    expect(bubbles[0]).toMatchObject({
      session_id: "a",
      agent_source: "codex",
      agent_state: "review",
      model: "m1",
      effort: "high",
      source_cwd: "/work",
      source_tty: "/dev/ttys001",
    });
    expect(bubbles[1]).toMatchObject({
      session_id: "b",
      agent_state: "waiting",
      busy: false,
    });
    expect(bubbles[2]).toMatchObject({
      session_id: "a",
      agent_state: "idle",
      busy: false,
    });
  });
  test("rejects missing sessions, invalid types and invalid usage without side effects", async () => {
    const { responses, posts, usage } = await fixture([
      call(1, "petdex_show_bubble", { text: "No session" }),
      call(2, "petdex_show_bubble", { text: 123, session_id: "a" }),
      call(3, "petdex_set_state", { state: "bogus", session_id: "a" }),
      call(4, "petdex_report_usage", { windows: [[-1, 0]] }),
      call(5, "petdex_report_usage", { windows: [["90", 0]] }),
      call(6, "petdex_set_state", null),
    ]);
    expect(responses.every((r) => r.error.code === -32602)).toBe(true);
    expect(posts).toEqual([]);
    expect(usage).toBeNull();
  });
  test("records usage observation time and marks tool delivery failures", async () => {
    const { usage, responses } = await fixture(
      [
        call(1, "petdex_report_usage", { windows: [[42, 2000000000, 300]] }),
        call(2, "petdex_show_bubble", { text: "Hello", session_id: "a" }),
      ],
      { offline: true },
    );
    expect(usage.windows).toEqual([[42, 2000000000, 300]]);
    expect(Math.abs(usage.observed_at - Date.now() / 1000)).toBeLessThan(5);
    expect(responses[0].result.isError).toBe(false);
    expect(responses[1].result.isError).toBe(true);
  });
  test("killswitch blocks writes while status remains available", async () => {
    const { responses, posts } = await fixture(
      [
        call(1, "petdex_show_bubble", { text: "Hi", session_id: "a" }),
        call(2, "petdex_status"),
      ],
      { disabled: true },
    );
    expect(responses[0].result.isError).toBe(true);
    expect(responses[1].result.isError).toBe(false);
    expect(posts).toHaveLength(2);
    expect(posts[0].url).toEndWith("/integrations");
    expect(posts[1].url).toEndWith("/health");
  });
  test("notification killswitch does not disable usage reports or their desktop refresh", async () => {
    const { usage, responses, posts } = await fixture(
      [call(1, "petdex_report_usage", { windows: [[42, 2000000000, 300]] })],
      {
        disabled: true,
        refresh: { ok: true, queued: true, usage_enabled: true },
      },
    );
    expect(usage.windows).toEqual([[42, 2000000000, 300]]);
    expect(responses[0].result.structuredContent).toEqual({
      agent: "codex",
      saved: true,
      refresh_requested: true,
      usage_enabled: true,
    });
    expect(posts).toHaveLength(1);
    expect(posts[0].url).toEndWith("/usage/refresh");
    expect(posts[0].headers["X-Petdex-Update-Token"]).toBe("fixture-token");
  });
  test("usage reports distinguish persistence from disabled display and offline refresh", async () => {
    const { responses } = await fixture(
      [call(1, "petdex_report_usage", { windows: [[42, 0]] })],
      { refresh: { ok: true, queued: true, usage_enabled: false } },
    );
    expect(responses[0].result.content[0].text).toContain(
      "Enable Usage limits",
    );
    expect(responses[0].result.structuredContent.usage_enabled).toBe(false);
    const offline = await fixture(
      [call(1, "petdex_report_usage", { windows: [[42, 0]] })],
      { offline: true },
    );
    expect(offline.responses[0].result.isError).toBe(false);
    expect(offline.responses[0].result.structuredContent).toEqual({
      agent: "codex",
      saved: true,
      refresh_requested: false,
      usage_enabled: null,
    });
    expect(offline.usage.windows).toEqual([[42, 0]]);
  });
  test("already reset observations are rejected instead of saved then silently hidden", async () => {
    const { usage, posts, responses } = await fixture([
      call(1, "petdex_report_usage", {
        windows: [[42, Math.floor(Date.now() / 1000) - 1]],
      }),
    ]);
    expect(responses[0].error.code).toBe(-32602);
    expect(usage).toBeNull();
    expect(posts).toHaveLength(0);
  });
  test("millisecond reset timestamps are rejected before native display loses the reset", async () => {
    const { usage, posts, responses } = await fixture([
      call(1, "petdex_report_usage", { windows: [[42, 1e12]] }),
      call(2, "petdex_report_usage", { windows: [[42, Date.now() + 3600000]] }),
    ]);
    expect(responses).toHaveLength(2);
    expect(responses.every((response) => response.error.code === -32602)).toBe(
      true,
    );
    expect(usage).toBeNull();
    expect(posts).toHaveLength(0);
  });
});

test("diagnostics authenticate, filter session cards and remain readable when disabled", async () => {
  const snapshot = {
    ok: true,
    protocol_version: 1,
    notifications_enabled: false,
    integrations: [{ agent: "codex", hooks: "current", mcp: "current" }],
    usage_enabled: true,
    usage_checked_at: 1800000000,
    usage: [
      {
        agent: "codex",
        percent: 42,
        observed_at: 1800000000,
        windows: [{ used: 42, resets_at: 2000000000, minutes: 300, label: "" }],
      },
      {
        agent: "grok",
        percent: null,
        credits_used: 123.45,
        credits_resets_at: 2000000000,
        observed_at: 1800000000,
        windows: [],
      },
    ],
    sessions: [
      { agent: "codex", title: "Fix auth" },
      { agent: "amp", title: "Review" },
    ],
  };
  const { responses, posts } = await fixture(
    [
      call(1, "petdex_status"),
      call(2, "petdex_get_sessions"),
      call(3, "petdex_get_sessions", { agent: "*" }),
      call(4, "petdex_get_sessions", { agent: 42 }),
    ],
    { disabled: true, snapshot },
  );
  expect(responses[0].result.structuredContent).toMatchObject({
    notifications_enabled: false,
    session_count: 2,
    integrations: snapshot.integrations,
    usage_enabled: true,
    usage: snapshot.usage,
    usage_checked_at: snapshot.usage_checked_at,
  });
  expect(responses[0].result.structuredContent.sessions).toBeUndefined();
  expect(responses[1].result.structuredContent.sessions).toEqual([
    snapshot.sessions[0],
  ]);
  expect(responses[2].result.structuredContent.sessions).toHaveLength(2);
  expect(responses[3].error.code).toBe(-32602);
  expect(posts).toHaveLength(3);
  for (const post of posts) {
    expect(post.url).toEndWith("/integrations");
    expect(post.headers["X-Petdex-Update-Token"]).toBe("fixture-token");
    expect(post.body).toBeNull();
  }
});

test("session readback fails explicitly on old desktops or malformed responses", async () => {
  const { responses } = await fixture([call(1, "petdex_get_sessions")]);
  expect(responses[0].result.isError).toBe(true);
  expect(responses[0].result.content[0].text).toContain("unavailable");
});

test("new integration ids accept usage observations", async () => {
  const { responses } = await fixture(
    ["copilot", "windsurf", "amp", "droid"].map((agent, i) =>
      call(i, "petdex_report_usage", {
        agent,
        windows: [[25, 2000000000, 300]],
      }),
    ),
  );
  expect(responses).toHaveLength(4);
  expect(responses.every((r) => r.result.isError === false)).toBe(true);
});

test("the bundled desktop server runs under Node with the same five tools", async () => {
  const asset = fileURLToPath(
    new URL(
      "../../../petdex-desktop-native/src/assets/petdex-mcp-server.mjs",
      import.meta.url,
    ),
  );
  const child = Bun.spawn(["node", asset], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  child.stdin.write(
    [
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-11-25" },
      },
      { jsonrpc: "2.0", id: 2, method: "tools/list" },
      { jsonrpc: "2.0", id: 3, method: "ping" },
    ]
      .map((message) => JSON.stringify(message))
      .join("\n"),
  );
  child.stdin.end();
  const [output, errors, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect(code).toBe(0);
  expect(errors).toBe("");
  const replies = output
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  expect(replies).toHaveLength(3);
  expect(replies[0].result.serverInfo.version).toBe("0.4.0");
  expect(
    replies[1].result.tools.map((tool: { name: string }) => tool.name),
  ).toEqual([
    "petdex_set_state",
    "petdex_show_bubble",
    "petdex_report_usage",
    "petdex_status",
    "petdex_get_sessions",
  ]);
  expect(replies[1].result.tools[0].inputSchema.required).toContain(
    "session_id",
  );
});
