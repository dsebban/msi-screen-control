import SwiftUI
import MSIScreenCore

struct TailnetMachinesView: View {
    @ObservedObject var computers: ComputersStore
    let machines: [MachineDefinition]
    let configure: (MachineDefinition?, MachineDefinition?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Discovered via Tailscale").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { computers.refreshTailnet() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh Tailscale machines")
                    .accessibilityIdentifier("tailnet-refresh")
                    .disabled(computers.discoveringTailnet)
            }
            if let snapshot = computers.tailnet {
                ForEach(snapshot.peers) { peer in
                    let machine = TailnetMachineMatch.machine(for: peer, peers: snapshot.peers, machines: machines,
                                                              resolvedHosts: computers.resolvedHosts)
                    HStack(spacing: 8) {
                        Image(systemName: peer.operatingSystem == .ios || peer.operatingSystem == .android ? "iphone" : "desktopcomputer")
                            .frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(peer.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(detail(peer, machine: machine)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        if !peer.isSelf, let host = peer.sshHostCandidate,
                           let platform = platform(peer) {
                            Button(machine == nil ? "Configure…" : "Edit…") {
                                let suggestion = MachineDefinition(id: "tailnet-" + UUID().uuidString.lowercased(),
                                    name: String(peer.name.prefix(128)), platform: platform, input: nil, host: host,
                                    access: .ssh, sshTransport: .tailscale)
                                configure(machine, machine == nil ? suggestion : nil)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Configure Tailscale machine \(peer.name)")
                            .accessibilityIdentifier("tailnet-configure-\(peer.id)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tailnet-peer-\(peer.id)")
                }
                ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message).font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.peers.isEmpty && snapshot.issues.isEmpty {
                    Text("No Tailscale devices found.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Network discovery does not identify monitor cables. Configure an input to add video controls.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Checked \(snapshot.checkedAt, style: .time)").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Looking for Tailscale devices…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .monitorCard()
    }

    private func platform(_ peer: TailnetPeer) -> MachinePlatform? {
        switch peer.operatingSystem {
        case .macos: return .macos
        case .linux: return .linux
        default: return nil
        }
    }

    private func detail(_ peer: TailnetPeer, machine: MachineDefinition?) -> String {
        let online = peer.advertisedOnline.map { $0 ? "Online in Tailscale" : "Offline in Tailscale" } ?? "Presence unknown"
        let assignment = peer.isSelf ? "This Mac" : machine.map { $0.input?.title ?? "Saved · no input" } ?? "No input assigned"
        return "\(peer.rawOperatingSystem ?? "Unknown OS") · \(online) · \(assignment)"
    }
}
