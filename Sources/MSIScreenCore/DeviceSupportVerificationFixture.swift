import Darwin
import Foundation

/// Explicit verifier-only execution context. This never selects a real device.
/// Native fixture code is source-reviewed user code, not an OS sandbox.
public final class DeviceSupportVerificationFixture: DeviceInventoryClient, @unchecked Sendable {
    public static let label = "ISOLATED NON-HARDWARE SUPPORT FIXTURE — not device qualification"
    public struct Reference: Codable, Sendable {
        let receiptPath: String
        public let nonce: UUID
        let receiptDigest: String
        private enum CodingKeys: String, CodingKey { case receiptPath, nonce, receiptDigest }
        init(receiptPath: String, nonce: UUID, receiptDigest: String) {
            self.receiptPath = receiptPath; self.nonce = nonce; self.receiptDigest = receiptDigest
        }
        public init(from decoder: Decoder) throws {
            try decoder.contractKeys(["receiptPath", "nonce", "receiptDigest"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            receiptPath = try c.decode(String.self, forKey: .receiptPath); nonce = try c.decode(UUID.self, forKey: .nonce)
            receiptDigest = try c.decode(String.self, forKey: .receiptDigest)
            try requireContract(contractDigest(receiptDigest), "invalidFixtureReceipt")
        }
    }
    private struct Receipt: Decodable {
        let schema: Int
        let owner: String
        let nonce: UUID
        let expiresAtMilliseconds: Int64
        let packageDigests: [String]
        let adapterDigest: String
        let bundleIdentifier: String
        private enum CodingKeys: String, CodingKey { case schema, owner, nonce, expiresAtMilliseconds, packageDigests, adapterDigest, bundleIdentifier }
        init(from decoder: Decoder) throws {
            try decoder.contractKeys(["schema", "owner", "nonce", "expiresAtMilliseconds", "packageDigests", "adapterDigest", "bundleIdentifier"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schema = try c.decode(Int.self, forKey: .schema); owner = try c.decode(String.self, forKey: .owner); nonce = try c.decode(UUID.self, forKey: .nonce)
            expiresAtMilliseconds = try c.decode(Int64.self, forKey: .expiresAtMilliseconds)
            packageDigests = try c.decode([String].self, forKey: .packageDigests); adapterDigest = try c.decode(String.self, forKey: .adapterDigest)
            bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        }
    }
    private struct Attachment: Decodable { let schema: Int; let attachment: UInt32; let connected: Bool }
    private struct StopRequest: Decodable {
        let nonce: UUID
        private enum CodingKeys: String, CodingKey { case nonce }
        init(from decoder: Decoder) throws {
            try decoder.contractKeys(["nonce"])
            nonce = try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .nonce)
        }
    }
    public let reference: Reference
    public let directory: URL
    public let registry: SupportRegistry
    public let skillsHome: URL
    public let machineRegistryURL: URL
    public let bundleIdentifier: String
    private let root: SupportDirectory
    private let receipt: Receipt
    private let inventoryIdentity: DeviceInventoryIdentity
    public convenience init(receiptPath: String, nonce: String, requireEnvironment: Bool = true) throws {
        guard let id = UUID(uuidString: nonce) else { throw DeviceContractError.invalid("invalidFixtureReceipt") }
        let (root, bytes, _) = try Self.admit(path: receiptPath, nonce: id)
        withExtendedLifetime(root) {}
        try self.init(reference: Reference(receiptPath: receiptPath, nonce: id, receiptDigest: SupportPackageContent.hash(bytes)))
        if requireEnvironment {
            try requireContract(ProcessInfo.processInfo.environment["MSI_SCREEN_SUPPORT_HOME"] == registry.home.path
                && ProcessInfo.processInfo.environment["MSI_SCREEN_AGENT_SKILLS_HOME"] == skillsHome.path, "fixtureRootMismatch")
        }
    }
    init(reference: Reference) throws {
        let (root, bytes, receipt) = try Self.admit(path: reference.receiptPath, nonce: reference.nonce)
        try requireContract(SupportPackageContent.hash(bytes) == reference.receiptDigest, "fixtureReceiptChanged")
        self.reference = reference; self.root = root; self.receipt = receipt; directory = root.url
        registry = try SupportRegistry(home: root.url.appendingPathComponent("support"))
        let key: Data
        if try registry.root.exists("identity.key") { key = try registry.existingInstallationKey() }
        else { key = try registry.installationKey() }
        inventoryIdentity = try DeviceInventoryIdentity(installationKey: key)
        skillsHome = root.url.appendingPathComponent("skills")
        machineRegistryURL = root.url.appendingPathComponent("machines.json")
        bundleIdentifier = receipt.bundleIdentifier
        _ = try root.directory("skills"); _ = try root.directory("leases")
    }
    private static func admit(path: String, nonce: UUID) throws -> (SupportDirectory, Data, Receipt) {
        let url = URL(fileURLWithPath: path), parent = url.deletingLastPathComponent()
        try requireContract(path == parent.path + "/receipt.json" && parent.deletingLastPathComponent().path == "/private/tmp"
            && parent.lastPathComponent.hasPrefix("msi-support-fixture-")
            && UUID(uuidString: String(parent.lastPathComponent.dropFirst("msi-support-fixture-".count))) != nil, "invalidFixtureReceipt")
        let root = try SupportDirectory.root(parent, create: false)
        let fd = try root.file("receipt.json"); defer { close(fd) }
        let bytes = try SupportDirectory.read(fd, limit: 16384), value = try StrictJSON.decode(Receipt.self, from: bytes)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try requireContract(value.schema == 1 && value.owner == "msi-screen-verifier-support-v1" && value.nonce == nonce
            && now < value.expiresAtMilliseconds && value.expiresAtMilliseconds - now <= 86400000
            && (1...8).contains(value.packageDigests.count) && Set(value.packageDigests).count == value.packageDigests.count
            && value.packageDigests.allSatisfy(contractDigest) && contractDigest(value.adapterDigest)
            && value.bundleIdentifier == "com.danielsivan.msi-screen.support-fixture." + nonce.uuidString.lowercased(), "invalidFixtureReceipt")
        return (root, bytes, value)
    }
    func check() throws {
        _ = try Self.admit(path: reference.receiptPath, nonce: reference.nonce)
        let digest = SupportPackageContent.hash(try read("receipt.json"))
        try requireContract(digest == reference.receiptDigest, "fixtureReceiptChanged")
    }
    private func read(_ name: String) throws -> Data {
        let fd = try root.file(name); defer { close(fd) }; return try SupportDirectory.read(fd, limit: StrictJSON.byteLimit)
    }
    public func snapshot() async throws -> DeviceInventorySnapshot { try snapshotSynchronously() }
    func snapshotSynchronously() throws -> DeviceInventorySnapshot {
        try check()
        let attachment = try StrictJSON.decode(Attachment.self, from: read("attachment.json"))
        try requireContract(attachment.schema == 1 && attachment.attachment > 0, "invalidFixtureState")
        let identity = inventoryIdentity
        let token = String(attachment.attachment)
        let endpoint = try DeviceEndpoint(kind: .hid, id: identity.token("fixture-endpoint", [token]),
            identity: DevicePassiveIdentity(transport: .bluetooth, vendorID: 65534, productID: 65264, interfaceNumber: 0, usages: [DeviceUsage(page: 1, usage: 5)]),
            physicalDomainID: identity.token("fixture-domain", [token]), incarnationID: identity.token("fixture-incarnation", [token]),
            address: .hid(registryID: UInt64(attachment.attachment), usbDeviceID: nil, interfaceID: nil))
        let record = try DeviceRecord(id: endpoint.id, displayName: Self.label, kind: .other, endpoints: [endpoint], relations: [],
            bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
        return try DeviceInventorySnapshot(checkedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000), generation: UInt64(attachment.attachment), devices: attachment.connected ? [record] : [], displays: .complete, usb: .complete, hid: .complete)
    }
    func checkedContent(_ content: SupportPackageContent) throws {
        try check()
        try requireContract(receipt.packageDigests.contains(content.digest) && content.manifest.id == "u5.fixture"
            && content.manifest.selectors.allSatisfy { $0.transport == .bluetooth && $0.vendorID == 65534 && $0.productID == 65264 }
            && content.manifest.trustedGuards.isEmpty, "invalidFixturePackage")
        if case .nativeAdapter(let executable, _, _) = content.manifest.backend {
            try requireContract(content.files[executable].map(SupportPackageContent.hash) == receipt.adapterDigest, "invalidFixturePackage")
            guard let data = content.files["fixture.json"], let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeviceContractError.invalid("invalidFixturePackage") }
            try requireContract(Set(config.keys) == ["mode", "statePath", "marker", "applyDelayMilliseconds"] && config["mode"] as? String == "normal"
                && config["statePath"] as? String == directory.appendingPathComponent("native-state.json").path
                && config["marker"] as? String == directory.appendingPathComponent("native-marker.json").path
                && config["applyDelayMilliseconds"] as? Int == 1500, "invalidFixturePackage")
        }
    }
    public func validate(source: URL, expectedDigest: String? = nil) async throws -> ValidatedSupportPackage {
        let content = try SupportPackageContent.read(SupportDirectory.root(source, create: false, managed: false))
        try checkedContent(content)
        return try await SupportPackageInstaller(registry: registry).validate(source: source, expectedDigest: expectedDigest ?? content.digest)
    }
    public func supportRequest(executable: URL? = nil) -> DeviceSupportRequest {
        DeviceSupportRequest(registry: registry, inventory: self, installer: skillInstaller(),
            source: { try AgentSkillInstallation.bundledSkill(.writeSupport, executable: executable) },
            destination: { self.skillsHome.appendingPathComponent(AgentSkill.writeSupport.rawValue) })
    }
    private func skillInstaller() -> AgentSkillInstallation {
        AgentSkillInstallation(registry: registry, trash: { url in
            // Test retirement remains within the receipt-owned root, not the user's Trash.
            let retired = try self.root.directory("retired", create: true)
            try FileManager.default.moveItem(at: url, to: retired.url.appendingPathComponent(UUID().uuidString))
        })
    }
    public func installSkill(_ skill: AgentSkill, executable: URL? = nil) throws -> AgentSkillInstallResult {
        try check()
        return try skillInstaller().install(skill: skill, source: AgentSkillInstallation.bundledSkill(skill, executable: executable), destination: skillsHome.appendingPathComponent(skill.rawValue))
    }
    public func install(source: URL, expectedDigest: String, expectedRevision: UInt64, requestID: UUID, replacement: SupportBindingReplacement?) async throws -> SupportLifecycleResult {
        let checked = try await validate(source: source, expectedDigest: expectedDigest)
        let id = replacement?.bindingID ?? ("request-" + requestID.uuidString.lowercased())
        let (_, endpoint) = try await supportRequest().resolveEndpoint(requestID, allowingInstalled: (id, expectedDigest))
        let before = try registry.snapshot()
        let after = try SupportPackageInstaller(registry: registry).activate(checked, endpoint: endpoint, bindingID: id, expectedRevision: expectedRevision,
            replacing: replacement?.expectedActiveDigest, snapshot: { try self.snapshotSynchronously() }, graph: { try USBDeviceGraph(devices: []) }, leaseDirectory: directory.appendingPathComponent("leases"))
        notify()
        return SupportLifecycleResult(schema: 1, action: "install", dryRun: false, before: before, after: after,
            preservedBindingIDs: before.bindings.filter { $0.id != replacement?.bindingID && after.bindings.contains($0) }.map(\.id), deviceVerified: false)
    }
    public func bind(packageID: String, digest: String, deviceID: String, expectedRevision: UInt64, replacement: SupportBindingReplacement? = nil, dryRun: Bool = false) throws -> SupportLifecycleResult {
        let result = try SupportPackageInstaller(registry: registry).bind(packageID: packageID, digest: digest, deviceID: deviceID, expectedRevision: expectedRevision,
            replacement: replacement, dryRun: dryRun, snapshot: { try self.snapshotSynchronously() }, graph: { try USBDeviceGraph(devices: []) }, leaseDirectory: directory.appendingPathComponent("leases"))
        if !dryRun { notify() }; return result
    }
    public func changeBinding(bindingID: String, expectedDigest: String, digest: String?, expectedRevision: UInt64, dryRun: Bool = false) throws -> SupportLifecycleResult {
        let result = try SupportPackageInstaller(registry: registry).changeBinding(bindingID: bindingID, expectedDigest: expectedDigest, digest: digest, expectedRevision: expectedRevision, dryRun: dryRun,
            snapshot: { try self.snapshotSynchronously() }, graph: { try USBDeviceGraph(devices: []) }, leaseDirectory: directory.appendingPathComponent("leases"))
        if !dryRun { notify() }; return result
    }
    public func remove(packageID: String, digest: String, expectedRevision: UInt64, dryRun: Bool = false) throws -> SupportLifecycleResult {
        try check()
        let result = try SupportPackageInstaller(registry: registry).remove(packageID: packageID, digest: digest, expectedRevision: expectedRevision, dryRun: dryRun, trash: { url in
            let retired = try self.root.directory("retired", create: true)
            try FileManager.default.moveItem(at: url, to: retired.url.appendingPathComponent(UUID().uuidString))
        })
        if !dryRun { notify() }; return result
    }
    private func notify() {
        DistributedNotificationCenter.default().postNotificationName(SupportPackageInstaller.registryDidChangeNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
    func lockRequest(_ endpoint: DeviceEndpoint, descriptor: DeviceDescriptor) throws -> DeviceResourceLock.Request {
        try DeviceResourceLock.controlRequest(endpoint, usbGraph: { try USBDeviceGraph(devices: []) }, descriptor: descriptor)
    }
    func revalidate(_ endpoint: DeviceEndpoint, content: SupportPackageContent) throws {
        try checkedContent(content); _ = try snapshotSynchronously().resolve(endpoint)
    }
    public func coordinator() throws -> DeviceControlCoordinator {
        let key = try registry.installationKey()
        let host = try AdapterHostIdentity.resolve()
        return DeviceControlCoordinator(registry: registry, key: key, resolve: { id in
            let snapshot = try self.snapshotSynchronously(), metadata = try self.registry.snapshot()
            let (_, endpoint) = try DeviceSupportRequest.selectedEndpoint(id, in: snapshot)
            let matches = metadata.bindings.filter { $0.enabled && $0.selector.physicalDomainID == endpoint.physicalDomainID }
            try requireContract(matches.count == 1, matches.isEmpty ? "unconfiguredDevice" : "providerCollision")
            let binding = matches[0]
            try requireContract(binding.selector.id == endpoint.id && binding.selector.incarnationID == endpoint.incarnationID, "staleBinding")
            let content = try SupportPackageContent.read(self.registry.root.directory("packages").directory(binding.packageID).directory(binding.digest))
            try self.checkedContent(content)
            let identity = try DeviceContractIdentity(deviceID: endpoint.id, incarnationID: endpoint.incarnationID, bindingID: binding.id, providerDigest: content.digest, domainID: endpoint.physicalDomainID)
            let runner = DeviceAdapterRunner(registry: self.registry, host: host, fixture: self.reference)
            return ResolvedDeviceControl(identity: identity, descriptor: content.manifest.descriptor, registryRevision: metadata.revision,
                lockRequest: try self.lockRequest(endpoint, descriptor: content.manifest.descriptor), lockDirectory: self.directory.appendingPathComponent("leases"),
                revalidate: { _ in
                    try self.revalidate(endpoint, content: content)
                    let current = try self.registry.snapshot(); try requireContract(current == metadata, "providerChanged")
                },
                read: { lease in
                    let result = try await runner.invoke(content: content, payload: .read(identity: identity, endpoint: endpoint, capabilityIDs: content.manifest.descriptor.capabilities.map(\.id)), timeout: 10, lease: lease)
                    guard case .read(let state) = result else { throw DeviceContractError.invalid("missingReadback") }; return state
                }, normalize: { observation, operation in
                    let result = try await runner.invoke(content: content, payload: .plan(observation: observation, operation: operation), timeout: 5)
                    guard case .plan(let normalized) = result else { throw DeviceContractError.invalid("adapterProtocolMismatch") }; return normalized
                }, apply: { plan, expected, lease in
                    let result = try await runner.invoke(content: content, payload: .apply(plan: plan, endpoint: endpoint, expected: expected), timeout: Double(plan.stages[0].budgetMilliseconds) / 1000, lease: lease)
                    guard case .apply(let evidence) = result else { throw DeviceContractError.invalid("missingReadback") }; return evidence
                }, verifyPreservation: { before, after, operation in
                    if case .profile(_, let path) = content.manifest.backend {
                        let profile = try StrictJSON.decode(HIDFeatureProfile.self, from: content.files[path]!)
                        var reports = before.preservation
                        for (id, value) in try profile.targetFields(capabilityID: operation.capabilityID, target: operation.target) {
                            let field = profile.fields.first { $0.id == id }!, reportID = String(profile.fields.first { $0.id == id }!.reportID)
                            var bytes = try HIDFeatureProfile.bytes(reports[reportID]!); try field.encode(value, into: &bytes); reports[reportID] = bytes.hex
                        }
                        try requireContract(reports == after.preservation, "fullReportMismatch")
                    } else { try requireContract(before.preservation == after.preservation, "preservationMismatch") }
                })
        })
    }
    func profileResult(request: AdapterRequest, content: SupportPackageContent) throws -> AdapterResult {
        try checkedContent(content)
        guard case .profile(_, let path) = content.manifest.backend else { throw DeviceContractError.invalid("invalidFixturePackage") }
        let profile = try StrictJSON.decode(HIDFeatureProfile.self, from: content.files[path]!)
        let identity: DeviceContractIdentity
        switch request.payload {
        case .read(let id, let endpoint, _): try revalidate(endpoint, content: content); identity = id
        case .apply(let plan, let endpoint, _): try revalidate(endpoint, content: content); identity = plan.identity
        case .selfTest: try HIDFeatureProfileExecutor.selfTest(profile: profile, descriptor: content.manifest.descriptor); return .selfTest
        case .plan(_, let operation): try content.manifest.descriptor.validate(operation: operation); return .plan(operation)
        }
        let transport = FixtureReports(root: root, check: { try self.check(); try AdapterProcessHost.checkLiveness(deadline: request.deadlineUptimeMilliseconds) })
        let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: content.manifest.descriptor, identity: identity, transport: transport)
        switch request.payload {
        case .read: return .read(try executor.read())
        case .apply(let plan, _, let expected): return .apply(try executor.apply(plan.operation, expected: expected))
        default: throw DeviceContractError.invalid("invalidFixtureRequest")
        }
    }
    /// Process lifecycle only, not a UI automation/control API. The app routes
    /// this owned request through native termination and its actual busy gate.
    public func terminationRequested() throws -> Bool {
        try check()
        guard try root.exists("stop-request.json") else { return false }
        return try StrictJSON.decode(StopRequest.self, from: read("stop-request.json")).nonce == reference.nonce
    }
    public func writeHealth(_ data: Data) throws { try check(); try requireContract(data.count <= StrictJSON.byteLimit, "invalidFixtureState"); try root.atomicWrite(data, name: "app-health.json") }
}

private final class FixtureReports: HIDFeatureTransport {
    let root: SupportDirectory
    let check: () throws -> Void
    init(root: SupportDirectory, check: @escaping () throws -> Void) { self.root = root; self.check = check }
    private func reports() throws -> [String: String] {
        try check(); let fd = try root.file("reports.json"); defer { close(fd) }
        return try StrictJSON.decode([String: String].self, from: SupportDirectory.read(fd, limit: 8192))
    }
    func get(_ report: HIDFeatureReport) throws -> [UInt8] {
        guard let value = try reports()[String(report.id)] else { throw DeviceContractError.invalid("invalidFixtureState") }
        return try HIDFeatureProfile.bytes(value)
    }
    func set(_ report: HIDFeatureReport, payload: [UInt8]) throws {
        var values = try reports(); values[String(report.id)] = payload.hex
        try root.atomicWrite(StrictJSON.canonical(values), name: "reports.json")
        let fd = try root.file("profile-writes", flags: O_WRONLY | O_APPEND | O_CREAT); defer { close(fd) }
        try SupportDirectory.write(Data([1]), to: fd)
    }
    func settle(milliseconds: Int) throws { try check(); if milliseconds > 0 { Thread.sleep(forTimeInterval: Double(milliseconds) / 1000) }; try check() }
}
