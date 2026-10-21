import AppKit
import SwiftUI
import Combine
import MSIScreenCore

@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    let appSettings = AppSettings()
    private let store = MonitorStore()
    private let preferences = MonitorPreferences()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appSettings.configureAtFirstLaunch()
        updater.willShowModalAlert = { [weak self] in self?.panel?.orderOut(nil) }
        updater.start()
        terminationObservation = Publishers.Merge3(store.objectWillChange, computers.objectWillChange, appSettings.objectWillChange)
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main).sink { [weak self] _ in
                guard let self, self.terminationPending, !self.hasActiveOperation else { return }
                self.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        if UserDefaults.standard.bool(forKey: MonitorStore.appSwitchPreference) {
            try? AppSwitchController.shared.start(mode: store.wheelHostAction)
        }
        if let bundleID = UserDefaults.standard.string(forKey: MonitorStore.pinnedAppPreference) {
            try? AppSwitchController.shared.pinApplication(bundleIdentifier: bundleID)
        }
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
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(self.store.state, local: self.computers.local, peer: self.computers.peer)
        }

        // A nonactivating panel lets the user keep typing in another app.
        // SwiftUI owns all monitor state; AppKit only owns presentation.
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: MonitorAppearance.panelSize),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
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
            closeControls: { [weak panel] in panel?.orderOut(nil) }
        ))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        // The full-size SwiftUI surface includes the titlebar inset. Keep the
        // reference proportions independent of AppKit's content-rect conversion.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: MonitorAppearance.panelSize), display: false)
        self.panel = panel
        computers.refresh()
        refreshTimer = Timer.publish(every: 30, tolerance: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, !self.supervisorStopped, self.panel?.isVisible == false else { return }
            // Read while closed so OSD/CLI changes reach the bar without
            // replacing a draft the user is editing in the open panel.
            self.store.refresh()
        }
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: ScreenController.didChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? String != String(ProcessInfo.processInfo.processIdentifier) else { return }
                Task { @MainActor in self?.store.refreshAfterExternalChange() }
            })
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: KVMCoordinator.didChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? String != String(ProcessInfo.processInfo.processIdentifier) else { return }
                Task { @MainActor in self?.store.refreshAfterExternalKVMChange() }
            })
        changeObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: MachineRegistryStore.didChangeNotification,
            object: MachineRegistryStore.defaultURL.standardizedFileURL.path, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.preferences.reload()
                    self.computers.refresh()
                }
            })
        observeSupervisor()
        if openWhenReady || CommandLine.arguments.contains("--show-controls") {
            showControls()
        } else {
            store.refresh()
        }
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

    private func handleAppControl(id: String, pid: Int32) async {
        guard let appControl else { return }
        do {
            guard let request = try appControl.takeRequest(id: id, targetPID: pid) else { return }
            do {
                try request.validateBeforeHandling()
                switch request.action {
                case .status:
                    try appControl.respond(to: request, status: wheelStatus())
                case .setSideWheel:
                    let result = try await store.setSideWheel(request.preset!, expected: request.expected!)
                    try appControl.respond(to: request, result: result)
                case .setHostAction:
                    try store.setWheelHostAction(request.hostAction!)
                    try appControl.respond(to: request, status: wheelStatus())
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

    private func wheelStatus() -> RapooAppSwitchStatus {
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
            permissions: AppPermissionStatus.current())
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSwitchController.shared.stop()
        for observer in changeObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private var hasActiveOperation: Bool {
        store.busy || computers.busy || store.sideWheelChangeBusy || store.topButtonChangeBusy || appSettings.changingLoginItem
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasActiveOperation else { return .terminateNow }
        // An updater relaunch must let an in-flight USB write/readback finish.
        terminationPending = true
        return .terminateLater
    }

    private func updateStatusItem(_ state: ScreenState?, local: MacDisplayState?, peer: MacDisplayState?) {
        guard let button = statusItem?.button else { return }
        let title: String
        if let state {
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
        button.setAccessibilityLabel("MSI Screen controls: \(title)")
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
        if let version = updater.readyVersion {
            button.setAccessibilityLabel("MSI Screen controls: \(title). Update \(version) ready")
            button.toolTip = (button.toolTip ?? "") + "\nUpdate \(version) ready to install."
        }
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
        idleObservation = store.$busy.combineLatest(computers.$busy).dropFirst().sink { [weak self] monitorBusy, computersBusy in
            if !monitorBusy && !computersBusy {
                // @Published emits before the stored value changes.
                DispatchQueue.main.async { self?.quitWhenIdle() }
            }
        }
        if kill(pid, 0) != 0 && errno == ESRCH {
            supervisorStopped = true
            quitWhenIdle()
        }
    }

    private func quitWhenIdle() {
        if supervisorStopped && !store.busy && !computers.busy { NSApp.terminate(nil) }
    }

    @objc private func toggleControls() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { showControls() }
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
        // orderFront does not reliably raise an inactive accessory app's
        // panel. Raise it explicitly without activating or taking key focus.
        panel.orderFrontRegardless()
        appSettings.refresh()
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
