import AppKit
import ServiceManagement
import SwiftUI
import MSIScreenCore

struct AppSettingsView: View {
    @ObservedObject var settings: AppSettings
    var inventory: DeviceInventoryStore? = nil
    var controlsBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Startup").font(.headline)
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .disabled(!settings.isInstalled || settings.hasActiveOperation || controlsBusy)
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
            ForEach(AgentSkill.allCases, id: \.self) { skill in
                VStack(alignment: .leading, spacing: 5) {
                    Text(skill.rawValue).font(.subheadline)
                    Button(skill == .screenControl ? "Install agent skill" : "Install ad-hoc support skill") { settings.installAgentSkill(skill) }
                        .disabled(controlsBusy || settings.hasActiveOperation)
                        .accessibilityIdentifier(skill == .screenControl ? "install-agent-skill" : "install-write-support-skill")
                    Text(settings.skillMessages[skill] ?? skillStatus(skill))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier(skill == .screenControl ? "agent-skill-status" : "write-support-skill-status")
                    if let error = settings.skillErrors[skill] ?? settings.skillPreviewErrors[skill] {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier(skill == .screenControl ? "agent-skill-error" : "write-support-skill-error")
                    }
                }
            }
            if let inventory = inventory ?? settings.deviceInventory {
                DeviceSupportManagementView(inventory: inventory)
                    .disabled(controlsBusy || inventory.managementBusy || inventory.handoffBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
    private func skillStatus(_ skill: AgentSkill) -> String {
        switch settings.skillActions[skill] {
        case .install: return "Not installed. Install the bundled skill."
        case .upgrade: return "An unchanged installer-owned version can be updated."
        case .unchanged: return "Complete installed content matches the bundle."
        case nil: return "Checking bundled/installed skill; unfamiliar content is preserved."
        }
    }
}

private struct DeviceSupportManagementView: View {
    @ObservedObject var inventory: DeviceInventoryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Local experimental support").font(.headline)
            Text("Activation changes metadata, not hardware. Native adapters run as trusted user code, not in a sandbox. Disable/retained-version activation never restores hardware.")
                .font(.caption).foregroundStyle(.secondary)
            if let listing = inventory.listing {
                ForEach(listing.registry.bindings, id: \.id) { binding in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(binding.packageID) · \(binding.enabled ? "enabled" : "disabled")").font(.caption.weight(.semibold))
                        Text(binding.digest).font(.caption2).textSelection(.enabled)
                        Text("Endpoint \(binding.selector.id.prefix(12)) · \(binding.id)").font(.caption2)
                        HStack {
                            Button("Disable") { inventory.disable(binding) }.disabled(!binding.enabled)
                                .accessibilityIdentifier("support-disable-\(binding.id)")
                            Menu("Activate retained version") {
                                ForEach(listing.registry.packages[binding.packageID] ?? [], id: \.self) { digest in
                                    Button(String(digest.prefix(16))) { inventory.activate(binding, digest: digest) }
                                }
                            }.accessibilityIdentifier("support-activate-\(binding.id)")
                        }
                    }.monitorCard()
                }
                ForEach(listing.packages, id: \.digest) { package in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(package.packageID) · \(package.digest.prefix(16)) · \(package.status)").font(.caption2)
                        if let reason = package.reason { Text(reason).font(.caption2).foregroundStyle(.orange) }
                        Button("Remove unreferenced package") { inventory.remove(packageID: package.packageID, digest: package.digest) }
                            .disabled(listing.registry.bindings.contains { $0.packageID == package.packageID && $0.digest == package.digest })
                            .accessibilityIdentifier("support-remove-\(package.digest)")
                    }
                }
            }
            if let error = inventory.error ?? inventory.metadataError { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("device-support-error") }
        }
    }
}
