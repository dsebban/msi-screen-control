import CryptoKit
import Darwin
import Foundation

/// Private backend read/evidence, including informational capability values.
/// Only the explicit configuration projection participates in stale comparison;
/// the complete values remain available for observations/receipts. Never export
/// raw fields, preservation bytes or addresses.
struct DeviceBackendState: Codable, Equatable, Sendable {
    let identity: DeviceContractIdentity
    let values: [String: DeviceValue]
    let fields: [String: DeviceValue]
    let preservation: [String: String]
    let unavailable: [String: DeviceUnavailable]
    private enum CodingKeys: String, CodingKey { case identity, values, fields, preservation, unavailable }
    init(identity: DeviceContractIdentity, values: [String: DeviceValue], fields: [String: DeviceValue], preservation: [String: String], unavailable: [String: DeviceUnavailable] = [:]) throws {
        self.identity = identity; self.values = values; self.fields = fields; self.preservation = preservation; self.unavailable = unavailable; try validate()
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["identity", "values", "fields", "preservation", "unavailable"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(DeviceContractIdentity.self, forKey: .identity); values = try c.decode([String: DeviceValue].self, forKey: .values)
        fields = try c.decode([String: DeviceValue].self, forKey: .fields); preservation = try c.decode([String: String].self, forKey: .preservation)
        unavailable = try c.decode([String: DeviceUnavailable].self, forKey: .unavailable); try validate()
    }
    func validate() throws {
        try identity.validate()
        try requireContract(values.count <= 64 && fields.count <= 128 && preservation.count <= 64 && uniqueIDs(Array(values.keys))
            && uniqueIDs(Array(fields.keys)) && uniqueIDs(Array(preservation.keys)) && preservation.values.allSatisfy { $0.utf8.count <= 32768 }, "backendState")
        try values.values.forEach { try $0.validate() }; try fields.values.forEach { try $0.validate() }
        try requireContract(unavailable.count <= 64 && uniqueIDs(Array(unavailable.keys)) && Set(values.keys).isDisjoint(with: unavailable.keys), "backendUnavailable")
        try unavailable.values.forEach { try $0.validate() }
    }
    func validate(descriptor: DeviceDescriptor, identity: DeviceContractIdentity) throws {
        try validate(); try requireContract(self.identity == identity, "identityMismatch")
        // Explicit unavailable capabilities may be absent, never fake defaults.
        let ids = Set(descriptor.capabilities.map(\.id))
        try requireContract(Set(values.keys).union(unavailable.keys) == ids, "missingReadback")
        for cap in descriptor.capabilities {
            if let value = values[cap.id] { try requireContract(cap.unavailableReason == nil, "unavailableCapability"); try cap.definition.validate(value: value) }
        }
        try requireContract(Set(fields.keys).isSubset(of: Set(descriptor.scopes.flatMap(\.observedFields))), "scopeEvidence")
        for scope in descriptor.scopes where descriptor.capabilities.contains(where: { $0.mutationScopeID == scope.id && $0.access == .readWrite && values[$0.id] != nil }) {
            try requireContract(Set(scope.observedFields).isSubset(of: Set(fields.keys)), "scopeEvidence")
        }
    }
}
/// Shared semantic projection for scope commitments and every configuration
/// comparison. Read-only capability values/availability are information, unless
/// their underlying fields are explicitly declared as configuration in a scope.
/// Native opaque preservation is configuration evidence; profiles supply only
/// whole writable reports here, never unrelated read-only report bytes.
struct DeviceBackendConfiguration: Encodable, Equatable {
    let identity: DeviceContractIdentity
    let values: [String: DeviceValue]
    let unavailable: [String: DeviceUnavailable]
    let fields: [String: DeviceValue]
    let preservation: [String: String]
}
extension DeviceBackendState {
    func configuration(descriptor: DeviceDescriptor, scope: DeviceMutationScope? = nil) -> DeviceBackendConfiguration {
        let scopes = scope.map { [$0] } ?? descriptor.scopes
        let scopeIDs = Set(scopes.map(\.id)), fieldIDs = Set(scopes.flatMap(\.observedFields))
        let ids = Set(descriptor.capabilities.filter { $0.access == .readWrite && scopeIDs.contains($0.mutationScopeID) }.map(\.id))
        return DeviceBackendConfiguration(identity: identity, values: values.filter { ids.contains($0.key) },
            unavailable: unavailable.filter { ids.contains($0.key) }, fields: fields.filter { fieldIDs.contains($0.key) }, preservation: preservation)
    }
    func hasSameConfiguration(as other: DeviceBackendState, descriptor: DeviceDescriptor) -> Bool {
        configuration(descriptor: descriptor) == other.configuration(descriptor: descriptor)
    }
    func verifyTransition(to after: DeviceBackendState, operation: DeviceOperation, descriptor: DeviceDescriptor) throws {
        let beforeConfiguration = configuration(descriptor: descriptor), afterConfiguration = after.configuration(descriptor: descriptor)
        try requireContract(identity == after.identity && operation.target.matchesTarget(after.values[operation.capabilityID])
            && Set(beforeConfiguration.values.keys) == Set(afterConfiguration.values.keys)
            && beforeConfiguration.unavailable == afterConfiguration.unavailable
            && Set(beforeConfiguration.fields.keys) == Set(afterConfiguration.fields.keys), "targetMismatch")
        let cap = descriptor.capabilities.first { $0.id == operation.capabilityID }!
        let scope = descriptor.scopes.first { $0.id == cap.mutationScopeID }!
        let allowed = Set(scope.writableFields + scope.coupledFields)
        for id in scope.requiredGuardFields + scope.preservedFields {
            try requireContract(fields[id] == after.fields[id], "guardOrPreservationMismatch")
        }
        for (id, value) in beforeConfiguration.fields where !allowed.contains(id) {
            try requireContract(afterConfiguration.fields[id] == value, "preservationMismatch")
        }
        for (id, value) in beforeConfiguration.values where id != operation.capabilityID {
            try requireContract(afterConfiguration.values[id] == value, "undeclaredCapabilityEffect")
        }
        if case .usbRoute(let definition) = cap.definition {
            try requireContract(definition.reachability == .remainsReachable && cap.verification.kind != .destinationObservation, "unavailableVerification")
            if cap.verification.ownershipRequired {
                guard case .usbRoute(let route) = after.values[cap.id] else { throw DeviceContractError.invalid("ownershipMismatch") }
                try requireContract(route.observedOwnerID == route.configuredDestinationID, "ownershipMismatch")
            }
        }
    }
}
struct DeviceBackendApply: Codable, Equatable, Sendable {
    let before: DeviceBackendState
    let after: DeviceBackendState
    let attempted: Bool
    let completed: Bool
    let acknowledged: Bool
    private enum CodingKeys: String, CodingKey { case before, after, attempted, completed, acknowledged }
    init(before: DeviceBackendState, after: DeviceBackendState, attempted: Bool, completed: Bool, acknowledged: Bool) throws {
        self.before = before; self.after = after; self.attempted = attempted; self.completed = completed; self.acknowledged = acknowledged; try validate()
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["before", "after", "attempted", "completed", "acknowledged"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decode(DeviceBackendState.self, forKey: .before); after = try c.decode(DeviceBackendState.self, forKey: .after)
        attempted = try c.decode(Bool.self, forKey: .attempted); completed = try c.decode(Bool.self, forKey: .completed)
        acknowledged = try c.decode(Bool.self, forKey: .acknowledged); try validate()
    }
    func validate() throws {
        try before.validate(); try after.validate()
        // Descriptor-aware configuration equality belongs to the consumer, not
        // wire decoding: a no-op may still carry newly observed information.
        try requireContract(before.identity == after.identity && (!completed || attempted) && (!acknowledged || completed), "impossibleApplyFlags")
    }
}

/// Deliberately distinct from DeviceEndpoint's export-safe Codable projection.
/// This wrapper exists only on the private host/worker pipe.
struct AdapterEndpoint: Codable {
    let value: DeviceEndpoint
    private enum CodingKeys: String, CodingKey { case endpoint, kind, registryID, usbDeviceID, interfaceID, parentID }
    init(_ value: DeviceEndpoint) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let endpoint = try c.decode(DeviceEndpoint.self, forKey: .endpoint)
        let address: DeviceEndpointAddress
        switch try c.decode(String.self, forKey: .kind) {
        case "hid":
            try decoder.contractKeys(["endpoint", "kind", "registryID", "usbDeviceID", "interfaceID"])
            address = .hid(registryID: try c.decode(UInt64.self, forKey: .registryID), usbDeviceID: try c.decodeIfPresent(UInt64.self, forKey: .usbDeviceID), interfaceID: try c.decodeIfPresent(UInt64.self, forKey: .interfaceID))
        case "usb":
            try decoder.contractKeys(["endpoint", "kind", "registryID", "parentID"])
            address = .usb(registryID: try c.decode(UInt64.self, forKey: .registryID), parentID: try c.decodeIfPresent(UInt64.self, forKey: .parentID))
        default: throw DeviceContractError.invalid("privateEndpointKind")
        }
        value = try DeviceEndpoint(kind: endpoint.kind, id: endpoint.id, identity: endpoint.identity,
            physicalDomainID: endpoint.physicalDomainID, incarnationID: endpoint.incarnationID, address: address)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(value, forKey: .endpoint)
        switch value.address {
        case .hid(let id, let usb, let interface):
            try c.encode("hid", forKey: .kind); try c.encode(id, forKey: .registryID)
            try c.encodeIfPresent(usb, forKey: .usbDeviceID); try c.encodeIfPresent(interface, forKey: .interfaceID)
        case .usb(let id, let parent):
            try c.encode("usb", forKey: .kind); try c.encode(id, forKey: .registryID); try c.encodeIfPresent(parent, forKey: .parentID)
        default: throw DeviceContractError.invalid("privateEndpointKind")
        }
    }
}

enum AdapterOperation: String, Codable, Sendable { case selfTest, plan, read, apply }
enum AdapterPayload: Codable, Equatable, Sendable {
    case selfTest
    case plan(observation: DeviceObservation, operation: DeviceOperation)
    case read(identity: DeviceContractIdentity, endpoint: DeviceEndpoint, capabilityIDs: [String])
    case apply(plan: DevicePlan, endpoint: DeviceEndpoint, expected: DeviceBackendState)
    private enum CodingKeys: String, CodingKey { case kind, observation, operation, identity, endpoint, capabilityIDs, plan, expected }
    var operation: AdapterOperation {
        switch self { case .selfTest: return .selfTest; case .plan: return .plan; case .read: return .read; case .apply: return .apply }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(AdapterOperation.self, forKey: .kind) {
        case .selfTest: try decoder.contractKeys(["kind"]); self = .selfTest
        case .plan:
            try decoder.contractKeys(["kind", "observation", "operation"])
            self = .plan(observation: try c.decode(DeviceObservation.self, forKey: .observation), operation: try c.decode(DeviceOperation.self, forKey: .operation))
        case .read:
            try decoder.contractKeys(["kind", "identity", "endpoint", "capabilityIDs"])
            self = .read(identity: try c.decode(DeviceContractIdentity.self, forKey: .identity), endpoint: try c.decode(AdapterEndpoint.self, forKey: .endpoint).value, capabilityIDs: try c.decode([String].self, forKey: .capabilityIDs))
        case .apply:
            try decoder.contractKeys(["kind", "plan", "endpoint", "expected"])
            self = .apply(plan: try c.decode(DevicePlan.self, forKey: .plan), endpoint: try c.decode(AdapterEndpoint.self, forKey: .endpoint).value, expected: try c.decode(DeviceBackendState.self, forKey: .expected))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(operation, forKey: .kind)
        switch self {
        case .selfTest: break
        case .plan(let observation, let operation): try c.encode(observation, forKey: .observation); try c.encode(operation, forKey: .operation)
        case .read(let identity, let endpoint, let ids): try c.encode(identity, forKey: .identity); try c.encode(AdapterEndpoint(endpoint), forKey: .endpoint); try c.encode(ids, forKey: .capabilityIDs)
        case .apply(let plan, let endpoint, let expected): try c.encode(plan, forKey: .plan); try c.encode(AdapterEndpoint(endpoint), forKey: .endpoint); try c.encode(expected, forKey: .expected)
        }
    }
}

struct AdapterRequest: Codable, Equatable, Sendable {
    let schema: Int
    let hostAPI: Int
    let buildIdentity: String
    let requestID: UUID
    let providerDigest: String
    let operation: AdapterOperation
    let payload: AdapterPayload
    /// Monotonic milliseconds; not a wall-clock deadline an adapter can extend.
    let deadlineUptimeMilliseconds: Int64
    private enum CodingKeys: String, CodingKey { case schema, hostAPI, buildIdentity, requestID, providerDigest, operation, payload, deadlineUptimeMilliseconds }
    init(providerDigest: String, payload: AdapterPayload, timeout: TimeInterval, requestID: UUID = UUID()) {
        schema = 1; hostAPI = 1; buildIdentity = AdapterProcessHost.buildIdentity; self.requestID = requestID
        self.providerDigest = providerDigest; operation = payload.operation; self.payload = payload
        deadlineUptimeMilliseconds = Int64((ProcessInfo.processInfo.systemUptime + timeout) * 1000)
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "hostAPI", "buildIdentity", "requestID", "providerDigest", "operation", "payload", "deadlineUptimeMilliseconds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); hostAPI = try c.decode(Int.self, forKey: .hostAPI)
        buildIdentity = try c.decode(String.self, forKey: .buildIdentity); requestID = try c.decode(UUID.self, forKey: .requestID)
        providerDigest = try c.decode(String.self, forKey: .providerDigest); operation = try c.decode(AdapterOperation.self, forKey: .operation)
        payload = try c.decode(AdapterPayload.self, forKey: .payload); deadlineUptimeMilliseconds = try c.decode(Int64.self, forKey: .deadlineUptimeMilliseconds)
        try validate()
    }
    func validate() throws {
        try requireContract(schema == 1 && hostAPI == 1 && buildIdentity == AdapterProcessHost.buildIdentity
            && contractDigest(providerDigest) && operation == payload.operation && deadlineUptimeMilliseconds > 0, "protocolMismatch")
        let budget: Int64
        switch operation { case .selfTest, .plan: budget = 5000; case .read: budget = 10000; case .apply: budget = 30000 }
        try requireContract(deadlineUptimeMilliseconds <= AdapterProcessHost.uptimeMilliseconds + budget, "protocolDeadline")
    }
}

enum AdapterResult: Codable, Equatable, Sendable {
    case selfTest
    case plan(DeviceOperation)
    case read(DeviceBackendState)
    case apply(DeviceBackendApply)
    case rejected(DeviceUnavailable)
    case failed(DeviceAdapterFailure)
    private enum CodingKeys: String, CodingKey { case kind, operation, state, result, failure }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "selfTest": try decoder.contractKeys(["kind"]); self = .selfTest
        case "plan": try decoder.contractKeys(["kind", "operation"]); self = .plan(try c.decode(DeviceOperation.self, forKey: .operation))
        case "read": try decoder.contractKeys(["kind", "state"]); self = .read(try c.decode(DeviceBackendState.self, forKey: .state))
        case "apply": try decoder.contractKeys(["kind", "result"]); self = .apply(try c.decode(DeviceBackendApply.self, forKey: .result))
        case "rejected": try decoder.contractKeys(["kind", "failure"]); self = .rejected(try c.decode(DeviceUnavailable.self, forKey: .failure))
        case "failed": try decoder.contractKeys(["kind", "failure"]); self = .failed(try c.decode(DeviceAdapterFailure.self, forKey: .failure))
        default: throw DeviceContractError.invalid("responseKind")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selfTest: try c.encode("selfTest", forKey: .kind)
        case .plan(let operation): try c.encode("plan", forKey: .kind); try c.encode(operation, forKey: .operation)
        case .read(let state): try c.encode("read", forKey: .kind); try c.encode(state, forKey: .state)
        case .apply(let result): try c.encode("apply", forKey: .kind); try c.encode(result, forKey: .result)
        case .rejected(let failure): try c.encode("rejected", forKey: .kind); try c.encode(failure, forKey: .failure)
        case .failed(let failure): try c.encode("failed", forKey: .kind); try c.encode(failure, forKey: .failure)
        }
    }
}
struct AdapterResponse: Codable, Equatable, Sendable {
    let schema: Int
    let hostAPI: Int
    let buildIdentity: String
    let requestID: UUID
    let providerDigest: String
    let operation: AdapterOperation
    let result: AdapterResult
    private enum CodingKeys: String, CodingKey { case schema, hostAPI, buildIdentity, requestID, providerDigest, operation, result }
    init(request: AdapterRequest, result: AdapterResult) {
        schema = 1; hostAPI = 1; buildIdentity = request.buildIdentity; requestID = request.requestID
        providerDigest = request.providerDigest; operation = request.operation; self.result = result
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "hostAPI", "buildIdentity", "requestID", "providerDigest", "operation", "result"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); hostAPI = try c.decode(Int.self, forKey: .hostAPI)
        buildIdentity = try c.decode(String.self, forKey: .buildIdentity); requestID = try c.decode(UUID.self, forKey: .requestID)
        providerDigest = try c.decode(String.self, forKey: .providerDigest); operation = try c.decode(AdapterOperation.self, forKey: .operation)
        result = try c.decode(AdapterResult.self, forKey: .result)
    }
    func validate(request: AdapterRequest) throws {
        try requireContract(schema == 1 && hostAPI == 1 && buildIdentity == request.buildIdentity && requestID == request.requestID
            && providerDigest == request.providerDigest && operation == request.operation, "responseCorrelation")
        switch (request.payload, result) {
        case (_, .rejected), (_, .failed): break
        case (.selfTest, .selfTest), (.plan, .plan): break
        case (.read(let identity, _, _), .read(let state)): try requireContract(state.identity == identity, "identityMismatch")
        case (.apply(let plan, _, let expected), .apply(let evidence)):
            // This layer correlates identities without a descriptor. The
            // runner/coordinator perform shared descriptor-aware configuration
            // comparison, never whole-object equality over informational values.
            try requireContract(evidence.before.identity == expected.identity && evidence.after.identity == plan.identity, "applyEvidenceMismatch")
        default: throw DeviceContractError.invalid("responseOperation")
        }
    }
}

/// Carries conservative evidence even when a malformed/lost response cannot be
/// decoded. Diagnostics remain private; public errors use fixed codes only.
struct DeviceAdapterFailure: Error, Codable, Equatable, Sendable {
    let code: String
    let dispatched: Bool
    let cleanupConfirmed: Bool
    static let codes: Set<String> = ["adapterTimeout", "adapterCancelled", "adapterOutputOverflow", "cleanupFailed", "adapterSignal", "adapterExit",
        "adapterProtocolMismatch", "hostWorkerBuildMismatch", "hostBuildChanged", "parentLost", "providerChanged", "staleBaseline", "identityMismatch",
        "integrityChangedDuringRun", "unavailableCapability", "unavailableVerification", "deviceAccessDenied", "osExecutionDenied"]
    private enum CodingKeys: String, CodingKey { case code, dispatched, cleanupConfirmed }
    init(code: String, dispatched: Bool, cleanupConfirmed: Bool) { self.code = code; self.dispatched = dispatched; self.cleanupConfirmed = cleanupConfirmed }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["code", "dispatched", "cleanupConfirmed"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code); dispatched = try c.decode(Bool.self, forKey: .dispatched)
        cleanupConfirmed = try c.decode(Bool.self, forKey: .cleanupConfirmed)
        try requireContract(Self.codes.contains(code), "failureCode")
    }
}

final class DeviceAdapterRunner {
    let registry: SupportRegistry
    let host: AdapterHostIdentity
    init(registry: SupportRegistry, host: AdapterHostIdentity) { self.registry = registry; self.host = host }

    func invoke(content: SupportPackageContent, payload: AdapterPayload, timeout: TimeInterval,
                lease: DeviceResourceLock? = nil) async throws -> AdapterResult {
        try registry.validateRoot(); try host.validate()
        let invocations = try registry.root.directory("invocations")
        let name = UUID().uuidString
        guard mkdirat(invocations.fd, name, 0o700) == 0 else { throw SupportStorageError.unsafeFile }
        let invocationDirectory = try invocations.directory(name)
        var cleanupConfirmed = true
        defer { if cleanupConfirmed { SupportPackageInstaller.cleanupOwned(invocationDirectory, parent: invocations, name: name) } }
        let directory = try invocationDirectory.directory("package", create: true)
        _ = try invocationDirectory.directory("scratch", create: true)
        try content.copy(to: directory)
        try SupportPackageInstaller.validateNative(content, directory: directory)
        guard try SupportPackageContent.read(directory) == content else { throw SupportStorageError.integrityChanged }
        let request = AdapterRequest(providerDigest: content.digest, payload: payload, timeout: timeout)
        let invocation = HostInvocation(host: host, directory: directory.url.path, supportHome: registry.home.path, request: request, leaseNames: lease?.request.orderedNames ?? [])
        let response: AdapterResponse
        do { response = try await AdapterProcessHost.launch(host: host, invocation: invocation, lease: lease, timeout: timeout) }
        catch {
            if let failure = error as? DeviceAdapterFailure { cleanupConfirmed = failure.cleanupConfirmed }
            guard (try? SupportPackageContent.read(directory)) == content else {
                throw DeviceAdapterFailure(code: "integrityChangedDuringRun", dispatched: payload.operation == .apply, cleanupConfirmed: cleanupConfirmed)
            }
            throw error
        }
        do {
            guard try SupportPackageContent.read(directory) == content else { throw SupportStorageError.integrityChanged }
            try SupportPackageInstaller.validateNative(content, directory: directory)
        } catch { throw DeviceAdapterFailure(code: "integrityChangedDuringRun", dispatched: payload.operation == .apply, cleanupConfirmed: true) }
        try response.validate(request: request)
        if case .apply(_, _, let expected) = payload, case .apply(let evidence) = response.result {
            let descriptor = content.manifest.descriptor
            try evidence.before.validate(descriptor: descriptor, identity: expected.identity)
            try evidence.after.validate(descriptor: descriptor, identity: expected.identity)
            try requireContract(evidence.before.hasSameConfiguration(as: expected, descriptor: descriptor)
                && (evidence.attempted || evidence.after.hasSameConfiguration(as: evidence.before, descriptor: descriptor)), "applyEvidenceMismatch")
        }
        if case .failed(let failure) = response.result { cleanupConfirmed = failure.cleanupConfirmed; throw failure }
        if case .rejected(let failure) = response.result {
            throw DeviceAdapterFailure(code: DeviceAdapterFailure.codes.contains(failure.code) ? failure.code : "adapterProtocolMismatch", dispatched: false, cleanupConfirmed: true)
        }
        return response.result
    }
}
