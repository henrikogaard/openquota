# Development and verification

[README](../README.md) · [Design](../DESIGN.md) · [Provider details](providers.md)

## Build locally

Use macOS 26 Tahoe and Xcode 26 / Swift 6.2 or newer for the native app.
The Foundation core also builds on Linux with Swift 6.1.

```bash
swift build
swift test
```

On macOS, create an ad-hoc development bundle with Sparkle and the Claude bridge:

```bash
scripts/bundle.sh
open dist/OpenQuota.app --args --demo
```

Quit a running OpenQuota instance first. Demo mode uses synthetic readings and
disables account changes and network fetches. It is for layout inspection, not
live provider validation. `swift run openquota` is also useful during development;
build first so the sibling `openquota-bridge` is available for Claude setup.

## Where changes belong

- `Sources/OpenQuota/`: native SwiftUI/AppKit shell, settings, and account forms.
- `Sources/OpenQuotaCore/`: models, providers, credential storage, refresh engine,
  CLI bridges, and local spend estimation.
- `Tests/OpenQuotaCoreTests/`: parsing, refresh, storage, and account regression tests.
- `Resources/`: app metadata and icon.
- `scripts/`: bundling, signing, notarization, and release helpers.

Keep credentials out of fixtures, snapshots, logs, and commits. Prefer synthetic
responses and isolated temporary account directories to real sign-ins.
User-facing text must support English and Norwegian Bokmål.

## Verification gates

| Change | Minimum evidence |
|---|---|
| Core behavior | Focused regression tests, then `swift test` and `swift build` |
| SwiftUI/AppKit | Native macOS build and bundled-app inspection; Linux excludes these paths |
| Layout/copy | English/Norwegian, light/dark, long labels, empty/error/stale readings |
| Account flow | Add, cancel, replace, remove, isolation, and keyboard actions with synthetic credentials |
| Quota mapping | Fixture tests plus a separately authorized live dashboard comparison |
| Resource behavior | Bounded-state tests and timed CPU/RSS sampling with scenario and duration recorded |
| Updates | Signed disposable old/new bundles, installed version, signature/notarization, and relaunch |

Use `git diff --check` before committing. There is no separately configured Swift
linter. Avoid repeated pushes solely to rerun checks: GitHub Actions usage is
metered. CI currently runs build and core tests on Linux, not native UI tests.

Fixtures do not prove live accuracy. A short memory sample does not prove leak
freedom. A simulated wake notification does not prove physical sleep/wake.
Record these limitations rather than turning a missing check into a pass.

## Release safety

The `v*` tag workflow signs, notarizes, packages, and publishes an update. Do not
create a tag as part of routine verification. Release only with explicit approval
and the credentials described in the [README](../README.md#auto-update--releases).

An ad-hoc development bundle is not a notarized release. Test updates on disposable
copies, never by replacing a user's installed app without permission.
