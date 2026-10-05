// Run in a separate process with a temporary HOME so real tokens, local HTTP
// endpoints, and other test files' fetch implementations are never involved.
const options = JSON.parse(await Bun.stdin.text());
const posts: Array<{ url: string; body: Record<string, unknown> }> = [];
globalThis.fetch = (async (url: string | URL | Request, init?: RequestInit) => {
  if (options.offline) throw new Error("Desktop is offline");
  posts.push({ url: String(url), body: JSON.parse(String(init?.body)) });
  return new Response("{}", { status: 200 });
}) as typeof fetch;

const results: boolean[] = [];
if (options.agent === "opencode") {
  const { default: plugin } = await import(
    "../../src/assets/opencode-plugin.js"
  );
  const hooks = await plugin({
    client: {
      session: {
        get: async ({ path }: { path: { id: string } }) => ({
          data: { title: `Title ${path.id}` },
        }),
      },
    },
  });
  for (const step of options.steps) {
    const result = await hooks.event({ event: step });
    results.push(result === undefined);
  }
} else {
  const { default: plugin } = await import("../../src/assets/omp-extension.ts");
  const handlers = new Map<string, (event: never, ctx: never) => unknown>();
  plugin({
    on: (name, handler) => handlers.set(name, handler),
    registerCommand() {},
  });
  for (const step of options.steps) {
    const handler = handlers.get(step.type);
    if (!handler) throw new Error(`Missing handler: ${step.type}`);
    const result = await handler(
      step.payload as never,
      {
        sessionManager: { getSessionId: () => step.sessionId },
        ui: { notify() {} },
      } as never,
    );
    results.push(result === undefined);
  }
}
process.stdout.write(JSON.stringify({ posts, results }));
