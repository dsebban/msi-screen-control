# MSI Screen Control

[![CI](https://github.com/dsebban/msi-screen-control/actions/workflows/ci.yml/badge.svg)](https://github.com/dsebban/msi-screen-control/actions/workflows/ci.yml)

A native macOS menu-bar app and CLI for sharing an **MSI Modern MD342CQP** between computers. Turn Picture by Picture (PBP) on or off, choose each input, swap sides, or return to one full-screen input without reaching for the monitor's buttons.

The app and CLI use the monitor's existing USB control interface. **No firmware replacement or flashing is needed.** This version supports only the MD342CQP with USB protocol **V20** and rejects unrecognized model/protocol responses.

## Requirements

- macOS 13 or later, on Apple silicon or Intel.
- One MSI MD342CQP USB controller connected to this Mac.
- A working USB upstream connection from the monitor to the Mac. HDMI or DisplayPort video alone does not provide USB control.
- Two different video inputs for PBP, chosen from HDMI 1, HDMI 2, DisplayPort and USB-C.

USB control can work while the monitor shows another computer. The monitor's KVM configuration or a disconnected upstream cable can remove the control connection; this app does not change KVM routing.

## Install

The initial release is **v0.1.0**, with separate Apple silicon (`arm64`) and Intel (`x86_64`) ZIPs for macOS 13 or later. Download the ZIP for your Mac from [Releases](https://github.com/dsebban/msi-screen-control/releases), extract it, and move **MSI Screen.app** to your Applications folder. Release assets include SHA-256 checksums.

The initial releases are **ad hoc signed, not Developer ID signed or notarized**. macOS may block the first launch. After reviewing and trusting the download, use **System Settings → Privacy & Security → Open Anyway** if offered.

Launch the app and look for the display icon in the menu bar. There is no Dock icon or automatic login startup.

The CLI is included in the app:

```sh
"/Applications/MSI Screen.app/Contents/MacOS/msi-screen" capabilities
```

For the shorter commands below, put the CLI on your `PATH`, or use its full path. For example, if you installed the app in `/Applications` and do not already have an `msi-screen` command:

```sh
mkdir -p "$HOME/.local/bin"
ln -s "/Applications/MSI Screen.app/Contents/MacOS/msi-screen" "$HOME/.local/bin/msi-screen"
export PATH="$HOME/.local/bin:$PATH"
```

Adjust the app path if you use `~/Applications`; add the `PATH` setting to your shell configuration to keep it across sessions.

## Menu-bar controls

1. Click the display icon.
2. Choose **Full screen** or **Side by side** and select the input or inputs.
3. Click **Apply layout** and allow 5–10 seconds for the monitor to settle.

**Swap sides** changes the draft; click Apply to send it. The **Current** caption shows the last monitor readback separately from that draft. **Refresh** reads changes made by the monitor's buttons or another agent. **Copy CLI command** copies the explicit command for the selected layout.

Opening the panel, choosing inputs, swapping the draft, and copying a command do not change the monitor. A stale draft is rejected if the monitor changed before Apply. Closing the panel keeps the icon running; **Quit** exits the app. The URL `msi-screen://controls` opens the controls panel.

PIP settings are read and preserved where possible. PIP editing, brightness, volume and KVM routing are not implemented.

## CLI and agent use

```sh
msi-screen capabilities                         # Offline, machine-readable command discovery
msi-screen status                               # Read live monitor state
msi-screen pbp on --left dp --right usbc --dry-run
msi-screen pbp on --left dp --right usbc
msi-screen pbp on --left usbc --right dp         # Explicitly swap the two inputs
msi-screen fullscreen usbc                       # Leave PBP/PIP and select USB-C
msi-screen pbp off                               # Full screen on the current primary input
msi-screen input dp                              # Change input while split mode is already off
```

Input names are `hdmi1`, `hdmi2`, `dp` and `usbc`. In PBP, `source1` is left and `source2` is right. Omitting `--left` or `--right` preserves that configured input. Enabling PBP requires different inputs. `fullscreen INPUT` works even if the saved secondary input matches the primary.

Commands return JSON; `--help` returns usage text. Mutation results contain `schemaVersion: 1`, `before`, `changes`, `after`, `dryRun` and `verified`. A successful applied or already-matching request has `verified: true`. A dry-run has `verified: false` and no `after` value because it does not write. Errors exit nonzero and return `error` with `verified: false`.

For agents:

- Read `status`, choose an explicit desired layout, and use `--dry-run` to inspect the planned changes. Dry-run still needs a connected monitor.
- Check both the process exit code and `verified`. Repeating an already-matching layout performs no writes.
- After an error, read `status` again and inspect the connection or mismatch before deciding what to do. **Do not blindly retry a mutation.**
- Allow the transaction to finish. Changed layouts normally take five seconds; one narrowly detected cold USB-C initialization case can take ten.

`verified: true` means the complete desired layout matches settled USB readback. It does **not** prove that the physical panel shows a useful image, that a source has a video signal, or that macOS detects the intended resolution. Check those separately when validating a setup.

The app and CLI share a nonblocking process lock. If another operation holds it, the new request returns an error; the idle app does not prevent CLI use. Changed layouts wake the Mac's displays and hold a display-sleep assertion through verification. Read-only commands, dry-runs and unchanged requests do not wake them. The compiled app and CLI need no root access, network service or third-party runtime.

## Build from source

Install Xcode or the Xcode command-line tools with Swift 5.9 or newer, then:

```sh
git clone https://github.com/dsebban/msi-screen-control.git
cd msi-screen-control
swift test
./script/package.sh --configuration release --output dist
```

The standalone packaging script produces `dist/MSI Screen.app`, including `Contents/MacOS/msi-screen`. It builds for the host architecture and ad hoc signs the app. Open the packaged app in Finder to use it. Quit the installed copy before replacing it.

Plain `swift build` produces the development CLI at `.build/debug/msi-screen`. OMP and Cua Driver are optional development integrations, not build or runtime requirements:

```sh
./script/build_and_run.sh              # Build/package and run with the OMP-managed service
./script/build_and_run.sh --verify     # Managed read-only CLI and GUI verification
```

The managed entrypoint requires Bun, OMP and Cua Driver. `OMP_LAUNCH_CLIENT` can override the installed OMP `launch/client.ts` path. Its service is `msi-screen-menu`; use `omp ps logs msi-screen-menu --dir "$PWD"` to inspect it or `omp ps stop msi-screen-menu --dir "$PWD"` to stop it. A managed app observes its supervisor's exit and quits after any active monitor transaction completes. A normally launched app stays open until Quit.

## Verification and releases

The project uses one verification entrypoint, [scripts/verify.py](scripts/verify.py), with separate offline and real-hardware modes:

```sh
# No monitor or GUI automation needed:
swift test
./script/package.sh --configuration release --output dist
python3 scripts/verify.py --offline \
  --binary "dist/MSI Screen.app/Contents/MacOS/msi-screen" \
  --app "dist/MSI Screen.app"

# Requires the connected MD342CQP:
python3 scripts/verify.py
python3 scripts/verify.py --exercise

# Also requires Cua Driver and its Accessibility / Screen Recording permissions:
python3 scripts/verify.py --gui
python3 scripts/verify.py --gui --exercise
```

The normal hardware run checks live USB state, exclusive access, dry-run behavior and command validation. `--exercise` changes PBP, swaps inputs and returns to the initial layout. It requires inactive PIP and matching saved PIP/PBP secondary inputs for exact restoration. If another actor changes the layout or USB disappears, verification fails and reports the restoration gap instead of overwriting unknown state. Do not run a hardware exercise while someone else is changing the monitor.

GUI verification launches an instance it owns, drives the actual controls through background Cua Driver actions, captures screenshots and readback, and quits only that instance. Evidence is saved under ignored `.local/verify-*`. See [FEATURES.md](FEATURES.md) for the user paths, agent controls and observable results.

GitHub Actions builds and tests on Apple silicon and Intel macOS, packages the real app and runs offline CLI/bundle smoke checks. A version tag builds architecture-specific release ZIPs and checksums. Hosted CI does not have the monitor: a green CI run is evidence for the code and packaged artifact, **not a physical USB or panel acceptance test**.

Run `./script/ci.sh` for the same unit tests, release build and smoke checks locally. It extracts the generated ZIP into a temporary directory and tests that copy. CI runs on pushes to `main`, pull requests and `v*` tags.

To release, update `VERSION` and add `docs/releases/vVERSION.md`, commit the changes, and wait for main CI to pass. Create and push an annotated tag matching the file (for example, `git tag -a v0.1.0 -m "MSI Screen v0.1.0"` followed by `git push origin v0.1.0`). The release job runs only after both architecture checks pass. It publishes ZIPs and `SHA256SUMS`; use `shasum -a 256 -c SHA256SUMS` in the download directory to verify them.

## Protocol provenance

USB HID query framing is informed by [couriersud/msigd](https://github.com/couriersud/msigd); its [MD342CQP contribution](https://github.com/couriersud/msigd/pull/71) documents the model identity. [MSI Display Switch](https://github.com/Phaseowner/MSI-Display-Switch) independently demonstrates native IOKit access on this model.

Model-specific layout framing and register mappings were inspected in MSI's [official Productivity Intelligence package](https://download.msi.com/uti_exe/monitor/ProductivityIntelligence-x64.zip), specifically `MonitorControlLibrary.Nuvoton` and `MD342CQP_ProfileInfo.BuildPBPX4SpecialCMD`. This implementation sends the complete `5b001g` layout packet, waits five seconds and reads back every supported field. Short writes produced transient or inconsistent results on the tested unit. The primary input is register `00500`; the secondary PBP input is `00610`. Older four-source registers `00670`/`00680` do not describe this model's two-pane layout.

The monitor couples the saved PIP secondary input to the PBP right-side input; changes report this explicitly. PIP size and position are preserved. MSI's [manual](https://download-2.msi.com/archive/mnu_exe/monitor/MD342CQP_MD342CQPWv1.1_English.pdf) documents PBP dependencies, including Adaptive-Sync, MPRT, HDMI CEC and screen-size restrictions.

This repository contains an original Swift implementation and protocol facts. It does not redistribute MSI's utility, decompiled code or firmware. Investigation downloads and local device evidence stay outside the published source. This is an independent project and is not affiliated with MSI.

## License

[MIT](LICENSE).
