import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class SupportPackageTests: XCTestCase {
    func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/msi-u2-package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func package(_ parent: URL, backend: SupportBackend = .profile(engine: "hid-feature-fields-v1", relativePath: "profile.json"), payload: Data = Data("{}".utf8)) throws -> (URL, SupportPackageContent) {
        let source = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = source.appendingPathComponent(backend.payloadPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try payload.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let descriptor = try DeviceDescriptor(capabilities: [], scopes: [], evidence: [], supportsLayoutAndUSB: false)
        let manifest = try SupportManifest(schema: 1, hostAPI: 1, id: "test.fixture", version: "1.0.0", name: "Fixture", backend: backend,
            selectors: [DevicePassiveSelector(transport: .usb, vendorID: 1, productID: 2, interfaceNumber: 0, usages: [DeviceUsage(page: 1, usage: 5)])],
            trustedGuards: [], descriptor: descriptor, files: [backend.payloadPath: SupportPackageContent.hash(payload)])
        let manifestURL = source.appendingPathComponent("manifest.json")
        try StrictJSON.canonical(manifest).write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        return (source, try SupportPackageContent.read(SupportDirectory.root(source, create: false, managed: false)))
    }
    func testBothBackendValidatedActivationIsMetadataOnlyIdempotentAndCASPreservesPriorBinding() async throws {
        for native in [false, true] {
            let parent = try temporary(), registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
            let payload = native ? try Data(contentsOf: await AdapterFixture.build.value.executable) : nil
            let content = try U3Fixture.content(native: payload)
            let source = try SupportDirectory.root(parent.appendingPathComponent("source")); try content.copy(to: source)
            let installer = SupportPackageInstaller(registry: registry)
            let validated = try await installer.validate(source: source.url, expectedDigest: content.digest, host: U3Fixture.host())
            let identity = try U3Fixture.identity()
            let endpoint = try DeviceEndpoint(kind: .hid, id: identity.deviceID,
                identity: DevicePassiveIdentity(transport: .usb, vendorID: 1, productID: 2, interfaceNumber: 0, usages: [DeviceUsage(page: 1, usage: 5)]),
                physicalDomainID: identity.domainID, incarnationID: identity.incarnationID, address: .hid(registryID: 999, usbDeviceID: 998, interfaceID: 997))
            let record = try DeviceRecord(id: identity.deviceID, displayName: "fixture", kind: .other, endpoints: [endpoint], relations: [],
                bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
            let snapshot = try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: [record], displays: .complete, usb: .complete, hid: .complete)
            let graph = try USBDeviceGraph(devices: [USBDeviceNode(id: 998, parentID: nil, vendor: 1, product: 2, deviceClass: 0, rootHub: false, name: "fixture", serial: nil)])
            let locks = parent.appendingPathComponent("locks")
            let first = try installer.activate(validated, endpoint: endpoint, bindingID: "binding", expectedRevision: 0, snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks)
            XCTAssertEqual(first.revision, 1); XCTAssertEqual(first.bindings.count, 1); XCTAssertNil(first.bindings[0].selector.address)
            XCTAssertEqual(try installer.activate(validated, endpoint: endpoint, bindingID: "binding", expectedRevision: 1, replacing: content.digest,
                snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks), first)
            XCTAssertThrowsError(try installer.activate(validated, endpoint: endpoint, bindingID: "binding", expectedRevision: 0, replacing: content.digest,
                snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks))
            XCTAssertThrowsError(try installer.activate(validated, endpoint: endpoint, bindingID: "binding", expectedRevision: 1, replacing: String(repeating: "f", count: 64),
                snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks))
            let resource = try DeviceResourceLock(DeviceResourceLock.selectedRequest(endpoint, graph: graph), directory: locks)
            XCTAssertThrowsError(try installer.activate(validated, endpoint: endpoint, bindingID: "binding", expectedRevision: 1, replacing: content.digest,
                snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks))
            withExtendedLifetime(resource) {}
            XCTAssertEqual(try registry.snapshot(), first)
            XCTAssertFalse(installer.executionReady); XCTAssertFalse(installer.executionReadinessGaps.isEmpty)
            print("U3 \(native ? "native" : "profile") validate/selfTest + metadata activation: no live endpoint opener invoked")
        }
    }

    func testRetainedLifecycleDryRunsRebindDisconnectedLeasesAndUnreferencedRemoval() async throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try U3Fixture.content(), source = try SupportDirectory.root(root.appendingPathComponent("source"))
        try content.copy(to: source)
        let validated = try await installer.validate(source: source.url, host: U3Fixture.host())
        let helper = DeviceInventoryTests(), identity = registry.inventoryIdentity()
        let oldSnapshot = try helper.build([], [helper.usb()], [helper.hid(30, usage: 5)], key: identity)
        let oldEndpoint = try helper.endpoint(oldSnapshot, kind: .hid), graph = try USBDeviceGraph(devices: [helper.usb()]), locks = root.appendingPathComponent("locks")
        let initial = try installer.activate(validated, endpoint: oldEndpoint, bindingID: "old", expectedRevision: 0,
            snapshot: { oldSnapshot }, graph: { graph }, leaseDirectory: locks)
        let oldBytes = try Data(contentsOf: registry.home.appendingPathComponent("registry.json"))
        let off = try installer.changeBinding(bindingID: "old", expectedDigest: content.digest, digest: nil, expectedRevision: initial.revision, dryRun: true,
            snapshot: { oldSnapshot }, graph: { graph }, leaseDirectory: locks)
        XCTAssertFalse(off.after.bindings[0].enabled); XCTAssertEqual(off.after.revision, 2)
        XCTAssertEqual(try Data(contentsOf: registry.home.appendingPathComponent("registry.json")), oldBytes)
        XCTAssertThrowsError(try installer.remove(packageID: content.manifest.id, digest: content.digest, expectedRevision: initial.revision, dryRun: true))
        let replugged = try helper.build([], [helper.usb(11)], [helper.hid(31, usb: 11, interface: 21, usage: 5)], key: identity)
        let selected = try helper.endpoint(replugged, kind: .hid), newGraph = try USBDeviceGraph(devices: [helper.usb(11)])
        let rebound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: selected.id, expectedRevision: 1, dryRun: true,
            snapshot: { replugged }, graph: { newGraph }, leaseDirectory: locks)
        XCTAssertEqual(rebound.preservedBindingIDs, ["old"]); XCTAssertEqual(rebound.after.bindings.count, 2)
        XCTAssertEqual(try registry.snapshot(), initial)
        let both = try helper.build([], [helper.usb(), helper.usb(11)], [helper.hid(30, usage: 5), helper.hid(31, usb: 11, interface: 21, usage: 5)], key: identity)
        var enumerations = 0
        XCTAssertThrowsError(try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: selected.id, expectedRevision: 1,
            replacement: SupportBindingReplacement(bindingID: "old", expectedActiveDigest: content.digest), snapshot: {
                enumerations += 1; return enumerations == 1 ? both : replugged
            }, graph: { try USBDeviceGraph(devices: [helper.usb(), helper.usb(11)]) }, leaseDirectory: locks))
        XCTAssertEqual(enumerations, 2); XCTAssertEqual(try registry.snapshot(), initial)
        let bound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: selected.id, expectedRevision: 1,
            snapshot: { replugged }, graph: { newGraph }, leaseDirectory: locks)
        XCTAssertEqual(bound.after.bindings.count, 2); XCTAssertEqual(bound.preservedBindingIDs, ["old"])
        let repeated = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: selected.id, expectedRevision: 2,
            snapshot: { replugged }, graph: { newGraph }, leaseDirectory: locks)
        XCTAssertEqual(repeated.before, repeated.after)
        let empty = try helper.build([], [], [], key: identity), emptyGraph = try USBDeviceGraph(devices: [])
        do {
            let live = try DeviceResourceLock(DeviceResourceLock.controlRequest(oldEndpoint, graph: graph, descriptor: content.manifest.descriptor), directory: locks)
            defer { withExtendedLifetime(live) {} }
            XCTAssertThrowsError(try installer.changeBinding(bindingID: "old", expectedDigest: content.digest, digest: nil, expectedRevision: 2, dryRun: false,
                snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks)) { XCTAssertEqual($0 as? SupportStorageError, .busy) }
        }
        let disabled = try installer.changeBinding(bindingID: "old", expectedDigest: content.digest, digest: nil, expectedRevision: 2, dryRun: false,
            snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks)
        XCTAssertFalse(try XCTUnwrap(disabled.after.bindings.first { $0.id == "old" }).enabled)
        // A second retained version has no binding. Dry-run leaves exact bytes;
        // real removal moves only that owned digest to an isolated Trash sink.
        var files = content.files
        var manifestObject = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: Any]
        manifestObject["version"] = "1.0.1"
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
        let other = SupportPackageContent(files: files, manifest: try StrictJSON.decode(SupportManifest.self, from: files["manifest.json"]!), digest: SupportPackageContent.digest(files))
        let second = try SupportDirectory.root(root.appendingPathComponent("second")); try other.copy(to: second)
        let staged = try installer.stageInactive(source: second.url, expectedDigest: other.digest, expectedRevision: 3)
        let retainedPlan = try installer.changeBinding(bindingID: "old", expectedDigest: content.digest, digest: other.digest, expectedRevision: staged.revision, dryRun: true,
            snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks)
        XCTAssertEqual(retainedPlan.after.bindings.first { $0.id == "old" }?.digest, other.digest)
        XCTAssertEqual(try registry.snapshot(), staged)
        let activated = try installer.changeBinding(bindingID: "old", expectedDigest: content.digest, digest: other.digest, expectedRevision: staged.revision, dryRun: false,
            snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks)
        XCTAssertTrue(try XCTUnwrap(activated.after.bindings.first { $0.id == "old" }).enabled)
        let restored = try installer.changeBinding(bindingID: "old", expectedDigest: other.digest, digest: content.digest, expectedRevision: activated.after.revision, dryRun: false,
            snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks)
        var trashCalls = 0
        let removePlan = try installer.remove(packageID: other.manifest.id, digest: other.digest, expectedRevision: restored.after.revision, dryRun: true) { _ in XCTFail("Dry-run used Trash") }
        XCTAssertEqual(try registry.snapshot(), restored.after); XCTAssertEqual(removePlan.after.packages[other.manifest.id], [content.digest])
        let removed = try installer.remove(packageID: other.manifest.id, digest: other.digest, expectedRevision: restored.after.revision, dryRun: false) { url in
            trashCalls += 1; try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("owned-trash"))
        }
        XCTAssertEqual(trashCalls, 1); XCTAssertEqual(removed.after, try registry.snapshot())
        XCTAssertEqual(try SupportPackageContent.read(registry.root.directory("packages").directory(content.manifest.id).directory(content.digest)), content)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path).isEmpty)
    }
    private func scalarContent(transport: DeviceTransport = .usb) throws -> SupportPackageContent {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: Bundle.module.url(forResource: "device-support-cases", withExtension: "json")!)) as! [String: Any]
        let u4 = fixture["u4"] as! [String: Any]
        let descriptor = try StrictJSON.decode(DeviceDescriptor.self, from: JSONSerialization.data(withJSONObject: u4["descriptor"]!))
        let profile = try JSONSerialization.data(withJSONObject: u4["profile"]!, options: [.sortedKeys])
        let manifest = try SupportManifest(schema: 1, hostAPI: 1, id: "test.scalar", version: "1.0.0", name: "Fixture",
            backend: .profile(engine: "hid-feature-fields-v1", relativePath: "profile.json"),
            selectors: [DevicePassiveSelector(transport: transport, vendorID: 1, productID: 2, interfaceNumber: transport == .usb ? 0 : nil,
                usages: [DeviceUsage(page: 1, usage: 5)])], trustedGuards: [], descriptor: descriptor, files: ["profile.json": SupportPackageContent.hash(profile)])
        let files = ["manifest.json": try StrictJSON.canonical(manifest), "profile.json": profile]
        return SupportPackageContent(files: files, manifest: manifest, digest: SupportPackageContent.digest(files))
    }
    func testNonUSBMetadataLifecycleDoesNotRequireUnrelatedUSBGraph() async throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try scalarContent(transport: .bluetooth), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let validated = try await installer.validate(source: source.url, host: U3Fixture.host())
        let helper = DeviceInventoryTests(), identity = registry.inventoryIdentity(), locks = root.appendingPathComponent("locks")
        let hid = HIDDeviceNode(id: 30, usbDeviceID: nil, interfaceID: nil, interfaceNumber: nil, transport: .bluetooth,
            vendor: 1, product: 2, name: "fixture", serial: "durable", usages: [DeviceUsage(page: 1, usage: 5)])
        let snapshot = try helper.build([], [], [hid], key: identity, usbOutcome: .failed(code: .unavailable, message: "private USB failure"))
        let endpoint = try helper.endpoint(snapshot, kind: .hid)
        XCTAssertEqual(try DeviceSupportRequest.selectedEndpoint(endpoint.id, in: snapshot).1, endpoint)
        var graphCalls = 0
        func unrelatedUSB() throws -> USBDeviceGraph { graphCalls += 1; throw DeviceContractError.invalid("inventoryIncomplete") }
        let installed = try installer.activate(validated, endpoint: endpoint, bindingID: "bluetooth", expectedRevision: 0,
            snapshot: { snapshot }, graph: unrelatedUSB, leaseDirectory: locks)
        let bound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: endpoint.id, expectedRevision: installed.revision,
            snapshot: { snapshot }, graph: unrelatedUSB, leaseDirectory: locks)
        let activated = try installer.changeBinding(bindingID: "bluetooth", expectedDigest: content.digest, digest: content.digest,
            expectedRevision: bound.after.revision, dryRun: false, snapshot: { snapshot }, graph: unrelatedUSB, leaseDirectory: locks)
        let empty = try helper.build([], [], [], key: identity, usbOutcome: .failed(code: .unavailable, message: "private USB failure"))
        do {
            let active = try DeviceResourceLock(DeviceResourceLock.controlRequest(endpoint, graph: USBDeviceGraph(devices: []), descriptor: content.manifest.descriptor), directory: locks)
            defer { withExtendedLifetime(active) {} }
            XCTAssertThrowsError(try installer.changeBinding(bindingID: "bluetooth", expectedDigest: content.digest, digest: nil,
                expectedRevision: activated.after.revision, dryRun: false, snapshot: { empty }, graph: unrelatedUSB, leaseDirectory: locks)) {
                XCTAssertEqual($0 as? SupportStorageError, .busy)
            }
        }
        _ = try installer.changeBinding(bindingID: "bluetooth", expectedDigest: content.digest, digest: nil,
            expectedRevision: activated.after.revision, dryRun: false, snapshot: { empty }, graph: unrelatedUSB, leaseDirectory: locks)
        XCTAssertEqual(graphCalls, 0)
        let usbContent = try scalarContent(), usbSource = try SupportDirectory.root(root.appendingPathComponent("usb-source")); try usbContent.copy(to: usbSource)
        let staged = try installer.stageInactive(source: usbSource.url, expectedDigest: usbContent.digest, expectedRevision: registry.snapshot().revision)
        let usb = try helper.build([], [helper.usb()], [helper.hid(31, usage: 5)], key: identity), usbEndpoint = try helper.endpoint(usb, kind: .hid)
        XCTAssertThrowsError(try installer.bind(packageID: usbContent.manifest.id, digest: usbContent.digest, deviceID: usbEndpoint.id,
            expectedRevision: staged.revision, snapshot: { usb }, graph: unrelatedUSB, leaseDirectory: locks)) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("inventoryIncomplete"))
        }
        XCTAssertEqual(graphCalls, 1); XCTAssertEqual(try registry.snapshot(), staged)
    }
    func testRetainedLeaseFactsStayBoundedAfterRawAttachmentChanges() throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try scalarContent(), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let staged = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let helper = DeviceInventoryTests(), identity = registry.inventoryIdentity(), locks = root.appendingPathComponent("locks")
        let current = try helper.build([], [helper.usb(11, serial: "durable")], [helper.hid(31, usb: 11, interface: 21, serial: "durable", usage: 5)], key: identity)
        let endpoint = try helper.endpoint(current, kind: .hid), graph = try USBDeviceGraph(devices: [helper.usb(11, serial: "durable")])
        let bound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: endpoint.id, expectedRevision: staged.revision,
            snapshot: { current }, graph: { graph }, leaseDirectory: locks)
        let binding = try XCTUnwrap(bound.after.bindings.first), name = SupportPackageContent.hash(try StrictJSON.canonical(binding.selector)) + ".json"
        let directory = try registry.root.directory("binding-leases")
        let priorDomains = (0..<128).map { "usb:\(1000 + $0)" }
        let prior = try JSONSerialization.data(withJSONObject: ["domains": priorDomains, "controller": false, "rapoo": false], options: [.sortedKeys])
        try directory.atomicWrite(prior, name: name)
        do {
            let active = try DeviceResourceLock(.init(domains: [priorDomains[127]]), directory: locks)
            defer { withExtendedLifetime(active) {} }
            XCTAssertThrowsError(try installer.changeBinding(bindingID: binding.id, expectedDigest: content.digest, digest: content.digest,
                expectedRevision: bound.after.revision, dryRun: false, snapshot: { current }, graph: { graph }, leaseDirectory: locks)) {
                XCTAssertEqual($0 as? SupportStorageError, .busy)
            }
        }
        _ = try installer.changeBinding(bindingID: binding.id, expectedDigest: content.digest, digest: content.digest,
            expectedRevision: bound.after.revision, dryRun: true, snapshot: { current }, graph: { graph }, leaseDirectory: locks)
        XCTAssertEqual(try Data(contentsOf: directory.url.appendingPathComponent(name)), prior)
        let activated = try installer.changeBinding(bindingID: binding.id, expectedDigest: content.digest, digest: content.digest,
            expectedRevision: bound.after.revision, dryRun: false, snapshot: { current }, graph: { graph }, leaseDirectory: locks)
        let fd = try directory.file(name); defer { close(fd) }
        let stored = try JSONSerialization.jsonObject(with: SupportDirectory.read(fd, limit: 32768)) as! [String: Any]
        XCTAssertEqual(stored["domains"] as? [String], try DeviceResourceLock.controlRequest(endpoint, graph: graph, descriptor: content.manifest.descriptor).domains)
        let empty = try helper.build([], [], [], key: identity), emptyGraph = try USBDeviceGraph(devices: [])
        do {
            let active = try DeviceResourceLock(DeviceResourceLock.controlRequest(endpoint, graph: graph, descriptor: content.manifest.descriptor), directory: locks)
            defer { withExtendedLifetime(active) {} }
            XCTAssertThrowsError(try installer.changeBinding(bindingID: binding.id, expectedDigest: content.digest, digest: nil,
                expectedRevision: activated.after.revision, dryRun: false, snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks)) {
                XCTAssertEqual($0 as? SupportStorageError, .busy)
            }
        }
        XCTAssertNoThrow(try installer.changeBinding(bindingID: binding.id, expectedDigest: content.digest, digest: nil,
            expectedRevision: activated.after.revision, dryRun: false, snapshot: { empty }, graph: { emptyGraph }, leaseDirectory: locks))
    }
    func testScalarCrossRootRequestsKeepGlobalRawExclusionAlongsideDifferentLogicalLeases() throws {
        let root = try temporary(), firstRegistry = try SupportRegistry(home: root.appendingPathComponent("first")), secondRegistry = try SupportRegistry(home: root.appendingPathComponent("second"))
        let helper = DeviceInventoryTests(), graph = try USBDeviceGraph(devices: [helper.usb(serial: "durable")]), descriptor = try scalarContent().manifest.descriptor
        let first = try helper.endpoint(helper.build([], graph.devices, [helper.hid(30, serial: "durable", usage: 5)], key: firstRegistry.inventoryIdentity()), kind: .hid)
        let second = try helper.endpoint(helper.build([], graph.devices, [helper.hid(30, serial: "durable", usage: 5)], key: secondRegistry.inventoryIdentity()), kind: .hid)
        XCTAssertNotEqual(first.physicalDomainID, second.physicalDomainID)
        let a = try DeviceResourceLock.controlRequest(first, graph: graph, descriptor: descriptor), b = try DeviceResourceLock.controlRequest(second, graph: graph, descriptor: descriptor)
        XCTAssertFalse(a.controller || a.rapoo || b.controller || b.rapoo)
        XCTAssertNotEqual(DeviceResourceLock.configurationRequest(first), DeviceResourceLock.configurationRequest(second))
        XCTAssertEqual(Set(a.domains).intersection(b.domains), ["usb:10"])
        let locks = root.appendingPathComponent("shared-locks")
        do {
            let active = try DeviceResourceLock(a, directory: locks); defer { withExtendedLifetime(active) {} }
            XCTAssertThrowsError(try DeviceResourceLock(b, directory: locks)) { XCTAssertEqual($0 as? SupportStorageError, .busy) }
        }
        _ = try DeviceResourceLock(b, directory: locks)
    }
    func testDisconnectedRetainedRoutingActivationAcquiresNewCompatibilityLeases() throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try scalarContent(), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let staged = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let helper = DeviceInventoryTests(), identity = registry.inventoryIdentity(), locks = root.appendingPathComponent("locks")
        let current = try helper.build([], [helper.usb()], [helper.hid(30, usage: 5)], key: identity), endpoint = try helper.endpoint(current, kind: .hid)
        let bound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: endpoint.id, expectedRevision: staged.revision,
            snapshot: { current }, graph: { try USBDeviceGraph(devices: [helper.usb()]) }, leaseDirectory: locks)
        let routing = try U3Fixture.content()
        var files = routing.files, manifest = try JSONSerialization.jsonObject(with: routing.files["manifest.json"]!) as! [String: Any]
        manifest["id"] = content.manifest.id; manifest["version"] = "1.1.0"
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let retained = SupportPackageContent(files: files, manifest: try StrictJSON.decode(SupportManifest.self, from: files["manifest.json"]!), digest: SupportPackageContent.digest(files))
        let next = try SupportDirectory.root(root.appendingPathComponent("routing")); try retained.copy(to: next)
        let metadata = try installer.stageInactive(source: next.url, expectedDigest: retained.digest, expectedRevision: bound.after.revision)
        let empty = try helper.build([], [], [], key: identity)
        let legacy = try RapooQueryLock(directory: locks); defer { withExtendedLifetime(legacy) {} }
        XCTAssertThrowsError(try installer.changeBinding(bindingID: bound.after.bindings[0].id, expectedDigest: content.digest, digest: retained.digest,
            expectedRevision: metadata.revision, dryRun: false, snapshot: { empty }, graph: { throw DeviceContractError.invalid("unexpectedUSBGraph") }, leaseDirectory: locks)) {
            XCTAssertEqual($0 as? SupportStorageError, .busy)
        }
        XCTAssertEqual(try registry.snapshot(), metadata)
    }
    func testDisconnectedDurableReattachmentStillExcludesAWorkerUsingFreshRawFacts() throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try scalarContent(), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let staged = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let helper = DeviceInventoryTests(), identity = registry.inventoryIdentity(), locks = root.appendingPathComponent("locks")
        let old = try helper.build([], [helper.usb(serial: "durable")], [helper.hid(30, serial: "durable", usage: 5)], key: identity)
        let oldEndpoint = try helper.endpoint(old, kind: .hid)
        let bound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: oldEndpoint.id, expectedRevision: staged.revision,
            snapshot: { old }, graph: { try USBDeviceGraph(devices: [helper.usb(serial: "durable")]) }, leaseDirectory: locks)
        let current = try helper.build([], [helper.usb(11, serial: "durable")], [helper.hid(31, usb: 11, interface: 21, serial: "durable", usage: 5)], key: identity)
        let endpoint = try helper.endpoint(current, kind: .hid), graph = try USBDeviceGraph(devices: [helper.usb(11, serial: "durable")])
        XCTAssertEqual(endpoint.id, oldEndpoint.id); XCTAssertEqual(endpoint.physicalDomainID, oldEndpoint.physicalDomainID)
        XCTAssertNotEqual(endpoint.incarnationID, oldEndpoint.incarnationID)
        let active = try DeviceResourceLock(DeviceResourceLock.controlRequest(endpoint, graph: graph, descriptor: content.manifest.descriptor), directory: locks)
        defer { withExtendedLifetime(active) {} }
        let empty = try helper.build([], [], [], key: identity)
        XCTAssertThrowsError(try installer.changeBinding(bindingID: bound.after.bindings[0].id, expectedDigest: content.digest, digest: nil,
            expectedRevision: bound.after.revision, dryRun: false, snapshot: { empty }, graph: { try USBDeviceGraph(devices: []) }, leaseDirectory: locks)) {
            XCTAssertEqual($0 as? SupportStorageError, .busy)
        }
        XCTAssertEqual(try registry.snapshot(), bound.after)
    }
    func testRetainedActivationCannotEnableASecondProviderInTheSameDomain() throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try U3Fixture.content(), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let installed = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let helper = DeviceInventoryTests(), snapshot = try helper.build([], [helper.usb()], [helper.hid(30, usage: 5)], key: registry.inventoryIdentity())
        let endpoint = try helper.endpoint(snapshot, kind: .hid)
        let selector = try DeviceEndpoint(kind: endpoint.kind, id: endpoint.id, identity: endpoint.identity, physicalDomainID: endpoint.physicalDomainID, incarnationID: endpoint.incarnationID, address: nil)
        let first = try SupportBinding(id: "first", selector: selector, packageID: content.manifest.id, digest: content.digest, enabled: false)
        let second = try SupportBinding(id: "second", selector: selector, packageID: content.manifest.id, digest: content.digest, enabled: true)
        let metadata: SupportRegistrySnapshot
        do {
            let lock = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
            metadata = try registry.compareAndSwap(expectedRevision: installed.revision, packages: installed.packages, bindings: [first, second])
        }
        XCTAssertThrowsError(try installer.changeBinding(bindingID: first.id, expectedDigest: content.digest, digest: content.digest, expectedRevision: metadata.revision, dryRun: true,
            snapshot: { snapshot }, graph: { try USBDeviceGraph(devices: [helper.usb()]) }, leaseDirectory: root.appendingPathComponent("locks"))) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("providerCollision"))
        }
        XCTAssertEqual(try registry.snapshot(), metadata)
    }

    func testRequiredSourceFailureIsNotDisconnectedMetadataBeforeOrAfterLease() throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let content = try scalarContent(), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let staged = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let helper = DeviceInventoryTests(), key = registry.inventoryIdentity(), locks = root.appendingPathComponent("locks")
        let present = try helper.build([], [helper.usb()], [helper.hid(30, usage: 5)], key: key), endpoint = try helper.endpoint(present, kind: .hid)
        let bound = try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: endpoint.id, expectedRevision: staged.revision,
            snapshot: { present }, graph: { try USBDeviceGraph(devices: [helper.usb()]) }, leaseDirectory: locks)
        let empty = try helper.build([], [], [], key: key)
        for failedUSB in [true, false] {
            let failed = try helper.build([], [], [], key: key,
                usbOutcome: failedUSB ? .failed(code: .unavailable, message: "private") : .complete,
                hidOutcome: failedUSB ? .complete : .failed(code: .denied, message: "private"))
            for failAfterLease in [false, true] { for dryRun in [false, true] { for digest in [nil, content.digest] as [String?] {
                var captures = 0
                XCTAssertThrowsError(try installer.changeBinding(bindingID: bound.after.bindings[0].id, expectedDigest: content.digest,
                    digest: digest, expectedRevision: bound.after.revision, dryRun: dryRun, snapshot: {
                        captures += 1; return failAfterLease && captures == 1 ? empty : failed
                    }, graph: { throw DeviceContractError.invalid("unexpectedUSBGraph") }, leaseDirectory: locks)) {
                    XCTAssertEqual($0 as? DeviceContractError, .invalid("inventoryIncomplete"))
                }
                XCTAssertEqual(try registry.snapshot(), bound.after)
            } } }
        }
        // Genuine complete-empty disconnection still permits metadata disable.
        let disabled = try installer.changeBinding(bindingID: bound.after.bindings[0].id, expectedDigest: content.digest, digest: nil,
            expectedRevision: bound.after.revision, dryRun: false, snapshot: { empty }, graph: { throw DeviceContractError.invalid("unexpectedUSBGraph") }, leaseDirectory: locks)
        XCTAssertFalse(disabled.after.bindings[0].enabled)
    }

    func testRebindChecksPriorSourcesEvenWhenNewBluetoothEndpointNeedsNoUSB() throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let usbContent = try scalarContent(), bluetoothContent = try scalarContent(transport: .bluetooth)
        let source = try SupportDirectory.root(root.appendingPathComponent("usb")); try usbContent.copy(to: source)
        let staged = try installer.stageInactive(source: source.url, expectedDigest: usbContent.digest, expectedRevision: 0)
        let helper = DeviceInventoryTests(), key = registry.inventoryIdentity(), locks = root.appendingPathComponent("locks")
        let usb = try helper.build([], [helper.usb()], [helper.hid(30, usage: 5)], key: key), oldEndpoint = try helper.endpoint(usb, kind: .hid)
        let bound = try installer.bind(packageID: usbContent.manifest.id, digest: usbContent.digest, deviceID: oldEndpoint.id, expectedRevision: staged.revision,
            snapshot: { usb }, graph: { try USBDeviceGraph(devices: [helper.usb()]) }, leaseDirectory: locks)
        let next = try SupportDirectory.root(root.appendingPathComponent("bluetooth")); try bluetoothContent.copy(to: next)
        let metadata = try installer.stageInactive(source: next.url, expectedDigest: bluetoothContent.digest, expectedRevision: bound.after.revision)
        let hid = HIDDeviceNode(id: 77, usbDeviceID: nil, interfaceID: nil, interfaceNumber: nil, transport: .bluetooth,
            vendor: 1, product: 2, name: "fixture", serial: "durable", usages: [DeviceUsage(page: 1, usage: 5)])
        let current = try helper.build([], [], [hid], key: key), endpoint = try helper.endpoint(current, kind: .hid)
        let failed = try helper.build([], [], [hid], key: key, usbOutcome: .failed(code: .unavailable, message: "private"))
        let replacement = try SupportBindingReplacement(bindingID: bound.after.bindings[0].id, expectedActiveDigest: usbContent.digest)
        for failAfterLease in [false, true] {
            var captures = 0
            XCTAssertThrowsError(try installer.bind(packageID: bluetoothContent.manifest.id, digest: bluetoothContent.digest, deviceID: endpoint.id,
                expectedRevision: metadata.revision, replacement: replacement, dryRun: true, snapshot: {
                    captures += 1; return failAfterLease && captures == 1 ? current : failed
                }, graph: { throw DeviceContractError.invalid("unexpectedUSBGraph") }, leaseDirectory: locks)) {
                XCTAssertEqual($0 as? DeviceContractError, .invalid("inventoryIncomplete"))
            }
        }
        let preview = try installer.bind(packageID: bluetoothContent.manifest.id, digest: bluetoothContent.digest, deviceID: endpoint.id,
            expectedRevision: metadata.revision, replacement: replacement, dryRun: true, snapshot: { current },
            graph: { throw DeviceContractError.invalid("unexpectedUSBGraph") }, leaseDirectory: locks)
        XCTAssertEqual(preview.after.bindings[0].selector.id, endpoint.id); XCTAssertEqual(try registry.snapshot(), metadata)
    }

    func testInstallReplacementAcquiresPriorAliasesAndLegacyWithoutRetainingHistory() async throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), installer = SupportPackageInstaller(registry: registry)
        let routing = try U3Fixture.content(), scalar = try scalarContent()
        let firstSource = try SupportDirectory.root(root.appendingPathComponent("routing")); try routing.copy(to: firstSource)
        let secondSource = try SupportDirectory.root(root.appendingPathComponent("scalar")); try scalar.copy(to: secondSource)
        let oldPackage = try await installer.validate(source: firstSource.url, host: U3Fixture.host())
        let newPackage = try await installer.validate(source: secondSource.url, host: U3Fixture.host())
        let helper = DeviceInventoryTests(), snapshot = try helper.build([], [helper.usb()], [helper.hid(30, usage: 5)], key: registry.inventoryIdentity())
        let endpoint = try helper.endpoint(snapshot, kind: .hid), graph = try USBDeviceGraph(devices: [helper.usb()]), locks = root.appendingPathComponent("locks")
        let before = try installer.activate(oldPackage, endpoint: endpoint, bindingID: "binding", expectedRevision: 0, snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks)
        let directory = try registry.root.directory("binding-leases"), name = SupportPackageContent.hash(try StrictJSON.canonical(before.bindings[0].selector)) + ".json"
        let aliases = try JSONSerialization.data(withJSONObject: ["domains": ["usb:77777"], "controller": true, "rapoo": true])
        try directory.atomicWrite(aliases, name: name)
        for request in [DeviceResourceLock.Request(domains: ["usb:77777"]), .init(domains: [], controller: true), .init(domains: [], rapoo: true)] {
            let active = try DeviceResourceLock(request, directory: locks)
            XCTAssertThrowsError(try installer.activate(newPackage, endpoint: endpoint, bindingID: "binding", expectedRevision: before.revision,
                replacing: routing.digest, snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks)) {
                XCTAssertEqual($0 as? SupportStorageError, .busy)
            }
            withExtendedLifetime(active) {}; XCTAssertEqual(try registry.snapshot(), before)
        }
        var checkedBefore: SupportRegistrySnapshot?
        let after = try installer.activate(newPackage, endpoint: endpoint, bindingID: "binding", expectedRevision: before.revision,
            replacing: routing.digest, snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks, checkedBefore: { checkedBefore = $0 })
        XCTAssertEqual(checkedBefore, before); XCTAssertEqual(after.revision, before.revision + 1)
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appendingPathComponent(name))) as! [String: Any]
        XCTAssertFalse((stored["domains"] as! [String]).contains("usb:77777")); XCTAssertEqual(stored["controller"] as? Bool, false); XCTAssertEqual(stored["rapoo"] as? Bool, false)
    }

    func testProfileValidationReportsRejectedProfileWithoutPrivateDecoderContext() async throws {
        let root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support"))
        let (source, _) = try package(root, payload: Data("{\"private\":\"/Users/private/secret\"}".utf8))
        do { _ = try await SupportPackageInstaller(registry: registry).validate(source: source, host: U3Fixture.host()); XCTFail("Invalid profile accepted") }
        catch {
            let data = DevicePublicJSON.error(error), value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(value["code"] as? String, "rejectedProfile")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        }
    }

    func testFreshSynchronousQueueSnapshotRejectsReplacementAfterLeaseAndSharesAsyncGeneration() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let counter = Counter(), root = try temporary(), registry = try SupportRegistry(home: root.appendingPathComponent("support"))
        let helper = DeviceInventoryTests(), identity = registry.inventoryIdentity()
        let reader = MacDeviceInventoryReader(identity: identity, bootIdentity: "fixture-boot", sources: DeviceInventorySources(
            displays: { InventorySourceSlice([]) }, usb: { InventorySourceSlice([helper.usb()]) },
            hid: { InventorySourceSlice([helper.hid(counter.next() >= 3 ? 31 : 30, usage: 5)]) }))
        let first = try await reader.snapshot(), endpoint = try helper.endpoint(first, kind: .hid)
        let content = try U3Fixture.content(), source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let installer = SupportPackageInstaller(registry: registry), staged = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let before = try Data(contentsOf: registry.home.appendingPathComponent("registry.json"))
        XCTAssertThrowsError(try installer.bind(packageID: content.manifest.id, digest: content.digest, deviceID: endpoint.id, expectedRevision: staged.revision,
            snapshot: { try reader.snapshotSynchronously() }, graph: { try USBDeviceGraph(devices: [helper.usb()]) }, leaseDirectory: root.appendingPathComponent("locks")))
        XCTAssertEqual(try Data(contentsOf: registry.home.appendingPathComponent("registry.json")), before)
        let next = try reader.snapshotSynchronously(), asyncNext = try await reader.snapshot()
        XCTAssertEqual(next.generation, first.generation + 3); XCTAssertEqual(asyncNext.generation, next.generation + 1)
        XCTAssertEqual(next.devices, asyncNext.devices); XCTAssertNotEqual(next.devices, first.devices)
    }

    func testInactivePublicationCASIdempotenceAndBusyPreserveRegistry() throws {
        let parent = try temporary(), registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
        let (source, content) = try package(parent)
        let installer = SupportPackageInstaller(registry: registry)
        XCTAssertFalse(installer.executionReady)
        let first = try installer.stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 0)
        XCTAssertEqual(first.revision, 1); XCTAssertTrue(first.bindings.isEmpty)
        let installed = try registry.root.directory("packages").directory(content.manifest.id).directory(content.digest)
        XCTAssertEqual(try SupportPackageContent.read(installed), content) // Publication cleanup must not erase the pinned bytes.
        XCTAssertEqual(try installer.stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 1), first)
        XCTAssertThrowsError(try installer.stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 0))
        var lease: SupportFileLease? = try registry.root.lock("registry.lock")
        XCTAssertThrowsError(try installer.stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 1)) { XCTAssertEqual($0 as? SupportStorageError, .busy) }
        withExtendedLifetime(lease) {}; lease = nil
        XCTAssertEqual(try registry.snapshot(), first)
        let publishedData = installed.url.appendingPathComponent("profile.json")
        XCTAssertEqual(chmod(publishedData.path, 0o640), 0)
        XCTAssertThrowsError(try installer.stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 1)) { XCTAssertEqual($0 as? SupportStorageError, .unsafeFile) }
        XCTAssertEqual(try registry.snapshot(), first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: publishedData.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }
    func testSourceAndStagingMutationNeverPublish() throws {
        for stage in [false, true] {
            let parent = try temporary(), registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
            let (source, content) = try package(parent)
            XCTAssertThrowsError(try SupportPackageInstaller(registry: registry).stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 0) {
                let directory: URL
                if stage {
                    let staging = registry.home.appendingPathComponent("staging")
                    directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first)
                } else { directory = source }
                try Data("changed".utf8).write(to: directory.appendingPathComponent("profile.json"))
            })
            XCTAssertEqual(try registry.snapshot().revision, 0)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("packages").path).isEmpty)
        }
    }
    func testLinksSpecialFilesCaseAndUnexpectedPayloadRejected() throws {
        for attack in ["symlink", "hardlink", "fifo", "case", "extra", "writable", "quarantine"] {
            let parent = try temporary(), (source, _) = try package(parent)
            let file = source.appendingPathComponent("profile.json")
            switch attack {
            case "symlink":
                let target = source.appendingPathComponent("linked")
                XCTAssertEqual(symlink(file.path, target.path), 0)
            case "hardlink": XCTAssertEqual(link(file.path, source.appendingPathComponent("linked").path), 0)
            case "fifo": XCTAssertEqual(mkfifo(source.appendingPathComponent("fifo").path, 0o600), 0)
            case "case": try Data().write(to: source.appendingPathComponent("MANIFEST.JSON"))
            case "extra": try Data().write(to: source.appendingPathComponent("unlisted"))
            case "writable": XCTAssertEqual(chmod(file.path, 0o666), 0)
            default:
                let value = Data("0081;fixture".utf8)
                XCTAssertEqual(value.withUnsafeBytes { setxattr(file.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, 0)
            }
            XCTAssertThrowsError(try SupportPackageContent.read(SupportDirectory.root(source, create: false)), attack)
        }
    }
    func testInvalidOverrideDoesNotFallBackAndDamagedKeyIsPreserved() throws {
        XCTAssertThrowsError(try SupportRegistry(environment: ["MSI_SCREEN_SUPPORT_HOME": "relative"]))
        let parent = try temporary(), linked = parent.appendingPathComponent("link")
        XCTAssertEqual(symlink(parent.path, linked.path), 0)
        XCTAssertThrowsError(try SupportRegistry(environment: ["MSI_SCREEN_SUPPORT_HOME": linked.appendingPathComponent("state").path]))
        let registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
        let key = try registry.installationKey(); XCTAssertEqual(key.count, 32); XCTAssertEqual(try registry.installationKey(), key)
        let keyURL = registry.home.appendingPathComponent("identity.key")
        try Data([1, 2]).write(to: keyURL)
        XCTAssertThrowsError(try registry.installationKey())
        XCTAssertFalse(registry.inventoryIdentity().persistent)
        XCTAssertEqual(try Data(contentsOf: keyURL), Data([1, 2]))
        XCTAssertEqual(chmod(registry.home.path, 0o755), 0)
        XCTAssertThrowsError(try SupportRegistry(home: registry.home))
    }
    func testConcurrentFirstUseAndCorruptRegistryFailClosed() throws {
        let parent = try temporary(), registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
        let mutex = NSLock(); var keys: [Data] = []; var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { let key = try registry.installationKey(); mutex.lock(); keys.append(key); mutex.unlock() }
            catch { mutex.lock(); failures.append(error); mutex.unlock() }
        }
        XCTAssertFalse(keys.isEmpty); XCTAssertEqual(Set(keys).count, 1)
        XCTAssertTrue(failures.allSatisfy { $0 as? SupportStorageError == .busy }, "Concurrent failures: \(failures)")
        XCTAssertEqual(try registry.installationKey(), keys[0])
        for corrupt in ["{bad", "{\"schema\":2,\"revision\":0,\"packages\":{},\"bindings\":[]}", "{\"schema\":1,\"revision\":0,\"rev\\u0069sion\":1,\"packages\":{},\"bindings\":[]}"] {
            try registry.root.atomicWrite(Data(corrupt.utf8), name: "registry.json")
            XCTAssertThrowsError(try registry.snapshot())
            XCTAssertEqual(try Data(contentsOf: registry.home.appendingPathComponent("registry.json")), Data(corrupt.utf8))
        }
    }
    func testNativeSignatureSliceOSAndDependencyChecksOnActualExecutable() async throws {
        let artifact = try await AdapterFixture.build.value
        let payload = try Data(contentsOf: artifact.executable)
        #if arch(arm64)
        let host: SupportArchitecture = .arm64, other: SupportArchitecture = .x86_64
        #else
        let host: SupportArchitecture = .x86_64, other: SupportArchitecture = .arm64
        #endif
        func attempt(_ bytes: Data, architectures: [SupportArchitecture], minimum: String = "13.0") throws {
            let parent = try temporary(), registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
            let backend = SupportBackend.nativeAdapter(relativeExecutable: "bin/adapter", architectures: architectures, minimumMacOS: minimum)
            let (source, content) = try package(parent, backend: backend, payload: bytes)
            _ = try SupportPackageInstaller(registry: registry).stageInactive(source: source, expectedDigest: content.digest, expectedRevision: 0)
        }
        try attempt(payload, architectures: [host])
        XCTAssertThrowsError(try attempt(payload, architectures: [other]))
        XCTAssertThrowsError(try attempt(payload, architectures: [host], minimum: "99.0"))
        // This 24-byte version passes the manifest's structural regex. Its
        // overflowing middle component must not disappear at native validation.
        XCTAssertThrowsError(try attempt(payload, architectures: [host], minimum: "1.99999999999999999999.0")) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("minimumMacOS"))
        }
        var damaged = payload; damaged[4096] ^= 1
        XCTAssertThrowsError(try attempt(damaged, architectures: [host])) { XCTAssertEqual($0 as? DeviceContractError, .invalid("invalidSignature")) }
        var dependency = payload
        let library = try XCTUnwrap(dependency.range(of: Data("/usr/lib/libSystem.B.dylib".utf8)))
        dependency.replaceSubrange(library.lowerBound..<(library.lowerBound + 9), with: Data("/private/".utf8))
        XCTAssertThrowsError(try attempt(dependency, architectures: [host])) { XCTAssertEqual($0 as? DeviceContractError, .invalid("nativeDependenciesOrOS")) }
    }
    func testStagingNameSwapAndRegistryRevisionRaceCannotPublishWrongBytes() throws {
        for swap in [false, true] {
            let parent = try temporary(), registry = try SupportRegistry(home: parent.appendingPathComponent("support"))
            let (first, firstContent) = try package(parent)
            let (second, secondContent) = try package(parent, payload: Data("{\"fixture\":2}".utf8))
            let installer = SupportPackageInstaller(registry: registry)
            var moved: URL?
            XCTAssertThrowsError(try installer.stageInactive(source: first, expectedDigest: firstContent.digest, expectedRevision: 0) {
                if swap {
                    let staging = registry.home.appendingPathComponent("staging")
                    let owned = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).first)
                    let displaced = parent.appendingPathComponent("displaced"); moved = displaced
                    try FileManager.default.moveItem(at: owned, to: displaced)
                    try FileManager.default.copyItem(at: second, to: owned)
                } else {
                    _ = try installer.stageInactive(source: second, expectedDigest: secondContent.digest, expectedRevision: 0)
                }
            })
            let snapshot = try registry.snapshot()
            XCTAssertEqual(snapshot.revision, swap ? 0 : 1)
            XCTAssertFalse(snapshot.packages.values.flatMap { $0 }.contains(firstContent.digest))
            if let moved { XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("profile.json").path)) }
        }
    }
    func testSourceLimitsForeignOwnershipAndPostOpenRootReplacementFailClosed() throws {
        for attack in ["size", "count", "depth"] {
            let parent = try temporary(), (source, _) = try package(parent)
            if attack == "size" { try Data(repeating: 0, count: 16 * 1024 * 1024 + 1).write(to: source.appendingPathComponent("profile.json")) }
            else if attack == "count" {
                for i in 0..<64 { try Data().write(to: source.appendingPathComponent("extra-\(i)")) }
            } else {
                var directory = source
                for _ in 0..<17 { directory.appendPathComponent("nested") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            XCTAssertThrowsError(try SupportPackageContent.read(SupportDirectory.root(source, create: false)), attack)
        }
        XCTAssertThrowsError(try SupportDirectory.root(URL(fileURLWithPath: "/usr/bin"), create: false, managed: false))
        let parent = try temporary(), home = parent.appendingPathComponent("support")
        let registry = try SupportRegistry(home: home)
        let original = parent.appendingPathComponent("displaced-support")
        try FileManager.default.moveItem(at: home, to: original)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try registry.installationKey())
        XCTAssertThrowsError(try registry.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathComponent("identity.key").path))
    }
    func testUnicodeCaseFoldCollisionsCannotPublishAsDistinctPayloads() throws {
        let parent = try temporary(), (_, content) = try package(parent)
        let manifest = content.manifest
        var files = manifest.files
        files["straße.json"] = String(repeating: "a", count: 64)
        files["STRASSE.json"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try SupportManifest(schema: manifest.schema, hostAPI: manifest.hostAPI,
            id: manifest.id, version: manifest.version, name: manifest.name, backend: manifest.backend,
            selectors: manifest.selectors, trustedGuards: manifest.trustedGuards, descriptor: manifest.descriptor, files: files)) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("pathCollision"))
        }
    }
    func testDigestIncludesExactManifestBytesAndLengthPrefixedPaths() throws {
        let parent = try temporary(), (source, content) = try package(parent)
        let manifest = source.appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifest); bytes.append(0x20); try bytes.write(to: manifest)
        let changed = try SupportPackageContent.read(SupportDirectory.root(source, create: false))
        XCTAssertNotEqual(changed.digest, content.digest)
        XCTAssertNotEqual(SupportPackageContent.digest(["a": Data("bc".utf8)]), SupportPackageContent.digest(["ab": Data("c".utf8)]))
    }
}
