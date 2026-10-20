#!/usr/bin/env bash
# Standalone packaging; no OMP, Bun, Cua Driver, or attached monitor required.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION=release
OUTPUT="$ROOT_DIR/dist"
SIGNING_IDENTITY="${MSI_SCREEN_SIGNING_IDENTITY:-}"
UNIVERSAL=false
DISTRIBUTION=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration|--output)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            if [[ "$1" == "--configuration" ]]; then CONFIGURATION="$2"; else OUTPUT="$2"; fi
            shift 2 ;;
        --signing-identity)
            [[ $# -ge 2 && -n "$2" ]] || { echo "Missing signing identity" >&2; exit 2; }
            SIGNING_IDENTITY="$2"
            shift 2 ;;
        --ad-hoc)
            SIGNING_IDENTITY="-"
            shift ;;
        --universal) UNIVERSAL=true; shift ;;
        --distribution) DISTRIBUTION=true; shift ;;
        *) echo "usage: $0 [--configuration debug|release] [--output DIRECTORY] [--signing-identity ID|--ad-hoc] [--universal] [--distribution]" >&2; exit 2 ;;
    esac
done
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || {
    echo "Configuration must be debug or release" >&2; exit 2;
}
# The per-user pin survives checkout changes and reinstalls. A configured
# identity that is missing or locked must fail signing, never fall back to '-'.
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(python3 - <<'PY'
from pathlib import Path
import re
p = Path.home() / 'Library/Application Support/MSI Screen/signing-identity'
if p.exists() or p.is_symlink():
    identity = p.read_text().strip()
    if not re.fullmatch(r'[0-9A-Fa-f]{40}', identity):
        raise SystemExit('MSI Screen signing-identity must contain one certificate SHA-1 fingerprint')
    print(identity)
else:
    print('-')
PY
)"
fi
if $DISTRIBUTION && [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Distribution requires a Developer ID Application signing identity" >&2
    exit 2
fi
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    python3 - "$SIGNING_IDENTITY" "$DISTRIBUTION" <<'PY'
import re, subprocess, sys
identities = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
matches = [(fingerprint, name) for fingerprint, name in
           re.findall(r'\b([0-9A-Fa-f]{40}) "([^"]+)"', identities)
           if sys.argv[1].upper() == fingerprint.upper() or sys.argv[1] == name]
if len(matches) != 1:
    raise SystemExit('Configured signing identity is unavailable or ambiguous. Unlock/restore its Keychain identity; ad hoc fallback is disabled.')
if sys.argv[2] == 'true' and not matches[0][1].startswith('Developer ID Application:'):
    raise SystemExit('Distribution requires a Developer ID Application certificate')
PY
fi
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
APP="$OUTPUT/MSI Screen.app"
# Refuse to replace any copy currently in use, including the managed local app.
python3 - "$APP/Contents/MacOS/MSIScreenMenu" <<'PY'
import subprocess, sys
target = sys.argv[1]
processes = subprocess.check_output(['ps', '-axo', 'args='], text=True)
if any(line == target or line.startswith(target + ' ') for line in processes.splitlines()):
    raise SystemExit('Quit this copy of MSI Screen before rebuilding it: ' + target)
PY
BUILD_ARGS=(--configuration "$CONFIGURATION")
if $UNIVERSAL; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MSIScreenMenu" "$APP/Contents/MacOS/MSIScreenMenu"
cp "$BIN_DIR/msi-screen" "$APP/Contents/MacOS/msi-screen"
cp "$ROOT_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
python3 - "$APP/Contents/Info.plist" "$ROOT_DIR/VERSION" <<'PY'
import pathlib, plistlib, re, sys
version = pathlib.Path(sys.argv[2]).read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('VERSION must contain MAJOR.MINOR.PATCH')
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({
        'CFBundleExecutable': 'MSIScreenMenu',
        'CFBundleIdentifier': 'com.danielsivan.msi-screen.menu',
        'CFBundleName': 'MSI Screen',
        'CFBundleDisplayName': 'MSI Screen',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': version,
        'LSMinimumSystemVersion': '13.0',
        'LSUIElement': True,
        'NSPrincipalClass': 'NSApplication',
        'CFBundleURLTypes': [{'CFBundleURLName': 'MSI Screen controls', 'CFBundleURLSchemes': ['msi-screen']}],
    }, f)
PY
# A certificate-backed default DR uses the bundle and signer identity instead
# of the changing cdhash. Never weaken it with an identifier-only requirement.
# Distribution additionally enables hardened runtime and a secure timestamp;
# release-dmg.sh owns notarization. Local development needs neither service.
SIGN_ARGS=(--force --timestamp=none --sign "$SIGNING_IDENTITY")
if $DISTRIBUTION; then SIGN_ARGS=(--force --timestamp --options runtime --sign "$SIGNING_IDENTITY"); fi
/usr/bin/codesign "${SIGN_ARGS[@]}" \
    --identifier com.danielsivan.msi-screen.cli "$APP/Contents/MacOS/msi-screen"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad hoc build: TCC permissions may reset after code changes." >&2
else
    /usr/bin/codesign -d -r- "$APP"
fi
echo "Packaged $APP"
