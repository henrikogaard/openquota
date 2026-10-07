# Estimated Spend · This Mac

Enable **Estimated Spend** in the popover (with confirmation), or turn on
**Read Local Claude & Codex Usage Logs** under Settings → General.
It is off by default. Disable it there to stop scanning and clear the memory cache.

This is the **API-rate value of locally recorded activity**, not the price of
your subscription, a bill, or remaining quota. It does not predict your next
invoice or convert subscription percentages into dollars.

## What is included

- Claude Code JSONL usage under `~/.claude/projects`, or `CLAUDE_CONFIG_DIR`.
- Codex JSONL rollouts under `~/.codex/sessions` and `archived_sessions`, or
  `CODEX_HOME`.
- The corresponding directories of explicitly connected Claude/Codex profiles.
- Today, Yesterday, or 30 calendar days including today, in the Mac's time zone.
- Separate Claude and Codex totals, in USD.

No browser, private usage endpoint, or subscription-token access is involved.
The opt-in concerns **local logs only**. Nothing is uploaded or sent to a pricing
service. The scanner reads JSONL lines transiently but retains only token counts,
model IDs, timestamps, request identities and costs—not prompts or responses.
No usage cache is written to disk.

Other devices, deleted logs, unsupported tools and disabled/unrecorded logging
are not covered. Default CLI directories can contain several logins' history.
We do not relabel that history as the currently signed-in subscription, combine
it with API billing dashboards, or attach it to a guessed account. Identity is
preserved while parsing and deduplicating requests; the panel deliberately
reports machine-local provider totals.

## Pricing and normalization

OpenQuota adapts OpenUsage's shared pricing engine, including its bundled
LiteLLM/models.dev snapshots and supplement, from
[`robinebers/openusage` at `cb21465`](https://github.com/robinebers/openusage/tree/cb21465e3d88d8b2075ca48d38c936b82177fb78).
The MIT notice is shipped in the pricing resource bundle as `OpenUsage-LICENSE.txt`.
The supplement's timestamp is **2026-09-30**. The catalogs include their own
retrieval timestamps. Prices are bundled snapshots, updated by an app update;
this version does not download live pricing or maintain historical tariffs.
They represent the bundled API rates, even for older requests.

1. A valid recorded Claude `costUSD` wins, including zero. It is labeled
   **Log-reported**, not verified billing data.
2. Otherwise, model aliases and the supplement resolve first, followed by
   LiteLLM and exact models.dev gap-filling. Date suffixes can match; numeric
   version continuations cannot silently match an older model.
3. Cost uses disjoint input, 5-minute cache-write, 1-hour cache-write,
   cache-read and output buckets. Request-wide long-context and supported
   fast/priority rates are included. Codex does not assume an unpublished cache
   discount. Reasoning tokens are not added to Codex output a second time.
4. Unknown models are **excluded and counted as unpriced**, never priced using
   an invented default. There is no automatic reference-model fallback.
5. Repeated Claude message/request IDs are deduplicated; parent records win
   over sidechain replays, followed by richer token/speed records.
6. Codex uses per-turn counts where supplied, otherwise differences between
   cumulative snapshots. Repeated snapshots are ignored. Child-session replay
   seeds the cumulative baseline but is not charged again; a live task-start
   event unlocks child usage. Copied/archived rollouts deduplicate by session,
   timestamp, model and token signature.

The displayed total can combine log-reported and estimated cost. When recorded
cost is present, both subtotals are shown. Missing pricing, unreadable files,
malformed usage records and resource limits produce visible warnings rather
than a claim that the total is complete.

## Resource bounds

- One actor performs scans away from the UI executor, at most once every five
  minutes; Refresh can request another scan but never overlaps a running scan.
- Unchanged files reuse parsed metadata by path, size and modification time.
  Changed files are reread from their start so cumulative baselines stay valid.
- Only regular `.jsonl` files under the selected log roots are read; symlinks
  inside them are skipped. Credentials, settings and other files are ignored.
- Each pass is bounded to 20,000 directory entries, 2,000 files, 64 MiB per file,
  256 MiB of new reads, 1 MiB per line, 100,000 retained usage events, and a
  10-second discovery/read budget. The subsequent in-memory pricing pass is
  bounded by the retained event count.
- Exceeding a limit shows **Partial total**. It does not quietly claim zero
  spend. Old cache entries and removed sources/files are dropped.

The demo displays fixed synthetic values and does not read local logs.

## Verification

`swift test --filter SpendTests` covers token arithmetic, cache bucket splitting,
long-context and fast multipliers, bundled model resolution, unknown models,
recorded-cost precedence, request/replay deduplication, Codex cumulative deltas,
child replay filtering, cache refresh/deletion, scan limits and local calendar
boundaries (including daylight saving).
