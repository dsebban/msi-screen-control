import Foundation
import MSIScreenCore

@MainActor
final class MonitorPreferences: ObservableObject {
    @Published private(set) var machines: [MachineDefinition] = []
    @Published private(set) var usbUpstreamMachineID: String?
    @Published private(set) var error: String?
    @Published var inputNames: [String: String] {
        didSet { defaults.set(inputNames, forKey: "inputNames") }
    }
    @Published var followFullscreenUSB: Bool {
        didSet { defaults.set(followFullscreenUSB, forKey: "followFullscreenUSB") }
    }
    /// A user-confirmed Mac sharing link, independent of USB ownership or
    /// service health. A configured peer is not a live connectivity verdict.
    @Published var universalControlPeerID: String? {
        didSet { defaults.set(universalControlPeerID, forKey: "universalControlPeerID") }
    }
    private let defaults: UserDefaults
    private let registryStore: MachineRegistryStore
    private var snapshot = MachineRegistry(machines: [])

    var localMachine: MachineDefinition? { machines.first(where: \.isLocal) }
    var peerMachine: MachineDefinition? { machines.first { $0.access == .ssh && $0.platform == .macos } }
    var localInput: Input? { localMachine?.input }
    var peerInput: Input? { peerMachine?.input }
    var peerHost: String { peerMachine?.host ?? "" }
    var usbUpstreamMachine: MachineDefinition? { snapshot.usbUpstreamMachine }
    var universalControlPeer: MachineDefinition? {
        guard localMachine?.platform == .macos else { return nil }
        return machines.first { $0.id == universalControlPeerID && $0.platform == .macos && !$0.isLocal }
    }

    func usesUniversalControl(_ machine: MachineDefinition) -> Bool {
        guard let peer = universalControlPeer else { return false }
        return machine.id == peer.id || machine.id == localMachine?.id
    }

    init(defaults: UserDefaults = .standard, registryStore: MachineRegistryStore = MachineRegistryStore()) {
        self.defaults = defaults
        self.registryStore = registryStore
        inputNames = defaults.dictionary(forKey: "inputNames") as? [String: String] ?? [:]
        followFullscreenUSB = defaults.object(forKey: "followFullscreenUSB") as? Bool ?? true
        universalControlPeerID = defaults.string(forKey: "universalControlPeerID")
        do {
            // Migrate once, only when no shared registry exists. Thereafter the
            // file owns input/host assignments for both app and CLI.
            if !FileManager.default.fileExists(atPath: registryStore.url.path) {
                let localName = (try? MacDisplayController().state().computerName) ?? "This Mac"
                var initial = [MachineDefinition(id: "local-mac", name: localName, platform: .macos,
                    input: Input(rawValue: defaults.string(forKey: "localInput") ?? "") ?? .usbc, host: nil)]
                if let host = defaults.string(forKey: "peerHost"), !host.isEmpty {
                    initial.append(MachineDefinition(id: "peer-mac", name: "Other Mac", platform: .macos,
                        input: Input(rawValue: defaults.string(forKey: "peerInput") ?? "") ?? .hdmi1, host: host))
                }
                try registryStore.save(MachineRegistry(machines: initial), replacing: MachineRegistry(), ifMissing: true)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func reload() {
        do {
            let updated = try registryStore.load()
            snapshot = updated
            if machines != updated.machines { machines = updated.machines }
            usbUpstreamMachineID = updated.usbUpstreamMachineID
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func saveMachine(_ machine: MachineDefinition, replacing expected: MachineDefinition?) throws {
        guard machines.first(where: { $0.id == machine.id }) == expected else {
            throw ScreenError.message("This machine changed while editing. Cancel and reopen its editor.")
        }
        var updated = machines
        if let index = updated.firstIndex(where: { $0.id == machine.id }) { updated[index] = machine }
        else { updated.append(machine) }
        var registry = snapshot
        registry.machines = updated
        if let id = registry.usbUpstreamMachineID,
           !updated.contains(where: { $0.id == id && $0.isUSBUpstreamCandidate }) {
            registry.usbUpstreamMachineID = nil
        }
        try registryStore.save(registry, replacing: snapshot)
        reload()
    }

    func removeMachine(_ machine: MachineDefinition) throws {
        guard machines.first(where: { $0.id == machine.id }) == machine else {
            throw ScreenError.message("This machine changed while editing. Cancel and reopen its editor.")
        }
        var registry = snapshot
        registry.machines.removeAll { $0.id == machine.id }
        if registry.usbUpstreamMachineID == machine.id { registry.usbUpstreamMachineID = nil }
        try registryStore.save(registry, replacing: snapshot)
        reload()
    }

    func setUSBUpstreamMachine(_ id: String?) {
        do {
            var registry = snapshot
            registry.usbUpstreamMachineID = id
            try registryStore.save(registry, replacing: snapshot)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func name(for input: Input, localName: String?, peerName: String?) -> String {
        if let label = inputNames[input.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if input == localInput, let localName { return localName }
        if input == peerInput, let peerName { return peerName }
        return machines.first { $0.input == input }?.name ?? input.title
    }
}
