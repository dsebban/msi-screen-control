import SwiftUI
import MSIScreenCore

struct DeviceCapabilityView: View {
    @ObservedObject var control: DeviceControlStore
    let capability: DeviceCapability
    let deviceID: String
    private var value: DeviceValue? { control.draft[capability.id] }
    private var prefix: String { "device-capability-\(deviceID)-\(capability.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(capability.title).font(.subheadline.weight(.semibold))
            Text("Declared \(capability.category.rawValue) · \(capability.access.rawValue) · evidence: \(capability.evidenceIDs.joined(separator: ", "))")
                .font(.caption2).foregroundStyle(.secondary)
            if let reason = capability.unavailableReason?.code ?? control.observation?.unavailable[capability.id]?.code {
                Text(reason).font(.caption).foregroundStyle(.orange)
            } else if let value {
                editor(value).disabled(control.busy || capability.access == .readOnly)
                if capability.access == .readWrite {
                    Button(applyTitle) { control.apply(capability.id) }
                        .disabled(!control.canApply(capability.id))
                        .accessibilityIdentifier("device-apply-\(deviceID)-\(capability.id)")
                }
            } else {
                Text("No observed value. Use explicit Read; no default value is assumed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(prefix)
        .monitorCard()
    }
    private var applyTitle: String {
        switch capability.definition {
        case .layout: return "Apply layout"
        case .usbRoute: return "Apply USB routing policy"
        case .inputMapping: return "Apply complete mapping"
        default: return "Apply \(capability.title)"
        }
    }
    @ViewBuilder private func editor(_ value: DeviceValue) -> some View {
        switch (capability.definition, value) {
        case (.integer(let definition), .integer(let current)):
            // Text avoids loss of Int64 precision in a Double-backed slider.
            TextField(capability.title, text: Binding(get: { String(current) }, set: {
                control.editInteger(capability.id, text: $0)
            }))
            .textFieldStyle(.roundedBorder).accessibilityIdentifier(prefix + "-value")
            Text("\(definition.minimum)…\(definition.maximum), step \(definition.step) \(definition.unit ?? "")").font(.caption2)
        case (.boolean, .boolean(let current)):
            Toggle(capability.title, isOn: Binding(get: { current }, set: { control.edit(capability.id, value: .boolean($0)) }))
                .accessibilityIdentifier(prefix + "-value")
        case (.choice(let choices), .choice(let current)):
            Picker(capability.title, selection: Binding(get: { current }, set: { control.edit(capability.id, value: .choice($0)) })) {
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
            }.accessibilityIdentifier(prefix + "-value")
        case (.text, .text(let text)):
            Text(text).textSelection(.enabled)
        case (.layout(let definition), .layout(let layout)):
            DeviceLayoutView(definition: definition, value: layout, prefix: prefix,
                changed: { control.edit(capability.id, value: .layout($0)) }, invalidated: { control.invalidateDraft(capability.id) })
                .id(control.baselineRevision)
        case (.usbRoute(let definition), .usbRoute(let route)):
            DeviceUSBHostControls(definition: definition, value: route, prefix: prefix) { control.edit(capability.id, value: .usbRoute($0)) }
        case (.inputMapping(let definition), .inputMapping(let mapping)):
            ForEach(definition.controls, id: \.id) { item in
                Picker(item.title, selection: Binding(get: { mapping[item.id] ?? "" }, set: { action in
                    var complete = mapping; complete[item.id] = action
                    control.edit(capability.id, value: .inputMapping(complete))
                })) {
                    ForEach(definition.actions, id: \.id) { Text($0.title).tag($0.id) }
                }.accessibilityIdentifier(prefix + "-" + item.id)
            }
        default: Text("Definition/value mismatch. Refresh support metadata.").foregroundStyle(.orange)
        }
    }
}

struct DeviceControlSummary: View {
    @ObservedObject var inventory: DeviceInventoryStore
    @ObservedObject var control: DeviceControlStore
    var category: DeviceCapabilityCategory? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(inventory.selectedTitle).font(.headline)
            Text(inventory.providerTitle).font(.caption).foregroundStyle(.secondary)
            if let label = inventory.fixtureLabel { Text(label).font(.headline).foregroundStyle(.orange) }
            if let endpoint = inventory.selectedEndpoint {
                Button("Read selected device") { control.read() }
                    .disabled(control.busy || control.selection == nil)
                    .accessibilityIdentifier("device-read-\(endpoint.id)")
                if let reason = inventory.selectedControlReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                } else if inventory.selectedDescriptor == nil {
                    Text("No declared configuration controls. Write ad-hoc support or bind a retained package in Devices.").font(.caption)
                }
                if inventory.listing?.executionReady == false && inventory.selectedBinding != nil && inventory.fixtureLabel == nil {
                    Text("Production experimental Read/plan/Apply refused: native Intel/macOS13 lifecycle and responsible launch-client attribution are not qualified.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach((control.descriptor?.capabilities ?? []).filter { category == nil || $0.category == category }
                    .sorted { ($0.presentationOrder, $0.id) < ($1.presentationOrder, $1.id) }, id: \.id) { cap in
                    DeviceCapabilityView(control: control, capability: cap, deviceID: endpoint.id)
                }
                if category == nil, control.descriptor?.supportsLayoutAndUSB == true {
                    Menu("Apply layout and USB policy") {
                        ForEach((control.descriptor?.capabilities ?? []).filter { if case .layout = $0.definition { return true }; return false }, id: \.id) { layout in
                            ForEach((control.descriptor?.capabilities ?? []).filter { if case .usbRoute = $0.definition { return true }; return false }, id: \.id) { route in
                                Button("\(layout.title) [\(layout.id)] + \(route.title) [\(route.id)]") {
                                    control.applyLayoutAndUSB(layoutID: layout.id, routeID: route.id)
                                }
                                .disabled(!control.canApplyLayoutAndUSB(layoutID: layout.id, routeID: route.id))
                                .accessibilityIdentifier("device-compose-\(endpoint.id)-\(layout.id):\(route.id)")
                            }
                        }
                    }
                    .disabled(control.busy || control.needsRefresh || !control.hasDraft || !control.invalidDrafts.isEmpty)
                    .accessibilityIdentifier("device-compose-\(endpoint.id)")
                }
            } else { Text("Select an exact endpoint in Devices. Disconnected selections are never replaced automatically.").font(.caption) }
            Text(control.message).font(.caption).accessibilityIdentifier("device-control-status")
            if let error = control.error { Text(error).foregroundStyle(.red).font(.caption).accessibilityIdentifier("device-control-error") }
            if let receipt = control.receipt {
                Text("Receipt \(receipt.operationID.uuidString.lowercased()) · \(receipt.outcome.rawValue) · possible write: \(receipt.writeMayHaveOccurred ? "yes" : "no")")
                    .font(.caption).textSelection(.enabled).accessibilityIdentifier("device-receipt")
                ForEach(receipt.stages, id: \.id) { stage in
                    Text("\(stage.id): attempted \(stage.attempted ? "yes" : "no"), completed \(stage.completed ? "yes" : "no"), verified \(stage.verified ? "yes" : "no")").font(.caption2)
                }
            }
        }
    }
}
