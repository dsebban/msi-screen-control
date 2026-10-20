import Foundation

/// The fixed, versioned request accepted by the helper over standard input.
public struct MacDisplayRequest: Codable, Equatable {
    public enum Action: String, Codable { case status, main, arrange }

    public let schemaVersion: Int
    public let action: Action
    public let expected: MacDisplayState?
    public let target: MacMainDisplayTarget?
    public let laptopPosition: MacLaptopPosition?

    public init(action: Action, expected: MacDisplayState? = nil, target: MacMainDisplayTarget? = nil,
                laptopPosition: MacLaptopPosition? = nil) throws {
        switch action {
        case .status:
            guard expected == nil, target == nil, laptopPosition == nil else {
                throw ScreenError.message("A display status request accepts no expected state or target")
            }
        case .main:
            guard expected != nil, target != nil, laptopPosition == nil else {
                throw ScreenError.message("A main display request requires expected state and target")
            }
        case .arrange:
            guard expected != nil, laptopPosition != nil, target == nil else {
                throw ScreenError.message("An arrange request requires expected state and laptopPosition, preserving the main display")
            }
        }
        self.schemaVersion = 1
        self.action = action
        self.expected = expected
        self.target = target
        self.laptopPosition = laptopPosition
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, action, expected, target, laptopPosition
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw ScreenError.message("Unknown field in display request")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw ScreenError.message("Unsupported display request schemaVersion; expected 1")
        }
        let action = try values.decode(Action.self, forKey: .action)
        switch action {
        case .status:
            guard !values.contains(.expected), !values.contains(.target), !values.contains(.laptopPosition) else {
                throw ScreenError.message("A display status request accepts only schemaVersion and action")
            }
            try self.init(action: .status)
        case .main:
            guard !values.contains(.laptopPosition) else {
                throw ScreenError.message("A main display request does not accept laptopPosition")
            }
            try self.init(action: .main,
                          expected: values.decode(MacDisplayState.self, forKey: .expected),
                          target: values.decode(MacMainDisplayTarget.self, forKey: .target))
        case .arrange:
            guard !values.contains(.target) else {
                throw ScreenError.message("An arrange request preserves the main display and does not accept target")
            }
            try self.init(action: .arrange,
                          expected: values.decode(MacDisplayState.self, forKey: .expected),
                          laptopPosition: values.decode(MacLaptopPosition.self, forKey: .laptopPosition))
        }
    }
}
