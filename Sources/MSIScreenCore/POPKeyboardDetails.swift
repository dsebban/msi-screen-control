import Foundation

public struct HIDPPFeature: Codable, Equatable, Identifiable {
    public let id: Int
    public let index: Int
    public let version: Int
    public let flags: Int
    public var displayName: String {
        // Standard feature identifiers: Solaar e7304c4, hidpp20_constants.SupportedFeature.
        switch id {
        case 0: return "HID++ root"
        case 1: return "Feature discovery"
        case 3: return "Firmware information"
        case 5: return "Device name"
        case 7: return "Device friendly name"
        case 0x0020: return "Configuration change"
        case 0x1000: return "Battery status"
        case 0x1001: return "Battery voltage"
        case 0x1004: return "Unified battery"
        case 0x1814: return "Host switching"
        case 0x1815: return "Host information"
        case 0x1b04: return "Reprogrammable controls"
        case 0x1d4b: return "Wireless device status"
        case 0x40a0, 0x40a2: return "Function-key mode"
        case 0x40a3: return "Host-specific function-key mode"
        case 0x4220: return "Lock-key state"
        case 0x4521: return "Keyboard key disabling"
        case 0x4531: return "Multi-platform keyboard mode"
        case 0x4540: return "Keyboard layout"
        default: return String(format: "Feature 0x%04X", id)
        }
    }
}

public enum PeripheralFirmwareKind: String, Codable {
    case firmware, bootloader, hardware, other
}

public struct PeripheralFirmware: Codable, Equatable {
    public let kind: PeripheralFirmwareKind
    public let prefix: String?
    public let version: String?
    public let build: Int?
}

public enum PeripheralBatteryLevel: String, Codable {
    case critical, low, good, full
}

public struct PeripheralBattery: Codable, Equatable {
    public let featureID: Int
    public let percentage: Int?
    public let level: PeripheralBatteryLevel?
    public let statusCode: Int?
    public let voltageMillivolts: Int?
    public var statusDescription: String? {
        guard let statusCode else { return nil }
        return [0: "Discharging", 1: "Charging", 2: "Almost full", 3: "Full",
                4: "Slow charging", 5: "Invalid battery", 6: "Thermal error"][statusCode]
            ?? "Unknown status \(statusCode)"
    }
}

public struct PeripheralFnMode: Codable, Equatable {
    public let featureID: Int
    public let inverted: Bool
    public let defaultInverted: Bool?
}

public struct PeripheralControl: Codable, Equatable, Identifiable {
    public let controlID: Int
    public let defaultTaskID: Int
    public let flags: Int
    public let position: Int
    public let group: Int
    public let groupMask: Int
    public let currentControlID: Int?
    public let reportingFlags: Int?
    public var id: Int { controlID }
    public var defaultTaskName: String {
        // Task and control IDs are distinct. Names use Solaar's pinned metadata:
        // github.com/pwr-Solaar/Solaar/blob/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver/special_keys.py
        switch defaultTaskID {
        case 1: return "Volume up"
        case 2: return "Volume down"
        case 3: return "Mute"
        case 4: return "Play / pause"
        case 5: return "Next track"
        case 6: return "Previous track"
        case 0x43: return "Show desktop"
        case 0x62: return "No assigned task"
        case 0xae: return "Easy-Switch 1"
        case 0xaf: return "Easy-Switch 2"
        case 0xb0: return "Easy-Switch 3"
        case 0xbf: return "Mission Control / Task View"
        case 0xd8: return "Voice dictation"
        case 0xd9: return "Heart-eyes emoji"
        case 0xda: return "Crying emoji"
        case 0xdb: return "Smiley emoji"
        case 0xdc: return "Tears-of-joy emoji"
        case 0xdd: return "Emoji panel"
        case 0xdf: return "Snipping tool"
        case 0xf1: return "Mute microphone"
        default: return String(format: "Task 0x%04X", defaultTaskID)
        }
    }
    public var displayName: String {
        let name: String
        switch controlID {
        // These firmware keys report a no-action task; retain their actual CID names.
        case 0x0034: name = "Fn key"
        case 0x00de: name = "Function lock"
        default: name = defaultTaskName
        }
        return name + String(format: " (0x%04X)", controlID)
    }
}

public struct POPKeyboardDetails: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let hostName: String
    public let platform: MachinePlatform
    public let slot: Int
    public let wirelessProductID: String
    public let name: String
    public let features: [HIDPPFeature]
    public let featureInventoryComplete: Bool
    public let firmware: [PeripheralFirmware]
    public let battery: PeripheralBattery?
    public let fnMode: PeripheralFnMode?
    public let controls: [PeripheralControl]
    public let controlInventoryComplete: Bool
    public let errors: [String]

    static func decodeRemote(_ data: Data, expected: PairedUSBPeripheral) throws -> POPKeyboardDetails {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard data.count <= 65_536, let result = try? decoder.decode(Self.self, from: data),
              result.schemaVersion == 1, result.platform == .linux,
              text(result.hostName, 128), !result.hostName.isEmpty,
              result.slot == expected.slot, result.wirelessProductID.uppercased() == expected.wirelessProductID.uppercased(),
              result.name == "Logi POP Keys" || result.name == "POP Keys",
              result.features.count <= 64,
              Set(result.features.map(\.id)).count == result.features.count,
              Set(result.features.map(\.index)).count == result.features.count,
              result.features.allSatisfy({ (0...65535).contains($0.id) && (0...255).contains($0.index)
                  && (0...255).contains($0.version) && (0...255).contains($0.flags) }),
              result.firmware.count <= 8, result.firmware.allSatisfy({
                  optionalText($0.prefix, 3) && optionalText($0.version, 16)
                  && ($0.build.map { (0...65535).contains($0) } ?? true)
              }),
              result.controls.count <= 32,
              Set(result.controls.map(\.controlID)).count == result.controls.count,
              result.controls.allSatisfy({
                  (0...65535).contains($0.controlID) && (0...65535).contains($0.defaultTaskID)
                  && (0...65535).contains($0.flags) && (0...255).contains($0.position)
                  && (0...255).contains($0.group) && (0...255).contains($0.groupMask)
                  && ($0.currentControlID.map { (0...65535).contains($0) } ?? true)
                  && ($0.reportingFlags.map { (0...65535).contains($0) } ?? true)
              }),
              result.errors.count <= 128, result.errors.allSatisfy({ text($0, 512) }) else {
            throw ScreenError.message("Linux returned invalid POP Keys details")
        }
        let ids = Set(result.features.map(\.id))
        if let battery = result.battery {
            guard [0x1000, 0x1001, 0x1004].contains(battery.featureID), ids.contains(battery.featureID),
                  battery.percentage.map({ (1...100).contains($0) }) ?? true,
                  battery.statusCode.map({ (0...255).contains($0) }) ?? true,
                  battery.voltageMillivolts.map({ (0...65535).contains($0) }) ?? true else {
                throw ScreenError.message("Linux returned invalid battery details")
            }
        }
        if let fn = result.fnMode, ![0x40a0, 0x40a2].contains(fn.featureID) || !ids.contains(fn.featureID) {
            throw ScreenError.message("Linux returned a function-key mode without an advertised feature")
        }
        guard (result.firmware.isEmpty || ids.contains(3)), (result.controls.isEmpty || ids.contains(0x1b04)) else {
            throw ScreenError.message("Linux returned details without their advertised features")
        }
        return result
    }

    private static func text(_ value: String, _ maximum: Int) -> Bool {
        value.utf8.count <= maximum && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func optionalText(_ value: String?, _ maximum: Int) -> Bool { value.map { text($0, maximum) } ?? true }
}
