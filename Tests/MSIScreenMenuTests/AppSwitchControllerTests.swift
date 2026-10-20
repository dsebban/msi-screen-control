import XCTest
@testable import MSIScreenMenu

// Exercise only the value-type burst state; never register keys or activate apps.
final class AppSwitchControllerTests: XCTestCase {
    func testThreeAppsAdvanceDespiteLateFrontmostAndMRUNotifications() {
        var state = AppCycleState<String>()
        let apps = ["A", "B", "C"]
        state.recordActivation("A", live: Set(apps))
        XCTAssertEqual(state.next(applications: apps, frontmost: "A", direction: 1, now: 0), "B")
        state.recordActivation("B", live: Set(apps))
        XCTAssertEqual(state.next(applications: apps, frontmost: "A", direction: 1, now: 0.15), "C")
        state.recordActivation("C", live: Set(apps))
        XCTAssertEqual(state.next(applications: apps, frontmost: "B", direction: 1, now: 0.30), "A")
    }

    func testReverseWrapsAndDirectionChangeWalksBackThroughSameRing() {
        var state = AppCycleState<String>()
        let apps = ["A", "B", "C"]
        XCTAssertEqual(state.next(applications: apps, frontmost: "A", direction: -1, now: 0), "C")
        XCTAssertEqual(state.next(applications: apps, frontmost: "A", direction: -1, now: 0.15), "B")
        XCTAssertEqual(state.next(applications: apps, frontmost: "A", direction: 1, now: 0.30), "C")
    }

    func testThrottledPulsesKeepBurstFrozenWhileMRUChanges() {
        var state = AppCycleState<String>()
        let apps = ["A", "B", "C", "D"]
        XCTAssertEqual(state.next(applications: apps, frontmost: "A", direction: 1, now: 0), "B")
        state.recordActivation("D", live: Set(apps))
        // Each accepted step is over 0.8s apart; intervening throttled pulses
        // must extend the same burst instead of rebuilding it from changed MRU.
        XCTAssertNil(state.next(applications: apps, frontmost: "D", direction: 1, now: 0.05))
        XCTAssertEqual(state.next(applications: apps, frontmost: "D", direction: 1, now: 0.825), "C")
        XCTAssertNil(state.next(applications: apps, frontmost: "D", direction: 1, now: 0.875))
        XCTAssertEqual(state.next(applications: apps, frontmost: "D", direction: 1, now: 1.65), "D")
    }

    func testIdleGapRebuildsUsingNewFrontmostAndCurrentApps() {
        var state = AppCycleState<String>()
        XCTAssertEqual(state.next(applications: ["A", "B", "C"], frontmost: "A", direction: 1, now: 0), "B")
        state.recordActivation("C", live: ["B", "C", "D"])
        XCTAssertEqual(state.next(applications: ["B", "C", "D"], frontmost: "C", direction: 1, now: 1), "B")
    }

    func testTerminatedAppsAreSkippedWithoutChangingFrozenPositions() {
        var state = AppCycleState<String>()
        XCTAssertEqual(state.next(applications: ["A", "B", "C", "D"], frontmost: "A", direction: 1, now: 0), "B")
        XCTAssertEqual(state.next(applications: ["A", "D"], frontmost: "A", direction: 1, now: 0.15), "D")
        XCTAssertEqual(state.next(applications: ["A", "D"], frontmost: "D", direction: -1, now: 0.30), "A")
    }

    func testEmptyAndSingleAppDoNotActivateRepeatedly() {
        var state = AppCycleState<String>()
        XCTAssertNil(state.next(applications: [], frontmost: nil, direction: 1, now: 0))
        XCTAssertNil(state.next(applications: ["A"], frontmost: "A", direction: 1, now: 1))
        XCTAssertNil(state.next(applications: ["A"], frontmost: "A", direction: -1, now: 2))
    }
}
