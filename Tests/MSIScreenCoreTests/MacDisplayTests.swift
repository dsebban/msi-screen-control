import XCTest
@testable import MSIScreenCore

final class MacDisplayTests: XCTestCase {
    private let mode = MacDisplayMode(id: 7, width: 1720, height: 1440,
                                      pixelWidth: 1720, pixelHeight: 1440, refreshRate: 60, flags: 0)

    private func display(_ id: UInt32, x: CGFloat, y: CGFloat, monitor: Bool = false,
                         builtIn: Bool = false, main: Bool = false, mirrored: Bool = false,
                         active: Bool = true) -> MacDisplayInfo {
        MacDisplayInfo(id: id, uuid: "display-\(id)", vendor: monitor ? 0x3669 : 0x610,
                       model: monitor ? 0x30c5 : 1, isBuiltIn: builtIn, isMain: main,
                       isActive: active, isAsleep: false, isMirrored: mirrored, mirrorsDisplay: 0,
                       bounds: CGRect(x: x, y: y, width: 1720, height: 1440), rotation: 0, mode: mode)
    }

    private var initial: MacDisplayState {
        MacDisplayState(computerName: "Test Mac", displays: [
            display(1, x: 0, y: 0, builtIn: true, main: true),
            display(4, x: 1720, y: -300, monitor: true),
            display(8, x: -1720, y: 500)
        ])
    }

    func testMainChangeTranslatesAllDisplaysAndPreservesModesAndRelativeArrangement() throws {
        let baseline = initial
        let plan = try MacDisplayController.planMain(from: baseline, target: .monitor)
        XCTAssertEqual(plan.after.displays.map(\.bounds.origin),
                       [CGPoint(x: -1720, y: 300), .zero, CGPoint(x: -3440, y: 800)])
        XCTAssertEqual(plan.after.displays.filter(\.isMain).map(\.id), [4])
        XCTAssertEqual(plan.after.displays.map(\.mode), baseline.displays.map(\.mode))
        XCTAssertEqual(plan.after.displays.map(\.bounds.size), baseline.displays.map(\.bounds.size))
        let restored = try MacDisplayController.planMain(from: plan.after, target: .builtIn)
        XCTAssertEqual(restored.after, baseline)
    }

    func testStaleGeometryDisconnectAndReusedDisplayIDFailComparison() throws {
        var moved = initial
        moved.displays[2].bounds.origin.x -= 20
        XCTAssertThrowsError(try MacDisplayController.requireUnchanged(moved, from: initial))
        var disconnected = initial
        disconnected.displays.removeLast()
        XCTAssertThrowsError(try MacDisplayController.requireUnchanged(disconnected, from: initial))
        var replaced = initial
        let old = replaced.displays[1]
        replaced.displays[1] = MacDisplayInfo(
            id: old.id, uuid: "different-physical-display", vendor: old.vendor, model: old.model,
            isBuiltIn: old.isBuiltIn, isMain: old.isMain, isActive: old.isActive, isAsleep: old.isAsleep,
            isMirrored: old.isMirrored, mirrorsDisplay: old.mirrorsDisplay, bounds: old.bounds,
            rotation: old.rotation, mode: old.mode)
        XCTAssertThrowsError(try MacDisplayController.requireUnchanged(replaced, from: initial))
    }

    func testMirroredAndInactiveDisplaysAreNotSilentlyRearranged() {
        var mirrored = initial
        mirrored.displays[2] = display(8, x: 0, y: 0, mirrored: true)
        XCTAssertThrowsError(try MacDisplayController.planMain(from: mirrored, target: .monitor))
        var inactive = initial
        inactive.displays[2] = display(8, x: -1720, y: 500, active: false)
        XCTAssertThrowsError(try MacDisplayController.planMain(from: inactive, target: .monitor))
    }

    func testLaptopArrangementPreservesEitherMainRoleAndUsesActualWidths() throws {
        var pair = initial
        pair.displays.removeLast()
        pair.displays[0].bounds.size = CGSize(width: 1512, height: 982)
        for target in MacMainDisplayTarget.allCases {
            let baseline = try MacDisplayController.planMain(from: pair, target: target).after
            for position in MacLaptopPosition.allCases {
                let plan = try MacDisplayController.planArrangement(from: baseline, laptopPosition: position)
                let laptop = plan.after.displays[0]
                let monitor = plan.after.displays[1]
                XCTAssertEqual(plan.after.laptopPosition, position)
                XCTAssertEqual(laptop.bounds.minY, monitor.bounds.minY)
                if position == .left { XCTAssertEqual(laptop.bounds.maxX, monitor.bounds.minX) }
                else { XCTAssertEqual(monitor.bounds.maxX, laptop.bounds.minX) }
                XCTAssertEqual(plan.after.displays.map(\.isMain), baseline.displays.map(\.isMain))
                XCTAssertEqual(plan.after.displays.first(where: \.isMain)?.bounds.origin, .zero)
                XCTAssertEqual(plan.after.displays.map(\.mode), baseline.displays.map(\.mode))
                XCTAssertEqual(plan.after.displays.map(\.bounds.size), baseline.displays.map(\.bounds.size))
                XCTAssertFalse(try MacDisplayController.planArrangement(
                    from: plan.after, laptopPosition: position).changesRequired)
                let opposite: MacLaptopPosition = position == .left ? .right : .left
                let switched = try MacDisplayController.planArrangement(from: plan.after, laptopPosition: opposite)
                XCTAssertEqual(switched.after.laptopPosition, opposite)
                XCTAssertEqual(switched.after.displays.map(\.isMain), baseline.displays.map(\.isMain))
            }
        }
    }

    func testArrangementDoesNotRelocateAnUnrelatedDisplayOrAlterMirroring() {
        XCTAssertThrowsError(try MacDisplayController.planArrangement(from: initial, laptopPosition: .right))
        var mirrored = initial
        mirrored.displays.removeLast()
        mirrored.displays[1] = display(4, x: 0, y: 0, monitor: true, mirrored: true)
        XCTAssertThrowsError(try MacDisplayController.planArrangement(from: mirrored, laptopPosition: .right))
        XCTAssertNil(mirrored.laptopPosition)
    }

    func testMainAlreadySelectedHasNoConfigurationChanges() throws {
        let plan = try MacDisplayController.planMain(from: initial, target: .builtIn)
        XCTAssertFalse(plan.changesRequired)
        XCTAssertEqual(plan.after, initial)
    }

    func testMissingOrAmbiguousMSIIdentityDoesNotSelectAnotherDisplay() {
        var missing = initial
        missing.displays.removeAll(where: \.isMonitor)
        XCTAssertThrowsError(try MacDisplayController.planMain(from: missing, target: .monitor))
        var ambiguous = initial
        ambiguous.displays.append(display(9, x: 3440, y: -300, monitor: true))
        XCTAssertThrowsError(try MacDisplayController.planMain(from: ambiguous, target: .monitor))
    }

    func testReadbackRejectsOSAdjustedGeometryOrModeDespiteCorrectMainDisplay() throws {
        let plan = try MacDisplayController.planMain(from: initial, target: .monitor)
        var adjusted = plan.after
        adjusted.displays[2].bounds.origin.y += 100
        XCTAssertThrowsError(try MacDisplayController.requireVerified(adjusted, plan: plan))
        var changedMode = plan.after
        let old = changedMode.displays[1]
        changedMode.displays[1] = MacDisplayInfo(
            id: old.id, uuid: old.uuid, vendor: old.vendor, model: old.model, isBuiltIn: old.isBuiltIn,
            isMain: old.isMain, isActive: old.isActive, isAsleep: old.isAsleep,
            isMirrored: old.isMirrored, mirrorsDisplay: old.mirrorsDisplay, bounds: old.bounds,
            rotation: old.rotation, mode: nil)
        XCTAssertThrowsError(try MacDisplayController.requireVerified(changedMode, plan: plan))
        XCTAssertNoThrow(try MacDisplayController.requireVerified(plan.after, plan: plan))
    }
}
