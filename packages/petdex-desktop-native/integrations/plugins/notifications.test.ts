import { expect, test } from "bun:test";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

async function fixture(options: Record<string, unknown>) {
  const home = await mkdtemp(
    path.join(tmpdir(), "petdex-plugin-notifications-"),
  );
  try {
    const runtime = path.join(home, ".petdex/runtime");
    await mkdir(runtime, { recursive: true });
    await writeFile(path.join(runtime, "update-token"), "fixture-token");
    if (options.disabled)
      await writeFile(path.join(runtime, "hooks-disabled"), "1");
    const child = Bun.spawn(
      [
        process.execPath,
        new URL("./notification-fixture.ts", import.meta.url).pathname,
      ],
      {
        env: { ...process.env, HOME: home, USERPROFILE: home },
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    child.stdin.write(JSON.stringify(options));
    child.stdin.end();
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    expect(code, stderr).toBe(0);
    const result = JSON.parse(stdout);
    expect(result.results.every(Boolean)).toBe(true); // No host decisions returned.
    return result.posts as Array<{
      url: string;
      body: Record<string, unknown>;
    }>;
  } finally {
    await rm(home, { recursive: true, force: true });
  }
}

test("OpenCode permission and question events expose waiting and resume per session", async () => {
  const posts = await fixture({
    agent: "opencode",
    steps: [
      { type: "permission.asked", properties: { sessionID: "session-a" } },
      { type: "question.asked", properties: { sessionID: "session-b" } },
      {
        type: "permission.replied",
        properties: { sessionID: "session-a", reply: "reject" },
      },
      { type: "question.rejected", properties: { sessionID: "session-b" } },
      { type: "permission.asked", properties: {} },
    ],
  });
  const bubbles = posts
    .filter((post) => post.url.endsWith("/bubble"))
    .map((post) => post.body);
  expect(bubbles).toHaveLength(4);
  expect(
    bubbles.map((body) => [body.session_id, body.agent_state, body.busy]),
  ).toEqual([
    ["session-a", "waiting", false],
    ["session-b", "waiting", false],
    ["session-a", "running", true],
    ["session-b", "running", true],
  ]);
  expect(bubbles[0].title).toBe("Title session-a");
});

test("OpenCode supports current v2 and data envelopes without changing decisions", async () => {
  const posts = await fixture({
    agent: "opencode",
    steps: [
      { type: "permission.v2.asked", properties: { sessionID: "a" } },
      { type: "permission.v2.replied", properties: { sessionID: "a" } },
      { type: "question.v2.asked", properties: { sessionID: "b" } },
      { type: "question.v2.replied", properties: { sessionID: "b" } },
      { type: "permission.asked", data: { sessionID: "c" } },
      { type: "question.replied", data: { sessionID: "c" } },
    ],
  });
  const bubbles = posts
    .filter((post) => post.url.endsWith("/bubble"))
    .map((post) => post.body);
  expect(bubbles.map((body) => body.agent_state)).toEqual([
    "waiting",
    "running",
    "waiting",
    "running",
    "waiting",
    "running",
  ]);
});

test("OMP carries each session state and keeps tool failures and continuations busy", async () => {
  const posts = await fixture({
    agent: "omp",
    steps: [
      { type: "input", sessionId: "a", payload: { text: "Fix auth" } },
      {
        type: "tool_call",
        sessionId: "a",
        payload: { toolName: "read", input: { path: "main.ts" } },
      },
      {
        type: "tool_result",
        sessionId: "a",
        payload: { toolName: "bash", isError: true },
      },
      {
        type: "tool_approval_requested",
        sessionId: "a",
        payload: { sessionId: "b" },
      },
      {
        type: "tool_approval_resolved",
        sessionId: "a",
        payload: { sessionId: "b" },
      },
      { type: "agent_end", sessionId: "a", payload: { willContinue: true } },
      { type: "agent_end", sessionId: "a", payload: { willContinue: false } },
      { type: "session_shutdown", sessionId: "a", payload: {} },
    ],
  });
  const bubbles = posts
    .filter((post) => post.url.endsWith("/bubble"))
    .map((post) => post.body);
  expect(bubbles.map((body) => [body.agent_state, body.busy])).toEqual([
    ["jumping", true],
    ["review", true],
    ["failed", true],
    ["waiting", false],
    ["running", true],
    ["running", true],
    ["waving", false],
    ["idle", false],
  ]);
  expect(bubbles[0].title).toBe("Fix auth");
  expect(bubbles[3].session_id).toBe("b");
  expect(bubbles[5].text).toBe("Continuing…");
  expect(bubbles[7].text).toBe("Session ended.");
});

test("plugins stay silent when notifications are disabled or desktop is offline", async () => {
  for (const agent of ["opencode", "omp"]) {
    const steps =
      agent === "opencode"
        ? [{ type: "permission.asked", properties: { sessionID: "a" } }]
        : [{ type: "input", sessionId: "a", payload: { text: "Fix auth" } }];
    expect(await fixture({ agent, steps, disabled: true })).toEqual([]);
    expect(await fixture({ agent, steps, offline: true })).toEqual([]);
  }
});

test("OpenCode idle after an error does not overwrite failure with Done", async () => {
  const posts = await fixture({
    agent: "opencode",
    steps: [
      { type: "session.error", properties: { sessionID: "a" } },
      { type: "session.idle", properties: { sessionID: "a" } },
      { type: "session.idle", properties: { sessionID: "b" } },
      {
        type: "session.status",
        properties: { sessionID: "a", status: { type: "busy" } },
      },
      { type: "session.idle", properties: { sessionID: "a" } },
    ],
  });
  const bubbles = posts
    .filter((post) => post.url.endsWith("/bubble"))
    .map((post) => post.body);
  expect(bubbles.map((body) => [body.session_id, body.text])).toEqual([
    ["a", "OpenCode hit an error."],
    ["b", "Done."],
    ["a", "Done."],
  ]);
});

test("OMP reports terminal errors and cancellations without claiming success", async () => {
  const posts = await fixture({
    agent: "omp",
    steps: [
      {
        type: "agent_end",
        sessionId: "a",
        payload: { messages: [{ role: "assistant", stopReason: "error" }] },
      },
      {
        type: "agent_end",
        sessionId: "b",
        payload: { messages: [{ role: "assistant", stopReason: "aborted" }] },
      },
      {
        type: "agent_end",
        sessionId: "c",
        payload: {
          willContinue: true,
          messages: [{ role: "assistant", stopReason: "error" }],
        },
      },
    ],
  });
  const bubbles = posts
    .filter((post) => post.url.endsWith("/bubble"))
    .map((post) => post.body);
  expect(bubbles.map((body) => [body.agent_state, body.busy])).toEqual([
    ["failed", false],
    ["idle", false],
    ["running", true],
  ]);
  expect(bubbles.every((body) => body.text !== "Done.")).toBe(true);
});
