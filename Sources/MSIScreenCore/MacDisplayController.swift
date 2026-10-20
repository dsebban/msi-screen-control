import Foundation
import CoreGraphics
import ColorSync
import SystemConfiguration
import Darwin

public enum MacMainDisplayTarget: String, CaseIterable, Codable {
    case monitor
    case builtIn = "built-in"
}

public enum MacLaptopPosition: String, CaseIterable, Codable {
    case left, right
}

public struct MacDisplayMode: Codable, Equatable {
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let flags: UInt32
}

public struct MacDisplayInfo: Codable, Equatable {
    public let id: UInt32
    public let uuid: String
    public let vendor: UInt32
    public let model: UInt32
    public let isBuiltIn: Bool
    public var isMain: Bool
    public let isActive: Bool
    public let isAsleep: Bool
    public let isMirrored: Bool
    public let mirrorsDisplay: UInt32
    public var bounds: CGRect
    public let rotation: Double
    public let mode: MacDisplayMode?

    public var isMonitor: Bool { vendor == 0x3669 && model == 0x30c5 }
    public var name: String { isMonitor ? "MSI MD342CQP" : isBuiltIn ? "Built-in display" : "Display \(id)" }
}

public struct MacDisplayState: Codable, Equatable {
    public let computerName: String
    public var displays: [MacDisplayInfo]

    /// Physical order, independent of display IDs and the chosen main display.
    public var arrangedDisplays: [MacDisplayInfo] {
        displays.sorted {
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            return $0.id < $1.id
        }
    }

    public var laptopPosition: MacLaptopPosition? {
        guard displays.count == 2, !displays.contains(where: \.isMirrored),
              let laptop = displays.first(where: \.isBuiltIn),
              let monitor = displays.first(where: \.isMonitor),
              laptop.bounds.minY == monitor.bounds.minY else { return nil }
        if laptop.bounds.maxX == monitor.bounds.minX { return .left }
        if monitor.bounds.maxX == laptop.bounds.minX { return .right }
        return nil
    }
}

public struct MacDisplayPlan: Codable, Equatable {
    public let before: MacDisplayState
    public let after: MacDisplayState
    public let targetDisplayID: UInt32
    public var changesRequired: Bool { before.displays != after.displays }
}

/// Desktop roles belong to this Mac, independently of the monitor's USB layout.
public final class MacDisplayController {
    public init() {}

    public func state() throws -> MacDisplayState {
        var consoleUID: uid_t = 0
        var consoleGID: gid_t = 0
        let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) as String?
        guard let consoleUser, !consoleUser.isEmpty, consoleUser != "loginwindow", consoleUID == getuid() else {
            throw ScreenError.message("Run display controls as the Mac's currently signed-in desktop user")
        }
        let ids = try onlineDisplays()
        let displays = try ids.map { id -> MacDisplayInfo in
            let reference: Unmanaged<CFUUID>? = CGDisplayCreateUUIDFromDisplayID(id)
            guard let reference else {
                throw ScreenError.message("Display identity is unavailable; refresh before changing the main display")
            }
            let uuid = reference.takeRetainedValue()
            let mode = CGDisplayCopyDisplayMode(id).map {
                MacDisplayMode(id: $0.ioDisplayModeID, width: $0.width, height: $0.height,
                               pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                               refreshRate: $0.refreshRate, flags: $0.ioFlags)
            }
            return MacDisplayInfo(
                id: id, uuid: CFUUIDCreateString(nil, uuid) as String,
                vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0, isMain: CGDisplayIsMain(id) != 0,
                isActive: CGDisplayIsActive(id) != 0, isAsleep: CGDisplayIsAsleep(id) != 0,
                isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                mirrorsDisplay: CGDisplayMirrorsDisplay(id), bounds: CGDisplayBounds(id),
                rotation: CGDisplayRotation(id), mode: mode)
        }
        guard try onlineDisplays() == ids else {
            throw ScreenError.message("Displays changed while reading; refresh before changing the main display")
        }
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return MacDisplayState(computerName: name ?? ProcessInfo.processInfo.hostName, displays: displays)
    }

    /// A pure preview: never opens USB, changes a display, or wakes a computer.
    public static func planMain(from state: MacDisplayState, target: MacMainDisplayTarget) throws -> MacDisplayPlan {
        guard state.displays.filter(\.isMonitor).count == 1 else {
            throw ScreenError.message("Connect exactly one MSI MD342CQP video display to this Mac")
        }
        let candidates = state.displays.filter { target == .monitor ? $0.isMonitor : $0.isBuiltIn }
        guard candidates.count == 1, let selected = candidates.first else {
            throw ScreenError.message("The requested main display is unavailable or ambiguous")
        }
        guard Set(state.displays.map(\.id)).count == state.displays.count,
              Set(state.displays.map(\.uuid)).count == state.displays.count,
              state.displays.filter(\.isMain).count == 1,
              state.displays.allSatisfy({ $0.id != 0 && !$0.uuid.isEmpty }) else {
            throw ScreenError.message("Display identity changed; refresh before changing the main display")
        }
        guard state.displays.allSatisfy({ !$0.isMirrored && $0.mirrorsDisplay == 0 }) else {
            throw ScreenError.message("Set displays to an extended desktop in macOS Displays before choosing the main display")
        }
        guard state.displays.allSatisfy({ $0.isActive && !$0.isAsleep && $0.mode != nil }) else {
            throw ScreenError.message("Wake and connect all displays before changing the main display")
        }
        var after = state
        for index in after.displays.indices {
            let original = state.displays[index].bounds
            let x = original.origin.x - selected.bounds.origin.x
            let y = original.origin.y - selected.bounds.origin.y
            guard original.width.isFinite, original.height.isFinite,
                  original.width > 0, original.height > 0 else {
                throw ScreenError.message("Display geometry is unavailable; refresh before changing the main display")
            }
            _ = try coordinate(x)
            _ = try coordinate(y)
            after.displays[index].bounds.origin = CGPoint(x: x, y: y)
            after.displays[index].isMain = after.displays[index].id == selected.id
        }
        return MacDisplayPlan(before: state, after: after, targetDisplayID: selected.id)
    }

    /// Place the laptop beside its MSI display, preserving the chosen main
    /// display and every mode. Universal Control's other-Mac group is separate.
    public static func planArrangement(from state: MacDisplayState,
                                       laptopPosition: MacLaptopPosition) throws -> MacDisplayPlan {
        guard state.displays.count == 2,
              let laptopIndex = state.displays.firstIndex(where: \.isBuiltIn),
              let monitorIndex = state.displays.firstIndex(where: \.isMonitor),
              laptopIndex != monitorIndex else {
            throw ScreenError.message("Arrange requires one MacBook display and one MSI MD342CQP; use macOS Displays for additional displays")
        }
        let mainTarget: MacMainDisplayTarget = state.displays[laptopIndex].isMain ? .builtIn : .monitor
        // Reuse identity, mirroring, activity and geometry validation before
        // replacing any coordinates.
        _ = try planMain(from: state, target: mainTarget)
        var positioned = state
        positioned.displays[laptopIndex].bounds.origin = CGPoint(
            x: laptopPosition == .left ? 0 : state.displays[monitorIndex].bounds.width, y: 0)
        positioned.displays[monitorIndex].bounds.origin = CGPoint(
            x: laptopPosition == .left ? state.displays[laptopIndex].bounds.width : 0, y: 0)
        let normalized = try planMain(from: positioned, target: mainTarget)
        return MacDisplayPlan(before: state, after: normalized.after,
                              targetDisplayID: normalized.targetDisplayID)
    }

    public func arrange(from expected: MacDisplayState,
                        laptopPosition: MacLaptopPosition) throws -> MacDisplayState {
        try apply(Self.planArrangement(from: expected, laptopPosition: laptopPosition))
    }

    public func makeMain(from expected: MacDisplayState, target: MacMainDisplayTarget) throws -> MacDisplayState {
        try apply(Self.planMain(from: expected, target: target))
    }

    private func apply(_ plan: MacDisplayPlan) throws -> MacDisplayState {
        let current = try state()
        try Self.requireUnchanged(current, from: plan.before)
        guard plan.changesRequired else { return current }

        var configuration: CGDisplayConfigRef?
        try Self.check(CGBeginDisplayConfiguration(&configuration), action: "Begin display configuration")
        guard let configuration else { throw ScreenError.message("macOS did not create a display configuration") }
        var ownsConfiguration = true
        defer {
            if ownsConfiguration { _ = CGCancelDisplayConfiguration(configuration) }
        }
        // Include every display: omitted displays can be rearranged by
        // CoreGraphics. Never set modes, rotations, or mirror relationships.
        for display in plan.after.displays {
            try Self.check(CGConfigureDisplayOrigin(configuration, display.id,
                                                    try Self.coordinate(display.bounds.origin.x),
                                                    try Self.coordinate(display.bounds.origin.y)),
                           action: "Arrange \(display.name)")
        }
        // Complete invalidates the configuration even when it reports failure.
        ownsConfiguration = false
        try Self.check(CGCompleteDisplayConfiguration(configuration, .permanently), action: "Apply display arrangement")
        let after = try state()
        try Self.requireVerified(after, plan: plan)
        return after
    }

    static func requireUnchanged(_ current: MacDisplayState, from expected: MacDisplayState) throws {
        guard current.displays == expected.displays else {
            throw ScreenError.message("Displays changed since planning; refresh before changing the main display")
        }
    }

    static func requireVerified(_ actual: MacDisplayState, plan: MacDisplayPlan) throws {
        guard actual.displays == plan.after.displays else {
            throw ScreenError.message("macOS did not preserve the requested main display and arrangement; refresh before trying again")
        }
    }

    private static func coordinate(_ value: CGFloat) throws -> Int32 {
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= CGFloat(Int32.min), value <= CGFloat(Int32.max) else {
            throw ScreenError.message("Display coordinates cannot be represented safely")
        }
        return Int32(value)
    }

    private func onlineDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        try Self.check(CGGetOnlineDisplayList(0, nil, &count), action: "Count displays")
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual = count
        try Self.check(CGGetOnlineDisplayList(count, &ids, &actual), action: "Read displays")
        guard actual <= count else { throw ScreenError.message("Displays changed while reading; refresh") }
        return Array(ids.prefix(Int(actual))).sorted()
    }

    private static func check(_ result: CGError, action: String) throws {
        guard result == .success else {
            throw ScreenError.message("\(action) failed (macOS error \(result.rawValue))")
        }
    }
}
