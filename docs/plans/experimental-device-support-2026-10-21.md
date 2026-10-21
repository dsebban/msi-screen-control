# Experimental device support

Implementation plan · 2026-10-21 · macOS 13+

## Goal

Detect connected screens and peripherals even when MSI Screen cannot control them. Add an experimental **Write ad-hoc support** action that copies a device-specific request invoking the installable **`write-addhoc-support`** skill; the agent already running on the computer can author, validate, install, and activate a local extension without rebuilding the app.

## Outcome and boundaries

The user selected these product decisions in the up-front interview:

1. **Both declarative profiles and executable adapters**, according to the protocol.
2. **Copy and paste into the existing agent**, not automatic agent launch, session selection, or messaging.
3. **Full layout/KVM and peripheral-control extensibility**, not an identity-only or screens-only feature. This does not promise controls that hardware or macOS does not expose.
4. **Automatic installation and activation after checks**, without another extension-approval click or per-write confirmation in ordinary controls.

Activation makes checked support available; it does not authorize research probes or experimental hardware writes, establish live identity, or prove physical behavior. Passive discovery and offline validation may proceed automatically. The skill must obtain explicit authorization for named active device experiments. Ordinary explicit Read/Apply actions use the normal controls thereafter.

### Done when

- With no supported MSI controller, the real app and CLI still enumerate OS-visible displays and peripherals, explaining support, availability, and incomplete discovery independently.
- Copying a selected device's support request installs the exact bundled skill if absent, preserves unfamiliar skills, and copies no personal device identifiers or paths.
- A generated declarative profile and a generated native adapter can each pass the same local package lifecycle, become available in the open app without rebuilding/restarting, and expose typed controls through both clients.
- Layout templates, video inputs, USB destinations, settings, and onboard input mappings use device-specific IDs and explicit, guarded targets rather than MSI-specific enums.
- Built-in hardware retains its existing verified controller paths. Experimental execution cannot silently claim those configuration domains, guess an endpoint, overwrite stale state, or resend an uncertain write.
- The packaged executable/bundle passes the existing verifier extended with isolated inventory, package, adapter, clipboard, lifecycle, and GUI fixtures. Hardware qualification is separately authorized and records protocol and physical evidence separately.

### Non-goals

No extension marketplace, downloads or sharing, automatic agent launch, background protocol experimentation, generic remote adapter deployment, firmware/bootloader operations, factory resets, pairing changes, arbitrary host commands, input recording, or automatic rollback/retry. No promise of universal Bluetooth, USB, DDC/CI, GPU, adapter, or monitor compatibility. Existing MSI remote/Linux workflows continue unchanged; new support runs on this Mac only.

## Background: observed seams and constraints

### Planning baseline

Repository `/Users/danielsivan/dev/msi-screen-control`, branch `main`, HEAD `c74a543`. The authoritative checkout includes pending identity, app, skill, packaging, and updater work; do not implement against HEAD alone or overwrite those changes. Reconcile the checkout again before execution. This document proposes work; none of its new types, commands, or tests exists merely because it is specified here.

Shared guidance is `/Users/danielsivan/.agents/AGENTS.md`; project guidance is `AGENTS.md`. Shared device logic belongs in `MSIScreenCore`; app and CLI are clients. Relevant observed seams:

| Owner | Current behavior and implementation consequence |
| --- | --- |
| `MonitorIdentity.swift:3–28` | Only identity `3030a0` and protocol `563230` (`V20`) authorize `MD342CQP/V20`. Two read-only queries, `00140` and `00150`, preserve unknown bytes. These are MSI-family requests, never universal safe probes. |
| `ScreenController.swift:31–84,123–166` | `ScreenTransport`, per-operation session ownership, identity gating, complete baseline comparison, no-op, complete layout packet, settling, and readback. The extra write is restricted to the reproduced cold USB-C/video-enumeration condition. Preserve PIP geometry and coupled PBP/PIP secondary inputs; do not generalize packets, timing, or retry exceptions. |
| `HIDConnection.swift:13–96` | Video display count is separate from USB controller matching. One matching MSI HID controller is required. `controller.lock` is nonblocking; callbacks, run loop, reports, assertions, and teardown belong to the creating thread/session. |
| `KVMCoordinator.swift:38–60,113–128` | `KVMEndpoint` is an injection seam. Only genuine local absence allows remote fallback; unsupported, malformed, or busy are errors. The existing setter/destination-readback sequence must remain the owner of MSI handoffs. |
| `MacUSBPeripheralReader.swift:8–52` | Real ancestry associates receivers with one MSI controller's parent hub. Bolt `046d:c548` and Rapoo `24ae:186a` are specialized matches, not a universal inventory. Extract raw facts without importing the singleton assumption. |
| `USBPeripherals.swift`, `GameControllers.swift`, `PeripheralsView.swift` | Receiver location, paired identity, radio response, native macOS support, declared controls, and observed input are different evidence. Sleeping/unresponsive does not mean unsupported or absent. A receiver is not its paired device. |
| `MonitorStore.swift`, `LayoutCoordinator.swift`, `MachineFocusCoordinator.swift` | Existing stores/coordinators own MSI drafts, USB owner changes, staged operations, and receipts. General devices need separate value models and stores, not fabricated `ScreenState`/`KVMSnapshot` values. |
| `StatusItemController.swift:7–35,93–121,198–214,262–290` | The app delegate owns stores, constructs `MonitorView`, observes changes, refreshes built-in state while closed, and defers termination for active operations. Extend this owner rather than creating stores in another app entry point. Do not extend its closed-panel MSI timer into adapter polling. |
| `AppUpdater.swift:24–26,43–49` | Sparkle owns update sessions; the app's termination gate already protects writes. Extend runtime busy coverage without taking over/stalling Sparkle's session. |
| `AgentSkillInstaller.swift:6–37` | Skill resources install under `~/.agents/skills`; identical content is a no-op, conflicting content is preserved, publication uses unique staging/no-overwrite move. Strengthen link checks rather than replacing user-maintained skills. |
| `ProcessRunner.swift:4–37,51–144` | Explicit executable/argument arrays, bounded combined output, deadline, private stdin file, and owned-group timeout cleanup. Streams are merged, cancellation is absent, and normal leader exit does not clean descendants. It is not yet an adapter host. |
| `main.swift`, `script/package.sh`, `scripts/verify.py`, `FEATURES.md` | Hand-written CLI and structured JSON, complete bundled skill resources, real package/signature checks, GUI ownership receipts, and one maintained verifier. Extend them instead of creating competing infrastructure. |

Paths in this table without prefixes are under `Sources/MSIScreenCore/`, except Menu stores/views/app files, `Sources/msi-screen/main.swift`, and the named scripts/docs. File impact below gives exact paths. `docs/compatibility.md:3–18` is the nearest prior design record: other MSI identities are unverified, shared USB IDs do not establish support, and experimental evidence must not silently change paid compatibility claims. Scoped reconnaissance found no existing generic extension loader.

Current trusted flow is **explicit target → fresh identity and baseline → owned session/lock → protocol-specific write → settling/readback → receipt → notification after release**. Owner-aware MSI operations add machine registry checks, USB acquisition, destination verification, and stage receipts. Inventory must succeed independently of either chain.

### Platform evidence

Apple documents hardened-runtime library validation for Apple/same-Team-ID code and additional scrutiny when disabled. Use subprocess adapters; do not disable library validation or load generated dylibs into the app. Process isolation is **not sandboxing**. [Library validation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.disable-library-validation), [Apple DTS library-loading guidance](https://developer.apple.com/forums/thread/706437).

Quartz display enumeration/configuration does not establish a device-specific control transport. HID APIs enumerate interfaces and metadata and exchange reports, but HID is not all USB, and public API availability does not guarantee access to a given device. Use public OS enumeration and surface incomplete/denied sources rather than inventing DDC access or using private CoreDisplay APIs. [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services), [HID interface guide, archived](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/HID/new_api_10_5/tn2187.html).

Do not strip quarantine, self-grant privacy permissions, install drivers/toolchains, or assume the signed app's trust/permissions transfer to an adapter. Execution and device access can fail independently of prior app success. macOS privacy attribution can follow the responsible app/terminal/agent client rather than a separately grantable adapter identity; W0 must verify attribution for packaged-app and CLI launches. Sandboxed USB entitlement documentation is a constraint reference, not a universal grant. [Notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [USB entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.usb). Research used `exa-cli`; archived HID documentation is background, not a promise about all macOS 13+ transports.

## Architecture and data flow

Choose an additive, typed local-provider boundary rather than rewriting the verified MSI stack:

**Passive inventory → exact selected control endpoint → built-in or explicit experimental binding → descriptor → explicit observation → typed draft → hardware-free plan → guarded single execution → readback/receipt.**

Separately: **selected endpoint → checked skill installation → private expiring local request → sanitized copied prompt → existing agent → researched package → offline validation → atomic binding activation → metadata reload.**

Core owns discovery, identities, capability validation, resolution, packages, processes, locks, plans, receipts, and prompt construction. Menu owns presentation, clipboard, selection and drafts; CLI owns parsing and JSON emission. Profiles use a fixed compiled HID feature-report engine. New protocols use one-shot native executable adapters. Package metadata never embeds shell commands, launch arguments, expressions, or installer hooks.

### 1. Passive inventory and endpoint identity

Add immutable `Codable`, `Equatable`, `Sendable` values, never live IOKit handles:

| Type | Required fields |
| --- | --- |
| `DeviceInventorySnapshot` | Schema 1, checked time, generation, ordered devices, separate display/USB/HID source outcomes. |
| `DeviceRecord` | Opaque host-local ID, bounded local display name, kind, endpoint facts, relationships, binding eligibility. |
| `DeviceKind` | `display`, `hub`, `receiver`, `keyboard`, `pointer`, `gameController`, `other`; descriptive, not control authorization. |
| `DeviceEndpoint` | Tagged display/USB/HID/provider-observed-paired endpoint, private address, passive identity, physical-domain key, incarnation. |
| `DeviceRelation` | `usbParent`, `interfaceOf`, `pairedThrough`, `controlsDisplay`, each with evidence. |
| `InventorySourceOutcome` | `complete` or `failed(code,message)`; failure cannot masquerade as an empty successful source. |

`MacDeviceInventoryReader` performs passive OS enumeration on a serial utility queue. Displays use `CGGetOnlineDisplayList` and public vendor/model/built-in/main/active/asleep/mode facts. USB uses the registry device graph; HID uses registry/interface properties and declared usage pairs. Do not seize/open report sessions, send Get/Set/feature/output requests, register input listeners, inspect pairing protocols, launch adapters, acquire the MSI lock, wake displays, or query SSH during inventory. Existing native controller observations may be merged through their current actor/framework owner; do not change their authorization semantics.

Reuse immutable facts from `MacDisplayController`, `MacUSBPeripheralReader`, and `GameControllers`. Extract a small `USBDeviceGraph` only for their genuinely shared enumeration/ancestry. Preserve a visited set and 32-step ancestry bound. `MonitorUSBTopology` retains its specialized one-controller validation and receiver projections; generic inventory handles zero/multiple controllers and records uncertainty rather than setting unknown topology to false.

Endpoint addresses are local-only: display ID plus available display UUID; USB registry entry and parent IDs; HID registry/interface/transport/usage facts; paired device receiver plus provider-validated pairing identity. Pairing slot alone is not identity. USB/HID interfaces may group only through real ancestry, retaining separately targetable interface identities and the union of declared usages. Never merge devices merely by VID/PID, location, name, or count.

**Identity and reconnection**

- Create a private 32-byte installation key. Export keyed host-local IDs, not raw identifiers or plain serial hashes.
- Keep serials, display UUIDs, Bluetooth addresses, registry paths, location identifiers, and the boot identity in private local state; normal inventory JSON exposes opaque IDs and nonunique facts only.
- Durable anchors are an available OS display UUID or nonempty transport/vendor/product/serial tuple unique in the current inventory. Neither establishes protocol support. Recheck uniqueness on every resolution.
- Otherwise bind to the current attachment only. Incarnation includes boot and endpoint registry identity and expires on disconnect/replacement. Replugging identical twins does not transfer control via ordinal. A user can bind an already-validated retained package to a newly selected attachment without another agent session; see §6.
- Re-enumerate immediately before opening; require the same endpoint, incarnation, passive identity, interface, and physical domain. Zero matches is stale/absent; multiple matches is ambiguous; never take the first.
- A durable binding may reappear after reconnect, but controls require a new explicit read and protocol identity check. A transient binding requires explicit reselection and metadata-only rebinding, not regeneration/reinstallation. Static selectors still never bind it automatically.
- If an existing identity key is unreadable, do not replace it. Show transient inventory; reject persistent binding/control with the concrete reason. Initialize a missing key atomically under the registry lock so concurrent app/CLI first use cannot generate different IDs.

A video display and USB control device remain separate unless a provider supplies a verifiable association. Names or one-of-each counts are insufficient. Controls can attach to a controller with **Video display association unknown**, avoiding an invented association. A passive MSI display match is a candidate, never proof that the USB tuple is verified.

### 2. Resolution and protected built-in domains

`DeviceSupportResolver` chooses one configuration provider per physical control domain; passive/native input observations may coexist. Closed states are `builtInCandidate`, `builtInVerified`, `experimental(binding,digest,identityState)`, `unconfigured`, `collision(candidates)`, and `disabled(reason)`. Experimental identity state is `notRead` or `matched`. Availability/error/radio/permission states remain separate from support resolution.

No directory order, version sorting, partial capability merging, or failure-driven provider fallback. Installation binds an explicit selected endpoint. Replacement requires expected prior digest and registry revision. Static package selectors describe eligible models/interfaces; they never automatically bind every matching device.

Compiled `BuiltInControlDomainCatalog`:

| Domain | Protection |
| --- | --- |
| MSI HID `1462:3fa4` | Trusted guard `msi-identity-v1`; reserve exact `3030a0`/`563230`; share existing `controller.lock`. |
| Bolt `046d:c548` | Reserve existing receiver configuration domain in v1; retain pairing/detail behavior. No process lock today; new binaries add the shared receiver-domain lease around active queries. |
| Rapoo `24ae:186a` | Reserve existing receiver configuration domain in v1; retain mappings/host-handler coordination. Existing `rapoo.lock` is a compatibility lease, separate from `controller.lock`. |
| Existing native OS display/controller operations | Keep their trusted existing owners. Declared OS-native support does not authorize monitor-register or peripheral-configuration writes. |

Experimental MSI selectors must declare the trusted guard and finite exact allowed identity/protocol tuples disjoint from the protected tuple. Wildcards, exclusion-only rules, names, or an adapter's own support assertion cannot bypass it. The current evidence lacks equivalent narrowing guards for Bolt/Rapoo receiver domains, so v1 refuses experimental configuration there; this includes paired devices reached through those reserved receivers. This is a known first-contract limit, not a claim that all products using those receivers are supported. Adding a narrower trusted guard is later evidence-driven work.

At each live MSI read/apply: acquire operation and legacy leases → re-resolve exact endpoint → compiled two-query guard → reject protected/unlisted/malformed/absent/busy identities → continue only for an explicitly permitted experimental tuple. Do not dispatch the originally requested experimental operation to a built-in provider after discovering a protected tuple; return provider-changed and require refresh.

Add an internal `HIDConnection` initializer for selected registry endpoint and borrowed lease. Public initialization retains singleton selection and lock ownership. The guard creates/uses/destroys the HID session on one thread before any await. Only a file-descriptor lease survives into adapter work. Inventory/install/activation/reload never issue identity queries; non-MSI devices never receive MSI requests.

### 3. Typed capability, state, plan, and receipt contract

`DeviceCapabilities.swift` owns explicit tagged JSON, not synthesized associated-value enum encodings. Shared validators serve UI, CLI, profiles, adapter boundaries, and host verification.

`DeviceCapability` fields: stable ID, title, category, presentation order, `readOnly|readWrite`, typed definition, mutation-scope ID, evidence IDs, declared execution/settling budget, verification definition and unavailable reason where appropriate. IDs are 1–64 bounded ASCII letters/digits plus `.`, `_`, `-`; labels are at most 128 UTF-8 bytes without control characters. Reject duplicates and invalid domains, do not truncate them into valid definitions.

| Kind | Definition/value |
| --- | --- |
| `integer` | Inclusive bounds, positive step, optional unit; reject overflow/nonintegral/out-of-step values. |
| `boolean` | Typed Boolean. |
| `choice` | At most 32 unique ordered IDs/titles; target must be a member. |
| `text` | Read-only text, maximum 128 UTF-8 bytes; explicit export policy and source-reviewed nonpersonal semantics. Serial/identifier/device-name text is local-only and never emitted to the agent. |
| `layout` | Device-local inputs/templates/slots/options/distinct-input constraints. Complete value: template ID, all slot assignments, all options. |
| `usbRoute` | Explicit destination IDs, affected domain, configured policy distinct from observed owner, verification/control reachability. |
| `inputMapping` | Device control IDs and finite onboard action IDs; complete mapping. No scripts, app launches, or host command values. |

`DeviceValue` mirrors these kinds. Unknown/missing values carry an unavailable reason; never substitute zero, false, or a first option. Layout templates support up to eight slots with normalized integer rectangles 0…10,000 and z-order. Rectangles describe panel composition, not OS desktop positions. Display modes, inputs, mapping choices, slot geometry, references and limits must be internally consistent.

A mutation scope declares observed configuration fields, required guard fields, writable fields, documented coupled fields, preserved fields, and an optional opaque preservation commitment. Native adapter stale comparisons exclude timestamps/labels/unrelated telemetry. Full profile reports have stricter preservation below. Evidence records distinguish declared/device metadata, source/vendor review, offline fixture, protocol readback, and physical observation; nothing promotes itself into physical support.

`DeviceObservation`: schema, device/incarnation/binding/digest, checked time, typed values, unavailable reasons, guard state, scope commitments, persistent configuration-domain epoch, and host HMAC. Commitments bind canonical complete configuration, including preservation state, not arbitrary telemetry. Only Core can authenticate an observation after a live read under the resource lease. A plan cannot operate from an unauthenticated caller-edited observation or a declaration-only descriptor. Private preservation bytes/addresses remain host-side; exported observations use authenticated opaque commitments and export-safe values. Authenticate that complete export-safe projection, not fields later omitted by serialization. On apply, re-resolve private addresses and re-read private preservation state under the lease, requiring its commitment to match; no private snapshot must traverse agent stdin to validate the observation. Exported incarnation/domain identifiers are keyed opaque tokens too.

`DevicePlan`: schema, operation UUID, issued/expires times, exact identities/digest, registry revision, expected commitments, explicit operation, complete normalized target, ordered stages, computed changes, host-authenticated plan digest. Expiry is five minutes. Derive domain-separated HMAC keys for observations and plans from the installation key. Canonical form is sorted-key UTF-8 JSON with fixed integer milliseconds since Unix epoch for times, lowercase hex digests and no floats; authenticate all fields except the authentication field itself. Preserve the authenticated form through stdin round trips and verify it before planning/dispatch. A plan is local, not a security token against native code running as the same user.

Operation union: `setCapability`, `setLayout`, `setUSBRoute`, `setInputMapping`, and explicitly advertised `setLayoutAndUSB`. A hardware-free adapter `plan` may normalize documented coupling from supplied observations; the host validates every effect against the declared scope. No hidden changes or unknown operation tags. Planning is the dry-run path and performs no new device I/O; a separate explicit read obtains a baseline.

`DeviceMutationReceipt`: operation identity, before/target/after, ordered stage receipts, structured failure, outcome `notAttempted|noChange|verified|unverified|cancelled`, `writeMayHaveOccurred`, per-stage attempted/completed/acknowledged, host-calculated `verified`. Acknowledgment is not proof. Verification requires target values, preserved state, guards, and declared ownership checks. Nonzero exit/malformed output cannot become verified because a claimed Boolean says so. No-op verifies the baseline and sends no setter or settling delay.

For native adapters, successful apply returns actual before/after evidence; the host additionally obtains a fresh read after a successful setter while the endpoint remains reachable. Require agreement of scope/identity and target/preservation checks. This independently checks response consistency, not honesty of arbitrary native code. If transport ownership disappears, follow the explicit KVM reachability rules; do not invent a post-read path.

### 4. Declarative profile engine: `hid-feature-fields-v1`

Choose one bounded compiled feature-report interpreter, not an arbitrary register scripting language. Profiles declare exact passive HID selectors, documented report IDs/lengths, identity fields/allowed values, codecs, capabilities, scopes, guards, settling and deterministic fixtures. An agent can add a device conforming to this report model as data; new framing/checksum/transaction protocols use the native adapter. Do not assume MSI ASCII registers or complete layout packets fit it.

Codecs: `u8`, `u16LE`, `u16BE`, `u32LE`, `u32BE`, contiguous bit field in one byte, fixed-width unsigned ASCII decimal, bijective fixed-width enum bytes, and bounded read-only ASCII text. Offsets refer to logical payload after report-ID normalization; the transport owns numbered/unnumbered normalization. Reject out-of-bounds/overflow, duplicate or overlapping writable bit ranges, writable identity fields, invalid options and references.

Guards: `equals`, `notEquals`, `oneOf`, `integerRange`, all-of only; a missing guard fails closed. Limits: 16 reports, 4,096 bytes/report, 128 fields, 64 capabilities, settling 0…5,000 ms with no borrowed MSI default. Writable layouts/routes/mappings fit a single complete report. Custom packets/checksums, multi-report writes, arithmetic, conditional command sequences, or retries require native code.

Apply algorithm under the lease:

1. Validate binding/digest/incarnation and live identity.
2. Read the complete target report and required guard reports; compare expected scope commitment and guards.
3. Copy the fresh report, changing only declared writable bits.
4. If the complete target is unchanged, return no-change without write/wait.
5. Send one SetReport, settle once, then read the complete report and guards again.
6. Require exact target report equality and unchanged preservation/guards. Return an unverified receipt on mismatch; never retry.

Volatile counters, command triggers, write-one-to-clear bits, unsafe reserved values or any bytes not safely round-trippable disqualify that report from writable profiles. Do not add ignored-byte masks. Read-only fields remain usable where safe. The compiled worker creates, uses and destroys all HID objects on one thread/run loop; supervisor bounds its execution.

### 5. Native package and wire protocol

`SupportManifest` schema/host API are both exactly 1. Required fields: ID (1–64 lowercase ASCII alphanumeric plus `.`, `_`, `-`, alphanumeric first), semantic version, bounded name, backend, exact selectors/trusted guards, capabilities/scopes, evidence, complete payload file-to-SHA-256 map. Version is informational; **digest is execution identity**. Backend is `profile(engine,relativePath)` or `nativeAdapter(relativeExecutable,architectures,minimumMacOS)`, never both. Every referenced payload exists and every payload is listed; manifest excludes itself from its file map but is included in the package digest.

Native packages contain a self-contained Mach-O with a valid signature; ad hoc is allowed and labelled honestly. Require a native slice for the running host and supported OS minimum. System libraries/frameworks only; validate Mach-O dependencies/load paths recursively and reject user/Homebrew/checkout dependencies or escaping `@rpath`. No Python/zsh runtime contract, Rosetta installation, fetched binaries/runtimes, root, driver or toolchain installation. The agent may compile/sign with an already-installed toolchain; otherwise report the exact missing prerequisite and stop. Preserve quarantine and reject quarantined adapter payloads without clearing attributes. Check signing/OS compatibility again on the invocation copy.

**Protocol:** one strict UTF-8 JSON object on stdin, one response on stdout; stderr only bounded diagnostics. Envelope: schema, request UUID, pinned provider digest, operation, operation-specific payload. Fixed operations:

- `selfTest`: hardware-free fixtures, no endpoint address.
- `plan`: hardware-free normalization from supplied observation/target.
- `read`: requested capabilities plus resolved exact binding/address.
- `apply`: authenticated complete plan, expected scope and explicit target.

The backend independently rechecks identity and current expected state immediately before its first setter. Host-supplied private address is only the selected resource, not the whole machine registry. Native adapters are trusted local user code: selfTest's no-hardware promise is contractual/source-reviewed, not OS-enforced by JSON or a filtered environment.

Strict rejection: unsupported versions, invalid UTF-8, escaped duplicate JSON keys, unknown keys/cases at every level, trailing data, invalid numbers, mismatched request/digest/device/operation, undeclared values/effects, impossible receipt flags, missing readback. Extract existing remote duplicate-key checks into `StrictJSON` without changing legacy decoder acceptance.

| Bound | Value |
| --- | --- |
| Request / stdout response / manifest / profile | 256 KiB each |
| Stderr | 64 KiB |
| selfTest / plan | 5 seconds each |
| Read | 10 seconds |
| Apply stage | Declared, maximum 30 seconds |
| Composed operation | Maximum 120 seconds, including reads/settling; cleanup slack separate |

Replace—not append to—the environment: system PATH `/usr/bin:/bin`, isolated HOME/TMPDIR in the owned invocation directory, deterministic locale, and reserved liveness/lease/deadline descriptors only. No SSH agent socket, secrets, DYLD variables, experimental-root override, inherited credentials, command strings, shell expansion, user-config loading, daemonization or persistent children. This reduces accidental disclosure; native code can still access the user's resources.

### 6. Content-addressed install, activation and reload

Use `~/Library/Application Support/MSI Screen/Support/`: `identity.key`, `registry.json`/lock, `packages/<ID>/<digest>/`, owned `staging/`, `invocations/`, `requests/`, `receipts/`. Directories 0700, data 0600, published executables 0500. A validated absolute `MSI_SCREEN_SUPPORT_HOME` override isolates app/CLI verification state; a separate absolute `MSI_SCREEN_AGENT_SKILLS_HOME` isolates skill fixtures. Both clients use the same resolution. Reject relative or unsafe overrides, never fall back from an invalid override into production state. Overrides are removed from adapter environments and never copied into prompts.

Registry schema: version, monotonically increasing UInt64 revision, installed package digests, bindings `{id,selector,packageID,digest,enabled}`. Binding owns its digest; updating one device must not update every matching device. Missing registry is empty; malformed/unknown schema is preserved and disables experimental execution only. Existing machine registry, defaults and remote schemas remain unchanged.

Package digest: SHA-256 over sorted canonical relative UTF-8 paths and exact bytes, including manifest, using length-prefixed entries. Reject path normalization/case-fold collisions, absolute/traversing paths, duplicate file entries, links (symbolic or hard), special files, foreign ownership, unsafe writable managed directories, >64 files, >16 MiB total, or depth >16. Use descriptor-relative no-follow operations and fstat throughout; do not check a path then later reopen it unchecked. Validate ancestor ownership/permissions for managed roots without following symlinks. Do not chmod/replace unfamiliar files to make them acceptable.

**Install and activate:** structural source validation → unique owned staging copy → compute/require caller's expected digest → strict schema/static protection/capability/profile/binary/evidence validation → deterministic fixtures or bounded selfTest → rehash → registry lock and affected resource leases nonblocking → compare expected revision/prior binding → passive exact endpoint revalidation → publish digest directory no-overwrite → sync data and atomically replace registry → release → notify.

The host issues no device requests in that pipeline. Profile fixture validation is hardware-free; native selfTest is trusted, unconfined code whose no-hardware contract must be source-reviewed before execution. Run it through the same bounded supervisor in validation mode, with replaced environment, no endpoint and no resource leases: there is no declared live target to lease, and acquiring one would not confine arbitrary native code. Tests can prove host/fixture behavior, not that arbitrary selfTest code cannot access devices. A contract-breaking selfTest could race device work; disclose this residual trust rather than claiming activation is a sandbox. Activation means eligible for a later explicit read; metadata controls appear with Apply disabled until the required live observation exists. A failure preserves the previous binding and clipboard. An identical already-published digest with the same binding is an idempotent no-op after validation; never overwrite mismatched existing content. Busy installation fails, not queues.

Before every invocation, securely copy and verify the pinned package in an owned per-invocation directory; execute that verified copy, not mutable authoring paths. Rehash after self-tests and every run, preserve source/signature identity, and never modify a running version. An invocation-copy change invalidates success and yields integrityChangedDuringRun with conservative possible-write evidence; leave the installed pinned version unchanged. Private copies and locks close races among cooperating installers/processes; they do **not** eliminate same-user adversarial mutation or make a macOS path-based exec immutable against that user.

For a disconnected attachment-only binding, Devices offers **Bind existing support**: choose a retained validated digest and the exact current endpoint, check static selectors/protected domains and expected revision/prior binding, then publish only new binding metadata. CLI `support bind` provides the same operation. No agent session, reinstall, device request, implicit all-model binding or automatic hardware restoration is involved. Require a fresh identity/read observation before enabling Apply. Preserve the old stale binding unless explicitly replaced; provide its disposition in the result.

Disable, explicit rollback to retained digest, rebind and removal use expected revision/digest checks and affected leases. Each supports `--dry-run`, returning the exact prospective metadata changes after the same checks but without publishing or executing a backend. Remove only unreferenced managed digests; no hardware restoration. Prefer Trash for explicit user removal; never recursively delete unfamiliar content. Published orphan digests after a crash remain inert; report them, do not add automatic recovery or garbage collection. Cleanup may remove only owned staging/invocation directories.

Notifications/directory events are hints, never trusted package content. Reload metadata on app activation, explicit inventory refresh and before each operation. Reload invalidates affected observations/drafts and never starts adapter reads. When registry changes during an operation, leases/CAS prevent rebinding its resource; the pinned digest remains the operation identity.

### 7. Resource ownership and supervised processes

Keep `ProcessRunner.run(executable:arguments:timeout:input:outputLimit:)` and existing `Output` fields/constructors and merged-stream ordering source-compatible. Add `runStructured(specification,cancellationPolicy)` via the same internal execution primitive, returning separate stream bytes and termination `exited|signaled|timedOut|cancelled|outputLimitExceeded|cleanupFailed`. Keep legacy truncation/deadline semantics; structured overflow terminates the adapter. Preserve cancellation evidence instead of losing completed stages to an unadorned thrown CancellationError.

Replace Foundation `Process` internally with `posix_spawn`: `POSIX_SPAWN_SETPGROUP` with pgroup 0 creates the child's group before exec; `POSIX_SPAWN_CLOEXEC_DEFAULT` plus explicit file actions (`adddup2`/`addinherit_np`) passes only declared stdio, liveness and borrowed lease descriptors. Local macOS SDK spawn headers confirm these APIs predate macOS 13. Foundation Process cannot supply this descriptor contract. Legacy `run` moves to the same primitive in W4 only with its current callers and unchanged API/capture tests passing; retain its merged pipe rather than concatenating streams. Add close-on-exec to lock creation by default, explicitly inheriting only a borrowed lease for the intended worker.

The primitive handles cancellation-before/during-spawn with a small lock-protected state machine, drains both streams fairly, and reaps the direct child. Timeout/cancellation/overflow **and normal leader exit with descendants** cause owned-group TERM → 500 ms grace → KILL cleanup. Do not infer ownership from a process name or kill the app's group. Bound pipe draining so noise cannot postpone deadlines. Keep private bounded stdin storage. Retain sufficient child/group ownership evidence through cleanup to avoid PID/group-reuse signaling mistakes.

Use the packaged CLI's hidden internal modes rather than a daemon/new product:

- `support-host`: trusted supervisor; validates invocation, takes leases, runs compiled identity guard, launches worker, watches parent liveness, streams/deadline/exit, cleans children, records receipt.
- `support-worker`: compiled profile executor. Native packages replace this worker with their validated executable.

Resolve the host binary without PATH: Menu uses its own `Bundle.main` resource layout `Contents/MacOS/msi-screen`; embedded or source-build CLI re-execs its own resolved executable image. A source-build Menu without its sibling packaged host reports runtime unavailable, rather than searching another installation. Internal envelopes carry host API and exact build identity; host/worker must echo both before any live device request. Pin and verify the host executable's expected build/signature before spawn; if a bundle update replaces it, mismatch fails before dispatch, not a fallback to another CLI. Source CLI may test runtime modes even when skill packaging is unavailable; copy/handoff still requires its packaged resources.

Parent app/CLI alone holds the writer for supervisor liveness; supervisor alone holds the writer for worker liveness. No child inherits a writer that can keep itself alive. Cancellation closes parent liveness first; allow cleanup slack before forcibly ending an unresponsive supervisor. Workers honor monotonic deadlines and supervisor death. Native worker compliance is source-reviewed and exercised with real lifecycle fixtures; it must not escape its group or daemonize.

`DeviceResourceLock` takes a deterministic sorted set of physical configuration-domain and affected USB-ancestry leases nonblockingly; failure releases the partial set. These are operation locks, not HID handles.

- Built-in operations keep their protocol implementations and legacy exclusion. Add shared domain exclusion only where needed to serialize the new paths.
- Experimental MSI calls hold `controller.lock` across trusted guard and worker; the guard **borrows** the open lease rather than opening/flocking again.
- Operations under an MSI hub also share its legacy compatibility lock, preventing an old CLI KVM handoff while a peripheral is being configured.
- Rapoo active reads/setters currently own `RapooQueryLock` (`RapooMouseDetails.swift:526–540`) in `MacRapooReader.withSession` (`:640–649`). Give that lock an external-lease path. New Rapoo sessions take domain/ancestry exclusion and applicable monitor compatibility before their Rapoo compatibility lease, then revalidate target before opening. New monitor/hub operations whose effects include a Rapoo receiver also take `rapoo.lock`; this coordinates with older Rapoo clients that honor only that lock.
- Bolt's `MacBoltReader` sends active detail queries, not setters, and has no current process lock. New binaries take the shared receiver-domain/ancestry lease around those queries; no legacy Bolt lock can be borrowed. Older Bolt binaries cannot be made to honor a lock they never took. Document this coexistence limitation; do not claim full exclusion from arbitrary/old vendor queries, kill processes or invent retries.
- Deterministic order for cooperating paths: registry lock when publishing metadata → sorted new domain/ancestry leases → `controller.lock` if applicable → `rapoo.lock` if applicable. Journal claim lock is acquired only after domain leases, never held while requesting registry locks. Every acquisition is nonblocking and releases the partial set on failure. Coordinator/supervisor owns each lease; low-level sessions borrow rather than independently reacquire. Update only the actual shared session owners, not packet behavior.
- Reads opening configuration interfaces participate in the same exclusion. Passive inventory does not.

No HID session survives await or crosses its creating thread; descriptor leases may. Inherit copies of the **same open lock descriptions** into workers so parent death cannot release exclusion while a cooperating worker still operates. Every inherited descriptor has an explicit owner/close path; unrelated descriptors are close-on-exec. Resource cleanup cannot release someone else's lock or terminate someone else's process.

This is a bounded cooperation contract, not a native-code sandbox. If cleanup is unconfirmed, return cleanupFailed/unverified and do not automatically launch another attempt or restore hardware.

### 8. Single execution, cancellation and uncertainty

Use a narrow `DeviceOperationJournal`, justified by the concrete safety risk of duplicated KVM/configuration writes after app/worker loss—not as generic recovery automation.

Before mutating dispatch: authenticate observation and unexpired plan/exact binding → compare persistent configuration-domain epoch → exclusively claim UUID under the resource lease → persist plan digest/initial receipt and advance that domain's epoch → durably mark possible-write **before** launching the mutating worker → atomically publish terminal receipt. Persist the last accepted operation/terminal state with the epoch. Advancing the epoch invalidates every older observation/plan on overlapping scopes, including a newly assigned UUID; a caller cannot re-plan the same old observation to replay an uncertain write. Use the whole physical configuration domain as the conservative invalidation owner, rather than maintaining a separate fine-grained recovery graph. If epoch/claim persistence fails or is interrupted, fail closed before dispatch and require a fresh read. A fresh read authenticates the current epoch under the lease; after uncertainty it is an explicit user-directed observation, never automatic retry authorization. Same UUID/same plan returns existing receipt/status, never executes again; UUID/different plan rejects. Expose receipt retrieval, not resume/retry.

Keep claims/receipts for 30 days within 64 MiB; prune expired records only. Plan expiry remains authoritative after pruning so old UUIDs cannot become executable again. If space/durability checks fail, stop before dispatch. Validate bounded receipt reads; user-corrupt state fails safely. No separate automatic recovery state machine or retry queue.

Malformed/lost output, crash, timeout or cancellation after dispatch leaves `writeMayHaveOccurred:true` unless a valid correlated pre-write rejection proves otherwise. Preserve completed stages; stop, no rollback, resend or backend fallback. Invalidate draft baseline and require an explicit fresh read. A later read describes current state; it does not rewrite historical execution into verified success.

### 9. Layout/KVM and peripheral integration

`BuiltInDeviceProvider` projects existing descriptors and delegates to `ScreenController`, `LayoutCoordinator`, `KVMCoordinator`, and `MachineFocusCoordinator`; do not duplicate their packet/transition logic. Keep `Input`, `DisplayMode`, `ScreenState`, `KVMRoute`, `KVMSnapshot`, `MachineRegistry` schema 1, machine input assignments, legacy commands, remote messages and `LayoutApplication` behavior intact.

Generic devices use local template/input/route IDs, not `Input.allCases`. Settings/mappings are scoped whole-state operations with documented coupling and preserved fields, not arbitrary single-register writes. Existing Rapoo host-action reservation remains in its current owner.

Generic KVM explicitly distinguishes **configured routing policy** from **observed USB owner**:

- If the control endpoint remains reachable, verify configured route readback and label exactly that; do not claim receiving-host enumeration.
- If switching removes the endpoint, verified completion requires an authorized destination observation. No generic remote adapter deployment/execution exists in v1; disable such a route **before any setter** when that required path is unavailable.
- Existing MSI/Linux destination verification remains in its existing path.

Expose `setLayoutAndUSB` only for one provider advertising composition with locally reachable verification. Sequence: fresh baseline/guards → layout apply/readback → explicit route apply/readback → final layout/route consistency. Any failure stops with stage receipts. No implicit generic follow-USB preference or automatic restoration. The MSI `followFullscreenUSB` preference does not leak to another device.

### 10. App ownership, UX and stale-result rules

`StatusItemController` owns one `@MainActor DeviceInventoryStore` and one `DeviceControlStore` alongside existing stores and passes them to views. Do not instantiate stores inside `MSIScreenApp` or transient SwiftUI bodies.

Inventory store owns snapshot/source errors, selection, resolver metadata, generation and handoff status. Control store owns exact selected endpoint/digest, descriptor, observation, draft, plan, receipt, busy/mutation state and needsRefresh. Every result is keyed by `(deviceID,incarnationID,providerDigest,requestGeneration)`. Late reads cannot populate a new selection/provider. Retain completed operation receipts even after selection changes without applying their state to the new controls.

Selection/disconnect cancels reads and increments generation; no replacement device is auto-selected. Provider/capability change invalidates the full draft. External state hints preserve dirty drafts but mark stale. Coalesce passive inventory events over 250 ms; refresh on panel open/tab entry, explicit refresh and support-registry change. No idle adapter/SSH polling. Leave the existing built-in closed-panel timer semantics intact.

**Devices tab:** inventory grouped as built-in candidates/verified, local experimental support, and unconfigured; distinguish permissions, partial sources, ambiguity, asleep/unresponsive and disconnected. Show relationships, declared versus observed capabilities, checked time, explicit Read/Refresh, and **Write ad-hoc support**. Default-select a single external display only when exactly one exists, otherwise chooser; controller controls remain selectable even without video association. Use a scrollable/adaptive tab selector within the existing panel so adding Devices does not clip fixed-width segments.

**Layout/Monitor:** header follows selected device/provider, not cached MSI state. Capability-driven layout editor shows templates/slots/options and explicit Apply layout. Scalar settings/mappings use typed editors with Apply. USB controls show exact destinations and verification limitations. Unsupported capability shows a concrete reason, not fake defaults. Keep existing supported MSI controls and copy-layout command.

**Peripherals:** retain owner-aware receiver/radio/pairing, native controller and observed-input cards; add generic runtime cards without duplicate control ownership. Do not turn this into a new unbounded input-probe API; existing bounded probes remain separately scoped evidence.

**Settings:** independent install/status rows for both skills; list experimental bindings/digests with Disable, explicit retained-version activation and removal of unreferenced packages. Surface conflict/missing resource/error without overwriting unfamiliar content.

**Status item:** neutral existing icon for runtime devices and truthful selected-device/last-observed tooltip. Never fabricate `ScreenState` for colors or display another device's cached layout. Track selected provider in icon/tooltip invalidation.

Stable accessibility IDs: `devices-tab`, `devices-inventory`, `devices-refresh`, `device-row-<opaqueID>`, `device-read-<opaqueID>`, `device-write-support-<opaqueID>`, `device-capability-<opaqueID>-<capID>`, `device-apply-<opaqueID>-<capID>`, `device-support-error`. Prefix controls with endpoint identity to avoid collisions across cards. Document these controls in FEATURES/verifier.

**Guard mutations below buttons.** Configure reciprocal external-mutation predicates once in the app delegate, with main-actor check/set busy before the first await. Guard `MonitorStore.apply(machines:followUSB:)`, `route(_:to:followUSB:)`, `applyPreservingUSB(_:from:expectedMachine:)`, `focus(_:)`, `restoreSetup()`, `applySetting(_:)`, `setKVM(_:expectedMachines:)`, `setSideWheel(_:expected:)`, `setTopButton(_:expectedRecordHex:bundleIdentifier:)`, and `ComputersStore.changeDisplay`. Include host-mapping changes where they conflict, not only SwiftUI disabled clauses: Rapoo RPC can invoke setters directly.

Include runtime mutations in footer install/update/Quit guards, `StatusItemController.hasActiveOperation`, termination observers, external OMP-parent idle termination, and native Quit. Add the new store's `objectWillChange` to the termination observation merge and its busy state to the external OMP-parent `idleObservation`/`quitWhenIdle` path. Here “external OMP parent” is distinct from the new per-invocation support-host supervisor. Extend existing Sparkle termination/relaunch protection at this same app-delegate gate without taking over its session. Closing the panel may hide it while operation ownership survives. Read cancellation is bounded; app termination cannot orphan a live setter.

### 11. Skill installation and privacy-filtered handoff

Move reusable filesystem work into Core `AgentSkillInstallation` for app/CLI parity; retain the Menu façade's default name and `install(from:to:)` signature for current callers. Closed catalog: `msi-screen-control`, `write-addhoc-support`. Resolve both from the packaged app Resources/AgentSkills whether called by Menu or embedded CLI. Source-build CLI without resources reports missing bundle; no cwd search, download or fallback to an arbitrary skill. Explain next-turn skill availability; do not assume a running agent reloads it immediately. Include an instruction to read the exact installed skill locally if not yet indexed.

Preserve complete-content equality/no-op, unique staging, no-overwrite move, conflict preservation; reject source/destination links including live/dangling links. Both skills get independent Settings status, so one conflict cannot mask the other.

For future upgrades, record exact complete-tree digests only for skill trees this installer actually publishes, in private `skill-installs.json` under the support root. When Copy or a Settings install is requested and the installed tree still exactly matches its recorded prior managed digest, stage the new bundled tree, validate the skill's host-API contract against CLI capabilities, then replace only that known-managed tree under a nonblocking installer lock and expected-digest check. Use atomic directory exchange for cooperating installs, Trash the old managed tree after successful publication, and record the new digest durably. If installed content, ownership, links or receipt changed, preserve everything and report conflict; never overwrite user edits or infer ownership merely from the skill name. Exact preexisting content is a no-op but does not itself establish installer ownership. A legacy/unrecorded differing skill remains an explicit move-aside conflict. This small ownership receipt enables checked automatic upgrades; it is not generic skill management.

**Copy sequence:** revalidate selected incarnation → inspect packaged/installed skill and ownership receipt → install if absent or upgrade unchanged known-managed content → fail on unfamiliar differing/missing/linked skill without changing clipboard → create private random request UUID with 24-hour expiry → build redacted prompt → replace clipboard only after success. Button detail reads **Install skill and copy request**, **Update managed skill and copy request**, or **Copy support request** as appropriate. Copy does not spawn an agent, open a URL, probe hardware or run an adapter. UI confirms “Paste into your running agent.”

The private request stores exact endpoint/binding evidence, never returned verbatim. `support request UUID` resolves it host-side on the same installation, checks expiry/incarnation/uniqueness and returns only export-safe facts/opaque handles. Expired/wrong-host/stale/ambiguous fails, never broadens targeting. Keep request files private and bounded; prune only expired owned requests. Request handles are random local locators, not exported serial hashes or authorization for arbitrary device access.

Copied prompt allowlist: `$write-addhoc-support`, request schema/random handle/expiry, category, nonunique numeric transport/vendor/product/model/usage facts, nonpersonal known provider/capability IDs, CLI contract version, fixed research/authorization instructions and generic instructions to locate the installed CLI. No serials or hashes, MAC/Bluetooth addresses, device/display UUIDs, registry/port paths, usernames/hostnames, SSH aliases, expanded local paths, pairing tables, raw input/descriptors, raw OS names or arbitrary diagnostic text. The explicit exceptions are fixed nonpersonal literals `~/.agents/skills/write-addhoc-support/SKILL.md` and documented default app CLI locations (not resolved usernames or home directories). If an override is active, state that local CLI resolution is needed without copying its value. Trusted MSI guard `identityHex`/`protocolHex` from an explicit read may be included as nonunique model/firmware facts; no serial property, unreviewed device text or arbitrary raw report is permitted. Known nonpersonal catalog labels are allowed; untrusted device strings are bounded quoted data, never instructions. Do not rely on regex guessing which names look personal. An agent may resolve private facts locally, but the skill must not paste them into external searches/logs or upload diagnostics.

**Skill run:** inspect CLI capabilities → resolve private request → research exact protocol using primary sources/vendor documents/established driver source and passive descriptors → choose fixed profile engine if it fits, otherwise native adapter with available toolchain → review source/identity boundaries/dependencies → offline fixtures plus actual process lifecycle checks → validate exact digest → guarded install/automatic activation → report capabilities/evidence/remaining limitations. No speculative probing, firmware/reset/pairing writes, sudo, security bypass or publication. Obtain named experiment authorization separately; do not automatically exercise a newly active package.

### 12. Core API and CLI

Core interfaces:

| Interface | Contract |
| --- | --- |
| `DeviceInventoryClient.snapshot()` | Async immutable snapshot with per-source errors. |
| `DeviceControlCoordinator.read(deviceID:)` | Explicit bounded live identity/capability observation. |
| `DeviceControlCoordinator.plan(observation:request:)` | Hardware-free normalization, validation and authentication. |
| `DeviceControlCoordinator.apply(plan:)` | Throws before accepted dispatch; accepted operation yields durable receipt including partial failure. |
| `SupportPackageInstaller.install(source:expectedDigest:expectedRevision:requestID:replacement:)` | Validate/publish/bind automatically with CAS and lease checks. |
| `DeviceSupportRequest.prepare(deviceID:)` | Shared skill check/install + private request + redacted prompt; no clipboard calls. |
| `AgentSkillInstallation.install(skill:source:destination:)` | Synchronous throwing filesystem work off main actor. |
| `ProcessRunner.runStructured` | Structured bounded execution; legacy run remains compatible. |

Add `Sources/msi-screen/ExperimentalCommands.swift`; dispatch before legacy global flag stripping. Hidden host/worker modes accept only internal bounded invocation contracts and never bypass validation. Public surface:

| Command (after `msi-screen`) | Result/side effects |
| --- | --- |
| `devices list` | Passive redacted local inventory, no adapter. |
| `devices inspect ID` | Passive facts, binding, declared support/reasons. |
| `devices read ID` | Explicit identity/capability read; can enrich unknown MSI identity only under the trusted guard. |
| `devices request` | Bounded stdin tagged `plan` or `apply`; plan takes observation + operation, apply takes authenticated plan. |
| `devices support-request ID` | Shared skill install/request preparation; JSON prompt, never changes clipboard. |
| `support request UUID` | Resolve private unexpired local request for agent. |
| `support list` | Packages/bindings/digests/validation status/revision. |
| `support validate PATH` | Host-offline validation plus supervised contractually hardware-free selfTest and exact digest; no install or host device requests. |
| `support install PATH --request UUID --expected-digest SHA --expected-revision N` | Validate/publish/bind automatically. Replacement adds `--replace-binding ID --expected-active-digest SHA`. |
| `support bind PACKAGE --digest SHA --device ID --expected-revision N` | Bind retained validated support to exact current attachment; replacement additionally takes `--replace-binding ID --expected-active-digest SHA`. No agent/reinstall/device I/O. |
| `support disable BINDING --expected-digest SHA --expected-revision N` | Metadata disable; no hardware changes. |
| `support activate BINDING --digest SHA --expected-active-digest SHA --expected-revision N` | Select retained checked version; no hardware changes. |
| `support remove PACKAGE --digest SHA --expected-revision N` | Remove only unreferenced managed digest. |
| `support receipt UUID` | Historical receipt only, never resume. |

`support bind/disable/activate/remove` accept `--dry-run` with the same checks and prospective metadata diff but no publication/backend execution. `support validate` is install dry-run; `devices request` plan is mutation dry-run.

IDs use complete opaque values; no ordinal/prefix guessing. All commands are local-only; reject `--machine` before any device or SSH call. `capabilities` gains additive experimental schema/engine/host API/commands/bounds metadata, retaining existing fields. Help warns that adapters run as the user and activation is not hardware qualification.

All agent-facing public command output (`devices list/inspect/read`, `support request`, plans, receipts and errors) uses one shared export-safe serializer. Private addresses/serials/UUIDs/registry locations/preservation blobs stay in host state and internal host→worker requests only. The agent uses opaque request/device IDs; it never needs the raw target address. `support request` returns sanitized protocol facts, eligibility and opaque handles—not its private request file. Text, labels, evidence excerpts and stderr need the same classification/allowlist; private text is omitted with a local-only reason. Source review classifies exportable model/firmware text; unclassified arbitrary text and raw diagnostics are local-only. Provide only fixed error codes and reviewed nonpersonal context publicly. Native code can still leak data if malicious; this serializer prevents accidental host export, not arbitrary-code exfiltration. Test the actual public JSON, not just copied prompts.

New error envelope contains schema, bounded code/message, `verified:false`, identity where safe, and receipt for accepted operations. Preserve legacy JSON formatting/error paths. Exit nonzero on errors or a mutating result not verified; hardware-free plan success exits zero with no write flags. Distinguish install/validation success from device `verified`—never mark installation as physical/device verification.

Closed errors: unavailable root, busy lock, unsupported schema/API, rejected manifest/profile, protected domain, collision, integrity change, missing toolchain/native slice/OS minimum, OS execution/device denial, protocol mismatch, stale/absent/ambiguous endpoint/request/plan, changed registry/provider, stale baseline, unavailable capability/verification path, adapter exit/signal/output overflow/timeout/cancellation, cleanup failure, journal persistence/full, and unverified result. Each is terminal for the attempt. No retry/backend fallback. Failed slices render partial inventory; no-MSI is not an overall discovery failure; malformed registry leaves built-in support working; damaged packages remain on disk, inactive, with a reason.

## File-by-file impact

**New paths are proposed, not present.** Keep files at coherent ownership boundaries; combine adjacent schema/value definitions only if dependencies remain clear. No new production target, service or third-party runtime dependency is required.

| Path | Work / dependency |
| --- | --- |
| `Sources/MSIScreenCore/DeviceInventory.swift` | Snapshot/device/endpoint/relation/identity/source values. Foundation for selection and packages. |
| `Sources/MSIScreenCore/MacDeviceInventoryReader.swift`, `USBDeviceGraph.swift` | Passive OS enumeration, bounded ancestry, owned notifications; inventory types first. |
| `Sources/MSIScreenCore/MacDisplayController.swift`, `MacUSBPeripheralReader.swift`, `GameControllers.swift` | Share passive facts; preserve specialized mutators/topology/native framework ownership. No generalization of OS arrangement semantics in this feature. |
| `Sources/MSIScreenCore/DeviceCapabilities.swift`, `StrictJSON.swift` | Tagged contract, validator, scope/plan/receipt types; shared duplicate-key checks. |
| `Sources/MSIScreenCore/KVMCoordinator.swift` | Use shared strict JSON helper; domain lease seam only as required. No handoff/routing/retry changes. |
| `Sources/MSIScreenCore/DeviceSupportResolver.swift`, `BuiltInDeviceProvider.swift` | Bindings, compiled protected catalog/trusted guard and descriptor bridge; do not duplicate MSI execution. |
| `Sources/MSIScreenCore/HIDConnection.swift` | Internal selected-endpoint/borrowed lease; public singleton and cleanup preserved. Land with guard/lease tests. |
| `Sources/MSIScreenCore/SupportManifest.swift`, `SupportRegistry.swift` | Schemas, content identities, key/revision persistence, binary/file validation, root resolution/notifications. |
| `Sources/MSIScreenCore/SupportPackageInstaller.swift` | Secure staging, validation, publish/CAS/activation, disable/retained-version/remove. Depends on contracts, registry, runner and leases. |
| `Sources/MSIScreenCore/HIDFeatureProfile.swift`, `HIDFeatureProfileExecutor.swift` | Fixed profile schema/fixtures and thread-owned compiled worker execution. |
| `Sources/MSIScreenCore/ProcessRunner.swift` | One primitive, separate streams/cancellation/groups/descendant cleanup; preserve legacy run/output. |
| `Sources/MSIScreenCore/DeviceResourceLock.swift` | Ordered nonblocking domain/ancestry/legacy leases; no inheritance except declared borrowed descriptors. |
| `Sources/MSIScreenCore/RapooMouseDetails.swift`, `MacUSBPeripheralReader.swift` | Add shared leases at `MacRapooReader.withSession`/`RapooQueryLock` and `MacBoltReader` active-query ownership. Borrow `rapoo.lock`, preserve packets, cancellation and single-thread teardown. Name old Bolt coexistence limitation; no invented legacy lock. |
| `Sources/MSIScreenCore/DeviceAdapterRunner.swift`, `AdapterProcessHost.swift` | Wire validation, supervisor/liveness/inherited descriptors, invocation copies and workers. |
| `Sources/MSIScreenCore/DeviceControlCoordinator.swift`, `DeviceOperationJournal.swift` | Explicit read/plan/apply, target verification/composition, single-execution claims, receipts/expiry. |
| `Sources/MSIScreenCore/DeviceSupportRequest.swift`, `AgentSkillInstallation.swift` | Shared expiring/redacted handoff and complete two-skill installer. |
| `Sources/MSIScreenMenu/Stores/DeviceInventoryStore.swift`, `DeviceControlStore.swift` | Main-actor ownership, generations/selection/draft/receipt/cancellation. |
| `Sources/MSIScreenMenu/Views/DevicesView.swift`, `DeviceCapabilityView.swift`, `DeviceLayoutView.swift`, `DeviceUSBHostControls.swift` | Inventory and typed controls/AX identifiers; no embedded protocol logic. |
| `Sources/MSIScreenMenu/Views/MonitorView.swift` | Store injection, Devices/adaptive selector, selected header/layout/settings, tab/refresh/copy routing and footer guards. |
| `Sources/MSIScreenMenu/Views/PeripheralsView.swift`, `USBHostControls.swift` | Experimental cards and expanded busy predicates; preserve specialized evidence/API. |
| `Sources/MSIScreenMenu/Stores/MonitorStore.swift`, `ComputersStore.swift` | Reciprocal entry-point mutation guards at named methods; do not move existing MSI state ownership. |
| `Sources/MSIScreenMenu/Stores/AgentSkillInstaller.swift`, `AppSettings.swift`, `Views/AppSettingsView.swift` | Preserve façade, two independent skill statuses, experimental package/binding management. |
| `Sources/MSIScreenMenu/App/StatusItemController.swift` | Sole new store ownership, observers, icon/tooltip invalidation, expanded active-operation/termination/supervisor wiring. |
| `Sources/MSIScreenCore/AppPermissions.swift`, `Sources/MSIScreenMenu/Views/PrivacyStatusView.swift` | Reuse permission-state/remediation presentation for the responsible launch client; add only adapters into existing status paths where observable. |
| `Sources/MSIScreenMenu/App/AppUpdater.swift` | No planned change: existing Sparkle flow remains. Runtime relaunch protection belongs in `StatusItemController`, not a second updater gate. |
| `Sources/msi-screen/ExperimentalCommands.swift`, `main.swift` | Early strict parsing, hidden runtime modes, JSON/help/capabilities. |
| `skills/write-addhoc-support/SKILL.md`, `agents/openai.yaml`, `references/contract-v1.md`, `references/validation.md` | New exact authoring contract/workflow; metadata and detailed validation evidence. Follow skill authoring guidance during implementation, not by expanding always-on instructions. |
| `skills/msi-screen-control/SKILL.md` | Add discovery/handoff/device-qualified commands; no broadened compatibility claim. |
| `script/package.sh`, `scripts/verify.py` | Explicitly package both complete skill trees and verify exact file sets; extend the one verifier with owned offline/package/GUI support fixture. |
| `Package.swift` | Test fixture resources only if needed; keep system frameworks/no new production runtime dependency. |
| `FEATURES.md`, `docs/compatibility.md` | Exact user/agent paths, prerequisites/observable evidence/traps; local experimental versus built-in/physical qualification. |

Preserve existing state/schema/protocol meaning in `MachineRegistry.swift`, `MachineStatus.swift`, `LayoutApplication.swift`, `KVM.swift`, `ScreenController.swift`, `MonitorIdentity.swift`, `MonitorSettings.swift`, and `Protocol.swift`. Any minimal lease plumbing must not change protocol or machine behavior.

## Verification specification

All checks below are **future implementation gates**, not claims that planning ran hardware or product tests.

### Focused deterministic checks

Use injected immutable OS records, fake transports for profile algorithms, disposable filesystem roots, and actual owned fixture executables for process behavior. Add only tests catching the named defects, not assertions locking unsupported policy choices or framework behavior.

| Test file | Material behavior to prove |
| --- | --- |
| `Tests/MSIScreenCoreTests/DeviceInventoryTests.swift` | No MSI/failed built-in refresh still inventories; non-console/SSH display enumeration yields public facts or an explicit source failure, never fabricated empty success; per-source failure is not empty success; composite ancestry/interface preservation; no inferred display association; identical twins/reconnect/boot and missing key; no active I/O. |
| `Tests/MSIScreenCoreTests/DeviceSupportResolverTests.swift` | Exact endpoint/provider binding; ambiguity/collisions; protected model cannot be shadowed through shared IDs; trusted guard required for disjoint MSI tuple; live identity change fails before adapter dispatch. |
| `Tests/MSIScreenCoreTests/DeviceCapabilityTests.swift` | Non-MSI inputs/templates, complete targets, coupled/preserved state, invalid slots/options/actions, guard comparison, no-op, offline plan/authentication/expiry, KVM unreachable verification yields zero writes/SSH. |
| `Tests/MSIScreenCoreTests/HIDFeatureProfileTests.swift` | Numbered/unnumbered normalization, codecs/bounds/overlap, unsafe round-trip reports, guards/missing values, preserved bits/full readback, stale/no-op, exactly one setter/wait. |
| `Tests/MSIScreenCoreTests/SupportPackageTests.swift` | Complete file/digest set, staging mutation, traversal/case/link attacks, wrong uid/modes/quarantine/signature/dependencies, corrupt registry/key, concurrent first initialization, revision races, idempotent install, failed/busy replacement/disable keeps prior binding, retained-version activation, serial-less rebind without reinstall/agent/I/O, dry-run metadata unchanged, unreferenced-only removal. |
| `Tests/MSIScreenCoreTests/DeviceAdapterTests.swift` | Strict protocol/escaped duplicate keys/mismatches/impossible flags/missing post-read; timeout/cancel/overflow/nonzero exit; inherited leases; parent/supervisor death; selected-endpoint guard; no resend/rollback; uncertain receipts and cleanup ownership. |
| `Tests/MSIScreenCoreTests/DeviceOperationJournalTests.swift` | Same UUID never spawns twice, changed-plan reuse rejects; unauthenticated observation rejects; a new UUID re-planned from a prior domain epoch cannot resend after a successful or uncertain operation; fresh explicit read carries the current authenticated epoch; crash after possible-write remains unverified, expiry/pruning/full store never enables replay, failed persistence precedes dispatch. |
| `Tests/MSIScreenCoreTests/ProcessRunnerTests.swift` | Separate stdout/stderr, replaced environment, cancellation-before/during spawn, fairness/deadline under noise, ignoring descendants after timeout/cancel/normal leader exit, no cross-group kill, explicit posix_spawn group creation and inherited-descriptor closure (unlisted sentinel and controller.lock descriptors never reach an adapter); legacy API, merged ordering, exit status and timeout behavior unchanged. |
| `Tests/MSIScreenMenuTests/DeviceSupportStoreTests.swift` | Late result/selection/provider race, disconnected selection, dirty draft versus external change, metadata-only activation, reciprocal below-button guards including RPC, native/footer Quit/update/external OMP-parent idle gates. |
| `Tests/MSIScreenMenuTests/DeviceSupportRequestTests.swift` and Core request tests | Malicious/private device names/errors/paths never enter prompt; exact private target/expiry; wrong host/stale request rejects; actual support-request/list/inspect/read/plan/receipt/error JSON never returns private addresses or identifier text; trusted nonunique MSI model bytes remain usable; clipboard changes only on total success; missing/conflicting/linked skill preserves existing clipboard. |
| `Tests/MSIScreenMenuTests/AgentSkillInstallerTests.swift` | Two independent skills, complete equality including extras, source/live/dangling links and preserved conflicts; recorded unchanged owned version upgrades, user-edited/unrecorded content never replaced; failed publication preserves managed state. |
| `Tests/MSIScreenMenuTests/DeviceTerminationTests.swift` | Actual app-delegate active-operation/termination predicate includes new store, notification merge, external OMP-parent idle path and Sparkle-triggered termination; existing AppUpdater tests remain unchanged. |

Retain and run the existing unknown-identity/two-query `ScreenTests`, no-op/layout tests, `KVMCoordinatorTests`, `LayoutCoordinatorTests`, `MachineFocusCoordinatorTests`, specialized `USBPeripheralTests` topology/radio/remote checks, `GameControllerTests` and skill tests. Enumeration extraction must preserve existing projections. Check all `ProcessRunner.run` consumers (remote KVM, USB snapshots, machine status, RemoteMacClient, UniversalControlClient, RapooAppControl and tests) for source/behavior compatibility.

Shared deterministic cases live in `Tests/MSIScreenCoreTests/Fixtures/device-support-cases.json`; an owned `AdapterFixture.swift` source builds temporary test executables, never a production adapter. Fixture packages cover both profile and native backends and malformed cases. Do not rely exclusively on fake transports to prove process lifecycle.

### Existing real-artifact verifier

Extend `scripts/verify.py`, no second harness:

1. Offline: packaged capabilities/new parser/help, early local-only/unsafe-input rejections before spawn (sentinel executable), strict validation, isolated roots, both backend fixture packages, install/list/auto-activation/digest mutation/disable/remove/receipt paths. Keep Linux companion tests unchanged.
2. Verify complete source versus bundle file sets for **both explicitly named skills**, including stale extra files, not only a few filenames or arbitrary unknown directories.
3. Use one owned GUI support fixture: disposable app copy/bundle ID/signature plus explicit support and skills roots shared by that app and CLI. Do not reuse the existing real-home skill fixture unchanged. Health-check app/CLI before driving controls.
4. Through background Cua Driver: select Devices, refresh, copy via the real button, inspect clipboard independently; record the triggering action and result. Verify no agent/adapter/hardware probe spawned by copy. Clipboard restore only if expected contents/change count still belong to this fixture.
5. Install through the **packaged CLI while the app stays open**. Observe checked metadata/control availability without relaunch or another approval. Exercise Read → draft → plan/Apply against a non-hardware fixture and compare UI receipt with an independent CLI observation. Reconnect a serial-less fixture and use Bind existing support without an agent or reinstall. Upgrade an unchanged installer-owned skill, then verify that a user-edited skill is preserved and Copy reports conflict.
6. Drop registry notification; refresh/activation/pre-operation recheck must see new digest. Exercise provider changes, late reads and mutation-sensitive native/footer Quit/update behavior.
7. Inventory/transport injection is fixture-only, explicitly enabled by owned verifier flags/receipt, visibly labelled, and cannot open live devices. An ordinary environment override cannot turn a production device into fake success.
8. Cleanup only fixture-recorded PIDs/groups/directories. Never production skill/support state. Preserve signatures/distribution/architecture/extracted-archive assertions already in the verifier.

Required commands after implementation (run long jobs under the workspace's OMP management):

```sh
swift test
./script/package.sh --configuration release --output dist
python3 scripts/verify.py --offline \
  --binary "dist/MSI Screen.app/Contents/MacOS/msi-screen" \
  --app "dist/MSI Screen.app"
./script/ci.sh
```

Add `--support-fixture` to the existing verifier's GUI mode. This mode uses only its isolated inventory/transport/skill/support roots, skips ordinary live-hardware stages, and cannot dispatch device I/O. After implementation, run:

```sh
python3 scripts/verify.py --gui --support-fixture \
  --binary "dist/MSI Screen.app/Contents/MacOS/msi-screen" \
  --app "dist/MSI Screen.app"
```

Document that invocation in help/FEATURES. Existing `--gui` requires background Cua Driver prerequisites; an unavailable driver makes that check INCONCLUSIVE, not PASS.

### Separately authorized hardware qualification

Read-only qualification first on the existing MD342CQP: passive inventory neither contends for the MSI lock nor changes status; built-in model remains a protected candidate until trusted observation; existing status/KVM paths work before/after inventory. Time-dependent fields may differ—compare device/configuration semantics, not byte-identical timestamps. Do not run `--exercise` merely for discovery.

For a **named new device/capability**, record passive facts → explicitly authorized protocol reads → minimal authorized mutation with baseline/target/readback/receipt → required physical observation. A representative new screen and peripheral are needed to claim their real controls work; fixture success proves the framework, not arbitrary hardware. Restoration only when authorized and fresh complete identity/state still matches the result the verifier owns. Disconnect, wrong endpoint, uncertain route, OS denial or unavailable physical observation is an honest limit. No automatic resends/restoration.

Keep HID ACK, software readback, actual input counters, screenshots and human-observed panel/video behavior distinct. Experimental activation never promotes a device into built-in or paid compatibility by itself.

## Execution index

Sizes are relative engineering units: S = bounded component, M = several coherent files, L = cross-process or UI integration with failure-mode verification. Dependencies refer to work IDs; every item includes its acceptance evidence.

| ID | Goal | Done when | Key files | Dependencies | Size |
| --- | --- | --- | --- | --- | --- |
| W0 | Reconcile live checkout and ownership seams | Pending input preserved; actual construction/termination/permission-attribution/peripheral lease sites confirmed; existing MSI baseline recorded | AGENTS, StatusItemController, AppUpdater, MonitorStore, peripheral readers/setters | None | S |
| W1 | Define strict values/contracts | Tagged schemas/validators/identity/scope/plan/receipt bounds and duplicate-key extraction pass focused tests; no legacy acceptance changes | DeviceInventory, DeviceCapabilities, SupportManifest, StrictJSON, KVMCoordinator | W0 | M |
| W2 | Independent passive discovery | No-MSI/partial/identical/composite/non-console inventory works; host sends zero active probes; existing projections pass | MacDeviceInventoryReader, USBDeviceGraph, MacDisplayController, MacUSBPeripheralReader, GameControllers | W1 | M |
| W3 | Secure package persistence | Key initialization, content digests, schemas, owned staging/registry CAS, inactive publication and root isolation pass attack/race fixtures | SupportRegistry, SupportManifest, SupportPackageInstaller | W1, W2 | M |
| W4 | Process and lease foundation | Real fixture cancellation/normal-exit descendant/parent loss tests pass; trusted selected-endpoint guard cannot shadow built-in or double-lock | ProcessRunner, DeviceResourceLock, HIDConnection, DeviceSupportResolver; actual peripheral lease seams | W1–W3 | L |
| W5 | Execute both backends | Profile single-report preservation and native protocol/liveness/verification work through actual supervised workers; host/compliant fixtures issue no activation device requests | HIDFeatureProfile/Executor, DeviceAdapterRunner, AdapterProcessHost, hidden CLI modes | W3, W4 | L |
| W6 | Shared planning/control/single execution | Authenticated observations/domain epochs and stale/no-op/composed plans, receipts, interrupted/duplicate/new-UUID replay claims and KVM reachability refusal proven | DeviceControlCoordinator, BuiltInDeviceProvider, DeviceOperationJournal | W2–W5 | L |
| W7 | CLI and copy-to-agent skill | Packaged CLI completes rebind/dry-run/lifecycle and export-safe handoff; both skills bundle/install/managed-upgrade/conflict correctly; no agent launch or host device requests on install | ExperimentalCommands, main, DeviceSupportRequest, AgentSkillInstallation, skill trees, package/verifier resource checks | W3–W6 | M |
| W8 | App stores and typed UX | Actual Devices/copy/Read/Apply and settings flows work; stale results and RPC/native Quit/update conflicts guarded | Device stores/views, MonitorView, PeripheralsView, MonitorStore, ComputersStore, StatusItemController, PrivacyStatusView | W6, W7 | L |
| W9 | Prove packaged artifact/document paths | Unit, release/offline/extracted bundle and owned GUI fixture checks pass; feature map records exact controls/results/limitations | scripts/verify.py, Fixtures, FEATURES, docs/compatibility | W7, W8 | M |
| W10 | Qualify particular hardware | Only authorized named capabilities have protocol/physical evidence; untested remain explicitly experimental | Existing verifier + private evidence, no source evidence dumps | W9; hardware + separate authorization | Device-dependent |

**Atomic boundaries:** selected-endpoint/borrowed-lease seam, trusted guard and tests land together (W4); both worker implementations are verified before exposing controls (W5→W8); store ownership/view signature changes, reciprocal guards and native/update termination wiring land together (W8); skill files, explicit packaging and bundle equality verifier update land together (W7). W3's executable selfTest/activation gate completes only after W4/W5; metadata staging alone is not user-visible install readiness. Build contracts first, validate one bounded change, then proceed; do not leave an unsafe half-enabled loader. Native selfTest is supervised unconfined code: hardware-free acceptance applies to the host's I/O and compliant fixture behavior only, not arbitrary adapter behavior.

## Risks, migration and design choices

- **Local arbitrary code:** signing/hash checks establish compatibility/byte identity, not safety. Source review, bounded contract/process tests and explicit experiment scope are required. No sandbox claim or privilege escalation.
- **Permissions/execution policy:** errors identify the executing binary, responsible launch client where known, and prerequisite. App permission does not establish success for an agent/terminal-launched CLI. Verify attribution in W0 and reuse `AppPermissions`/`PrivacyStatusView` remediation; do not promise a separately grantable adapter permission. Never clear quarantine or weaken signing to make it work.
- **Identity:** no durable unique identifier means attachment-only binding and reselection after reconnect. Provider descriptor trust cannot solve indistinguishable hardware.
- **Interruption:** applied stages can remain. Journal/readback exposes uncertainty; it does not supply rollback. Unknown outcomes stop automation.
- **Concurrency:** borrow the actual lease, never reacquire it independently. Topology can change outside app control; recheck at the write boundary. OS/other vendor utilities need not honor our locks, so compare fresh configuration as well.
- **Disk failure/crash:** failed checks preserve prior registry/bindings; publication-before-registry crash can leave inert owned packages. No speculative repair/reset. Corrupt new state does not disable trusted built-in controls.
- **Migration:** purely additive Support state; existing machines/defaults/remote schemas untouched. Older releases ignore it. Retained-digest rollback is explicit metadata selection, never hardware restoration. App rollback leaves extensions inert in versions without this runtime.
- **Scope limits:** v1 does not solve generic remote handoff verification, reserved receiver narrowing, new compiled profile engines, or unavailable device transports. Each limitation has a pre-write refusal, not fake success. Current work still exposes complete typed layout/KVM/peripheral controls when a local adapter can implement and verify them.

### Reconciled alternatives and preservation decisions

The planning pass returned three complete independent drafts (A/B/C). The following decisions preserve their supported requirements while resolving incompatible designs. This table is a coverage/decision index, not another implementation spec; the named sections above are authoritative.

| Source | Disposition | Item, rationale and retained coverage |
| --- | --- | --- |
| A/B/C | Accepted | Independent passive discovery; shared Core ownership; additive contracts; exact versions/strict decoding; copy-only existing-agent handoff; automatic checked activation; built-in preservation; honest capability/evidence limits. Background and Architecture §§1–12. |
| A/C | Accepted | Full device-local layout/input/route/mapping types rather than scalar-only MSI-shaped targets. Scopes, complete targets, coupled/preserved state and partial receipts in §3/9 and capability tests. |
| A | Accepted | Attachment/incarnation identity, optional durable private anchor, keyed exported IDs, actual ancestry, source outcomes and explicit bindings. Avoid invented video association (§1). |
| B/C | Rejected | Ordinals or VID/PID/location tuples as durable identity and name/count-based display correlation; they can retarget identical devices. Replace with §1's incarnation/unique-anchor checks and the same twin/replug/ambiguity tests. |
| B/C | Rejected | Private CoreDisplay naming or passive vendor/model numbers as verified control support. Public facts establish candidates only; explicit identity establishes control (§1/2). |
| A/C | Accepted | Permit finite proven non-built-in MSI identities behind compiled guard and legacy exclusion; protect known receiver domains. B's blanket ban on all MSI shared IDs is rejected because it excludes unsupported models the feature is meant to support (§2). |
| A | Accepted | Fixed feature-report profiles, exact codecs/guards/round-trip/single-report constraints and worker lifetime (§4). |
| B/C | Rejected | OS-arrangement-only profiles do not add device-protocol support; programmable MSI register/packet templates grow another control language. One bounded HID engine plus native adapters meets both extension requirements and retains stale/preservation/readback coverage. Existing OS arrangement stays owned and unchanged. |
| A | Accepted | Native Mach-O, architecture/signature/system-dependency/toolchain checks, strict bounded wire contract and selfTest (§5). |
| B/C | Rejected | Python/zsh/script interpreter contract and assumption Python ships ready. Self-contained binaries avoid runtime guessing/install prompts; missing toolchain/native slice are explicit errors, covered in package tests. |
| A/B/C | Accepted | Separate bounded stdout/stderr, replacement environment, cancellation, process group cleanup, compatibility for old ProcessRunner callers (§7). C's thrown cancellation-only path replaced by receipts preserving completed effects. |
| A | Accepted | Supervisor/worker liveness and inherited leases, descendants on normal exit, resource/topology exclusion and bounded cleanup (§7). B's no-MSI-lock and VID/PID-only locks are rejected: hub effects and shared MSI transports can overlap. |
| A/B/C | Accepted | Owned staging, complete file/digest checks, modes/links/ownership/quarantine, atomic registry publication, invocation copy and integrity failures. Contradictory storage/command names normalized to Support + devices/support (§6/12). |
| A/C | Rejected | “Immutable private copy eliminates all exec races” is too strong for same-user native code. Keep private copy/descriptor checks and explicitly document residual trust (§6/7). |
| A | Accepted | Per-binding digest, registry CAS, explicit replacement/disable/retained digest/remove, no-op install and metadata reload despite missed notifications (§6). Replaces B/C in-place/global auto replacement with equivalent lifecycle checks plus stale-binding protection. |
| A/B | Accepted | Activation performs no live device I/O. C's live smoke/inspect during activation is rejected; explicit Read/authorized qualification supplies that evidence without changing automatic activation semantics (§6/11). |
| A/B/C | Accepted | Fresh baseline, single attempt, settling, post-readback, no retry/fallback/rollback; uncertainty distinct from verified (§3/8/9). B's inherently unverifiable writable actions are not exposed in v1; unavailable verification disables the setter, while uncertainty after a supported dispatch remains visible. |
| A | Accepted | Authenticated expiring plans and narrow durable UUID claims prevent duplicated interrupted configuration/handoff execution; bounded retention/space/durability failure precedes dispatch (§3/8). |
| B | Rejected | Generalizing OS main-display/arrangement controls is unrelated to adding missing device protocols and would broaden existing semantics. Preserve existing OS owner/guards; full panel layouts/KVM are covered by typed provider operations (§9). |
| A/B/C | Accepted | Local-only extension execution; unchanged Linux schemas; reject remote flags. KVM route readback versus destination observation is explicit; unavailable destination path blocks before setter (§9/12). |
| A | Accepted | Separate inventory/control stores owned by existing app delegate; selection/generation/draft invalidation; status-item and below-button RPC/Quit/update guards (§10). B/C MonitorStore-heavy/SwiftUI-owned store variants replaced without losing device UI/late-result checks. |
| A/B/C | Accepted | Dynamic device header/settings/peripheral cards, explicit Apply, skill statuses and binding removal; no idle adapter polling (§10). |
| B/C | Rejected | Hiding everything only in Peripherals or only when built-in refresh fails weakens screen discoverability and simultaneous use. Dedicated Devices plus typed Layout/Monitor/Peripherals routing; adaptive selector addresses B's fixed-width panel concern (§10). |
| C | Rejected | New general input-probe extension API is not needed for requested configuration support. Preserve existing bounded input/native-controller evidence separately; no input-capture scope expansion (§10/11). |
| A/B/C | Accepted | Shared two-skill installation, no-overwrite conflicts, packaged resources, per-skill status and safe clipboard sequencing (§11). |
| B/C | Rejected | Copying despite conflicting/missing skill and regex-redacted arbitrary names/paths cannot guarantee a usable, private handoff. Exact skill + opaque local request + allowlist gives the same target/context without those leaks; conflict leaves clipboard unchanged (§11). |
| A/B/C | Accepted | Packaged CLI, both-backend fixtures, exact skill equality, Cua GUI install/copy/activation, focused protocol/filesystem/process/stale-state tests and feature map (§Verification). Explicit disposable roots replace production-home fixture mutation. |
| B | Rejected | Byte-identical timestamped status around inventory is not meaningful. Compare configuration semantics, lock noninterference and no-device-I/O evidence instead; retain real MD342CQP read-only check (§Verification). |
| A/B/C | Accepted | Additive persistence, old-version inert behavior, no compatibility promotion, OS-denial/native-code trust risks, ordered atomic handoffs and required artifact checks. Risks/Execution index retain these explicitly. |

### Bounded critique disposition and fidelity check

One design critique is recorded at `docs/reviews/experimental-device-support-plan-critique-2026-10-21.md`. Its verified findings were integrated, not pasted as instructions:

- **F1/F2:** agent-facing export-safe serialization/private host resolution and authenticated observations plus domain epochs close accidental identifier export and stale-observation/new-UUID replay (§3/8/11/12; request/journal tests).
- **F3/F4:** name posix_spawn/descriptor inheritance and both legacy locks; borrow Rapoo's lock at its session owner and add new Bolt active-query exclusion, with the old-Bolt limitation stated (§2/7; lifecycle/lease tests).
- **F5:** host-offline activation is not a sandbox for native selfTest; supervised/source-reviewed code remains trusted and fixture evidence is qualified (§5/6; W5).
- **F6/F7:** user-triggered metadata-only rebind and upgrades only of unchanged installer-owned skill trees preserve automatic usability without overwriting unfamiliar work (§6/11; package/installer/GUI tests). These are local reversible lifecycle operations within the selected scope, not new approval gates.
- **F8–F11:** verify responsible-client privacy attribution, reuse existing remediation, resolve/check the packaged host instead of PATH, allow only fixed nonpersonal skill-location literals, and put runtime termination protection in the actual app delegate rather than changing Sparkle (§7/10–12).
- **F12:** post-run rehash, non-console discovery result, reviewed MSI model bytes, and practical metadata dry-runs are explicit rather than implied.
- **Narrow MSI settings-engine suggestion:** retain one profile engine plus native adapters in v1. A second compiled scalar MSI engine is a valid future simplification for a demonstrated model, but neither the user nor current compatibility evidence requires it now. The rejected element is C's programmable register/layout packet engine, not the possibility of safely bounded scalar profiles. Native adapters satisfy the user's chosen both-backend contract without expanding the first interpreter's proof surface.

Fidelity check covers all generated-plan sections from all three completed drafts: current state, platform constraints, identity/discovery, protection, typed contracts, profiles, native runtime, packages/activation, locks/cancellation, receipts, composition, stores/UX, skills/privacy, APIs/CLI/errors, file impacts, verification, migration/risks and ordered work. Conflicting alternatives and corrected assertions have their disposition above; no supported behavior was replaced by a generic “update callers” or “add tests.” The temporary planning export can be retired after this check; the plan is the execution source, and the critique remains an audit artifact, not another implementation plan.

## Open questions and execution prerequisites

No unresolved product decision blocks the local v1 implementation. W0 must confirm the **current** named low-level session/lock owners and responsible-client permission attribution before editing; §7 already fixes the legacy lock identities/order and borrowed-lease placement. This is reconnaissance, not permission to relax exclusion or rewrite protocols. Implementation must validate inherited-lock/process-group behavior on both supported macOS architectures with real fixture processes before exposing writes.

Hardware-specific questions remain intentionally open: which exact new device/protocol to qualify first, whether it supplies safe readable configuration, and whether its USB control path survives a route change. These determine that adapter's evidence and available controls, not the framework contract. Toolchain, signing/execution policy and Cua availability are prerequisites to check, not assumed support.

## References

- `AGENTS.md`, `FEATURES.md`, `docs/compatibility.md`, `skills/msi-screen-control/SKILL.md`.
- [Apple library validation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.disable-library-validation), [Apple DTS library-loading problems](https://developer.apple.com/forums/thread/706437).
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services).
- [Apple USB entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.usb), [archived HID guide](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/HID/new_api_10_5/tn2187.html).
