# DESIGN

Goal: looks like Apple made it. Quiet, monochrome, one glance.

## Platform

macOS 26 Tahoe and later. Real Liquid Glass (`glassEffect`, `.glass` buttons) — no hand-made blur or opaque fills.

## Popover (Control Center style)

- No title bar. Top: a **headline module** for the single window closest to running out — ring, big "16% left", provider · account · window, "Resets in 1h 5m".
- One **glass module per provider** (all in one `GlassEffectContainer`), monochrome glyph + name. Collapsed: one line per account (label · tightest meter · value). Click to expand: every window, balance, freshness, errors, usage-page link.
- Stale/error collapse to a small glyph in the module header (clock / orange triangle); the text lives in the expanded view.
- Bottom: a row of circular glass buttons — Refresh, Add Account (opens Settings straight into the sheet), Settings, ⋯ (Check for Updates, Quit).
- Height follows content, scrolling past 520pt.
- Meters/rings show what's **left**, neutral `primary @ 60%`; orange at 80% used, red at 90%.
- Scroll content reserves a 16pt trailing gutter so the native scrollbar never overlaps provider cards.
- Menu bar (General → Menu Bar): icon only, percentage only, icon + percentage, or provider + percentage. Default is the lowest remaining percentage across all accounts; an account and optionally a specific window can be pinned. Never switch away from an unavailable pinned source. Hover/accessibility text identifies provider, account, window, timestamp, and cached state. Cached readings are dimmed; unavailable percentages show an em dash. Existing icon-only preferences are preserved.

## Settings (System Settings style)

- `NavigationSplitView`: glass sidebar with General, then accounts grouped by source (glyph + provider + label). `+` in the toolbar.
- Detail is a grouped `Form`: provider, label (editable for keys), source, plan, live meters, notes, usage page, Remove Account….
- Add Account is a sheet: searchable grid of provider tiles → pushes a short form. One line of help text, max.

## Glyphs

Monochrome SF Symbols per provider, monogram fallback. Never provider logos.

## Tokens

```css
:root {
  --oq-popover-width: 340px;
  --oq-popover-max-content-height: 520px;
  --oq-inset: 12px;
  --oq-module-spacing: 8px;
  --oq-module-radius: 16px;
  --oq-module-padding: 12px;
  --oq-meter-height: 5px;
  --oq-meter-fill: color-mix(in srgb, currentColor 60%, transparent);
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
  popoverMaxContentHeight: 520,
  inset: 12,
  moduleSpacing: 8,
  moduleRadius: 16,
  modulePadding: 12,
  meterHeight: 5,
  meterFillOpacity: 0.6,
  meterTrackOpacity: 0.1,
  warnThreshold: 0.8,
  criticalThreshold: 0.9,
} as const;
```

```json
{"popoverWidth": 340, "popoverMaxContentHeight": 520, "inset": 12, "moduleSpacing": 8,
 "moduleRadius": 16, "modulePadding": 12, "meterHeight": 5,
 "meterFillOpacity": 0.6, "meterTrackOpacity": 0.1, "warnThreshold": 0.8, "criticalThreshold": 0.9}
```

Swift source of truth: `Tokens` in `Sources/OpenQuota/Components.swift`.

## Rules

- Numbers are monospaced and short ("62% left", "$18.75 left", "2h 14m").
- Color only carries meaning. No focus rings, no custom fills behind system glass. SF Symbols only.
- Never invent a percentage: balances and activity show as amounts.
