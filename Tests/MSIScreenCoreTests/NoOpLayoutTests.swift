import XCTest
@testable import MSIScreenCore

final class NoOpLayoutTests: XCTestCase {
    final class Transport: ScreenTransport {
        var queryCount = 0
        var videoEnumerationCount = 0
        var writeCount = 0
        var source: Input = .hdmi1
        var onlineVideoCount: Int? {
            videoEnumerationCount += 1
            return 1
        }
        func query(_ code: String) throws -> [UInt8] {
            queryCount += 1
            switch code {
            case "00140": return [48,48,160]
            case "00150": return Array("V20".utf8)
            case "00500": return Array(String(format: "%03d", source.value).utf8)
            case "00600", "00630", "00640": return Array("000".utf8)
            case "00610", "00620": return Array("003".utf8)
            default: throw ScreenError.message("Unexpected register")
            }
        }
        func writeLayout(_ state: ScreenState, primaryChanged: Bool) throws { writeCount += 1 }
        func writeSetting(_ setting: MonitorSetting, value: Int) throws {
            XCTFail("No-op layout must not write settings")
        }
    }

    private let baseline = ScreenState(model: "MD342CQP", protocolVersion: "V20",
                                       mode: .off, source1: .hdmi1, source2: .usbc,
                                       pipInput: .usbc, pipSize: 0, pipPosition: 0)

    func testNoOpValidatesOnceWithoutEnumeratingVideoOrWriting() throws {
        let transport = Transport()
        let after = try ScreenController(transport: transport).apply(baseline, from: baseline)
        XCTAssertEqual(after, baseline)
        // All identity/layout fields must still be validated, but a no-op must
        // not perform the redundant second read or desktop video enumeration.
        XCTAssertEqual(transport.queryCount, 8)
        XCTAssertEqual(transport.videoEnumerationCount, 0)
        XCTAssertEqual(transport.writeCount, 0)
    }

    func testNoOpRejectsStaleSnapshotBeforeReturning() {
        let transport = Transport()
        transport.source = .usbc
        XCTAssertThrowsError(try ScreenController(transport: transport).apply(baseline, from: baseline))
        XCTAssertEqual(transport.videoEnumerationCount, 0)
        XCTAssertEqual(transport.writeCount, 0)
    }
}
