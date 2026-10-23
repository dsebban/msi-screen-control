import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

/// Shared owned compiled fixture; the entire test invocation runs under OMP.
enum AdapterFixture {
    struct Artifact { let directory: URL; let executable: URL }
    static let build = Task<Artifact, Error> {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-executable-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let executable = directory.appendingPathComponent("adapter-fixture")
        let source = Bundle.module.url(forResource: "AdapterFixture", withExtension: "swift")!
        #if arch(arm64)
        let target = "arm64-apple-macos13.0"
        #else
        let target = "x86_64-apple-macos13.0"
        #endif
        let output = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swiftc", "-target", target, source.path, "-o", executable.path], timeout: 60, outputLimit: 65536)
        guard output.succeeded else { throw NSError(domain: "FixtureCompilation", code: Int(output.exitCode), userInfo: [NSLocalizedDescriptionKey: output.text]) }
        // arm64 linking normally supplies an ad hoc signature; x86_64 linking
        // need not. Sign only this fresh owned fixture, never relax validation.
        let signing = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--timestamp=none", executable.path], timeout: 10)
        guard signing.succeeded else { throw NSError(domain: "FixtureSigning", code: Int(signing.exitCode)) }
        print("U2 actual fixture executable: \(executable.path)")
        return Artifact(directory: directory, executable: executable)
    }
    static func specification(_ arguments: [String], timeout: TimeInterval = 3) async throws -> ProcessRunner.Specification {
        let artifact = try await build.value
        return ProcessRunner.Specification(executable: artifact.executable, arguments: arguments, timeout: timeout)
    }
    static func waitForFile(_ url: URL) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "FixtureReadiness", code: 1) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

final class DeviceAdapterTests: XCTestCase {
    func u3Root() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u3-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }; return directory
    }
    func testBothBackendsActualHiddenSupervisorWorkerSelfTestsAndOfflinePlan() async throws {
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), host = try U3Fixture.host()
        let artifact = try await AdapterFixture.build.value
        for native in [false, true] {
            let marker = root.appendingPathComponent("marker")
            let content = try U3Fixture.content(native: native ? Data(contentsOf: artifact.executable) : nil, marker: marker.path)
            let runner = DeviceAdapterRunner(registry: registry, host: host)
            let result = try await runner.invoke(content: content, payload: .selfTest, timeout: 5)
            XCTAssertEqual(result, .selfTest)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path).isEmpty)
            if native {
                let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
                XCTAssertEqual(facts["lease"] as? Bool, false); XCTAssertEqual(facts["sentinel"] as? Bool, false)
                let environment = facts["environment"] as! [String: String]
                // CoreFoundation may synthesize its own encoding variable after
                // exec; this is not an inherited credential/environment entry.
                XCTAssertTrue(Set(environment.keys).isSubset(of: Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING"])))
                XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
                XCTAssertTrue(environment["HOME"]!.hasPrefix(registry.home.appendingPathComponent("invocations").path))
                XCTAssertEqual(environment["HOME"], environment["TMPDIR"])
                print("U3 native supervised host/worker selfTest: \(facts)")
            }
            let source = try SupportDirectory.root(root.appendingPathComponent(native ? "native" : "profile"))
            try content.copy(to: source)
            let validated = try await SupportPackageInstaller(registry: registry).validate(source: source.url, expectedDigest: content.digest, host: host)
            XCTAssertEqual(validated.digest, content.digest); XCTAssertEqual(try registry.snapshot().revision, 0)
        }
    }
    func testSupervisedNativeMalformedCorrelationExitOverflowTimeoutAndCopyMutationFailClosed() async throws {
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), host = try U3Fixture.host()
        let executable = try Data(contentsOf: await AdapterFixture.build.value.executable)
        for mode in ["badHello", "wrongRequest", "unknownKey", "malformed", "nonzero", "noise", "hold", "mutate"] {
            let marker = root.appendingPathComponent(mode)
            let content = try U3Fixture.content(native: executable, mode: mode, marker: marker.path)
            let expected = ["badHello": "hostWorkerBuildMismatch", "wrongRequest": "adapterProtocolMismatch", "unknownKey": "adapterProtocolMismatch",
                "malformed": "adapterProtocolMismatch", "nonzero": "adapterExit", "noise": "adapterOutputOverflow", "hold": "adapterTimeout", "mutate": "integrityChangedDuringRun"]
            do {
                // The deadline includes signature checks and both process
                // handshakes; allow startup to reach the intentional hold on CI.
                _ = try await DeviceAdapterRunner(registry: registry, host: host).invoke(content: content, payload: .selfTest, timeout: 5)
                XCTFail("Accepted \(mode)")
            } catch {
                XCTAssertEqual((error as? DeviceAdapterFailure)?.code, expected[mode]); XCTAssertEqual((error as? DeviceAdapterFailure)?.cleanupConfirmed, true)
                if mode == "badHello" { XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)) }
                if mode == "hold" { XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Timeout must exercise the running adapter, not startup") }
                print("U3 supervised failure \(mode): \(error)")
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path).isEmpty)
        }
    }
    func testPreReleaseRevalidationKeepsConcreteReasonAndNeverSendsGo() async throws {
        let root = try u3Root(), executable = try Data(contentsOf: await AdapterFixture.build.value.executable)
        for code in ["providerChanged", "unlistedIdentity", "absentEndpoint", "staleEndpoint", "registryChanged", "expiredPlan"] {
            let marker = root.appendingPathComponent(code), directory = try SupportDirectory.root(root.appendingPathComponent("copy-" + code))
            let content = try U3Fixture.content(native: executable, marker: marker.path); try content.copy(to: directory)
            let request = AdapterRequest(providerDigest: content.digest, payload: .selfTest, timeout: 5)
            let spec = ProcessRunner.Specification(executable: directory.url.appendingPathComponent("adapter"), arguments: [], timeout: 5,
                input: try StrictJSON.canonical(request))
            do {
                _ = try await AdapterProcessHost.runSupervised(specification: spec, request: request,
                    expectedExecutableDigest: SupportPackageContent.hash(executable), live: AdapterLiveness()) {
                        throw DeviceContractError.invalid(code)
                    }
                XCTFail("Pre-release rejection accepted")
            } catch {
                let failure = try XCTUnwrap(error as? DeviceAdapterFailure)
                XCTAssertEqual(failure.code, code); XCTAssertFalse(failure.dispatched); XCTAssertTrue(failure.cleanupConfirmed)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Worker marker is after Go; revalidation must reject before it")
        }
    }

    func testActualNegativeCleanupSurvivesPostRunIntegrityAndCorrelationFailure() async throws {
        let root = try u3Root(), host = try U3Fixture.host(), executable = try Data(contentsOf: await AdapterFixture.build.value.executable)
        for mode in ["cleanupFalseMutation", "cleanupFalseCorrelation"] {
            let registry = try SupportRegistry(home: root.appendingPathComponent(mode)), marker = root.appendingPathComponent(mode + ".marker")
            let content = try U3Fixture.content(native: executable, mode: mode, marker: marker.path)
            do {
                _ = try await DeviceAdapterRunner(registry: registry, host: host).invoke(content: content, payload: .selfTest, timeout: 5)
                XCTFail("Negative cleanup was accepted")
            } catch {
                let failure = try XCTUnwrap(error as? DeviceAdapterFailure)
                XCTAssertEqual(failure.code, mode == "cleanupFalseMutation" ? "integrityChangedDuringRun" : "adapterProtocolMismatch")
                XCTAssertFalse(failure.cleanupConfirmed); XCTAssertFalse(failure.dispatched)
            }
            let retained = try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path)
            XCTAssertEqual(retained.count, 1, "Unconfirmed cleanup must retain the exact invocation state, never remove it or retry")
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testBothActualWorkersRetainOnlyBorrowedDescriptionAfterParentClosesAndExitOnParentLoss() async throws {
        let root = try u3Root(), artifact = try await AdapterFixture.build.value
        for native in [false, true] {
            let owned = try SupportDirectory.root(root.appendingPathComponent(native ? "native" : "profile"))
            let content = try U3Fixture.content(native: native ? Data(contentsOf: artifact.executable) : nil, mode: "hold")
            try content.copy(to: owned)
            let request = AdapterRequest(providerDigest: content.digest, payload: .selfTest, timeout: 5)
            let input = root.appendingPathComponent(UUID().uuidString + ".json"); try StrictJSON.canonical(request).write(to: input)
            let marker = root.appendingPathComponent(UUID().uuidString + ".ready"), lock = root.appendingPathComponent(UUID().uuidString + ".lock")
            let executable = native ? owned.url.appendingPathComponent("adapter").path : try U3Fixture.host().path
            let spec = try await AdapterFixture.specification(["runtime-parent", executable, input.path, owned.url.path, marker.path, lock.path, native ? "native" : "profile"], timeout: 5)
            let task = Task { try await ProcessRunner.runStructured(spec) }
            try await AdapterFixture.waitForFile(marker)
            let pids = try String(contentsOf: marker).split(separator: " ").map { Int32($0)! }
            let descriptor = open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC); defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), -1) // Fixture parent has closed every lease copy.
            XCTAssertEqual(kill(pids[0], SIGKILL), 0)
            let output = try await task.value; XCTAssertEqual(output.termination, .signaled); XCTAssertTrue(output.cleanupConfirmed)
            for _ in 0..<200 where kill(pids[1], 0) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            if kill(pids[1], 0) == 0 { kill(pids[1], SIGKILL); XCTFail("Owned worker ignored liveness") }
            XCTAssertEqual(kill(pids[1], 0), -1); XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            print("U3 real \(native ? "native" : "support-worker") parent \(pids[0]) lost; sole worker lease \(pids[1]) released")
        }
    }
    func testHostImageReplacementRefusesBeforeWorkerAndStrictProtocolRejectsEscapedKeysAndImpossibleFlags() async throws {
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support"))
        // Root-owned signed images use the executable trust path, not the
        // user-owned writable Support-directory policy. No system code is run.
        let systemImage = try AdapterHostIdentity.capture(URL(fileURLWithPath: "/usr/bin/true"))
        try systemImage.validate()
        let source = try U3Fixture.host(), copy = root.appendingPathComponent("msi-screen")
        try FileManager.default.copyItem(atPath: source.path, toPath: copy.path)
        let pinned = try AdapterHostIdentity.capture(copy)
        let fd = open(copy.path, O_WRONLY | O_APPEND); XCTAssertGreaterThanOrEqual(fd, 0)
        var byte: UInt8 = 0; XCTAssertEqual(write(fd, &byte, 1), 1); close(fd)
        do { _ = try await DeviceAdapterRunner(registry: registry, host: pinned).invoke(content: U3Fixture.content(), payload: .selfTest, timeout: 5); XCTFail("Replaced host dispatched") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path).isEmpty)
        let request = AdapterRequest(providerDigest: U3Fixture.zero, payload: .selfTest, timeout: 5)
        let bytes = try StrictJSON.canonical(request), text = String(decoding: bytes, as: UTF8.self)
        let duplicate = "{\"schema\":1,\"sch\\u0065ma\":1," + text.dropFirst()
        XCTAssertThrowsError(try StrictJSON.decode(AdapterRequest.self, from: Data(duplicate.utf8)))
        let state = try DeviceBackendState(identity: U3Fixture.identity(), values: [:], fields: [:], preservation: [:])
        let invalid: [String: Any] = ["before": try JSONSerialization.jsonObject(with: StrictJSON.canonical(state)), "after": try JSONSerialization.jsonObject(with: StrictJSON.canonical(state)),
            "attempted": false, "completed": true, "acknowledged": true]
        XCTAssertThrowsError(try StrictJSON.decode(DeviceBackendApply.self, from: JSONSerialization.data(withJSONObject: invalid)))
    }

    func testRoutingFunctionTakesLegacyExclusionAndNonUSBHIDIdentityIsRootIndependent() throws {
        let root = try u3Root()
        let passive = try DevicePassiveIdentity(transport: .bluetooth, vendorID: 1, productID: 2, usages: [DeviceUsage(page: 1, usage: 5)])
        func hid(_ token: String) throws -> DeviceEndpoint {
            try DeviceEndpoint(kind: .hid, id: String(repeating: token, count: 64), identity: passive,
                physicalDomainID: String(repeating: token, count: 64), incarnationID: String(repeating: token, count: 64),
                address: .hid(registryID: 999, usbDeviceID: nil, interfaceID: nil))
        }
        let empty = try USBDeviceGraph(devices: [])
        let first = try DeviceResourceLock.selectedRequest(hid("1"), graph: empty), second = try DeviceResourceLock.selectedRequest(hid("2"), graph: empty)
        XCTAssertEqual(first, second) // Different installation keys cannot split the physical lease.
        do {
            let owner = try DeviceResourceLock(first, directory: root)
            XCTAssertThrowsError(try DeviceResourceLock(second, directory: root))
            withExtendedLifetime(owner) {}
        }
        let endpoint = try DeviceEndpoint(kind: .usb, id: U3Fixture.zero, identity: DevicePassiveIdentity(transport: .usb, vendorID: 1, productID: 2),
            physicalDomainID: U3Fixture.zero, incarnationID: U3Fixture.zero, address: .usb(registryID: 998, parentID: nil))
        let graph = try USBDeviceGraph(devices: [USBDeviceNode(id: 998, parentID: nil, vendor: 1, product: 2, deviceClass: 0, rootHub: false, name: nil, serial: nil)])
        let routing = try DeviceResourceLock.controlRequest(endpoint, graph: graph, descriptor: U3Fixture.descriptor())
        do {
            let legacy = try RapooQueryLock(directory: root)
            XCTAssertThrowsError(try DeviceResourceLock(routing, directory: root))
            _ = try DeviceResourceLock(.init(domains: routing.domains), directory: root) // Failed partial acquisition released its physical leases.
            withExtendedLifetime(legacy) {}
        }
        let owned = try DeviceResourceLock(routing, directory: root)
        XCTAssertNotNil(owned.descriptor(forLegacy: "controller.lock")); XCTAssertNotNil(owned.descriptor(forLegacy: "rapoo.lock"))
    }

    func testProductionExperimentalTargetRefusesQualificationPendingBeforeAnyOperationalDispatch() async throws {
        struct FixedInventory: DeviceInventoryClient {
            let value: DeviceInventorySnapshot
            func snapshot() async throws -> DeviceInventorySnapshot { value }
        }
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), helper = DeviceInventoryTests()
        let hid = HIDDeviceNode(id: 30, usbDeviceID: nil, interfaceID: nil, interfaceNumber: nil, transport: .bluetooth,
            vendor: 1, product: 2, name: "fixture", serial: "durable", usages: [DeviceUsage(page: 1, usage: 5)])
        let snapshot = try helper.build([], [], [hid], key: registry.inventoryIdentity(), usbOutcome: .failed(code: .unavailable, message: "private diagnostic"))
        let endpoint = try helper.endpoint(snapshot, kind: .hid), original = try U3Fixture.content()
        var files = original.files, object = try JSONSerialization.jsonObject(with: original.files["manifest.json"]!) as! [String: Any]
        object["selectors"] = [["transport": "bluetooth", "vendorID": 1, "productID": 2, "usages": [["page": 1, "usage": 5]]]]
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let content = SupportPackageContent(files: files, manifest: try StrictJSON.decode(SupportManifest.self, from: files["manifest.json"]!), digest: SupportPackageContent.digest(files))
        let source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let installer = SupportPackageInstaller(registry: registry), staged = try installer.stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let selector = try DeviceEndpoint(kind: endpoint.kind, id: endpoint.id, identity: endpoint.identity, physicalDomainID: endpoint.physicalDomainID, incarnationID: endpoint.incarnationID, address: nil)
        let binding = try SupportBinding(id: "fixture", selector: selector, packageID: content.manifest.id, digest: content.digest, enabled: true)
        do {
            let lock = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
            _ = try registry.compareAndSwap(expectedRevision: staged.revision, packages: staged.packages, bindings: [binding])
        }
        XCTAssertFalse(installer.executionReady)
        do {
            _ = try await DeviceControlCoordinator.selectedTarget(deviceID: endpoint.id, registry: registry, reader: FixedInventory(value: snapshot), hostPin: .success(U3Fixture.host()))
            XCTFail("Production returned an operational target while qualification remains pending; no target closure was invoked")
        } catch { XCTAssertEqual(error as? DeviceContractError, .invalid("runtimeQualificationPending")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path).isEmpty)
    }
    func testSelectedRuntimeResourceRequestsIgnoreUnrelatedPartialUSBBUTRequireUSBAncestry() throws {
        let root = try u3Root(), helper = DeviceInventoryTests()
        let partial = InventorySourceSlice([helper.usb()], outcome: InventorySourceOutcome.failed(code: .unavailable, message: "private USB diagnostic"))
        let hid = HIDDeviceNode(id: 30, usbDeviceID: nil, interfaceID: nil, interfaceNumber: nil, transport: .bluetooth,
            vendor: 1, product: 2, name: "fixture", serial: "serial", usages: [DeviceUsage(page: 1, usage: 5)])
        let snapshot = try helper.build([], [], [hid], usbOutcome: partial.outcome), endpoint = try helper.endpoint(snapshot, kind: .hid)
        var calls = 0
        func graph() throws -> USBDeviceGraph { calls += 1; return try MacUSBPeripheralReader.controlGraph(from: partial) }
        let request = try DeviceResourceLock.controlRequest(endpoint, usbGraph: graph, descriptor: U3Fixture.descriptor())
        let lease = try DeviceResourceLock(request, directory: root)
        try DeviceSupportResolver.guardSelected(endpoint: endpoint, manifest: {
            let content = try U3Fixture.content()
            var object = try JSONSerialization.jsonObject(with: content.files["manifest.json"]!) as! [String: Any]
            object["selectors"] = [["transport": "bluetooth", "vendorID": 1, "productID": 2, "usages": [["page": 1, "usage": 5]]]]
            return try StrictJSON.decode(SupportManifest.self, from: JSONSerialization.data(withJSONObject: object))
        }(), lease: lease, snapshot: { snapshot }, usbSource: { calls += 1; return partial })
        XCTAssertEqual(calls, 0); XCTAssertTrue(request.controller); XCTAssertTrue(request.rapoo)
        let usb = try helper.build([], [helper.usb()], [helper.hid(31, usage: 5)]), usbEndpoint = try helper.endpoint(usb, kind: .hid)
        XCTAssertThrowsError(try DeviceResourceLock.controlRequest(usbEndpoint, usbGraph: graph, descriptor: U3Fixture.descriptor())) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("usbInventoryIncomplete"))
        }
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try DeviceResourceLock.controlRequest(usbEndpoint, usbGraph: { try USBDeviceGraph(devices: []) }, descriptor: U3Fixture.descriptor())) {
            XCTAssertEqual($0 as? DeviceContractError, .invalid("absentEndpoint"))
        }
        withExtendedLifetime(lease) {}
    }
    func testProfileWorkerFailureIsCorrelatedAndFailedValidationCannotActivate() async throws {
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support"))
        let original = try U3Fixture.content()
        var files = original.files
        var profile = try JSONSerialization.jsonObject(with: files["profile.json"]!) as! [String: Any]
        var fixtures = profile["fixtures"] as! [[String: Any]]
        fixtures[0]["reports"] = ["0": "2b" + U3Fixture.baseline.dropFirst(2)]; profile["fixtures"] = fixtures
        files["profile.json"] = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        var manifest = try JSONSerialization.jsonObject(with: files["manifest.json"]!) as! [String: Any]
        manifest["files"] = ["profile.json": SupportPackageContent.hash(files["profile.json"]!)]
        files["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let decoded = try StrictJSON.decode(SupportManifest.self, from: files["manifest.json"]!)
        let content = SupportPackageContent(files: files, manifest: decoded, digest: SupportPackageContent.digest(files))
        let source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        do {
            _ = try await SupportPackageInstaller(registry: registry).validate(source: source.url, expectedDigest: content.digest, host: U3Fixture.host())
            XCTFail("Invalid profile fixture activated")
        } catch { XCTAssertEqual((error as? DeviceAdapterFailure)?.code, "identityMismatch") }
        XCTAssertEqual(try registry.snapshot().revision, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path).isEmpty)
    }

    func testActualSupervisorCleansNativeDescendantAfterNormalLeaderExit() async throws {
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), host = try U3Fixture.host()
        let executable = try Data(contentsOf: await AdapterFixture.build.value.executable), marker = root.appendingPathComponent("normal-exit")
        let content = try U3Fixture.content(native: executable, mode: "descendant", marker: marker.path)
        let result = try await DeviceAdapterRunner(registry: registry, host: host).invoke(content: content, payload: .selfTest, timeout: 5)
        XCTAssertEqual(result, .selfTest)
        let pid = try XCTUnwrap(Int32(String(contentsOf: URL(fileURLWithPath: marker.path + ".descendant"))))
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(kill(pid, 0), -1)
        print("U3 actual host normal-exit descendant \(pid) cleanup confirmed")
    }

    func testActualSupportHostDeathAndCancellationCloseWorkerLivenessNoResend() async throws {
        let root = try u3Root(), registry = try SupportRegistry(home: root.appendingPathComponent("support")), host = try U3Fixture.host()
        let executable = try Data(contentsOf: await AdapterFixture.build.value.executable)
        for mode in ["killSupervisor", "hold"] {
            let marker = root.appendingPathComponent(mode)
            let content = try U3Fixture.content(native: executable, mode: mode, marker: marker.path)
            let task = Task { try await DeviceAdapterRunner(registry: registry, host: host).invoke(content: content, payload: .selfTest, timeout: 4) }
            try await AdapterFixture.waitForFile(marker)
            let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
            if mode == "hold" { task.cancel() }
            do { _ = try await task.value; XCTFail("Lost/cancelled supervisor accepted") } catch {}
            try await AdapterFixture.waitForFile(URL(fileURLWithPath: marker.path + ".eof"))
            let pid = facts["pid"] as! Int32
            for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(kill(pid, 0), -1)
            print("U3 actual support-host \(mode), worker \(pid), liveness EOF, terminal")
        }
    }

    func testBorrowedDescriptionSurvivesParentCloseAndLivenessWriterIsNotInherited() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-borrowed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: DeviceResourceLock? = try DeviceResourceLock(.init(domains: ["owned-fixture"], controller: true, rapoo: true), directory: directory)
        let request = owner!.request
        var live: [Int32] = [-1, -1]; XCTAssertEqual(pipe(&live), 0)
        defer { close(live[0]); if live[1] >= 0 { close(live[1]) } }
        let marker = directory.appendingPathComponent("ready")
        var spec = try await AdapterFixture.specification(["lease", marker.path])
        spec.inheritedDescriptors = owner!.descriptors.enumerated().map { .init(source: $0.element, destination: 210 + Int32($0.offset) * 2) }
            + [.init(source: live[0], destination: 211)]
        let task = Task { try await ProcessRunner.runStructured(spec) }
        try await AdapterFixture.waitForFile(marker)
        owner = nil
        // Only the worker's copy now holds the new domain. A distinct open must be busy.
        XCTAssertThrowsError(try DeviceResourceLock(request, directory: directory)) { XCTAssertEqual($0 as? SupportStorageError, .busy) }
        let legacy = open(directory.appendingPathComponent("controller.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        defer { close(legacy) }
        XCTAssertEqual(flock(legacy, LOCK_EX | LOCK_NB), -1)
        XCTAssertThrowsError(try RapooQueryLock(directory: directory))
        close(live[1]); live[1] = -1
        let output = try await task.value
        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "liveness-eof\n")
        _ = try DeviceResourceLock(request, directory: directory)
    }
    func testActualParentLossClosesOnlyParentWriterAndCleansDescendant() async throws {
        let spec = try await AdapterFixture.specification(["parent-loss", "normal"])
        let output = try await ProcessRunner.runStructured(spec)
        XCTAssertEqual(output.termination, .signaled); XCTAssertEqual(output.signal, SIGKILL)
        XCTAssertTrue(output.cleanupConfirmed)
        let lines = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let child = try XCTUnwrap(lines.first.flatMap { Int32($0.dropFirst("descendant:".count)) })
        XCTAssertTrue(lines.contains("parent-eof:\(child)"))
        // Foundation only: actual support-host/worker death and receipt paths require W5 hidden modes.
        for _ in 0..<100 where kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(kill(child, 0), -1)
    }
}
