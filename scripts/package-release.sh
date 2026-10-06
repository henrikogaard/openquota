#!/usr/bin/env bash
# Notarize + dmg the bundled app. Mirrors linkrouter's package-release.sh.
set -euo pipefail
: "${VERSION:?}" "${APPLE_TEAM_ID:?}" "${APPSTORE_API_KEY_ID:?}" "${APPSTORE_ISSUER_ID:?}" "${APPSTORE_API_PRIVATE_KEY:?}"
APP_NAME="${APP_NAME:-OpenQuota}"
APP="dist/${APP_NAME}.app"
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openquota-notary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
KEY="$WORK/AuthKey.p8"
printf '%s\n' "$APPSTORE_API_PRIVATE_KEY" > "$KEY"
notarize() {
  xcrun notarytool submit "$1" --key "$KEY" \
    --key-id "$APPSTORE_API_KEY_ID" --issuer "$APPSTORE_ISSUER_ID" \
    --wait --timeout 20m --output-format json > "$WORK/result.json"
  python3 - "$WORK/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    sys.exit('Notarization was not accepted: ' + str(result.get('status')))
PY
  xcrun stapler staple "$2"
  xcrun stapler validate "$2"
}
codesign --verify --deep --strict --verbose=2 "$APP"
EXEC_NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")
for architecture in arm64 x86_64; do
  xcrun lipo "$APP/Contents/MacOS/${EXEC_NAME}" -verify_arch "$architecture" || true
done
ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
notarize "$WORK/submit.zip" "$APP"
spctl --assess --type execute --verbose=2 "$APP"
mkdir -p "$WORK/image" dist
ditto "$APP" "$WORK/image/${APP_NAME}.app"
ln -s /Applications "$WORK/image/Applications"
DMG="dist/${APP_NAME}-${VERSION}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "$WORK/image" -ov -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG" "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
(cd dist && shasum -a 256 "${APP_NAME}-${VERSION}.dmg" > SHA256SUMS)
