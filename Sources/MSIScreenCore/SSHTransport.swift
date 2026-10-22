import Darwin
import Foundation

public enum SSHTransport: String, Codable, CaseIterable, Sendable {
    case standard, tailscale

    static let tailscaleExecutableCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    func executable(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) throws -> URL {
        switch self {
        case .standard:
            return URL(fileURLWithPath: "/usr/bin/ssh")
        case .tailscale:
            guard let path = Self.tailscaleExecutableCandidates.first(where: isExecutable) else {
                throw RemoteMacError.tailscaleUnavailable
            }
            return URL(fileURLWithPath: path)
        }
    }

    func arguments(host: String, command: String) throws -> [String] {
        try Self.validate(host: host)
        switch self {
        case .standard:
            return ["-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                    "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                    "-o", "LogLevel=ERROR", "--", host, command]
        case .tailscale:
            // The native wrapper verifies the advertised node host key. Do not
            // replace that managed trust with an OpenSSH known_hosts policy.
            return ["ssh", host, "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                    "-o", "LogLevel=ERROR", command]
        }
    }

    static func validate(host: String) throws {
        guard !host.isEmpty, host.utf8.count <= 255, host.first != "-", host.last != "@" else {
            throw RemoteMacError.invalidHost
        }
        let pieces = host.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { throw RemoteMacError.invalidHost }
        let destination = pieces.last.map(String.init) ?? ""
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !destination.isEmpty, destination.first != "-",
              destination.unicodeScalars.allSatisfy(hostCharacters.contains) else {
            throw RemoteMacError.invalidHost
        }
        if destination.contains(":") {
            var address = in6_addr()
            guard destination.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw RemoteMacError.invalidHost
            }
        }
        if pieces.count == 2 {
            let user = String(pieces[0])
            let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard !user.isEmpty, user.first != "-", user.utf8.count <= 64,
                  user.unicodeScalars.allSatisfy(userCharacters.contains) else {
                throw RemoteMacError.invalidHost
            }
        }
    }
}
