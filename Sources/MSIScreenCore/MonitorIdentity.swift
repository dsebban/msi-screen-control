import Foundation

/// USB VID/PID is shared across MSI models. Only this exact model/firmware
/// identity authorizes our register profile; raw bytes remain useful for
/// evaluating another monitor without querying model-specific controls.
public struct MonitorIdentity: Encodable, Equatable {
    public let schemaVersion = 1
    public let identityHex: String
    public let protocolHex: String
    public let protocolVersion: String?
    public let matchedProfile: String?
    public let controlSupported: Bool

    init(identity: [UInt8], version: [UInt8]) {
        identityHex = identity.hex
        protocolHex = version.hex
        protocolVersion = version.allSatisfy { (0x20...0x7e).contains($0) } && !version.isEmpty
            ? String(bytes: version, encoding: .ascii) : nil
        controlSupported = identity == [0x30, 0x30, 0xa0] && version == Array("V20".utf8)
        matchedProfile = controlSupported ? "MD342CQP/V20" : nil
    }
}

public extension ScreenController {
    /// Two read-only identity requests, without layout or setting registers.
    func identity() throws -> MonitorIdentity {
        try MonitorIdentity(identity: transport.query("00140"), version: transport.query("00150"))
    }
}
