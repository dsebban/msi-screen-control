import CryptoKit
import Darwin
import Foundation

public enum SupportStorageError: Error, Equatable {
    case unavailableRoot, unsafeFile, busy, corruptKey, corruptRegistry, revisionChanged, integrityChanged, limitExceeded
    case validationPending
}

/// All paths below a managed root are opened relative to checked directory descriptors.
/// Never repair permissions/ownership on preexisting state, including corrupt keys.
final class SupportDirectory {
    let fd: Int32
    let url: URL
    let managed: Bool
    init(fd: Int32, url: URL, managed: Bool = true) { self.fd = fd; self.url = url; self.managed = managed }
    func validateMetadata() throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              managed ? info.st_mode & 0o777 == 0o700 : info.st_mode & 0o022 == 0 else { throw SupportStorageError.unsafeFile }
    }
    deinit { close(fd) }

    static func root(_ url: URL, create: Bool = true, managed: Bool = true) throws -> SupportDirectory {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), path != "/", !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw SupportStorageError.unavailableRoot
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw SupportStorageError.unavailableRoot }
        defer { if current >= 0 { close(current) } }
        let components = path.split(separator: "/").map(String.init)
        for (index, name) in components.enumerated() {
            let last = index == components.count - 1
            if create {
                if mkdirat(current, name, 0o700) == 0 {
                    guard fsync(current) == 0 else { throw SupportStorageError.unavailableRoot }
                } else if errno != EEXIST { throw SupportStorageError.unavailableRoot }
            }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw SupportStorageError.unavailableRoot }
            var info = stat()
            let valid = fstat(next, &info) == 0 && (info.st_uid == getuid() || (!last && info.st_uid == 0))
                && (last && managed ? info.st_mode & 0o777 == 0o700 :
                    (info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0)))
            guard valid else { close(next); throw SupportStorageError.unavailableRoot }
            close(current); current = next
        }
        let result = SupportDirectory(fd: current, url: url, managed: managed); current = -1
        return result
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    func directory(_ name: String, create: Bool = false) throws -> SupportDirectory {
        try validateMetadata()
        guard Self.validName(name) else { throw SupportStorageError.unsafeFile }
        if create {
            if mkdirat(fd, name, 0o700) == 0 {
                guard fsync(fd) == 0 else { throw SupportStorageError.unsafeFile }
            } else if errno != EEXIST { throw SupportStorageError.unsafeFile }
        }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { throw SupportStorageError.unsafeFile }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(child); throw SupportStorageError.unsafeFile
        }
        return SupportDirectory(fd: child, url: url.appendingPathComponent(name, isDirectory: true))
    }
    func file(_ name: String, flags: Int32 = O_RDONLY, mode: mode_t = 0o600, exactMode: Bool = true) throws -> Int32 {
        try validateMetadata()
        guard Self.validName(name) else { throw SupportStorageError.unsafeFile }
        let child = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
        guard child >= 0 else { throw SupportStorageError.unsafeFile }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), (exactMode ? info.st_mode & 0o777 == mode : info.st_mode & 0o022 == 0) else {
            close(child); throw SupportStorageError.unsafeFile
        }
        return child
    }
    func exists(_ name: String) throws -> Bool {
        guard Self.validName(name) else { throw SupportStorageError.unsafeFile }
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw SupportStorageError.unsafeFile }
        return false
    }
    static func read(_ fd: Int32, limit: Int) throws -> Data {
        var before = stat(); var after = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= limit,
              lseek(fd, 0, SEEK_SET) == 0 else { throw SupportStorageError.limitExceeded }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - bytes.count))
            if count < 0 { if errno == EINTR { continue }; throw SupportStorageError.unsafeFile }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= limit else { throw SupportStorageError.limitExceeded }
        }
        guard fstat(fd, &after) == 0, same(before, after), bytes.count == before.st_size else {
            throw SupportStorageError.integrityChanged
        }
        return bytes
    }
    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode
            && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SupportStorageError.unsafeFile }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SupportStorageError.unsafeFile }
    }
    func atomicWrite(_ data: Data, name: String) throws {
        // Validate an existing destination too: rename must not silently repair an unfamiliar object.
        if try exists(name) { let old = try file(name); close(old) }
        let temporary = ".write-" + UUID().uuidString
        let output = try file(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(output); unlinkat(fd, temporary, 0) }
        try Self.write(data, to: output)
        guard renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else { throw SupportStorageError.unsafeFile }
    }
    func lock(_ name: String) throws -> SupportFileLease {
        let descriptor: Int32
        do { descriptor = try file(name, flags: O_RDWR | O_CREAT | O_EXCL) }
        catch {
            guard errno == EEXIST else { throw error }
            descriptor = try file(name, flags: O_RDWR)
        }
        return try SupportFileLease(descriptor: descriptor)
    }
}

final class SupportFileLease {
    let descriptor: Int32
    init(descriptor: Int32) throws {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw SupportStorageError.busy }
        self.descriptor = descriptor
    }
    deinit { close(descriptor) } // No LOCK_UN: inherited copies must keep the same open description locked.
}

public struct SupportBinding: Codable, Equatable, Sendable {
    public let id: String
    public let selector: DeviceEndpoint
    public let packageID: String
    public let digest: String
    public let enabled: Bool
    public init(id: String, selector: DeviceEndpoint, packageID: String, digest: String, enabled: Bool) throws {
        self.id = id; self.selector = selector; self.packageID = packageID; self.digest = digest; self.enabled = enabled
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, selector, packageID, digest, enabled }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "selector", "packageID", "digest", "enabled"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); selector = try c.decode(DeviceEndpoint.self, forKey: .selector)
        packageID = try c.decode(String.self, forKey: .packageID); digest = try c.decode(String.self, forKey: .digest)
        enabled = try c.decode(Bool.self, forKey: .enabled); try validate()
    }
    func validate() throws {
        try selector.validate()
        try requireContract(contractID(id) && SupportRegistry.validPackageID(packageID) && contractDigest(digest), "binding")
    }
}

public struct SupportRegistrySnapshot: Codable, Equatable, Sendable {
    public let schema: Int
    public let revision: UInt64
    public let packages: [String: [String]]
    public let bindings: [SupportBinding]
    public init(revision: UInt64 = 0, packages: [String: [String]] = [:], bindings: [SupportBinding] = []) throws {
        schema = 1; self.revision = revision; self.packages = packages; self.bindings = bindings; try validate()
    }
    private enum CodingKeys: String, CodingKey { case schema, revision, packages, bindings }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "revision", "packages", "bindings"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); revision = try c.decode(UInt64.self, forKey: .revision)
        packages = try c.decode([String: [String]].self, forKey: .packages)
        bindings = try c.decode([SupportBinding].self, forKey: .bindings); try validate()
    }
    func validate() throws {
        try requireContract(schema == 1 && packages.count <= 1024 && bindings.count <= 4096
            && Set(bindings.map(\.id)).count == bindings.count, "registry")
        for (id, digests) in packages {
            try requireContract(SupportRegistry.validPackageID(id) && digests.count <= 1024
                && Set(digests).count == digests.count && digests.allSatisfy(contractDigest), "registryPackages")
        }
        for binding in bindings {
            try binding.validate()
            try requireContract(packages[binding.packageID]?.contains(binding.digest) == true, "bindingPackage")
        }
    }
}

/// Private storage foundation. No activation or executable readiness is exposed by W3.
public final class SupportRegistry {
    let root: SupportDirectory
    public let home: URL
    public static func resolveHome(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let override = environment["MSI_SCREEN_SUPPORT_HOME"] {
            guard override.hasPrefix("/"), !override.contains("\0"), !override.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw SupportStorageError.unavailableRoot
            }
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MSI Screen/Support", isDirectory: true)
    }
    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(home: Self.resolveHome(environment: environment))
    }
    public init(home: URL) throws {
        self.home = home; root = try SupportDirectory.root(home)
        for name in ["packages", "staging", "invocations", "requests", "receipts"] { _ = try root.directory(name, create: true) }
    }
    init(existingHome home: URL) throws {
        self.home = home; root = try SupportDirectory.root(home, create: false)
        for name in ["packages", "staging", "invocations", "requests", "receipts"] { _ = try root.directory(name) }
    }
    static func validPackageID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}\z"#, options: .regularExpression) != nil
    }
    func validateRoot() throws {
        let named = try SupportDirectory.root(home, create: false)
        var original = stat(); var current = stat()
        guard fstat(root.fd, &original) == 0, fstat(named.fd, &current) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else { throw SupportStorageError.unavailableRoot }
    }
    public func installationKey() throws -> Data {
        try validateRoot()
        let lease = try root.lock("registry.lock"); defer { withExtendedLifetime(lease) {} }
        if try root.exists("identity.key") {
            do {
                let fd = try root.file("identity.key"); defer { close(fd) }
                let key = try SupportDirectory.read(fd, limit: 32)
                guard key.count == 32 else { throw SupportStorageError.corruptKey }; return key
            } catch { throw SupportStorageError.corruptKey }
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // The registry lease serializes cooperating first users; no-overwrite publication also handles outsiders.
        let temporary = ".key-" + UUID().uuidString
        let fd = try root.file(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); unlinkat(root.fd, temporary, 0) }
        try SupportDirectory.write(key, to: fd)
        guard renameatx_np(root.fd, temporary, root.fd, "identity.key", UInt32(RENAME_EXCL)) == 0,
              fsync(root.fd) == 0 else { throw SupportStorageError.corruptKey }
        return key
    }
    /// Read an already initialized immutable key without taking registry.lock.
    /// Supervisors call this while borrowing resource leases; initialization
    /// remains exclusively owned by installationKey() before those leases.
    func existingInstallationKey() throws -> Data {
        try validateRoot()
        do {
            let fd = try root.file("identity.key"); defer { close(fd) }
            let bytes = try SupportDirectory.read(fd, limit: 32)
            guard bytes.count == 32 else { throw SupportStorageError.corruptKey }; return bytes
        } catch { throw SupportStorageError.corruptKey }
    }
    public func inventoryIdentity() -> DeviceInventoryIdentity {
        do { return try DeviceInventoryIdentity(installationKey: installationKey()) }
        catch { return try! DeviceInventoryIdentity(installationKey: nil, unavailableReason: DeviceUnavailable(code: "identityKeyUnavailable")) }
    }
    public func snapshot() throws -> SupportRegistrySnapshot {
        try validateRoot()
        do {
            guard try root.exists("registry.json") else { return try SupportRegistrySnapshot() }
            let fd = try root.file("registry.json"); defer { close(fd) }
            return try StrictJSON.decode(SupportRegistrySnapshot.self, from: SupportDirectory.read(fd, limit: 262144))
        } catch { throw SupportStorageError.corruptRegistry }
    }
    /// Called only with registry.lock held, before acquiring any resource leases.
    func compareAndSwap(expectedRevision: UInt64, packages: [String: [String]], bindings: [SupportBinding]) throws -> SupportRegistrySnapshot {
        let old = try snapshot()
        guard old.revision == expectedRevision else { throw SupportStorageError.revisionChanged }
        if old.packages == packages && old.bindings == bindings { return old }
        guard old.revision < UInt64.max else { throw SupportStorageError.limitExceeded }
        let next = try SupportRegistrySnapshot(revision: old.revision + 1, packages: packages, bindings: bindings)
        let data = try StrictJSON.canonical(next)
        guard data.count <= 262144 else { throw SupportStorageError.limitExceeded }
        try root.atomicWrite(data, name: "registry.json"); return next
    }
}
