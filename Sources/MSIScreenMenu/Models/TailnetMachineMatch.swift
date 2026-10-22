import Darwin
import Foundation
import MSIScreenCore

/// A discovery label is never enough to rewrite a saved SSH or input assignment.
enum TailnetMachineMatch {
    static func machine(for peer: TailnetPeer, peers: [TailnetPeer], machines: [MachineDefinition],
                        resolvedHosts: [String: String] = [:]) -> MachineDefinition? {
        if peer.isSelf { return machines.first(where: \.isLocal) }
        let matches = machines.filter { machine in
            guard machine.access == .ssh, let host = machine.host,
                  (try? MachineRegistry(machines: [machine]).validate()) != nil else { return false }
            let destination: String
            if machine.sshTransport == .standard {
                // Even a saved DNS/IP spelling can be redirected by ssh_config.
                guard let resolved = resolvedHosts[machine.id] else { return false }
                destination = resolved
            } else {
                destination = String(host.split(separator: "@").last ?? "")
            }
            let target = normalized(destination)
            let exact = peers.filter { candidate in
                candidate.dnsName.map(normalized) == target || candidate.addresses.map(normalized).contains(target)
            }
            if !exact.isEmpty { return exact.count == 1 && exact[0].id == peer.id }
            // OpenSSH aliases may redirect to an unrelated HostName. Only the
            // native Tailscale transport resolves a short MagicDNS node name.
            guard machine.sshTransport == .tailscale else { return false }
            let short = peers.filter { candidate in
                candidate.dnsName?.split(separator: ".").first.map { normalized(String($0)) } == target
            }
            return short.count == 1 && short[0].id == peer.id
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalized(_ value: String) -> String {
        var address = in6_addr()
        if inet_pton(AF_INET6, value, &address) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil { return String(cString: buffer) }
        }
        return (value.hasSuffix(".") ? String(value.dropLast()) : value).lowercased()
    }
}
