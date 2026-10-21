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
            let resource = try DeviceResourceLock(DeviceResourceLock.selectedRequest(endpoint, graph: graph), directory: locks)
            XCTAssertThrowsError(try installer.activate(validated, endpoint: endpoint, bindingID: "binding", expectedRevision: 1, replacing: content.digest,
                snapshot: { snapshot }, graph: { graph }, leaseDirectory: locks))
            withExtendedLifetime(resource) {}
            XCTAssertEqual(try registry.snapshot(), first)
            XCTAssertFalse(installer.executionReady); XCTAssertFalse(installer.executionReadinessGaps.isEmpty)
            print("U3 \(native ? "native" : "profile") validate/selfTest + metadata activation: no live endpoint opener invoked")
        }
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
