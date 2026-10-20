# Linux USB KVM companion

This optional Python 3 helper controls the MSI MD342CQP / V20 USB hub route. It runs once per request, uses only the Python standard library, and has no background service. Ordinary Linux machine status and video routing do not require it.

The monitor's USB-B upstream connection must reach this computer. DisplayPort alone carries no USB peripherals. Switching the hub can move the MSI control interface with the mouse and keyboard, so the destination must have the helper and HID access before an app-controlled handoff.

## One-time installation

Run these commands as the intended regular user from a directory containing the reviewed helper and rule, such as `scripts/linux` in this repository. The rule grants read/write access to MSI USB `1462:3fa4` HID interfaces and, for optional peripheral diagnostics, Bolt `046d:c548` vendor interface 02, through the existing `plugdev` group. Confirm that the user belongs to that group. Inspect any existing rule with the same name before replacing it.

```sh
getent group plugdev
id -nG
install -d -m 700 "$HOME/.local/share/msi-screen-control"
install -m 700 ./msi-screen-kvm.py "$HOME/.local/share/msi-screen-control/msi-screen-kvm"
sudo install -o root -g root -m 644 ./70-msi-screen-control.rules /etc/udev/rules.d/70-msi-screen-control.rules
sudo udevadm control --reload-rules
```

The two `sudo` commands require administrative authorization. Installation changes no monitor setting and adds no service or sudoers entry.

The rule applies when the monitor next enumerates on this computer. Reloading rules does not establish access to an already-existing node. Read status after enumeration to confirm permissions. Keep the monitor's physical KVM menu available until a software return path has been verified.

## Requests and results

Read-only status opens no device when the MSI controller is absent:

```sh
printf '%s\n' '{"schemaVersion":1,"action":"status"}' |
  "$HOME/.local/share/msi-screen-control/msi-screen-kvm"
```

A setting request requires the route from a fresh status. This example moves an observed USB-B upstream route to USB-C and sends the setter at most once:

```sh
printf '%s\n' '{"schemaVersion":1,"action":"setKVM","expected":"upstream","target":"usbc"}' |
  "$HOME/.local/share/msi-screen-control/msi-screen-kvm"
```

Routes are `auto`, `upstream` and `usbc`. Auto is a monitor policy, not an observation of the active USB host.

Requests must contain exactly `schemaVersion` and `action` for status, layout or peripherals, with `expected` and `target` added for `setKVM`, or `slot` and `expectedWirelessProductID` for `popDetails`. Unknown or duplicate fields, invalid values and input larger than 4096 bytes are rejected.

Status and setKVM responses contain `present`, `accessible`, `state`, `writeAttempted`, `writeCompleted`, `acknowledged`, `verified` and `outcome`, with a structured `error` on failure. The state contains `model`, `protocolVersion` and `kvm`.

- Status with `verified: true` confirms model, protocol and route register readback. It does not prove physical mouse or keyboard operation.
- A completed setting write returns `outcome: "sent"`, `writeCompleted: true`, `acknowledged: false` and `verified: false`, retaining the pre-write state. The helper does not wait for an ACK because a handoff can move the USB controller immediately. Obtain a fresh status from the destination computer to verify the handoff.
- An unchanged target sends no setter and returns `outcome: "unchanged"` with `verified: true`.
- A failed or short setting write returns `outcome: "unverified"` and exit code 2 after the attempt. The setting may already have applied. A caller timeout or missing response is also uncertain. Do not resend automatically.
- Exit code 0 covers observed/absent status, unchanged targets and completed setting writes. Other failures return exit code 2.

The helper checks USB identity on the already-open descriptor using `HIDIOCGRAWINFO`, takes a nonblocking lock, then validates model and protocol before reading or changing KVM. It exposes no arbitrary register, command, device path or shell execution API. Stdin completion and each HID query reply have separate three-second deadlines; setters are send-only. Callers should impose an overall process deadline, such as 20 seconds.

## Read-only layout and peripheral inventory

Send `{"schemaVersion":1,"action":"layout"}` to read the eight model, protocol and layout registers. Success returns `schemaVersion`, `action`, `model`, `protocolVersion` and `layout`; the nested layout also includes model and protocol, plus `mode`, `source1`, `source2`, `pipInput`, `pipSize` and `pipPosition`. A failed identity, permission or value check returns a structured `error` and exit code 2. It sends no setting command and does not prove the physical picture.

Send `{"schemaVersion":1,"action":"peripherals"}` for a snapshot with `checkedAt`, `hostName`, `platform`, `monitorHubPresent` and the fixed `bolt` and `rapoo` receiver entries. Receiver connection is `monitorHub`, `elsewhere` or `notDetected`. Monitor attachment requires one MSI controller directly below a downstream USB hub and a receiver anywhere below that same hub, including nested hubs. A bounded ancestry walk excludes unrelated hubs; sharing a host's root hub is insufficient.

Only a monitor-attached Bolt `046d:c548` receiver is queried, through its vendor HID++ interface 02. The helper checks its report descriptor, validates the opened descriptor identity, and takes a nonblocking lock. It reads stored pairing metadata/names and sends one read-only protocol ping per observed slot. There are no pairing, notification-setting or keyboard-input commands. Rapoo is topology-only. An off-hub receiver is never opened.

The entire Bolt HID session has a five-second deadline, with 350 ms metadata requests and 400 ms pings, without resending. A valid ping echo produces `radio: "responding"` and `protocolVersion`. A sent ping without a response in its allotted time, or an explicit unreachable result, produces `notResponding`; it does not establish permanent disconnection. Permission and other query failures produce `unavailable`. Pairing query errors and timeouts leave an explicit incomplete-inventory error; they do not prove an unpaired slot. The receiver's metadata error `08` on additional slots is omitted after at least one valid paired slot was observed. An inventory containing only those errors remains unknown. Names may be shortened by the receiver's stored-name response. Serial numbers, addresses and raw reports are omitted.

The supplied rule limits Bolt access to vendor interface 02. It first matches vendor/product on the USB-device ancestor and marks the udev event with a private temporary property; a second rule matches interface 02 on its separate ancestor and grants `plugdev` mode 0660. Combining these three `ATTRS` matches in one rule would incorrectly require them on the same ancestor. The helper continues to report permission errors gracefully until the rule is installed and applied. Installation is a separate administrative action; running these diagnostics changes no permissions.

Protocol provenance: [Logitech's IRoot.GetProtocolVersion specification](https://github.com/Logitech/cpg-docs/blob/master/hidpp20/features/0x0000-IRoot.rst), [Solaar's Bolt receiver decoding](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/receiver.py#L496-L510), [ping matching and error handling](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/base.py#L804-L854), and [Linux report-descriptor filtering](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/hidapi/udev_impl.py#L101-L163).

## Read-only POP Keys details

Use the slot and four-digit wireless product ID from a fresh peripheral snapshot:

```json
{"schemaVersion":1,"action":"popDetails","slot":1,"expectedWirelessProductID":"B365"}
```

The helper validates the monitor-attached receiver, stored keyboard kind, exact product ID and complete `Logi POP Keys` or `POP Keys` name again, then requires a fresh matched HID++ 2 protocol ping. A failed identity or access check returns a structured error with exit code 2. A successful or partial read returns the direct detail snapshot with exit code 0: identity, timestamp, advertised `features`, `firmware`, optional `battery` and `fnMode`, `controls`, inventory-completeness flags and explicit `errors`.

Only fixed read getters are allowed: root FeatureSet lookup; FeatureSet (`0001`) count and entries; firmware (`0003`) count and entities; unified battery (`1004`), battery status (`1000`) or voltage (`1001`); function-key inversion (`40A2`, otherwise `40A0`); and reprogrammable controls (`1B04`) count, capabilities and current reporting/mapping. Numeric feature and control fields use JSON integers. Unknown advertised feature IDs remain visible without additional queries. Host-specific function-key mode `40A3` is capability-only and reports that its current setting was not read. Legacy control features are capability-only. The helper sends no setters, pairing requests, notification changes or key-event subscriptions.

Control-ID mappings describe the device configuration. Logi Options+ can apply separate emoji or shortcut assignments on its host; these are not read here. Reporting flags bits 0 and 2 indicate temporary and persistent diversion to host software. This action changes no host mappings and installs no service.

This session has an eight-second deadline and caps discovery at 64 features including root, eight firmware entities and 32 controls. Each getter uses a rotating software ID and matches the device, feature and function header; control mappings must also echo their control ID. A timeout or transport failure stops subsequent queries, retaining already-observed details. Explicit matched protocol errors leave the affected field unavailable and allow independent sections to continue. Incomplete inventories and caps produce errors; missing values are not treated as zero. A battery percentage of zero is omitted because the protocol uses it for unavailable percentage; voltage is reported without estimating a percentage. Firmware unit IDs, receiver serials, addresses and raw reports are discarded.

Getter provenance beyond the official root specification is the pinned Solaar implementation: [firmware entities](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L1771-L1798), [battery getters](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L1896-L1909), [battery decoding](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L2191-L2265), [function-key mode](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L2056-L2062), [control capabilities](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L765-L775), and [control reporting/mapping](https://github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/hidpp20.py#L529-L548).

## Verification

The existing project verifier runs the companion fixtures in offline mode:

```sh
python3 scripts/verify.py --offline --binary .build/debug/msi-screen
```

`script/ci.sh` runs this same path against the extracted release CLI on each architecture. The fixtures exercise identity checks, stale-state rejection, lock ownership, send-only writes, ambiguous write failures, query timeouts and the real JSON stdin boundary. POP fixtures additionally cover fresh identity checks, matched feature replies, timeout stopping, bounded inventories, protocol errors, control-ID echoes and omission of private identifiers. They use disposable files and mocked HID transport; they require no monitor, SSH, installation or Linux permissions.

Hardware acceptance additionally requires live Linux enumeration, permission checks, a fresh destination-host route readback after a handoff, and observation of the actual peripheral behavior.

The transport follows the [Linux kernel hidraw API](https://www.kernel.org/doc/html/latest/hid/hidraw.html).

## GNOME side-wheel application switching

On GNOME, `setup_app_switch.py` adds F19 (next application) and F18 (previous application) to the native application switcher while preserving existing shortcuts. The mouse must already be configured to send those keys; this script does not change the receiver, mouse, display, USB route, or desktop session. It uses the existing Python GObject bindings and GNOME settings; it installs no dependencies and runs no background process.

Run as the desktop's regular user. Save the initial status and successful receipt so restoration can compare the exact settings it owns:

```sh
python3 scripts/linux/setup_app_switch.py status > app-switch-before.json
python3 scripts/linux/setup_app_switch.py configure --expected app-switch-before.json --dry-run
python3 scripts/linux/setup_app_switch.py configure --expected app-switch-before.json > app-switch-receipt.json
python3 scripts/linux/setup_app_switch.py status
# Optional: restore only if neither shortcut list has changed since configuration.
python3 scripts/linux/setup_app_switch.py restore --receipt app-switch-receipt.json --dry-run
python3 scripts/linux/setup_app_switch.py restore --receipt app-switch-receipt.json
```

`--expected -` and `--receipt -` accept JSON on standard input for an SSH caller. Configuration is idempotent. Stale snapshots, different session identities, and newer shortcut edits are rejected. Both shortcut lists are submitted in one delayed GSettings transaction and read back; a failed readback is reported without retry or automatic restoration.

GNOME 48.2 supports modifier-free application-switcher keys: rolling moves through the native chooser and pausing for 1.5 seconds activates the selected application. This is a chooser with delayed activation, unlike immediate activation on each wheel step. See the [native switcher timeout](https://github.com/GNOME/gnome-shell/blob/48.2/js/ui/switcherPopup.js#L279-L289) and [application next/previous handlers](https://github.com/GNOME/gnome-shell/blob/48.2/js/ui/altTab.js#L171-L174). The project verifier automatically includes `test_app_switch.py` in its existing offline Linux fixture run.

## GNOME Tern button shortcut

The same setup helper can bind F20 to the already installed `so.stencil.tern.desktop` application using GNOME's native custom shortcuts. This supports a mouse button configured to emit F20. Setup never launches Tern or changes the mouse mapping, F18/F19 bindings, USB route, or desktop session.

```sh
python3 scripts/linux/setup_app_switch.py tern-status > tern-before.json
python3 scripts/linux/setup_app_switch.py pin-tern --expected tern-before.json --dry-run
python3 scripts/linux/setup_app_switch.py pin-tern --expected tern-before.json > tern-receipt.json
python3 scripts/linux/setup_app_switch.py tern-status
# Optional: preview and restore the exact shortcut settings from this receipt.
python3 scripts/linux/setup_app_switch.py restore-tern --receipt tern-receipt.json --dry-run
python3 scripts/linux/setup_app_switch.py restore-tern --receipt tern-receipt.json
```

The helper verifies Tern's executable and `gtk-launch`, checks for another F20 assignment, and owns only the `msi-screen-tern` custom-shortcut entry. It preserves the existing shortcut list and rejects an unfamiliar configuration at its dedicated path. A single existing `dconf load` transaction registers the fixed command and binding. Restoration requires the recorded list and owned values to remain unchanged. Independent settings readback proves configuration; pressing the physical button and observing Tern is the separate behavior check.
