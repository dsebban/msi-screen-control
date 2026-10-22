import Foundation

public struct MachineFocusResult: Codable {
    public let schemaVersion: Int
    public let machineID: String
    public let dryRun: Bool
    public let targetInput: Input
    public let targetUSB: KVMRoute
    public let beforeUSB: KVMStatus?
    public let afterUSB: KVMStatus?
    public let beforeLayout: ScreenState?
    public let targetLayout: ScreenState?
    public let afterLayout: ScreenState?
    public let usbChanges: [KVMChangeResult]
    /// Conservative: apply was entered for a changed layout. A later guard
    /// may have stopped it before the first HID report was sent.
    public let videoWriteAttempted: Bool
    public let videoVerified: Bool
    /// Fresh identity, route and complete layout readbacks matched. This does
    /// not prove the physical picture or a keyboard/mouse input event.
    public let verified: Bool
    public let error: String?
}

/// Focus is a sequence of owned, verified stages, not an atomic transaction.
/// A failed stage leaves completed changes in place and reports them; it never
/// replays a write or attempts to roll the monitor back automatically.
public struct MachineFocusCoordinator {
    private let registry: MachineRegistry
    private let kvm: KVMCoordinator
    private let video: any LayoutVideoEndpoint
    private let checkRegistry: () throws -> Void
    private let announce: (_ videoAttempted: Bool) -> Void

    public init(registry: MachineRegistry, upstreamMachineID: String? = nil,
                registryStore: MachineRegistryStore = MachineRegistryStore()) throws {
        let kvm = try KVMCoordinator(registry: registry, upstreamMachineID: upstreamMachineID,
                                     registryStore: registryStore)
        self.init(registry: registry, kvm: kvm, video: LocalLayoutVideoEndpoint(),
                  checkRegistry: {
                      guard try registryStore.load() == registry else {
                          throw ScreenError.message("Machine assignments changed; refresh before focusing a machine")
                      }
                  }, announce: { videoAttempted in
                      KVMCoordinator.postChangeNotification()
                      if videoAttempted { ScreenController.postChangeNotification() }
                  })
    }

    init(registry: MachineRegistry, kvm: KVMCoordinator,
         video: any LayoutVideoEndpoint, checkRegistry: @escaping () throws -> Void,
         announce: @escaping (_ videoAttempted: Bool) -> Void = { _ in }) {
        self.registry = registry
        self.kvm = kvm
        self.video = video
        self.checkRegistry = checkRegistry
        self.announce = announce
    }

    public func focus(machineID: String, expectedUSB: KVMRoute? = nil,
                      expectedLayout: ScreenState? = nil,
                      dryRun: Bool = false) async throws -> MachineFocusResult {
        try registry.validate()
        let machine = try registry.machine(id: machineID)
        guard let input = machine.input else {
            throw ScreenError.message("Assign a monitor input to \(machine.name) before focusing it")
        }
        let targetUSB: KVMRoute
        if machine.isLocal, machine.platform == .macos, machine.input == .usbc {
            targetUSB = .usbc
        } else if machine.isUSBUpstreamCandidate, machine.id == kvm.upstreamMachine?.id {
            targetUSB = .upstream
        } else {
            throw ScreenError.message("Focus supports this USB-C Mac and the configured Linux USB-B machine")
        }
        guard registry.machines.contains(where: {
            $0.isLocal && $0.platform == .macos && $0.input == .usbc
        }), kvm.upstreamMachine != nil else {
            throw ScreenError.message("Focus requires this Mac assigned to USB-C and a Linux USB-B machine")
        }

        var beforeUSB: KVMStatus?
        var afterUSB: KVMStatus?
        var beforeLayout: ScreenState?
        var targetLayout: ScreenState?
        var afterLayout: ScreenState?
        var usbChanges: [KVMChangeResult] = []
        var videoWriteAttempted = false
        var videoVerified = false
        var verified = false
        var failure: String?
        let videoMutation = LayoutMutationFlag()
        // Intermediate USB/layout notifications invite another process to take
        // the HID lock between focus stages. Publish once after all sessions and
        // final reads finish, even if an attempted stage leaves partial state.
        defer {
            if videoMutation.wasAttempted || usbChanges.contains(where: \.writeAttempted) {
                announce(videoMutation.wasAttempted)
            }
        }

        do {
            try Task.checkCancellation()
            try checkRegistry()
            let initialUSB = try await kvm.status()
            beforeUSB = initialUSB
            afterUSB = initialUSB
            if let expectedUSB, initialUSB.route != expectedUSB {
                throw ScreenError.message("USB route changed since planning; refresh before focusing")
            }
            try Task.checkCancellation()
            let initialLayout = try await kvm.layout(owner: initialUSB.controlHost)
            beforeLayout = initialLayout
            afterLayout = initialLayout
            if let expectedLayout, initialLayout != expectedLayout {
                throw ScreenError.message("Monitor changed since planning; refresh before focusing")
            }
            let target = try MachineRouter.target(for: machine, route: .fullscreen, from: initialLayout)
            targetLayout = target
            try checkRegistry()
            try Task.checkCancellation()

            if !dryRun {
                let destinationHost: KVMControlHost = targetUSB == .usbc ? .local : .upstream
                if initialUSB.route == targetUSB, initialUSB.controlHost == destinationHost,
                   initialLayout == target {
                    // In particular, an already-focused Linux computer never
                    // loses USB merely to read a layout the companion can read.
                    videoVerified = true
                    verified = true
                } else {
                    if initialUSB.route != .usbc || initialUSB.controlHost != .local {
                        try Task.checkCancellation()
                        let acquisition = try await kvm.set(target: .usbc, expected: initialUSB.route,
                                                            announceChange: false)
                        usbChanges.append(acquisition)
                        afterUSB = acquisition.after
                        guard acquisition.verified, acquisition.after?.route == .usbc,
                              acquisition.after?.controlHost == .local else {
                            throw ScreenError.message(acquisition.error ?? "Could not acquire USB control on this Mac")
                        }
                    }

                    try Task.checkCancellation()
                    try checkRegistry()
                    videoWriteAttempted = initialLayout != target
                    afterLayout = nil
                    let applied = try await video.apply(target: target, expected: initialLayout,
                                                         checkRegistry: checkRegistry,
                                                         onWriteAttempt: videoMutation.record)
                    afterLayout = applied
                    guard applied == target else {
                        throw ScreenError.message("The complete focused layout was not verified")
                    }
                    videoVerified = true

                    if targetUSB == .upstream {
                        try Task.checkCancellation()
                        // A failed guard or a lost handoff leaves the final
                        // layout unknown. targetLayout + videoVerified retain
                        // the successfully completed local video stage.
                        afterLayout = nil
                        let handoff = try await kvm.set(target: .upstream, expected: .usbc,
                                                        expectedLayout: target, announceChange: false)
                        usbChanges.append(handoff)
                        afterUSB = handoff.after
                        guard handoff.verified, handoff.after?.route == .upstream,
                              handoff.after?.controlHost == .upstream else {
                            throw ScreenError.message(handoff.error ?? "Video changed, but the USB handoff is unverified")
                        }
                    }

                    try Task.checkCancellation()
                    let finalUSB = try await kvm.status()
                    afterUSB = finalUSB
                    guard finalUSB.route == targetUSB, finalUSB.controlHost == destinationHost else {
                        throw ScreenError.message("USB ownership changed before the final focus check")
                    }
                    try Task.checkCancellation()
                    let finalLayout = try await kvm.layout(owner: finalUSB.controlHost)
                    afterLayout = finalLayout
                    videoVerified = finalLayout == target
                    guard videoVerified else {
                        throw ScreenError.message("Monitor layout changed before the final focus check")
                    }
                    try checkRegistry()
                    verified = true
                }
            } else {
                // Planned results intentionally contain no post-mutation state.
                afterUSB = nil
                afterLayout = nil
            }
        } catch {
            failure = error is CancellationError
                ? "Focus was canceled; any completed changes remain in place"
                : String(describing: error)
        }

        return MachineFocusResult(
            schemaVersion: 1, machineID: machineID, dryRun: dryRun,
            targetInput: input, targetUSB: targetUSB,
            beforeUSB: beforeUSB, afterUSB: afterUSB,
            beforeLayout: beforeLayout, targetLayout: targetLayout, afterLayout: afterLayout,
            usbChanges: usbChanges, videoWriteAttempted: videoWriteAttempted,
            videoVerified: videoVerified, verified: verified, error: failure)
    }
}
