import Foundation
import ServiceManagement
import MSIScreenCore

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var changingLoginItem = false
    @Published private(set) var error: String?
    @Published private(set) var skillMessage: String?
    @Published private(set) var skillError: String?
    @Published private(set) var skillMessages: [AgentSkill: String] = [:]
    @Published private(set) var skillErrors: [AgentSkill: String] = [:]
    @Published private(set) var installingSkills: Set<AgentSkill> = []
    weak var deviceInventory: DeviceInventoryStore?
    var fixtureSkillInstall: ((AgentSkill) async throws -> AgentSkillInstallResult)?
    var fixtureSkillAction: ((AgentSkill) async throws -> AgentSkillInstallAction)?
    @Published private(set) var skillActions: [AgentSkill: AgentSkillInstallAction] = [:]
    @Published private(set) var skillPreviewErrors: [AgentSkill: String] = [:]
    private var inspectingSkills = false
    var externalMutationActive: () -> Bool = { false }
    var hasActiveOperation: Bool { changingLoginItem || !installingSkills.isEmpty }
    private let service = SMAppService.mainApp
    private let configuredKey = "launchAtLoginConfigured"

    var isInstalled: Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return Bundle.main.bundleURL.pathExtension == "app" &&
            ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path].contains(parent)
    }

    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    var loginStatusText: String {
        switch loginStatus {
        case .enabled: return "Launch at login is enabled."
        case .notRegistered: return "Launch at login is off."
        case .requiresApproval: return "Allow MSI Screen in System Settings → General → Login Items."
        case .notFound: return "macOS could not find this app’s login item."
        @unknown default: return "Login item status is unavailable."
        }
    }

    func configureAtFirstLaunch() {
        refresh()
        // Only the installed app opts in by default. Verification copies and
        // development bundles must not leave login items pointing at temp paths.
        guard isInstalled, !CommandLine.arguments.contains("--verification-owner"),
              !UserDefaults.standard.bool(forKey: configuredKey) else { return }
        UserDefaults.standard.set(true, forKey: configuredKey)
        if loginStatus == .notRegistered { setLaunchAtLogin(true) }
    }

    func refresh() {
        loginStatus = service.status
        guard !inspectingSkills else { return }
        inspectingSkills = true
        let fixtureAction = fixtureSkillAction
        Task {
            defer { inspectingSkills = false }
            let result = await Task.detached { () -> ([AgentSkill: AgentSkillInstallAction], [AgentSkill: String]) in
                var actions: [AgentSkill: AgentSkillInstallAction] = [:], errors: [AgentSkill: String] = [:]
                for skill in AgentSkill.allCases {
                    do {
                        if let fixtureAction { actions[skill] = try await fixtureAction(skill) }
                        else {
                            let destination = try AgentSkillInstallation.skillsHome().appendingPathComponent(skill.rawValue)
                            actions[skill] = try AgentSkillInstallation(registry: SupportRegistry()).prospectiveAction(skill: skill,
                                source: AgentSkillInstallation.bundledSkill(skill), destination: destination)
                        }
                    } catch { errors[skill] = DevicePublicJSON.errorCode(error) }
                }
                return (actions, errors)
            }.value
            for skill in AgentSkill.allCases where !installingSkills.contains(skill) {
                skillActions[skill] = result.0[skill]; skillPreviewErrors[skill] = result.1[skill]
            }
        }
    }

    func installAgentSkill(_ skill: AgentSkill = .screenControl) {
        guard !hasActiveOperation, !externalMutationActive() else { return }
        installingSkills.insert(skill); skillErrors[skill] = nil; skillMessages[skill] = nil
        if skill == .screenControl { skillError = nil; skillMessage = nil }
        Task {
            defer { installingSkills.remove(skill) }
            do {
                let fixtureInstall = fixtureSkillInstall
                let status = try await Task.detached {
                    if let fixtureInstall { return try await fixtureInstall(skill) }
                    // Validate overrides before constructing any production root.
                    let destination = try AgentSkillInstallation.skillsHome().appendingPathComponent(skill.rawValue)
                    let source = try AgentSkillInstallation.bundledSkill(skill)
                    return try AgentSkillInstallation(registry: SupportRegistry()).install(skill: skill, source: source, destination: destination)
                }.value
                let text = "\(status.rawValue.capitalized). Available on your next agent turn; read the installed skill locally if not indexed."
                skillActions[skill] = .unchanged; skillPreviewErrors[skill] = nil
                skillMessages[skill] = text
                if skill == .screenControl { skillMessage = text }
            } catch {
                let text = error is AgentSkillInstallError ? "Missing, conflicting, linked or incompatible skill. Existing content was preserved." : DevicePublicJSON.errorCode(error)
                skillErrors[skill] = text
                if skill == .screenControl { skillError = text }
            }
            if skill == .writeSupport { await deviceInventory?.refreshSkillAction() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isInstalled, !hasActiveOperation, !externalMutationActive() else { return }
        refresh()
        guard launchAtLogin != enabled else { return }
        UserDefaults.standard.set(true, forKey: configuredKey)
        changingLoginItem = true
        error = nil
        Task {
            defer {
                refresh()
                changingLoginItem = false
            }
            do {
                if enabled { try service.register() }
                else { try await service.unregister() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
