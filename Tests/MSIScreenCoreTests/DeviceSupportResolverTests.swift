import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class DeviceSupportResolverTests: XCTestCase {
    let digest = String(repeating: "d", count: 64)
    func endpoint(vendor: UInt32 = 0x1462, product: UInt32 = 0x3fa4, incarnation: String = String(repeating: "c", count: 64)) throws -> DeviceEndpoint {
        try DeviceEndpoint(kind: .hid, id: String(repeating: "a", count: 64),
            identity: DevicePassiveIdentity(transport: .usb, vendorID: vendor, productID: product, interfaceNumber: 0, usages: [DeviceUsage(page: 0xff00, usage: 1)]),
            physicalDomainID: String(repeating: "b", count: 64), incarnationID: incarnation,
            address: .hid(registryID: 11, usbDeviceID: 10, interfaceID: 12))
    }
    func snapshot(_ endpoint: DeviceEndpoint, duplicate: Bool = false) throws -> DeviceInventorySnapshot {
        var records = [try DeviceRecord(id: String(repeating: "e", count: 64), displayName: "Fixture", kind: .other,
            endpoints: [endpoint], relations: [], bindingEligibility: .durable, bindingReason: nil)]
        if duplicate { records.append(try DeviceRecord(id: String(repeating: "f", count: 64), displayName: "Twin", kind: .other,
            endpoints: [endpoint], relations: [], bindingEligibility: .durable, bindingReason: nil)) }
        return try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: records, displays: .complete, usb: .complete, hid: .complete)
    }
    func manifest(_ endpoint: DeviceEndpoint) throws -> SupportManifest {
        let msi = BuiltInControlDomainCatalog.isMSI(endpoint.identity)
        return try SupportManifest(schema: 1, hostAPI: 1, id: "test.fixture", version: "1.0.0", name: "Fixture",
            backend: .profile(engine: "hid-feature-fields-v1", relativePath: "profile.json"),
            selectors: [DevicePassiveSelector(transport: .usb, vendorID: endpoint.identity.vendorID!, productID: endpoint.identity.productID!, interfaceNumber: 0, usages: endpoint.identity.usages)],
            trustedGuards: msi ? [DeviceTrustedGuard(id: "msi-identity-v1", allowedIdentities: [DeviceMSIIdentityTuple(identityHex: "3031a0", protocolHex: "563230")])] : [],
            descriptor: DeviceDescriptor(capabilities: [], scopes: [], evidence: [], supportsLayoutAndUSB: false), files: ["profile.json": digest])
    }
    func graph(vendor: Int = 0x1462, product: Int = 0x3fa4) throws -> USBDeviceGraph {
        try USBDeviceGraph(devices: [USBDeviceNode(id: 10, parentID: 20, vendor: vendor, product: product, deviceClass: 0, rootHub: false, name: nil, serial: nil),
            USBDeviceNode(id: 20, parentID: 30, vendor: 1, product: 2, deviceClass: 9, rootHub: false, name: nil, serial: nil),
            USBDeviceNode(id: 30, parentID: nil, vendor: 1, product: 3, deviceClass: 9, rootHub: true, name: nil, serial: nil)])
    }
    func testSelectedGuardBorrowsActualLeaseAndRejectsProtectedOrChangedIdentity() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-guard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = try endpoint(), inventory = try snapshot(selected), graph = try graph(), manifest = try manifest(selected)
        let request = try DeviceResourceLock.selectedRequest(selected, graph: graph)
        let lease = try DeviceResourceLock(request, directory: directory)
        XCTAssertNotNil(lease.descriptor(forLegacy: "controller.lock"))
        for identity: [UInt8] in [[0x30, 0x31, 0xa0], [0x30, 0x30, 0xa0], [1], []] {
            var queries: [String] = []; var dispatched = false
            do {
                try DeviceSupportResolver.guardSelected(endpoint: selected, manifest: manifest, lease: lease,
                    snapshot: { inventory }, usbSource: { InventorySourceSlice(graph.devices) }, queryFixture: { code in
                        queries.append(code)
                        XCTAssertThrowsError(try DeviceResourceLock(request, directory: directory))
                        return code == "00140" ? identity : Array("V20".utf8)
                    })
                dispatched = true
            } catch { XCTAssertNotEqual(identity, [0x30, 0x31, 0xa0]) }
            XCTAssertEqual(dispatched, identity == [0x30, 0x31, 0xa0])
            XCTAssertEqual(queries, ["00140", "00150"])
        }
    }
    func testStaleAmbiguousAndMissingBorrowedLeaseRejectBeforeQuery() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-guard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try endpoint(), graph = try graph(), manifest = try manifest(endpoint)
        let lease = try DeviceResourceLock(DeviceResourceLock.selectedRequest(endpoint, graph: graph), directory: directory)
        for inventory in [try snapshot(self.endpoint(incarnation: digest)), try snapshot(endpoint, duplicate: true)] {
            XCTAssertThrowsError(try DeviceSupportResolver.guardSelected(endpoint: endpoint, manifest: manifest, lease: lease,
                snapshot: { inventory }, usbSource: { InventorySourceSlice(graph.devices) }, queryFixture: { _ in XCTFail("must not query stale/ambiguous target"); return [] }))
        }
        let unrelatedDirectory = directory.appendingPathComponent("other")
        let unrelated = try DeviceResourceLock(.init(domains: []), directory: unrelatedDirectory)
        XCTAssertThrowsError(try DeviceSupportResolver.guardSelected(endpoint: endpoint, manifest: manifest, lease: unrelated,
            snapshot: { try self.snapshot(endpoint) }, usbSource: { InventorySourceSlice(graph.devices) }, queryFixture: { _ in XCTFail("must not query without lease"); return [] }))
    }
    func testNonMSIReceivesNoMSIRequestAndReservedReceiversCannotBeClaimed() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-guard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = try endpoint(vendor: 1, product: 2), graph = try graph(vendor: 1, product: 2)
        let lease = try DeviceResourceLock(DeviceResourceLock.selectedRequest(endpoint, graph: graph), directory: directory)
        try DeviceSupportResolver.guardSelected(endpoint: endpoint, manifest: manifest(endpoint), lease: lease,
            snapshot: { try self.snapshot(endpoint) }, usbSource: { InventorySourceSlice(graph.devices) }, queryFixture: { _ in XCTFail("non-MSI query"); return [] })
        for (vendor, product): (UInt32, UInt32) in [(0x046d, 0xc548), (0x24ae, 0x186a)] {
            XCTAssertThrowsError(try manifest(self.endpoint(vendor: vendor, product: product)))
        }
    }
    func testPairedAddressCannotBypassReceiverReservationWithDifferentModelIDs() throws {
        let facts = try endpoint(vendor: 1, product: 2)
        let paired = try DeviceEndpoint(kind: .providerObservedPaired, id: facts.id, identity: facts.identity,
            physicalDomainID: facts.physicalDomainID, incarnationID: facts.incarnationID,
            address: .providerObservedPaired(receiverID: 40, providerID: "fixture", validatedIdentity: "private-pairing-identity"))
        // Missing receiver evidence must not make the paired address eligible.
        XCTAssertThrowsError(try BuiltInControlDomainCatalog.validate(manifest(paired), endpoint: paired, snapshot: snapshot(paired)))
        let receiver = try DeviceEndpoint(kind: .usb, id: String(repeating: "1", count: 64),
            identity: DevicePassiveIdentity(transport: .usb, vendorID: 0x046d, productID: 0xc548),
            physicalDomainID: String(repeating: "2", count: 64), incarnationID: String(repeating: "3", count: 64), address: .usb(registryID: 40, parentID: nil))
        let record = try DeviceRecord(id: String(repeating: "4", count: 64), displayName: "Receiver", kind: .receiver,
            endpoints: [receiver], relations: [], bindingEligibility: .durable, bindingReason: nil)
        let base = try snapshot(paired)
        let inventory = try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: base.devices + [record], displays: .complete, usb: .complete, hid: .complete)
        XCTAssertThrowsError(try BuiltInControlDomainCatalog.validate(manifest(paired), endpoint: paired, snapshot: inventory))
    }
    func testTwoMSIControllersDoNotBlockAnExactSelectedEndpoint() throws {
        let nodes = [
            USBDeviceNode(id: 10, parentID: 20, vendor: 0x1462, product: 0x3fa4, deviceClass: 0, rootHub: false, name: nil, serial: nil),
            USBDeviceNode(id: 20, parentID: 30, vendor: 1, product: 2, deviceClass: 9, rootHub: false, name: nil, serial: nil),
            USBDeviceNode(id: 30, parentID: nil, vendor: 1, product: 3, deviceClass: 9, rootHub: true, name: nil, serial: nil),
            USBDeviceNode(id: 60, parentID: 50, vendor: 0x1462, product: 0x3fa4, deviceClass: 0, rootHub: false, name: nil, serial: nil),
            USBDeviceNode(id: 50, parentID: 30, vendor: 1, product: 4, deviceClass: 9, rootHub: false, name: nil, serial: nil),
            USBDeviceNode(id: 80, parentID: 30, vendor: 1, product: 2, deviceClass: 0, rootHub: false, name: nil, serial: nil)]
        XCTAssertThrowsError(try HIDConnection.builtInSelection(from: InventorySourceSlice(nodes))) {
            XCTAssertFalse($0 is HIDConnectionError) // Public built-in selection remains singleton-only, not absent.
        }
        for (usb, kind): (UInt64, DeviceEndpointKind) in [(80, .usb), (80, .hid), (10, .hid), (60, .hid)] {
            let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-multi-controller-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let msi = usb != 80
            let base = try endpoint(vendor: msi ? 0x1462 : 1, product: msi ? 0x3fa4 : 2)
            let address: DeviceEndpointAddress = kind == .usb ? .usb(registryID: usb, parentID: 30)
                : .hid(registryID: usb + 100, usbDeviceID: usb, interfaceID: usb + 200)
            let selected = try DeviceEndpoint(kind: kind, id: base.id, identity: base.identity,
                physicalDomainID: base.physicalDomainID, incarnationID: base.incarnationID, address: address)
            var queries: [String] = []
            XCTAssertNoThrow(try {
                let graph = try USBDeviceGraph(devices: nodes)
                let request = try DeviceResourceLock.selectedRequest(selected, graph: graph)
                XCTAssertTrue(request.domains.contains("usb:\(usb)"))
                XCTAssertFalse(request.domains.contains("usb:\(usb == 10 ? 60 : 10)"))
                let lease = try DeviceResourceLock(request, directory: directory)
                try DeviceSupportResolver.guardSelected(endpoint: selected, manifest: manifest(selected), lease: lease,
                    snapshot: { try self.snapshot(selected) }, usbSource: { InventorySourceSlice(graph.devices) }, queryFixture: { code in
                        queries.append(code); return code == "00140" ? [0x30, 0x31, 0xa0] : Array("V20".utf8)
                    })
            }())
            XCTAssertEqual(queries, msi ? ["00140", "00150"] : [])
        }
    }
    func testSelectedHIDInterfaceIsExactWithMultipleControllersAndCollections() throws {
        let first = HIDDeviceNode(id: 11, usbDeviceID: 10, interfaceID: 12, interfaceNumber: 0, transport: .usb,
            vendor: 0x1462, product: 0x3fa4, name: nil, serial: nil, usages: [DeviceUsage(page: 0xff00, usage: 1)])
        let second = HIDDeviceNode(id: 61, usbDeviceID: 60, interfaceID: 62, interfaceNumber: 0, transport: .usb,
            vendor: 0x1462, product: 0x3fa4, name: nil, serial: nil, usages: first.usages)
        let collection = HIDDeviceNode(id: 21, usbDeviceID: 10, interfaceID: 22, interfaceNumber: 0, transport: .usb,
            vendor: 0x1462, product: 0x3fa4, name: nil, serial: nil, usages: first.usages)
        let selected = try endpoint()
        let other = try DeviceEndpoint(kind: .hid, id: selected.id, identity: selected.identity,
            physicalDomainID: selected.physicalDomainID, incarnationID: selected.incarnationID,
            address: .hid(registryID: 61, usbDeviceID: 60, interfaceID: 62))
        for nodes in [[second, collection, first], [first, collection, second]] {
            XCTAssertEqual(try HIDConnection.selectedInterface(for: selected, from: InventorySourceSlice(nodes)), first)
            XCTAssertEqual(try HIDConnection.selectedInterface(for: other, from: InventorySourceSlice(nodes)), second)
        }
        XCTAssertThrowsError(try HIDConnection.selectedInterface(for: selected, from: InventorySourceSlice([second]))) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("absentEndpoint"))
        }
        let usbOnly = try DeviceEndpoint(kind: .usb, id: selected.id, identity: selected.identity,
            physicalDomainID: selected.physicalDomainID, incarnationID: selected.incarnationID, address: .usb(registryID: 10, parentID: 20))
        XCTAssertThrowsError(try HIDConnection.selectedInterface(for: usbOnly, from: InventorySourceSlice([first, collection, second]))) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("ambiguousEndpoint"))
        }
        XCTAssertThrowsError(try HIDConnection.selectedInterface(for: selected,
            from: InventorySourceSlice([first], outcome: .failed(code: .changedDuringEnumeration, message: "Fixture changed")))) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("hidInventoryIncomplete"))
        }
        let changed = HIDDeviceNode(id: 11, usbDeviceID: 10, interfaceID: 99, interfaceNumber: 0, transport: .usb,
            vendor: 0x1462, product: 0x3fa4, name: nil, serial: nil, usages: first.usages)
        XCTAssertThrowsError(try HIDConnection.selectedInterface(for: selected, from: InventorySourceSlice([changed]))) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("staleEndpoint"))
        }
    }
    func testIncompleteUSBGuardSourceRefusesBeforeTrustedQueries() throws {
        let selected = try endpoint(), graph = try graph()
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-partial-guard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try DeviceResourceLock(DeviceResourceLock.selectedRequest(selected, graph: graph), directory: directory)
        XCTAssertThrowsError(try DeviceSupportResolver.guardSelected(endpoint: selected, manifest: manifest(selected), lease: lease,
            snapshot: { try self.snapshot(selected) },
            usbSource: { InventorySourceSlice(graph.devices, outcome: .failed(code: .identityUnavailable, message: "Fixture incomplete")) },
            queryFixture: { _ in XCTFail("Incomplete discovery must not open/query a selected session"); return [] })) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("usbInventoryIncomplete"))
        }
    }
    func testMetadataCollisionCannotPickFirstAndAllExperimentalReadinessStaysDisabled() throws {
        let endpoint = try endpoint(vendor: 1, product: 2), inventory = try snapshot(endpoint)
        func binding(_ id: String) throws -> SupportBinding { try SupportBinding(id: id, selector: endpoint, packageID: "test.fixture", digest: digest, enabled: true) }
        let one = try SupportRegistrySnapshot(packages: ["test.fixture": [digest]], bindings: [binding("one")])
        XCTAssertEqual(DeviceSupportResolver.resolve(endpoint: endpoint, snapshot: inventory, registry: one), .disabled(reason: "executionValidationPending"))
        let two = try SupportRegistrySnapshot(packages: one.packages, bindings: [binding("two"), binding("one")])
        XCTAssertEqual(DeviceSupportResolver.resolve(endpoint: endpoint, snapshot: inventory, registry: two), .collision(candidates: ["one", "two"]))
    }
}
