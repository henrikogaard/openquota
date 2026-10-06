# Provider endpoint matrix

Coverage is layered by credential source — the rule is **no automatic browser
cookie import, ever**. Spec-marked `unverified` rows ship field mappings from
public docs/CodexBar's implementation, not yet exercised on a live account.

## API-key specs (Settings → Add API key)

| Provider | Auth | Endpoint | Notes |
|---|---|---|---|
| OpenRouter | bearer | `openrouter.ai/api/v1/credits` + `/key` | verified |
| Requesty | bearer | `api-v2.requesty.ai/v1/manage/org` | verified |
| DeepSeek | bearer | `api.deepseek.com/user/balance` | USD balance |
| Moonshot | bearer | `api.moonshot.ai/v1/users/me/balance` | unverified |
| z.ai | bearer | `api.z.ai/api/monitor/usage/quota/limit` | 5h/weekly/search, unverified |
| ElevenLabs | `xi-api-key` | `elevenlabs.io/v1/user/subscription` | char quota + reset |
| MiniMax | bearer | `api.minimax.io/v1/api/openplatform/coding_plan/remains` | unverified |
| Synthetic | bearer | `api.synthetic.new/v2/quotas` | unverified |
| Kilo | bearer | `kilocode.ai/api/users/me/balance` | unverified |
| Venice | bearer | `api.venice.ai/api/v1/apikeys` | unverified |
| Mistral | `x-api-key` | `api.mistral.ai/v1/admin/usage` | admin key, unverified |
| OpenAI | bearer (admin key) | `api.openai.com/v1/organization/costs` | sums 30d buckets, unverified |
| Warp | bearer | `app.warp.dev/graphql` | POST GraphQL, unverified |

## Local-credential adapters (auto-detected, no key entry)

| Provider | Credential source | Endpoint(s) | Notes |
|---|---|---|---|
| Claude | `~/.claude/.credentials.json` | `GET api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`; refresh via `platform.claude.com/v1/oauth/token` | 5h/7d/Sonnet/Opus %. **429s aggressively — honor retry-after, refresh token on persistent 429.** |
| Codex | `~/.codex/auth.json` | `GET chatgpt.com/backend-api/wham/usage` + `ChatGPT-Account-Id`; refresh via `auth.openai.com/oauth/token` | 5h/weekly %, plan, credits |
| Gemini | `~/.gemini/oauth_creds.json` | `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` → `retrieveUserQuota`; refresh via `oauth2.googleapis.com/token` | per-model buckets |
| Grok | `~/.grok/auth.json` (multi-entry) | `cli-chat-proxy.grok.com/v1/billing?format=credits`; refresh via `auth.x.ai/oauth2/token` | weekly pool + PAYG balance |
| OpenCode Go | `opencode-go` key in `~/.local/share/opencode/auth.json` | `GET opencode.ai/zen/go/v1/usage` | 5h/weekly/monthly |
| Devin | `~/.local/share/devin/credentials.toml` | `POST {server}/exa.seat_management_pb.SeatManagementService/GetUserStatus` (Connect, default `server.codeium.com`) | daily/weekly + extra-usage ACUs |
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
