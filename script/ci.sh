#!/usr/bin/env bash
# Same hardware-free verification and packaging entrypoint locally and in CI.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="$(tr -d '\n' < VERSION)"
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" != "v$VERSION" ]]; then
    echo "Release tag must match VERSION (v$VERSION)" >&2
    exit 1
fi
swift test
./script/package.sh --configuration release --output dist
ARCH="$(uname -m)"
ARCHIVE="$ROOT_DIR/dist/MSI-Screen-v$VERSION-macos-$ARCH.zip"
/usr/bin/ditto -c -k --keepParent "dist/MSI Screen.app" "$ARCHIVE"
# Verify what a release user extracts, not just the pre-archive build folder.
python3 - "$ARCHIVE" <<'PY'
import pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix='msi-screen-smoke-') as staging:
    subprocess.run(['/usr/bin/ditto', '-x', '-k', sys.argv[1], staging], check=True)
    app = pathlib.Path(staging) / 'MSI Screen.app'
    subprocess.run([sys.executable, 'scripts/verify.py', '--offline',
                    '--binary', str(app / 'Contents/MacOS/msi-screen'), '--app', str(app)], check=True)
PY
