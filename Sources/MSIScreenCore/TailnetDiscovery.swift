import Darwin
import Foundation

public enum TailnetOperatingSystem: String, Codable, Sendable {
    case macos, linux, windows, ios, android, freebsd, openbsd, other

    init(_ value: String?) {
        switch value?.lowercased() {
        case "macos", "darwin": self = .macos
        case "linux": self = .linux
        case "windows": self = .windows
        case "ios": self = .ios
        case "android": self = .android
        case "freebsd": self = .freebsd
        case "openbsd": self = .openbsd
        default: self = .other
        }
    }
}

public struct TailnetPeer: Codable, Equatable, Identifiable, Sendable {
    /// Tailscale's stable node ID, not the rotating public-key dictionary key.
    public let id: String
    public let name: String
    public let hostName: String?
    public let dnsName: String?
    public let operatingSystem: TailnetOperatingSystem
    public let rawOperatingSystem: String?
    public let isSelf: Bool
    /// Advertised by Tailscale; neither SSH reachability nor authentication proof.
    public let advertisedOnline: Bool?
    public let addresses: [String]
    /// A validated connection candidate only. No SSH check is performed here.
    public var sshHostCandidate: String? { dnsName ?? addresses.first }
}

public enum TailnetDiscoveryOutcome: String, Codable, Sendable {
    case complete, incomplete, unavailable, failed
}

public struct TailnetDiscoveryIssue: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case missingExecutable, commandFailed, commandTimedOut, outputLimitExceeded, cancelled
        case invalidJSON, backendNotRunning, missingSelf, missingPeers, tooManyPeers
        case invalidPeer, duplicatePeer, invalidPeerField
    }
    public let code: Code
    public let peerID: String?
    public let message: String
}

public struct TailnetDiscoverySnapshot: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let outcome: TailnetDiscoveryOutcome
    public let backendState: String?
    /// Includes this computer when Self is present, and retains offline peers.
    public let peers: [TailnetPeer]
    public let issues: [TailnetDiscoveryIssue]
}

/// Passive discovery through the installed Tailscale client. It never saves a
/// machine, assigns an input, changes Tailscale settings, or attempts SSH.
public struct TailnetDiscoveryClient {
    static let outputLimit = 1_048_576
    static let peerLimit = 1_024
    private let executables: [URL]
    private let run: (ProcessRunner.Specification) async throws -> ProcessRunner.StructuredOutput

    public init() {
        // Deterministic installed-client fallbacks also work from a GUI app's
        // minimal PATH. The app client is preferred over a stale Homebrew CLI.
        let paths = SSHTransport.tailscaleExecutableCandidates
        self.init(executables: paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }, run: { try await ProcessRunner.runStructured($0) })
    }

    init(executables: [URL],
         run: @escaping (ProcessRunner.Specification) async throws -> ProcessRunner.StructuredOutput) {
        self.executables = executables
        self.run = run
    }

    public func snapshot() async -> TailnetDiscoverySnapshot {
        let checkedAt = Date()
        func failure(_ code: TailnetDiscoveryIssue.Code, _ message: String,
                     outcome: TailnetDiscoveryOutcome = .failed) -> TailnetDiscoverySnapshot {
            TailnetDiscoverySnapshot(checkedAt: checkedAt, outcome: outcome, backendState: nil,
                peers: [], issues: [.init(code: code, peerID: nil, message: message)])
        }
        guard !executables.isEmpty else {
            return failure(.missingExecutable, "Install Tailscale to discover computers on your tailnet.", outcome: .unavailable)
        }
        var lastFailure = failure(.commandFailed, "Tailscale status could not be read.")
        for executable in executables {
            if Task.isCancelled { return failure(.cancelled, "Tailscale discovery was canceled.") }
            do {
                let output = try await run(.init(executable: executable, arguments: ["status", "--json"],
                    timeout: 4, stdoutLimit: Self.outputLimit, stderrLimit: 8_192))
                if output.termination == .cancelled || Task.isCancelled {
                    return failure(.cancelled, "Tailscale discovery was canceled.")
                }
                guard output.succeeded else {
                    if output.termination == .outputLimitExceeded {
                        return failure(.outputLimitExceeded, "Tailscale status exceeded the discovery size limit.")
                    }
                    lastFailure = output.termination == .timedOut
                        ? failure(.commandTimedOut, "Tailscale status timed out.")
                        : failure(.commandFailed, "Tailscale status could not be read. Check that Tailscale is running.")
                    continue
                }
                do { return try Self.parse(output.stdout, checkedAt: checkedAt) }
                catch {
                    lastFailure = failure(.invalidJSON, "Tailscale returned an unreadable status response.")
                }
            } catch {
                if error is CancellationError { return failure(.cancelled, "Tailscale discovery was canceled.") }
                lastFailure = failure(.commandFailed, "The installed Tailscale client could not be started.")
            }
        }
        return lastFailure
    }

    static func parse(_ data: Data, checkedAt: Date = Date()) throws -> TailnetDiscoverySnapshot {
        guard data.count <= outputLimit, let text = String(data: data, encoding: .utf8) else {
            throw DeviceContractError.invalid("tailnetStatusSizeOrEncoding")
        }
        try StrictJSON.rejectDuplicateKeys(text)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceContractError.invalid("tailnetStatusObject")
        }
        var issues: [TailnetDiscoveryIssue] = []
        func issue(_ code: TailnetDiscoveryIssue.Code, _ message: String, peerID: String? = nil) {
            if issues.count < 32 { issues.append(.init(code: code, peerID: peerID, message: message)) }
        }
        let backend = (object["BackendState"] as? String).flatMap { label($0, limit: 64) }
        if backend != "Running" { issue(.backendNotRunning, "Tailscale is not reporting a running connection.") }

        func peer(_ value: Any, isSelf: Bool) -> TailnetPeer? {
            guard let fields = value as? [String: Any], let id = fields["ID"] as? String,
                  (1...128).contains(id.utf8.count), id.utf8.allSatisfy({
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95].contains($0)
                  }) else {
                issue(.invalidPeer, "A Tailscale node has no valid stable identity.")
                return nil
            }
            func invalid(_ field: String) {
                issue(.invalidPeerField, "A Tailscale node has an invalid or missing \(field).", peerID: id)
            }
            let hostName = (fields["HostName"] as? String).flatMap { label($0, limit: 256) }
            if hostName == nil { invalid("hostname") }
            let rawDNS = fields["DNSName"] as? String
            let dns = rawDNS.flatMap(dnsName)
            if let rawDNS, !rawDNS.isEmpty, dns == nil { invalid("DNS name") }
            else if fields["DNSName"] != nil && rawDNS == nil { invalid("DNS name") }
            let os = (fields["OS"] as? String).flatMap { label($0, limit: 64) }
            if os == nil { invalid("operating system") }
            // NSNumber also bridges JSON 0/1 to Bool; accept only actual booleans.
            let onlineValue = fields["Online"] as? NSNumber
            let online = onlineValue.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
            if online == nil { invalid("online status") }
            var addresses: [String] = []
            if let values = fields["TailscaleIPs"] as? [Any], !values.isEmpty, values.count <= 16 {
                for value in values {
                    guard let value = value as? String, let address = address(value) else {
                        invalid("IP address")
                        continue
                    }
                    if !addresses.contains(address) { addresses.append(address) }
                }
            } else { invalid("IP address list") }
            return TailnetPeer(id: id, name: dns?.split(separator: ".").first.map(String.init) ?? hostName ?? id,
                hostName: hostName, dnsName: dns, operatingSystem: .init(os), rawOperatingSystem: os,
                isSelf: isSelf, advertisedOnline: online, addresses: addresses)
        }

        var peers: [TailnetPeer] = []
        if let rawSelf = object["Self"], let local = peer(rawSelf, isSelf: true) { peers.append(local) }
        else { issue(.missingSelf, "Tailscale did not identify this computer.") }
        if let remote = object["Peer"] as? [String: Any] {
            if remote.count > peerLimit { issue(.tooManyPeers, "The tailnet exceeds the discovery node limit.") }
            var seen = Set(peers.map(\.id))
            // The dictionary keys are node public keys. Sorting only makes the
            // bounded parse deterministic; the ID inside each record owns identity.
            for key in remote.keys.sorted().prefix(peerLimit) {
                guard let node = peer(remote[key]!, isSelf: false) else { continue }
                guard seen.insert(node.id).inserted else {
                    issue(.duplicatePeer, "Tailscale returned a repeated node identity.", peerID: node.id)
                    continue
                }
                peers.append(node)
            }
        } else { issue(.missingPeers, "Tailscale did not provide a complete peer list.") }
        peers.sort {
            if $0.isSelf != $1.isSelf { return $0.isSelf }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
        return TailnetDiscoverySnapshot(checkedAt: checkedAt, outcome: issues.isEmpty ? .complete : .incomplete,
                                       backendState: backend, peers: peers, issues: issues)
    }

    private static func label(_ value: String, limit: Int) -> String? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    private static func dnsName(_ value: String) -> String? {
        let name = value.hasSuffix(".") ? String(value.dropLast()) : value
        guard !name.isEmpty, name.utf8.count <= 253 else { return nil }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ part in
            (1...63).contains(part.utf8.count) && part.first != "-" && part.last != "-" && part.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }) else { return nil }
        return name.lowercased()
    }

    private static func address(_ value: String) -> String? {
        // Darwin's IPv6 parser accepts zone suffixes; TailscaleIPs must be bare
        // literals. Check characters before C parsing also rejects embedded NUL.
        guard value.utf8.count <= INET6_ADDRSTRLEN, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || [46, 58].contains($0)
        }) else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            guard inet_ntop(AF_INET, &v4, &output, socklen_t(output.count)) != nil else { return nil }
        } else if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            guard inet_ntop(AF_INET6, &v6, &output, socklen_t(output.count)) != nil else { return nil }
        } else { return nil }
        return String(cString: output)
    }
}
