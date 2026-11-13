# OpenRouter readings

Status: Implemented locally (2026-11-13); bundled-app acceptance pending
Size: Small, one provider within the existing account and snapshot architecture.
Approved: Henrik, 2026-11-13, “Do 1–5 please”.

## Requirements
- FR-1: Fetch balance and key usage independently. Either can succeed alone; failed values disappear from a fresh partial reading. Both failing uses existing stale/error handling.
- FR-2: Explain normal versus management keys in setup and distinguish balance permission failures from invalid credentials. Do not disclose provider response bodies.
- FR-3: Show used, remaining and total key allowance as currency when a limit exists. Respect reported limit_remaining and limit_reset; do not invent a limit for unlimited keys.
- FR-4: Show optional key usage_daily and usage_monthly in account details, not the compact card. Missing fields stay absent; zero stays visible.
- FR-5: Highlight low account balances using a per-account USD threshold in Settings, default $5; zero disables warnings. Unknown balances never trigger warnings.
- CON-1: OpenAI and generic custom-provider parsing stay unchanged; English and Norwegian copy; no live credential use, merge, release or installation.

## Design
Keep GenericProvider's credential storage and account UI. The built-in OpenRouter spec selects a narrow internal reader; custom specs retain the generic path.
Fetch GET /credits and GET /key concurrently using the same saved bearer key and no redirects. Decode each response into bounded numeric values; only finite values enter snapshots.
An optional OpenRouter details value on UsageSnapshot stores period spend, scoped issue enums and Retry-After. Old snapshots decode without it. Partial reads replace snapshots rather than merging stale values.
The scheduler honors Retry-After even on a partial success. No endpoint response body or credential enters error text.
Reuse MetricLine in popover/details. Key amounts wrap at narrow widths. Low-balance preferences use AppStorage, with one key per account, and are purely local visual warnings.

## Build plan
1. Complete: Independent reader, structured partial issues, optional period spend, cache compatibility and Retry-After tests (FR-1, FR-2, FR-4).
2. Complete: Setup copy, currency key row, details, threshold preference and visible warning; fixtures, rendered verification and PR update (FR-2–FR-5).

## Detailed design
### Slice 1
OpenRouterReadings.refresh(http:headers:account:) returns UsageSnapshot. Two concurrent GETs produce Sendable numeric payloads or safe typed failures. Example: /credits 403 plus /key {"data":{"usage":3,"limit":10,"limit_remaining":7,"usage_daily":1,"usage_monthly":2}} yields a key window, no balance, and a management-key warning. Conversely /key failure preserves only a fresh balance. Both fail throws a ProviderError for standard stale retention. Cancellation propagates. A partial 429 sets Retry-After for the scheduler.
### Slice 2
OpenRouterKeyUsage shows $3 used and $7 left of $10. OpenRouterAccountReadings renders account balance, scoped issues and optional period spend. Threshold control is $0–$1000, step $1, initially $5; 0 means Off. Invalid stored thresholds fall back to $5. Warnings use text/icon plus orange, including cached readings already labelled stale. Preferences are isolated per account and disabled in demo mode.

## Verification
- FR-1: Red tests reproduced both lost-reading failures before the change. Partial/both-failed, cancellation, timeout and stale-store transition fixtures now pass.
- FR-2: Permission issue fixtures pass; real native setup/details forms rendered in English/Norwegian and light/dark with synthetic data.
- FR-3: Zero/unlimited/resetting allowance fixtures pass; currency rows rendered with exact cents, including large values and stale readings.
- FR-4: Missing/zero daily and monthly values, cache round trip and legacy decode tests pass. Actual account details render both period values.
- FR-5: Boundary/Off/invalid-threshold/account-isolation tests pass; native stepper action persisted $6 in an isolated defaults suite. Rendered default/custom/Off warnings match the chosen thresholds.
- Focused provider/refresh tests: 25 pass. Full native suite: 254 tests, same 12 assertion failures across the same 6 cases recorded on unchanged base a803fa0 (242 tests), concerning local account discovery, installed Codex path and English-only expectations under Norwegian locale.
- Native build and diff whitespace check pass. No live key/dashboard comparison or bundled-app interaction: default macOS Space absent from inventory; offscreen rendering does not prove packaged acceptance.

## Decisions and deltas
- 2026-11-13: Scoped endpoint reads use the same manually supplied key. Partial 429 responses preserve data and apply the existing account-level Retry-After cooldown. All-request failures retain existing stale readings; partial success omits the failed reading rather than silently retaining old data.
- 2026-11-13: Lifetime key spend is stored separately from the resetting quota window so the currency row and menu-bar percentage both remain correct. OpenRouter currency displays retain cents above $100.
