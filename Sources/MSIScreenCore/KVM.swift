import Foundation

/// The MD342CQP switches its downstream USB devices between these upstream ports.
public enum KVMRoute: String, CaseIterable, Codable {
    case auto, upstream, usbc

    public var title: String {
        switch self {
        case .auto: return "Auto (follow video)"
        case .upstream: return "USB-B upstream"
        case .usbc: return "USB-C"
        }
    }

    init(response: [UInt8]) throws {
        switch response {
        case [48, 48, 48]: self = .auto
        case [48, 48, 49]: self = .upstream
        case [48, 48, 50]: self = .usbc
        default: throw ScreenError.message("Unsupported response for 008>0: \(response.hex)")
        }
    }
}

public struct KVMSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let model: String
    public let protocolVersion: String
    public let route: KVMRoute

    public init(model: String, protocolVersion: String, route: KVMRoute) {
        schemaVersion = 1
        self.model = model
        self.protocolVersion = protocolVersion
        self.route = route
    }
}

public extension ScreenController {
    /// Read the configured route. Auto does not identify the currently active
    /// USB host, and USB readback does not prove a peripheral is working there.
    func kvmStatus() throws -> KVMSnapshot {
        try validateIdentity()
        // MSI's MD342CQP global command list includes KVM128, register008>0.
        // Keep this separate from picture settings: rerouting USB can also move
        // the HID controller away from the host currently controlling the screen.
        let route = try KVMRoute(response: transport.query("008>0"))
        return KVMSnapshot(model: "MD342CQP", protocolVersion: "V20", route: route)
    }
}
