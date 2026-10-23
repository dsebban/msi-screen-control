import Foundation
import CoreGraphics

public struct VideoModeCapability: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Zero means macOS did not report a fixed refresh rate, not zero Hertz.
    public let refreshRate: Double
}

extension VideoModeCapability {
    init(_ mode: CGDisplayMode) {
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }
}

public struct VideoDisplayDiagnostics: Codable, Equatable, Sendable {
    public let display: MacDisplayInfo
    public let modes: [VideoModeCapability]
}

public struct VideoDiagnosticsSnapshot: Encodable, Sendable {
    public let checkedAt: Date
    public let displays: [VideoDisplayDiagnostics]
    public let links: MacVideoConnectionSnapshot
    public let error: String?
    public var complete: Bool { error == nil && links.outcome == .complete }

    private enum CodingKeys: String, CodingKey { case checkedAt, displays, links, error, complete }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(checkedAt, forKey: .checkedAt)
        try values.encode(displays, forKey: .displays)
        try values.encode(links, forKey: .links)
        try values.encodeIfPresent(error, forKey: .error)
        try values.encode(complete, forKey: .complete)
    }

    /// Shared model identities are candidates, never proof that two identical
    /// monitors are the same physical unit. Do not pick the first match.
    public func connection(for display: MacDisplayInfo) -> MacVideoConnection? {
        guard links.outcome == .complete,
              displays.filter({ $0.display.vendor == display.vendor && $0.display.model == display.model }).count == 1 else { return nil }
        let matches = links.connections.filter { $0.display.vendorID == display.vendor && $0.display.productID == display.model }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// No HID, network, user client, wake, mode setter, subprocess or privileged API.
/// Quartz modes describe choices macOS currently exposes, not panel limits.
public struct VideoDiagnosticsClient {
    struct Services {
        var displays: () throws -> MacDisplayState
        var modes: (CGDirectDisplayID) throws -> [VideoModeCapability]
        var links: () -> MacVideoConnectionSnapshot
    }
    private let services: Services
    public init() {
        services = Services(displays: { try MacDisplayController().state() }, modes: { id in
            guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] else {
                throw ScreenError.message("macOS did not return available display modes")
            }
            return modes.map(VideoModeCapability.init)
        }, links: { MacVideoConnectionReader().snapshot() })
    }
    init(services: Services) { self.services = services }

    public func snapshot() -> VideoDiagnosticsSnapshot {
        let links = services.links()
        do {
            let before = try services.displays()
            let displays = try before.displays.filter(\.isMonitor).map { display in
                let modes = try services.modes(display.id)
                guard !modes.isEmpty, modes.allSatisfy({ $0.width > 0 && $0.height > 0
                    && $0.pixelWidth > 0 && $0.pixelHeight > 0 && $0.refreshRate.isFinite && $0.refreshRate >= 0 }) else {
                    throw ScreenError.message("Available display modes are incomplete")
                }
                return VideoDisplayDiagnostics(display: display, modes: Array(Set(modes)).sorted {
                    if $0.width != $1.width { return $0.width > $1.width }
                    if $0.height != $1.height { return $0.height > $1.height }
                    if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
                    if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight > $1.pixelHeight }
                    return $0.refreshRate < $1.refreshRate
                })
            }
            let after = try services.displays()
            guard before == after else { throw ScreenError.message("Display configuration changed during the read") }
            return VideoDiagnosticsSnapshot(checkedAt: Date(), displays: displays, links: links, error: nil)
        } catch {
            return VideoDiagnosticsSnapshot(checkedAt: Date(), displays: [], links: links, error: error.localizedDescription)
        }
    }
}

public struct VideoStabilityEvent: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case connected, disconnected, mode, capabilities, link, unavailable, resumed }
    public let id: UInt64
    public let date: Date
    public let kind: Kind
    public let message: String
}

/// Bounded session observations. No-event intervals do not prove signal quality
/// or exclude a disconnect shorter than the observation interval.
public struct VideoStabilityHistory: Sendable {
    public private(set) var startedAt: Date?
    public private(set) var lastCheckedAt: Date?
    public private(set) var events: [VideoStabilityEvent] = []
    public private(set) var changeCount = 0
    private var previous: VideoDiagnosticsSnapshot?
    private var sourceFailed = false
    private var sequence: UInt64 = 0
    public init() {}

    public mutating func observe(_ snapshot: VideoDiagnosticsSnapshot) {
        if startedAt == nil { startedAt = snapshot.checkedAt }
        lastCheckedAt = snapshot.checkedAt
        guard snapshot.complete else {
            if !sourceFailed { append(.unavailable, "Observation incomplete; this interval cannot establish continuity.", at: snapshot.checkedAt) }
            sourceFailed = true
            return
        }
        if sourceFailed {
            append(.resumed, "Observation resumed; changes during the gap are unknown.", at: snapshot.checkedAt)
            sourceFailed = false
            previous = snapshot
            return
        }
        defer { previous = snapshot }
        guard let previous else { return }
        // OS display IDs distinguish concurrent displays with duplicate EDID
        // UUIDs; re-enumeration is deliberately an observed reconnect.
        let old = Dictionary(uniqueKeysWithValues: previous.displays.map { ("\($0.display.id):\($0.display.uuid)", $0) })
        let new = Dictionary(uniqueKeysWithValues: snapshot.displays.map { ("\($0.display.id):\($0.display.uuid)", $0) })
        for uuid in old.keys.sorted() where new[uuid] == nil { append(.disconnected, "MSI display disconnected from macOS.", at: snapshot.checkedAt) }
        for uuid in new.keys.sorted() {
            guard let current = new[uuid], let prior = old[uuid] else {
                append(.connected, "MSI display connected to macOS.", at: snapshot.checkedAt); continue
            }
            if prior.display.mode != current.display.mode || prior.display.isAsleep != current.display.isAsleep {
                append(.mode, "Display mode or sleep state changed.", at: snapshot.checkedAt)
            }
            if prior.modes != current.modes { append(.capabilities, "Available resolutions or refresh rates changed.", at: snapshot.checkedAt) }
        }
        if previous.links.portStates != snapshot.links.portStates {
            append(.link, "Local video port, link rate, driver or hot-plug state changed.", at: snapshot.checkedAt)
        }
    }

    private mutating func append(_ kind: VideoStabilityEvent.Kind, _ message: String, at date: Date) {
        sequence += 1
        if kind != .unavailable && kind != .resumed { changeCount += 1 }
        events.append(VideoStabilityEvent(id: sequence, date: date, kind: kind, message: message))
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }
}
