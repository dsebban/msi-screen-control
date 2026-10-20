import XCTest
@testable import MSIScreenCore

final class MonitorSettingsTests: XCTestCase {
    final class Transport: ScreenTransport {
        var values: [String: [UInt8]] = [
            "00140": [48,48,160], "00150": Array("V20".utf8),
            "00600": Array("002".utf8), "00500": Array("000".utf8),
            "00610": Array("003".utf8), "00620": Array("003".utf8),
            "00630": Array("000".utf8), "00640": Array("000".utf8),
            "00190": Array("000".utf8), "00230": Array("000".utf8)
        ]
        var writes = 0
        var ignoreWrites = false
        var changeLayoutOnWrite = false
        var onlineVideoCount: Int? = 1
        init() {
            for setting in MonitorSetting.allCases {
                values[setting.register] = Array(String(format: "%03d", setting.range.lowerBound).utf8)
            }
            values["00870"] = [48,48,98] // Vendor packed value50.
        }
        func query(_ code: String) throws -> [UInt8] {
            guard let value = values[code] else { throw ScreenError.message("Unavailable register") }
            return value
        }
        func writeLayout(_ state: ScreenState, primaryChanged: Bool) throws { XCTFail("Scalar controls must not write layouts") }
        func writeSetting(_ setting: MonitorSetting, value: Int) throws {
            writes += 1
            if !ignoreWrites { values[setting.register] = Array(String(format: "%03d", value).utf8) }
            if changeLayoutOnWrite { values["00600"] = Array("000".utf8) }
        }
    }

    func testScalarFramesPreserveVendorEncodingDifference() throws {
        // Vendor Nuvoton scalar templates: brightness decimal ID16, volume
        // packed ID131. Decimal-encoding volume50 would set a different value.
        XCTAssertEqual(Array(try MSIProtocol.setting(.brightness, value: 50).prefix(12)),
                       [1,53,98,48,48,52,48,48,48,53,48,13])
        XCTAssertEqual(Array(try MSIProtocol.setting(.volume, value: 50).prefix(12)),
                       [1,53,98,48,48,56,55,48,48,48,98,13])
        XCTAssertThrowsError(try MSIProtocol.setting(.volume, value: 101))
    }

    func testInvalidAndStaleChangesDoNotWrite() throws {
        let transport = Transport()
        let controller = ScreenController(transport: transport)
        let original = try controller.settings()
        XCTAssertEqual(original.value(.volume), 50)
        XCTAssertThrowsError(try controller.apply(.volume, value: 101, from: original))
        transport.values["00870"] = [48,48,108]
        XCTAssertThrowsError(try controller.apply(.volume, value: 70, from: original))
        XCTAssertEqual(transport.writes, 0)
    }

    func testHDRUnknownRemainsVisibleAndPBPResponseTimeIsBlocked() throws {
        let transport = Transport()
        transport.values["00190"] = nil
        let controller = ScreenController(transport: transport)
        let current = try controller.settings()
        XCTAssertNil(current.hdrActive)
        XCTAssertNil(current.unavailableReason(.brightness))
        XCTAssertNotNil(current.unavailableReason(.responseTime))
        XCTAssertNil(current.unavailableReason(.volume))
        let after = try controller.apply(.volume, value: 60, from: current)
        XCTAssertEqual(after.value(.volume), 60)
        XCTAssertEqual(after.layout, current.layout)
    }

    func testUnappliedAndLayoutChangingSettingWritesFailVerification() throws {
        let transport = Transport()
        let controller = ScreenController(transport: transport)
        transport.ignoreWrites = true
        XCTAssertThrowsError(try controller.apply(.volume, value: 60, from: controller.settings()))
        XCTAssertEqual(transport.writes, 1)
        transport.ignoreWrites = false
        transport.changeLayoutOnWrite = true
        XCTAssertThrowsError(try controller.apply(.volume, value: 60, from: controller.settings()))
        XCTAssertEqual(transport.writes, 2)
    }

    func testSRGBAndDynamicContrastBlockConflictingChanges() throws {
        let transport = Transport()
        transport.values["00350"] = Array("003".utf8)
        transport.values["00240"] = Array("001".utf8)
        let controller = ScreenController(transport: transport)
        let current = try controller.settings()
        for setting in [MonitorSetting.contrast, .colorTemperature, .lowBlueLight, .brightness] {
            XCTAssertNotNil(current.unavailableReason(setting))
            XCTAssertThrowsError(try controller.apply(setting, value: 1, from: current))
        }
        XCTAssertEqual(transport.writes, 0)
    }

    func testKnownHDRRejectsPictureChange() throws {
        let transport = Transport()
        transport.values["00190"] = Array("001".utf8)
        let controller = ScreenController(transport: transport)
        let current = try controller.settings()
        XCTAssertEqual(current.hdrActive, true)
        XCTAssertNotNil(current.unavailableReason(.brightness))
        XCTAssertThrowsError(try controller.apply(.brightness, value: 60, from: current))
        XCTAssertEqual(transport.writes, 0)
    }

    func testUnavailableRegisterDoesNotInventAValue() throws {
        let transport = Transport()
        transport.values["00870"] = Array("999".utf8)
        let snapshot = try ScreenController(transport: transport).settings()
        XCTAssertNil(snapshot.value(.volume))
        XCTAssertNotNil(snapshot.unavailableReason(.volume))
    }
}
