import Darwin
import Foundation

/// Runs an explicitly chosen executable without a shell, with a deadline and
/// a bounded combined output buffer. Keep the executable and arguments typed
/// or otherwise validated at each feature's boundary.
public enum ProcessRunner {
    public enum ConfigurationError: Error {
        case invalidTimeoutOrOutputLimit
    }
    public struct Output: Sendable {
        public let text: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let truncated: Bool
        public var succeeded: Bool { !timedOut && exitCode == 0 }
    }

    private static let queue = DispatchQueue(
        label: "MSIScreen.external-process", qos: .utility, attributes: .concurrent
    )

    public static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        input: Data? = nil,
        outputLimit: Int = 262_144
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try execute(executable: executable, arguments: arguments,
                                timeout: timeout, input: input, outputLimit: outputLimit)
                })
            }
        }
    }

    private static func execute(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        input: Data?,
        outputLimit: Int
    ) throws -> Output {
        guard timeout.isFinite, timeout > 0, outputLimit > 0 else {
            throw ConfigurationError.invalidTimeoutOrOutputLimit
        }
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var inputDirectory: URL?
        var inputHandle: FileHandle?
        defer {
            try? inputHandle?.close()
            if let inputDirectory { try? FileManager.default.removeItem(at: inputDirectory) }
        }
        if let input {
            // A private file avoids blocking a writer if the child does not
            // consume stdin. Only this invocation's temporary directory is removed.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("msi-screen-process-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            inputDirectory = directory
            let url = directory.appendingPathComponent("stdin")
            try input.write(to: url)
            inputHandle = try FileHandle(forReadingFrom: url)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = output.fileHandleForWriting
        process.standardError = output.fileHandleForWriting
        try process.run()
        // Only the child keeps the writing endpoint. A nonblocking reader never
        // waits for EOF from a descendant that may outlive the direct child.
        try? output.fileHandleForWriting.close()
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid && pid != getpgrp()
        var captured = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 4_096)

        func drain() {
            // Limit each pass so a continuously noisy child cannot postpone
            // the deadline. Discard excess bytes while continuing to drain.
            for _ in 0..<32 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                let remaining = max(0, outputLimit - captured.count)
                captured.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { truncated = true }
            }
        }

        func signalOwnedProcess(_ signal: Int32) {
            // Foundation normally gives its child a process group on macOS.
            // Never signal the app's group or infer ownership from a name.
            // Retain that group's ownership after its leader exits: descendants
            // may ignore TERM, so they still need the bounded KILL escalation.
            if ownsGroup {
                _ = Darwin.kill(-pid, signal)
            } else if process.isRunning {
                _ = Darwin.kill(pid, signal)
            }
        }

        func ownedProcessesRemain() -> Bool {
            process.isRunning || (ownsGroup && Darwin.kill(-pid, 0) == 0)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            signalOwnedProcess(SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while ownedProcessesRemain() && ProcessInfo.processInfo.systemUptime < grace {
                drain()
                Thread.sleep(forTimeInterval: 0.01)
            }
            signalOwnedProcess(SIGKILL)
        }
        process.waitUntilExit()
        drain()
        return Output(text: String(decoding: captured, as: UTF8.self),
                      exitCode: process.terminationStatus,
                      timedOut: timedOut, truncated: truncated)
    }
}
