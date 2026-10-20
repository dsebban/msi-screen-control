import XCTest
@testable import MSIScreenCore

final class GameControllerTests: XCTestCase {
    func testHIDInventoryExcludesObservedMonitorMouseKeyboardAndSensors() async {
        await MainActor.run {
            for (name, page, usage) in [
                ("MSI Gaming Controller", 1, 0), ("Rapoo NearLink Mouse", 1, 2),
                ("USB Receiver", 1, 6), ("Apple Internal Keyboard / Trackpad", 1, 6),
                ("Headset", 12, 1), ("Game controller", 65280, 4)
            ] {
                XCTAssertFalse(GameControllerClient.isController(name: name, usagePage: page, usage: usage), name)
            }
            XCTAssertTrue(GameControllerClient.isController(name: "Xbox Wireless Controller", usagePage: 1, usage: 5))
            // Keep the actually observed Android-mode device visible so the UI
            // can explain its unsupported mode instead of calling it absent.
            XCTAssertTrue(GameControllerClient.isController(name: "BSP-D8", usagePage: 12, usage: 1))
        }
    }
}
