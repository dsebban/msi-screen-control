import AppKit
import Combine
import MSIScreenCore

@MainActor
final class ComputersStore: ObservableObject {
    @Published private(set) var statuses: [String: MachineStatus] = [:]
    @Published private(set) var tailnet: TailnetDiscoverySnapshot?
    @Published private(set) var resolvedHosts: [String: String] = [:]
    @Published private(set) var discoveringTailnet = false
    @Published private(set) var busy = false
    @Published private(set) var isMutating = false
    @Published private(set) var error: String?
    @Published private(set) var message = ""
    @Published private(set) var sharingDetails = ""
    @Published private(set) var sharingSummary = "Check keyboard and mouse sharing services on both Macs."
    var externalMutationActive: () -> Bool = { false }
    private let preferences: MonitorPreferences
    private var definitions: [String: MachineDefinition] = [:]
    private var resolvedDefinitions: [String: MachineDefinition] = [:]
    private let discoverTailnet: () async -> TailnetDiscoverySnapshot
    private let resolveSSHHost: (MachineDefinition) async -> String?
    private var machinesObservation: AnyCancellable?
    private var refreshPending = false

    var local: MacDisplayState? { preferences.localMachine.flatMap { statuses[$0.id]?.macDisplays } }
    var peer: MacDisplayState? { preferences.peerMachine.flatMap { statuses[$0.id]?.macDisplays } }

    init(preferences: MonitorPreferences,
         discoverTailnet: @escaping () async -> TailnetDiscoverySnapshot = { await TailnetDiscoveryClient().snapshot() },
         resolveSSHHost: @escaping (MachineDefinition) async -> String? = { await OpenSSHHostResolver().resolvedHost(for: $0) }) {
        self.preferences = preferences
        self.discoverTailnet = discoverTailnet
        self.resolveSSHHost = resolveSSHHost
        machinesObservation = preferences.$machines.dropFirst().sink { [weak self] machines in
            guard let self else { return }
            let current = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
            self.statuses = self.statuses.filter { self.definitions[$0.key] == current[$0.key] }
            self.definitions = self.definitions.filter { $0.value == current[$0.key] }
            self.resolvedHosts = self.resolvedHosts.filter { self.resolvedDefinitions[$0.key] == current[$0.key] }
            self.resolvedDefinitions = self.resolvedDefinitions.filter { $0.value == current[$0.key] }
        }
    }

    func refreshIfStale() {
        if tailnet == nil || Date().timeIntervalSince(tailnet!.checkedAt) > 30 { refreshTailnet() }
        if preferences.machines.contains(where: {
            guard let status = statuses[$0.id] else { return true }
            return Date().timeIntervalSince(status.checkedAt) > 30
        }) { refresh() }
    }

    func refresh() {
        refreshTailnet()
        guard !busy else { refreshPending = true; return }
        busy = true
        error = nil
        message = "Checking machines…"
        let machines = preferences.machines
        Task {
            defer { finishOperation() }
            // Independent remote checks run together, without holding USB.
            await withTaskGroup(of: (MachineDefinition, MachineStatus).self) { group in
                for machine in machines {
                    group.addTask { (machine, await MachineStatusClient().state(for: machine)) }
                }
                for await (machine, result) in group {
                    guard preferences.machines.contains(machine) else { continue }
                    statuses[machine.id] = result
                    definitions[machine.id] = machine
                }
            }
            message = "Machine checks complete. Input selection is read from the monitor."
        }
    }

    /// Discovery is passive and never changes saved input or SSH assignments.
    func refreshTailnet() {
        guard !discoveringTailnet else { return }
        discoveringTailnet = true
        let machines = preferences.machines.filter { $0.access == .ssh && $0.sshTransport == .standard }
        let resolveSSHHost = resolveSSHHost
        Task {
            async let snapshot = discoverTailnet()
            var hosts: [String: String] = [:]
            var definitions: [String: MachineDefinition] = [:]
            await withTaskGroup(of: (MachineDefinition, String?).self) { group in
                for machine in machines {
                    group.addTask { (machine, await resolveSSHHost(machine)) }
                }
                for await (machine, host) in group {
                    guard let host, preferences.machines.contains(machine) else { continue }
                    hosts[machine.id] = host
                    definitions[machine.id] = machine
                }
            }
            tailnet = await snapshot
            // A definition can change while discovery finishes after ssh -G.
            resolvedHosts = hosts.filter { id, _ in preferences.machines.contains { $0 == definitions[id] } }
            resolvedDefinitions = definitions.filter { resolvedHosts[$0.key] != nil }
            discoveringTailnet = false
        }
    }

    func makeMain(machine: MachineDefinition, target: MacMainDisplayTarget) {
        changeDisplay(machine: machine, change: .main(target))
    }

    func arrange(machine: MachineDefinition, laptopPosition: MacLaptopPosition) {
        changeDisplay(machine: machine, change: .arrange(laptopPosition))
    }

    private enum DisplayChange {
        case main(MacMainDisplayTarget)
        case arrange(MacLaptopPosition)
    }

    private func changeDisplay(machine: MachineDefinition, change: DisplayChange) {
        guard machine.platform == .macos, machine.access != .videoOnly else { return }
        guard !externalMutationActive() else { error = "Another device operation is active. Wait for it to finish."; return }
        guard !busy, definitions[machine.id] == machine,
              preferences.machines.contains(machine),
              let before = statuses[machine.id]?.macDisplays else { return }
        busy = true
        error = nil
        message = "Updating display arrangement…"
        isMutating = true
        Task {
            defer { finishOperation() }
            do {
                guard try MachineRegistryStore().load().machine(id: machine.id) == machine else {
                    throw ScreenError.message("Machine assignment changed. Refresh before changing its display.")
                }
                let result: MacDisplayState
                switch change {
                case .main(let target):
                    if let host = machine.host {
                        result = try await RemoteMacClient(host: host, transport: machine.sshTransport).makeMain(from: before, target: target)
                    } else {
                        result = try MacDisplayController().makeMain(from: before, target: target)
                    }
                case .arrange(let position):
                    if let host = machine.host {
                        result = try await RemoteMacClient(host: host, transport: machine.sshTransport).arrange(from: before, laptopPosition: position)
                    } else {
                        result = try MacDisplayController().arrange(from: before, laptopPosition: position)
                    }
                }
                guard preferences.machines.contains(machine) else { return }
                statuses[machine.id] = MachineStatus(machine: machine, macDisplays: result)
                message = "Display positions and Main/Extended roles verified."
            } catch {
                guard preferences.machines.contains(machine) else { return }
                statuses[machine.id] = nil
                self.error = error.localizedDescription
                message = "Refresh displays before trying again."
            }
        }
    }

    func makeMain(peer: Bool, target: MacMainDisplayTarget) {
        guard let machine = peer ? preferences.peerMachine : preferences.localMachine else { return }
        makeMain(machine: machine, target: target)
    }

    func checkSharing() { runSharing(.check) }
    func reconnectSharing() { runSharing(.refresh) }

    private func runSharing(_ operation: UniversalControlOperation) {
        guard operation != .refresh || !externalMutationActive() else { error = "Another device operation is active. Wait for it to finish."; return }
        guard !busy else { return }
        busy = true
        isMutating = operation == .refresh
        error = nil
        sharingSummary = operation == .refresh ? "Reconnecting sharing services…" : "Checking both Macs…"
        Task {
            defer { finishOperation() }
            do {
                let result = try await UniversalControlClient().run(operation)
                sharingDetails = result.process.text
                sharingSummary = result.summary
            } catch {
                self.error = error.localizedDescription
                sharingSummary = "Sharing could not be checked."
            }
        }
    }

    func openSharingSettings() { NSWorkspace.shared.open(UniversalControlClient.displaysSettingsURL) }

    private func finishOperation() {
        busy = false
        isMutating = false
        if refreshPending {
            refreshPending = false
            refresh()
        }
    }
}
