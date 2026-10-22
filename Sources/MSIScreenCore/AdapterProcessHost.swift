import Darwin
import Foundation
import MachO
import Security

struct AdapterHostIdentity: Codable, Equatable, Sendable {
    let path: String
    let digest: String
    let signature: String
    let buildIdentity: String
    private enum CodingKeys: String, CodingKey { case path, digest, signature, buildIdentity }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["path", "digest", "signature", "buildIdentity"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path); digest = try c.decode(String.self, forKey: .digest)
        signature = try c.decode(String.self, forKey: .signature); buildIdentity = try c.decode(String.self, forKey: .buildIdentity)
        try requireContract(path.hasPrefix("/") && contractDigest(digest) && contractDigest(signature)
            && buildIdentity == AdapterProcessHost.buildIdentity, "hostIdentity")
    }
    private init(path: String, digest: String, signature: String) {
        self.path = path; self.digest = digest; self.signature = signature; buildIdentity = AdapterProcessHost.buildIdentity
    }
    static func currentExecutable() throws -> URL {
        var size: UInt32 = 0; _ = _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&bytes, &size) == 0, let resolved = realpath(bytes, nil) else { throw DeviceContractError.invalid("runtimeUnavailable") }
        defer { free(resolved) }; return URL(fileURLWithPath: String(cString: resolved))
    }
    /// Menu never searches PATH, another bundle or the checkout. A CLI re-execs
    /// only its resolved image. Source Menu without its sibling reports absence.
    static func resolve(bundle: Bundle = .main) throws -> AdapterHostIdentity {
        let current = try currentExecutable()
        let candidate: URL
        if current.lastPathComponent == "msi-screen" { candidate = current }
        else {
            guard bundle.bundleURL.pathExtension == "app", current.deletingLastPathComponent().lastPathComponent == "MacOS" else {
                throw DeviceContractError.invalid("runtimeUnavailable")
            }
            candidate = bundle.bundleURL.appendingPathComponent("Contents/MacOS/msi-screen")
        }
        return try capture(candidate)
    }
    static func capture(_ url: URL) throws -> AdapterHostIdentity {
        // An installed signed application may be root-owned. Unlike mutable
        // Support state, trusted executable ancestry accepts root or this user,
        // but never links, unsafe writable directories or writable code images.
        let path = url.path
        try requireContract(url.isFileURL && path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains { $0 == "." || $0 == ".." }, "hostPath")
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DeviceContractError.invalid("runtimeUnavailable") }
        defer { close(parent) }
        for name in path.split(separator: "/").dropLast().map(String.init) {
            let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DeviceContractError.invalid("runtimeUnavailable") }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == getuid() || info.st_uid == 0,
                  info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else {
                close(next); throw DeviceContractError.invalid("hostPath")
            }
            close(parent); parent = next
        }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw DeviceContractError.invalid("runtimeUnavailable") }
        defer { close(fd) }; var image = stat()
        guard fstat(fd, &image) == 0, image.st_mode & S_IFMT == S_IFREG, image.st_nlink == 1,
              image.st_uid == getuid() || image.st_uid == 0, image.st_mode & 0o022 == 0 else { throw DeviceContractError.invalid("hostPath") }
        let bytes = try SupportDirectory.read(fd, limit: 128 * 1024 * 1024)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw DeviceContractError.invalid("hostSignatureMismatch")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw DeviceContractError.invalid("hostSignatureMismatch") }
        let after = try SupportDirectory.read(fd, limit: 128 * 1024 * 1024)
        var named = stat(); var opened = stat()
        try requireContract(after == bytes && fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0
            && fstat(fd, &opened) == 0 && SupportDirectory.same(named, opened), "hostIntegrityChanged")
        return Self(path: url.path, digest: SupportPackageContent.hash(bytes), signature: SupportPackageContent.hash(hash))
    }
    func validate() throws {
        let current = try Self.capture(URL(fileURLWithPath: path)); try requireContract(current == self, "hostBuildChanged")
    }
}

struct HostInvocation: Codable, Sendable {
    let schema: Int
    let host: AdapterHostIdentity
    let directory: String
    let supportHome: String
    let request: AdapterRequest
    let leaseNames: [String]
    let fixture: DeviceSupportVerificationFixture.Reference?
    private enum CodingKeys: String, CodingKey { case schema, host, directory, supportHome, request, leaseNames, fixture }
    init(host: AdapterHostIdentity, directory: String, supportHome: String, request: AdapterRequest, leaseNames: [String], fixture: DeviceSupportVerificationFixture.Reference? = nil) {
        schema = 1; self.host = host; self.directory = directory; self.supportHome = supportHome; self.request = request; self.leaseNames = leaseNames; self.fixture = fixture
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "host", "directory", "supportHome", "request", "leaseNames", "fixture"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); host = try c.decode(AdapterHostIdentity.self, forKey: .host)
        directory = try c.decode(String.self, forKey: .directory); supportHome = try c.decode(String.self, forKey: .supportHome)
        request = try c.decode(AdapterRequest.self, forKey: .request)
        leaseNames = try c.decode([String].self, forKey: .leaseNames)
        fixture = try c.decodeIfPresent(DeviceSupportVerificationFixture.Reference.self, forKey: .fixture)
        try requireContract(schema == 1 && directory.hasPrefix("/") && supportHome.hasPrefix("/") && leaseNames.count <= 128 && Set(leaseNames).count == leaseNames.count, "hostInvocation")
    }
}

struct AdapterHello: Codable, Equatable {
    let hostAPI: Int
    let buildIdentity: String
    let requestID: UUID
    let providerDigest: String
    let executableDigest: String
    private enum CodingKeys: String, CodingKey { case hostAPI, buildIdentity, requestID, providerDigest, executableDigest }
    init(request: AdapterRequest, executableDigest: String) {
        hostAPI = 1; buildIdentity = request.buildIdentity; requestID = request.requestID
        providerDigest = request.providerDigest; self.executableDigest = executableDigest
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["hostAPI", "buildIdentity", "requestID", "providerDigest", "executableDigest"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        hostAPI = try c.decode(Int.self, forKey: .hostAPI); buildIdentity = try c.decode(String.self, forKey: .buildIdentity)
        requestID = try c.decode(UUID.self, forKey: .requestID); providerDigest = try c.decode(String.self, forKey: .providerDigest)
        executableDigest = try c.decode(String.self, forKey: .executableDigest)
    }
}

/// Every writer has one owner. CLOEXEC and explicit spawn mappings ensure no
/// worker inherits either writer, including when a supervisor is killed.
final class AdapterLiveness: @unchecked Sendable {
    let reader: Int32
    private let lock = NSLock()
    private var writer: Int32
    init() throws {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw POSIXError(.EIO) }
        reader = pair[0]; writer = pair[1]
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    }
    func end() { lock.lock(); defer { lock.unlock() }; if writer >= 0 { close(writer); writer = -1 } }
    deinit { end(); close(reader) }
}

public enum AdapterProcessHost {
    public static let buildIdentity = "msi-support-host-api1-u3-20261021"
    static let liveFD: Int32 = 200
    static let helloFD: Int32 = 201
    static let firstLeaseFD: Int32 = 210
    static var uptimeMilliseconds: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    static func failure(_ error: Error, dispatched: Bool) -> DeviceAdapterFailure {
        if let failure = error as? DeviceAdapterFailure { return failure }
        let code: String
        switch error {
        case DeviceContractError.invalid("hostBuildChanged"), DeviceContractError.invalid("hostIntegrityChanged"): code = "hostBuildChanged"
        case DeviceContractError.invalid("hostSignatureChanged"), DeviceContractError.invalid("hostSignatureMismatch"): code = "hostSignatureChanged"
        case DeviceContractError.invalid("hostPath"): code = "hostUnavailable"
        case DeviceContractError.invalid(let reason) where ["unlistedIdentity", "absentEndpoint", "staleEndpoint", "ambiguousEndpoint", "inventoryIncomplete", "registryChanged", "expiredPlan"].contains(reason): code = reason
        case SupportStorageError.revisionChanged: code = "registryChanged"
        case DeviceContractError.invalid("parentLost"): code = "parentLost"
        case DeviceContractError.invalid("adapterTimeout"): code = "adapterTimeout"
        case DeviceContractError.invalid("providerChanged"): code = "providerChanged"
        case DeviceContractError.invalid("staleBaseline"): code = "staleBaseline"
        case DeviceContractError.invalid("identityMismatch"): code = "identityMismatch"
        case DeviceContractError.invalid("deviceAccessDenied"): code = "deviceAccessDenied"
        case is POSIXError where (error as? POSIXError)?.code == .EACCES || (error as? POSIXError)?.code == .EPERM: code = "osExecutionDenied"
        case is CancellationError: code = "adapterCancelled"
        case SupportStorageError.integrityChanged: code = "integrityChangedDuringRun"
        default: code = "adapterProtocolMismatch"
        }
        return DeviceAdapterFailure(code: code, dispatched: dispatched, cleanupConfirmed: true)
    }

    static func checkLiveness(deadline: Int64, descriptor: Int32 = liveFD) throws {
        try requireContract(uptimeMilliseconds < deadline, "adapterTimeout")
        var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let n = poll(&event, 1, 0)
        try requireContract(n >= 0 && event.revents == 0, "parentLost")
    }
    static func writeAll(_ data: Data, descriptor: Int32) throws {
        // Socket handshakes use SO_NOSIGPIPE. stdout EPIPE is a terminal worker
        // failure, not permission to retry a setter.
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EPIPE) }; offset += n
            }
        }
    }
    static func boundedInput() throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw POSIXError(.EIO) }; if n == 0 { return data }
            data.append(contentsOf: buffer.prefix(n)); try requireContract(data.count <= StrictJSON.byteLimit, "requestSize")
        }
    }
    static func exchangeHello(request: AdapterRequest, executableDigest: String) throws {
        try checkLiveness(deadline: request.deadlineUptimeMilliseconds)
        let hello = try StrictJSON.canonical(AdapterHello(request: request, executableDigest: executableDigest))
        try writeAll(hello + Data([10]), descriptor: helloFD)
        while true {
            try checkLiveness(deadline: request.deadlineUptimeMilliseconds)
            var event = pollfd(fd: helloFD, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 10) > 0 {
                var byte: UInt8 = 0
                try requireContract(Darwin.read(helloFD, &byte, 1) == 1 && byte == 1, "hostHandshakeRejected"); break
            }
        }
    }
    private static func receiveHello(_ fd: Int32, expected: AdapterHello, deadline: Int64) async throws {
        var bytes = Data()
        while uptimeMilliseconds < deadline {
            try Task.checkCancellation()
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 0) > 0 {
                var byte: UInt8 = 0
                try requireContract(Darwin.read(fd, &byte, 1) == 1, "missingHandshake")
                if byte == 10 {
                    let hello = try StrictJSON.decode(AdapterHello.self, from: bytes)
                    try requireContract(hello == expected, "hostWorkerBuildMismatch"); return
                }
                bytes.append(byte); try requireContract(bytes.count <= 4096, "handshakeSize")
            } else { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        throw DeviceContractError.invalid("handshakeTimeout")
    }
    private static func sockets() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        for fd in pair {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return (pair[0], pair[1])
    }
    /// The same supervisor primitive drives host and worker. Cancellation first
    /// closes liveness; the child gets cleanup slack before forced group cleanup.
    static func runSupervised(specification: ProcessRunner.Specification, request: AdapterRequest,
                              expectedExecutableDigest: String, live: AdapterLiveness,
                              beforeRelease: (() async throws -> Void)? = nil) async throws -> ProcessRunner.StructuredOutput {
        let pair = try sockets(); defer { close(pair.0); close(pair.1); live.end() }
        var spec = specification
        spec.inheritedDescriptors += [.init(source: live.reader, destination: liveFD), .init(source: pair.1, destination: helloFD)]
        let worker = Task { try await ProcessRunner.runStructured(spec, cancellationPolicy: .terminate) }
        return try await withTaskCancellationHandler {
            var handshakeComplete = false
            do {
                try await receiveHello(pair.0, expected: AdapterHello(request: request, executableDigest: expectedExecutableDigest),
                    deadline: min(request.deadlineUptimeMilliseconds, uptimeMilliseconds + 5000))
                handshakeComplete = true
                try Task.checkCancellation(); try await beforeRelease?(); try Task.checkCancellation()
                try writeAll(Data([1]), descriptor: pair.0)
            } catch {
                let rejected = handshakeComplete ? failure(error, dispatched: false)
                    : DeviceAdapterFailure(code: Task.isCancelled ? "adapterCancelled" : "hostWorkerBuildMismatch", dispatched: false, cleanupConfirmed: true)
                live.end()
                let escalation = Task { try? await Task.sleep(nanoseconds: 1_000_000_000); if !Task.isCancelled { worker.cancel() } }
                defer { escalation.cancel() }
                let output = try await worker.value
                throw DeviceAdapterFailure(code: rejected.code, dispatched: false, cleanupConfirmed: rejected.cleanupConfirmed && output.cleanupConfirmed)
            }
            let output = try await worker.value
            return output
        } onCancel: {
            live.end()
            Task { try? await Task.sleep(nanoseconds: 1_000_000_000); worker.cancel() }
        }
    }
    static func launch(host: AdapterHostIdentity, invocation: HostInvocation, lease: DeviceResourceLock?, timeout: TimeInterval) async throws -> AdapterResponse {
        try host.validate()
        let live = try AdapterLiveness()
        var spec = ProcessRunner.Specification(executable: URL(fileURLWithPath: host.path), arguments: ["support-host"], timeout: timeout + 4,
            input: try StrictJSON.canonical(invocation), scratchParent: URL(fileURLWithPath: invocation.directory).deletingLastPathComponent().appendingPathComponent("scratch"))
        spec.inheritedDescriptors = (lease?.descriptors ?? []).enumerated().map { .init(source: $0.element, destination: firstLeaseFD + Int32($0.offset)) }
        let output = try await runSupervised(specification: spec, request: invocation.request, expectedExecutableDigest: host.digest, live: live)
        do { try host.validate() }
        catch {
            let rejected = failure(error, dispatched: invocation.request.operation == .apply)
            throw DeviceAdapterFailure(code: rejected.code, dispatched: rejected.dispatched,
                cleanupConfirmed: rejected.cleanupConfirmed && cleanupConfirmed(in: output))
        }
        if Task.isCancelled { throw DeviceAdapterFailure(code: "adapterCancelled", dispatched: invocation.request.operation == .apply, cleanupConfirmed: cleanupConfirmed(in: output)) }
        return try response(output, request: invocation.request)
    }
    /// A decoded worker's negative cleanup evidence is conservative even when
    /// its correlation or a later integrity check fails. It can never upgrade
    /// the process primitive's own unconfirmed cleanup to confirmed.
    static func cleanupConfirmed(in output: ProcessRunner.StructuredOutput) -> Bool {
        guard output.cleanupConfirmed else { return false }
        if let response = try? StrictJSON.decode(AdapterResponse.self, from: output.stdout), case .failed(let failure) = response.result {
            return failure.cleanupConfirmed
        }
        return true
    }
    static func response(_ output: ProcessRunner.StructuredOutput, request: AdapterRequest) throws -> AdapterResponse {
        let cleanup = cleanupConfirmed(in: output)
        guard output.succeeded else {
            let code: String
            switch output.termination {
            case .timedOut: code = "adapterTimeout"
            case .cancelled: code = "adapterCancelled"
            case .outputLimitExceeded: code = "adapterOutputOverflow"
            case .cleanupFailed: code = "cleanupFailed"
            case .signaled: code = "adapterSignal"
            case .exited: code = "adapterExit"
            }
            throw DeviceAdapterFailure(code: code, dispatched: request.operation == .apply, cleanupConfirmed: cleanup)
        }
        do {
            let response = try StrictJSON.decode(AdapterResponse.self, from: output.stdout)
            try response.validate(request: request); return response
        } catch { throw DeviceAdapterFailure(code: "adapterProtocolMismatch", dispatched: request.operation == .apply, cleanupConfirmed: cleanup) }
    }

    /// Public solely for the CLI's hidden early dispatch. There is no public
    /// command parser, path lookup, fallback or device experiment in these modes.
    public static func runInternalMode(_ arguments: [String]) async -> Int32? {
        guard let mode = arguments.first, ["support-host", "support-worker"].contains(mode) else { return nil }
        do {
            signal(SIGPIPE, SIG_IGN)
            try requireContract(fcntl(liveFD, F_GETFD) >= 0 && fcntl(helloFD, F_GETFD) >= 0, "internalDescriptorsRequired")
            if mode == "support-host" {
                try requireContract(arguments.count == 1, "internalArguments")
                let invocation = try StrictJSON.decode(HostInvocation.self, from: boundedInput())
                do { try await supervise(invocation) }
                catch {
                    var failure = failure(error, dispatched: invocation.request.operation == .apply)
                    if uptimeMilliseconds >= invocation.request.deadlineUptimeMilliseconds {
                        failure = DeviceAdapterFailure(code: "adapterTimeout", dispatched: failure.dispatched, cleanupConfirmed: failure.cleanupConfirmed)
                    }
                    try writeAll(StrictJSON.canonical(AdapterResponse(request: invocation.request, result: .failed(failure))), descriptor: STDOUT_FILENO)
                }
            } else {
                try requireContract(arguments.count == 3 || arguments.count == 6, "internalArguments")
                var fixture: DeviceSupportVerificationFixture.Reference?
                if arguments.count == 6 {
                    guard let nonce = UUID(uuidString: arguments[4]) else { throw DeviceContractError.invalid("invalidFixtureReceipt") }
                    fixture = .init(receiptPath: arguments[3], nonce: nonce, receiptDigest: arguments[5])
                }
                let request = try StrictJSON.decode(AdapterRequest.self, from: boundedInput())
                do { try profileWorker(request: request, directory: arguments[1], supportHome: arguments[2], fixture: fixture) }
                catch {
                    let failure = failure(error, dispatched: request.operation == .apply)
                    try writeAll(StrictJSON.canonical(AdapterResponse(request: request, result: .failed(failure))), descriptor: STDOUT_FILENO)
                }
            }
            return 0
        } catch {
            // No raw paths, endpoint data, stderr or arbitrary native messages.
            try? writeAll(Data("supportRuntimeFailed\n".utf8), descriptor: STDERR_FILENO)
            return 1
        }
    }
    private static func supervise(_ invocation: HostInvocation) async throws {
        let current = try AdapterHostIdentity.capture(AdapterHostIdentity.currentExecutable())
        try requireContract(current == invocation.host, "hostBuildChanged")
        try invocation.request.validate()
        try exchangeHello(request: invocation.request, executableDigest: current.digest)
        let directory = try SupportDirectory.root(URL(fileURLWithPath: invocation.directory), create: false)
        let content = try SupportPackageContent.read(directory)
        try requireContract(content.digest == invocation.request.providerDigest, "providerDigestChanged")
        try SupportPackageInstaller.validateNative(content, directory: directory)
        try validatePayload(invocation.request.payload, content: content)
        let fixture = try invocation.fixture.map { try DeviceSupportVerificationFixture(reference: $0) }
        if let fixture {
            try requireContract(invocation.supportHome == fixture.registry.home.path
                && directory.url.deletingLastPathComponent().deletingLastPathComponent().path == fixture.registry.home.appendingPathComponent("invocations").path, "fixtureRootMismatch")
            try fixture.checkedContent(content)
        }
        let supportRegistry = try SupportRegistry(existingHome: URL(fileURLWithPath: invocation.supportHome))
        switch invocation.request.payload {
        case .apply(let plan, _, _): try DeviceContractAuthentication(key: supportRegistry.existingInstallationKey()).verify(plan)
        case .plan(let observation, _): try DeviceContractAuthentication(key: supportRegistry.existingInstallationKey()).verify(observation)
        case .read, .selfTest: break
        }
        let live = try AdapterLiveness()
        let request = invocation.request
        let executable: URL; let arguments: [String]; let digest: String
        switch content.manifest.backend {
        case .profile:
            executable = URL(fileURLWithPath: current.path)
            arguments = ["support-worker", invocation.directory, invocation.supportHome] + (invocation.fixture.map { [$0.receiptPath, $0.nonce.uuidString, $0.receiptDigest] } ?? [])
            digest = current.digest
        case .nativeAdapter(let path, _, _):
            executable = directory.url.appendingPathComponent(path); arguments = []; digest = SupportPackageContent.hash(content.files[path]!)
        }
        let remaining = Double(request.deadlineUptimeMilliseconds - uptimeMilliseconds) / 1000
        try requireContract(remaining > 0, "adapterTimeout")
        var spec = ProcessRunner.Specification(executable: executable, arguments: arguments, timeout: remaining + 1,
            input: try StrictJSON.canonical(request), scratchParent: directory.url.deletingLastPathComponent().appendingPathComponent("scratch"))
        spec.inheritedDescriptors = invocation.leaseNames.indices.map { .init(source: firstLeaseFD + Int32($0), destination: firstLeaseFD + Int32($0)) }
        let task = Task {
            try await runSupervised(specification: spec, request: request, expectedExecutableDigest: digest, live: live) {
                try checkLiveness(deadline: request.deadlineUptimeMilliseconds)
                try await revalidateLive(invocation, content: content, registry: supportRegistry)
            }
        }
        let watcher = Task {
            while !Task.isCancelled {
                do { try checkLiveness(deadline: request.deadlineUptimeMilliseconds) }
                catch { live.end(); task.cancel(); return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        defer { watcher.cancel(); live.end() }
        let output = try await task.value
        do {
            guard try SupportPackageContent.read(directory) == content else { throw SupportStorageError.integrityChanged }
            try SupportPackageInstaller.validateNative(content, directory: directory)
        } catch {
            throw DeviceAdapterFailure(code: "integrityChangedDuringRun", dispatched: request.operation == .apply, cleanupConfirmed: cleanupConfirmed(in: output))
        }
        if uptimeMilliseconds >= request.deadlineUptimeMilliseconds { throw DeviceAdapterFailure(code: "adapterTimeout", dispatched: request.operation == .apply, cleanupConfirmed: cleanupConfirmed(in: output)) }
        let response = try response(output, request: request)
        try writeAll(StrictJSON.canonical(response), descriptor: STDOUT_FILENO)
    }
    private static func validatePayload(_ payload: AdapterPayload, content: SupportPackageContent) throws {
        let descriptor = content.manifest.descriptor
        switch payload {
        case .selfTest: break
        case .plan(let observation, let operation):
            try descriptor.validate(operation: operation)
            try requireContract(observation.identity.providerDigest == content.digest, "providerDigestChanged")
        case .read(let identity, let endpoint, let ids):
            try requireContract(identity.deviceID == endpoint.id && identity.incarnationID == endpoint.incarnationID
                && identity.providerDigest == content.digest && uniqueIDs(ids) && Set(ids).isSubset(of: Set(descriptor.capabilities.map(\.id))), "readTarget")
        case .apply(let plan, let endpoint, let expected):
            try descriptor.validate(operation: plan.operation)
            try requireContract(plan.identity == expected.identity && plan.identity.deviceID == endpoint.id
                && plan.identity.incarnationID == endpoint.incarnationID && plan.identity.providerDigest == content.digest, "applyTarget")
        }
    }
    private static func revalidateLive(_ invocation: HostInvocation, content: SupportPackageContent, registry: SupportRegistry) async throws {
        let endpoint: DeviceEndpoint
        switch invocation.request.payload {
        case .selfTest, .plan:
            try requireContract(invocation.leaseNames.isEmpty, "offlineLeaseForbidden"); return
        case .read(_, let selected, _), .apply(_, let selected, _): endpoint = selected
        }
        // Keyed inventory identity is irrelevant to physical revalidation here:
        // resolve the supplied exact attachment against current raw OS facts.
        let fixture = try invocation.fixture.map { try DeviceSupportVerificationFixture(reference: $0) }
        let required = try fixture?.lockRequest(endpoint, descriptor: content.manifest.descriptor) ?? DeviceResourceLock.controlRequest(endpoint,
            usbGraph: { try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB()) }, descriptor: content.manifest.descriptor)
        let lease = try DeviceResourceLock(borrowing: required, names: invocation.leaseNames, firstDescriptor: firstLeaseFD,
            directory: fixture?.directory.appendingPathComponent("leases"))
        let key = try registry.existingInstallationKey()
        let current: DeviceInventorySnapshot
        if let fixture { current = try fixture.snapshotSynchronously() }
        else { current = try await MacDeviceInventoryReader(identity: DeviceInventoryIdentity(installationKey: key)).snapshot() }
        let metadata = try registry.snapshot()
        let selected = try current.resolve(endpoint)
        let identity: DeviceContractIdentity
        switch invocation.request.payload {
        case .read(let expected, _, _): identity = expected
        case .apply(let plan, _, _):
            try requireContract(plan.registryRevision == metadata.revision, "registryChanged")
            try requireContract(Int64(Date().timeIntervalSince1970 * 1000) < plan.expiresAtMilliseconds, "expiredPlan")
            identity = plan.identity
        default: throw DeviceContractError.invalid("livePayloadRequired")
        }
        let matching = metadata.bindings.filter { $0.enabled && $0.selector.physicalDomainID == selected.physicalDomainID }
        try requireContract(matching.count == 1 && matching[0].id == identity.bindingID && matching[0].digest == content.digest
            && matching[0].selector.id == endpoint.id && matching[0].selector.identity == endpoint.identity, "providerChanged")
        try checkLiveness(deadline: invocation.request.deadlineUptimeMilliseconds)
        if let fixture { try fixture.revalidate(selected, content: content) }
        else {
            try DeviceSupportResolver.guardSelected(endpoint: selected, manifest: content.manifest, lease: lease,
                snapshot: { current }, usbSource: { try USBDeviceGraph.enumerateUSB() })
        }
    }
    static func revalidatePhysical(_ endpoint: DeviceEndpoint) throws {
        switch endpoint.address {
        case .hid:
            _ = try HIDConnection.selectedInterface(for: endpoint, from: USBDeviceGraph.enumerateHID())
        case .usb(let id, let parent):
            let graph = try MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB())
            guard let node = graph.devices.first(where: { $0.id == id }) else { throw DeviceContractError.invalid("absentEndpoint") }
            try requireContract(node.parentID == parent && node.vendor.flatMap(UInt32.init(exactly:)) == endpoint.identity.vendorID
                && node.product.flatMap(UInt32.init(exactly:)) == endpoint.identity.productID, "staleEndpoint")
        default: throw DeviceContractError.invalid("unsupportedControlEndpoint")
        }
    }
    private static func profileWorker(request: AdapterRequest, directory path: String, supportHome: String, fixture reference: DeviceSupportVerificationFixture.Reference? = nil) throws {
        try request.validate()
        let current = try AdapterHostIdentity.capture(AdapterHostIdentity.currentExecutable())
        let directory = try SupportDirectory.root(URL(fileURLWithPath: path), create: false)
        let content = try SupportPackageContent.read(directory)
        try requireContract(content.digest == request.providerDigest, "providerDigestChanged")
        guard case .profile(_, let relativePath) = content.manifest.backend else { throw DeviceContractError.invalid("profileBackendRequired") }
        let profile = try StrictJSON.decode(HIDFeatureProfile.self, from: content.files[relativePath]!)
        try profile.validate(descriptor: content.manifest.descriptor)
        if case .apply(let plan, _, _) = request.payload {
            let registry = try SupportRegistry(existingHome: URL(fileURLWithPath: supportHome))
            try DeviceContractAuthentication(key: registry.existingInstallationKey()).verify(plan)
        }
        try exchangeHello(request: request, executableDigest: current.digest)
        let result: AdapterResult
        if let reference {
            let fixture = try DeviceSupportVerificationFixture(reference: reference)
            try requireContract(fixture.registry.home.path == supportHome, "fixtureRootMismatch")
            result = try fixture.profileResult(request: request, content: content)
        } else {
        switch request.payload {
        case .selfTest:
            try HIDFeatureProfileExecutor.selfTest(profile: profile, descriptor: content.manifest.descriptor); result = .selfTest
        case .plan(_, let operation):
            try content.manifest.descriptor.validate(operation: operation); result = .plan(operation)
        case .read(let identity, let endpoint, _):
            try revalidatePhysical(endpoint)
            let transport = try SelectedHIDFeatureTransport(endpoint: endpoint) { try checkLiveness(deadline: request.deadlineUptimeMilliseconds) }
            let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: content.manifest.descriptor, identity: identity, transport: transport)
            result = .read(try executor.read())
            withExtendedLifetime(executor) {}
        case .apply(let plan, let endpoint, let expected):
            try revalidatePhysical(endpoint)
            let transport = try SelectedHIDFeatureTransport(endpoint: endpoint) { try checkLiveness(deadline: request.deadlineUptimeMilliseconds) }
            let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: content.manifest.descriptor, identity: plan.identity, transport: transport)
            result = .apply(try executor.apply(plan.operation, expected: expected))
            withExtendedLifetime(executor) {}
        }
        }
        try checkLiveness(deadline: request.deadlineUptimeMilliseconds)
        let after = try SupportPackageContent.read(directory)
        try requireContract(after == content, "integrityChangedDuringRun")
        try writeAll(StrictJSON.canonical(AdapterResponse(request: request, result: result)), descriptor: STDOUT_FILENO)
    }
}
