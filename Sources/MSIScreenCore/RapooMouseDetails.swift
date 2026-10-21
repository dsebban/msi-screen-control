import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.hid

public struct RapooWheelMapping: Codable, Equatable, Sendable {
    public let keyID: Int
    /// Native horizontal axis sign, independent of macOS scrolling direction.
    public let direction: String?
    public let function: String
    /// Only this key's four-byte record, excluding adjacent configuration.
    public let rawRecordHex: String
    public let logicalType: Int?
}

public enum RapooSideWheelPreset: String, Codable, CaseIterable, Sendable {
    case horizontal, appSwitch

    fileprivate func record(keyID: Int) -> [UInt8] {
        switch self {
        case .horizontal: return [7, 0, 8, 0]
        // These are ordinary F18/F19 keys. App cycling requires a host binding;
        // this persistent mapping does not itself activate applications.
        case .appSwitch: return [1, 0, keyID == 7 ? 0x6d : 0x6e, 0]
        }
    }
}

public struct RapooWheelChangeResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let preset: RapooSideWheelPreset
    public let dryRun: Bool
    public let before: [RapooWheelMapping]
    public let target: [RapooWheelMapping]
    /// Last complete readback. Nil after a write whose resulting state could
    /// not be read; never substitute the requested state for an observation.
    public let after: [RapooWheelMapping]?
    public let writeAttemptedKeys: [Int]
    /// Keys whose write was followed by a matching complete readback. A later
    /// failure can still make the final overall state unavailable.
    public let verifiedWriteKeys: [Int]
    public let verified: Bool
    public let error: String?
}

public struct RapooDPIDetails: Codable, Equatable, Sendable {
    /// Active slots only, in the device's order. Unused raw slots stay in rawPayloadHex.
    public let slots: [Int]
    public let activeSlot: Int
    public let currentDPI: Int
    public let rawPayloadHex: String
}

public struct RapooButtonMapping: Codable, Equatable, Sendable {
    public let keyID: Int
    public let function: String
    public let rawRecordHex: String
    public let logicalType: Int?
}

public enum RapooTopButtonPreset: String, Codable, CaseIterable, Sendable {
    case pinnedApp, dpiCycle
    fileprivate var record: [UInt8] {
        switch self {
        case .pinnedApp: return [1, 0, 0x6f, 0]
        case .dpiCycle: return [8, 0, 3, 0]
        }
    }
}

public struct RapooButtonChangeResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let preset: RapooTopButtonPreset
    public let dryRun: Bool
    public let before: RapooButtonMapping
    public let target: RapooButtonMapping
    public let after: RapooButtonMapping?
    public let writeAttempted: Bool
    public let verified: Bool
    public let error: String?
}

public struct RapooMouseDetails: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let hostName: String
    public let platform: MachinePlatform
    public let model: String
    public let receiver: String
    public let dongleFirmware: String?
    public let mouseFirmware: String?
    public let batteryPercent: Int?
    /// The vendor status byte is preserved without guessing charging semantics.
    public let batteryStatusRaw: Int?
    public let sideWheelMappings: [RapooWheelMapping]
    public let dpi: RapooDPIDetails?
    public let topButtonMapping: RapooButtonMapping?
    public let errors: [String]
}

/// On-demand, local-only operations. Synchronous IOKit calls have no per-call
/// timeout argument; the operation window prevents starting another request after
/// its budget expires, and does not promise a hard wall-clock deadline.
public struct RapooPeripheralClient {
    private static let queue = DispatchQueue(label: "MSIScreen.Rapoo-details", qos: .utility)
    public init() {}

    public func localDetails() async throws -> RapooMouseDetails {
        try Task.checkCancellation()
        let cancellation = RapooReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let result = try MacRapooReader.read(cancellation: cancellation)
                        try cancellation.check()
                        return result
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// Only these two wheel presets can be written. The saved records must
    /// still match immediately before changing any key.
    public func setSideWheelPreset(_ preset: RapooSideWheelPreset, expected: [RapooWheelMapping],
                                   dryRun: Bool = false) async throws -> RapooWheelChangeResult {
        try Task.checkCancellation()
        try RapooWheelMutation.validateExpected(expected)
        let cancellation = RapooReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try MacRapooReader.setSideWheelPreset(preset, expected: expected,
                            dryRun: dryRun, cancellation: cancellation)
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// The top button is key 4 (DPI) in the exact MT760 NL image/profile.
    /// F20 needs a host binding; restoring DPI cycle does not change its slots.
    public func setTopButtonPreset(_ preset: RapooTopButtonPreset, expectedRecordHex: String,
                                   dryRun: Bool = false) async throws -> RapooButtonChangeResult {
        try Task.checkCancellation()
        try RapooTopButtonMutation.validateExpected(expectedRecordHex)
        let cancellation = RapooReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try MacRapooReader.setTopButtonPreset(preset, expectedRecordHex: expectedRecordHex,
                            dryRun: dryRun, cancellation: cancellation)
                    })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

enum RapooReplyReader {
    // A HUB's UHid::readDevice performs up to 250 GET_INPUT reads, 2ms apart,
    // while status 2 means the reply is pending. It never resends the command.
    // The deadline includes receive time; synchronous IOKit itself is not interruptible.
    static func read(deadline: TimeInterval, checkCancellation: () throws -> Void,
                     receive: (inout [UInt8], inout Int) throws -> Void,
                     now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> [UInt8] {
        for attempt in 0..<250 {
            try checkCancellation()
            guard now() < deadline else { throw ScreenError.message("Rapoo receiver reply timed out") }
            // GetReport overwrites both the status/report-ID byte and length.
            var buffer = [UInt8](repeating: 0, count: 32)
            buffer[0] = 0xba
            var count = buffer.count
            try receive(&buffer, &count)
            try checkCancellation()
            guard now() < deadline else { throw ScreenError.message("Rapoo receiver reply timed out") }
            guard (0...buffer.count).contains(count) else { throw ScreenError.message("Rapoo returned an invalid byte count") }
            let response = Array(buffer.prefix(count))
            if response.first != 2 { return response }
            if attempt < 249 { sleep(min(0.002, max(0, deadline - now()))) }
        }
        throw ScreenError.message("Rapoo receiver reply timed out (status 2)")
    }
}

private final class RapooReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

enum RapooGetter: String, CaseIterable {
    case dongleFirmware, mouseFirmware, battery, sideWheelKey7, sideWheelKey8, dpi, topButtonKey4
    var packet: [UInt8] {
        switch self {
        case .dongleFirmware: return [0xba, 0xe2, 0xf1]
        case .mouseFirmware: return [0xba, 0xf7, 0xf1]
        case .battery: return [0xba, 0xf7, 0xf8]
        // MT760 NL reads 16 bytes at key table 0x600 + 4 * keyID.
        case .sideWheelKey7: return [0xba, 0xf7, 0xf6, 0x10, 0x1c, 0x06, 0x00, 0x00]
        case .sideWheelKey8: return [0xba, 0xf7, 0xf6, 0x10, 0x20, 0x06, 0x00, 0x00]
        case .dpi: return [0xba, 0xf7, 0xf6, 0x18, 0x38, 0x06, 0x00, 0x00]
        case .topButtonKey4: return [0xba, 0xf7, 0xf6, 0x10, 0x10, 0x06, 0x00, 0x00]
        }
    }

    var keyID: Int? {
        switch self {
        case .sideWheelKey7: return 7
        case .sideWheelKey8: return 8
        default: return nil
        }
    }
}

enum RapooReading: Equatable {
    case firmware(String)
    case battery(percent: Int, status: Int)
    case wheelMapping(RapooWheelMapping)
    case dpi(RapooDPIDetails)
    case buttonMapping(RapooButtonMapping)
}

enum RapooDetailProtocol {
    // A HUB 1.1.15, libRapooDevice.dylib SHA256
    // 23d65416b655469cb3250cccdba8bbb0f5896dcd0e49fafb7d7619731136ca4a.
    // MT760 NL selects MouseForNearLink21E, with inherited Telink mouse getters.
    // These getter shapes and 32-byte replies were validated on 24ae:186a.
    static func decode(_ response: [UInt8], for getter: RapooGetter) throws -> RapooReading {
        let minimum = getter == .dpi ? 28 :
            ((getter.keyID != nil || getter == .topButtonKey4) ? 20 : (getter == .battery ? 3 : 5))
        guard (minimum...32).contains(response.count), response[0] == 1 else {
            throw ScreenError.message("Rapoo \(getter.rawValue) returned an invalid length or status")
        }
        // Native hidapi does not strip a nonzero report ID. Here byte zero is
        // the vendor's success status, as confirmed by the live getters.
        if getter == .topButtonKey4 {
            return .buttonMapping(decodeTopButtonRecord(Array(response[4..<8])))
        }
        if getter == .dpi {
            // Exact 21E getDPIListInfo: seven LE16 slots in units of 50,
            // followed by zero-based count/current fields, not both adjacent.
            let count = Int(response[18]) + 1
            let current = Int(response[20]) + 1
            guard (1...7).contains(count), (1...count).contains(current) else {
                throw ScreenError.message("Rapoo returned invalid DPI slot indices")
            }
            let slots = (0..<count).map { index in
                (Int(response[4 + index * 2]) | Int(response[5 + index * 2]) << 8) * 50
            }
            guard slots.allSatisfy({ $0 > 0 }) else {
                throw ScreenError.message("Rapoo returned an empty active DPI slot")
            }
            return .dpi(RapooDPIDetails(slots: slots, activeSlot: current,
                currentDPI: slots[current - 1],
                rawPayloadHex: response[4..<28].map { String(format: "%02x", $0) }.joined()))
        }
        if let keyID = getter.keyID {
            return .wheelMapping(decodeWheelRecord(Array(response[4..<8]), keyID: keyID))
        }
        if getter == .battery {
            guard response[2] <= 100 else { throw ScreenError.message("Rapoo returned an invalid battery percentage") }
            return .battery(percent: Int(response[2]), status: Int(response[1]))
        }
        let bytes = getter == .dongleFirmware ? Array(response[1...4]) : Array(response[1...4].reversed())
        return .firmware("V" + bytes.map(String.init).joined(separator: "."))
    }

    static func decodeTopButtonRecord(_ record: [UInt8]) -> RapooButtonMapping {
        let function: String
        let logicalType: Int?
        if record == [1, 0, 0x6f, 0] {
            function = "pinnedApp"; logicalType = 1
        } else if record == [8, 0, 3, 0] {
            function = "dpiCycle"; logicalType = 50
        } else {
            function = "unknown"; logicalType = nil
        }
        return RapooButtonMapping(keyID: 4, function: function,
            rawRecordHex: record.map { String(format: "%02x", $0) }.joined(), logicalType: logicalType)
    }

    static func decodeWheelRecord(_ record: [UInt8], keyID: Int) -> RapooWheelMapping {
        var logicalType: Int?
        var function = "unknown"
        var direction: String?
        if record[1] == 1 {
            // The native decoder returns 53 here; its meaning is unproven.
            logicalType = 53
        } else if record[0] == 1, record[1] == 0, [0x6d, 0x6e].contains(record[2]), record[3] == 0 {
            logicalType = 1
            function = record[2] == 0x6d ? "appSwitchPrevious" : "appSwitchNext"
            direction = keyID == 7 ? "horizontalNegative" : "horizontalPositive"
        } else if record[0] == 7, record[1] == 0, record[2] == 8, record[3] == 0 {
            // Actual MT760 NL readbacks use 07 00 08 00. The native 21E
            // decoder derives opposite horizontal signs from keyID here.
            logicalType = 7
            function = "horizontalScroll"
            direction = keyID == 7 ? "horizontalNegative" : "horizontalPositive"
        } else if record[0] == 7, record[1] == 0, record[2] == 0, record[3] == 0 {
            logicalType = 0
            function = "disabled"
        } else if record[0] == 12, record[1] == 0, [1, 2].contains(record[2]), record[3] == 0 {
            logicalType = 7
            function = "horizontalScroll"
            direction = record[2] == 2 ? "horizontalPositive" : "horizontalNegative"
        } else if record[0] == 255 {
            logicalType = 7
            function = "defaultHorizontalScroll"
            // Native default-record signs differ from the explicit subcode8
            // form above. Preserve the decoder's sign without inferring why.
            direction = keyID == 7 ? "horizontalPositive" : "horizontalNegative"
        } else if record[0] == 11, record[1] == 0, [1, 2].contains(record[2]), record[3] == 0 {
            logicalType = 6
            function = "verticalScroll"
        }
        return RapooWheelMapping(keyID: keyID, direction: direction, function: function,
            rawRecordHex: record.map { String(format: "%02x", $0) }.joined(), logicalType: logicalType)
    }

    static func read(hostName: String, beforeGetter: () throws -> Void,
                     exchange: (RapooGetter) throws -> [UInt8]) throws -> RapooMouseDetails {
        var dongle: String?
        var mouse: String?
        var percent: Int?
        var status: Int?
        var mappings: [RapooWheelMapping] = []
        var dpi: RapooDPIDetails?
        var topButton: RapooButtonMapping?
        var errors: [String] = []
        for getter in RapooGetter.allCases {
            do {
                try beforeGetter()
                let value = try decode(exchange(getter), for: getter)
                switch (getter, value) {
                case (.dongleFirmware, .firmware(let version)): dongle = version
                case (.mouseFirmware, .firmware(let version)): mouse = version
                case (.battery, .battery(let charge, let rawStatus)): percent = charge; status = rawStatus
                case (.sideWheelKey7, .wheelMapping(let mapping)), (.sideWheelKey8, .wheelMapping(let mapping)):
                    mappings.append(mapping)
                case (.dpi, .dpi(let details)): dpi = details
                case (.topButtonKey4, .buttonMapping(let mapping)): topButton = mapping
                default: throw ScreenError.message("Unexpected Rapoo getter result")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Replies carry no getter echo. Stop after any failed getter;
                // a later request must not consume an ambiguous earlier reply.
                errors.append("\(getter.rawValue): \(error)")
                break
            }
        }
        return RapooMouseDetails(schemaVersion: 1, checkedAt: Date(), hostName: hostName, platform: .macos,
            model: "MT760 Pro / MT760 NL", receiver: "24ae:186a", dongleFirmware: dongle, mouseFirmware: mouse,
            batteryPercent: percent, batteryStatusRaw: status, sideWheelMappings: mappings,
            dpi: dpi, topButtonMapping: topButton, errors: errors)
    }
}

/// Fixed, model-specific mutation sequence with an injectable exchange for
/// regressions. The production endpoint validates topology before every request.
enum RapooWheelMutation {
    static let keys: [RapooGetter] = [.sideWheelKey7, .sideWheelKey8]

    static func validateExpected(_ expected: [RapooWheelMapping]) throws {
        guard expected.count == 2, Set(expected.map(\.keyID)) == Set([7, 8]),
              expected.allSatisfy({ $0.rawRecordHex.utf8.count == 8 &&
                  $0.rawRecordHex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw ScreenError.message("Expected both saved side-wheel records with four-byte lowercase hexadecimal values")
        }
    }

    static func apply(_ preset: RapooSideWheelPreset, expected: [RapooWheelMapping], dryRun: Bool,
                      beforeRequest: () throws -> Void,
                      exchange: ([UInt8]) throws -> [UInt8]) throws -> RapooWheelChangeResult {
        try validateExpected(expected)
        func get(_ getter: RapooGetter) throws -> RapooReading {
            try beforeRequest()
            return try RapooDetailProtocol.decode(exchange(getter.packet), for: getter)
        }
        func readMappings() throws -> [RapooWheelMapping] {
            try keys.map { getter in
                guard case .wheelMapping(let mapping) = try get(getter) else {
                    throw ScreenError.message("Unexpected Rapoo wheel readback")
                }
                return mapping
            }
        }
        func records(_ values: [RapooWheelMapping]) -> [String] {
            values.sorted { $0.keyID < $1.keyID }.map(\.rawRecordHex)
        }

        // This write path is limited to the firmware actually read from the
        // identified receiver; read-only details remain available on other versions.
        guard try get(.dongleFirmware) == .firmware("V1.3.6.0"),
              try get(.mouseFirmware) == .firmware("V1.0.0.41") else {
            throw ScreenError.message("Side-wheel writes require the validated Rapoo dongle V1.3.6.0 and mouse V1.0.0.41")
        }
        let before = try readMappings()
        guard records(before) == records(expected) else {
            throw ScreenError.message("Side-wheel mappings changed; refresh before applying a preset")
        }
        let target = keys.map { RapooDetailProtocol.decodeWheelRecord(preset.record(keyID: $0.keyID!), keyID: $0.keyID!) }
        var after: [RapooWheelMapping]? = before
        var attempted: [Int] = []
        var verifiedWrites: [Int] = []
        var owned = before
        func result(_ error: String? = nil) -> RapooWheelChangeResult {
            RapooWheelChangeResult(schemaVersion: 1, checkedAt: Date(), preset: preset,
                dryRun: dryRun, before: before, target: target, after: after,
                writeAttemptedKeys: attempted, verifiedWriteKeys: verifiedWrites,
                verified: !dryRun && error == nil && after == target, error: error)
        }
        if dryRun || records(before) == records(target) { return result() }

        for (index, getter) in keys.enumerated() where owned[index].rawRecordHex != target[index].rawRecordHex {
            do {
                try beforeRequest()
                let keyID = getter.keyID!
                // Same length/address representation as A HUB's exact 21E
                // setter. It writes one four-byte record with no separate commit.
                let packet: [UInt8] = [0xba, 0xf7, 0xf7, 4, keyID == 7 ? 0x1c : 0x20, 6, 0, 0]
                    + preset.record(keyID: keyID)
                attempted.append(keyID)
                after = nil
                let reply = try exchange(packet)
                guard (1...32).contains(reply.count), reply[0] == 1 else {
                    throw ScreenError.message("Rapoo wheel setter returned an invalid length or status")
                }
                let observed = try readMappings()
                after = observed
                owned[index] = target[index]
                guard records(observed) == records(owned) else {
                    throw ScreenError.message("Rapoo wheel readback did not match the requested record and unchanged other key")
                }
                verifiedWrites.append(keyID)
                // This complete readback is also the stale-state guard for
                // the next key. An external change stops the sequence.
            } catch {
                if attempted.isEmpty { throw error }
                return result(String(describing: error))
            }
        }
        return result()
    }
}

/// A separate fixed key-4 operation; it never changes DPI values or accepts
/// arbitrary configuration addresses/records. The native setter has no commit.
enum RapooTopButtonMutation {
    static func validateExpected(_ expected: String) throws {
        guard expected.utf8.count == 8,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ScreenError.message("Expected the saved top-button record as four-byte lowercase hexadecimal")
        }
    }

    static func apply(_ preset: RapooTopButtonPreset, expectedRecordHex: String, dryRun: Bool,
                      beforeRequest: () throws -> Void,
                      exchange: ([UInt8]) throws -> [UInt8]) throws -> RapooButtonChangeResult {
        try validateExpected(expectedRecordHex)
        func get(_ getter: RapooGetter) throws -> [UInt8] {
            try beforeRequest()
            let reply = try exchange(getter.packet)
            _ = try RapooDetailProtocol.decode(reply, for: getter)
            return reply
        }
        let dongle = try RapooDetailProtocol.decode(get(.dongleFirmware), for: .dongleFirmware)
        let mouse = try RapooDetailProtocol.decode(get(.mouseFirmware), for: .mouseFirmware)
        guard dongle == .firmware("V1.3.6.0"), mouse == .firmware("V1.0.0.41") else {
            throw ScreenError.message("Top-button writes require the validated Rapoo dongle V1.3.6.0 and mouse V1.0.0.41")
        }
        let beforeReply = try get(.topButtonKey4)
        let before = RapooDetailProtocol.decodeTopButtonRecord(Array(beforeReply[4..<8]))
        guard before.rawRecordHex == expectedRecordHex else {
            throw ScreenError.message("Top-button mapping changed; refresh before applying a preset")
        }
        let target = RapooDetailProtocol.decodeTopButtonRecord(preset.record)
        var after: RapooButtonMapping? = before
        var attempted = false
        func result(_ error: String? = nil) -> RapooButtonChangeResult {
            RapooButtonChangeResult(schemaVersion: 1, checkedAt: Date(), preset: preset, dryRun: dryRun,
                before: before, target: target, after: after, writeAttempted: attempted,
                verified: !dryRun && error == nil && after == target, error: error)
        }
        if dryRun || before == target { return result() }
        do {
            try beforeRequest()
            // 21E setKey's ordinary key path: F20 = 01 00 6f 00.
            // Its DPI cycle+ path is logical50/code3 = 08 00 03 00.
            let packet: [UInt8] = [0xba, 0xf7, 0xf7, 4, 0x10, 6, 0, 0] + preset.record
            attempted = true
            after = nil
            let reply = try exchange(packet)
            guard (1...32).contains(reply.count), reply[0] == 1 else {
                throw ScreenError.message("Rapoo top-button setter returned an invalid length or status")
            }
            let observed = try get(.topButtonKey4)
            after = RapooDetailProtocol.decodeTopButtonRecord(Array(observed[4..<8]))
            guard after == target, observed[8..<20] == beforeReply[8..<20] else {
                throw ScreenError.message("Rapoo top-button readback did not match the requested record and unchanged adjacent keys")
            }
            return result()
        } catch {
            if !attempted { throw error }
            return result(String(describing: error))
        }
    }
}

/// Compatibility lease for older Rapoo clients. Live sessions borrow the
/// coordinator's ordered set instead of independently flocking rapoo.lock.
final class RapooQueryLock {
    private var lease: DeviceResourceLock?
    init(directory: URL? = nil) throws {
        lease = try DeviceResourceLock(.init(domains: [], rapoo: true), directory: directory)
    }
    init(borrowing lease: DeviceResourceLock) throws {
        guard lease.descriptor(forLegacy: "rapoo.lock") != nil else { throw DeviceContractError.invalid("missingBorrowedLease") }
        self.lease = lease
    }
    func release() { lease = nil }
}

private enum MacRapooReader {
    // Exact descriptor from the validated receiver. The containing interface
    // also declares keyboard/consumer collections; no callbacks or event taps
    // are registered. Only vendor report BA is requested.
    private static let expectedDescriptor = Data([
        0x05,0x01,0x09,0x06,0xa1,0x01,0x85,0x01,0x05,0x07,0x19,0xe0,0x29,0xe7,0x15,0x00,
        0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,0x95,0x01,0x75,0x08,0x81,0x01,0x95,0x05,
        0x75,0x01,0x05,0x08,0x19,0x01,0x29,0x05,0x91,0x02,0x95,0x01,0x75,0x03,0x91,0x01,
        0x95,0x06,0x75,0x08,0x15,0x00,0x26,0xff,0x00,0x05,0x07,0x19,0x00,0x2a,0xff,0x00,
        0x81,0x00,0xc0,0x05,0x0c,0x09,0x01,0xa1,0x01,0x85,0x03,0x19,0x00,0x2a,0x3c,0x03,
        0x15,0x00,0x26,0x3c,0x03,0x95,0x01,0x75,0x10,0x81,0x00,0xc0,0x05,0x01,0x09,0x80,
        0xa1,0x01,0x85,0x02,0x05,0x01,0x19,0x81,0x29,0x83,0x15,0x00,0x25,0x01,0x95,0x03,
        0x75,0x01,0x81,0x02,0x95,0x01,0x75,0x05,0x81,0x01,0xc0,0x06,0xa0,0xff,0x09,0x02,
        0xa1,0x01,0x85,0xa1,0xa1,0x00,0x15,0x00,0x26,0xff,0x00,0x09,0x00,0x2a,0xff,0x00,
        0x75,0x08,0x95,0x3f,0x81,0x02,0xc0,0x85,0xa0,0xa1,0x00,0x15,0x00,0x26,0xff,0x00,
        0x09,0x00,0x2a,0xff,0x00,0x75,0x08,0x95,0x3f,0x91,0x02,0xc0,0xc0,0x06,0x00,0xff,
        0x09,0x0e,0xa1,0x01,0x85,0xba,0x75,0x08,0x95,0x1f,0x15,0x00,0x26,0xff,0x00,0x09,
        0x01,0x81,0x00,0x09,0x01,0x91,0x00,0xc0,0x06,0x00,0xff,0x09,0x02,0xa1,0x01,0x85,
        0x09,0x75,0x08,0x95,0x04,0x15,0x00,0x26,0xff,0x00,0x09,0x02,0x81,0x00,0x09,0x02,
        0x91,0x00,0xc0,0x06,0x00,0xff,0x09,0x02,0xa1,0x01,0x85,0xbb,0x75,0x08,0x95,0x07,
        0x15,0x00,0x26,0xff,0x00,0x09,0x02,0x81,0x00,0x09,0x02,0x91,0x00,0xc0
    ])

    private static func requireNoAHub() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.yourcompany.A-HUB").isEmpty else {
            throw ScreenError.message("Close A HUB before accessing Rapoo settings so the two apps do not mix USB replies")
        }
    }

    private static func target() throws -> (receiver: UInt64, hub: UInt64) {
        let topology = try MonitorUSBTopology(devices: MacUSBPeripheralReader.enumerateUSB())
        let receivers = topology.receivers(.rapoo)
        guard receivers.count == 1, let receiver = receivers.first,
              let hub = topology.monitorHubID, topology.isOnMonitorHub(receiver) else {
            throw ScreenError.message("Exactly one Rapoo 24ae:186a receiver must be connected through the MSI monitor hub")
        }
        return (receiver.id, hub)
    }

    private static func matchesDescriptor(_ service: io_registry_entry_t) -> Bool {
        (IORegistryEntryCreateCFProperty(service, "ReportDescriptor" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data) == expectedDescriptor
    }

    private static func selectDevice(usbID: UInt64) throws -> IOHIDDevice {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            throw ScreenError.message("Cannot enumerate the Rapoo receiver interface")
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [IOHIDDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard MacUSBPeripheralReader.number(service, "VendorID") == 0x24ae,
                  MacUSBPeripheralReader.number(service, "ProductID") == 0x186a,
                  MacUSBPeripheralReader.number(service, "PrimaryUsagePage") == 1,
                  MacUSBPeripheralReader.number(service, "PrimaryUsage") == 6,
                  MacUSBPeripheralReader.number(service, "MaxInputReportSize") == 64,
                  MacUSBPeripheralReader.number(service, "MaxOutputReportSize") == 64,
                  MacUSBPeripheralReader.usbAncestor(service, includingSelf: true) == usbID,
                  matchesDescriptor(service) else { continue }
            if let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) { candidates.append(candidate) }
        }
        guard candidates.count == 1 else { throw ScreenError.message("The validated Rapoo vendor interface is absent or ambiguous") }
        return candidates[0]
    }

    static func read(cancellation: RapooReadCancellation) throws -> RapooMouseDetails {
        try withSession(cancellation: cancellation) { beforeRequest, exchange in
            try RapooDetailProtocol.read(hostName: MacUSBPeripheralReader.hostName, beforeGetter: beforeRequest) {
                try exchange($0.packet)
            }
        }
    }

    static func setSideWheelPreset(_ preset: RapooSideWheelPreset, expected: [RapooWheelMapping],
                                   dryRun: Bool, cancellation: RapooReadCancellation) throws -> RapooWheelChangeResult {
        try withSession(cancellation: cancellation) { beforeRequest, exchange in
            try RapooWheelMutation.apply(preset, expected: expected, dryRun: dryRun,
                beforeRequest: beforeRequest, exchange: exchange)
        }
    }

    static func setTopButtonPreset(_ preset: RapooTopButtonPreset, expectedRecordHex: String,
                                   dryRun: Bool, cancellation: RapooReadCancellation) throws -> RapooButtonChangeResult {
        try withSession(cancellation: cancellation) { beforeRequest, exchange in
            try RapooTopButtonMutation.apply(preset, expectedRecordHex: expectedRecordHex, dryRun: dryRun,
                beforeRequest: beforeRequest, exchange: exchange)
        }
    }

    private static func withSession<T>(cancellation: RapooReadCancellation,
        body: (_ beforeRequest: () throws -> Void, _ exchange: ([UInt8]) throws -> [UInt8]) throws -> T) throws -> T {
        try cancellation.check()
        try requireNoAHub()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let expected = try target()
        let graph = try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB())
        let request = try DeviceResourceLock.request(usbID: expected.receiver, graph: graph)
        let lease = try DeviceResourceLock(request)
        let lock = try RapooQueryLock(borrowing: lease)
        defer { lock.release(); withExtendedLifetime(lease) {} }
        let currentGraph = try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB())
        guard try target() == expected,
              try DeviceResourceLock.request(usbID: expected.receiver, graph: currentGraph) == request else {
            throw DeviceContractError.invalid("staleEndpoint")
        }
        let device = try selectDevice(usbID: expected.receiver)
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened == kIOReturnNotPermitted {
            throw ScreenError.message("Allow Input Monitoring for MSI Screen in System Settings, then restart the app. After replacing an ad hoc signed build, remove its old permission entry and add the installed app again if access is still denied.")
        }
        guard opened == kIOReturnSuccess else { throw ScreenError.message("Cannot open Rapoo receiver: \(opened)") }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        func beforeRequest() throws {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ScreenError.message("Rapoo operation window ended") }
            try requireNoAHub()
            let current = try target()
            let service = IOHIDDeviceGetService(device)
            guard current == expected, MacUSBPeripheralReader.usbAncestor(service, includingSelf: true) == expected.receiver,
                  matchesDescriptor(service) else { throw ScreenError.message("Rapoo receiver topology changed; refresh peripherals") }
        }
        return try body(beforeRequest) { packet in
            // These are the native driver's 50ms delays around a request.
            Thread.sleep(forTimeInterval: 0.05)
            try beforeRequest()
            let sent = packet.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0xba, $0.baseAddress!, packet.count)
            }
            guard sent == kIOReturnSuccess else { throw ScreenError.message("Rapoo request failed: \(sent)") }
            Thread.sleep(forTimeInterval: 0.05)
            let response = try RapooReplyReader.read(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 1),
                checkCancellation: cancellation.check) { buffer, count in
                let received = buffer.withUnsafeMutableBufferPointer {
                    IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, 0xba, $0.baseAddress!, &count)
                }
                guard received == kIOReturnSuccess else { throw ScreenError.message("Rapoo input report failed: \(received)") }
            }
            try requireNoAHub()
            return response
        }
    }
}
