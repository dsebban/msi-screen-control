# Experimental support — implementation work breakdown

Parent-owned execution record · 2026-10-21

## Authority and preservation

- Final specification (read fully): `/Users/danielsivan/dev/msi-screen-control/docs/plans/experimental-device-support-2026-10-21.md`. Its exact requirements/acceptance gates govern; this breakdown does not replace or narrow them.
- Every worker must read `/Users/danielsivan/.agents/AGENTS.md` and `/Users/danielsivan/dev/msi-screen-control/AGENTS.md`; carry both absolute paths across delegation boundaries.
- Repository: `/Users/danielsivan/dev/msi-screen-control`; measured branch `main`, HEAD `c74a543` on entry. Authoritative pending checkout, not HEAD-only input.
- Initial status: 15 modified, 19 untracked entries. Preservation snapshots: supplied `_git_data/repos/msi-screen-control-ee003ca3/2026-10-21/0012`; freshly captured `_git_data/repos/msi-screen-control-ee003ca3/2026-10-21/0858` (MAP and full patch). Worker changes must be distinguished from this pending input.
- Supplied baseline evidence: OMP `msi-experimental-baseline-20261021`, job `434e39d1-b234-4803-9429-7addbb5b95e3`, exit 0, 155 tests. This parent has not independently inspected that log yet.
- No storefront, secrets, AGENTS, release version, updater implementation, unrelated pending edits, commits, pushes, publication, or history rewriting. Existing schemas/protocol behavior remain as specified. No unapproved new production target/dependency.
- W10 is excluded. No monitor/layout/USB-routing changes, speculative device I/O, active input probing, or newly generated adapter hardware exercise. Passive inspection is allowed. All execution verification uses owned disposable fixtures.
- Native adapters are trusted user code, not sandboxed. Activation is not hardware qualification; software readback is not physical-panel evidence.

## Coordination and checkpoints

1. Read the supplied plan and acceptance checks. **Done.** Direct orchestration path: an existing final plan makes another builder/planning pass unnecessary.
2. Divide into a few verifiable units with one shared-plan owner. **This document; checkpoint pending.**
3. Supervise fresh sequential workers, inspect each actual diff/artifact and run its checks before approving dependents. **Pending.**
4. Exercise the combined user path, inspect the final diff, preserve pending input, and record gaps/durable handles. **Pending.**

Only this parent edits this breakdown. Workers return evidence in their session results, not competing plans/reviews. Before the first worker, confirm no sibling writers are active, including the supplied planning session `181E696B-5D3B-4102-80B4-E3AF02FED213`; do not launch duplicate implementation. Dispatch fresh RepoPrompt workers sequentially on the authoritative checkout, with exact writable scope below. No parallel writers; any later parallelism requires separately materialized authoritative pending scoped input and distinct ownership.

After exporting this breakdown: `ask_user` with the plan/breakdown paths and wait for inspection/response before dispatch. After each unit: inspect real changes, run checks, update evidence here, then `ask_user` with summary and actual diff/check paths before dependents. A timeout/skipped question is not checkpoint approval. Routine decisions and in-scope fixes need no additional product interview.

Long commands only use OMP-managed jobs/services; short reads/diffs need no OMP wrapper. Reuse healthy jobs, record durable IDs/logs, and inspect at meaningful checkpoints rather than repeatedly polling. `scripts/managed.ts` is the installed launch-client example (read, not owned for edits). Preserve healthy Oracle invocations for up to 45 minutes. No shell backgrounding/tmux/nohup.

Each dispatch additionally supplies the plan, this breakdown, both absolute guidance paths, preservation baseline, predecessor evidence, exact scope, and stop boundary. No worker may broaden scope or dispatch additional implementation writers. Parent reviews real changed hunks and reruns material checks; worker summaries alone are not acceptance evidence.

## Units and exact writable ownership

Paths below are relative to the pinned repository. A listed directory is not a blanket write grant: only the named paths are owned. Test fixtures are temporary/owned or the exact maintained fixture paths below. Any required additional production source path needs parent reconciliation against the plan before editing.

### U1 — Strict contracts and independent discovery (W0 → W1 → W2)

**Status:** Implementation and local parent checks complete; checkpoint 1 accepted. W0 responsible-client attribution remains an explicit unverified gate for packaged-runtime fixture measurement, not a PASS. Other evidence limits are recorded below.

**Goal:** Reconcile actual construction, permission-attribution and lease owners, then add strict typed contracts and passive inventory independent of MSI availability. No loader or experimental execution is enabled.

**Dependencies:** Breakdown checkpoint; sibling-writer check. **Size:** Large. **Worker:** fresh pair.

**Writable paths:**
- `Sources/MSIScreenCore/DeviceInventory.swift`
- `Sources/MSIScreenCore/DeviceCapabilities.swift`
- `Sources/MSIScreenCore/StrictJSON.swift`
- `Sources/MSIScreenCore/SupportManifest.swift`
- `Sources/MSIScreenCore/KVMCoordinator.swift` (strict JSON extraction only)
- `Sources/MSIScreenCore/MacDeviceInventoryReader.swift`
- `Sources/MSIScreenCore/USBDeviceGraph.swift`
- `Sources/MSIScreenCore/MacDisplayController.swift`
- `Sources/MSIScreenCore/MacUSBPeripheralReader.swift` (passive extraction only)
- `Sources/MSIScreenCore/GameControllers.swift`
- `Tests/MSIScreenCoreTests/DeviceInventoryTests.swift`
- `Tests/MSIScreenCoreTests/DeviceCapabilityTests.swift`
- `Tests/MSIScreenCoreTests/DeviceSupportResolverTests.swift` (contract cases only if needed)
- `Tests/MSIScreenCoreTests/KVMCoordinatorTests.swift` (legacy decoder regression only)
- `Tests/MSIScreenCoreTests/USBPeripheralTests.swift` (projection regression only)
- `Tests/MSIScreenCoreTests/Fixtures/device-support-cases.json`
- `Package.swift` (test resources only if required)

**Done when / evidence:** W0 names real app ownership/termination/OMP-idle/Sparkle and low-level lease sites before edits, establishes observable responsible-launch-client attribution or explicitly records what remains unobservable without forbidden live experiments, and inspects supplied baseline evidence. W1 validators enforce explicit tagged JSON, bounds, complete typed targets/scopes, export classification and identity/plan/receipt shapes without changing legacy acceptance. W2 proves zero active inventory requests, no-MSI/partial/non-console/twin/reconnect/composite cases, no inferred display association, and unchanged specialized projections. Run focused tests then `swift test` via OMP; report commands, job IDs, logs, exit/test totals and exact diff.

### U2 — Secure persistence, selected-endpoint protection and process/lease foundation (W3 → W4)

**Status:** Implementation/corrections and parent local verification complete; checkpoint 2 accepted. Execution remains disabled. Packaged-host/backend, responsible-client attribution and other architecture/OS evidence remain later gates, not PASS.

**Goal:** Establish private keyed identities/content-addressed storage/CAS and the single structured spawn primitive with real descendant/descriptor/lease evidence. Package staging remains inactive until U3 completes executable validation.

**Dependencies:** U1 verified and checkpoint accepted. **Size:** Large. **Worker:** fresh pair.

**Writable paths:**
- `Sources/MSIScreenCore/SupportManifest.swift`
- `Sources/MSIScreenCore/SupportRegistry.swift`
- `Sources/MSIScreenCore/SupportPackageInstaller.swift`
- `Sources/MSIScreenCore/ProcessRunner.swift`
- `Sources/MSIScreenCore/DeviceResourceLock.swift`
- `Sources/MSIScreenCore/HIDConnection.swift`
- `Sources/MSIScreenCore/DeviceSupportResolver.swift`
- `Sources/MSIScreenCore/RapooMouseDetails.swift`
- `Sources/MSIScreenCore/MacUSBPeripheralReader.swift` (actual active-query lease owners only)
- `Sources/MSIScreenCore/KVMCoordinator.swift` (necessary lease seam only)
- `Tests/MSIScreenCoreTests/SupportPackageTests.swift`
- `Tests/MSIScreenCoreTests/ProcessRunnerTests.swift`
- `Tests/MSIScreenCoreTests/DeviceSupportResolverTests.swift`
- `Tests/MSIScreenCoreTests/DeviceAdapterTests.swift` (foundation cases)
- `Tests/MSIScreenCoreTests/USBPeripheralTests.swift` (lease regressions only)
- `Tests/MSIScreenCoreTests/Fixtures/AdapterFixture.swift`
- `Tests/MSIScreenCoreTests/Fixtures/device-support-cases.json`
- `Package.swift` (test resources only if required)

**Done when / evidence:** Exact W3 path/file/key/registry/ownership/permission/digest/CAS attack/race gates pass; invalid roots never fall back to production. W4 real process fixtures prove separate streams, replaced environment, posix_spawn group creation, explicit inherited descriptors, normal-exit descendant cleanup, cancellation/timeouts/fairness, parent-loss foundation and no cross-group kills. Legacy merged ordering/API/callers pass unchanged. Selected-endpoint seam + compiled guard + borrowed locks/tests land atomically; built-in/reserved receiver protections and deterministic nonblocking lock order are preserved. W3's selfTest/activation acceptance remains explicitly pending U3; no public half-enabled loader. Run focused checks and full `swift test`; return actual evidence and remaining architecture coverage.

### U3 — Both supervised backends, authenticated control and single execution (W5 → W6)

**Status:** Implementation/correction and parent local software verification complete; checkpoint 3 pending. Operational experimental execution remains disabled: responsible-client attribution and native Intel/macOS13 lifecycle are unverified. Translated x86 fixture success is not native platform qualification.

**Goal:** Complete profile/native execution and package validation before exposing controls; implement shared read/plan/apply, durable epochs/receipts and built-in delegation without duplicating MSI logic.

**Dependencies:** U2 verified and checkpoint accepted. **Size:** Large. **Worker:** fresh pair.

**Writable paths:**
- `Sources/MSIScreenCore/HIDFeatureProfile.swift`
- `Sources/MSIScreenCore/HIDFeatureProfileExecutor.swift`
- `Sources/MSIScreenCore/DeviceAdapterRunner.swift`
- `Sources/MSIScreenCore/AdapterProcessHost.swift`
- `Sources/MSIScreenCore/DeviceControlCoordinator.swift`
- `Sources/MSIScreenCore/DeviceOperationJournal.swift`
- `Sources/MSIScreenCore/BuiltInDeviceProvider.swift`
- `Sources/MSIScreenCore/SupportPackageInstaller.swift`
- `Sources/MSIScreenCore/SupportManifest.swift`
- `Sources/MSIScreenCore/SupportRegistry.swift`
- `Sources/MSIScreenCore/DeviceCapabilities.swift`
- `Sources/MSIScreenCore/DeviceSupportResolver.swift`
- `Sources/MSIScreenCore/DeviceResourceLock.swift`
- `Sources/MSIScreenCore/ProcessRunner.swift` (U3 checked invocation scratch-parent seam only; legacy default unchanged)
- `Sources/msi-screen/ExperimentalCommands.swift` (hidden host/worker entry only)
- `Sources/msi-screen/main.swift` (hidden-mode early dispatch only)
- `Tests/MSIScreenCoreTests/HIDFeatureProfileTests.swift`
- `Tests/MSIScreenCoreTests/DeviceAdapterTests.swift`
- `Tests/MSIScreenCoreTests/DeviceOperationJournalTests.swift`
- `Tests/MSIScreenCoreTests/ProcessRunnerTests.swift` (invocation scratch-parent seam regression only)
- `Tests/MSIScreenCoreTests/DeviceCapabilityTests.swift`
- `Tests/MSIScreenCoreTests/SupportPackageTests.swift`
- `Tests/MSIScreenCoreTests/Fixtures/AdapterFixture.swift`
- `Tests/MSIScreenCoreTests/Fixtures/device-support-cases.json`
- `Package.swift` (test resources only if required)

**Done when / evidence:** Both backends pass actual supervised-worker lifecycle checks and exact W5/W6 gates: strict correlated protocol, profile complete-report preservation/one setter/no retry, invocation-copy rehash/signature/build pinning, liveness/borrowed lease/deadline cleanup, zero host activation I/O, independently checked native post-read, scope/identity/target/preservation checks, complete typed layouts/routes/mappings/composition and pre-write refusal for unreachable verification. Authenticated export-safe observations/plans retain canonical round trips; UUID claims/domain epochs prevent old-observation replay even under new UUID; uncertainty preserves partial receipts and never retries/restores. W3 activation gate now closes for both backends. Existing built-in transitions remain their owner. Run focused tests plus full suite, with actual executable fixture evidence. Record per-architecture process/lock coverage honestly; unavailable second architecture is a remaining gate, not PASS.

### U4 — Public CLI, privacy-filtered handoff and exact bundled skills (W7)

**Goal:** Expose the completed local lifecycle/control API and install/copy flow with shared strict export-safe serialization; package both complete skills atomically with resource verification.

**Dependencies:** U3 verified and checkpoint accepted. **Size:** Large. **Worker:** fresh pair/engineer as complexity warrants.

**Writable paths:**
- `Sources/msi-screen/ExperimentalCommands.swift`
- `Sources/msi-screen/main.swift`
- `Sources/MSIScreenCore/DeviceSupportRequest.swift`
- `Sources/MSIScreenCore/AgentSkillInstallation.swift`
- `Sources/MSIScreenCore/DeviceCapabilities.swift` (shared export serializer only)
- `Sources/MSIScreenCore/SupportPackageInstaller.swift` (public lifecycle integration only)
- `Sources/MSIScreenMenu/Stores/AgentSkillInstaller.swift` (preserved façade)
- `Tests/MSIScreenCoreTests/DeviceSupportRequestTests.swift`
- `Tests/MSIScreenCoreTests/SupportPackageTests.swift` (public lifecycle regressions)
- `Tests/MSIScreenMenuTests/AgentSkillInstallerTests.swift`
- `Tests/MSIScreenMenuTests/DeviceSupportRequestTests.swift`
- `skills/write-addhoc-support/SKILL.md`
- `skills/write-addhoc-support/agents/openai.yaml`
- `skills/write-addhoc-support/references/contract-v1.md`
- `skills/write-addhoc-support/references/validation.md`
- `skills/msi-screen-control/SKILL.md`
- `script/package.sh`
- `scripts/verify.py` (CLI/offline/resource gates only)
- `Tests/MSIScreenCoreTests/Fixtures/AdapterFixture.swift`
- `Tests/MSIScreenCoreTests/Fixtures/device-support-cases.json`

**Done when / evidence:** All §12 commands, early local-only strict parsing, capabilities/help/errors/nonzero unverified semantics, rebind/retained lifecycle/dry-runs work through packaged CLI. Actual public JSON across inventory/read/request/plan/receipt/error is privacy-tested, not just copied text. Shared two-skill installation preserves unfamiliar/linked/edited content and only upgrades receipt-owned unchanged trees with checked atomic publication. Handoff uses private expiring exact requests, no raw identifiers/paths or adapter/agent launch. Read skill-authoring guidance when writing the new skill. Both named complete skill file sets match bundle; W7 skill+package+verifier boundary lands together. Run full tests, release packaging and offline packaged verifier; report exact artifact paths.

### U5 — Owned app UX, reciprocal mutation guards and artifact proof (W8 → W9)

**Goal:** Integrate inventory/control into existing app ownership, expose full typed controls/management, then prove packaged and extracted artifacts with isolated fixtures and coordinate externally owned installed-companion QA.

**Dependencies:** U4 verified and checkpoint accepted. **Size:** Large. **Worker:** fresh pair.

**Writable paths:**
- `Sources/MSIScreenMenu/Stores/DeviceInventoryStore.swift`
- `Sources/MSIScreenMenu/Stores/DeviceControlStore.swift`
- `Sources/MSIScreenMenu/Views/DevicesView.swift`
- `Sources/MSIScreenMenu/Views/DeviceCapabilityView.swift`
- `Sources/MSIScreenMenu/Views/DeviceLayoutView.swift`
- `Sources/MSIScreenMenu/Views/DeviceUSBHostControls.swift`
- `Sources/MSIScreenMenu/Views/MonitorView.swift`
- `Sources/MSIScreenMenu/Views/PeripheralsView.swift`
- `Sources/MSIScreenMenu/Views/USBHostControls.swift`
- `Sources/MSIScreenMenu/Stores/MonitorStore.swift`
- `Sources/MSIScreenMenu/Stores/ComputersStore.swift`
- `Sources/MSIScreenMenu/Stores/AppSettings.swift`
- `Sources/MSIScreenMenu/Views/AppSettingsView.swift`
- `Sources/MSIScreenMenu/App/StatusItemController.swift`
- `Sources/MSIScreenCore/AppPermissions.swift`
- `Sources/MSIScreenMenu/Views/PrivacyStatusView.swift`
- `Tests/MSIScreenMenuTests/DeviceSupportStoreTests.swift`
- `Tests/MSIScreenMenuTests/DeviceSupportRequestTests.swift`
- `Tests/MSIScreenMenuTests/DeviceTerminationTests.swift`
- `Tests/MSIScreenMenuTests/AgentSkillInstallerTests.swift` (UI integration regressions)
- `scripts/verify.py`
- `Tests/MSIScreenCoreTests/Fixtures/AdapterFixture.swift`
- `Tests/MSIScreenCoreTests/Fixtures/device-support-cases.json`
- `FEATURES.md`
- `docs/compatibility.md`

**Done when / evidence:** Exact W8 store ownership/view injection/below-button reciprocal guards/termination wiring land atomically, including RPC, native Quit, footer install/update, Sparkle and external OMP-parent idle paths. Selection/generation/digest changes invalidate correctly; no idle adapter polling, fake MSI state, implicit replacement selection or swallowed partial discovery. Devices/typed layout/settings/routes/mappings/peripheral cards/independent skill status/binding lifecycle meet §10 with specified accessibility IDs. Existing MSI controls remain functional.

W9 extends the one verifier with owned, visibly labelled `--support-fixture` inventory/transports and isolated shared CLI/app support/skill roots; ordinary overrides cannot fake success or open live devices. CLI health, install while app stays open, copy/clipboard ownership, metadata reload despite lost notification, Read/draft/Apply/independent receipt, serial-less rebind, skill upgrade/conflict and mutation-sensitive termination paths get observable evidence. Preserve all current signature/architecture/extracted-archive checks. Run:

```sh
swift test
./script/package.sh --configuration release --output dist
python3 scripts/verify.py --offline --binary "dist/MSI Screen.app/Contents/MacOS/msi-screen" --app "dist/MSI Screen.app"
./script/ci.sh
```

Final GUI QA is externally owned by the supervising user using **installed computer-use companion MCP tools only**, background delivery, no installation/focus takeover/destructive/account/sending/publishing actions. Prepare and document the existing verifier invocation:

```sh
python3 scripts/verify.py --gui --support-fixture --binary "dist/MSI Screen.app/Contents/MacOS/msi-screen" --app "dist/MSI Screen.app"
```

Coordinate real tested bundle/CLI paths, fixture start/health/stop ownership, durable job IDs, isolated roots and stable control IDs before QA. Parent must obtain/inspect returned action+result/side-effect evidence; pending external QA or unavailable driver is **INCONCLUSIVE**, never PASS. Do not substitute another automation system. Do not run ordinary hardware stages or `--exercise`.

## Final review and completion gates

One bounded Oracle review of the actual candidate after complex integration, with verified selection/diff artifacts and both guidance contents; keep healthy call alive, fix straightforward in-scope findings through an owned worker, rerun affected real checks. Do not restart product planning or re-adjudicate the plan critique. No repeat Oracle review unless requested.

Final parent inspection compares implementation delta to the captured authoritative input, checks exact requested paths/side effects and test/artifact evidence, and records any failures. Completion requires per-unit verified evidence, release/offline/extracted checks and coordinated GUI result, with architecture/hardware limitations explicit. W10 remains unauthorized, not an implementation success claim. End with terminal worker states or explicit durable handoff; no unattended active workers.

## Append-only checkpoint/evidence trail

- Entry: read all 567 lines of final plan, shared guidance and project guidance. Revalidated `main`/`c74a543`; captured snapshot `2026-10-21/0858`. Read `scripts/managed.ts` launch-client pattern. No implementation or device requests issued.
- Supplied update: baseline OMP job above reports 155 passing tests; planning session above is directed not to duplicate dispatch. Before workers, inspect current sibling ownership and baseline log.
- Checkpoint 0: breakdown exported; awaiting inspection before any worker dispatch.
- Checkpoint 0 accepted on resume: supervisor independently verified all 155 baseline tests and settled sibling implementation ownership. No export replay or additional approval required.
- U1 dispatched: fresh RepoPrompt pair worker `F55F1242-8C12-442C-BFD8-7D773B4180BD` (Codex CLI, running), authoritative checkout, exact U1 scope, no implementation subdelegation/live experiments. Direct orchestration path confirmed; U2 remains blocked on parent verification and checkpoint.
- External QA preflight: supervisor discovered installed computer-use companion tools; first read-only `list_apps` returned `isError:true`, `bootstrapTimedOut`. Core implementation continues. Prepare isolated real fixture for supervisor retry after the artifact is ready; do not install/enable plugins/connectors or switch automation. Persistent unavailability is GUI QA INCONCLUSIVE, not PASS.
- U1 worker completed its initial pass: 16 authorized paths, 49 focused / 179 full tests, OMP `msi-u1-acceptance-20261021` / `e963826a-dba7-4520-9b28-abfcc66b2f31`, exit 0. No loader/runtime exposed. All worker jobs terminal at that point.
- Parent independently inspected strict JSON, manifest protection, endpoint identity/privacy/resolution, actual passive-source call paths, scope/target/receipt validators, legacy extraction/projections and W0 session/termination seams. Parent OMP `msi-u1-parent-acceptance-20261021` / `600ca457-b227-4029-ac45-94d5e0b3954c` exited 0: `swift test` 179/0, then `git diff --check`. Log: `/Users/danielsivan/.omp/run/daemons/4ff10f9b3f924d4f/daemons/msi-u1-parent-acceptance-20261021/output.log`; actual passive test reported 31 records / 2 displays / all sources complete.
- Parent preservation proof: reconstructed the 15 originally modified tracked files from HEAD plus snapshot `0858` patch in owned disposable state; all 14 outside U1 are byte-identical to input. Item-only delta (16 files, initially +2458/-96) and per-file hashes: `/private/tmp/msi-experimental-u1-evidence-mflqaicf/u1.patch` and `preservation.json`. Snapshot `0955` is a full working-tree diff, not a delta from snapshot contents. Original snapshots omit untracked bytes, so retrospective byte comparison of unrelated untracked input is unavailable; U1 owns none of those preexisting untracked files.
- Parent correction pending: `distinctInputs:true` layouts could be declared without any feasible complete assignment, violating internal consistency. Same U1 worker steered for a failing regression and bounded shared-validator fix in only `DeviceCapabilities.swift` / `DeviceCapabilityTests.swift`, then focused/full checks. No dependent dispatch.
- U1 evidence limits carried forward: arm64/macOS 26.5 only; x86_64/macOS 13 untested. Responsible-launch-client attribution for future adapter launches remains unverified and must be measured with the packaged runtime fixtures when available; existing caller permission checks are not that proof. This does not meet the final plan's W0 attribution-before-editing requirement, so it is reported as an outstanding gate rather than silently marked complete. Reconnect/non-console/twin failures were injected, not live experiments. No active-I/O claim exceeds source/call-path evidence plus actual passive OS enumeration. Persistent key initialization and host authentication are U2/U3, not implemented execution in U1.
- U1 correction verified: meaningful red regression (`msi-u1-distinct-red-20261021`, `5cceb3fc-1f6b-4483-b349-d7b9a6d769d9`) failed with four assertions proving impossible constraints were accepted. The shared validator now checks Hall's condition over at most 255 slot subsets; feasible overlapping choices remain accepted. Worker green job (`msi-u1-distinct-green-20261021`, `d94ff190-0210-4ac4-ab97-2ec5d269f7c0`) passed 12 focused / 181 full tests. Parent inspected the actual fix/tests and red log.
- U1 FINAL parent acceptance: OMP `msi-u1-parent-final-20261021`, `58f2ea81-cc76-4c08-8921-3198ec2ff421`, terminal `exited`, exit 0; `swift test` **181 tests / zero failures**, followed by `git diff --check`. Log: `/Users/danielsivan/.omp/run/daemons/4ff10f9b3f924d4f/daemons/msi-u1-parent-final-20261021/output.log`. Actual passive enumeration again reported 31 records / 2 displays / all three sources complete.
- U1 FINAL item-only evidence: `/private/tmp/msi-experimental-u1-evidence-mflqaicf/u1-final.patch` and `/private/tmp/msi-experimental-u1-evidence-mflqaicf/preservation-final.json`; 16 authorized files, +2509/-96, no unexpected tracked-input changes. All 14 originally modified tracked files outside U1 remain byte-identical; Package.swift's prior Sparkle input is retained and its item delta is test-resource registration only. Final status: 21 modified / 29 untracked, accounting for U1's six newly modified tracked paths and nine new source/test/fixture paths plus this parent-owned breakdown.
- Worker `F55F1242-8C12-442C-BFD8-7D773B4180BD` is terminal Completed after correction (run `48B3C1A3-F810-4303-9D82-DC1EF89843DE`). U2 has not started. Checkpoint 1 requests inspection of final diff/logs, explicit disposition of the carried attribution gap, and approval before dependents.
- Checkpoint 1 accepted (`accept`): proceed to U2 with the recorded attribution gate deferred to runtime fixtures. Revalidated `main` / `c74a543`, unchanged status counts, and all 16 approved U1 file hashes before dispatch. Captured exact existing bytes/hashes for U2's 18 authorized paths (10 currently exist) at `/private/tmp/msi-experimental-u2-evidence-53uefh68/before/` and `before-manifest.json`, avoiding retrospective untracked-input gaps for this unit.
- U2 dispatched: fresh pair worker `548F5CB4-7D6F-484A-9555-7DF634071C41`, authoritative checkout, exact 18-path scope, no sibling writers. W3 executable validation/activation gate remains explicitly pending W5/U3; no user-visible half-enabled loader. Parent remains sole breakdown owner; U3 blocked on U2 verification/checkpoint.
- U2 interim inspection: parent read current descriptor-relative storage, key/CAS and inactive publication/native-validation code. Found `minimumMacOS` integer parsing used `compactMap`, silently dropping an overflowing component (24-byte `1.99999999999999999999.0` became `[1,0]`). Steered the same healthy worker to add a real-boundary regression and reject any failed component parse before U2 completion. No restart or dependent dispatch. Parent separately measured current platform with `sw_vers` / `uname -m`: macOS 26.5 (25F71), arm64.
- U2 initial worker pass completed: 60 focused / 208 full tests, OMP `msi-u2-final-verified-20261021` / `629d3d35-4ff9-4a88-a33a-4c50f20bec22`, exit 0, all 16 worker jobs reported terminal (`jobs-final.json` in U2 evidence). Parent independently reconstructed 16-file +1740/-161 delta and checked approved U1/original tracked input outside U2 unchanged: `/private/tmp/msi-experimental-u2-evidence-53uefh68/u2-parent.patch`, `u2-parent-preservation.json`.
- U2 initial parent acceptance: `msi-u2-parent-acceptance-20261021` / `3cbc44dd-01b7-4504-a303-3142d319ec65`, terminal exited 0; actual `swift test` log shows 208/0 and owned fixture executable use, followed by `git diff --check`. Log under `/Users/danielsivan/.omp/run/daemons/4ff10f9b3f924d4f/daemons/msi-u2-parent-acceptance-20261021/output.log`.
- U2 parent corrections pending: exact generic guard/lease/selected-HID paths still constructed `MonitorUSBTopology`, whose intentionally retained singleton guard rejects multiple MSI controllers even for an exact/unrelated selected endpoint. Hub Rapoo compatibility exclusion only considered MSI-associated hubs, omitting generic hubs with Rapoo descendants. New built-in USB selection prerequisite also ignored partial source outcomes, risking false absence/remote-fallback authorization. Same U2 worker steered to raw shared graph facts, preserve public built-in singleton semantics, test generic hub exclusion and reject incomplete selection sources; only current U2-owned paths authorized. Parent has inspected actual spawn PID reservation/descriptor/environment/cleanup and lease/guard source, not accepted by summary. U3 remains blocked.
- Additional U2 selected-open correction: installed SDK `IOHIDManager.h` explicitly says `IOHIDManagerOpen` opens all current/future enumerated devices. The new selected initializer used a VID/PID-wide manager open before registry-ID filtering, touching unselected controllers. Same healthy correction run steered to open only the exact revalidated registry interface with symmetric thread/run-loop ownership; public built-in behavior stays owned. No live I/O authorized or used for this finding.
- U2 recovery: supervisor requested resume after provider capacity loss. Inspected the persisted original worker once: it was already Completed with corrections; no work replay, duplicate dispatch or healthy-job restart. The old local CLI wait handle had expired; terminal worker/job state was resolved from durable handles, not repeatedly polled.
- U2 corrections verified in actual source: generic guard/leases use raw `USBDeviceGraph`; legacy public built-in selection retains singleton semantics. Incomplete USB/HID sources fail before selected queries/fallback. Generic hubs take Rapoo compatibility exclusion for actual descendants. Selected HID path resolves exact registry interface, opens it directly and symmetrically schedules/closes that device; manager-wide opening remains only in public built-in path. Parent read the actual guard/HID/lease code and meaningful exact/absent/ambiguous/two-controller/hub/partial regressions. Red job `e993f337-559a-4d19-892e-0db2549161cf` reproduced 12 failures in 3 tests; parent inspected its log. Worker correction final `f28c53ae-dc9d-4236-b7c2-f9255278f9c2` exited 0, 78 focused / 213 full tests. Worker artifacts: `/private/tmp/msi-u2-correction-dt78elcr/`.
- U2 FINAL parent acceptance: OMP `msi-u2-parent-final-20261021` / `3e313911-13b1-48ff-a44f-6bd79568dd4d`, terminal exited 0; actual `swift test` **213 tests / zero failures**, then `git diff --check`. Log: `/Users/danielsivan/.omp/run/daemons/4ff10f9b3f924d4f/daemons/msi-u2-parent-final-20261021/output.log`. Actual owned fixture executable exercised; passive inventory again 31 records / 2 displays / sources complete. Tested bundle exists at `/Users/danielsivan/dev/msi-screen-control/.build/arm64-apple-macosx/debug/MSIScreenControlPackageTests.xctest`. Disposable fixture executables are cleaned, not release assets.
- U2 FINAL parent-owned item delta: `/private/tmp/msi-experimental-u2-evidence-53uefh68/u2-parent-final.patch`; 16 authorized files, +1973/-177. `/private/tmp/msi-experimental-u2-evidence-53uefh68/u2-parent-preservation-final.json` records exact before/after hashes; all approved U1 files outside U2 and original tracked input outside scope remain unchanged. Parent queried all 20 listed U2 jobs once: all terminal, none active (`terminal-jobs-parent.json` alongside the patch). Expected red jobs failed as reproduced; final acceptance passed.
- U2 worker `548F5CB4-7D6F-484A-9555-7DF634071C41` is terminal Completed. U3 has not started. Execution/activation remains disabled (`executionReady:false`, resolver `executionValidationPending`). W5 selfTests/backends/invocation pinning/actual support-host lifecycle, W6 authentication/journal, responsible-client attribution, x86_64/macOS 13 and later packaging/installed-companion GUI QA are still unverified. Foundational parent-loss fixtures are not packaged-host proof; no physical-panel/hardware qualification claim. Old Bolt clients still cannot honor the new leases. Checkpoint 2/report is the current stop boundary.
- Checkpoint 2 accepted (`accept`): U2 completion report/evidence inspected; continue the original sequential implementation with fresh U3 ownership. Acceptance does not convert deferred runtime/attribution/architecture/hardware evidence into PASS. U1/U2 workers remain terminal.
- U3 dispatched: fresh pair worker `09622D08-5A79-4D3C-88BE-85EB8957ADE9`, exact 23-path scope, no sibling writers. Revalidated `main` / `c74a543` and all approved predecessor hashes; before bytes/hashes at `/private/tmp/msi-experimental-u3-evidence-na89zqro/before/`, `before-manifest.json`, `approved-predecessor-hashes.json`. Both supervised backends and authenticated control/journal gates precede operational readiness; U4 public CLI/skills and U5 UI are not authorized to this worker. All original hardware/publication/GUI boundaries retained.
- U3 minimal scope reconciliation: worker identified that structured HOME/TMPDIR must live inside the owned invocation directory, while U2's primitive always creates a generic temporary scratch directory. Parent authorized only a checked optional scratch-parent seam in `ProcessRunner.swift` plus focused `ProcessRunnerTests.swift` regression; preserve default/legacy behavior, reject unsafe roots without fallback, no scope beyond these two plan-listed files. Captured their exact bytes/hashes before approval; both match approved U2, expanding U3 to 25 paths. No new product decision or approval gate.
- U3 interim worker evidence: first W5 focused run 9/0 (both hidden backend selfTests and real native lifecycle/protocol failures); first W6 focused run 13/0 (typed controls/composition on both backends, durable replay refusal after lost apply response). Parent has not yet accepted U3 or those checks by summary. Read-only parent prerequisite probe found an installed `com.apple.pkg.RosettaUpdateAuto` receipt; steered original healthy U3 run to assess actual translated x86_64 fixture/test execution with installed tools only, no installation or assumption of success. Translation must not be described as Intel hardware/macOS13 proof. Current healthy checks remain alive.
- U3 initial parent checks recovered and independently confirmed: OMP `msi-u3-parent-acceptance-20261021` / `d3640560-d70c-4ba1-9fff-05c81b34ab21`, terminal exited 0. Actual log records 236 full arm64, 19 packaged-host and 58 translated x86_64 tests, all zero failures, plus diff/signature checks. Tested initial app: `/private/tmp/msi-u3-packaged-20261021/MSI Screen.app`; not yet the final corrected candidate. No Intel-hardware/macOS13 or responsible-client-attribution proof; `executionReadinessGaps` keeps operational execution disabled.
- U3 correction pending parent acceptance: readonly information/telemetry was included in configuration commitments and full equality, so harmless changes could falsely stale a plan or invalidate independent readback. Same worker `09622D08-5A79-4D3C-88BE-85EB8957ADE9`, correction run `1B2BE3DB-406D-4CE5-B57B-84496574FD7E`, is active on meaningful native/profile fixtures and shared configuration-only comparisons. Identity, guards, writable configuration and full-byte writable-report preservation must remain strict. Recovered the original healthy invocation after transport/provider loss; no duplicate work or test restart. U4 remains blocked.
- U3 correction worker completed. Parent inspected shared projection/transition code, exact profile IOKit transport/preservation, host pinning/handshake/borrowed-lease/liveness paths and actual native/profile regressions. Red log independently reproduces 2 tests / 12 failed assertions; corrected native fixtures exercise each comparison boundary, while guard/preservation/undeclared effects still fail after one setter. Worker final arm64 job `6dba9711-9d32-4b6f-aca2-18b463cad6b1` reports 239 full / 25 packaged-host/profile tests; translated x86 serial job `098a2e74-af9a-4ab3-8755-e124bf271dc7` reports 61/0. An earlier concurrent x86 bad-hello fixture timed out instead of the expected mismatch; preserved failure, unchanged serial candidate passed without relaxed deadlines.
- U3 parent-owned item proof: `/private/tmp/msi-experimental-u3-evidence-na89zqro/u3-parent-final.patch` and `u3-parent-preservation-final.json`: 22 changed authorized paths, +3203/-14; all approved predecessor files outside U3 and original tracked pending input outside scope unchanged, HEAD still `c74a543`. Independent corrected-candidate acceptance is running as OMP `msi-u3-parent-final-20261021` / `70243661-e324-4256-bfac-7bae1d3bb460` (full arm64, parent-owned release package, packaged host/profile, existing offline verifier, translated x86, diff/signature). Target artifact `/private/tmp/msi-u3-parent-final-20261021/MSI Screen.app`; not PASS until terminal evidence is inspected.
- U3 FINAL parent local software acceptance: OMP `msi-u3-parent-final-20261021` / `70243661-e324-4256-bfac-7bae1d3bb460`, independently inspected terminal exited 0. Actual log: **239 full arm64 / 25 packaged-host+profile / 61 translated x86 tests**, all zero failures; parent release packaging, existing offline verifier, `git diff --check` and deep/strict signature verification passed. Owned bundle `/private/tmp/msi-u3-parent-final-20261021/MSI Screen.app`, CLI `Contents/MacOS/msi-screen` SHA-256 `fdf45b5f87029e9b7fa89c316c4f05fa73624aa5936c3762b340afdc39d6d21b`. Ad hoc arm64 bundle, not notarized/universal/physical-panel proof. Offline evidence `.local/verify-20261021-141131-aed647`.
- U3 FINAL parent evidence: `/private/tmp/msi-experimental-u3-evidence-na89zqro/parent-final-acceptance.json`, `parent-final-job.json`, `u3-parent-final.patch`, `u3-parent-preservation-final.json`, `terminal-jobs-parent.json`. Rechecked exact source hashes after tests; no out-of-scope predecessor/original tracked changes. All 24 worker jobs independently resolved terminal (14 exited / 10 failed including preserved red/intermediate failures), using persisted OMP metadata for 18 historical jobs no longer registered in the current broker; six current correction states were inspected directly. Worker `09622D08-5A79-4D3C-88BE-85EB8957ADE9` is terminal Completed. No active worker or owned test job remains.
- Checkpoint 3 requests inspection before U4. Software/backend fixtures pass; operational readiness remains explicitly disabled. Responsible-client attribution and native Intel/macOS13 lifecycle are unverified, W0 attribution-before-editing was not met, U4 public CLI/skills and U5 UX/extracted/support-fixture/installed-companion GUI checks remain outstanding. GUI preflight remains INCONCLUSIVE. No W10/hardware activity is authorized; no Oracle review has yet been used (reserved for the final integrated candidate).
- Checkpoint 3 `ask_user` timed out after 600 seconds with no answer. This is not approval; no U4 worker dispatched. All workers and owned test jobs remain terminal; awaiting checkpoint inspection/response.
