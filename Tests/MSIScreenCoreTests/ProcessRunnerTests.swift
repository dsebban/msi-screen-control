import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class ProcessRunnerTests: XCTestCase {
    func testLargeInputAndBothOutputStreamsDoNotDeadlock() async throws {
        let input = String(repeating: "fixture input\n", count: 10_000)
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", "cat; print stderr-marker >&2"],
            timeout: 3, input: Data(input.utf8)
        )
        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.text, input + "stderr-marker\n")
        XCTAssertFalse(output.truncated)
    }

    func testNoisyChildCannotOverrunOutputLimitOrPostponeDeadline() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [], timeout: 0.2, outputLimit: 1_024
        )
        XCTAssertTrue(output.timedOut)
        XCTAssertFalse(output.succeeded)
        XCTAssertTrue(output.truncated)
        XCTAssertEqual(output.text.utf8.count, 1_024)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }

    func testTimeoutKillsIgnoringDescendantAfterShellLeaderExits() async throws {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", "/bin/zsh -c 'trap \"\" TERM; exec /bin/sleep 20' & print $!; wait"],
            timeout: 0.2
        )
        let child = try XCTUnwrap(Int32(output.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // If the test fails, clean up only the descendant this fixture created.
        defer { if Darwin.kill(child, 0) == 0 { _ = Darwin.kill(child, SIGKILL) } }
        XCTAssertTrue(output.timedOut)
        for _ in 0..<100 where Darwin.kill(child, 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Darwin.kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
