import AppKit
import XCTest
@testable import MSIScreenMenu
@testable import MSIScreenCore

final class MonitorAppearanceTests: XCTestCase {
    private func state(_ mode: DisplayMode, left: Input, right: Input) -> ScreenState {
        ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: mode,
                    source1: left, source2: right, pipInput: right, pipSize: 2, pipPosition: 3)
    }

    private func raster(_ state: ScreenState?, updateReady: Bool = false) throws -> NSBitmapImageRep {
        let image = MonitorAppearance.statusImage(for: state, updateReady: updateReady)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    }

    private func assertColor(_ bitmap: NSBitmapImageRep, x: Int, expected: NSColor,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 12)?.usingColorSpace(.deviceRGB))
        // Calibrate through the same AppKit bitmap color profile; TIFF can
        // convert device RGB when materializing an NSImage drawing handler.
        let swatch = NSImage(size: NSSize(width: 1, height: 1), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(expected.cgColor)
            context.fill(bounds)
            return true
        }
        let reference = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(swatch.tiffRepresentation)))
        let expected = try XCTUnwrap(reference.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03, file: file, line: line)
    }

    func testPBPUsesActualLeftAndRightSourceColors() throws {
        for (left, right) in [(Input.hdmi1, Input.usbc), (.usbc, .dp)] {
            let bitmap = try raster(state(.pbp, left: left, right: right))
            try assertColor(bitmap, x: 3, expected: MonitorAppearance.color(for: left))
            try assertColor(bitmap, x: 15, expected: MonitorAppearance.color(for: right))
        }
    }

    func testFullscreenColorsBothHalvesFromPrimarySource() throws {
        for input in [Input.hdmi1, .hdmi2, .dp, .usbc] {
            let bitmap = try raster(state(.off, left: input, right: .usbc))
            for x in [3, 15] {
                try assertColor(bitmap, x: x, expected: MonitorAppearance.color(for: input))
            }
        }
    }

    func testUnavailableIsGreyAndHasNoShieldBackground() throws {
        let bitmap = try raster(nil)
        try assertColor(bitmap, x: 3, expected: NSColor(white: 0.55, alpha: 0.75))
        try assertColor(bitmap, x: 15, expected: NSColor(white: 0.55, alpha: 0.75))
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 9, y: 14)).alphaComponent, 0)
    }

    func testUpdateBadgePreservesConnectionAndSourceColors() throws {
        let split = state(.pbp, left: .hdmi1, right: .usbc)
        let badge = try raster(split, updateReady: true)
        try assertColor(badge, x: 3, expected: MonitorAppearance.color(for: .hdmi1))
        try assertColor(badge, x: 15, expected: MonitorAppearance.color(for: .usbc))
        let unavailable = try raster(nil, updateReady: true)
        try assertColor(unavailable, x: 3, expected: NSColor(white: 0.55, alpha: 0.75))
        let dot = try XCTUnwrap(badge.colorAt(x: 15, y: 3)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(dot.redComponent, 0.8)
        XCTAssertGreaterThan(dot.greenComponent, 0.6)
        XCTAssertLessThan(dot.blueComponent, 0.3)
    }
}
