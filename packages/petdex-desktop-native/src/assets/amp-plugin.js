// Petdex Amp integration v1. Local lifecycle observation through the native runner.
// No tool.call handler: that API returns a permission decision.
const WINDOWS = /*PETDEX_WINDOWS*/ false;

export default function petdex(amp) {
  async function emit(event, ctx, phase) {
    try {
      // A machine-local pet cannot receive events from an orb's executor.
      if (ctx.system?.executor?.kind === "remote") return;
      const session = event.thread?.id ?? ctx.thread?.id;
      if (typeof session !== "string" || !session) return;
      let cwd;
      try {
        const root = ctx.system?.workspaceRoot;
        if (root) cwd = amp.helpers.filePathFromURI(root);
      } catch {}
      // Bound argv and omit full file contents, outputs and transcripts.
      const input = {};
      for (const key of [
        "path",
        "file_path",
        "command",
        "description",
        "pattern",
      ]) {
        if (typeof event.input?.[key] === "string")
          input[key] = event.input[key].slice(0, 256);
      }
      const payload = JSON.stringify({
        session_id: session,
        prompt:
          phase === "user-prompt" && typeof event.message === "string"
            ? event.message.slice(0, 512)
            : undefined,
        tool_name: event.tool,
        tool_input: input,
        status: event.status,
        cwd,
      });
      if (WINDOWS) {
        // Quote data for PowerShell as one literal; ctx.$ quotes the script argument.
        const quoted = payload.replaceAll("'", "''");
        const script = `$OutputEncoding=[System.Text.UTF8Encoding]::new($false); $h=Join-Path $env:USERPROFILE '.petdex/bin/petdex-hook.cmd'; if(Test-Path -LiteralPath $h){'${quoted}' | & $h bubble ${phase} amp}; exit 0`;
        await ctx.$`powershell -NoProfile -NonInteractive -Command ${script}`;
      } else {
        await ctx.$`printf '%s' ${payload} | "$HOME/.petdex/bin/petdex-hook" bubble ${phase} amp`;
      }
    } catch {
      // Notifications must never change an agent result or stop its turn.
    }
  }
  amp.on("agent.start", async (event, ctx) => {
    await emit(event, ctx, "user-prompt");
  });
  amp.on("tool.result", async (event, ctx) => {
    await emit(event, ctx, event.status === "error" ? "tool-failure" : "post");
  });
  amp.on("agent.end", async (event, ctx) => {
    await emit(
      event,
      ctx,
      event.status === "error"
        ? "stop-failure"
        : event.status === "cancelled"
          ? "cancelled"
          : "stop",
    );
  });
}
