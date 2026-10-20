import Foundation
import MSIScreenCore

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var state: ScreenState?
    @Published private(set) var busy = false
    @Published private(set) var isApplying = false
    @Published private(set) var pendingTarget: ScreenState?
    @Published private(set) var verifiedAt: Date?
    @Published private(set) var needsRefresh = false
    @Published private(set) var error: String?
    @Published private(set) var message = "Connect the monitor’s USB upstream cable."
    @Published var split = false
    @Published var left: Input = .dp
    @Published var right: Input = .usbc
    @Published private(set) var settings: MonitorSettingsSnapshot?
    @Published private(set) var kvm: KVMStatus?
    @Published private(set) var kvmError: String?
    @Published private(set) var kvmBusy = false
    @Published private(set) var kvmMessage = "Refresh to read the USB route."
    @Published private(set) var peripherals: USBPeripheralSnapshot?
    @Published private(set) var peripheralsBusy = false
    @Published private(set) var peripheralsError: String?
    @Published private(set) var pointerDescriptor: PointerDescriptorSnapshot?
    @Published private(set) var pointerProbe: PointerProbeSnapshot?
    @Published private(set) var pointerProbeBusy = false
    @Published private(set) var pointerProbeError: String?
    @Published private(set) var popDetails: POPKeyboardDetails?
    @Published private(set) var popDetailsBusy = false
    @Published private(set) var popDetailsError: String?
    @Published private(set) var rapooDetails: RapooMouseDetails?
    @Published private(set) var rapooDetailsBusy = false
    @Published private(set) var rapooDetailsError: String?
    @Published private(set) var sideWheelChangeBusy = false
    @Published private(set) var sideWheelChange: RapooWheelChangeResult?
    @Published private(set) var sideWheelChangeError: String?
    @Published private(set) var topButtonChangeBusy = false
    @Published private(set) var topButtonChange: RapooButtonChangeResult?
    @Published private(set) var topButtonChangeError: String?
    static let appSwitchPreference = "sideWheelAppSwitchEnabled"
    static let wheelActionPreference = "sideWheelHostAction"
    static let pinnedAppPreference = "rapooPinnedApplication"
    @Published private(set) var wheelHostAction = RapooWheelHostAction(
        rawValue: UserDefaults.standard.string(forKey: wheelActionPreference) ?? "") ?? .applications
    @Published var settingsDraft: [String: Int] = [:]
    @Published private(set) var hasSavedSetup = UserDefaults.standard.data(forKey: "savedLayout") != nil
    var showingSettings = false

    private let queue = DispatchQueue(label: "MSIScreen.usb", qos: .userInitiated)
    private var externalRefreshPending = false
    private var externalKVMRefreshPending = false
    private var peripheralGeneration = 0
    private var peripheralRefreshPending = false
    // A handoff moves the HID controller too. Only an explicit KVM read can
    // establish that local USB control has returned; idle refresh must not poll.
    private var localMonitorReadBlocked = false

    var target: ScreenState? {
        guard let state else { return nil }
        if split {
            return try? ScreenController.pbpTarget(from: state, enabled: true, left: left, right: right)
        }
        return ScreenController.fullscreenTarget(from: state, input: left)
    }

    func layoutApplication(machines: [MachineDefinition], followUSB: Bool) -> LayoutApplication? {
        target.map { LayoutApplication(target: $0, machines: machines, followUSB: followUSB) }
    }

    func canApply(machines: [MachineDefinition], followUSB: Bool) -> Bool {
        guard !busy, !needsRefresh, let state,
              let application = layoutApplication(machines: machines, followUSB: followUSB) else { return false }
        return application.canApply(from: state, kvm: kvm, localReadBlocked: localMonitorReadBlocked)
    }
    var hasDraft: Bool {
        (state != nil && target != state) || (settings != nil && settingsDraft != settings?.values)
    }
    var duplicateInputs: Bool { split && left == right }
    var currentLayout: String? {
        guard let state else { return nil }
        switch state.mode {
        case .off: return "Current: \(state.source1.title) full screen"
        case .pbp: return "Current: \(state.source1.title) | \(state.source2.title)"
        case .pip: return "Current: picture in picture"
        }
    }

    func refresh() {
        guard !localMonitorReadBlocked else { return }
        perform(message: "Reading monitor…") { controller in try controller.state() }
    }

    func refreshAfterExternalChange() {
        guard !localMonitorReadBlocked else { return }
        guard !busy else { externalRefreshPending = true; return }
        if hasDraft {
            needsRefresh = true
            message = "Monitor changed elsewhere. Refresh before applying this draft."
        } else if showingSettings {
            refreshSettings()
        } else {
            refresh()
        }
    }

    func refreshAfterExternalKVMChange() {
        guard !busy else { externalKVMRefreshPending = true; return }
        refreshKVM()
    }

    func swap() {
        let previousLeft = left
        left = right
        right = previousLeft
    }

    func apply(machines: [MachineDefinition], followUSB: Bool) {
        guard let before = state,
              let application = layoutApplication(machines: machines, followUSB: followUSB),
              canApply(machines: machines, followUSB: followUSB) else { return }
        if let machine = application.focusMachine {
            focus(machine)
            return
        }
        let target = application.target
        if localMonitorReadBlocked {
            applyPreservingUSB(target, from: before)
            return
        }
        // Carry the displayed baseline across the UI boundary. A newer OSD or
        // CLI change must fail the core's comparison, not get overwritten.
        pendingTarget = target
        isApplying = true
        perform(message: "Switching now · verifying after monitor settles…") { controller in
            try controller.apply(target, from: before)
        }
    }

    func canRoute(_ machine: MachineDefinition, to route: MachineRoute, followUSB: Bool) -> Bool {
        guard !busy else { return false }
        if followsUSB(machine, route: route, enabled: followUSB) {
            return kvm != nil && (!needsRefresh || (localMonitorReadBlocked && state == nil))
        }
        return !needsRefresh && state != nil && (!localMonitorReadBlocked || kvm != nil)
    }

    private func followsUSB(_ machine: MachineDefinition, route: MachineRoute, enabled: Bool) -> Bool {
        enabled && route == .fullscreen &&
            ((machine.isLocal && machine.input == .usbc) || machine.platform == .linux)
    }

    func route(_ machine: MachineDefinition, to route: MachineRoute, followUSB: Bool = false) {
        guard canRoute(machine, to: route, followUSB: followUSB) else { return }
        if followsUSB(machine, route: route, enabled: followUSB) {
            focus(machine)
            return
        }
        guard let before = state else { return }
        do {
            let target = try MachineRouter.target(for: machine, route: route, from: before)
            guard target != before else { return }
            if localMonitorReadBlocked {
                applyPreservingUSB(target, from: before, expectedMachine: machine)
                return
            }
            pendingTarget = target
            isApplying = true
            perform(message: "Switching to \(machine.name) · verifying…") {
                guard try MachineRegistryStore().load().machine(id: machine.id) == machine else {
                    throw ScreenError.message("Machine assignment changed. Refresh before switching.")
                }
                return try $0.apply(target, from: before)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func applyPreservingUSB(_ target: ScreenState, from before: ScreenState,
                                    expectedMachine: MachineDefinition? = nil) {
        guard !busy, let expectedUSB = kvm?.route else { return }
        busy = true
        isApplying = true
        kvmBusy = true
        error = nil
        kvmError = nil
        pendingTarget = target
        invalidatePeripherals()
        message = "Applying layout · keeping the selected USB host…"
        Task {
            do {
                let registry = try MachineRegistryStore().load()
                if let expectedMachine,
                   try registry.machine(id: expectedMachine.id) != expectedMachine {
                    throw ScreenError.message("Machine assignment changed. Refresh before switching.")
                }
                let result = try await LayoutCoordinator(registry: registry).apply(
                    target, from: before, expectedUSB: expectedUSB)
                if let usb = result.afterUSB { receiveKVM(usb) }
                if result.verified, let layout = result.afterLayout {
                    receive(layout)
                    message = "Layout verified · USB host preserved."
                    kvmMessage = "USB route verified: \(result.afterUSB?.route.title ?? "unchanged")."
                } else {
                    invalidateLocalMonitor()
                    error = result.error ?? "Layout or USB readback could not be verified."
                    kvmError = error
                    message = "Switch stopped. Refresh to inspect the picture and USB route."
                }
            } catch {
                self.error = error.localizedDescription
                needsRefresh = true
                message = "Switch stopped. Refresh the current state."
            }
            isApplying = false
            pendingTarget = nil
            finishKVM(refreshLocal: false)
        }
    }

    private func focus(_ machine: MachineDefinition) {
        let expectedUSB = kvm?.route
        let expectedLayout = state
        busy = true
        isApplying = true
        kvmBusy = true
        error = nil
        kvmError = nil
        invalidatePeripherals()
        pendingTarget = state.map { ScreenController.fullscreenTarget(from: $0, input: machine.input) }
        message = "Switching \(machine.name) · picture, then keyboard & mouse…"
        kvmMessage = "Switching picture and USB together…"
        Task {
            do {
                let registry = try MachineRegistryStore().load()
                guard try registry.machine(id: machine.id) == machine else {
                    throw ScreenError.message("Machine assignment changed. Refresh before switching.")
                }
                let coordinator = try MachineFocusCoordinator(registry: registry)
                let result = try await coordinator.focus(machineID: machine.id, expectedUSB: expectedUSB,
                                                         expectedLayout: expectedLayout)
                if let usb = result.afterUSB { receiveKVM(usb) }
                if result.verified, let layout = result.afterLayout {
                    receive(layout)
                    message = "\(machine.name) · full screen and USB verified."
                    kvmMessage = "USB route verified: \(result.targetUSB.title)."
                } else {
                    invalidateLocalMonitor()
                    localMonitorReadBlocked = true
                    error = result.error ?? "The combined switch could not be verified."
                    kvmError = error
                    message = "Switch stopped. Refresh to inspect the current picture and USB route."
                    kvmMessage = result.videoVerified ? "Picture verified; USB switch incomplete."
                        : "Combined switch incomplete. Refresh before another change."
                }
            } catch {
                self.error = error.localizedDescription
                kvmError = error.localizedDescription
                kvmMessage = "Switch stopped before completion. Refresh the current state."
                message = "Switch could not be completed. Refresh the current state."
            }
            isApplying = false
            pendingTarget = nil
            finishKVM(refreshLocal: false)
        }
    }

    func saveSetup() {
        guard !busy, let state else { return }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: "savedLayout")
            hasSavedSetup = true
            message = "Saved the current monitor layout."
        } catch { self.error = error.localizedDescription }
    }

    func restoreSetup() {
        guard !busy, !needsRefresh, let before = state,
              let data = UserDefaults.standard.data(forKey: "savedLayout") else { return }
        do {
            let saved = try JSONDecoder().decode(ScreenState.self, from: data)
            if localMonitorReadBlocked {
                applyPreservingUSB(saved, from: before)
                return
            }
            pendingTarget = saved
            isApplying = true
            perform(message: "Restoring saved layout…") { controller in
                try controller.apply(saved, from: before)
            }
        } catch { self.error = error.localizedDescription }
    }

    func refreshSettings() {
        guard !localMonitorReadBlocked else { return }
        performSettings(message: "Reading monitor controls…") { try $0.settings() }
    }

    func refreshKVM() {
        guard !busy else { externalKVMRefreshPending = true; return }
        busy = true
        kvmBusy = true
        kvmError = nil
        kvmMessage = "Reading USB route…"
        Task {
            var refreshLocal = false
            do {
                let registry = try MachineRegistryStore().load()
                let coordinator = try KVMCoordinator(registry: registry)
                let status = try await coordinator.status()
                let wasBlocked = localMonitorReadBlocked
                receiveKVM(status)
                kvmMessage = "USB route read: \(status.route.title)."
                if status.controlHost == .upstream {
                    await readRemoteLayout(coordinator)
                } else {
                    refreshLocal = wasBlocked || state == nil
                }
            } catch {
                kvm = nil
                invalidatePeripherals()
                kvmError = error.localizedDescription
                self.error = error.localizedDescription
                kvmMessage = "USB route could not be read."
                message = "Refresh after reconnecting the computer that owns the USB hub."
            }
            finishKVM(refreshLocal: refreshLocal)
        }
    }

    func setKVM(_ route: KVMRoute, expectedMachines: [MachineDefinition]) {
        guard !busy, let before = kvm else { return }
        busy = true
        kvmBusy = true
        kvmError = nil
        invalidatePeripherals()
        kvmMessage = "Switching USB route to \(route.title)…"
        Task {
            var refreshLocal = false
            do {
                let registry = try MachineRegistryStore().load()
                guard registry.machines == expectedMachines else {
                    throw ScreenError.message("Machine assignments changed. Refresh before switching USB.")
                }
                let coordinator = try KVMCoordinator(registry: registry)
                let result = try await coordinator.set(target: route, expected: before.route)
                if result.writeAttempted {
                    invalidateLocalMonitor()
                    localMonitorReadBlocked = true
                }
                if let after = result.after {
                    receiveKVM(after)
                    refreshLocal = after.controlHost == .local && (result.writeAttempted || state == nil)
                } else if result.writeAttempted {
                    kvm = nil
                    message = "USB handoff is unverified. Refresh the USB route to reconnect."
                }
                if result.verified {
                    kvmMessage = "USB route verified: \(route.title)."
                    if result.after?.controlHost == .upstream {
                        await readRemoteLayout(coordinator)
                    }
                } else {
                    kvmError = result.error ?? "USB handoff could not be verified. Refresh the USB route before another change."
                    kvmMessage = result.writeAttempted ? "USB write attempted; readback unverified." : "USB route was not changed."
                }
            } catch {
                kvmError = error.localizedDescription
                kvmMessage = "USB operation stopped. Refresh to inspect the current route."
            }
            finishKVM(refreshLocal: refreshLocal)
        }
    }

    private func receiveKVM(_ status: KVMStatus) {
        if status != kvm { invalidatePeripherals() }
        kvm = status
        localMonitorReadBlocked = status.controlHost == .upstream
        if localMonitorReadBlocked {
            invalidateLocalMonitor()
            message = "USB is on USB-B. Layout changes keep the selected USB host."
        }
    }

    private func readRemoteLayout(_ coordinator: KVMCoordinator) async {
        do {
            receive(try await coordinator.layout())
        } catch {
            // A failed picture read must not disable the verified USB return
            // path, especially with an older Linux companion.
            self.error = error.localizedDescription
            message = "USB host is known; picture readback is unavailable. USB switching remains available."
        }
    }

    private func invalidateLocalMonitor() {
        state = nil
        settings = nil
        settingsDraft = [:]
        verifiedAt = nil
        needsRefresh = true
        error = nil
    }

    private func finishKVM(refreshLocal: Bool) {
        busy = false
        kvmBusy = false
        requestPeripheralSnapshot()
        if externalKVMRefreshPending {
            consumePendingRefresh()
            return
        }
        if refreshLocal {
            externalRefreshPending = false
            refresh()
        } else if localMonitorReadBlocked {
            externalRefreshPending = false
        } else {
            consumePendingRefresh()
        }
    }

    /// Explicit refreshes and handoff notifications update diagnostics. There
    /// is no timer or recurring SSH process for peripheral status.
    func refreshPeripherals() { refreshKVM() }

    private func invalidatePeripherals() {
        peripheralGeneration += 1
        peripherals = nil
        peripheralsError = nil
        pointerDescriptor = nil
        pointerProbe = nil
        pointerProbeError = nil
        popDetails = nil
        popDetailsError = nil
        rapooDetails = nil
        rapooDetailsError = nil
        sideWheelChange = nil
        sideWheelChangeError = nil
        topButtonChange = nil
        topButtonChangeError = nil
    }

    func refreshRapooDetails() {
        guard !busy, !rapooDetailsBusy, kvm?.controlHost == .local else { return }
        rapooDetailsBusy = true
        rapooDetailsError = nil
        rapooDetails = nil
        sideWheelChange = nil
        sideWheelChangeError = nil
        topButtonChange = nil
        topButtonChangeError = nil
        let generation = peripheralGeneration
        Task {
            do {
                let details = try await RapooPeripheralClient().localDetails()
                if generation == peripheralGeneration, kvm?.controlHost == .local {
                    rapooDetails = details
                }
            } catch {
                if generation == peripheralGeneration { rapooDetailsError = error.localizedDescription }
            }
            rapooDetailsBusy = false
        }
    }

    /// Both the UI and CLI enter here so a mouse mapping cannot be enabled
    /// before this Mac has successfully reserved its corresponding shortcuts.
    func setSideWheel(_ preset: RapooSideWheelPreset,
                      expected: [RapooWheelMapping]) async throws -> RapooWheelChangeResult {
        guard !busy, !rapooDetailsBusy, !sideWheelChangeBusy, !pointerProbeBusy else {
            throw ScreenError.message("Another device operation is active. Wait for it to finish.")
        }
        guard kvm?.controlHost != .upstream else {
            throw ScreenError.message("Return the monitor USB hub to this Mac before changing the mouse.")
        }
        busy = true
        sideWheelChangeBusy = true
        sideWheelChangeError = nil
        sideWheelChange = nil
        let generation = peripheralGeneration
        let wasActive = AppSwitchController.shared.active
        defer {
            busy = false
            sideWheelChangeBusy = false
            consumePendingRefresh()
        }
        do {
            if preset == .appSwitch { try AppSwitchController.shared.start(mode: wheelHostAction) }
            let result = try await RapooPeripheralClient().setSideWheelPreset(preset, expected: expected)
            sideWheelChange = result
            sideWheelChangeError = result.error
            if preset == .appSwitch {
                if result.verified || !result.writeAttemptedKeys.isEmpty {
                    // A partial write may already emit one of the shortcuts.
                    // Keep its handler available until an explicit restore.
                    UserDefaults.standard.set(true, forKey: Self.appSwitchPreference)
                } else if !wasActive {
                    AppSwitchController.shared.stopWheel()
                }
            } else if result.verified {
                UserDefaults.standard.set(false, forKey: Self.appSwitchPreference)
                AppSwitchController.shared.stopWheel()
            }
            // Return the verified write receipt promptly. Optional telemetry
            // must not turn a completed mutation into a CLI reply timeout.
            updateRapooDetails(afterGeneration: generation)
            return result
        } catch {
            if preset == .appSwitch, !wasActive { AppSwitchController.shared.stopWheel() }
            sideWheelChangeError = error.localizedDescription
            throw error
        }
    }

    /// Changes only this Mac's interpretation of the onboard F18/F19 mappings.
    func setWheelHostAction(_ action: RapooWheelHostAction) throws {
        guard !sideWheelChangeBusy else {
            throw ScreenError.message("Wait for the mouse mapping change to finish.")
        }
        try AppSwitchController.shared.start(mode: action)
        wheelHostAction = action
        UserDefaults.standard.set(action.rawValue, forKey: Self.wheelActionPreference)
        UserDefaults.standard.set(true, forKey: Self.appSwitchPreference)
    }

    func setTopButton(_ preset: RapooTopButtonPreset, expectedRecordHex: String,
                      bundleIdentifier: String?) async throws -> RapooButtonChangeResult {
        guard !busy, !rapooDetailsBusy, !pointerProbeBusy else {
            throw ScreenError.message("Another device operation is active. Wait for it to finish.")
        }
        guard kvm?.controlHost != .upstream else {
            throw ScreenError.message("Return the monitor USB hub to this Mac before changing the mouse.")
        }
        guard (preset == .pinnedApp) == (bundleIdentifier != nil) else {
            throw ScreenError.message("Choose an installed app for the pinned button.")
        }
        busy = true
        topButtonChangeBusy = true
        topButtonChange = nil
        topButtonChangeError = nil
        let generation = peripheralGeneration
        let controller = AppSwitchController.shared
        let previousPin = controller.pinActive ? controller.pinnedApplicationBundleID : nil
        func restorePreviousHandler() {
            if let previousPin { try? controller.pinApplication(bundleIdentifier: previousPin) }
            else { controller.unpinApplication() }
        }
        defer {
            busy = false
            topButtonChangeBusy = false
            consumePendingRefresh()
        }
        do {
            if let bundleIdentifier { try controller.pinApplication(bundleIdentifier: bundleIdentifier) }
            let result = try await RapooPeripheralClient().setTopButtonPreset(
                preset, expectedRecordHex: expectedRecordHex)
            topButtonChange = result
            topButtonChangeError = result.error
            if preset == .pinnedApp {
                if result.verified || result.writeAttempted {
                    // An unverified write can already emit F20. Keep its
                    // destination available until an explicit verified restore.
                    UserDefaults.standard.set(bundleIdentifier, forKey: Self.pinnedAppPreference)
                } else {
                    restorePreviousHandler()
                }
            } else if result.verified {
                UserDefaults.standard.removeObject(forKey: Self.pinnedAppPreference)
                controller.unpinApplication()
            }
            updateRapooDetails(afterGeneration: generation)
            return result
        } catch {
            if preset == .pinnedApp { restorePreviousHandler() }
            topButtonChangeError = error.localizedDescription
            throw error
        }
    }

    private func updateRapooDetails(afterGeneration generation: Int) {
        rapooDetailsBusy = true
        Task {
            let details = try? await RapooPeripheralClient().localDetails()
            if generation == peripheralGeneration {
                rapooDetails = details
                rapooDetailsError = details == nil ? "Refresh to read the current mouse mappings." : nil
            }
            rapooDetailsBusy = false
        }
    }

    func refreshPOPDetails(slot: Int? = nil) {
        guard !busy, !peripheralsBusy, !popDetailsBusy, let expected = kvm else { return }
        let pairings = peripherals?.receivers.first { $0.id == .bolt }?.pairedDevices.filter {
            $0.kind == .keyboard && ["POP Keys", "Logi POP Keys"].contains($0.name ?? "")
        } ?? []
        let paired: PairedUSBPeripheral?
        if let slot { paired = pairings.first { $0.slot == slot } }
        else { paired = pairings.first { $0.radio == .responding } ?? pairings.first }
        guard let paired else {
            popDetailsError = slot == nil
                ? "Refresh the receivers, then wake the POP keyboard on its receiver channel."
                : "That receiver slot has no recognized POP keyboard. Refresh the receivers."
            return
        }
        popDetailsBusy = true
        popDetailsError = nil
        popDetails = nil
        let generation = peripheralGeneration
        Task {
            do {
                let registry = try MachineRegistryStore().load()
                let client = USBPeripheralClient()
                let details: POPKeyboardDetails
                if expected.controlHost == .local {
                    details = try await client.localDetails(for: paired)
                } else {
                    guard let id = expected.machineID, let host = try registry.machine(id: id).host else {
                        throw ScreenError.message("The USB host has no SSH connection.")
                    }
                    details = try await client.remoteDetails(host: host, for: paired)
                }
                if generation == peripheralGeneration, expected == kvm,
                   try MachineRegistryStore().load() == registry {
                    popDetails = details
                }
            } catch {
                if generation == peripheralGeneration, expected == kvm {
                    popDetailsError = error.localizedDescription
                }
            }
            popDetailsBusy = false
        }
    }

    func refreshPointerCapabilities() {
        guard kvm?.controlHost == .local, !pointerProbeBusy else { return }
        let generation = peripheralGeneration
        Task {
            do {
                let descriptor = try await PointerProbeClient().describe()
                guard generation == peripheralGeneration, kvm?.controlHost == .local else { return }
                pointerDescriptor = descriptor
                pointerProbeError = descriptor.error
            } catch {
                if generation == peripheralGeneration { pointerProbeError = error.localizedDescription }
            }
        }
    }

    func startPointerProbe() {
        guard !busy, !pointerProbeBusy, kvm?.controlHost == .local else { return }
        pointerProbeBusy = true
        pointerProbeError = nil
        pointerProbe = nil
        let generation = peripheralGeneration
        Task {
            do {
                let result = try await PointerProbeClient().probe(seconds: 10)
                if generation == peripheralGeneration, kvm?.controlHost == .local {
                    pointerProbe = result
                    pointerDescriptor = result.descriptor
                    pointerProbeError = result.error
                }
            } catch {
                if generation == peripheralGeneration { pointerProbeError = error.localizedDescription }
            }
            pointerProbeBusy = false
        }
    }

    private func requestPeripheralSnapshot() {
        guard let expected = kvm else { return }
        if peripheralsBusy {
            peripheralRefreshPending = true
            return
        }
        peripheralsBusy = true
        peripheralsError = nil
        let generation = peripheralGeneration
        Task {
            do {
                let registry = try MachineRegistryStore().load()
                let snapshot: USBPeripheralSnapshot
                if expected.controlHost == .local {
                    snapshot = try await USBPeripheralClient().local()
                } else {
                    guard let id = expected.machineID, let host = try registry.machine(id: id).host else {
                        throw ScreenError.message("The USB host has no SSH connection.")
                    }
                    snapshot = try await USBPeripheralClient().remote(host: host)
                }
                guard generation == peripheralGeneration, expected == kvm,
                      try MachineRegistryStore().load() == registry else {
                    finishPeripheralSnapshot()
                    return
                }
                guard snapshot.monitorHubPresent else {
                    throw ScreenError.message("The monitor hub moved or disconnected. Refresh its USB route.")
                }
                peripherals = snapshot
                if expected.controlHost == .local { refreshPointerCapabilities() }
            } catch {
                if generation == peripheralGeneration, expected == kvm {
                    peripherals = nil
                    peripheralsError = error.localizedDescription
                }
            }
            finishPeripheralSnapshot()
        }
    }

    private func finishPeripheralSnapshot() {
        peripheralsBusy = false
        if peripheralRefreshPending {
            peripheralRefreshPending = false
            requestPeripheralSnapshot()
        }
    }

    func applySetting(_ setting: MonitorSetting) {
        guard !busy, !needsRefresh, let before = settings, let value = settingsDraft[setting.rawValue] else { return }
        isApplying = true
        performSettings(message: "Applying \(setting.title)…") {
            try $0.apply(setting, value: value, from: before)
        }
    }

    private func performSettings(message: String,
                                 operation: @escaping (ScreenController) throws -> MonitorSettingsSnapshot) {
        guard !busy else { return }
        busy = true
        error = nil
        self.message = message
        queue.async {
            let result: Result<MonitorSettingsSnapshot, Error> = Result {
                try ScreenController.withHIDConnection(operation)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.isApplying = false
                switch result {
                case .success(let settings):
                    self.settings = settings
                    self.settingsDraft = settings.values
                    self.receive(settings.layout)
                    self.message = "Settings read back from monitor."
                case .failure(let error):
                    self.settings = nil
                    self.settingsDraft = [:]
                    self.error = String(describing: error)
                    self.message = "Refresh controls before trying again."
                }
                self.consumePendingRefresh()
            }
        }
    }

    private func receive(_ state: ScreenState) {
        if self.state != state { self.state = state }
        if split != (state.mode == .pbp) { split = state.mode == .pbp }
        if left != state.source1 { left = state.source1 }
        if right != state.source2 { right = state.source2 }
        verifiedAt = Date()
        needsRefresh = false
    }

    private func perform(message: String, operation: @escaping (ScreenController) throws -> ScreenState) {
        guard !busy else { return }
        busy = true
        error = nil
        self.message = message
        queue.async {
            // Each operation owns one synchronous HID session. Creation, I/O
            // and destruction stay on this thread and its CFRunLoop. Releasing
            // it before returning also frees the interprocess lock for the CLI.
            let result: Result<ScreenState, Error> = Result {
                try ScreenController.withHIDConnection(operation)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.isApplying = false
                self.pendingTarget = nil
                switch result {
                case .success(let state):
                    self.receive(state)
                    self.settings = nil
                    self.settingsDraft = [:]
                    self.message = state.mode == .pip ? "PIP active · choose a layout to replace it." : "Read back from monitor"
                case .failure(let error):
                    self.state = nil
                    self.error = String(describing: error)
                    self.message = "Refresh before trying again."
                }
                self.consumePendingRefresh()
            }
        }
    }

    private func consumePendingRefresh() {
        if externalKVMRefreshPending {
            externalKVMRefreshPending = false
            refreshKVM()
        } else if externalRefreshPending {
            externalRefreshPending = false
            refreshAfterExternalChange()
        }
    }
}

extension Input {
    var title: String {
        switch self {
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .dp: return "DisplayPort"
        case .usbc: return "USB-C"
        }
    }
}
