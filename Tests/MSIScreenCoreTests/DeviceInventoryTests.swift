import XCTest
@testable import MSIScreenCore

final class DeviceInventoryTests: XCTestCase {
    func identity(_ byte: UInt8 = 7) throws -> DeviceInventoryIdentity {
        try DeviceInventoryIdentity(installationKey: Data(repeating: byte, count: 32))
    }
    func display(_ id: UInt32 = 1, uuid: String = "private-display-uuid") -> MacDisplayInfo {
        MacDisplayInfo(id: id, uuid: uuid, vendor: 1, model: 2, isBuiltIn: false, isMain: true,
            isActive: true, isAsleep: false, isMirrored: false, mirrorsDisplay: 0,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), rotation: 0, mode: nil)
    }
    func usb(_ id: UInt64 = 10, parent: UInt64? = nil, serial: String? = nil, vendor: Int = 1, product: Int = 2, deviceClass: Int = 0) -> USBDeviceNode {
        USBDeviceNode(id: id, parentID: parent, vendor: vendor, product: product, deviceClass: deviceClass,
            rootHub: false, name: "private user's device", serial: serial)
    }
    func hid(_ id: UInt64, usb: UInt64? = 10, interface: UInt64? = 20, number: UInt8? = 0,
             serial: String? = nil, usage: UInt16 = 6) -> HIDDeviceNode {
        HIDDeviceNode(id: id, usbDeviceID: usb, interfaceID: interface, interfaceNumber: number, transport: .usb,
            vendor: 1, product: 2, name: "private keyboard", serial: serial, usages: [DeviceUsage(page: 1, usage: usage)])
    }
    func build(_ displays: [MacDisplayInfo] = [], _ usb: [USBDeviceNode] = [], _ hid: [HIDDeviceNode] = [],
               boot: String = "private-boot", key: DeviceInventoryIdentity? = nil,
               usbOutcome: InventorySourceOutcome = .complete, hidOutcome: InventorySourceOutcome = .complete) throws -> DeviceInventorySnapshot {
        try MacDeviceInventoryReader.build(identity: key ?? identity(), bootIdentity: boot,
            displays: InventorySourceSlice(displays), usb: InventorySourceSlice(usb, outcome: usbOutcome),
            hid: InventorySourceSlice(hid, outcome: hidOutcome), generation: 1, checkedAtMilliseconds: 1)
    }
    func endpoint(_ snapshot: DeviceInventorySnapshot, kind: DeviceEndpointKind) throws -> DeviceEndpoint {
        try XCTUnwrap(snapshot.devices.flatMap(\.endpoints).first { $0.kind == kind })
    }
    func testEmptyRegistryMatchIsNotReportedAsAChangedRegistry() throws {
        // IOKit can return success with a null iterator when there are no
        // matches. This is absence, not an invalidated in-progress enumeration.
        XCTAssertNoThrow(try USBDeviceGraph.enumerate("MSIScreenControlAbsentRegressionService") { _ in
            XCTFail("The regression fixture must not match a registry service")
        })
    }

    func testNoMSIAndIndependentFailedSourcesStillInventory() async throws {
        let reader = MacDeviceInventoryReader(identity: try identity(), bootIdentity: "boot", sources: DeviceInventorySources(
            displays: { InventorySourceSlice([self.display()]) },
            usb: { throw DeviceContractError.invalid("fixtureUSBFailure") },
            hid: { InventorySourceSlice([self.hid(30, usb: nil, interface: nil, number: nil)]) }))
        let snapshot = try await reader.snapshot()
        XCTAssertEqual(snapshot.displays, .complete)
        guard case .failed(code: .unavailable, _) = snapshot.usb else { return XCTFail("Must preserve failure") }
        XCTAssertEqual(snapshot.hid, .complete)
        XCTAssertEqual(Set(snapshot.devices.map(\.kind)), [.display, .keyboard])
        XCTAssertTrue(snapshot.devices.allSatisfy { $0.relations.isEmpty })
        let next = try await reader.snapshot()
        XCTAssertEqual(next.generation, snapshot.generation + 1)
        XCTAssertEqual(next.devices, snapshot.devices)
    }
    func testPartialAndNonConsoleFailuresCannotBecomeEmptySuccess() async throws {
        let reader = MacDeviceInventoryReader(identity: try identity(), bootIdentity: "boot", sources: DeviceInventorySources(
            displays: { InventorySourceSlice([], outcome: .failed(code: .nonConsoleSession, message: "Display source unavailable")) },
            usb: { InventorySourceSlice([self.usb(serial: "serial")], outcome: .failed(code: .identityUnavailable, message: "One device missing")) },
            hid: { InventorySourceSlice([]) }))
        let snapshot = try await reader.snapshot()
        guard case .failed(code: .nonConsoleSession, _) = snapshot.displays else { return XCTFail("No fabricated display success") }
        guard case .failed(code: .identityUnavailable, _) = snapshot.usb else { return XCTFail("No swallowed partial source") }
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices[0].bindingEligibility, .attachmentOnly) // uniqueness is not established
    }
    func testCompositeInterfacesKeepAncestryUnionAndSeparateTargets() throws {
        let snapshot = try build([display()], [usb(serial: "serial")],
            [hid(30, serial: "serial"), hid(31, serial: "serial", usage: 2), hid(32, interface: 21, number: 1, serial: "serial", usage: 5)])
        let composite = try XCTUnwrap(snapshot.devices.first { $0.endpoints.count == 2 })
        XCTAssertEqual(Set(composite.declaredUsages), [DeviceUsage(page: 1, usage: 6), DeviceUsage(page: 1, usage: 2)])
        XCTAssertEqual(Set(composite.endpoints.map(\.id)).count, 2)
        XCTAssertEqual(composite.relations.map(\.kind), [.interfaceOf])
        XCTAssertEqual(snapshot.devices.filter { $0.endpoints.contains { $0.kind == .hid } }.count, 2)
        let usbEndpoint = try endpoint(snapshot, kind: .usb)
        XCTAssertTrue(snapshot.devices.flatMap(\.endpoints).filter { $0.kind == .hid }.allSatisfy { $0.physicalDomainID == usbEndpoint.physicalDomainID })
        XCTAssertFalse(snapshot.devices.flatMap(\.relations).contains { $0.kind == .controlsDisplay || $0.kind == .pairedThrough })
    }
    func testMultipleMSIControllersAndMissingUSBSourceDoNotImposeSingletonTopology() throws {
        let multiple = try build([], [usb(10, vendor: 0x1462, product: 0x3fa4), usb(11, vendor: 0x1462, product: 0x3fa4)])
        XCTAssertEqual(multiple.devices.count, 2)
        XCTAssertEqual(multiple.usb, .complete)
        let missing = try build([], [], [hid(30), hid(31, interface: 21, number: 1, usage: 2)],
            usbOutcome: .failed(code: .unavailable, message: "USB unavailable"))
        XCTAssertEqual(missing.devices.count, 2)
        XCTAssertTrue(missing.devices.allSatisfy { $0.relations.isEmpty })
        XCTAssertEqual(Set(missing.devices.flatMap(\.endpoints).map(\.physicalDomainID)).count, 1)
        XCTAssertTrue(missing.devices.allSatisfy { $0.bindingEligibility == .attachmentOnly })
    }

    func testTwinsNeverMergeAndReplugNeverTransfersAttachmentIdentity() throws {
        for serial in [nil, "duplicate"] as [String?] {
            let first = try build([], [usb(10, serial: serial), usb(11, serial: serial)])
            XCTAssertEqual(first.devices.count, 2)
            XCTAssertEqual(Set(first.devices.map(\.id)).count, 2)
            XCTAssertTrue(first.devices.allSatisfy { $0.bindingEligibility == .attachmentOnly })
            let replug = try build([], [usb(12, serial: serial), usb(13, serial: serial)])
            XCTAssertTrue(Set(first.devices.map(\.id)).isDisjoint(with: replug.devices.map(\.id)))
            XCTAssertThrowsError(try replug.resolve(endpoint(first, kind: .usb)))
        }
        let hidTwins = try build([], [], [hid(30, usb: nil, interface: nil, number: nil), hid(31, usb: nil, interface: nil, number: nil)])
        XCTAssertEqual(hidTwins.devices.count, 2)
    }
    func testUniqueAnchorReappearsButIncarnationRequiresFreshRead() throws {
        let first = try build([], [usb(10, serial: "unique")])
        let second = try build([], [usb(11, serial: "unique")])
        XCTAssertEqual(first.devices[0].id, second.devices[0].id)
        XCTAssertEqual(first.devices[0].bindingEligibility, .durable)
        XCTAssertNotEqual(try endpoint(first, kind: .usb).incarnationID, try endpoint(second, kind: .usb).incarnationID)
        XCTAssertThrowsError(try second.resolve(endpoint(first, kind: .usb)))
        XCTAssertEqual(try first.resolve(endpoint(first, kind: .usb)), try endpoint(first, kind: .usb))
        let changedBoot = try build([], [usb(10, serial: "unique")], boot: "another-boot")
        XCTAssertEqual(first.devices[0].id, changedBoot.devices[0].id)
        XCTAssertNotEqual(try endpoint(first, kind: .usb).incarnationID, try endpoint(changedBoot, kind: .usb).incarnationID)
        let changedPassiveIdentity = try build([], [usb(10, serial: "unique", product: 3)])
        XCTAssertThrowsError(try changedPassiveIdentity.resolve(endpoint(first, kind: .usb)))
    }
    func testDisplayUUIDUniquenessAndNoInferredControlAssociation() throws {
        let unique = try build([display()], [usb(10, vendor: 0x1462, product: 0x3fa4)])
        XCTAssertTrue(unique.devices.allSatisfy { $0.relations.isEmpty })
        let twins = try build([display(1), display(2)])
        XCTAssertEqual(Set(twins.devices.map(\.id)).count, 2)
        XCTAssertTrue(twins.devices.allSatisfy { $0.bindingEligibility == .attachmentOnly })
        let noUUID = try build([display(1, uuid: "")])
        XCTAssertEqual(noUUID.devices[0].bindingEligibility, .attachmentOnly)
    }
    func testMissingUnreadableKeyAndBootDoNotInventPersistentIdentity() throws {
        XCTAssertThrowsError(try DeviceInventoryIdentity(installationKey: Data(repeating: 1, count: 31)))
        let missing = try DeviceInventoryIdentity(installationKey: nil, unavailableReason: DeviceUnavailable(code: "identityKeyUnreadable"))
        let first = try build([display()], [usb(serial: "unique")], key: missing)
        XCTAssertTrue(first.devices.allSatisfy { $0.bindingEligibility == .transient && $0.bindingReason?.code == "identityKeyUnreadable" })
        let other = try build([display()], [usb(serial: "unique")], key: DeviceInventoryIdentity(installationKey: nil))
        XCTAssertTrue(Set(first.devices.map(\.id)).isDisjoint(with: other.devices.map(\.id)))
        let bootMissing = try MacDeviceInventoryReader.build(identity: identity(), bootIdentity: "ephemeral", bootIdentityAvailable: false,
            displays: InventorySourceSlice([display()]), usb: InventorySourceSlice([]), hid: InventorySourceSlice([]), generation: 1, checkedAtMilliseconds: 1)
        XCTAssertEqual(bootMissing.devices[0].bindingEligibility, .transient)
        XCTAssertEqual(bootMissing.devices[0].bindingReason?.code, "bootIdentityUnavailable")
    }
    func testExportOmitsPrivateAddressesNamesSerialsAndBoot() throws {
        let snapshot = try build([display()], [usb(serial: "private-serial")], [hid(30, serial: "private-serial")])
        let json = String(decoding: try StrictJSON.canonical(snapshot), as: UTF8.self)
        for forbidden in ["private", "registryID", "parentID", "usbDeviceID", "interfaceID", "address"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
        let exported = try StrictJSON.decode(DeviceInventorySnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(exported.devices.map(\.id), snapshot.devices.map(\.id))
        XCTAssertTrue(exported.devices.flatMap(\.endpoints).allSatisfy { $0.address == nil })
        XCTAssertThrowsError(try snapshot.resolve(endpoint(exported, kind: .usb)))
        XCTAssertNotEqual(try build([display()], key: identity(8)).devices.first?.id, try build([display()]).devices.first?.id)
    }
    func testMismatchedPrivateTagsAndAmbiguousReResolutionCannotOpenFirstMatch() throws {
        let snapshot = try build([], [usb()])
        let expected = try endpoint(snapshot, kind: .usb)
        XCTAssertThrowsError(try DeviceEndpoint(kind: .usb, id: expected.id, identity: expected.identity,
            physicalDomainID: expected.physicalDomainID, incarnationID: expected.incarnationID, address: .display(id: 1, uuid: nil)))
        let second = try DeviceRecord(id: identity().token("other-record", ["fixture"]), displayName: "Other", kind: .other,
            endpoints: [expected], relations: [], bindingEligibility: .ambiguous, bindingReason: DeviceUnavailable(code: "ambiguousEndpoint"))
        let ambiguous = try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: snapshot.devices + [second],
            displays: .complete, usb: .complete, hid: .complete)
        XCTAssertThrowsError(try ambiguous.resolve(expected)) { error in
            XCTAssertEqual(error as? DeviceContractError, .invalid("ambiguousEndpoint"))
        }
    }

    func testSharedAncestryBoundsAndCycles() throws {
        let cycle = try USBDeviceGraph(devices: [usb(1, parent: 2), usb(2, parent: 1)])
        XCTAssertEqual(cycle.ancestors(of: 1), [2])
        let chain = try USBDeviceGraph(devices: (1...40).map { usb(UInt64($0), parent: UInt64($0 + 1)) })
        XCTAssertEqual(chain.ancestors(of: 1).count, 32)
        XCTAssertThrowsError(try USBDeviceGraph(devices: [usb(1), usb(1)]))
    }
    func testSystemReaderUsesOnlyPassiveSources() async throws {
        // Actual public API/registry enumeration, not a transport fixture. The
        // source surface has no Get/SetReport, open session, SSH or input probe.
        let snapshot = try await MacDeviceInventoryReader(identity: identity()).snapshot()
        try snapshot.validate()
        print("PASSIVE_INVENTORY devices=\(snapshot.devices.count) displays=\(snapshot.devices.filter { $0.kind == .display }.count) sourceOutcomes=\(snapshot.displays),\(snapshot.usb),\(snapshot.hid)")
    }
}
