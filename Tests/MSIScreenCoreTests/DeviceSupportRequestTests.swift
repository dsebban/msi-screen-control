import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class U4Inventory: DeviceInventoryClient, @unchecked Sendable {
    private let lock = NSLock()
    private var value: DeviceInventorySnapshot
    init(_ value: DeviceInventorySnapshot) { self.value = value }
    func set(_ value: DeviceInventorySnapshot) { lock.lock(); self.value = value; lock.unlock() }
    private func current() -> DeviceInventorySnapshot { lock.lock(); defer { lock.unlock() }; return value }
    func snapshot() async throws -> DeviceInventorySnapshot { current() }
}
final class DeviceSupportRequestTests: XCTestCase {
    func fixture() throws -> (URL, SupportRegistry, U4Inventory, DeviceEndpoint) {
        let root = URL(fileURLWithPath: "/private/tmp/msi-u4-request-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let registry = try SupportRegistry(home: root.appendingPathComponent("private-daniel-support"))
        let helper = DeviceInventoryTests()
        let snapshot = try helper.build([], [helper.usb(serial: "PRIVATE-SERIAL")], [helper.hid(30, serial: "PRIVATE-SERIAL", usage: 5)], key: registry.inventoryIdentity())
        let endpoint = try helper.endpoint(snapshot, kind: .hid)
        return (root, registry, U4Inventory(snapshot), endpoint)
    }
    var bundledSource: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("skills/write-addhoc-support")
    }
    func request(_ root: URL, _ registry: SupportRegistry, _ inventory: U4Inventory, now: @escaping () -> Int64 = { 1000 }, source: URL? = nil) -> DeviceSupportRequest {
        DeviceSupportRequest(registry: registry, inventory: inventory, installer: AgentSkillInstallation(registry: registry),
            source: { source ?? self.bundledSource }, destination: { root.appendingPathComponent("skills/write-addhoc-support") }, now: now)
    }
    func testPrepareAndResolveExportOnlySafeFactsAndExactEndpointNotRecordID() async throws {
        let (root, registry, inventory, endpoint) = try fixture(), client = request(root, registry, inventory)
        let prepared = try await client.prepare(deviceID: endpoint.id)
        let resolved = try await client.resolve(prepared.requestID)
        XCTAssertEqual(resolved.deviceID, endpoint.id); XCTAssertEqual(resolved.facts.vendorID, 1)
        let snapshot = try await inventory.snapshot()
        let output = String(decoding: try DevicePublicJSON.data(prepared) + DevicePublicJSON.data(resolved) + DevicePublicJSON.data(snapshot), as: UTF8.self)
        for secret in ["PRIVATE-SERIAL", "private user's device", "private keyboard", "private-boot", root.path, "registryID", "usbDeviceID", "address"] {
            XCTAssertFalse(output.contains(secret), "Leaked \(secret)")
        }
        XCTAssertTrue(prepared.prompt.contains("$write-addhoc-support")); XCTAssertTrue(prepared.prompt.contains("~/.agents/skills/write-addhoc-support/SKILL.md"))
        let requestFile = registry.home.appendingPathComponent("requests/" + prepared.requestID.uuidString.lowercased() + ".json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: requestFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let record = try XCTUnwrap(snapshot.devices.first { $0.endpoints.contains { $0.id == endpoint.id } })
        if record.id != endpoint.id { XCTAssertThrowsError(try DeviceSupportRequest.selectedEndpoint(record.id, in: snapshot)) }
        let repeated = try await client.prepare(deviceID: endpoint.id)
        XCTAssertEqual(repeated.skillStatus, .unchanged)
    }
    func testExpiredWrongHostTamperedAndReconnectedRequestsNeverRetarget() async throws {
        let (root, registry, inventory, endpoint) = try fixture()
        let prepared = try await request(root, registry, inventory).prepare(deviceID: endpoint.id)
        do { _ = try await request(root, registry, inventory, now: { 86401000 }).resolve(prepared.requestID); XCTFail("Expired request accepted") }
        catch { XCTAssertEqual(error as? DeviceContractError, .invalid("expiredRequest")) }
        let other = try SupportRegistry(home: root.appendingPathComponent("other-host")); _ = try other.installationKey()
        let name = prepared.requestID.uuidString.lowercased() + ".json"
        try FileManager.default.copyItem(at: registry.home.appendingPathComponent("requests/" + name), to: other.home.appendingPathComponent("requests/" + name))
        do { _ = try await request(root, other, inventory).resolve(prepared.requestID); XCTFail("Wrong host accepted") }
        catch { XCTAssertEqual(error as? DeviceContractError, .invalid("wrongHostRequest")) }
        let original = try Data(contentsOf: registry.home.appendingPathComponent("requests/" + name))
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]; object["category"] = "pointer"
        try JSONSerialization.data(withJSONObject: object).write(to: registry.home.appendingPathComponent("requests/" + name))
        do { _ = try await request(root, registry, inventory).resolve(prepared.requestID); XCTFail("Tampered request accepted") }
        catch { XCTAssertEqual(error as? DeviceContractError, .invalid("wrongHostRequest")) }
        try original.write(to: registry.home.appendingPathComponent("requests/" + name))
        let helper = DeviceInventoryTests()
        inventory.set(try helper.build([], [helper.usb(11, serial: "PRIVATE-SERIAL")], [helper.hid(31, usb: 11, serial: "PRIVATE-SERIAL", usage: 5)], key: registry.inventoryIdentity()))
        do { _ = try await request(root, registry, inventory).resolve(prepared.requestID); XCTFail("Reconnect silently retargeted") }
        catch { XCTAssertTrue(["staleRequest", "absentEndpoint"].contains(DevicePublicJSON.errorCode(error))) }
    }
    func testConflictingSkillOrFailedSelectionCreatesNoRequestAndPreservesUserBytes() async throws {
        let (root, registry, inventory, endpoint) = try fixture(), client = request(root, registry, inventory)
        _ = try await client.prepare(deviceID: endpoint.id)
        let edited = root.appendingPathComponent("skills/write-addhoc-support/SKILL.md")
        try Data("private user edit".utf8).write(to: edited)
        let before = try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("requests").path)
        do { _ = try await client.prepare(deviceID: endpoint.id); XCTFail("Conflicting skill accepted") }
        catch { XCTAssertEqual(error as? AgentSkillInstallError, .conflict) }
        XCTAssertEqual(try String(contentsOf: edited), "private user edit")
        do { _ = try await client.prepare(deviceID: String(endpoint.id.prefix(8))); XCTFail("Prefix accepted") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("requests").path), before)
    }
    func testExpiredPruningLeavesUnfamiliarAndLinkedRequestFilesUntouched() async throws {
        let (root, registry, inventory, endpoint) = try fixture()
        let old = try await request(root, registry, inventory).prepare(deviceID: endpoint.id)
        let directory = registry.home.appendingPathComponent("requests"), unfamiliar = directory.appendingPathComponent("unfamiliar.json")
        try Data("keep".utf8).write(to: unfamiliar)
        let linked = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        XCTAssertEqual(symlink("missing", linked.path), 0)
        _ = try await request(root, registry, inventory, now: { 86401001 }).prepare(deviceID: endpoint.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.requestID.uuidString.lowercased() + ".json").path))
        XCTAssertEqual(try String(contentsOf: unfamiliar), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path), "missing")
    }
    func testPublicProjectionPreservesLegalMetadataSpelledProtocolIDsAndAuthentication() throws {
        let (_, registry, _, _) = try fixture(), identity = try U3Fixture.identity()
        let choices = try [DeviceChoice(id: "name", title: "PRIVATE_LABEL"), DeviceChoice(id: "title", title: "PRIVATE_LABEL")]
        let layout = try DeviceLayoutDefinition(inputs: [DeviceChoice(id: "reason", title: "PRIVATE_INPUT")],
            templates: [DeviceLayoutTemplate(id: "name", title: "PRIVATE_TEMPLATE", slots: [DeviceLayoutSlot(id: "code", rectangle: DeviceRectangle(x: 0, y: 0, width: 10000, height: 10000, z: 0), allowedInputIDs: ["reason"])], distinctInputs: false)],
            options: [DeviceLayoutOption(id: "unit", choices: choices)])
        let mapping = try DeviceInputMappingDefinition(controls: [DeviceChoice(id: "name", title: "PRIVATE_CONTROL"), DeviceChoice(id: "unit", title: "PRIVATE_CONTROL")], actions: choices)
        let scope = try DeviceMutationScope(id: "code", observedFields: ["name", "title", "reason"], requiredGuardFields: [], writableFields: ["name", "title", "reason"], coupledFields: [], preservedFields: [], preservationCommitment: nil)
        let definitions: [(String, DeviceCapabilityDefinition)] = [("name", .integer(try DeviceIntegerDefinition(minimum: 0, maximum: 100, step: 1, unit: "PRIVATE_UNIT"))), ("title", .layout(layout)), ("reason", .inputMapping(mapping))]
        let caps = try definitions.enumerated().map { index, value in try DeviceCapability(id: value.0, title: "PRIVATE_CAPABILITY", category: .setting, presentationOrder: index,
            access: .readWrite, definition: value.1, mutationScopeID: "code", evidenceIDs: [], executionBudgetMilliseconds: 1000, settlingMilliseconds: 0,
            verification: DeviceVerification(kind: .readback, guardFieldIDs: [], ownershipRequired: false), unavailableReason: nil) }
        let descriptor = try DeviceDescriptor(capabilities: caps, scopes: [scope], evidence: [], supportsLayoutAndUSB: false)
        let layoutValue = try DeviceLayoutValue(templateID: "name", slots: ["code": "reason"], options: ["unit": "name"])
        let values: [String: DeviceValue] = ["name": .integer(5), "title": .layout(layoutValue), "reason": .inputMapping(["name": "title", "unit": "name"])]
        let state = try DeviceBackendState(identity: identity, values: values, fields: values, preservation: [:])
        let authentication = DeviceContractAuthentication(key: try registry.installationKey())
        let observation = try authentication.observation(state: state, descriptor: descriptor, epoch: 0, now: 1)
        let encoded = try DevicePublicJSON.data(observation)
        XCTAssertEqual(encoded, try StrictJSON.canonical(observation), "Protocol map keys are data, not metadata labels")
        if let roundTrip = try? StrictJSON.decode(DeviceObservation.self, from: encoded) {
            XCTAssertEqual(roundTrip, observation); XCTAssertNoThrow(try authentication.verify(roundTrip))
        } else { XCTFail("Public observation no longer decodes") }
        let changed = try DeviceLayoutValue(templateID: "name", slots: ["code": "reason"], options: ["unit": "title"])
        let operation = try U3Fixture.operation("title", .layout(changed), kind: .setLayout)
        let stage = try DevicePlanStage(id: "configuration", operation: operation, scopeIDs: ["code"], budgetMilliseconds: 1000)
        let plan = try authentication.signedPlan(operationID: UUID(), identity: identity, revision: 0, epoch: 0, commitments: observation.scopeCommitments,
            operation: operation, stages: [stage], changes: ["title": DeviceValueChange(before: .layout(layoutValue), after: .layout(changed))], now: 1)
        let planJSON = try DevicePublicJSON.data(plan)
        XCTAssertEqual(planJSON, try StrictJSON.canonical(plan))
        if let roundTrip = try? StrictJSON.decode(DevicePlan.self, from: planJSON) {
            XCTAssertEqual(roundTrip, plan); XCTAssertNoThrow(try authentication.verify(roundTrip))
        } else { XCTFail("Public plan no longer decodes") }
        for value in values.values {
            XCTAssertEqual(try StrictJSON.decode(DeviceValue.self, from: DevicePublicJSON.data(value)), value)
        }
        let descriptorJSON = String(decoding: try DevicePublicJSON.data(descriptor), as: UTF8.self)
        XCTAssertFalse(descriptorJSON.contains("PRIVATE"), "Preserving protocol IDs must not export labels/units")
    }
    func testTrustedHostErrorsKeepDistinctSafePublicCodesInsteadOfRejectedManifest() throws {
        let (root, _, _, _) = try fixture()
        let unsafe = root.appendingPathComponent("unsafe-host")
        try Data("not executable code".utf8).write(to: unsafe)
        try FileManager.default.setAttributes([.posixPermissions: 0o602], ofItemAtPath: unsafe.path)
        do { _ = try AdapterHostIdentity.capture(unsafe); XCTFail("Unsafe host accepted") }
        catch {
            // Include the host post-run failure wrapper: retaining cleanup
            // evidence must not reclassify a trusted host error as protocol noise.
            let data = DevicePublicJSON.error(AdapterProcessHost.failure(error, dispatched: false)), json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(json["code"] as? String, "hostUnavailable")
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(root.path))
        }
        for (internalCode, publicCode) in [("hostSignatureMismatch", "hostSignatureChanged"), ("hostIntegrityChanged", "hostBuildChanged"), ("clipboardUnavailable", "clipboardUnavailable")] {
            let data = DevicePublicJSON.error(DeviceContractError.invalid(internalCode))
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as! [String: Any])["code"] as? String, publicCode)
            if internalCode.hasPrefix("host") {
                let failure = AdapterProcessHost.failure(DeviceContractError.invalid(internalCode), dispatched: false)
                XCTAssertEqual(failure.code, publicCode); XCTAssertFalse(failure.dispatched)
            }
        }
        let privateError = DevicePublicJSON.error(DeviceContractError.invalid("/Users/private/diagnostic"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: privateError) as! [String: Any])["code"] as? String, "invalidRequest")
        XCTAssertFalse(String(decoding: privateError, as: UTF8.self).contains("/Users/private"))
    }

    func testPublicPartialInventoryPreservesClosedSourceFailuresWithoutPrivateDiagnostics() throws {
        for code in [InventoryFailureCode.unavailable, .denied, .changedDuringEnumeration, .nonConsoleSession, .identityUnavailable] {
            let snapshot = try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: [],
                displays: .failed(code: code, message: "PRIVATE_USER /Users/private/secret"), usb: .complete, hid: .complete)
            let bytes = try DevicePublicJSON.data(snapshot)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
            if let result = try? StrictJSON.decode(DeviceInventorySnapshot.self, from: bytes) {
                XCTAssertEqual(result.displays, .failed(code: code, message: "Inventory source incomplete")); XCTAssertEqual(result.usb, .complete)
            } else { XCTFail("Public partial inventory no longer decodes for \(code)") }
        }
    }
    func testPassiveInspectionRetainsIncompleteFactsWhileBindingRefusesThem() throws {
        let helper = DeviceInventoryTests()
        let snapshot = try helper.build([], [helper.usb()], [helper.hid(30)], usbOutcome: .failed(code: .denied, message: "PRIVATE_PATH"))
        let endpoint = try helper.endpoint(snapshot, kind: .hid)
        XCTAssertEqual(try DeviceSupportRequest.selectedEndpoint(endpoint.id, in: snapshot, requireEligible: false).1, endpoint)
        XCTAssertThrowsError(try DeviceSupportRequest.selectedEndpoint(endpoint.id, in: snapshot))
    }
    func testPackagedOwnResourceLookupAndSourceBuildMissingBundle() throws {
        let executable = URL(fileURLWithPath: try U3Fixture.host().path)
        if executable.deletingLastPathComponent().lastPathComponent == "MacOS" {
            let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AgentSkills/write-addhoc-support")
            XCTAssertNoThrow(try AgentSkillTree.read(resources, source: true))
            XCTAssertEqual(try AgentSkillInstallation.bundledSkill(.writeSupport, executable: executable), resources)
        } else { XCTAssertThrowsError(try AgentSkillInstallation.bundledSkill(.writeSupport, executable: executable)) }
    }

    func testActualCLIRejectsEarlyAndReturnsPrivateSafeHistoricalUnverifiedReceiptWithoutDispatch() async throws {
        let (root, registry, _, _) = try fixture(), host = try U3Fixture.host()
        let notCreated = root.appendingPathComponent("must-not-be-created")
        func invoke(_ args: [String], input: Data? = nil, home: URL? = nil) async throws -> ProcessRunner.StructuredOutput {
            try await ProcessRunner.runStructured(.init(executable: URL(fileURLWithPath: host.path), arguments: args, timeout: 10, input: input,
                environment: ["MSI_SCREEN_SUPPORT_HOME": (home ?? registry.home).path, "MSI_SCREEN_AGENT_SKILLS_HOME": root.appendingPathComponent("isolated-skills").path]))
        }
        for args in [["devices", "list", "--machine", "PRIVATE_HOST"], ["support", "list", "--dry-run"],
                     ["support", "bind", "fixture", "--digest", String(repeating: "0", count: 64), "--device", "prefix", "--expected-revision", "0"],
                     ["support", "disable", "binding", "--expected-digest", String(repeating: "0", count: 64), "--expected-revision", "-1"]] {
            let output = try await invoke(args, home: notCreated)
            XCTAssertEqual(output.exitCode, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: notCreated.path))
            let text = String(decoding: output.stdout + output.stderr, as: UTF8.self)
            XCTAssertFalse(text.contains("PRIVATE_HOST")); XCTAssertFalse(text.contains(root.path))
        }
        let malformed = try await invoke(["devices", "request"], input: Data("{\"schema\":1,\"kind\":\"plan\",\"kind\":\"apply\"}".utf8), home: notCreated)
        XCTAssertEqual(malformed.exitCode, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: notCreated.path))
        let rejectedSource = root.appendingPathComponent("rejected-source")
        try FileManager.default.createDirectory(at: rejectedSource, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("{malformed PRIVATE_PATH".utf8).write(to: rejectedSource.appendingPathComponent("manifest.json"))
        let validationError = try await invoke(["support", "validate", rejectedSource.path])
        XCTAssertEqual(validationError.exitCode, 1)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: validationError.stdout) as? [String: Any])?["code"] as? String, "rejectedManifest")
        XCTAssertFalse(String(decoding: validationError.stdout + validationError.stderr, as: UTF8.self).contains("PRIVATE"))
        let listed = try await invoke(["devices", "list"]); XCTAssertTrue(listed.succeeded)
        let snapshot = try StrictJSON.decode(DeviceInventorySnapshot.self, from: listed.stdout)
        XCTAssertTrue(snapshot.devices.allSatisfy { $0.displayName == $0.kind.rawValue && $0.endpoints.allSatisfy { $0.address == nil } })
        let absent = String(repeating: "0", count: 64)
        XCTAssertFalse(snapshot.devices.flatMap(\.endpoints).contains { $0.id == absent })
        let readError = try await invoke(["devices", "read", absent]); XCTAssertEqual(readError.exitCode, 1)
        XCTAssertTrue(String(decoding: readError.stdout, as: UTF8.self).contains("absentEndpoint"))
        let authentication = DeviceContractAuthentication(key: try registry.installationKey()), identity = try U3Fixture.identity()
        let operation = try U3Fixture.operation("level", .integer(20)), time = Int64(Date().timeIntervalSince1970 * 1000)
        let stage = try DevicePlanStage(id: "configuration", operation: operation, scopeIDs: ["configuration"], budgetMilliseconds: 5000)
        let plan = try authentication.signedPlan(operationID: UUID(), identity: identity, revision: 0, epoch: 0,
            commitments: ["configuration": String(repeating: "0", count: 64)], operation: operation, stages: [stage], changes: [:], now: time)
        let receipt = try DeviceMutationReceipt(schema: 1, operationID: plan.operationID, identity: identity, before: ["level": .integer(5)], target: ["level": .integer(20)], after: nil,
            stages: [], failure: DeviceUnavailable(code: "PRIVATE_USER"), outcome: .unverified, writeMayHaveOccurred: true, verified: false)
        let record = DeviceJournalRecord(operationID: plan.operationID, planDigest: SupportPackageContent.hash(try StrictJSON.canonical(plan)), domainID: identity.domainID,
            acceptedAtMilliseconds: time, receipt: receipt, terminal: true)
        try registry.root.directory("receipts").atomicWrite(StrictJSON.canonical(record), name: "operation-" + plan.operationID.uuidString.lowercased() + ".json")
        struct Apply: Encodable { let schema = 1; let kind = "apply"; let plan: DevicePlan }
        let before = try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path)
        for args in [["support", "receipt", plan.operationID.uuidString], ["devices", "request"]] {
            let output = try await invoke(args, input: args.last == "request" ? StrictJSON.canonical(Apply(plan: plan)) : nil)
            XCTAssertEqual(output.exitCode, 1)
            let receiptBytes: Data
            if args.last == "request" {
                let envelope = try JSONSerialization.jsonObject(with: output.stdout) as! [String: Any]
                XCTAssertEqual(envelope["code"] as? String, "invalidRequest"); XCTAssertEqual(envelope["verified"] as? Bool, false)
                receiptBytes = try JSONSerialization.data(withJSONObject: envelope["receipt"]!, options: [.sortedKeys])
            } else { receiptBytes = output.stdout }
            let exported = try StrictJSON.decode(DeviceMutationReceipt.self, from: receiptBytes)
            XCTAssertEqual(exported.operationID, plan.operationID); XCTAssertFalse(exported.verified); XCTAssertTrue(exported.writeMayHaveOccurred)
            XCTAssertEqual(exported.failure?.code, "invalidRequest")
            XCTAssertFalse(String(decoding: output.stdout + output.stderr, as: UTF8.self).contains("PRIVATE"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registry.home.appendingPathComponent("invocations").path), before)
        print("U4 actual public CLI: early parser, passive redacted list, absent read, historical receipt/apply nonzero; zero backend invocation")
    }

    func testActualInspectReportsDisabledAndCollisionWithoutPickingFirstDescriptor() async throws {
        let nonce = UUID(), root = URL(fileURLWithPath: "/private/tmp/msi-support-fixture-" + UUID().uuidString)
        let directory = try SupportDirectory.root(root), content = try U3Fixture.content()
        let receipt: [String: Any] = ["schema": 1, "owner": "msi-screen-verifier-support-v1", "nonce": nonce.uuidString,
            "expiresAtMilliseconds": Int64(Date().timeIntervalSince1970 * 1000) + 600000, "packageDigests": [content.digest],
            "adapterDigest": String(repeating: "0", count: 64), "bundleIdentifier": "com.danielsivan.msi-screen.support-fixture." + nonce.uuidString.lowercased()]
        try directory.atomicWrite(JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), name: "receipt.json")
        try directory.atomicWrite(Data("{\"schema\":1,\"attachment\":1,\"connected\":true}".utf8), name: "attachment.json")
        _ = try directory.directory("skills", create: true)
        _ = try directory.directory("leases", create: true)
        let fixture = try DeviceSupportVerificationFixture(receiptPath: root.appendingPathComponent("receipt.json").path, nonce: nonce.uuidString, requireEnvironment: false)
        let snapshot = try await fixture.snapshot()
        let endpoint = try XCTUnwrap(snapshot.devices.flatMap(\.endpoints).first)
        let source = try SupportDirectory.root(root.appendingPathComponent("source")); try content.copy(to: source)
        let installed = try SupportPackageInstaller(registry: fixture.registry).stageInactive(source: source.url, expectedDigest: content.digest, expectedRevision: 0)
        let selector = try DeviceEndpoint(kind: endpoint.kind, id: endpoint.id, identity: endpoint.identity, physicalDomainID: endpoint.physicalDomainID, incarnationID: endpoint.incarnationID, address: nil)
        let disabled = try SupportBinding(id: "disabled", selector: selector, packageID: content.manifest.id, digest: content.digest, enabled: false)
        let before: SupportRegistrySnapshot
        do {
            let lock = try fixture.registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
            before = try fixture.registry.compareAndSwap(expectedRevision: installed.revision, packages: installed.packages, bindings: [disabled])
        }
        let host = try U3Fixture.host()
        func inspect() async throws -> [String: Any] {
            let output = try await ProcessRunner.runStructured(.init(executable: URL(fileURLWithPath: host.path), arguments: ["devices", "inspect", endpoint.id,
                "--support-fixture-receipt", root.appendingPathComponent("receipt.json").path, "--support-fixture-nonce", nonce.uuidString], timeout: 10,
                environment: ["MSI_SCREEN_SUPPORT_HOME": fixture.registry.home.path, "MSI_SCREEN_AGENT_SKILLS_HOME": fixture.skillsHome.path]))
            XCTAssertTrue(output.succeeded, String(decoding: output.stdout + output.stderr, as: UTF8.self))
            return try JSONSerialization.jsonObject(with: output.stdout) as! [String: Any]
        }
        let first = try await inspect()
        XCTAssertEqual(first["support"] as? String, "disabled"); XCTAssertEqual(first["reason"] as? String, "bindingDisabled")
        XCTAssertEqual((first["binding"] as? [String: Any])?["enabled"] as? Bool, false)
        do {
            let lock = try fixture.registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
            let other = try SupportBinding(id: "other", selector: selector, packageID: content.manifest.id, digest: content.digest, enabled: true)
            _ = try fixture.registry.compareAndSwap(expectedRevision: before.revision, packages: before.packages, bindings: [disabled, other])
        }
        let collision = try await inspect()
        XCTAssertEqual(collision["support"] as? String, "collision"); XCTAssertNil(collision["binding"]); XCTAssertNil(collision["descriptor"])
    }

    func testActualPublicObservationPlanReceiptAndErrorJSONKeepAuthenticationAndOmitPrivateText() throws {
        let (_, registry, _, _) = try fixture(), base = try U3Fixture.descriptor()
        let local = try DeviceCapability(id: "privateInfo", title: "PRIVATE-NAME", category: .information, presentationOrder: 30, access: .readOnly,
            definition: .text(DeviceTextDefinition(maximumUTF8Bytes: 128, exportPolicy: .localOnly, reviewEvidenceIDs: [])), mutationScopeID: "configuration", evidenceIDs: [],
            executionBudgetMilliseconds: 1000, settlingMilliseconds: 0, verification: DeviceVerification(kind: .readback, guardFieldIDs: [], ownershipRequired: false), unavailableReason: nil)
        let descriptor = try DeviceDescriptor(capabilities: base.capabilities + [local], scopes: base.scopes, evidence: base.evidence, supportsLayoutAndUSB: true)
        let executor = try HIDFeatureProfileExecutor(profile: U3Fixture.profile(), descriptor: base, identity: U3Fixture.identity(), transport: HIDFixtureTransport(profile: U3Fixture.profile(), reports: ["0": U3Fixture.baseline]))
        let initial = try executor.read(), state = try DeviceBackendState(identity: initial.identity, values: initial.values.merging(["privateInfo": .text("PRIVATE-SERIAL-NAME")]) { _, new in new },
            fields: initial.fields, preservation: ["private": "PRIVATE-PRESERVATION"])
        let authentication = DeviceContractAuthentication(key: try registry.installationKey())
        let observation = try authentication.observation(state: state, descriptor: descriptor, epoch: 0, now: 1)
        let encoded = try DevicePublicJSON.data(observation), roundTrip = try StrictJSON.decode(DeviceObservation.self, from: encoded)
        try authentication.verify(roundTrip); XCTAssertEqual(roundTrip, observation)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PRIVATE"))
        let operation = try U3Fixture.operation("level", .integer(20))
        let stage = try DevicePlanStage(id: "configuration", operation: operation, scopeIDs: ["configuration"], budgetMilliseconds: 5000)
        let plan = try authentication.signedPlan(operationID: UUID(), identity: state.identity, revision: 0, epoch: 0, commitments: observation.scopeCommitments,
            operation: operation, stages: [stage], changes: ["level": DeviceValueChange(before: .integer(5), after: .integer(20))], now: 1)
        try authentication.verify(StrictJSON.decode(DevicePlan.self, from: DevicePublicJSON.data(plan)))
        let receipt = try DeviceMutationReceipt(schema: 1, operationID: plan.operationID, identity: state.identity, before: observation.values, target: ["level": .integer(20)], after: nil,
            stages: [], failure: DeviceUnavailable(code: "PRIVATE_USER"), outcome: .unverified, writeMayHaveOccurred: true, verified: false)
        let output = String(decoding: try DevicePublicJSON.data(receipt) + DevicePublicJSON.data(descriptor) + DevicePublicJSON.error(DeviceContractError.invalid("PRIVATE_USER")), as: UTF8.self)
        XCTAssertFalse(output.contains("PRIVATE")); XCTAssertTrue(output.contains("invalidRequest"))
    }
}
