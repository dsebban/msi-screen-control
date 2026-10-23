import Foundation

public struct LinuxDisplayConnector: Codable, Equatable, Identifiable {
    public enum Status: String, Codable { case connected, disconnected, unknown }
    public let id: String
    public let status: Status
    /// Modes advertised through DRM. They do not identify the active video mode.
    public let modes: [String]
    /// This identifies the attached display, not the monitor-side input number.
    public let identification: DisplayIdentification?
    /// Nil with no identification means an older probe did not report EDID.
    public let identificationError: String?

    public init(id: String, status: Status, modes: [String],
                identification: DisplayIdentification? = nil, identificationError: String? = nil) {
        self.id = id; self.status = status; self.modes = modes
        self.identification = identification; self.identificationError = identificationError
    }
}

public struct MachineStatus: Codable {
    public let machineID: String
    /// Display label. Its observed or configured origin is explicit below.
    public let name: String
    public let configuredName: String
    public let observedName: String?
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
        self.init(machineID: machine.id, configuredName: machine.name,
                  observedName: macDisplays.computerName, platform: .macos,
                  checkedAt: Date(), reachable: true, user: machine.isLocal ? NSUserName() : nil,
                  architecture: nil, macDisplays: macDisplays, connectors: [], error: nil)
    }

    init(machineID: String, configuredName: String, observedName: String?, platform: MachinePlatform, checkedAt: Date,
         reachable: Bool?, user: String?, architecture: String?, macDisplays: MacDisplayState?,
         connectors: [LinuxDisplayConnector], error: String?) {
        self.machineID = machineID
        self.name = observedName ?? configuredName
        self.configuredName = configuredName
        self.observedName = observedName
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
                return MachineStatus(machineID: machine.id, configuredName: machine.name, observedName: nil, platform: machine.platform,
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
            return MachineStatus(machineID: machine.id, configuredName: machine.name,
                                 observedName: result.name, platform: .linux, checkedAt: Date(),
                                 reachable: true, user: result.user, architecture: result.architecture,
                                 macDisplays: nil, connectors: result.connectors, error: nil)
        } catch {
            let reached: Bool?
            if case RemoteMacError.helperMissing = error { reached = true } else { reached = nil }
            return MachineStatus(machineID: machine.id, configuredName: machine.name, observedName: nil, platform: machine.platform,
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
    edid_reader_available=1
    command -v od >/dev/null 2>&1 && command -v tr >/dev/null 2>&1 || edid_reader_available=0
    for path in /sys/class/drm/card*-*/status; do
        [ -r "$path" ] || continue
        connector=${path%/status}
        connector=${connector##*/}
        connector_status=$(cat "$path")
        printf 'CONNECTOR\t%s\t%s\n' "$connector" "$connector_status"
        modes=${path%/status}/modes
        if [ -r "$modes" ]; then
            while IFS= read -r mode; do printf 'MODE\t%s\t%s\n' "$connector" "$mode"; done < "$modes"
        fi
        if [ "$connector_status" = connected ]; then
            edid=${path%/status}/edid
            if [ "$edid_reader_available" -ne 1 ]; then
                printf 'EDID_ERROR\t%s\treaderUnavailable\n' "$connector"
            elif [ ! -r "$edid" ]; then
                printf 'EDID_ERROR\t%s\tunreadable\n' "$connector"
            elif edid_dump=$(LC_ALL=C od -An -v -tx1 -N 4097 "$edid" 2>/dev/null); then
                edid_hex=$(printf '%s' "$edid_dump" | tr -d ' \n')
                if [ -z "$edid_hex" ]; then
                    printf 'EDID_ERROR\t%s\tempty\n' "$connector"
                elif [ "${#edid_hex}" -gt 8192 ]; then
                    printf 'EDID_ERROR\t%s\ttooLarge\n' "$connector"
                else
                    printf 'EDID\t%s\t%s\n' "$connector" "$edid_hex"
                fi
            else
                printf 'EDID_ERROR\t%s\tunreadable\n' "$connector"
            fi
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
        var identifications: [String: DisplayIdentification] = [:]
        var identificationErrors: [String: String] = [:]
        var identificationRows = Set<String>()
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
            } else if parts.count == 3, ["EDID", "EDID_ERROR"].contains(parts[0]),
                      statuses[parts[1]] == .connected, identificationRows.insert(parts[1]).inserted {
                if parts[0] == "EDID_ERROR" {
                    guard ["readerUnavailable", "unreadable", "empty", "tooLarge"].contains(parts[2]) else {
                        throw ScreenError.message("Unrecognized Linux EDID error")
                    }
                    identificationErrors[parts[1]] = parts[2]
                } else {
                    let hex = parts[2]
                    guard !hex.isEmpty, hex.utf8.count <= 8192, hex.utf8.count % 2 == 0,
                          hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
                        throw ScreenError.message("Invalid Linux EDID response")
                    }
                    let bytes = Array(hex.utf8)
                    var data = Data(capacity: bytes.count / 2)
                    for index in stride(from: 0, to: bytes.count, by: 2) {
                        data.append(UInt8(String(decoding: bytes[index...index + 1], as: UTF8.self), radix: 16)!)
                    }
                    do { identifications[parts[1]] = try DisplayIdentification(edid: data) }
                    catch let failure as DisplayIdentificationError { identificationErrors[parts[1]] = failure.rawValue }
                }
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
                LinuxDisplayConnector(id: $0, status: statuses[$0]!, modes: modes[$0] ?? [],
                                      identification: identifications[$0], identificationError: identificationErrors[$0])
            })
    }
}
