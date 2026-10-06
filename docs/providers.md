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

## Local-credential adapters (auto-detected, no key entry)

| Provider | Credential source | Endpoint(s) | Notes |
|---|---|---|---|
| Claude | macOS `Claude Code-credentials` Keychain (current user), then `~/.claude/.credentials.json` | `GET api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`; refresh via `platform.claude.com/v1/oauth/token` | 5h/7d/Sonnet/Opus %. Honor retry-after; do not rotate credentials to evade rate limits. File profiles bypass Keychain. |
| Codex | `~/.codex/auth.json` | `GET chatgpt.com/backend-api/wham/usage` + `ChatGPT-Account-Id`; refresh via `auth.openai.com/oauth/token` | 5h/weekly %, plan, credits |
| Gemini | `~/.gemini/oauth_creds.json` | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` → `retrieveUserQuota`; refresh via `oauth2.googleapis.com/token` | per-model buckets |
| Grok | `~/.grok/auth.json` (multi-entry) | `cli-chat-proxy.grok.com/v1/billing?format=credits`; refresh via `auth.x.ai/oauth2/token` | weekly pool + PAYG balance |
| OpenCode Go | `opencode-go` key in `~/.local/share/opencode/auth.json` | `GET opencode.ai/zen/go/v1/usage` | 5h/weekly/monthly |
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
- Claude, Codex, OpenCode, Devin, Grok: Settings → Add Account → Local Credential
  Profile references a separate credential file. Profile IDs namespace account
  IDs, so identical internal CLI identifiers do not overwrite one another.
  Re-adding the same canonical provider/path updates the profile label.
- A profile path must point to an existing regular file, at most 1 MiB. There
  are at most 100 profiles and 100 saved keys per generic provider.
- Removing a profile removes its dashboard state, not its credential file.
  Use separate files for separate logins. Default rows follow the default CLI
  login rather than offering a second OAuth sign-in flow.
- Token refresh writes rotated tokens back to their source. A write failure
  becomes an error rather than silently throwing away the new token.
- First refresh failures still have named account cards. Subsequent failures
  retain last-good values as outdated. Successful discovery prunes removed
  accounts; discovery errors preserve cached accounts until recovery.

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
