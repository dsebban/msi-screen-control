import AppKit
import IOKit
import MSIScreenCore

/// Metadata and selection only. Reloading never reads a configuration interface.
@MainActor
final class DeviceInventoryStore: ObservableObject {
    struct Services {
        var snapshot: () async throws -> DeviceInventorySnapshot
        var listing: () async throws -> SupportPackageListing
        var descriptor: (String, String) async throws -> DeviceDescriptor
        var prepare: (String) async throws -> PreparedDeviceSupportRequest
        var bind: (String, String, String, UInt64) async throws -> Void
        var disable: (SupportBinding, UInt64) async throws -> Void
        var activate: (SupportBinding, String, UInt64) async throws -> Void
        var remove: (String, String, UInt64) async throws -> Void
        var skillAction: () async throws -> AgentSkillInstallAction = { throw AgentSkillInstallError.missingBundle }

        static func fixture(_ fixture: DeviceSupportVerificationFixture) -> Self {
            Self(snapshot: { try await fixture.snapshot() }, listing: { try SupportPackageInstaller(registry: fixture.registry).list() },
                descriptor: { try SupportPackageInstaller(registry: fixture.registry).descriptor(packageID: $0, digest: $1) },
                prepare: { try await fixture.supportRequest().prepare(deviceID: $0) },
                bind: { _ = try fixture.bind(packageID: $0, digest: $1, deviceID: $2, expectedRevision: $3) },
                disable: { _ = try fixture.changeBinding(bindingID: $0.id, expectedDigest: $0.digest, digest: nil, expectedRevision: $1) },
                activate: { _ = try fixture.changeBinding(bindingID: $0.id, expectedDigest: $0.digest, digest: $1, expectedRevision: $2) },
                remove: { _ = try fixture.remove(packageID: $0, digest: $1, expectedRevision: $2) },
                skillAction: { try AgentSkillInstallation(registry: fixture.registry).prospectiveAction(skill: .writeSupport,
                    source: AgentSkillInstallation.bundledSkill(.writeSupport), destination: fixture.skillsHome.appendingPathComponent(AgentSkill.writeSupport.rawValue)) })
        }
        // Lazy and off-main: store construction must not touch a user's support
        // root. One reader owns the queue/generation and any ephemeral session key.
        private actor InventorySession {
            let factory: () throws -> MacDeviceInventoryReader
            var reader: MacDeviceInventoryReader?
            init(factory: @escaping () throws -> MacDeviceInventoryReader) { self.factory = factory }
            func snapshot() async throws -> DeviceInventorySnapshot {
                if reader == nil { reader = try factory() }
                return try await reader!.snapshot()
            }
        }
        static func production(readerFactory: @escaping () throws -> MacDeviceInventoryReader = {
            let identity = try (try? SupportRegistry())?.inventoryIdentity() ?? DeviceInventoryIdentity(installationKey: nil)
            return MacDeviceInventoryReader(identity: identity)
        }) -> Self {
            let session = InventorySession(factory: readerFactory)
            return Self(snapshot: { try await session.snapshot() }, listing: { try SupportPackageInstaller(registry: SupportRegistry()).list() }, descriptor: { id, digest in
                try SupportPackageInstaller(registry: SupportRegistry()).descriptor(packageID: id, digest: digest)
            }, prepare: { id in try await DeviceSupportRequest(registry: SupportRegistry()).prepare(deviceID: id) }, bind: { package, digest, id, revision in
                _ = try await SupportPackageInstaller(registry: SupportRegistry()).bind(packageID: package, digest: digest, deviceID: id, expectedRevision: revision)
            }, disable: { binding, revision in
                _ = try await SupportPackageInstaller(registry: SupportRegistry()).disable(bindingID: binding.id, expectedDigest: binding.digest, expectedRevision: revision)
            }, activate: { binding, digest, revision in
                _ = try await SupportPackageInstaller(registry: SupportRegistry()).activate(bindingID: binding.id, digest: digest, expectedActiveDigest: binding.digest, expectedRevision: revision)
            }, remove: { package, digest, revision in
                _ = try SupportPackageInstaller(registry: SupportRegistry()).remove(packageID: package, digest: digest, expectedRevision: revision)
            }, skillAction: {
                let destination = try AgentSkillInstallation.skillsHome().appendingPathComponent(AgentSkill.writeSupport.rawValue)
                return try AgentSkillInstallation(registry: SupportRegistry()).prospectiveAction(skill: .writeSupport,
                    source: AgentSkillInstallation.bundledSkill(.writeSupport), destination: destination)
            })
        }
    }
    @Published private(set) var snapshot: DeviceInventorySnapshot?
    @Published private(set) var listing: SupportPackageListing?
    @Published private(set) var selectedID: String?
    @Published private(set) var legacyBuiltInSelected = false
    @Published private(set) var descriptors: [String: DeviceDescriptor] = [:]
    @Published private(set) var descriptorErrors: [String: String] = [:]
    @Published private(set) var error: String?
    @Published private(set) var metadataError: String?
    @Published private(set) var message = "Refresh passive device inventory."
    @Published private(set) var busy = false
    @Published private(set) var handoffBusy = false
    @Published private(set) var managementBusy = false
    @Published private(set) var skillAction: AgentSkillInstallAction?
    @Published private(set) var skillActionError: String?
    @Published private(set) var eventWarning: String?
    @Published private(set) var generation: UInt64 = 0
    let fixtureLabel: String?
    var externalMutationActive: () -> Bool = { false }
    var selectionChanged: () -> Void = {}
    var metadataHint: () -> Void = {}
    private let services: Services
    private enum SelectionScope { case device, peripheral }
    private var selectionScope: SelectionScope = .device
    private var initializedSelection = false
    private var refreshGeneration: UInt64 = 0
    private var skillRefreshGeneration: UInt64 = 0
    private var coalescedRefresh: Task<Void, Never>?
    private var clipboard: (String) -> Bool
    private var passiveEvents: PassiveInventoryEvents?

    init(services: Services = .production(), fixtureLabel: String? = nil,
         clipboard: @escaping (String) -> Bool = { text in
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.services = services; self.fixtureLabel = fixtureLabel; self.clipboard = clipboard
        // Discovery is additive: production opens the existing MSI controls,
        // whose controller still validates identity before every operation.
        // Choosing a generic endpoint explicitly leaves this separate owner.
        legacyBuiltInSelected = fixtureLabel == nil
        initializedSelection = fixtureLabel == nil
    }
    var selectedEndpoint: DeviceEndpoint? { snapshot?.devices.flatMap(\.endpoints).first { $0.id == selectedID } }
    var selectedRecord: DeviceRecord? { snapshot?.devices.first { $0.endpoints.contains { $0.id == selectedID } } }
    var selectedBindings: [SupportBinding] {
        guard let endpoint = selectedEndpoint else { return [] }
        return listing?.registry.bindings.filter { $0.selector.physicalDomainID == endpoint.physicalDomainID } ?? []
    }
    var selectedBinding: SupportBinding? { selectedBindings.count == 1 ? selectedBindings[0] : nil }
    var selectedDescriptor: DeviceDescriptor? { selectedBinding.flatMap { descriptors[$0.digest] } }
    // The legacy singleton controller cannot establish an association to a
    // generic inventory endpoint. Shared VID/PID is never trusted ownership.
    var usesBuiltInMonitor: Bool { legacyBuiltInSelected }
    var selectedTitle: String {
        if selectedID != nil { return selectedRecord?.displayName ?? "Disconnected selection" }
        return usesBuiltInMonitor ? "Existing MSI controls" : "Select a device"
    }
    var providerTitle: String {
        if selectedBindings.count > 1 { return "Provider collision. No configuration owner selected." }
        if let binding = selectedBinding { return "Local experimental\(binding.enabled ? "" : " (disabled)") · \(binding.packageID) · \(binding.digest.prefix(12))" }
        if selectedID == nil && usesBuiltInMonitor { return "Compiled MSI owner · identity checked by existing controller" }
        return selectionScope == .peripheral ? "No configuration provider" : "No configuration provider · video association unknown"
    }
    var selectedControlReason: String? {
        if selectedBindings.count > 1 { return "Provider collision. No configuration owner selected." }
        if selectedBinding?.enabled == false { return "Binding disabled. Activate a retained version explicitly in Settings → Local experimental support, then Read." }
        return nil
    }
    var copyDetail: String {
        switch skillAction {
        case .install: return "Install skill and copy request"
        case .upgrade: return "Update managed skill and copy request"
        case .unchanged: return "Copy support request"
        case nil: return skillActionError == nil ? "Checking bundled skill…" : "Skill unavailable or conflicting; Copy will recheck and preserve the clipboard on failure."
        }
    }
    func select(_ id: String?) {
        select(id, scope: .device)
    }
    /// Inspect support for an endpoint without changing the active monitor owner.
    func selectPeripheral(_ id: String) {
        select(id, scope: .peripheral)
    }
    private func select(_ id: String?, scope: SelectionScope) {
        guard id != selectedID || selectionScope != scope || (scope == .device && legacyBuiltInSelected) else { return }
        initializedSelection = true
        if scope == .device { legacyBuiltInSelected = false }
        selectionScope = scope; selectedID = id; generation &+= 1
        error = nil; message = "Selection changed. Read explicitly before editing."
        selectionChanged()
    }
    func selectBuiltInMonitor() {
        guard fixtureLabel == nil else { return }
        selectionScope = .device
        initializedSelection = true; legacyBuiltInSelected = true; selectedID = nil; generation &+= 1
        error = nil; message = "Explicit legacy MSI controls. The existing controller validates its model/protocol; no inventory association is implied."
        selectionChanged()
    }
    func startObservingPassiveChanges() {
        guard fixtureLabel == nil, passiveEvents == nil else { return }
        let events = PassiveInventoryEvents { [weak self] in self?.scheduleRefresh() }
        passiveEvents = events
        eventWarning = events.complete ? nil : "Passive device-change notifications unavailable; use Refresh."
    }
    func stopObservingPassiveChanges() { passiveEvents = nil; coalescedRefresh?.cancel() }
    func scheduleRefresh(stateMayHaveChanged: Bool = false) {
        // Topology is metadata, not evidence that the selected configuration
        // changed. Real external state hints still preserve-but-stale drafts.
        if stateMayHaveChanged { metadataHint() }
        coalescedRefresh?.cancel()
        coalescedRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
    func refresh() { Task { await reload() } }
    /// Awaitable for pre-operation recheck and verification. Partial sources remain visible.
    func reload() async {
        refreshGeneration &+= 1; let request = refreshGeneration
        skillRefreshGeneration &+= 1; let skillRequest = skillRefreshGeneration
        busy = true
        defer { if request == refreshGeneration { busy = false } }
        let services = services
        let result = await Task.detached { () -> (Result<DeviceInventorySnapshot, Error>, Result<SupportPackageListing, Error>, [String: DeviceDescriptor], [String: String], Result<AgentSkillInstallAction, Error>) in
            let inventory = await Result.catching { try await services.snapshot() }
            let listing = await Result.catching { try await services.listing() }
            var descriptors: [String: DeviceDescriptor] = [:], errors: [String: String] = [:]
            if case .success(let listing) = listing {
                for binding in listing.registry.bindings where descriptors[binding.digest] == nil {
                    do { descriptors[binding.digest] = try await services.descriptor(binding.packageID, binding.digest) }
                    catch { errors[binding.digest] = DevicePublicJSON.errorCode(error) }
                }
            }
            let action = await Result.catching { try await services.skillAction() }
            return (inventory, listing, descriptors, errors, action)
        }.value
        guard request == refreshGeneration else { return }
        let priorEndpoint = selectedEndpoint, priorBindings = selectedBindings, priorDescriptor = selectedDescriptor
        switch result.0 {
        case .success(let value): snapshot = value; error = nil
        case .failure(let failure): snapshot = nil; error = DevicePublicJSON.errorCode(failure)
        }
        switch result.1 {
        case .success(let value): listing = value; metadataError = nil
        case .failure(let failure): listing = nil; metadataError = DevicePublicJSON.errorCode(failure)
        }
        descriptors = result.2; descriptorErrors = result.3
        acceptSkillAction(result.4, request: skillRequest)
        if !initializedSelection, let snapshot {
            initializedSelection = true
            let external = snapshot.devices.filter { $0.kind == .display && $0.endpoints.contains { $0.identity.isBuiltIn == false } }
            if external.count == 1, external[0].endpoints.count == 1 { selectedID = external[0].endpoints[0].id }
        }
        if priorEndpoint != selectedEndpoint || priorBindings != selectedBindings || priorDescriptor != selectedDescriptor {
            generation &+= 1; selectionChanged()
        }
        message = "Passive inventory checked. Declared controls are not observed support."
    }
    private func acceptSkillAction(_ result: Result<AgentSkillInstallAction, Error>, request: UInt64) {
        guard request == skillRefreshGeneration else { return }
        switch result {
        case .success(let action): skillAction = action; skillActionError = nil
        case .failure(let failure): skillAction = nil; skillActionError = DevicePublicJSON.errorCode(failure)
        }
    }
    func refreshSkillAction() async {
        skillRefreshGeneration &+= 1; let request = skillRefreshGeneration, services = services
        let result = await Task.detached { await Result.catching { try await services.skillAction() } }.value
        acceptSkillAction(result, request: request)
    }
    func copySupportRequest() {
        guard !handoffBusy, !managementBusy, !externalMutationActive(), let endpoint = selectedEndpoint else { return }
        handoffBusy = true; error = nil
        let requestGeneration = generation, services = services
        Task {
            defer { handoffBusy = false }
            do {
                let prepared = try await Task.detached {
                    _ = try await services.snapshot().resolve(endpoint)
                    let prepared = try await services.prepare(endpoint.id)
                    _ = try await services.snapshot().resolve(endpoint)
                    return prepared
                }.value
                guard generation == requestGeneration, selectedEndpoint == endpoint else { throw DeviceContractError.invalid("staleEndpoint") }
                guard clipboard(prepared.prompt) else { throw DeviceContractError.invalid("clipboardUnavailable") }
                skillRefreshGeneration &+= 1
                skillAction = .unchanged; skillActionError = nil
                message = "\(prepared.skillStatus.rawValue.capitalized) skill. Paste into your running agent."
            } catch {
                self.error = DevicePublicJSON.errorCode(error)
                await refreshSkillAction()
            }
        }
    }
    func bind(packageID: String, digest: String) {
        guard let endpoint = selectedEndpoint else { return }
        manage { services, revision in
            _ = try await services.snapshot().resolve(endpoint)
            try await services.bind(packageID, digest, endpoint.id, revision)
        }
    }
    func disable(_ binding: SupportBinding) { manage { try await $0.disable(binding, $1) } }
    func activate(_ binding: SupportBinding, digest: String) { manage { try await $0.activate(binding, digest, $1) } }
    func remove(packageID: String, digest: String) { manage { try await $0.remove(packageID, digest, $1) } }
    private func manage(_ operation: @escaping (Services, UInt64) async throws -> Void) {
        guard !managementBusy, !handoffBusy, !externalMutationActive(), let revision = listing?.registry.revision else { return }
        managementBusy = true; error = nil; let services = services
        Task {
            defer { managementBusy = false }
            do {
                try await Task.detached { try await operation(services, revision) }.value
                await reload(); message = "Support metadata updated. A fresh explicit Read is required."
            } catch {
                let failure = DevicePublicJSON.errorCode(error)
                await reload()
                self.error = failure // A successful refresh must not swallow the failed lifecycle attempt.
            }
        }
    }
}

/// Passive matching/termination notifications only: never opens an interface,
/// requests a report or registers an input listener. Owned on the main run loop.
private final class PassiveInventoryEvents {
    private var port: IONotificationPortRef?
    private var source: CFRunLoopSource?
    private var iterators: [io_iterator_t] = []
    private let changed: () -> Void
    private(set) var complete = true
    init(changed: @escaping () -> Void) {
        self.changed = changed
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { complete = false; return }
        self.port = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else { complete = false; return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        for name in ["IOUSBHostDevice", "IOHIDDevice"] {
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port, notification, IOServiceMatching(name), { context, iterator in
                    while true { let service = IOIteratorNext(iterator); if service == 0 { break }; IOObjectRelease(service) }
                    if let context { Unmanaged<PassiveInventoryEvents>.fromOpaque(context).takeUnretainedValue().changed() }
                }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
                if result == KERN_SUCCESS {
                    iterators.append(iterator)
                    // Arm without treating already-present records as new events.
                    while true { let service = IOIteratorNext(iterator); if service == 0 { break }; IOObjectRelease(service) }
                } else { if iterator != 0 { IOObjectRelease(iterator) }; complete = false }
            }
        }
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for iterator in iterators { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }
}

extension Result where Failure == Error {
    static func catching(_ operation: () async throws -> Success) async -> Self {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
