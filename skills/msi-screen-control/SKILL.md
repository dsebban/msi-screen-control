---
name: msi-screen-control
description: Control the MSI MD342CQP monitor through the installed msi-screen CLI, including PBP layouts, source selection, monitor settings, USB routing, saved computers, and supported peripherals. Use for this monitor's operation, not firmware flashing or arbitrary MSI models.
metadata:
  msi-screen-host-api: "1"
---

# MSI Screen Control

## Locate and inspect

The macOS app includes the CLI; no daemon, Python runtime, or root access is needed for local monitor controls. Use its absolute path so spaces in the app name are handled correctly:

```sh
MSI_SCREEN="$HOME/Applications/MSI Screen.app/Contents/MacOS/msi-screen"
if [ ! -x "$MSI_SCREEN" ]; then
  MSI_SCREEN="/Applications/MSI Screen.app/Contents/MacOS/msi-screen"
fi
"$MSI_SCREEN" capabilities
"$MSI_SCREEN" --help
```

If neither app exists, locate `msi-screen` on PATH or use an explicitly selected source build. Do not download or build a replacement implicitly. `capabilities` is hardware-free JSON: use it and `--help` as the installed version's command contract. Older versions may lack commands shown here. Other commands return JSON and a nonzero exit status on failure.

Read `status` before local monitor mutations; it must identify `MD342CQP` / `V20`. If available, `identity` reads model/firmware identifiers without model-specific setting probes. A shared USB product ID does not establish compatibility. A disconnected controller is unavailable, not evidence that a remembered layout is still active.

## Discover other local devices

When `capabilities.experimental` is present, `devices list` passively inventories screens and peripherals even without an MSI controller. Use exact **endpoint** IDs, not record IDs or ordinal guesses. `devices inspect ID` gives passive facts, declared controls, binding and availability; partial sources are not absence. A USB control endpoint need not have a known video-display association.

For missing protocol support, `devices support-request ID` checks/installs the exact bundled `write-addhoc-support` skill and returns a redacted prompt for the existing agent; it does not launch an agent or change the clipboard. New skills may appear next turn; read `~/.agents/skills/write-addhoc-support/SKILL.md` locally if not yet indexed. A skill conflict preserves user content and stops handoff. Keep private request resolution/diagnostics local; do not upload identifiers.

Experimental Read/plan/apply remain unavailable while `executionReady:false` (`runtimeQualificationPending`); metadata lifecycle, historical receipts and hardware-free validation/selfTest remain available, with no production override. After recorded qualification gates close, explicit `devices read ID` supplies an authenticated baseline for an already configured endpoint. Submit `{"schema":1,"kind":"plan","observation":OBSERVATION,"operation":OPERATION}` to `devices request` for a hardware-free plan, then `{"schema":1,"kind":"apply","plan":PLAN}` for the user's intended mutation. Preserve complete authenticated JSON, including commitments; never edit or regenerate authentication. Read receipts with `support receipt UUID`, never resume/retry an uncertain operation. Nonzero/unverified means stop and report partial evidence. Follow the installed help/descriptor for device-local IDs, complete layouts/options/routes/mappings—not MSI enums or implicit follow-USB.

`support list` shows retained digests/bindings and qualification gates. `support bind` rebinds retained support to an exact newly selected attachment without regeneration or hardware I/O. Bind/disable/activate/remove support checked metadata `--dry-run`; activation does not restore hardware. Native support runs as the user, not in a sandbox. Operational qualification gates must not be bypassed. Experimental activation never expands this skill's MD342CQP/V20 built-in compatibility claim.

## Apply an explicit desired state

For the user's requested change, inspect a dry run, then apply the same command without `--dry-run`. A dry run reads live hardware but performs no writes; it normally returns `verified: false`. Do not ask again for permission already given by the user's request.

```sh
"$MSI_SCREEN" status
"$MSI_SCREEN" pbp on --left dp --right usbc --dry-run
"$MSI_SCREEN" pbp on --left dp --right usbc
"$MSI_SCREEN" fullscreen usbc --dry-run
"$MSI_SCREEN" settings
"$MSI_SCREEN" set brightness 50 --dry-run
```

Inputs are `hdmi1`, `hdmi2`, `dp`, `usbc`. PBP `source1` is left, `source2` is right; swap by specifying the opposite pair. `fullscreen INPUT` leaves PBP/PIP and selects the source in one transaction. `pbp off` retains the primary source. `input INPUT` selects a source while split mode is already off. Obtain setting names, ranges, options and unavailable reasons from `capabilities` / `settings` rather than guessing.

Let each transaction finish: changed layouts settle for about five seconds, sometimes ten for the CLI's narrowly bounded cold USB-C case. The CLI owns complete packets, locking, stale-state checks and readback. Do not send raw HID packets, terminate an in-flight change, or wrap mutations in retries. On busy/error/timeout, inspect fresh read-only state and the receipt before deciding the next action; unknown completion is not a failed write to resend.

Inspect `before`, `target`, `after`, `changes`, attempted stages and `verified`, then reread state independently. Repeating an already-matching layout performs no further writes. `verified: true` proves settled software readback, not a useful physical image, video signal, resolution, or actual keyboard/mouse operation. Report those separately.

## Computers, displays and USB

Read `machine list`; use its real IDs and input assignments instead of inferring them from names. See [advanced controls](references/advanced-controls.md) for configuration, USB handoffs and peripheral writes.

- `machine fullscreen ID` changes video only. `machine pbp-left ID` / `machine pbp-right ID` place a configured source on that side.
- `machine focus ID` combines full-screen video and USB ownership for supported local USB-C / configured Linux machines. This can move the keyboard, mouse and controller away from this Mac.
- `kvm status` reads USB ownership; `kvm layout` reads the picture through the current controller host. Use these when Linux owns the USB controller and local `status` cannot read it.
- Add `--preserve-usb` to supported picture commands when the user's intent is to retain the current explicit USB host. It temporarily acquires USB-C and returns it after verified video readback.
- `displays` enumerates this Mac's video connection independently of USB. `main monitor|built-in` changes the main display; `arrange left|right` places the laptop beside MSI. Both support `--dry-run`; two awake extended displays are required for arrangement.

Do not reinterpret a request to change video as permission to move USB. When testing configuration, set `MSI_SCREEN_MACHINE_CONFIG` to an absolute disposable JSON path; never use the real registry for fixtures.
