# Short history ranges and missing model prices

Status: Implemented locally (2026-11-13); bundled-app acceptance pending
Size: Small, within the existing history and local pricing pipeline.
Approved: Henrik requested Today/Last 7 Days in statistics and investigation of an understated daily API-value estimate.

## Requirements
- FR-1: History offers Today, Yesterday, Last 7 Days, 30 Days, 90 Days, 1 Year and All. AC: totals, sources, models, chart and footprint use the selected local-calendar days; Yesterday excludes today and Last 7 Days includes today plus six earlier days.
- FR-2: The compact card also offers 7 Days. AC: both surfaces use the same calendar boundaries; controls fit the minimum Settings width in English and Norwegian.
- FR-3: Published rates exist for claude-fable-5-2, claude-haiku-5-5 and gemini-4-hydrogen. AC: cache and fast rates are respected, including Haiku's request-wide 100k prompt threshold; unknown models remain unpriced.
- FR-4: Adding a rate reprices retained previously unpriced events even when their files are unchanged. AC: daily totals update without deleting history, rereading unchanged logs or double counting. Pruned totals remain intact.
- FR-5: History warns when unpriced records are excluded from dollar totals. AC: users can distinguish token coverage from priced API value.
- CON-1: No production database edits, history deletion, paid calls, account changes, merge or release. No personal usage data or credentials in commits.

## Design and detailed slices
Extend SpendHistoryRange with three short ranges and centralize their local-calendar start/end filtering. Buckets remain daily because retained history is daily, not hourly. Use ViewThatFits for the History selectors to wrap into two rows or use a range menu at narrow widths. Single-day chart axes show dates, not hourly ticks.
Add sevenDays to SpendPeriod and its localized label. Update only the three missing published models in the bundled supplement. Extend supplement decoding to carry the long-context tier fields already supported by ModelRates; Haiku uses a 100,000-token prompt threshold. No guessed fallback rates.
On each scan, identify retained days with unpriced models that now resolve to rates, and union those days with normal affected days before the existing deduplication/recompute transaction. Reprice only sources still represented by retained events; keep pruned source totals. Unknown models are not repeatedly repriced.

## Build plan
1. Range, tier pricing and cached-repricing regression tests, then implement the model/scanner changes.
2. Add localized selectors and coverage warning; check native rendering, read-only production-data diagnostics on a disposable database copy, focused tests, full suite and build; deliver a review PR.

## Published pricing sources (checked 2026-11-13)
- Fable 5.2: https://platform.claude.com/docs/en/models/fable-5-2/overview
- Fable fast mode: https://platform.claude.com/docs/en/build-with-claude/fast-mode
- Haiku 5.5: https://platform.claude.com/docs/en/models/haiku-5-5/overview
- Gemini 4 Hydrogen: https://ai.google.dev/gemini-api/docs/pricing#gemini-4-hydrogen

## Verification
- All 27 focused spend/range/pricing/history tests pass, covering DST calendar boundaries, Yesterday exclusion, Last 7 Days totals/sources/models, published cache/fast rates, Haiku's 100k tier, and cached repricing without rereading or doubling.
- An authorized disposable copy of the real usage database repriced its previously unpriced current-day records with zero log reads. The live database was not changed. Personal amounts and counts are excluded from this document and the PR.
- Native History renders checked in English/Norwegian and light/dark, at 680pt and 900pt, for Today, Yesterday, Last 7 Days, cost/tokens/footprint, coverage warnings and the 340pt compact card. A Norwegian minimum-width clipping defect found during verification was fixed with the range-menu fallback.
- Full native suite: 263 tests, same 12 assertion failures across the same 6 cases reproduced before this change, involving installed Codex resolution, local accounts and English-only expectations under Norwegian locale.
- Native build and diff check pass. Bundled-app interaction remains untested because the default macOS Space was unavailable in the earlier checks in this chat. No installation or release.
- Unreadable logs, unrecorded activity, other devices, tool/storage charges and unsupported providers remain outside a complete billing claim.
