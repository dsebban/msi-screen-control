import XCTest
@testable import MSIScreenCore

final class ScreenTests: XCTestCase {
    let initial = ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: .off,
                              source1: .dp, source2: .usbc, pipInput: .usbc, pipSize: 0, pipPosition: 0)

    func testReplyMustMatchTheRequestedRegister() {
        XCTAssertThrowsError(try MSIProtocol.value([1] + Array("5b00620003\r".utf8), for: "00610"))
        XCTAssertThrowsError(try MSIProtocol.value([1] + Array("5b00610003".utf8), for: "00610"))
        XCTAssertEqual(try MSIProtocol.value([1] + Array("5b0014000".utf8) + [0xa0, 13], for: "00140"), [48, 48, 0xa0])
    }

    func testCompletePacketMatchesVendorPBPFormatAndPreservesPIPFields() throws {
        var target = initial
        target.mode = .pbp
        // Reference layout from PI's MD342CQP builder, including its binary
        // 0xff unchanged sentinels. Independent of the report implementation.
        let expected: [UInt8] = [1, 0x35, 0x62, 0x30, 0x30, 0x31, 0x67,
                                 0x32, 0x33, 0x33, 0x30, 0x30, 0x32,
                                 0x30, 0x30, 0x30, 0xff, 0xff, 0xff,
                                 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 13]
        let actual = try MSIProtocol.layout(target)
        XCTAssertEqual(Array(actual.prefix(expected.count)), expected)
        XCTAssertEqual(actual.count, 64)
        XCTAssertTrue(actual.dropFirst(expected.count).allSatisfy { $0 == 0 })
    }

    func testDesiredLayoutCouplesSecondaryInputAndKeepsPIPGeometry() throws {
        let target = try ScreenController.pbpTarget(from: initial, enabled: true, left: .usbc, right: .dp)
        XCTAssertEqual(target.source1, .usbc)
        XCTAssertEqual(target.source2, .dp)
        XCTAssertEqual(target.pipInput, .dp)
        XCTAssertEqual(target.pipSize, initial.pipSize)
        XCTAssertTrue(ScreenController.changes(from: target, to: try ScreenController.pbpTarget(from: target, enabled: true, left: .usbc, right: .dp)).isEmpty)
        XCTAssertThrowsError(try ScreenController.pbpTarget(from: initial, enabled: true, left: .dp, right: .dp))
    }

    func testFullscreenSendsPrimarySelectionAfterCompleteLayout() throws {
        // Reproduced on MD342CQP: off+DP in the complete packet exits PBP but
        // leaves HDMI1 selected. Vendor register 00500 must follow that packet.
        let reports = try MSIProtocol.layoutReports(initial, primaryChanged: true)
        guard reports.count == 2 else {
            return XCTFail("Full screen must send the layout and explicit primary input")
        }
        XCTAssertEqual(Array(reports[0].prefix(7)), [1] + Array("5b001g".utf8))
        let primary = [UInt8(1)] + Array("5b00500002\r".utf8)
        XCTAssertEqual(reports[1], primary + Array(repeating: 0, count: 64 - primary.count))
        var split = initial
        split.mode = .pbp
        XCTAssertEqual(try MSIProtocol.layoutReports(initial, primaryChanged: false).count, 1,
                       "Exiting split on the same primary must not reselect that input")
        XCTAssertEqual(try MSIProtocol.layoutReports(split, primaryChanged: true).count, 1,
                       "PBP continues to use only its complete layout packet")
    }

    func testFullscreenLeavesSplitModeWithoutChangingSavedSecondaryOrPIPGeometry() throws {
        let split = try ScreenController.pbpTarget(from: initial, enabled: true, left: .dp, right: .usbc)
        let full = ScreenController.fullscreenTarget(from: split, input: .usbc)
        XCTAssertEqual(full.mode, .off)
        XCTAssertEqual(full.source1, .usbc)
        XCTAssertEqual(full.source2, split.source2)
        XCTAssertEqual(full.pipInput, split.pipInput)
        XCTAssertEqual(full.pipSize, split.pipSize)
        XCTAssertEqual(full.pipPosition, split.pipPosition)
        XCTAssertEqual(ScreenController.fullscreenTarget(from: full, input: .usbc), full)
    }

    final class Transport: ScreenTransport {
        var values: [String: [UInt8]] = ["00140": [48,48,160], "00150": Array("V20".utf8), "00600": Array("000".utf8), "00500": Array("002".utf8), "00610": Array("003".utf8), "00620": Array("003".utf8), "00630": Array("000".utf8), "00640": Array("000".utf8)]
        var writes = 0
        var ignoreWrites = false
        var onlineVideoCount: Int? = 1
        var coldUSBVideo = false
        func query(_ code: String) throws -> [UInt8] { values[code]! }
        func writeSetting(_ setting: MonitorSetting, value: Int) throws {
            XCTFail("Layout operations must not write individual settings")
        }
        func writeLayout(_ state: ScreenState, primaryChanged: Bool) throws {
            writes += 1
            if coldUSBVideo && writes == 1 {
                onlineVideoCount = 1
                return
            }
            if !ignoreWrites {
                for (code, value) in [("00600", state.mode.value), ("00500", state.source1.value), ("00610", state.source2.value), ("00620", state.mode == .pbp ? state.source2.value : state.pipInput.value)] {
                    values[code] = Array(String(format: "%03d", value).utf8)
                }
            }
        }
    }

    func testUnrecognizedMonitorFailsBeforeAnyWrite() {
        let transport = Transport()
        transport.values["00140"] = [48,48,161]
        XCTAssertThrowsError(try ScreenController(transport: transport).apply(initial, from: initial))
        XCTAssertEqual(transport.writes, 0)
    }

    func testPhysicalOSDChangeInvalidatesPendingLayout() {
        let transport = Transport()
        transport.values["00610"] = Array("001".utf8)
        XCTAssertThrowsError(try ScreenController(transport: transport).apply(initial, from: initial))
        XCTAssertEqual(transport.writes, 0)
    }

    func testRepeatedDesiredStateDoesNotWrite() throws {
        let transport = Transport()
        XCTAssertEqual(try ScreenController(transport: transport).apply(initial, from: initial), initial)
        XCTAssertEqual(transport.writes, 0)
    }

    func testFullscreenExitsPBPWithDuplicateSavedSources() throws {
        let transport = Transport()
        transport.values["00600"] = Array("002".utf8)
        transport.values["00500"] = Array("003".utf8)
        let controller = ScreenController(transport: transport)
        let duplicated = try controller.state()
        let target = ScreenController.fullscreenTarget(from: duplicated, input: .usbc)
        let result = try controller.apply(target, from: duplicated)
        XCTAssertEqual(result.mode, .off)
        XCTAssertEqual(result.source1, .usbc)
        XCTAssertEqual(result.source2, duplicated.source2)
        XCTAssertEqual(result.pipInput, duplicated.pipInput)
        XCTAssertEqual(transport.writes, 1)
    }

    func testAcknowledgedButUnappliedLayoutFailsVerification() throws {
        let transport = Transport()
        transport.ignoreWrites = true
        let target = try ScreenController.pbpTarget(from: initial, enabled: true, left: nil, right: nil)
        XCTAssertThrowsError(try ScreenController(transport: transport).apply(target, from: initial)) { error in
            XCTAssertTrue(String(describing: error).contains("did not persist"))
        }
        XCTAssertEqual(transport.writes, 1)
    }

    func testColdUSBVideoInitializationCompletesTheLayoutOnce() throws {
        let transport = Transport()
        transport.onlineVideoCount = 0
        transport.coldUSBVideo = true
        let target = try ScreenController.pbpTarget(from: initial, enabled: true, left: nil, right: nil)
        XCTAssertEqual(try ScreenController(transport: transport).apply(target, from: initial), target)
        XCTAssertEqual(transport.writes, 2)
    }
}
