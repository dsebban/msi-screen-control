import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class RapooAppControlTests: XCTestCase {
    private func fixture() throws -> (URL, RapooAppControlServer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rapoo-ipc-test-" + UUID().uuidString)
        return (directory, try RapooAppControlServer(directory: directory))
    }
    private func write(_ request: RapooAppControlRequest, at directory: URL,
                       transform: ([String: Any]) -> [String: Any] = { $0 }) throws -> URL {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(request)) as! [String: Any]
        let url = directory.appendingPathComponent(request.id + ".request")
        try JSONSerialization.data(withJSONObject: transform(object)).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
    func testTargetedRequestConsumedOnceAndPrivateReply() throws {
        let (directory, server) = try fixture()
        let request = RapooAppControlRequest(targetPID: getpid(), action: .status, preset: nil, expected: nil)
        let requestURL = try write(request, at: directory)
        XCTAssertNil(try server.takeRequest(id: request.id, targetPID: getpid() + 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let consumed = try XCTUnwrap(server.takeRequest(id: request.id, targetPID: getpid()))
        XCTAssertNil(try server.takeRequest(id: request.id, targetPID: getpid()))
        try server.respond(to: consumed, status: RapooAppSwitchStatus(enabled: true, hotkeysRegistered: true,
            switchCount: 3, activeHostAction: .applications))
        let replyURL = directory.appendingPathComponent(request.id + ".reply")
        let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: replyURL)) as! [String: Any]
        XCTAssertEqual(reply["id"] as? String, request.id)
        XCTAssertEqual(reply["targetPID"] as? Int32, getpid())
        XCTAssertEqual((reply["status"] as? [String: Any])?["switchCount"] as? Int, 3)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: replyURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testHostActionRequestAndStatusKeepDesktopRequestsSeparateFromApps() throws {
        let (directory, server) = try fixture()
        let request = RapooAppControlRequest(targetPID: getpid(), action: .setHostAction,
            preset: nil, expected: nil, hostAction: .spaces)
        _ = try write(request, at: directory)
        let consumed = try XCTUnwrap(server.takeRequest(id: request.id, targetPID: getpid()))
        XCTAssertEqual(consumed.hostAction, .spaces)
        XCTAssertNil(consumed.preset)
        XCTAssertNil(consumed.expected)
        try server.respond(to: consumed, status: RapooAppSwitchStatus(enabled: true,
            hotkeysRegistered: true, switchCount: 3, lastApplication: "Tern",
            hostAction: .spaces, activeHostAction: .spaces, spaceRequestCount: 2, lastSpaceDirection: "left"))
        let data = try Data(contentsOf: directory.appendingPathComponent(request.id + ".reply"))
        let reply = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let status = try XCTUnwrap(reply["status"] as? [String: Any])
        XCTAssertNil(reply["result"], "A host action must not return a mouse write receipt")
        XCTAssertEqual(status["hostAction"] as? String, "spaces")
        XCTAssertEqual(status["activeHostAction"] as? String, "spaces")
        XCTAssertEqual(status["switchCount"] as? Int, 3)
        XCTAssertEqual(status["spaceRequestCount"] as? Int, 2)
        XCTAssertEqual(status["lastSpaceDirection"] as? String, "left")
    }
    func testHostActionRejectsMissingActionAndMixedHardwarePayload() throws {
        let (directory, server) = try fixture()
        for change in ["missing", "preset", "expected", "status"] {
            let request = RapooAppControlRequest(targetPID: getpid(), action: .setHostAction,
                preset: nil, expected: nil, hostAction: .spaces)
            _ = try write(request, at: directory) { input in
                var object = input
                if change == "missing" { object.removeValue(forKey: "hostAction") }
                if change == "preset" { object["preset"] = "appSwitch" }
                if change == "expected" { object["expected"] = [] }
                if change == "status" { object["action"] = "status" }
                return object
            }
            XCTAssertThrowsError(try server.takeRequest(id: request.id, targetPID: getpid()))
            XCTAssertNil(try server.takeRequest(id: request.id, targetPID: getpid()))
        }
    }
    func testTopButtonReturnsOnlyItsGuardedWriteReceipt() throws {
        let (directory, server) = try fixture()
        let request = RapooAppControlRequest(targetPID: getpid(), action: .setTopButton,
            preset: nil, expected: nil, topButtonPreset: .pinnedApp,
            expectedRecordHex: "08000300", bundleIdentifier: "so.stencil.tern")
        _ = try write(request, at: directory)
        let consumed = try XCTUnwrap(server.takeRequest(id: request.id, targetPID: getpid()))
        XCTAssertEqual(consumed.bundleIdentifier, "so.stencil.tern")
        XCTAssertEqual(consumed.expectedRecordHex, "08000300")
        let status = RapooAppSwitchStatus(enabled: false, hotkeysRegistered: false, switchCount: 0,
            pinnedBundleIdentifier: "so.stencil.tern", pinHotkeyRegistered: true)
        XCTAssertThrowsError(try server.respond(to: consumed, status: status),
                             "Registered hotkeys cannot substitute for a verified mouse-write receipt")
        let before = RapooButtonMapping(keyID: 4, function: "dpiCycle", rawRecordHex: "08000300", logicalType: 50)
        let target = RapooButtonMapping(keyID: 4, function: "pinnedApp", rawRecordHex: "01006f00", logicalType: 1)
        let partial = RapooButtonChangeResult(schemaVersion: 1, checkedAt: Date(), preset: .pinnedApp,
            dryRun: false, before: before, target: target, after: nil,
            writeAttempted: true, verified: false, error: "Readback unavailable")
        XCTAssertThrowsError(try server.respond(to: consumed, status: status, buttonResult: partial))
        try server.respond(to: consumed, buttonResult: partial)
        let data = try Data(contentsOf: directory.appendingPathComponent(request.id + ".reply"))
        let reply = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(reply["status"])
        let result = try XCTUnwrap(reply["buttonResult"] as? [String: Any])
        XCTAssertEqual(result["writeAttempted"] as? Bool, true)
        XCTAssertEqual(result["verified"] as? Bool, false)
        XCTAssertNil(result["after"], "An ambiguous write must not invent a readback")
        XCTAssertEqual(result["error"] as? String, "Readback unavailable")
    }
    func testTopButtonRejectsMissingGuardAndUnrelatedPayloads() throws {
        let (directory, server) = try fixture()
        for change in ["missing record", "malformed record", "missing app", "mixed host", "restore with app"] {
            let request = RapooAppControlRequest(targetPID: getpid(), action: .setTopButton,
                preset: nil, expected: nil, topButtonPreset: .pinnedApp,
                expectedRecordHex: "08000300", bundleIdentifier: "so.stencil.tern")
            _ = try write(request, at: directory) { input in
                var object = input
                if change == "missing record" { object.removeValue(forKey: "expectedRecordHex") }
                if change == "malformed record" { object["expectedRecordHex"] = "080003" }
                if change == "missing app" { object.removeValue(forKey: "bundleIdentifier") }
                if change == "mixed host" { object["hostAction"] = "spaces" }
                if change == "restore with app" { object["topButtonPreset"] = "dpiCycle" }
                return object
            }
            XCTAssertThrowsError(try server.takeRequest(id: request.id, targetPID: getpid()))
            XCTAssertNil(try server.takeRequest(id: request.id, targetPID: getpid()))
        }
    }
    func testRejectsExpiredUnknownAndIncompleteMutation() throws {
        let (directory, server) = try fixture()
        for change in ["expiry", "unknown", "mapping"] {
            let request = RapooAppControlRequest(targetPID: getpid(), action: .status, preset: nil, expected: nil)
            _ = try write(request, at: directory) { input in
                var object = input
                if change == "expiry" { object["expiresAt"] = "2000-01-01T00:00:00Z" }
                if change == "unknown" { object["unexpected"] = true }
                if change == "mapping" { object["action"] = "set-side-wheel"; object["preset"] = "appSwitch" }
                return object
            }
            XCTAssertThrowsError(try server.takeRequest(id: request.id, targetPID: getpid()))
            XCTAssertNil(try server.takeRequest(id: request.id, targetPID: getpid()))
        }
        XCTAssertNil(try server.takeRequest(id: "../../outside", targetPID: getpid()))
    }
    func testRejectsPublicOversizedAndSymlinkPayloads() throws {
        let (directory, server) = try fixture()
        for kind in ["permissions", "size", "symlink"] {
            let request = RapooAppControlRequest(targetPID: getpid(), action: .status, preset: nil, expected: nil)
            let url = try write(request, at: directory)
            if kind == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            if kind == "size" { try Data(repeating: 32, count: 65_537).write(to: url) }
            if kind == "symlink" {
                let target = directory.appendingPathComponent("target")
                try FileManager.default.moveItem(at: url, to: target)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            }
            XCTAssertThrowsError(try server.takeRequest(id: request.id, targetPID: getpid()))
            if kind == "symlink" { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("target").path)) }
        }
    }
}
