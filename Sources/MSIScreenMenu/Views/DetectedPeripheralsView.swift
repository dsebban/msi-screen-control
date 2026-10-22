import SwiftUI
import MSIScreenCore

/// The live OS inventory is the source of the list; support only adds controls.
struct DetectedPeripheralsView: View {
    @ObservedObject var inventory: DeviceInventoryStore
    @ObservedObject var control: DeviceControlStore

    private var devices: [DetectedPeripheral] {
        inventory.snapshot.map(DetectedPeripheral.from) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Detected on this Mac").font(.headline)
                Spacer()
                Button("Refresh devices") { inventory.refresh() }
                    .disabled(inventory.busy)
                    .accessibilityIdentifier("peripherals-refresh-devices")
            }
            Text("USB and Bluetooth devices update automatically. The monitor’s USB devices appear on the host that owns its USB hub.")
                .font(.caption2).foregroundStyle(.secondary)
            if devices.isEmpty {
                if inventory.busy {
                    Text("Checking connected devices…").font(.caption).foregroundStyle(.secondary)
                } else if let snapshot = inventory.snapshot, snapshot.usb == .complete, snapshot.hid == .complete {
                    Text("No external peripherals detected on this Mac.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Peripheral discovery is unavailable or incomplete.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(devices) { device in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Image(systemName: device.symbol).foregroundStyle(.cyan).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.caption.weight(.semibold))
                            Text(description(device)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    if let first = device.endpoints.first {
                        selectButton(first, title: "Controls & agent support")
                    }
                    if device.endpoints.count > 1 {
                        DisclosureGroup("Other interfaces") {
                            ForEach(Array(device.endpoints.dropFirst()), id: \.id) { endpoint in
                                selectButton(endpoint, title: endpointLabel(endpoint))
                            }
                        }.font(.caption2)
                    }
                    if device.endpoints.contains(where: { $0.id == inventory.selectedID }) {
                        DeviceSupportActions(inventory: inventory, control: control)
                        Text(inventory.message).font(.caption2)
                        if let error = inventory.error ?? inventory.metadataError {
                            Text(error).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                .monitorCard(inset: 10)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detected-peripheral-\(device.id)")
            }
            if let warning = inventory.eventWarning {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            }
            if let snapshot = inventory.snapshot,
               snapshot.usb != .complete || snapshot.hid != .complete {
                Text("Some device sources are incomplete. Devices has the discovery details.")
                    .font(.caption2).foregroundStyle(.orange)
            } else if let error = inventory.error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detected-peripherals")
    }

    private func selectButton(_ endpoint: DeviceEndpoint, title: String) -> some View {
        Button { inventory.selectPeripheral(endpoint.id) } label: {
            HStack {
                Text(title)
                Spacer()
                if inventory.selectedID == endpoint.id { Image(systemName: "checkmark") }
            }
        }
        .buttonStyle(.borderless).font(.caption)
        .disabled(control.busy || inventory.managementBusy || inventory.handoffBusy)
        .accessibilityIdentifier("peripheral-select-\(endpoint.id)")
    }

    private func description(_ device: DetectedPeripheral) -> String {
        let transports = Set(device.endpoints.map { $0.identity.transport.rawValue.uppercased() }).sorted().joined(separator: ", ")
        let kind = device.kind == .other ? "Device" : device.kind.rawValue.capitalized
        return "\(kind) · \(transports) · \(device.endpoints.count) interface\(device.endpoints.count == 1 ? "" : "s")"
    }

    private func endpointLabel(_ endpoint: DeviceEndpoint) -> String {
        let number = endpoint.identity.interfaceNumber.map { " \($0)" } ?? ""
        return "\(endpoint.kind.rawValue.uppercased())\(number) · controls & agent support"
    }
}
