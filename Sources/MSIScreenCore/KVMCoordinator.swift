import Foundation

public enum KVMControlHost: String, Codable { case local, upstream }

public struct KVMStatus: Codable, Equatable {
    public let schemaVersion: Int
    public let model: String
    public let protocolVersion: String
    public let route: KVMRoute
    public let controlHost: KVMControlHost
    public let machineID: String?

    init(_ snapshot: KVMSnapshot, host: KVMControlHost, machineID: String?) {
        schemaVersion = 1
        model = snapshot.model
        protocolVersion = snapshot.protocolVersion
        route = snapshot.route
        controlHost = host
        self.machineID = machineID
    }
}

public struct KVMChangeResult: Codable {
    public let schemaVersion: Int
    public let before: KVMStatus
    public let after: KVMStatus?
    public let target: KVMRoute
    public let dryRun: Bool
    /// True also when a dispatched SSH setter loses its response: the write
    /// cannot be excluded, so callers must never automatically repeat it.
    public let writeAttempted: Bool
    public let writeCompleted: Bool
    public let acknowledged: Bool
    public let verified: Bool
    public let error: String?
}

struct KVMWriteReceipt {
    let attempted: Bool
    let completed: Bool
    let acknowledged: Bool
    let error: String?
}

protocol KVMEndpoint {
    func status(timeout: TimeInterval) async throws -> KVMSnapshot?
    func layout(timeout: TimeInterval) async throws -> ScreenState
    func write(target: KVMRoute, expected: KVMRoute, expectedLayout: ScreenState?,
               checkRegistry: @escaping () throws -> Void) async throws -> KVMWriteReceipt
}

/// One explicit USB handoff followed only by reads on the receiving computer.
/// No HID connection survives an await or crosses between worker threads.
public struct KVMCoordinator {
    public static let didChangeNotification = Notification.Name("com.danielsivan.msi-screen.kvm-changed")
    public let upstreamMachine: MachineDefinition?
    private let registry: MachineRegistry
    private let local: any KVMEndpoint
    private let remote: (any KVMEndpoint)?
    private let checkRegistry: () throws -> Void
    private let wait: () async throws -> Void
    private let announce: () -> Void

    public init(registry: MachineRegistry, upstreamMachineID: String? = nil,
                registryStore: MachineRegistryStore = MachineRegistryStore()) throws {
        try registry.validate()
        let machine = try Self.upstream(in: registry, id: upstreamMachineID)
        self.init(registry: registry, upstreamMachine: machine, local: LocalKVMEndpoint(),
                  remote: machine.map { RemoteKVMEndpoint(host: $0.host!) },
                  checkRegistry: {
                      guard try registryStore.load() == registry else {
                          throw ScreenError.message("Machine assignments changed since planning; refresh before switching USB")
                      }
                  }, wait: { try await Task.sleep(nanoseconds: 500_000_000) },
                  announce: Self.postChangeNotification)
    }

    init(registry: MachineRegistry, upstreamMachine: MachineDefinition?,
         local: any KVMEndpoint, remote: (any KVMEndpoint)?,
         checkRegistry: @escaping () throws -> Void,
         wait: @escaping () async throws -> Void,
         announce: @escaping () -> Void = {}) {
        self.registry = registry
        self.upstreamMachine = upstreamMachine
        self.local = local
        self.remote = remote
        self.checkRegistry = checkRegistry
        self.wait = wait
        self.announce = announce
    }

    static func postChangeNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            didChangeNotification, object: String(ProcessInfo.processInfo.processIdentifier),
            userInfo: nil, deliverImmediately: true)
    }

    private static func upstream(in registry: MachineRegistry, id: String?) throws -> MachineDefinition? {
        if let id {
            let machine = try registry.machine(id: id)
            guard machine.platform == .linux, machine.host != nil else {
                throw ScreenError.message("The USB-B machine must be a Linux machine with an SSH host")
            }
            return machine
        }
        let candidates = registry.machines.filter { $0.platform == .linux }
        guard candidates.count <= 1 else {
            throw ScreenError.message("Choose the Linux USB-B machine with --machine ID")
        }
        return candidates.first
    }

    public func status() async throws -> KVMStatus {
        // Only a genuinely absent local controller permits a remote fallback.
        // Busy, malformed replies and an unsupported model remain errors.
        if let snapshot = try await local.status(timeout: 12) {
            return observation(snapshot, host: .local)
        }
        guard let remote else {
            throw ScreenError.message("USB controller is absent from this Mac; configure the Linux USB-B machine")
        }
        guard let snapshot = try await remote.status(timeout: 12) else {
            throw ScreenError.message("USB controller is absent from both configured computers")
        }
        return observation(snapshot, host: .upstream)
    }

    /// Read the full layout from the computer currently owning the USB hub.
    public func layout() async throws -> ScreenState {
        let current = try await status()
        return try await layout(owner: current.controlHost)
    }

    func layout(owner: KVMControlHost) async throws -> ScreenState {
        let endpoint: any KVMEndpoint
        if owner == .local {
            endpoint = local
        } else if let remote {
            endpoint = remote
        } else {
            throw ScreenError.message("Configure the Linux USB-B machine before reading its monitor")
        }
        let state = try await endpoint.layout(timeout: 15)
        try Self.validateLayout(state)
        return state
    }

    static func validateLayout(_ state: ScreenState) throws {
        guard state.model == "MD342CQP", state.protocolVersion == "V20",
              (0...2).contains(state.pipSize), (0...3).contains(state.pipPosition) else {
            throw ScreenError.message("Unsupported monitor identity or layout fields")
        }
    }

    public func set(target: KVMRoute, expected: KVMRoute,
                    dryRun: Bool = false,
                    expectedLayout: ScreenState? = nil,
                    announceChange: Bool = true) async throws -> KVMChangeResult {
        guard target != .auto else {
            throw ScreenError.message("Auto is read-only; choose USB-C or USB-B upstream explicitly")
        }
        guard registry.machines.contains(where: {
            $0.isLocal && $0.platform == .macos && $0.input == .usbc
        }), let remote, upstreamMachine != nil else {
            throw ScreenError.message("USB switching requires this Mac assigned to USB-C and a Linux USB-B machine")
        }
        let before = try await status()
        guard before.route == expected else {
            throw ScreenError.message("USB route changed since planning; refresh before switching")
        }
        if let expectedLayout {
            try Self.validateLayout(expectedLayout)
            guard before.controlHost == .local else {
                throw ScreenError.message("The guarded video-to-USB handoff requires this Mac to own the controller")
            }
            if dryRun || before.route == target {
                guard try await layout(owner: .local) == expectedLayout else {
                    throw ScreenError.message("Monitor changed before switching USB; refresh before switching")
                }
            }
        }
        try checkRegistry()
        if dryRun || before.route == target {
            return result(before, after: dryRun ? nil : before, target: target,
                          dryRun: dryRun, receipt: nil, verified: !dryRun, error: nil)
        }
        // Before moving USB off this Mac, prove the remote helper is reachable.
        // A missing controller is expected while the hub is still on USB-C.
        if target == .upstream {
            _ = try await remote.status(timeout: 12)
        }
        try checkRegistry()
        try Task.checkCancellation()
        let sender = before.controlHost == .local ? local : remote
        let receipt = try await sender.write(target: target, expected: expected,
                                             expectedLayout: expectedLayout,
                                             checkRegistry: checkRegistry)
        guard receipt.attempted else {
            return result(before, after: nil, target: target, dryRun: false,
                          receipt: receipt, verified: false,
                          error: receipt.error ?? "No USB switch was sent; refresh its status")
        }

        let destination = target == .usbc ? local : remote
        let destinationHost: KVMControlHost = target == .usbc ? .local : .upstream
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var lastError = receipt.error
        var after: KVMStatus?
        // USB re-enumeration is expected after handoff. These are fresh reads,
        // never repetitions of the route command.
        for attempt in 0..<6 {
            do {
                try Task.checkCancellation()
                let remaining = max(0.1, deadline - ProcessInfo.processInfo.systemUptime)
                let snapshot = try await destination.status(timeout: min(12, remaining))
                if let snapshot {
                    // This model moves its controller with the hub. A reply
                    // from the old host cannot prove destination enumeration.
                    after = observation(snapshot, host: destinationHost)
                    if snapshot.route == target {
                        if announceChange { announce() }
                        return result(before, after: after, target: target, dryRun: false,
                                      receipt: receipt, verified: true, error: nil)
                    }
                    lastError = "Receiving computer reports USB route \(snapshot.route.rawValue)"
                } else {
                    lastError = "USB controller has not appeared on the receiving computer"
                }
            } catch {
                lastError = String(describing: error)
                if error is CancellationError { break }
            }
            guard attempt < 5, ProcessInfo.processInfo.systemUptime < deadline else { break }
            do { try await wait() } catch {
                lastError = "USB verification was interrupted after the switch"
                break
            }
        }
        return result(before, after: after, target: target, dryRun: false,
                      receipt: receipt, verified: false,
                      error: "USB switch is unverified. \(lastError ?? "Read status on the receiving computer"). No change was repeated.")
    }

    private func observation(_ snapshot: KVMSnapshot, host: KVMControlHost) -> KVMStatus {
        KVMStatus(snapshot, host: host,
                  machineID: host == .upstream ? upstreamMachine?.id :
                    registry.machines.first(where: \.isLocal)?.id)
    }

    private func result(_ before: KVMStatus, after: KVMStatus?, target: KVMRoute,
                        dryRun: Bool, receipt: KVMWriteReceipt?, verified: Bool,
                        error: String?) -> KVMChangeResult {
        KVMChangeResult(schemaVersion: 1, before: before, after: after, target: target,
                        dryRun: dryRun, writeAttempted: receipt?.attempted ?? false,
                        writeCompleted: receipt?.completed ?? false,
                        acknowledged: receipt?.acknowledged ?? false,
                        verified: verified, error: error)
    }
}

struct LocalKVMEndpoint: KVMEndpoint {
    private static let queue = DispatchQueue(label: "MSIScreen.KVM-USB", qos: .userInitiated)
    final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        func check() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }

    func status(timeout: TimeInterval) async throws -> KVMSnapshot? {
        try await Self.run {
            do {
                let connection = try HIDConnection(replyBudget: timeout)
                return try ScreenController(transport: connection).kvmStatus()
            } catch HIDConnectionError.notPresent {
                return nil
            }
        }
    }

    func layout(timeout: TimeInterval) async throws -> ScreenState {
        try await Self.run {
            let connection = try HIDConnection(replyBudget: timeout)
            return try ScreenController(transport: connection).state()
        }
    }

    func write(target: KVMRoute, expected: KVMRoute, expectedLayout: ScreenState?,
               checkRegistry: @escaping () throws -> Void) async throws -> KVMWriteReceipt {
        try await Self.runCancellable { cancellation in
            try checkRegistry()
            let connection = try HIDConnection()
            let controller = ScreenController(transport: connection)
            let before = try controller.kvmStatus()
            guard before.route == expected else {
                throw ScreenError.message("USB route changed before writing; refresh before switching")
            }
            if let expectedLayout, try controller.state() != expectedLayout {
                throw ScreenError.message("Monitor changed before switching USB; refresh before switching")
            }
            // The video guard and registry guard belong in the actual setter
            // session, after any SSH preflight or queue delay.
            try checkRegistry()
            try cancellation.check()
            return connection.writeKVM(target)
        }
    }

    static func runCancellable<T>(
        _ operation: @escaping (CancellationGate) throws -> T
    ) async throws -> T {
        let cancellation = CancellationGate()
        return try await withTaskCancellationHandler {
            try await run {
                try cancellation.check()
                return try operation(cancellation)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func run<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

struct RemoteKVMEndpoint: KVMEndpoint {
    let host: String

    struct Request: Encodable {
        let schemaVersion = 1
        let action: String
        let expected: KVMRoute?
        let target: KVMRoute?
    }
    struct Response: Decodable {
        struct State: Decodable {
            let model: String
            let protocolVersion: String
            let kvm: KVMRoute
        }
        struct Failure: Decodable { let code: String; let message: String }
        let schemaVersion: Int
        let action: String
        let present: Bool
        let accessible: Bool
        let state: State?
        let writeAttempted: Bool
        let writeCompleted: Bool
        let acknowledged: Bool
        let verified: Bool
        let outcome: String
        let error: Failure?
    }

    func status(timeout: TimeInterval) async throws -> KVMSnapshot? {
        let output = try await send(Request(action: "status", expected: nil, target: nil), timeout: timeout)
        let response = try Self.decode(output, action: "status")
        guard output.succeeded, response.error == nil else {
            throw ScreenError.message(response.error?.message ?? "Linux USB status failed")
        }
        if !response.present, !response.accessible, response.state == nil,
           response.outcome == "not_present", !response.verified { return nil }
        guard response.present, response.accessible, response.verified,
              let state = response.state else {
            throw ScreenError.message("Linux USB status did not verify the controller")
        }
        return try Self.snapshot(state)
    }

    func layout(timeout: TimeInterval) async throws -> ScreenState {
        let output = try await send(Request(action: "layout", expected: nil, target: nil),
                                    timeout: timeout)
        return try Self.decodeLayout(output)
    }

    static func decodeLayout(_ output: ProcessRunner.Output) throws -> ScreenState {
        struct Response: Decodable {
            let schemaVersion: Int
            let action: String
            let model: String
            let protocolVersion: String
            let layout: ScreenState
        }
        guard output.succeeded, !output.truncated, output.text.utf8.count <= 16_384 else {
            throw ScreenError.message("Linux monitor layout request failed or exceeded its limit")
        }
        try rejectDuplicateKeys(output.text)
        guard let data = output.text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "action", "model", "protocolVersion", "layout"],
              let fields = object["layout"] as? [String: Any],
              Set(fields.keys) == ["model", "protocolVersion", "mode", "source1", "source2",
                                   "pipInput", "pipSize", "pipPosition"],
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.schemaVersion == 1, response.action == "layout",
              response.model == "MD342CQP", response.protocolVersion == "V20" else {
            throw ScreenError.message("Linux returned an invalid monitor layout response")
        }
        try KVMCoordinator.validateLayout(response.layout)
        return response.layout
    }

    func write(target: KVMRoute, expected: KVMRoute, expectedLayout: ScreenState?,
               checkRegistry: @escaping () throws -> Void) async throws -> KVMWriteReceipt {
        guard expectedLayout == nil else {
            throw ScreenError.message("Guarded video handoff must be sent by the local USB controller")
        }
        try checkRegistry()
        try Task.checkCancellation()
        let response: Response
        do {
            let output = try await send(Request(action: "setKVM", expected: expected, target: target), timeout: 25)
            response = try Self.decode(output, action: "setKVM")
            if let state = response.state { _ = try Self.snapshot(state) }
        } catch {
            // SSH may fail after the helper sent the command. Missing output
            // must remain uncertain, never authorize a second setter.
            return KVMWriteReceipt(attempted: true, completed: false,
                                   acknowledged: false, error: String(describing: error))
        }
        return KVMWriteReceipt(attempted: response.writeAttempted, completed: response.writeCompleted,
                               acknowledged: response.acknowledged, error: response.error?.message)
    }

    private func send(_ request: Request, timeout: TimeInterval) async throws -> ProcessRunner.Output {
        try RemoteMacClient(host: host).validateHost()
        return try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: Self.arguments(host: host), timeout: timeout,
            input: JSONEncoder().encode(request), outputLimit: 16_384)
    }

    static func arguments(host: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
         "-o", "LogLevel=ERROR", "--", host,
         #"if [ ! -x "$HOME/.local/share/msi-screen-control/msi-screen-kvm" ]; then printf '%s\n' MSI_SCREEN_KVM_HELPER_MISSING >&2; exit 127; fi; exec "$HOME/.local/share/msi-screen-control/msi-screen-kvm""#]
    }

    static func decode(_ output: ProcessRunner.Output, action: String) throws -> Response {
        guard !output.timedOut else { throw ScreenError.message("Linux USB request timed out") }
        guard !output.truncated else { throw ScreenError.message("Linux USB response exceeded its limit") }
        try rejectDuplicateKeys(output.text)
        guard let data = output.text.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.schemaVersion == 1, response.action == action,
              [0, 2].contains(output.exitCode),
              !response.writeCompleted || response.writeAttempted,
              !response.acknowledged || response.writeCompleted else {
            throw ScreenError.message("Linux returned an invalid USB response; check its KVM companion")
        }
        if action == "status" {
            guard !response.writeAttempted, !response.writeCompleted, !response.acknowledged else {
                throw ScreenError.message("Linux status returned mutation flags")
            }
        } else if response.writeAttempted {
            guard !response.verified,
                  ["sent", "acknowledged", "unverified"].contains(response.outcome) else {
                throw ScreenError.message("Linux returned an inconsistent USB mutation receipt")
            }
        } else {
            guard ["failed", "unchanged"].contains(response.outcome) else {
                throw ScreenError.message("Linux returned an inconsistent USB mutation receipt")
            }
        }
        return response
    }

    // Reject repeated fields within each object. The layout response repeats
    // identity fields legitimately in its nested ScreenState.
    private static func rejectDuplicateKeys(_ text: String) throws {
        let bytes = Array(text.utf8)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 123 { objects.append([]); index += 1; continue }
            if bytes[index] == 125 { if !objects.isEmpty { objects.removeLast() }; index += 1; continue }
            guard bytes[index] == 34 else { index += 1; continue }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { break }
                index += 1
            }
            guard index < bytes.count else { break }
            let end = index
            index += 1
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            if index < bytes.count, bytes[index] == 58 {
                guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...end])),
                      !objects.isEmpty, objects[objects.count - 1].insert(key).inserted else {
                    throw ScreenError.message("Linux returned duplicate USB response fields")
                }
            }
        }
    }

    static func snapshot(_ state: Response.State) throws -> KVMSnapshot {
        guard state.model == "MD342CQP", state.protocolVersion == "V20" else {
            throw ScreenError.message("Linux USB controller is not an MSI MD342CQP / V20")
        }
        return KVMSnapshot(model: state.model, protocolVersion: state.protocolVersion, route: state.kvm)
    }
}
