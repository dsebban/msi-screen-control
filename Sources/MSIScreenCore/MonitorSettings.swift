import Foundation

/// MD342CQP/V20 controls from MSI's model profile and Nuvoton command table.
public enum MonitorSetting: String, CaseIterable, Codable {
    case brightness, contrast, sharpness, imageEnhancement, pictureMode
    case colorTemperature, redGain, greenGain, blueGain, lowBlueLight, hdcr
    case responseTime, refreshRate, refreshRatePosition, volume
    case osdTransparency, osdTimeout, infoOnScreen, autoScan

    public var title: String {
        switch self {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .sharpness: return "Sharpness"
        case .imageEnhancement: return "Image enhancement"
        case .pictureMode: return "Picture mode"
        case .colorTemperature: return "Color temperature"
        case .redGain: return "Red"
        case .greenGain: return "Green"
        case .blueGain: return "Blue"
        case .lowBlueLight: return "Low blue light"
        case .hdcr: return "Dynamic contrast"
        case .responseTime: return "Response time"
        case .refreshRate: return "Refresh rate overlay"
        case .refreshRatePosition: return "Overlay position"
        case .volume: return "Speaker volume"
        case .osdTransparency: return "OSD transparency"
        case .osdTimeout: return "OSD timeout"
        case .infoOnScreen: return "Monitor information overlay"
        case .autoScan: return "Automatic input scan"
        }
    }

    public var category: String {
        switch self {
        case .volume: return "Sound"
        case .responseTime, .refreshRate, .refreshRatePosition: return "Motion"
        case .osdTransparency, .osdTimeout, .infoOnScreen, .autoScan: return "Monitor"
        default: return "Picture"
        }
    }

    public var register: String {
        switch self {
        case .brightness: return "00400"
        case .contrast: return "00410"
        case .sharpness: return "00420"
        case .imageEnhancement: return "00340"
        case .pictureMode: return "00350"
        case .colorTemperature: return "00430"
        case .redGain: return "00431"
        case .greenGain: return "00432"
        case .blueGain: return "00433"
        case .lowBlueLight: return "00480"
        case .hdcr: return "00240"
        case .responseTime: return "00220"
        case .refreshRate: return "00250"
        case .refreshRatePosition: return "00251"
        case .volume: return "00870"
        case .osdTransparency: return "00810"
        case .osdTimeout: return "00820"
        case .infoOnScreen: return "00830"
        case .autoScan: return "00510"
        }
    }

    public var range: ClosedRange<Int> {
        switch self {
        case .brightness, .contrast, .redGain, .greenGain, .blueGain, .volume: return 0...100
        case .sharpness, .osdTransparency: return 0...5
        case .imageEnhancement: return 0...4
        case .pictureMode: return 0...11
        case .colorTemperature, .refreshRatePosition: return 0...3
        case .responseTime: return 0...2
        case .osdTimeout: return 5...30
        default: return 0...1
        }
    }

    public var options: [Int: String] {
        let names: [String]
        switch self {
        case .imageEnhancement: names = ["Off", "Weak", "Medium", "Strong", "Strongest"]
        case .pictureMode:
            // The MD342CQP model filters the shared standard-mode table.
            return Dictionary(uniqueKeysWithValues: zip([0, 3, 4, 5, 6, 7, 11],
                       ["User", "sRGB", "Movie", "Office", "Black and white", "Anti-blue", "Eco"]))
        case .colorTemperature: names = ["Cool", "Normal", "Warm", "Custom"]
        case .responseTime: names = ["Normal", "Fast", "Fastest"]
        case .refreshRatePosition: names = ["Top left", "Top right", "Bottom left", "Bottom right"]
        case .lowBlueLight, .hdcr, .refreshRate, .infoOnScreen, .autoScan: names = ["Off", "On"]
        default: return [:]
        }
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.offset, $0.element) })
    }

    public func accepts(_ value: Int) -> Bool {
        range.contains(value) && (options.isEmpty || options[value] != nil)
    }

    // Nuvoton.SetCommandValue explicitly decimal-encodes IDs16/17/31/32/33/25.
    // Other IDs add the value to the final byte. In particular AudioVolume131
    // value50 is "00b", not "050"; using decimal would silently set the wrong level.
    var usesDecimalPayload: Bool {
        switch self {
        case .brightness, .contrast, .redGain, .greenGain, .blueGain, .osdTimeout: return true
        default: return false
        }
    }
}

public struct MonitorSettingsSnapshot: Codable, Equatable {
    public let layout: ScreenState
    public let values: [String: Int]
    public let unavailable: [String: String]
    /// Read-only conditions used to guard writes. A missing value is unknown.
    public let conditions: [String: Int]
    public var hdrActive: Bool? { conditions["hdr"].map { $0 == 1 } }

    public func value(_ setting: MonitorSetting) -> Int? { values[setting.rawValue] }
    public func unavailableReason(_ setting: MonitorSetting) -> String? { unavailable[setting.rawValue] }
}

public extension ScreenController {
    func settings() throws -> MonitorSettingsSnapshot {
        let layout = try state()
        var values: [String: Int] = [:]
        var unavailable: [String: String] = [:]
        var conditions: [String: Int] = [:]
        // MD342CQP HDRStatus95 and ImageAntiBlur14; these are state queries,
        // not an attempt to toggle HDR or the monitor's power.
        for (name, register) in [("hdr", "00190"), ("mprt", "00230")] {
            conditions[name] = try? readSettingValue(register, allowed: 0...1)
        }
        for setting in MonitorSetting.allCases {
            do {
                let value = try readSettingValue(setting.register, allowed: setting.range)
                guard setting.accepts(value) else {
                    throw ScreenError.message("Unrecognized \(setting.title) value \(value)")
                }
                values[setting.rawValue] = value
            } catch {
                unavailable[setting.rawValue] = "Unavailable: \(error)"
            }
        }
        for setting in MonitorSetting.allCases where unavailable[setting.rawValue] == nil {
            unavailable[setting.rawValue] = disabledReason(setting, layout: layout,
                                                          values: values, conditions: conditions)
        }
        guard try state() == layout else {
            throw ScreenError.message("Monitor layout changed while reading controls; refresh before continuing")
        }
        return MonitorSettingsSnapshot(layout: layout, values: values,
                                       unavailable: unavailable, conditions: conditions)
    }

    func apply(_ setting: MonitorSetting, value: Int,
               from expected: MonitorSettingsSnapshot) throws -> MonitorSettingsSnapshot {
        guard setting.accepts(value) else {
            throw ScreenError.message("Invalid \(setting.title) value; no settings changed")
        }
        let current = try settings()
        guard current == expected else {
            throw ScreenError.message("Monitor changed since planning; refresh before applying a setting")
        }
        guard current.value(setting) != value else { return current }
        guard let _ = current.value(setting), current.unavailableReason(setting) == nil else {
            throw ScreenError.message(current.unavailableReason(setting) ?? "Setting unavailable; no report sent")
        }
        try transport.writeSetting(setting, value: value)
        // The MD342CQP profile uses a 400ms delay after individual OSD commands.
        // Readback is required; an HID acknowledgement is not an applied setting.
        Thread.sleep(forTimeInterval: 0.4)
        let after = try settings()
        guard after.layout == current.layout else {
            throw ScreenError.message("Monitor layout changed during the setting update; refresh before continuing")
        }
        guard after.value(setting) == value else {
            throw ScreenError.message("\(setting.title) did not persist after settling; refresh before retrying")
        }
        didVerifyChange()
        return after
    }
}

private extension ScreenController {
    func readSettingValue(_ register: String, allowed: ClosedRange<Int>) throws -> Int {
        let bytes = try transport.query(register)
        let value: Int
        if bytes.count == 3, bytes.allSatisfy({ (48...57).contains($0) }),
           let decimal = Int(String(decoding: bytes, as: UTF8.self)) {
            value = decimal
        } else if bytes.count == 3, bytes[0] == 48, bytes[1] == 48, bytes[2] >= 48 {
            value = Int(bytes[2]) - 48
        } else {
            throw ScreenError.message("Unsupported response for \(register): \(bytes.hex)")
        }
        guard allowed.contains(value) else {
            throw ScreenError.message("Unsupported response for \(register): \(bytes.hex)")
        }
        return value
    }

    func disabledReason(_ setting: MonitorSetting, layout: ScreenState,
                        values: [String: Int], conditions: [String: Int]) -> String? {
        let hdrRestricted: Set<MonitorSetting> = [
            .brightness, .contrast, .colorTemperature, .redGain, .greenGain,
            .blueGain, .lowBlueLight, .hdcr, .pictureMode
        ]
        if hdrRestricted.contains(setting) {
            if conditions["hdr"] == 1 { return "Unavailable while the monitor receives HDR" }
        }
        let colorSettings: Set<MonitorSetting> = [.colorTemperature, .redGain, .greenGain, .blueGain]
        if colorSettings.contains(setting) || [.contrast, .lowBlueLight].contains(setting) {
            guard let mode = values[MonitorSetting.pictureMode.rawValue] else { return "Picture mode unavailable" }
            if mode == 3 { return "Unavailable in sRGB mode" }
        }
        if colorSettings.contains(setting) {
            guard let blueLight = values[MonitorSetting.lowBlueLight.rawValue] else { return "Low blue light status unavailable" }
            if blueLight != 0 { return "Turn off Low blue light to adjust color temperature" }
        }
        if [.redGain, .greenGain, .blueGain].contains(setting),
           values[MonitorSetting.colorTemperature.rawValue] != 3 {
            return "Choose Custom color temperature to adjust RGB"
        }
        if setting == .responseTime && layout.mode != .off {
            return "Unavailable in PIP or PBP"
        }
        if [.brightness, .hdcr, .responseTime].contains(setting) {
            guard let mprt = conditions["mprt"] else { return "MPRT status unavailable" }
            if mprt != 0 { return "Unavailable while MPRT is on" }
        }
        if setting == .brightness {
            guard let hdcr = values[MonitorSetting.hdcr.rawValue] else { return "Dynamic contrast status unavailable" }
            if hdcr != 0 { return "Turn off Dynamic contrast to adjust brightness" }
        }
        return nil
    }
}
