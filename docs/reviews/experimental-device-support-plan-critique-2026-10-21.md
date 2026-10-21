# Critique: experimental device support plan

Review · 2026-10-21 · plan-only, one bounded pass

## Scope and evidence

- **Plan reviewed:** `docs/plans/experimental-device-support-2026-10-21.md`, all 534 lines.
- **Baseline:** `prompt-exports/oracle-plan-2026-10-21-004059-plan-experimental-de-4b94.md`, all 1904 lines. Lanes A (lines 135–968), B (979–1430) and C (1441–1897) all completed and end at the group marker. Only their generated plan text was treated as baseline.
- **Code spot-checks (read-only):**
  - `HIDConnection.swift:42–84`
  - `RapooMouseDetails.swift:526–540,644–669`
  - `MacUSBPeripheralReader.swift:190–228`
  - `ProcessRunner.swift:60–90`
  - `AgentSkillInstaller.swift:3–37`
  - `AppUpdater.swift:1–60`
  - `StatusItemController.swift:25–40,205–214,270–290`
  - `skills/msi-screen-control/SKILL.md:13–17`
  - `script/package.sh:85`
  - `scripts/verify.py:399–400,604–605`
- **Not done:** no implementation, hardware or Oracle calls, and no edits to the plan.

The user's stated scope is fixed:

- both profiles and native adapters;
- a copied prompt plus an installable skill, with no agent launch;
- full layout/KVM/peripheral ambition, within real hardware limits;
- automatic install and activation after checks.

## Findings (most severe first)

### F1 — High · Privacy: `support request UUID` gives the agent the private facts the prompt was built to withhold

- **Plan:** lines 306, 308, 336. Also `devices inspect` (332) and `text` capabilities (141, 164).
- **Defect:** The copied prompt is filtered by an allowlist. But the request file "stores exact endpoint/binding evidence", and `support request UUID` "resolve[s] it … for agent". Whatever that command prints goes into the agent's transcript, which normally goes to a cloud model provider. "Must not paste them into external searches/logs" does not cover the transcript itself. `devices inspect` has no redaction contract (only `list` says "redacted"). A profile `text` capability (bounded ASCII) can also expose a serial through `devices read`.
- **Correction:**
  - Keep private addresses host-side. `support request`, `devices inspect` and `devices read` should return only opaque IDs, nonunique numeric facts and passive descriptors.
  - Commands that need the exact target already take `--request UUID` or an opaque device ID and resolve it internally (339). Say explicitly that the agent never needs raw serials, UUIDs or registry paths.
  - Mark serial-like or identifier text capabilities as non-exportable in CLI JSON.
  - Add a `DeviceSupportRequestTests` case that asserts the `support request` output, not just the prompt, has no private fields.

### F2 — High · Duplicate execution: the journal only blocks reusing the same UUID; re-planning from a stale observation can resend an uncertain write

- **Plan:** lines 152–154, 254, 258, 320, 334.
- **Defect:**
  - `plan(observation:request:)` takes an observation from the caller (CLI stdin, line 334), and observations are not authenticated (only plans have an HMAC, 152).
  - After an uncertain apply, the "require a fresh read" rule is stated only for the UI draft (258).
  - An agent can build a second plan, with a new UUID, from the same pre-crash observation. If the device still reports the old state during settling or USB re-enumeration, the commitments match and the write goes out again. That is the duplicated KVM/configuration write the journal is meant to prevent (252), and it breaks the project rule "never resend an uncertain write".
- **Correction (a stale-baseline guard, not recovery automation):**
  - HMAC observations with the same derived key and reject unauthenticated ones in `plan`.
  - Record per binding and mutation scope the latest accepted operation and its terminal state. `apply` rejects any plan whose observation was checked before an accepted operation on an overlapping scope.
  - Add both cases to `DeviceOperationJournalTests` (405).

### F3 — High · Spawn design: inherited leases, explicit process groups and liveness pipes can't be built on the current Foundation `Process` primitive

- **Plan:** lines 227–229, 236, 246; W4 (459).
- **Evidence:**
  - `ProcessRunner.swift:80–90` uses Foundation `Process` and detects group ownership after the fact (`getpgid(pid) == pid && pid != getpgrp()`).
  - Foundation `Process` offers no way to set the process group before exec, to inherit chosen descriptors such as the `controller.lock` lease or liveness writers, or to close all other descriptors deterministically.
  - `HIDConnection.swift:42` opens `controller.lock` without `O_CLOEXEC`.
- **Defect:** The plan says to run legacy `run` and the new `runStructured` through "the same internal execution primitive" but never names the required mechanism change. In practice that means `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, `POSIX_SPAWN_CLOEXEC_DEFAULT` and explicit `addinherit_np`. That change also moves every legacy caller (remote KVM, USB snapshot, machine status, RemoteMacClient, UniversalControlClient, RapooAppControl) to new spawn semantics, including group ownership where today `ownsGroup` may be false.
- **Correction:**
  - State the primitive decision in §7.
  - Say whether legacy callers move to it in W4, or keep `Process` until the new primitive passes the existing `ProcessRunnerTests` unchanged.
  - Add a test that no unlisted descriptor (in particular `controller.lock`) reaches an adapter.

### F4 — Medium-High · Locks: the plan treats `controller.lock` as the only legacy lock, but Rapoo has its own and Bolt has none

- **Plan:** lines 238–245, 368, 459. W0 (518) defers this to reconnaissance, but the facts are already observable.
- **Evidence:**
  - `RapooQueryLock` takes `~/Library/Caches/msi-screen-control/rapoo.lock` "without acquiring the monitor's separate lock" (`RapooMouseDetails.swift:526–540`) and wraps the output report `0xba` setter (644–669).
  - Bolt detail reads open the receiver and send output report `0x10` with no process lock (`MacUSBPeripheralReader.swift:190–228`).
- **Defects:**
  1. Older CLIs exclude Rapoo writes only through `rapoo.lock`. The compatibility argument the plan makes for the MSI hub (242) therefore requires that experimental work touching the Rapoo receiver's ancestry also take `rapoo.lock` as a borrowed legacy lease.
  2. The phrase "Bolt/Rapoo setters" (243) is wrong for Bolt. Bolt has active queries, not setters, and no lock to borrow. Whether they join a new receiver-domain lease (that only new binaries honor) is a decision the plan doesn't make.
- **Correction:**
  - List the legacy lock for each domain in the `BuiltInControlDomainCatalog` table: MSI → `controller.lock`; Rapoo → `rapoo.lock`; Bolt → none today, with an explicit decision.
  - Have `RapooQueryLock` accept an external lease, as `HIDConnection` does.

### F5 — Medium-High · Auto-activation: "no device requests in that pipeline" is stated as a guarantee, but native `selfTest` is unconfined code that runs without leases

- **Plan:** lines 187, 192, 215, 217; W5 acceptance "activation stays hardware-free" (460).
- **Defect:**
  - Line 192 correctly calls the native `selfTest` no-hardware rule "contractual … not OS-enforced". Lines 215 and 217 then guarantee no device requests during activation.
  - `selfTest` runs before the registry lock and resource leases are taken (215). An adapter that breaks its contract could open the MSI controller during a built-in KVM handoff without holding `controller.lock`.
  - "Activation stays hardware-free" can't be accepted as written: fixtures can show the host's behaviour, not that arbitrary native code stays off the hardware.
- **Correction:**
  - Reword 217 as: "the host issues no device requests; native `selfTest` is trusted local code, run by the supervisor with the replaced environment and deadline."
  - Limit the W5 and test acceptance to the host's own I/O and the fixture adapter.
  - Either run `selfTest` under the supervisor without leases and document the residual race, or say why leases aren't taken. Don't claim more than that.
  - The skill's source-review step (310) is the real control. Keep it a required step before `support install`.

### F6 — Medium-High · Lifecycle: serial-less devices lose support on every replug or reboot, and the only way back is a new copy and reinstall

- **Plan:** lines 102–104, 113, 306, 339.
- **Defect:**
  - Transient bindings include boot identity and the registry entry, and "require reselection/rebinding through a new request".
  - `support install` always needs `--request UUID` (24-hour expiry), and the plan defines no bind-only command.
  - Many HID peripherals report no serial. For them, every reconnect or reboot means: user clicks copy → agent session → reinstall. That defeats automatic activation for a large share of the peripherals in scope.
- **Correction:**
  - Add an explicit, user-initiated rebind that changes metadata only. For example, a Devices-row action and `support bind PACKAGE --digest SHA --request UUID --expected-revision N` that binds an already-validated digest to the newly selected endpoint, with no agent and no device I/O.
  - Static selectors still never bind automatically (113).
  - Cover it in `SupportPackageTests` and the GUI fixture.

### F7 — Medium-High · Skill drift: after an app update, the "exact skill" rule blocks copying for anyone who installed the earlier version

- **Plan:** lines 302, 304; adjudication row 511. Code: `AgentSkillInstaller.swift:23–27`.
- **Defect:** Any difference from the bundled skill counts as a conflict, and the plan correctly refuses to copy in that case (rejecting B's copy-anyway). But every app update that changes `write-addhoc-support` leaves a stale earlier-version skill installed. Copying then fails until the user moves the folder aside by hand. The plan has no upgrade path, and the same problem already exists for `msi-screen-control`.
- **Correction (needs a decision, see Q1):** Record the digest of each skill tree the app installs, in Support state. Replace an installed tree (Trash the old one, then publish without overwrite) only when it still exactly matches a digest this app installed. Anything else stays an unfamiliar conflict. Tie the skill contract version to the CLI `capabilities` host API so a mismatched skill fails clearly.

### F8 — Medium · Permissions: OS denial is attributed to "the adapter's own process"; macOS normally charges the responsible app

- **Plan:** lines 66, 472, 349.
- **Defect:** macOS privacy permissions (Input Monitoring and similar) normally apply to the *responsible* process: MSI Screen.app when the app spawns `support-host`, or the terminal/agent host when the CLI does. So the same package can succeed from one client and fail from the other. Lane C's concrete reuse of `AppPermissions` and the existing privacy-status UI was dropped without being dispositioned in the adjudication table.
- **Correction:**
  - In W0, verify which process is charged for each client.
  - Report denial with the responsible client named (app or CLI host), and reuse `AppPermissions`/`PrivacyStatusView` for remediation.
  - Don't promise per-adapter authorization.

### F9 — Medium · Spawning: how the app and CLI locate the `support-host`/`support-worker` executable is unspecified

- **Plan:** lines 231–234.
- **Defect:**
  - Nothing in the code today locates the app's own CLI.
  - The app has to run `Contents/MacOS/msi-screen`, and the CLI has to re-run its own image.
  - A Sparkle update can replace the bundle mid-operation, so a path lookup could start a newer `support-host` under an older parent.
  - Source builds (`swift run`) have no packaged layout.
- **Correction:**
  - Resolve the supervisor from the caller's own executable or bundle, never from `PATH`.
  - Pass and check the host API/version in the internal invocation, and fail on mismatch.
  - State that source builds either re-run themselves or report the experimental runtime as unavailable, the same way they already report a missing skill bundle (300).

### F10 — Low-Medium · Contradiction: the prompt bans local paths, yet must tell the agent where to read the installed skill

- **Plan:** line 300 vs line 308.
- **Correction:** Allow the fixed, non-personal literal `~/.agents/skills/write-addhoc-support/SKILL.md` and the documented app CLI locations (`skills/msi-screen-control/SKILL.md:13–16`). Never expand `$HOME` or the override paths. When `MSI_SCREEN_AGENT_SKILLS_HOME` is set, say so without giving the path.

### F11 — Low · Updater impact targets the wrong owner

- **Plan:** lines 379, 409.
- **Evidence:** `AppUpdater` has no busy logic. It returns `false` from `willInstallUpdateOnQuit` (43–48), so update relaunches go through `StatusItemController.applicationShouldTerminate` (209–214), with `terminateLater` answered by the `Merge3` observer (33–38).
- **Correction:**
  - Remove `AppUpdater.swift` and the `AppUpdaterTests` row unless a concrete change appears.
  - Put the regression at the actual gate: the new store's `objectWillChange` joins the termination merge; `hasActiveOperation` includes runtime mutations; `quitWhenIdle`/`idleObservation` (276–289) observe the new busy state.
  - Rename "supervisor-idle termination" (296). `StatusItemController` already uses "supervisor" for its external parent process, which collides with the new `support-host` supervisor.

### F12 — Low · Single-lane items dropped without a disposition

- **B's post-run rehash** (export 1186). Plan line 219 rehashes after self-tests only. Add a rehash of the invocation copy after each run and report a mismatch as integrity changed. This is cheap and catches the adapter rewriting its own copy.
- **B's non-console/SSH display enumeration** (export 1098, 1409). Inventory run from an SSH session or another non-console session should report a failed display source with a reason, not an empty successful result. Plan line 89 has the outcome type, but there's no test case for it.
- **C's unknown-MSI identity bytes in the handoff** (export 1585). State whether bytes from a trusted-guard read (`00140`/`00150`) are allowed in the prompt as nonunique model facts (308 is ambiguous).
- **B's `--dry-run`** on remove (export 1300). `support disable`, `activate` and `remove` have no `--dry-run`, although the shared AGENTS.md says to support one where practical. Add it, or note that `support list` plus the expected-revision CAS already covers it.

## Adjudication check (against evidence and user scope)

- **Correctly decided:**
  - rejecting ordinal or VID/PID identity (B/C);
  - rejecting interpreter adapters (B/C);
  - rejecting a live smoke test during activation (C), since activation must not do device I/O without authorization;
  - rejecting copy despite a skill conflict (B/C), though see F7;
  - a dedicated Devices tab;
  - finite allowed MSI tuples behind the trusted guard, rather than B's blanket ban.
- **B's OS-arrangement profile:** rejecting it is sound. "Layout" in this app means panel PBP/PIP, and the existing `MacDisplayController` owner stays as it is.
- **C's MSI register profile — open (Q2):** Rejecting it pushes the most likely next unsupported class, other MSI monitors on `1462:3fa4` (`docs/compatibility.md`), onto agent-written native code that reimplements MSI framing outside Core. A compiled engine limited to scalar MSI ASCII register settings, with no packet templates, layouts or KVM, would be no more of a language than `hid-feature-fields-v1`. The plan's reason ("another control language", 493) fits C's packet templates, not that narrower option.

## Questions that affect design or order

1. **Q1 (F7, blocks W7):** May the app replace an installed skill tree that still exactly matches a version this app installed, or must every update need a manual move-aside?
2. **Q2 (W5 scope):** Should v1 include a compiled engine limited to scalar MSI ASCII register settings, or is a native adapter acceptable for other MSI models?
3. **Q3 (F6, W3/W7/W8):** Is a user-initiated, metadata-only rebind of an already-validated package acceptable without a new agent session?

## Coverage and fidelity conclusion

The plan keeps nearly all of Lane A's implementation detail and resolves the A/B/C conflicts correctly against the code and the user's four decisions. I found no requested feature missing, and no out-of-scope expansion beyond the items above.

The gaps are concentrated at a few seams:

- what actually leaves the host through agent-facing CLI output (F1);
- duplicate-write prevention beyond reusing the same UUID (F2);
- the spawn primitive that inherited leases depend on (F3);
- legacy locks other than `controller.lock` (F4);
- an overstated "hardware-free" guarantee for activation (F5).

There are also two lifecycle gaps that work against the user's automatic-activation goal: rebinding serial-less devices (F6) and skill drift after updates (F7).

F1–F5 should be fixed in the plan before W1/W4 begin. F6, F7 and Q2 need user decisions before W3 and W7 are finalized.
