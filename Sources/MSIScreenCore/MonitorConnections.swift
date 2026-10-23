import Foundation

/// Read-only observations. A video connection is independent of access to the
/// monitor's USB controller, and neither establishes a useful physical picture.
public struct MonitorConnectionSnapshot: Encodable {
    public let schemaVersion = 1
    public let checkedAt: Date
    public let localVideo: MonitorVideoObservation
    public let usbControl: MonitorControlConnection
    public let machines: [MachineConnectionObservation]
    public let registryError: String?

    public var complete: Bool {
        registryError == nil && localVideo.state != .unknown && localVideo.connectorError == nil
            && usbControl.local.state != .unavailable && usbControl.upstream.state != .unavailable
            && usbControl.layoutError == nil && machines.allSatisfy {
                $0.video != .unknown && $0.error == nil && !$0.connectors.contains { $0.identificationError != nil }
            }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, checkedAt, complete, localVideo, usbControl, machines, registryError }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(checkedAt, forKey: .checkedAt)
        try values.encode(complete, forKey: .complete)
        try values.encode(localVideo, forKey: .localVideo)
        try values.encode(usbControl, forKey: .usbControl)
        try values.encode(machines, forKey: .machines)
        try values.encodeIfPresent(registryError, forKey: .registryError)
    }
}

public enum MonitorVideoPresence: String, Codable { case detected, notDetected, ambiguous, unknown }

public struct MonitorVideoObservation: Encodable {
    public let state: MonitorVideoPresence
    public let computerName: String?
    public let displays: [MonitorDisplayConnection]
    public let error: String?
    public let connectorError: String?

    init(displays result: Result<MacDisplayState, Error>, links: MacVideoConnectionSnapshot) {
        if case .failed(_, let message) = links.outcome { connectorError = message } else { connectorError = nil }
        switch result {
        case .failure(let failure):
            state = .unknown; computerName = nil; displays = []; error = failure.localizedDescription
        case .success(let snapshot):
            computerName = snapshot.computerName; error = nil
            let matches = snapshot.displays.filter(\.isMonitor)
            state = matches.isEmpty ? .notDetected : matches.count == 1 ? .detected : .ambiguous
            displays = matches.map { display in
                let matchingLinks = links.connections.filter {
                    $0.display.vendorID == display.vendor && $0.display.productID == display.model
                }
                let uniqueDisplay = snapshot.displays.filter { $0.vendor == display.vendor && $0.model == display.model }.count == 1
                let link = links.outcome == .complete && uniqueDisplay && matchingLinks.count == 1 ? matchingLinks[0] : nil
                return MonitorDisplayConnection(display: display, link: link,
                    ambiguous: !uniqueDisplay || matchingLinks.count > 1)
            }
        }
    }
}

/// Host connector names and HDMI CEC topology are evidence, not the monitor's
/// validated OSD layout. Inferences must never authorize an input or USB write.
public struct MonitorDisplayConnection: Encodable {
    public enum Source: String, Encodable { case macOS, linuxDRM }
    public enum Association: String, Encodable { case uniqueModelCandidate, sourceReported, ambiguous, unknown }
    public let source: Source
    public let display: MacDisplayInfo?
    public let hostConnector: String?
    public let transport: VideoTransport
    public let identification: DisplayIdentification?
    public let association: Association
    public let inferredMonitorInput: Input?
    public let inputEvidence: String?
    public let inputLimitation: String

    init(display: MacDisplayInfo, link: MacVideoConnection?, ambiguous: Bool) {
        source = .macOS; self.display = display; hostConnector = link?.hostPort
        transport = link?.transport ?? .unknown; identification = link?.display
        association = ambiguous ? .ambiguous : link == nil ? .unknown : .uniqueModelCandidate
        inferredMonitorInput = ambiguous ? nil : Self.inferredInput(identification, transport: transport)
        inputEvidence = inferredMonitorInput == nil ? nil : "edidHDMIPhysicalAddress"
        inputLimitation = Self.limitation
    }

    init(connector: LinuxDisplayConnector) {
        source = .linuxDRM; display = nil; hostConnector = connector.id
        if connector.id.contains("-HDMI-") { transport = .hdmi }
        else if connector.id.contains("-DP-") { transport = .displayPort }
        else { transport = .unknown }
        identification = connector.identification
        association = .sourceReported
        inferredMonitorInput = Self.inferredInput(identification, transport: transport)
        inputEvidence = inferredMonitorInput == nil ? nil : "edidHDMIPhysicalAddress"
        inputLimitation = Self.limitation
    }

    private static let limitation = "HDMI topology may suggest an input; it does not verify the monitor's printed port label or selected layout. Host connector numbers are not monitor input numbers."

    private static func inferredInput(_ identity: DisplayIdentification?, transport: VideoTransport) -> Input? {
        guard transport == .hdmi, let identity, identity.vendorID == 0x3669, identity.productID == 0x30c5,
              let address = identity.hdmiPhysicalAddress?.rawValue, address & 0x0fff == 0 else { return nil }
        switch address >> 12 {
        case 1: return .hdmi1
        case 2: return .hdmi2
        default: return nil
        }
    }
}

public struct ConnectionEndpointObservation: Encodable, Equatable {
    public enum State: String, Encodable { case available, absent, unavailable, notChecked }
    public let state: State
    public let error: String?

    init(_ state: State, error: String? = nil) { self.state = state; self.error = error }
}

public struct MonitorControlConnection: Encodable {
    public let local: ConnectionEndpointObservation
    public let upstream: ConnectionEndpointObservation
    public let upstreamMachineID: String?
    public let usb: KVMStatus?
    public let layout: ScreenState?
    public let layoutError: String?
}

public struct MachineConnectionObservation: Encodable {
    public enum Assignment: String, Encodable { case consistentWithInference, conflictsWithInference, unknown }
    public let machineID: String
    public let configuredName: String
    public let observedName: String?
    public let configuredInput: Input?
    public let reachable: Bool?
    public let video: MonitorVideoPresence
    public let displays: [MonitorDisplayConnection]
    public let connectors: [LinuxDisplayConnector]
    public let assignment: Assignment
    public let error: String?

    init(machine: MachineDefinition, status: MachineStatus, localVideo: MonitorVideoObservation?) {
        machineID = machine.id; configuredName = machine.name; configuredInput = machine.input
        observedName = status.observedName; reachable = status.reachable; error = status.error
        connectors = status.connectors
        if let localVideo {
            video = localVideo.state; displays = localVideo.displays
        } else if let snapshot = status.macDisplays {
            let matches = snapshot.displays.filter(\.isMonitor)
            video = matches.isEmpty ? .notDetected : matches.count == 1 ? .detected : .ambiguous
            displays = matches.map { MonitorDisplayConnection(display: $0, link: nil, ambiguous: matches.count > 1) }
        } else if machine.platform == .linux && status.error == nil && machine.access != .videoOnly {
            let connected = status.connectors.filter { $0.status == .connected }
            let matches = connected.filter { $0.identification?.vendorID == 0x3669 && $0.identification?.productID == 0x30c5 }
            displays = matches.map(MonitorDisplayConnection.init(connector:))
            if !matches.isEmpty { video = matches.count == 1 ? .detected : .ambiguous }
            else if connected.contains(where: { $0.identification == nil }) || status.connectors.contains(where: { $0.status == .unknown }) { video = .unknown }
            else { video = .notDetected }
        } else {
            video = .unknown; displays = []
        }
        let inputs = Set(displays.compactMap(\.inferredMonitorInput))
        if video == .detected, inputs.count == 1, let input = inputs.first, let configuredInput {
            assignment = input == configuredInput ? .consistentWithInference : .conflictsWithInference
        } else { assignment = .unknown }
    }
}

/// One shared backend snapshot for CLI and presentation clients. This collector
/// reads no saved assignment as if it were discovery and persists no changes.
public struct MonitorConnectionClient {
    struct Services {
        var displays: () throws -> MacDisplayState
        var links: () -> MacVideoConnectionSnapshot
        var machine: (MachineDefinition) async -> MachineStatus
        var control: (MachineRegistry) async throws -> MonitorControlConnection
    }
    private let services: Services

    public init() {
        services = Services(displays: { try MacDisplayController().state() },
            links: { MacVideoConnectionReader().snapshot() },
            machine: { await MachineStatusClient().state(for: $0) },
            control: { try await KVMCoordinator(registry: $0).inspectConnection() })
    }
    init(services: Services) { self.services = services }

    public func snapshot(registry source: Result<MachineRegistry, Error>) async -> MonitorConnectionSnapshot {
        // A broken saved registry cannot hide independently observed local
        // video. Only validated definitions may cause a remote query.
        let validated = source.flatMap { registry in Result { try registry.validate(); return registry } }
        let registry: MachineRegistry
        let registryError: String?
        switch validated {
        case .success(let value): registry = value; registryError = nil
        case .failure(let error): registry = MachineRegistry(machines: []); registryError = error.localizedDescription
        }
        let services = services
        let local = await Task.detached { (Result { try services.displays() }, services.links()) }.value
        let video = MonitorVideoObservation(displays: local.0, links: local.1)
        async let controlResult: Result<MonitorControlConnection, Error> = {
            do { return .success(try await services.control(registry)) }
            catch { return .failure(error) }
        }()
        var statuses: [String: MachineStatus] = [:]
        await withTaskGroup(of: (String, MachineStatus).self) { group in
            for machine in registry.machines {
                if machine.isLocal {
                    switch local.0 {
                    case .success(let displays):
                        statuses[machine.id] = MachineStatus(machine: machine, macDisplays: displays)
                    case .failure(let error):
                        statuses[machine.id] = MachineStatus(machineID: machine.id,
                            configuredName: machine.name, observedName: nil, platform: .macos,
                            checkedAt: Date(), reachable: nil, user: nil, architecture: nil,
                            macDisplays: nil, connectors: [], error: error.localizedDescription)
                    }
                } else {
                    group.addTask { (machine.id, await services.machine(machine)) }
                }
            }
            for await (id, status) in group { statuses[id] = status }
        }
        let control: MonitorControlConnection
        switch await controlResult {
        case .success(let value): control = value
        case .failure(let error):
            control = MonitorControlConnection(local: .init(.unavailable, error: error.localizedDescription),
                upstream: .init(.notChecked), upstreamMachineID: registry.usbUpstreamMachineID,
                usb: nil, layout: nil, layoutError: nil)
        }
        return MonitorConnectionSnapshot(checkedAt: Date(), localVideo: video, usbControl: control,
            machines: registry.machines.compactMap { machine in
                statuses[machine.id].map { MachineConnectionObservation(machine: machine, status: $0, localVideo: machine.isLocal ? video : nil) }
            }, registryError: registryError)
    }
}
