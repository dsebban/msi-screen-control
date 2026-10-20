import AppKit
import SwiftUI
import MSIScreenCore

struct MonitorView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var prefs: MonitorPreferences
    @ObservedObject var computers: ComputersStore
    let closeControls: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: Tab = .layout
    @State private var machineEditor: MachineEditorRequest?
    @State private var expandedMachineIDs: Set<String> = []

    private struct MachineEditorRequest: Identifiable {
        let id = UUID()
        let machine: MachineDefinition?
    }

    private enum Tab: String, CaseIterable {
        case layout = "Layout", monitor = "Monitor", machines = "Machines", peripherals = "Peripherals"
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            tabControls

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .layout: layoutControls
                    case .monitor: monitorControls
                    case .machines: machineControls
                    case .peripherals:
                        PeripheralsView(store: store, usbHostName: usbHostName,
                                        machines: prefs.machines, configurationError: prefs.error,
                                        controlsBusy: computers.isMutating)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(width: MonitorAppearance.panelSize.width, height: MonitorAppearance.panelSize.height)
        .background(MonitorAppearance.panelBackground)
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .tint(MonitorAppearance.tint(for: store.state))
        .onChange(of: tab) { selection in
            store.showingSettings = selection == .monitor
            switch selection {
            case .layout: break
            case .monitor: store.refreshSettings()
            case .machines:
                store.refresh()
                computers.refresh()
            case .peripherals:
                store.refreshPeripherals()
                store.refreshPointerCapabilities()
            }
        }
        .sheet(item: $machineEditor) { request in
            MachineEditor(machine: request.machine, preferences: prefs) { computers.refresh() }
                .preferredColorScheme(.dark)
        }
    }

    private var tabControls: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: tab == item ? .semibold : .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(tab == item ? Color.white.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityValue(tab == item ? "Selected" : "Not selected")
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                if item != Tab.allCases.last {
                    Rectangle().fill(.white.opacity(0.13)).frame(width: 1, height: 18)
                }
            }
        }
        .padding(1)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
        .accessibilityIdentifier("controls-tab")
    }

    private var header: some View {
        HStack(spacing: 14) {
            MonitorMark(state: store.state)
                .frame(width: 41, height: 45)
            VStack(alignment: .leading, spacing: 3) {
                Text("MSI Screen").font(.system(size: 21, weight: .bold))
                Text("MD342CQP").font(.system(size: 14)).foregroundStyle(MonitorAppearance.secondaryText)
            }
            Spacer(minLength: 6)
            Button { tab = .layout } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.state?.mode == .pbp ? "rectangle.split.2x1" : "display")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(MonitorAppearance.tint(for: store.state))
                    Text(modeBadge).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 14).frame(height: 38)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.09)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose monitor layout")
        }
        .frame(height: 46)
    }

    private var modeBadge: String {
        guard let state = store.state else { return "—" }
        switch state.mode {
        case .pbp: return "PBP"
        case .pip: return "PIP"
        case .off: return state.source1.title
        }
    }

    private func refreshControls() {
        switch tab {
        case .layout: store.refreshKVM()
        case .monitor: store.refreshSettings()
        case .machines:
            store.refresh()
            computers.refresh()
        case .peripherals:
            store.refreshPeripherals()
            store.refreshPointerCapabilities()
        }
    }

    private var modeTitle: String {
        guard let state = store.state else { return "Connect monitor" }
        switch state.mode {
        case .off: return state.source1.title
        case .pbp: return "Side by side"
        case .pip: return "Picture in picture"
        }
    }

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(store.isApplying ? "APPLYING LAYOUT" : "LAYOUT PREVIEW")
                        .font(.system(size: 10, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.isApplying { ProgressView().controlSize(.mini) }
                }
                monitorPreview(current: false)
                if let current = store.currentLayout {
                    Text(current).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Picker("Layout", selection: $store.split) {
                Text("Full screen").tag(false)
                Text("Side by side").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("layout-mode")
            .disabled(store.busy || store.state == nil)

            VStack(spacing: 10) {
                inputPicker(store.split ? "Left input" : "Input", selection: $store.left)
                if store.split {
                    inputPicker("Right input", selection: $store.right)
                    Button("Swap sides", systemImage: "arrow.left.arrow.right") { store.swap() }
                        .accessibilityIdentifier("swap-sides")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(store.busy || store.state == nil)

            if store.duplicateInputs {
                Label("Choose two different inputs.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            if store.layoutApplication(machines: prefs.machines, followUSB: prefs.followFullscreenUSB)?.focusMachine != nil {
                if store.kvm == nil {
                    HStack {
                        Text("Read the USB host before applying full screen.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Read USB host") { store.refreshKVM() }
                            .accessibilityIdentifier("layout-refresh-usb")
                            .disabled(store.busy)
                    }
                } else {
                    Text("Full screen also moves the USB keyboard and mouse to this computer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Button { store.apply(machines: prefs.machines, followUSB: prefs.followFullscreenUSB) } label: {
                Text(store.busy ? "Working…" : "Apply layout").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!store.canApply(machines: prefs.machines, followUSB: prefs.followFullscreenUSB)
                      || computers.isMutating || prefs.error != nil)
            .accessibilityIdentifier("apply-layout")

            VStack(alignment: .leading, spacing: 9) {
                Label("Saved layout", systemImage: "bookmark")
                    .font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 9) {
                    Text("Save the monitor’s current inputs and split, then restore them when needed.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Save current layout") { store.saveSetup() }
                            .disabled(store.busy || store.state == nil)
                        Spacer(minLength: 4)
                        Button("Restore saved layout") { store.restoreSetup() }
                            .disabled(store.busy || computers.isMutating || store.state == nil || !store.hasSavedSetup)
                    }
                    .controlSize(.small)
                }
            }
            .monitorCard()
        }
    }

    private func monitorPreview(current: Bool) -> some View {
        let pending = store.pendingTarget ?? (current ? store.state : nil)
        let split = pending.map { $0.mode == .pbp } ?? store.split
        let left = pending?.source1 ?? store.left
        let right = pending?.source2 ?? store.right
        let unknown = current && store.state == nil && store.pendingTarget == nil
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                if unknown {
                    Label("Refresh to read the selected layout", systemImage: "display")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    previewPane(left, side: split ? "Left" : "Full screen")
                    if split {
                        previewPane(right, side: "Right")
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
            }
            .frame(height: current ? 48 : 126)
            .padding(5)
            .background(Color(red: 0.035, green: 0.04, blue: 0.065))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.47), lineWidth: 0.65))
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.12), .black.opacity(0.4), .white.opacity(0.13)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 26, height: 11)
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.28), .white.opacity(0.12)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 195, height: 3)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .topTrailing) {
            if current && store.isApplying {
                Label("Switching…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(9)
            }
        }
        .animation(motion, value: split)
        .animation(motion, value: left)
        .animation(motion, value: right)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unknown ? "Selected layout unavailable. Refresh monitor." :
            "\(current ? store.isApplying ? "Applying layout" : "Selected layout" : "Proposed layout"): \(left.title)\(split ? " left, \(right.title) right" : " full screen")")
    }

    private func previewPane(_ input: Input, side: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "display")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(MonitorAppearance.tint(for: input))
            Text(input.title).font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MonitorScreenArtwork(input: input))
        .help("\(inputName(input)) · \(side)")
    }

    private var monitorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings read from your monitor")
                .font(.subheadline.weight(.semibold))
            if let snapshot = store.settings {
                ForEach(settingCategories, id: \.self) { category in
                    GroupBox(category) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(MonitorSetting.allCases.filter { $0.category == category }, id: \.rawValue) {
                                settingControl($0, snapshot: snapshot)
                            }
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Label("HDR signal", systemImage: "sun.max")
                    Spacer()
                    Text(hdrDescription(snapshot.hdrActive)).foregroundStyle(.secondary)
                }
                .font(.caption)
                Text("HDR follows the video signal. Choose HDR in macOS Displays when available.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(store.busy ? "Reading available settings…" : "Refresh to read available controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Use Saved layout in the Layout tab to restore your inputs and split. Power cycling and factory reset require the monitor’s own controls.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var settingCategories: [String] {
        MonitorSetting.allCases.reduce(into: []) { categories, setting in
            if !categories.contains(setting.category) { categories.append(setting.category) }
        }
    }

    @ViewBuilder
    private func settingControl(_ setting: MonitorSetting, snapshot: MonitorSettingsSnapshot) -> some View {
        if let value = snapshot.value(setting), snapshot.unavailableReason(setting) == nil {
            let draft = store.settingsDraft[setting.rawValue] ?? value
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(setting.title).font(.caption.weight(.medium))
                    Spacer()
                    if setting.options.isEmpty {
                        Text("\(draft)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    if setting.options.isEmpty {
                        Slider(value: Binding(
                            get: { Double(store.settingsDraft[setting.rawValue] ?? value) },
                            set: { store.settingsDraft[setting.rawValue] = Int($0) }
                        ), in: Double(setting.range.lowerBound)...Double(setting.range.upperBound), step: 1)
                        .accessibilityLabel(setting.title)
                    } else {
                        Picker(setting.title, selection: Binding(
                            get: { store.settingsDraft[setting.rawValue] ?? value },
                            set: { store.settingsDraft[setting.rawValue] = $0 }
                        )) {
                            ForEach(setting.options.keys.sorted(), id: \.self) { option in
                                Text(setting.options[option] ?? "\(option)").tag(option)
                            }
                        }
                        .labelsHidden()
                    }
                    Button("Apply") { store.applySetting(setting) }
                        .disabled(store.busy || computers.isMutating || store.needsRefresh || draft == value)
                        .accessibilityLabel("Apply \(setting.title)")
                }
                .controlSize(.small)
                .disabled(store.busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(setting.title).font(.caption.weight(.medium))
                Text(snapshot.unavailableReason(setting) ?? "Unavailable from this monitor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hdrDescription(_ active: Bool?) -> String {
        guard let active else { return "Unavailable" }
        return active ? "Active" : "Inactive"
    }

    private var machineControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            monitorPreview(current: true).padding(.bottom, 2)
            peripheralControls
            ForEach(orderedMachines) { machine in
                machineCard(machine)
            }
            if prefs.machines.isEmpty {
                Text("Add a machine and assign the monitor input it uses.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .monitorCard()
            }
            connectionControls.padding(.top, 3)
        }
    }

    /// Keep the two visible machines in the same left/right order as PBP.
    private var orderedMachines: [MachineDefinition] {
        guard let state = store.state else { return prefs.machines }
        let inputs = state.mode == .pbp ? [state.source1, state.source2] : [state.source1]
        return prefs.machines.enumerated().sorted {
            let left = inputs.firstIndex(of: $0.element.input) ?? inputs.count
            let right = inputs.firstIndex(of: $1.element.input) ?? inputs.count
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    private var connectionControls: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(alignment: .top, spacing: 6) {
                DisclosureGroup("Connection & input management") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Move USB with full screen", isOn: $prefs.followFullscreenUSB)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("follow-fullscreen-usb")
                        Text("The USB-C Mac and \(usbUpstreamMachine?.name ?? "the Linux machine") full-screen choices also move the USB hub, including Apply layout. PBP and other inputs keep the selected USB host.")
                            .font(.caption).foregroundStyle(.secondary)
                        sharingControls
                        DisclosureGroup("Input names") {
                            VStack(spacing: 8) {
                                ForEach(Input.allCases, id: \.self) { input in
                                    HStack {
                                        Text(input.title).font(.caption).frame(width: 76, alignment: .leading)
                                        TextField("Automatic name", text: Binding(
                                            get: { prefs.inputNames[input.rawValue] ?? "" },
                                            set: { prefs.inputNames[input.rawValue] = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("\(input.title) computer name")
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                        .font(.caption)
                    }
                    .padding(.top, 12)
                }
                .font(.system(size: 13))
                .tint(MonitorAppearance.secondaryText)
                Button {
                    machineEditor = MachineEditorRequest(machine: nil)
                } label: { Image(systemName: "plus.circle").font(.system(size: 16)) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add machine")
                    .help("Add machine")
                    .disabled(store.busy || computers.busy || prefs.error != nil)
            }
        }
    }

    private var peripheralControls: some View {
        USBHostControls(store: store, machines: prefs.machines, configurationError: prefs.error,
                        controlsBusy: computers.isMutating)
            .onAppear { if store.peripherals == nil { store.refreshPeripherals() } }
    }

    private var usbHostName: String {
        USBHostControls.hostName(for: store.kvm, machines: prefs.machines)
    }

    private var usbUpstreamMachine: MachineDefinition? {
        let candidates = prefs.machines.filter { $0.platform == .linux }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func machineCard(_ machine: MachineDefinition) -> some View {
        let status = computers.statuses[machine.id]
        let tint = MonitorAppearance.tint(for: machine.input)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: machine.platform == .macos ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 37)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(machine.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if machine.isLocal {
                            Text("This Mac").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(red: 0.38, green: 0.79, blue: 1))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.blue.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(machine.input.title).help("Configured input assignment")
                        Text("·").foregroundStyle(.tertiary)
                        Text(machineDisplaySummary(machine, status: status))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(MonitorAppearance.secondaryText)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Circle().fill(reachabilityColor(status)).frame(width: 7, height: 7)
                    if !machine.isLocal {
                        Text(reachabilityText(status, local: false))
                            .font(.system(size: 10))
                            .foregroundStyle(MonitorAppearance.secondaryText)
                            .fixedSize()
                    }
                }
                .help(reachabilityText(status, local: machine.isLocal))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(reachabilityText(status, local: machine.isLocal))
                Button {
                    withAnimation(motion) {
                        if expandedMachineIDs.contains(machine.id) { expandedMachineIDs.remove(machine.id) }
                        else { expandedMachineIDs.insert(machine.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .rotationEffect(.degrees(expandedMachineIDs.contains(machine.id) ? 90 : 0))
                        .frame(width: 18, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MonitorAppearance.secondaryText)
                .accessibilityLabel("Connection details for \(machine.name)")
                .accessibilityValue(expandedMachineIDs.contains(machine.id) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("machine-\(machine.id)-details")
            }
            HStack(spacing: 7) {
                routeButton(machine, route: .fullscreen, title: "Full screen", suffix: "full-screen")
                routeButton(machine, route: .pbpLeft, title: "Left", suffix: "left")
                routeButton(machine, route: .pbpRight, title: "Right", suffix: "right")
            }
            if machine.platform == .macos {
                Divider().padding(.vertical, 4)
                Text("Main & extended displays")
                    .font(.system(size: 11, weight: .semibold))
                machineDetails(machine, status: status)
            }
            if expandedMachineIDs.contains(machine.id) {
                VStack(alignment: .leading, spacing: 9) {
                    Divider()
                    HStack(spacing: 5) {
                        Text(reachabilityText(status, local: machine.isLocal))
                        if let status {
                            Text("·")
                            Text(status.checkedAt, style: .time).monospacedDigit()
                        }
                        Spacer()
                        Menu {
                            Button("Edit machine…") {
                                machineEditor = MachineEditorRequest(machine: machine)
                            }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("Edit \(machine.name)")
                            .disabled(store.busy || computers.busy)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorAppearance.secondaryText)
                    if machine.platform != .macos {
                        machineDetails(machine, status: status)
                    }
                }
                .padding(.top, 2)
            }
        }
        .monitorCard(tint: isSelected(machine.input) ? tint : nil, inset: 9)
        .animation(motion, value: selectedPosition(machine.input))
    }

    private func machineDisplaySummary(_ machine: MachineDefinition, status: MachineStatus?) -> String {
        if let display = status?.macDisplays?.displays.first(where: \.isMonitor), let mode = display.mode {
            return "\(mode.width) × \(mode.height)"
        }
        // Linux connector modes list supported modes, not the active resolution.
        return selectedPosition(machine.input)
    }

    private func routeButton(_ machine: MachineDefinition, route: MachineRoute,
                             title: String, suffix: String) -> some View {
        let label = route == .fullscreen ? "Show \(machine.name) full screen"
            : "Show \(machine.name) on \(route == .pbpLeft ? "left" : "right")"
        return Button {
            store.route(machine, to: route, followUSB: prefs.followFullscreenUSB)
        } label: {
            Text(title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
        }
        .buttonStyle(MonitorRouteButtonStyle(tint: MonitorAppearance.tint(for: machine.input),
                                            selected: selectedRoute(machine.input) == route))
        .disabled(computers.isMutating || prefs.error != nil
                  || !store.canRoute(machine, to: route, followUSB: prefs.followFullscreenUSB))
        .accessibilityLabel(label)
        .accessibilityIdentifier("machine-\(machine.id)-\(suffix)")
    }

    @ViewBuilder
    private func machineDetails(_ machine: MachineDefinition, status: MachineStatus?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let status {
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let mac = status.macDisplays {
                    if mac.displays.count == 2,
                       mac.displays.contains(where: \.isBuiltIn),
                       mac.displays.contains(where: \.isMonitor) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("MacBook position beside MSI").font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 7) {
                                ForEach(MacLaptopPosition.allCases, id: \.self) { position in
                                    Button(position == .left ? "Left of MSI" : "Right of MSI") {
                                        computers.arrange(machine: machine, laptopPosition: position)
                                    }
                                    .buttonStyle(MonitorRouteButtonStyle(
                                        tint: MonitorAppearance.tint(for: machine.input),
                                        selected: mac.laptopPosition == position))
                                    .accessibilityLabel("Place \(machine.name) MacBook \(position.rawValue) of MSI")
                                    .accessibilityIdentifier("machine-\(machine.id)-laptop-\(position.rawValue)")
                                    .disabled(store.busy || computers.busy || prefs.error != nil
                                        || mac.laptopPosition == position
                                        || mac.displays.contains { $0.isMirrored || !$0.isActive || $0.isAsleep })
                                }
                            }
                            Text(mac.laptopPosition.map {
                                $0 == .left ? "Left → right: MacBook · MSI" : "Left → right: MSI · MacBook"
                            } ?? "Custom arrangement · choose a side to align the top edges")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(mac.arrangedDisplays, id: \.id) { display in
                        HStack(spacing: 8) {
                            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                                .frame(width: 20).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name).font(.caption.weight(.medium))
                                Text("\(display.isMain ? "Main" : display.isMirrored ? "Mirrored" : "Extended") · \(displayDetails(display))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if !display.isMain && (display.isBuiltIn || display.isMonitor) {
                                Button("Make main") {
                                    computers.makeMain(machine: machine, target: display.isMonitor ? .monitor : .builtIn)
                                }
                                .controlSize(.small)
                                .disabled(store.busy || computers.busy || prefs.error != nil || mac.displays.contains { $0.isMirrored || !$0.isActive || $0.isAsleep })
                                .accessibilityLabel(mainDisplayLabel(display, machine: machine))
                            }
                        }
                    }
                    if !mac.displays.contains(where: \.isMonitor) {
                        Text("MSI video isn’t detected on this Mac.").font(.caption).foregroundStyle(.secondary)
                    } else if mac.displays.contains(where: \.isMirrored) {
                        Text("Choose an extended desktop in macOS Displays before changing the main display.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if machine.platform == .linux {
                    if status.connectors.isEmpty {
                        Text("Video connector status unavailable.").foregroundStyle(.secondary)
                    } else {
                        ForEach(status.connectors, id: \.id) { connector in
                            HStack {
                                Text(connector.id)
                                Spacer()
                                Text(connector.status.rawValue.capitalized).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        Text("Connector detection does not confirm the image on the monitor.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Refresh to read this machine’s status.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func selectedRoute(_ input: Input) -> MachineRoute? {
        guard let state = store.state else { return nil }
        if state.mode == .off && state.source1 == input { return .fullscreen }
        if state.mode == .pbp && state.source1 == input { return .pbpLeft }
        if state.mode == .pbp && state.source2 == input { return .pbpRight }
        return nil
    }

    private func selectedPosition(_ input: Input) -> String {
        switch selectedRoute(input) {
        case .fullscreen: return "Full screen"
        case .pbpLeft: return "Left"
        case .pbpRight: return "Right"
        case nil:
            guard let state = store.state else { return "Unknown" }
            if state.mode == .pip && (state.source1 == input || state.pipInput == input) { return "PIP" }
            return "Not selected"
        }
    }

    private func isSelected(_ input: Input) -> Bool {
        guard let state = store.state else { return false }
        return state.source1 == input || (state.mode == .pbp && state.source2 == input)
            || (state.mode == .pip && state.pipInput == input)
    }

    private func reachabilityColor(_ status: MachineStatus?) -> Color {
        guard let reachable = status?.reachable else { return .secondary }
        return reachable ? .green : .orange
    }

    private func reachabilityText(_ status: MachineStatus?, local: Bool) -> String {
        guard let reachable = status?.reachable else {
            return status?.error == nil ? "Not checked" : "Check failed"
        }
        return reachable ? (local ? "Local status read" : "SSH reachable")
            : local ? "Local check failed" : "SSH unreachable"
    }

    private func mainDisplayLabel(_ display: MacDisplayInfo, machine: MachineDefinition) -> String {
        let location = machine.isLocal ? "this Mac" : machine.host == prefs.peerHost ? "other Mac" : machine.name
        return "Make \(display.isMonitor ? "MSI" : "laptop") main on \(location)"
    }

    private var sharingControls: some View {
        DisclosureGroup("Universal Control · Macs only") {
            VStack(alignment: .leading, spacing: 10) {
                Text(computers.sharingSummary).font(.caption)
                HStack {
                    Button("Check") { computers.checkSharing() }
                    Button("Reconnect") { computers.reconnectSharing() }
                    Spacer(minLength: 0)
                    Button("Settings…") { computers.openSharingSettings() }
                }
                .controlSize(.small)
                .disabled(store.busy || computers.busy)
                if !computers.sharingDetails.isEmpty {
                    DisclosureGroup("Details") {
                        Text(computers.sharingDetails).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled).padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .font(.caption)
    }

    private func displayDetails(_ display: MacDisplayInfo) -> String {
        var parts: [String] = []
        if display.isAsleep { parts.append("Asleep") }
        else if !display.isActive { parts.append("Inactive") }
        if let mode = display.mode { parts.append("\(mode.width) × \(mode.height)") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            if let error = prefs.error ?? store.error ?? (tab == .machines ? computers.error : nil) {
                Text(error).font(.caption).foregroundStyle(.red)
                    .lineLimit(4)
                    .help(error)
                    .accessibilityIdentifier("monitor-error")
            }
            HStack(spacing: 8) {
                if store.busy || computers.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: store.state != nil && !store.needsRefresh ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(store.state != nil && !store.needsRefresh ? Color.green : .orange)
                }
                Text(footerMessage)
                    .font(.system(size: 10)).foregroundStyle(MonitorAppearance.secondaryText)
                    .lineLimit(tab == .machines ? 1 : 2)
                    .help(tab == .machines ? "\(store.message) \(computers.message)" : footerMessage)
                    .accessibilityLabel(tab == .machines ? "\(store.message) \(computers.message)" : footerMessage)
                    .accessibilityIdentifier("monitor-status")
                Spacer(minLength: 0)
                Button { refreshControls() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                            .foregroundStyle(MonitorAppearance.tint(for: store.state))
                        if let date = store.verifiedAt {
                            Text(date, style: .time).font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(MonitorAppearance.secondaryText)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh current controls")
                .accessibilityLabel(tab == .peripherals ? "Refresh peripheral controls" : "Refresh monitor")
                .disabled(store.busy || computers.busy || (tab == .peripherals && store.pointerProbeBusy))
                Menu {
                    if tab == .layout {
                        Button("Copy CLI command") {
                            NSPasteboard.general.clearContents()
                            if let application = store.layoutApplication(machines: prefs.machines,
                                                                          followUSB: prefs.followFullscreenUSB) {
                                let suffix = application.focusMachine == nil && store.kvm?.controlHost == .upstream
                                    ? " --preserve-usb" : ""
                                NSPasteboard.general.setString(application.command + suffix, forType: .string)
                            }
                        }
                        .disabled(store.state == nil || store.duplicateInputs || store.busy)
                    }
                    Button("Close controls", action: closeControls)
                        .keyboardShortcut("w", modifiers: .command)
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .disabled(store.busy || computers.busy)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("App actions")
            }
        }
    }

    private var machineFooterMessage: String {
        if store.busy || store.needsRefresh || store.error != nil { return store.message }
        if computers.busy { return computers.message }
        return "Monitor detected · \(prefs.machines.count) configured"
    }

    private var footerMessage: String {
        if tab == .machines { return machineFooterMessage }
        guard tab == .peripherals else { return store.message }
        if store.pointerProbeBusy { return "Testing mouse controls · move wheels and buttons" }
        if store.peripheralsBusy { return "Checking receiver connections…" }
        return "Device status is checked on refresh."
    }

    private func inputName(_ input: Input) -> String {
        if let name = prefs.inputNames[input.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return prefs.machines.first(where: { $0.input == input })?.name ?? input.title
    }

    private func machineSymbol(for input: Input) -> String {
        let machine = prefs.machines.first { $0.input == input }
        return machine?.platform == .macos ? "laptopcomputer" : "desktopcomputer"
    }

    private func inputPicker(_ label: String, selection: Binding<Input>) -> some View {
        Picker(label, selection: selection) {
            ForEach(Input.allCases, id: \.self) { input in Text(input.title).tag(input) }
        }
    }
}

extension View {
    func monitorCard(tint: Color? = nil, inset: CGFloat = 11) -> some View {
        padding(inset)
            .background(LinearGradient(colors: [.white.opacity(0.035), .white.opacity(0.015)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint?.opacity(0.3) ?? Color.white.opacity(0.12), lineWidth: 0.8))
    }
}

struct MonitorRouteButtonStyle: ButtonStyle {
    let tint: Color
    let selected: Bool
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.black.opacity(0.88) : Color.white.opacity(0.92))
            .frame(height: height)
            .background(
                LinearGradient(colors: selected ? [tint, tint.opacity(0.85)] : [.white.opacity(0.085), .white.opacity(0.055)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? tint : .white.opacity(0.1), lineWidth: 0.7))
            .opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.7 : 1)
    }
}

private struct MachineEditor: View {
    let machine: MachineDefinition?
    @ObservedObject var preferences: MonitorPreferences
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var platform: MachinePlatform
    @State private var input: Input
    @State private var isLocal: Bool
    @State private var host: String
    @State private var error: String?

    init(machine: MachineDefinition?, preferences: MonitorPreferences, onSave: @escaping () -> Void) {
        self.machine = machine
        self.preferences = preferences
        self.onSave = onSave
        _name = State(initialValue: machine?.name ?? "")
        _platform = State(initialValue: machine?.platform ?? .macos)
        _input = State(initialValue: machine?.input ?? .dp)
        _isLocal = State(initialValue: machine?.isLocal ?? false)
        _host = State(initialValue: machine?.host ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(machine == nil ? "Add machine" : "Edit machine").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                    .accessibilityLabel("Machine name")
                Picker("Platform", selection: $platform) {
                    Text("macOS").tag(MachinePlatform.macos)
                    Text("Linux").tag(MachinePlatform.linux)
                }
                Picker("Monitor input", selection: $input) {
                    ForEach(Input.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("This Mac", isOn: $isLocal)
                    .disabled(platform != .macos)
                if !isLocal {
                    TextField("SSH host or alias", text: $host)
                        .accessibilityLabel("Machine SSH host")
                }
            }
            .formStyle(.grouped)
            .onChange(of: platform) { if $0 == .linux { isLocal = false } }
            Text("Assign the input that this machine uses. Remote checks use your existing trusted SSH connection; remote Macs also need the MSI Screen companion.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("machine-editor-error")
            }
            HStack {
                if let machine {
                    Button("Remove", role: .destructive) {
                        do {
                            try preferences.removeMachine(machine)
                            onSave()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (!isLocal && host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func save() {
        do {
            try preferences.saveMachine(MachineDefinition(
                id: machine?.id ?? UUID().uuidString.lowercased(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                platform: platform, input: input,
                host: isLocal ? nil : host.trimmingCharacters(in: .whitespacesAndNewlines)
            ), replacing: machine)
            onSave()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
