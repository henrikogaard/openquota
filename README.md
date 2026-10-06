# OpenQuota

A small, fast macOS menu-bar app that shows how much AI-provider usage you have left — per provider, **per account**.

One row per account in the popover; the menu bar shows the lowest remaining-% across everything you track, so one glance answers "how much do I have left".

## Why another one

OpenQuota prioritizes a small native UI, independent account state and bounded background work:

- **No WebKit, ever.** Usage comes from provider APIs, local credential files, or pasted API keys — never a live browser session.
- **No session-log scanning.** Only provider-reported numbers; nothing grows with your history.
- **Shared ephemeral URLSession.** Four concurrent account fetches; last-good snapshots replace old values rather than accumulating history.
- **Hard timeouts.** 15s request / 30s resource / 60s per-fetch ceiling. A blocked network fails fast instead of hanging.

## Providers

Each saved key/session has its own row. Local providers discover their default CLI login; additional Claude, Codex, OpenCode, Devin and Grok logins can be added as labeled **credential-file profiles** in Settings. Profiles reference existing files, not browser sessions or interactive sign-in flows. Grok can also enumerate named entries in its credential file.

| Provider | Status | Source |
|---|---|---|
| Claude | Local OAuth | Claude Code Keychain on macOS, then credential file; usage windows and resets |
| Codex / ChatGPT | Local OAuth | Codex credential file; primary/secondary limits and credits |
| OpenCode Go | Local API key | Rolling, weekly and monthly usage |
| Devin | Local CLI credentials | Daily/weekly remaining percentage and extra-usage balance |
| Grok | Local OAuth | Billing-period usage; named local accounts |
| Cursor | Manual session token | Plan usage and credit grants; no browser-cookie import |
| Mistral Vibe | Admin API key | **30-day activity**, not personal remaining allowance |
| OpenRouter | API key | Remaining account credits and independent key usage/limit |
| Requesty | Management API key | Organization balance |
| Additional / custom providers | Specs and CLI adapters | See [provider details](docs/providers.md) |

These implementations are fixture-tested, **not a claim that every provider has been verified with a live paid account**. Private endpoints may change; errors retain the last good reading and mark it outdated. Additional generic integrations are labeled unverified. CLI integrations are experimental and depend on the installed CLI supporting the specified JSON command.

Custom providers are added by dropping a `ProviderSpec` JSON into `~/Library/Application Support/openquota/provider-specs.json` — no code needed for any bearer-key + JSON-usage-endpoint service.

## Build & run

macOS 15+, Swift 6:

```bash
scripts/bundle.sh        # builds + assembles dist/OpenQuota.app (ad-hoc signed for dev)
swift test               # core suite — also runs on Linux
```

For development: `swift run` shows the menu-bar item without an app bundle (icon may render in the Dock until bundled as a `.app` with `LSUIElement`).

To review populated cards without credentials:

```bash
open dist/OpenQuota.app --args --demo
```

Quit an existing instance first. Demo mode uses synthetic data, performs no account fetches and disables credential changes.

## Accounts and privacy

Settings → Add Account accepts API keys, manually pasted Cursor sessions, or an absolute local credential-file path. Saved secrets use macOS Keychain; profile files store only labels and paths. Saved API-key/session accounts can be renamed or removed. Removing a local profile never deletes its provider-owned credential file.

OAuth refresh may update the original credential file (or Claude Code Keychain item) with rotated tokens. Use a separate, stable credential file per extra login; duplicating a file does not create a new provider account. If the CLI changes its default login, that default row follows it. OpenQuota does not provide a browser-based OAuth account-switching flow.

Requests time out, HTTP response bodies are capped at 2 MiB on macOS, local credential files at 1 MiB, and the on-disk snapshot cache at 256 KiB. Saved keys and local profiles have count limits. Rate limits honor `Retry-After`, including during manual refresh. A five-minute refresh cadence and exponential backoff avoid aggressive polling. These bounds reduce risk; they are not a substitute for a long-running memory soak test.

## Auto-update & releases

Sparkle 2.x, same setup as linkrouter: the app checks `releases/latest/download/appcast.xml` (EdDSA-signed updates), and each `v*` tag runs `release.yml` — sign (Developer ID) → notarize → dmg → appcast → GitHub release.

Release secrets/vars to configure on the repo (same values as linkrouter):
`DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `APPSTORE_API_PRIVATE_KEY` (secrets); `APPLE_TEAM_ID`, `APPSTORE_API_KEY_ID`, `APPSTORE_ISSUER_ID` (vars); `SPARKLE_PRIVATE_ED_KEY` (secret — EdDSA private key matching the public key in `Resources/Info.plist`).

Only tag an approved release after configuring signing/notarization and update-signing credentials. A development ad-hoc bundle is not a signed, notarized distribution. A successful appcast request is not evidence of a successful update installation.

## Repo layout

```
Sources/OpenQuotaCore/   # providers, models, refresh engine — pure Foundation
Sources/OpenQuota/       # macOS menu-bar shell (SwiftUI MenuBarExtra)
Tests/OpenQuotaCoreTests/
docs/providers.md        # researched endpoint/auth matrix for every provider
DESIGN.md                # UI tokens
```

## Resource design

| Risk | Our rule |
|---|---|
| Multi-GB scan-cache artifact | No local session-log scanning; bounded one-entry-per-account JSON cache |
| WebKit helper leaks | Zero WebKit anywhere |
| Per-poll allocation growth | Shared URLSession; snapshots are value types; account pruning |
| Hung fetches (7-day timeouts) | Explicit request/resource/fetch timeouts, `waitsForConnectivity = false` |
