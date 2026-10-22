import XCTest
@testable import MSIScreenMenu
@testable import MSIScreenCore

final class LayoutApplicationTests: XCTestCase {
    private let mac = MachineDefinition(id: "mac", name: "Mac", platform: .macos, input: .usbc, host: nil)
    private let linux = MachineDefinition(id: "linux", name: "Linux", platform: .linux, input: .dp, host: "linux")
    private let baseline = ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: .pbp,
                                      source1: .hdmi1, source2: .usbc, pipInput: .usbc,
                                      pipSize: 2, pipPosition: 3)

    private func usb(_ route: KVMRoute, _ host: KVMControlHost) -> KVMStatus {
        KVMStatus(KVMSnapshot(model: "MD342CQP", protocolVersion: "V20", route: route),
                  host: host, machineID: "linux")
    }

    func testFullscreenLinuxStillAppliesWhenOnlyUSBNeedsMoving() {
        let target = ScreenController.fullscreenTarget(from: baseline, input: .dp)
        let application = LayoutApplication(target: target, machines: [mac, linux], followUSB: true,
                                            usbUpstreamMachineID: linux.id)
        XCTAssertEqual(application.focusMachine, linux)
        XCTAssertEqual(application.command, "msi-screen machine focus linux")
        XCTAssertTrue(application.canApply(from: target, kvm: usb(.usbc, .local), localReadBlocked: false))
        XCTAssertFalse(application.canApply(from: target, kvm: usb(.upstream, .upstream), localReadBlocked: true))
        XCTAssertFalse(application.canApply(from: baseline, kvm: nil, localReadBlocked: false))
    }

    func testVideoOnlyFullscreenPreservesUSBWithSavedSSHMachineUnassigned() {
        var savedLinux = linux
        savedLinux.input = nil
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .dp, host: nil, access: .videoOnly)
        let target = ScreenController.fullscreenTarget(from: baseline, input: .dp)
        let application = LayoutApplication(target: target, machines: [mac, savedLinux, deck], followUSB: true)
        XCTAssertNil(application.focusMachine)
        XCTAssertEqual(application.command, "msi-screen fullscreen dp")
        XCTAssertTrue(application.canApply(from: baseline, kvm: nil, localReadBlocked: false))
        XCTAssertFalse(application.canApply(from: target, kvm: usb(.usbc, .local), localReadBlocked: false))
        XCTAssertEqual(LayoutApplication(target: ScreenController.fullscreenTarget(from: baseline, input: .usbc),
                                         machines: [mac, savedLinux, deck], followUSB: true).focusMachine, mac)
    }

    @MainActor
    func testPreferencesDoNotTreatVideoOnlySourceAsLocalMac() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .dp, host: nil, access: .videoOnly)
        var unassignedMac = mac
        unassignedMac.input = nil
        try store.save(MachineRegistry(machines: [deck, unassignedMac]), replacing: MachineRegistry())
        let preferences = MonitorPreferences(registryStore: store)
        XCTAssertEqual(preferences.localMachine?.id, mac.id)
        XCTAssertNil(preferences.localInput)
        XCTAssertEqual(preferences.name(for: .usbc, localName: "Observed Mac", peerName: nil), Input.usbc.title)
        XCTAssertEqual(preferences.name(for: .dp, localName: "Observed Mac", peerName: nil), deck.name)
    }

    func testFullscreenMacCanReturnUSBFromLinux() {
        let target = ScreenController.fullscreenTarget(from: baseline, input: .usbc)
        let application = LayoutApplication(target: target, machines: [mac, linux], followUSB: true)
        XCTAssertEqual(application.focusMachine, mac)
        XCTAssertTrue(application.canApply(from: baseline, kvm: usb(.upstream, .upstream), localReadBlocked: true))
    }

    func testPBPAndDisabledFollowKeepExplicitUSBSelection() throws {
        let split = try ScreenController.pbpTarget(from: baseline, enabled: true, left: .dp, right: .usbc)
        let application = LayoutApplication(target: split, machines: [mac, linux], followUSB: true)
        XCTAssertNil(application.focusMachine)
        XCTAssertEqual(application.command, "msi-screen pbp on --left dp --right usbc")
        XCTAssertTrue(application.canApply(from: baseline, kvm: nil, localReadBlocked: false))
        XCTAssertTrue(application.canApply(from: baseline, kvm: usb(.upstream, .upstream), localReadBlocked: true))
        XCTAssertFalse(application.canApply(from: baseline, kvm: nil, localReadBlocked: true))
        let full = ScreenController.fullscreenTarget(from: baseline, input: .dp)
        let videoOnly = LayoutApplication(target: full, machines: [mac, linux], followUSB: false)
        XCTAssertNil(videoOnly.focusMachine)
        XCTAssertEqual(videoOnly.command, "msi-screen fullscreen dp")
        XCTAssertFalse(videoOnly.canApply(from: full, kvm: usb(.usbc, .local), localReadBlocked: false))
    }

    func testSecondSSHComputerDoesNotMoveUSBWithoutThePhysicalAssignment() {
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .hdmi2, host: "deck@steamdeck", sshTransport: .tailscale)
        let target = ScreenController.fullscreenTarget(from: baseline, input: .hdmi2)
        let application = LayoutApplication(target: target, machines: [mac, linux, deck], followUSB: true,
                                            usbUpstreamMachineID: linux.id)
        XCTAssertNil(application.focusMachine)
        XCTAssertEqual(application.command, "msi-screen fullscreen hdmi2")
        let reassigned = LayoutApplication(target: target, machines: [mac, linux, deck], followUSB: true,
                                          usbUpstreamMachineID: deck.id)
        XCTAssertEqual(reassigned.focusMachine, deck)
    }

    @MainActor
    func testUniversalControlLinkPersistsForTheSelectedMacAndNeverAdoptsAnotherMachine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "msi-universal-control-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let registry = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let peer = MachineDefinition(id: "peer", name: "Shared Mac", platform: .macos, input: .hdmi1, host: "peer")
        let other = MachineDefinition(id: "other", name: "Unlinked Mac", platform: .macos, input: .hdmi2, host: "other")
        let initial = MachineRegistry(machines: [mac, peer, other, linux])
        try registry.save(initial, replacing: MachineRegistry())
        let prefs = MonitorPreferences(defaults: defaults, registryStore: registry)
        XCTAssertNil(prefs.universalControlPeer)
        prefs.universalControlPeerID = peer.id
        XCTAssertTrue(prefs.usesUniversalControl(mac))
        XCTAssertTrue(prefs.usesUniversalControl(peer))
        XCTAssertFalse(prefs.usesUniversalControl(other))
        XCTAssertFalse(prefs.usesUniversalControl(linux))
        let reopened = MonitorPreferences(defaults: defaults, registryStore: registry)
        XCTAssertEqual(reopened.universalControlPeer, peer)
        var reordered = initial
        reordered.machines = [other, mac, linux, peer]
        try registry.save(reordered, replacing: initial)
        reopened.reload()
        XCTAssertEqual(reopened.universalControlPeer, peer)
        try reopened.removeMachine(peer)
        XCTAssertNil(reopened.universalControlPeer)
        XCTAssertFalse(reopened.usesUniversalControl(other))
        reopened.universalControlPeerID = linux.id
        XCTAssertNil(reopened.universalControlPeer)
    }

    @MainActor
    func testAddingDiscoveredMachinePreservesExplicitUSBUpstream() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryStore = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        try registryStore.save(MachineRegistry(machines: [mac, linux], usbUpstreamMachineID: linux.id),
                               replacing: MachineRegistry())
        let preferences = MonitorPreferences(registryStore: registryStore)
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: nil, host: "deck@steamdeck", sshTransport: .tailscale)
        try preferences.saveMachine(deck, replacing: nil)
        XCTAssertEqual(try registryStore.load().usbUpstreamMachineID, linux.id)
        XCTAssertEqual(preferences.usbUpstreamMachine?.id, linux.id)
        try preferences.removeMachine(linux)
        XCTAssertNil(try registryStore.load().usbUpstreamMachineID)
        XCTAssertNil(preferences.usbUpstreamMachine, "Removing the USB-B computer must not assign its cable to the remaining peer")
    }
}
