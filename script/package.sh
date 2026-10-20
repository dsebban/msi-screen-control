#!/usr/bin/env bash
# Standalone packaging; no OMP, Bun, Cua Driver, or attached monitor required.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CONFIGURATION=release
OUTPUT="$ROOT_DIR/dist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration|--output)
            [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
            if [[ "$1" == "--configuration" ]]; then CONFIGURATION="$2"; else OUTPUT="$2"; fi
            shift 2 ;;
        *) echo "usage: $0 [--configuration debug|release] [--output DIRECTORY]" >&2; exit 2 ;;
    esac
done
[[ "$CONFIGURATION" == debug || "$CONFIGURATION" == release ]] || {
    echo "Configuration must be debug or release" >&2; exit 2;
}
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
swift build --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
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
# Ad-hoc signing checks integrity locally; this is not Developer ID/notarization.
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/msi-screen"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "Packaged $APP"
