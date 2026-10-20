import Foundation

public enum ScreenError: Error, CustomStringConvertible, LocalizedError {
    case message(String)
    public var description: String {
        switch self { case .message(let text): return text }
    }
    public var errorDescription: String? { description }
}

public enum MSIProtocol {
    static func kvm(_ route: KVMRoute) throws -> [UInt8] {
        guard route != .auto else { throw ScreenError.message("Auto is read-only") }
        let value: UInt8 = route == .upstream ? 49 : 50
        return report(Array("5b008>0".utf8) + [48, 48, value, 13])
    }

    static func setting(_ setting: MonitorSetting, value: Int) throws -> [UInt8] {
        guard setting.accepts(value) else {
            throw ScreenError.message("Invalid \(setting.title) value; no report sent")
        }
        let encoded = setting.usesDecimalPayload
            ? Array(String(format: "%03d", value).utf8)
            : [48, 48, UInt8(value + 48)]
        return report(Array(("5b" + setting.register).utf8) + encoded + [13])
    }

    public static func query(_ code: String) -> [UInt8] {
        report(Array(("58" + code).utf8) + [13])
    }

    static func layout(_ state: ScreenState) throws -> [UInt8] {
        guard state.model == "MD342CQP", state.protocolVersion == "V20",
              (0...2).contains(state.pipSize), (0...3).contains(state.pipPosition) else {
            throw ScreenError.message("Unsupported monitor/layout; no report sent")
        }
        // Derived from the official PI utility's MD342CQP profile builder:
        // mode, PBP secondary, PIP secondary, PIP size, PIP position, primary;
        // then three zero fields, three unchanged sentinels, seven zero fields.
        let fields = [state.mode.value, state.source2.value, state.pipInput.value,
                      state.pipSize, state.pipPosition, state.source1.value]
            + [0, 0, 0, 207, 207, 207, 0, 0, 0, 0, 0, 0, 0]
        return report(Array("5b001g".utf8) + fields.map { UInt8($0 + 48) } + [13])
    }

    static func layoutReports(_ state: ScreenState, primaryChanged: Bool) throws -> [[UInt8]] {
        var reports = [try layout(state)]
        // This model ignores the primary field in a full-screen layout packet.
        // Live PBP -> DP testing requires the vendor's separate 00500 setter
        // immediately after it, before the shared settling/readback interval.
        if state.mode == .off && primaryChanged {
            reports.append(report(Array("5b00500".utf8) + [48, 48, UInt8(state.source1.value + 48), 13]))
        }
        return reports
    }

    private static func report(_ command: [UInt8]) -> [UInt8] {
        let bytes: [UInt8] = [1] + command
        return bytes + Array(repeating: 0, count: 64 - bytes.count)
    }

    public static func value(_ report: [UInt8], for code: String) throws -> [UInt8] {
        let body = try body(report)
        let expected = Array(("5b" + code).utf8)
        guard body.starts(with: expected), body.count > expected.count else {
            throw ScreenError.message("Unexpected HID reply for \(code): \(body.hex)")
        }
        return Array(body.dropFirst(expected.count))
    }

    static func acknowledge(_ report: [UInt8]) throws {
        guard try body(report) == Array("5600+".utf8) else {
            throw ScreenError.message("Monitor did not acknowledge the change")
        }
    }

    private static func body(_ report: [UInt8]) throws -> [UInt8] {
        let bytes = report.first == 1 ? Array(report.dropFirst()) : report
        guard let end = bytes.firstIndex(of: 13) else { throw ScreenError.message("Unterminated HID reply") }
        return Array(bytes[..<end])
    }
}

public extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
