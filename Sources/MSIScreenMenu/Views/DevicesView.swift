import SwiftUI
import MSIScreenCore

struct DevicesView: View {
    @ObservedObject var inventory: DeviceInventoryStore
    @ObservedObject var control: DeviceControlStore
    private func group(_ endpoint: DeviceEndpoint) -> String {
        if inventory.listing?.registry.bindings.contains(where: { $0.selector.physicalDomainID == endpoint.physicalDomainID }) == true { return "Local experimental support" }
        if BuiltInControlDomainCatalog.isMSI(endpoint.identity) || BuiltInControlDomainCatalog.isReservedReceiver(endpoint.identity) { return "Built-in candidates / verified owners" }
        return "Unconfigured"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Devices").font(.headline)
                Spacer()
                Button("Refresh") { inventory.refresh() }.disabled(inventory.busy)
                    .accessibilityIdentifier("devices-refresh")
            }
            if let label = inventory.fixtureLabel { Text(label).font(.headline).foregroundStyle(.orange) }
            else {
                Button("Use existing MSI controls") { inventory.selectBuiltInMonitor() }
                    .accessibilityIdentifier("device-select-built-in")
                Text("Separate legacy controller path; a passive MSI candidate is not a verified MD342CQP association.").font(.caption2).foregroundStyle(.secondary)
            }
            Text("Passive OS facts are independent of control support. A receiver is not its paired device; video association is unknown unless verified by a provider.")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = inventory.eventWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let snapshot = inventory.snapshot {
                Text("Checked \(Date(timeIntervalSince1970: Double(snapshot.checkedAtMilliseconds) / 1000), style: .time) · generation \(snapshot.generation)").font(.caption)
                source("Displays", snapshot.displays); source("USB", snapshot.usb); source("HID", snapshot.hid)
                ForEach(["Built-in candidates / verified owners", "Local experimental support", "Unconfigured"], id: \.self) { title in
                    let records = snapshot.devices.filter { $0.endpoints.contains { group($0) == title } }
                    if !records.isEmpty {
                        Text(title).font(.subheadline.weight(.semibold))
                        ForEach(records) { record in
                            ForEach(record.endpoints.filter { group($0) == title }, id: \.id) { endpoint in
                                Button { inventory.select(endpoint.id) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.displayName).font(.caption.weight(.semibold))
                                        Text("\(record.kind.rawValue) · \(endpoint.kind.rawValue) · \(record.bindingEligibility.rawValue)")
                                        Text("\(endpoint.identity.transport.rawValue) · endpoint \(endpoint.id.prefix(12))")
                                        if let asleep = endpoint.identity.isAsleep, asleep { Text("Asleep (OS observation), not unsupported") }
                                        ForEach(record.relations, id: \.targetID) { relation in Text("\(relation.kind.rawValue): \(relation.targetID.prefix(12)) · \(relation.evidence.rawValue)") }
                                        if let reason = record.bindingReason { Text(reason.code) }
                                    }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                                        .monitorCard(tint: inventory.selectedID == endpoint.id ? .blue : nil)
                                }.buttonStyle(.plain).accessibilityIdentifier("device-row-\(endpoint.id)")
                                    .accessibilityValue(inventory.selectedID == endpoint.id ? "Selected" : "Not selected")
                            }
                        }
                    }
                }
                if snapshot.devices.isEmpty { Text("No OS-visible devices in the completed sources.").font(.caption) }
            }
            if inventory.selectedID != nil && inventory.selectedEndpoint == nil {
                Text("Selected attachment disconnected or discovery failed. Select an endpoint explicitly; no replacement was selected.").font(.caption).foregroundStyle(.orange)
            }
            DeviceSupportActions(inventory: inventory, control: control)
            if !control.receipts.isEmpty {
                DisclosureGroup("Completed operation receipts") {
                    ForEach(control.receipts.values.sorted { $0.operationID.uuidString < $1.operationID.uuidString }, id: \.operationID) { receipt in
                        Text("\(receipt.operationID.uuidString.lowercased()) · endpoint \(receipt.identity.deviceID.prefix(12)) · \(receipt.outcome.rawValue)")
                            .font(.caption2).textSelection(.enabled)
                    }
                }.accessibilityIdentifier("device-operation-history")
            }
            Text(inventory.message).font(.caption).accessibilityIdentifier("device-handoff-status")
            if let error = inventory.error ?? inventory.metadataError {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("device-support-error")
            }
        }.accessibilityIdentifier("devices-inventory")
    }
    @ViewBuilder private func source(_ name: String, _ outcome: InventorySourceOutcome) -> some View {
        switch outcome {
        case .complete: Text("\(name): complete").font(.caption2).foregroundStyle(.secondary)
        case .failed(let code, _): Text("\(name): incomplete · \(code.rawValue)").font(.caption).foregroundStyle(.orange)
        }
    }
}
