import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class ProcessRunnerTests: XCTestCase {
    func testActualStructuredStreamsAndLegacyMergedOrdering() async throws {
        let spec = try await AdapterFixture.specification(["streams"])
        let structured = try await ProcessRunner.runStructured(spec)
        XCTAssertTrue(structured.succeeded)
        XCTAssertEqual(String(decoding: structured.stdout, as: UTF8.self), (0..<40).map { "out-\($0)\n" }.joined())
        XCTAssertEqual(String(decoding: structured.stderr, as: UTF8.self), (0..<40).map { "err-\($0)\n" }.joined())
        let merged = try await ProcessRunner.run(executable: spec.executable, arguments: spec.arguments, timeout: 3)
        XCTAssertTrue(merged.succeeded)
        XCTAssertEqual(merged.text, (0..<40).map { "out-\($0)\nerr-\($0)\n" }.joined())
    }
    func testReplacementEnvironmentGroupCreationAndExplicitDescriptorAllowlist() async throws {
        let directory = try ownedDirectory()
        let sentinel = open(directory.appendingPathComponent("sentinel").path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(sentinel, 0)
        let controller = try DeviceResourceLock(.init(domains: [], controller: true), directory: directory)
        let unlisted = fcntl(sentinel, F_DUPFD, 200)
        let legacy = fcntl(controller.descriptor(forLegacy: "controller.lock")!, F_DUPFD, 201)
        defer { close(sentinel); close(unlisted); close(legacy); withExtendedLifetime(controller) {} }
        XCTAssertEqual(unlisted, 200); XCTAssertEqual(legacy, 201)
        var spec = try await AdapterFixture.specification(["environment"])
        spec.environment = ["FIXTURE_ONLY": "visible", "HOME": "must-be-replaced", "PATH": "must-be-replaced"]
        spec.inheritedDescriptors = [.init(source: sentinel, destination: 210)]
        let output = try await ProcessRunner.runStructured(spec)
        XCTAssertTrue(output.succeeded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        let environment = try XCTUnwrap(json["environment"] as? [String: String])
        // CoreFoundation initializes this one local encoding variable after exec;
        // it is not supplied by the spawn environment.
        XCTAssertEqual(Set(environment.keys).subtracting(["__CF_USER_TEXT_ENCODING"]), Set(["FIXTURE_ONLY", "HOME", "TMPDIR", "PATH", "LANG", "LC_ALL"]))
        XCTAssertEqual(environment["FIXTURE_ONLY"], "visible"); XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["HOME"], environment["TMPDIR"]); XCTAssertNotEqual(environment["HOME"], "must-be-replaced")
        XCTAssertEqual(json["pid"] as? Int32, output.processID); XCTAssertEqual(json["pid"] as? Int, json["group"] as? Int)
        XCTAssertEqual(json["listed"] as? Bool, true); XCTAssertEqual(json["sentinel"] as? Bool, false); XCTAssertEqual(json["legacy"] as? Bool, false)
    }
    func ownedDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp/msi-u2-process-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testCancellationBeforeAndDuringSpawnTransitionHasNoLostChild() async throws {
        let base = try await AdapterFixture.specification(["exit", "0"])
        let before = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await ProcessRunner.runStructured(base) }
        let cancelled = try await before.value
        XCTAssertEqual(cancelled.termination, .cancelled); XCTAssertNil(cancelled.processID)
        let arrived = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        var spec = base
        spec.beforeSpawn = { arrived.signal(); proceed.wait() }
        let task = Task { try await ProcessRunner.runStructured(spec) }
        XCTAssertEqual(arrived.wait(timeout: .now() + 3), .success)
        task.cancel(); proceed.signal()
        let result = try await task.value
        XCTAssertEqual(result.termination, .cancelled); XCTAssertNil(result.processID)
        XCTAssertTrue(result.cleanupConfirmed)
    }
    func testCancellationRacingSpawnBeforePIDRegistrationStillOwnsCleanup() async throws {
        let marker = try ownedDirectory().appendingPathComponent("ready")
        var spec = try await AdapterFixture.specification(["hold", marker.path])
        let spawned = DispatchSemaphore(value: 0), register = DispatchSemaphore(value: 0)
        spec.afterSpawn = { spawned.signal(); register.wait() }
        let task = Task { try await ProcessRunner.runStructured(spec) }
        XCTAssertEqual(spawned.wait(timeout: .now() + 3), .success)
        let cancellationReturned = DispatchSemaphore(value: 0)
        let cancel = Task.detached { task.cancel(); cancellationReturned.signal() }
        // Cancellation itself must not block the caller behind a slow spawn or
        // PID registration. Cleanup still owns any child created in that window.
        XCTAssertEqual(cancellationReturned.wait(timeout: .now() + 0.5), .success)
        register.signal(); await cancel.value
        let output = try await task.value
        XCTAssertNotNil(output.processID); XCTAssertEqual(output.termination, .cancelled); XCTAssertTrue(output.cleanupConfirmed)
        XCTAssertEqual(kill(output.processID!, 0), -1)
    }
    func testNormalExitTimeoutAndCancellationCleanIgnoringDescendants() async throws {
        for mode in ["normal", "timeout", "cancel"] {
            let marker = try ownedDirectory().appendingPathComponent("child")
            let spec = try await AdapterFixture.specification(["descendants", mode, marker.path], timeout: mode == "timeout" ? 0.2 : 3)
            let task = Task { try await ProcessRunner.runStructured(spec) }
            try await AdapterFixture.waitForFile(marker)
            if mode == "cancel" { task.cancel() }
            let output = try await task.value
            XCTAssertEqual(output.termination, mode == "normal" ? .exited : (mode == "cancel" ? .cancelled : .timedOut))
            XCTAssertTrue(output.cleanupConfirmed)
            let child = try XCTUnwrap(Int32(String(contentsOf: marker)))
            defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
            for _ in 0..<100 where kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(kill(child, 0), -1, mode)
        }
    }
    func testCleanupDoesNotKillOtherOwnedGroup() async throws {
        let directory = try ownedDirectory()
        let firstMarker = directory.appendingPathComponent("one"), secondMarker = directory.appendingPathComponent("two")
        let firstSpec = try await AdapterFixture.specification(["hold", firstMarker.path])
        let secondSpec = try await AdapterFixture.specification(["hold", secondMarker.path])
        let first = Task { try await ProcessRunner.runStructured(firstSpec) }
        let second = Task { try await ProcessRunner.runStructured(secondSpec) }
        try await AdapterFixture.waitForFile(firstMarker); try await AdapterFixture.waitForFile(secondMarker)
        let otherPID = try XCTUnwrap(Int32(String(contentsOf: secondMarker)))
        first.cancel(); let firstOutput = try await first.value
        XCTAssertEqual(firstOutput.termination, .cancelled); XCTAssertTrue(firstOutput.cleanupConfirmed)
        XCTAssertEqual(kill(otherPID, 0), 0)
        second.cancel(); let secondOutput = try await second.value
        XCTAssertEqual(secondOutput.termination, .cancelled); XCTAssertTrue(secondOutput.cleanupConfirmed)
    }
    func testStructuredNoiseOverflowFairnessAndDeadline() async throws {
        var spec = try await AdapterFixture.specification(["noise"])
        spec.stdoutLimit = 1024; spec.stderrLimit = 1024
        let overflow = try await ProcessRunner.runStructured(spec)
        XCTAssertEqual(overflow.termination, .outputLimitExceeded); XCTAssertTrue(overflow.cleanupConfirmed)
        XCTAssertLessThanOrEqual(overflow.stdout.count, 1024); XCTAssertLessThanOrEqual(overflow.stderr.count, 1024)
        XCTAssertTrue(String(decoding: overflow.stderr, as: UTF8.self).hasPrefix("stderr-start\n"))
        spec.stdoutLimit = 64 * 1024 * 1024; spec.stderrLimit = 64 * 1024 * 1024; spec.timeout = 0.1
        let start = ProcessInfo.processInfo.systemUptime
        let timeout = try await ProcessRunner.runStructured(spec)
        XCTAssertEqual(timeout.termination, .timedOut); XCTAssertTrue(timeout.cleanupConfirmed)
        XCTAssertGreaterThan(timeout.stdout.count, 0); XCTAssertGreaterThan(timeout.stderr.count, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testStructuredExitAndSignalAreNotSuccess() async throws {
        let exit = try await ProcessRunner.runStructured(AdapterFixture.specification(["exit", "37"]))
        XCTAssertEqual(exit.termination, .exited); XCTAssertEqual(exit.exitCode, 37); XCTAssertFalse(exit.succeeded)
        let signal = try await ProcessRunner.runStructured(AdapterFixture.specification(["signal"]))
        XCTAssertEqual(signal.termination, .signaled); XCTAssertEqual(signal.signal, SIGUSR1); XCTAssertFalse(signal.succeeded)
    }

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

    func testCheckedInvocationScratchParentIsUsedCleanedAndNeverFallsBack() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/msi-u3-scratch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var spec = ProcessRunner.Specification(executable: URL(fileURLWithPath: "/bin/pwd"), timeout: 2,
            environment: ["HOME": "/must-not-use", "TMPDIR": "/must-not-use"], scratchParent: root)
        // The real fixture reports its actual replacement environment.
        let fixture = try await AdapterFixture.build.value; spec.executable = fixture.executable; spec.arguments = ["environment"]
        let output = try await ProcessRunner.runStructured(spec)
        XCTAssertTrue(output.succeeded)
        let object = try JSONSerialization.jsonObject(with: output.stdout) as! [String: Any]
        let environment = object["environment"] as! [String: String]
        let home = try XCTUnwrap(environment["HOME"])
        XCTAssertTrue(home.hasPrefix(root.path + "/.process-")); XCTAssertEqual(environment["TMPDIR"], home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home)); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let linked = root.appendingPathComponent("linked"); XCTAssertEqual(symlink(root.path, linked.path), 0)
        for unsafe in [URL(fileURLWithPath: "relative", relativeTo: URL(fileURLWithPath: ".")), linked] {
            spec.scratchParent = unsafe
            do { _ = try await ProcessRunner.runStructured(spec); XCTFail("Unsafe scratch launched") } catch {}
        }
        XCTAssertEqual(chmod(root.path, 0o755), 0); spec.scratchParent = root
        do { _ = try await ProcessRunner.runStructured(spec); XCTFail("Unsafe scratch launched") } catch {}
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
