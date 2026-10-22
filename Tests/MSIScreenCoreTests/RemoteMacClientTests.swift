import Foundation
import XCTest
@testable import MSIScreenCore

final class RemoteMacClientTests: XCTestCase {
    func testSSHHostRejectsOptionAndShellInjectionBeforeLaunching() {
        for host in ["-oProxyCommand=touch /tmp/unsafe", "peer; whoami", "peer\nwhoami", "peer$(whoami)"] {
            XCTAssertThrowsError(try RemoteMacClient(host: host).validateHost()) { error in
                guard case RemoteMacError.invalidHost = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertNoThrow(try RemoteMacClient(host: "deck@steamdeck", transport: .tailscale).validateHost())
    }

    func testMissingCompanionHasSpecificDiagnostic() {
        let output = ProcessRunner.Output(text: "MSI_SCREEN_HELPER_MISSING\n",
                                          exitCode: 127, timedOut: false, truncated: false)
        XCTAssertThrowsError(try RemoteMacClient.decode(output)) { error in
            guard case RemoteMacError.helperMissing = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTruncatedOrFailedResponseCannotBeReportedAsDisplayState() throws {
        let state = MacDisplayState(computerName: "Fixture Mac", displays: [])
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let truncated = ProcessRunner.Output(text: json, exitCode: 0, timedOut: false, truncated: true)
        XCTAssertThrowsError(try RemoteMacClient.decode(truncated)) { error in
            guard case RemoteMacError.invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let failed = ProcessRunner.Output(text: json, exitCode: 1, timedOut: false, truncated: false)
        XCTAssertThrowsError(try RemoteMacClient.decode(failed)) { error in
            guard case RemoteMacError.failed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
