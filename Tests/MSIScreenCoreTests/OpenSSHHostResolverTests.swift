import XCTest
@testable import MSIScreenCore

final class OpenSSHHostResolverTests: XCTestCase {
    private let machine = MachineDefinition(id: "saved", name: "Saved", platform: .linux,
                                            input: .hdmi2, host: "gamer@configured-alias")

    func testEffectiveHostComesFromBoundedConfigReadWithoutConnecting() async {
        var arguments: [String] = []
        let resolver = OpenSSHHostResolver { value in
            arguments = value
            return .init(text: "Pseudo-terminal will not be allocated.\nuser gamer\nhostname 100.64.0.2\nport 22\n",
                         exitCode: 0, timedOut: false, truncated: false)
        }
        let host = await resolver.resolvedHost(for: machine)
        XCTAssertEqual(host, "100.64.0.2")
        XCTAssertEqual(arguments, ["-G", "--", "gamer@configured-alias"])
        XCTAssertEqual(machine.host, "gamer@configured-alias")
    }

    func testFailureTruncationAndAmbiguousOrUnsafeHostCannotEstablishAssociation() async {
        let outputs: [ProcessRunner.Output] = [
            .init(text: "hostname 100.64.0.1\n", exitCode: 1, timedOut: false, truncated: false),
            .init(text: "hostname 100.64.0.1\n", exitCode: 0, timedOut: true, truncated: false),
            .init(text: "hostname 100.64.0.1\n", exitCode: 0, timedOut: false, truncated: true),
            .init(text: "hostname one\nhostname two\n", exitCode: 0, timedOut: false, truncated: false),
            .init(text: "hostname user@host\n", exitCode: 0, timedOut: false, truncated: false),
            .init(text: "hostname --option\n", exitCode: 0, timedOut: false, truncated: false),
            .init(text: "hostname host extra\n", exitCode: 0, timedOut: false, truncated: false)
        ]
        for output in outputs {
            let host = await OpenSSHHostResolver { _ in output }.resolvedHost(for: machine)
            XCTAssertNil(host)
        }
    }

    func testNativeTailscaleAndInvalidSavedTargetsDoNotInvokeOpenSSH() async {
        var native = machine
        native.sshTransport = .tailscale
        var invalid = machine
        invalid.host = "bad;target"
        let resolver = OpenSSHHostResolver { _ in
            XCTFail("Only a valid saved standard SSH target may run ssh -G")
            return .init(text: "hostname ignored", exitCode: 0, timedOut: false, truncated: false)
        }
        let nativeHost = await resolver.resolvedHost(for: native)
        let invalidHost = await resolver.resolvedHost(for: invalid)
        XCTAssertNil(nativeHost)
        XCTAssertNil(invalidHost)
    }
}
