#!/usr/bin/env bash
# Prepare the signed update feed locally. Publishing remains a separate action.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ $# == 1 ]] || { echo "usage: $0 RELEASE_OUTPUT_DIRECTORY|--check-key" >&2; exit 2; }
VERSION="$(tr -d '\n' < VERSION)"
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
ACCOUNT="$(python3 -c 'import json; print(json.load(open("config/updates.json"))["keychainAccount"])')"
PUBLIC_KEY="$("$TOOLS/generate_keys" --account "$ACCOUNT" -p)"
python3 - "$PUBLIC_KEY" <<'PY'
import json, sys
if sys.argv[1].strip() != json.load(open('config/updates.json'))['publicKey']:
    raise SystemExit('The Sparkle Keychain key does not match the app public key')
PY
if [[ "$1" == --check-key ]]; then echo "Sparkle Keychain key matches the app public key"; exit 0; fi
OUTPUT="$(cd "$1" && pwd)"
ZIP="$OUTPUT/MSI-Screen-v$VERSION-macos-universal.zip"
[[ -f "$ZIP" ]] || { echo "Missing universal release ZIP: $ZIP" >&2; exit 1; }
# Only the ZIP belongs in the generator's input; the DMG has the same version.
mkdir -p "$ROOT_DIR/.local"
STAGING="$(mktemp -d "$ROOT_DIR/.local/appcast-XXXXXXXX")"
trap 'trash "$STAGING"' EXIT
cp "$ZIP" "$STAGING/"
cp "docs/releases/v$VERSION.md" "$STAGING/$(basename "$ZIP" .zip).md"
"$TOOLS/generate_appcast" --account "$ACCOUNT" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/dsebban/msi-screen-control/releases/download/v$VERSION/" \
    --link "https://github.com/dsebban/msi-screen-control/releases/tag/v$VERSION" \
    -o "$OUTPUT/appcast.xml" "$STAGING"
"$TOOLS/sign_update" --account "$ACCOUNT" --verify "$OUTPUT/appcast.xml"
python3 - "$OUTPUT/appcast.xml" "$ZIP" "$TOOLS/sign_update" "$ACCOUNT" "$VERSION" <<'PY'
from pathlib import Path
import subprocess, sys, xml.etree.ElementTree as ET
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
item, = ET.parse(sys.argv[1]).getroot().findall('./channel/item')
archive = Path(sys.argv[2])
enclosure = item.find('enclosure')
assert item.findtext(namespace + 'version') == sys.argv[5], 'Feed version differs from VERSION'
assert enclosure.attrib['url'] == 'https://github.com/dsebban/msi-screen-control/releases/download/v' + sys.argv[5] + '/' + archive.name
assert int(enclosure.attrib['length']) == archive.stat().st_size, 'Feed length differs from the final ZIP'
subprocess.run([sys.argv[3], '--account', sys.argv[4], '--verify', str(archive),
                enclosure.attrib[namespace + 'edSignature']], check=True)
PY
echo "Signed feed ready: $OUTPUT/appcast.xml"
