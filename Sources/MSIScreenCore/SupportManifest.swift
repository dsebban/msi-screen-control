import Foundation

public enum SupportArchitecture: String, Codable, Sendable { case arm64, x86_64 }
public enum DeviceTransport: String, Codable, Sendable { case usb, bluetooth, display, other }

public struct DeviceUsage: Codable, Equatable, Hashable, Sendable {
    public let page: UInt16
    public let usage: UInt16
    public init(page: UInt16, usage: UInt16) { self.page = page; self.usage = usage }
    private enum CodingKeys: String, CodingKey { case page, usage }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["page", "usage"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decode(UInt16.self, forKey: .page); usage = try c.decode(UInt16.self, forKey: .usage)
    }
}

/// Static eligibility only, never an automatic binding or endpoint address.
public struct DevicePassiveSelector: Codable, Equatable, Sendable {
    public let transport: DeviceTransport
    public let vendorID: UInt32
    public let productID: UInt32
    public let interfaceNumber: UInt8?
    public let usages: [DeviceUsage]
    public init(transport: DeviceTransport, vendorID: UInt32, productID: UInt32,
                interfaceNumber: UInt8?, usages: [DeviceUsage]) throws {
        self.transport = transport; self.vendorID = vendorID; self.productID = productID
        self.interfaceNumber = interfaceNumber; self.usages = usages
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case transport, vendorID, productID, interfaceNumber, usages }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["transport", "vendorID", "productID", "interfaceNumber", "usages"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transport = try c.decode(DeviceTransport.self, forKey: .transport)
        vendorID = try c.decode(UInt32.self, forKey: .vendorID); productID = try c.decode(UInt32.self, forKey: .productID)
        interfaceNumber = try c.decodeIfPresent(UInt8.self, forKey: .interfaceNumber)
        usages = try c.decode([DeviceUsage].self, forKey: .usages)
        try validate()
    }
    public func validate() throws {
        try requireContract(usages.count <= 128 && Set(usages).count == usages.count, "selectorUsages")
        if transport == .usb || transport == .bluetooth {
            try requireContract(vendorID <= 65535 && productID <= 65535, "selectorNumericDomain")
        }
        if transport == .display { try requireContract(interfaceNumber == nil && usages.isEmpty, "displaySelector") }
    }
}

public struct DeviceMSIIdentityTuple: Codable, Equatable, Hashable, Sendable {
    public let identityHex: String
    public let protocolHex: String
    public init(identityHex: String, protocolHex: String) throws {
        self.identityHex = identityHex; self.protocolHex = protocolHex; try validate()
    }
    private enum CodingKeys: String, CodingKey { case identityHex, protocolHex }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["identityHex", "protocolHex"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identityHex = try c.decode(String.self, forKey: .identityHex)
        protocolHex = try c.decode(String.self, forKey: .protocolHex)
        try validate()
    }
    public func validate() throws {
        func hex(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 128 && value.utf8.count % 2 == 0
                && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        try requireContract(hex(identityHex) && hex(protocolHex), "identityTuple")
    }
}

public struct DeviceTrustedGuard: Codable, Equatable, Sendable {
    public let id: String
    public let allowedIdentities: [DeviceMSIIdentityTuple]
    public init(id: String, allowedIdentities: [DeviceMSIIdentityTuple]) throws {
        self.id = id; self.allowedIdentities = allowedIdentities; try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, allowedIdentities }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "allowedIdentities"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        allowedIdentities = try c.decode([DeviceMSIIdentityTuple].self, forKey: .allowedIdentities)
        try validate()
    }
    public func validate() throws {
        try requireContract(id == "msi-identity-v1" && (1...32).contains(allowedIdentities.count)
            && Set(allowedIdentities).count == allowedIdentities.count, "trustedGuard")
        try allowedIdentities.forEach { try $0.validate() }
        try requireContract(!allowedIdentities.contains { $0.identityHex == "3030a0" && $0.protocolHex == "563230" }, "protectedIdentity")
    }
}

public enum SupportBackend: Codable, Equatable, Sendable {
    case profile(engine: String, relativePath: String)
    case nativeAdapter(relativeExecutable: String, architectures: [SupportArchitecture], minimumMacOS: String)
    private enum CodingKeys: String, CodingKey { case kind, engine, relativePath, relativeExecutable, architectures, minimumMacOS }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "profile":
            try decoder.contractKeys(["kind", "engine", "relativePath"])
            self = .profile(engine: try c.decode(String.self, forKey: .engine), relativePath: try c.decode(String.self, forKey: .relativePath))
        case "nativeAdapter":
            try decoder.contractKeys(["kind", "relativeExecutable", "architectures", "minimumMacOS"])
            self = .nativeAdapter(relativeExecutable: try c.decode(String.self, forKey: .relativeExecutable),
                architectures: try c.decode([SupportArchitecture].self, forKey: .architectures), minimumMacOS: try c.decode(String.self, forKey: .minimumMacOS))
        default: throw DeviceContractError.invalid("backend")
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .profile(let engine, let path):
            try c.encode("profile", forKey: .kind); try c.encode(engine, forKey: .engine); try c.encode(path, forKey: .relativePath)
        case .nativeAdapter(let path, let architectures, let minimum):
            try c.encode("nativeAdapter", forKey: .kind); try c.encode(path, forKey: .relativeExecutable)
            try c.encode(architectures, forKey: .architectures); try c.encode(minimum, forKey: .minimumMacOS)
        }
    }
    public var payloadPath: String {
        switch self { case .profile(_, let p), .nativeAdapter(let p, _, _): return p }
    }
    public func validate() throws {
        try requireContract(SupportManifest.validRelativePath(payloadPath), "payloadPath")
        switch self {
        case .profile(let engine, _): try requireContract(engine == "hid-feature-fields-v1", "profileEngine")
        case .nativeAdapter(_, let architectures, let minimum):
            try requireContract(!architectures.isEmpty && Set(architectures).count == architectures.count
                && minimum.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?\z"#, options: .regularExpression) != nil
                && minimum.utf8.count <= 24, "nativeMetadata")
        }
    }
}

/// Structural validation only. File ownership, exact content sets, signatures,
/// native compatibility and selfTest are installer gates, not manifest claims.
public struct SupportManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let hostAPI: Int
    public let id: String
    public let version: String
    public let name: String
    public let backend: SupportBackend
    public let selectors: [DevicePassiveSelector]
    public let trustedGuards: [DeviceTrustedGuard]
    public let descriptor: DeviceDescriptor
    public let files: [String: String]

    public init(schema: Int, hostAPI: Int, id: String, version: String, name: String, backend: SupportBackend,
                selectors: [DevicePassiveSelector], trustedGuards: [DeviceTrustedGuard], descriptor: DeviceDescriptor, files: [String: String]) throws {
        self.schema = schema; self.hostAPI = hostAPI; self.id = id; self.version = version; self.name = name
        self.backend = backend; self.selectors = selectors; self.trustedGuards = trustedGuards; self.descriptor = descriptor; self.files = files
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case schema, hostAPI, id, version, name, backend, selectors, trustedGuards, descriptor, files }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "hostAPI", "id", "version", "name", "backend", "selectors", "trustedGuards", "descriptor", "files"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); hostAPI = try c.decode(Int.self, forKey: .hostAPI)
        id = try c.decode(String.self, forKey: .id); version = try c.decode(String.self, forKey: .version); name = try c.decode(String.self, forKey: .name)
        backend = try c.decode(SupportBackend.self, forKey: .backend)
        selectors = try c.decode([DevicePassiveSelector].self, forKey: .selectors)
        trustedGuards = try c.decode([DeviceTrustedGuard].self, forKey: .trustedGuards)
        descriptor = try c.decode(DeviceDescriptor.self, forKey: .descriptor); files = try c.decode([String: String].self, forKey: .files)
        try validate()
    }
    public func validate() throws {
        try requireContract(schema == 1 && hostAPI == 1, "unsupportedSchemaOrAPI")
        try requireContract(id.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}\z"#, options: .regularExpression) != nil
            && contractLabel(name) && version.utf8.count <= 128, "manifestIdentity")
        try requireContract(Self.validSemanticVersion(version), "semanticVersion")
        try backend.validate(); try descriptor.validate()
        if case .profile = backend {
            try requireContract(selectors.allSatisfy { [.usb, .bluetooth].contains($0.transport) && !$0.usages.isEmpty }, "profileHIDSelector")
        }
        let selectorData = try selectors.map { try StrictJSON.canonical($0) }
        try requireContract((1...32).contains(selectors.count) && Set(selectorData).count == selectors.count
            && trustedGuards.count <= 1, "selectors")
        try selectors.forEach { try $0.validate() }; try trustedGuards.forEach { try $0.validate() }
        // Static protection is not live identity verification; the runtime guard
        // must still own the exact selected endpoint before any dispatch.
        try requireContract(!selectors.contains { ($0.vendorID == 0x046d && $0.productID == 0xc548)
            || ($0.vendorID == 0x24ae && $0.productID == 0x186a) }, "reservedReceiverDomain")
        let msi = selectors.contains { $0.vendorID == 0x1462 && $0.productID == 0x3fa4 }
        try requireContract(msi == !trustedGuards.isEmpty, "requiredTrustedGuard")
        try requireContract((1...63).contains(files.count) && files[backend.payloadPath] != nil
            && files.keys.allSatisfy(Self.validRelativePath) && files["manifest.json"] == nil
            && files.values.allSatisfy(contractDigest), "payloadMap")
        let folded = files.keys.map(Self.foldedPath)
        try requireContract(Set(folded).count == files.count && !folded.contains("manifest.json"), "pathCollision")
        let paths = Set(folded)
        try requireContract(folded.allSatisfy { path in
            let parts = path.split(separator: "/")
            return (1..<parts.count).allSatisfy { !paths.contains(parts.prefix($0).joined(separator: "/")) }
        }, "fileDirectoryCollision")
    }
    static func foldedPath(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    static func validRelativePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 1024 && parts.count <= 16
            && value == value.precomposedStringWithCanonicalMapping
            && !value.contains("\\") && !value.contains(":")
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func validSemanticVersion(_ value: String) -> Bool {
        let identifier = #"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"#
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-"# + identifier + #"(?:\."# + identifier + #")*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
