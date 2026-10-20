import Foundation

public struct LayoutChangeResult: Codable {
    public let schemaVersion: Int
    public let dryRun: Bool
    /// The explicit USB route observed before this operation, when available.
    public let targetUSB: KVMRoute?
    public let beforeUSB: KVMStatus?
    public let afterUSB: KVMStatus?
    public let beforeLayout: ScreenState?
    public let targetLayout: ScreenState
    public let afterLayout: ScreenState?
    public let usbChanges: [KVMChangeResult]
    /// Conservative: a changed video apply was entered, even if its last guard
    /// stopped the first report. It is not a statement that a report arrived.
    public let videoWriteAttempted: Bool
    public let videoVerified: Bool
    /// Complete layout and explicit USB ownership readbacks matched. This does
    /// not prove the physical picture or a keyboard/mouse input event.
    public let verified: Bool
    public let error: String?
}

protocol LayoutVideoEndpoint {
    func apply(target: ScreenState, expected: ScreenState,
               checkRegistry: @escaping () throws -> Void,
               onWriteAttempt: @escaping () -> Void) async throws -> ScreenState
}

/// The HID callback runs on a worker; the coordinator observes it after await,
/// including when an attempted report fails before returning a verified state.
final class LayoutMutationFlag {
    private let lock = NSLock()
    private var attempted = false
    func record() { lock.lock(); attempted = true; lock.unlock() }
    var wasAttempted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attempted
    }
}

/// Change video while preserving the original explicit USB host. Remote control
/// is acquired only for a real change, then returned after verified video. Each
/// failed stage stops in place and preserves its receipt; there is no rollback.
public struct LayoutCoordinator {
    private let kvm: KVMCoordinator
    private let video: any LayoutVideoEndpoint
    private let checkRegistry: () throws -> Void
    private let announce: (_ videoAttempted: Bool) -> Void

    public init(registry: MachineRegistry, upstreamMachineID: String? = nil,
                registryStore: MachineRegistryStore = MachineRegistryStore()) throws {
        let kvm = try KVMCoordinator(registry: registry, upstreamMachineID: upstreamMachineID,
                                     registryStore: registryStore)
        self.init(kvm: kvm, video: LocalLayoutVideoEndpoint(), checkRegistry: {
            guard try registryStore.load() == registry else {
                throw ScreenError.message("Machine assignments changed; refresh before applying the layout")
            }
        }, announce: { videoAttempted in
            KVMCoordinator.postChangeNotification()
            if videoAttempted { ScreenController.postChangeNotification() }
        })
    }

    init(kvm: KVMCoordinator, video: any LayoutVideoEndpoint,
         checkRegistry: @escaping () throws -> Void,
         announce: @escaping (_ videoAttempted: Bool) -> Void = { _ in }) {
        self.kvm = kvm
        self.video = video
        self.checkRegistry = checkRegistry
        self.announce = announce
    }

    public func apply(_ target: ScreenState, from expected: ScreenState,
                      expectedUSB: KVMRoute? = nil,
                      dryRun: Bool = false) async throws -> LayoutChangeResult {
        // Reject malformed identity/geometry and impossible PBP plans before
        // acquiring USB, using the same pure packet validation as the transport.
        _ = try MSIProtocol.layout(target)
        try KVMCoordinator.validateLayout(expected)
        if target.mode == .pbp {
            guard target.source1 != target.source2, target.pipInput == target.source2 else {
                throw ScreenError.message("PBP needs two different inputs and matching secondary registers")
            }
        }

        var beforeUSB: KVMStatus?
        var afterUSB: KVMStatus?
        var beforeLayout: ScreenState?
        var afterLayout: ScreenState?
        var usbChanges: [KVMChangeResult] = []
        var videoWriteAttempted = false
        var videoVerified = false
        var verified = false
        var failure: String?
        let mutation = LayoutMutationFlag()
        // Publish only after every session/await finishes. Intermediate notices
        // can let another app take the HID lock between the owned stages.
        defer {
            if mutation.wasAttempted || usbChanges.contains(where: \.writeAttempted) {
                announce(mutation.wasAttempted)
            }
        }

        do {
            try Task.checkCancellation()
            try checkRegistry()
            let initialUSB = try await kvm.status()
            beforeUSB = initialUSB
            afterUSB = initialUSB
            if let expectedUSB, initialUSB.route != expectedUSB {
                throw ScreenError.message("USB route changed since planning; refresh before applying the layout")
            }
            try Task.checkCancellation()
            let initialLayout = try await kvm.layout(owner: initialUSB.controlHost)
            beforeLayout = initialLayout
            afterLayout = initialLayout
            guard initialLayout == expected else {
                throw ScreenError.message("Monitor changed since planning; refresh before applying the layout")
            }
            try checkRegistry()
            try Task.checkCancellation()
            if target == initialLayout {
                // An already-applied remote layout needs no USB roundtrip or
                // explicit pinning, including when the current policy is Auto.
                if !dryRun {
                    videoVerified = true
                    try Task.checkCancellation()
                    let finalUSB = try await kvm.status()
                    afterUSB = finalUSB
                    guard finalUSB.route == initialUSB.route,
                          finalUSB.controlHost == initialUSB.controlHost else {
                        throw ScreenError.message("USB ownership changed while checking the existing layout")
                    }
                    try checkRegistry()
                    verified = true
                }
            } else {
                guard initialUSB.route != .auto else {
                    throw ScreenError.message("Choose USB-C or USB-B explicitly before applying a layout while preserving USB")
                }
                let originalHost: KVMControlHost = initialUSB.route == .usbc ? .local : .upstream
                guard initialUSB.controlHost == originalHost else {
                    throw ScreenError.message("USB route and controller ownership disagree; refresh before applying the layout")
                }
                if !dryRun {
                    if originalHost == .upstream {
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
                    videoWriteAttempted = true
                    afterLayout = nil
                    let applied = try await video.apply(target: target, expected: initialLayout,
                                                        checkRegistry: checkRegistry,
                                                        onWriteAttempt: mutation.record)
                    afterLayout = applied
                    guard applied == target else {
                        throw ScreenError.message("The complete requested layout was not verified")
                    }
                    videoVerified = true
                    if originalHost == .upstream {
                        try Task.checkCancellation()
                        afterLayout = nil
                        // expectedLayout is checked again inside the actual
                        // local USB setter session, after remote preflight.
                        let handoff = try await kvm.set(target: .upstream, expected: .usbc,
                                                        expectedLayout: target, announceChange: false)
                        usbChanges.append(handoff)
                        afterUSB = handoff.after
                        guard handoff.verified, handoff.after?.route == .upstream,
                              handoff.after?.controlHost == .upstream else {
                            throw ScreenError.message(handoff.error ?? "Layout verified, but returning USB is unverified")
                        }
                    }
                    try Task.checkCancellation()
                    let finalUSB = try await kvm.status()
                    afterUSB = finalUSB
                    guard finalUSB.route == initialUSB.route, finalUSB.controlHost == originalHost else {
                        throw ScreenError.message("USB ownership changed before the final layout check")
                    }
                    try Task.checkCancellation()
                    let finalLayout = try await kvm.layout(owner: finalUSB.controlHost)
                    afterLayout = finalLayout
                    videoVerified = finalLayout == target
                    guard videoVerified else {
                        throw ScreenError.message("Monitor layout changed before final verification")
                    }
                    try Task.checkCancellation()
                    // Status and layout use separate sessions. Check the route
                    // again so an OSD change to Auto cannot pass unnoticed.
                    let finalRoute = try await kvm.status()
                    afterUSB = finalRoute
                    guard finalRoute.route == initialUSB.route, finalRoute.controlHost == originalHost else {
                        throw ScreenError.message("USB ownership changed during the final layout check")
                    }
                    try checkRegistry()
                    verified = true
                }
            }
            if dryRun { afterUSB = nil; afterLayout = nil }
        } catch {
            failure = error is CancellationError
                ? "Layout change was canceled; any completed changes remain in place"
                : String(describing: error)
        }
        return LayoutChangeResult(schemaVersion: 1, dryRun: dryRun, targetUSB: beforeUSB?.route,
                                  beforeUSB: beforeUSB, afterUSB: afterUSB,
                                  beforeLayout: beforeLayout, targetLayout: target, afterLayout: afterLayout,
                                  usbChanges: usbChanges, videoWriteAttempted: videoWriteAttempted,
                                  videoVerified: videoVerified, verified: verified, error: failure)
    }
}

struct LocalLayoutVideoEndpoint: LayoutVideoEndpoint {
    func apply(target: ScreenState, expected: ScreenState,
               checkRegistry: @escaping () throws -> Void,
               onWriteAttempt: @escaping () -> Void) async throws -> ScreenState {
        try await LocalKVMEndpoint.runCancellable { cancellation in
            try checkRegistry()
            return try ScreenController.withHIDConnection(announceChange: false) { controller in
                func requireLocalUSB() throws {
                    guard try controller.kvmStatus().route == .usbc else {
                        throw ScreenError.message("Pin USB to this Mac before changing the monitor layout")
                    }
                }
                try requireLocalUSB()
                try checkRegistry()
                try cancellation.check()
                // Keep USB pinning and full-state comparison in this same
                // synchronous HID session, with the normal settle/readback.
                return try controller.apply(target, from: expected) {
                    try requireLocalUSB()
                    try checkRegistry()
                    try cancellation.check()
                    onWriteAttempt()
                }
            }
        }
    }
}
