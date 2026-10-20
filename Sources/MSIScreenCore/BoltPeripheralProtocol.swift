import Foundation

// Read-only Bolt receiver metadata and HID++ root GetProtocolVersion.
// Metadata: github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/receiver.py#L496-L510
// Ping: github.com/Logitech/cpg-docs/blob/master/hidpp20/features/0x0000-IRoot.rst
// Pairing, notification configuration and key-event reports are never requested.
enum BoltReadRequest {
    case pairing(Int), name(Int), ping(Int, softwareID: UInt8, mark: UInt8)
    case feature(slot: Int, index: UInt8, function: UInt8, softwareID: UInt8, parameters: [UInt8], responseLength: Int)

    var packet: [UInt8] {
        switch self {
        case .pairing(let slot): return [0x10, 0xff, 0x83, 0xb5, UInt8(0x50 + slot), 0, 0]
        case .name(let slot): return [0x10, 0xff, 0x83, 0xb5, UInt8(0x60 + slot), 1, 0]
        case .ping(let slot, let softwareID, let mark): return [0x10, UInt8(slot), 0, 0x10 | softwareID, 0, 0, mark]
        case .feature(let slot, let index, let function, let softwareID, let parameters, _):
            return [0x10, UInt8(slot), index, (function << 4) | softwareID] + parameters
                + Array(repeating: 0, count: 3 - parameters.count)
        }
    }
}

enum BoltReadReply: Equatable {
    case pairing(PairedPeripheralKind, productID: String)
    case name(String, truncated: Bool)
    case pong(String)
    case receiverError(Int)
    case pingError(Int)
    case feature([UInt8])
    case featureError(Int)
}

enum BoltPeripheralProtocol {
    static func decode<C: RandomAccessCollection>(_ report: C, for request: BoltReadRequest) throws -> BoltReadReply?
    where C.Element == UInt8, C.Index == Int {
        guard (report.count == 7 && report[0] == 0x10)
            || (report.count == 20 && report[0] == 0x11) else { return nil }
        switch request {
        case .pairing(let slot), .name(let slot):
            guard report[1] == 0xff else { return nil }
            if report[0] == 0x10, report[2] == 0x8f, report[3] == 0x83, report[4] == 0xb5 {
                return .receiverError(Int(report[5]))
            }
            let selector = request.packet[4]
            guard (1...6).contains(slot), report.count == 20, report[0] == 0x11,
                  report[2] == 0x83, report[3] == 0xb5, report[4] == selector else { return nil }
            if case .pairing = request {
                let rawKind = report[5] & 0x0f
                let kind: PairedPeripheralKind = rawKind == 1 ? .keyboard : rawKind == 2 ? .mouse : .other
                let product = UInt16(report[6]) | UInt16(report[7]) << 8
                return .pairing(kind, productID: String(format: "%04X", product))
            }
            guard report[5] == 1 else { return nil }
            let length = Int(report[6])
            let bytes = (0..<min(length, 13)).map { report[7 + $0] }
            guard bytes.allSatisfy({ (32...126).contains($0) }) else {
                throw ScreenError.message("Bolt returned an invalid paired-device name")
            }
            return .name(String(decoding: bytes, as: UTF8.self), truncated: length > 13)
        case .ping(let slot, let softwareID, let mark):
            guard report[1] == UInt8(slot) else { return nil }
            let function = 0x10 | softwareID
            if report[2] == 0, report[3] == function, report[6] == mark {
                guard report[4] > 0 else { throw ScreenError.message("Bolt returned an invalid protocol version") }
                return .pong("\(report[4]).\(report[5])")
            }
            if (report[0] == 0x10 && report[2] == 0x8f) || report[2] == 0xff,
               report[3] == 0, report[4] == function {
                return .pingError(Int(report[5]))
            }
            return nil
        case .feature(let slot, let index, let function, let softwareID, _, let length):
            let operation = (function << 4) | softwareID
            guard report[1] == UInt8(slot) else { return nil }
            if report[2] == 0xff || (report[0] == 0x10 && report[2] == 0x8f),
               report[3] == index, report[4] == operation {
                return .featureError(Int(report[5]))
            }
            guard report[2] == index, report[3] == operation, report.count >= length + 4 else { return nil }
            // The fixed getter selects the payload prefix it needs. Firmware
            // device-info reads retain only entity count, excluding unit IDs.
            return .feature((0..<length).map { report[4 + $0] })
        }
    }

    static func readDevices(request: (BoltReadRequest) throws -> BoltReadReply?) -> (devices: [PairedUSBPeripheral], error: String?) {
        var devices: [PairedUSBPeripheral] = []
        for slot in 1...6 {
            do {
                guard let metadata = try request(.pairing(slot)) else {
                    return (devices, "Bolt pairing metadata did not respond; remaining slots are unavailable")
                }
                if case .receiverError = metadata { continue }
                guard case .pairing(let kind, let product) = metadata else { continue }
                devices.append(PairedUSBPeripheral(slot: slot, name: nil, kind: kind, wirelessProductID: product,
                    radio: .unavailable, protocolVersion: nil, error: "Radio response has not been checked"))
                var name: String?
                var note: String?
                if let response = try request(.name(slot)) {
                    if case .name(let value, let truncated) = response {
                        name = value
                        if truncated { note = "Receiver returned a shortened device name" }
                    } else { note = "Paired-device name is unavailable" }
                } else {
                    devices[devices.count - 1] = PairedUSBPeripheral(slot: slot, name: nil, kind: kind, wirelessProductID: product,
                        radio: .unavailable, protocolVersion: nil, error: "Paired-device name did not respond")
                    return (devices, "Bolt metadata read timed out; remaining slots are unavailable")
                }
                devices[devices.count - 1] = PairedUSBPeripheral(slot: slot, name: name, kind: kind, wirelessProductID: product,
                    radio: .unavailable, protocolVersion: nil, error: "Radio response has not been checked")
                let response = try request(.ping(slot, softwareID: 0x0b, mark: UInt8.random(in: 0...255)))
                let radio: PeripheralRadioState
                var version: String?
                switch response {
                case .pong(let value): radio = .responding; version = value
                case .pingError(let code) where code == 4 || code == 9:
                    radio = .notResponding; note = "Device is not responding; it may be asleep"
                case .pingError(let code): radio = .unavailable; note = "Bolt ping returned error \(code)"
                case nil: radio = .notResponding; note = "Device did not respond within the check window; it may be asleep"
                default: radio = .unavailable; note = "Bolt returned an unexpected ping response"
                }
                devices[devices.count - 1] = PairedUSBPeripheral(slot: slot, name: name, kind: kind, wirelessProductID: product,
                                                    radio: radio, protocolVersion: version, error: note)
            } catch { return (devices, String(describing: error)) }
        }
        return (devices, devices.isEmpty
            ? "No paired-device metadata was returned; receiver slots may be empty or unavailable" : nil)
    }
}
