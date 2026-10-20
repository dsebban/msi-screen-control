import XCTest
@testable import MSIScreenCore

final class PointerProbeTests: XCTestCase {
    // Actual mouse-interface descriptor captured from Rapoo 24ae:186a. The
    // installed app had an empty IOHID element list while the CLI returned nine.
    private let rapooMouseDescriptor = Data([
        0x05,0x01,0x09,0x02,0xa1,0x01,0x09,0x01,0xa1,0x00,0x05,0x09,0x15,0x00,0x25,0x01,
        0x19,0x01,0x29,0x05,0x75,0x01,0x95,0x05,0x81,0x02,0x95,0x03,0x81,0x01,0x05,0x01,
        0x16,0x01,0x80,0x26,0xff,0x7f,0x09,0x30,0x09,0x31,0x75,0x10,0x95,0x02,0x81,0x06,
        0x15,0x81,0x25,0x7f,0x09,0x38,0x75,0x08,0x95,0x01,0x81,0x06,0x05,0x0c,0x0a,0x38,
        0x02,0x95,0x01,0x81,0x06,0xc0,0xc0
    ])

    func testRecordedDescriptorProvidesControlsWithoutInputElementAccess() throws {
        let usages = try XCTUnwrap(rapooDeclaredPointerUsages(reportDescriptor: rapooMouseDescriptor))
        XCTAssertEqual(usages.count, 9)
        XCTAssertEqual(usages.filter { $0.kind == .button }.map(\.usage), [1, 2, 3, 4, 5])
        let horizontal = try XCTUnwrap(usages.first { $0.kind == .horizontalWheel })
        XCTAssertEqual(horizontal.usagePage, 12)
        XCTAssertEqual(horizontal.usage, 0x238)
        XCTAssertTrue(horizontal.relative)
        XCTAssertEqual(horizontal.logicalMin, -127)
        XCTAssertEqual(horizontal.logicalMax, 127)
        let x = try XCTUnwrap(usages.first { $0.kind == .x })
        XCTAssertEqual(x.logicalMin, -32767)
        XCTAssertEqual(x.logicalMax, 32767)
    }

    func testMissingOrChangedDescriptorDoesNotInventKnownControls() {
        XCTAssertNil(rapooDeclaredPointerUsages(reportDescriptor: nil))
        XCTAssertNil(rapooDeclaredPointerUsages(reportDescriptor: Data()))
        var changed = rapooMouseDescriptor
        changed[64] = 0x03 // A different consumer usage is not AC Pan.
        XCTAssertNil(rapooDeclaredPointerUsages(reportDescriptor: changed))
        XCTAssertNil(rapooDeclaredPointerUsages(reportDescriptor: rapooMouseDescriptor.dropLast()))
    }

    func testMixedKeyboardAndPointerUsagesNeverCountKeyboardOrMediaKeys() {
        let horizontal = PointerUsageDescriptor(usagePage: 12, usage: 0x238, kind: .horizontalWheel,
            name: "Horizontal", relative: true, logicalMin: -127, logicalMax: 127)
        let vertical = PointerUsageDescriptor(usagePage: 1, usage: 0x38, kind: .verticalWheel,
            name: "Vertical", relative: true, logicalMin: -127, logicalMax: 127)
        var counter = PointerProbeAccumulator([horizontal, vertical])
        for (page, usage, value): (UInt32, UInt32, Int) in [(7, 0x38, 1), (7, 0x238, 1), (12, 0xe9, 1), (0xff00, 0x238, -1), (12, 0x238, -3), (12, 0x238, 2), (1, 0x38, 0), (1, 0x38, 1)] {
            counter.record(page: page, usage: usage, value: value)
        }
        XCTAssertEqual(counter.counts[0].samples, 2)
        XCTAssertEqual(counter.counts[0].nonzeroSamples, 2)
        XCTAssertEqual(counter.counts[0].positiveSamples, 1)
        XCTAssertEqual(counter.counts[0].negativeSamples, 1)
        XCTAssertEqual(counter.counts[1].samples, 2)
        XCTAssertEqual(counter.counts[1].nonzeroSamples, 1)
    }

    func testUnadvertisedAllowedUsageCannotInventInputEvidence() {
        let x = PointerUsageDescriptor(usagePage: 1, usage: 0x30, kind: .x,
            name: "X", relative: true, logicalMin: -32767, logicalMax: 32767)
        var counter = PointerProbeAccumulator([x])
        counter.record(page: 12, usage: 0x238, value: 1)
        XCTAssertEqual(counter.counts[0].samples, 0)
        XCTAssertEqual(counter.counts.count, 1)
    }

    func testProbeDurationRejectsBeforeTouchingHardware() async {
        for seconds in [0, 16, Int.max] {
            do { _ = try await PointerProbeClient().probe(seconds: seconds); XCTFail("Accepted unbounded duration") }
            catch { XCTAssertTrue(error.localizedDescription.contains("1 and 15")) }
        }
    }
}
