import AppKit
import Carbon
import Combine
import MSIScreenCore

/// Enabled wheel control reserves F18/F19; an enabled app pin reserves F20.
/// The menu app must remain open. Neither feature captures arbitrary keys or
/// creates a continuous input listener.
@MainActor
final class AppSwitchController: ObservableObject {
    static let shared = AppSwitchController()
    @Published private(set) var active = false
    @Published private(set) var error: String?
    @Published private(set) var mode: RapooWheelHostAction = .applications
    /// Accepted activation requests; this alone does not prove foreground delivery.
    @Published private(set) var switchCount = 0
    @Published private(set) var lastApplication: String?
    /// Posted Control–Arrow requests, not verified changes of the active Space.
    @Published private(set) var spaceRequestCount = 0
    @Published private(set) var lastSpaceDirection: String?
    @Published private(set) var pinActive = false
    @Published private(set) var pinnedApplicationBundleID: String?
    /// Activation/open requests issued, not verified foreground delivery.
    @Published private(set) var pinRequestCount = 0
    @Published private(set) var lastPinnedApplication: String?
    @Published private(set) var lastPinError: String?

    private var hotKeys: [EventHotKeyRef] = []
    private var pinHotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?
    private var cycle = AppCycleState<NSRunningApplication>()
    private var lastSpaceRequest: TimeInterval?
    private var pinGeneration = 0
    private var pinLaunchInProgress = false

    private init() {}

    func start(mode requestedMode: RapooWheelHostAction = .applications) throws {
        // Preflight never prompts or changes TCC. A failed mode change preserves
        // the currently registered action instead of silently falling back.
        if requestedMode == .spaces, !CGPreflightPostEventAccess() {
            throw failure(Self.spacesPermissionMessage)
        }
        error = nil
        if active {
            if mode != requestedMode { configureMode(requestedMode) }
            return
        }
        // A failed cleanup retains its owned references so start cannot create
        // a second registration on top of resources it could not release.
        let priorCleanup = removeWheelRegistrations()
        guard priorCleanup.isEmpty else { throw failure(priorCleanup.joined(separator: " ")) }

        do {
            try installHandlerIfNeeded()
            for (code, id, name) in [(kVK_F18, UInt32(1), "F18"), (kVK_F19, UInt32(2), "F19")] {
                var reference: EventHotKeyRef?
                let registered = RegisterEventHotKey(
                    UInt32(code), 0, EventHotKeyID(signature: appSwitchSignature, id: id),
                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                guard registered == noErr, let reference else {
                    throw AppSwitchFailure.message(
                        "\(name) could not be reserved for app switching (OSStatus \(registered)). " +
                        "It may already be assigned to another app.")
                }
                hotKeys.append(reference)
            }
        } catch {
            let cleanup = removeWheelRegistrations()
            throw failure(([error.localizedDescription] + cleanup).joined(separator: " "))
        }

        configureMode(requestedMode)
        active = true
    }

    private func configureMode(_ newMode: RapooWheelHostAction) {
        removeActivationObserver()
        cycle.reset()
        lastSpaceRequest = nil
        mode = newMode
        guard newMode == .applications else { return }
        let applications = eligibleApplications()
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            cycle.recordActivation(frontmost, live: Set(applications))
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // NSWorkspace delivers this observer on the explicitly requested main queue.
            MainActor.assumeIsolated {
                guard let self, self.active,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.cycle.recordActivation(app, live: Set(self.eligibleApplications()))
            }
        }
    }

    /// Restoring horizontal scrolling must not disable an independent app pin.
    func stopWheel() {
        active = false
        removeActivationObserver()
        cycle.reset()
        lastSpaceRequest = nil
        let failures = removeWheelRegistrations()
        error = failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    func stop() {
        stopWheel()
        unpinApplication()
    }

    /// Reserve F20 only after validating the installed app. Call this before
    /// writing an F20 mapping to the mouse, so a conflict cannot strand its button.
    func pinApplication(bundleIdentifier: String) throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
            let message = "The app \(bundleIdentifier) is not installed on this Mac."
            lastPinError = message
            throw AppSwitchFailure.message(message)
        }
        if pinActive, pinnedApplicationBundleID == bundleIdentifier {
            lastPinError = nil
            return
        }
        if pinHotKey == nil {
            do {
                try installHandlerIfNeeded()
                var reference: EventHotKeyRef?
                let status = RegisterEventHotKey(UInt32(kVK_F20), 0,
                    EventHotKeyID(signature: appSwitchSignature, id: 3),
                    GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                guard status == noErr, let reference else {
                    throw AppSwitchFailure.message(
                        "F20 could not be reserved for the pinned app (OSStatus \(status)). It may already be assigned.")
                }
                pinHotKey = reference
            } catch {
                let cleanup = removeHandlerIfUnused()
                let message = ([error.localizedDescription] + cleanup).joined(separator: " ")
                lastPinError = message
                throw AppSwitchFailure.message(message)
            }
        }
        pinGeneration += 1
        pinLaunchInProgress = false
        pinnedApplicationBundleID = bundleIdentifier
        pinActive = true
        lastPinError = nil
    }

    func unpinApplication() {
        pinActive = false
        pinGeneration += 1
        pinLaunchInProgress = false
        var failures: [String] = []
        if let pinHotKey {
            let status = UnregisterEventHotKey(pinHotKey)
            if status == noErr { self.pinHotKey = nil }
            else { failures.append("Could not release F20 (OSStatus \(status)).") }
        }
        failures += removeHandlerIfUnused()
        if pinHotKey == nil { pinnedApplicationBundleID = nil }
        lastPinError = failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    fileprivate func receiveHotKey(_ id: UInt32) {
        if id == 3 {
            activatePinnedApplication()
            return
        }
        guard active, id == 1 || id == 2 else { return }
        if mode == .spaces {
            postSpaceShortcut(direction: id == 1 ? -1 : 1)
            return
        }
        let applications = eligibleApplications()
        guard let target = cycle.next(
            applications: applications, frontmost: NSWorkspace.shared.frontmostApplication,
            direction: id == 1 ? -1 : 1, now: ProcessInfo.processInfo.systemUptime
        ) else { return }

        let accepted: Bool
        if #available(macOS 14, *) {
            accepted = target.activate(options: [])
        } else {
            accepted = target.activate(options: [.activateIgnoringOtherApps])
        }
        // This is an accepted activation request, not proof that the app became
        // frontmost. Workspace notifications supply the subsequent MRU history.
        error = accepted ? nil : "macOS did not accept switching to \(target.localizedName ?? "that app")."
        if accepted {
            switchCount += 1
            lastApplication = target.localizedName ?? target.bundleIdentifier
        }
    }

    private func activatePinnedApplication() {
        guard pinActive, !pinLaunchInProgress, let bundleID = pinnedApplicationBundleID else { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            let accepted: Bool
            if #available(macOS 14, *) { accepted = app.activate(options: []) }
            else { accepted = app.activate(options: [.activateIgnoringOtherApps]) }
            pinRequestCount += 1
            lastPinnedApplication = app.localizedName ?? bundleID
            lastPinError = accepted ? nil : "macOS did not accept activating \(lastPinnedApplication ?? bundleID)."
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: url)?.bundleIdentifier == bundleID else {
            lastPinError = "The pinned app \(bundleID) is no longer installed."
            return
        }
        let generation = pinGeneration
        pinLaunchInProgress = true
        pinRequestCount += 1
        lastPinnedApplication = bundleID
        lastPinError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self, self.pinActive, self.pinGeneration == generation else { return }
                self.pinLaunchInProgress = false
                self.lastPinnedApplication = app?.localizedName ?? bundleID
                self.lastPinError = error?.localizedDescription
                if app == nil, error == nil { self.lastPinError = "macOS did not return the launched app." }
            }
        }
    }

    private static let spacesPermissionMessage =
        "Spaces control needs Accessibility permission for MSI Screen in System Settings → Privacy & Security → Accessibility. " +
        "Then enable Spaces control again. Control–Left/Right must be enabled in Keyboard Shortcuts → Mission Control."

    private func postSpaceShortcut(direction: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        // Bound rapid wheel input without a queue, timer, or idle work.
        if let lastSpaceRequest, now - lastSpaceRequest < 0.25 { return }
        guard CGPreflightPostEventAccess() else {
            stopWheel()
            error = ([Self.spacesPermissionMessage] + [error].compactMap { $0 }).joined(separator: " ")
            return
        }
        guard let events = Self.spaceShortcutEvents(direction: direction) else {
            error = "Could not create the Spaces keyboard shortcut."
            return
        }
        // CGEventPost has no delivery receipt. System shortcut configuration,
        // transition animation, and the desktop edge determine the visible result.
        for event in events { event.post(tap: .cghidEventTap) }
        lastSpaceRequest = now
        spaceRequestCount += 1
        lastSpaceDirection = direction < 0 ? "left" : "right"
        error = nil
    }

    /// Constructs a balanced sequence without posting it, so it can be checked
    /// without changing focus. Allocate every event before sending any key down.
    static func spaceShortcutEvents(direction: Int) -> [CGEvent]? {
        // Mission Control ignores our private-source Control–Arrow events on
        // macOS 26.5. Use HID system state and the flag carried by physical
        // arrow keys; ordinary app shortcuts do not expose this difference.
        guard direction == -1 || direction == 1,
              let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        let arrow = CGKeyCode(direction < 0 ? kVK_LeftArrow : kVK_RightArrow)
        guard let controlDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: true),
              let arrowDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true),
              let arrowUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: false) else {
            return nil
        }
        controlDown.flags = .maskControl
        arrowDown.flags = [.maskControl, .maskSecondaryFn]
        arrowUp.flags = [.maskControl, .maskSecondaryFn]
        controlUp.flags = []
        return [controlDown, arrowDown, arrowUp, controlUp]
    }

    private func eligibleApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            // Workspace has no historical MRU API. Previously unobserved apps
            // get a deterministic order; observed activations take precedence.
            let left = $0.localizedName ?? $0.bundleIdentifier ?? ""
            let right = $1.localizedName ?? $1.bundleIdentifier ?? ""
            let comparison = left.localizedStandardCompare(right)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.processIdentifier < $1.processIdentifier
        }
    }

    private func failure(_ description: String) -> AppSwitchFailure {
        error = description
        return .message(description)
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), appSwitchHotKeyHandler,
                                        1, &event, nil, &handler)
        guard status == noErr else {
            throw AppSwitchFailure.message("Could not install side-wheel/button hotkeys (OSStatus \(status)).")
        }
    }

    private func removeWheelRegistrations() -> [String] {
        var failures: [String] = []
        var retained: [EventHotKeyRef] = []
        for key in hotKeys.reversed() {
            let status = UnregisterEventHotKey(key)
            if status != noErr {
                retained.append(key)
                failures.append("Could not release an app-switch hotkey (OSStatus \(status)).")
            }
        }
        hotKeys = retained.reversed()
        failures += removeHandlerIfUnused()
        return failures
    }

    private func removeHandlerIfUnused() -> [String] {
        guard hotKeys.isEmpty, pinHotKey == nil else { return [] }
        var failures: [String] = []
        if let handler {
            // Carbon invalidates the handler reference after this call,
            // including an error return; never keep it for another attempt.
            self.handler = nil
            let status = RemoveEventHandler(handler)
            if status != noErr { failures.append("Could not remove the app-switch event handler (OSStatus \(status)).") }
        }
        return failures
    }
}

private enum AppSwitchFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private let appSwitchSignature: OSType = 0x4D534143 // MSAC

private let appSwitchHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == appSwitchSignature, (1...3).contains(id.id),
          Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
    // The Carbon application event target runs on the main thread. Handling
    // synchronously preserves event order and leaves nothing queued after stop.
    MainActor.assumeIsolated { AppSwitchController.shared.receiveHotKey(id.id) }
    return noErr
}

/// Pure burst state. NSObject's Hashable conformance uses isEqual, so the live
/// controller retains NSRunningApplication identities rather than reusing PIDs.
struct AppCycleState<Application: Hashable> {
    private var recent: [Application] = []
    private var ring: [Application] = []
    private var cursor: Int?
    private var lastPulse: TimeInterval?
    private var lastStep: TimeInterval?

    mutating func reset() { self = Self() }

    mutating func recordActivation(_ app: Application, live: Set<Application>) {
        recent.removeAll { !live.contains($0) || $0 == app }
        if live.contains(app) { recent.insert(app, at: 0) }
        // Deliberately leave the active burst's ring and cursor unchanged.
    }

    mutating func next(applications: [Application], frontmost: Application?,
                       direction: Int, now: TimeInterval) -> Application? {
        guard direction == -1 || direction == 1 else { return nil }
        let live = Set(applications)
        guard !live.isEmpty else { reset(); return nil }
        let rebuild = lastPulse.map { now - $0 >= 0.8 } ?? true
        // Throttled pulses extend the burst without activating another app.
        lastPulse = now
        if let lastStep, now - lastStep < 0.1 { return nil }
        if rebuild || !ring.contains(where: live.contains) {
            recent.removeAll { !live.contains($0) }
            var seen = Set<Application>()
            ring = (recent + applications).filter { seen.insert($0).inserted }
            cursor = frontmost.flatMap { ring.firstIndex(of: $0) }
        }
        guard !ring.isEmpty else { return nil }
        let previous = cursor
        let anchor = cursor ?? (direction > 0 ? -1 : 0)
        for distance in 1...ring.count {
            let next = ((anchor + direction * distance) % ring.count + ring.count) % ring.count
            guard live.contains(ring[next]) else { continue }
            guard next != previous else { return nil }
            cursor = next
            lastStep = now
            return ring[next]
        }
        return nil
    }
}
