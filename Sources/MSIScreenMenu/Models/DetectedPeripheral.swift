import Foundation
import MSIScreenCore

/// A presentation of current passive facts, not a control owner or a pairing
/// claim. The complete inventory remains available in Devices.
struct DetectedPeripheral: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: DeviceKind
    let endpoints: [DeviceEndpoint]

    var symbol: String {
        switch kind {
        case .keyboard: return "keyboard"
        case .pointer: return "computermouse"
        case .gameController: return "gamecontroller"
        case .hub: return "point.3.connected.trianglepath.dotted"
        case .receiver: return "antenna.radiowaves.left.and.right"
        case .display: return "display"
        case .other: return "cable.connector"
        }
    }

    static func from(_ snapshot: DeviceInventorySnapshot) -> [DetectedPeripheral] {
        let entries = snapshot.devices.filter { $0.kind != .display }.flatMap { record in
            record.endpoints.filter { $0.kind != .display }.map { (record: record, endpoint: $0) }
        }
        // Domain IDs already carry the reader's proven physical association.
        // Shared labels, serials or VID/PID never create a presentation group.
        let groups = Dictionary(grouping: entries, by: { $0.endpoint.physicalDomainID })
        return groups.compactMap { domain, entries in
            // One interface can carry the OS built-in fact for a shared device.
            guard !entries.contains(where: { $0.endpoint.identity.isBuiltIn == true }),
                  entries.contains(where: { isPeripheral($0.endpoint) }) else { return nil }
            let ranked = entries.sorted {
                let left = (priority($0.record.kind), $0.endpoint.kind == .usb ? 0 : 1, $0.record.id, $0.endpoint.id)
                let right = (priority($1.record.kind), $1.endpoint.kind == .usb ? 0 : 1, $1.record.id, $1.endpoint.id)
                return left < right
            }
            guard let representative = ranked.first else { return nil }
            return DetectedPeripheral(id: domain, name: representative.record.displayName, kind: representative.record.kind,
                endpoints: entries.map(\.endpoint).sorted { $0.id < $1.id })
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private static func isPeripheral(_ endpoint: DeviceEndpoint) -> Bool {
        if endpoint.identity.transport == .usb || endpoint.identity.transport == .bluetooth { return true }
        // Other transports also expose internal sensors and software endpoints.
        // Retain standard pointer/joystick/gamepad/keyboard/keypad usages here;
        // vendor-defined and unclassified endpoints remain in Devices.
        return endpoint.identity.usages.contains { $0.page == 1 && [2, 4, 5, 6, 7].contains($0.usage) }
    }

    private static func priority(_ kind: DeviceKind) -> Int {
        switch kind {
        case .receiver: return 0
        case .gameController: return 1
        case .keyboard: return 2
        case .pointer: return 3
        case .hub: return 4
        case .other: return 5
        case .display: return 6
        }
    }
}
