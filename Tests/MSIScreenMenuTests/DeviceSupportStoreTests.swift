import XCTest
@testable import MSIScreenCore
@testable import MSIScreenMenu

@MainActor
final class DeviceSupportStoreTests: XCTestCase {
    static let digest = String(repeating: "a", count: 64)
    static func endpoint(_ digit: String = "1", incarnation: String = "2") throws -> DeviceEndpoint {
        try DeviceEndpoint(kind: .hid, id: String(repeating: digit, count: 64), identity: DevicePassiveIdentity(transport: .bluetooth, vendorID: 123, productID: 456),
            physicalDomainID: String(repeating: "3", count: 64), incarnationID: String(repeating: incarnation, count: 64), address: .hid(registryID: 1, usbDeviceID: nil, interfaceID: nil))
    }
    static func selection(_ digit: String = "1", digest: String = String(repeating: "a", count: 64)) throws -> DeviceControlStore.Selection {
        let endpoint = try endpoint(digit)
        let cap = try DeviceCapability(id: "level", title: "Level", category: .setting, presentationOrder: 0, access: .readWrite,
            definition: .integer(DeviceIntegerDefinition(minimum: 0, maximum: 100, step: 1, unit: nil)), mutationScopeID: "config", evidenceIDs: [],
            executionBudgetMilliseconds: 1000, settlingMilliseconds: 0, verification: DeviceVerification(kind: .readback, guardFieldIDs: [], ownershipRequired: false), unavailableReason: nil)
        let scope = try DeviceMutationScope(id: "config", observedFields: ["level"], requiredGuardFields: [], writableFields: ["level"], coupledFields: [], preservedFields: [], preservationCommitment: nil)
        return try .init(endpoint: endpoint, binding: SupportBinding(id: "binding", selector: endpoint, packageID: "fixture", digest: digest, enabled: true),
                         descriptor: DeviceDescriptor(capabilities: [cap], scopes: [scope], evidence: [], supportsLayoutAndUSB: false))
    }
    static func observation(_ selected: DeviceControlStore.Selection) throws -> DeviceObservation {
        try DeviceObservation(schema: 1, identity: DeviceContractIdentity(deviceID: selected.endpoint.id, incarnationID: selected.endpoint.incarnationID,
            bindingID: selected.binding.id, providerDigest: selected.binding.digest, domainID: selected.endpoint.physicalDomainID), checkedAtMilliseconds: 1,
            values: ["level": .integer(20)], unavailable: [:], guardState: [:], scopeCommitments: ["config": digest], domainEpoch: 0, authentication: digest)
    }
    static func typedFixture() throws -> (DeviceControlStore.Selection, DeviceObservation) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MSIScreenCoreTests/Fixtures/device-support-cases.json")
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let fixture = cases["u5"] as! [String: Any], state = (cases["u5"] as! [String: Any])["nativeState"] as! [String: Any]
        let descriptor = try JSONDecoder().decode(DeviceDescriptor.self, from: JSONSerialization.data(withJSONObject: fixture["descriptor"]!))
        let values = try JSONDecoder().decode([String: DeviceValue].self, from: JSONSerialization.data(withJSONObject: state["values"]!))
        let base = try selection(), identity = try observation(base).identity
        return (.init(endpoint: base.endpoint, binding: base.binding, descriptor: descriptor),
            try DeviceObservation(schema: 1, identity: identity, checkedAtMilliseconds: 1, values: values, unavailable: [:], guardState: [:],
                scopeCommitments: Dictionary(uniqueKeysWithValues: descriptor.scopes.map { ($0.id, digest) }), domainEpoch: 0, authentication: digest))
    }
    static func services(read: @escaping (String) async throws -> DeviceObservation) -> DeviceControlStore.Services {
        .init(read: read, plan: { _, _ in throw DeviceContractError.invalid("unexpectedPlan") }, apply: { _ in throw DeviceContractError.invalid("unexpectedApply") })
    }
    func settle(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Store did not reach bounded checkpoint")
    }
    func testLateReadCannotPopulateAnotherSelectionOrProvider() async throws {
        let first = try Self.selection(), second = try Self.selection("4")
        var release: CheckedContinuation<DeviceObservation, Error>?
        let store = DeviceControlStore(services: Self.services { _ in try await withCheckedThrowingContinuation { release = $0 } })
        store.select(first); store.read()
        await settle { release != nil }
        XCTAssertTrue(store.busy)
        store.select(second)
        XCTAssertTrue(store.busy, "Cancellation must retain operation ownership until cleanup returns")
        release?.resume(returning: try Self.observation(first)); await settle { !store.busy }
        XCTAssertNil(store.observation); XCTAssertTrue(store.draft.isEmpty)
        release = nil; store.select(first); store.read(); await settle { release != nil }
        store.select(try Self.selection(digest: String(repeating: "b", count: 64)))
        release?.resume(returning: try Self.observation(first)); await settle { !store.busy }
        XCTAssertNil(store.observation); XCTAssertTrue(store.needsRefresh)
    }
    func testExternalHintPreservesDirtyDraftButInvalidatesApplyAndExplicitReadRestores() async throws {
        let selected = try Self.selection(), observation = try Self.observation(selected)
        let store = DeviceControlStore(services: Self.services { _ in observation })
        store.select(selected); store.read(); await settle { !store.busy }
        store.edit("level", value: .integer(21)); XCTAssertTrue(store.canApply("level"))
        store.invalidateDraft("level"); XCTAssertFalse(store.canApply("level"))
        store.edit("level", value: .integer(21)); XCTAssertTrue(store.canApply("level"))
        store.externalChange()
        XCTAssertEqual(store.draft["level"], .integer(21)); XCTAssertTrue(store.needsRefresh); XCTAssertFalse(store.canApply("level"))
        store.read(); await settle { !store.busy }
        XCTAssertEqual(store.draft["level"], .integer(20)); XCTAssertFalse(store.needsRefresh)
    }
    func testMetadataRecheckInvalidatesProviderBeforeReadDispatch() async throws {
        let selected = try Self.selection(); var reads = 0
        let store = DeviceControlStore(services: Self.services { _ in reads += 1; return try Self.observation(selected) })
        store.select(selected)
        store.recheckMetadata = { store.select(try! Self.selection(digest: String(repeating: "b", count: 64))) }
        store.read(); await settle { !store.busy }
        XCTAssertEqual(reads, 0); XCTAssertNil(store.observation); XCTAssertTrue(store.needsRefresh)
    }

    func testCompletedMutationReceiptSurvivesSelectionWithoutPopulatingNewControls() async throws {
        let selected = try Self.selection(), baseline = try Self.observation(selected), operationID = UUID()
        let operation = try DeviceOperation(kind: .setCapability, capabilityID: "level", target: .integer(21), usbCapabilityID: nil, usbTarget: nil)
        let stage = try DevicePlanStage(id: "configuration", operation: operation, scopeIDs: ["config"], budgetMilliseconds: 1000)
        let plan = try DevicePlan(schema: 1, operationID: operationID, issuedAtMilliseconds: 1, expiresAtMilliseconds: 300001,
            identity: baseline.identity, registryRevision: 1, domainEpoch: 0, expectedCommitments: baseline.scopeCommitments, operation: operation,
            stages: [stage], changes: ["level": DeviceValueChange(before: .integer(20), after: .integer(21))], authentication: Self.digest)
        let result = try DeviceMutationReceipt(schema: 1, operationID: operationID, identity: baseline.identity, before: baseline.values,
            target: ["level": .integer(21)], after: ["level": .integer(21)], stages: [DeviceStageReceipt(id: "configuration", attempted: true, completed: true, acknowledged: true, verified: true, failure: nil)],
            failure: nil, outcome: .verified, writeMayHaveOccurred: true, verified: true)
        var release: CheckedContinuation<DeviceMutationReceipt, Error>?
        let store = DeviceControlStore(services: .init(read: { _ in baseline }, plan: { _, _ in plan }, apply: { _ in try await withCheckedThrowingContinuation { release = $0 } }))
        store.select(selected); store.read(); await settle { !store.busy }; store.edit("level", value: .integer(21)); store.apply("level")
        XCTAssertTrue(store.busy); XCTAssertTrue(store.isMutating)
        await settle { release != nil }; store.select(try Self.selection("4"))
        XCTAssertTrue(store.busy, "Selection cannot abandon an accepted setter")
        release?.resume(returning: result); await settle { !store.busy }
        XCTAssertEqual(store.receipts[operationID], result); XCTAssertNil(store.receipt); XCTAssertNil(store.observation); XCTAssertTrue(store.draft.isEmpty)
    }

    func testCompositionTargetsExplicitDirtyPairInsteadOfFirstCapabilities() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MSIScreenCoreTests/Fixtures/device-support-cases.json")
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        let fixture = cases["u5"] as! [String: Any]
        let original = try JSONDecoder().decode(DeviceDescriptor.self, from: JSONSerialization.data(withJSONObject: fixture["descriptor"]!))
        func copy(_ source: DeviceCapability, id: String) throws -> DeviceCapability {
            try DeviceCapability(id: id, title: id, category: source.category, presentationOrder: source.presentationOrder,
                access: source.access, definition: source.definition, mutationScopeID: source.mutationScopeID, evidenceIDs: source.evidenceIDs,
                executionBudgetMilliseconds: source.executionBudgetMilliseconds, settlingMilliseconds: source.settlingMilliseconds,
                verification: source.verification, unavailableReason: nil)
        }
        let descriptor = try DeviceDescriptor(capabilities: original.capabilities + [copy(original.capabilities.first { $0.id == "layout" }!, id: "second-layout"),
            copy(original.capabilities.first { $0.id == "route" }!, id: "second-route")], scopes: original.scopes, evidence: original.evidence, supportsLayoutAndUSB: true)
        let selected = try Self.selection(), identity = try Self.observation(selected).identity
        let native = fixture["nativeState"] as! [String: Any]
        var values = try JSONDecoder().decode([String: DeviceValue].self, from: JSONSerialization.data(withJSONObject: native["values"]!))
        values["second-layout"] = values["layout"]; values["second-route"] = values["route"]
        let baseline = try DeviceObservation(schema: 1, identity: identity, checkedAtMilliseconds: 1, values: values, unavailable: [:],
            guardState: [:], scopeCommitments: ["configuration": Self.digest], domainEpoch: 0, authentication: Self.digest)
        var requested: DeviceOperation?
        let store = DeviceControlStore(services: .init(read: { _ in baseline }, plan: { _, operation in requested = operation; throw DeviceContractError.invalid("stopBeforeDispatch") }, apply: { _ in throw DeviceContractError.invalid("unexpectedApply") }))
        store.select(.init(endpoint: selected.endpoint, binding: selected.binding, descriptor: descriptor)); store.read(); await settle { !store.busy }
        store.edit("second-layout", value: .layout(try DeviceLayoutValue(templateID: "pair", slots: ["main": "alpha", "sub": "beta"], options: ["ratio": "equal"])))
        store.edit("second-route", value: .usbRoute(try DeviceUSBRouteValue(configuredDestinationID: "beta", observedOwnerID: nil)))
        XCTAssertFalse(store.canApplyLayoutAndUSB(layoutID: "layout", routeID: "route"))
        XCTAssertTrue(store.canApplyLayoutAndUSB(layoutID: "second-layout", routeID: "second-route"))
        store.applyLayoutAndUSB(layoutID: "second-layout", routeID: "second-route"); await settle { !store.busy }
        XCTAssertEqual(requested?.capabilityID, "second-layout"); XCTAssertEqual(requested?.usbCapabilityID, "second-route")
    }

    func testInvalidDraftNeverLeavesAnEnabledSingleApplyForAnOlderTarget() async throws {
        let (selected, baseline) = try Self.typedFixture()
        var plans = 0
        let store = DeviceControlStore(services: .init(read: { _ in baseline }, plan: { _, _ in
            plans += 1; throw DeviceContractError.invalid("stopBeforeDispatch")
        }, apply: { _ in throw DeviceContractError.invalid("unexpectedApply") }))
        store.select(selected); store.read(); await settle { !store.busy }
        store.edit("level", value: .integer(21)); XCTAssertTrue(store.canApply("level"))
        store.invalidateDraft("layout")
        XCTAssertFalse(store.canApply("level"), "Single Apply must match the conservative all-drafts-valid dispatch gate")
        store.edit("layout", value: baseline.values["layout"]!); XCTAssertTrue(store.canApply("level"))
        store.edit("level", value: .integer(101))
        XCTAssertTrue(store.invalidDrafts.contains("level"), "An invalid edit must not leave the older dirty target eligible")
        store.apply("level"); await settle { !store.busy }; XCTAssertEqual(plans, 0)
        store.editInteger("level", text: "not an integer")
        XCTAssertFalse(store.canApply("level")); XCTAssertTrue(store.invalidDrafts.contains("level"))
        store.read(); await settle { !store.busy }
        store.editInteger("level", text: "22"); XCTAssertTrue(store.canApply("level"))
        store.apply("level"); await settle { !store.busy }; XCTAssertEqual(plans, 1)
    }

    func testUnrelatedTopologyHintDoesNotCancelExplicitRead() async throws {
        let selected = try Self.selection(), baseline = try Self.observation(selected)
        var release: CheckedContinuation<DeviceObservation, Error>?
        let control = DeviceControlStore(services: Self.services { _ in try await withCheckedThrowingContinuation { release = $0 } })
        let inventory = DeviceInventoryStore(services: .init(snapshot: { throw DeviceContractError.invalid("unused") },
            listing: { throw DeviceContractError.invalid("unused") }, descriptor: { _, _ in throw DeviceContractError.invalid("unused") },
            prepare: { _ in throw DeviceContractError.invalid("unused") }, bind: { _, _, _, _ in }, disable: { _, _ in }, activate: { _, _, _ in }, remove: { _, _, _ in }))
        inventory.metadataHint = { control.externalChange() }
        control.select(selected); control.read(); await settle { release != nil }
        let generation = control.generation
        inventory.scheduleRefresh(); inventory.stopObservingPassiveChanges()
        XCTAssertEqual(control.generation, generation)
        release?.resume(returning: baseline); await settle { !control.busy }
        XCTAssertEqual(control.observation, baseline)
        control.edit("level", value: .integer(21))
        inventory.scheduleRefresh(stateMayHaveChanged: true); inventory.stopObservingPassiveChanges()
        XCTAssertTrue(control.needsRefresh); XCTAssertEqual(control.draft["level"], .integer(21)); XCTAssertFalse(control.canApply("level"))
    }

    func testAcceptedSameValueReadResetsBaselineRevisionForLocalEditors() async throws {
        let (selected, baseline) = try Self.typedFixture()
        let control = DeviceControlStore(services: Self.services { _ in baseline })
        control.select(selected); control.read(); await settle { !control.busy }
        let revision = control.baselineRevision
        control.invalidateDraft("layout")
        control.read(); await settle { !control.busy }
        XCTAssertEqual(control.observation, baseline)
        XCTAssertEqual(control.baselineRevision, revision + 1, "DeviceLayoutView is keyed by accepted baseline, not timestamp/value equality")
        XCTAssertTrue(control.invalidDrafts.isEmpty)
    }

    func testProductionInventorySessionRetainsEphemeralKeyAndQueueAcrossRefreshes() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/msi-u5-reader-" + UUID().uuidString)
        let registry = try SupportRegistry(home: root)
        try registry.root.atomicWrite(Data("damaged-key".utf8), name: "identity.key")
        let source = HIDDeviceNode(id: 30, usbDeviceID: nil, interfaceID: nil, interfaceNumber: nil, transport: .bluetooth,
            vendor: 1, product: 2, name: "fixture", serial: nil, usages: [DeviceUsage(page: 1, usage: 6)])
        let services = DeviceInventoryStore.Services.production(readerFactory: {
            XCTAssertFalse(Thread.isMainThread)
            return MacDeviceInventoryReader(identity: registry.inventoryIdentity(), bootIdentity: nil,
                sources: DeviceInventorySources(displays: { InventorySourceSlice([]) }, usb: { InventorySourceSlice([]) }, hid: { InventorySourceSlice([source]) }))
        })
        let first = try await services.snapshot(), next = try await services.snapshot()
        XCTAssertEqual(next.generation, first.generation + 1)
        XCTAssertEqual(next.devices, first.devices)
        XCTAssertFalse(first.devices.isEmpty); XCTAssertTrue(first.devices.allSatisfy { $0.bindingEligibility == .transient })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("identity.key")), Data("damaged-key".utf8))
    }

    func testDisabledAndCollidingMetadataHaveConcreteNoOwnerGuidance() async throws {
        let selected = try Self.selection()
        var bindings = [try SupportBinding(id: selected.binding.id, selector: selected.endpoint, packageID: selected.binding.packageID,
            digest: selected.binding.digest, enabled: false)]
        let record = try DeviceRecord(id: selected.endpoint.id, displayName: "fixture", kind: .other, endpoints: [selected.endpoint],
            relations: [], bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
        let inventory = DeviceInventoryStore(services: .init(snapshot: {
            try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: [record], displays: .complete, usb: .complete, hid: .complete)
        }, listing: { SupportPackageListing(schema: 1, registry: try SupportRegistrySnapshot(revision: 1,
            packages: [selected.binding.packageID: [selected.binding.digest]], bindings: bindings), packages: [], executionReady: false, executionReadinessGaps: []) },
            descriptor: { _, _ in selected.descriptor }, prepare: { _ in throw DeviceContractError.invalid("unused") }, bind: { _, _, _, _ in },
            disable: { _, _ in }, activate: { _, _, _ in }, remove: { _, _, _ in }))
        await inventory.reload(); inventory.select(selected.endpoint.id)
        XCTAssertTrue(inventory.providerTitle.contains("disabled")); XCTAssertTrue(inventory.selectedControlReason?.contains("Settings") == true)
        XCTAssertNotNil(inventory.selectedDescriptor, "Declared metadata may remain visible; it is not live authorization")
        bindings.append(try SupportBinding(id: "other", selector: selected.endpoint, packageID: selected.binding.packageID,
            digest: selected.binding.digest, enabled: true))
        await inventory.reload()
        XCTAssertNil(inventory.selectedBinding); XCTAssertNil(inventory.selectedDescriptor)
        XCTAssertTrue(inventory.selectedControlReason?.contains("collision") == true)
    }

    func testReciprocalMonitorGuardsRejectDirectRPCAndHostMappingBeforeSideEffects() async throws {
        let store = MonitorStore(); store.externalMutationActive = { true }
        store.apply(machines: [], followUSB: false); XCTAssertNotNil(store.error)
        let machine = MachineDefinition(id: "test", name: "Test", platform: .macos, input: .usbc, host: nil)
        store.route(machine, to: .fullscreen, followUSB: true)
        store.restoreSetup(); store.applySetting(.brightness); store.setKVM(.usbc, expectedMachines: [], expectedUpstreamMachineID: nil)
        XCTAssertFalse(store.busy)
        do { _ = try await store.setSideWheel(.appSwitch, expected: []); XCTFail("RPC must be guarded") } catch {}
        do { _ = try await store.setTopButton(.pinnedApp, expectedRecordHex: "", bundleIdentifier: nil); XCTFail("RPC must be guarded") } catch {}
        XCTAssertThrowsError(try store.setWheelHostAction(.applications))
        XCTAssertFalse(store.sideWheelChangeBusy); XCTAssertFalse(store.topButtonChangeBusy)
    }
    func testExistingMSIControlsStayDefaultWithoutClaimingSelectedGenericEndpoints() async throws {
        let endpoint = try DeviceEndpoint(kind: .hid, id: String(repeating: "1", count: 64),
            identity: DevicePassiveIdentity(transport: .usb, vendorID: 0x1462, productID: 0x3fa4), physicalDomainID: String(repeating: "3", count: 64),
            incarnationID: String(repeating: "2", count: 64), address: .hid(registryID: 77, usbDeviceID: 78, interfaceID: 79))
        let record = try DeviceRecord(id: endpoint.id, displayName: "Unknown MSI model", kind: .other, endpoints: [endpoint], relations: [], bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
        var present = true
        let services = DeviceInventoryStore.Services(snapshot: {
            try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: present ? [record] : [], displays: .complete, usb: .complete, hid: .complete)
        }, listing: { throw DeviceContractError.invalid("unused") }, descriptor: { _, _ in throw DeviceContractError.invalid("unexpected") }, prepare: { _ in throw DeviceContractError.invalid("unexpected") }, bind: { _, _, _, _ in }, disable: { _, _ in }, activate: { _, _, _ in }, remove: { _, _, _ in })
        let fixture = DeviceInventoryStore(services: services, fixtureLabel: "Isolated non-hardware fixture")
        await fixture.reload()
        XCTAssertFalse(fixture.usesBuiltInMonitor, "A verification fixture must never default to the live MSI control path")
        fixture.selectPeripheral(endpoint.id)
        fixture.selectBuiltInMonitor()
        XCTAssertFalse(fixture.usesBuiltInMonitor, "Neither peripheral inspection nor explicit MSI selection may escape fixture isolation")
        XCTAssertEqual(fixture.selectedID, endpoint.id)
        let store = DeviceInventoryStore(services: services)
        XCTAssertTrue(store.usesBuiltInMonitor, "The additive discovery feature must preserve the existing MSI controls on launch")
        await store.reload()
        XCTAssertTrue(store.usesBuiltInMonitor, "Passive inventory must not silently replace the existing control surface")
        store.select(endpoint.id)
        XCTAssertFalse(store.usesBuiltInMonitor, "Shared VID/PID establishes only a candidate, never the cached compiled owner")
        XCTAssertFalse(store.providerTitle.contains("MD342CQP"))
        present = false; await store.reload()
        XCTAssertFalse(store.usesBuiltInMonitor); XCTAssertEqual(store.selectedID, endpoint.id)
        store.select(nil); XCTAssertFalse(store.usesBuiltInMonitor)
    }

    func testPeripheralInspectionPreservesMonitorOwnerAndUsesEndpointSupportMetadata() async throws {
        let selected = try Self.selection()
        let record = try DeviceRecord(id: selected.endpoint.id, displayName: "Bluetooth pointer", kind: .pointer,
            endpoints: [selected.endpoint], relations: [], bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
        var present = true, bindings: [SupportBinding] = []
        let inventory = DeviceInventoryStore(services: .init(snapshot: {
            try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: present ? [record] : [],
                displays: .complete, usb: .complete, hid: .complete)
        }, listing: { SupportPackageListing(schema: 1, registry: try SupportRegistrySnapshot(revision: 1,
            packages: [selected.binding.packageID: [selected.binding.digest]], bindings: bindings), packages: [], executionReady: false, executionReadinessGaps: []) },
            descriptor: { _, _ in selected.descriptor }, prepare: { _ in throw DeviceContractError.invalid("unused") },
            bind: { _, _, _, _ in }, disable: { _, _ in }, activate: { _, _, _ in }, remove: { _, _, _ in }))
        await inventory.reload()
        inventory.selectPeripheral(selected.endpoint.id)
        XCTAssertTrue(inventory.usesBuiltInMonitor, "Inspecting a peripheral must keep the existing Layout and Monitor owner")
        XCTAssertEqual(inventory.selectedEndpoint, selected.endpoint)
        XCTAssertEqual(inventory.selectedTitle, record.displayName, "Support controls must name the peripheral rather than the compiled MSI owner")
        XCTAssertEqual(inventory.providerTitle, "No configuration provider")
        bindings = [selected.binding]
        await inventory.reload()
        XCTAssertTrue(inventory.usesBuiltInMonitor)
        XCTAssertEqual(inventory.selectedBinding, selected.binding)
        XCTAssertEqual(inventory.selectedDescriptor, selected.descriptor)
        XCTAssertTrue(inventory.providerTitle.contains("Local experimental"))
        present = false
        await inventory.reload()
        XCTAssertTrue(inventory.usesBuiltInMonitor, "Peripheral disconnection must not change monitor ownership")
        XCTAssertEqual(inventory.selectedID, selected.endpoint.id)
        XCTAssertNil(inventory.selectedEndpoint)
        XCTAssertEqual(inventory.selectedTitle, "Disconnected selection")
        inventory.select(selected.endpoint.id)
        XCTAssertFalse(inventory.usesBuiltInMonitor, "Devices retains its explicit alternate-owner selection")
        inventory.selectPeripheral(selected.endpoint.id)
        XCTAssertFalse(inventory.usesBuiltInMonitor, "Peripheral inspection must also preserve an explicit alternate owner")
    }

    func testDisconnectKeepsExactSelectionAndPartialSourcesAreVisible() async throws {
        let endpoint = try Self.endpoint()
        let record = try DeviceRecord(id: endpoint.id, displayName: "Private local name", kind: .pointer, endpoints: [endpoint], relations: [], bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
        var present = true
        let store = DeviceInventoryStore(services: .init(snapshot: {
            try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: present ? [record] : [], displays: .complete, usb: .failed(code: .denied, message: "private"), hid: .complete)
        }, listing: { throw DeviceContractError.invalid("corruptRegistry") }, descriptor: { _, _ in throw DeviceContractError.invalid("unexpected") }, prepare: { _ in throw DeviceContractError.invalid("unexpected") }, bind: { _, _, _, _ in }, disable: { _, _ in }, activate: { _, _, _ in }, remove: { _, _, _ in }))
        await store.reload(); store.select(endpoint.id)
        XCTAssertNotNil(store.metadataError); XCTAssertEqual(store.snapshot?.usb, .failed(code: .denied, message: "private"))
        present = false; await store.reload()
        XCTAssertEqual(store.selectedID, endpoint.id); XCTAssertNil(store.selectedEndpoint)
    }
}
