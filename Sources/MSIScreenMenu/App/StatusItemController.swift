import AppKit
import SwiftUI
import Combine
import Darwin
import MSIScreenCore

/// Verification-only presentation cannot acquire keyboard/main-window status,
/// including AppKit's automatic launch-time window selection. Production panels
/// retain their existing key eligibility for normal user interaction.
@MainActor
private final class SupportFixturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    let appSettings = AppSettings()
    let store = MonitorStore()
    let videoDiagnostics = VideoDiagnosticsStore()
    let inventory: DeviceInventoryStore
    let deviceControl: DeviceControlStore
    private let preferences: MonitorPreferences
    private let fixture: DeviceSupportVerificationFixture?
    private let updater = AppUpdater()
    private lazy var computers = ComputersStore(preferences: preferences)
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var openWhenReady = false
    private var supervisorExit: DispatchSourceProcess?
    private var idleObservation: AnyCancellable?
    private var supervisorStopped = false
    private var statusObservation: AnyCancellable?
    private var refreshTimer: AnyCancellable?
    private var changeObservers: [NSObjectProtocol] = []
    private var lastIconState: ScreenState?
    private var hasRenderedIcon = false
    private var lastUpdateReady = false
    private var terminationPending = false
    private var terminationObservation: AnyCancellable?
    private var appControl: RapooAppControlServer?
    private var fixtureStopObservation: DispatchSourceFileSystemObject?
    private var fixtureStopRequested = false
    struct FixtureFrontmost: Encodable, Equatable {
        let pid: Int32
        let bundleID: String?
    }
    private var fixtureFrontmostBefore: FixtureFrontmost?
    private var fixtureFrontmostAfter: FixtureFrontmost?
    private var fixtureInitializationComplete = false
    private var fixtureInitializationBackgroundSafe = false
    private var fixtureBackgroundViolation = false
    private var fixtureHealthHeartbeat: AnyCancellable?
    private var fixtureSelectedTab: String?
    private struct FixturePresentationState: Encodable, Equatable {
        let appIsHidden: Bool
        let panelWindowNumber: Int?
        let panelIsVisible: Bool
        let panelIsMiniaturized: Bool
        let panelIsOnActiveSpace: Bool
        let panelOcclusionVisible: Bool
        let selectedTab: String?
    }
    private struct FixturePresentationEvent: Encodable {
        let sequence: UInt64
        let checkedAtMilliseconds: UInt64
        let reason: String
        let state: FixturePresentationState
    }
    private var fixturePresentationEvents: [FixturePresentationEvent] = []
    private var fixtureLastPresentation: FixturePresentationState?
    private var fixturePresentationSequence: UInt64 = 0

    private static func fixtureExternalFrontmost(_ sample: FixtureFrontmost?, pid: Int32, bundleID: String?) -> Bool {
        guard let sample, sample.pid > 0, sample.pid != pid else { return false }
        return bundleID == nil || sample.bundleID != bundleID
    }

    static func fixtureForegroundPreservation(before: FixtureFrontmost?, after: FixtureFrontmost?, fixturePID: Int32,
                                             fixtureBundleID: String?, initializationComplete: Bool, initializationBackgroundSafe: Bool) -> String {
        // Initialization evidence is about the before/settled-after interval,
        // not a promise that the user never changes foreground applications later.
        guard initializationComplete, initializationBackgroundSafe, before == after,
              fixtureExternalFrontmost(before, pid: fixturePID, bundleID: fixtureBundleID),
              fixtureExternalFrontmost(after, pid: fixturePID, bundleID: fixtureBundleID) else { return "INCONCLUSIVE" }
        return "OBSERVED_UNCHANGED"
    }

    static func fixtureBackgroundSafety(current: FixtureFrontmost?, fixturePID: Int32, fixtureBundleID: String?,
                                        appIsActive: Bool, panelIsKey: Bool, violation: Bool) -> String {
        guard !appIsActive, !panelIsKey, !violation,
              fixtureExternalFrontmost(current, pid: fixturePID, bundleID: fixtureBundleID) else { return "INCONCLUSIVE" }
        return "PASS"
    }

    private func fixtureFrontmost() -> FixtureFrontmost? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier > 0, !app.isTerminated else { return nil }
        return FixtureFrontmost(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    // SwiftUI's delegate adaptor constructs through NSObject's init selector.
    override convenience init() { self.init(inventory: nil, deviceControl: nil, preferences: nil) }

    init(inventory: DeviceInventoryStore? = nil, deviceControl: DeviceControlStore? = nil, preferences: MonitorPreferences? = nil) {
        let arguments = CommandLine.arguments
        let admitted: DeviceSupportVerificationFixture?
        if arguments.contains("--support-fixture-receipt") || arguments.contains("--support-fixture-nonce") {
            do {
                guard arguments.filter({ $0 == "--support-fixture-receipt" }).count == 1,
                      arguments.filter({ $0 == "--support-fixture-nonce" }).count == 1,
                      let receipt = arguments.firstIndex(of: "--support-fixture-receipt"), receipt + 1 < arguments.count,
                      let nonce = arguments.firstIndex(of: "--support-fixture-nonce"), nonce + 1 < arguments.count else { throw DeviceContractError.invalid("invalidFixtureReceipt") }
                let context = try DeviceSupportVerificationFixture(receiptPath: arguments[receipt + 1], nonce: arguments[nonce + 1])
                guard Bundle.main.bundleIdentifier == context.bundleIdentifier else { throw DeviceContractError.invalid("fixtureRootMismatch") }
                admitted = context
            } catch { NSLog("Isolated support fixture admission refused; no live fallback."); exit(78) }
        } else { admitted = nil }
        fixture = admitted
        if let fixture = admitted {
            self.inventory = inventory ?? DeviceInventoryStore(services: .fixture(fixture), fixtureLabel: DeviceSupportVerificationFixture.label)
            self.deviceControl = deviceControl ?? DeviceControlStore(services: .fixture(fixture))
            self.preferences = preferences ?? MonitorPreferences(defaults: UserDefaults(suiteName: fixture.bundleIdentifier + ".preferences")!, registryStore: MachineRegistryStore(url: fixture.machineRegistryURL))
        } else {
            self.inventory = inventory ?? DeviceInventoryStore()
            self.deviceControl = deviceControl ?? DeviceControlStore()
            self.preferences = preferences ?? MonitorPreferences()
        }
        super.init()
        configureDeviceOwnership()
    }

    func configureDeviceOwnership() {
        appSettings.deviceInventory = inventory
        if let fixture {
            appSettings.fixtureSkillInstall = { try fixture.installSkill($0) }
            appSettings.fixtureSkillAction = { skill in
                try AgentSkillInstallation(registry: fixture.registry).prospectiveAction(skill: skill,
                    source: AgentSkillInstallation.bundledSkill(skill), destination: fixture.skillsHome.appendingPathComponent(skill.rawValue))
            }
        }
        store.usbUpstreamMachine = { [weak self] in self?.preferences.usbUpstreamMachine }
        store.externalMutationActive = { [weak self] in
            guard let self else { return false }
            return self.deviceControl.busy || self.inventory.managementBusy || self.inventory.handoffBusy || self.computers.isMutating || self.appSettings.hasActiveOperation
        }
        computers.externalMutationActive = { [weak self] in
            guard let self else { return false }
            return self.store.hasActiveOperation || self.deviceControl.busy || self.inventory.managementBusy || self.inventory.handoffBusy || self.appSettings.hasActiveOperation
        }
        deviceControl.externalMutationActive = { [weak self] in
            guard let self else { return false }
            return self.store.hasActiveOperation || self.computers.isMutating || self.inventory.managementBusy || self.inventory.handoffBusy || self.appSettings.hasActiveOperation
        }
        inventory.externalMutationActive = { [weak self] in
            guard let self else { return false }
            return self.store.hasActiveOperation || self.computers.isMutating || self.deviceControl.busy || self.appSettings.hasActiveOperation
        }
        appSettings.externalMutationActive = { [weak self] in
            guard let self else { return false }
            return self.store.hasActiveOperation || self.computers.busy || self.deviceControl.busy || self.inventory.managementBusy || self.inventory.handoffBusy
        }
        inventory.selectionChanged = { [weak self] in self?.synchronizeDeviceSelection() }
        inventory.metadataHint = { [weak self] in self?.deviceControl.externalChange() }
        deviceControl.recheckMetadata = { [weak self] in await self?.inventory.reload() }
    }

    private func synchronizeDeviceSelection() {
        if let endpoint = inventory.selectedEndpoint, let binding = inventory.selectedBinding,
           binding.enabled, let descriptor = inventory.selectedDescriptor {
            deviceControl.select(.init(endpoint: endpoint, binding: binding, descriptor: descriptor))
        } else { deviceControl.select(nil) }
    }

    private var operationChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([store.objectWillChange.eraseToAnyPublisher(), computers.objectWillChange.eraseToAnyPublisher(),
            appSettings.objectWillChange.eraseToAnyPublisher(), deviceControl.objectWillChange.eraseToAnyPublisher(),
            inventory.objectWillChange.eraseToAnyPublisher()]).eraseToAnyPublisher()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if fixture != nil { fixtureFrontmostBefore = fixtureFrontmost() }
        NSApp.setActivationPolicy(.accessory)
        if fixture == nil { inventory.startObservingPassiveChanges() }
        if fixture == nil { appSettings.configureAtFirstLaunch() }
        updater.willShowModalAlert = { [weak self] in self?.hideControls(reason: "updater-modal") }
        if fixture == nil { updater.start() }
        terminationObservation = operationChanges
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main).sink { [weak self] _ in
                guard let self, self.terminationPending, !self.hasActiveOperation else { return }
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        if fixture == nil, UserDefaults.standard.bool(forKey: MonitorStore.appSwitchPreference) {
            try? AppSwitchController.shared.start(mode: store.wheelHostAction)
        }
        if fixture == nil, let bundleID = UserDefaults.standard.string(forKey: MonitorStore.pinnedAppPreference) {
            try? AppSwitchController.shared.pinApplication(bundleIdentifier: bundleID)
        }
        if fixture == nil {
        do {
            appControl = try RapooAppControlServer()
            changeObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: RapooAppControlServer.notificationName, object: nil, queue: .main
            ) { [weak self] notification in
                let id = notification.userInfo?["requestID"] as? String
                let pid = (notification.userInfo?["targetPID"] as? NSNumber)?.int32Value
                guard let id, let pid else { return }
                Task { @MainActor in await self?.handleAppControl(id: id, pid: pid) }
            })
        } catch {
            NSLog("MSI Screen CLI bridge unavailable: %@", error.localizedDescription)
        }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MonitorAppearance.statusImage(for: nil)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggleControls)
        statusItem = item
        statusObservation = Publishers.Merge4(store.$state.map { _ in () }.eraseToAnyPublisher(),
                                              store.$kvm.map { _ in () }.eraseToAnyPublisher(),
                                              computers.objectWillChange.eraseToAnyPublisher(),
                                              preferences.objectWillChange.eraseToAnyPublisher())
            .merge(with: updater.objectWillChange.map { _ in () })
            .merge(with: inventory.objectWillChange.map { _ in () }, deviceControl.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(self.store.state, local: self.computers.local, peer: self.computers.peer)
                self.publishFixtureHealth()
        }

        // A nonactivating panel lets the user keep typing in another app.
        // SwiftUI owns all monitor state; AppKit only owns presentation.
        let frame = NSRect(origin: .zero, size: MonitorAppearance.panelSize)
        let mask: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        let panel: NSPanel
        if fixture != nil { panel = SupportFixturePanel(contentRect: frame, styleMask: mask, backing: .buffered, defer: false) }
        else { panel = NSPanel(contentRect: frame, styleMask: mask, backing: .buffered, defer: false) }
        panel.title = "MSI Screen"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        // Moving to the active Space depends on app activation. This menu-bar
        // app stays inactive, so let its panel join the user's current Space,
        // including a full-screen app's Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let hostingView = NSHostingView(rootView: MonitorView(
            store: store, prefs: preferences, computers: computers, updater: updater, appSettings: appSettings,
            inventory: inventory, deviceControl: deviceControl, videoDiagnostics: videoDiagnostics,
            closeControls: { [weak self] in self?.hideControls(reason: "close-controls-action") },
            fixtureTabObservation: fixture == nil ? nil : { [weak self] tab, reason in
                self?.fixtureSelectedTab = tab
                self?.recordFixturePresentation(reason)
                self?.publishFixtureHealth()
            }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // The full-size SwiftUI surface includes the titlebar inset. Keep the
        // reference proportions independent of AppKit's content-rect conversion.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: MonitorAppearance.panelSize), display: false)
        self.panel = panel
        if fixture == nil { computers.refresh() }
        refreshTimer = Timer.publish(every: 30, tolerance: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.fixture == nil, !self.supervisorStopped else { return }
            if self.panel?.isVisible == true {
                self.computers.refreshTailnet()
                return
            }
            // Read while closed so OSD/CLI changes reach the bar without
            // replacing a draft the user is editing in the open panel.
            self.store.refresh()
        }
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: ScreenController.didChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? String != String(ProcessInfo.processInfo.processIdentifier) else { return }
                Task { @MainActor in if self?.fixture == nil { self?.store.refreshAfterExternalChange() } }
            })
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: KVMCoordinator.didChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? String != String(ProcessInfo.processInfo.processIdentifier) else { return }
                Task { @MainActor in if self?.fixture == nil { self?.store.refreshAfterExternalKVMChange() } }
            })
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: MachineRegistryStore.didChangeNotification,
            object: MachineRegistryStore.defaultURL.standardizedFileURL.path, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.fixture == nil else { return }
                    self.preferences.reload()
                    self.computers.refresh()
                }
            })
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: SupportPackageInstaller.registryDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.inventory.scheduleRefresh() }
            })
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.inventory.scheduleRefresh(stateMayHaveChanged: true) }
            })
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.inventory.scheduleRefresh(stateMayHaveChanged: self.inventory.selectedEndpoint?.kind == .display)
                }
            })
        inventory.refresh()
        observeSupervisor()
        observeFixtureStop()
        if fixture != nil {
            // Showing a key-eligible panel inside didFinishLaunching allowed
            // AppKit's remaining launch processing to select it after our old
            // synchronous snapshot. Show only after that callback has returned.
            for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
                changeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.fixtureBackgroundViolation = true
                        self?.publishFixtureHealth()
                    }
                })
            }
            // Fixture-only passive diagnostics. These notifications establish
            // observed transitions, not who caused them; no input monitoring or recovery.
            for name in [NSApplication.willHideNotification, NSApplication.didHideNotification,
                         NSApplication.willUnhideNotification, NSApplication.didUnhideNotification] {
                changeObservers.append(NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.recordFixturePresentation(name.rawValue); self?.publishFixtureHealth() }
                })
            }
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
                changeObservers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.recordFixturePresentation(name.rawValue); self?.publishFixtureHealth() }
                })
            }
            changeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.recordFixturePresentation("active-space-changed"); self?.publishFixtureHealth() }
                })
            // Passive verification heartbeat only: no inventory/adapter/device
            // operation. Health must not keep reporting a stale foreground sample.
            fixtureHealthHeartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.publishFixtureHealth() }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.fixtureStopRequested else { return }
                if self.openWhenReady || CommandLine.arguments.contains("--show-controls") { self.showControls() }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                    guard let self else { return }
                    self.fixtureFrontmostAfter = self.fixtureFrontmost()
                    self.fixtureInitializationComplete = NSRunningApplication.current.isFinishedLaunching
                    self.fixtureInitializationBackgroundSafe = Self.fixtureBackgroundSafety(current: self.fixtureFrontmostAfter,
                        fixturePID: getpid(), fixtureBundleID: Bundle.main.bundleIdentifier, appIsActive: NSApp.isActive,
                        panelIsKey: self.panel?.isKeyWindow ?? false, violation: self.fixtureBackgroundViolation) == "PASS"
                    self.recordFixturePresentation("initialization-settled")
                    self.publishFixtureHealth()
                }
            }
        } else if openWhenReady || CommandLine.arguments.contains("--show-controls") {
            showControls()
        } else {
            store.refresh()
        }
        publishFixtureHealth()
        // Cua Driver's window inventory includes only normal-level windows.
        // Give the verifier our exact floating panel ID so all interaction and
        // screenshots still go through Cua rather than a second GUI driver.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--verification-window-file"), index + 1 < arguments.count,
           let ownerIndex = arguments.firstIndex(of: "--verification-owner"), ownerIndex + 1 < arguments.count {
            let receipt: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                          "owner": arguments[ownerIndex + 1], "windowID": panel.windowNumber]
            do {
                let data = try JSONSerialization.data(withJSONObject: receipt)
                try data.write(to: URL(fileURLWithPath: arguments[index + 1]), options: .atomic)
            } catch {
                NSLog("MSI Screen verification window unavailable: %@", error.localizedDescription)
            }
        }
    }

    private func observeFixtureStop() {
        guard let fixture else { return }
        let fd = open(fixture.directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { NSLog("Fixture lifecycle observation unavailable."); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.acceptFixtureStop() }
        source.setCancelHandler { close(fd) }
        fixtureStopObservation = source
        source.resume()
        DispatchQueue.main.async { [weak self] in self?.acceptFixtureStop() }
    }

    private func acceptFixtureStop() {
        guard let fixture, !fixtureStopRequested else { return }
        do {
            if try fixture.terminationRequested() { fixtureStopRequested = true; NSApp.terminate(nil) }
        }
        catch { NSLog("Fixture lifecycle request refused.") }
    }

    private func fixturePresentationState() -> FixturePresentationState {
        FixturePresentationState(appIsHidden: NSRunningApplication.current.isHidden, panelWindowNumber: panel?.windowNumber,
            panelIsVisible: panel?.isVisible ?? false, panelIsMiniaturized: panel?.isMiniaturized ?? false,
            panelIsOnActiveSpace: panel?.isOnActiveSpace ?? false, panelOcclusionVisible: panel?.occlusionState.contains(.visible) ?? false,
            selectedTab: fixtureSelectedTab)
    }

    private func recordFixturePresentation(_ reason: String) {
        guard fixture != nil else { return }
        let state = fixturePresentationState()
        fixtureLastPresentation = state
        fixturePresentationSequence &+= 1
        fixturePresentationEvents.append(.init(sequence: fixturePresentationSequence,
            checkedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000), reason: reason, state: state))
        if fixturePresentationEvents.count > 16 { fixturePresentationEvents.removeFirst(fixturePresentationEvents.count - 16) }
    }

    private func publishFixtureHealth() {
        guard let fixture else { return }
        let active = NSApp.isActive, key = panel?.isKeyWindow ?? false
        if active || key { fixtureBackgroundViolation = true }
        let current = fixtureFrontmost()
        let presentation = fixturePresentationState()
        if presentation != fixtureLastPresentation { recordFixturePresentation("passive-presentation-change") }
        struct Health: Encodable {
            let schema = 1; let label = DeviceSupportVerificationFixture.label
            let pid: Int32; let bundleID: String?; let nonce: UUID; let selectedID: String?
            let inventoryGeneration: UInt64; let controlGeneration: UInt64; let metadataRevision: UInt64?; let descriptorCount: Int
            let busy: Bool; let mutating: Bool; let copyDetail: String
            let observation: DeviceObservation?; let receipt: DeviceMutationReceipt?; let error: String?
            let initializationComplete: Bool; let initializationBackgroundSafe: Bool; let appFinishedLaunching: Bool
            let frontmostBefore: FixtureFrontmost?; let frontmostAfter: FixtureFrontmost?; let frontmostCurrent: FixtureFrontmost?
            let checkedAtMilliseconds: UInt64; let backgroundViolationObserved: Bool
            let foregroundPreservation: String; let currentBackgroundSafety: String
            let appIsActive: Bool; let panelIsKeyWindow: Bool; let panelIsVisible: Bool
            let appIsHidden: Bool; let panelWindowNumber: Int?; let panelIsMiniaturized: Bool
            let panelIsOnActiveSpace: Bool; let panelOcclusionVisible: Bool; let selectedTab: String?
            let presentationEvents: [FixturePresentationEvent]
        }
        do {
            try fixture.writeHealth(StrictJSON.canonical(Health(pid: getpid(), bundleID: Bundle.main.bundleIdentifier, nonce: fixture.reference.nonce,
                selectedID: inventory.selectedID, inventoryGeneration: inventory.generation, controlGeneration: deviceControl.generation,
                metadataRevision: inventory.listing?.registry.revision, descriptorCount: inventory.descriptors.count, busy: hasActiveOperation, mutating: deviceControl.isMutating, copyDetail: inventory.copyDetail, observation: deviceControl.observation, receipt: deviceControl.receipt, error: deviceControl.error ?? inventory.error,
                initializationComplete: fixtureInitializationComplete, initializationBackgroundSafe: fixtureInitializationBackgroundSafe,
                appFinishedLaunching: NSRunningApplication.current.isFinishedLaunching, frontmostBefore: fixtureFrontmostBefore, frontmostAfter: fixtureFrontmostAfter, frontmostCurrent: current,
                checkedAtMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000), backgroundViolationObserved: fixtureBackgroundViolation,
                foregroundPreservation: Self.fixtureForegroundPreservation(before: fixtureFrontmostBefore, after: fixtureFrontmostAfter,
                    fixturePID: getpid(), fixtureBundleID: Bundle.main.bundleIdentifier, initializationComplete: fixtureInitializationComplete,
                    initializationBackgroundSafe: fixtureInitializationBackgroundSafe),
                currentBackgroundSafety: Self.fixtureBackgroundSafety(current: current, fixturePID: getpid(), fixtureBundleID: Bundle.main.bundleIdentifier,
                    appIsActive: active, panelIsKey: key, violation: fixtureBackgroundViolation),
                appIsActive: active, panelIsKeyWindow: key, panelIsVisible: presentation.panelIsVisible,
                appIsHidden: presentation.appIsHidden, panelWindowNumber: presentation.panelWindowNumber, panelIsMiniaturized: presentation.panelIsMiniaturized,
                panelIsOnActiveSpace: presentation.panelIsOnActiveSpace, panelOcclusionVisible: presentation.panelOcclusionVisible,
                selectedTab: presentation.selectedTab, presentationEvents: fixturePresentationEvents)))
        } catch { NSLog("Support fixture health publication failed.") }
    }

    private func handleAppControl(id: String, pid: Int32) async {
        guard let appControl else { return }
        do {
            guard let request = try appControl.takeRequest(id: id, targetPID: pid) else { return }
            do {
                try request.validateBeforeHandling()
                switch request.action {
                case .status:
                    try appControl.respond(to: request, status: await wheelStatus())
                case .setSideWheel:
                    let result = try await store.setSideWheel(request.preset!, expected: request.expected!)
                    try appControl.respond(to: request, result: result)
                case .setHostAction:
                    try store.setWheelHostAction(request.hostAction!)
                    try appControl.respond(to: request, status: await wheelStatus())
                case .setTopButton:
                    let result = try await store.setTopButton(
                        request.topButtonPreset!, expectedRecordHex: request.expectedRecordHex!,
                        bundleIdentifier: request.bundleIdentifier)
                    try appControl.respond(to: request, buttonResult: result)
                }
            } catch {
                try appControl.respond(to: request, error: error.localizedDescription)
            }
        } catch {
            NSLog("MSI Screen CLI request failed: %@", error.localizedDescription)
        }
    }

    private func wheelStatus() async -> RapooAppSwitchStatus {
        // Certificate trust evaluation can block; keep the same app identity
        // checks as the privacy card without running them on the UI thread.
        let permissions = await Task.detached { AppPermissionStatus.current() }.value
        let controller = AppSwitchController.shared
        return RapooAppSwitchStatus(
            enabled: UserDefaults.standard.bool(forKey: MonitorStore.appSwitchPreference),
            hotkeysRegistered: controller.active, switchCount: controller.switchCount,
            lastApplication: controller.lastApplication, error: controller.error,
            hostAction: store.wheelHostAction, activeHostAction: controller.active ? controller.mode : nil,
            spaceRequestCount: controller.spaceRequestCount, lastSpaceDirection: controller.lastSpaceDirection,
            pinnedBundleIdentifier: controller.pinnedApplicationBundleID,
            pinHotkeyRegistered: controller.pinActive, pinRequestCount: controller.pinRequestCount,
            lastPinnedApplication: controller.lastPinnedApplication, pinError: controller.lastPinError,
            permissions: permissions)
    }

    func applicationWillTerminate(_ notification: Notification) {
        videoDiagnostics.stop()
        inventory.stopObservingPassiveChanges()
        fixtureStopObservation?.cancel()
        fixtureStopObservation = nil
        fixtureHealthHeartbeat?.cancel()
        fixtureHealthHeartbeat = nil
        AppSwitchController.shared.stop()
        for observer in changeObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var hasActiveOperation: Bool {
        store.hasActiveOperation || computers.busy || appSettings.hasActiveOperation || deviceControl.busy || inventory.busy || inventory.handoffBusy || inventory.managementBusy
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasActiveOperation else { return .terminateNow }
        // An updater relaunch must let an in-flight USB write/readback finish.
        terminationPending = true
        return .terminateLater
    }

    static func statusItemDescription(title: String, toolTip: String, readyVersion: String?) -> (label: String, toolTip: String) {
        let label = "MSI Screen controls: \(title)"
        guard let version = readyVersion else { return (label, toolTip) }
        return (label + ". Update \(version) ready", toolTip + "\nUpdate \(version) ready to install.")
    }

    private func updateStatusItem(_ state: ScreenState?, local: MacDisplayState?, peer: MacDisplayState?) {
        guard let button = statusItem?.button else { return }
        let state = inventory.usesBuiltInMonitor ? state : nil
        let title: String
        if !inventory.usesBuiltInMonitor {
            title = inventory.selectedTitle
        } else if let state {
            switch state.mode {
            case .off:
                title = state.source1.title
            case .pbp:
                title = "\(state.source1.title) | \(state.source2.title)"
            case .pip:
                title = "\(state.source1.title) + \(state.pipInput.title) PIP"
            }
        } else if store.kvm?.controlHost == .upstream {
            title = "USB-B"
        } else {
            title = "Monitor unavailable"
        }
        button.title = ""
        let updateReady = updater.readyVersion != nil
        if !hasRenderedIcon || lastIconState != state || lastUpdateReady != updateReady {
            button.image = MonitorAppearance.statusImage(for: state, updateReady: updateReady)
            lastIconState = state
            lastUpdateReady = updateReady
            hasRenderedIcon = true
        }
        if !inventory.usesBuiltInMonitor {
            let observed = deviceControl.observation.map { Date(timeIntervalSince1970: Double($0.checkedAtMilliseconds) / 1000).description } ?? "not read"
            button.toolTip = "\(inventory.selectedTitle)\n\(inventory.providerTitle)\nLast explicit observation: \(observed)\(deviceControl.needsRefresh ? " (refresh required)" : "")"
        } else {
            button.toolTip = state == nil
                ? "Monitor status unavailable. Open controls to refresh."
                : "Selected layout: \(title). Click to choose full screen or side by side."
            if let state {
                let inputs = state.mode == .off ? [state.source1] : [state.source1, state.mode == .pip ? state.pipInput : state.source2]
                let names = inputs.map { input in
                    let name = preferences.name(for: input, localName: local?.computerName, peerName: peer?.computerName)
                    return "\(input.title): \(name)"
                }
                button.toolTip = names.joined(separator: "\n") + "\nClick to open MSI Screen."
            } else if let kvm = store.kvm, kvm.controlHost == .upstream {
                let name = preferences.machines.first { $0.id == kvm.machineID }?.name ?? "the Linux computer"
                button.toolTip = "USB control is on \(name) via USB-B.\nOpen Machines to return USB to this Mac."
            }
        }
        let description = Self.statusItemDescription(title: title, toolTip: button.toolTip ?? "", readyVersion: updater.readyVersion)
        button.setAccessibilityLabel(description.label)
        button.toolTip = description.toolTip
    }

    private func observeSupervisor() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--supervisor"), index + 1 < arguments.count,
              let pid = Int32(arguments[index + 1]), pid > 1 else { return }
        // LaunchServices owns the app process; OMP owns its supervisor. Observe
        // that specific supervisor's exit in the kernel, then finish any active
        // monitor transaction before terminating ourselves.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.supervisorStopped = true
            self?.quitWhenIdle()
        }
        supervisorExit = source
        source.resume()
        idleObservation = operationChanges.sink { [weak self] _ in
            // @Published emits before the stored value changes. Use the same
            // complete predicate as native Quit and Sparkle's relaunch request.
            DispatchQueue.main.async { self?.quitWhenIdle() }
        }
        if kill(pid, 0) != 0 && errno == ESRCH {
            supervisorStopped = true
            quitWhenIdle()
        }
    }

    private func quitWhenIdle() {
        if supervisorStopped && !hasActiveOperation { NSApp.terminate(nil) }
    }

    private func hideControls(reason: String) {
        panel?.orderOut(nil)
        recordFixturePresentation(reason)
        publishFixtureHealth()
    }

    @objc private func toggleControls() {
        guard let panel else { return }
        if panel.isVisible { hideControls(reason: "status-item-toggle-hide") } else { showControls() }
    }

    private func showControls() {
        guard let panel else { return }
        if let button = statusItem?.button, let statusWindow = button.window {
            let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = statusWindow.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
            let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: visible.maxY))
        } else {
            panel.center()
        }
        // Order without an explicit activation call. This alone is not proof
        // of background safety: the fixture separately refuses key/main status
        // and reports actual settled/current app/window observations.
        panel.orderFrontRegardless()
        recordFixturePresentation("show-controls")
        appSettings.refresh()
        inventory.refresh()
        guard fixture == nil else { publishFixtureHealth(); return }
        preferences.reload()
        computers.refreshIfStale()
        if store.showingSettings { store.refreshSettings() }
        else { store.refresh() }
        store.refreshPeripherals()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "msi-screen" && $0.host == "controls" }) {
            openWhenReady = true
            showControls()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }
}
