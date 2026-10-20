# MSI Screen Control

[![CI](https://github.com/dsebban/msi-screen-control/actions/workflows/ci.yml/badge.svg)](https://github.com/dsebban/msi-screen-control/actions/workflows/ci.yml)

A native macOS menu-bar app and CLI for sharing an **MSI Modern MD342CQP** between computers. Keep Mac and Linux machines in one list, switch them to full screen or Picture by Picture (PBP), adjust supported monitor settings, and choose the main display independently on each Mac.

The app and CLI use the monitor's existing USB control interface. **No firmware replacement or flashing is needed.** This version supports only the MD342CQP with USB protocol **V20** and rejects unrecognized model/protocol responses.

## Requirements

- macOS 13 or later, on Apple silicon or Intel.
- One MSI MD342CQP USB controller; layout and picture controls require its USB connection on this Mac.
- A working USB upstream connection from the monitor to the Mac. HDMI or DisplayPort video alone does not provide USB control.
- Two different video inputs for PBP, chosen from HDMI 1, HDMI 2, DisplayPort and USB-C.

USB control can work while the monitor shows another computer. The built-in KVM can move the USB hub between this Mac on USB-C and a configured Linux computer on USB-B. `msi-screen kvm status` discovers the controller on either computer and reads its configured route (`auto`, `upstream`, or `usbc`).

The [MD342CQP manual](https://download-2.msi.com/archive/mnu_exe/monitor/MD342CQP_MD342CQPWv1.1_English.pdf) defines USB-B upstream and USB-C as the two USB destinations. [MSI documents automatic switching](https://jp.msi.com/Business-Productivity-Monitor/Modern-MD342CQPW/Specification) with video input for the supported two-computer wiring; Auto behavior with PBP is unspecified, so the app reads Auto but offers only explicit USB-C and USB-B switches. The controller moves with the USB hub. Linux return control requires the [one-shot companion and narrow HID permission rule](scripts/linux/README.md).

## Install

Download the **v0.2.0 universal DMG** from [Releases](https://github.com/dsebban/msi-screen-control/releases/latest). It supports Apple silicon and Intel Macs running macOS 13 or later. Open the DMG, quit any running MSI Screen, and drag **MSI Screen.app** onto **Applications**. Eject the disk, then open the installed app. For an upgrade, replace the existing copy in its current Applications folder rather than keeping duplicates.

The app and DMG are **Developer ID signed and notarized**, with stapled Apple tickets. The universal ZIP contains the same notarized app; `SHA256SUMS` verifies the downloads. The older v0.1.0 ZIPs are ad hoc signed and not notarized.

Launch the app and look for the shield icon in the menu bar. There is no Dock icon or automatic login startup.

The menu bar shows the monitor's selected input, such as **HDMI 1**, or both sides of PBP, such as **HDMI 1 | USB-C**. Opening the controls reads fresh monitor state. Successful changes through this app or CLI notify the app immediately; changes made with the monitor's buttons are checked every 30 seconds while the panel is closed. This timer allows a three-second scheduling tolerance and does not replace a draft while the panel is open. **USB-B** means the Linux computer owns USB control; its tooltip explains the return path. **MSI ?** means the monitor state could not be read. Use the footer menu's **Close controls** action or click the menu-bar icon to hide the panel.

The original shield/M mark is purple for PBP/PIP, orange for HDMI, teal for USB-C, blue for DisplayPort and gray when unavailable. These labels report the selected layout; they do not detect which computers or video cables are connected. The icon and preview use native vector drawing. Animations run for state changes, respect macOS Reduce Motion, and do not run continuously in the background.

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

1. Click the shield icon and select **Layout**.
2. Choose **Full screen** or **Side by side** and select the input or inputs.
3. Click **Apply layout**. The app shows the requested switch as pending while the monitor settles and its complete layout is verified.

The command is sent before the five-second settling interval. This interval comes from the model's verified protocol behavior; it is not an animation delay. One narrowly detected cold USB-C initialization case can require a second packet and take about ten seconds. An already-matching layout performs no write or settling wait, after checking that its state is still current.

**Swap sides** changes the draft; click Apply to send it. The **Current** caption shows the last monitor readback separately from that draft. **Refresh** reads changes made by the monitor's buttons or another agent. **Copy CLI command** copies the explicit command for the selected layout.

Opening the panel, choosing inputs, swapping the draft, and copying a command do not change the monitor. A stale draft is rejected if the monitor changed before Apply. Closing the panel keeps the icon running; **Quit** exits the app. The URL `msi-screen://controls` opens the controls panel.

The preview uses computer names from the **Machines** tab and your input assignments. Input assignments and custom names are preferences, not automatic cable detection. **Save current layout** saves the last read inputs and split; **Restore saved layout** restores only those layout settings. It does not reset monitor preferences or restart the screen.

**Monitor** reads 19 model-specific controls with validated ranges and options: brightness, contrast, sharpness, image enhancement, picture mode, color temperature, RGB gains, low blue light, dynamic contrast, response time, refresh-rate overlay and position, speaker volume, OSD transparency and timeout, information overlay, and automatic input scan. Change a value, then click that control's **Apply** button. Unavailable controls show the reason; settings can depend on HDR, picture mode or PBP. Each write is checked against fresh state and verified by readback.

The supported picture modes are User, sRGB, Movie, Office, Black and white, Anti-blue and Eco; this model profile has no separate gaming mode. HDR follows the video signal and is shown as read-only status, which may be unavailable. Choose HDR in macOS Displays when supported. PIP editing, factory reset and monitor restart are not exposed; use the monitor's own controls for power cycling or reset.

### Machines and display roles

Open **Machines** to add, edit or remove a computer. Give it a name, platform and monitor input. Choose this Mac for a local entry, or an existing SSH host/alias for a remote Mac or Linux machine such as ChimeraOS. Each input belongs to at most one entry, and only one entry can represent this Mac. Names and input assignments are shared with the CLI in `~/Library/Application Support/MSI Screen/machines.json`.

Each machine offers **Full screen**, **Left** and **Right** actions; Left and Right place it in PBP. **Move USB with full screen** is enabled by default: Full screen on the local USB-C Mac or configured Linux machine switches both video and the monitor's USB hub. Turn this preference off under **Connection & input management** for video-only Full screen. Left and Right always preserve USB routing. Putting an input on the opposite PBP side swaps the two existing inputs; otherwise the other configured side is preserved. A route needs a distinct input for the other side. The Layout tab’s full-screen Apply uses the same preference. Side-by-side and video-only changes also work while USB belongs to Linux: they briefly acquire USB-C control, verify the layout, and return USB to Linux. Each stage is checked before continuing.

Machine status is checked at startup, when entering Machines or using **Refresh**, and when opening the panel if the last result is more than 30 seconds old. There is no periodic SSH polling. Registry changes made through the app or CLI refresh the shared list. Status includes its check time; it is separate from the monitor's currently selected input.

For a Mac, the machine card lists its displays and Main/Extended roles. **Make main** changes that Mac's main display while preserving the relative arrangement and display modes. Both displays must be awake and already form an extended desktop; change mirroring in macOS Displays first. The MSI must be detected as a video display, independently of USB control.

**Left of MSI / Right of MSI** places that MacBook beside its MSI image with the top edges aligned, preserving its Main/Extended choice and display modes. The same controls are available as `msi-screen arrange right --dry-run` and `msi-screen machine arrange local-mac right` (or `peer-mac left`). Machine cards follow the current PBP input order, and display rows follow their actual desktop positions. Universal Control's arrangement between Macs is separate: set that in macOS **Displays → Arrange**. Video input swaps do not reposition physical laptops or change their main displays.

Remote status requires trusted SSH host keys and noninteractive key authentication. Enter a host or alias; user names and options belong in SSH configuration. A Linux check reads its identity and `/sys/class/drm` connector status and advertised modes over SSH. It installs nothing and changes no Linux display settings. A connected connector or advertised mode does not establish the active resolution or physical picture. Main-display changes are available for macOS only.

Install this version's CLI manually at `~/.local/share/msi-screen-control/msi-screen` on the other Mac. Use a build matching that Mac's architecture. For two Macs of the same architecture, after packaging locally:

```sh
ssh other-mac 'mkdir -p "$HOME/.local/share/msi-screen-control"'
scp "dist/MSI Screen.app/Contents/MacOS/msi-screen" other-mac:.local/share/msi-screen-control/msi-screen
ssh other-mac 'chmod 755 "$HOME/.local/share/msi-screen-control/msi-screen"'
```

Replace `other-mac` with your configured alias. Review and approve an upload before asking an agent to run it. The app never installs a companion or edits SSH configuration; a missing or incompatible Mac companion produces an actionable error. Linux machines do not need this companion.

### USB peripherals and KVM

Open the visible **Keyboard & mouse** card in **Machines**. **Refresh USB route** reads the current setting and receiver status on the computer that owns the monitor hub; **USB-C Mac** and **USB-B NAME** move the entire hub, including attached receivers, keyboards, mice and the monitor control interface. Video inputs and PBP are independent of this route.

Assign this Mac to USB-C and the Linux computer to its video input, and connect that computer to the monitor's USB-B upstream port. The GUI requires exactly one Linux entry; the CLI can select one explicitly with `--machine ID`. Set up the [Linux companion and HID permissions](scripts/linux/README.md) before handing off USB. The app uses existing trusted, noninteractive SSH configuration and installs nothing itself.

While USB belongs to Linux, side-by-side, video-only layout changes and saved-layout restore preserve the selected USB host through a temporary USB-C handoff. Picture settings such as brightness still require returning USB-C first. Combined **Full screen** acquires USB-C control, applies and verifies the video layout, then moves USB to the selected machine. The separate **USB-C Mac** button also returns USB without changing video. Each handoff sends one command and verifies fresh model/protocol/route readback after enumeration. It does not wait for an acknowledgment from the disconnected host or replay a write. If verification fails, refresh the route and inspect the connection before taking another action. The monitor's physical KVM menu remains a return path.

KVM moves peripherals connected to the monitor's USB hub. A keyboard or mouse connected directly to, or paired with, a Mac stays with that Mac. Use **Connection & input management → Universal Control · Macs only** for Universal Control between Macs; it does not provide Linux sharing. USB route readback is separate from proving that a particular keyboard or mouse works on the receiving computer.

Receiver checks distinguish **not detected**, **outside the monitor hub**, and **connected through the monitor hub**. Logitech Bolt can also report paired-device names and whether its radio responds; Rapoo NearLink reports receiver presence. Reads run on demand, without pairing, changing radio settings, or capturing input events. Receiver presence and a radio response do not prove that a physical key press or pointer movement reaches an application.

Open **Peripherals** for the **MT760 Pro** and **POP Keys** cards. **Declared HID controls** shows the Rapoo mouse's actual descriptor: main wheel, side wheel (Consumer AC Pan), pointer axes and buttons supported by the receiver interface. **Test mouse controls** explicitly listens for ten seconds on this Mac and keeps only aggregate pointer/wheel/button counts. It requires local USB ownership and already-granted Input Monitoring access; it does not request permission automatically, capture keyboard values, remap controls, or leave an idle listener. “No input observed” is a diagnostic result, not proof that a control is broken.

**Game controllers** shows controllers connected to this Mac, whether macOS supports their current HID mode, native button mappings, battery when reported, and available motion/vibration/light capabilities. **Customize in macOS** opens the system controller settings. **Test controls** observes native gamepad changes for ten seconds, then removes its input handlers; leaving the tab also stops the test. Agents use `peripherals controllers` and `peripherals controller-test --seconds 10`. Bluetooth pairing is independent of the monitor hub and does not move when KVM changes.

The BSP-D8's yellow-light Android mode can be Bluetooth-connected without a native macOS gamepad profile. Power it off, hold **RB + Home** for two seconds, then pair **Xbox Wireless Controller** with its cyan indicator. These mode instructions come from the [D8 manual](https://manuals.plus/m/cb5c51d89dc614d945421230e99b5b8a426413cc951478aa6d82794bfc550580.pdf); the app reports the actual advertised identity rather than assuming every Xbox-compatible device is a BSP-D8.

**Read mouse details** reads MT760 Pro battery percentage, mouse/receiver firmware, DPI slots, the top-button mapping and both onboard side-wheel mappings while its `24ae:186a` NearLink receiver belongs to this Mac and is connected through the monitor hub. A reply is shown with its check time; missing fields and getter errors stay visible. **Onboard side wheel** shows the reported function for each direction. The remaining button labels under **Features & device controls** are manufacturer defaults, not live mapping readbacks. Battery status is retained as a raw byte without assigning charging semantics. The model-specific getter path was validated on the MT760 Pro / MT760 NL path in installed A HUB 1.1.15 (`libRapooDevice.dylib` SHA-256 `23d65416b655469cb3250cccdba8bbb0f5896dcd0e49fafb7d7619731136ca4a`); this does not establish support for other Rapoo models. Reading details does not change firmware, profiles or mappings.

**Onboard side wheel → Host shortcuts** assigns F18 (previous/left) and F19 (next/right) to the two wheel directions. **Horizontal scroll** restores both native scroll records. Writes require the exact validated receiver/mouse firmware pair (V1.3.6.0 / V1.0.0.41), local monitor-hub ownership, and unchanged mappings; each write is read back before the next. Partial failures stay visible and are not retried. No firmware is flashed.

**Side wheel on this Mac → Applications / Spaces** chooses how this Mac handles F18/F19. Applications cycles a stable app list during a wheel burst. Spaces sends the standard Control–Left/Right shortcuts, at most four times per second. This selection changes only the running Mac app; it does not read or write the mouse and remains available while USB is elsewhere. The mouse must already use Host shortcuts, and MSI Screen must remain running. Both modes are event-driven, with no continuous mouse listener or idle polling. ChimeraOS retains its native GNOME app chooser: roll to select, then pause about 1.5 seconds to activate. The Mac selection does not alter Linux shortcuts; GNOME bindings do not apply inside Gamescope.

Spaces needs **Accessibility** permission for the installed MSI Screen app and enabled Control–Left/Right bindings under **Keyboard → Keyboard Shortcuts → Mission Control**. The app checks permission without prompting and never changes those shortcuts. If the bindings were customized or disabled, the generated shortcut may reach the foreground app instead of moving Spaces. [Apple documents the standard Spaces shortcuts](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac). **Input Monitoring** is a separate permission used for this receiver’s configuration interface and the optional mouse test; it does not authorize Spaces shortcuts. Replacing an ad hoc signed build can invalidate its grants. If toggling Input Monitoring off/on leaves the app denied, remove only MSI Screen from that permission list, add the current installed bundle again, and restart the app.

**Read mouse details → Button behind main wheel → Pin to Tern** assigns the verified top button (key 4) to F20 and reserves F20 for the installed Tern app (`so.stencil.tern`). Pressing it requests activation of Tern, or launches Tern if it is closed. **Restore DPI button** restores the native DPI-cycle action. The fixed records are `01006f00` for F20 and `08000300` for DPI cycle; this control does not offer arbitrary button writes. Pinning replaces the button’s DPI-cycle behavior without changing the selected DPI or its slots. **Pointer DPI** is read-only and reports the device’s current DPI, active slot and configured slots; it does not change macOS tracking speed.

F20 and the wheel controls are independent: restoring horizontal scrolling leaves the app pin enabled; restoring the DPI button releases only F20. The mouse retains its onboard mappings when MSI Screen exits, so restore native scrolling/DPI behavior explicitly if wanted. Mapping readback and request counters do not prove physical wheel movement, a changed Space, or Tern becoming frontmost. The top button was physically confirmed to bring Tern forward on this Mac; physical Spaces switching remains a separate acceptance check.

**Read keyboard details** checks the selected POP receiver pairing and reads its reported battery, firmware, Fn-row mode and control mappings when available. Missing or partial data remains visible; wake the keyboard on its receiver channel if it cannot respond. Receiver slots are pairing records, not Easy-Switch channels, and multiple records can refer to one keyboard. Device-reported mappings can differ from Logi Options+ actions. These reads do not change pairings, channels or mappings.

**Universal Control · Macs only** optionally uses an already installed `~/.local/bin/universal-control` helper. **Check** reads service health, **Reconnect** runs that helper's reconnect operation, and **Settings…** opens macOS Displays for Universal Control preferences. There is no public enable/disable toggle in this app. Service health does not prove pointer or keyboard transfer; test crossing between both Macs. The helper uses its own existing configuration, independently of the display companion's SSH alias.

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
msi-screen settings                              # Read supported controls and unavailable reasons
msi-screen set brightness 50 --dry-run
msi-screen set volume 30                          # Speaker volume, with readback
msi-screen displays                              # This Mac's video displays and desktop roles
msi-screen main monitor --dry-run
msi-screen main built-in                         # Make this Mac's laptop display main
```

Use the same machine IDs in the app's shared list and CLI:

```sh
msi-screen machine list
msi-screen machine add gaming-pc --name "Gaming PC" --platform linux --input dp --host gaming-pc --dry-run
msi-screen machine add gaming-pc --name "Gaming PC" --platform linux --input dp --host gaming-pc
msi-screen machine status gaming-pc               # Read SSH identity and DRM connectors
msi-screen machine update gaming-pc --name "ChimeraOS"
msi-screen machine focus gaming-pc --expected-usb usbc --dry-run
msi-screen machine focus gaming-pc --expected-usb usbc
msi-screen machine fullscreen gaming-pc --dry-run # Video only
msi-screen machine fullscreen gaming-pc
msi-screen machine pbp-left gaming-pc
msi-screen machine pbp-right gaming-pc
msi-screen machine remove gaming-pc --dry-run
```

Replace `gaming-pc` after `--host` with your configured SSH alias, and select an unassigned input. `machine add` requires a name, platform (`macos` or `linux`) and input; use `--local` for this Mac or `--host ALIAS` for a remote machine. `machine update` accepts any of those fields. `machine remove` deletes only the saved entry, leaving the monitor layout and remote machine unchanged. All three configuration commands support `--dry-run`. Configuration writes reject conflicting concurrent edits. The absolute-path environment override `MSI_SCREEN_MACHINE_CONFIG` is available for isolated CLI fixtures.

Read the current USB route before choosing `--expected`:

```sh
msi-screen kvm status --machine gaming-pc
msi-screen kvm set upstream --expected usbc --machine gaming-pc --dry-run
msi-screen kvm set upstream --expected usbc --machine gaming-pc
msi-screen kvm status --machine gaming-pc
msi-screen kvm set usbc --expected upstream --machine gaming-pc
```

These examples assume the first read reports `usbc` and the handoff read reports `upstream`. `--machine` may be omitted when exactly one Linux machine is saved. An ambiguous assignment, changed registry or stale expected route rejects the write. `auto` is accepted as an observed expected route, but cannot be a target.

Input names are `hdmi1`, `hdmi2`, `dp` and `usbc`. In PBP, `source1` is left and `source2` is right. Omitting `--left` or `--right` preserves that configured input. Enabling PBP requires different inputs. `fullscreen INPUT` works even if the saved secondary input matches the primary.

Commands return JSON; `--help` returns usage text. Layout mutation results contain `schemaVersion: 1`, `before`, `changes`, `after`, `dryRun` and `verified`. Setting mutations return the setting, requested value and before/after snapshots with `dryRun` and `verified`. A successful applied or already-matching USB request has `verified: true`; a USB dry-run has `verified: false` and no `after` because it does not write. Mutation errors exit nonzero and return `error` with `verified: false`. `main --dry-run` returns a display plan; applied `main` returns the verified macOS display state. Neither display command needs USB access.

Machine routes add `machineID`, `route` and `target` to their layout result. Configuration changes return the registry `before` and proposed or saved `after`; `verified: true` confirms persistence, not hardware state. `machine status` returns a status snapshot with an ISO 8601 `checkedAt`, Mac displays or Linux connectors, and any captured `error`; it exits nonzero when that error is present. A failed SSH check leaves reachability unknown. Registry list/edit commands and machine status do not require USB access.

`machine focus ID` combines fullscreen video and USB for the local USB-C Mac or configured Linux machine. Its result includes `targetInput`, `targetUSB`, the before/target/after layout and USB snapshots, individual `usbChanges`, `videoWriteAttempted`, `videoVerified`, and overall `verified`. A partial failure reports the completed or attempted stages and stops without retrying or restoring earlier stages. `--expected-usb ROUTE` rejects a stale route; `--dry-run` performs no video or USB writes. `kvm layout` reads the full layout from the current controller host. Add `--preserve-usb` to `pbp on/off`, `fullscreen INPUT`, or `input INPUT` to change video while keeping the current explicit USB host. Its staged JSON reports temporary handoffs, video readback, and final ownership; use `--dry-run` to plan without writes. Auto must be changed to an explicit USB host before a layout mutation through this path. `peripherals [--machine ID]` returns an ISO 8601 `checkedAt`, host/platform, monitor-hub presence, and receiver/paired-device observations.

Read peripheral diagnostics explicitly:

```sh
msi-screen peripherals                          # Current USB owner's receiver snapshot
msi-screen peripherals describe                 # This Mac's Rapoo HID metadata; no input listener
msi-screen peripherals mouse                    # MT760 battery, firmware, DPI and mapping readbacks
msi-screen peripherals app-switch               # Running Mac wheel/pin handler status
msi-screen peripherals wheel-action spaces       # Mac only; no receiver read/write
msi-screen peripherals wheel-action applications # Restore Mac app cycling
msi-screen peripherals mouse-map app-switch --expected-left 07000800 --expected-right 07000800 --dry-run
msi-screen peripherals probe --seconds 1        # Explicit bounded pointer capture (1–15; default 10)
msi-screen peripherals keyboard --slot 1         # Use a POP pairing slot returned by peripherals
msi-screen peripherals keyboard --slot 1 --machine gaming-pc
```

These commands return raw schema-version-1 JSON with ISO 8601 timestamps. `describe` includes `connection`, process-specific `access` and allowed `usages`; descriptor metadata remains available without Input Monitoring. `probe` includes that descriptor, `requestedSeconds`, `elapsedSeconds`, per-usage `counts` (`samples`, `nonzeroSamples`, `positiveSamples`, `negativeSamples`), `completed`, `disconnected`, and any `error`. An incomplete probe exits nonzero. Pointer commands run only on this Mac; the app's permission can differ from the CLI's.

`keyboard` follows current USB ownership, validates a fresh recognized POP identity/radio response, and returns `hostName`, `platform`, `slot`, `wirelessProductID`, `name`, discovered `features`, `firmware`, optional `battery`/`fnMode`, `controls`, inventory-completeness flags and `errors`. Partial getter results retain their errors; an unavailable identity or radio returns an error instead of invented device details. Linux reads require the matching companion. The slot range is 1–6; it does not select an Easy-Switch channel.

`mouse` returns `hostName`, `platform`, `model`, `receiver`, optional `dongleFirmware`, `mouseFirmware`, `batteryPercent`, `batteryStatusRaw`, `sideWheelMappings`, `dpi`, `topButtonMapping`, and `errors`, alongside `schemaVersion` and `checkedAt`. Each side-wheel entry includes `keyID` (7 or 8), optional `direction` (`horizontalNegative` / `horizontalPositive`), `function` (`horizontalScroll`, `defaultHorizontalScroll`, `verticalScroll`, `disabled`, `appSwitchPrevious`, `appSwitchNext`, or `unknown`), four-byte `rawRecordHex`, and optional `logicalType`. Partial reads can omit entries. It is local-only, accepts no `--machine` option, and registers no input listener. Partial reads preserve their available fields and errors; no reply is retried or used to infer physical mouse input.

`peripherals mouse-map horizontal|app-switch --expected-left HEX --expected-right HEX [--dry-run]` accepts exactly the two four-byte records from the last mouse read. A dry run reads/validates the device without writing. Changes go through the running menu app so the Mac shortcut handler is registered before app-switch mappings are written. JSON includes before/target/after mappings, attempted and verified keys, and overall verification; a timed-out app reply means completion is unknown, so inspect the live state before another request. `peripherals wheel-action applications|spaces` changes only this Mac’s handler through the running app, without requiring a mouse read or write; it does not accept `--dry-run`. `peripherals app-switch` reports configured `hostAction`, actual `activeHostAction`, and whether the wheel hotkeys are registered. `switchCount` counts accepted application-activation requests; `spaceRequestCount` counts posted shortcuts. Neither confirms the visible result.

Use the current `topButtonMapping.rawRecordHex` from a fresh `peripherals mouse` result for `--expected`. These examples assume the native DPI record is present before pinning, and F20 is present before restoring:

```sh
msi-screen peripherals pin-app so.stencil.tern --expected 08000300 --dry-run
msi-screen peripherals pin-app so.stencil.tern --expected 08000300
msi-screen peripherals mouse                    # Read key 4 before restoring
msi-screen peripherals mouse-button dpi-cycle --expected 01006f00 --dry-run
msi-screen peripherals mouse-button dpi-cycle --expected 01006f00
```

`pin-app BUNDLE_ID --expected HEX [--dry-run]` validates the installed Mac app and reserves F20 before a real key-4 write. `mouse-button dpi-cycle --expected HEX [--dry-run]` restores only that button. Both reject stale records and use the same local ownership/firmware guards as wheel writes. A dry run previews without registering hotkeys or writing. Receipts include before/target/after, `writeAttempted`, `verified`, and any error; unknown completion requires a fresh read, not an automatic retry. An attempted but unverified pin keeps its handler available until an explicit verified restore. App status also exposes `pinnedBundleIdentifier`, `pinHotkeyRegistered`, `pinRequestCount`, `lastPinnedApplication` and `pinError`; the count records issued activation/open requests, including requests macOS may reject.

Mouse `dpi` contains `slots`, one-based `activeSlot`, `currentDPI` and `rawPayloadHex`. `topButtonMapping` contains key 4’s `function`, `rawRecordHex` and optional `logicalType`. DPI values are read-only; assigning or restoring the top button does not set DPI, acceleration or tracking speed.

KVM status keeps `schemaVersion`, `model`, `protocolVersion` and `route`, and adds `controlHost` (`local` or `upstream`) and `machineID`. Handoff results contain `before`, `after`, `target`, `dryRun`, `writeAttempted`, `writeCompleted`, `acknowledged`, `verified` and any `error`. `verified: true` means fresh route readback matched the target; it does not prove peripheral operation. `acknowledged: false` is normal for a successful handoff because the interface moves. A lost SSH response leaves the write uncertain and is never permission to resend automatically.

For agents:

- Read `status`, choose an explicit desired layout, and use `--dry-run` to inspect the planned changes. Dry-run still needs a connected monitor.
- For USB mutations, check both the process exit code and `verified`. Repeating an already-matching layout performs no writes.
- After an error, read `status` again and inspect the connection or mismatch before deciding what to do. **Do not blindly retry a mutation.**
- Allow the transaction to finish. Changed layouts normally take five seconds; one narrowly detected cold USB-C initialization case can take ten.

For layout changes, `verified: true` means the complete desired layout matches settled USB readback. For individual settings it means the requested value read back correctly and the layout remained unchanged. It does **not** prove that the physical panel shows a useful image, that a source has a video signal, or that macOS detects the intended resolution. Check those separately when validating a setup.

The app and CLI share a nonblocking process lock. If another USB operation holds it, the new request returns an error; the idle app does not prevent CLI use. Changed layouts wake the Mac's displays and hold a display-sleep assertion through verification. Read-only commands, dry-runs and unchanged requests do not wake them. Local monitor/display controls need no root access, network service or third-party runtime. Remote status and Mac display controls use macOS SSH; sharing integration requires the optional helper described above.

## Build from source

Install Xcode or the Xcode command-line tools with Swift 5.9 or newer, then:

```sh
git clone https://github.com/dsebban/msi-screen-control.git
cd msi-screen-control
swift test
./script/package.sh --configuration release --output dist
```

The output is `dist/MSI Screen.app`, including `Contents/MacOS/msi-screen`, for the host architecture. Add `--universal` for arm64 and x86_64, and `--distribution` for Developer ID signing with hardened runtime and a secure timestamp. Packaging uses `--signing-identity ID`, then `MSI_SCREEN_SIGNING_IDENTITY`, then the fingerprint stored in `~/Library/Application Support/MSI Screen/signing-identity`. Without a configured identity it uses ad hoc signing; `--ad-hoc` explicitly selects that mode. A configured identity that is unavailable fails the build rather than falling back. `--distribution` also refuses ad hoc or non-Developer-ID identities. Packaging alone does not notarize. Open the packaged app in Finder to use it. Quit the installed copy before replacing it.

To retain macOS privacy grants across local rebuilds, use the same certificate-backed identity and bundle identifier. `security find-identity -v -p codesigning` lists available identities; save the chosen certificate's 40-character fingerprint in the per-user `signing-identity` file. Keep its private key in Keychain. Moving from an older ad hoc build requires one final removal/re-addition of MSI Screen in Accessibility and Input Monitoring. Later builds must satisfy that signed app's designated requirement; never replace it with an identifier-only requirement or edit the TCC database. See [Apple's code identity explanation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

**Peripherals → Privacy & permissions** validates this running app's Accessibility trust, permission to post events, Input Monitoring grant, and signature. **Check again** refreshes the read-only checks; Settings buttons open the relevant macOS pane. These checks do not prompt or grant access and do not poll in the background. `msi-screen permissions` returns the running menu app's snapshot, including its PID, installed path, signer and designated requirement; it does not mistake the CLI's own permissions for the app's. A valid stable signature does not by itself mean permissions have been granted.

Use `python3 scripts/verify.py --permissions --gui` to exercise the installed permission panel and compare it with the app's CLI response. For an update artifact, add `--previous-app "/path/to/previous/MSI Screen.app"` to the offline verifier to check that the new executable satisfies the old signed identity. This reports identity continuity separately from live grant retention.

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

# Additional explicit exercises / read-only checks:
python3 scripts/verify.py --exercise-controls
python3 scripts/verify.py --peer-host other-mac
python3 scripts/verify.py --gui --peer-host other-mac --exercise-peer-controls
python3 scripts/verify.py --gui --sharing
python3 scripts/verify.py --exercise-machine gaming-pc
python3 scripts/verify.py --gui --exercise-machine gaming-pc
python3 scripts/verify.py --gui --exercise-machine-editor gaming-pc
python3 scripts/verify.py --gui --idle-seconds 60
python3 scripts/verify.py --gui --exercise-kvm gaming-pc
python3 scripts/verify.py --gui --exercise-focus gaming-pc
python3 scripts/verify.py --peripherals
python3 scripts/verify.py --gui --peripherals
python3 scripts/verify.py --gui --peripherals --probe-pointer
# Optionally add --expect-usb VID:PID for each connected USB peripheral to verify.
python3 scripts/verify.py --gui --usb-route --idle-seconds 60
```

The normal hardware run checks live USB state, exclusive access, dry-run behavior and command validation, including route previews for saved machines. Offline checks exercise machine configuration in a disposable registry. `--exercise` changes PBP, swaps inputs and returns to the initial layout. It requires inactive PIP and matching saved PIP/PBP secondary inputs for exact restoration. If another actor changes the layout or USB disappears, verification fails and reports the restoration gap instead of overwriting unknown state. Do not run a hardware exercise while someone else is changing the monitor.

`--exercise-controls` briefly changes this Mac’s main display and brightness by one step, then restores each only while it still owns the observed state. `--peer-host ALIAS` reads the installed display companion; adding `--exercise-peer-controls` changes and restores that Mac’s main display with the same ownership guard. `--gui` exercises the actual buttons and slider. `--sharing` checks the optional sharing helper. These checks do not establish physical image quality or working cross-Mac pointer/keyboard transfer.

`--exercise-machine ID` applies that saved machine's full-screen, PBP-left and PBP-right routes, verifies the target independently and restores the baseline after each while it still owns the exact layout. Adding `--gui` drives the machine card's actual buttons with **Move USB with full screen** temporarily off, then restores that preference. This exercise requires PIP off, distinct saved primary/secondary inputs, and matching saved PIP/PBP secondary inputs. Replace `gaming-pc` above with an existing machine ID.

`--exercise-focus ID` independently checks the combined Linux fullscreen/USB action, then the local Mac fullscreen/USB return, and restores the original video layout only from an exact state it still owns. Add `--gui` to drive Layout → Full screen → Apply, then Side by side → Apply while USB belongs to Linux, and finally the local Mac card’s Full screen return. Screenshots and remote readbacks capture the result and receiver continuity. Repeat `--expect-usb VID:PID` for specific dongles that must enumerate on Linux and return.

`--peripherals` is a separate read-only check for either USB owner. It records receiver topology, local Rapoo descriptor metadata and mouse detail results when USB belongs to this Mac, and a recognized POP pairing's detail result or explicit unavailable error. Adding `--gui` verifies the Machines receiver card and dedicated Peripherals screen, then captures **Read mouse details**, **Read keyboard details** and their results when available. Battery values are validated without requiring independent reads to match. Add `--probe-pointer` to explicitly run a one-second CLI capture and, with `--gui`, the ten-second app test when enabled. Remote ownership or missing app permission is recorded as a skipped probe; permission settings are not changed. Zero input counts are valid, and the verifier does not simulate physical mouse controls. A passed inspection can include unavailable device reads; inspect `peripheralDetails` and `peripheralDetailGUI` in its summary for their actual outcomes.

`--gui --exercise-machine-editor ID` opens the machine editor, renames that machine through the CLI, and verifies that saving the stale form is rejected. It restores the original name only while the complete registry still matches its expected state. This check does not change the monitor.

`--gui --idle-seconds N` measures the owned app with its panel closed for 10–300 seconds, after any requested exercises. It checks process ownership and records cumulative CPU time and resident memory every five seconds, then reopens the same app. The report contains elapsed time, CPU usage as a percentage of one core, and the RSS range; these are measurements, without a pass/fail performance threshold. Used alone, this option skips the longer generic GUI checks.

GUI verification launches an instance it owns, drives the actual controls through background Cua Driver actions, captures screenshots and readback, and quits only that instance. Evidence is saved under ignored `.local/verify-*`. See [FEATURES.md](FEATURES.md) for the user paths, agent controls and observable results.

GitHub Actions builds and tests on Apple silicon and Intel macOS, packages the real app and runs offline CLI/bundle smoke checks. Its architecture-specific ad hoc ZIPs are CI artifacts, separate from the signed public release. Hosted CI does not have the monitor: a green CI run is evidence for the code and packaged artifact, **not a physical USB or panel acceptance test**.

Run `./script/ci.sh` for the same unit tests, release build and smoke checks locally. It extracts the generated ZIP into a temporary directory and tests that copy. CI runs on pushes to `main`, pull requests and `v*` tags.

To release, update `VERSION` and add `docs/releases/vVERSION.md`, commit the changes, and wait for main CI to pass. Create and push an annotated tag matching the file. After both tag architecture checks pass, CI creates a draft release. Signing credentials remain on the release Mac: configure the Developer ID identity above and a saved `notarytool` Keychain profile, then run:

```sh
NOTARY_KEYCHAIN_PROFILE=your-saved-profile ./script/release-dmg.sh
```

This builds a universal app, notarizes and staples it, creates the ZIP and drag-to-Applications DMG, then signs, notarizes and staples the DMG. It mounts only its own DMG read-only, validates the installer shortcut, both architectures, hardened runtime, secure timestamps, Apple tickets and Gatekeeper acceptance, and exercises the embedded CLI. Logs and Apple submission receipts stay in ignored `.local/`; no credentials are bundled or uploaded to GitHub. A failed or timed-out notarization must be inspected by its saved submission ID before another submission.

Upload the resulting `.dmg`, `.zip` and `SHA256SUMS` from `dist/release-vVERSION/` to that draft and publish after the checks pass. Recheck a downloaded copy with `python3 scripts/verify.py --offline --dmg /path/to/download.dmg` and `shasum -a 256 -c SHA256SUMS`.

## Protocol provenance

USB HID query framing is informed by [couriersud/msigd](https://github.com/couriersud/msigd); its [MD342CQP contribution](https://github.com/couriersud/msigd/pull/71) documents the model identity. [MSI Display Switch](https://github.com/Phaseowner/MSI-Display-Switch) independently demonstrates native IOKit access on this model.

Model-specific layout framing and register mappings were inspected in MSI's [official Productivity Intelligence package](https://download.msi.com/uti_exe/monitor/ProductivityIntelligence-x64.zip), specifically `MonitorControlLibrary.Nuvoton` and `MD342CQP_ProfileInfo.BuildPBPX4SpecialCMD`. This implementation sends the complete `5b001g` layout packet, waits five seconds and reads back every supported field. Short writes produced transient or inconsistent results on the tested unit. The primary input is register `00500`; the secondary PBP input is `00610`. Older four-source registers `00670`/`00680` do not describe this model's two-pane layout.

For full-screen input changes, the app also sends the vendor's dedicated primary-input command (`00500`) before settling. On the tested MD342CQP, the complete layout packet disabled PBP but left the old primary input selected; the complementary input command produced the requested full-screen source with one settling interval.

The monitor couples the saved PIP secondary input to the PBP right-side input; changes report this explicitly. PIP size and position are preserved. MSI's [manual](https://download-2.msi.com/archive/mnu_exe/monitor/MD342CQP_MD342CQPWv1.1_English.pdf) documents PBP dependencies, including Adaptive-Sync, MPRT, HDMI CEC and screen-size restrictions.

Logitech HID++ discovery and control identifiers were cross-checked against [Solaar](https://github.com/pwr-Solaar/Solaar/tree/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver). Rapoo capabilities follow the [MT760 Pro documentation](https://www.rapoo.com/en/product/MT760PRO); its implemented getters were traced in the installed native A HUB library identified above, then exercised on this receiver. [OpenRapoo's exact-model research](https://github.com/waltenne/openrapoo/blob/2fe9c3c5f61f125dae6b63adec1ff63e81b1e6ba/docs/hardware-analysis.md) was also reviewed, but its configuration writer was not adopted. Other MT760 variants use different device IDs and protocols.

This repository contains an original Swift implementation and protocol facts. It does not redistribute vendor utilities, decompiled code or firmware. Investigation downloads and local device evidence stay outside the published source. This is an independent project and is not affiliated with MSI, Logitech or Rapoo.

## License

[MIT](LICENSE).
