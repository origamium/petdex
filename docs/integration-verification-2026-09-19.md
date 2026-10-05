# Hooks, MCP and usage verification — 2026-09-19

This audit found and repaired additional failures between host hooks, the
bundled MCP server, Desktop session cards and usage display. Automated checks
cover the repaired boundaries; they do not establish live compatibility with
every upstream agent or operating system. The final runtime, visual and
installation checks are recorded separately below.

The source exposes 19 direct integration rows, 13 MCP installers and usage
report identifiers for all 19 agents. See the
[support matrix](agent-integration-support.md) for host-specific limits.
Automatic notifications require the host's hooks or plugin. A model calling an
MCP tool is supplemental and cannot guarantee that completion or approval events
will be delivered. Accepting usage reports for 19 IDs does **not** mean Petdex
automatically obtains account quotas from all 19 providers.

## Corrections and evidence

| Boundary | Defect and resulting behavior | Evidence and scope |
| --- | --- | --- |
| Hook payload → session | Nested tool data could be confused with envelope metadata. Conversation and model fields now come from the host envelope rather than nested arguments, arrays or quoted prose. | Native regression fixtures exercise nested/escaped payloads and provider session isolation. |
| Hook command → host | A failed or stale notification runner could return a nonzero exit or print a permission decision, affecting hosts with fail-closed pre-tool hooks. Shell `cat` and PowerShell `ReadToEnd` could also wait indefinitely for EOF. Managed wrappers now defer input to the native bounded reader, suppress runner output and preserve the host's tool flow. | An open-pipe regression reproduced the old shell hang. Eighteen actual macOS subprocess checks cover native input and generated wrappers with enabled/disabled/missing/failing runners. Cursor's response contract is preserved. Windows runtime cases are added to CI; they were not executed on this Mac. |
| Hook configuration → connection status | Partial event coverage, restrictive matchers and unsupported schemas must not claim a complete connection. Unsafe Codex feature/settings edits are refused. Oversized configuration files are detected before editing or backing up a truncated prefix. Kimi removes only managed runner commands rather than matching arbitrary names containing Petdex. | Install/status, malformed/oversized input, foreign-entry preservation and complete lifecycle coverage fixtures. Claude statusline restoration also refuses missing, malformed or oversized saved originals. Qoder/CodeBuddy status reflects missing or disabled events. |
| Codex install → existing TOML hooks | Valid foreign array tables such as `[[hooks.SessionStart]]` were incorrectly rejected as unsafe feature settings. The installer now preserves those tables and existing JSON hooks while adding Petdex's five lifecycle groups and MCP registration. Ambiguous feature-array syntax remains rejected. | A fixture reproducing the real config structure passes installation, exact TOML preservation, foreign-hook preservation and current-status checks. Real installation through Settings also succeeded; hashes confirmed all non-Petdex TOML values and pre-existing JSON hooks were preserved. |
| OpenCode/OMP plugin → cards | Waiting and resume transitions were incomplete; an error followed by idle could appear as success. OpenCode handles legacy/v2 events and `data` envelopes. OMP sends conversation state and distinguishes continuation, failure and cancellation from successful completion. | Six subprocess tests execute the actual plugin assets, with 34 assertions. These are controlled host-event fixtures, not live upstream UI events. |
| MCP usage → Desktop | Saving a report did not prove it was displayed, and notification disablement could obstruct usage reporting. Reports are timestamped and atomically saved independently of notifications; an authenticated refresh request follows. The result distinguishes persistence, refresh queueing and usage enablement. | MCP subprocess tests cover offline persistence, notification disablement, refresh responses and invalid windows, including expired resets and millisecond values supplied as epoch seconds. No response claims that a queued refresh has already rendered. |
| MCP transport | Malformed/non-object JSONL requests could wait indefinitely as partial framed messages, and truncated frames could exit as if complete. Parsing now returns the appropriate error and rejects incomplete frames. | Bundled-server protocol subprocess tests. CLI MCP component checks passed 20 tests / 107 assertions, included within the combined integration checks below. |
| MCP configuration ownership | OpenCode's active JSONC precedence was ignored; large configuration/backup buffers could cut off original data. Unreadable removal could appear successful, while a genuinely empty configuration could not be initialized. Editors now use the active configuration and refuse incomplete reads without replacing its contents. | Native installer regressions cover active JSONC, oversize preservation and full backups. CLI typecheck/build and bundled MCP asset synchronization checks passed. |
| Usage observation → valid reading | Invalid dates/UTC offsets, negative/non-finite measurements, stale observations and future-dated Codex rollouts could corrupt or hide readings. Date parsing, selection and expiry now validate those conditions; an unavailable value remains unknown. | Usage tests cover timezone-aware resets and token expiry, stale/future observations, resumed Codex sessions, invalid endpoint values and explicit zero. |
| Copilot credentials → quota API | Reading only legacy `apps.json` missed the current active credential. The reader now follows public GitHub active sessions in `auth.db`, respects sign-out and XDG configuration, and opens the database read-only. Unknown/encrypted schemas do not fall back to an old account. | Production credential reader plus a real read-only quota request returned HTTP 200. Database fixtures cover active/inactive accounts, Enterprise exclusion, WAL, sign-out, unsupported schema and legacy fallback ownership. |
| Copilot quota → usage model | Unlimited pooled credits have consumption but no percentage denominator. Absolute credits and their reset are now retained separately from bounded percentage windows, including explicit zero. | A sanitized response-shape fixture, with synthetic consumption, verifies credit-only and mixed readings, independent reset/TTL expiry, local serialization and chat context. No remaining allowance or percentage is inferred. |
| Usage state → Desktop UI | The floating column alone was difficult to inspect, and many windows could exceed a small screen. Settings → Notifications now includes a named usage list and refresh control; floating details use a bounded scroll viewport. Credit-only readings are visible with percentage unavailable. | Native layout/state regressions cover credit-only details and a small-screen viewport. An isolated running app's Settings view was visually verified with synthetic Codex/Cursor percentages, Copilot credits and reset times. Floating-panel scrolling remains visually unverified. |
| Provider retry → other providers | A single provider's HTTP 429 delayed all network usage sources. Backoff now belongs to the affected provider. | Native regression verifies that other providers remain eligible. |
| Desktop → MCP diagnostics | Status lacked current usage/display evidence. Authenticated diagnostics now include usage enablement, observation/check times, bounded windows and absolute credits; usage refresh is independent of bubble delivery. | Native diagnostic serialization/mailbox tests and MCP readback fixtures. A configured hook is not reported as proof of a received live event. |

## Copilot finding corrects the earlier diagnosis

The earlier [usage verification](usage-verification-2026-09-19.md) observed HTTP
401 using a saved legacy `apps.json` token. That result did not establish that
the user's current Copilot session required reauthentication. The current
language-server `auth.db` contained an active public GitHub credential; after
adding its read-only acquisition path, the same quota endpoint returned HTTP
200 without signing in again or refreshing a token.

Microsoft's maintainer describes the shared `auth.db` store and its XDG path in
[Copilot IntelliJ issue 1830](https://github.com/microsoft/copilot-intellij-feedback/issues/1830).
The implemented plaintext schema and active-session relationships were also
checked against the local database schema. This is an internal store, not a
promise of compatibility with future schema/encryption changes.

The successful response reported unlimited categories and absolute premium
credit consumption, without a finite entitlement. Hiding a fabricated 0% was
correct, but hiding all consumption was insufficient. The new model carries
absolute credits through display and diagnostics. Its parsing and persistence
are regression-verified using synthetic values matching that response shape.

## Validation completed

| Check | Result |
| --- | --- |
| Native suite, `make test` | **472/472 passed** on macOS. |
| Combined Bun integration checks | **99 tests, 274 assertions passed**, including CLI hooks/MCP and plugin fixtures. |
| macOS release build | **ReleaseFast build succeeded** with the integrated changes. |
| Usage-focused suite | **27/27 passed**, including modern Copilot auth and absolute credits. This is a subset, not an additional count. |
| Formatting and patch validation | Zig formatting and applicable Biome / `git diff --check` checks passed during the component audits. |
| Actual Copilot acquisition | Production reader obtained the current credential; the fixed provider quota endpoint returned HTTP 200. No model generation or token refresh was performed. |
| Actual Settings screen | CUA screenshot/accessibility inspection first confirmed synthetic percentage readings, multiple windows, absolute credits with percentage unavailable, and reset text. The final real-home Petdex Dev also visibly showed Claude Code, Codex and Cursor percentages plus Copilot credits/reset, with unavailable providers explicitly unknown. |
| Actual notification screen | CUA screenshot/accessibility inspection confirmed separate Flock cards showing working, waiting/blocked and idle states after real bundled MCP calls. |
| Live process integration | All six checks in `tests/integration_pipeline_test.py` passed against the isolated running Desktop: authentication, MCP usage refresh, notification-off usage, absolute credits, per-conversation MCP states and native hook delivery. Fixture usage files were restored. |
| Current real account readback | The rebuilt Petdex Dev process exposed fresh Claude Code, Codex and Cursor percentage observations and Copilot absolute credits through authenticated diagnostics. Values and account identities are omitted. |
| Cross-platform compile checks | Windows/Linux hook, runner and server modules plus runtime-entry and command-formatter fixtures compiled. These checks do not establish successful linking or runtime behavior. |
| Prior actual acquisition | September 18 checks read fresh Claude Code/Codex observations and obtained a Cursor HTTP 200 response. These earlier observations do not establish freshness on September 19. |

Temporary fixture homes and controlled subprocesses isolate regression data.
Credentials, account identities and personal consumption measurements are not
included in this report or committed as fixtures. No provider credential was
rewritten or refreshed by the audit.

## Final runtime and activation checks

Runtime and installation status is separate from the automated suite.

| Check | Status |
| --- | --- |
| macOS release build containing the integrated changes | Passed — ReleaseFast build succeeded. |
| Running Desktop: hook → notification card → authenticated readback | Passed against the isolated Desktop using the actual native runner and stdin payload. |
| Running Desktop: MCP usage save → immediate refresh → diagnostic reading | Passed using the bundled Node MCP server; updates appeared within two seconds, including with notifications disabled. |
| Actual screen: distinct conversation notification states | Passed — Flock visibly showed working, waiting/blocked and idle cards. |
| Actual screen: Settings usage list and credit-only reading | Passed with synthetic fixtures and subsequently with real fresh Claude Code/Codex/Cursor observations and Copilot absolute credits. Settings scrolling also displayed the lower provider rows correctly. |
| Actual screen: floating usage detail scrolling | Unverified — CUA could not reliably access the separate floating panel. Layout/state regression tests passed. |
| Petdex Dev application updated and running the verified build | Passed — the installed development launcher runs the final repository ReleaseFast binary. Real-home authenticated diagnostics and the new Settings caption confirmed activation. `/Applications/Petdex.app` remains the separate unchanged release installation. |
| Existing host configuration activation | Eleven detected agents now report current hooks and MCP configuration. Codex was updated through the real Settings UI and its foreign configuration was preserved. Already-running host/MCP processes still need to reload; configuration status alone is not live host-event evidence. |

Windows and Linux native runtime/GUI behavior has not been exercised in this
audit. Native usage display is currently macOS-only. Compile or fixture coverage
must not be presented as live host/platform verification.

Grok, Gemini and Antigravity still require usable credentials in their supported
stores to validate live account acquisition. Earlier inspected Junie data was
stale and correctly hidden. Missing observations remain unknown; report-only
agents require actual provider data supplied through the reporting interface.
Project overrides, host trust/approval settings, disabled hooks/tools and host
versions can prevent a correctly installed integration from executing. Reload
the host and restart existing MCP subprocesses after updating their integration
assets, then confirm receipt rather than relying solely on configuration status.

For Codex, the canonical feature key is `features.hooks`. New or changed
non-managed hooks also require review of their exact definition in `/hooks`,
according to the [official OpenAI hook documentation](https://learn.chatgpt.com/docs/hooks).
Petdex's caption now points to this step. Configuration installation does not
grant hook trust, bypass review or restart the user's current agent sessions.
