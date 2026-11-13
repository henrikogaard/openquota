# Estimated Spend · This Mac

Enable **Estimated Spend** in the popover (with confirmation), or turn on
**Read local AI tool usage logs** under Settings → General.
It is off by default. Disable it there to stop scanning and clear the memory cache.

This is the **API-rate value of locally recorded activity**, not the price of
your subscription, a bill, or remaining quota. It does not predict your next
invoice or convert subscription percentages into dollars.

## What is included

- Claude Code JSONL usage under `~/.claude/projects`, or `CLAUDE_CONFIG_DIR`.
- Codex JSONL rollouts under `~/.codex/sessions` and `archived_sessions`, or
  `CODEX_HOME`, including the older ones Codex compresses to `.jsonl.zst`.
- The corresponding directories of explicitly connected Claude/Codex profiles.
- OpenCode: assistant messages in `~/.local/share/opencode/opencode.db` (or
  under `XDG_DATA_HOME`), opened read-only. Each message has its own token
  counts and cost.
- Mistral Vibe: the `meta.json` of each session under `~/.vibe/logs/session`
  (or `VIBE_HOME`). A session is one entry, on the day it started.
- GitHub Copilot CLI: `session.shutdown` events in
  `~/.copilot/session-state/*/events.jsonl` (or `COPILOT_HOME`). Usage shows
  up when a session shuts down, on that day; a session still running is not
  counted yet.
- Google Antigravity (**experimental, best guess**): one entry per model
  generation in each conversation database under
  `~/.gemini/antigravity/conversations/*.db`, opened read-only. Antigravity
  publishes no format for these; see [Antigravity](#antigravity-experimental)
  for what is confirmed and what is inferred.
- Today, Yesterday, or 30 calendar days including today, in the Mac's time zone,
  in the popover; 30 days, 90 days, 1 year or all saved history under
  **Settings → History**.
- Separate totals per tool, in USD. Claude and Codex are always listed; the
  others appear once they have usage in the period.

No browser, private usage endpoint, or subscription-token access is involved.
The opt-in concerns **local logs only**. Nothing is uploaded or sent to a pricing
service. The scanner reads JSONL lines transiently but retains only token counts,
model IDs, timestamps, request identities and costs—not prompts or responses.
From OpenCode's database it selects only the message id, timestamps, model,
cost and token counts; message text is in other tables and is never queried.
The database is opened read-only and never changed; SQLite may create
its own `-shm`/`-wal` side files next to it if they are missing.
A database that is locked or can't be read is not remembered as read: the
total is marked partial and it is tried again on the next pass.
An Antigravity record is a binary blob that also holds conversation text.
The reader walks it by field number and takes out only the token counts, the
model id, the response id and the step time; text fields are skipped by
length and never read as text, logged or stored. A value in the model field that
is not shaped like a model id is dropped.

## Saved history

Claude Code deletes its session logs after 30 days by default, so OpenQuota
keeps what it reads in a small SQLite database,
`~/Library/Application Support/openquota/usage.sqlite` (0600):

- **Files:** path, size, modification time and read position of each log. A
  file is read once, including across launches. When a Claude log grows, only
  the new lines are read; a large one is read across several passes. A Codex
  log is reread in full when it changes, because its totals are cumulative.
  A Copilot log is read on from where it stopped, with the totals already
  counted remembered; a Vibe session file and an Antigravity conversation
  database are reread in full.
- **Requests:** per-request token counts, model, timestamp, request identity
  and source for the last 40 days, used to drop duplicates across files (a
  resumed Claude session copies earlier messages into a new file). Older
  requests are removed once every log has been read. A pass that was
  cancelled mid-read, or whose folder walk was cut short, removes nothing.
- **Days:** daily totals per source and model: input, cache-write, cache-read
  and output tokens, estimated and log-reported cost, priced and unpriced
  request counts. Kept until you delete them. No prompts or responses.

A **source** is the provider, the CLI home the log came from, and for Claude
the app that wrote it (Claude Code's `entrypoint`: CLI, Claude Desktop, Agent
SDK, …). History shows each source with the email of the matching connection
when known. Claude Desktop signs in separately, so its usage is not given the
CLI folder's email.

- A compressed Codex rollout is read from start to end in one go, once: a
  compressed stream can't be picked up half-way, and these archives don't
  change. It counts as the same log as the plain file it was made from, so
  a rollout read before and after compression counts once while its requests
  are still kept (40 days). A day whose requests were already removed keeps
  the totals it had: older days OpenQuota only partly saw before this stay
  as they were, until you delete history and let it rebuild.
- Each pass reads new or changed files, newest first, taking turns between
  Claude and Codex, within the time and byte budget below. While older logs
  remain, passes repeat a few seconds apart; the panel says how many files are
  left. Each source folder has its own file and directory-entry budget.
- A source whose requests for a day were already removed keeps its totals for
  that day: its requests that show up later come from copied or resumed
  sessions. A different source (a newly connected folder) still counts.
- A file with lines that couldn't be used keeps the total marked partial
  until the file changes. A Codex `response_item` line over the line limit (a
  whole tool output) is the exception: it never carries token counts, so it
  is skipped without marking the file. A file rewritten without growing is read again from
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
Compressed logs are read with [Zstandard](https://github.com/facebook/zstd)
(BSD licence), built from source by SwiftPM and linked into the app.
The upstream supplement snapshot is dated **2026-09-30**, with targeted
OpenQuota additions checked on **2026-11-13** for Fable 5.2, Haiku 5.5 and
Gemini 4 Hydrogen. The catalogs include their own
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
   For OpenCode, Vibe and Copilot, a model written with dots
   (`claude-sonnet-4.6`) is also tried with hyphens (`claude-sonnet-4-6`).
   OpenCode's per-message `cost` and Vibe's `session_cost` win when above
   zero, as **Log-reported**; a zero is treated as "not recorded" and the
   API rate is estimated instead, because subscription and free models
   record zero. Copilot records no dollar cost. OpenCode reasoning tokens
   count as output. Vibe and Copilot prompt/input counts include cached
   tokens, which are split out as cache reads.
4. Unknown models are **excluded and counted as unpriced**, never priced using
   an invented default. There is no automatic reference-model fallback.
5. Repeated Claude message/request IDs are deduplicated; parent records win
   over sidechain replays, followed by richer token/speed records.
   OpenCode messages are read in order of update time and id, a page at a
   time. A message updated after it was first read (it finished later)
   is read again and the larger record wins. A Copilot session that is
   resumed and shut down again without new work repeats its totals; identical
   totals in one file count once. Whether a later, larger total in a resumed
   Copilot session is cumulative is **not confirmed**: both shapes were seen,
   and each differing total is counted, so such a session may be overcounted.
   A Vibe session resumed more than 40 days after it started keeps the total
   it had then; the later usage is not added.
   An Antigravity generation is identified by its response id, so a
   conversation database copied elsewhere counts once.
6. Codex uses per-turn counts where supplied, otherwise differences between
   cumulative snapshots. Repeated snapshots are ignored. Child-session replay
   seeds the cumulative baseline but is not charged again; a live task-start
   event unlocks child usage. Copied/archived rollouts deduplicate by session,
   timestamp, model and token signature.

The displayed total can combine log-reported and estimated cost. When recorded
cost is present, both subtotals are shown. Missing pricing, unreadable files,
malformed usage records and resource limits produce visible warnings rather
than a claim that the total is complete.

## Estimated footprint

**Settings → History → Footprint** turns the saved token totals into estimated
data-centre electricity, CO2e and cooling water. These are **estimates, not
measurements**: neither Anthropic nor OpenAI publishes energy per token, so
every figure is shown with a low–high range. Nothing is fetched; the factors
are fixed in `Sources/OpenQuotaCore/Spend/Footprint.swift` and change only with
an app update.

| Factor | Value | Basis |
|---|---|---|
| Electricity per 1,000 output tokens, standard-size model, data-centre overhead included | 0.3 / 1.0 / 3.0 Wh (low / central / high) | Low: Google's measured median Gemini text prompt, 0.24 Wh ([2025](https://cloud.google.com/blog/products/infrastructure/measuring-the-environmental-impact-of-ai-inference)). Central: Epoch AI's method scaled to Claude by [Couch (2026)](https://simonpcouch.com/blog/2026-01-20-cc-impact/), 0.99 Wh; Epoch's own GPT-4o figure is about 0.6 ([2025](https://epoch.ai/gradient-updates/how-much-energy-does-chatgpt-use)). High: a fit to Jegham et al. ([arXiv 2505.09598](https://arxiv.org/abs/2505.09598)) |
| Input token against output token | 0.2 | **Assumption**, taken from the API price ratio. No measured ratio exists for hosted models |
| Cache write against input | 1.25 | **Assumption**, from the price multiplier |
| Cache read against input | 0.1 | **Assumption**, from the price discount. No published energy measurement |
| Model size | small 0.25×, standard 1×, large 2× | **Assumption**. Read from whole words in the model name: haiku, mini, nano, flash, spark or small is small; opus, fable, mythos or pro is large; everything else, unknown names included, is standard |
| On-site cooling water | 0.15 / 0.65 / 1.15 mL per Wh | AWS 2024 (0.15 L/kWh) to Google 2024 (1.15 L/kWh); the central value is their midpoint. Water used to generate the electricity is not included |
| Grid carbon intensity, g CO2e/kWh | United States 384, World 458, EU 210, Germany 330, United Kingdom 217, France 41, Sweden 35, Norway 28 | 2025, Ember: countries via [Our World in Data](https://ourworldindata.org/grapher/carbon-intensity-electricity), World and EU from Ember's Global Electricity Review 2026 |

- Energy = (output + 0.2 × (input + 1.25 × cache write + 0.1 × cache read))
  ÷ 1,000 × size multiplier × Wh factor. Codex reasoning tokens are already
  part of output.
- **Saved by caching** is the central estimate of what the cache-read tokens
  would have cost as plain input, minus what they cost as cache reads. It
  rests entirely on the assumed 0.1 factor.
- CO2e multiplies the electricity by the grid you pick. The default is the
  United States, where most of this traffic is served. Your own grid is not
  the data centre's grid, and providers' clean-power purchases are unknown.
- The everyday comparisons use a 100 W TV, a 50 W laptop, a 15 Wh phone charge
  and a 10 W LED bulb, on the central estimate.
- Training, hardware manufacturing, networks and your own Mac are not included.
- Unlike cost, the footprint counts every model with tokens, priced or not.

`swift test --filter FootprintTests` covers the token weights, size classes,
ranges, grid and water arithmetic, and the History totals, buckets and
per-model rows.

## Resource bounds

- One actor performs scans away from the UI executor, at most once every five
  minutes; Refresh can request another scan but never overlaps a running scan.
- Files already read are recognised by path, size and modification time and
  skipped. Changed files are reread from their start so cumulative baselines
  stay valid.
- Only regular `.jsonl` files (and `.jsonl.zst` for Codex) under the selected Claude and Codex log roots,
  `events.jsonl` under Copilot's, `meta.json` under Vibe's (16 MiB at most),
  `.db` files under Antigravity's conversations folder,
  and OpenCode's one database are read; symlinks inside them are skipped.
  OpenCode's folder is never walked. Credentials, settings and other files
  are ignored.
- Each pass is bounded to 200,000 directory entries per source folder, 2,000
  files not read yet per source folder, 256 MiB of new reads, 1 MiB per line,
  100,000 events per file read, and a 10-second discovery/read budget. Files
  already read don't count against the 2,000, so a folder with more files is
  worked through over several passes instead of being cut off; the panel says
  how many are left. A compressed rollout may decompress to at most 4 GiB and
  hold at most 1,000,000 requests (the 100,000-event bound applies to plain
  logs), and is finished once started, so it can run past the time budget; it
  counts against the byte budget by its compressed size, several times less
  than what is actually read.
  Daily totals are then rebuilt only for the days the pass touched.
- Exceeding a limit shows **Partial total**. It does not quietly claim zero
  spend. Old cache entries and removed sources/files are dropped.

The demo displays fixed synthetic values and does not read local logs.

## Antigravity (experimental)

Antigravity documents none of this. The mapping below was worked out from
field numbers and integer values in seven real conversation databases (800
generation records) on one Mac, in November 2026. It can break without
notice when Antigravity changes its storage.

Each conversation is a SQLite database with a `gen_metadata` table (one
protobuf record per model generation) and a `steps` table. Paths are protobuf
field numbers.

| What | Where | Status |
| --- | --- | --- |
| Input tokens, without the cached part | `gen_metadata.data` 1.4.2 | Inferred from size and from Windsurf's similar usage record |
| Output tokens, thinking included | 1.4.3 | Inferred; 1.4.9 + 1.4.10 = 1.4.3 in 790 of 790 records |
| Cache-read tokens | 1.4.5 | Inferred; present in 698 of 790, far larger than 1.4.2 |
| Cache-write tokens | not read | Field 4 was never present, so nothing is counted |
| Model id | 1.19 | Confirmed: one name per model number (1.3) in all records |
| Response id | 1.4.7 | Confirmed: unique per record, repeated in exactly one step |
| Time | `steps.metadata` 1.1 (seconds) and 1.2 (nanoseconds) of the step whose 9.7 is that response id | Confirmed for all 792 records that have an id; the step's field 9 is byte-for-byte the record's 1.4 |
| Second copy of the counts | 1.17.2 | Confirmed identical to 1.4 in 792 of 792; not read, so nothing is counted twice |

Known limits:

- Whether 1.4.2 really excludes cached tokens, and whether 1.4.5 is cache
  reads rather than something else, is **not confirmed**. If wrong, token
  totals and estimates are off.
- Antigravity's model ids (`gemini-4-argon` and the like) are internal names.
  One with no bundled price is counted as unpriced, never priced by guess.
- A generation whose step is not written yet takes the time of the
  generation before it; the first one in a conversation is left out until
  its step exists.
- A record whose counts are missing, zero or above one billion is skipped.
- A closed conversation (no `-wal` file) is read as a plain file, so no side
  files are created next to it. One that Antigravity has open is read through
  its write-ahead log; SQLite may then create a missing `-shm` file.
- A database that is busy or unreadable keeps the totals read before, shows
  **Partial total**, and is tried again on the next pass.
- Reading stops at the pass's byte and time budget. A conversation cut short
  by what other files used is read again on the next pass; one too large for
  a whole pass keeps what was read and shows **Partial total**.
- No environment variable for another location is known, so only the default
  folder is read.

## Verification

`swift test --filter ToolUsageTests` covers the OpenCode, Vibe, Copilot and
Antigravity readers, their token splits, the read-only database open,
re-reading a grown session or updated message without double counting, the
protobuf reader on malformed bytes, and default locations. The Antigravity
tests use synthetic records only.

`swift test --filter CompressedLogTests` covers zstd decompression (large,
empty, multi-frame, damaged, cut-off and oversized input), compressed Codex
rollouts in the scanner, a plain log and its compressed copy counting once,
and a folder larger than one pass.

`swift test --filter SpendTests` covers token arithmetic, cache bucket splitting,
long-context and fast multipliers, bundled model resolution, unknown models,
recorded-cost precedence, request/replay deduplication, Codex cumulative deltas,
child replay filtering, cache refresh/deletion, scan limits and local calendar
boundaries (including daylight saving).

## Short ranges and missing prices

History includes Today, Yesterday and Last 7 Days, alongside the existing longer
ranges. Days follow this Mac's local calendar; Last 7 Days includes today plus
six earlier days. Single-day charts are daily totals, not hourly activity.
At narrow Settings widths, the range selector uses a menu so all options remain
accessible. The compact Estimated Spend card also offers 7 Days.

Models without known prices still contribute token counts, but not dollar
value. History warns about those exclusions and about unreadable log records.
When an app update adds a missing rate, retained previously unpriced request
records are repriced on the next scan, even if their logs have not changed.
This preserves deduplication and does not delete history. Already pruned request
records cannot be reconstructed from daily token aggregates alone, so their
saved totals are retained.

The targeted rate additions use the published [Fable 5.2 rates](https://platform.claude.com/docs/en/models/fable-5-2/overview),
[Fable fast pricing](https://platform.claude.com/docs/en/build-with-claude/fast-mode),
[Haiku 5.5 rates](https://platform.claude.com/docs/en/models/haiku-5-5/overview),
and [Gemini 4 Hydrogen rates](https://ai.google.dev/gemini-api/docs/pricing#gemini-4-hydrogen).
Haiku's 100k prompt threshold applies to the whole request, including cache
and output rates. These changes do not turn local token estimates into a
complete record of account billing or activity on other devices.
