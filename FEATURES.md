# Feature map

The menu-bar app uses the same controller as the CLI. Click the display icon or open `msi-screen://controls`. Draft changes are applied only through **Apply layout**. `python3 scripts/verify.py --gui --exercise` drives this same SwiftUI surface with background Cua Driver actions, saves before/busy/after screenshots, and independently checks USB state through the CLI.

| Delivery feature | User / agent path | Observable proof | Prerequisites / traps |
| --- | --- | --- | --- |
| Build an app | `./script/package.sh --configuration release --output dist` | Versioned `dist/MSI Screen.app` with an embedded CLI and valid ad-hoc signature | macOS and Swift developer tools; no OMP or monitor required |
| Offline smoke | `./script/ci.sh` | Unit tests pass; extracted release CLI returns capabilities and rejects invalid commands; bundle signature/dependencies validate | Does not exercise USB or the GUI; evidence in `.local/verify-*` |
| Tagged release | Push `v$(cat VERSION)` after main CI passes | Both architectures pass CI; release contains two ZIPs and `SHA256SUMS` | Release notes at `docs/releases/vVERSION.md`; ad-hoc signed, not notarized |

| Menu feature | User path | Agent path | Proof |
| --- | --- | --- | --- |
| Open controls | Menu-bar display icon | Cua Driver `launch_app` with `msi-screen://controls` | Native “MSI Screen” panel with refresh/layout/input controls |
| Read current layout | Open panel or Refresh | `msi-screen status` | Actual state separate from draft; USB model/protocol validated |
| Full-screen selection | Full screen → Input → Apply | `msi-screen fullscreen usbc` | mode=off and source1=usbc after settling |
| PBP inputs | Side by side → Left/Right → Apply | `msi-screen pbp on --left dp --right usbc` | Both inputs and mode read back exactly |
| Swap | Swap sides → Apply | Specify the opposite left/right inputs | Opposite input order in UI and separate-process readback |
| Draft safety | Change inputs without Apply | Add `--dry-run` | Monitor state unchanged; duplicate inputs disable Apply |
| Agent handoff | Copy CLI command | `msi-screen capabilities` | Explicit idempotent command; capability JSON works offline |
| Error handling | Refresh after error | Nonzero exit, `verified:false` | Stale drafts/USB errors disable Apply; no blind retry |
| Coexistence | Leave panel open | Run CLI while idle | CLI acquires USB lock; UI holds it only during operations |
| Quit | Quit or close just the panel | Verifier quits only its uniquely identified app | Closing the panel retains icon; quitting removes that process |

PIP editing, brightness, volume and KVM controls are outside the implemented sharing controls. USB upstream must remain attached to this Mac. UI automation requires Cua Driver permissions; normal use does not.

| Feature | User / agent control | Observable proof | Prerequisites / traps |
| --- | --- | --- | --- |
| Inspect layout | `msi-screen status` | Live USB mode, sources and preserved PIP settings | One MD342CQP/V20 USB controller connected to this Mac |
| Preview change | Add `--dry-run` to a setting command | Planned changes; subsequent status is unchanged | Still reads live hardware; `verified:false` means no write was attempted |
| Enable / configure PBP | `msi-screen pbp on --left dp --right usbc` | Complete layout packet acknowledged, then matching readback after five seconds | Two different video sources; source1 is primary/left, source2 is secondary/right. Applying wakes displays briefly. The saved PIP secondary follows the PBP secondary. |
| Swap sides | Specify the two sources in reverse order | Source readback matches requested order | Uses one complete layout packet; does not toggle or guess |
| Disable PBP | `msi-screen pbp off` | Settled mode is `off` | Primary/source1 becomes the fullscreen input |
| Select fullscreen input | `msi-screen input dp` | Settled primary input is `dp` | Requires split mode off; never changes the USB/KVM route |

`python3 scripts/verify.py` health-checks the real CLI and checks locking, dry-run and input validation. `--exercise` also enables PBP, swaps sources, checks persistence from separate CLI processes, and restores the starting layout. A newly initialized USB-C video connection can require a second complete layout packet; that single bounded transition is detected through CoreGraphics and exact source readback. Run long verification through OMP. Evidence is kept in `.local/verify-*`; no monitor serial is collected.
