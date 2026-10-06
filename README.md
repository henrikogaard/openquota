# OpenQuota

A small, fast macOS menu-bar app that shows how much AI-provider usage you have left — per provider, **per account**.

One row per account in the popover; the menu bar shows the lowest remaining-% across everything you track, so one glance answers "how much do I have left".

## Why another one

CodexBar and OpenUsage cover this space, but CodexBar has documented memory leaks (multi-GB growth from its session-log scan cache, WebKit cookie-import helpers, per-poll allocation growth) and both are large apps. OpenQuota is deliberately tiny:

- **No WebKit, ever.** Usage comes from provider APIs, local credential files, or pasted API keys — never a live browser session.
- **No session-log scanning.** Only provider-reported numbers; nothing grows with your history.
- **One URLSession, one timer.** Value-type snapshots in a bounded store; nothing accumulates across refreshes.
- **Hard timeouts.** 15s request / 30s resource / 60s per-fetch ceiling. A blocked network fails fast instead of hanging.

## Providers

Each provider tracks **multiple accounts / API keys** — every key or login is its own row.

| Provider | Status | Source |
|---|---|---|
| OpenRouter | ✅ API key | `/api/v1/credits` + `/api/v1/key` |
| Requesty | ✅ API key | `api-v2.requesty.ai/v1/manage/org` |
| Custom (any JSON+bearer API) | ✅ spec-driven | see `docs/providers.md` |
| Claude, Codex/ChatGPT, OpenCode Go, Devin, Grok, Cursor, Mistral Vibe | 🔜 adapters | local CLI/app credentials — see `docs/providers.md` for the mapped endpoints |

Custom providers are added by dropping a `ProviderSpec` JSON into `~/Library/Application Support/openquota/provider-specs.json` — no code needed for any bearer-key + JSON-usage-endpoint service.

## Build & run

macOS 15+, Swift 6:

```bash
swift build -c release
# or package into an .app — see scripts/ (todo: bundle script)
```

For development: `swift run` shows the menu-bar item without an app bundle (icon may render in the Dock until bundled as a `.app` with `LSUIElement`).

The `OpenQuotaCore` library (providers, models, engine) also compiles and tests on Linux — `swift test` runs the full core suite.

## Repo layout

```
Sources/OpenQuotaCore/   # providers, models, refresh engine — pure Foundation
Sources/OpenQuota/       # macOS menu-bar shell (SwiftUI MenuBarExtra)
Tests/OpenQuotaCoreTests/
docs/providers.md        # researched endpoint/auth matrix for every provider
DESIGN.md                # UI tokens
```

## Design rules (the "no leaks" contract)

| CodexBar failure | Our rule |
|---|---|
| Multi-GB scan-cache artifact | No local session-log scanning; bounded one-entry-per-account JSON cache |
| WebKit helper leaks | Zero WebKit anywhere |
| Per-poll allocation growth | One URLSession + one Timer; snapshots are value types |
| Hung fetches (7-day timeouts) | Explicit request/resource/fetch timeouts, `waitsForConnectivity = false` |
