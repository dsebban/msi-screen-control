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

    func testLegacyRegistryMigratesAccessAndWritesVersionThreeOnEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let legacy = Data(#"{"schemaVersion":1,"machines":[{"id":"mac","name":"Mac","platform":"macos","input":"usbc"},{"id":"linux","name":"Linux","platform":"linux","input":"dp","host":"linux"}]}"#.utf8)
        try legacy.write(to: store.url)
        let loaded = try store.load()
        XCTAssertEqual(loaded.schemaVersion, 3)
        XCTAssertEqual(loaded.machines.map(\.access), [.local, .ssh])
        XCTAssertEqual(loaded.usbUpstreamMachineID, "linux")
        XCTAssertEqual(try Data(contentsOf: store.url), legacy, "Reading must not rewrite the shared file")
        var updated = loaded
        updated.machines[1].input = nil
        updated.machines.append(MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                                  input: .dp, host: nil, access: .videoOnly))
        try store.save(updated, replacing: loaded)
        XCTAssertEqual(try store.load(), updated)
        let data = try Data(contentsOf: store.url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 3, "Older applications must reject the new records")
        let records = try XCTUnwrap(json["machines"] as? [[String: Any]])
        XCTAssertEqual(records.last?["access"] as? String, "video-only")
    }

    func testAccessAndUnassignedInputsAreExplicit() throws {
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .dp, host: nil, access: .videoOnly)
        var unplugged = linux
        unplugged.input = nil
        var peerWithoutVideo = peer
        peerWithoutVideo.input = nil
        try MachineRegistry(machines: [local, deck, unplugged, peerWithoutVideo]).validate()
        XCTAssertFalse(deck.isLocal)
        XCTAssertThrowsError(try MachineRouter.target(for: unplugged, route: .fullscreen, from: split))
        XCTAssertEqual(try MachineRouter.target(for: deck, route: .fullscreen, from: split).source1, .dp)
        var invalid = deck
        invalid.host = "unexpected-host"
        XCTAssertThrowsError(try MachineRegistry(machines: [invalid]).validate())
        let missingAccess = Data(#"{"schemaVersion":2,"machines":[{"id":"deck","name":"Deck","platform":"macos","input":"dp"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MachineRegistry.self, from: missingAccess))
    }

    func testExistingSSHTransportDefaultsToStandardAndExplicitTransportRoundTrips() throws {
        let existing = Data(#"{"schemaVersion":2,"machines":[{"id":"linux","name":"Linux","platform":"linux","input":"dp","access":"ssh","host":"configured-linux"}]}"#.utf8)
        var registry = try JSONDecoder().decode(MachineRegistry.self, from: existing)
        XCTAssertEqual(registry.machines[0].sshTransport, .standard)
        XCTAssertEqual(registry.usbUpstreamMachineID, "linux")
        registry.machines[0].sshTransport = .tailscale
        registry.machines[0].host = "deck@steamdeck"
        try registry.validate()
        let data = try JSONEncoder().encode(registry)
        XCTAssertEqual(registry.schemaVersion, 3)
        XCTAssertEqual(try JSONDecoder().decode(MachineRegistry.self, from: data), registry)
        let missingTransport = Data(#"{"schemaVersion":3,"machines":[{"id":"linux","name":"Linux","platform":"linux","access":"ssh","host":"configured-linux"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MachineRegistry.self, from: missingTransport))
        var videoOnly = registry.machines[0]
        videoOnly.access = .videoOnly
        videoOnly.host = nil
        XCTAssertThrowsError(try MachineRegistry(machines: [videoOnly]).validate(),
                             "A saved native transport cannot silently turn into local/video-only access")
    }

    func testVideoOnlyStatusNeverReportsThisMacOrSSHObservation() async {
        for platform in MachinePlatform.allCases {
            let machine = MachineDefinition(id: "source", name: "Configured source", platform: platform,
                                            input: .dp, host: nil, access: .videoOnly)
            let status = await MachineStatusClient().state(for: machine)
            XCTAssertEqual(status.name, machine.name)
            XCTAssertEqual(status.platform, platform)
            XCTAssertNil(status.reachable)
            XCTAssertNil(status.user)
            XCTAssertNil(status.macDisplays)
            XCTAssertTrue(status.connectors.isEmpty)
            XCTAssertNil(status.error)
        }
    }

    func testUSBUpstreamMigrationPreservesOnlyUnambiguousLegacyAssignment() throws {
        let ambiguous = Data(#"{"schemaVersion":2,"machines":[{"id":"linux","name":"Linux","platform":"linux","access":"ssh","host":"linux"},{"id":"deck","name":"Deck","platform":"linux","access":"ssh","host":"deck"}]}"#.utf8)
        let migrated = try JSONDecoder().decode(MachineRegistry.self, from: ambiguous)
        XCTAssertNil(migrated.usbUpstreamMachineID)
        let explicit = MachineRegistry(machines: [linux], usbUpstreamMachineID: linux.id)
        XCTAssertEqual(try JSONDecoder().decode(MachineRegistry.self, from: JSONEncoder().encode(explicit)), explicit)
        let unassigned = MachineRegistry(machines: [linux])
        XCTAssertNil(try JSONDecoder().decode(MachineRegistry.self, from: JSONEncoder().encode(unassigned)).usbUpstreamMachineID,
                     "Version 3 must preserve an explicit absence rather than infer a stored assignment")
    }

    func testUSBUpstreamAssignmentRejectsMissingAndIneligibleMachines() throws {
        for id in ["missing", local.id, peer.id] {
            XCTAssertThrowsError(try MachineRegistry(machines: [local, peer, linux],
                                                     usbUpstreamMachineID: id).validate())
        }
        var videoOnly = linux
        videoOnly.access = .videoOnly
        videoOnly.host = nil
        XCTAssertThrowsError(try MachineRegistry(machines: [videoOnly], usbUpstreamMachineID: videoOnly.id).validate())
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
