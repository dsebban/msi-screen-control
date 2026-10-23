import Foundation
import IOKit

/// The Mac-side connector reported by IOKit, not the monitor's numbered input.
/// A DisplayPort signal inside the Mac's HDMI converter remains an HDMI port.
public enum VideoTransport: String, Codable, Equatable, Sendable {
    case hdmi, displayPort, usbc, unknown
}

public enum MacVideoConnectionEvidenceSource: String, Codable, Equatable, Sendable {
    case ioKitPortTransportStateDisplayPort
}

public struct MacVideoConnection: Codable, Equatable, Sendable {
    public let transport: VideoTransport
    /// An OS-reported host-port identifier. Its number is not a monitor input.
    public let hostPort: String?
    public let display: DisplayIdentification
    public let evidenceSource: MacVideoConnectionEvidenceSource

    public init(transport: VideoTransport, hostPort: String?, display: DisplayIdentification,
                evidenceSource: MacVideoConnectionEvidenceSource = .ioKitPortTransportStateDisplayPort) throws {
        guard hostPort.map({ !$0.isEmpty && $0.utf8.count <= 96
            && $0.utf8.allSatisfy { (0x20...0x7e).contains($0) } }) != false else {
            throw MacVideoConnectionReadError.invalidRegistryData
        }
        self.transport = transport; self.hostPort = hostPort; self.display = display
        self.evidenceSource = evidenceSource
    }

    private enum CodingKeys: String, CodingKey { case transport, hostPort, display, evidenceSource }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(transport: values.decode(VideoTransport.self, forKey: .transport),
                      hostPort: values.decodeIfPresent(String.self, forKey: .hostPort),
                      display: values.decode(DisplayIdentification.self, forKey: .display),
                      evidenceSource: values.decode(MacVideoConnectionEvidenceSource.self, forKey: .evidenceSource))
    }
}

public struct MacVideoConnectionSnapshot: Codable, Equatable, Sendable {
    public let checkedAtMilliseconds: Int64
    public let connections: [MacVideoConnection]
    public let outcome: InventorySourceOutcome
    /// OS port observations include inactive ports without treating their old
    /// EDID as an attached display. Property names and availability vary by OS.
    public let portStates: [MacVideoPortState]

    public init(connections: [MacVideoConnection], outcome: InventorySourceOutcome,
                checkedAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
                portStates: [MacVideoPortState] = []) {
        self.checkedAtMilliseconds = checkedAtMilliseconds
        self.connections = connections
        self.outcome = outcome
        self.portStates = portStates
    }
}

enum MacVideoConnectionReadError: String, Error {
    case invalidRegistryData, responseTooLarge
}

/// Passive registry reads only: no user clients, HID opens, DDC/I2C requests,
/// private framework calls, or changes to the display configuration.
public struct MacVideoConnectionReader {
    private static let serviceClass = "IOPortTransportStateDisplayPort"
    public init() {}

    public func snapshot() -> MacVideoConnectionSnapshot {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(Self.serviceClass), &iterator) == KERN_SUCCESS else {
            return Self.failed(.unavailable)
        }
        guard iterator != 0 else { return MacVideoConnectionSnapshot(connections: [], outcome: .complete) }
        defer { IOObjectRelease(iterator) }
        var records: [[String: Any]] = []
        var incomplete = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = properties?.takeRetainedValue() as? [String: Any] else {
                incomplete = true; continue
            }
            records.append(properties)
        }
        let parsed = Self.parseRecords(records)
        if IOIteratorIsValid(iterator) == 0 {
            return MacVideoConnectionSnapshot(connections: parsed.connections,
                outcome: .failed(code: .changedDuringEnumeration, message: "Display-link registry changed during enumeration"),
                portStates: parsed.portStates)
        }
        if incomplete {
            return MacVideoConnectionSnapshot(connections: parsed.connections,
                outcome: .failed(code: .identityUnavailable, message: "Some display-link identities are unavailable"),
                portStates: parsed.portStates)
        }
        return parsed
    }

    /// Parses the bounded plist returned by the fixed read-only command
    /// `ioreg -a -r -c IOPortTransportStateDisplayPort`. This shares the same
    /// candidate semantics with remote clients without launching a subprocess.
    static func parseRegistryData(_ data: Data) throws -> MacVideoConnectionSnapshot {
        guard data.count <= 1_048_576 else { throw MacVideoConnectionReadError.responseTooLarge }
        guard let records = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              records.count <= 1_024,
              records.allSatisfy({ ($0["IOObjectClass"] as? String) == serviceClass }) else {
            throw MacVideoConnectionReadError.invalidRegistryData
        }
        return parseRecords(records)
    }

    static func parseRecords(_ records: [[String: Any]]) -> MacVideoConnectionSnapshot {
        var connections: [MacVideoConnection] = []
        var ports: [MacVideoPortState] = []
        var incomplete = false
        for record in records {
            if let port = portState(record) { ports.append(port) }
            do {
                if let connection = try connection(record) { connections.append(connection) }
            } catch { incomplete = true }
        }
        connections.sort {
            if $0.hostPort != $1.hostPort { return ($0.hostPort ?? "") < ($1.hostPort ?? "") }
            if $0.display.vendorID != $1.display.vendorID { return $0.display.vendorID < $1.display.vendorID }
            if $0.display.productID != $1.display.productID { return $0.display.productID < $1.display.productID }
            return $0.transport.rawValue < $1.transport.rawValue
        }
        return MacVideoConnectionSnapshot(connections: connections, outcome: incomplete
            ? .failed(code: .identityUnavailable, message: "Some display-link identities are unavailable") : .complete,
            portStates: ports.sorted { $0.hostPort < $1.hostPort })
    }

    private static func connection(_ record: [String: Any]) throws -> MacVideoConnection? {
        guard let active = record["Active"] as? NSNumber else { throw MacVideoConnectionReadError.invalidRegistryData }
        // Unplugged services can retain their former EDID and product name.
        guard active.boolValue else { return nil }
        let metadata = record["Metadata"] as? [String: Any] ?? [:]
        let directEDID = record["EDID"] as? Data
        let metadataEDID = metadata["EDID"] as? Data
        if let directEDID, let metadataEDID, directEDID != metadataEDID {
            throw MacVideoConnectionReadError.invalidRegistryData
        }
        guard let edid = directEDID ?? metadataEDID else { throw MacVideoConnectionReadError.invalidRegistryData }
        let display = try DisplayIdentification(edid: edid)
        for properties in [record, metadata] {
            if let product = properties["ProductID"] as? NSNumber,
               product.uint64Value != UInt64(display.productID) {
                throw MacVideoConnectionReadError.invalidRegistryData
            }
        }
        let transports = Set([record["ParentPortTypeDescription"], record["ParentBuiltInPortTypeDescription"]]
            .compactMap { $0 as? String }.map(transport).filter { $0 != .unknown })
        // An adapter may report different immediate and built-in connectors.
        // Keep that distinction unresolved rather than selecting one silently.
        let observedTransport = transports.count == 1 ? transports.first! : .unknown
        let hostPort = (record["TransportDescription"] as? String)
            .flatMap { $0.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) }
        return try MacVideoConnection(transport: observedTransport, hostPort: hostPort, display: display)
    }

    private static func transport(_ name: String) -> VideoTransport {
        switch name {
        case "HDMI": return .hdmi
        case "DisplayPort": return .displayPort
        case "USB-C": return .usbc
        default: return .unknown
        }
    }

    private static func portState(_ record: [String: Any]) -> MacVideoPortState? {
        guard let active = record["Active"] as? NSNumber,
              let description = record["TransportDescription"] as? String,
              let port = description.split(separator: "/").first.map(String.init),
              !port.isEmpty, port.utf8.count <= 96, port.utf8.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        func text(_ key: String) -> String? {
            guard let value = record[key] as? String, !value.isEmpty, value.utf8.count <= 96,
                  value.utf8.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
            return value
        }
        func code(_ key: String) -> Int? {
            guard let number = record[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue <= 255,
                  number.doubleValue == Double(number.intValue) else { return nil }
            return number.intValue
        }
        let transports = Set([text("ParentPortTypeDescription"), text("ParentBuiltInPortTypeDescription")]
            .compactMap { $0 }.map(transport).filter { $0 != .unknown })
        return MacVideoPortState(hostPort: port, transport: transports.count == 1 ? transports.first! : .unknown,
            active: active.boolValue, linkRateDescription: text("LinkRateDescription"),
            driverStatus: text("DriverStatusDescription"), hotPlugStatus: text("HPD_StateDescription"),
            rawLaneCount: code("LaneCount"), rawMaxLaneCount: code("MaxLaneCount"))
    }

    private static func failed(_ code: InventoryFailureCode) -> MacVideoConnectionSnapshot {
        MacVideoConnectionSnapshot(connections: [], outcome: .failed(code: code, message: "Display-link registry unavailable"))
    }
}

/// Direct OS-reported observations, not measured throughput or error counters.
/// Lane fields stay opaque: their encoding is not a verified physical count.
public struct MacVideoPortState: Codable, Equatable, Sendable {
    public let hostPort: String
    public let transport: VideoTransport
    public let active: Bool
    public let linkRateDescription: String?
    public let driverStatus: String?
    public let hotPlugStatus: String?
    public let rawLaneCount: Int?
    public let rawMaxLaneCount: Int?
}
