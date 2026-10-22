import SwiftUI
import MSIScreenCore

struct DeviceLayoutView: View {
    let definition: DeviceLayoutDefinition
    let value: DeviceLayoutValue
    let prefix: String
    let changed: (DeviceLayoutValue) -> Void
    let invalidated: () -> Void
    @State private var templateID = ""
    @State private var slots: [String: String] = [:]
    @State private var options: [String: String] = [:]
    private var template: DeviceLayoutTemplate? { definition.templates.first { $0.id == templateID } }
    private var complete: DeviceLayoutValue? {
        guard let result = try? DeviceLayoutValue(templateID: templateID, slots: slots, options: options),
              (try? DeviceCapabilityDefinition.layout(definition).validate(value: .layout(result))) != nil else { return nil }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Template", selection: $templateID) {
                ForEach(definition.templates, id: \.id) { Text($0.title).tag($0.id) }
            }.accessibilityIdentifier(prefix + "-template")
                .onChange(of: templateID) { _ in
                    slots = slots.filter { id, input in template?.slots.contains { $0.id == id && $0.allowedInputIDs.contains(input) } == true }
                    publish()
                }
            if let template {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(template.slots, id: \.id) { slot in
                            Text(slots[slot.id] ?? "Choose input")
                                .font(.caption2).frame(width: geometry.size.width * Double(slot.rectangle.width) / 10000,
                                                     height: 90 * Double(slot.rectangle.height) / 10000)
                                .background(.blue.opacity(0.2)).border(.secondary)
                                .offset(x: geometry.size.width * Double(slot.rectangle.x) / 10000, y: 90 * Double(slot.rectangle.y) / 10000)
                                .zIndex(Double(slot.rectangle.z))
                        }
                    }
                }.frame(height: 90).accessibilityLabel("Panel composition preview, not macOS display positions")
                ForEach(template.slots, id: \.id) { slot in
                    Picker(slot.id, selection: Binding(get: { slots[slot.id] ?? "" }, set: { slots[slot.id] = $0; publish() })) {
                        Text("Choose input").tag("")
                        ForEach(definition.inputs.filter { slot.allowedInputIDs.contains($0.id) }, id: \.id) { Text($0.title).tag($0.id) }
                    }.accessibilityIdentifier(prefix + "-slot-" + slot.id)
                }
                if template.distinctInputs { Text("Each slot requires a different input.").font(.caption2) }
            }
            ForEach(definition.options, id: \.id) { option in
                Picker(option.id, selection: Binding(get: { options[option.id] ?? "" }, set: { options[option.id] = $0; publish() })) {
                    Text("Choose option").tag("")
                    ForEach(option.choices, id: \.id) { Text($0.title).tag($0.id) }
                }.accessibilityIdentifier(prefix + "-option-" + option.id)
            }
            if complete == nil { Text("Choose a complete, valid layout before Apply.").font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { reset(value) }
        .onChange(of: value) { reset($0) }
    }
    private func publish() { if let complete { changed(complete) } else { invalidated() } }
    private func reset(_ value: DeviceLayoutValue) { templateID = value.templateID; slots = value.slots; options = value.options }
}
