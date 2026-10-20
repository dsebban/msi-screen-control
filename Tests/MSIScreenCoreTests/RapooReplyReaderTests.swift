import XCTest
@testable import MSIScreenCore

final class RapooReplyReaderTests: XCTestCase {
    func testPendingReceivesFinishWithoutAnotherGetterAndResetBuffer() throws {
        var packets: [[UInt8]] = []
        var receives = 0
        var clock: TimeInterval = 0
        let details = try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {}) { getter in
            packets.append(getter.packet)
            if getter != .dongleFirmware { throw ScreenError.message("Stop after first getter") }
            return try RapooReplyReader.read(deadline: 1, checkCancellation: {}, receive: { buffer, count in
                receives += 1
                XCTAssertEqual(count, 32)
                XCTAssertEqual(buffer, [0xba] + Array(repeating: 0, count: 31))
                if receives < 3 {
                    buffer[0] = 2
                    count = 1
                } else {
                    buffer = [1, 1, 3, 6, 0] + Array(repeating: 0, count: 27)
                    count = 32
                }
            }, now: { clock }, sleep: { clock += $0 })
        }
        XCTAssertEqual(details.dongleFirmware, "V1.3.6.0")
        XCTAssertEqual(receives, 3)
        XCTAssertEqual(packets, [RapooGetter.dongleFirmware.packet, RapooGetter.mouseFirmware.packet])
        XCTAssertEqual(clock, 0.004, accuracy: 0.000001)
    }

    func testPendingReplyExhaustsNativeCountWithoutResending() throws {
        var packets: [[UInt8]] = []
        var receives = 0
        let details = try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {}) { getter in
            packets.append(getter.packet)
            return try RapooReplyReader.read(deadline: 1, checkCancellation: {}, receive: { buffer, count in
                receives += 1
                buffer[0] = 2
                count = 32
            }, now: { 0 }, sleep: { _ in })
        }
        XCTAssertEqual(receives, 250)
        XCTAssertEqual(packets, [RapooGetter.dongleFirmware.packet])
        XCTAssertNil(details.dongleFirmware)
        XCTAssertTrue(details.errors.first?.contains("timed out") == true)
    }

    func testElapsedGetReportTimeStopsPendingAndRejectsLateSuccess() {
        for status: UInt8 in [1, 2] {
            var clock: TimeInterval = 0
            var receives = 0
            XCTAssertThrowsError(try RapooReplyReader.read(deadline: 1, checkCancellation: {}, receive: { buffer, count in
                receives += 1
                buffer[0] = status
                count = 32
                clock = 1.1
            }, now: { clock }, sleep: { clock += $0 }))
            XCTAssertEqual(receives, 1)
        }
    }

    func testCancellationAfterPendingReplyStopsBeforeNextReceive() {
        var cancelled = false
        var receives = 0
        XCTAssertThrowsError(try RapooReplyReader.read(deadline: 1, checkCancellation: {
            if cancelled { throw CancellationError() }
        }, receive: { buffer, count in
            receives += 1
            buffer[0] = 2
            count = 32
            cancelled = true
        }, now: { 0 }, sleep: { _ in })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(receives, 1)
    }
}
