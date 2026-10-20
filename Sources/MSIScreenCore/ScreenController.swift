import Foundation

public enum Input: String, CaseIterable, Codable {
    case hdmi1, hdmi2, dp, usbc
    var value: Int { Self.allCases.firstIndex(of: self)! }
    init(value: Int) { self = Self.allCases[value] }
}

public enum DisplayMode: String, CaseIterable, Codable {
    case off, pip, pbp
    var value: Int { Self.allCases.firstIndex(of: self)! }
    init(value: Int) { self = Self.allCases[value] }
}

public struct ScreenState: Codable, Equatable {
    public let model: String
    public let protocolVersion: String
    public var mode: DisplayMode
    public var source1: Input
    public var source2: Input
    public var pipInput: Input
    public let pipSize: Int
    public let pipPosition: Int
}

public struct Change: Codable, Equatable {
    public let setting: String
    public let value: String
}

public protocol ScreenTransport {
    func query(_ code: String) throws -> [UInt8]
    func writeLayout(_ state: ScreenState) throws
    var onlineVideoCount: Int? { get }
}

public final class ScreenController {
    private let transport: ScreenTransport
    public init(transport: ScreenTransport) { self.transport = transport }

    public func state() throws -> ScreenState {
        let identity = try transport.query("00140")
        let version = try transport.query("00150")
        guard identity == [0x30, 0x30, 0xa0], version == Array("V20".utf8) else {
            throw ScreenError.message("Unrecognized MSI model/protocol (\(identity.hex), \(version.hex)); no settings changed")
        }
        // MD342CQP uses the primary input for source 1, and 00610 for the
        // secondary PBP source. 00670/00680 belong to older four-source models.
        return try ScreenState(model: "MD342CQP", protocolVersion: "V20",
                               mode: DisplayMode(value: read("00600", range: 0...2)),
                               source1: Input(value: read("00500", range: 0...3)),
                               source2: Input(value: read("00610", range: 0...3)),
                               pipInput: Input(value: read("00620", range: 0...3)),
                               pipSize: read("00630", range: 0...2),
                               pipPosition: read("00640", range: 0...3))
    }

    private func read(_ code: String, range: ClosedRange<Int>) throws -> Int {
        let bytes = try transport.query(code)
        guard bytes.count == 3, bytes.allSatisfy({ (48...57).contains($0) }),
              let value = Int(String(decoding: bytes, as: UTF8.self)), range.contains(value) else {
            throw ScreenError.message("Unsupported response for \(code): \(bytes.hex)")
        }
        return value
    }

    public static func pbpTarget(from state: ScreenState, enabled: Bool, left: Input?, right: Input?) throws -> ScreenState {
        guard enabled || (left == nil && right == nil) else {
            throw ScreenError.message("Use --left/--right with pbp on")
        }
        var target = state
        target.mode = enabled ? .pbp : .off
        if let left { target.source1 = left }
        if let right { target.source2 = right }
        // Hardware couples the PIP and PBP secondary registers while in PBP.
        // A live side-swap changes both 00610 and 00620 to the new secondary.
        if enabled { target.pipInput = target.source2 }
        guard !enabled || target.source1 != target.source2 else {
            throw ScreenError.message("PBP requires two different input sources")
        }
        return target
    }

    public static func changes(from before: ScreenState, to target: ScreenState) -> [Change] {
        var result: [Change] = []
        if before.mode != target.mode { result.append(Change(setting: "mode", value: target.mode.rawValue)) }
        if before.source1 != target.source1 { result.append(Change(setting: "source1", value: target.source1.rawValue)) }
        if before.source2 != target.source2 { result.append(Change(setting: "source2", value: target.source2.rawValue)) }
        if before.pipInput != target.pipInput { result.append(Change(setting: "pipInput", value: target.pipInput.rawValue)) }
        return result
    }

    public static func fullscreenTarget(from state: ScreenState, input: Input) -> ScreenState {
        var target = state
        target.mode = .off
        target.source1 = input
        return target
    }

    public func apply(_ target: ScreenState, from before: ScreenState) throws -> ScreenState {
        guard try state() == before else { throw ScreenError.message("Monitor changed since planning; read status again") }
        let videoCountBefore = transport.onlineVideoCount
        if target != before {
            try transport.writeLayout(target)
            // MSI's MD342CQP profile builder waits 5000 ms after the complete
            // PIPSpecial packet. Short writes can echo transient, unapplied values.
            Thread.sleep(forTimeInterval: 5)
        }
        var after = try state()
        var initializedLayout = after
        initializedLayout.mode = target.mode
        // Cold USB-C initialization was reproduced on this unit: its video
        // device appears, sources apply, but PBP returns to off. Complete that
        // specific transition once. Never retry USB errors or other mismatches.
        if target != before, target.mode == .pbp, after.mode == .off,
           target.source1 == .usbc || target.source2 == .usbc,
           videoCountBefore == 0, transport.onlineVideoCount == 1, initializedLayout == target {
            try transport.writeLayout(target)
            Thread.sleep(forTimeInterval: 5)
            after = try state()
        }
        guard after == target else {
            throw ScreenError.message("Layout did not persist after settling; read status before retrying. Observed mode=\(after.mode.rawValue), source1=\(after.source1.rawValue), source2=\(after.source2.rawValue)")
        }
        return after
    }
}
