import CryptoKit
import Foundation

struct DeviceContractAuthentication {
    let key: Data
    private func derived(_ domain: String) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(domain.utf8), using: SymmetricKey(data: key))))
    }
    private func payload<T: Encodable>(_ value: T) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: StrictJSON.canonical(value)) as! [String: Any]
        object.removeValue(forKey: "authentication")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func sign<T: Encodable>(_ value: T, domain: String) throws -> String {
        Data(HMAC<SHA256>.authenticationCode(for: try payload(value), using: derived(domain))).map { String(format: "%02x", $0) }.joined()
    }
    func verify(_ observation: DeviceObservation) throws {
        try observation.validate()
        let bytes = try HIDFeatureProfile.bytes(observation.authentication)
        let data = try payload(observation)
        try requireContract(HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: data, using: derived("device-observation-v1")), "unauthenticatedObservation")
    }
    func verify(_ plan: DevicePlan) throws {
        try plan.validate()
        let bytes = try HIDFeatureProfile.bytes(plan.authentication)
        let data = try payload(plan)
        try requireContract(HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: data, using: derived("device-plan-v1")), "unauthenticatedPlan")
    }
    func commitments(_ state: DeviceBackendState, descriptor: DeviceDescriptor) throws -> [String: String] {
        var result: [String: String] = [:]
        for scope in descriptor.scopes {
            let bytes = try StrictJSON.canonical(state.configuration(descriptor: descriptor, scope: scope))
            result[scope.id] = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: derived("device-scope-commitment-v1"))).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    func observation(state: DeviceBackendState, descriptor: DeviceDescriptor, epoch: UInt64, now: Int64) throws -> DeviceObservation {
        let values = try descriptor.exportSafeValues(state.values)
        var unavailable: [String: DeviceUnavailable] = [:]
        for cap in descriptor.capabilities where values[cap.id] == nil {
            unavailable[cap.id] = try DeviceUnavailable(code: cap.unavailableReason == nil && state.unavailable[cap.id] == nil ? "localOnly" : "unavailableCapability")
        }
        func make(_ authentication: String) throws -> DeviceObservation {
            try DeviceObservation(schema: 1, identity: state.identity, checkedAtMilliseconds: now, values: values, unavailable: unavailable,
                guardState: [:], scopeCommitments: commitments(state, descriptor: descriptor), domainEpoch: epoch, authentication: authentication)
        }
        return try make(sign(make(String(repeating: "0", count: 64)), domain: "device-observation-v1"))
    }
    func signedPlan(operationID: UUID, identity: DeviceContractIdentity, revision: UInt64, epoch: UInt64,
                    commitments: [String: String], operation: DeviceOperation, stages: [DevicePlanStage],
                    changes: [String: DeviceValueChange], now: Int64) throws -> DevicePlan {
        try requireContract(now >= 0 && now <= Int64.max - 300000, "planTime")
        func make(_ authentication: String) throws -> DevicePlan {
            try DevicePlan(schema: 1, operationID: operationID, issuedAtMilliseconds: now, expiresAtMilliseconds: now + 300000,
                identity: identity, registryRevision: revision, domainEpoch: epoch, expectedCommitments: commitments,
                operation: operation, stages: stages, changes: changes, authentication: authentication)
        }
        return try make(sign(make(String(repeating: "0", count: 64)), domain: "device-plan-v1"))
    }
}

/// Internal provider seam. Production constructs only exact pinned experimental
/// targets; tests inject disposable transports, never an environment fake mode.
struct ResolvedDeviceControl {
    let identity: DeviceContractIdentity
    let descriptor: DeviceDescriptor
    let registryRevision: UInt64
    let lockRequest: DeviceResourceLock.Request
    var lockDirectory: URL? = nil
    var unavailableForMutation: String? = nil
    let revalidate: (DeviceResourceLock) async throws -> Void
    let read: (DeviceResourceLock) async throws -> DeviceBackendState
    let normalize: (DeviceObservation, DeviceOperation) async throws -> DeviceOperation
    let apply: (DevicePlan, DeviceBackendState, DeviceResourceLock) async throws -> DeviceBackendApply
    let verifyPreservation: (DeviceBackendState, DeviceBackendState, DeviceOperation) throws -> Void
}

public final class DeviceControlCoordinator {
    private let registry: SupportRegistry
    private let authentication: DeviceContractAuthentication
    private let journal: DeviceOperationJournal
    private let resolve: (String) async throws -> ResolvedDeviceControl
    private let now: () -> Int64
    public convenience init(registry: SupportRegistry) throws {
        let key = try registry.installationKey()
        let reader = MacDeviceInventoryReader(identity: try DeviceInventoryIdentity(installationKey: key))
        let hostPin = Result { try AdapterHostIdentity.resolve() }
        self.init(registry: registry, key: key, resolve: { id in
            try await Self.selectedTarget(deviceID: id, registry: registry, reader: reader, hostPin: hostPin)
        })
    }
    init(registry: SupportRegistry, key: Data, journal: DeviceOperationJournal? = nil,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         resolve: @escaping (String) async throws -> ResolvedDeviceControl) {
        self.registry = registry; authentication = DeviceContractAuthentication(key: key)
        self.journal = journal ?? DeviceOperationJournal(registry: registry); self.resolve = resolve; self.now = now
    }
    private func checkKey() throws {
        // Registry/key work precedes every resource lease, never in reverse.
        let key = try registry.installationKey(); try requireContract(key == authentication.key, "identityKeyChanged")
    }
    public func read(deviceID: String) async throws -> DeviceObservation {
        try checkKey(); let target = try await resolve(deviceID); try target.descriptor.validate()
        let lease = try DeviceResourceLock(target.lockRequest, directory: target.lockDirectory)
        defer { withExtendedLifetime(lease) {} }
        try await target.revalidate(lease)
        let state = try await target.read(lease)
        try state.validate(descriptor: target.descriptor, identity: target.identity)
        try await target.revalidate(lease)
        let epoch = try journal.epoch(domainID: target.identity.domainID)
        return try authentication.observation(state: state, descriptor: target.descriptor, epoch: epoch, now: now())
    }
    public func plan(observation: DeviceObservation, request: DeviceOperation) async throws -> DevicePlan {
        try checkKey(); try authentication.verify(observation)
        let target = try await resolve(observation.identity.deviceID)
        try requireContract(target.identity == observation.identity, "providerChanged")
        try target.descriptor.validate(operation: request)
        let normalized = try await target.normalize(observation, request)
        try target.descriptor.validateNormalization(request: request, normalized: normalized)
        return try makePlan(observation: observation, operation: normalized, target: target, operationID: UUID(), time: now())
    }
    private func makePlan(observation: DeviceObservation, operation: DeviceOperation, target: ResolvedDeviceControl, operationID: UUID, time: Int64) throws -> DevicePlan {
        try requireContract(time >= observation.checkedAtMilliseconds && Set(observation.scopeCommitments.keys) == Set(target.descriptor.scopes.map(\.id)), "invalidObservation")
        let operations = try Self.operations(operation)
        var stages: [DevicePlanStage] = []; var changes: [String: DeviceValueChange] = [:]
        for (index, operation) in operations.enumerated() {
            try target.descriptor.validate(operation: operation)
            guard let cap = target.descriptor.capabilities.first(where: { $0.id == operation.capabilityID }), let before = observation.values[cap.id] else {
                throw DeviceContractError.invalid("unavailableCapability")
            }
            stages.append(try DevicePlanStage(id: index == 0 ? "configuration" : "usb", operation: operation,
                scopeIDs: [cap.mutationScopeID], budgetMilliseconds: cap.executionBudgetMilliseconds))
            if !Self.matches(operation.target, actual: before) { changes[cap.id] = try DeviceValueChange(before: before, after: operation.target) }
        }
        return try authentication.signedPlan(operationID: operationID, identity: target.identity, revision: target.registryRevision,
            epoch: observation.domainEpoch, commitments: observation.scopeCommitments, operation: operation, stages: stages, changes: changes, now: time)
    }
    static func operations(_ operation: DeviceOperation) throws -> [DeviceOperation] {
        if operation.kind != .setLayoutAndUSB { return [operation] }
        return try [DeviceOperation(kind: .setLayout, capabilityID: operation.capabilityID, target: operation.target, usbCapabilityID: nil, usbTarget: nil),
            DeviceOperation(kind: .setUSBRoute, capabilityID: operation.usbCapabilityID!, target: .usbRoute(operation.usbTarget!), usbCapabilityID: nil, usbTarget: nil)]
    }
    static func matches(_ target: DeviceValue, actual: DeviceValue?) -> Bool {
        target.matchesTarget(actual)
    }
    public func apply(plan: DevicePlan) async throws -> DeviceMutationReceipt {
        try Task.checkCancellation()
        let task = Task { try await self.applyOnce(plan: plan) }
        let watchdog = Task { try? await Task.sleep(nanoseconds: 120_000_000_000); if !Task.isCancelled { task.cancel() } }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func bounded<T>(until deadline: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw DeviceAdapterFailure(code: "adapterTimeout", dispatched: true, cleanupConfirmed: true) }
        let task = Task { try await operation() }
        let watchdog = Task { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)); if !Task.isCancelled { task.cancel() } }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                if ProcessInfo.processInfo.systemUptime >= deadline { throw DeviceAdapterFailure(code: "adapterTimeout", dispatched: true, cleanupConfirmed: true) }
                return value
            } catch {
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    throw DeviceAdapterFailure(code: "adapterTimeout", dispatched: true, cleanupConfirmed: (error as? DeviceAdapterFailure)?.cleanupConfirmed ?? true)
                }
                throw error
            }
        } onCancel: { task.cancel() }
    }
    private func applyOnce(plan: DevicePlan) async throws -> DeviceMutationReceipt {
        try Task.checkCancellation(); try checkKey(); try authentication.verify(plan)
        // Historical duplicate lookup needs no device resolution or I/O.
        if let prior = try journal.record(operationID: plan.operationID) {
            let digest = SupportPackageContent.hash(try StrictJSON.canonical(plan))
            try requireContract(prior.planDigest == digest, "operationUUIDReused"); return prior.receipt
        }
        let time = now()
        try requireContract(time >= plan.issuedAtMilliseconds && time < plan.expiresAtMilliseconds, "expiredPlan")
        let target = try await resolve(plan.identity.deviceID)
        try requireContract(target.identity == plan.identity && target.registryRevision == plan.registryRevision, "providerChanged")
        try target.descriptor.validate(operation: plan.operation)
        if let reason = target.unavailableForMutation { throw DeviceContractError.invalid(reason) }
        let lease = try DeviceResourceLock(target.lockRequest, directory: target.lockDirectory)
        defer { withExtendedLifetime(lease) {} }
        let epoch = try journal.epoch(domainID: plan.identity.domainID)
        try requireContract(epoch == plan.domainEpoch, "staleDomainEpoch")
        try await target.revalidate(lease)
        let baseline = try await target.read(lease)
        try baseline.validate(descriptor: target.descriptor, identity: target.identity)
        let commitments = try authentication.commitments(baseline, descriptor: target.descriptor)
        try requireContract(commitments == plan.expectedCommitments, "staleBaseline")
        let currentObservation = try authentication.observation(state: baseline, descriptor: target.descriptor, epoch: plan.domainEpoch, now: plan.issuedAtMilliseconds)
        let reconstructed = try makePlan(observation: currentObservation, operation: plan.operation, target: target, operationID: plan.operationID, time: plan.issuedAtMilliseconds)
        try requireContract(reconstructed == plan, "planEffectsMismatch")
        let before = try target.descriptor.exportSafeValues(baseline.values)
        let targets = Dictionary(uniqueKeysWithValues: try Self.operations(plan.operation).map { ($0.capabilityID, $0.target) })
        var stages: [DeviceStageReceipt] = []; var after: DeviceBackendState? = baseline
        var possibleWrite = false
        func receipt(outcome: DeviceMutationOutcome, failure: String? = nil) throws -> DeviceMutationReceipt {
            try DeviceMutationReceipt(schema: 1, operationID: plan.operationID, identity: plan.identity, before: before,
                target: targets, after: after.map { try target.descriptor.exportSafeValues($0.values) }, stages: stages,
                failure: failure.map { try DeviceUnavailable(code: $0) }, outcome: outcome,
                writeMayHaveOccurred: possibleWrite, verified: outcome == .verified || outcome == .noChange)
        }
        try Task.checkCancellation()
        let claim = try journal.claim(plan: plan, initial: receipt(outcome: .notAttempted), now: time)
        let record: DeviceJournalRecord
        switch claim { case .existing(let existing): return existing.receipt; case .accepted(let accepted): record = accepted }
        var final: DeviceMutationReceipt
        do {
            // A no-op still had a fresh complete read and authenticated baseline.
            if targets.allSatisfy({ Self.matches($0.value, actual: baseline.values[$0.key]) }) {
                final = try receipt(outcome: .noChange)
            } else {
                possibleWrite = true; after = nil
                _ = try journal.markPossibleWrite(record, receipt: receipt(outcome: .unverified, failure: "operationIncomplete"))
                var current = baseline
                let deadline = ProcessInfo.processInfo.systemUptime + 120
                for stage in plan.stages {
                    let stageDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + Double(stage.budgetMilliseconds) / 1000)
                    try Task.checkCancellation(); try await Self.bounded(until: stageDeadline) { try await target.revalidate(lease) }
                    try requireContract(ProcessInfo.processInfo.systemUptime < deadline, "adapterTimeout")
                    if Self.matches(stage.operation.target, actual: current.values[stage.operation.capabilityID]) { continue }
                    stages.append(try DeviceStageReceipt(id: stage.id, attempted: true, completed: false, acknowledged: false, verified: false, failure: nil))
                    let stagePlan = try authentication.signedPlan(operationID: plan.operationID, identity: plan.identity, revision: plan.registryRevision,
                        epoch: plan.domainEpoch, commitments: authentication.commitments(current, descriptor: target.descriptor), operation: stage.operation,
                        stages: [stage], changes: plan.changes.filter { $0.key == stage.operation.capabilityID }, now: plan.issuedAtMilliseconds)
                    let expected = current
                    let result = try await Self.bounded(until: stageDeadline) { try await target.apply(stagePlan, expected, lease) }
                    try result.before.validate(descriptor: target.descriptor, identity: target.identity)
                    try requireContract(result.before.hasSameConfiguration(as: current, descriptor: target.descriptor) && result.attempted && result.completed, "applyEvidenceMismatch")
                    stages[stages.count - 1] = try DeviceStageReceipt(id: stage.id, attempted: true, completed: result.completed, acknowledged: result.acknowledged, verified: false, failure: nil)
                    try result.after.validate(descriptor: target.descriptor, identity: target.identity)
                    after = result.after
                    try current.verifyTransition(to: result.after, operation: stage.operation, descriptor: target.descriptor)
                    try target.verifyPreservation(current, result.after, stage.operation)
                    // Independent fresh backend read, not a claimed verified flag.
                    let fresh = try await Self.bounded(until: stageDeadline) { try await target.read(lease) }
                    try fresh.validate(descriptor: target.descriptor, identity: target.identity)
                    try requireContract(fresh.hasSameConfiguration(as: result.after, descriptor: target.descriptor), "independentReadMismatch")
                    try await Self.bounded(until: stageDeadline) { try await target.revalidate(lease) }
                    stages[stages.count - 1] = try DeviceStageReceipt(id: stage.id, attempted: true, completed: true, acknowledged: result.acknowledged, verified: true, failure: nil)
                    current = fresh; after = current
                }
                try Task.checkCancellation()
                try requireContract(targets.allSatisfy { Self.matches($0.value, actual: current.values[$0.key]) }, "finalConsistencyMismatch")
                final = try receipt(outcome: .verified)
            }
        } catch {
            let failure = AdapterProcessHost.failure(error, dispatched: possibleWrite)
            if let last = stages.last, !last.verified {
                stages[stages.count - 1] = try DeviceStageReceipt(id: last.id, attempted: last.attempted, completed: last.completed,
                    acknowledged: last.acknowledged, verified: false, failure: DeviceUnavailable(code: failure.code))
            }
            final = try receipt(outcome: Task.isCancelled ? .cancelled : (possibleWrite ? .unverified : .notAttempted), failure: failure.code)
        }
        do { try journal.finish(record, receipt: final); return final }
        catch {
            // Disk failure cannot erase the evidence returned to the caller or
            // turn a durable possible-write claim into permission to resend.
            return try receipt(outcome: possibleWrite ? .unverified : .notAttempted, failure: "journalPersistence")
        }
    }
    public func receipt(operationID: UUID) throws -> DeviceMutationReceipt? { try journal.receipt(operationID: operationID) }
}

extension DeviceControlCoordinator {
    static func selectedTarget(deviceID: String, registry: SupportRegistry, reader: DeviceInventoryClient, hostPin: Result<AdapterHostIdentity, Error>) async throws -> ResolvedDeviceControl {
        let snapshot = try await reader.snapshot(), metadata = try registry.snapshot()
        let matches = snapshot.devices.flatMap(\.endpoints).filter { $0.id == deviceID }
        try requireContract(matches.count == 1, matches.isEmpty ? "absentEndpoint" : "ambiguousEndpoint")
        let endpoint = matches[0]
        switch endpoint.kind {
        case .hid: try requireContract(snapshot.hid == .complete && (endpoint.identity.transport != .usb || snapshot.usb == .complete), "inventoryIncomplete")
        case .usb: try requireContract(snapshot.usb == .complete, "inventoryIncomplete")
        default: throw DeviceContractError.invalid("unsupportedControlEndpoint")
        }
        let bindings = metadata.bindings.filter { $0.enabled && $0.selector.physicalDomainID == endpoint.physicalDomainID }
        if bindings.isEmpty && BuiltInControlDomainCatalog.isMSI(endpoint.identity) {
            // Explicit unbound built-in candidate only. Registry failure, stale
            // experimental binding and experimental guard rejection never enter
            // this branch. ScreenController validates its protected tuple before
            // reading settings or performing its own verified transition.
            return try BuiltInDeviceProvider.selectedTarget(endpoint: endpoint, registryRevision: metadata.revision, reader: reader) {
                let current = try registry.snapshot(); try requireContract(current == metadata, "providerChanged")
            }
        }
        guard bindings.count == 1, let binding = bindings.first else { throw DeviceContractError.invalid(bindings.isEmpty ? "unconfiguredDevice" : "providerCollision") }
        let durable = snapshot.devices.contains { $0.bindingEligibility == .durable && $0.endpoints.contains { $0.id == endpoint.id } }
        try requireContract(binding.selector.id == endpoint.id && (durable || binding.selector.incarnationID == endpoint.incarnationID)
            && binding.selector.identity == endpoint.identity, "staleBinding")
        let content = try SupportPackageContent.read(registry.root.directory("packages").directory(binding.packageID).directory(binding.digest))
        try requireContract(content.digest == binding.digest, "providerDigestChanged")
        try BuiltInControlDomainCatalog.validate(content.manifest, endpoint: endpoint, snapshot: snapshot)
        let identity = try DeviceContractIdentity(deviceID: endpoint.id, incarnationID: endpoint.incarnationID, bindingID: binding.id,
            providerDigest: binding.digest, domainID: endpoint.physicalDomainID)
        let request = try DeviceResourceLock.controlRequest(endpoint, graph: MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB()), descriptor: content.manifest.descriptor)
        let runner = DeviceAdapterRunner(registry: registry, host: try hostPin.get())
        let revalidate: (DeviceResourceLock) async throws -> Void = { lease in
            let currentMetadata = try registry.snapshot(); try requireContract(currentMetadata == metadata, "registryChanged")
            let current = try await reader.snapshot()
            try DeviceSupportResolver.guardSelected(endpoint: endpoint, manifest: content.manifest, lease: lease, snapshot: { current }, usbSource: { try USBDeviceGraph.enumerateUSB() })
        }
        return ResolvedDeviceControl(identity: identity, descriptor: content.manifest.descriptor, registryRevision: metadata.revision, lockRequest: request,
            unavailableForMutation: SupportPackageInstaller(registry: registry).executionReady ? nil : "runtimeQualificationPending",
            revalidate: revalidate, read: { lease in
                let result = try await runner.invoke(content: content, payload: .read(identity: identity, endpoint: endpoint, capabilityIDs: content.manifest.descriptor.capabilities.map(\.id)), timeout: 10, lease: lease)
                guard case .read(let state) = result else { throw DeviceContractError.invalid("missingReadback") }; return state
            }, normalize: { observation, operation in
                let result = try await runner.invoke(content: content, payload: .plan(observation: observation, operation: operation), timeout: 5)
                guard case .plan(let normalized) = result else { throw DeviceContractError.invalid("adapterProtocolMismatch") }; return normalized
            }, apply: { plan, expected, lease in
                let result = try await runner.invoke(content: content, payload: .apply(plan: plan, endpoint: endpoint, expected: expected),
                    timeout: Double(plan.stages[0].budgetMilliseconds) / 1000, lease: lease)
                guard case .apply(let evidence) = result else { throw DeviceContractError.invalid("missingReadback") }; return evidence
            }, verifyPreservation: { before, after, operation in
                if case .profile(_, let path) = content.manifest.backend {
                    let profile = try StrictJSON.decode(HIDFeatureProfile.self, from: content.files[path]!)
                    var reports = before.preservation
                    for (id, value) in try profile.targetFields(capabilityID: operation.capabilityID, target: operation.target) {
                        let field = profile.fields.first { $0.id == id }!; let reportID = String(field.reportID)
                        var bytes = try HIDFeatureProfile.bytes(reports[reportID]!); try field.encode(value, into: &bytes); reports[reportID] = bytes.hex
                    }
                    try requireContract(reports == after.preservation, "fullReportMismatch")
                } else { try requireContract(before.preservation == after.preservation, "preservationMismatch") }
            })
    }
}
