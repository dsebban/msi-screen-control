# MSI Screen experimental contract — schema/host API 1

Use the executing CLI's `capabilities.experimental` as the availability contract. Unsupported API/engine or `runtimeQualificationPending` is a stop, not a request to weaken checks. Everything below is local-only. Native adapters are trusted native code, not sandboxed.

## JSON and package identity

All boundaries reject unknown/missing required keys, unknown tags, duplicate keys (including escaped duplicates), trailing data, non-UTF-8, fractional/exponent numbers, nonintegral/overflow values and inconsistent references. Integers only; timestamps are integer Unix milliseconds except the monotonic worker deadline. IDs are 1–64 ASCII letters/digits/`.`/`_`/`-`; package IDs additionally start alphanumeric and use lowercase only. Titles are at most 128 UTF-8 bytes without controls. Digests are 64 lowercase hex characters. Optional fields may be absent or null. Do not invent defaults for unavailable observations.

A package is a directory containing `manifest.json` and exactly its mapped payload files. No links (including hard links), special files, path/case/Unicode-normalization collisions, absolute/traversing paths or group/world-writable content. Maximum 64 files including manifest, 16 MiB total, depth 16. The manifest is excluded from `files` but included in the package digest.

Manifest keys, all required:

```json
{"schema":1,"hostAPI":1,"id":"vendor.model","version":"1.0.0","name":"Nonpersonal model label","backend":{"kind":"profile","engine":"hid-feature-fields-v1","relativePath":"profile.json"},"selectors":[{"transport":"usb","vendorID":1,"productID":2,"interfaceNumber":0,"usages":[{"page":1,"usage":5}]}],"trustedGuards":[],"descriptor":{"capabilities":[],"scopes":[],"evidence":[],"supportsLayoutAndUSB":false},"files":{"profile.json":"PAYLOAD_SHA256"}}
```

This is a structural illustration, not a usable device protocol or valid digest. Version is semantic version and informational; digest is execution identity. Native backend instead is `{"kind":"nativeAdapter","relativeExecutable":"adapter","architectures":["arm64"],"minimumMacOS":"13.0"}`. Require a self-contained signed Mach-O (ad hoc is allowed and labelled), native running-host slice, compatible OS and only recursively validated system libraries/frameworks. No Homebrew/checkout dependencies, escaping rpaths, script runtimes, plugins/dylib loading, fetched toolchains or quarantine removal. Include non-executable resources and reviewed evidence in the complete file map.

Package digest: sort relative UTF-8 paths bytewise; for each path append its 8-byte unsigned big-endian byte length, UTF-8 path, then its 8-byte big-endian file length and exact bytes. SHA-256 that stream, including manifest. `support validate ABSOLUTE_PATH` returns the authoritative digest after checks and selfTest. Do not compute a digest from a pretty-printed reserialization of files.

Selectors are static eligibility, not automatic bindings. `transport` is `usb|bluetooth|display|other`; vendor/product are unsigned numeric facts; usages are unique `{page,usage}` UInt16 pairs. Interfaces remain separately targetable. No ordinal/name/VID-PID-only identity. MSI `1462:3fa4` selectors require `trustedGuards:[{"id":"msi-identity-v1","allowedIdentities":[{"identityHex":"...","protocolHex":"..."}]}]` with finite exact disjoint tuples; protected `3030a0`/`563230` cannot be listed. No wildcard/exclusion-only bypass. Bolt `046d:c548`, Rapoo `24ae:186a` and devices reached through these reserved receivers cannot be experimentally configured in v1.

## Typed descriptor

Descriptor keys: `capabilities`, `scopes`, `evidence`, `supportsLayoutAndUSB`. Up to 64 capabilities. Scope:

```json
{"id":"configuration","observedFields":["level","model","preserved"],"requiredGuardFields":["model"],"writableFields":["level"],"coupledFields":[],"preservedFields":["preserved"],"preservationCommitment":null}
```

Every referenced field is observed; writable/coupled/preserved/guard sets are consistent and disjoint as appropriate. Native commitments exclude arbitrary telemetry; configuration, guards and preservation remain strict. Private preservation bytes/addresses never pass through public JSON.

Capability keys: `id`, `title`, `category` (`setting|layout|usb|input|information`), `presentationOrder` (0…65535), `access` (`readOnly|readWrite`), `definition`, `mutationScopeID`, `evidenceIDs`, `executionBudgetMilliseconds` (1…30000), `settlingMilliseconds` (0…5000, within budget), `verification`, optional `unavailableReason:{"code":"..."}`. Verification: `{"kind":"readback","guardFieldIDs":["model"],"ownershipRequired":false}`; kind may also be `configuredRoute|destinationObservation`.

Definitions use `{"kind":K,"definition":D}` except Boolean, which is exactly `{"kind":"boolean"}`:

| K | D |
|---|---|
| integer | `{minimum,maximum,step,unit?}` inclusive Int64 bounds, positive step, no overflow/out-of-step values |
| choice | Array of unique ordered `{id,title}`, 1…32 members |
| text | `{maximumUTF8Bytes,exportPolicy,reviewEvidenceIDs}`; maximum 1…128; always read-only |
| layout | `{inputs,templates,options}`; inputs `{id,title}`; template `{id,title,slots,distinctInputs}`; slot `{id,rectangle:{x,y,width,height,z},allowedInputIDs}`; option `{id,choices:[{id,title}]}` |
| usbRoute | `{destinations:[{id,title}],affectedDomainID,reachability}`; reachability `remainsReachable|destinationRequired|unavailable` |
| inputMapping | `{controls:[{id,title}],actions:[{id,title}]}`; finite onboard actions only, no scripts/host commands |

Layout rectangles are normalized integers 0…10000, up to 8 slots; geometry is panel composition, not OS arrangement. Every input/template/slot/option/action reference and distinct-input assignment must be feasible. `text.exportPolicy` is `localOnly` or `sourceReviewedNonpersonal`; the latter requires referenced source/vendor review evidence. Serial/device-name/identifier text is always local-only. Evidence entries are `{id,kind,title,exportPolicy}`; kind `declared|deviceMetadata|sourceReview|vendorReview|offlineFixture|protocolReadback|physicalObservation`. Declarations/fixture readback do not promote themselves to physical observation. Unclassified labels, text and diagnostics are not agent-exportable; public labels may be omitted/replaced.

Values are `{"kind":K,"value":V}`. Integer, Boolean, choice-ID and text values have their JSON scalar type. Layout value is `{templateID,slots:{slotID:inputID},options:{optionID:choiceID}}` with **every** selected-template slot and declared option. USB route value is `{configuredDestinationID,observedOwnerID?}`; policy and observed owner are distinct. Mapping value is the complete `{controlID:actionID}` dictionary. Unknown values use explicit unavailable reasons, never zero/false/first-choice placeholders.

Operation is `{kind,capabilityID,target,usbCapabilityID?,usbTarget?}`. Kind: `setCapability` (integer/Boolean/choice), `setLayout`, `setUSBRoute`, `setInputMapping`, `setLayoutAndUSB`. Only composition has the USB fields, requires one provider explicitly advertising composition, and uses a layout target plus a complete USB value. Coupling normalization may alter only documented declared effects. No generic follow-USB preference.

## Fixed profile engine

Profile keys: `schema:1`, `engine:"hid-feature-fields-v1"`, `reports`, `fields`, `identities`, `guards`, `capabilities`, `fixtures`.

- Report: `{id,length,safeToRoundTrip}`. Up to 16 reports, IDs UInt8, payload length 1…4096 **excluding** normalized report-ID prefix.
- Field: `{id,reportID,offset,width,codec,bitOffset,bitCount,enumBytes,writable}`. Up to 128 fields; offsets are logical payload offsets. Codes `u8|u16LE|u16BE|u32LE|u32BE|bits|asciiDecimal|enumBytes|asciiText`. `bits` is contiguous within one byte. Enum byte maps `{choiceID:lowercaseHex}` are fixed-width bijections. Text is read-only bounded ASCII. Use zero bit offsets/counts and empty enum maps where inapplicable; include all keys.
- Identities: `{fieldID:[allowed DeviceValue,...]}`, immutable fields with finite exact nonempty allowlists.
- Guard: `{fieldID,kind,values}`; kind `equals|notEquals|oneOf|integerRange`; all-of, missing fails. Range has two integer values, equals/notEquals one value.
- Capability mapping: `{capabilityID,components:{component:fieldID}}`. Scalar `value`; layout `template`, `slot.ID`, `option.ID`; route `destination`; mapping `control.ID`. These are fixed paths, not expressions.
- Fixture: `{reports:{decimalReportID:hex},expectedValues:{capabilityID:DeviceValue},operation?,expectedReports:{decimalReportID:hex}}`. Provide deterministic read, mutation, no-change and preservation cases. Vectors cover all declared values/guards and exact report bytes.

No overlapping writable bits, writable identity, unsafe round-trip report, ignored-byte mask, command trigger, W1C/reserved/volatile byte, multi-report setter, conditional sequence, arithmetic, custom checksum or retry. Layout/route/mapping writes fit **one complete report**. If any byte cannot safely be read and written back unchanged, that report is not writable under this engine. The compiled worker rechecks exact endpoint/identity/guards, reads whole reports, compares commitment, copies fresh bytes, changes only declared bits, skips a no-op without delay, sends one setter, settles once and requires complete exact report/guard readback. Use native code when this does not fit; do not expand the interpreter.

## Native wire and process contract

No arguments or installer hooks from manifest. One strict stdin object / one stdout response, each at most 256 KiB; stderr diagnostic-only at most 64 KiB and never publicly exported. Envelope request keys:

```text
schema=1, hostAPI=1, buildIdentity, requestID (UUID), providerDigest,
operation=selfTest|plan|read|apply, payload, deadlineUptimeMilliseconds
```

Require the installed build identity exactly; echo the supplied checked identity, never substitute a hardcoded version from this document. Payload variants:

```text
{kind:"selfTest"}
{kind:"plan", observation, operation:DeviceOperation}
{kind:"read", identity:DeviceContractIdentity, endpoint:PrivateEndpoint, capabilityIDs:[ID]}
{kind:"apply", plan:DevicePlan, endpoint:PrivateEndpoint, expected:BackendState}
```

PrivateEndpoint wraps `{endpoint:publicEndpoint,kind:"hid",registryID,usbDeviceID?,interfaceID?}` or `{endpoint:publicEndpoint,kind:"usb",registryID,parentID?}`. Public endpoint is `{kind,id,identity:passiveFacts,physicalDomainID,incarnationID}`. Only host→worker receives addresses; never emit them publicly. Contract identity is `{deviceID,incarnationID,bindingID,providerDigest,domainID}`; all device/domain/incarnation values are keyed opaque tokens, not serial hashes.

Before device access, perform the reserved fd 201 handshake: send one newline-terminated JSON `{hostAPI:1,buildIdentity,requestID,providerDigest,executableDigest}` (SHA-256 of the executing invocation copy); wait for one acknowledgment byte equal to 1. A failed/mismatched handshake stops **before** device access. Supervisor liveness is read-only fd 200: EOF/error or monotonic deadline requires bounded exit without further setters. Borrowed leases start at fd 210; keep them through teardown, do not independently open/unlock the same lock. Do not close or leak reserved descriptors into descendants. Do not daemonize, escape the owned process group or leave persistent children.

Environment is replaced: system PATH `/usr/bin:/bin`, private invocation HOME/TMPDIR and deterministic locale, no credentials, SSH/DYLD/config/root overrides. This limits accidental disclosure; it does not confine native code. All HID objects are created/used/destroyed on their owning thread/run loop; only leases cross awaits.

Response envelope keys: `schema,hostAPI,buildIdentity,requestID,providerDigest,operation,result`, echoing all correlation fields. Results:

```text
{kind:"selfTest"}
{kind:"plan",operation:normalized DeviceOperation}
{kind:"read",state:BackendState}
{kind:"apply",result:{before:BackendState,after:BackendState,attempted,completed,acknowledged}}
{kind:"rejected",failure:{code}}    // valid correlated pre-write rejection only
{kind:"failed",failure:{code,dispatched,cleanupConfirmed}}
```

BackendState is `{identity,values:{capID:DeviceValue},fields:{fieldID:DeviceValue},preservation:{ID:opaqueString},unavailable:{capID:{code}}}`. Every declared capability is present exactly once as value or unavailable. Writable scope observed fields must be complete. Supply actual before/after evidence, not a claimed verified Boolean. Recheck exact live identity and expected configuration immediately before the single setter. Preserve unrelated configuration/guards, skip true no-ops. The host separately reads again after success and verifies targets/guards/preservation/ownership while still reachable. It rejects undeclared effects, impossible flags, inconsistent readback and changed invocation bytes.

selfTest and plan are hardware-free, max 5 s; read max 10 s; apply stage max declared 30 s; composition max 120 s including read/settle. Cleanup slack is separate. Timeouts/cancellation/nonzero/malformed/lost output after dispatch conservatively mean possible write. No resend/automatic restore/backend fallback. TERM→500 ms→KILL and owned-descendant cleanup also apply to normal leader exit; implement liveness/deadline compliance anyway.

## Public lifecycle/control

`devices list|inspect ID` are passive. `devices support-request ID` returns a prepared prompt and private random locator, not the private file. `support request UUID` resolves only on this installation, within 24 h, same incarnation/uniqueness/binding. It returns category, safe numeric facts, opaque endpoint/binding/digest and registry revision. It never authorizes probes.

`support validate PATH` is install dry-run, including trusted unconfined native selfTest, but no host device request or publication. `support install PATH --request UUID --expected-digest SHA --expected-revision N` validates/publishes/binds; replacement adds `--replace-binding ID --expected-active-digest SHA`. Exact digest/binding is idempotent after validation and CAS; no global model activation. Support state root is private; invalid overrides never fall back to production.

`support bind PACKAGE --digest SHA --device ID --expected-revision N` binds retained checked support to an exact current attachment, optionally replacing the explicitly named prior binding/digest. Otherwise the old stale binding is preserved and listed in the result. No reinstall/agent/device I/O. `support disable BINDING --expected-digest SHA --expected-revision N`; `support activate BINDING --digest SHA --expected-active-digest SHA --expected-revision N`; `support remove PACKAGE --digest SHA --expected-revision N`. These four accept `--dry-run` with exact checks/prospective before/after metadata and no backend execution/publication. Removal refuses even disabled references, trashes only a checked unreferenced managed digest, never restores hardware or garbage-collects unknown content.

Production experimental Read/plan/apply are refused while `executionReady:false`; `runtimeQualificationPending` has no production override. Metadata lifecycle, receipt lookup and hardware-free validation/selfTest remain available. After recorded qualification gates close, explicit `devices read ID` yields a host-authenticated observation. `devices request` stdin is `{schema:1,kind:"plan",observation,operation}` or `{schema:1,kind:"apply",plan}`. Observation fields include schema, identity, checkedAtMilliseconds, values, unavailable, guardState, scopeCommitments, domainEpoch, authentication. Plan includes schema, operationID, issuedAtMilliseconds, expiresAtMilliseconds (5 min), identity, registryRevision, domainEpoch, expectedCommitments, operation, stages, changes, authentication. Preserve the exact complete canonical form; only the host signs it. Planning does no new live I/O; apply requires fresh scope/guard agreement. Whole-domain epochs and durable UUID claims prevent replay even with a new UUID. `support receipt UUID` is historical lookup, never resume/retry.

Receipt fields: schema, operationID, identity, before/target/after values, ordered stages `{id,attempted,completed,acknowledged,verified,failure?}`, failure, outcome `notAttempted|noChange|verified|unverified|cancelled`, writeMayHaveOccurred, verified. Inspect partial stages and independent evidence. Nonzero for errors or an unverified mutating/historical receipt; plan and successful metadata checks exit zero, without device-verification claims. Error envelope is `{schema:1,code,message,verified:false}` with fixed reviewed context, no raw diagnostics; an accepted but unverified apply additionally includes its safe `identity` and complete `receipt`. Historical `support receipt` returns the receipt itself, with nonzero status when unverified. All public device/request/plan/receipt/error output shares export classification. Activation and fixture readback are never physical-panel/video/USB-destination proof.
