import Darwin
import Foundation

public enum MachinePlatform: String, Codable, CaseIterable {
    case macos, linux
}

public enum MachineAccess: String, Codable, CaseIterable {
    case local, ssh
    case videoOnly = "video-only"
}

public struct MachineDefinition: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: MachinePlatform
    /// Nil preserves a saved machine without assigning a monitor input.
    public var input: Input?
    public var access: MachineAccess
    /// Present only for SSH access. Credentials remain in the user's SSH configuration.
    public var host: String?
    public var sshTransport: SSHTransport
    public var isLocal: Bool { access == .local }
    public var isUSBUpstreamCandidate: Bool { access == .ssh && platform == .linux && host != nil }
    public func followsFullscreenUSB(upstreamMachineID: String?) -> Bool {
        input != nil && ((isLocal && input == .usbc) || (isUSBUpstreamCandidate && id == upstreamMachineID))
    }

    public init(id: String, name: String, platform: MachinePlatform, input: Input?, host: String?,
                access: MachineAccess? = nil, sshTransport: SSHTransport = .standard) {
        self.id = id
        self.name = name
        self.platform = platform
        self.input = input
        self.host = host
        self.access = access ?? (host == nil ? .local : .ssh)
        self.sshTransport = sshTransport
    }

    private enum CodingKeys: String, CodingKey { case id, name, platform, input, access, host, sshTransport }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        platform = try container.decode(MachinePlatform.self, forKey: .platform)
        input = try container.decodeIfPresent(Input.self, forKey: .input)
        access = try container.decode(MachineAccess.self, forKey: .access)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        // Version 3 requires an explicit trust path. Legacy defaults are applied
        // only by MachineRegistry's versioned migration.
        sshTransport = try container.decode(SSHTransport.self, forKey: .sshTransport)
    }
}

public struct MachineRegistry: Codable, Equatable {
    public let schemaVersion: Int
    public var machines: [MachineDefinition]
    public var usbUpstreamMachineID: String?
    public var usbUpstreamMachine: MachineDefinition? {
        guard let id = usbUpstreamMachineID else { return nil }
        return machines.first { $0.id == id && $0.isUSBUpstreamCandidate }
    }

    public init(machines: [MachineDefinition] = [], usbUpstreamMachineID: String? = nil) {
        schemaVersion = 3
        self.machines = machines
        self.usbUpstreamMachineID = usbUpstreamMachineID
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, machines, usbUpstreamMachineID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        switch version {
        case 1:
            // Legacy nil-host records meant this Mac. Only v1 may infer access;
            // v2 requires it, and older apps reject v2 before acting on records.
            struct LegacyMachine: Decodable {
                let id: String
                let name: String
                let platform: MachinePlatform
                let input: Input
                let host: String?
            }
            let legacy = try container.decode([LegacyMachine].self, forKey: .machines)
            machines = legacy.map {
                MachineDefinition(id: $0.id, name: $0.name, platform: $0.platform,
                                  input: $0.input, host: $0.host)
            }
        case 2:
            struct LegacyMachine: Decodable {
                let id: String
                let name: String
                let platform: MachinePlatform
                let input: Input?
                let access: MachineAccess
                let host: String?
            }
            let legacy = try container.decode([LegacyMachine].self, forKey: .machines)
            machines = legacy.map {
                MachineDefinition(id: $0.id, name: $0.name, platform: $0.platform,
                                  input: $0.input, host: $0.host, access: $0.access)
            }
        case 3:
            machines = try container.decode([MachineDefinition].self, forKey: .machines)
        default:
            throw ScreenError.message("Unsupported machine configuration version")
        }
        if version < 3 {
            // Preserve an unambiguous existing USB-B assignment when adding
            // another Linux SSH machine after migration.
            let candidates = machines.filter(\.isUSBUpstreamCandidate)
            usbUpstreamMachineID = candidates.count == 1 ? candidates[0].id : nil
        } else {
            usbUpstreamMachineID = try container.decodeIfPresent(String.self, forKey: .usbUpstreamMachineID)
        }
        schemaVersion = 3
    }

    public func validate() throws {
        guard schemaVersion == 3 else {
            throw ScreenError.message("Unsupported machine configuration version")
        }
        guard Set(machines.map(\.id)).count == machines.count else {
            throw ScreenError.message("Each machine must have a unique ID")
        }
        let assignedInputs = machines.compactMap(\.input)
        guard Set(assignedInputs).count == assignedInputs.count else {
            throw ScreenError.message("Assign each monitor input to only one machine")
        }
        guard machines.filter(\.isLocal).count <= 1 else {
            throw ScreenError.message("Only one machine can represent this Mac")
        }
        if let id = usbUpstreamMachineID {
            guard machines.contains(where: { $0.id == id && $0.isUSBUpstreamCandidate }) else {
                throw ScreenError.message("The USB-B upstream assignment must identify a Linux machine with an SSH host")
            }
        }
        let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for machine in machines {
            guard !machine.id.isEmpty, machine.id.first != "-", machine.id.utf8.count <= 64,
                  machine.id.unicodeScalars.allSatisfy(allowedID.contains) else {
                throw ScreenError.message("Machine IDs must contain 1–64 letters, digits, underscores or hyphens")
            }
            guard !machine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  machine.name.count <= 128,
                  !machine.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ScreenError.message("Give each machine a name of 1–128 characters")
            }
            switch machine.access {
            case .local:
                guard machine.platform == .macos, machine.host == nil, machine.sshTransport == .standard else {
                    throw ScreenError.message("This Mac must use macOS without an SSH host")
                }
            case .ssh:
                guard let host = machine.host else {
                    throw ScreenError.message("SSH access requires a host")
                }
                try RemoteMacClient(host: host, transport: machine.sshTransport).validateHost()
            case .videoOnly:
                guard machine.host == nil, machine.sshTransport == .standard else {
                    throw ScreenError.message("Video-only machines cannot have an SSH host or transport")
                }
            }
        }
    }

    public func machine(id: String) throws -> MachineDefinition {
        guard let machine = machines.first(where: { $0.id == id }) else {
            throw ScreenError.message("Unknown machine ID: \(id)")
        }
        return machine
    }
}

/// Shared by the menu app and CLI. Writes compare the loaded snapshot while
/// holding a nonblocking process lock, then atomically replace only this file.
public struct MachineRegistryStore {
    private static let maximumFileSize = 65_536
    public static let defaultURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("MSI Screen/machines.json")
    public static let didChangeNotification = Notification.Name("com.msiscreen.machine-registry-changed")
    public let url: URL

    public init(url: URL = Self.defaultURL) { self.url = url }

    public func load() throws -> MachineRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else { return MachineRegistry() }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = Self.maximumFileSize
        var data = Data()
        while let chunk = try file.read(upToCount: min(8_192, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw ScreenError.message("Machine configuration exceeds 64 KiB") }
        }
        let registry = try JSONDecoder().decode(MachineRegistry.self, from: data)
        try registry.validate()
        return registry
    }

    public func save(_ registry: MachineRegistry, replacing expected: MachineRegistry, ifMissing: Bool = false) throws {
        try registry.validate()
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.appendingPathExtension("lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ScreenError.message("Cannot open the machine configuration lock") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ScreenError.message("Machine configuration is being edited elsewhere; refresh and try again")
        }
        // First-run migration must not replace a configuration created by the
        // CLI between the app's initial existence check and this lock.
        if ifMissing && manager.fileExists(atPath: url.path) { return }
        guard try load() == expected else {
            throw ScreenError.message("Machine configuration changed elsewhere; refresh before saving")
        }
        guard registry != expected else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        guard data.count <= Self.maximumFileSize else {
            throw ScreenError.message("Machine configuration exceeds 64 KiB")
        }
        let temporary = directory.appendingPathComponent(".machines-\(UUID().uuidString).json")
        let temporaryFD = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard temporaryFD >= 0 else { throw ScreenError.message("Cannot prepare machine configuration") }
        let file = FileHandle(fileDescriptor: temporaryFD, closeOnDealloc: true)
        defer {
            try? file.close()
            if manager.fileExists(atPath: temporary.path) { try? manager.removeItem(at: temporary) }
        }
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw ScreenError.message("Cannot replace machine configuration")
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.didChangeNotification, object: url.standardizedFileURL.path,
            userInfo: nil, deliverImmediately: true
        )
    }
}

public enum MachineRoute: String, Codable, CaseIterable {
    case fullscreen
    case pbpLeft = "pbp-left"
    case pbpRight = "pbp-right"
}

public enum MachineRouter {
    public static func target(for machine: MachineDefinition, route: MachineRoute,
                              from state: ScreenState) throws -> ScreenState {
        guard let input = machine.input else {
            throw ScreenError.message("Assign a monitor input to \(machine.name) before switching its video")
        }
        if route == .fullscreen {
            return ScreenController.fullscreenTarget(from: state, input: input)
        }
        let other: Input?
        if route == .pbpLeft {
            other = state.source2 != input ? state.source2
                : state.source1 != input ? state.source1 : nil
        } else {
            other = state.source1 != input ? state.source1
                : state.source2 != input ? state.source2 : nil
        }
        guard let other else {
            throw ScreenError.message("Choose a different input for the other side before enabling PBP")
        }
        return try ScreenController.pbpTarget(
            from: state, enabled: true,
            left: route == .pbpLeft ? input : other,
            right: route == .pbpRight ? input : other
        )
    }
}
