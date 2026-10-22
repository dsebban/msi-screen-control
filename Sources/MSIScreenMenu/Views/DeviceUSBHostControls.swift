import SwiftUI
import MSIScreenCore

struct DeviceUSBHostControls: View {
    let definition: DeviceUSBRouteDefinition
    let value: DeviceUSBRouteValue
    let prefix: String
    let changed: (DeviceUSBRouteValue) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Configured routing policy", selection: Binding(get: { value.configuredDestinationID }, set: {
                if let target = try? DeviceUSBRouteValue(configuredDestinationID: $0, observedOwnerID: nil) { changed(target) }
            })) {
                ForEach(definition.destinations, id: \.id) { Text($0.title).tag($0.id) }
            }.accessibilityIdentifier(prefix + "-destination")
            Text("Observed USB owner: \(value.observedOwnerID ?? "unknown; not inferred from configured policy")").font(.caption)
            Text(definition.reachability == .remainsReachable
                 ? "Verification checks configured route readback, not receiving-host enumeration."
                 : "Unavailable: endpoint disappears and no authorized destination observation exists. No setter will run.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
