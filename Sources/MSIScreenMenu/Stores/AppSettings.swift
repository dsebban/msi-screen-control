import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var changingLoginItem = false
    @Published private(set) var error: String?
    @Published private(set) var skillMessage: String?
    @Published private(set) var skillError: String?
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

    func refresh() { loginStatus = service.status }

    func installAgentSkill() {
        skillError = nil
        skillMessage = nil
        do {
            guard let source = AgentSkillInstaller.bundledSkill else {
                throw AgentSkillInstaller.InstallError.missingBundle
            }
            try AgentSkillInstaller.install(from: source, to: AgentSkillInstaller.destination)
            skillMessage = "Installed at \(AgentSkillInstaller.destination.path). Available on your next agent turn."
        } catch {
            skillError = error.localizedDescription
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isInstalled, !changingLoginItem else { return }
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
