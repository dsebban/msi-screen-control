import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid
import Security

public struct AppSigningIdentity: Codable, Equatable {
    public enum Kind: String, Codable { case certificate, adHoc, unsigned, unknown }
    public let kind: Kind
    public let identifier: String?
    public let teamIdentifier: String?
    public let designatedRequirement: String?
    public let signatureValid: Bool
    public let validationError: Int32?

    /// Continuity still requires future builds to satisfy this same requirement.
    public var hasStableIdentity: Bool {
        kind == .certificate && signatureValid
            && designatedRequirement.map { !$0.isEmpty && !$0.contains("cdhash") } == true
    }

    static func current() -> AppSigningIdentity {
        var code: SecCode?
        var staticCode: SecStaticCode?
        let selfResult = SecCodeCopySelf([], &code)
        guard selfResult == errSecSuccess, let code else { return unknown(selfResult) }
        let staticResult = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticResult == errSecSuccess, let staticCode else { return unknown(staticResult) }
        let validity = SecStaticCodeCheckValidity(staticCode, [], nil)
        var information: CFDictionary?
        let result = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard result == errSecSuccess, let info = information as? [String: Any] else {
            return AppSigningIdentity(kind: validity == errSecCSUnsigned ? .unsigned : .unknown,
                identifier: nil, teamIdentifier: nil, designatedRequirement: nil,
                signatureValid: false, validationError: validity == errSecSuccess ? result : validity)
        }
        var requirement: SecRequirement?
        var requirementText: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
           let requirement {
            _ = SecRequirementCopyString(requirement, [], &requirementText)
        }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let kind: Kind = flags & 0x2 != 0 ? .adHoc : certificates.isEmpty ? .unsigned : .certificate
        return AppSigningIdentity(kind: kind,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            designatedRequirement: requirementText as String?,
            signatureValid: validity == errSecSuccess,
            validationError: validity == errSecSuccess ? nil : validity)
    }

    private static func unknown(_ result: OSStatus) -> AppSigningIdentity {
        AppSigningIdentity(kind: .unknown, identifier: nil, teamIdentifier: nil,
                           designatedRequirement: nil, signatureValid: false, validationError: result)
    }
}

/// Checks the calling process. The CLI asks the running menu app for its own
/// snapshot: a grant for Terminal or the CLI is not evidence of an app grant.
public struct AppPermissionStatus: Codable {
    public enum Access: String, Codable { case granted, denied, unknown }
    public let schemaVersion: Int
    public let checkedAt: Date
    public let processID: Int32
    public let bundleIdentifier: String?
    public let appPath: String
    public let accessibilityTrusted: Bool
    public let eventPostingAllowed: Bool
    public let inputMonitoring: Access
    public let signing: AppSigningIdentity

    public var spacesAllowed: Bool { accessibilityTrusted && eventPostingAllowed }
    public var allGranted: Bool { spacesAllowed && inputMonitoring == .granted }

    public static func current() -> AppPermissionStatus {
        let input: Access
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: input = .granted
        case kIOHIDAccessTypeDenied: input = .denied
        default: input = .unknown
        }
        return AppPermissionStatus(schemaVersion: 1, checkedAt: Date(), processID: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier, appPath: Bundle.main.bundlePath,
            accessibilityTrusted: AXIsProcessTrusted(),
            eventPostingAllowed: CGPreflightPostEventAccess(), inputMonitoring: input,
            signing: .current())
    }
}
