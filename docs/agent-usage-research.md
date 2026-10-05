# Agent usage limits: acquisition audit

For the latest implementation and live verification results, see
[the September 19 integration verification](integration-verification-2026-09-19.md),
which supersedes [the earlier usage report](usage-verification-2026-09-19.md).
The implementation-status column below is a historical September 14 snapshot.

Verified on 2026-09-14 for the native desktop usage column. This is an
acquisition report, not a claim that the additional providers are implemented.
Account identifiers, credentials, balances and personal usage measurements are
intentionally excluded from this document.

## Findings

Grok usage is available. An authenticated browser displayed its current weekly
usage percentage and reset time. The official Build source also exposes a
billing API and an ACP request that can retrieve those values without a model
turn. The installed CLI's saved authentication was expired, so its failed
requests do not establish that the provider lacks a usage interface.

| Provider | Acquisition path | Result on this machine | Native column today |
| --- | --- | --- | --- |
| Grok Build | Official billing API, ACP `x.ai/billing`, billing snapshots in the CLI log, authenticated web Usage page | Web percentage/reset verified; direct API returned 401; installed CLI ACP returned an authentication-related error; local snapshots were stale | Not implemented |
| Claude Code | Existing statusline integration; OAuth usage endpoint; authenticated web Usage page | Web session/weekly percentages verified; Keychain item exists, but reading its secret returned `errSecInteractionNotAllowed` | Statusline integration |
| Cursor | Saved app token and `/api/usage-summary` | HTTP 200 with a numeric plan percentage and billing-cycle end | Implemented |
| Copilot | Saved Copilot OAuth token and `/copilot_internal/user` | HTTP 401 with the inspected saved token | Implemented; credentials rejected in this check |
| Gemini CLI | Code Assist `loadCodeAssist` then `retrieveUserQuota` | Saved credentials found but metadata request returned 401; quota request was therefore not sent | Not implemented |
| Kimi Code | Official managed `/usages` endpoint | Current and legacy source paths verified; no CLI/default credential root found for a live account check | Not implemented |
| Qoder | Official SDK `getUsageInfo()` / `get_usage_info()` | Documented account quota interface; neither default `.qoder` nor `.qoder-cn` root nor CLI was found | Not implemented |
| CodeBuddy | Official website Profile → Usage | Documented account credits UI; no local CLI/default configuration found; programmatic account-quota interface not established | Not implemented |
| OpenCode | Usage belongs to the selected upstream provider, or a Zen/Go account | Local authentication contained an OpenAI provider entry, not a Zen/Go credential; no separate OpenCode allowance established | Not implemented |
| Codex / Junie | Existing session-log / JetBrains local quota integrations | Existing implementation inspected; not independently revalidated against their live account services in this audit | Implemented |

“Not found” above is limited to the inspected default roots, relevant environment
overrides and executable paths. It is not proof that an account or a custom
installation does not exist elsewhere.

## Grok Build

The inspected binary was `grok 0.2.99 (b1b49ccb71a7) [stable]`. Public source
was inspected at commit `37949780c144e37df692e3d669051a21fec24f20`, whose
`SOURCE_REV` was `c4ea71cfdbcdb21e32e41bc25a0043d7d4836714`.
The public source is newer than the installed binary; local protocol checks
were performed separately rather than assuming exact version parity.

### Account billing API

The official [`billing` extension](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-shell/src/extensions/billing.rs)
uses:

```text
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Authorization: Bearer <existing user token>
X-XAI-Token-Auth: xai-grok-cli
x-userid: <authenticated user ID>
x-grok-client-version: <CLI version>
```

The production origin comes from the official
[`xai-grok-env` constants](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-env/src/lib.rs).
The current implementation also sends its process client-mode header. The
direct probe reproduced the authentication headers and installed version.

Relevant response fields are:

| Field | Meaning |
| --- | --- |
| `config.creditUsagePercent` | Included allowance used, on a 0–100 scale |
| `config.currentPeriod.type` | Weekly/monthly period enum |
| `config.currentPeriod.start/end` | RFC 3339 period boundaries |
| `config.isUnifiedBillingUser` | Whether the account uses the shared pool |
| `config.prepaidBalance.val` | Extra purchased credits, in cents; separate from included allowance |
| `config.monthlyLimit.val`, `used.val`, `billingPeriodEnd` | Legacy fallback fields |

The CLI stores credentials in `~/.grok/auth.json`, with optional
`GROK_AUTH_PATH` relocation. Storage and scope selection are defined in
[`storage.rs`](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-login/src/storage.rs)
and [`config.rs`](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-login/src/config.rs).
Scopes include issuer/client combinations and a legacy accounts sign-in key;
do not just select the first JSON entry or send a custom enterprise issuer's
token to the public consumer endpoint.

The inspected saved token was expired. An actual request returned HTTP 401
with an invalid/expired authentication error. No refresh token was redeemed.
The upstream storage implementation explicitly coordinates single-use refresh
tokens with a file lock, so a Petdex reader should continue to leave credential
renewal to Grok itself.

### Official CLI / ACP

The installed CLI accepted this launch without auto-updating:

```sh
grok --no-auto-update agent --no-leader stdio
```

Over its JSON-lines stdio transport, `initialize` with protocol version 1
succeeded. The extension's on-wire request is:

```json
{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}
```

This returned an authentication-related JSON-RPC error (`-32603`) on the
installed version. No `session/new` or `session/prompt` request was sent. The
CLI process was stopped after the response, and the auth file remained
byte-for-byte unchanged. This establishes a usable protocol path, not a
successful authenticated quota response from that binary.

### Files, statusline and web

The billing extension records `billing: fetched credits config` entries in
`~/.grok/logs/unified.jsonl`, under `ctx.config`. Two local snapshots contained
weekly period boundaries; both described a period that had already ended.
Neither contained an explicit usage percentage. They are not current quota
measurements.

There is a parsing nuance: the official
[`credit_balance_from_config`](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-pager/src/app/effects/helpers.rs)
prefers the percentage, then legacy used/limit, and finally defaults to zero
inside an accepted billing configuration. That fallback must not turn a 401,
missing configuration, malformed record or expired snapshot into “0% used.”
A future adapter needs separate freshness and acquisition states.

The official [statusline fields](https://docs.x.ai/build/features/status-line)
describe context occupancy and process cost, not the account allowance.
Likewise, the newer source's `grok usage <session-id>` command reads persisted
session tokens/cost. Neither substitutes for billing quota.

The authenticated browser at `https://grok.com/?_s=usage` displayed a current
percentage and weekly reset time. This worked while CLI authentication failed.
According to the [Grok usage FAQ](https://docs.x.ai/grok/faq#usage--limits), the
weekly pool is shared across products including Build. A “Grok Build” row must
make this shared scope clear rather than imply an independent Build budget.

Browser cookies were not exported or decrypted. Browser and CLI logins can
represent different accounts; a future adapter must verify account selection
instead of merging them solely by provider name.

## Gemini CLI

The official [Code Assist server](https://github.com/google-gemini/gemini-cli/blob/9c1b0a610534d6f8120964cf2672c07807d8fc90/packages/core/src/code_assist/server.ts)
uses these read operations, expressed as POST requests:

```text
POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota
```

The first resolves the Code Assist project; the second receives
`{"project":"<resolved project>"}`. Its
[`BucketInfo` type](https://github.com/google-gemini/gemini-cli/blob/9c1b0a610534d6f8120964cf2672c07807d8fc90/packages/core/src/code_assist/types.ts)
contains `modelId`, `remainingFraction`, `remainingAmount`, `resetTime` and
`tokenType`. Preserve model identity; do not collapse distinct model buckets
into a fabricated single quota or infer a denominator from token counts.

The official
[`OAuthCredentialStorage`](https://github.com/google-gemini/gemini-cli/blob/9c1b0a610534d6f8120964cf2672c07807d8fc90/packages/core/src/code_assist/oauth-credential-storage.ts)
uses service `gemini-cli-oauth`, account `main-account`, with legacy
`~/.gemini/oauth_creds.json` migration. The legacy file existed here, but its
access token was expired and `loadCodeAssist` returned 401. The inspected
Keychain service was absent. Project discovery and quota parsing are therefore
source-verified, not successful live account results in this audit.

## Other acquisition paths

- **Claude:** the installed binary contains `/api/oauth/usage` and the
  `oauth-2025-04-20` beta-header string. Keychain service
  `Claude Code-credentials` was found outside the sandbox, but `security` could
  not read its value: exit 36 corresponds to OSStatus `-25308`, “User
  interaction is not allowed.” The direct endpoint was not called without a
  token. The authenticated browser Usage settings successfully displayed live
  session and weekly limits. Keep the existing statusline path; Keychain
  availability cannot be assumed in unattended collection.
- **Kimi Code:** current official
  [`managed-usage.ts`](https://github.com/MoonshotAI/kimi-code/blob/1336be38777959cc558fed2b51dc53caa07da5db/packages/oauth/src/managed-usage.ts)
  defines `/coding/v1/usages` at `api.kimi.com` and `api.kimi.ai`. It returns
  `usage` for the weekly allowance and `limits[].window/detail` for other
  periods, with decimal-string `used`/`limit` and `resetTime`. The current
  [`storage.ts`](https://github.com/MoonshotAI/kimi-code/blob/1336be38777959cc558fed2b51dc53caa07da5db/packages/oauth/src/storage.ts)
  stores credentials below `~/.kimi-code/credentials/`; honor `KIMI_CODE_HOME`
  and regional origin. The older Python `kimi-cli` also has a `/usages`
  implementation, but its config roots and `/status` alias differ. Do not
  implement against that legacy edition alone.
- **Qoder:** the official [SDK cost/usage documentation](https://docs.qoder.com/cli/sdk/cost-usage)
  explicitly supports querying account quotas without starting an agent turn.
  `getUsageInfo()` exposes plan/add-on/organization quotas, percentages and
  exhaustion state. An object can contain only session statistics when account
  quota is unavailable; those are not interchangeable. This is preferable to
  reverse-engineering a private HTTP endpoint.
- **CodeBuddy:** the official [Usage guide](https://www.codebuddy.ai/docs/ide/Account/usage)
  documents Profile → Usage. Its [OpenTelemetry guide](https://www.codebuddy.ai/docs/cli/monitoring)
  describes model token metrics, which do not establish the remaining account
  allowance. A supported machine-readable account quota interface remains
  unverified here.
- **OpenCode:** [providers](https://opencode.ai/docs/providers/) and
  [Zen](https://opencode.ai/docs/zen/) need different treatment. An upstream
  subscription remains that provider's allowance; showing it again as an
  independent OpenCode budget would be misleading. A Zen/Go adapter would need
  its own account/credential verification, absent in this check.

## Implications for implementation

1. Add Grok as a candidate account-usage adapter, prioritizing a valid existing
   official CLI credential and the billing endpoint. Keep log snapshots as an
   explicitly dated fallback. Browser observation proves availability but does
   not by itself provide an unattended native-app integration.
2. Track acquisition separately from quota: available, expired credentials,
   access denied, stale data, unavailable and unsupported. The current column
   hides all missing values, which makes these different causes look alike.
3. Preserve each provider's units, model scope, account selection and period.
   Percentage used, fraction remaining, session tokens, purchased credits and
   shared subscription pools are distinct quantities.
4. Verify Grok and Gemini again after their own clients restore valid
   authentication. Do not have Petdex rotate their refresh tokens. Test
   multiple accounts, missing/zero fields, ended periods, 401/403/429 responses
   and log rotation before shipping polling.
5. Kimi and Qoder have concrete first-party integration paths, but need a
   signed-in installation for live verification. CodeBuddy's programmatic path
   needs further evidence.

Investigation covered existing Petdex code, installed CLI help/protocol,
first-party source and docs, relevant config/cache/log files, scoped Keychain
queries, actual vendor HTTP responses and authenticated browser UIs. No model
generation was requested. Product code and user agent settings were not changed.
