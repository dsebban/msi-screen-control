import XCTest
import MSIScreenCore
@testable import MSIScreenMenu

@MainActor
final class DeviceSupportRequestTests: XCTestCase {
    private func store(prepare: @escaping (String) async throws -> PreparedDeviceSupportRequest,
                       clipboard: @escaping (String) -> Bool,
                       skillAction: @escaping () async throws -> AgentSkillInstallAction = { throw AgentSkillInstallError.missingBundle }) throws -> DeviceInventoryStore {
        let endpoint = try DeviceSupportStoreTests.endpoint()
        let record = try DeviceRecord(id: endpoint.id, displayName: "Local only", kind: .pointer, endpoints: [endpoint], relations: [], bindingEligibility: .attachmentOnly, bindingReason: DeviceUnavailable(code: "attachmentOnly"))
        return DeviceInventoryStore(services: .init(snapshot: {
            try DeviceInventorySnapshot(checkedAtMilliseconds: 1, generation: 1, devices: [record], displays: .complete, usb: .complete, hid: .complete)
        }, listing: { throw DeviceContractError.invalid("unused") }, descriptor: { _, _ in throw DeviceContractError.invalid("unused") }, prepare: prepare,
            bind: { _, _, _, _ in }, disable: { _, _ in }, activate: { _, _, _ in }, remove: { _, _, _ in }, skillAction: skillAction), clipboard: clipboard)
    }
    func testFailedSkillOrRequestPreparationNeverChangesClipboard() async throws {
        for failure in [AgentSkillInstallError.conflict, .missingBundle, .incompatibleContract] {
            var clipboard = "prior clipboard"
            let inventory = try store(prepare: { _ in throw failure }, clipboard: { clipboard = $0; return true })
            await inventory.reload(); inventory.select(try DeviceSupportStoreTests.endpoint().id); inventory.copySupportRequest()
            for _ in 0..<1000 { if !inventory.handoffBusy { break }; try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertEqual(clipboard, "prior clipboard"); XCTAssertNotNil(inventory.error)
        }
    }
    func testCopyFailureRefreshesProspectiveSkillDetailWithoutReselecting() async throws {
        var conflicting = false, copies = 0
        let inventory = try store(prepare: { _ in throw AgentSkillInstallError.conflict }, clipboard: { _ in copies += 1; return true },
            skillAction: { if conflicting { throw AgentSkillInstallError.conflict }; return .upgrade })
        await inventory.reload(); inventory.select(try DeviceSupportStoreTests.endpoint().id)
        XCTAssertEqual(inventory.skillAction, .upgrade)
        let generation = inventory.generation, selected = inventory.selectedID
        conflicting = true; inventory.copySupportRequest()
        await DeviceSupportStoreTests().settle { !inventory.handoffBusy }
        XCTAssertNil(inventory.skillAction); XCTAssertEqual(inventory.skillActionError, "skillConflict")
        XCTAssertEqual(inventory.error, "skillConflict"); XCTAssertEqual(copies, 0)
        XCTAssertEqual(inventory.generation, generation); XCTAssertEqual(inventory.selectedID, selected)
    }

    func testSettingsWriteSupportInstallRefreshesOnlySkillPreviewAndIndependentStatus() async throws {
        var installed = false
        let inventory = try store(prepare: { _ in throw DeviceContractError.invalid("unused") }, clipboard: { _ in XCTFail("No Copy requested"); return false },
            skillAction: { installed ? .unchanged : .install })
        await inventory.reload(); inventory.select(try DeviceSupportStoreTests.endpoint().id)
        let generation = inventory.generation, selected = inventory.selectedID
        let settings = AppSettings(); settings.deviceInventory = inventory
        settings.fixtureSkillInstall = { skill in
            guard skill == .writeSupport else { throw AgentSkillInstallError.conflict }
            installed = true; return .installed
        }
        settings.installAgentSkill(.screenControl); await DeviceSupportStoreTests().settle { !settings.hasActiveOperation }
        let otherError = settings.skillErrors[.screenControl]; XCTAssertNotNil(otherError)
        settings.installAgentSkill(.writeSupport); await DeviceSupportStoreTests().settle { !settings.hasActiveOperation }
        XCTAssertEqual(inventory.skillAction, .unchanged); XCTAssertNil(inventory.skillActionError)
        XCTAssertEqual(settings.skillErrors[.screenControl], otherError); XCTAssertNil(settings.skillErrors[.writeSupport])
        XCTAssertEqual(inventory.generation, generation); XCTAssertEqual(inventory.selectedID, selected)
    }

    func testClipboardFailureHasConcreteSafeCodeAfterPreparation() async throws {
        let endpoint = try DeviceSupportStoreTests.endpoint()
        let bytes = try JSONSerialization.data(withJSONObject: ["schema": 1, "requestID": UUID().uuidString, "expiresAtMilliseconds": 1,
            "deviceID": endpoint.id, "skill": "write-addhoc-support", "skillStatus": "installed", "prompt": "sanitized fixture request"])
        let prepared = try JSONDecoder().decode(PreparedDeviceSupportRequest.self, from: bytes)
        var attempts = 0
        let inventory = try store(prepare: { _ in prepared }, clipboard: { _ in attempts += 1; return false })
        await inventory.reload(); inventory.select(endpoint.id); inventory.copySupportRequest()
        await DeviceSupportStoreTests().settle { !inventory.handoffBusy }
        XCTAssertEqual(attempts, 1); XCTAssertEqual(inventory.error, "clipboardUnavailable")
    }

    func testSelectionChangeDuringPreparePreservesClipboard() async throws {
        var release: CheckedContinuation<PreparedDeviceSupportRequest, Error>?, clipboard = "prior clipboard"
        let inventory = try store(prepare: { _ in try await withCheckedThrowingContinuation { release = $0 } }, clipboard: { clipboard = $0; return true })
        await inventory.reload(); inventory.select(try DeviceSupportStoreTests.endpoint().id); inventory.copySupportRequest()
        for _ in 0..<1000 { if release != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        inventory.select(nil)
        let bytes = try JSONSerialization.data(withJSONObject: ["schema": 1, "requestID": UUID().uuidString, "expiresAtMilliseconds": 1,
            "deviceID": DeviceSupportStoreTests.endpoint().id, "skill": "write-addhoc-support", "skillStatus": "installed", "prompt": "sanitized fixture request"])
        release?.resume(returning: try JSONDecoder().decode(PreparedDeviceSupportRequest.self, from: bytes))
        for _ in 0..<1000 { if !inventory.handoffBusy { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(clipboard, "prior clipboard"); XCTAssertNotNil(inventory.error)
    }
}
