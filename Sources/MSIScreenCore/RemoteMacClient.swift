import Foundation

public enum RemoteMacError: LocalizedError {
    case invalidHost
    case tailscaleUnavailable
    case helperMissing
    case timedOut
    case failed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Choose [user@]host using only letters, digits, dots, colons, underscores or hyphens."
        case .tailscaleUnavailable:
            return "The Tailscale command is unavailable. Install or open Tailscale, then try again."
        case .helperMissing:
            return "The MSI Screen companion is missing on the other Mac. Install the companion before changing its display roles."
        case .timedOut:
            return "The other Mac did not respond in time. Check its connection and refresh before trying again."
        case .failed(let details):
            return "The other Mac could not complete the request. \(details)"
        case .invalidResponse:
            return "The other Mac returned an unreadable display response. Check that both Macs use the same MSI Screen version."
        }
    }
}

/// Uses a user-configured SSH host or alias; it neither installs a remote
/// executable nor modifies SSH configuration. All remote actions use one fixed command,
/// with the typed display request carried through stdin.
public struct RemoteMacClient {
    public let host: String
    public let transport: SSHTransport

    public init(host: String, transport: SSHTransport = .standard) {
        self.host = host
        self.transport = transport
    }

    public func state() async throws -> MacDisplayState {
        try await send(MacDisplayRequest(action: .status, expected: nil, target: nil))
    }

    public func makeMain(from state: MacDisplayState, target: MacMainDisplayTarget) async throws -> MacDisplayState {
        try await send(MacDisplayRequest(action: .main, expected: state, target: target))
    }

    public func arrange(from state: MacDisplayState, laptopPosition: MacLaptopPosition) async throws -> MacDisplayState {
        try await send(MacDisplayRequest(action: .arrange, expected: state, laptopPosition: laptopPosition))
    }

    private func send(_ request: MacDisplayRequest) async throws -> MacDisplayState {
        try validateHost()
        let output = try await ProcessRunner.run(
            executable: try transport.executable(),
            arguments: try Self.arguments(host: host, transport: transport),
            timeout: 45, input: JSONEncoder().encode(request)
        )
        return try Self.decode(output)
    }

    func validateHost() throws {
        try SSHTransport.validate(host: host)
    }

    static func arguments(host: String, transport: SSHTransport = .standard) throws -> [String] {
        try transport.arguments(host: host, command:
            // This text is constant. Only the remote shell expands its own
            // HOME, inside double quotes, so paths containing spaces are safe.
            #"if [ ! -x "$HOME/.local/share/msi-screen-control/msi-screen" ]; then printf '%s\n' MSI_SCREEN_HELPER_MISSING >&2; exit 127; fi; exec "$HOME/.local/share/msi-screen-control/msi-screen" display-request"#
        )
    }

    static func decode(_ output: ProcessRunner.Output) throws -> MacDisplayState {
        if output.timedOut { throw RemoteMacError.timedOut }
        if !output.succeeded {
            if output.exitCode == 127 && output.text.contains("MSI_SCREEN_HELPER_MISSING") {
                throw RemoteMacError.helperMissing
            }
            throw RemoteMacError.failed(String(output.text.prefix(2_048))
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !output.truncated,
              let data = output.text.data(using: .utf8),
              let state = try? JSONDecoder().decode(MacDisplayState.self, from: data) else {
            throw RemoteMacError.invalidResponse
        }
        return state
    }
}
