# DESIGN

Goal: looks like Apple made it. Quiet, monochrome, one glance.

## Popover

- No cards. Providers are small secondary section titles; accounts sit beneath them.
- Each quota window is one line (label · reset · value) over a 4pt hairline meter.
- The meter shows what's **left**, in neutral `primary @ 55%`. Orange at 80% used, red at 90%.
- Stale readings: tertiary "Updated 5m ago" on the account line. Errors: one orange caption line.
- Header holds the only actions: refresh and `⋯` (Settings, Check for Updates, Quit).
- Menu bar: gauge + tightest "% left"; stale dims the number to 50%.

## Settings

- Two tabs: Accounts and General.
- Accounts is Mail-style: sidebar list grouped by source, detail form on the right, +/− under the list.
- Add Account is a sheet with a searchable provider list and a short form per provider. One line of help text, max.

## Tokens

```css
:root {
  --oq-popover-width: 320px;
  --oq-inset: 16px;
  --oq-section-spacing: 18px;
  --oq-meter-height: 4px;
  --oq-meter-fill: color-mix(in srgb, currentColor 55%, transparent);
  --oq-meter-track: color-mix(in srgb, currentColor 8%, transparent);
  --oq-meter-warn: #ff9500;      /* >= 80% used */
  --oq-meter-critical: #ff3b30;  /* >= 90% used */
  --oq-font-title: 600 13px -apple-system, system-ui, sans-serif;
  --oq-font-section: 600 11px -apple-system, system-ui, sans-serif;
  --oq-font-metric: 400 11px -apple-system, system-ui, sans-serif;
}
```

```ts
export const tokens = {
  popoverWidth: 320,
  inset: 16,
  sectionSpacing: 18,
  meterHeight: 4,
  meterFillOpacity: 0.55,
  meterTrackOpacity: 0.08,
  warnThreshold: 0.8,
  criticalThreshold: 0.9,
} as const;
```

```json
{"popoverWidth": 320, "inset": 16, "sectionSpacing": 18, "meterHeight": 4,
 "meterFillOpacity": 0.55, "meterTrackOpacity": 0.08, "warnThreshold": 0.8, "criticalThreshold": 0.9}
```

Swift source of truth: `Tokens` in `Sources/OpenQuota/PopoverView.swift`.

## Rules

- Numbers are monospaced and short ("62% left", "$18.75 left", "2h 14m").
- Color only carries meaning. No focus rings, no fills, no badges. SF Symbols only.
- Never invent a percentage: balances and activity show as amounts.
