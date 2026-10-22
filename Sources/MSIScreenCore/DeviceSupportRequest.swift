import CryptoKit
import Darwin
import Foundation

public struct PreparedDeviceSupportRequest: Codable, Equatable, Sendable {
    public let schema: Int
    public let requestID: UUID
    public let expiresAtMilliseconds: Int64
    public let deviceID: String
    public let skill: AgentSkill
    public let skillStatus: AgentSkillInstallResult
    public let prompt: String
}

public struct ResolvedDeviceSupportRequest: Codable, Equatable, Sendable {
    public let schema: Int
    public let requestID: UUID
    public let expiresAtMilliseconds: Int64
    public let deviceID: String
    public let category: DeviceKind
    public let facts: DevicePassiveIdentity
    public let bindingEligibility: DeviceBindingEligibility
    public let bindingID: String?
    public let activeDigest: String?
    public let registryRevision: UInt64
    public let hostAPI: Int
}

private struct PrivateSupportRequest: Codable {
    let schema: Int
    let id: UUID
    let issuedAtMilliseconds: Int64
    let expiresAtMilliseconds: Int64
    let endpoint: DeviceEndpoint
    let category: DeviceKind
    let binding: SupportBinding?
    let authentication: String
    private enum CodingKeys: String, CodingKey {
        case schema, id, issuedAtMilliseconds, expiresAtMilliseconds, endpoint, category, binding, authentication
    }
    init(id: UUID, issued: Int64, endpoint: DeviceEndpoint, category: DeviceKind, binding: SupportBinding?, authentication: String) {
        schema = 1; self.id = id; issuedAtMilliseconds = issued; expiresAtMilliseconds = issued + 86400000
        self.endpoint = endpoint; self.category = category; self.binding = binding; self.authentication = authentication
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "id", "issuedAtMilliseconds", "expiresAtMilliseconds", "endpoint", "category", "binding", "authentication"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); id = try c.decode(UUID.self, forKey: .id)
        issuedAtMilliseconds = try c.decode(Int64.self, forKey: .issuedAtMilliseconds)
        expiresAtMilliseconds = try c.decode(Int64.self, forKey: .expiresAtMilliseconds)
        endpoint = try c.decode(DeviceEndpoint.self, forKey: .endpoint); category = try c.decode(DeviceKind.self, forKey: .category)
        binding = try c.decodeIfPresent(SupportBinding.self, forKey: .binding); authentication = try c.decode(String.self, forKey: .authentication)
        try requireContract(schema == 1 && issuedAtMilliseconds >= 0 && issuedAtMilliseconds <= Int64.max - 86400000
            && expiresAtMilliseconds == issuedAtMilliseconds + 86400000 && contractDigest(authentication), "invalidRequest")
    }
}

/// No clipboard, agent launch or active device access. Requests contain only exact
/// keyed endpoint commitments; raw OS addresses are re-resolved locally, not exported.
public final class DeviceSupportRequest {
    private let registry: SupportRegistry
    private let inventory: any DeviceInventoryClient
    private let installer: AgentSkillInstallation
    private let source: () throws -> URL
    private let destination: () throws -> URL
    private let now: () -> Int64
    public convenience init(registry: SupportRegistry, executable: URL? = nil) throws {
        let inventory = MacDeviceInventoryReader(identity: try DeviceInventoryIdentity(installationKey: registry.installationKey()))
        self.init(registry: registry, inventory: inventory, installer: AgentSkillInstallation(registry: registry),
            source: { try AgentSkillInstallation.bundledSkill(.writeSupport, executable: executable) },
            destination: { try AgentSkillInstallation.skillsHome().appendingPathComponent(AgentSkill.writeSupport.rawValue) })
    }
    init(registry: SupportRegistry, inventory: any DeviceInventoryClient, installer: AgentSkillInstallation,
         source: @escaping () throws -> URL, destination: @escaping () throws -> URL,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.registry = registry; self.inventory = inventory; self.installer = installer
        self.source = source; self.destination = destination; self.now = now
    }
    /// Passive inspect can return exact incomplete/ineligible facts. Binding and
    /// request preparation retain the stricter default; this is not authorization.
    public static func selectedEndpoint(_ id: String, in snapshot: DeviceInventorySnapshot, requireEligible: Bool = true) throws -> (DeviceRecord, DeviceEndpoint) {
        try requireContract(contractDigest(id), "invalidEndpointID")
        let matches = snapshot.devices.flatMap { record in record.endpoints.filter { $0.id == id }.map { (record, $0) } }
        try requireContract(matches.count == 1, matches.isEmpty ? "absentEndpoint" : "ambiguousEndpoint")
        let (record, endpoint) = matches[0]
        if !requireEligible { return (record, endpoint) }
        try requireCompleteSources(for: endpoint, in: snapshot)
        try requireContract(endpoint.address != nil && record.bindingEligibility != .ambiguous && record.bindingEligibility != .transient, "ineligibleEndpoint")
        return (record, endpoint)
    }
    /// Also valid for a disconnected metadata selector (which has no address).
    /// Failed required slices are unknown, not proof of disconnection. Bluetooth
    /// HID never acquires an unrelated USB-completeness prerequisite.
    static func requireCompleteSources(for endpoint: DeviceEndpoint, in snapshot: DeviceInventorySnapshot) throws {
        switch endpoint.kind {
        case .display: try requireContract(snapshot.displays == .complete, "inventoryIncomplete")
        case .usb: try requireContract(snapshot.usb == .complete, "inventoryIncomplete")
        case .hid: try requireContract(snapshot.hid == .complete && (endpoint.identity.transport != .usb || snapshot.usb == .complete), "inventoryIncomplete")
        case .providerObservedPaired: try requireContract(snapshot.usb == .complete && snapshot.hid == .complete, "inventoryIncomplete")
        }
    }
    private func binding(for endpoint: DeviceEndpoint) throws -> SupportBinding? {
        let matches = try registry.snapshot().bindings.filter { $0.selector.physicalDomainID == endpoint.physicalDomainID }
        try requireContract(matches.count <= 1, "providerCollision"); return matches.first
    }
    private func signature(_ request: PrivateSupportRequest) throws -> String {
        var object = try JSONSerialization.jsonObject(with: StrictJSON.canonical(request)) as! [String: Any]
        object.removeValue(forKey: "authentication")
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let key = HMAC<SHA256>.authenticationCode(for: Data("device-support-request-v1".utf8), using: SymmetricKey(data: try registry.existingInstallationKey()))
        return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(key)))).map { String(format: "%02x", $0) }.joined()
    }
    private func checked(_ id: UUID) throws -> PrivateSupportRequest {
        let directory = try registry.root.directory("requests")
        let name = id.uuidString.lowercased() + ".json"
        guard try directory.exists(name) else { throw DeviceContractError.invalid("absentRequest") }
        let fd = try directory.file(name); defer { close(fd) }
        let request = try StrictJSON.decode(PrivateSupportRequest.self, from: SupportDirectory.read(fd, limit: 16384))
        let expectedSignature = try signature(request)
        try requireContract(request.id == id && expectedSignature == request.authentication, "wrongHostRequest")
        let time = now()
        try requireContract(time >= request.issuedAtMilliseconds && time < request.expiresAtMilliseconds, "expiredRequest")
        return request
    }
    private func reserveRequest(_ request: PrivateSupportRequest) throws {
        let directory = try registry.root.directory("requests"), lock = try registry.root.lock("requests.lock")
        defer { withExtendedLifetime(lock) {} }
        let listing = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard listing >= 0 else { throw SupportStorageError.unsafeFile }
        guard let stream = fdopendir(listing) else { close(listing); throw SupportStorageError.unsafeFile }
        defer { closedir(stream) }
        var count = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 1024 else { throw SupportStorageError.limitExceeded }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))), name == id.uuidString.lowercased() + ".json" else { continue }
            // Only authenticated, expired, owned files are eligible for pruning.
            if let fd = try? directory.file(name) {
                defer { close(fd) }
                if let bytes = try? SupportDirectory.read(fd, limit: 16384),
                   let old = try? StrictJSON.decode(PrivateSupportRequest.self, from: bytes), old.id == id,
                   (try? signature(old)) == old.authentication, old.expiresAtMilliseconds <= now() {
                    var opened = stat(), named = stat()
                    if fstat(fd, &opened) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                       SupportDirectory.same(opened, named), unlinkat(directory.fd, name, 0) == 0 { count -= 1 }
                }
            }
        }
        try requireContract(count < 1024, "requestStoreFull")
        let name = request.id.uuidString.lowercased() + ".json"
        let fd = try directory.file(name, flags: O_WRONLY | O_CREAT | O_EXCL); defer { close(fd) }
        do { try SupportDirectory.write(StrictJSON.canonical(request), to: fd); guard fsync(directory.fd) == 0 else { throw SupportStorageError.unsafeFile } }
        catch { unlinkat(directory.fd, name, 0); throw error }
    }
    public func prepare(deviceID: String) async throws -> PreparedDeviceSupportRequest {
        _ = try registry.installationKey()
        let (record, endpoint) = try Self.selectedEndpoint(deviceID, in: await inventory.snapshot())
        let prior = try binding(for: endpoint)
        let status = try installer.install(skill: .writeSupport, source: source(), destination: destination())
        _ = try await inventory.snapshot().resolve(endpoint)
        let afterBinding = try binding(for: endpoint)
        try requireContract(afterBinding == prior, "providerChanged")
        let issued = now(); try requireContract(issued >= 0 && issued <= Int64.max - 86400000, "invalidRequest")
        let id = UUID()
        let unsigned = PrivateSupportRequest(id: id, issued: issued, endpoint: endpoint, category: record.kind, binding: prior, authentication: String(repeating: "0", count: 64))
        let request = PrivateSupportRequest(id: id, issued: issued, endpoint: endpoint, category: record.kind, binding: prior, authentication: try signature(unsigned))
        try reserveRequest(request)
        let facts = endpoint.identity
        let numeric = [facts.vendorID.map { "vendorID=\($0)" }, facts.productID.map { "productID=\($0)" }, facts.interfaceNumber.map { "interface=\($0)" }].compactMap { $0 }.joined(separator: ", ")
        let prompt = """
        Use $write-addhoc-support. If it is not indexed yet, read ~/.agents/skills/write-addhoc-support/SKILL.md locally; newly installed skills may be available next turn.
        Request schema 1, handle \(id.uuidString.lowercased()), expiresAtMilliseconds \(request.expiresAtMilliseconds). Category \(record.kind.rawValue); transport \(facts.transport.rawValue); \(numeric). CLI host API 1.
        Locate the installed local msi-screen CLI (normally ~/Applications/MSI Screen.app/Contents/MacOS/msi-screen or /Applications/MSI Screen.app/Contents/MacOS/msi-screen), inspect capabilities, then resolve with support request HANDLE. Local overrides, if configured, must be resolved locally; do not copy their values.
        Research only nonpersonal protocol facts using primary sources. Keep private identifiers, paths and diagnostics local. Review native source: adapters run as the user, not in a sandbox. Validate offline and install the exact checked digest with registry CAS. Activation is not hardware qualification. Obtain explicit authorization for named active device experiments; do not probe or exercise newly active support automatically. Do not launch another agent, upload diagnostics or publish.
        """
        return PreparedDeviceSupportRequest(schema: 1, requestID: id, expiresAtMilliseconds: request.expiresAtMilliseconds,
            deviceID: endpoint.id, skill: .writeSupport, skillStatus: status, prompt: prompt)
    }
    func resolveEndpoint(_ id: UUID, allowingInstalled: (String, String)? = nil) async throws -> (ResolvedDeviceSupportRequest, DeviceEndpoint) {
        let request = try checked(id), snapshot = try await inventory.snapshot()
        let (record, endpoint) = try Self.selectedEndpoint(request.endpoint.id, in: snapshot)
        try requireContract(endpoint.incarnationID == request.endpoint.incarnationID && endpoint.identity == request.endpoint.identity
            && endpoint.physicalDomainID == request.endpoint.physicalDomainID, "staleRequest")
        let current = try binding(for: endpoint)
        let installedHere = allowingInstalled.map { allowed in current?.id == allowed.0 && current?.digest == allowed.1
            && current?.selector.id == endpoint.id && current?.selector.incarnationID == endpoint.incarnationID } == true
        try requireContract(current == request.binding || installedHere, "providerChanged")
        let metadata = try registry.snapshot()
        return (ResolvedDeviceSupportRequest(schema: 1, requestID: id, expiresAtMilliseconds: request.expiresAtMilliseconds,
            deviceID: endpoint.id, category: record.kind, facts: endpoint.identity, bindingEligibility: record.bindingEligibility,
            bindingID: current?.id, activeDigest: current?.digest, registryRevision: metadata.revision, hostAPI: 1), endpoint)
    }
    public func resolve(_ id: UUID) async throws -> ResolvedDeviceSupportRequest { try await resolveEndpoint(id).0 }
}
