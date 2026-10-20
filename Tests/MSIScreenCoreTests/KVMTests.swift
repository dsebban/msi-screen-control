import XCTest
@testable import MSIScreenCore

final class KVMTests: XCTestCase {
    final class Transport: ScreenTransport {
        var values: [String: [UInt8]] = [
            "00140": [48, 48, 160], "00150": Array("V20".utf8),
            "00600": Array("002".utf8), "00500": Array("000".utf8),
            "00610": Array("003".utf8), "00620": Array("003".utf8),
            "00630": Array("001".utf8), "00640": Array("000".utf8),
            "008>0": Array("002".utf8)
        ]
        var queried: [String] = []
        var onlineVideoCount: Int? { nil }
        func query(_ code: String) throws -> [UInt8] {
            queried.append(code)
            return values[code]!
        }
        func writeLayout(_ state: ScreenState, primaryChanged: Bool) throws {
            XCTFail("Reading the USB route must not change the layout")
        }
        func writeSetting(_ setting: MonitorSetting, value: Int) throws {
            XCTFail("Reading the USB route must not change monitor settings")
        }
    }

    func testKVMStatusDecodesObservedUSBCReply() throws {
        let transport = Transport()
        let snapshot = try ScreenController(transport: transport).kvmStatus()
        XCTAssertEqual(snapshot.model, "MD342CQP")
        XCTAssertEqual(snapshot.protocolVersion, "V20")
        XCTAssertEqual(snapshot.route, .usbc)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(json["route"] as? String, "usbc")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
    }

    func testKVMStatusRejectsMalformedAndUnknownReplies() {
        for reply in [[], [50], Array("02".utf8), Array("003".utf8), Array("00x".utf8), Array("0020".utf8)] {
            let transport = Transport()
            transport.values["008>0"] = reply
            XCTAssertThrowsError(try ScreenController(transport: transport).kvmStatus())
        }
    }

    func testKVMStatusValidatesModelBeforeReadingModelSpecificRegister() {
        let transport = Transport()
        transport.values["00140"] = [48, 48, 161]
        XCTAssertThrowsError(try ScreenController(transport: transport).kvmStatus())
        XCTAssertFalse(transport.queried.contains("008>0"))
    }
}
