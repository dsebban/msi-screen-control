import XCTest
@testable import MSIScreenCore

final class SSHTransportTests: XCTestCase {
    func testStandardTransportPreservesStrictOpenSSHArguments() throws {
        let arguments = try SSHTransport.standard.arguments(host: "fixture-host", command: "fixed-command")
        XCTAssertEqual(arguments, [
            "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR", "--", "fixture-host", "fixed-command",
        ])
        XCTAssertEqual(try SSHTransport.standard.executable { _ in false }.path, "/usr/bin/ssh")
    }

    func testTailscaleTransportUsesManagedHostTrustAndUserDestination() throws {
        let arguments = try SSHTransport.tailscale.arguments(host: "deck@steamdeck", command: "fixed-command")
        XCTAssertEqual(arguments, [
            "ssh", "deck@steamdeck", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR", "fixed-command",
        ])
        XCTAssertFalse(arguments.contains(where: { $0.contains("StrictHostKeyChecking") }))
        XCTAssertFalse(arguments.contains(where: { $0.contains("known_hosts") }))
    }

    func testTailscaleExecutableUsesFirstInstalledCandidateAndFailsWhenAbsent() throws {
        let selected = try SSHTransport.tailscale.executable { path in
            path == "/opt/homebrew/bin/tailscale" || path == "/usr/local/bin/tailscale"
        }
        XCTAssertEqual(selected.path, "/opt/homebrew/bin/tailscale")
        XCTAssertThrowsError(try SSHTransport.tailscale.executable { _ in false }) { error in
            guard case RemoteMacError.tailscaleUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDestinationAcceptsMagicDNSIPAndOptionalUserButRejectsInjection() throws {
        for host in ["steamdeck", "steamdeck.tailnet.ts.net", "100.64.0.10", "fd7a:115c:a1e0::1",
                     "deck@steamdeck", "deck.user@100.64.0.10", "deck@fd7a:115c:a1e0::1"] {
            XCTAssertNoThrow(try SSHTransport.validate(host: host), host)
        }
        for host in ["", "-oProxyCommand=bad", "@steamdeck", "deck@", "deck@@steamdeck",
                     "deck user@steamdeck", "deck@steamdeck;whoami", "deck@$(whoami)",
                     "deck@steamdeck\nwhoami", "bad:host", "deck@1::2::3"] {
            XCTAssertThrowsError(try SSHTransport.validate(host: host), host)
        }
    }

    func testEveryRemoteClientBuildsTheChosenTransportArguments() throws {
        let remoteMac = try RemoteMacClient.arguments(host: "deck@steamdeck", transport: .tailscale)
        let linux = try MachineStatusClient.linuxArguments(host: "deck@steamdeck", transport: .tailscale)
        let kvm = try RemoteKVMEndpoint.arguments(host: "deck@steamdeck", transport: .tailscale)
        for arguments in [remoteMac, linux, kvm] {
            XCTAssertEqual(arguments.prefix(2), ["ssh", "deck@steamdeck"])
            XCTAssertFalse(arguments.contains(where: { $0.contains("StrictHostKeyChecking") }))
        }
        XCTAssertNotEqual(remoteMac.last, linux.last)
        XCTAssertNotEqual(linux.last, kvm.last)
    }
}
