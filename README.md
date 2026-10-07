# OpenQuota

A small, fast macOS menu-bar app that shows how much AI-provider usage you have left — per provider, **per account**.

One row per account in the popover; the menu bar shows the lowest remaining-% across everything you track, so one glance answers "how much do I have left".

## Why another one

OpenQuota prioritizes a small native UI, independent account state and bounded background work:

- **No browser scraping.** Quota comes from provider APIs, local credential files, or documented CLI integrations — never automatic browser-cookie import.
- **Optional local spend estimates.** Opt in to a bounded Claude/Codex log scan for Today, Yesterday and 30 Days. This estimates API-rate value, not subscription charges; prompts are not retained and nothing is uploaded. [Pricing and privacy](docs/estimated-spend.md).
- **Shared ephemeral URLSession.** Four concurrent account fetches; last-good snapshots replace old values rather than accumulating history.
- **Hard timeouts.** 15s request / 30s resource / 60s per-fetch ceiling. A blocked network fails fast instead of hanging.

## Providers

Each saved key/session has its own row. Other local providers discover their default CLI login; OpenCode, Devin and Grok also support labeled **credential-file profiles**. Claude and Codex subscriptions use separate, explicit connections in Settings → Subscriptions.

| Provider | Status | Source |
|---|---|---|
| Claude Code | Passive status line | Sanitized documented status-line readings; updates while you use Claude Code |
| Codex / ChatGPT | Managed CLI sign-in | Codex app-server subscription limits and credits; isolated Codex home per connection |
| OpenCode Go | Local API key | Rolling, weekly and monthly usage |
| Devin | Local CLI credentials | Daily/weekly remaining percentage and extra-usage balance |
| Grok | Local OAuth | Billing-period usage; named local accounts |
| Cursor | Manual session token | Plan usage and credit grants; no browser-cookie import |
| OpenRouter | API key | Remaining account credits and independent key usage/limit |
| Requesty | Management API key | Organization balance |
| Additional / custom providers | Specs and CLI adapters | See [provider details](docs/providers.md) |

Provider mappings are fixture-tested, **not a claim that every provider has been verified with a live paid account**. Other providers' endpoints may change; errors retain the last good reading and mark it outdated. Claude and Codex use the documented integration surfaces linked in [provider details](docs/providers.md); their fixture tests do not replace live paid-account validation.

Mistral is temporarily hidden: no supported personal-allowance source has been confirmed. Existing Mistral accounts and Keychain entries are retained, but are not displayed or refreshed.

Custom providers are added by dropping a `ProviderSpec` JSON array into `~/Library/Application Support/openquota/provider-specs.json` — no code needed for bearer-key + JSON-usage-endpoint services. Quit and relaunch OpenQuota after editing the file to load the new definitions.

## Build & run

macOS 26 Tahoe+, Xcode 26 / Swift 6.2 toolchain for the app (core builds with Swift 6.1 on Linux):

```bash
scripts/bundle.sh        # builds + assembles dist/OpenQuota.app (ad-hoc signed for dev)
swift test               # core suite — also runs on Linux
```

For development: `swift run OpenQuota` shows the menu-bar item without an app bundle (icon may render in the Dock until bundled as a `.app` with `LSUIElement`).
Run `swift build` before installing the Claude status-line integration during development so the sibling `openquota-bridge` executable is available.

To review populated cards without credentials:

```bash
open dist/OpenQuota.app --args --demo
```

Quit an existing instance first. Demo mode uses synthetic data, performs no account fetches and disables credential changes.

## Accounts and privacy

Settings → Add Account accepts API keys, manually pasted Cursor sessions, or an absolute local credential-file path for supported providers. Saved secrets use macOS Keychain; profile files store only labels and paths. Saved API-key/session accounts can be renamed or removed. Removing a local profile never deletes its provider-owned credential file.

Claude Code connection requires Claude Code and an existing config directory. OpenQuota installs a reversible status-line wrapper that keeps the existing command and unrelated settings. It stores only sanitized quota percentages and reset times from Claude's documented status-line input; it makes no quota requests. Readings follow whichever login is active in that configuration, and become outdated after ten minutes without a new Claude Code response. Disconnect restores the prior status-line object only if the installed command is still unchanged. Separate Claude configs/logins are needed for separate connections.

Codex connection requires the Codex CLI. “Sign in with ChatGPT” runs Codex's documented app-server flow in a dedicated app-managed `CODEX_HOME`, independent for each connection. OpenQuota does not read or copy `auth.json`; Codex manages its own sign-in files. API keys are for separate API billing and do not provide ChatGPT subscription quotas. Removing a Codex connection removes it from OpenQuota but retains Codex-managed files in that dedicated home.

Older Claude/Codex credential-file profiles remain listed as **Reconnect required** but are no longer read. Remove those profiles and add the account from Settings → Subscriptions. Other supported providers may update their own credential file with refreshed tokens; use a separate, stable file per extra login. Duplicating a file does not create a new provider account.

Requests time out, HTTP response bodies are capped at 2 MiB on macOS, local credential files at 1 MiB, and the on-disk snapshot cache at 256 KiB. Subscription connection metadata is secret-free and capped at 100 entries. Saved keys and local profiles have count limits. Rate limits honor `Retry-After`, including during manual refresh. A five-minute refresh cadence and exponential backoff avoid aggressive polling. These bounds reduce risk; they are not a substitute for a long-running memory soak test.

## Auto-update & releases

Sparkle 2.x, same setup as linkrouter: the app checks `releases/latest/download/appcast.xml` (EdDSA-signed updates), and each `v*` tag runs `release.yml` — sign (Developer ID) → notarize → dmg → appcast → GitHub release.

Release secrets/vars to configure on the repo (Apple signing credentials may be shared with linkrouter; use OpenQuota's own Sparkle key):
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
