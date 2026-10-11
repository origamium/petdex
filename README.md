<div align="center">

<img src="public/brand/petdex-desktop-icon.png" alt="Petdex" width="120" />

<h1>Petdex</h1>

<p>
  Animated desktop companions for your coding agents.
  <br />
  A pet that watches Claude Code, Codex, Cursor and 16 more, and talks back.
</p>

<p>
  <a href="https://petdex.dev"><strong>petdex.dev</strong></a>
  &nbsp;·&nbsp;
  <a href="https://petdex.dev/built-with">Built with Petdex</a>
  &nbsp;·&nbsp;
  <a href="https://discord.gg/byhubdyBTe">Discord</a>
  &nbsp;·&nbsp;
  <a href="https://www.npmjs.com/package/petdex">npm</a>
</p>

<p>
  <a href="https://www.npmjs.com/package/petdex"><img src="https://img.shields.io/npm/v/petdex?style=flat-square&label=cli&color=000000" alt="npm version" /></a>
  <a href="https://github.com/origamium/petdex/stargazers"><img src="https://img.shields.io/github/stars/origamium/petdex?style=flat-square&color=000000" alt="GitHub stars" /></a>
  <a href="https://github.com/origamium/petdex/blob/main/LICENSE"><img src="https://img.shields.io/github/license/origamium/petdex?style=flat-square&color=000000" alt="MIT license" /></a>
  <a href="https://github.com/origamium/petdex/issues"><img src="https://img.shields.io/github/issues/origamium/petdex?style=flat-square&color=000000" alt="GitHub issues" /></a>
</p>

</div>

---

## What is Petdex

Petdex is three things working together:

1. **A web gallery** at [petdex.dev](https://petdex.dev) where the community submits, reviews, and showcases animated pets in the Codex sprite format.
2. **A CLI** that installs any pet on your machine with one command and ships them straight into Codex.
3. **A desktop app** that floats a pet on your screen, reacts to your coding agents in real time, and talks to you in its own voice.

Every pet is a folder. Every folder is a Pokédex entry. Every entry is one `npx petdex install` away.

> This repository is a heavily extended fork of [crafter-station/petdex](https://github.com/crafter-station/petdex).
> The gallery, CLI and pet format stay compatible with upstream; most of the changes are in the desktop app, described below.

## What's different in this fork

The desktop app (`packages/petdex-desktop-native`) was rebuilt on [Native SDK](https://github.com/vercel-labs/native) with no WebView and no Node sidecar, and grew from a floating mascot into a small companion for agent work.

- **19 coding agents, one pet.** Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Junie, Antigravity, Devin CLI, Grok Build, Copilot CLI, Windsurf / Devin Desktop, Amp, Droid, Qoder, Kimi Code, CodeBuddy, OMP, Hermes and DeepSeek Harness connect from Settings → Connections. Hooks and plugins are merged into the host's existing config (foreign entries kept, a backup written beside it). Herdr panes are mirrored too. Support matrix and upstream limits: [`docs/agent-integration-support.md`](./docs/agent-integration-support.md).
- **Agent bubbles.** Each conversation floats over the pet with the agent's logo. Click one to open a card with the project, status, model, reasoning effort and the latest text, and jump to its Warp pane or Terminal tab. Bubbles glow when an agent is waiting on you and show a check when it is done.
- **Chat with the pet.** Click the pet to talk to it through ChatGPT or a local OpenAI-compatible server (LM Studio, Ollama). The persona comes from `pet.json`, an optional `persona.md`, or `~/.petdex/personas/<slug>.md`. History is kept in a local SQLite database, and the pet can remember a few facts you ask it to. Double-click for a catch-up on your agents.
- **Pet speaks first (opt-in).** Small talk every few minutes, and a nudge when an agent needs you. Both are off by default and silent while chat is closed or Focus Mode is on.
- **Timer.** A persistent Pomodoro and countdown timer under the chat. The pet announces completions in its own voice, and you can drive the timer from chat (`25分タイマー始めて`, `timer start`).
- **Usage limits (macOS).** A column beside the pet shows how much of each agent's five-hour and weekly limits is used, and when they reset. The pet knows the numbers too.
- **MCP server.** A bundled Node 20+ server (`petdex_set_state`, `petdex_show_bubble`, `petdex_report_usage`, `petdex_status`, `petdex_get_sessions`) gives agents optional controls and readback. Installers exist for 13 hosts.
- **Remote agents over SSH.** Agents on other machines drive the same pet through a supervised reverse tunnel. See the [desktop README](./packages/petdex-desktop-native/README.md#remote-agents-ssh).
- **Languages and appearance.** English and Japanese UI, Auto / Light / Dark, pet size from 0.4× to 2×, and multi-display aware placement.

## Quick start

Follow this checklist to get a pet installed, visible in Codex, and connected to the desktop app.

1. Install a known pet:

```sh
npx petdex install boba
```

You should see `~/.petdex/pets/boba/` with `pet.json` and a spritesheet.

2. Get the desktop app from [petdex.dev/download](https://petdex.dev/download). It
   This fork's releases are Apple Silicon macOS only (Linux and Windows build from source, see the desktop README).

3. Open it, then hit <kbd>Cmd</kbd>+<kbd>,</kbd> over the pet to open Settings.
   Pick your pet under **Pets**, and connect your coding agents under **Connections**
   with one click each. No terminal involved.

The pet floats above your workspace and animates on every tool call your agent
makes. Click it to chat.

## For users

| You want to... | Do this |
| --- | --- |
| Browse pets | Visit [petdex.dev](https://petdex.dev) |
| Install a pet | `npx petdex install <slug>` |
| Switch active mascot | Open Settings in the desktop app (<kbd>Cmd</kbd>+<kbd>,</kbd>) |
| Run the desktop floater | Download it from [petdex.dev/download](https://petdex.dev/download) |
| Chat with your pet | Click it, or press <kbd>Cmd</kbd>+<kbd>K</kbd> |
| Connect a coding agent | Settings → Connections |
| Make a pet | Use the `hatch-pet` skill inside Codex, or build one with the [Petdex creator tools](https://petdex.dev/create) |
| Submit a pet | `npx petdex submit ./my-pet/` or drop it through the web submitter |
| Join the community | [Discord](https://discord.gg/byhubdyBTe) |

Full CLI reference: [`packages/petdex-cli/README.md`](./packages/petdex-cli/README.md). Full desktop reference: [`packages/petdex-desktop-native/README.md`](./packages/petdex-desktop-native/README.md).

## For builders

If you want to build on top of Petdex (a desktop client, a wearable, an SDK, a Discord bot, anything), you have two stable surfaces:

- **The HTTP API.** `petdex.dev/api/manifest` returns every approved pet with its slug, spritesheet URL, animation states, and metadata.
- **The pet package format.** Every pet is a `pet.json` plus a `spritesheet.{webp,png}` rendered as an 8x9 grid of 192x208 frames, or the v2 8x11 grid.
- **The local desktop surfaces.** The desktop app listens on `127.0.0.1:7777` for token-gated agent hooks, and ships an MCP server for agents that want to set state, show a bubble, report usage or read back their session cards. See [`docs/agent-integration-support.md`](./docs/agent-integration-support.md).

21 open-source and source-available projects already build on these. See [petdex.dev/built-with](https://petdex.dev/built-with) for the catalog, then [submit yours via the issue template](https://github.com/origamium/petdex/issues/new?template=built-with.yml).

## Architecture

```text
petdex
├── src/
│   ├── app/[locale]/          Public site: gallery, /pets/<slug>, /collections, /built-with, /community, /create, /download, /submit, /u/<handle>, ...
│   ├── app/api/cli/           CLI endpoints: OAuth config, submit (zip → presigned R2), dedup check, register
│   ├── app/api/manifest/      Public manifest: every approved pet with its spritesheet URL
│   ├── app/api/admin/         Admin review surface for submissions, edits, collection requests
│   └── lib/db/schema.ts       Drizzle schema (Postgres)
├── packages/
│   ├── petdex-cli/            npm `petdex` catalog client (auth, list, install, submit)
│   ├── petdex-desktop-native/ Native SDK (Zig) desktop pet (released for Apple Silicon macOS; Linux/Windows from source): hooks, chat, timer, usage, MCP, SSH remotes
│   └── discord-bot/           Discord.js bot for the Petdex server
├── docs/                      Agent integration support, verification notes, ChatGPT pet integration
├── public/built-with/         Screenshots for the community page
├── public/brand/              Logos, OS icons, Discord icon
└── drizzle/                   SQL migrations (Postgres schema history)
```

**Web stack**: Next.js 16, React 19, Tailwind, Drizzle, Postgres, Redis, Clerk, R2.<br />
**CLI**: Bun + TypeScript, ships as a single npm binary. Auth via Clerk OAuth + PKCE.<br />
**Desktop**: Native SDK app (Zig) with an in-process hook server on `127.0.0.1:7777`, local SQLite for chat history, and a bundled Node 20+ MCP server that is optional. No WebView, no Node sidecar. Building it needs Zig 0.16.0 and `make`; see its [README](./packages/petdex-desktop-native/README.md#build--run).

## Develop locally

Two paths are supported.

| Goal | Command | Setup |
| --- | --- | --- |
| Local full stack | `bun run dev:docker` | Docker or Podman, ~30s warm-up. |
| Run against real services | `bun run dev` | `.env.local` filled (maintainers only). |

```sh
git clone https://github.com/origamium/petdex.git
cd petdex
bun install
bun run dev:docker
```

Open [localhost:3000](http://localhost:3000). Full guide in [`CONTRIBUTING.md`](./CONTRIBUTING.md).

For the desktop app, run `make dev PETDEX_PET=boba` from `packages/petdex-desktop-native`.

## Pet package format

Every pet is two files:

```text
my-pet/
├── pet.json                Metadata: name, slug, tags, vibes, kind, frame size, animation states
└── spritesheet.webp        8x9 or v2 8x11 frame grid of 192x208 px each (or .png)
```

The native renderer supports nine state rows: `idle`, `running-right`, `running-left`, `waving`, `jumping`, `failed`, `waiting`, `running`, and `review`. Codex and the supported coding agents map their activity hooks to these states. The v2 8x11 atlas leaves two additional rows available to the consuming client.

## Contribute

- **Submit a pet:** [petdex.dev/submit](https://petdex.dev/submit) or `npx petdex submit <path>`.
- **List your project:** open a [Built with Petdex issue](https://github.com/origamium/petdex/issues/new?template=built-with.yml).
- **Fix a bug or add a feature:** read [`CONTRIBUTING.md`](./CONTRIBUTING.md), then open a PR.
- **Hang out:** [Discord](https://discord.gg/byhubdyBTe) has channels for shipping (`#wip`, `#ship-or-sink`), feedback (`#cli-feedback`), and showcases (`#showcase`).

## Pet IP and takedowns

Pets are user-submitted fan art. Petdex does not claim rights to any underlying IP. If you hold rights to a character and want a pet removed, file a [takedown request](https://github.com/origamium/petdex/issues/new?template=takedown.yml) and we review within 48 hours.

## License

The source code is [MIT](./LICENSE). Pet assets are owned by their submitters under whatever license they choose to declare.

---

<div align="center">

Fork maintained by <a href="https://github.com/origamium">origamium</a>.
Original Petdex by <a href="https://crafter.run">Crafter Station</a>, lead <a href="https://x.com/RaillyHugo">@RaillyHugo</a>.

</div>
