import XCTest
import CoreGraphics
import Carbon
@testable import MSIScreenMenu

final class SpaceShortcutTests: XCTestCase {
    func testSpaceShortcutCarriesPhysicalArrowFlagsAndReleasesControl() async throws {
        try await MainActor.run {
            for (direction, arrow) in [(-1, kVK_LeftArrow), (1, kVK_RightArrow)] {
                let events = try XCTUnwrap(AppSwitchController.spaceShortcutEvents(direction: direction))
                XCTAssertEqual(events.count, 4)
                XCTAssertEqual(events.map { $0.getIntegerValueField(.eventSourceStateID) },
                               Array(repeating: Int64(CGEventSourceStateID.hidSystemState.rawValue), count: 4))
                XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                               [Int64(kVK_Control), Int64(arrow), Int64(arrow), Int64(kVK_Control)])
                let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn]
                XCTAssertEqual(events.map { $0.flags.rawValue },
                               [CGEventFlags.maskControl.rawValue, arrowFlags.rawValue,
                                arrowFlags.rawValue, 0])
                XCTAssertEqual(events[1].type, .keyDown)
                XCTAssertEqual(events[2].type, .keyUp)
                XCTAssertEqual(events.map { $0.type }, [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
            }
        }
    }
}
