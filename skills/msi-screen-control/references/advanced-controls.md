# Configuration, USB and peripherals

Check the installed CLI's `--help` before using these commands. Examples ending in `--dry-run` are previews; remove it only for the requested mutation.

## Saved computers

```sh
"$MSI_SCREEN" machine list
"$MSI_SCREEN" machine add gaming-pc --name "Gaming PC" --platform linux --input dp --host gaming-pc --dry-run
"$MSI_SCREEN" machine update gaming-pc --name "ChimeraOS" --dry-run
"$MSI_SCREEN" machine status gaming-pc
"$MSI_SCREEN" machine fullscreen gaming-pc --dry-run
"$MSI_SCREEN" machine pbp-left gaming-pc --dry-run
"$MSI_SCREEN" machine remove gaming-pc --dry-run
```

Choose an unassigned input and an existing SSH alias. Platforms are `macos` / `linux`; use `--local` for this Mac, `--host ALIAS` for a peer. Never infer a host or connect to an unrelated machine. The shared app/CLI registry lives at `~/Library/Application Support/MSI Screen/machines.json`. Removal deletes only the entry; it does not delete the remote computer or change its monitor input. Concurrent edits reject a stale save. `machine arrange ID left|right [--dry-run]` controls that Mac's own desktop, not Universal Control ordering.

## USB ownership

```sh
"$MSI_SCREEN" kvm status
"$MSI_SCREEN" kvm layout
"$MSI_SCREEN" kvm set upstream --expected usbc --machine gaming-pc --dry-run
"$MSI_SCREEN" machine focus gaming-pc --expected-usb usbc --dry-run
"$MSI_SCREEN" pbp on --left dp --right usbc --preserve-usb --dry-run
```

Replace the expected route with the freshly observed value. Setters accept `upstream` (USB-B) / `usbc`; `auto` can be observed/expected but cannot be a write target. Linux control requires the configured SSH companion and exact device permissions. Preserve-USB picture changes require an explicit route, not Auto.

Receipts distinguish temporary USB handoffs, video writes/readback, final ownership and partial failure. If any stage fails, stop and reread `kvm status` / `kvm layout` through the reachable owner. Do not automatically resend or roll back completed stages. USB receiver topology and acknowledgments do not prove that physical input follows the selected machine.

## Peripherals and host shortcuts

Read before writing:

```sh
"$MSI_SCREEN" peripherals
"$MSI_SCREEN" peripherals mouse
"$MSI_SCREEN" peripherals describe
"$MSI_SCREEN" peripherals app-switch
"$MSI_SCREEN" peripherals controllers
```

`peripherals [--machine ID]` reads the current USB host's receiver topology; discovery does not pair devices. Mouse writes are exact-model/firmware guarded and need local hub ownership and receiver configuration access. Use the fresh four-byte records from `peripherals mouse`, not sample constants:

```sh
"$MSI_SCREEN" peripherals mouse-map app-switch --expected-left "$LEFT_RECORD" --expected-right "$RIGHT_RECORD" --dry-run
"$MSI_SCREEN" peripherals mouse-map horizontal --expected-left "$LEFT_RECORD" --expected-right "$RIGHT_RECORD" --dry-run
"$MSI_SCREEN" peripherals pin-app "$BUNDLE_ID" --expected "$TOP_BUTTON_RECORD" --dry-run
"$MSI_SCREEN" peripherals mouse-button dpi-cycle --expected "$TOP_BUTTON_RECORD" --dry-run
```

App-switch mappings require the running menu app to register F18/F19 first. Pinning reserves F20 for an installed application before writing; DPI restore releases that pin while preserving the wheel handler. A partial or timed-out app reply may have changed the receiver; reread instead of retrying. Do not guess unsupported raw records or bypass stale guards.

`peripherals wheel-action applications|spaces` changes only this Mac's handler in the running app. It does **not** accept `--dry-run` and does not rewrite the mouse. `permissions` reports the running app's process-specific grants/signature; a CLI grant does not establish the app's access.

`peripherals probe --seconds N` and `peripherals controller-test --seconds N` observe input for 1–15 seconds. Run only when requested and allow physical user input. Zero events are inconclusive; counters of activation or Space requests do not prove the visible result. Bluetooth devices stay with their paired host when monitor USB moves.
