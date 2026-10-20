import AppKit
import Darwin
import Foundation

/// The Mac's interpretation of F18/F19; selecting it never writes to the mouse.
public enum RapooWheelHostAction: String, Codable, CaseIterable, Sendable {
    case applications, spaces
}

public struct RapooAppSwitchStatus: Codable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let enabled: Bool
    public let hotkeysRegistered: Bool
    public let switchCount: Int
    public let lastApplication: String?
    public let error: String?
    public let hostAction: RapooWheelHostAction
    public let activeHostAction: RapooWheelHostAction?
    /// Posted Space shortcuts, not confirmation that macOS changed Spaces.
    public let spaceRequestCount: Int
    public let lastSpaceDirection: String?
    public let pinnedBundleIdentifier: String?
    public let pinHotkeyRegistered: Bool
    public let pinRequestCount: Int
    public let lastPinnedApplication: String?
    public let pinError: String?
    public let permissions: AppPermissionStatus?

    public init(enabled: Bool, hotkeysRegistered: Bool, switchCount: Int,
                lastApplication: String? = nil, error: String? = nil,
                hostAction: RapooWheelHostAction = .applications,
                activeHostAction: RapooWheelHostAction? = nil,
                spaceRequestCount: Int = 0, lastSpaceDirection: String? = nil,
                pinnedBundleIdentifier: String? = nil, pinHotkeyRegistered: Bool = false,
                pinRequestCount: Int = 0, lastPinnedApplication: String? = nil, pinError: String? = nil,
                permissions: AppPermissionStatus? = nil) {
        schemaVersion = 1
        checkedAt = Date()
        self.enabled = enabled
        self.hotkeysRegistered = hotkeysRegistered
        self.switchCount = switchCount
        self.lastApplication = lastApplication
        self.error = error
        self.hostAction = hostAction
        self.activeHostAction = activeHostAction
        self.spaceRequestCount = spaceRequestCount
        self.lastSpaceDirection = lastSpaceDirection
        self.pinnedBundleIdentifier = pinnedBundleIdentifier
        self.pinHotkeyRegistered = pinHotkeyRegistered
        self.pinRequestCount = pinRequestCount
        self.lastPinnedApplication = lastPinnedApplication
        self.pinError = pinError
        self.permissions = permissions
    }
}

public struct RapooAppControlRequest: Codable {
    public enum Action: String, Codable {
        case status
        case setSideWheel = "set-side-wheel"
        case setHostAction = "set-host-action"
        case setTopButton = "set-top-button"
    }
    public let schemaVersion: Int
    public let id: String
    public let targetPID: Int32
    public let expiresAt: Date
    public let action: Action
    public let preset: RapooSideWheelPreset?
    public let expected: [RapooWheelMapping]?
    public let hostAction: RapooWheelHostAction?
    public let topButtonPreset: RapooTopButtonPreset?
    public let expectedRecordHex: String?
    public let bundleIdentifier: String?

    init(targetPID: Int32, action: Action, preset: RapooSideWheelPreset?, expected: [RapooWheelMapping]?,
         hostAction: RapooWheelHostAction? = nil, topButtonPreset: RapooTopButtonPreset? = nil,
         expectedRecordHex: String? = nil, bundleIdentifier: String? = nil) {
        schemaVersion = 1
        id = UUID().uuidString.lowercased()
        self.targetPID = targetPID
        expiresAt = Date().addingTimeInterval(15)
        self.action = action
        self.preset = preset
        self.expected = expected
        self.hostAction = hostAction
        self.topButtonPreset = topButtonPreset
        self.expectedRecordHex = expectedRecordHex
        self.bundleIdentifier = bundleIdentifier
    }

    /// Call again immediately before starting a mutation if app setup awaited.
    public func validateBeforeHandling() throws {
        try validate(targetPID: getpid())
    }

    func validate(targetPID: Int32, now: Date = Date()) throws {
        guard schemaVersion == 1, validRapooRequestID(id), self.targetPID == targetPID,
              targetPID > 0, expiresAt > now, expiresAt.timeIntervalSince(now) <= 16 else {
            throw ScreenError.message("Invalid, expired, or differently targeted Rapoo app request")
        }
        switch action {
        case .status:
            guard preset == nil, expected == nil, hostAction == nil,
                  topButtonPreset == nil, expectedRecordHex == nil, bundleIdentifier == nil else {
                throw ScreenError.message("Rapoo status accepts no mapping or host action")
            }
        case .setHostAction:
            guard hostAction != nil, preset == nil, expected == nil,
                  topButtonPreset == nil, expectedRecordHex == nil, bundleIdentifier == nil else {
                throw ScreenError.message("Rapoo host action accepts only applications or spaces, without mouse mappings")
            }
        case .setSideWheel:
            guard hostAction == nil, topButtonPreset == nil, expectedRecordHex == nil, bundleIdentifier == nil,
                  preset != nil, let expected, expected.count == 2,
                  Set(expected.map(\.keyID)) == Set([7, 8]), expected.allSatisfy({
                      validRapooRecordHex($0.rawRecordHex)
                  }) else { throw ScreenError.message("Rapoo mapping requires both complete expected records") }
        case .setTopButton:
            guard preset == nil, expected == nil, hostAction == nil, let topButtonPreset,
                  let expectedRecordHex, validRapooRecordHex(expectedRecordHex) else {
                throw ScreenError.message("Rapoo top button requires a fixed preset and its complete expected record")
            }
            switch topButtonPreset {
            case .pinnedApp:
                guard let bundleIdentifier, validRapooBundleIdentifier(bundleIdentifier) else {
                    throw ScreenError.message("Pinning requires an installed application's bundle identifier")
                }
            case .dpiCycle:
                guard bundleIdentifier == nil else {
                    throw ScreenError.message("Restoring DPI cycling accepts no application")
                }
            }
        }
    }
}

private struct RapooAppControlReply: Codable {
    let schemaVersion: Int
    let id: String
    let targetPID: Int32
    let status: RapooAppSwitchStatus?
    let result: RapooWheelChangeResult?
    let buttonResult: RapooButtonChangeResult?
    let error: String?

    func hasValidPayload(for action: RapooAppControlRequest.Action) -> Bool {
        guard [status != nil, result != nil, buttonResult != nil, error != nil].filter({ $0 }).count == 1 else {
            return false
        }
        if error != nil { return true }
        switch action {
        case .status, .setHostAction: return status != nil
        case .setSideWheel: return result != nil
        case .setTopButton: return buttonResult != nil
        }
    }
}

/// The notification carries only the request ID and target PID. Payloads stay
/// in private, bounded files; consuming the request makes wakeups idempotent.
public struct RapooAppControlServer {
    public static let bundleIdentifier = "com.danielsivan.msi-screen.menu"
    public static let notificationName = Notification.Name("com.danielsivan.msi-screen.rapoo-app-control")
    static let defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("msi-screen-control/rapoo-app-control", isDirectory: true)
    private let files: RapooControlFiles

    public init() throws { files = try RapooControlFiles(directory: Self.defaultDirectory) }
    init(directory: URL) throws { files = try RapooControlFiles(directory: directory) }

    public func takeRequest(id: String, targetPID: Int32) throws -> RapooAppControlRequest? {
        guard validRapooRequestID(id), targetPID == getpid() else { return nil }
        let claim = id + ".claimed"
        guard try files.consume(id + ".request", as: claim) else { return nil }
        defer { files.remove(claim) }
        guard let data = try files.read(claim) else { return nil }
        let allowed: Set<String> = ["schemaVersion", "id", "targetPID", "expiresAt", "action", "preset", "expected",
                                    "hostAction", "topButtonPreset", "expectedRecordHex", "bundleIdentifier"]
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else { throw ScreenError.message("Unknown Rapoo app request fields") }
        let request = try rapooControlDecoder().decode(RapooAppControlRequest.self, from: data)
        guard request.id == id else { throw ScreenError.message("Rapoo request ID mismatch") }
        try request.validateBeforeHandling()
        return request
    }

    public func respond(to request: RapooAppControlRequest, status: RapooAppSwitchStatus? = nil,
                        result: RapooWheelChangeResult? = nil, buttonResult: RapooButtonChangeResult? = nil,
                        error: String? = nil) throws {
        let reply = RapooAppControlReply(schemaVersion: 1, id: request.id, targetPID: getpid(),
                                        status: status, result: result, buttonResult: buttonResult, error: error)
        guard validRapooRequestID(request.id), request.targetPID == getpid(),
              reply.hasValidPayload(for: request.action) else {
            throw ScreenError.message("Invalid Rapoo app response")
        }
        // The client has stopped waiting after expiry. Do not leave a late
        // orphan response; the app still retains its actual operation result.
        guard request.expiresAt > Date() else { return }
        try files.write(try rapooControlEncoder().encode(reply), to: request.id + ".reply")
    }
}

public struct RapooAppControlClient {
    public init() {}

    public func status() async throws -> RapooAppSwitchStatus {
        let reply = try await exchange(action: .status, preset: nil, expected: nil)
        return try checkedStatus(reply)
    }

    /// Configures the running Mac app only; F18/F19 on the receiver are untouched.
    public func setHostAction(_ action: RapooWheelHostAction) async throws -> RapooAppSwitchStatus {
        let reply = try await exchange(action: .setHostAction, preset: nil, expected: nil, hostAction: action)
        let status = try checkedStatus(reply)
        guard status.enabled, status.hotkeysRegistered,
              status.hostAction == action, status.activeHostAction == action else {
            throw ScreenError.message("MSI Screen did not activate the requested wheel action; inspect peripherals app-switch")
        }
        return status
    }

    public func setSideWheel(preset: RapooSideWheelPreset, expected: [RapooWheelMapping]) async throws -> RapooWheelChangeResult {
        let reply = try await exchange(action: .setSideWheel, preset: preset, expected: expected)
        guard let result = reply.result, result.schemaVersion == 1, result.preset == preset,
              !result.dryRun, result.before == expected else {
            throw ScreenError.message("MSI Screen returned an inconsistent side-wheel result; inspect current mappings")
        }
        return result
    }

    /// The app reserves F20 before a pinned-app write. Only the fixed top button is writable.
    public func setTopButton(preset: RapooTopButtonPreset, expectedRecordHex: String,
                             bundleIdentifier: String? = nil) async throws -> RapooButtonChangeResult {
        let reply = try await exchange(action: .setTopButton, preset: nil, expected: nil,
            topButtonPreset: preset, expectedRecordHex: expectedRecordHex, bundleIdentifier: bundleIdentifier)
        guard let result = reply.buttonResult, result.schemaVersion == 1, result.preset == preset,
              !result.dryRun, result.before.keyID == 4, result.target.keyID == 4,
              result.before.rawRecordHex.lowercased() == expectedRecordHex.lowercased() else {
            throw ScreenError.message("MSI Screen returned an inconsistent top-button result; inspect current mappings")
        }
        return result
    }

    private func exchange(action: RapooAppControlRequest.Action, preset: RapooSideWheelPreset?,
                          expected: [RapooWheelMapping]?,
                          hostAction: RapooWheelHostAction? = nil, topButtonPreset: RapooTopButtonPreset? = nil,
                          expectedRecordHex: String? = nil, bundleIdentifier: String? = nil) async throws -> RapooAppControlReply {
        let application = try await MainActor.run {
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: RapooAppControlServer.bundleIdentifier).filter { !$0.isTerminated }
            guard applications.count == 1, let application = applications.first else {
                throw ScreenError.message(applications.isEmpty
                    ? "Start MSI Screen before using app-switch controls"
                    : "More than one MSI Screen app is running; keep one instance before using app-switch controls")
            }
            return application
        }
        let request = RapooAppControlRequest(targetPID: application.processIdentifier, action: action,
            preset: preset, expected: expected, hostAction: hostAction, topButtonPreset: topButtonPreset,
            expectedRecordHex: expectedRecordHex, bundleIdentifier: bundleIdentifier)
        try request.validate(targetPID: application.processIdentifier)
        let files = try RapooControlFiles(directory: RapooAppControlServer.defaultDirectory)
        defer { files.remove(request.id + ".request"); files.remove(request.id + ".reply") }
        try files.write(try rapooControlEncoder().encode(request), to: request.id + ".request")
        DistributedNotificationCenter.default().postNotificationName(RapooAppControlServer.notificationName,
            object: nil, userInfo: ["requestID": request.id, "targetPID": Int(request.targetPID)], deliverImmediately: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let data = try files.read(request.id + ".reply") {
                let reply = try rapooControlDecoder().decode(RapooAppControlReply.self, from: data)
                guard reply.schemaVersion == 1, reply.id == request.id, reply.targetPID == request.targetPID,
                      reply.hasValidPayload(for: action) else {
                    throw ScreenError.message("MSI Screen returned an invalid Rapoo app response")
                }
                if let error = reply.error { throw ScreenError.message(error) }
                return reply
            }
            guard !application.isTerminated else {
                throw ScreenError.message("MSI Screen exited before replying; inspect current mappings before another change")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ScreenError.message("MSI Screen did not reply within 15 seconds; completion is unknown. Inspect current mappings before another change")
    }

    private func checkedStatus(_ reply: RapooAppControlReply) throws -> RapooAppSwitchStatus {
        guard let status = reply.status, status.schemaVersion == 1,
              status.switchCount >= 0, status.spaceRequestCount >= 0,
              status.lastSpaceDirection == nil || ["left", "right"].contains(status.lastSpaceDirection!),
              status.hotkeysRegistered == (status.activeHostAction != nil), status.pinRequestCount >= 0,
              !status.pinHotkeyRegistered || status.pinnedBundleIdentifier.map(validRapooBundleIdentifier) == true else {
            throw ScreenError.message("MSI Screen returned invalid wheel-action status")
        }
        return status
    }
}

private func validRapooRecordHex(_ value: String) -> Bool {
    value.utf8.count == 8 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
}

private func validRapooBundleIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255 &&
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil
}

private func validRapooRequestID(_ id: String) -> Bool {
    UUID(uuidString: id)?.uuidString.lowercased() == id
}

private func rapooControlEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func rapooControlDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

private final class RapooControlFiles {
    private let directoryFD: Int32
    private static let maximumBytes = 65_536

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0 else { throw ScreenError.message("Cannot open private Rapoo app-control directory") }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw ScreenError.message("Rapoo app-control directory must be owned by this user with mode 0700")
        }
        directoryFD = fd
    }
    deinit { close(directoryFD) }

    func consume(_ name: String, as claim: String) throws -> Bool {
        // linkat creates the claim exclusively, then unlink removes the inbox
        // entry. Duplicate notifications cannot acquire the same claim.
        guard linkat(directoryFD, name, directoryFD, claim, 0) == 0 else {
            if errno == ENOENT || errno == EEXIST { return false }
            throw ScreenError.message("Cannot consume Rapoo app request")
        }
        guard unlinkat(directoryFD, name, 0) == 0 else {
            remove(claim)
            throw ScreenError.message("Cannot remove consumed Rapoo app request")
        }
        return true
    }

    func read(_ name: String) throws -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ScreenError.message("Cannot open Rapoo app-control payload")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw ScreenError.message("Rapoo app-control payload must be a private regular file under 64 KiB")
        }
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        let length = Darwin.read(fd, &bytes, bytes.count)
        guard length >= 0, length <= Self.maximumBytes, length == info.st_size else {
            throw ScreenError.message("Rapoo app-control payload changed or exceeded 64 KiB")
        }
        return Data(bytes.prefix(length))
    }

    func write(_ data: Data, to name: String) throws {
        guard data.count <= Self.maximumBytes else { throw ScreenError.message("Rapoo app-control payload exceeds 64 KiB") }
        let temporary = "." + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ScreenError.message("Cannot prepare Rapoo app-control payload") }
        defer { remove(temporary) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        guard linkat(directoryFD, temporary, directoryFD, name, 0) == 0 else {
            throw ScreenError.message("Cannot publish Rapoo app-control payload")
        }
    }

    func remove(_ name: String) { _ = unlinkat(directoryFD, name, 0) }
}
