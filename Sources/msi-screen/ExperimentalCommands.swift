import Foundation
import MSIScreenCore

func dispatchInternalSupportMode(_ arguments: [String]) async -> Int32? {
    await AdapterProcessHost.runInternalMode(arguments)
}

let experimentalCommandNames = [
    "devices list", "devices inspect ID", "devices read ID", "devices request", "devices support-request ID",
    "support request UUID", "support list", "support validate PATH",
    "support install PATH --request UUID --expected-digest SHA --expected-revision N [--replace-binding ID --expected-active-digest SHA]",
    "support bind PACKAGE --digest SHA --device ID --expected-revision N [--replace-binding ID --expected-active-digest SHA] [--dry-run]",
    "support disable BINDING --expected-digest SHA --expected-revision N [--dry-run]",
    "support activate BINDING --digest SHA --expected-active-digest SHA --expected-revision N [--dry-run]",
    "support remove PACKAGE --digest SHA --expected-revision N [--dry-run]", "support receipt UUID"
]
let experimentalHelp = experimentalCommandNames.map { "msi-screen " + $0 }.joined(separator: "\n") + """

Experimental commands are local-only; --machine and unknown/duplicate flags are rejected before I/O.
IDs select exact endpoint IDs from devices list, never record IDs, ordinals or prefixes.
devices request reads one strict JSON object (maximum 256 KiB) on stdin:
  {"schema":1,"kind":"plan","observation":OBSERVATION,"operation":OPERATION}
  {"schema":1,"kind":"apply","plan":AUTHENTICATED_PLAN}
Plan is hardware-free; obtain observations only through explicit devices read.
Lifecycle dry-runs publish nothing and execute no backend. support validate runs offline fixtures/selfTest.
Native adapters run as the user, not in a sandbox. Review source before validation/selfTest.
Installation/activation is not hardware qualification or permission to experiment.
Operational experimental Read/plan/apply remain unavailable until recorded qualification gates close.
Metadata lifecycle, receipt lookup and hardware-free validation/selfTest remain available; there is no production bypass.
Accepted mutations return receipts; unverified/cancelled results exit nonzero. Never retry an uncertain write.
Support requests install/check the bundled skill and return a prompt, without clipboard changes or agent launch.
Paste into your running agent. New skills may be available next turn; read the installed skill locally if not indexed.
"""
struct ExperimentalCapabilities: Encodable {
    let schema = 1
    let hostAPI = 1
    let engines = ["hid-feature-fields-v1"]
    let backends = ["profile", "nativeAdapter"]
    let commands = experimentalCommandNames
    let requestMaxBytes = 262144
    let stderrMaxBytes = 65536
    let planLifetimeMilliseconds = 300000
    let supportRequestLifetimeMilliseconds = 86400000
    let selfTestAndPlanTimeoutMilliseconds = 5000
    let readTimeoutMilliseconds = 10000
    let applyStageMaxMilliseconds = 30000
    let composedMaxMilliseconds = 120000
    let executionReady = false
    let executionReadinessGaps = ["x86_64MacOS13LifecycleUnverified", "responsibleLaunchClientUnverified"]
    let skills = AgentSkill.allCases
}

private func invalidArguments() -> DeviceContractError { .invalid("invalidArguments") }
private func digest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
    }
}
private func uuid(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value.lowercased() else { throw invalidArguments() }; return id
}
private struct PublicDeviceRequest: Decodable {
    let observation: DeviceObservation?
    let operation: DeviceOperation?
    let plan: DevicePlan?
    private enum Keys: String, CodingKey { case schema, kind, observation, operation, plan }
    private struct AnyKey: CodingKey { let stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int? { nil }; init?(intValue: Int) { nil } }
    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self), c = try decoder.container(keyedBy: Keys.self)
        guard try c.decode(Int.self, forKey: .schema) == 1 else { throw DeviceContractError.invalid("unsupportedSchema") }
        switch try c.decode(String.self, forKey: .kind) {
        case "plan":
            guard Set(raw.allKeys.map(\.stringValue)) == Set(["schema", "kind", "observation", "operation"]) else { throw invalidArguments() }
            observation = try c.decode(DeviceObservation.self, forKey: .observation); operation = try c.decode(DeviceOperation.self, forKey: .operation); plan = nil
        case "apply":
            guard Set(raw.allKeys.map(\.stringValue)) == Set(["schema", "kind", "plan"]) else { throw invalidArguments() }
            plan = try c.decode(DevicePlan.self, forKey: .plan); observation = nil; operation = nil
        default: throw invalidArguments()
        }
    }
}
private func readPublicRequest() throws -> PublicDeviceRequest {
    var bytes = Data()
    while let part = try FileHandle.standardInput.read(upToCount: min(16384, StrictJSON.byteLimit + 1 - bytes.count)), !part.isEmpty {
        bytes.append(part)
        guard bytes.count <= StrictJSON.byteLimit else { throw DeviceContractError.invalid("invalidUTF8OrSize") }
    }
    return try StrictJSON.decode(PublicDeviceRequest.self, from: bytes)
}
private struct ParsedExperimentalCommand {
    let group: String
    let command: String
    let operand: String?
    let flags: [String: String]
    let dryRun: Bool
    let request: PublicDeviceRequest?
    init(_ args: [String]) throws {
        guard !args.contains(where: { $0 == "--machine" || $0.hasPrefix("--machine=") }) else { throw DeviceContractError.invalid("remoteNotSupported") }
        guard args.count >= 2 else { throw invalidArguments() }
        group = args[0]; command = args[1]
        let needsOperand: Bool
        var required: Set<String> = [], optional: Set<String> = []
        var allowsDryRun = false
        switch (group, command) {
        case ("devices", "list"), ("devices", "request"), ("support", "list"): needsOperand = false
        case ("devices", "inspect"), ("devices", "read"), ("devices", "support-request"), ("support", "request"), ("support", "receipt"), ("support", "validate"): needsOperand = true
        case ("support", "install"):
            needsOperand = true; required = ["--request", "--expected-digest", "--expected-revision"]
            optional = ["--replace-binding", "--expected-active-digest"]
        case ("support", "bind"):
            needsOperand = true; required = ["--digest", "--device", "--expected-revision"]
            optional = ["--replace-binding", "--expected-active-digest"]; allowsDryRun = true
        case ("support", "disable"):
            needsOperand = true; required = ["--expected-digest", "--expected-revision"]; allowsDryRun = true
        case ("support", "activate"):
            needsOperand = true; required = ["--digest", "--expected-active-digest", "--expected-revision"]; allowsDryRun = true
        case ("support", "remove"):
            needsOperand = true; required = ["--digest", "--expected-revision"]; allowsDryRun = true
        default: throw invalidArguments()
        }
        var index = 2
        if needsOperand {
            guard index < args.count, !args[index].hasPrefix("-"), !args[index].isEmpty else { throw invalidArguments() }
            operand = args[index]; index += 1
        } else { operand = nil }
        var parsed: [String: String] = [:], dry = false
        while index < args.count {
            let key = args[index]
            if key == "--dry-run" {
                guard allowsDryRun && !dry else { throw invalidArguments() }; dry = true; index += 1; continue
            }
            guard required.union(optional).contains(key), parsed[key] == nil, index + 1 < args.count,
                  !args[index + 1].hasPrefix("-"), !args[index + 1].isEmpty else { throw invalidArguments() }
            parsed[key] = args[index + 1]; index += 2
        }
        guard required.isSubset(of: Set(parsed.keys)),
              (parsed["--replace-binding"] == nil) == (parsed["--expected-active-digest"] == nil) || command == "activate" else { throw invalidArguments() }
        for key in ["--digest", "--expected-digest", "--expected-active-digest"] {
            if let value = parsed[key], !digest(value) { throw invalidArguments() }
        }
        if let value = parsed["--expected-revision"] {
            guard value.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(value) != nil else { throw invalidArguments() }
        }
        if let value = parsed["--device"], !digest(value) { throw invalidArguments() }
        if let value = parsed["--replace-binding"], !identifier(value) { throw invalidArguments() }
        if let value = parsed["--request"] { _ = try uuid(value) }
        if let operand {
            if group == "devices" { guard digest(operand) else { throw invalidArguments() } }
            else if ["request", "receipt"].contains(command) { _ = try uuid(operand) }
            else if ["validate", "install"].contains(command) {
                guard operand.hasPrefix("/"), operand.utf8.count <= 4096, !operand.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalidArguments() }
            } else {
                guard identifier(operand) else { throw invalidArguments() }
                if ["bind", "remove"].contains(command) {
                    guard operand.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}\z"#, options: .regularExpression) != nil else { throw invalidArguments() }
                }
            }
        }
        flags = parsed; dryRun = dry
        // Decode bounded stdin before constructing roots, inventory, host or SSH clients.
        request = group == "devices" && command == "request" ? try readPublicRequest() : nil
    }
    var revision: UInt64 { UInt64(flags["--expected-revision"]!)! }
    var replacement: SupportBindingReplacement? {
        get throws {
            guard let id = flags["--replace-binding"] else { return nil }
            return try SupportBindingReplacement(bindingID: id, expectedActiveDigest: flags["--expected-active-digest"]!)
        }
    }
}
private func publicEmit<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try DevicePublicJSON.data(value)); FileHandle.standardOutput.write(Data([10]))
}

func dispatchExperimentalCommand(_ args: [String]) async -> Int32? {
    guard args.first == "devices" || args.first == "support" else { return nil }
    do {
        // Help is side-effect free, but remote flags never get a parsing escape hatch.
        if args.contains(where: { $0 == "--machine" || $0.hasPrefix("--machine=") }) { throw DeviceContractError.invalid("remoteNotSupported") }
        if args == [args[0], "--help"] { print(experimentalHelp); return 0 }
        if args.count == 3 && args[2] == "--help" && experimentalCommandNames.contains(where: { $0.split(separator: " ").prefix(2).map(String.init) == Array(args.prefix(2)) }) {
            print(experimentalHelp); return 0
        }
        var args = args
        var fixture: DeviceSupportVerificationFixture?
        var fixtureCommand: ParsedExperimentalCommand?
        if args.contains("--support-fixture-receipt") || args.contains("--support-fixture-nonce") {
            var values: [String: String] = [:], remaining: [String] = [], index = 0
            while index < args.count {
                let key = args[index]
                if ["--support-fixture-receipt", "--support-fixture-nonce"].contains(key) {
                    guard values[key] == nil, index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw invalidArguments() }
                    values[key] = args[index + 1]; index += 2
                } else { remaining.append(key); index += 1 }
            }
            guard let path = values["--support-fixture-receipt"], let nonce = values["--support-fixture-nonce"] else { throw invalidArguments() }
            // Validate the public command before touching any fixture state.
            fixtureCommand = try ParsedExperimentalCommand(remaining)
            fixture = try DeviceSupportVerificationFixture(receiptPath: path, nonce: nonce)
            FileHandle.standardError.write(Data((DeviceSupportVerificationFixture.label + "\n").utf8))
            args = remaining
        }
        let parsed = try fixtureCommand ?? ParsedExperimentalCommand(args)
        let registry = try fixture?.registry ?? SupportRegistry()
        func inventory() async throws -> DeviceInventorySnapshot {
            if let fixture { return try await fixture.snapshot() }
            return try await MacDeviceInventoryReader(identity: registry.inventoryIdentity()).snapshot()
        }
        func coordinator() throws -> DeviceControlCoordinator {
            if let fixture { return try fixture.coordinator() }
            return try DeviceControlCoordinator(registry: registry)
        }
        func supportRequest() throws -> DeviceSupportRequest {
            if let fixture { return fixture.supportRequest() }
            return try DeviceSupportRequest(registry: registry)
        }
        let installer = SupportPackageInstaller(registry: registry)
        switch (parsed.group, parsed.command) {
        case ("devices", "list"):
            try publicEmit(await inventory())
        case ("devices", "inspect"):
            let inventory = try await inventory()
            let (record, endpoint) = try DeviceSupportRequest.selectedEndpoint(parsed.operand!, in: inventory, requireEligible: false)
            let metadata = Swift.Result { try registry.snapshot() }
            let usableMetadata = try (try? metadata.get()) ?? SupportRegistrySnapshot()
            let resolution = DeviceSupportResolver.resolve(endpoint: endpoint, snapshot: inventory, registry: usableMetadata)
            let bindings = usableMetadata.bindings.filter { $0.selector.physicalDomainID == endpoint.physicalDomainID }
            let binding = bindings.count == 1 ? bindings[0] : nil
            var descriptor: DeviceDescriptor?, reason: String?
            if let binding {
                do { descriptor = try installer.descriptor(packageID: binding.packageID, digest: binding.digest) }
                catch { reason = DevicePublicJSON.errorCode(error) }
            }
            if case .failure = metadata { reason = "corruptRegistry" }
            let state: String
            switch resolution {
            case .builtInCandidate: state = "builtInCandidate"
            case .builtInVerified: state = "builtInVerified"
            case .experimental: state = "experimental"
            case .unconfigured: state = "unconfigured"
            case .collision: state = "collision"
            case .disabled(let why): state = "disabled"; reason = reason ?? why
            }
            struct Inspection: Encodable {
                let schema = 1; let deviceID: String; let record: DeviceRecord; let endpoint: DeviceEndpoint
                let support: String; let binding: SupportBinding?; let descriptor: DeviceDescriptor?; let reason: String?
                let executionReady: Bool
            }
            try publicEmit(Inspection(deviceID: endpoint.id, record: record, endpoint: endpoint, support: state, binding: binding,
                descriptor: descriptor, reason: reason, executionReady: installer.executionReady))
        case ("devices", "read"):
            try publicEmit(await coordinator().read(deviceID: parsed.operand!))
        case ("devices", "request"):
            let coordinator = try coordinator(), request = parsed.request!
            if let plan = request.plan {
                let receipt = try await coordinator.apply(plan: plan)
                if receipt.verified { try publicEmit(receipt); return 0 }
                FileHandle.standardOutput.write(try DevicePublicJSON.unverified(receipt)); FileHandle.standardOutput.write(Data([10])); return 1
            }
            try publicEmit(await coordinator.plan(observation: request.observation!, request: request.operation!))
        case ("devices", "support-request"):
            try publicEmit(await supportRequest().prepare(deviceID: parsed.operand!))
        case ("support", "request"):
            try publicEmit(await supportRequest().resolve(uuid(parsed.operand!)))
        case ("support", "list"): try publicEmit(installer.list())
        case ("support", "validate"):
            let validated: ValidatedSupportPackage
            if let fixture { validated = try await fixture.validate(source: URL(fileURLWithPath: parsed.operand!)) }
            else { validated = try await installer.validate(source: URL(fileURLWithPath: parsed.operand!)) }
            struct Validation: Encodable { let schema = 1; let packageID: String; let digest: String; let validated = true; let deviceVerified = false }
            try publicEmit(Validation(packageID: validated.manifest.id, digest: validated.digest))
        case ("support", "install"):
            if let fixture {
                try publicEmit(await fixture.install(source: URL(fileURLWithPath: parsed.operand!), expectedDigest: parsed.flags["--expected-digest"]!, expectedRevision: parsed.revision,
                    requestID: uuid(parsed.flags["--request"]!), replacement: parsed.replacement))
                return 0
            }
            try publicEmit(await installer.install(source: URL(fileURLWithPath: parsed.operand!), expectedDigest: parsed.flags["--expected-digest"]!,
                expectedRevision: parsed.revision, requestID: uuid(parsed.flags["--request"]!), replacement: parsed.replacement))
        case ("support", "bind"):
            if let fixture {
                try publicEmit(fixture.bind(packageID: parsed.operand!, digest: parsed.flags["--digest"]!, deviceID: parsed.flags["--device"]!, expectedRevision: parsed.revision, replacement: parsed.replacement, dryRun: parsed.dryRun))
                return 0
            }
            try publicEmit(await installer.bind(packageID: parsed.operand!, digest: parsed.flags["--digest"]!, deviceID: parsed.flags["--device"]!,
                expectedRevision: parsed.revision, replacement: parsed.replacement, dryRun: parsed.dryRun))
        case ("support", "disable"):
            if let fixture {
                try publicEmit(fixture.changeBinding(bindingID: parsed.operand!, expectedDigest: parsed.flags["--expected-digest"]!, digest: nil, expectedRevision: parsed.revision, dryRun: parsed.dryRun)); return 0
            }
            try publicEmit(await installer.disable(bindingID: parsed.operand!, expectedDigest: parsed.flags["--expected-digest"]!, expectedRevision: parsed.revision, dryRun: parsed.dryRun))
        case ("support", "activate"):
            if let fixture {
                try publicEmit(fixture.changeBinding(bindingID: parsed.operand!, expectedDigest: parsed.flags["--expected-active-digest"]!, digest: parsed.flags["--digest"]!, expectedRevision: parsed.revision, dryRun: parsed.dryRun)); return 0
            }
            try publicEmit(await installer.activate(bindingID: parsed.operand!, digest: parsed.flags["--digest"]!, expectedActiveDigest: parsed.flags["--expected-active-digest"]!, expectedRevision: parsed.revision, dryRun: parsed.dryRun))
        case ("support", "remove"):
            if let fixture { try publicEmit(fixture.remove(packageID: parsed.operand!, digest: parsed.flags["--digest"]!, expectedRevision: parsed.revision, dryRun: parsed.dryRun)); return 0 }
            try publicEmit(installer.remove(packageID: parsed.operand!, digest: parsed.flags["--digest"]!, expectedRevision: parsed.revision, dryRun: parsed.dryRun))
        case ("support", "receipt"):
            guard let receipt = try coordinator().receipt(operationID: uuid(parsed.operand!)) else { throw DeviceContractError.invalid("absentReceipt") }
            try publicEmit(receipt); return receipt.verified ? 0 : 1
        default: throw invalidArguments()
        }
        return 0
    } catch {
        FileHandle.standardOutput.write(DevicePublicJSON.error(error)); FileHandle.standardOutput.write(Data([10])); return 1
    }
}
