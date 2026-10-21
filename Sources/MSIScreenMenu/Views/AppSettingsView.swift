import AppKit
import ServiceManagement
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .disabled(!settings.isInstalled || settings.changingLoginItem)
                .accessibilityIdentifier("launch-at-login")
            Text("Start MSI Screen in the menu bar when you sign in to your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text(settings.loginStatusText)
                .font(.caption)
                .foregroundStyle(settings.loginStatus == .requiresApproval ? Color.orange : .secondary)
                .accessibilityIdentifier("launch-at-login-status")
            if settings.loginStatus == .requiresApproval {
                Button("Open Login Items settings…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if !settings.isInstalled {
                Text("Move MSI Screen to Applications to manage launch at login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = settings.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("launch-at-login-error")
            }
            Divider()
            Text("Agents").font(.headline)
            Text("Give compatible agents instructions for controlling this monitor through the bundled CLI.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Install agent skill") { settings.installAgentSkill() }
                .accessibilityIdentifier("install-agent-skill")
            Text("Installs msi-screen-control into ~/.agents/skills. Existing changes are preserved.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = settings.skillMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("agent-skill-status")
            }
            if let error = settings.skillError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("agent-skill-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
