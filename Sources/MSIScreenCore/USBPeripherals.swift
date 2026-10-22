import Foundation

public enum USBReceiverKind: String, CaseIterable, Codable, Identifiable {
    case bolt, rapoo
    public var id: Self { self }
    public var displayName: String { self == .bolt ? "Logitech Bolt" : "Rapoo NearLink" }
}

public enum USBReceiverConnection: String, Codable {
    case monitorHub, elsewhere, notDetected
}

public enum PeripheralRadioState: String, Codable, Sendable {
    case responding, notResponding, unavailable
}

public enum PairedPeripheralKind: String, Codable, Sendable {
    case keyboard, mouse, other
}

public struct PairedUSBPeripheral: Codable, Equatable, Identifiable, Sendable {
    public let slot: Int
    public let name: String?
    public let kind: PairedPeripheralKind
    public let wirelessProductID: String
    public let radio: PeripheralRadioState
    public let protocolVersion: String?
    public let error: String?
    public var id: Int { slot }
}

public struct USBReceiverSnapshot: Codable, Equatable, Identifiable {
    public let id: USBReceiverKind
    public let connection: USBReceiverConnection
    public let pairedDevices: [PairedUSBPeripheral]
    public let error: String?
    public var displayName: String { id.displayName }
}

public struct USBPeripheralSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let hostName: String
    public let platform: MachinePlatform
    public let monitorHubPresent: Bool
    public let receivers: [USBReceiverSnapshot]
}

/// Explicit reads only. The caller chooses the host after reading the KVM route;
/// this client neither changes that route nor starts a polling task.
public struct USBPeripheralClient {
    private static let queue = DispatchQueue(label: "MSIScreen.USB-peripherals", qos: .utility)
    public init() {}

    public func local() async throws -> USBPeripheralSnapshot {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try MacUSBPeripheralReader.read() })
            }
        }
    }

    public func remote(host: String, transport: SSHTransport = .standard) async throws -> USBPeripheralSnapshot {
        try Task.checkCancellation()
        try RemoteMacClient(host: host, transport: transport).validateHost()
        let output = try await ProcessRunner.run(
            executable: try transport.executable(),
            arguments: try RemoteKVMEndpoint.arguments(host: host, transport: transport), timeout: 15,
            input: Data(#"{"schemaVersion":1,"action":"peripherals"}"#.utf8), outputLimit: 32_768
        )
        guard !output.timedOut else { throw ScreenError.message("Linux peripheral check timed out") }
        guard !output.truncated, output.succeeded else {
            throw ScreenError.message(output.exitCode == 127
                ? "Install the Linux MSI Screen companion before checking USB peripherals"
                : "Linux peripheral check failed; refresh or update its MSI Screen companion")
        }
        return try Self.decodeRemote(Data(output.text.utf8))
    }

    public func localDetails(for expected: PairedUSBPeripheral) async throws -> POPKeyboardDetails {
        try Task.checkCancellation()
        try POPKeyboardProbe.validateExpected(expected)
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try MacUSBPeripheralReader.readDetails(expected: expected) })
            }
        }
    }

    public func remoteDetails(host: String, transport: SSHTransport = .standard,
                              for expected: PairedUSBPeripheral) async throws -> POPKeyboardDetails {
        try Task.checkCancellation()
        try POPKeyboardProbe.validateExpected(expected)
        try RemoteMacClient(host: host, transport: transport).validateHost()
        struct Request: Encodable {
            let schemaVersion = 1
            let action = "popDetails"
            let slot: Int
            let expectedWirelessProductID: String
        }
        let input = try JSONEncoder().encode(Request(slot: expected.slot, expectedWirelessProductID: expected.wirelessProductID))
        let output = try await ProcessRunner.run(executable: try transport.executable(),
            arguments: try RemoteKVMEndpoint.arguments(host: host, transport: transport),
            timeout: 20, input: input, outputLimit: 65_536)
        guard !output.timedOut else { throw ScreenError.message("Linux POP Keys detail check timed out") }
        guard output.succeeded, !output.truncated else {
            throw ScreenError.message(output.exitCode == 127
                ? "Install the Linux MSI Screen companion before checking POP Keys details"
                : "POP Keys details unavailable; refresh peripherals and check that the keyboard is responding")
        }
        return try POPKeyboardDetails.decodeRemote(Data(output.text.utf8), expected: expected)
    }

    static func decodeRemote(_ data: Data) throws -> USBPeripheralSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(USBPeripheralSnapshot.self, from: data),
              snapshot.schemaVersion == 1, snapshot.platform == .linux,
              validText(snapshot.hostName, maximum: 128), !snapshot.hostName.isEmpty,
              snapshot.receivers.count == 2,
              Set(snapshot.receivers.map(\.id)) == Set(USBReceiverKind.allCases) else {
            throw ScreenError.message("Linux returned an invalid peripheral snapshot; update its companion")
        }
        for receiver in snapshot.receivers {
            guard (snapshot.monitorHubPresent || receiver.connection != .monitorHub),
                  receiver.connection == .monitorHub || receiver.pairedDevices.isEmpty,
                  receiver.id == .bolt || receiver.pairedDevices.isEmpty,
                  receiver.pairedDevices.count <= 6,
                  Set(receiver.pairedDevices.map(\.slot)).count == receiver.pairedDevices.count,
                  receiver.error.map({ validText($0, maximum: 512) }) ?? true else {
                throw ScreenError.message("Linux returned inconsistent peripheral topology")
            }
            for device in receiver.pairedDevices {
                guard (1...6).contains(device.slot), device.wirelessProductID.count == 4,
                      device.wirelessProductID.allSatisfy(\.isHexDigit),
                      device.name.map({ validText($0, maximum: 128) }) ?? true,
                      device.error.map({ validText($0, maximum: 512) }) ?? true,
                      validVersion(device.protocolVersion, radio: device.radio) else {
                    throw ScreenError.message("Linux returned invalid paired-device metadata")
                }
            }
        }
        return snapshot
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        value.utf8.count <= maximum && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validVersion(_ value: String?, radio: PeripheralRadioState) -> Bool {
        guard radio == .responding else { return value == nil }
        guard let value, value.utf8.count <= 7 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            && UInt8(parts[0]).map { $0 > 0 } == true && UInt8(parts[1]) != nil
    }
}
