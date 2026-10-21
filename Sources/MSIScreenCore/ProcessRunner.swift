import Darwin
import Foundation

/// One spawn primitive for legacy merged capture and bounded structured workers.
public enum ProcessRunner {
    public enum ConfigurationError: Error { case invalidTimeoutOrOutputLimit, invalidSpecification }
    public struct Output: Sendable {
        public let text: String
        public let exitCode: Int32
        public let timedOut: Bool
        public let truncated: Bool
        public var succeeded: Bool { !timedOut && exitCode == 0 }
    }
    public enum Termination: String, Sendable { case exited, signaled, timedOut, cancelled, outputLimitExceeded, cleanupFailed }
    public enum CancellationPolicy: Sendable { case terminate, ignore }
    public struct InheritedDescriptor: Sendable {
        public let source: Int32
        public let destination: Int32
        public init(source: Int32, destination: Int32) { self.source = source; self.destination = destination }
    }
    public struct Specification: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var timeout: TimeInterval
        public var input: Data?
        public var stdoutLimit: Int
        public var stderrLimit: Int
        /// Replacement, never appended to the parent's environment. HOME/TMPDIR,
        /// PATH and locale below are reserved and supplied by the primitive.
        public var environment: [String: String]
        public var inheritedDescriptors: [InheritedDescriptor]
        /// Optional checked 0700 invocation directory. Invalid roots fail closed;
        /// legacy/default callers keep their existing private system-temp path.
        public var scratchParent: URL?
        // Deterministic spawn-transition fixture seam; not a public launch hook.
        var beforeSpawn: (@Sendable () -> Void)?
        var afterSpawn: (@Sendable () -> Void)?
        public init(executable: URL, arguments: [String] = [], timeout: TimeInterval,
                    input: Data? = nil, stdoutLimit: Int = 262144, stderrLimit: Int = 65536,
                    environment: [String: String] = [:], inheritedDescriptors: [InheritedDescriptor] = [], scratchParent: URL? = nil) {
            self.executable = executable; self.arguments = arguments; self.timeout = timeout; self.input = input
            self.stdoutLimit = stdoutLimit; self.stderrLimit = stderrLimit; self.environment = environment
            self.inheritedDescriptors = inheritedDescriptors; self.scratchParent = scratchParent
        }
    }
    public struct StructuredOutput: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let termination: Termination
        public let exitCode: Int32?
        public let signal: Int32?
        public let processID: Int32?
        public let cleanupConfirmed: Bool
        public var succeeded: Bool { termination == .exited && exitCode == 0 && cleanupConfirmed }
    }
    private final class Lifecycle: @unchecked Sendable {
        enum Phase { case preparing, spawning, running(pid_t), finished }
        private let lock = NSLock()
        private var phase = Phase.preparing
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        /// Cancellation only records intent; this execution thread always owns
        /// pid registration and cleanup, including cancellation inside spawn.
        /// Never hold the mutex across the OS call and block the cancelling UI.
        func spawn(_ body: () throws -> pid_t) throws -> pid_t? {
            lock.lock()
            if cancelled { phase = .finished; lock.unlock(); return nil }
            phase = .spawning; lock.unlock()
            do {
                let pid = try body()
                lock.lock(); phase = .running(pid); lock.unlock()
                return pid
            } catch {
                lock.lock(); phase = .finished; lock.unlock()
                throw error
            }
        }
        func finish() { lock.lock(); phase = .finished; lock.unlock() }
    }
    private static let queue = DispatchQueue(label: "MSIScreen.external-process", qos: .utility, attributes: .concurrent)

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                           input: Data? = nil, outputLimit: Int = 262144) async throws -> Output {
        let spec = Specification(executable: executable, arguments: arguments, timeout: timeout,
                                 input: input, stdoutLimit: outputLimit, stderrLimit: outputLimit)
        let result = try await schedule(spec, legacy: true, lifecycle: Lifecycle())
        return Output(text: String(decoding: result.output.stdout, as: UTF8.self), exitCode: result.output.cleanupConfirmed ? (result.output.exitCode ?? result.output.signal ?? -1) : -1,
                      timedOut: result.deadlineExpired, truncated: result.truncated)
    }
    public static func runStructured(_ specification: Specification, cancellationPolicy: CancellationPolicy = .terminate) async throws -> StructuredOutput {
        let lifecycle = Lifecycle()
        return try await withTaskCancellationHandler {
            if Task.isCancelled && cancellationPolicy == .terminate { lifecycle.cancel() }
            return try await schedule(specification, legacy: false, lifecycle: lifecycle).output
        } onCancel: { if cancellationPolicy == .terminate { lifecycle.cancel() } }
    }
    private struct Capture { let output: StructuredOutput; let truncated: Bool; let deadlineExpired: Bool }
    private static func schedule(_ spec: Specification, legacy: Bool, lifecycle: Lifecycle) async throws -> Capture {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try execute(spec, legacy: legacy, lifecycle: lifecycle) }) }
        }
    }
    private static func execute(_ spec: Specification, legacy: Bool, lifecycle: Lifecycle) throws -> Capture {
        defer { lifecycle.finish() }
        guard spec.timeout.isFinite, spec.timeout > 0, spec.stdoutLimit > 0, spec.stderrLimit > 0 else { throw ConfigurationError.invalidTimeoutOrOutputLimit }
        guard spec.executable.isFileURL, spec.executable.path.hasPrefix("/"), !spec.executable.path.contains("\0"),
              spec.arguments.allSatisfy({ !$0.contains("\0") }),
              spec.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }),
              legacy || (spec.input?.count ?? 0) <= 262144,
              spec.inheritedDescriptors.allSatisfy({ $0.source >= 0 && $0.destination >= 3 && $0.destination < 1024 && fcntl($0.source, F_GETFD) >= 0 }),
              Set(spec.inheritedDescriptors.map(\.destination)).count == spec.inheritedDescriptors.count else { throw ConfigurationError.invalidSpecification }
        var deadline = ProcessInfo.processInfo.systemUptime + spec.timeout
        func unspawned(_ reason: Termination) -> Capture {
            Capture(output: StructuredOutput(stdout: Data(), stderr: Data(), termination: reason, exitCode: nil, signal: nil, processID: nil, cleanupConfirmed: true), truncated: false, deadlineExpired: reason == .timedOut)
        }
        if lifecycle.isCancelled { return unspawned(.cancelled) }
        var owned: [Int32] = []
        defer { for fd in owned { close(fd) } }
        func own(_ fd: Int32) throws -> Int32 {
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            owned.append(fd); return fd
        }
        func pipePair() throws -> (Int32, Int32) {
            var pair = [Int32](repeating: -1, count: 2)
            guard pipe(&pair) == 0 else { throw POSIXError(.EIO) }
            _ = try own(pair[0]); _ = try own(pair[1])
            for fd in pair { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) } }
            let flags = fcntl(pair[0], F_GETFL)
            guard flags >= 0, fcntl(pair[0], F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            return (pair[0], pair[1])
        }
        let stdout = try pipePair(), stderr = legacy ? stdout : try pipePair()
        let directory: URL
        let directoryFD: Int32
        var scratch: (SupportDirectory, SupportDirectory, String)?
        if let parentURL = spec.scratchParent {
            guard parentURL.baseURL == nil, parentURL.isFileURL, parentURL.relativePath.hasPrefix("/") else { throw SupportStorageError.unavailableRoot }
            let parent = try SupportDirectory.root(parentURL, create: false)
            let name = ".process-" + UUID().uuidString
            guard mkdirat(parent.fd, name, 0o700) == 0 else { throw SupportStorageError.unsafeFile }
            let child = try parent.directory(name)
            scratch = (child, parent, name); directory = child.url
            directoryFD = try own(fcntl(child.fd, F_DUPFD_CLOEXEC, 3))
        } else {
            var template = Array((FileManager.default.temporaryDirectory.path + "/msi-screen-process-XXXXXX").utf8CString)
            guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
            directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
            directoryFD = try own(open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        defer {
            if let (child, parent, name) = scratch { SupportPackageInstaller.cleanupOwned(child, parent: parent, name: name) }
            else { try? FileManager.default.removeItem(at: directory) }
        }
        let inputFD: Int32
        if let input = spec.input {
            inputFD = try own(openat(directoryFD, "stdin", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
            try SupportDirectory.write(input, to: inputFD)
            guard lseek(inputFD, 0, SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        } else { inputFD = try own(open("/dev/null", O_RDONLY | O_CLOEXEC)) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        func checked(_ result: Int32) throws { if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) } }
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(); sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE, SIGQUIT] { sigaddset(&mask, signal) }
        try checked(posix_spawnattr_setsigdefault(&attributes, &mask))
        // Duplicate sources above all target numbers first: remapping must never
        // accidentally overwrite a later source, including borrowed descriptions.
        let minimum = max(64, (spec.inheritedDescriptors.map(\.destination).max() ?? 3) + 1)
        let mappings = [InheritedDescriptor(source: inputFD, destination: 0), InheritedDescriptor(source: stdout.1, destination: 1), InheritedDescriptor(source: stderr.1, destination: 2)] + spec.inheritedDescriptors
        for mapping in mappings {
            let copy = try own(fcntl(mapping.source, F_DUPFD_CLOEXEC, minimum))
            try checked(posix_spawn_file_actions_adddup2(&actions, copy, mapping.destination))
        }
        var environment = legacy ? ProcessInfo.processInfo.environment : spec.environment
        if !legacy {
            environment["PATH"] = "/usr/bin:/bin"; environment["HOME"] = directory.path; environment["TMPDIR"] = directory.path
            environment["LANG"] = "C"; environment["LC_ALL"] = "C"
        }
        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0)! }
        let env = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!)! }
        defer { for p in argv + env { free(p) } }
        var arguments: [UnsafeMutablePointer<CChar>?] = argv.map { $0 } + [nil]
        var variables: [UnsafeMutablePointer<CChar>?] = env.map { $0 } + [nil]
        spec.beforeSpawn?()
        if !legacy && ProcessInfo.processInfo.systemUptime >= deadline { return unspawned(lifecycle.isCancelled ? .cancelled : .timedOut) }
        guard let pid = try lifecycle.spawn({
            var pid: pid_t = 0
            let result = posix_spawn(&pid, spec.executable.path, &actions, &attributes, &arguments, &variables)
            try checked(result)
            spec.afterSpawn?()
            return pid
        }) else { return unspawned(.cancelled) }
        // Legacy deadlines historically cover the launched process, not stdin
        // preparation. Structured invocation budgets include preparation/spawn.
        if legacy { deadline = ProcessInfo.processInfo.systemUptime + spec.timeout }
        // All parent writer copies, including dup sources, close before draining.
        let retained = Set([stdout.0, stderr.0, directoryFD])
        for fd in owned where !retained.contains(fd) { close(fd) }
        owned.removeAll { !retained.contains($0) }
        var out = Data(), err = Data(), truncated = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        func drain(_ fd: Int32, _ data: inout Data, _ limit: Int) {
            for _ in 0..<8 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let remaining = max(0, limit - data.count)
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { truncated = true }
            }
        }
        func drainBoth() { drain(stdout.0, &out, spec.stdoutLimit); if !legacy { drain(stderr.0, &err, spec.stderrLimit) } }
        var waitFailure = false
        func leaderExited() -> Bool {
            var info = siginfo_t()
            // Keep the leader waitable until cleanup finishes. Its reserved PID
            // prevents process-group ID reuse while signals are still possible.
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
                if errno != EINTR { waitFailure = true }; return false
            }
            return info.si_pid == pid
        }
        var reason: Termination = .exited
        while true {
            drainBoth()
            if lifecycle.isCancelled { reason = .cancelled; break }
            if !legacy && truncated { reason = .outputLimitExceeded; break }
            if leaderExited() { break }
            if waitFailure { reason = .cleanupFailed; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { reason = .timedOut; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let expired = reason == .timedOut
        // Group creation was atomic in posix_spawn; never fall back to the
        // caller's group, a name lookup, or a reaped/reusable numeric pid.
        let ownsGroup = pid > 1 && pid != getpgrp() && !waitFailure
        var cleanupConfirmed = ownsGroup
        if ownsGroup {
            _ = Darwin.kill(-pid, SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while ProcessInfo.processInfo.systemUptime < grace {
                drainBoth()
                if liveGroupMembers(pid) == false { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if liveGroupMembers(pid) != false { _ = Darwin.kill(-pid, SIGKILL) }
            let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while liveGroupMembers(pid) == true && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
                drainBoth(); Thread.sleep(forTimeInterval: 0.005)
            }
            cleanupConfirmed = liveGroupMembers(pid) == false
        }
        var status: Int32 = 0
        var waited: pid_t = 0
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        repeat {
            waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited < 0 && errno != EINTR) { break }
            drainBoth(); Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < reapDeadline
        cleanupConfirmed = cleanupConfirmed && waited == pid
        // Bounded final capture; EOF is not trusted because a contract-breaking
        // child may have escaped the owned group with a pipe still open.
        for _ in 0..<4 { drainBoth() }
        if !legacy && truncated && reason == .exited { reason = .outputLimitExceeded }
        let signal = status & 0x7f
        if !cleanupConfirmed { reason = .cleanupFailed }
        else if reason == .exited && signal != 0 { reason = .signaled }
        return Capture(output: StructuredOutput(stdout: out, stderr: err, termination: reason,
            exitCode: signal == 0 && waited == pid ? (status >> 8) & 0xff : nil,
            signal: signal != 0 ? signal : nil, processID: pid, cleanupConfirmed: cleanupConfirmed), truncated: truncated, deadlineExpired: expired)
    }
    private static func liveGroupMembers(_ group: pid_t) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        // Extra capacity covers forks between size discovery and collection.
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
        size = entries.count * MemoryLayout<kinfo_proc>.stride
        let result = entries.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return entries.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { $0.kp_proc.p_stat != Int8(SZOMB) }
    }
}
