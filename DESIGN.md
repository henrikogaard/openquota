# DESIGN

Tiny surface, so tokens are deliberately few. Goal: looks like Apple made it.

## Tokens

```css
--popover-width: 320px;
--card-radius: 8px;
--card-fill: quaternary @ 50%;
--meter-height: ~4pt;        /* ProgressView scaled 0.7 vertically */
--meter-ok: accentColor;
--meter-warn: orange;        /* >70% consumed */
--meter-critical: red;       /* >90% consumed */
--stale-badge: orange @ 20%;
--text-primary: primary;
--text-secondary: secondary;
--text-tertiary: tertiary;
```

```ts
export const tokens = {
  popoverWidth: 320,
  cardRadius: 8,
  warnThreshold: 0.7,
  criticalThreshold: 0.9,
} as const;
```

```json
{"popoverWidth": 320, "cardRadius": 8, "warnThreshold": 0.7, "criticalThreshold": 0.9}
```

## Rules

- Numbers are monospaced (`monospacedDigit`), short ("82% left", "Resets in 2h").
- One card per account; provider name headline + account label secondary.
- Meters are thin and quiet; color only carries meaning past 70%.
- No focus rings, no chrome beyond the card fill. SF Symbols only.
