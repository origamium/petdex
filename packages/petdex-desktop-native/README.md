# petdex-desktop-native

Petdex on Native SDK (vercel-labs/native): no WebView, no Node sidecar.
Rewrite slice 1; strategy: upstream-first on latest Native SDK, no maintained fork.

## V1 (this package)

Runtime-loaded pet animating its real atlas in a chromeless window:
- Scans `~/.petdex/pets` + `~/.codex/pets` (`PETDEX_PET=<dir>` overrides).
- Canonical state table ported from the WebView renderer (9 states,
  per-frame durations, idle's irregular blink timing).
- App-side atlas decode (registry caps one image at 1MB pixels and the
  platform decode scratch at 1.25MB, so full sheets can't ride
  `registerImageBytes`): V1 uses a macOS dev shim (`sips` -> TGA -> Zig
  TGA parser); V5 replaces it with vendored libwebp on all platforms.
- Frames registered per state into slots 1..8, replaced in place.
- Space or `native automate native-command petdex.cycle` cycles states.

## Build & run

Needs Zig 0.16.0 and git. From this directory:

```bash
make                         # release-flag build (what CI builds)
make dev PETDEX_PET=boba     # automation build, then run it
make test                    # unit tests
make restart                 # macOS: rebuild and relaunch "Petdex Dev.app"
```

The first `make` clones the Native SDK at the commit
`.github/workflows/desktop-native-ci.yml` pins, applies the Petdex patches
from `/patches`, and builds its `native` CLI into
`~/.cache/petdex/native-sdk-<ref>`. Later runs reuse it; bumping the pin in
the workflow switches to a fresh checkout.

`DEV_HOME=/tmp/petdex-home` runs against an isolated home, keeping your real
settings, pets and chat history untouched. The installed Petdex app owns
`127.0.0.1:7777`, so agent hooks keep reaching it until you quit it.

With the automation build running, drive it with the SDK's CLI, e.g.
`~/.cache/petdex/native-sdk-<ref>/zig-out/bin/native automate screenshot pet-canvas`.

Builds pass `-Dtrace=off`. Without it the SDK appends a trace record per frame
and timer to `native-sdk.jsonl` in the platform log directory (#714); the app
deletes that file once it passes 32 MB.

## Bubbles

Each coding-agent conversation floats over the pet as a bubble with the
agent's logo. A bubble waiting on you glows, with an orange dot; one that hit
an error wears a red "!". Click a bubble to open it into a card: the project,
the agent and its status, the model (Claude Code, Codex, OpenCode) and the
reasoning effort (Claude Code, Codex) when the agent reports them, and the
first lines of what it is doing or last said. When the agent runs in Warp (2026.05 or later) or in
Terminal, the card also brings its pane or tab to the front. Click again to
close it. Any number can be open; the cards stack without overlapping. A finished bubble stays with a green check, its card and terminal
still a click away, until you clear the bubbles from the pet's menu or the
tray, or its lifetime in Settings runs out. Up to ten conversations float at
once; past that, the one idle longest makes way. On Linux the bubbles show
their state but do not open into cards.

Claude Code reports failed tools and failed turns once its hooks are installed
again from Settings; an earlier install keeps working without them.

## Chat

Click the pet to talk to it; double-click it for a catch-up on your coding
agents and your last conversation, in its own voice. Cmd+K, the tray and the
pet's menu toggle the chat. Choose ChatGPT or a local OpenAI-compatible server
(LM Studio, Ollama) under Settings → Chat.

The persona comes from the pet's `pet.json` (`displayName`, `description`). A
`persona.md` next to `pet.json` describes the character in more depth, and
`~/.petdex/personas/<slug>.md` overrides it for your own copy; either stands in
for the description. The app keeps the framing: a desktop pet that answers in
one to three short sentences of plain text. Until a reply's first words arrive,
the chat shows one of the pet's `thinking` lines, picked at random, or
"Thinking…" when it has none:

```json
{ "displayName": "古関ウイ", "thinking": ["眠いなあ…", "先生、何考えてるんだろう…"] }
```

History lives in `~/.petdex/petdex.db`, up to 400 messages per pet.

## Language

The app speaks English or Japanese. Settings → Appearance → Language offers
Auto, English and 日本語. Auto follows the macOS preferred languages, the Windows
display language, or `LC_ALL`, `LC_MESSAGES` and `LANG` on Linux. Windows and
Linux draw Japanese only with a Japanese font set under Custom font file, so
Auto stays English there without one. The menu bar changes after a restart;
everything else changes at once. Prompts sent to the model stay English.

## Herdr

The local Herdr plugin mirrors agent attention from Herdr into Petdex and
preserves the exact pane ID so clicking the agent in the Flock window can
focus that pane. Direct
Petdex hooks remain preferred for supported agents. See
[`integrations/herdr`](integrations/herdr/README.md) for setup and filtering.

## DeepSeek Harness (macOS)

The bundled DeepSeek Harness plugin mirrors official DSH Web session events
into Petdex. Install it from Settings, restart DSH Web, then start or continue
a task; Petdex reports the integration as connected only after receiving a real
event. One top-level DSH session becomes one task card, while subagents,
workflows, goals, and compaction update their parent card.

See [`integrations/dsh`](integrations/dsh/README.md) for setup, behavior, and
troubleshooting.

## Remote agents (SSH)

Agents running on other machines can drive the same pet. Declare remotes in
`~/.petdex/remote-agents.json`:

```json
{
  "remotes": [
    {
      "name": "rogue",
      "host": "shakib@rogue.lan",
      "port": 22,
      "identity_file": "~/.ssh/id_ed25519",
      "enabled": true,
      "agents": {
        "opencode": { "enabled": true },
        "codex": { "enabled": false },
        "hermes": { "enabled": true, "home": "~/.hermes" }
      }
    }
  ]
}
```

At launch the desktop probes each enabled remote (`ssh` with `BatchMode=yes`,
no password prompts ever), then runs a fetch-merge-writeback: the remote's
existing hook configs are read, merged locally by the exact installers a local
connect uses, and written back. Foreign hooks are preserved, never clobbered.
The desktop first verifies a supervised reverse tunnel
(`ssh -R 127.0.0.1:7777:127.0.0.1:7777`), installs executable dependencies
before the configs that enable them, starts the session reconcilers, and only
then atomically publishes the hook-server update token. Hook POSTs from the
remote can reach the desktop's loopback server only after that complete gated
patch pass succeeds.

Remote shell-exec agents (codex, hermes) invoke `~/.petdex/bin/petdex-hook` on
the remote, where a small POSIX sh + curl script (`src/assets/petdex-remote-hook.sh`)
mirrors the desktop hook runner's contract: stdin drain, killswitch
(`~/.petdex/runtime/hooks-disabled`), token-gated POSTs to `127.0.0.1:7777`,
never fails outward. The opencode plugin POSTs directly and works unchanged.

Notes:
- SSH only; there is no API fallback transport. Windows remotes are out of scope.
- Remote accounts need a POSIX shell and `ps`; Codex/Hermes reconciliation
  additionally needs `python3`, and their shell hooks need `curl`. Startup
  stays gated and reports a retrying state when a required dependency is absent.
- Names are `[a-zA-Z0-9_-]{1,32}`, must be unique ignoring case, and appear
  in logs and private staging paths.
- `agents.hermes.home` is optional. Set it to Hermes's remote `HERMES_HOME`
  when that installation does not use `~/.hermes`; it must be absolute or
  begin with `~/`.
- Sync runs after every tunnel establishment, before that tunnel's feed token
  becomes available; the Settings "Remote Agents" section reports live status
  and stays read-only.
- If a remote account also runs a petdex desktop, do not point a remote at it:
  the writeback replaces that account's `~/.petdex/bin/petdex-hook` with the
  sh script.
