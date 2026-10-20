import Foundation
import XCTest
@testable import MSIScreenCore

final class POPKeyboardTests: XCTestCase {
    private let expected = PairedUSBPeripheral(slot: 1, name: "Logi POP Keys", kind: .keyboard,
        wirelessProductID: "B365", radio: .responding, protocolVersion: "2.0", error: nil)

    private final class Fixture {
        var features = [0, 1, 3, 0x1004, 0x40a2, 0x1b04]
        var packets: [BoltReadRequest] = []
        var timeoutIndex: UInt8?
        var badMappingEcho = false
        var identity = "B365"
        var pingResponds = true

        func request(_ request: BoltReadRequest) throws -> BoltReadReply? {
            packets.append(request)
            switch request {
            case .pairing: return .pairing(.keyboard, productID: identity)
            case .name: return .name("Logi POP Keys", truncated: false)
            case .ping: return pingResponds ? .pong("2.0") : nil
            case .feature(_, let index, let function, _, let parameters, let length):
                var payload: [UInt8]
                switch (index, function) {
                case (0, 0): payload = [1, 0, 1]
                case (1, 0): payload = [UInt8(features.count - 1)]
                case (1, 1):
                    if parameters[0] == timeoutIndex { return nil }
                    let id = features[Int(parameters[0])]
                    payload = [UInt8(id >> 8), UInt8(id & 255), 0, 1]
                case (2, 0): payload = [2]
                case (2, 1): payload = parameters[0] == 0
                    ? [0, 66, 79, 84, 3, 1, 0, 32] : [2, 5, 0, 0, 0, 0, 0, 0]
                case (3, 1): payload = [0, 4, 0, 0]
                case (4, 0): payload = [1, 0]
                case (5, 0): payload = [1]
                case (5, 1): payload = [0, 0xe2, 0, 0xdd, 0x10, 0, 1, 1, 0]
                case (5, 2): payload = [0, badMappingEcho ? 0xe3 : 0xe2, 0, 0, 0, 0]
                default: throw ScreenError.message("Unexpected getter")
                }
                XCTAssertEqual(payload.count, length)
                return .feature(payload)
            }
        }
    }

    func testReadsOnlyAdvertisedGettersAndPreservesObservedValues() throws {
        let fixture = Fixture()
        let result = try POPKeyboardProbe(expected: expected, request: fixture.request).read(hostName: "fixture", platform: .linux)
        XCTAssertTrue(result.featureInventoryComplete)
        XCTAssertEqual(result.firmware[0].prefix, "BOT")
        XCTAssertEqual(result.firmware[0].version, "03.01")
        XCTAssertEqual(result.firmware[0].build, 32)
        XCTAssertEqual(result.firmware[1].version, "5")
        XCTAssertNil(result.battery?.percentage, "A discrete battery level must not be displayed as zero percent")
        XCTAssertEqual(result.battery?.level, .good)
        XCTAssertEqual(result.fnMode?.inverted, true)
        XCTAssertEqual(result.controls[0].currentControlID, 0xe2, "Mapped CID zero means the control maps to itself")
        XCTAssertEqual(result.controls[0].defaultTaskName, "Emoji panel")
        XCTAssertTrue(result.controlInventoryComplete)
        XCTAssertTrue(result.errors.isEmpty)
        for packet in fixture.packets {
            if case .feature(_, let index, let function, _, _, _) = packet {
                XCTAssertLessThanOrEqual(function, 2)
                if function == 2 { XCTAssertEqual(index, 5, "Only the documented mapping getter uses function 2") }
            }
        }
    }

    func testFreshIdentityMismatchStopsBeforeFeatureDiscovery() throws {
        let fixture = Fixture()
        fixture.identity = "B366"
        XCTAssertThrowsError(try POPKeyboardProbe(expected: expected, request: fixture.request).read(hostName: "fixture", platform: .macos))
        XCTAssertEqual(fixture.packets.count, 1)
        let sleeping = PairedUSBPeripheral(slot: 1, name: "Logi POP Keys", kind: .keyboard,
            wirelessProductID: "B365", radio: .notResponding, protocolVersion: nil, error: nil)
        let awakened = Fixture()
        XCTAssertEqual(try POPKeyboardProbe(expected: sleeping, request: awakened.request)
            .read(hostName: "fixture", platform: .macos).name, "Logi POP Keys")
        let nowSleeping = Fixture()
        nowSleeping.pingResponds = false
        XCTAssertThrowsError(try POPKeyboardProbe(expected: expected, request: nowSleeping.request)
            .read(hostName: "fixture", platform: .macos))
        XCTAssertEqual(nowSleeping.packets.count, 3, "No feature query may follow a missing fresh ping")
    }

    func testTimeoutStopsIndexedEnumerationAndReturnsExplicitPartialResult() throws {
        let fixture = Fixture()
        fixture.timeoutIndex = 1
        let result = try POPKeyboardProbe(expected: expected, request: fixture.request).read(hostName: "fixture", platform: .macos)
        XCTAssertFalse(result.featureInventoryComplete)
        XCTAssertEqual(result.features.map(\.id), [0])
        XCTAssertEqual(fixture.packets.count, 7)
        XCTAssertTrue(result.firmware.isEmpty)
        XCTAssertNil(result.battery)
        XCTAssertFalse(result.errors.isEmpty)
    }

    func testMappingEchoMismatchRetainsControlButDoesNotInventCurrentMapping() throws {
        let fixture = Fixture()
        fixture.badMappingEcho = true
        let result = try POPKeyboardProbe(expected: expected, request: fixture.request).read(hostName: "fixture", platform: .macos)
        XCTAssertEqual(result.controls.first?.controlID, 0xe2)
        XCTAssertNil(result.controls.first?.currentControlID)
        XCTAssertFalse(result.controlInventoryComplete)
        XCTAssertTrue(result.errors.contains { $0.contains("echo") })
    }

    func testFeatureDecoderDropsUnitIDsAndRejectsWrongReplyHeader() throws {
        let request = BoltReadRequest.feature(slot: 1, index: 2, function: 0, softwareID: 4, parameters: [], responseLength: 1)
        let report: [UInt8] = [0x11, 1, 2, 4, 2] + Array(repeating: 0xab, count: 15)
        XCTAssertEqual(try BoltPeripheralProtocol.decode(report, for: request), .feature([2]))
        var unrelated = report
        unrelated[3] = 5
        XCTAssertNil(try BoltPeripheralProtocol.decode(unrelated, for: request))
        unrelated = report
        unrelated[1] = 2
        XCTAssertNil(try BoltPeripheralProtocol.decode(unrelated, for: request))
        let error: [UInt8] = [0x10, 1, 0xff, 2, 4, 9, 0]
        XCTAssertEqual(try BoltPeripheralProtocol.decode(error, for: request), .featureError(9))
    }

    func testRemoteDetailsMustBelongToExpectedKeyboardAndAdvertisedFeatures() throws {
        let fixture = Fixture()
        let result = try POPKeyboardProbe(expected: expected, request: fixture.request).read(hostName: "fixture", platform: .linux)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        XCTAssertEqual(try POPKeyboardDetails.decodeRemote(data, expected: expected).name, "Logi POP Keys")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["wirelessProductID"] = "B366"
        XCTAssertThrowsError(try POPKeyboardDetails.decodeRemote(JSONSerialization.data(withJSONObject: object), expected: expected))
        object["wirelessProductID"] = "B365"
        object["features"] = []
        XCTAssertThrowsError(try POPKeyboardDetails.decodeRemote(JSONSerialization.data(withJSONObject: object), expected: expected))
    }
}
