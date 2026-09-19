# Desktop usage verification, 2026-09-18–19

This is the earlier audit. The [subsequent integration verification](integration-verification-2026-09-19.md)
records further fixes, successful Copilot acquisition through the current
`auth.db`, and actual Settings/notification UI checks. The legacy-token HTTP 401
below did not mean the current Copilot session needed reauthentication.

The data path works for the observed Claude Code, Codex and Cursor data, and
for explicit MCP reports from all 19 supported agent IDs. This does **not**
establish that every provider can currently supply authenticated account usage,
or that all usage panels have passed visual end-to-end testing.

Account identities, credentials and personal quota measurements are omitted.
The real account checks below ran on September 18 JST; regression checks and
this report were completed on September 19 JST.

## Live acquisition

The probe imported the production `usage.zig` readers and parsers. Credential
values stayed in captured process memory and were sent only to their provider's
existing read-only quota endpoint. No model turn or OAuth refresh was performed.
Cursor's actual token and cookie were also checked against the buffer sizes
used by `main.zig`.

| Provider | Observed result | Meaning |
| --- | --- | --- |
| Claude Code | A fresh weekly statusline observation was read successfully. Later it aged out. | Acquisition works when Claude supplies a recent statusline update; an old value is hidden. |
| Codex | The production reader found the latest weekly allowance in local rollouts on both reads. | Current local usage and reset time were parsed successfully. |
| Cursor | HTTP 200; production parser accepted the plan percentage and billing-cycle end. The captured quota response also passed after the fixes. | Live API acquisition and native parsing verified. |
| Copilot | The inspected legacy OAuth credential returned HTTP 401. | Superseded: the later audit added the current `auth.db` reader and obtained HTTP 200 without reauthentication. |
| Grok | Production credential reader returned no usable token; the inspected consumer credential was expired. | No quota request was sent. Authentication must be renewed by Grok. |
| Gemini CLI | Production credential reader returned no usable token; the legacy file credential was expired. | No quota request was sent. This does not prove all possible Keychain/storage locations lack an account. |
| Antigravity | Production credential reader returned no usable token. | No quota request was sent; successful authenticated acquisition remains unverified. |
| Junie | Available JetBrains quota XML was older than the freshness limit. | Correctly hidden; current usage remains unverified. |
| Other agent IDs | No current local observation was available. | Explicit MCP reporting is supported; this is not automatic discovery of each provider's account allowance. |

Native usage UI is currently macOS-only. Notifications or MCP support on another
platform do not imply that its native usage column is implemented there.

## Corrections made during verification

- Cursor no longer substitutes zero when `used` is missing from the amount/limit
  fallback. Missing, negative or non-finite values are unknown; an explicit zero
  still displays as zero. Valid overages retain the existing capped display.
- Copilot now reads limited chat and completion categories as well as premium
  usage, including legacy Free counts. It skips unallocated and unlimited pools,
  keeps category labels, and rejects invalid percentages.
- Copilot reset precedence is category `quota_reset_at`, account
  `quota_reset_date_utc`, legacy account date, then Free's reset date. AI-credit
  labels follow the response's billing flag. An unlimited pool has no percentage
  denominator, so an absolute credit count is not converted into a fake ratio.

These Copilot fields and reset rules were checked against Microsoft's
[entitlement parser and quota display helpers](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/chat/common/chatEntitlementService.ts)
and [response types](https://github.com/microsoft/vscode/blob/main/src/vs/base/common/defaultAccount.ts).
GitHub's [usage monitoring documentation](https://docs.github.com/en/copilot/how-tos/manage-and-track-spending/monitor-ai-usage)
also distinguishes bounded budgets from absolute consumption without a user
budget. The new response cases are fixture-verified, not a successful live
Copilot account response on this machine.

## Cross-process verification

An isolated temporary home was used for these checks:

- The shipped `petdex-mcp-server.mjs`, executed under Node, accepted reports for
  all 19 agent IDs. The production native reader read both windows for every
  agent, kept reset times and observation timestamps, and selected the higher
  used percentage.
- Negative/out-of-range percentages, 17-window requests and unknown/path-like
  agent IDs could not overwrite an existing valid observation. Sixteen windows
  survived the MCP-to-native boundary.
- Observations older than one hour, more than 60 seconds into the future, or
  with already elapsed resets were hidden rather than displayed as zero.
- The production executable's `statusline` command wrote Claude usage, and the
  native reader recovered its five-hour and weekly windows.
- Endpoint fixtures distinguish a missing Cursor amount from a legitimate zero,
  and cover Copilot Free, credit allocation, per-category resets and pooled
  unlimited accounts.

Repeatable repository checks:

```sh
cd packages/petdex-desktop-native
make test
make build
cd ../petdex-cli
bun test src/hooks/mcp-server.test.ts src/hooks/mcp-server-runtime.test.ts
```

Results: **451 native tests passed**, **13 MCP tests passed**, and the macOS
ReleaseFast build succeeded. Zig formatting and `git diff --check` passed.

The temporary cross-process probe imported repository modules directly; its
helper export was removed after verification. No credentials were added to the
repository or copied into the isolated application home.

## Visual and installation limits

An isolated app bundle started successfully, rendered the pet, enabled Usage
Limits, and served its local health endpoint. The automation interface exposed
the main pet window, but did not expose the separate usage panel for reliable
inspection. Percent rows, expanded breakdowns, reset countdown rendering and
small-screen placement therefore remain **visually unverified**; passing parser
or layout unit tests is not a substitute for those checks.

The verification app was quit after testing. The installed Petdex/Petdex Dev
apps and real provider credentials were not replaced. To use the source fixes,
the installed desktop app still needs to be updated to a build containing them.
