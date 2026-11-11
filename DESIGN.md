# DESIGN

Goal: looks like Apple made it. Quiet, monochrome, one glance.

## Platform

macOS 26 Tahoe and later. The popover window keeps the system material; its cards are flat fills, not glass.

## Popover (compact flat cards)

- Title row: app name and account count. Optional local-spend tile below it:
  big total, period picker, and a thin bar splitting Claude and Codex.
- A small-caps "Plans" heading, then one **always-expanded flat card per
  provider** (quiet fill, hairline edge, no glass). The header is one line:
  glyph, name, experimental badge, account subtitle (truncated, full text in
  help), usage-page arrow.
- Every window remains visible on one line: small ring, label, short reset
  ("3d 8h · Sun"), percentage left. The percentage column is 38pt wide so
  values align. Windows without a meter keep the two-line row. A provider
  with several accounts adds a one-line account header above each group.
- Rings and percentages are grey until usage gets tight: orange at 80% used,
  red at 90%.
- Balances and errors stay visible; error text wraps in full. Last successful
  reading and source appear only for a saved (stale) reading or an error. The
  footer carries the overall update time.
- Accounts sharing one sign-in show a one-line "Shared with …" note; the full
  explanation is in its help text and the Settings detail.
- Bottom: freshness text, borderless Refresh button, and Options menu containing
  Add Account, Settings, Check for Updates, and Quit.
- Height follows content up to the screen height minus 140pt (never below
  600pt), then scrolls with no visible scrollbar and a soft edge fade.
- Settings meters show what's **left**: system accent normally, orange at 80% used, red at 90%.
- Menu bar (General → Menu Bar): icon only, percentage only, icon + percentage, or provider + percentage. Default is the lowest remaining percentage across all accounts; an account and optionally a specific window can be pinned. Never switch away from an unavailable pinned source. Hover/accessibility text identifies provider, account, window, timestamp, and cached state. Cached readings are dimmed; unavailable percentages show an em dash. Existing icon-only preferences are preserved.

## Settings (native toolbar tabs)

- All three tabs share one size (680 × 520pt), so switching tabs never resizes
  the window. General scrolls if its content grows past that.
- `TabView` toolbar tabs: Accounts, History and General. History shows a range
  picker (30 days, 90 days, 1 year, all), a cost/tokens switch, the total with
  a row per source (Claude CLI, Claude Desktop, each profile folder, Codex;
  email when known), a stacked bar chart per source (days, weeks or months;
  oranges for Claude, greens for Codex), top models, catch-up progress, and
  the saved-history note with Delete. Accounts has a Mail-style bordered
  list with a bottom +/− bar, alongside a grouped detail `Form`.
- Account rows separate provider, account label, and optional experimental badge.
  Long names have help text. Detail includes source, plan, usage, freshness, and
  replacement/recovery actions.
- Add Account is a searchable provider grid leading to a connection form.
  Tiles reserve two text lines; names are not shrunk to fit.
- Forms share a fixed bottom Cancel/primary action row outside scrolling content.
  Claude has a copyable separate-profile command and passive-update explanation.
  OpenCode Go distinguishes workspace keys from additional local sign-in files.
- Concise helper text may wrap. Never hide consent or credential-safety caveats
  merely to make a form shorter. All UI copy supports English and Norwegian.

## Glyphs

Monochrome SF Symbols per provider, monogram fallback. Never provider logos.

## Tokens

```css
:root {
  --oq-popover-width: 340px;
  --oq-popover-max-content-height: 600px;
  --oq-inset: 12px;
  --oq-module-spacing: 8px;
  --oq-module-radius: 10px;
  --oq-module-padding: 10px;
  --oq-meter-height: 6px;
  --oq-quota-value-width: 38px;
  --oq-meter-fill: AccentColor;
  --oq-meter-track: color-mix(in srgb, currentColor 10%, transparent);
  --oq-meter-warn: #ff9500;      /* >= 80% used */
  --oq-meter-critical: #ff3b30;  /* >= 90% used */
  --oq-font-title: 600 13px -apple-system, system-ui, sans-serif;
  --oq-font-section: 600 11px -apple-system, system-ui, sans-serif;
  --oq-font-metric: 400 11px -apple-system, system-ui, sans-serif;
}
```

```ts
export const tokens = {
  popoverWidth: 340,
  popoverMaxContentHeight: 600,
  inset: 12,
  moduleSpacing: 8,
  moduleRadius: 10,
  modulePadding: 10,
  meterHeight: 6,
  quotaValueWidth: 38,
  meterFill: "AccentColor",
  meterTrackOpacity: 0.1,
  warnThreshold: 0.8,
  criticalThreshold: 0.9,
} as const;
```

```json
{"popoverWidth": 340, "popoverMaxContentHeight": 600, "inset": 12, "moduleSpacing": 8,
 "moduleRadius": 10, "modulePadding": 10, "meterHeight": 6, "quotaValueWidth": 38,
 "meterFill": "AccentColor", "meterTrackOpacity": 0.1, "warnThreshold": 0.8, "criticalThreshold": 0.9}
```

Swift source of truth: `Tokens` in `Sources/OpenQuota/Components.swift`.

## Rules

- Numbers are monospaced and short ("62% left", "$18.75 left", "2h 14m").
- Color only carries meaning. No custom focus highlighters; retain native keyboard
  focus and accessibility behavior. SF Symbols only.
- Never invent a percentage: balances and activity show as amounts.
