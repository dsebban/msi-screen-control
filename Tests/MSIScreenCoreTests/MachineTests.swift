import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

final class MachineTests: XCTestCase {
    private let local = MachineDefinition(id: "local-mac", name: "This Mac", platform: .macos,
                                          input: .usbc, host: nil)
    private let peer = MachineDefinition(id: "peer-mac", name: "Other Mac", platform: .macos,
                                         input: .hdmi1, host: "configured-peer")
    private let linux = MachineDefinition(id: "linux", name: "Linux PC", platform: .linux,
                                          input: .dp, host: "configured-linux")
    private var split: ScreenState {
        ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: .pbp,
                    source1: .usbc, source2: .hdmi1, pipInput: .hdmi1, pipSize: 1, pipPosition: 2)
    }

    func testRegistryPersistsSharedStateAndRejectsStaleEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let baseline = try store.load()
        let first = MachineRegistry(machines: [local, peer])
        try store.save(first, replacing: baseline)
        XCTAssertEqual(try store.load(), first)
        var updated = first
        updated.machines.append(linux)
        try store.save(updated, replacing: first)
        XCTAssertThrowsError(try store.save(first, replacing: baseline))
        XCTAssertEqual(try store.load(), updated)
        try store.save(first, replacing: MachineRegistry(), ifMissing: true)
        XCTAssertEqual(try store.load(), updated, "First-run migration must preserve a concurrently created registry")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidOrMalformedRegistryDoesNotOverwriteExistingConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let saved = MachineRegistry(machines: [local])
        try store.save(saved, replacing: MachineRegistry())
        XCTAssertThrowsError(try store.save(MachineRegistry(machines: [local, local]), replacing: saved))
        var reassignedPeer = peer
        reassignedPeer.input = local.input
        XCTAssertThrowsError(try store.save(MachineRegistry(machines: [local, reassignedPeer]), replacing: saved))
        XCTAssertEqual(try store.load(), saved)
        let malformed = Data(#"{"schemaVersion":1,"machines":"corrupted"}"#.utf8)
        try malformed.write(to: store.url)
        XCTAssertThrowsError(try store.save(saved, replacing: MachineRegistry()))
        XCTAssertEqual(try Data(contentsOf: store.url), malformed)
    }

    func testOversizedEncodedRegistryPreservesReadableSavedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let saved = MachineRegistry(machines: [local])
        try store.save(saved, replacing: MachineRegistry())
        let originalBytes = try Data(contentsOf: store.url)
        var oversized = saved
        // Combining marks keep this name within the character limit while its
        // encoded UTF-8 exceeds the reader's 64 KiB file limit.
        oversized.machines[0].name = "A" + String(repeating: "\u{0301}", count: 35_000)
        try oversized.validate()
        XCTAssertThrowsError(try store.save(oversized, replacing: saved))
        XCTAssertTrue(try Data(contentsOf: store.url) == originalBytes)
        XCTAssertEqual(try store.load(), saved)
    }

    func testRoutesSwapOppositeMachineAndPreserveOtherSettings() throws {
        let movedLeft = try MachineRouter.target(for: peer, route: .pbpLeft, from: split)
        XCTAssertEqual(movedLeft.source1, .hdmi1)
        XCTAssertEqual(movedLeft.source2, .usbc)
        XCTAssertEqual(movedLeft.pipInput, .usbc)
        XCTAssertEqual(movedLeft.pipSize, split.pipSize)
        XCTAssertEqual(movedLeft.pipPosition, split.pipPosition)
        let movedRight = try MachineRouter.target(for: local, route: .pbpRight, from: split)
        XCTAssertEqual(movedRight, movedLeft)
        let thirdMachine = try MachineRouter.target(for: linux, route: .pbpLeft, from: split)
        XCTAssertEqual(thirdMachine.source1, .dp)
        XCTAssertEqual(thirdMachine.source2, .hdmi1)
        let full = try MachineRouter.target(for: linux, route: .fullscreen, from: split)
        XCTAssertEqual(full.mode, .off)
        XCTAssertEqual(full.source1, .dp)
        XCTAssertEqual(full.source2, split.source2)
    }

    func testRouteNeedsDistinctExistingCounterpart() throws {
        var fullscreen = split
        fullscreen.mode = .off
        fullscreen.source2 = fullscreen.source1
        XCTAssertThrowsError(try MachineRouter.target(for: local, route: .pbpLeft, from: fullscreen))
        let target = try MachineRouter.target(for: linux, route: .pbpRight, from: fullscreen)
        XCTAssertEqual(target.source1, .usbc)
        XCTAssertEqual(target.source2, .dp)
    }

    func testLinuxStatusKeepsConnectorEvidenceSeparateFromModes() throws {
        let output = """
        USER\tfixture
        HOSTNAME\tlinux-fixture
        KERNEL\tLinux
        ARCH\tx86_64
        CONNECTOR\tcard0-DP-1\tconnected
        MODE\tcard0-DP-1\t1720x1440
        MODE\tcard0-DP-1\t2560x1440
        CONNECTOR\tcard0-HDMI-A-1\tdisconnected
        """
        let identity = try MachineStatusClient.decodeLinux(output)
        XCTAssertEqual(identity.name, "linux-fixture")
        XCTAssertEqual(identity.connectors.count, 2)
        XCTAssertEqual(identity.connectors[0].status, .connected)
        XCTAssertEqual(identity.connectors[0].modes, ["1720x1440", "2560x1440"])
        XCTAssertEqual(identity.connectors[1].status, .disconnected)
        XCTAssertThrowsError(try MachineStatusClient.decodeLinux(output.replacingOccurrences(of: "HOSTNAME\tlinux-fixture\n", with: "")))
        XCTAssertThrowsError(try MachineStatusClient.decodeLinux(output + "\nCONNECTOR\tcard0-DP-1\tdisconnected"))
    }
}
