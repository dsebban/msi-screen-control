import SwiftUI
import MSIScreenCore

/// Both tabs use the same guarded whole-hub handoff and current-host readback.
struct USBHostControls: View {
    @ObservedObject var store: MonitorStore
    let machines: [MachineDefinition]
    let configurationError: String?
    let controlsBusy: Bool
    var showReceiverSummary = true
    private let hubMessage = "All devices on the monitor’s USB hub move together. Keep keyboard and mouse in receiver mode."

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard").foregroundStyle(usbHostTint)
                Image(systemName: "computermouse").foregroundStyle(usbHostTint)
                Text("Keyboard & mouse").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 3)
                Text(usbHostName).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(usbHostTint)
                Text(store.kvm?.route.title ?? "Not read")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("usb-route-status")
                Button { store.refreshPeripherals() } label: {
                    if store.kvmBusy || store.peripheralsBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh the USB host and keyboard/mouse receiver status")
                .accessibilityLabel("Refresh USB route")
                .accessibilityIdentifier("refresh-peripherals")
                .disabled(store.busy || store.peripheralsBusy || controlsBusy)
            }
            HStack(spacing: 7) {
                usbRouteButton(.usbc, title: "Mac", accessibilityLabel: "USB-C Mac")
                usbRouteButton(.upstream, title: usbUpstreamMachine?.name ?? "Linux",
                               accessibilityLabel: "USB-B \(usbUpstreamMachine?.name ?? "Linux")")
            }
            if showReceiverSummary {
                VStack(spacing: 4) {
                    receiverRow(.bolt, label: "Keyboard", symbol: "keyboard")
                    receiverRow(.rapoo, label: "Mouse", symbol: "computermouse")
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Text(store.kvmBusy ? store.kvmMessage : hubMessage)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(store.kvmMessage + " " + hubMessage)
                    .accessibilityIdentifier("usb-route-message")
                Spacer(minLength: 0)
                if let checked = store.peripherals?.checkedAt {
                    Text(checked, style: .time)
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                        .help("Receivers checked on \(store.peripherals?.hostName ?? "this computer")")
                }
            }
            if let issue = usbConfigurationIssue {
                Text(issue).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("usb-route-configuration")
            }
            if let error = store.kvmError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("usb-route-error")
            }
            if let error = store.peripheralsError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("peripheral-error")
            }
        }
        .monitorCard(tint: usbHostTint, inset: 10)
    }

    static func hostName(for status: KVMStatus?, machines: [MachineDefinition]) -> String {
        guard let status else { return "Not read" }
        if status.route == .auto { return "Automatic" }
        if let machine = machines.first(where: { $0.id == status.machineID }) {
            return machine.name
        }
        return status.controlHost == .local ? "This Mac" : "Linux"
    }

    private var usbHostName: String { Self.hostName(for: store.kvm, machines: machines) }

    private var usbHostTint: Color {
        switch store.kvm?.route {
        case .usbc: return MonitorAppearance.tint(for: Input.usbc)
        case .upstream: return MonitorAppearance.tint(for: Input.dp)
        default: return MonitorAppearance.secondaryText
        }
    }

    private func receiverRow(_ kind: USBReceiverKind, label: String, symbol: String) -> some View {
        let receiver = store.peripherals?.receivers.first { $0.id == kind }
        let summary = receiver.map(receiverSummary) ?? "Not checked"
        return HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(.secondary)
            Text(receiver?.displayName ?? label).font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 3)
            Text(summary).font(.system(size: 10)).foregroundStyle(MonitorAppearance.secondaryText)
                .lineLimit(1)
            Circle().fill(receiver.map(receiverColor) ?? .secondary).frame(width: 5, height: 5)
        }
        .help(receiver.map(receiverDetails) ?? "Refresh to inspect the receiver.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) receiver: \(summary)")
        .accessibilityIdentifier("receiver-\(kind == .bolt ? "bolt" : "rapoo")-status")
    }

    private func receiverSummary(_ receiver: USBReceiverSnapshot) -> String {
        switch receiver.connection {
        case .notDetected: return "Receiver not detected"
        case .elsewhere: return "Outside monitor hub"
        case .monitorHub: break
        }
        guard receiver.id == .bolt else { return "Receiver detected" }
        let keyboards = receiver.pairedDevices.filter { $0.kind == .keyboard }
        guard let keyboard = keyboards.first else { return "Detected · keyboard not checked" }
        if keyboards.count > 1 {
            let responding = keyboards.filter { $0.radio == .responding }.count
            return "\(keyboards.count) pairings · \(responding) responding"
        }
        switch keyboard.radio {
        case .responding: return "Detected · keyboard responding"
        case .notResponding: return "Detected · keyboard not responding"
        case .unavailable: return "Detected · radio unavailable"
        }
    }

    private func receiverColor(_ receiver: USBReceiverSnapshot) -> Color {
        guard receiver.connection == .monitorHub else {
            return receiver.connection == .elsewhere ? .orange : .secondary
        }
        guard receiver.id == .bolt else { return .green }
        let keyboards = receiver.pairedDevices.filter { $0.kind == .keyboard }
        if keyboards.contains(where: { $0.radio == .responding }) { return .green }
        return keyboards.contains(where: { $0.radio == .notResponding }) ? .orange : .secondary
    }

    private func receiverDetails(_ receiver: USBReceiverSnapshot) -> String {
        let names = receiver.pairedDevices.compactMap(\.name)
        let errors = [receiver.error].compactMap { $0 } + receiver.pairedDevices.compactMap(\.error)
        return ([receiver.displayName] + names + errors).joined(separator: "\n")
    }

    private var usbUpstreamMachine: MachineDefinition? {
        let candidates = machines.filter { $0.platform == .linux }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private var usbConfigurationIssue: String? {
        let local = machines.filter { $0.isLocal && $0.platform == .macos && $0.input == .usbc }
        guard local.count == 1 else {
            return "Assign this Mac to USB-C before switching the USB hub."
        }
        let linux = machines.filter { $0.platform == .linux }
        guard linux.count == 1 else {
            return linux.isEmpty ? "Add the Linux machine connected to USB-B."
                : "More than one Linux machine is configured. The USB-B destination is ambiguous."
        }
        return nil
    }

    private func usbRouteButton(_ route: KVMRoute, title: String, accessibilityLabel: String) -> some View {
        Button { store.setKVM(route, expectedMachines: machines) } label: {
            HStack(spacing: 6) {
                Image(systemName: route == .usbc ? "laptopcomputer" : "desktopcomputer")
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(route == .usbc ? "USB-C" : "USB-B").font(.system(size: 9)).opacity(0.7)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MonitorRouteButtonStyle(tint: MonitorAppearance.tint(for: route == .usbc ? Input.usbc : .dp),
                                            selected: store.kvm?.route == route, height: 32))
        // USB return is independent of video state; local HID disappears during
        // a successful handoff and is reached through the Linux companion.
        .disabled(store.busy || store.peripheralsBusy || store.rapooDetailsBusy || store.popDetailsBusy
                  || store.pointerProbeBusy || controlsBusy || configurationError != nil || store.kvm == nil
                  || usbConfigurationIssue != nil || store.kvm?.route == route)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(store.kvm?.route == route ? "Current USB host" : "")
        .accessibilityIdentifier("usb-route-\(route.rawValue)")
    }

}
