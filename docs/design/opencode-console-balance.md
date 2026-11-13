# OpenCode Console prepaid balance

Status: Implemented locally (2026-11-13); bundled-app acceptance pending
Size: Small, an additional read in the existing Console provider.
Approved: Henrik, “Test the balance endpoint using my existing OpenQuota Console session. If it works, add the remaining credits to the OpenCode card.”

## Requirements
- FR-1: Read the signed-in workspace's prepaid balance with the existing Console session. AC: a successful prepaid response maps balanceMicroCents / 100,000,000 to USD, including zero.
- FR-2: Show the balance alongside Go limits and budgets. AC: a credits-kind budget never hides the separate balance; a workspace with only a prepaid balance is valid.
- FR-3: Preserve other readings when billing fails. AC: permission, server and malformed responses produce no invented balance and a scoped warning; cancellation propagates and Retry-After delays further billing requests.
- CON-1: No new credentials, account changes, paid calls, release or deployment. No personal response or account identifiers in fixtures or commits. Other providers stay unchanged.

## Scope
- In: FR-1–FR-3, English/Norwegian setup and Settings copy, provider documentation and synthetic fixtures.
- Out: CLI credential import, invoiced credit-limit reporting, low-balance notifications.

## Design and detailed slice
The existing Console refresh concurrently requests Go limits, budgets and GET https://opencode.ai/console/api/billing/status with Authorization: Bearer and x-org-id, through its redirect-refusing bounded client.
For example, {"billingMode":"prepaid","balanceMicroCents":"1234000000","availableMicroCents":"1234000000"} maps to creditsRemaining 12.34, creditsUnit USD. Only the explicit prepaid mode maps to wallet credits; the ledger balance is used rather than available credit capacity. Signed integer microcent strings are required; missing, malformed or non-finite values never become zero.
Billing is an optional reading: failures omit the balance and add a localized warning without discarding Go/budgets. A per-account in-memory cooldown honors Retry-After; expired entries are pruned. If there are no readings at all, existing whole-card error/stale handling applies.
Reuse the existing Balance row in the popover and details, allowing it for opencode-console even when credit-kind budget windows coexist. No model migration is needed: snapshot balance fields already persist.

## Build plan
1. Add failing mapping/balance-only tests, implement the optional billing read and cooldown, then run Console regressions.
2. Update balance visibility and copy, render the changed card/details, run native build/full tests, and deliver a review PR.

## Evidence
- Authorized live read on 2026-11-13: HTTP 200 using the unexpired saved OpenQuota session, without renewal or credential writes. Schema includes billingMode, balanceMicroCents and availableMicroCents. Prepaid fields agree. Personal values and raw responses are excluded from this document.
- The new mapping and balance-only tests failed before implementation, then passed. All 21 Console provider tests pass, including zero/units, denied/malformed responses, invoiced-capacity exclusion, stale-balance replacement and per-account Retry-After.
- A temporary read-only harness exercised the production provider against the live billing endpoint. The mapped USD amount matched the direct endpoint check; Go/budget responses were synthetic 403, and credential writes and renewal requests were disabled. No personal response was retained in the repository.
- Native card and account-detail renders checked in English/Norwegian, light/dark, including budget-plus-balance, balance-only zero, missing balance and long/stale labels. Temporary verification code was removed before the final build.
- Full local suite: 260 tests, same 12 assertion failures across the same 6 cases recorded earlier on the unchanged baseline. They concern installed Codex resolution, local account discovery and English-only expectations under Norwegian locale.
- Native build and diff check pass. Bundled-app interaction and a live Console dashboard comparison remain untested; local:mac-12gb was absent from the current Spaces inventory. No release or installation.
