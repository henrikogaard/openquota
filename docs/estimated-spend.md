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
- Today, Yesterday, or 30 calendar days including today, in the Mac's time zone,
  in the popover; 30 days, 90 days, 1 year or all saved history under
  **Settings → History**.
- Separate Claude and Codex totals, in USD.

No browser, private usage endpoint, or subscription-token access is involved.
The opt-in concerns **local logs only**. Nothing is uploaded or sent to a pricing
service. The scanner reads JSONL lines transiently but retains only token counts,
model IDs, timestamps, request identities and costs—not prompts or responses.

## Saved history

Claude Code deletes its session logs after 30 days by default, so OpenQuota
keeps what it reads in a small SQLite database,
`~/Library/Application Support/openquota/usage.sqlite` (0600):

- **Files:** path, size, modification time and read position of each log. A
  file is read once, including across launches. When a Claude log grows, only
  the new lines are read; a large one is read across several passes. A Codex
  log is reread in full when it changes, because its totals are cumulative.
- **Requests:** per-request token counts, model, timestamp, request identity
  and source for the last 40 days, used to drop duplicates across files (a
  resumed Claude session copies earlier messages into a new file). Older
  requests are removed once every log has been read.
- **Days:** daily totals per source and model: input, cache-write, cache-read
  and output tokens, estimated and log-reported cost, priced and unpriced
  request counts. Kept until you delete them. No prompts or responses.

A **source** is the provider, the CLI home the log came from, and for Claude
the app that wrote it (Claude Code's `entrypoint`: CLI, Claude Desktop, Agent
SDK, …). History shows each source with the email of the matching connection
when known. Claude Desktop signs in separately, so its usage is not given the
CLI folder's email.

- Each pass reads new or changed files, newest first, taking turns between
  Claude and Codex, within the time and byte budget below. While older logs
  remain, passes repeat a few seconds apart; the panel says how many files are
  left. Each source folder has its own file and directory-entry budget.
- A source whose requests for a day were already removed keeps its totals for
  that day: its requests that show up later come from copied or resumed
  sessions. A different source (a newly connected folder) still counts.
- A file with lines that couldn't be used keeps the total marked partial
  until the file changes. A file rewritten without growing is read again from
  the start.
- A Codex file over 64 MiB, or one a whole pass can't finish, is skipped until
  it changes and counted as partial. Claude files have no size limit.
- Turning log reading off stops reading but keeps the database.
  **Settings → History → Delete History…** deletes it; the next scan rebuilds
  whatever the logs still hold.

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
- Files already read are recognised by path, size and modification time and
  skipped. Changed files are reread from their start so cumulative baselines
  stay valid.
- Only regular `.jsonl` files under the selected log roots are read; symlinks
  inside them are skipped. Credentials, settings and other files are ignored.
- Each pass is bounded to 20,000 directory entries and 2,000 files per source
  folder, 64 MiB per Codex file, 256 MiB of new reads, 1 MiB per line, 100,000
  events per file read, and a 10-second discovery/read budget. Daily totals are
  then rebuilt only for the days the pass touched.
- Exceeding a limit shows **Partial total**. It does not quietly claim zero
  spend. Old cache entries and removed sources/files are dropped.

The demo displays fixed synthetic values and does not read local logs.

## Verification

`swift test --filter SpendTests` covers token arithmetic, cache bucket splitting,
long-context and fast multipliers, bundled model resolution, unknown models,
recorded-cost precedence, request/replay deduplication, Codex cumulative deltas,
child replay filtering, cache refresh/deletion, scan limits and local calendar
boundaries (including daylight saving).
