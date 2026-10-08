# DESIGN

Goal: looks like Apple made it. Quiet, monochrome, one glance.

## Platform

macOS 26 Tahoe and later. Real Liquid Glass (`glassEffect`, `.glass` buttons) — no hand-made blur or opaque fills.

## Popover (Control Center style)

- No title bar or oversized headline ring. Optional local-spend summary at the top.
- One **always-expanded glass module per provider** (one `GlassEffectContainer`
  inside the scroll view, separate from the fixed footer).
  Provider name, account subtitle, and experimental badge have separate lines
  rather than competing in a single crowded row.
- Every window remains visible: label, reset time, meter, percentage left.
  The trailing value column is 72pt wide so stacked meters align.
  Long window/reset labels stack vertically instead of clipping.
- Balances, source, last successful reading, and errors stay visible. Error text
  wraps in full; the popover scrolls rather than hiding recovery instructions.
- Bottom: freshness text, circular Refresh button, and Options menu containing
  Add Account, Settings, Check for Updates, and Quit.
- Height follows content, scrolling past 600pt.
- Meters show what's **left**: system accent normally, orange at 80% used, red at 90%.
- Scroll content reserves a 16pt trailing gutter so the native scrollbar never overlaps provider cards.
- Menu bar (General → Menu Bar): icon only, percentage only, icon + percentage, or provider + percentage. Default is the lowest remaining percentage across all accounts; an account and optionally a specific window can be pinned. Never switch away from an unavailable pinned source. Hover/accessibility text identifies provider, account, window, timestamp, and cached state. Cached readings are dimmed; unavailable percentages show an em dash. Existing icon-only preferences are preserved.

## Settings (native toolbar tabs)

- `TabView` toolbar tabs: Accounts and General. Accounts has a Mail-style bordered
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
  --oq-module-radius: 16px;
  --oq-module-padding: 12px;
  --oq-meter-height: 6px;
  --oq-quota-value-width: 72px;
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
  moduleRadius: 16,
  modulePadding: 12,
  meterHeight: 6,
  quotaValueWidth: 72,
  meterFill: "AccentColor",
  meterTrackOpacity: 0.1,
  warnThreshold: 0.8,
  criticalThreshold: 0.9,
} as const;
```

```json
{"popoverWidth": 340, "popoverMaxContentHeight": 600, "inset": 12, "moduleSpacing": 8,
 "moduleRadius": 16, "modulePadding": 12, "meterHeight": 6, "quotaValueWidth": 72,
 "meterFill": "AccentColor", "meterTrackOpacity": 0.1, "warnThreshold": 0.8, "criticalThreshold": 0.9}
```

Swift source of truth: `Tokens` in `Sources/OpenQuota/Components.swift`.

## Rules

- Numbers are monospaced and short ("62% left", "$18.75 left", "2h 14m").
- Color only carries meaning. No custom focus highlighters; retain native keyboard
  focus and accessibility behavior. No custom fills behind system glass. SF Symbols only.
- Never invent a percentage: balances and activity show as amounts.
