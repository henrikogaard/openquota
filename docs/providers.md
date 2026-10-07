# Provider endpoint matrix

Coverage is layered by credential source — the rule is **no automatic browser
cookie import, ever**. Spec-marked `unverified` rows ship field mappings from
public docs/reference implementations, not yet exercised on a live account.
Handwritten adapters and OpenRouter/Requesty have response-fixture coverage;
this is not live authentication or paid-account verification.

## API-key specs (Settings → Add API key)

| Provider | Auth | Endpoint | Notes |
|---|---|---|---|
| OpenRouter | bearer | `openrouter.ai/api/v1/credits` + `/api/v1/key` | total credits minus consumed credits; independent key limit |
| Requesty | bearer | `api-v2.requesty.ai/v1/manage/org` | organization balance; management API access required |
| DeepSeek | bearer | `api.deepseek.com/user/balance` | USD balance |
| Moonshot | bearer | `api.moonshot.ai/v1/users/me/balance` | unverified |
| z.ai | bearer | `api.z.ai/api/monitor/usage/quota/limit` | 5h/weekly/search, unverified |
| ElevenLabs | `xi-api-key` | `elevenlabs.io/v1/user/subscription` | char quota + reset |
| MiniMax | bearer | `api.minimax.io/v1/api/openplatform/coding_plan/remains` | unverified |
| Synthetic | bearer | `api.synthetic.new/v2/quotas` | unverified |
| Kilo | bearer | `kilocode.ai/api/users/me/balance` | unverified |
| Venice | bearer | `api.venice.ai/api/v1/apikeys` | unverified |
| Mistral Vibe | bearer | `api.mistral.ai/v1/admin/analytics/vibe/code/usage/by_workspace` | admin access, 30-day sessions and tokens; **activity, not remaining quota**; unverified live |
| OpenAI | bearer (admin key) | `api.openai.com/v1/organization/costs` | sums 30d buckets, unverified |
| Warp | bearer | `app.warp.dev/graphql` | POST GraphQL, unverified |
| ClinePass | bearer | `api.cline.bot/api/v1/users/me/plan/usage-limits` | 5h/weekly/monthly % used + resets, unverified |
| Vercel AI Gateway | bearer | `ai-gateway.vercel.sh/v1/credits` | team USD balance + lifetime spend, unverified |
| Atlas Cloud | bearer (balance permission) | `api.atlascloud.ai/public/v1/balance` | USD balance only, unverified |
| Poe | bearer | `api.poe.com/usage/current_balance` | point balance, unverified |
| ZenMux | bearer (Management key) | `zenmux.ai/api/v1/management/subscription/detail` | 5h + 7d flows, plan tier; PAYG balance not yet fetched; unverified |
| DevPass | bearer | `api.llmgateway.io/v1/key` | plan credits, premium weekly, key spend; unverified |
| v0 | bearer | `api.v0.dev/v1/user/billing` + `/v1/rate-limits` | token or legacy billing branch + request limit; unverified |
| Codebuff | bearer | `POST www.codebuff.com/api/v1/usage` | credits used/quota/remaining + reset; subscription metadata not fetched; unverified |

## Next candidates (from the OpenUsage / CodexBar audit)

Documented API-key endpoints that need a small handwritten adapter rather than a spec:

- **DeepInfra** — prepaid balance, month spend, spending limit, suspension.
- **Fireworks** — 30-day spend; needs account discovery.
- **xAI platform** — prepaid balance + daily spend; Management key and team ID.
- **Deepgram** — project discovery, then usage breakdown.
- **LiteLLM / LLM Proxy** — user/team budget; needs a user-supplied base URL.
- **Chutes** — subscription quota windows.

Not planned: CodexBar's browser-cookie and private-endpoint integrations
(Windsurf, Manus, Notion AI, Qwen, T3 Chat, Raycast and similar). They need
imported web sessions, which OpenQuota does not do. Antigravity and Ollama
(OpenUsage) read local app state with no documented interface yet.

## Subscription integrations (explicit opt-in)

Claude and Codex subscriptions are not read from their legacy token files or
queried through private usage endpoints. Connections are stored separately
from credential-file profiles. `connections.json` contains only a UUID, kind,
label and config/home directory; the account ID is derived from the UUID.
App-owned bridge data lives below
`~/Library/Application Support/openquota/connections/<uuid>` with private
directory and file permissions.

### Claude Code status line

Requires Claude Code and an existing config directory (normally `~/.claude`).
In Settings → Subscriptions, choose **Connect & Install Status Line** and
explicitly select the configuration. Use a distinct Claude config/login for
each connection. The card follows the active login in that config and does not
guarantee an immutable provider identity.

The installer changes only `statusLine.command` in Claude's `settings.json`.
It preserves unknown top-level keys, other status-line fields and the complete
previous `statusLine` object in private app-owned metadata. The helper receives
Claude Code's documented status-line JSON, retains only `recordedAt`,
`five_hour.used_percentage`, `five_hour.resets_at`,
`seven_day.used_percentage`, and `seven_day.resets_at`, and atomically writes
that sanitized reading. It never saves raw stdin/session context, cwd,
transcript or prompt, and it makes no network request. It invokes the previous
status-line command with the same stdin and forwards its stdout.

Claude Code must produce a response on a subscriber account before limits are
available. This is a passive reading, not a refresh request; readings update
while you use Claude Code and are marked outdated after ten minutes without a
new status-line event. On disconnect, the original status-line object is
restored only if the current command still exactly matches OpenQuota's
installed command. Later user edits and unrelated settings are preserved.
Settings are not removed if a user changed the command to refer to the helper.

Official documentation: [Claude Code status line](https://code.claude.com/docs/en/statusline)
and [Claude usage dashboard](https://claude.ai/settings/usage).

### Codex / ChatGPT subscription

Requires the Codex CLI (found on `PATH` or in common install locations, with
an optional absolute executable picker for nonstandard installs). Choose
**Add Codex Account** and **Sign in with ChatGPT**; OpenQuota opens only a validated HTTPS sign-in URL on
`auth.openai.com` or `chatgpt.com`. Each connection runs `codex app-server`
with its own app-managed `CODEX_HOME` under the OpenQuota support directory,
using Codex's documented file credential store. OpenQuota does not use
`~/.codex`, inspect or copy `auth.json`, pass API-key auth, create prompts, or
start threads/turns. It confirms the account type is `chatgpt`, then maps the
documented `account/rateLimits/read` response. API keys are usage-based API
billing and do not expose ChatGPT subscription quotas.

Refresh launches a short-lived app-server with a 30-second request/process
limit. Failures retain the last good reading as outdated. Removing a
connection disconnects it from OpenQuota but deliberately retains the
Codex-managed files in its private home. For migration from an older
Claude/Codex credential-file profile, remove the old profile and create a new
connection in Settings → Subscriptions; the old credential file is left
untouched and is no longer read.

Official documentation: [Codex authentication](https://developers.openai.com/codex/auth),
[Codex app-server](https://developers.openai.com/codex/app-server.md), and
[Codex usage dashboard](https://chatgpt.com/codex/settings/usage).

## Local-credential adapters (auto-detected, no key entry)

| Provider | Credential source | Endpoint(s) | Notes |
|---|---|---|---|
| Gemini | `~/.gemini/oauth_creds.json` | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` → `retrieveUserQuota`; refresh via `oauth2.googleapis.com/token` | per-model buckets |
| Grok | `~/.grok/auth.json` (multi-entry) | `cli-chat-proxy.grok.com/v1/billing?format=credits`; refresh via `auth.x.ai/oauth2/token` | weekly pool + PAYG balance |
| OpenCode Go | `opencode-go` key in `~/.local/share/opencode/auth.json`, or pasted keys (Add Account → OpenCode Go, one per subscription) | `GET opencode.ai/zen/go/v1/usage` | 5h/weekly/monthly |
| Devin | `~/.local/share/devin/credentials.toml` | `POST {server}/exa.seat_management_pb.SeatManagementService/GetUserStatus` (Connect, default `server.codeium.com`) | daily/weekly remaining percentage; overage balance in USD |
| Copilot | `~/.config/gh/hosts.yml` (gh CLI token) | `api.github.com/copilot_internal/v2/token` → `copilot_internal/user` | premium/chat/completions % |

## Session-token provider (manual paste only)

| Provider | Source | Endpoint(s) |
|---|---|---|
| Cursor | pasted `WorkosCursorSessionToken` (`userID::jwt`) | `api2.cursor.sh/aiserver.v1.DashboardService/{GetCurrentPeriodUsage,GetPlanInfo,GetCreditGrantsBalance}` |

Cookie-token spec providers (e.g. Perplexity) use `auth: "cookie"` — the
pasted value is sent as a `Cookie:` header. Rot is explicit: the row shows an
error until re-pasted; other providers are unaffected.

## CLI providers (run the provider's own binary)

| Provider | Binary | Args |
|---|---|---|
| Amp | `amp` | `usage --json` |
| Kiro | `kiro-cli` | `usage --json` |
| Augment | `auggie` | `quota --json` |

Absence of the binary = provider hidden. A 10s watchdog bounds every call.
These command/field combinations are experimental, not verified against every
installed CLI version. They follow the CLI's active login, not multiple saved
profiles. Unsupported commands show an error card.

## Multiple accounts and recovery

- API-key providers: add, label, rename and remove independent keys in Settings.
  Adding an identical key updates its existing label, without another account.
- Cursor: paste and label each `userID::jwt` session separately. Sessions expire;
  remove/re-add a changed token when needed. No browser cookies are read.
- OpenCode, Devin, Grok: Settings → Add Account → Local Credential Profile
  references a separate credential file. Profile IDs namespace account IDs,
  so identical internal CLI identifiers do not overwrite one another.
- Claude Code and Codex: use the explicit subscription flows above. Old
  credential-file profiles remain visible as “Reconnect required” but are
  disabled; they are not opened, removed, or modified automatically.
  Re-adding the same canonical provider/path updates the profile label.
- A profile path must point to an existing regular file, at most 1 MiB. There
  are at most 100 profiles and 100 saved keys per generic provider.
- Removing a profile removes its dashboard state, not its credential file.
  Use separate files for separate logins. Other default rows follow the
  default CLI login rather than offering a second OAuth sign-in flow.
- Other local-credential adapters may write rotated tokens back to their
  source. A write failure
  becomes an error rather than silently throwing away the new token.
- First refresh failures still have named account cards. Subsequent failures
  retain last-good values as outdated. Successful discovery prunes removed
  accounts; discovery errors preserve cached accounts until recovery.

Claude and Codex fixtures validate sanitization and response mapping only. No
live paid-account sign-in or subscription quota result is represented by the
fixture suite; both integrations still require Mac-session validation with
user-controlled accounts.

Mistral's [Vibe analytics documentation](https://docs.mistral.ai/api/endpoint/beta/admin/vibe-code-analytics)
describes workspace activity; it does not expose personal subscription
remaining percentages. Requesty's [management API](https://docs.requesty.ai/)
provides an organization balance. Neither is relabeled as a subscription quota.

## Deliberately not covered

- Providers exposing no usage endpoint (GroqCloud rate-limit headers only,
  Doubao) and proxies needing a user base URL (LiteLLM, LLM Proxy) — a spec
  `baseURL` field is the TODO for the proxy class.
- CodexBar's remaining cookie-only tier (Qwen, Manus, Windsurf, …) — use a
  `provider-specs.json` entry with `auth: "cookie"` if needed.

## Custom providers (`provider-specs.json`)

Any "credential + JSON endpoint" provider can be added without code:

Save the array in `~/Library/Application Support/openquota/provider-specs.json`,
then quit and relaunch OpenQuota. Editing the file does not hot-reload definitions.

```json
[
  {
    "id": "acme",
    "displayName": "Acme",
    "url": "https://api.acme.com/usage?from={d30}&to={now}",
    "auth": "bearer",
    "dashboardURL": "https://acme.com/billing",
    "windows": [
      { "label": "Month", "used": "$.usage.used", "limit": "$.usage.limit",
        "resetsAt": "$.resets_at", "resetsAtFormat": "epochSeconds" }
    ],
    "map": { "creditsRemaining": "$.credits.balance" }
  }
]
```

Path syntax: `$.a.b[0].c`, plus `[*]` wildcard-flatten, `[key=value]`
first-match filter, and a `sum:` prefix that totals numeric leaves
(`"used": "sum:$.data[*].results[*].amount.value"`). URL templates: `{now}`,
`{today}`, `{d7}`, `{d30}` = epoch seconds. Auth: `bearer`, `apiKeyHeader`
(`x-api-key`), `header` (+`authHeader`/`authPrefix`, e.g. xi-api-key),
`cookie` (manual session cookie — never auto-imported). Requests default to
GET; set `method`/`body`/`headers` for POST/GraphQL endpoints.
