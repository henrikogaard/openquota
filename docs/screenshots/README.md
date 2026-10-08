# README screenshots

- `popover-light.png`: English, light appearance.
- `popover-dark-nb.png`: Norwegian Bokmål, dark appearance.

Captured from the native macOS 26 demo app after the footer/glass-container
fix in `66155ff`. The images are cropped from the verified native captures,
not mockups. All readings are synthetic; no real accounts or credentials appear.

To refresh them, bundle the app using `bash scripts/bundle.sh`, quit any older
instance, then launch `dist/OpenQuota.app` with `--demo`. Use English/light and
Norwegian/dark appearance, open the popover at its top scroll position, and
capture the native window. Preserve the Demo Data footer, inspect the rendered
images, and keep both screenshots at the same scale.
