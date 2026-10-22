import AppKit
import SwiftUI
import MSIScreenCore

struct PrivacyStatusView: View {
    @State private var snapshot: AppPermissionStatus?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Privacy & permissions", systemImage: "lock.shield")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Check again") { refresh() }
                    .controlSize(.small).disabled(checking)
                    .accessibilityIdentifier("check-app-permissions")
                    .accessibilityLabel("Check MSI Screen permissions")
            }
            if let snapshot {
                permissionRow("Accessibility", granted: snapshot.spacesAllowed,
                              status: snapshot.spacesAllowed ? "Granted" : "Not granted",
                              purpose: "Switch Spaces with the side wheel",
                              pane: "Privacy_Accessibility", id: "accessibility")
                permissionRow("Input Monitoring", granted: snapshot.inputMonitoring == .granted,
                              status: snapshot.inputMonitoring == .granted ? "Granted"
                                  : snapshot.inputMonitoring == .denied ? "Not granted" : "Not determined",
                              purpose: "Configure the mouse and test its controls",
                              pane: "Privacy_ListenEvent", id: "input-monitoring")
                Divider()
                HStack {
                    Image(systemName: snapshot.signing.hasStableIdentity ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(snapshot.signing.hasStableIdentity ? .green : .orange)
                    Text(snapshot.signing.hasStableIdentity ? "Stable signing identity" : "Signing needs attention")
                        .font(.caption.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("app-signing-status")
                Text(snapshot.signing.hasStableIdentity
                     ? "Updates signed with this identity can retain your permissions."
                     : "This build cannot preserve its identity reliably across code changes. Rebuild with the configured signing certificate.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !snapshot.allGranted {
                    Text("Grant access to MSI Screen in System Settings, then check again. Input Monitoring may require restarting the app.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("These checks describe this caller only. They do not identify macOS’s responsible launch client or grant access to a CLI/adapter. Native adapters are unconfined user code; execution policy and device access can fail independently. Experimental execution remains refused until launch-client and platform qualification closes.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("experimental-permission-limit")
                DisclosureGroup("Identity details") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.appPath)
                        Text("Bundle: \(snapshot.signing.identifier ?? "Unavailable")")
                        Text("Team: \(snapshot.signing.teamIdentifier ?? "Unavailable")")
                        Text("Signature: \(snapshot.signing.signatureValid ? "Valid" : "Not verified")")
                        Text("Accessibility trust: \(snapshot.accessibilityTrusted ? "Granted" : "Not granted")")
                        Text("Post events: \(snapshot.eventPostingAllowed ? "Granted" : "Not granted")")
                    }
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.caption2)
                Text("Checked \(snapshot.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .monitorCard()
        .accessibilityIdentifier("app-permissions")
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func permissionRow(_ title: String, granted: Bool, status: String,
                               purpose: String, pane: String, id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.medium))
                Text(purpose).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(status).font(.caption2).foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel("\(title): \(status)")
                .accessibilityIdentifier("permission-\(id)-status")
            if !granted {
                Button("Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("Open \(title) settings for MSI Screen")
            }
        }
    }

    private func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            snapshot = await Task.detached { AppPermissionStatus.current() }.value
            checking = false
        }
    }
}
