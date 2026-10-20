#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
APP="$HOME/Applications/MSI Screen.app"
case "$MODE" in
    run|--verify) exec bun "$ROOT_DIR/scripts/managed.ts" "$MODE" ;;
    --build-only|--managed-run|--managed-verify) ;;
    *) echo "usage: $0 [--build-only|--verify]" >&2; exit 2 ;;
esac
"$ROOT_DIR/script/package.sh" --configuration debug --output "$HOME/Applications"
if [[ "$MODE" != "--build-only" ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
    if [[ "$MODE" == "--managed-verify" ]]; then
        exec python3 "$ROOT_DIR/scripts/verify.py" --gui
    fi
    exec python3 "$ROOT_DIR/scripts/menu_service.py"
fi
