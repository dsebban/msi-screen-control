import Foundation
import MSIScreenCore

/// Generic controls never manufacture ScreenState or inherit MSI preferences.
@MainActor
final class DeviceControlStore: ObservableObject {
    struct Selection: Equatable {
        let endpoint: DeviceEndpoint
        let binding: SupportBinding
        let descriptor: DeviceDescriptor
    }
    struct Services {
        var read: (String) async throws -> DeviceObservation
        var plan: (DeviceObservation, DeviceOperation) async throws -> DevicePlan
        var apply: (DevicePlan) async throws -> DeviceMutationReceipt
        static func fixture(_ fixture: DeviceSupportVerificationFixture) -> Self {
            Self(read: { try await fixture.coordinator().read(deviceID: $0) },
                 plan: { try await fixture.coordinator().plan(observation: $0, request: $1) },
                 apply: { try await fixture.coordinator().apply(plan: $0) })
        }
        static func production() -> Self {
            Self(read: { try await DeviceControlCoordinator(registry: SupportRegistry()).read(deviceID: $0) },
                 plan: { try await DeviceControlCoordinator(registry: SupportRegistry()).plan(observation: $0, request: $1) },
                 apply: { try await DeviceControlCoordinator(registry: SupportRegistry()).apply(plan: $0) })
        }
    }
    @Published private(set) var selection: Selection?
    @Published private(set) var observation: DeviceObservation?
    @Published private(set) var draft: [String: DeviceValue] = [:]
    @Published private(set) var invalidDrafts: Set<String> = []
    @Published private(set) var plan: DevicePlan?
    @Published private(set) var receipt: DeviceMutationReceipt?
    @Published private(set) var receipts: [UUID: DeviceMutationReceipt] = [:]
    @Published private(set) var busy = false
    @Published private(set) var isMutating = false
    @Published private(set) var needsRefresh = true
    @Published private(set) var error: String?
    @Published private(set) var message = "Select a configuration endpoint, then Read explicitly."
    @Published private(set) var generation: UInt64 = 0
    // An accepted Read resets local editor state even when its values/time are identical.
    @Published private(set) var baselineRevision: UInt64 = 0
    var externalMutationActive: () -> Bool = { false }
    var recheckMetadata: () async -> Void = {}
    private let services: Services
    private var readTask: Task<Void, Never>?

    init(services: Services = .production()) { self.services = services }
    var hasDraft: Bool { observation.map { draft != $0.values } ?? false }
    var descriptor: DeviceDescriptor? { selection?.descriptor }
    func select(_ selection: Selection?) {
        guard selection != self.selection else { return }
        readTask?.cancel(); generation &+= 1; self.selection = selection
        observation = nil; draft = [:]; invalidDrafts = []; plan = nil; receipt = nil; needsRefresh = true; error = nil
        message = "Provider/attachment changed. Read explicitly before editing."
    }
    func externalChange() {
        // Preserve the user's draft, but never apply it against an old baseline.
        readTask?.cancel(); generation &+= 1; needsRefresh = true; plan = nil
        message = "State may have changed elsewhere. Read before applying."
    }
    func invalidateDraft(_ id: String) { invalidDrafts.insert(id); plan = nil }
    func edit(_ id: String, value: DeviceValue) {
        guard !busy, let cap = descriptor?.capabilities.first(where: { $0.id == id }), cap.access == .readWrite else { return }
        do { try cap.definition.validate(value: value); draft[id] = value; invalidDrafts.remove(id); plan = nil; error = nil }
        catch { invalidateDraft(id); self.error = "invalidTarget" }
    }
    func read() {
        guard !busy, !externalMutationActive(), selection != nil else { return }
        busy = true; error = nil; let ticket = generation, selected = selection!, services = services
        readTask = Task {
            defer { busy = false; readTask = nil }
            await recheckMetadata()
            guard ticket == generation, selection == selected, !Task.isCancelled else { return }
            do {
                let result = try await services.read(selected.endpoint.id)
                guard ticket == generation, selection == selected, !Task.isCancelled else { return }
                guard result.identity.deviceID == selected.endpoint.id, result.identity.incarnationID == selected.endpoint.incarnationID,
                      result.identity.providerDigest == selected.binding.digest, result.identity.bindingID == selected.binding.id else {
                    throw DeviceContractError.invalid("providerChanged")
                }
                observation = result; draft = result.values; invalidDrafts = []; plan = nil; needsRefresh = false
                baselineRevision &+= 1
                message = "Explicit protocol observation received. Not physical-panel evidence."
            } catch {
                guard ticket == generation else { return }
                observation = nil; draft = [:]; plan = nil; needsRefresh = true
                self.error = DevicePublicJSON.errorCode(error); message = "Read refused or failed. No automatic retry."
            }
        }
    }
    func editInteger(_ id: String, text: String) {
        guard !busy else { return }
        guard let value = Int64(text) else { invalidateDraft(id); error = "invalidTarget"; return }
        edit(id, value: .integer(value))
    }
    func operation(for capabilityID: String) throws -> DeviceOperation {
        guard let capability = descriptor?.capabilities.first(where: { $0.id == capabilityID }), let value = draft[capabilityID] else {
            throw DeviceContractError.invalid("unavailableCapability")
        }
        let kind: DeviceOperationKind
        switch capability.definition {
        case .layout: kind = .setLayout
        case .usbRoute: kind = .setUSBRoute
        case .inputMapping: kind = .setInputMapping
        default: kind = .setCapability
        }
        return try DeviceOperation(kind: kind, capabilityID: capabilityID, target: value, usbCapabilityID: nil, usbTarget: nil)
    }
    func canApply(_ id: String) -> Bool {
        guard !busy, !externalMutationActive(), !needsRefresh, invalidDrafts.isEmpty, let descriptor, let observation,
              let op = try? operation(for: id), (try? descriptor.validate(operation: op)) != nil else { return false }
        return observation.values[id] != draft[id]
    }
    func apply(_ id: String) {
        guard canApply(id), let operation = try? operation(for: id) else { return }
        apply(operation)
    }
    private func composedOperation(layoutID: String, routeID: String) -> DeviceOperation? {
        guard descriptor?.supportsLayoutAndUSB == true, let layout = draft[layoutID], case .usbRoute(let route) = draft[routeID] else { return nil }
        return try? DeviceOperation(kind: .setLayoutAndUSB, capabilityID: layoutID, target: layout, usbCapabilityID: routeID, usbTarget: route)
    }
    func canApplyLayoutAndUSB(layoutID: String, routeID: String) -> Bool {
        guard !busy, !externalMutationActive(), !needsRefresh, invalidDrafts.isEmpty, let observation, let descriptor,
              let operation = composedOperation(layoutID: layoutID, routeID: routeID),
              (try? descriptor.validate(operation: operation)) != nil else { return false }
        return draft[layoutID] != observation.values[layoutID] || draft[routeID] != observation.values[routeID]
    }
    func applyLayoutAndUSB(layoutID: String, routeID: String) {
        guard canApplyLayoutAndUSB(layoutID: layoutID, routeID: routeID),
              let operation = composedOperation(layoutID: layoutID, routeID: routeID) else { return }
        apply(operation)
    }
    private func apply(_ operation: DeviceOperation) {
        guard !busy, !externalMutationActive(), !needsRefresh, invalidDrafts.isEmpty, let selected = selection, let baseline = observation,
              (try? selected.descriptor.validate(operation: operation)) != nil else { return }
        // Main-actor check/set before any await: direct RPC/store callers cannot race a button.
        busy = true; isMutating = true; error = nil; plan = nil
        let ticket = generation, services = services
        Task {
            defer { busy = false; isMutating = false }
            await recheckMetadata()
            guard ticket == generation, selected == selection else { return }
            do {
                let prepared = try await services.plan(baseline, operation)
                guard ticket == generation, selected == selection else { return }
                plan = prepared; message = "Applying once; waiting for readback…"
                let result = try await services.apply(prepared)
                receipts[result.operationID] = result // Retained even if selection changed during the setter.
                guard ticket == generation, selected == selection else { return }
                receipt = result; observation = nil; needsRefresh = true; plan = nil
                message = "\(result.outcome.rawValue) · explicit Read required before another operation."
                error = result.failure?.code
            } catch {
                guard ticket == generation else { return }
                plan = nil; observation = nil; needsRefresh = true
                self.error = DevicePublicJSON.errorCode(error); message = "Stopped. No resend or rollback. Read explicitly."
            }
        }
    }
}
