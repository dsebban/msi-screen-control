import Foundation

public struct LinuxDisplayConnector: Codable, Equatable, Identifiable {
    public enum Status: String, Codable { case connected, disconnected, unknown }
    public let id: String
    public let status: Status
    /// Modes advertised through DRM. They do not identify the active video mode.
    public let modes: [String]
}

public struct MachineStatus: Codable {
    public let machineID: String
    public let name: String
    public let platform: MachinePlatform
    public let checkedAt: Date
    /// True after a successful remote response; nil when reachability is unproven.
    public let reachable: Bool?
    public let user: String?
    public let architecture: String?
    public let macDisplays: MacDisplayState?
    public let connectors: [LinuxDisplayConnector]
    public let error: String?

    public init(machine: MachineDefinition, macDisplays: MacDisplayState) {
        self.init(machineID: machine.id, name: macDisplays.computerName, platform: .macos,
                  checkedAt: Date(), reachable: true, user: machine.isLocal ? NSUserName() : nil,
                  architecture: nil, macDisplays: macDisplays, connectors: [], error: nil)
    }

    init(machineID: String, name: String, platform: MachinePlatform, checkedAt: Date,
         reachable: Bool?, user: String?, architecture: String?, macDisplays: MacDisplayState?,
         connectors: [LinuxDisplayConnector], error: String?) {
        self.machineID = machineID
        self.name = name
        self.platform = platform
        self.checkedAt = checkedAt
        self.reachable = reachable
        self.user = user
        self.architecture = architecture
        self.macDisplays = macDisplays
        self.connectors = connectors
        self.error = error
    }
}

public struct MachineStatusClient {
    public init() {}

    public func state(for machine: MachineDefinition) async -> MachineStatus {
        do {
            try MachineRegistry(machines: [machine]).validate()
            if machine.access == .videoOnly {
                return MachineStatus(machineID: machine.id, name: machine.name, platform: machine.platform,
                                     checkedAt: Date(), reachable: nil, user: nil, architecture: nil,
                                     macDisplays: nil, connectors: [], error: nil)
            }
            if machine.platform == .macos {
                let displays: MacDisplayState
                if let host = machine.host {
                    displays = try await RemoteMacClient(host: host, transport: machine.sshTransport).state()
                } else {
                    displays = try MacDisplayController().state()
                }
                return MachineStatus(machine: machine, macDisplays: displays)
            }
            guard let host = machine.host else { throw ScreenError.message("A Linux machine needs an SSH host") }
            let output = try await ProcessRunner.run(
                executable: try machine.sshTransport.executable(),
                arguments: try Self.linuxArguments(host: host, transport: machine.sshTransport),
                timeout: 25, outputLimit: 65_536
            )
            guard output.succeeded, !output.truncated else {
                throw ScreenError.message(output.timedOut ? "SSH status check timed out" :
                    output.truncated ? "SSH status response exceeded its limit" :
                    String(output.text.prefix(2_048)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let result = try Self.decodeLinux(output.text)
            return MachineStatus(machineID: machine.id, name: result.name, platform: .linux, checkedAt: Date(),
                                 reachable: true, user: result.user, architecture: result.architecture,
                                 macDisplays: nil, connectors: result.connectors, error: nil)
        } catch {
            let reached: Bool?
            if case RemoteMacError.helperMissing = error { reached = true } else { reached = nil }
            return MachineStatus(machineID: machine.id, name: machine.name, platform: machine.platform,
                                 checkedAt: Date(), reachable: reached, user: nil, architecture: nil,
                                 macDisplays: nil, connectors: [],
                                 error: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    static func linuxArguments(host: String, transport: SSHTransport = .standard) throws -> [String] {
        try transport.arguments(host: host, command: linuxCommand)
    }

    // No installation, environment edits or video changes. uname is available
    // on minimal Linux systems where the optional hostname utility is absent.
    static let linuxCommand = #"""
    set -eu
    machine_user=$(id -un)
    machine_name=$(uname -n)
    machine_kernel=$(uname -s)
    machine_arch=$(uname -m)
    printf 'USER\t%s\nHOSTNAME\t%s\nKERNEL\t%s\nARCH\t%s\n' "$machine_user" "$machine_name" "$machine_kernel" "$machine_arch"
    for path in /sys/class/drm/card*-*/status; do
        [ -r "$path" ] || continue
        connector=${path%/status}
        connector=${connector##*/}
        printf 'CONNECTOR\t%s\t%s\n' "$connector" "$(cat "$path")"
        modes=${path%/status}/modes
        if [ -r "$modes" ]; then
            while IFS= read -r mode; do printf 'MODE\t%s\t%s\n' "$connector" "$mode"; done < "$modes"
        fi
    done
    """#

    struct LinuxIdentity {
        let name: String
        let user: String
        let architecture: String
        let connectors: [LinuxDisplayConnector]
    }

    static func decodeLinux(_ text: String) throws -> LinuxIdentity {
        var fields: [String: String] = [:]
        var statuses: [String: LinuxDisplayConnector.Status] = [:]
        var modes: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2, ["USER", "HOSTNAME", "KERNEL", "ARCH"].contains(parts[0]),
               fields[parts[0]] == nil, !parts[1].isEmpty {
                fields[parts[0]] = parts[1]
            } else if parts.count == 3, parts[0] == "CONNECTOR", !parts[1].isEmpty,
                      statuses[parts[1]] == nil, let status = LinuxDisplayConnector.Status(rawValue: parts[2]) {
                statuses[parts[1]] = status
            } else if parts.count == 3, parts[0] == "MODE", statuses[parts[1]] != nil, !parts[2].isEmpty {
                modes[parts[1], default: []].append(parts[2])
            } else {
                throw ScreenError.message("Unrecognized Linux status response")
            }
        }
        guard fields["KERNEL"] == "Linux", let name = fields["HOSTNAME"],
              let user = fields["USER"], let architecture = fields["ARCH"] else {
            throw ScreenError.message("SSH host did not report a complete Linux identity")
        }
        return LinuxIdentity(name: name, user: user, architecture: architecture,
            connectors: statuses.keys.sorted().map {
                LinuxDisplayConnector(id: $0, status: statuses[$0]!, modes: modes[$0] ?? [])
            })
    }
}
