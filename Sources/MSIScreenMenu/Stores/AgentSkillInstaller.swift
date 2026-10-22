import Foundation
import MSIScreenCore

/// Existing callers keep the default name and install(from:to:) façade.
/// Filesystem policy and ownership receipts are shared with the CLI.
enum AgentSkillInstaller {
    static let name = AgentSkill.screenControl.rawValue
    static var bundledSkill: URL? { try? AgentSkillInstallation.bundledSkill(.screenControl) }
    static var destination: URL {
        // Resolution failures are reported by install, never redirected to a real home.
        (try? AgentSkillInstallation.skillsHome())?.appendingPathComponent(name)
            ?? URL(fileURLWithPath: "/invalid-msi-screen-skill-root/" + name)
    }
    static func install(from source: URL, to destination: URL) throws {
        _ = try AgentSkillInstallation.skillsHome() // Invalid overrides fail before creating support state.
        try install(skill: .screenControl, from: source, to: destination, registry: SupportRegistry())
    }
    static func install(skill: AgentSkill, from source: URL, to destination: URL, registry: SupportRegistry) throws {
        do { _ = try AgentSkillInstallation(registry: registry).install(skill: skill, source: source, destination: destination) }
        catch AgentSkillInstallError.missingBundle { throw InstallError.missingBundle }
        catch AgentSkillInstallError.conflict { throw InstallError.existingSkill(destination.path) }
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
