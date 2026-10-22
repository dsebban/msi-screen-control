import AppKit
import SwiftUI
import MSIScreenCore

/// Readback and short, user-triggered diagnostics stay distinct from documented
/// device features. Receiver enumeration cannot establish mouse radio state.
struct PeripheralsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var appSwitch = AppSwitchController.shared
    @State private var hostActionError: String?
    @State private var receiverRefreshPending = false
    let usbHostName: String
    let machines: [MachineDefinition]
    let upstreamMachineID: String?
    let configurationError: String?
    let controlsBusy: Bool
    @ObservedObject var inventory: DeviceInventoryStore
    @ObservedObject var deviceControl: DeviceControlStore

    private let mouseTint = Color(red: 0.35, green: 0.64, blue: 1)
    private let keyboardTint = Color(red: 0.80, green: 0.57, blue: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your peripherals").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 4) {
                        Text(hostDescription)
                        if let checkedAt = store.peripherals?.checkedAt {
                            Text("·")
                            Text(checkedAt, style: .time).monospacedDigit()
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            USBHostControls(store: store, machines: machines, upstreamMachineID: upstreamMachineID,
                            configurationError: configurationError,
                            controlsBusy: controlsBusy, showReceiverSummary: false)
            DetectedPeripheralsView(inventory: inventory, control: deviceControl)
            if receiverIsPresent(.rapoo) {
                DisclosureGroup("Rapoo mouse controls") { mouseCard.disabled(controlsBusy) }
                    .accessibilityIdentifier("rapoo-controls")
            }
            if receiverIsPresent(.bolt), let name = popKeyboardName {
                DisclosureGroup("\(name) controls") { keyboardCard.disabled(controlsBusy) }
                    .accessibilityIdentifier("pop-controls")
            }
            // Native controller discovery also recognizes alternate pairing modes
            // that have no generic game-controller usage in the passive HID list.
            GameControllersView()
            DisclosureGroup("Privacy & permissions") { PrivacyStatusView() }
        }
        .onChange(of: inventory.snapshot?.devices.flatMap(\.endpoints).map { "\($0.id):\($0.incarnationID)" }) { _ in
            // Coalesce topology changes while an operation owns the device.
            // This refresh reads receiver metadata; it never edits a draft.
            receiverRefreshPending = true
            refreshReceiversWhenIdle()
        }
        .onChange(of: store.hasActiveOperation) { _ in refreshReceiversWhenIdle() }
        .onChange(of: controlsBusy) { _ in refreshReceiversWhenIdle() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("peripherals-screen")
    }

    private func refreshReceiversWhenIdle() {
        guard receiverRefreshPending, !store.hasActiveOperation, !controlsBusy else { return }
        receiverRefreshPending = false
        if store.kvm?.controlHost == .local { store.refreshPeripherals() }
    }

    private var hostDescription: String {
        guard let snapshot = store.peripherals else { return "Refresh to inspect the monitor’s USB devices." }
        return "Checked on \(snapshot.hostName)"
    }

    private var mouseCard: some View {
        let receiver = receiver(.rapoo)
        return VStack(alignment: .leading, spacing: 10) {
            deviceHeader("Rapoo mouse", subtitle: "Detected NearLink receiver · device controls",
                         symbol: "computermouse", tint: mouseTint)
            statusRow("Receiver", value: connectionDescription(receiver),
                      color: connectionColor(receiver), id: "rapoo-detail-connection")
            statusRow("Mouse telemetry", value: mouseTelemetryDescription,
                      color: mouseTelemetryReceived ? .green : .secondary, id: "rapoo-detail-radio")
            HStack(spacing: 8) {
                Text("Battery & firmware").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Button { store.refreshRapooDetails() } label: {
                    if store.rapooDetailsBusy {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Reading…")
                        }
                    } else {
                        Text("Read mouse details")
                    }
                }
                .controlSize(.small)
                .disabled(store.busy || store.rapooDetailsBusy || store.kvm?.controlHost != .local
                          || receiver?.connection != .monitorHub)
                .accessibilityLabel("Read mouse details")
                .accessibilityIdentifier("read-rapoo-details")
            }
            if let details = store.rapooDetails { mouseDetails(details) }
            if let error = store.rapooDetailsError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rapoo-details-error")
            }
            Divider().opacity(0.6)
            hostWheelControls
            Divider().opacity(0.6)
            mouseTest
            DisclosureGroup("Features & device controls") {
                VStack(alignment: .leading, spacing: 10) {
                    feature("Side wheel", detail: "Choose horizontal scrolling or host shortcuts under Onboard side wheel. Mac shortcuts can switch apps or Spaces; ChimeraOS uses its native app switcher.")
                    manufacturerMappings
                    feature("DPI", detail: "The button behind the main wheel cycles DPI by default. Pinning it to an app replaces that action and keeps the selected DPI.")
                    feature("Connection modes", detail: "NearLink receiver, Bluetooth and wired. Keep the receiver connection selected for monitor USB sharing.")
                    feature("Onboard profiles", detail: "Rapoo documents 1+10 programmable buttons and onboard memory. MSI Screen reads the side wheel, top button and DPI slots. Other mappings use A HUB.")
                    if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.yourcompany.A-HUB") {
                        Button("Open A HUB") { NSWorkspace.shared.open(applicationURL) }
                            .controlSize(.small)
                            .accessibilityIdentifier("open-rapoo-ahub")
                            .help("Configure the mouse in Rapoo’s installed native app.")
                    }
                    Text("MSI Screen configures the side wheel and top button. Use A HUB for other mouse settings.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Link("Rapoo device guide", destination: URL(string: "https://www.rapoo.com/en/product/MT760PRO")!)
                        Link("Rapoo A HUB Office", destination: URL(string: "https://www.rapoo.com/en/support/downloadcenter")!)
                    }
                    .font(.caption)
                }
                .padding(.top, 9)
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rapoo-features")
        }
        .peripheralCard(tint: mouseTint)
    }

    private var mouseTelemetryReceived: Bool {
        guard let details = store.rapooDetails else { return false }
        return details.mouseFirmware != nil || details.batteryPercent != nil
    }

    private var mouseTelemetryDescription: String {
        if store.rapooDetailsBusy { return "Reading…" }
        guard store.rapooDetails != nil else { return "Not checked" }
        return mouseTelemetryReceived ? "Reply received at last check" : "No mouse data reported"
    }

    private func mouseDetails(_ details: RapooMouseDetails) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Battery").foregroundStyle(.secondary)
                Text(details.batteryPercent.map { "\($0)%" } ?? "Not reported")
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                Text(details.checkedAt, style: .time).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
            .help("Read on \(details.hostName). Battery state does not establish mouse input delivery.")
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("rapoo-detail-battery")
            if let dpi = details.dpi {
                statusRow("Pointer DPI", value: "\(dpi.currentDPI) · slot \(dpi.activeSlot) of \(dpi.slots.count)",
                          color: .primary, id: "rapoo-current-dpi")
                    .help("Saved DPI slots: " + dpi.slots.map(String.init).joined(separator: ", "))
            }
            if let mapping = details.topButtonMapping {
                topButtonControls(mapping)
            }
            DisclosureGroup("Onboard side wheel") {
                VStack(alignment: .leading, spacing: 7) {
                    if details.sideWheelMappings.isEmpty {
                        Text("Side-wheel mappings were not reported.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ForEach(details.sideWheelMappings, id: \.keyID) { mapping in
                            statusRow(wheelDirection(mapping), value: wheelFunction(mapping.function),
                                      color: mapping.function == "unknown" ? .orange : .primary,
                                      id: "rapoo-sidewheel-\(mapping.keyID)")
                                .help(wheelMappingDetails(mapping))
                        }
                        sideWheelControls(details.sideWheelMappings)
                    }
                }
                .padding(.top, 7)
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rapoo-sidewheel-mappings")
            DisclosureGroup("Firmware details") {
                VStack(alignment: .leading, spacing: 7) {
                    statusRow("Mouse firmware", value: details.mouseFirmware ?? "Not reported",
                              color: .primary, id: "rapoo-detail-mouse-firmware")
                    statusRow("Receiver firmware", value: details.dongleFirmware ?? "Not reported",
                              color: .primary, id: "rapoo-detail-receiver-firmware")
                }
                .padding(.top, 7)
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rapoo-firmware-details")
            ForEach(Array(details.errors.enumerated()), id: \.offset) { _, error in
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rapoo-device-details")
    }

    private func topButtonControls(_ mapping: RapooButtonMapping) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            statusRow("Button behind main wheel",
                      value: mapping.function == "pinnedApp" ? "Pinned app · F20"
                          : mapping.function == "dpiCycle" ? "Cycle DPI" : "Custom mapping",
                      color: .primary, id: "rapoo-top-button")
            HStack(spacing: 8) {
                Button("Pin to Tern") {
                    Task {
                        _ = try? await store.setTopButton(.pinnedApp, expectedRecordHex: mapping.rawRecordHex,
                                                         bundleIdentifier: "so.stencil.tern")
                    }
                }
                .accessibilityIdentifier("rapoo-pin-tern")
                Button("Restore DPI button") {
                    Task {
                        _ = try? await store.setTopButton(.dpiCycle, expectedRecordHex: mapping.rawRecordHex,
                                                         bundleIdentifier: nil)
                    }
                }
                .accessibilityIdentifier("rapoo-restore-dpi")
                if store.topButtonChangeBusy { ProgressView().controlSize(.mini) }
            }
            .controlSize(.small)
            .disabled(store.busy || store.rapooDetailsBusy || store.pointerProbeBusy
                      || store.kvm?.controlHost != .local)
            if appSwitch.pinActive {
                Label("Pinned app ready on this Mac", systemImage: "pin.fill")
                    .font(.system(size: 10)).foregroundStyle(.green)
                    .help(appSwitch.pinnedApplicationBundleID ?? "")
            }
            if let error = store.topButtonChangeError ?? appSwitch.lastPinError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.topButtonChange?.verified == true {
                Text("Top-button mapping verified on the mouse.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func sideWheelControls(_ mappings: [RapooWheelMapping]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                wheelPresetButton("Horizontal scroll", preset: .horizontal, mappings: mappings)
                wheelPresetButton("Host shortcuts", preset: .appSwitch, mappings: mappings)
                if store.sideWheelChangeBusy { ProgressView().controlSize(.mini) }
            }
            .disabled(store.busy || store.rapooDetailsBusy || store.pointerProbeBusy
                      || store.kvm?.controlHost != .local || mappings.count != 2)
            Text("F18/F19 follow the receiver. Mac: use the action below. ChimeraOS: roll through apps, then pause to select.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if appSwitch.active {
                Label(appSwitch.mode == .spaces ? "Spaces control ready on this Mac" : "App switching ready on this Mac",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundStyle(.green)
                    .accessibilityIdentifier("app-switch-ready")
            }
            if let error = store.sideWheelChangeError ?? appSwitch.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.sideWheelChange?.verified == true {
                Text("Both wheel mappings verified on the mouse.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var hostWheelControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Side wheel on this Mac").font(.system(size: 11, weight: .medium))
            Picker("Side wheel on this Mac", selection: Binding(
                get: { store.wheelHostAction },
                set: { action in
                    do { try store.setWheelHostAction(action); hostActionError = nil }
                    catch { hostActionError = error.localizedDescription }
                }
            )) {
                Text("Applications").tag(RapooWheelHostAction.applications)
                Text("Spaces").tag(RapooWheelHostAction.spaces)
            }
            .pickerStyle(.segmented)
            .disabled(store.sideWheelChangeBusy)
            .accessibilityIdentifier("rapoo-wheel-host-action")
            Text("Requires Host shortcuts on the mouse and MSI Screen running. Spaces uses Control–Left/Right.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = hostActionError ?? appSwitch.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func wheelPresetButton(_ title: String, preset: RapooSideWheelPreset,
                                   mappings: [RapooWheelMapping]) -> some View {
        Button(title) {
            Task { _ = try? await store.setSideWheel(preset, expected: mappings) }
        }
        .controlSize(.small)
        .accessibilityIdentifier(preset == .appSwitch ? "rapoo-wheel-app-switch" : "rapoo-wheel-horizontal")
    }

    private func wheelDirection(_ mapping: RapooWheelMapping) -> String {
        switch mapping.direction {
        case "horizontalNegative": return "← Left"
        case "horizontalPositive": return "Right →"
        default: return "Direction unknown · key \(mapping.keyID)"
        }
    }

    private func wheelFunction(_ function: String) -> String {
        switch function {
        case "horizontalScroll": return "Horizontal scrolling"
        case "defaultHorizontalScroll": return "Default horizontal scrolling"
        case "verticalScroll": return "Vertical scrolling"
        case "disabled": return "Disabled"
        case "appSwitchPrevious": return "Previous · F18"
        case "appSwitchNext": return "Next · F19"
        default: return "Unknown mapping"
        }
    }

    private func wheelMappingDetails(_ mapping: RapooWheelMapping) -> String {
        var parts = ["Device direction; system scrolling preferences may reverse it.",
                     "Onboard key \(mapping.keyID)", "Record: \(mapping.rawRecordHex)"]
        if let type = mapping.logicalType { parts.append("Logical type: \(type)") }
        return parts.joined(separator: "\n")
    }

    private var manufacturerMappings: some View {
        // Rapoo A HUB 1.1.15 embeds this UI layout in
        // DeviceProfile/Device/MT760-NL.json. It is not an onboard readback.
        VStack(alignment: .leading, spacing: 5) {
            Text("Manufacturer defaults · not live mappings")
                .font(.system(size: 11, weight: .medium))
            mappingGuideRow("Clicks", value: "Left · Middle · Right")
            mappingGuideRow("Thumb buttons", value: "Forward · Back")
            mappingGuideRow("Side wheel", value: "Horizontal left · right")
            mappingGuideRow("Main wheel", value: "Vertical up · down")
            mappingGuideRow("Device buttons", value: "DIY · DPI cycle")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rapoo-default-mapping-guide")
    }

    private func mappingGuideRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 10))
    }

    private var keyboardCard: some View {
        let receiver = receiver(.bolt)
        return VStack(alignment: .leading, spacing: 10) {
            deviceHeader(popKeyboardName ?? "Keyboard", subtitle: "Observed Bolt receiver pairing",
                         symbol: "keyboard", tint: keyboardTint)
            statusRow("Receiver", value: connectionDescription(receiver),
                      color: connectionColor(receiver), id: "pop-detail-connection")
            statusRow("Keyboard radio", value: keyboardRadio(receiver),
                      color: keyboardRadioColor(receiver), id: "pop-detail-radio")
            HStack {
                Text("Device details").font(.system(size: 11, weight: .medium))
                Spacer()
                Button {
                    store.refreshPOPDetails()
                } label: {
                    if store.popDetailsBusy {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Reading…")
                        }
                    } else {
                        Text("Read keyboard details")
                    }
                }
                .controlSize(.small)
                .disabled(store.busy || store.peripheralsBusy || store.popDetailsBusy || receiver?.pairedDevices.isEmpty != false)
                .accessibilityLabel("Read keyboard details")
                .accessibilityIdentifier("read-pop-details")
            }
            if let details = store.popDetails {
                keyboardDetails(details)
            }
            if let error = store.popDetailsError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pop-details-error")
            }
            DisclosureGroup("Setup & keyboard features") {
                VStack(alignment: .leading, spacing: 10) {
                    feature("Sharing setup", detail: "Use Easy-Switch 1 for your Bolt receiver. Reserve channel 3 for your Bluetooth connection. This is setup guidance; the active channel is not read.")
                    feature("Emoji keys", detail: "Assign emoji keys in Logi Options+ on macOS or Windows. These mappings are not read or changed here.")
                    feature("Function row", detail: "POP Keys includes Fn shortcuts for actions such as screenshots and microphone mute. Key behavior depends on the host and software.")
                    feature("Keyboard layout", detail: "Hold Fn–O for three seconds for macOS, or Fn–P for Windows/Android. The current layout is not read here.")
                    if let receiver, !receiver.pairedDevices.isEmpty {
                        pairingDetails(receiver)
                    }
                    Link("Logitech setup guide", destination: URL(string: "https://www.logitech.com/en-ae/products/keyboards/pop-keys-wireless-mechanical.html")!)
                        .font(.caption)
                    Link("Logi Options+ for key customization", destination: URL(string: "https://www.logitech.com/software/logi-options-plus.html")!)
                        .font(.caption)
                }
                .padding(.top, 9)
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pop-features")
        }
        .peripheralCard(tint: keyboardTint)
    }

    private func keyboardDetails(_ details: POPKeyboardDetails) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text("Receiver slot \(details.slot)")
                Text("·")
                Text(details.checkedAt, style: .time).monospacedDigit()
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .help("Receiver pairing slot, not an Easy-Switch channel. Read on \(details.hostName).")
            statusRow("Battery", value: batteryDescription(details.battery), color: .primary,
                      id: "pop-detail-battery")
            statusRow("Fn row", value: details.fnMode.map {
                $0.inverted ? "Media & special keys without Fn" : "F-keys without Fn"
            } ?? "Not reported", color: .primary, id: "pop-detail-fn-mode")
            DisclosureGroup("Reported mappings & firmware") {
                VStack(alignment: .leading, spacing: 9) {
                    if details.firmware.isEmpty {
                        feature("Firmware", detail: "Not reported")
                    } else {
                        ForEach(Array(details.firmware.enumerated()), id: \.offset) { _, firmware in
                            feature(firmware.kind.rawValue.capitalized, detail: firmwareDescription(firmware))
                        }
                    }
                    Text("Device-reported mappings are read-only here. Logi Options+ actions can differ.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(details.controls) { control in
                        HStack(alignment: .top) {
                            Text(control.displayName).fontWeight(.medium)
                            Spacer(minLength: 8)
                            Text(mappingDescription(control, controls: details.controls))
                                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                        .font(.system(size: 10))
                    }
                    if !details.controlInventoryComplete {
                        Text("Some key mappings could not be read.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    DisclosureGroup("Reported features (\(details.features.count))") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(details.features) { feature in
                                HStack {
                                    Text(feature.displayName)
                                    Spacer()
                                    Text("v\(feature.version)").foregroundStyle(.secondary)
                                }
                            }
                            if !details.featureInventoryComplete {
                                Text("Feature discovery is incomplete.").foregroundStyle(.orange)
                            }
                        }
                        .font(.system(size: 10)).padding(.top, 6)
                    }
                    ForEach(Array(details.errors.enumerated()), id: \.offset) { _, error in
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 11, weight: .medium))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pop-reported-details")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pop-device-details")
    }

    private func batteryDescription(_ battery: PeripheralBattery?) -> String {
        guard let battery else { return "Not reported" }
        var parts: [String] = []
        if let percentage = battery.percentage { parts.append("\(percentage)%") }
        else if let level = battery.level { parts.append(level.rawValue.capitalized) }
        if let state = battery.statusDescription { parts.append(state) }
        if parts.isEmpty, let millivolts = battery.voltageMillivolts { parts.append("\(millivolts) mV") }
        return parts.isEmpty ? "No value reported" : parts.joined(separator: " · ")
    }

    private func firmwareDescription(_ firmware: PeripheralFirmware) -> String {
        var parts = [firmware.prefix, firmware.version].compactMap { $0 }
        if let build = firmware.build { parts.append("build \(build)") }
        return parts.isEmpty ? "No version reported" : parts.joined(separator: " ")
    }

    private func mappingDescription(_ control: PeripheralControl, controls: [PeripheralControl]) -> String {
        guard let target = control.currentControlID else { return "Mapping not read" }
        if target == control.controlID { return control.defaultTaskName }
        if let mapped = controls.first(where: { $0.controlID == target }) {
            return "Mapped to \(mapped.displayName)"
        }
        return String(format: "Mapped to control 0x%04X", target)
    }

    private var mouseTest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wheels & buttons").font(.system(size: 12, weight: .semibold))
                    Text("A 10-second test on this Mac")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                Button { store.startPointerProbe() } label: {
                    if store.pointerProbeBusy {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test mouse controls")
                    }
                }
                .controlSize(.small)
                .disabled(store.busy || store.pointerProbeBusy || store.kvm?.controlHost != .local
                          || store.pointerDescriptor?.access != .granted
                          || store.pointerDescriptor?.connection != .monitorHub
                          || store.pointerDescriptor?.error != nil)
                .accessibilityLabel("Test mouse controls")
                .accessibilityIdentifier("test-mouse-controls")
            }
            if store.pointerProbeBusy {
                Text("Move both wheels and press the mouse buttons. Only event counts are kept.")
                    .font(.system(size: 10)).foregroundStyle(mouseTint)
                    .accessibilityIdentifier("pointer-probe-progress")
            }
            if store.kvm?.controlHost != .local {
                Text("Mouse tests run on this Mac. Choose this Mac as the USB host to test.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pointer-probe-host-required")
            }
            if let descriptor = store.pointerDescriptor ?? store.pointerProbe?.descriptor {
                descriptorSummary(descriptor)
            }
            if let probe = store.pointerProbe {
                probeResults(probe)
            }
            if let error = store.pointerProbeError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pointer-probe-error")
            }
        }
    }

    private func descriptorSummary(_ descriptor: PointerDescriptorSnapshot) -> some View {
        let horizontal = descriptor.usages.contains { $0.kind == .horizontalWheel }
        let vertical = descriptor.usages.contains { $0.kind == .verticalWheel }
        let buttons = descriptor.usages.filter { $0.kind == .button }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Declared HID controls").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            if descriptor.usages.isEmpty {
                Text("No control metadata reported.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    capabilityChip("Side wheel", present: horizontal)
                    capabilityChip("Main wheel", present: vertical)
                    capabilityChip("\(buttons) buttons", present: buttons > 0)
                }
            }
            if descriptor.access != .granted {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow Input Monitoring for MSI Screen to observe mouse controls, then refresh.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Button("Open Input Monitoring") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("open-input-monitoring")
                }
            }
            if let error = descriptor.error, error != store.pointerProbeError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pointer-descriptor")
    }

    private func probeResults(_ probe: PointerProbeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            probeCount("Side wheel", kind: .horizontalWheel, probe: probe)
            probeCount("Main wheel", kind: .verticalWheel, probe: probe)
            probeCount("Buttons", kind: .button, probe: probe)
            HStack(spacing: 4) {
                Text("Tested")
                Text(probe.checkedAt, style: .time).monospacedDigit()
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
            if probe.disconnected {
                Text("Receiver disconnected during the test. Refresh and test again.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            } else if !probe.completed {
                Text(probe.error ?? "The input test did not complete.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pointer-probe-results")
    }

    private func probeCount(_ title: String, kind: PointerInputKind, probe: PointerProbeSnapshot) -> some View {
        let counts = probe.counts.filter { $0.descriptor.kind == kind }
        let count = counts.reduce(0) { $0 + $1.nonzeroSamples }
        let positive = counts.reduce(0) { $0 + $1.positiveSamples }
        let negative = counts.reduce(0) { $0 + $1.negativeSamples }
        return HStack {
            Text(title)
            Spacer()
            Text(count == 0 ? "No input observed" : kind == .button ? "\(count) input events"
                 : "\(count) events · +\(positive) / −\(negative)")
                .foregroundStyle(count > 0 ? Color.green : MonitorAppearance.secondaryText)
        }
        .font(.system(size: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pointer-result-\(kind.rawValue)")
    }

    private func capabilityChip(_ title: String, present: Bool) -> some View {
        Text(present ? title : "\(title) not declared")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(present ? mouseTint : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
    }

    private func deviceHeader(_ title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint).frame(width: 38, height: 38)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusRow(_ label: String, value: String, color: Color, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(color)
        }
        .font(.system(size: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private func feature(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pairingDetails(_ receiver: USBReceiverSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Stored receiver pairings").font(.system(size: 11, weight: .medium))
            ForEach(receiver.pairedDevices, id: \.slot) { pairing in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(pairing.name ?? "Slot \(pairing.slot)")
                        Spacer(minLength: 4)
                        Text(radioDescription(pairing.radio)).foregroundStyle(.secondary)
                    }
                    if pairing.kind == .keyboard && ["POP Keys", "Logi POP Keys"].contains(pairing.name ?? "") {
                        Button("Read receiver slot \(pairing.slot)") { store.refreshPOPDetails(slot: pairing.slot) }
                            .controlSize(.mini)
                            .disabled(store.busy || store.peripheralsBusy || store.popDetailsBusy)
                            .accessibilityLabel("Read keyboard details for receiver slot \(pairing.slot)")
                    }
                }
                .font(.system(size: 10))
            }
            Text("Stored slots can refer to the same keyboard. A missing reply may mean it is asleep.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var popKeyboardName: String? {
        receiver(.bolt)?.pairedDevices.first {
            $0.kind == .keyboard && ["POP Keys", "Logi POP Keys"].contains($0.name ?? "")
        }?.name
    }

    private func receiverIsPresent(_ kind: USBReceiverKind) -> Bool {
        guard let observed = receiver(kind), observed.connection != .notDetected else { return false }
        // Remote observations remain explicitly scoped to the checked USB host.
        if store.kvm?.controlHost != .local { return true }
        let vendor: UInt32 = kind == .bolt ? 0x046d : 0x24ae
        let product: UInt32 = kind == .bolt ? 0xc548 : 0x186a
        return inventory.snapshot?.devices.flatMap(\.endpoints).contains {
            $0.identity.vendorID == vendor && $0.identity.productID == product
        } == true
    }

    private func receiver(_ kind: USBReceiverKind) -> USBReceiverSnapshot? {
        store.peripherals?.receivers.first { $0.id == kind }
    }

    private func connectionDescription(_ receiver: USBReceiverSnapshot?) -> String {
        guard let receiver else { return store.peripheralsBusy ? "Checking…" : "Not checked" }
        switch receiver.connection {
        case .monitorHub: return "Monitor hub · \(usbHostName.isEmpty ? "USB host" : usbHostName)"
        case .elsewhere: return "Detected outside monitor hub"
        case .notDetected: return "Not detected"
        }
    }

    private func connectionColor(_ receiver: USBReceiverSnapshot?) -> Color {
        guard let receiver else { return .secondary }
        switch receiver.connection {
        case .monitorHub: return .green
        case .elsewhere: return .orange
        case .notDetected: return .secondary
        }
    }

    private func keyboardRadio(_ receiver: USBReceiverSnapshot?) -> String {
        let pairings = receiver?.pairedDevices.filter { $0.kind == .keyboard } ?? []
        guard !pairings.isEmpty else { return "Not checked" }
        if pairings.count == 1 { return radioDescription(pairings[0].radio) }
        return "\(pairings.count) pairings · \(pairings.filter { $0.radio == .responding }.count) responding"
    }

    private func keyboardRadioColor(_ receiver: USBReceiverSnapshot?) -> Color {
        let pairings = receiver?.pairedDevices.filter { $0.kind == .keyboard } ?? []
        if pairings.contains(where: { $0.radio == .responding }) { return .green }
        return pairings.contains(where: { $0.radio == .notResponding }) ? .orange : .secondary
    }

    private func radioDescription(_ radio: PeripheralRadioState) -> String {
        switch radio {
        case .responding: return "Responding"
        case .notResponding: return "No reply · may be asleep"
        case .unavailable: return "Unavailable"
        }
    }
}

private extension View {
    func peripheralCard(tint: Color) -> some View {
        padding(12)
            .background(LinearGradient(colors: [tint.opacity(0.045), .white.opacity(0.015)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25), lineWidth: 0.8))
    }
}
