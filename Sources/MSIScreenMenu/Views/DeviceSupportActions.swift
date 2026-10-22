import SwiftUI
import MSIScreenCore

/// One support workflow for diagnostics, Peripherals and Machines.
struct DeviceSupportActions: View {
    @ObservedObject var inventory: DeviceInventoryStore
    @ObservedObject var control: DeviceControlStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let endpoint = inventory.selectedEndpoint {
                Button("Write ad-hoc support") { inventory.copySupportRequest() }
                    .disabled(inventory.handoffBusy || inventory.managementBusy || control.busy)
                    .accessibilityIdentifier("device-write-support-\(endpoint.id)")
                Text(inventory.copyDetail).font(.caption).accessibilityIdentifier("device-copy-detail-\(endpoint.id)")
                Text("Paste into your running agent; no agent is launched.").font(.caption2).foregroundStyle(.secondary)
                if let error = inventory.skillActionError { Text(error).font(.caption).foregroundStyle(.orange) }
                if inventory.selectedBinding == nil, let packages = inventory.listing?.packages {
                    Menu("Bind existing support") {
                        ForEach(packages.filter { $0.status == "validatedRetained" }, id: \.digest) { package in
                            Button("\(package.packageID) · \(package.digest.prefix(12))") { inventory.bind(packageID: package.packageID, digest: package.digest) }
                        }
                    }.disabled(control.busy || inventory.managementBusy).accessibilityIdentifier("device-bind-existing-\(endpoint.id)")
                }
                if let binding = inventory.selectedBinding, let reason = inventory.descriptorErrors[binding.digest] {
                    Text("Package inactive: \(reason)").font(.caption).foregroundStyle(.orange)
                }
                DeviceControlSummary(inventory: inventory, control: control)
            }
        }
    }
}
