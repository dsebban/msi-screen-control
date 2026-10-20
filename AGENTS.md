# Project guidance

MSI Screen Control is a macOS 13+ Swift package for the MSI MD342CQP / USB protocol V20. Keep shared device behavior in `MSIScreenCore`; the menu app and CLI are clients of that core.

## Code map

- `Sources/MSIScreenCore/Protocol.swift`: HID framing, complete layout packets and reply validation.
- `Sources/MSIScreenCore/HIDConnection.swift`: IOKit lifecycle, per-process USB lock, display assertions and display enumeration.
- `Sources/MSIScreenCore/ScreenController.swift`: typed state, desired layouts, stale-state checks and verified mutations.
- `Sources/msi-screen/main.swift`: CLI parsing and JSON contract.
- `Sources/MSIScreenMenu/`: SwiftUI controls, observable state and the AppKit menu-bar/panel bridge.
- `Tests/MSIScreenCoreTests/`: protocol and state-transition regressions.
- `script/package.sh`: standalone app packaging; `script/build_and_run.sh` is the optional OMP/Cua integration.
- `scripts/verify.py`: offline, hardware and GUI verification. Keep the corresponding user/agent paths in `FEATURES.md` current.

## Device invariants

- Validate model and protocol before changing settings. Do not generalize register mappings to another MSI model without device evidence.
- Use complete `5b001g` layout packets, the settling interval and full state readback. An HID acknowledgment alone is not success.
- Keep requested layouts explicit and idempotent. Preserve saved fields, including PIP geometry and the observed PBP/PIP secondary-input coupling.
- Preserve the compare-before-write guard and nonblocking lock. A stale draft must not overwrite a newer OSD or CLI change.
- Do not add generic retries. The existing single retry is limited to the reproduced cold USB-C transition with matching fields and a newly enumerated video connection.
- Create, use and destroy each HID session on one thread/run loop. Release it between UI operations so the CLI remains available.
- Never claim `verified: true`, a screenshot, or CI success proves the physical panel's picture or video resolution. Describe the actual evidence.

## Checks

Build and smoke-test without attached hardware:

```sh
swift test
./script/package.sh --configuration release --output dist
python3 scripts/verify.py --offline \
  --binary "dist/MSI Screen.app/Contents/MacOS/msi-screen" \
  --app "dist/MSI Screen.app"
```

`./script/ci.sh` runs the same checks and verifies a freshly extracted release ZIP. Release tags must match `VERSION` and have notes in `docs/releases/`; both macOS architecture jobs must pass before publication.

With a connected MD342CQP, `python3 scripts/verify.py` checks the real CLI without changing the layout. `--exercise` changes inputs and restores the baseline; use it only when the task authorizes monitor changes. `--gui` additionally requires background Cua Driver access. Follow the enclosing workspace's process-management and computer-use instructions.

Keep tests focused on real protocol, transition and failure-mode regressions. For changes to controls or packaging, exercise the resulting executable or bundle as well as unit tests. Preserve the verifier's ownership checks: cleanup may close only its own processes and restore only a layout it still owns.

Do not publish `.local/`, downloaded vendor utilities, screenshots, device evidence or build output as source. Release packages belong in release assets. Keep release architecture, version and signing claims consistent with the actual artifact; ad hoc signing is not notarization.
