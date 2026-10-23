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
            XCTAssertEqual(status.configuredName, machine.name)
            XCTAssertNil(status.observedName)
            XCTAssertEqual(status.platform, platform)
            XCTAssertNil(status.reachable)
            XCTAssertNil(status.user)
            XCTAssertNil(status.macDisplays)
            XCTAssertTrue(status.connectors.isEmpty)
            XCTAssertNil(status.error)
        }
    }

    func testObservedMacNamePreservesItsConfiguredAliasSeparately() {
        let displays = MacDisplayState(computerName: "Observed Mac name", displays: [])
        let status = MachineStatus(machine: local, macDisplays: displays)
        XCTAssertEqual(status.configuredName, "This Mac")
        XCTAssertEqual(status.observedName, "Observed Mac name")
        XCTAssertEqual(status.name, status.observedName)
    }

    func testFailedIdentityCheckDoesNotObserveItsConfiguredName() async {
        var invalid = local
        invalid.platform = .linux // Reject before any local display or SSH work.
        let status = await MachineStatusClient().state(for: invalid)
        XCTAssertEqual(status.name, invalid.name)
        XCTAssertEqual(status.configuredName, invalid.name)
        XCTAssertNil(status.observedName)
        XCTAssertNil(status.reachable)
        XCTAssertNotNil(status.error)
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
        XCTAssertTrue(identity.connectors.allSatisfy { $0.identification == nil && $0.identificationError == nil },
                      "Older probe responses do not establish a display identity")
        XCTAssertThrowsError(try MachineStatusClient.decodeLinux(output.replacingOccurrences(of: "HOSTNAME\tlinux-fixture\n", with: "")))
        XCTAssertThrowsError(try MachineStatusClient.decodeLinux(output + "\nCONNECTOR\tcard0-DP-1\tdisconnected"))
    }

    func testLinuxEDIDIdentifiesTheDisplayIndependentlyOfItsHostConnectorNumber() throws {
        let response = linuxIdentity + "\nCONNECTOR\tcard0-HDMI-A-3\tconnected\nEDID\tcard0-HDMI-A-3\t" + syntheticEDID().hex
        let result = try MachineStatusClient.decodeLinux(response)
        let connector = try XCTUnwrap(result.connectors.first)
        let identification = try XCTUnwrap(connector.identification)
        XCTAssertEqual(connector.id, "card0-HDMI-A-3")
        XCTAssertEqual(identification.vendorID, 0x3669)
        XCTAssertEqual(identification.productID, 0x30c5)
        XCTAssertEqual(identification.name, "Fixture MSI")
        XCTAssertEqual(identification.hdmiPhysicalAddress?.dottedString, "2.0.0.0")
        XCTAssertNil(connector.identificationError)
    }

    func testLinuxEDIDFailurePreservesObservedHostAndConnectorFacts() throws {
        var invalid = syntheticEDID()
        invalid[20] ^= 1
        let response = linuxIdentity + "\nCONNECTOR\tcard0-DP-1\tconnected\nEDID\tcard0-DP-1\t" + invalid.hex
        let result = try MachineStatusClient.decodeLinux(response)
        XCTAssertEqual(result.name, "observed-linux")
        XCTAssertEqual(result.connectors.first?.status, .connected)
        XCTAssertNil(result.connectors.first?.identification)
        XCTAssertEqual(result.connectors.first?.identificationError, "invalidChecksum")

        let unavailable = try MachineStatusClient.decodeLinux(linuxIdentity + "\nCONNECTOR\tcard0-DP-1\tconnected\nEDID_ERROR\tcard0-DP-1\tunreadable")
        XCTAssertEqual(unavailable.name, "observed-linux")
        XCTAssertNil(unavailable.connectors.first?.identification)
        XCTAssertEqual(unavailable.connectors.first?.identificationError, "unreadable")
    }

    func testLinuxEDIDRowsRejectMalformedDuplicateAndUnmatchedEvidence() {
        let baseline = linuxIdentity + "\nCONNECTOR\tcard0-DP-1\tconnected\n"
        let valid = "EDID\tcard0-DP-1\t" + syntheticEDID().hex
        let badRows = [
            "EDID\tcard0-DP-1\t", "EDID\tcard0-DP-1\t0", "EDID\tcard0-DP-1\txx",
            "EDID\tcard0-DP-1\t" + String(repeating: "00", count: 4097),
            "EDID\tunknown-connector\t" + syntheticEDID().hex,
            valid + "\n" + valid,
            valid + "\nEDID_ERROR\tcard0-DP-1\tempty",
            "EDID_ERROR\tcard0-DP-1\tempty\nEDID_ERROR\tcard0-DP-1\tunreadable",
            "EDID_ERROR\tcard0-DP-1\tunrecognized-private-text"
        ]
        for rows in badRows {
            XCTAssertThrowsError(try MachineStatusClient.decodeLinux(baseline + rows))
        }
        let disconnected = linuxIdentity + "\nCONNECTOR\tcard0-DP-1\tdisconnected\n" + valid
        XCTAssertThrowsError(try MachineStatusClient.decodeLinux(disconnected),
                             "A disconnected output cannot publish a current EDID identity")
    }

    private var linuxIdentity: String {
        "USER\tfixture\nHOSTNAME\tobserved-linux\nKERNEL\tLinux\nARCH\tx86_64"
    }

    /// Synthetic public identity and topology, with no real monitor serial.
    private func syntheticEDID() -> [UInt8] {
        var base = [UInt8](repeating: 0, count: 128)
        base.replaceSubrange(0..<12, with: [0, 255, 255, 255, 255, 255, 255, 0, 0x36, 0x69, 0xc5, 0x30])
        base[18] = 1; base[19] = 4; base[20] = 0x80; base[126] = 1
        base[57] = 0xfc
        base.replaceSubrange(59..<71, with: Array("Fixture MSI\n".utf8))
        var cta = [UInt8](repeating: 0, count: 128)
        cta[0] = 2; cta[1] = 3; cta[2] = 10
        cta.replaceSubrange(4..<10, with: [0x65, 0x03, 0x0c, 0x00, 0x20, 0x00])
        base[127] = UInt8((256 - base.reduce(0, { $0 + Int($1) }) % 256) % 256)
        cta[127] = UInt8((256 - cta.reduce(0, { $0 + Int($1) }) % 256) % 256)
        return base + cta
    }
}
