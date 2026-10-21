import Foundation
import CryptoKit

public enum DeviceKind: String, Codable, Sendable {
    case display, hub, receiver, keyboard, pointer, gameController, other
}
public enum DeviceEndpointKind: String, Codable, Sendable { case display, usb, hid, providerObservedPaired }
public enum DeviceRelationKind: String, Codable, Sendable { case usbParent, interfaceOf, pairedThrough, controlsDisplay }
public enum DeviceRelationEvidence: String, Codable, Sendable { case osAncestry, providerValidated }
public enum DeviceBindingEligibility: String, Codable, Sendable { case durable, attachmentOnly, transient, ambiguous }
public enum InventoryFailureCode: String, Codable, Sendable {
    case unavailable, denied, changedDuringEnumeration, nonConsoleSession, identityUnavailable
}

public enum InventorySourceOutcome: Codable, Equatable, Sendable {
    case complete
    case failed(code: InventoryFailureCode, message: String)
    private enum CodingKeys: String, CodingKey { case kind, code, message }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "complete": try decoder.contractKeys(["kind"]); self = .complete
        case "failed":
            try decoder.contractKeys(["kind", "code", "message"])
            let code = try c.decode(InventoryFailureCode.self, forKey: .code)
            let message = try c.decode(String.self, forKey: .message)
            try requireContract(contractLabel(message), "inventoryFailure")
            self = .failed(code: code, message: message)
        default: throw DeviceContractError.invalid("inventoryOutcome")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .complete: try c.encode("complete", forKey: .kind)
        case .failed(let code, _):
            try c.encode("failed", forKey: .kind); try c.encode(code, forKey: .code)
            // OS diagnostics are local-only; never forward an arbitrary error.
            try c.encode("Inventory source incomplete", forKey: .message)
        }
    }
}

public struct DevicePassiveIdentity: Codable, Equatable, Sendable {
    public let transport: DeviceTransport
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let interfaceNumber: UInt8?
    public let usages: [DeviceUsage]
    public let isBuiltIn: Bool?
    public let isMain: Bool?
    public let isActive: Bool?
    public let isAsleep: Bool?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(transport: DeviceTransport, vendorID: UInt32? = nil, productID: UInt32? = nil,
                interfaceNumber: UInt8? = nil, usages: [DeviceUsage] = [], isBuiltIn: Bool? = nil,
                isMain: Bool? = nil, isActive: Bool? = nil, isAsleep: Bool? = nil,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) throws {
        self.transport = transport; self.vendorID = vendorID; self.productID = productID
        self.interfaceNumber = interfaceNumber; self.usages = usages
        self.isBuiltIn = isBuiltIn; self.isMain = isMain; self.isActive = isActive; self.isAsleep = isAsleep
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        try validate()
    }
    private enum CodingKeys: String, CodingKey {
        case transport, vendorID, productID, interfaceNumber, usages, isBuiltIn, isMain, isActive, isAsleep, pixelWidth, pixelHeight
    }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["transport", "vendorID", "productID", "interfaceNumber", "usages", "isBuiltIn", "isMain", "isActive", "isAsleep", "pixelWidth", "pixelHeight"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decode(DeviceTransport.self, forKey: .transport)
        vendorID = try c.decodeIfPresent(UInt32.self, forKey: .vendorID); productID = try c.decodeIfPresent(UInt32.self, forKey: .productID)
        interfaceNumber = try c.decodeIfPresent(UInt8.self, forKey: .interfaceNumber); usages = try c.decode([DeviceUsage].self, forKey: .usages)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn); isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive); isAsleep = try c.decodeIfPresent(Bool.self, forKey: .isAsleep)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth); pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight)
        try validate()
    }
    public func validate() throws {
        try requireContract(usages.count <= 128 && Set(usages).count == usages.count
            && pixelWidth.map { (1...100000).contains($0) } != false && pixelHeight.map { (1...100000).contains($0) } != false, "passiveIdentity")
    }
}

/// Private, in-memory local address. Not part of normal inventory encoding.
/// A decoded exported endpoint has no address and must be resolved host-side.
public enum DeviceEndpointAddress: Equatable, Sendable {
    case display(id: UInt32, uuid: String?)
    case usb(registryID: UInt64, parentID: UInt64?)
    case hid(registryID: UInt64, usbDeviceID: UInt64?, interfaceID: UInt64?)
    case providerObservedPaired(receiverID: UInt64, providerID: String, validatedIdentity: String)
}

public struct DeviceEndpoint: Codable, Equatable, Sendable {
    public let kind: DeviceEndpointKind
    public let id: String
    public let identity: DevicePassiveIdentity
    public let physicalDomainID: String
    public let incarnationID: String
    public let address: DeviceEndpointAddress?

    public init(kind: DeviceEndpointKind, id: String, identity: DevicePassiveIdentity,
                physicalDomainID: String, incarnationID: String, address: DeviceEndpointAddress?) throws {
        self.kind = kind; self.id = id; self.identity = identity
        self.physicalDomainID = physicalDomainID; self.incarnationID = incarnationID; self.address = address
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case kind, id, identity, physicalDomainID, incarnationID }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["kind", "id", "identity", "physicalDomainID", "incarnationID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(DeviceEndpointKind.self, forKey: .kind); id = try c.decode(String.self, forKey: .id)
        identity = try c.decode(DevicePassiveIdentity.self, forKey: .identity)
        physicalDomainID = try c.decode(String.self, forKey: .physicalDomainID)
        incarnationID = try c.decode(String.self, forKey: .incarnationID); address = nil
        try validate()
    }
    public func validate() throws {
        try identity.validate()
        try requireContract([id, physicalDomainID, incarnationID].allSatisfy(contractDigest), "endpointIdentity")
        switch kind {
        case .display: try requireContract(identity.transport == .display, "endpointTransport")
        case .usb: try requireContract(identity.transport == .usb, "endpointTransport")
        case .hid: try requireContract(identity.transport != .display, "endpointTransport")
        case .providerObservedPaired: break
        }
        if let address {
            switch (kind, address) {
            case (.display, .display(let id, _)): try requireContract(id != 0, "displayAddress")
            case (.usb, .usb(let id, _)), (.hid, .hid(let id, _, _)): try requireContract(id != 0, "registryAddress")
            case (.providerObservedPaired, .providerObservedPaired(let receiver, let provider, let pairingIdentity)):
                try requireContract(receiver != 0 && contractID(provider) && !pairingIdentity.isEmpty, "pairedAddress")
            default: throw DeviceContractError.invalid("endpointAddressTag")
            }
        }
    }
}

public struct DeviceRelation: Codable, Equatable, Sendable {
    public let kind: DeviceRelationKind
    public let targetID: String
    public let evidence: DeviceRelationEvidence
    public init(kind: DeviceRelationKind, targetID: String, evidence: DeviceRelationEvidence) throws {
        self.kind = kind; self.targetID = targetID; self.evidence = evidence; try validate()
    }
    private enum CodingKeys: String, CodingKey { case kind, targetID, evidence }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["kind", "targetID", "evidence"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(DeviceRelationKind.self, forKey: .kind); targetID = try c.decode(String.self, forKey: .targetID)
        evidence = try c.decode(DeviceRelationEvidence.self, forKey: .evidence); try validate()
    }
    public func validate() throws {
        try requireContract(contractDigest(targetID), "relationTarget")
        try requireContract(![.pairedThrough, .controlsDisplay].contains(kind) || evidence == .providerValidated, "relationEvidence")
    }
}

public struct DeviceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// OS-supplied quoted data, for local UI only. Export uses a fixed kind label.
    public let displayName: String
    public let kind: DeviceKind
    public let endpoints: [DeviceEndpoint]
    public let relations: [DeviceRelation]
    public let bindingEligibility: DeviceBindingEligibility
    public let bindingReason: DeviceUnavailable?
    public var declaredUsages: [DeviceUsage] {
        Set(endpoints.flatMap { $0.identity.usages }).sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
    }
    public init(id: String, displayName: String, kind: DeviceKind, endpoints: [DeviceEndpoint], relations: [DeviceRelation],
                bindingEligibility: DeviceBindingEligibility, bindingReason: DeviceUnavailable?) throws {
        self.id = id; self.displayName = displayName; self.kind = kind; self.endpoints = endpoints
        self.relations = relations; self.bindingEligibility = bindingEligibility; self.bindingReason = bindingReason; try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, displayName, kind, endpoints, relations, bindingEligibility, bindingReason }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "displayName", "kind", "endpoints", "relations", "bindingEligibility", "bindingReason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decode(DeviceKind.self, forKey: .kind); endpoints = try c.decode([DeviceEndpoint].self, forKey: .endpoints)
        relations = try c.decode([DeviceRelation].self, forKey: .relations)
        bindingEligibility = try c.decode(DeviceBindingEligibility.self, forKey: .bindingEligibility)
        bindingReason = try c.decodeIfPresent(DeviceUnavailable.self, forKey: .bindingReason); try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(kind.rawValue, forKey: .displayName); try c.encode(kind, forKey: .kind)
        try c.encode(endpoints, forKey: .endpoints); try c.encode(relations, forKey: .relations)
        try c.encode(bindingEligibility, forKey: .bindingEligibility); try c.encodeIfPresent(bindingReason, forKey: .bindingReason)
    }
    public func validate() throws {
        try requireContract(contractDigest(id) && contractLabel(displayName) && !endpoints.isEmpty && endpoints.count <= 128
            && Set(endpoints.map(\.id)).count == endpoints.count && relations.count <= 128, "deviceRecord")
        try endpoints.forEach { try $0.validate() }; try relations.forEach { try $0.validate() }; try bindingReason?.validate()
        try requireContract(bindingEligibility == .durable || bindingReason != nil, "bindingReason")
    }
}

public struct DeviceInventorySnapshot: Codable, Equatable, Sendable {
    public let schema: Int
    public let checkedAtMilliseconds: Int64
    public let generation: UInt64
    public let devices: [DeviceRecord]
    public let displays: InventorySourceOutcome
    public let usb: InventorySourceOutcome
    public let hid: InventorySourceOutcome
    public init(schema: Int = 1, checkedAtMilliseconds: Int64, generation: UInt64, devices: [DeviceRecord],
                displays: InventorySourceOutcome, usb: InventorySourceOutcome, hid: InventorySourceOutcome) throws {
        self.schema = schema; self.checkedAtMilliseconds = checkedAtMilliseconds; self.generation = generation
        self.devices = devices; self.displays = displays; self.usb = usb; self.hid = hid; try validate()
    }
    private enum CodingKeys: String, CodingKey { case schema, checkedAtMilliseconds, generation, devices, displays, usb, hid }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "checkedAtMilliseconds", "generation", "devices", "displays", "usb", "hid"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); checkedAtMilliseconds = try c.decode(Int64.self, forKey: .checkedAtMilliseconds)
        generation = try c.decode(UInt64.self, forKey: .generation); devices = try c.decode([DeviceRecord].self, forKey: .devices)
        displays = try c.decode(InventorySourceOutcome.self, forKey: .displays); usb = try c.decode(InventorySourceOutcome.self, forKey: .usb)
        hid = try c.decode(InventorySourceOutcome.self, forKey: .hid); try validate()
    }
    public func validate() throws {
        try requireContract(schema == 1 && checkedAtMilliseconds >= 0 && devices.count <= 4096
            && Set(devices.map(\.id)).count == devices.count, "inventorySnapshot")
        try devices.forEach { try $0.validate() }
        let ids = Set(devices.map(\.id))
        try requireContract(devices.allSatisfy { $0.relations.allSatisfy { ids.contains($0.targetID) } }, "missingRelation")
    }

    /// Re-enumerate first. Exported records alone cannot authorize an open.
    public func resolve(_ expected: DeviceEndpoint) throws -> DeviceEndpoint {
        let matches = devices.flatMap(\.endpoints).filter { $0.id == expected.id }
        try requireContract(matches.count == 1, matches.isEmpty ? "absentEndpoint" : "ambiguousEndpoint")
        let actual = matches[0]
        try requireContract(expected.address != nil && actual == expected, "staleEndpoint")
        return actual
    }
}

public protocol DeviceInventoryClient: Sendable {
    func snapshot() async throws -> DeviceInventorySnapshot
}

/// W3 supplies a securely loaded installation key. Missing/unreadable keys use
/// an ephemeral session key, explicitly disabling persistent binding/control.
/// This type does no filesystem work and never replaces a damaged key.
public struct DeviceInventoryIdentity: Sendable {
    private let key: SymmetricKey
    public let persistent: Bool
    public let unavailableReason: DeviceUnavailable?
    public init(installationKey: Data?, unavailableReason: DeviceUnavailable? = nil) throws {
        if let installationKey {
            try requireContract(installationKey.count == 32, "identityKeyLength")
            key = SymmetricKey(data: installationKey); persistent = true; self.unavailableReason = nil
        } else {
            key = SymmetricKey(size: .bits256); persistent = false
            self.unavailableReason = try unavailableReason ?? DeviceUnavailable(code: "identityKeyUnavailable")
        }
    }
    func token(_ domain: String, _ fields: [String]) -> String {
        // Length-prefix every component: no separator/concatenation collisions.
        var data = Data()
        for field in ["msi-screen-inventory-v1", domain] + fields {
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(bytes)
        }
        return HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }
}
