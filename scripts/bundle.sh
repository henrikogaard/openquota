#!/usr/bin/env bash
# Build openquota and package it into dist/OpenQuota.app with Sparkle embedded.
# Usage:
#   scripts/bundle.sh [version]
# Env (optional):
#   CODESIGN_IDENTITY       — e.g. "Developer ID Application"; default = ad-hoc "-"
#   MARKETING_VERSION       — CFBundleShortVersionString (default: arg or 0.1.0)
#   CURRENT_PROJECT_VERSION — CFBundleVersion (default: 1)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${MARKETING_VERSION:-${1:-0.1.0}}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="dist/OpenQuota.app"

echo "==> swift build -c release"
swift build -c release

# SPM may put products in a triple-scoped dir; resolve dynamically.
BIN="$(find .build -path '*/release/openquota' -type f 2>/dev/null | head -1)"
BRIDGE_BIN="$(find .build -path '*/release/openquota-bridge' -type f 2>/dev/null | head -1)"
BUILD_DIR="$(dirname "$BIN")"
[[ -n "$BIN" ]] || { echo "!! openquota binary not found under .build/*/release" >&2; exit 1; }
[[ -n "$BRIDGE_BIN" ]] || { echo "!! openquota-bridge binary not found under .build/*/release" >&2; exit 1; }

echo "==> assemble $APP (v$VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenQuota"
cp "$BRIDGE_BIN" "$APP/Contents/MacOS/openquota-bridge"
APP_BINARY="$APP/Contents/MacOS/OpenQuota"
BRIDGE_BINARY="$APP/Contents/MacOS/openquota-bridge"

# Info.plist with version substituted
sed -e "s/\$(MARKETING_VERSION)/$VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/${CURRENT_PROJECT_VERSION:-1}/g" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

# --- Embed Sparkle.framework (SwiftPM fetches it as an xcframework under .build/artifacts) ---
FRAMEWORKS="$APP/Contents/Frameworks"
SPARKLE_FW="$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -1)"
[[ -n "$SPARKLE_FW" ]] || SPARKLE_FW="$(find .build/artifacts -type d -name "Sparkle.framework" 2>/dev/null | head -1)"
if [[ -z "$SPARKLE_FW" ]]; then
    echo "!! Sparkle.framework not found under .build/artifacts — updates will be disabled" >&2
else
    rm -rf "$FRAMEWORKS/Sparkle.framework"
    ditto "$SPARKLE_FW" "$FRAMEWORKS/Sparkle.framework"

    # OpenQuota is not sandboxed — drop Sparkle's XPC services (avoids nested-XPC
    # signing failures some non-sandboxed apps hit).
    rm -rf "$FRAMEWORKS"/Sparkle.framework/Versions/*/XPCServices
    rm -f  "$FRAMEWORKS/Sparkle.framework/XPCServices"

    # Point the binary at Contents/Frameworks for @rpath/Sparkle.framework.
    if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
    fi
fi

# --- Sign ---
# Sign the framework first (deep is safe now that XPC services are gone), then
# the outer app WITHOUT --deep so the framework signature is preserved.
# --options runtime requires a real identity: on an ad-hoc signature it turns
# on library validation with no Team ID and dyld kills the app at launch.
SIGN_OPTS=()
[[ "$IDENTITY" != "-" ]] && SIGN_OPTS=(--options runtime --timestamp)
if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    # ${arr[@]+...} keeps empty-array expansion legal under bash 3.2 + set -u.
    codesign --force --deep ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --sign "$IDENTITY" \
        "$FRAMEWORKS/Sparkle.framework"
fi
codesign --force ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --sign "$IDENTITY" "$BRIDGE_BINARY"
codesign --force ${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"} --sign "$IDENTITY" "$APP"

echo "==> done: $APP"
