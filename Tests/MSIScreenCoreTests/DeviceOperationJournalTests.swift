import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class OwnedDeviceControlFixture {
    let root: URL
    let registry: SupportRegistry
    let profile: HIDFeatureProfile
    let descriptor: DeviceDescriptor
    let identity: DeviceContractIdentity
    let content: SupportPackageContent
    let transport: HIDFixtureTransport
    let executor: HIDFeatureProfileExecutor
    let native: Bool
    let stateURL: URL
    let marker: URL
    var reads = 0
    var applies = 0
    var resolves = 0
    var revision: UInt64 = 0
    var disconnected = false
    var failReadAfterApply = false
    var clock: Int64 = 1000000
    init(native: Bool, mode: String = "normal", reachability: DeviceControlReachability = .remainsReachable) async throws {
        root = URL(fileURLWithPath: "/private/tmp/msi-u3-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        registry = try SupportRegistry(home: root.appendingPathComponent("support")); _ = try registry.installationKey()
        stateURL = root.appendingPathComponent("state.json"); marker = root.appendingPathComponent("worker")
        self.native = native; profile = try U3Fixture.profile(); descriptor = try U3Fixture.descriptor(reachability: reachability, coupledRatio: mode == "normalizeCoupled", information: mode.hasPrefix("telemetry"))
        let bytes = native ? try Data(contentsOf: await AdapterFixture.build.value.executable) : nil
        content = try U3Fixture.content(native: bytes, mode: mode, marker: marker.path, statePath: stateURL.path)
        let original = try U3Fixture.identity()
        identity = try DeviceContractIdentity(deviceID: original.deviceID, incarnationID: original.incarnationID, bindingID: original.bindingID,
            providerDigest: content.digest, domainID: original.domainID)
        transport = try HIDFixtureTransport(profile: profile, reports: ["0": U3Fixture.baseline])
        executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: U3Fixture.descriptor(), identity: identity, transport: transport)
        let state = try executor.read()
        var values = state.values
        if mode.hasPrefix("telemetry") { values["information"] = .integer(0) }
        let nativeState = try DeviceBackendState(identity: identity, values: values, fields: state.fields, preservation: ["opaque": "private-preservation"])
        try StrictJSON.canonical(nativeState).write(to: stateURL)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func coordinator(journal: DeviceOperationJournal? = nil) throws -> DeviceControlCoordinator {
        DeviceControlCoordinator(registry: registry, key: try registry.installationKey(), journal: journal, now: { self.clock }, resolve: { _ in
            self.resolves += 1; return try self.target()
        })
    }
    func target() throws -> ResolvedDeviceControl {
        ResolvedDeviceControl(identity: identity, descriptor: descriptor, registryRevision: revision,
            lockRequest: .init(domains: [identity.domainID]), lockDirectory: root.appendingPathComponent("locks"),
            revalidate: { lease in
                if self.disconnected { throw DeviceContractError.invalid("absentEndpoint") }
                XCTAssertTrue(lease.covers(.init(domains: [self.identity.domainID])))
            }, read: { lease in
                self.reads += 1
                if self.failReadAfterApply && self.applies > 0 { throw DeviceAdapterFailure(code: "adapterExit", dispatched: false, cleanupConfirmed: true) }
                if self.native {
                    let endpoint = try self.endpoint()
                    let result = try await self.oneShot(.read(identity: self.identity, endpoint: endpoint, capabilityIDs: self.descriptor.capabilities.map(\.id)), lease: lease)
                    guard case .read(let state) = result else { throw DeviceContractError.invalid("missingReadback") }; return state
                }
                return try self.executor.read()
            }, normalize: { observation, operation in
                let result = try await DeviceAdapterRunner(registry: self.registry, host: U3Fixture.host()).invoke(content: self.content,
                    payload: .plan(observation: observation, operation: operation), timeout: 5)
                guard case .plan(let normalized) = result else { throw DeviceContractError.invalid("adapterProtocolMismatch") }; return normalized
            }, apply: { plan, expected, lease in
                self.applies += 1
                if self.native {
                    let result = try await self.oneShot(.apply(plan: plan, endpoint: self.endpoint(), expected: expected), lease: lease)
                    guard case .apply(let result) = result else { throw DeviceContractError.invalid("missingReadback") }; return result
                }
                return try self.executor.apply(plan.operation, expected: expected)
            }, verifyPreservation: { before, after, operation in
                if self.native { XCTAssertEqual(before.preservation, ["opaque": "private-preservation"]); try requireContract(before.preservation == after.preservation, "preservationMismatch") }
                else {
                    var reports = before.preservation
                    for (id, value) in try self.profile.targetFields(capabilityID: operation.capabilityID, target: operation.target) {
                        let field = self.profile.fields.first { $0.id == id }!; let reportID = String(field.reportID)
                        var bytes = try HIDFeatureProfile.bytes(reports[reportID]!); try field.encode(value, into: &bytes); reports[reportID] = bytes.hex
                    }
                    try requireContract(reports == after.preservation, "fullReportMismatch")
                }
            })
    }
    func endpoint() throws -> DeviceEndpoint {
        try DeviceEndpoint(kind: .hid, id: identity.deviceID, identity: DevicePassiveIdentity(transport: .usb, vendorID: 1, productID: 2, interfaceNumber: 0, usages: [DeviceUsage(page: 1, usage: 5)]),
            physicalDomainID: identity.domainID, incarnationID: identity.incarnationID, address: .hid(registryID: 999, usbDeviceID: 998, interfaceID: 997))
    }
    /// Real compliant native worker, but disposable file-backed state. This test
    /// seam deliberately does not call the production host's OS endpoint opener.
    func oneShot(_ payload: AdapterPayload, lease: DeviceResourceLock) async throws -> AdapterResult {
        let parent = try SupportDirectory.root(root.appendingPathComponent("worker-" + UUID().uuidString))
        defer { SupportPackageInstaller.cleanupOwned(parent, parent: try! SupportDirectory.root(root, create: false), name: parent.url.lastPathComponent) }
        let package = try parent.directory("package", create: true), scratch = try parent.directory("scratch", create: true)
        try content.copy(to: package); try SupportPackageInstaller.validateNative(content, directory: package)
        // These correctness fixtures honor each operation's protocol cap and
        // leave read/apply headroom for cold native CI process startup. The
        // timeout-specific tests exercise their own short deadlines separately.
        let timeout: TimeInterval = payload.operation == .read ? 10 : payload.operation == .apply ? 15 : 5
        let request = AdapterRequest(providerDigest: content.digest, payload: payload, timeout: timeout)
        let executable = package.url.appendingPathComponent("adapter")
        var spec = ProcessRunner.Specification(executable: executable, timeout: timeout + 1, input: try StrictJSON.canonical(request), scratchParent: scratch.url)
        spec.inheritedDescriptors = lease.descriptors.enumerated().map { .init(source: $0.element, destination: 210 + Int32($0.offset)) }
        let output = try await AdapterProcessHost.runSupervised(specification: spec, request: request,
            expectedExecutableDigest: SupportPackageContent.hash(content.files["adapter"]!), live: AdapterLiveness())
        let result = try AdapterProcessHost.response(output, request: request).result
        if case .rejected(let failure) = result { throw DeviceAdapterFailure(code: failure.code, dispatched: false, cleanupConfirmed: true) }
        XCTAssertEqual(try SupportPackageContent.read(package), content)
        return result
    }
    var writes: Int { native ? ((try? Data(contentsOf: URL(fileURLWithPath: marker.path + ".writes")))?.count ?? 0) : transport.setters }
}

final class DeviceOperationJournalTests: XCTestCase {
    func testBothBackendsFullTypedControlsCompositionNoopAndAuthenticatedRoundTrips() async throws {
        for native in [false, true] {
            let fixture = try await OwnedDeviceControlFixture(native: native); defer { fixture.cleanup() }
            let coordinator = try fixture.coordinator()
            let operations = try [U3Fixture.operation("level", .integer(20)), U3Fixture.operation("enabled", .boolean(true)),
                U3Fixture.operation("layout", U3Fixture.layout(true), kind: .setLayout),
                U3Fixture.operation("route", .usbRoute(DeviceUSBRouteValue(configuredDestinationID: "beta", observedOwnerID: nil)), kind: .setUSBRoute),
                U3Fixture.operation("mapping", .inputMapping(["a": "mute", "b": "next"]), kind: .setInputMapping),
                DeviceOperation(kind: .setLayoutAndUSB, capabilityID: "layout", target: U3Fixture.layout(), usbCapabilityID: "route",
                    usbTarget: DeviceUSBRouteValue(configuredDestinationID: "alpha", observedOwnerID: nil))]
            for operation in operations {
                let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
                let exported = try StrictJSON.canonical(observation)
                let decoded = try StrictJSON.decode(DeviceObservation.self, from: exported)
                let plan = try await coordinator.plan(observation: decoded, request: operation)
                let roundTrip = try StrictJSON.decode(DevicePlan.self, from: StrictJSON.canonical(plan))
                let receipt = try await coordinator.apply(plan: roundTrip)
                XCTAssertTrue(receipt.verified, "\(native): \(receipt)")
                XCTAssertEqual(receipt.outcome, .verified); XCTAssertTrue(receipt.writeMayHaveOccurred)
                XCTAssertEqual(receipt.stages.count, operation.kind == .setLayoutAndUSB ? 2 : 1)
                XCTAssertFalse(String(decoding: try StrictJSON.canonical(receipt), as: UTF8.self).contains("private-preservation"))
                let count = fixture.writes, reads = fixture.reads, resolves = fixture.resolves
                let duplicate = try await coordinator.apply(plan: roundTrip)
                XCTAssertEqual(duplicate, receipt)
                XCTAssertEqual(fixture.writes, count); XCTAssertEqual(fixture.reads, reads); XCTAssertEqual(fixture.resolves, resolves)
            }
            let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
            XCTAssertEqual(observation.domainEpoch, 6)
            let noop = try await coordinator.plan(observation: observation, request: U3Fixture.operation("level", .integer(20)))
            let count = fixture.writes, result = try await coordinator.apply(plan: noop)
            XCTAssertEqual(result.outcome, .noChange); XCTAssertFalse(result.writeMayHaveOccurred); XCTAssertEqual(fixture.writes, count)
            print("U3 \(native ? "actual native subprocess" : "compiled profile fixture") full controls + composition: \(count) setters, domain epoch \(observation.domainEpoch), no replay")
        }
    }
    func testActualNativeReadOnlyInformationChangesDoNotStaleConfigurationOrVerification() async throws {
        // Isolate each comparison boundary as well as changing all of them in
        // one real file-backed native worker sequence, including availability.
        for mode in ["telemetry", "telemetryBefore", "telemetryAfter", "telemetryPostRead"] {
            let fixture = try await OwnedDeviceControlFixture(native: true, mode: mode); defer { fixture.cleanup() }
            let coordinator = try fixture.coordinator()
            let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
            let plan = try await coordinator.plan(observation: observation, request: U3Fixture.operation("level", .integer(20)))
            do {
                let receipt = try await coordinator.apply(plan: plan)
                XCTAssertEqual(receipt.outcome, .verified, "\(mode): \(receipt)")
                XCTAssertTrue(receipt.verified); XCTAssertEqual(fixture.writes, 1)
                XCTAssertEqual(receipt.after?["level"], .integer(20))
                let advances = try Int(String(contentsOf: URL(fileURLWithPath: fixture.stateURL.path + ".telemetry")))
                XCTAssertEqual(advances, mode == "telemetry" ? 5 : 1)
                if mode == "telemetry" {
                    XCTAssertEqual(observation.values["information"], .integer(1))
                    XCTAssertNil(receipt.after?["information"]) // Independent read now reports information unavailable.
                } else { XCTAssertEqual(receipt.after?["information"], .integer(1)) }
            } catch { XCTFail("Read-only information incorrectly blocked \(mode): \(error)") }
        }
    }
    func testNativeTelemetryExclusionStillRejectsGuardPreservationAndUndeclaredConfigurationEffects() async throws {
        for mode in ["telemetryGuard", "telemetryPreservation", "telemetryEffect", "telemetryIndependentGuard"] {
            let fixture = try await OwnedDeviceControlFixture(native: true, mode: mode); defer { fixture.cleanup() }
            let coordinator = try fixture.coordinator()
            let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
            let plan = try await coordinator.plan(observation: observation, request: U3Fixture.operation("level", .integer(20)))
            let receipt = try await coordinator.apply(plan: plan)
            XCTAssertEqual(receipt.outcome, .unverified); XCTAssertFalse(receipt.verified)
            XCTAssertTrue(receipt.writeMayHaveOccurred); XCTAssertEqual(fixture.writes, 1)
            // The public failure codec deliberately collapses private backend
            // consistency details; no guard/raw evidence is leaked in errors.
            XCTAssertEqual(receipt.failure?.code, "adapterProtocolMismatch", mode)
        }
    }
    func testLostNativeApplyCannotReplayUnderSameOrNewUUIDAndFreshReadDoesNotRewriteHistory() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: true, mode: "lostApply"); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator(), operation = try U3Fixture.operation("level", .integer(20))
        let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let plan = try await coordinator.plan(observation: observation, request: operation)
        let uncertain = try await coordinator.apply(plan: plan)
        XCTAssertEqual(uncertain.outcome, .unverified); XCTAssertTrue(uncertain.writeMayHaveOccurred); XCTAssertFalse(uncertain.verified); XCTAssertEqual(fixture.writes, 1)
        let relaunched = try fixture.coordinator()
        let duplicate = try await relaunched.apply(plan: plan)
        XCTAssertEqual(duplicate, uncertain); XCTAssertEqual(fixture.writes, 1)
        let replanned = try await relaunched.plan(observation: observation, request: operation)
        let reads = fixture.reads
        do { _ = try await relaunched.apply(plan: replanned); XCTFail("Old domain epoch replayed") } catch { XCTAssertEqual(error as? DeviceContractError, .invalid("staleDomainEpoch")) }
        XCTAssertEqual(fixture.reads, reads); XCTAssertEqual(fixture.writes, 1)
        let fresh = try await relaunched.read(deviceID: fixture.identity.deviceID)
        XCTAssertEqual(fresh.domainEpoch, 1); XCTAssertEqual(fresh.values["level"], .integer(20))
        XCTAssertEqual(try relaunched.receipt(operationID: plan.operationID), uncertain)
        let confirmationPlan = try await relaunched.plan(observation: fresh, request: operation)
        let confirmed = try await relaunched.apply(plan: confirmationPlan)
        XCTAssertEqual(confirmed.outcome, .noChange); XCTAssertEqual(fixture.writes, 1)
        XCTAssertEqual(try relaunched.receipt(operationID: plan.operationID), uncertain)
    }
    func testAuthenticationStaleBaselineExpiryChangedUUIDAndPersistenceFailurePrecedeSetter() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: false); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator(), operation = try U3Fixture.operation("level", .integer(20))
        let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        var object = try JSONSerialization.jsonObject(with: StrictJSON.canonical(observation)) as! [String: Any]
        object["domainEpoch"] = 99
        let edited = try StrictJSON.decode(DeviceObservation.self, from: JSONSerialization.data(withJSONObject: object))
        do { _ = try await coordinator.plan(observation: edited, request: operation); XCTFail("Edited observation authenticated") } catch {}
        let plan = try await coordinator.plan(observation: observation, request: operation)
        fixture.transport.reports[0]![15] ^= 1
        do { _ = try await coordinator.apply(plan: plan); XCTFail("Private preservation edit accepted") } catch {}
        XCTAssertEqual(fixture.writes, 0); fixture.transport.reports[0]![15] ^= 1
        fixture.clock += 300000
        do { _ = try await coordinator.apply(plan: plan); XCTFail("Expired plan executed") } catch {}
        XCTAssertEqual(fixture.writes, 0); fixture.clock -= 300000
        let full = DeviceOperationJournal(registry: fixture.registry, byteLimit: 10)
        let fullCoordinator = try fixture.coordinator(journal: full)
        do { _ = try await fullCoordinator.apply(plan: plan); XCTFail("Full journal dispatched") } catch {}
        XCTAssertEqual(fixture.writes, 0)
        let failing = DeviceOperationJournal(registry: fixture.registry, beforePersist: { if $0 == "possibleWrite" { throw DeviceContractError.invalid("journalPersistence") } })
        let failed = try await fixture.coordinator(journal: failing).apply(plan: plan)
        XCTAssertFalse(failed.verified); XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(try DeviceOperationJournal(registry: fixture.registry).epoch(domainID: fixture.identity.domainID), 1)
        let newUUID = try await coordinator.plan(observation: observation, request: operation)
        do { _ = try await coordinator.apply(plan: newUUID); XCTFail("Interrupted persistence allowed stale replay") } catch {}
        XCTAssertEqual(fixture.writes, 0)
    }
    func testIndependentPostReadFailureAndCompositionStopPreserveCompletedStageEvidence() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: true); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator()
        let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let operation = try DeviceOperation(kind: .setLayoutAndUSB, capabilityID: "layout", target: U3Fixture.layout(true), usbCapabilityID: "route", usbTarget: DeviceUSBRouteValue(configuredDestinationID: "beta", observedOwnerID: nil))
        let plan = try await coordinator.plan(observation: observation, request: operation)
        fixture.failReadAfterApply = true
        let receipt = try await coordinator.apply(plan: plan)
        XCTAssertEqual(receipt.outcome, .unverified); XCTAssertTrue(receipt.writeMayHaveOccurred)
        XCTAssertEqual(receipt.stages.count, 1); XCTAssertTrue(receipt.stages[0].completed); XCTAssertFalse(receipt.stages[0].verified)
        XCTAssertEqual(fixture.writes, 1) // No USB stage, rollback or resend.
    }
    func testUUIDChangedPlanRejectsAndExpiredArchivePruningCannotMakeOldPlanExecutable() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: false); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator()
        let observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let first = try await coordinator.plan(observation: observation, request: U3Fixture.operation("level", .integer(20)))
        let result = try await coordinator.apply(plan: first); XCTAssertTrue(result.verified)
        let auth = DeviceContractAuthentication(key: try fixture.registry.installationKey())
        let changed = try auth.signedPlan(operationID: first.operationID, identity: first.identity, revision: first.registryRevision, epoch: first.domainEpoch,
            commitments: first.expectedCommitments, operation: U3Fixture.operation("level", .integer(30)), stages: first.stages, changes: first.changes, now: first.issuedAtMilliseconds)
        do { _ = try await coordinator.apply(plan: changed); XCTFail("UUID reused for a different signed plan") } catch { XCTAssertEqual(error as? DeviceContractError, .invalid("operationUUIDReused")) }
        let secondObservation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let second = try await coordinator.plan(observation: secondObservation, request: U3Fixture.operation("level", .integer(30)))
        _ = try await coordinator.apply(plan: second)
        fixture.clock += DeviceOperationJournal.retentionMilliseconds + 1
        let fresh = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let third = try await coordinator.plan(observation: fresh, request: U3Fixture.operation("level", .integer(30)))
        _ = try await coordinator.apply(plan: third) // Prunes only the expired archive.
        XCTAssertNil(try coordinator.receipt(operationID: first.operationID))
        let writes = fixture.writes
        do { _ = try await coordinator.apply(plan: first); XCTFail("Pruned UUID became executable") } catch { XCTAssertEqual(error as? DeviceContractError, .invalid("expiredPlan")) }
        XCTAssertEqual(fixture.writes, writes)
    }
    func testNativePreservationMismatchIsUnverifiedAndRetainsAcknowledgedEvidence() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: true, mode: "wrongPreservation"); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator(), observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let plan = try await coordinator.plan(observation: observation, request: U3Fixture.operation("level", .integer(20)))
        let result = try await coordinator.apply(plan: plan)
        XCTAssertFalse(result.verified); XCTAssertEqual(result.outcome, .unverified); XCTAssertTrue(result.writeMayHaveOccurred)
        XCTAssertEqual(result.stages.count, 1); XCTAssertTrue(result.stages[0].completed); XCTAssertTrue(result.stages[0].acknowledged)
        XCTAssertEqual(fixture.writes, 1)
    }

    func testNativeHardwareFreeNormalizationOnlyChangesDeclaredCoupledComponents() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: true, mode: "normalizeCoupled"); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator(), observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let requested = try U3Fixture.operation("layout", U3Fixture.layout(true), kind: .setLayout)
        let plan = try await coordinator.plan(observation: observation, request: requested)
        XCTAssertEqual(fixture.writes, 0)
        guard case .layout(let normalized) = plan.operation.target else { return XCTFail("Missing full normalized layout") }
        XCTAssertEqual(normalized.options["ratio"], "wide"); XCTAssertEqual(plan.changes["layout"]?.after, plan.operation.target)
        let receipt = try await coordinator.apply(plan: plan); XCTAssertTrue(receipt.verified); XCTAssertEqual(fixture.writes, 1)
        let illegal = try U3Fixture.operation("layout", .layout(DeviceLayoutValue(templateID: "pair", slots: ["main": "beta", "sub": "alpha"], options: ["ratio": "wide"])), kind: .setLayout)
        XCTAssertThrowsError(try fixture.descriptor.validateNormalization(request: requested, normalized: illegal))
    }

    func testUnreachableRouteRefusesBeforeAnyBackendSetter() async throws {
        let fixture = try await OwnedDeviceControlFixture(native: false, reachability: .destinationRequired); defer { fixture.cleanup() }
        let coordinator = try fixture.coordinator(), observation = try await coordinator.read(deviceID: fixture.identity.deviceID)
        let route = try U3Fixture.operation("route", .usbRoute(DeviceUSBRouteValue(configuredDestinationID: "beta", observedOwnerID: nil)), kind: .setUSBRoute)
        do { _ = try await coordinator.plan(observation: observation, request: route); XCTFail("Unreachable destination planned") } catch { XCTAssertEqual(error as? DeviceContractError, .invalid("unavailableVerification")) }
        XCTAssertEqual(fixture.writes, 0); XCTAssertEqual(fixture.applies, 0)
    }
}
