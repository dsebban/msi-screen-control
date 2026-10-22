import Darwin
import Foundation

public enum AgentSkill: String, Codable, CaseIterable, Sendable {
    case screenControl = "msi-screen-control"
    case writeSupport = "write-addhoc-support"
}

public enum AgentSkillInstallError: Error, Equatable {
    case missingBundle, conflict, incompatibleContract
}
public enum AgentSkillInstallResult: String, Codable, Sendable { case installed, unchanged, upgraded }
public enum AgentSkillInstallAction: String, Sendable { case install, upgrade, unchanged }

/// Complete content, including empty directories. Descriptors never follow links;
/// hard links, special files, foreign ownership and writable ancestors fail closed.
struct AgentSkillTree: Equatable {
    let entries: [String: Data]
    var digest: String { SupportPackageContent.digest(entries) }
    static func read(_ url: URL, source: Bool) throws -> AgentSkillTree {
        let root: SupportDirectory
        if source {
            // Packaged resources may legitimately be owned by root after installation.
            guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", !url.path.contains("\0") else { throw SupportStorageError.unsafeFile }
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SupportStorageError.unsafeFile }
            do {
                let components = url.path.split(separator: "/").map(String.init)
                for (index, name) in components.enumerated() {
                    guard name != "." && name != ".." else { throw SupportStorageError.unsafeFile }
                    let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else { throw SupportStorageError.unsafeFile }
                    var info = stat()
                    guard fstat(next, &info) == 0, info.st_uid == getuid() || info.st_uid == 0,
                          info.st_mode & 0o022 == 0 || (index < components.count - 1 && info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else {
                        close(next); throw SupportStorageError.unsafeFile
                    }
                    close(fd); fd = next
                }
                root = SupportDirectory(fd: fd, url: url, managed: false)
            } catch { close(fd); throw error }
        } else { root = try SupportDirectory.root(url, create: false, managed: false) }
        var entries: [String: Data] = [:], folded = Set<String>(), total = 0
        func walk(_ fd: Int32, prefix: String, depth: Int) throws {
            guard depth <= 16, entries.count <= 128 else { throw SupportStorageError.limitExceeded }
            let listing = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard listing >= 0 else { throw SupportStorageError.unsafeFile }
            guard let stream = fdopendir(listing) else { close(listing); throw SupportStorageError.unsafeFile }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { throw SupportStorageError.unsafeFile }
                if name == "." || name == ".." { continue }
                let path = prefix + name
                guard SupportManifest.validRelativePath(path), folded.insert(SupportManifest.foldedPath(path)).inserted,
                      entries.count < 128 else { throw SupportStorageError.unsafeFile }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      (info.st_uid == getuid() || (source && info.st_uid == 0)), info.st_mode & 0o022 == 0 else { throw SupportStorageError.unsafeFile }
                let directory = info.st_mode & S_IFMT == S_IFDIR
                guard directory || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else { throw SupportStorageError.unsafeFile }
                let child = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
                guard child >= 0 else { throw SupportStorageError.unsafeFile }
                defer { close(child) }
                var opened = stat(), remaining = stat()
                guard fstat(child, &opened) == 0, SupportDirectory.same(info, opened) else { throw SupportStorageError.integrityChanged }
                if directory {
                    entries[path + "/"] = Data(); try walk(child, prefix: path + "/", depth: depth + 1)
                } else {
                    let data = try SupportDirectory.read(child, limit: 4 * 1024 * 1024 - total)
                    total += data.count; entries[path] = data
                }
                guard fstatat(fd, name, &remaining, AT_SYMLINK_NOFOLLOW) == 0,
                      SupportDirectory.same(opened, remaining) else { throw SupportStorageError.integrityChanged }
            }
        }
        try walk(root.fd, prefix: "", depth: 1)
        guard entries["SKILL.md"] != nil else { throw AgentSkillInstallError.missingBundle }
        return AgentSkillTree(entries: entries)
    }
    func copy(to root: SupportDirectory) throws {
        for path in entries.keys.sorted() {
            let parts = path.split(separator: "/").map(String.init)
            var parent = root
            for part in parts.dropLast() { parent = try parent.directory(part, create: true) }
            if path.hasSuffix("/") { _ = try parent.directory(parts.last!, create: true) }
            else {
                let fd = try parent.file(parts.last!, flags: O_WRONLY | O_CREAT | O_EXCL)
                defer { close(fd) }; try SupportDirectory.write(entries[path]!, to: fd)
            }
            guard fsync(parent.fd) == 0 else { throw SupportStorageError.unsafeFile }
        }
        guard fsync(root.fd) == 0 else { throw SupportStorageError.unsafeFile }
    }
}

private struct SkillOwnership: Codable {
    let schema: Int
    var installs: [String: Entry]
    struct Entry: Codable {
        let destination: String; let digest: String
        init(destination: String, digest: String) { self.destination = destination; self.digest = digest }
        private enum CodingKeys: String, CodingKey { case destination, digest }
        init(from decoder: Decoder) throws {
            try decoder.contractKeys(["destination", "digest"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            destination = try c.decode(String.self, forKey: .destination); digest = try c.decode(String.self, forKey: .digest)
        }
    }
    init(installs: [String: Entry] = [:]) { schema = 1; self.installs = installs }
    private enum CodingKeys: String, CodingKey { case schema, installs }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "installs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); installs = try c.decode([String: Entry].self, forKey: .installs)
        try requireContract(schema == 1 && installs.count <= 2 && installs.allSatisfy {
            AgentSkill(rawValue: $0.key) != nil && contractDigest($0.value.digest) && $0.value.destination.hasPrefix("/")
        }, "skillOwnership")
    }
}

public final class AgentSkillInstallation {
    public let registry: SupportRegistry
    private let trash: (URL) throws -> Void
    public init(registry: SupportRegistry) {
        self.registry = registry
        trash = { url in _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }
    init(registry: SupportRegistry, trash: @escaping (URL) throws -> Void) { self.registry = registry; self.trash = trash }

    public static func skillsHome(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let path = environment["MSI_SCREEN_AGENT_SKILLS_HOME"] {
            guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
                  !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw SupportStorageError.unavailableRoot }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true)
    }
    /// Only the executing app/embedded CLI's own resource layout. Never search cwd or PATH.
    public static func bundledSkill(_ skill: AgentSkill, executable: URL? = nil) throws -> URL {
        // Use the resolved executing image, not spoofable argv[0], cwd, PATH or
        // Foundation's temporary-directory aliases (which no-follow rejects).
        let image = try executable ?? AdapterHostIdentity.currentExecutable()
        let macOS = image.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", macOS.deletingLastPathComponent().lastPathComponent == "Contents" else {
            throw AgentSkillInstallError.missingBundle
        }
        let resources = macOS.deletingLastPathComponent().appendingPathComponent("Resources")
        let url = resources.appendingPathComponent("AgentSkills/" + skill.rawValue)
        guard (try? AgentSkillTree.read(url, source: true)) != nil else { throw AgentSkillInstallError.missingBundle }
        return url
    }
    private func validateContract(_ tree: AgentSkillTree, skill: AgentSkill) throws {
        guard let bytes = tree.entries["SKILL.md"], let text = String(data: bytes, encoding: .utf8), text.hasPrefix("---\n"),
              let end = text.dropFirst(4).range(of: "\n---\n") else { throw AgentSkillInstallError.incompatibleContract }
        let lines = text[..<end.lowerBound].components(separatedBy: "\n")
        guard lines.filter({ $0.hasPrefix("name:") }) == ["name: " + skill.rawValue],
              lines.filter({ $0 == "metadata:" }).count == 1, let metadata = lines.firstIndex(of: "metadata:") else {
            throw AgentSkillInstallError.incompatibleContract
        }
        let fields = lines.dropFirst(metadata + 1).prefix { $0.hasPrefix(" ") || $0.isEmpty }
        guard fields.filter({ $0.hasPrefix("  msi-screen-host-api:") }) == ["  msi-screen-host-api: \"1\""] else {
            throw AgentSkillInstallError.incompatibleContract
        }
        if skill == .writeSupport {
            guard ["agents/openai.yaml", "references/contract-v1.md", "references/validation.md"].allSatisfy({ tree.entries[$0] != nil }) else {
                throw AgentSkillInstallError.missingBundle
            }
        }
    }
    private func receiptBytes() throws -> Data? {
        guard try registry.root.exists("skill-installs.json") else { return nil }
        let fd = try registry.root.file("skill-installs.json"); defer { close(fd) }
        return try SupportDirectory.read(fd, limit: 16384)
    }
    private func requireManaged(_ prior: AgentSkillTree, skill: AgentSkill, destination: URL, ownership: SkillOwnership) throws {
        guard let recorded = ownership.installs[skill.rawValue], recorded.destination == destination.path,
              recorded.digest == prior.digest else { throw AgentSkillInstallError.conflict }
    }
    /// Advisory only: no publication, receipts, lock creation or missing-directory
    /// creation. Actual Copy/install must repeat all checks under its own lease.
    public func prospectiveAction(skill: AgentSkill, source: URL, destination: URL) throws -> AgentSkillInstallAction {
        try registry.validateRoot()
        guard destination.lastPathComponent == skill.rawValue else { throw AgentSkillInstallError.conflict }
        let tree = try AgentSkillTree.read(source, source: true)
        try validateContract(tree, skill: skill)
        let ownership = try receiptBytes().map { try StrictJSON.decode(SkillOwnership.self, from: $0) } ?? SkillOwnership()
        // Find the nearest existing ancestor without creating anything. Opening
        // it through the shared no-follow owner checks rejects dangling/ancestor
        // links too, rather than treating them as an absent skill.
        var ancestor = destination
        while true {
            var info = stat()
            if lstat(ancestor.path, &info) == 0 {
                _ = try SupportDirectory.root(ancestor, create: false, managed: false)
                if ancestor != destination { return .install }
                break
            }
            guard errno == ENOENT, ancestor.path != "/" else { throw SupportStorageError.unsafeFile }
            ancestor.deleteLastPathComponent()
        }
        let prior = try AgentSkillTree.read(destination, source: false)
        if prior == tree { return .unchanged }
        try requireManaged(prior, skill: skill, destination: destination, ownership: ownership)
        return .upgrade
    }
    @discardableResult
    public func install(skill: AgentSkill, source: URL, destination: URL) throws -> AgentSkillInstallResult {
        try install(skill: skill, source: source, destination: destination, checkContract: true)
    }
    func install(skill: AgentSkill, source: URL, destination: URL, checkContract: Bool) throws -> AgentSkillInstallResult {
        try registry.validateRoot()
        let lock = try registry.root.lock("skill-installer.lock"); defer { withExtendedLifetime(lock) {} }
        let tree = try AgentSkillTree.read(source, source: true)
        if checkContract { try validateContract(tree, skill: skill) }
        let originalReceipt = try receiptBytes()
        var ownership = try originalReceipt.map { try StrictJSON.decode(SkillOwnership.self, from: $0) } ?? SkillOwnership()
        let parent = try SupportDirectory.root(destination.deletingLastPathComponent(), managed: false)
        let name = destination.lastPathComponent
        guard name == skill.rawValue else { throw AgentSkillInstallError.conflict }
        let prior: AgentSkillTree?
        if try parent.exists(name) { prior = try AgentSkillTree.read(destination, source: false) } else { prior = nil }
        if prior == tree { return .unchanged } // Exact preexisting content does not confer ownership.
        if let prior {
            try requireManaged(prior, skill: skill, destination: destination, ownership: ownership)
        }
        let temporary = ".skill-" + UUID().uuidString
        let staged = try parent.directory(temporary, create: true)
        defer { SupportPackageInstaller.cleanupOwned(staged, parent: parent, name: temporary) }
        try tree.copy(to: staged)
        guard try AgentSkillTree.read(source, source: true) == tree,
              try AgentSkillTree.read(staged.url, source: false) == tree else { throw SupportStorageError.integrityChanged }
        guard try receiptBytes() == originalReceipt else { throw AgentSkillInstallError.conflict }
        if let prior {
            guard try AgentSkillTree.read(destination, source: false) == prior,
                  renameatx_np(parent.fd, temporary, parent.fd, name, UInt32(RENAME_SWAP)) == 0 else { throw AgentSkillInstallError.conflict }
        } else {
            guard renameatx_np(parent.fd, temporary, parent.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw AgentSkillInstallError.conflict }
        }
        do {
            guard fsync(parent.fd) == 0, try AgentSkillTree.read(destination, source: false) == tree,
                  try receiptBytes() == originalReceipt else { throw SupportStorageError.integrityChanged }
            if let prior { guard try AgentSkillTree.read(staged.url, source: false) == prior else { throw AgentSkillInstallError.conflict } }
            ownership.installs[skill.rawValue] = SkillOwnership.Entry(destination: destination.path, digest: tree.digest)
            try registry.root.atomicWrite(StrictJSON.canonical(ownership), name: "skill-installs.json")
        } catch {
            // Roll back only the exact publication we still own; never overwrite a new editor.
            if (try? AgentSkillTree.read(destination, source: false)) == tree {
                _ = renameatx_np(parent.fd, name, parent.fd, temporary, UInt32(prior == nil ? RENAME_EXCL : RENAME_SWAP))
                _ = fsync(parent.fd)
            }
            throw error
        }
        if prior != nil {
            // Receipt is durable before moving the old, unchanged managed version to Trash.
            // Do not let staging cleanup delete it if Trash is unavailable.
            do { try trash(staged.url) }
            catch { throw SupportStorageError.unsafeFile }
        }
        return prior == nil ? .installed : .upgraded
    }
}
