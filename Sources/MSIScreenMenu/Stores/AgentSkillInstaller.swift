import Foundation

enum AgentSkillInstaller {
    static let name = "msi-screen-control"

    static var bundledSkill: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("AgentSkills/\(name)")
    }

    static var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills/\(name)")
    }

    /// Existing skills can be user-maintained or managed by another installer.
    /// Only an exact match is a no-op; never replace unfamiliar content.
    static func install(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw InstallError.missingBundle
        }
        // lstat semantics also catch a dangling symlink at the destination.
        if (try? files.attributesOfItem(atPath: destination.path)) != nil {
            guard files.contentsEqual(atPath: source.path, andPath: destination.path) else {
                throw InstallError.existingSkill(destination.path)
            }
            return
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy to an owned staging folder, then publish the complete skill with
        // a move that refuses a destination created concurrently.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(name)-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try files.moveItem(at: staging, to: destination)
    }

    enum InstallError: LocalizedError {
        case missingBundle
        case existingSkill(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle: return "The agent skill is missing from this app. Install a packaged MSI Screen app."
            case .existingSkill(let path):
                return "A different skill already exists at \(path). Move it aside before installing; it has been left unchanged."
            }
        }
    }
}
