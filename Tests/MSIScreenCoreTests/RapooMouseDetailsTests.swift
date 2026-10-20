import Foundation
import XCTest
@testable import MSIScreenCore

final class RapooMouseDetailsTests: XCTestCase {
    private let dongle: [UInt8] = [1, 1, 3, 6, 0] + Array(repeating: 0, count: 27)
    private let mouse: [UInt8] = [1, 41, 0, 0, 1] + Array(repeating: 0, count: 27)
    private let battery: [UInt8] = [1, 1, 84] + Array(repeating: 0, count: 29)
    // Live overlapping 16-byte windows at 0x61c and 0x620. Only the first
    // four bytes in each window belong to the requested key.
    private let key7: [UInt8] = [1, 0, 0, 0] + [
        7, 0, 8, 0, 7, 0, 8, 0, 255, 255, 255, 255, 255, 255, 255, 255
    ] + Array(repeating: 0, count: 12)
    private let key8: [UInt8] = [1, 0, 0, 0] + [
        7, 0, 8, 0, 255, 255, 255, 255, 255, 255, 255, 255, 10, 0, 0, 0
    ] + Array(repeating: 0, count: 12)

    private var dpiReply: [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        result[0] = 1
        // 800, 1600, 3200, 6400 DPI, followed by three unused zero slots.
        for (index, raw) in [16, 32, 64, 128].enumerated() { result[4 + 2 * index] = UInt8(raw) }
        result[18] = 3
        result[20] = 1
        return result
    }
    private var buttonReply: [UInt8] { [1, 0, 0, 0, 8, 0, 3, 0] + Array(repeating: 0, count: 24) }

    func testLiveSideWheelRecordsDecodeHorizontalWithNativeOppositeSigns() throws {
        XCTAssertEqual(RapooGetter.sideWheelKey7.packet, [0xba, 0xf7, 0xf6, 16, 0x1c, 6, 0, 0])
        XCTAssertEqual(RapooGetter.sideWheelKey8.packet, [0xba, 0xf7, 0xf6, 16, 0x20, 6, 0, 0])
        XCTAssertEqual(try RapooDetailProtocol.decode(key7, for: .sideWheelKey7),
            .wheelMapping(RapooWheelMapping(keyID: 7, direction: "horizontalNegative",
                function: "horizontalScroll", rawRecordHex: "07000800", logicalType: 7)))
        XCTAssertEqual(try RapooDetailProtocol.decode(key8, for: .sideWheelKey8),
            .wheelMapping(RapooWheelMapping(keyID: 8, direction: "horizontalPositive",
                function: "horizontalScroll", rawRecordHex: "07000800", logicalType: 7)))
    }

    func testWheelDecoderPreservesUnknownAndDistinguishesDisabledFromHorizontal() throws {
        func decode(_ record: [UInt8]) throws -> RapooWheelMapping {
            let reply = [UInt8(1), 0, 0, 0] + record + Array(repeating: UInt8(0), count: 24)
            guard case .wheelMapping(let mapping) = try RapooDetailProtocol.decode(reply, for: .sideWheelKey7) else {
                throw ScreenError.message("Expected wheel mapping")
            }
            return mapping
        }
        let unknown = try decode([7, 0, 8, 9])
        XCTAssertEqual(unknown.function, "unknown")
        XCTAssertEqual(unknown.rawRecordHex, "07000809")
        XCTAssertNil(unknown.logicalType)
        XCTAssertNil(unknown.direction)
        let opaque = try decode([7, 1, 8, 0])
        XCTAssertEqual(opaque.function, "unknown")
        XCTAssertEqual(opaque.logicalType, 53)
        XCTAssertNil(opaque.direction)
        XCTAssertEqual(try decode([7, 0, 0, 0]).function, "disabled")
        XCTAssertEqual(try decode([12, 0, 2, 0]).direction, "horizontalPositive")
        XCTAssertEqual(try decode([255, 255, 255, 255]).direction, "horizontalPositive")
    }

    func testWheelGetterRequiresFullRequestedPayloadAndSuccessStatus() {
        XCTAssertThrowsError(try RapooDetailProtocol.decode(Array(key7.prefix(19)), for: .sideWheelKey7))
        var timeout = key7
        timeout[0] = 2
        XCTAssertThrowsError(try RapooDetailProtocol.decode(timeout, for: .sideWheelKey7))
        XCTAssertThrowsError(try RapooDetailProtocol.decode(key7 + [0], for: .sideWheelKey7))
    }

    func testMappingFailureKeepsPriorDetailsAndNeverResendsOrReadsFollowingKey() throws {
        var requests: [RapooGetter] = []
        let result = try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {}) { getter in
            requests.append(getter)
            switch getter {
            case .dongleFirmware: return dongle
            case .mouseFirmware: return mouse
            case .battery: return battery
            case .sideWheelKey7: return Array(key7.prefix(19))
            case .sideWheelKey8: return key8
            case .dpi: return dpiReply
            case .topButtonKey4: return buttonReply
            }
        }
        XCTAssertEqual(requests, [.dongleFirmware, .mouseFirmware, .battery, .sideWheelKey7])
        XCTAssertEqual(result.mouseFirmware, "V1.0.0.41")
        XCTAssertEqual(result.batteryPercent, 84)
        XCTAssertTrue(result.sideWheelMappings.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCompleteDetailsIncludeBothMappingsInReadOrder() throws {
        var requests: [RapooGetter] = []
        let result = try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {}) { getter in
            requests.append(getter)
            switch getter {
            case .dongleFirmware: return dongle
            case .mouseFirmware: return mouse
            case .battery: return battery
            case .sideWheelKey7: return key7
            case .sideWheelKey8: return key8
            case .dpi: return dpiReply
            case .topButtonKey4: return buttonReply
            }
        }
        XCTAssertEqual(requests, [.dongleFirmware, .mouseFirmware, .battery, .sideWheelKey7, .sideWheelKey8, .dpi, .topButtonKey4])
        XCTAssertEqual(result.sideWheelMappings.map(\.keyID), [7, 8])
        XCTAssertEqual(result.dpi?.currentDPI, 1600)
        XCTAssertEqual(result.topButtonMapping?.function, "dpiCycle")
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidatedNativeGetterFramesAndFirmwareByteOrder() throws {
        XCTAssertEqual(RapooGetter.dongleFirmware.packet, [0xba, 0xe2, 0xf1])
        XCTAssertEqual(RapooGetter.mouseFirmware.packet, [0xba, 0xf7, 0xf1])
        XCTAssertEqual(RapooGetter.battery.packet, [0xba, 0xf7, 0xf8])
        XCTAssertEqual(try RapooDetailProtocol.decode(dongle, for: .dongleFirmware), .firmware("V1.3.6.0"))
        XCTAssertEqual(try RapooDetailProtocol.decode(mouse, for: .mouseFirmware), .firmware("V1.0.0.41"))
        XCTAssertEqual(try RapooDetailProtocol.decode(battery, for: .battery), .battery(percent: 84, status: 1))
    }

    func testRejectsInvalidStatusLengthsAndBatteryWithoutShiftingReportID() {
        for reply in [[], [1, 1, 3, 6], Array(repeating: UInt8(1), count: 33), [0xba, 1, 1, 3, 6, 0]] {
            XCTAssertThrowsError(try RapooDetailProtocol.decode(reply, for: .dongleFirmware))
        }
        XCTAssertThrowsError(try RapooDetailProtocol.decode([1, 1, 101], for: .battery))
        XCTAssertThrowsError(try RapooDetailProtocol.decode([1, 1], for: .battery))
    }

    func testReadsEachGetterOnceAndStopsAfterFailureKeepingOnlyPriorValues() throws {
        var requests: [RapooGetter] = []
        let result = try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {}) { getter in
            requests.append(getter)
            if getter == .dongleFirmware { return dongle }
            throw ScreenError.message("Fixture USB disconnect")
        }
        XCTAssertEqual(requests, [.dongleFirmware, .mouseFirmware])
        XCTAssertEqual(result.dongleFirmware, "V1.3.6.0")
        XCTAssertNil(result.mouseFirmware)
        XCTAssertNil(result.batteryPercent)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCancelledOrExpiredReadNeverStartsTheNextGetter() throws {
        var readinessChecks = 0
        var queries = 0
        XCTAssertThrowsError(try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {
            readinessChecks += 1
            if readinessChecks == 2 { throw CancellationError() }
        }, exchange: { _ in queries += 1; return dongle })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(queries, 1)
        let blocked = try RapooDetailProtocol.read(hostName: "fixture", beforeGetter: {
            throw ScreenError.message("Read window ended")
        }, exchange: { _ in queries += 1; return dongle })
        XCTAssertEqual(queries, 1)
        XCTAssertNil(blocked.dongleFirmware)
        XCTAssertEqual(blocked.errors.count, 1)
    }

    func testRapooLockExcludesOtherReadersAndReleasesWithoutMonitorLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try RapooQueryLock(directory: directory)
        XCTAssertThrowsError(try RapooQueryLock(directory: directory))
        first.release()
        let next = try RapooQueryLock(directory: directory)
        next.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rapoo.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("controller.lock").path))
    }

    private final class WheelFixture {
        var records: [[UInt8]] = [[7, 0, 8, 0], [7, 0, 8, 0]]
        var packets: [[UInt8]] = []
        var writes: [[UInt8]] { packets.filter { $0.count > 2 && $0[2] == 0xf7 } }
        var rejectSecondWrite = false
        var ignoreFirstWrite = false
        var changeOtherKeyAfterWrite = false
        var invalidSetterReply = false
        var mouseVersion: UInt8 = 41
        var mappings: [RapooWheelMapping] {
            records.enumerated().map { RapooDetailProtocol.decodeWheelRecord($0.element, keyID: $0.offset + 7) }
        }

        func exchange(_ packet: [UInt8]) throws -> [UInt8] {
            packets.append(packet)
            if packet == RapooGetter.dongleFirmware.packet { return [1, 1, 3, 6, 0] + Array(repeating: 0, count: 27) }
            if packet == RapooGetter.mouseFirmware.packet { return [1, mouseVersion, 0, 0, 1] + Array(repeating: 0, count: 27) }
            if packet == RapooGetter.sideWheelKey7.packet || packet == RapooGetter.sideWheelKey8.packet {
                let index = packet[4] == 0x1c ? 0 : 1
                return [1, 0, 0, 0] + records[index] + Array(repeating: 0, count: 24)
            }
            guard packet.count == 12, Array(packet.prefix(4)) == [0xba, 0xf7, 0xf7, 4],
                  Array(packet[5..<8]) == [6, 0, 0], [0x1c, 0x20].contains(packet[4]) else {
                throw ScreenError.message("Unexpected fixture packet")
            }
            if rejectSecondWrite && writes.count == 2 { throw ScreenError.message("Fixture disconnect after dispatch") }
            if !(ignoreFirstWrite && writes.count == 1) {
                records[packet[4] == 0x1c ? 0 : 1] = Array(packet.suffix(4))
            }
            if changeOtherKeyAfterWrite { records[1] = [7, 0, 0, 0] }
            return invalidSetterReply ? [2] : [1] + Array(repeating: 0, count: 31)
        }
    }

    func testAppSwitchWritesOnlyTwoExactNativeSimpleKeyRecordsAndVerifiesBoth() throws {
        let fixture = WheelFixture()
        let result = try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertEqual(fixture.writes, [
            [0xba, 0xf7, 0xf7, 4, 0x1c, 6, 0, 0, 1, 0, 0x6d, 0],
            [0xba, 0xf7, 0xf7, 4, 0x20, 6, 0, 0, 1, 0, 0x6e, 0]
        ])
        XCTAssertEqual(result.writeAttemptedKeys, [7, 8])
        XCTAssertEqual(result.verifiedWriteKeys, [7, 8])
        XCTAssertEqual(result.after?.map(\.function), ["appSwitchPrevious", "appSwitchNext"])
        XCTAssertEqual(result.after?.map(\.direction), ["horizontalNegative", "horizontalPositive"])
        XCTAssertEqual(result.after?.map(\.logicalType), [1, 1])
        XCTAssertEqual(result.after, result.target)
        XCTAssertTrue(result.verified)
        XCTAssertNil(result.error)
        XCTAssertEqual(fixture.packets.suffix(2), [RapooGetter.sideWheelKey7.packet, RapooGetter.sideWheelKey8.packet])
    }

    func testHorizontalRestorePreservesExactValidatedRecordAndSkipsAlreadyMatchingKey() throws {
        let fixture = WheelFixture()
        fixture.records[0] = [1, 0, 0x6d, 0]
        let result = try RapooWheelMutation.apply(.horizontal, expected: fixture.mappings,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertEqual(fixture.writes, [[0xba, 0xf7, 0xf7, 4, 0x1c, 6, 0, 0, 7, 0, 8, 0]])
        XCTAssertEqual(result.writeAttemptedKeys, [7])
        XCTAssertEqual(result.after?.map(\.rawRecordHex), ["07000800", "07000800"])
        XCTAssertTrue(result.verified)
    }

    func testDryRunAndMatchingPresetNeverWrite() throws {
        let fixture = WheelFixture()
        let dry = try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: true, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertFalse(dry.verified)
        XCTAssertTrue(dry.writeAttemptedKeys.isEmpty)
        XCTAssertEqual(dry.after, dry.before)
        XCTAssertEqual(dry.target.map(\.rawRecordHex), ["01006d00", "01006e00"])
        let noop = try RapooWheelMutation.apply(.horizontal, expected: fixture.mappings,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertTrue(noop.verified)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testStaleOrIncompleteExpectedRecordsAndChangedFirmwarePreventWrites() {
        let fixture = WheelFixture()
        let expected = fixture.mappings
        fixture.records[1] = [7, 0, 0, 0]
        XCTAssertThrowsError(try RapooWheelMutation.apply(.appSwitch, expected: expected,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange))
        XCTAssertTrue(fixture.writes.isEmpty)
        let count = fixture.packets.count
        XCTAssertThrowsError(try RapooWheelMutation.apply(.appSwitch, expected: [expected[0]],
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange))
        XCTAssertEqual(fixture.packets.count, count)
        fixture.mouseVersion = 40
        XCTAssertThrowsError(try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange))
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testIgnoredWriteOrOtherKeyChangeStopsBeforeSecondSetter() throws {
        for otherChanged in [false, true] {
            let fixture = WheelFixture()
            fixture.ignoreFirstWrite = !otherChanged
            fixture.changeOtherKeyAfterWrite = otherChanged
            let result = try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
                dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
            XCTAssertEqual(result.writeAttemptedKeys, [7])
            XCTAssertEqual(fixture.writes.count, 1)
            XCTAssertFalse(result.verified)
            XCTAssertNotNil(result.after)
            XCTAssertNotNil(result.error)
        }
    }

    func testSecondSetterFailurePreservesBeforeTargetAndAttemptedKeysWithoutInventingAfter() throws {
        let fixture = WheelFixture()
        fixture.rejectSecondWrite = true
        let result = try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertEqual(result.writeAttemptedKeys, [7, 8])
        XCTAssertEqual(result.verifiedWriteKeys, [7])
        XCTAssertEqual(result.before.map(\.rawRecordHex), ["07000800", "07000800"])
        XCTAssertEqual(fixture.records[0], [1, 0, 0x6d, 0])
        XCTAssertNil(result.after)
        XCTAssertFalse(result.verified)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertEqual(fixture.packets.last, fixture.writes.last)
    }

    func testInvalidAcknowledgmentStopsWithoutReadingAnAmbiguousReply() throws {
        let fixture = WheelFixture()
        fixture.invalidSetterReply = true
        let result = try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertEqual(result.writeAttemptedKeys, [7])
        XCTAssertNil(result.after)
        XCTAssertFalse(result.verified)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(fixture.packets.last, fixture.writes.last)
    }

    func testCancellationBeforeMutationThrowsButAfterDispatchRetainsPartialResult() throws {
        let fixture = WheelFixture()
        XCTAssertThrowsError(try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: false, beforeRequest: { throw CancellationError() }, exchange: fixture.exchange))
        XCTAssertTrue(fixture.packets.isEmpty)
        let result = try RapooWheelMutation.apply(.appSwitch, expected: fixture.mappings,
            dryRun: false, beforeRequest: {
                if !fixture.writes.isEmpty { throw CancellationError() }
            }, exchange: fixture.exchange)
        XCTAssertEqual(result.writeAttemptedKeys, [7])
        XCTAssertNil(result.after)
        XCTAssertFalse(result.verified)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(fixture.writes.count, 1)
    }
    func testDPISlotsUseCorrectCountAndCurrentOffsetsAndPreserveRawPayload() throws {
        XCTAssertEqual(RapooGetter.dpi.packet, [0xba, 0xf7, 0xf6, 24, 0x38, 6, 0, 0])
        var response = dpiReply
        response[4] = 0x20; response[5] = 1 // LE16 288 * 50 = 14400
        response[19] = 255 // Not the current-slot field.
        guard case .dpi(let details) = try RapooDetailProtocol.decode(response, for: .dpi) else {
            return XCTFail("Expected DPI details")
        }
        XCTAssertEqual(details.slots, [14400, 1600, 3200, 6400])
        XCTAssertEqual(details.activeSlot, 2)
        XCTAssertEqual(details.currentDPI, 1600)
        XCTAssertEqual(details.rawPayloadHex, response[4..<28].map { String(format: "%02x", $0) }.joined())
        for offset in [18, 20] {
            var invalid = dpiReply; invalid[offset] = 7
            XCTAssertThrowsError(try RapooDetailProtocol.decode(invalid, for: .dpi))
        }
        var empty = dpiReply; empty[4] = 0
        XCTAssertThrowsError(try RapooDetailProtocol.decode(empty, for: .dpi))
        XCTAssertThrowsError(try RapooDetailProtocol.decode(Array(response.prefix(27)), for: .dpi))
    }

    private final class ButtonFixture {
        var record: [UInt8] = [8, 0, 3, 0]
        var adjacent: [UInt8] = [255, 255, 255, 255, 255, 255, 255, 255, 1, 0, 0x6d, 0]
        var packets: [[UInt8]] = []
        var writes: [[UInt8]] { packets.filter { $0.count > 2 && $0[2] == 0xf7 } }
        var ignoreWrite = false
        var changeAdjacent = false
        var failReadback = false
        var invalidAck = false
        var mouseVersion: UInt8 = 41
        func exchange(_ packet: [UInt8]) throws -> [UInt8] {
            packets.append(packet)
            if packet == RapooGetter.dongleFirmware.packet { return [1, 1, 3, 6, 0] }
            if packet == RapooGetter.mouseFirmware.packet { return [1, mouseVersion, 0, 0, 1] }
            if packet == RapooGetter.topButtonKey4.packet {
                if failReadback && !writes.isEmpty { throw ScreenError.message("Disconnected before readback") }
                return [1, 0, 0, 0] + record + adjacent + Array(repeating: 0, count: 12)
            }
            guard packet.count == 12, Array(packet.prefix(8)) == [0xba, 0xf7, 0xf7, 4, 0x10, 6, 0, 0] else {
                throw ScreenError.message("Unexpected top-button fixture packet")
            }
            if !ignoreWrite { record = Array(packet.suffix(4)) }
            if changeAdjacent { adjacent[0] = 9 }
            return [invalidAck ? 2 : 1]
        }
    }

    func testTopButtonF20AndDPIRestoreWriteOnlyExactKey4Records() throws {
        let fixture = ButtonFixture()
        let bound = try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertEqual(fixture.writes, [[0xba, 0xf7, 0xf7, 4, 0x10, 6, 0, 0, 1, 0, 0x6f, 0]])
        XCTAssertTrue(bound.verified)
        XCTAssertTrue(bound.writeAttempted)
        XCTAssertEqual(bound.before.function, "dpiCycle")
        XCTAssertEqual(bound.after?.function, "pinnedApp")
        XCTAssertEqual(bound.after?.keyID, 4)
        let restored = try RapooTopButtonMutation.apply(.dpiCycle, expectedRecordHex: "01006f00",
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertEqual(fixture.writes.last, [0xba, 0xf7, 0xf7, 4, 0x10, 6, 0, 0, 8, 0, 3, 0])
        XCTAssertEqual(restored.after?.rawRecordHex, "08000300")
        XCTAssertTrue(restored.verified)
    }

    func testTopButtonDryRunNoopStaleAndFirmwareGuardsNeverWrite() throws {
        let fixture = ButtonFixture()
        let dry = try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
            dryRun: true, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertFalse(dry.verified)
        XCTAssertFalse(dry.writeAttempted)
        let noop = try RapooTopButtonMutation.apply(.dpiCycle, expectedRecordHex: "08000300",
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
        XCTAssertTrue(noop.verified)
        XCTAssertFalse(noop.writeAttempted)
        for expected in ["01006f00", "080003", "0800030G"] {
            XCTAssertThrowsError(try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: expected,
                dryRun: false, beforeRequest: {}, exchange: fixture.exchange))
        }
        fixture.mouseVersion = 40
        XCTAssertThrowsError(try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
            dryRun: false, beforeRequest: {}, exchange: fixture.exchange))
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testTopButtonIgnoredWriteAdjacentChangeAndMissingReadbackRemainUnverified() throws {
        for failure in 0..<3 {
            let fixture = ButtonFixture()
            fixture.ignoreWrite = failure == 0
            fixture.changeAdjacent = failure == 1
            fixture.failReadback = failure == 2
            let result = try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
                dryRun: false, beforeRequest: {}, exchange: fixture.exchange)
            XCTAssertEqual(fixture.writes.count, 1)
            XCTAssertTrue(result.writeAttempted)
            XCTAssertFalse(result.verified)
            XCTAssertNotNil(result.error)
            if failure == 2 { XCTAssertNil(result.after) }
            else { XCTAssertNotNil(result.after) }
        }
    }

    func testTopButtonInvalidAckAndCancellationNeverReplayAnAttempt() throws {
        let badAck = ButtonFixture(); badAck.invalidAck = true
        let result = try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
            dryRun: false, beforeRequest: {}, exchange: badAck.exchange)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.after)
        XCTAssertEqual(badAck.packets.count, 4)
        let fixture = ButtonFixture()
        XCTAssertThrowsError(try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
            dryRun: false, beforeRequest: { throw CancellationError() }, exchange: fixture.exchange))
        let cancelled = try RapooTopButtonMutation.apply(.pinnedApp, expectedRecordHex: "08000300",
            dryRun: false, beforeRequest: { if !fixture.writes.isEmpty { throw CancellationError() } },
            exchange: fixture.exchange)
        XCTAssertTrue(cancelled.writeAttempted)
        XCTAssertFalse(cancelled.verified)
        XCTAssertNil(cancelled.after)
        XCTAssertEqual(fixture.writes.count, 1)
    }

}
