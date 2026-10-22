import Foundation

/// Reads OpenSSH's effective destination without connecting or changing the
/// saved alias. A failed read cannot establish a discovery association.
public struct OpenSSHHostResolver {
    private let run: ([String]) async throws -> ProcessRunner.Output

    public init() {
        self.init(run: { arguments in
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: arguments, timeout: 3, outputLimit: 65_536)
        })
    }

    init(run: @escaping ([String]) async throws -> ProcessRunner.Output) { self.run = run }

    public func resolvedHost(for machine: MachineDefinition) async -> String? {
        guard machine.access == .ssh, machine.sshTransport == .standard, let host = machine.host,
              (try? SSHTransport.validate(host: host)) != nil else { return nil }
        do {
            let output = try await run(["-G", "--", host])
            guard output.succeeded, !output.truncated else { return nil }
            let rows = output.text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
                .filter { $0.first?.lowercased() == "hostname" }
            guard rows.count == 1, rows[0].count == 2 else { return nil }
            let resolved = String(rows[0][1])
            guard !resolved.contains("@"), (try? SSHTransport.validate(host: resolved)) != nil else { return nil }
            return resolved
        } catch { return nil }
    }
}
