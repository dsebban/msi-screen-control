import CryptoKit
import Darwin
import Foundation
import MachO
import Security

struct SupportPackageContent: Equatable {
    let files: [String: Data]
    let manifest: SupportManifest
    let digest: String
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ files: [String: Data]) -> String {
        var hash = SHA256()
        for path in files.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            for bytes in [Data(path.utf8), files[path]!] {
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: $0) }; hash.update(data: bytes)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ directory: SupportDirectory) throws -> SupportPackageContent {
        try directory.validateMetadata()
        var files: [String: Data] = [:]; var modes: [String: mode_t] = [:]
        var folded = Set<String>(); var total = 0; var entries = 0
        func walk(_ fd: Int32, _ prefix: String, _ depth: Int) throws {
            guard depth <= 16 else { throw SupportStorageError.limitExceeded }
            let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard listing >= 0, let stream = fdopendir(listing) else {
                if listing >= 0 { close(listing) }; throw SupportStorageError.unsafeFile
            }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { throw SupportStorageError.unsafeFile }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= 1024 else { throw SupportStorageError.limitExceeded }
                let path = prefix + name
                guard SupportManifest.validRelativePath(path), folded.insert(SupportManifest.foldedPath(path)).inserted else {
                    throw SupportStorageError.unsafeFile
                }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                    throw SupportStorageError.unsafeFile
                }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                guard isDirectory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else { throw SupportStorageError.unsafeFile }
                let child = openat(fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (isDirectory ? O_DIRECTORY : 0))
                guard child >= 0 else { throw SupportStorageError.unsafeFile }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, SupportDirectory.same(info, opened) else { throw SupportStorageError.integrityChanged }
                if isDirectory {
                    guard !directory.managed || info.st_mode & 0o777 == 0o700 else { throw SupportStorageError.unsafeFile }
                    try walk(child, path + "/", depth + 1)
                }
                else {
                    guard files.count < 64 else { throw SupportStorageError.limitExceeded }
                    if fgetxattr(child, "com.apple.quarantine", nil, 0, 0, 0) >= 0 || errno != ENOATTR {
                        throw DeviceContractError.invalid("quarantinedPayload")
                    }
                    let data = try SupportDirectory.read(child, limit: min(16 * 1024 * 1024 - total, path == "manifest.json" ? 262144 : 16 * 1024 * 1024))
                    total += data.count; files[path] = data; modes[path] = info.st_mode & 0o777
                }
                var remaining = stat()
                guard fstatat(fd, name, &remaining, AT_SYMLINK_NOFOLLOW) == 0, SupportDirectory.same(opened, remaining) else {
                    throw SupportStorageError.integrityChanged
                }
            }
        }
        try walk(directory.fd, "", 1)
        guard let bytes = files["manifest.json"] else { throw DeviceContractError.invalid("missingManifest") }
        let manifest = try StrictJSON.decode(SupportManifest.self, from: bytes)
        guard Set(files.keys) == Set(manifest.files.keys).union(["manifest.json"]) else { throw DeviceContractError.invalid("payloadSet") }
        for (path, digest) in manifest.files {
            guard Self.hash(files[path]!) == digest else { throw SupportStorageError.integrityChanged }
        }
        if directory.managed {
            for (path, mode) in modes {
                let expected: mode_t
                if case .nativeAdapter(let executable, _, _) = manifest.backend, path == executable { expected = 0o500 }
                else { expected = 0o600 }
                guard mode == expected else { throw SupportStorageError.unsafeFile }
            }
        }
        return SupportPackageContent(files: files, manifest: manifest, digest: Self.digest(files))
    }
    func copy(to destination: SupportDirectory) throws {
        for path in files.keys.sorted() {
            let components = path.split(separator: "/").map(String.init)
            var parent = destination
            for name in components.dropLast() { parent = try parent.directory(name, create: true) }
            let name = components.last!
            let executable: Bool
            if case .nativeAdapter(let payload, _, _) = manifest.backend { executable = path == payload } else { executable = false }
            let fd = try parent.file(name, flags: O_WRONLY | O_CREAT | O_EXCL, mode: executable ? 0o500 : 0o600)
            defer { close(fd) }
            try SupportDirectory.write(files[path]!, to: fd)
            guard fsync(parent.fd) == 0 else { throw SupportStorageError.unsafeFile }
        }
        guard fsync(destination.fd) == 0 else { throw SupportStorageError.unsafeFile }
    }
}

public struct ValidatedSupportPackage: Sendable {
    public let manifest: SupportManifest
    public let digest: String
    let files: [String: Data]
    let host: AdapterHostIdentity
    var content: SupportPackageContent { SupportPackageContent(files: files, manifest: manifest, digest: digest) }
}

/// Validation is hardware-free on the host. Native selfTest is trusted user
/// code, not confined by the envelope or replacement environment.
public final class SupportPackageInstaller {
    let registry: SupportRegistry
    private let hostPin: Result<AdapterHostIdentity, Error>
    public init(registry: SupportRegistry) { self.registry = registry; hostPin = Result { try AdapterHostIdentity.resolve() } }
    /// Implementation readiness is not permission/architecture qualification.
    /// These release gates remain explicit until independently measured.
    public var executionReadinessGaps: [String] { ["x86_64MacOS13LifecycleUnverified", "responsibleLaunchClientUnverified"] }
    public var executionReady: Bool { executionReadinessGaps.isEmpty }

    public func validate(source: URL, expectedDigest: String? = nil) async throws -> ValidatedSupportPackage {
        do { return try await validate(source: source, expectedDigest: expectedDigest, host: hostPin.get()) }
        catch {
            // Public validation rejects malformed package contracts without
            // exporting Foundation paths, decoder context or native diagnostics.
            if DevicePublicJSON.errorCode(error) == "invalidRequest" { throw DeviceContractError.invalid("rejectedManifest") }
            throw error
        }
    }
    func validate(source: URL, expectedDigest: String? = nil, host: AdapterHostIdentity) async throws -> ValidatedSupportPackage {
        try registry.validateRoot()
        let original = try SupportDirectory.root(source, create: false, managed: false)
        let content = try SupportPackageContent.read(original)
        if let expectedDigest { guard content.digest == expectedDigest else { throw SupportStorageError.integrityChanged } }
        switch content.manifest.backend {
        case .profile(_, let path):
            do {
                let profile = try StrictJSON.decode(HIDFeatureProfile.self, from: content.files[path]!)
                try profile.validate(descriptor: content.manifest.descriptor)
            } catch { throw DeviceContractError.invalid("rejectedProfile") }
        case .nativeAdapter:
            try requireContract(content.manifest.descriptor.evidence.contains { $0.kind == .sourceReview }, "nativeSourceReviewRequired")
        }
        let result = try await DeviceAdapterRunner(registry: registry, host: host).invoke(content: content, payload: .selfTest, timeout: 5)
        guard case .selfTest = result, try SupportPackageContent.read(original) == content else { throw SupportStorageError.integrityChanged }
        return ValidatedSupportPackage(manifest: content.manifest, digest: content.digest, files: content.files, host: host)
    }

    /// Exact metadata activation, with no identity queries or backend reads.
    /// U4 resolves request handles and exposes this same primitive to clients.
    func activate(_ validated: ValidatedSupportPackage, endpoint: DeviceEndpoint, bindingID: String,
                  expectedRevision: UInt64, replacing expectedPriorDigest: String? = nil,
                  snapshot: () throws -> DeviceInventorySnapshot,
                  graph: () throws -> USBDeviceGraph, leaseDirectory: URL? = nil,
                  checkedBefore: ((SupportRegistrySnapshot) -> Void)? = nil) throws -> SupportRegistrySnapshot {
        _ = try registry.installationKey()
        try registry.validateRoot(); try validated.host.validate()
        let content = validated.content
        guard SupportPackageContent.digest(content.files) == content.digest else { throw SupportStorageError.integrityChanged }
        let registryLease = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(registryLease) {} }
        let old = try registry.snapshot()
        guard old.revision == expectedRevision else { throw SupportStorageError.revisionChanged }
        checkedBefore?(old)
        let current = try snapshot(); let selected = try current.resolve(endpoint)
        try DeviceSupportRequest.requireCompleteSources(for: selected, in: current)
        try BuiltInControlDomainCatalog.validate(content.manifest, endpoint: selected, snapshot: current)
        let domainBindings = old.bindings.filter { $0.selector.physicalDomainID == selected.physicalDomainID }
        guard domainBindings.count <= 1 else { throw DeviceContractError.invalid("providerCollision") }
        let prior = old.bindings.first { $0.id == bindingID }
        let alreadyBound = prior.map { $0.packageID == content.manifest.id && $0.digest == content.digest
            && $0.enabled && $0.selector.id == selected.id && $0.selector.incarnationID == selected.incarnationID
            && $0.selector.identity == selected.identity } == true
        guard domainBindings.allSatisfy({ $0.id == bindingID }), prior?.digest == expectedPriorDigest || (expectedPriorDigest == nil && alreadyBound) else { throw SupportStorageError.revisionChanged }
        if let prior { try requireContract(prior.selector.physicalDomainID == selected.physicalDomainID, "explicitRebindRequired") }
        let selectedRequest = try DeviceResourceLock.controlRequest(selected, usbGraph: graph, descriptor: content.manifest.descriptor)
        var requests = [selectedRequest]
        if let prior { requests += try leaseRequests(for: prior, snapshot: current, graph: graph).acquire }
        let resource = try combinedLease(requests, directory: leaseDirectory)
        defer { withExtendedLifetime(resource) {} }
        let fresh = try snapshot()
        try DeviceSupportRequest.requireCompleteSources(for: selected, in: fresh)
        _ = try fresh.resolve(selected)
        if let prior { try revalidateBinding(prior, before: current, after: fresh) }
        let packages = try registry.root.directory("packages").directory(content.manifest.id, create: true)
        if try packages.exists(content.digest) {
            guard try SupportPackageContent.read(packages.directory(content.digest)) == content else { throw SupportStorageError.integrityChanged }
        } else {
            let staging = try registry.root.directory("staging"), name = UUID().uuidString
            guard mkdirat(staging.fd, name, 0o700) == 0 else { throw SupportStorageError.unsafeFile }
            let staged = try staging.directory(name)
            defer { Self.cleanupOwned(staged, parent: staging, name: name) }
            try content.copy(to: staged); try Self.validateNative(content, directory: staged)
            guard try SupportPackageContent.read(staged) == content else { throw SupportStorageError.integrityChanged }
            guard renameatx_np(staging.fd, name, packages.fd, content.digest, UInt32(RENAME_EXCL)) == 0,
                  fsync(packages.fd) == 0 else { throw SupportStorageError.unsafeFile }
        }
        let selector = try DeviceEndpoint(kind: selected.kind, id: selected.id, identity: selected.identity,
            physicalDomainID: selected.physicalDomainID, incarnationID: selected.incarnationID, address: nil)
        let binding = try SupportBinding(id: bindingID, selector: selector, packageID: content.manifest.id, digest: content.digest, enabled: true)
        var installed = old.packages
        if !(installed[content.manifest.id] ?? []).contains(content.digest) { installed[content.manifest.id, default: []].append(content.digest); installed[content.manifest.id]!.sort() }
        var bindings = old.bindings.filter { $0.id != bindingID }; bindings.append(binding); bindings.sort { $0.id < $1.id }
        // Private lock facts let metadata disable/rollback exclude a still-running
        // worker even after its attachment disappears from passive inventory.
        try rememberLeases(binding: binding, request: selectedRequest)
        return try registry.compareAndSwap(expectedRevision: expectedRevision, packages: installed, bindings: bindings)
    }

    // Internal preparation seam, not the public install/activate API.
    @discardableResult
    func stageInactive(source: URL, expectedDigest: String, expectedRevision: UInt64,
                       afterStaging: (() throws -> Void)? = nil) throws -> SupportRegistrySnapshot {
        try registry.validateRoot()
        guard contractDigest(expectedDigest) else { throw SupportStorageError.integrityChanged }
        let original = try SupportDirectory.root(source, create: false, managed: false)
        let content = try SupportPackageContent.read(original)
        guard content.digest == expectedDigest else { throw SupportStorageError.integrityChanged }
        let staging = try registry.root.directory("staging")
        let name = UUID().uuidString
        guard mkdirat(staging.fd, name, 0o700) == 0 else { throw SupportStorageError.unsafeFile }
        let staged = try staging.directory(name)
        var published = false
        // Only this fresh directory is owned; cleanup never visits unrecognized siblings.
        defer {
            if !published {
                var named = stat(); var opened = stat()
                if fstatat(staging.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   fstat(staged.fd, &opened) == 0, named.st_ino == opened.st_ino, named.st_dev == opened.st_dev {
                    try? Self.removeOwned(staged); unlinkat(staging.fd, name, AT_REMOVEDIR)
                }
            }
        }
        try content.copy(to: staged)
        try afterStaging?()
        guard try SupportPackageContent.read(staged) == content,
              try SupportPackageContent.read(original) == content else { throw SupportStorageError.integrityChanged }
        try Self.validateNative(content, directory: staged)
        // Profile engine validation and native selfTest are deliberately NOT claimed here.
        let lock = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
        let old = try registry.snapshot()
        guard old.revision == expectedRevision else { throw SupportStorageError.revisionChanged }
        let packages = try registry.root.directory("packages")
        let package = try packages.directory(content.manifest.id, create: true)
        if try package.exists(content.digest) {
            let existing = try package.directory(content.digest)
            guard try SupportPackageContent.read(existing) == content else { throw SupportStorageError.integrityChanged }
            try Self.validateNative(content, directory: existing)
        } else {
            var named = stat(); var opened = stat()
            guard fstatat(staging.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  fstat(staged.fd, &opened) == 0, named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
                  try SupportPackageContent.read(staging.directory(name)) == content else { throw SupportStorageError.integrityChanged }
            guard renameatx_np(staging.fd, name, package.fd, content.digest, UInt32(RENAME_EXCL)) == 0 else { throw SupportStorageError.unsafeFile }
            published = true
            guard fsync(package.fd) == 0 else { throw SupportStorageError.unsafeFile }
        }
        var installed = old.packages
        if !(installed[content.manifest.id] ?? []).contains(content.digest) {
            installed[content.manifest.id, default: []].append(content.digest)
            installed[content.manifest.id]!.sort()
        }
        return try registry.compareAndSwap(expectedRevision: expectedRevision, packages: installed, bindings: old.bindings)
    }
    static func cleanupOwned(_ directory: SupportDirectory, parent: SupportDirectory, name: String) {
        var named = stat(); var opened = stat()
        guard fstatat(parent.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(directory.fd, &opened) == 0,
              named.st_ino == opened.st_ino, named.st_dev == opened.st_dev else { return }
        if (try? removeOwned(directory)) != nil { _ = unlinkat(parent.fd, name, AT_REMOVEDIR) }
    }
    private static func removeOwned(_ directory: SupportDirectory) throws {
        // Caller verifies the unique staging name still identifies this owned directory.
        let listing = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0, let stream = fdopendir(listing) else { throw SupportStorageError.unsafeFile }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid() else { throw SupportStorageError.unsafeFile }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = try directory.directory(name); try removeOwned(child)
                guard unlinkat(directory.fd, name, AT_REMOVEDIR) == 0 else { throw SupportStorageError.unsafeFile }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                      unlinkat(directory.fd, name, 0) == 0 else { throw SupportStorageError.unsafeFile }
            }
        }
    }
    static func validateNative(_ content: SupportPackageContent, directory: SupportDirectory) throws {
        guard case .nativeAdapter(let path, let architectures, let minimum) = content.manifest.backend else { return }
        #if arch(arm64)
        let host: SupportArchitecture = .arm64
        #else
        let host: SupportArchitecture = .x86_64
        #endif
        guard architectures.contains(host) else { throw DeviceContractError.invalid("missingNativeSlice") }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = os.majorVersion * 65536 + os.minorVersion * 256 + os.patchVersion
        // Never compactMap numeric components: overflow must reject the whole
        // version, not silently turn e.g. 1.<overflow>.0 into 1.0.
        let components = minimum.split(separator: ".", omittingEmptySubsequences: false)
        let parts = try components.map { component -> Int in
            guard let value = Int(component) else { throw DeviceContractError.invalid("minimumMacOS") }
            return value
        }
        guard (2...3).contains(parts.count), (0...65535).contains(parts[0]),
              parts.dropFirst().allSatisfy({ (0...255).contains($0) }) else { throw DeviceContractError.invalid("minimumMacOS") }
        let declaredMinimum = parts[0] * 65536 + parts[1] * 256 + (parts.count > 2 ? parts[2] : 0)
        guard declaredMinimum <= current else { throw DeviceContractError.invalid("minimumMacOS") }
        let slices = try SupportMachO.validate(content.files[path]!, currentOS: current, declaredMinimum: declaredMinimum)
        guard Set(architectures).isSubset(of: slices), slices.contains(host) else { throw DeviceContractError.invalid("missingNativeSlice") }
        let url = directory.url.appendingPathComponent(path)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw DeviceContractError.invalid("invalidSignature")
        }
        guard try SupportPackageContent.read(directory) == content else { throw SupportStorageError.integrityChanged }
    }
}

public struct SupportBindingReplacement: Sendable {
    public let bindingID: String
    public let expectedActiveDigest: String
    public init(bindingID: String, expectedActiveDigest: String) throws {
        try requireContract(contractID(bindingID) && contractDigest(expectedActiveDigest), "invalidReplacement")
        self.bindingID = bindingID; self.expectedActiveDigest = expectedActiveDigest
    }
}
public struct SupportLifecycleResult: Codable, Equatable, Sendable {
    public let schema: Int
    public let action: String
    public let dryRun: Bool
    public let before: SupportRegistrySnapshot
    public let after: SupportRegistrySnapshot
    public let preservedBindingIDs: [String]
    public let deviceVerified: Bool
}
public struct SupportPackageStatus: Codable, Sendable {
    public let packageID: String
    public let digest: String
    public let status: String
    public let reason: String?
}
public struct SupportPackageListing: Codable, Sendable {
    public let schema: Int
    public let registry: SupportRegistrySnapshot
    public let packages: [SupportPackageStatus]
    public let executionReady: Bool
    public let executionReadinessGaps: [String]
}

extension SupportPackageInstaller {
    public static let registryDidChangeNotification = Notification.Name("com.danielsivan.msi-screen.support-registry-changed")
    private func published(_ result: SupportLifecycleResult) -> SupportLifecycleResult {
        if !result.dryRun && result.before != result.after {
            // Hints only; clients must reload checked metadata before use.
            DistributedNotificationCenter.default().postNotificationName(Self.registryDidChangeNotification,
                object: nil, userInfo: nil, deliverImmediately: true)
        }
        return result
    }
    private struct BindingLeases: Codable {
        let domains: [String]
        let controller: Bool
        let rapoo: Bool
        private enum CodingKeys: String, CodingKey { case domains, controller, rapoo }
        init(_ request: DeviceResourceLock.Request) throws {
            domains = request.domains; controller = request.controller; rapoo = request.rapoo
            try validate()
        }
        init(from decoder: Decoder) throws {
            try decoder.contractKeys(["domains", "controller", "rapoo"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domains = try c.decode([String].self, forKey: .domains); controller = try c.decode(Bool.self, forKey: .controller)
            rapoo = try c.decode(Bool.self, forKey: .rapoo)
            try validate()
        }
        private func validate() throws {
            try requireContract(domains.count <= 128 && Set(domains).count == domains.count
                && domains.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }, "invalidBindingLeases")
        }
        var request: DeviceResourceLock.Request { .init(domains: domains, controller: controller, rapoo: rapoo) }
        func encoded() throws -> Data {
            let data = try StrictJSON.canonical(self)
            try requireContract(data.count <= 32768, "invalidBindingLeases")
            return data
        }
    }
    private func leaseName(_ binding: SupportBinding) throws -> String {
        SupportPackageContent.hash(try StrictJSON.canonical(binding.selector)) + ".json"
    }
    private func rememberLeases(binding: SupportBinding, request: DeviceResourceLock.Request) throws {
        let facts = try BindingLeases(request).encoded()
        let directory = try registry.root.directory("binding-leases", create: true)
        try directory.atomicWrite(facts, name: leaseName(binding))
    }
    private func retained(_ packageID: String, digest: String, metadata: SupportRegistrySnapshot) throws -> SupportPackageContent {
        try requireContract(SupportRegistry.validPackageID(packageID) && contractDigest(digest)
            && metadata.packages[packageID]?.contains(digest) == true, "missingRetainedPackage")
        let directory = try registry.root.directory("packages").directory(packageID).directory(digest)
        let content = try SupportPackageContent.read(directory)
        try requireContract(content.manifest.id == packageID && content.digest == digest, "providerDigestChanged")
        if case .profile(_, let path) = content.manifest.backend {
            try StrictJSON.decode(HIDFeatureProfile.self, from: content.files[path]!).validate(descriptor: content.manifest.descriptor)
        }
        try Self.validateNative(content, directory: directory)
        return content
    }
    public func descriptor(packageID: String, digest: String) throws -> DeviceDescriptor {
        try retained(packageID, digest: digest, metadata: registry.snapshot()).manifest.descriptor
    }
    public func list() throws -> SupportPackageListing {
        let metadata = try registry.snapshot()
        var statuses: [SupportPackageStatus] = []
        // Enumerate only managed package namespaces, never source/authoring trees.
        let packages = try registry.root.directory("packages")
        func names(_ directory: SupportDirectory) throws -> [String] {
            let fd = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw SupportStorageError.unsafeFile }
            guard let stream = fdopendir(fd) else { close(fd); throw SupportStorageError.unsafeFile }
            defer { closedir(stream) }; var result: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                guard result.count < 4096 else { throw SupportStorageError.limitExceeded }; result.append(name)
            }
            return result.sorted()
        }
        var all = metadata.packages
        for id in try names(packages) where SupportRegistry.validPackageID(id) {
            if let directory = try? packages.directory(id) {
                for digest in try names(directory) where contractDigest(digest) {
                    if !(all[id] ?? []).contains(digest) { all[id, default: []].append(digest) }
                }
            }
        }
        for id in all.keys.sorted() {
            for digest in all[id]!.sorted() {
                let referenced = metadata.packages[id]?.contains(digest) == true
                do {
                    if referenced { _ = try retained(id, digest: digest, metadata: metadata) }
                    else {
                        let content = try SupportPackageContent.read(packages.directory(id).directory(digest))
                        try requireContract(content.digest == digest && content.manifest.id == id, "providerDigestChanged")
                    }
                    statuses.append(SupportPackageStatus(packageID: id, digest: digest, status: referenced ? "validatedRetained" : "inertOrphan", reason: nil))
                } catch {
                    statuses.append(SupportPackageStatus(packageID: id, digest: digest, status: "damagedInactive", reason: DevicePublicJSON.errorCode(error)))
                }
            }
        }
        return SupportPackageListing(schema: 1, registry: metadata, packages: statuses, executionReady: executionReady, executionReadinessGaps: executionReadinessGaps)
    }
    public func install(source: URL, expectedDigest: String, expectedRevision: UInt64, requestID: UUID,
                        replacement: SupportBindingReplacement? = nil) async throws -> SupportLifecycleResult {
        let request = try DeviceSupportRequest(registry: registry)
        let validated = try await validate(source: source, expectedDigest: expectedDigest)
        let bindingID = replacement?.bindingID ?? ("request-" + requestID.uuidString.lowercased())
        let (_, endpoint) = try await request.resolveEndpoint(requestID, allowingInstalled: (bindingID, expectedDigest))
        let reader = MacDeviceInventoryReader(identity: try DeviceInventoryIdentity(installationKey: registry.installationKey()))
        var before: SupportRegistrySnapshot?
        let after = try activate(validated, endpoint: endpoint, bindingID: bindingID, expectedRevision: expectedRevision,
            replacing: replacement?.expectedActiveDigest, snapshot: { try reader.snapshotSynchronously() }, graph: { try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB()) },
            checkedBefore: { before = $0 })
        guard let before else { throw SupportStorageError.corruptRegistry }
        return published(result("install", dryRun: false, before: before, after: after, replacing: replacement?.bindingID))
    }
    private func result(_ action: String, dryRun: Bool, before: SupportRegistrySnapshot, after: SupportRegistrySnapshot, replacing: String? = nil) -> SupportLifecycleResult {
        SupportLifecycleResult(schema: 1, action: action, dryRun: dryRun, before: before, after: after,
            preservedBindingIDs: before.bindings.filter { $0.id != replacing && after.bindings.contains($0) }.map(\.id), deviceVerified: false)
    }
    public func bind(packageID: String, digest: String, deviceID: String, expectedRevision: UInt64,
                     replacement: SupportBindingReplacement? = nil, dryRun: Bool = false) async throws -> SupportLifecycleResult {
        let reader = MacDeviceInventoryReader(identity: try DeviceInventoryIdentity(installationKey: registry.installationKey()))
        return try published(bind(packageID: packageID, digest: digest, deviceID: deviceID, expectedRevision: expectedRevision,
            replacement: replacement, dryRun: dryRun, snapshot: { try reader.snapshotSynchronously() }, graph: { try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB()) }))
    }
    func bind(packageID: String, digest: String, deviceID: String, expectedRevision: UInt64,
              replacement: SupportBindingReplacement? = nil, dryRun: Bool = false, snapshot: () throws -> DeviceInventorySnapshot,
              graph: () throws -> USBDeviceGraph, leaseDirectory: URL? = nil) throws -> SupportLifecycleResult {
        let lock = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
        let before = try registry.snapshot(); try requireContract(before.revision == expectedRevision, "registryChanged")
        let content = try retained(packageID, digest: digest, metadata: before)
        let current = try snapshot(), (_, endpoint) = try DeviceSupportRequest.selectedEndpoint(deviceID, in: current)
        try BuiltInControlDomainCatalog.validate(content.manifest, endpoint: endpoint, snapshot: current)
        let prior = replacement.flatMap { replacement in before.bindings.first { $0.id == replacement.bindingID } }
            ?? (replacement == nil ? before.bindings.first { $0.enabled && $0.packageID == packageID && $0.digest == digest
                && $0.selector.id == endpoint.id && $0.selector.incarnationID == endpoint.incarnationID && $0.selector.identity == endpoint.identity } : nil)
        if let replacement { try requireContract(prior?.digest == replacement.expectedActiveDigest, "providerChanged") }
        let domainBindings = before.bindings.filter { $0.selector.physicalDomainID == endpoint.physicalDomainID && $0.id != prior?.id }
        try requireContract(domainBindings.isEmpty, "providerCollision")
        let request = try DeviceResourceLock.controlRequest(endpoint, usbGraph: graph, descriptor: content.manifest.descriptor)
        var requests = [request]
        if let prior { requests += try leaseRequests(for: prior, snapshot: current, graph: graph).acquire }
        _ = try BindingLeases(request).encoded() // Dry-run validates the exact facts real publication would retain.
        let resource = try combinedLease(requests, directory: leaseDirectory); defer { withExtendedLifetime(resource) {} }
        let fresh = try snapshot()
        try DeviceSupportRequest.requireCompleteSources(for: endpoint, in: fresh)
        _ = try fresh.resolve(endpoint)
        if let prior { try revalidateBinding(prior, before: current, after: fresh) }
        let selector = try DeviceEndpoint(kind: endpoint.kind, id: endpoint.id, identity: endpoint.identity, physicalDomainID: endpoint.physicalDomainID,
            incarnationID: endpoint.incarnationID, address: nil)
        // Stable id makes a repeated exact bind an idempotent no-op without guessing an endpoint.
        let id = prior?.id ?? ("binding-" + String(SupportPackageContent.hash(Data((packageID + digest + endpoint.id + endpoint.incarnationID).utf8)).prefix(48)))
        let binding = try SupportBinding(id: id, selector: selector, packageID: packageID, digest: digest, enabled: true)
        var bindings = before.bindings.filter { $0.id != id }; bindings.append(binding); bindings.sort { $0.id < $1.id }
        let after = try prospective(before, packages: before.packages, bindings: bindings)
        if !dryRun {
            try rememberLeases(binding: binding, request: request)
            _ = try registry.compareAndSwap(expectedRevision: expectedRevision, packages: after.packages, bindings: after.bindings)
        }
        return result("bind", dryRun: dryRun, before: before, after: after, replacing: prior?.id)
    }
    private func prospective(_ before: SupportRegistrySnapshot, packages: [String: [String]], bindings: [SupportBinding]) throws -> SupportRegistrySnapshot {
        if before.packages == packages && before.bindings == bindings { return before }
        try requireContract(before.revision < UInt64.max, "registryFull")
        return try SupportRegistrySnapshot(revision: before.revision + 1, packages: packages, bindings: bindings)
    }
    private func combinedRequest(_ requests: [DeviceResourceLock.Request]) -> DeviceResourceLock.Request {
        .init(domains: requests.flatMap(\.domains), controller: requests.contains { $0.controller }, rapoo: requests.contains { $0.rapoo })
    }
    private func combinedLease(_ requests: [DeviceResourceLock.Request], directory: URL?) throws -> DeviceResourceLock {
        try DeviceResourceLock(combinedRequest(requests), directory: directory)
    }
    private func leaseRequests(for binding: SupportBinding, snapshot: DeviceInventorySnapshot,
                               graph: () throws -> USBDeviceGraph) throws -> (acquire: [DeviceResourceLock.Request], retain: [DeviceResourceLock.Request]) {
        try DeviceSupportRequest.requireCompleteSources(for: binding.selector, in: snapshot)
        var remembered: [DeviceResourceLock.Request] = []
        if let directory = try? registry.root.directory("binding-leases"), try directory.exists(leaseName(binding)) {
            let fd = try directory.file(leaseName(binding)); defer { close(fd) }
            remembered.append(try StrictJSON.decode(BindingLeases.self, from: SupportDirectory.read(fd, limit: 32768)).request)
        }
        let matches = snapshot.devices.flatMap(\.endpoints).filter { $0.physicalDomainID == binding.selector.physicalDomainID }
        var current: [DeviceResourceLock.Request] = []
        for endpoint in matches {
            if let content = try? retained(binding.packageID, digest: binding.digest, metadata: registry.snapshot()) {
                current.append(try DeviceResourceLock.controlRequest(endpoint, usbGraph: graph, descriptor: content.manifest.descriptor))
            } else {
                // A damaged package must still be disableable. Reserve both
                // legacy domains conservatively rather than interpreting it.
                let selected = try DeviceResourceLock.selectedRequest(endpoint, usbGraph: graph)
                current.append(.init(domains: selected.domains, controller: true, rapoo: true))
            }
        }
        try requireContract(!remembered.isEmpty || !current.isEmpty, "unavailableBindingLeases")
        // Old aliases remain acquired through publication, but are not history
        // to accumulate forever. Disconnected bindings keep their checked facts.
        let configuration = DeviceResourceLock.configurationRequest(binding.selector)
        return (remembered + current + [configuration], (current.isEmpty ? remembered : current) + [configuration])
    }
    private func revalidateBinding(_ binding: SupportBinding, before: DeviceInventorySnapshot, after: DeviceInventorySnapshot) throws {
        try DeviceSupportRequest.requireCompleteSources(for: binding.selector, in: before)
        try DeviceSupportRequest.requireCompleteSources(for: binding.selector, in: after)
        let beforeEndpoints = before.devices.flatMap(\.endpoints).filter { $0.physicalDomainID == binding.selector.physicalDomainID }
        let afterEndpoints = after.devices.flatMap(\.endpoints).filter { $0.physicalDomainID == binding.selector.physicalDomainID }
        try requireContract(beforeEndpoints == afterEndpoints, "staleEndpoint")
    }
    public func disable(bindingID: String, expectedDigest: String, expectedRevision: UInt64, dryRun: Bool = false) async throws -> SupportLifecycleResult {
        try await published(changeBinding(bindingID: bindingID, expectedDigest: expectedDigest, digest: nil, expectedRevision: expectedRevision, dryRun: dryRun))
    }
    public func activate(bindingID: String, digest: String, expectedActiveDigest: String, expectedRevision: UInt64, dryRun: Bool = false) async throws -> SupportLifecycleResult {
        try await published(changeBinding(bindingID: bindingID, expectedDigest: expectedActiveDigest, digest: digest, expectedRevision: expectedRevision, dryRun: dryRun))
    }
    private func changeBinding(bindingID: String, expectedDigest: String, digest: String?, expectedRevision: UInt64, dryRun: Bool) async throws -> SupportLifecycleResult {
        let reader = MacDeviceInventoryReader(identity: try DeviceInventoryIdentity(installationKey: registry.installationKey()))
        return try changeBinding(bindingID: bindingID, expectedDigest: expectedDigest, digest: digest, expectedRevision: expectedRevision, dryRun: dryRun,
            snapshot: { try reader.snapshotSynchronously() }, graph: { try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB()) })
    }
    func changeBinding(bindingID: String, expectedDigest: String, digest: String?, expectedRevision: UInt64, dryRun: Bool,
                       snapshot: () throws -> DeviceInventorySnapshot, graph: () throws -> USBDeviceGraph, leaseDirectory: URL? = nil) throws -> SupportLifecycleResult {
        let lock = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
        let before = try registry.snapshot()
        try requireContract(before.revision == expectedRevision, "registryChanged")
        guard let old = before.bindings.first(where: { $0.id == bindingID }), old.digest == expectedDigest else { throw DeviceContractError.invalid("providerChanged") }
        if digest != nil {
            try requireContract(!before.bindings.contains { $0.id != old.id && $0.enabled && $0.selector.physicalDomainID == old.selector.physicalDomainID }, "providerCollision")
        }
        let current = try snapshot()
        let facts = try leaseRequests(for: old, snapshot: current, graph: graph)
        var requests = facts.acquire, retainedRequests = facts.retain
        if let digest {
            let content = try retained(old.packageID, digest: digest, metadata: before)
            try BuiltInControlDomainCatalog.validate(content.manifest, endpoint: old.selector, snapshot: current)
            let matches = current.devices.flatMap(\.endpoints).filter { $0.id == old.selector.id }
            try requireContract(matches.count <= 1, "ambiguousEndpoint")
            if let selected = matches.first {
                try BuiltInControlDomainCatalog.validate(content.manifest, endpoint: selected, snapshot: current)
                let request = try DeviceResourceLock.controlRequest(selected, usbGraph: graph, descriptor: content.manifest.descriptor)
                requests.append(request); retainedRequests = [request]
            } else {
                // Static protection and the new descriptor's compatibility
                // domains remain checkable without inventing an attachment.
                try content.manifest.validate()
                let declared = try DeviceResourceLock.controlRequest(old.selector, usbGraph: graph, descriptor: content.manifest.descriptor)
                let compatibility = DeviceResourceLock.Request(domains: [], controller: declared.controller, rapoo: declared.rapoo)
                requests.append(compatibility); retainedRequests.append(compatibility)
            }
        }
        let retainedRequest = combinedRequest(retainedRequests)
        _ = try BindingLeases(retainedRequest).encoded()
        let resource = try combinedLease(requests, directory: leaseDirectory); defer { withExtendedLifetime(resource) {} }
        let fresh = try snapshot()
        try revalidateBinding(old, before: current, after: fresh)
        let replacement = try SupportBinding(id: old.id, selector: old.selector, packageID: old.packageID, digest: digest ?? old.digest, enabled: digest != nil)
        let bindings = before.bindings.map { $0.id == old.id ? replacement : $0 }
        let after = try prospective(before, packages: before.packages, bindings: bindings)
        if !dryRun {
            try rememberLeases(binding: replacement, request: retainedRequest)
            _ = try registry.compareAndSwap(expectedRevision: expectedRevision, packages: after.packages, bindings: after.bindings)
        }
        return result(digest == nil ? "disable" : "activate", dryRun: dryRun, before: before, after: after, replacing: old.id)
    }
    public func remove(packageID: String, digest: String, expectedRevision: UInt64, dryRun: Bool = false) throws -> SupportLifecycleResult {
        try published(remove(packageID: packageID, digest: digest, expectedRevision: expectedRevision, dryRun: dryRun,
            trash: { _ = try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }))
    }
    func remove(packageID: String, digest: String, expectedRevision: UInt64, dryRun: Bool,
                trash: (URL) throws -> Void) throws -> SupportLifecycleResult {
        let lock = try registry.root.lock("registry.lock"); defer { withExtendedLifetime(lock) {} }
        let before = try registry.snapshot(); try requireContract(before.revision == expectedRevision, "registryChanged")
        try requireContract(!before.bindings.contains { $0.packageID == packageID && $0.digest == digest }, "referencedPackage")
        _ = try retained(packageID, digest: digest, metadata: before)
        var packages = before.packages; packages[packageID]?.removeAll { $0 == digest }
        if packages[packageID]?.isEmpty == true { packages.removeValue(forKey: packageID) }
        let after = try prospective(before, packages: packages, bindings: before.bindings)
        if !dryRun {
            let parent = try registry.root.directory("packages").directory(packageID), staging = try registry.root.directory("staging")
            let name = "removed-" + UUID().uuidString
            guard renameatx_np(parent.fd, digest, staging.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw SupportStorageError.unsafeFile }
            do { _ = try registry.compareAndSwap(expectedRevision: expectedRevision, packages: after.packages, bindings: after.bindings) }
            catch { _ = renameatx_np(staging.fd, name, parent.fd, digest, UInt32(RENAME_EXCL)); throw error }
            guard fsync(parent.fd) == 0, fsync(staging.fd) == 0 else { throw SupportStorageError.unsafeFile }
            try trash(staging.url.appendingPathComponent(name))
        }
        return result("remove", dryRun: dryRun, before: before, after: after)
    }
}

/// Inspect every slice and load command. Only the OS's absolute library namespace
/// is trusted (including its transitive dependencies in the signed shared cache).
/// Package-local/user @loader_path/@executable_path and escaping @rpath are refused.
enum SupportMachO {
    static func validate(_ data: Data, currentOS: Int, declaredMinimum: Int? = nil) throws -> Set<SupportArchitecture> {
        var visited = Set<String>()
        return try validateImage(data, currentOS: currentOS, declaredMinimum: declaredMinimum, executable: true, visited: &visited)
    }
    private static func validateImage(_ data: Data, currentOS: Int, declaredMinimum: Int?, executable: Bool,
                                      visited: inout Set<String>) throws -> Set<SupportArchitecture> {
        let b = [UInt8](data)
        func word(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= b.count - 4 else { throw DeviceContractError.invalid("machO") }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[offset + $1]) << UInt32((big ? 3 - $1 : $1) * 8) }
        }
        func system(_ path: String) -> Bool {
            (path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/"))
                && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) && !path.contains("\0")
        }
        var ranges: [(Int, Int)] = []
        if try word(0, big: true) == 0xcafebabe {
            let count = Int(try word(4, big: true)); guard (1...8).contains(count) else { throw DeviceContractError.invalid("machO") }
            for i in 0..<count {
                let offset = Int(try word(8 + i * 20 + 8, big: true)), size = Int(try word(8 + i * 20 + 12, big: true))
                guard offset >= 8 + count * 20, size >= 32, offset <= b.count - size,
                      !ranges.contains(where: { offset < $0.0 + $0.1 && $0.0 < offset + size }) else { throw DeviceContractError.invalid("machO") }
                ranges.append((offset, size))
            }
        } else { ranges = [(0, b.count)] }
        var result = Set<SupportArchitecture>()
        for (base, size) in ranges {
            guard try word(base) == 0xfeedfacf, try word(base + 12) == (executable ? 2 : 6) else { throw DeviceContractError.invalid("nativeExecutable") }
            let cpu = try word(base + 4)
            guard let arch: SupportArchitecture = cpu == 0x0100000c ? .arm64 : (cpu == 0x01000007 ? .x86_64 : nil), result.insert(arch).inserted else {
                throw DeviceContractError.invalid("nativeArchitecture")
            }
            let count = Int(try word(base + 16)), bytes = Int(try word(base + 20))
            guard count <= 4096, size >= 32, bytes <= size - 32 else { throw DeviceContractError.invalid("machO") }
            var cursor = base + 32; let end = cursor + bytes
            var libraries: [String] = []; var rpaths: [String] = []; var osMinimum: Int?
            for _ in 0..<count {
                let command = try word(cursor), length = Int(try word(cursor + 4))
                guard length >= 8, cursor <= end - length else { throw DeviceContractError.invalid("machO") }
                if [UInt32(0xc), 0x80000018, 0x8000001f, 0x20, 0x80000023, 0x8000001c, 0xe].contains(command) {
                    let start = Int(try word(cursor + 8))
                    guard start >= 12, start < length,
                          let nul = b[(cursor + start)..<(cursor + length)].firstIndex(of: 0),
                          let path = String(bytes: b[(cursor + start)..<nul], encoding: .utf8) else { throw DeviceContractError.invalid("machOPath") }
                    if command == 0x8000001c { rpaths.append(path) }
                    else if command == 0xe { guard path == "/usr/lib/dyld" else { throw DeviceContractError.invalid("dynamicLinker") } }
                    else { libraries.append(path) }
                }
                if command == 0x27 { throw DeviceContractError.invalid("dynamicEnvironment") }
                if command == 0x32 {
                    guard length >= 24, try word(cursor + 8) == 1 else { throw DeviceContractError.invalid("nativePlatform") }
                    osMinimum = Int(try word(cursor + 12))
                } else if command == 0x24 { guard length >= 16 else { throw DeviceContractError.invalid("machO") }; osMinimum = Int(try word(cursor + 8)) }
                cursor += length
            }
            guard cursor == end, let osMinimum, osMinimum <= min(currentOS, declaredMinimum ?? currentOS), rpaths.allSatisfy(system) else {
                throw DeviceContractError.invalid("nativeDependenciesOrOS")
            }
            for library in libraries {
                let candidates = library.hasPrefix("@rpath/") ? rpaths.map { $0 + "/" + library.dropFirst(7) } : [library]
                guard !candidates.isEmpty, candidates.allSatisfy(system) else { throw DeviceContractError.invalid("nativeDependenciesOrOS") }
                var found = false
                for candidate in candidates {
                    if _dyld_shared_cache_contains_path(candidate) {
                        // The OS owns the signed cache and its closed transitive graph.
                        found = true; break
                    }
                    guard let bytes = try systemLibrary(candidate) else { continue }
                    if visited.insert(candidate).inserted {
                        guard visited.count <= 128 else { throw DeviceContractError.invalid("nativeDependenciesOrOS") }
                        _ = try validateImage(bytes, currentOS: currentOS, declaredMinimum: nil, executable: false, visited: &visited)
                    }
                    found = true; break
                }
                guard found else { throw DeviceContractError.invalid("nativeDependenciesOrOS") }
            }
        }
        return result
    }
    private static func systemLibrary(_ path: String) throws -> Data? {
        // Non-cache dependencies must also be real root-owned no-follow images;
        // merely spelling /usr/lib/nonexistent.dylib is not validation.
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw DeviceContractError.invalid("nativeDependenciesOrOS") }
        defer { close(current) }
        let components = path.split(separator: "/").map(String.init)
        for (index, name) in components.enumerated() {
            let last = index == components.count - 1
            let next = openat(current, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (last ? 0 : O_DIRECTORY))
            if next < 0 && errno == ENOENT { return nil }
            guard next >= 0 else { throw DeviceContractError.invalid("nativeDependenciesOrOS") }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == (last ? S_IFREG : S_IFDIR) else { close(next); throw DeviceContractError.invalid("nativeDependenciesOrOS") }
            close(current); current = next
        }
        return try SupportDirectory.read(current, limit: 64 * 1024 * 1024)
    }
}
