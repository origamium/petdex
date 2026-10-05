import { expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

import petdex from "../../src/assets/amp-plugin.js";

function fixture(plugin = petdex) {
  const handlers = new Map();
  const calls = [];
  plugin({
    on: (name, handler) => handlers.set(name, handler),
    helpers: { filePathFromURI: () => "/project" },
  });
  const ctx = {
    thread: { id: "thread-a" },
    system: { workspaceRoot: "file:///project", executor: { kind: "local" } },
    $: async (strings, ...values) => {
      calls.push({ strings: [...strings], values });
      return { exitCode: 0, stdout: "", stderr: "" };
    },
  };
  return { handlers, calls, ctx };
}

test("Amp observes turns and tool results without intercepting permissions", async () => {
  const { handlers, calls, ctx } = fixture();
  expect([...handlers.keys()]).toEqual([
    "agent.start",
    "tool.result",
    "agent.end",
  ]);
  await handlers.get("agent.start")({ message: "Fix auth" }, ctx);
  await handlers.get("tool.result")(
    { tool: "Bash", input: { command: "bun test" }, status: "done" },
    ctx,
  );
  await handlers.get("tool.result")({ tool: "Bash", status: "error" }, ctx);
  await handlers.get("agent.end")({ status: "done" }, ctx);
  await handlers.get("agent.end")({ status: "cancelled" }, ctx);
  await handlers.get("agent.end")({ status: "error" }, ctx);
  expect(calls.map((c) => c.values[1])).toEqual([
    "user-prompt",
    "post",
    "tool-failure",
    "stop",
    "cancelled",
    "stop-failure",
  ]);
  expect(JSON.parse(calls[0].values[0])).toMatchObject({
    session_id: "thread-a",
    prompt: "Fix auth",
    cwd: "/project",
  });
});

test("Amp payloads are bounded data and keep thread ids separate", async () => {
  const { handlers, calls, ctx } = fixture();
  const command = "'; $(echo unsafe) `echo unsafe`";
  await handlers.get("tool.result")(
    {
      thread: { id: "thread-b" },
      tool: "Bash",
      input: { command, content: "secret", description: "x".repeat(10000) },
    },
    ctx,
  );
  const payload = JSON.parse(calls[0].values[0]);
  expect(payload.session_id).toBe("thread-b");
  expect(payload.tool_input.command).toBe(command);
  expect(payload.tool_input.content).toBeUndefined();
  expect(payload.tool_input.description).toHaveLength(256);
  expect(calls[0].strings.join("")).not.toContain(command);
});

test("Amp skips remote or unidentifiable threads and isolates notification errors", async () => {
  const { handlers, calls, ctx } = fixture();
  await handlers.get("agent.start")(
    {},
    { ...ctx, system: { executor: { kind: "remote" } } },
  );
  await handlers.get("agent.start")({}, { ...ctx, thread: undefined });
  expect(calls).toHaveLength(0);
  await handlers.get("agent.start")(
    {},
    {
      ...ctx,
      $: async () => {
        throw new Error("Desktop not running");
      },
    },
  );
});

test("Amp Windows variant quotes JSON as a PowerShell literal", async () => {
  const source = await readFile(
    new URL("../../src/assets/amp-plugin.js", import.meta.url),
    "utf8",
  );
  expect(source).toContain("/*PETDEX_WINDOWS*/ false");
  const windows = source.replace(
    "/*PETDEX_WINDOWS*/ false",
    "/*PETDEX_WINDOWS*/ true",
  );
  const dir = await mkdtemp(path.join(tmpdir(), "petdex-amp-plugin-"));
  try {
    const target = path.join(dir, "plugin.mjs");
    await writeFile(target, windows);
    const { default: plugin } = await import(pathToFileURL(target).href);
    const { handlers, calls, ctx } = fixture(plugin);
    await handlers.get("agent.start")({ message: "don't $(execute)" }, ctx);
    expect(calls[0].strings.join("")).toBe(
      "powershell -NoProfile -NonInteractive -Command ",
    );
    expect(calls[0].values[0]).toContain("don''t $(execute)");
    expect(calls[0].values[0]).toEndWith("exit 0");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
