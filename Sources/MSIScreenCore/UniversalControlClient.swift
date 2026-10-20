import Darwin
import Foundation

public enum UniversalControlOperation: String, CaseIterable, Sendable {
    case check
    case preflight
    case refresh

    var arguments: [String] {
        switch self {
        case .check: return ["--check"]
        case .preflight: return ["--dry-run"]
        case .refresh: return []
        }
    }
}

public struct UniversalControlResult: Sendable {
    public enum ServiceStatus: Sendable {
        case healthy, refreshed, preflightPassed, failed, unreported
    }
    public enum SharingStatus: Sendable { case unverified }

    public let operation: UniversalControlOperation
    public let serviceStatus: ServiceStatus
    // Services and SSH can be healthy while actual keyboard/mouse transfer is
    // disconnected. The installed script has no functional-sharing verdict.
    public let sharingStatus: SharingStatus = .unverified
    public let process: ProcessRunner.Output

    public var summary: String {
        if process.timedOut {
            return "The operation timed out." +
                (operation == .refresh ? " One Mac may have refreshed; inspect the details." : "")
        }
        switch serviceStatus {
        case .healthy: return "Sharing services are healthy. Test the pointer and keyboard across both Macs."
        case .refreshed: return "Sharing services refreshed. Test the pointer and keyboard across both Macs."
        case .preflightPassed: return "Both Macs passed preflight. Sharing has not been tested."
        case .failed: return "Universal Control could not complete. See the details."
        case .unreported: return "The script finished without a recognized service result. Sharing is unverified."
        }
    }
}

public enum UniversalControlError: LocalizedError {
    case unavailable
    case invalidInstallation

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Universal Control helper is unavailable. Install or repair ~/.local/bin/universal-control."
        case .invalidInstallation:
            return "The Universal Control helper must be an executable regular file owned by you or the system."
        }
    }
}

public struct UniversalControlClient {
    // The installed Displays extension advertises this URL scheme. macOS
    // settings own enable/disable and automatic-reconnect preferences.
    public static let displaysSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Displays-Settings.extension"
    )!

    public let installedURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        installedURL = homeDirectory.appendingPathComponent(".local/bin/universal-control")
    }

    public func resolveExecutable() throws -> URL {
        let url = installedURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw UniversalControlError.unavailable
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              manager.isExecutableFile(atPath: url.path),
              owner == getuid() || owner == 0 else {
            throw UniversalControlError.invalidInstallation
        }
        return url
    }

    public func run(_ operation: UniversalControlOperation) async throws -> UniversalControlResult {
        let output = try await ProcessRunner.run(
            executable: resolveExecutable(),
            arguments: operation.arguments,
            timeout: operation == .refresh ? 90 : 45
        )
        let lines = output.text.components(separatedBy: .newlines)
        let status: UniversalControlResult.ServiceStatus
        if !output.succeeded {
            status = .failed
        } else if operation == .check && lines.contains("SERVICE_STATUS=HEALTHY") {
            status = .healthy
        } else if operation == .refresh &&
                    lines.contains("SERVICE_STATUS=REFRESHED (both Macs)") {
            status = .refreshed
        } else if operation == .preflight &&
                    lines.contains("Dry run complete; neither Mac was restarted.") {
            status = .preflightPassed
        } else {
            status = .unreported
        }
        return UniversalControlResult(operation: operation, serviceStatus: status, process: output)
    }
}
