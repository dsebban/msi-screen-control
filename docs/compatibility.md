# Monitor compatibility

Status as of 2026-10-20. A common USB controller ID is not a common control profile. All control mutations still require the exact enabled identity and firmware response.

| Model | Evidence | MSI Screen status |
| --- | --- | --- |
| Modern MD342CQP / V20 | Physical panel used throughout development; two identity queries return `3030a0` and `563230` | Enabled and hardware-verified, within the feature limits in README |
| Modern MD342CQPW | MSI's shared MD342CQP/MD342CQPW manual and product family | Closest next candidate for reusing the existing profile; exact identity and controls have not been verified |
| Optix MAG274QRF-QD | Upstream reports firmware V43/V48/V56, identity `00e` | Different profile; not enabled here |
| Optix MAG272CQR | Upstream reports V18/V41, identity `00E` | Different profile; not enabled here |

There is no verified sales ranking behind this order. MD342CQPW is prioritized for the strongest family relationship and potential code reuse, rather than a claim that it is best-selling.

## Read-only identification

Build the current source and run `.build/debug/msi-screen identity` with one MSI USB controller attached. The JSON preserves raw model and firmware bytes, printable firmware text when available, and the matched control profile. It reads only `00140` and `00150`; it does not read or write layout, picture, KVM, factory, or firmware registers. Unknown identities remain available in the report without enabling controls. No serial number, host name or user paths are included.

This diagnostic is newer than v0.2.0. The current release remains limited to MD342CQP/V20. A family name alone is insufficient to enable another monitor: confirm its identity and the vendor profile, then verify each advertised feature and physical result before changing the paid compatibility list. Keep per-model register differences in MSIScreenCore, shared by app and CLI.

## Local experimental framework (2026-10-21)

Devices can enumerate OS-visible endpoints independently of MSI availability, prepare a privacy-filtered agent request, and retain checked local profile/native packages. Metadata activation is not model/protocol, hardware, physical-panel or paid compatibility qualification. Shared `1462:3fa4` facts are only candidates; the app never associates them with cached MD342CQP controls. The explicit legacy MSI path retains its existing trusted controller/identity owner.

Production experimental Read/plan/Apply remain refused before trusted-guard/backend construction until native Intel/macOS 13 lifecycle and measured responsible-launch-client/privacy attribution are verified. Rosetta, signatures/notarization, ancestry and caller TCC checks do not close those gates. There is no production override. The verifier's explicitly admitted, labelled, receipt-owned non-hardware fixture uses fixed endpoints and isolated file transports, not live devices; its passes establish software behavior only. External installed-companion background-only GUI action/result evidence remains separate and INCONCLUSIVE until supplied.

Bolt/Rapoo receiver configuration domains remain reserved to compiled owners, including paired devices reached through them. New cooperating binaries share leases; older Bolt clients never took the new lease and cannot be claimed fully excluded. Native adapters are trusted unconfined user code, not sandboxed. No new hardware qualification, compatibility promotion, pairing/firmware/reset, generic remote adapter execution or automatic uncertain-write retry is implied.

## Sources

- [MSI MD342CQP/MD342CQPW manual](https://download-2.msi.com/archive/mnu_exe/monitor/MD342CQP_MD342CQPWv1.1_English.pdf)
- [MSI Modern MD342CQP family announcement](https://www.msi.com/news/detail/MSI-Modern-MD342CQP-Series---A-Perfect-Blend-of-Performance--Comfort--and-Versatility-for-Professionals-144529)
- [msigd model/firmware table](https://github.com/couriersud/msigd#21-msi-monitors), which documents differing identities under USB `1462:3fa4`
- [MD342CQP contributor's hardware report, PR 71](https://github.com/couriersud/msigd/pull/71) (open when checked; not represented as an upstream merged release)
