# Troubleshooting

[README](../README.md) · [Accounts](accounts.md) · [Privacy](privacy.md)

| Symptom | What to check |
|---|---|
| No app window | OpenQuota lives in the menu bar. Click the gauge → Options → Settings. Quit old processes before testing a rebuilt app. |
| Unexpected percentage | Automatic mode chooses the lowest eligible window, not an average. Check General → Menu Bar for a pinned source and check freshness. |
| Menu bar shows — | The selected account/window may be missing or have no valid percentage. It never falls back from a missing pinned source. |
| Claude waiting/outdated | Connect the configuration actually used by Claude; restart Claude and produce a response. Ensure the CLI supports status-line `rate_limits`. Refresh cannot poll an idle profile. |
| OpenCode Go wrong workspace | Add that workspace's key through Add workspace subscription. Old credential files may not match the current CLI database login. |
| Devin detected but failing | Detection only proves a local source exists. Sign in again with the CLI; the current field is `windsurf_api_key`. Never share file contents. |
| Cursor stopped updating | Its session may have expired or the unofficial endpoint changed. Replace Credential for the same account; do not share cookies or keep adding duplicates. |
| Mistral stopped updating | The pasted web session expired (roughly monthly) or the console endpoint changed. Sign in at admin.mistral.ai, then Replace Credential with a fresh Cookie header. |
| Add disabled | Supply the required key/file and Cursor/Mistral consent where applicable. Labels have defaults. A duplicate/default credential file is not another account. |
| Offline or rate-limited | Last-good readings remain outdated. Wait for connectivity or the retry period; repeated refreshes do not bypass backoff. |

## Mistral sessions

Pro/Team subscription allowances are read through the web console session,
not an API key: `api.mistral.ai` has no usage endpoint, and the Admin API is
Enterprise-only. Studio or Admin API keys do not help here — do not create
keys for this. Paste the `Cookie:` request header from a signed-in
admin.mistral.ai request; it must include an `ory_session_*` cookie. Sessions
expire roughly monthly; the row then shows a sign-in error until a fresh
header is pasted. Allowances (Included / Vibe) are Mistral's own percentages;
credits are shown as a balance, never as an allowance.

## Keychain prompts

Verify the prompt belongs to the OpenQuota build you launched. Development
re-signing may prompt again. Denying access prevents credential reads; do not
export keys into plaintext files as a workaround. Relaunch the trusted build
and grant access, or replace the credential through Settings.

## Resource use

Record Activity Monitor CPU/memory, elapsed runtime, account count, refresh
state, and whether local spend scanning is enabled. Temporarily disabling
estimates can distinguish scanning from polling. A short flat-memory sample
does not prove indefinite stability.

## Safe bug reports

Include app/macOS version, provider, connection method, language/appearance,
steps, expected result, and visible error. For quota mismatches compare the same
account, workspace, window, and capture time with the provider dashboard.

**Redact keys, tokens, emails, account IDs, and private paths.** Never attach
credential files, Keychain exports, browser-cookie dumps, raw API responses, or
full CLI transcripts. Submit a minimal sanitized report to
[GitHub Issues](https://github.com/henrikogaard/openquota/issues).
