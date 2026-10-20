#!/usr/bin/env bash
# Local Developer ID release; credentials remain in the user's Keychain.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
PROFILE="${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to a saved notarytool profile}"
VERSION="$(tr -d '\n' < VERSION)"
OUTPUT="${1:-$ROOT_DIR/dist/release-v$VERSION}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
APP="$OUTPUT/MSI Screen.app"
DMG="$OUTPUT/MSI-Screen-v$VERSION-macos-universal.dmg"
ZIP="$OUTPUT/MSI-Screen-v$VERSION-macos-universal.zip"
[[ ! -e "$DMG" && ! -e "$ZIP" ]] || {
    echo "Release output already exists; choose a fresh output directory" >&2; exit 2;
}
EVIDENCE="$ROOT_DIR/.local/release-v$VERSION-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EVIDENCE/staging"
echo "Release evidence: $EVIDENCE"
# Verify access before building or uploading anything.
xcrun notarytool history --keychain-profile "$PROFILE" --output-format json > "$EVIDENCE/notary-access.json"
./script/package.sh --configuration release --universal --distribution --output "$OUTPUT"
for BINARY in "$APP/Contents/MacOS/MSIScreenMenu" "$APP/Contents/MacOS/msi-screen"; do
    lipo -verify_arch arm64 x86_64 "$BINARY"
done
python3 scripts/verify.py --offline --binary "$APP/Contents/MacOS/msi-screen" --app "$APP" > "$EVIDENCE/app-smoke.log" 2>&1

notarize() {
    local artifact="$1" receipt="$2"
    echo "Submitting $(basename "$artifact") for notarization"
    # A timeout keeps the submission receipt; inspect/wait on that ID rather
    # than blindly submitting the same artifact again.
    local result=0
    xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" \
        --wait --timeout 30m --output-format json > "$receipt" || result=$?
    python3 - "$receipt" "$result" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1]))
print('Notarization:', receipt.get('status'), 'submission:', receipt.get('id'), flush=True)
if int(sys.argv[2]) or receipt.get('status') != 'Accepted':
    raise SystemExit('Notarization did not complete successfully; inspect the saved submission before continuing')
PY
}

/usr/bin/ditto -c -k --keepParent "$APP" "$EVIDENCE/notarization.zip"
notarize "$EVIDENCE/notarization.zip" "$EVIDENCE/notary-app.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
/usr/bin/ditto "$APP" "$EVIDENCE/staging/MSI Screen.app"
ln -s /Applications "$EVIDENCE/staging/Applications"
cat > "$EVIDENCE/staging/Install.txt" <<'TXT'
Install MSI Screen

Quit MSI Screen if it is running, then drag MSI Screen.app onto Applications.
For an upgrade, replace your existing copy in its current Applications folder.
Eject this disk and open MSI Screen from Applications. Its controls appear in
the menu bar. Do not run the app from this disk image or keep duplicate copies.

The app and disk image are Developer ID signed and notarized by Apple.
Accessibility and Input Monitoring are optional permissions for mouse features;
check their status in Peripherals > Privacy & permissions.

The embedded agent/CLI tool is MSI Screen.app/Contents/MacOS/msi-screen.
TXT
hdiutil create -volname "MSI Screen $VERSION" -srcfolder "$EVIDENCE/staging" \
    -fs HFS+ -format UDZO "$DMG"
IDENTITY="$(/usr/bin/codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p')"
[[ -n "$IDENTITY" ]] || { echo "Developer ID signature missing" >&2; exit 1; }
/usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG" "$EVIDENCE/notary-dmg.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
python3 scripts/verify.py --offline --dmg "$DMG" > "$EVIDENCE/dmg-smoke.log" 2>&1
(
    cd "$OUTPUT"
    shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
echo "Signed, notarized release ready: $DMG"
echo "Evidence: $EVIDENCE"
