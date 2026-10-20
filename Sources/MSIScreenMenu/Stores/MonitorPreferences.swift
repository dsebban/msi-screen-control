import Foundation
import MSIScreenCore

@MainActor
final class MonitorPreferences: ObservableObject {
    @Published private(set) var machines: [MachineDefinition] = []
    @Published private(set) var error: String?
    @Published var inputNames: [String: String] {
        didSet { defaults.set(inputNames, forKey: "inputNames") }
    }
    @Published var followFullscreenUSB: Bool {
        didSet { defaults.set(followFullscreenUSB, forKey: "followFullscreenUSB") }
    }
    private let defaults: UserDefaults
    private let registryStore = MachineRegistryStore()
    private var snapshot = MachineRegistry(machines: [])

    var localMachine: MachineDefinition? { machines.first { $0.host == nil } }
    var peerMachine: MachineDefinition? { machines.first { $0.host != nil && $0.platform == .macos } }
    var localInput: Input { localMachine?.input ?? .usbc }
    var peerInput: Input { peerMachine?.input ?? .hdmi1 }
    var peerHost: String { peerMachine?.host ?? "" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inputNames = defaults.dictionary(forKey: "inputNames") as? [String: String] ?? [:]
        followFullscreenUSB = defaults.object(forKey: "followFullscreenUSB") as? Bool ?? true
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
        try registryStore.save(MachineRegistry(machines: updated), replacing: snapshot)
        reload()
    }

    func removeMachine(_ machine: MachineDefinition) throws {
        guard machines.first(where: { $0.id == machine.id }) == machine else {
            throw ScreenError.message("This machine changed while editing. Cancel and reopen its editor.")
        }
        try registryStore.save(MachineRegistry(machines: machines.filter { $0.id != machine.id }), replacing: snapshot)
        reload()
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
