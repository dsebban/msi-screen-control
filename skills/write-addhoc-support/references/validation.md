# Validation and evidence

## Before executing native selfTest

Inspect all source and resources. selfTest is contractually hardware-free but runs unconfined as the user; signing, private HOME, filtered environment and supervision do not prevent malicious native code from opening devices or reading files. No endpoint is supplied and the host itself issues no device requests during validation/activation. Do not validate an unreviewed fetched binary.

Use an owned disposable authoring directory and isolated support/skill roots for fixtures. Resolve absolute roots locally; do not disclose their values externally. Invalid/linked/unsafe overrides fail closed, not into production state. Do not alter real installed support/skills or remove unfamiliar content during tests.

## Meaningful checks

For a profile, include exact deterministic reports covering identity/guard rejection, legal codec boundaries, complete layout/options/mapping targets, no-change, preserved bits and one-setter/readback. Unsafe volatile/trigger/W1C bytes disqualify writable full-report profiles. Do not add an ignored-byte mask or borrow MSI settling/retries.

For native code, use fake transports in **that adapter's own explicit offline fixtures**, not an ordinary environment flag that turns a real device into simulated success. Exercise the actual built native executable and reserved handshake/liveness/lease descriptors: read and plan, complete before/after evidence, no-change, mismatched request/digest/build/identity, stale configuration, guards/preservation, malformed/oversized output, nonzero/signal, timeout/cancel, parent/supervisor loss and descendant cleanup on normal exit. Verify another unrelated process/group survives and all owned groups terminate. Source review must establish no daemonization, process-group escape or inherited writer keeping itself alive. The production host must never auto-enable real-device writes because software fixtures passed.

Document exact commands, artifact hashes/signing/native architecture/OS, terminal job IDs/logs when managed jobs are available, observed side effects and what was not observed. Test independent post-read disagreement, route reachability refusal **before setter**, and loss after dispatch without resend/restore. Validate public output using adversarial private names/paths/text/errors, not just the copied prompt. Keep raw diagnostics private.

## Local package flow

1. Read the installed CLI's capabilities/help and resolve `support request UUID`. Stop for a stale/expired/ambiguous/wrong-host request.
2. Run `support validate ABSOLUTE_PACKAGE_PATH`. Require zero exit and the exact digest. This runs bounded fixtures/selfTest without publication or host device requests. A native execution-policy/quarantine/signature/slice/OS failure is terminal: report the prerequisite, never bypass policy.
3. Read `support list`. Use its current registry revision and, for replacement, exact binding and expected active digest. Install the validated digest with `support install ... --request ... --expected-digest ... --expected-revision ...`. No extra extension-approval click is required. Rehash changes require another validation, not reusing an old digest.
4. Read `support list` and `devices inspect ENDPOINT_ID` independently. Check exact selected binding/digest and declared availability. Installation/activation returns `deviceVerified:false`, not physical success; production experimental Read/plan/apply remain refused until recorded runtime qualification gates close. Hardware-free validation/selfTest, metadata lifecycle and receipt lookup remain available; no production override exists.

For lifecycle testing, retain two validated versions under isolated roots. Check bind/disable/retained activate/remove `--dry-run` results and unchanged registry/package bytes. Verify revision/digest races, busy resources and changed content preserve the prior binding. Reconnect an attachment-only fixture: old selection must become stale; explicitly select the new full endpoint ID and bind retained support without regeneration/reinstall/agent/device requests. Preserve the old stale binding unless explicitly replacing it. Removal refuses any reference including disabled bindings and moves only checked unreferenced managed content to Trash. Do not create automatic cleanup/recovery/rollback.

For skill handling, verify both complete named trees, including extra/empty directories. Install into disposable roots, repeat as no-op, upgrade only an unchanged receipt-owned tree, then edit a file/add an extra or link and require conflict with bytes preserved. Equal preexisting content does not establish ownership. Failed staging/publication/receipt checks preserve unfamiliar content; clipboard replacement is a client action only after total prepare success. Source-build CLI without bundled resources must fail handoff, not search cwd/download.

## Stop and report boundaries

Busy/CAS/integrity/OS denial/protocol mismatch/stale request or baseline/uncertain write/cleanup failure is terminal for that attempt. `support receipt UUID` retrieves history; it does not resume. A fresh explicit read describes now and does not rewrite past uncertainty as success. An authenticated observation cannot be edited, replayed with a new UUID after its domain epoch advances, or used past a five-minute plan expiry.

No live tests are implied by offline acceptance. Named active reads/probes/mutations require explicit user authorization and an exact selected device, allowed scope, baseline/target/readback and, where needed, physical observation. Activation never grants that authorization. No firmware/reset/pairing, privacy grants, quarantine removal, installations, uploads or publication. If responsible-client attribution, native Intel/macOS 13 lifecycle or physical evidence is unverified, label it unverified; process ancestry, translated x86 fixtures, software receipts and screenshots cannot substitute for it.
