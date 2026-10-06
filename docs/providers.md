# Provider endpoint matrix

Researched endpoints + credential sources for each provider (from OpenUsage's and CodexBar's implementations, both open source).

| Provider | Credential source | Endpoint(s) | Returns | Multi-account |
|---|---|---|---|---|
| Claude | `~/.claude/.credentials.json` + Keychain `Claude Code*` | `GET api.anthropic.com/api/oauth/usage` (`?cedar_ember=1` adds reset grants), `anthropic-beta: oauth-2025-04-20`, Bearer OAuth; refresh via `platform.claude.com/v1/oauth/token` | 5h + 7d %, model limits, reset grants | Swap vaults / multiple homes. **Endpoint 429s aggressively — refresh token on 429, back off.** |
| Codex / ChatGPT | `~/.codex/auth.json` + Keychain `Codex Auth` (per-home) | `GET chatgpt.com/backend-api/wham/usage`, Bearer + `ChatGPT-Account-Id` | 5h/weekly windows (`used_percent`, `reset_at`), plan, credits, reset credits | `CODEX_HOME` dirs, codex-switch vaults |
| OpenCode Go | `opencode-go` key in `~/.local/share/opencode/auth.json` or channel SQLite `credential` table | `GET opencode.ai/zen/go/v1/usage`, Bearer API key | 5h/weekly/monthly caps | Multiple keys |
| Devin | `~/.local/share/devin/credentials.toml` (`api_key`, `api_server_url`) | `POST {server}/exa.seat_management_pb.SeatManagementService/GetUserStatus` (Connect protocol, default `server.codeium.com`) | Weekly/daily quota, extra-usage balance | Multiple credential files |
| Grok | `~/.grok/auth.json` (multi-entry file) | refresh `auth.x.ai/oauth2/token` → `cli-chat-proxy.grok.com/v1/billing?format=credits` + `/v1/settings` | Weekly shared pool, pay-as-you-go | Native — auth.json is already per-account |
| Cursor | Cursor app session (`WorkosCursorSessionToken`) + refresh via `api2.cursor.sh/oauth/token` | `api2.cursor.sh/aiserver.v1.DashboardService/{GetCurrentPeriodUsage,GetPlanInfo,GetCreditGrantsBalance}`; web: `cursor.com/api/usage-summary` | Period usage, plan, credits | Session per account |
| Mistral Vibe | Admin API key (preferred) or console cookies | `api.mistral.ai/v1/admin/usage` + `/v1/admin/analytics/vibe` (`x-api-key`); cookie path: `admin.mistral.ai/api/billing/v2/usage` + `console.mistral.ai` tRPC `billing.vibeUsage` | Monthly included %, pay-as-you-go spend | Multiple API keys |
| OpenRouter | User-supplied API key | `GET openrouter.ai/api/v1/credits` + `/api/v1/key` | Credit balance, usage | N keys |
| Requesty | User-supplied management key | `api-v2.requesty.ai/v1/manage/org` (balance), `/v1/manage/org/usage`, `/v1/manage/apikey/{id}/usage` | Org balance + usage | N keys |

Notes:

- **Requesty has the only documented, official management API** — most stable of all.
- Mistral: prefer the admin API key path; CodexBar scrapes browser cookies (a known leak vector) — we don't do cookie imports.
- Claude's `/api/oauth/usage` rate-limits hard and persistently (anthropics/claude-code#30930, #31637): poll gently, honor `retry-after`, refresh the OAuth token on persistent 429.

## Custom providers (`provider-specs.json`)

Any "bearer key + JSON endpoint" provider can be added without code:

```json
[
  {
    "id": "acme",
    "displayName": "Acme",
    "url": "https://api.acme.com/usage",
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

JSON-path syntax: `$.a.b[0].c` over a `JSONSerialization` tree.
