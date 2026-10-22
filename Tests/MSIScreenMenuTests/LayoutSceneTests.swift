import XCTest
@testable import MSIScreenMenu
@testable import MSIScreenCore

final class LayoutSceneTests: XCTestCase {
    private let local = MachineDefinition(id: "local", name: "Local Mac", platform: .macos,
                                          input: .usbc, host: nil)
    private let peer = MachineDefinition(id: "peer", name: "Other Mac", platform: .macos,
                                         input: .hdmi1, host: "other-mac")
    private let chimera = MachineDefinition(id: "chimera", name: "ChimeraOS", platform: .linux,
                                            input: .hdmi2, host: "chimera")
    private let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                         input: .dp, host: "deck@steamdeck", sshTransport: .tailscale)
    private var machines: [MachineDefinition] { [local, peer, chimera, deck] }
    private var observed: ScreenState {
        ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: .pbp,
                    source1: .hdmi2, source2: .usbc, pipInput: .hdmi1, pipSize: 2, pipPosition: 3)
    }

    func testCurrentFourComputerSceneUsesObservedInputsAndRetainsOtherAssignments() {
        let scene = LayoutScene(current: true, observed: observed, pendingTarget: nil,
                                split: false, left: .dp, right: .hdmi1, machines: machines)
        XCTAssertEqual(scene.presentation, .current)
        XCTAssertEqual(scene.panes.map(\.region), [.left, .right])
        XCTAssertEqual(scene.panes.map(\.input), [.hdmi2, .usbc])
        XCTAssertEqual(scene.panes.compactMap { $0.machine?.id }, [chimera.id, local.id])
        XCTAssertEqual(scene.otherAssignedMachines.map(\.id), [peer.id, deck.id])
    }

    func testDraftUsesChosenInputsWithoutChangingPhysicalUSBEligibility() {
        let scene = LayoutScene(current: false, observed: observed, pendingTarget: nil,
                                split: false, left: .dp, right: .usbc, machines: machines)
        XCTAssertEqual(scene.presentation, .draft)
        XCTAssertEqual(scene.panes.map(\.region), [.fullScreen])
        XCTAssertEqual(scene.panes.first?.machine, deck)
        XCTAssertEqual(scene.otherAssignedMachines.map(\.id), [local.id, peer.id, chimera.id])
        XCTAssertNil(LayoutScene.usbRoute(for: deck, upstreamMachineID: chimera.id))
        XCTAssertEqual(LayoutScene.usbRoute(for: chimera, upstreamMachineID: chimera.id), .upstream)
    }

    func testUneditedControlsDescribeTheCurrentLayoutUntilAVisibleInputChanges() {
        let current = LayoutScene(current: false, observed: observed, pendingTarget: nil,
                                  split: true, left: .hdmi2, right: .usbc, machines: machines)
        XCTAssertEqual(current.presentation, .current)
        let changed = LayoutScene(current: false, observed: observed, pendingTarget: nil,
                                  split: true, left: .dp, right: .usbc, machines: machines)
        XCTAssertEqual(changed.presentation, .draft)
        XCTAssertEqual(changed.panes.first?.machine, deck)
    }

    func testPendingLayoutIsApplyingEvenWhenCurrentReadbackIsUnavailable() {
        let pending = ScreenController.fullscreenTarget(from: observed, input: .hdmi1)
        for current in [true, false] {
            let scene = LayoutScene(current: current, observed: nil, pendingTarget: pending,
                                    split: true, left: .dp, right: .usbc, machines: machines)
            XCTAssertEqual(scene.presentation, .applying)
            XCTAssertEqual(scene.panes.map(\.input), [.hdmi1])
            XCTAssertEqual(scene.panes.first?.machine, peer)
        }
    }

    func testUnavailableLayoutNeverRendersDefaultInputsOrClaimsOffscreenMachines() {
        let scene = LayoutScene(current: false, observed: nil, pendingTarget: nil,
                                split: false, left: .dp, right: .usbc, machines: machines)
        XCTAssertEqual(scene.presentation, .unavailable)
        XCTAssertTrue(scene.panes.isEmpty)
        XCTAssertTrue(scene.otherAssignedMachines.isEmpty)
    }

    func testPIPUsesItsOwnSecondaryInputAndPreservesRawGeometry() {
        var current = observed
        current.mode = .pip
        let scene = LayoutScene(current: true, observed: current, pendingTarget: nil,
                                split: false, left: .dp, right: .usbc, machines: machines)
        XCTAssertEqual(scene.panes.map(\.region), [.main, .inset])
        XCTAssertEqual(scene.panes.map(\.input), [.hdmi2, .hdmi1])
        XCTAssertEqual(scene.panes.compactMap { $0.machine?.id }, [chimera.id, peer.id])
        XCTAssertEqual(scene.pip?.size, current.pipSize)
        XCTAssertEqual(scene.pip?.position, current.pipPosition)
        XCTAssertEqual(scene.otherAssignedMachines.map(\.id), [local.id, deck.id])
    }

    func testDuplicateDraftInputsKeepDistinctRegionsAndUnassignedVideoHasNoInventedMachine() {
        let duplicate = LayoutScene(current: false, observed: observed, pendingTarget: nil,
                                    split: true, left: .dp, right: .dp, machines: machines)
        XCTAssertEqual(duplicate.panes.map(\.input), [.dp, .dp])
        XCTAssertEqual(Set(duplicate.panes.map(\.id)).count, 2)
        var noVideoPeer = peer
        noVideoPeer.input = nil
        let unassigned = LayoutScene(current: false, observed: observed, pendingTarget: nil,
                                     split: false, left: .hdmi1, right: .usbc,
                                     machines: [local, noVideoPeer, chimera, deck])
        XCTAssertNil(unassigned.panes.first?.machine)
        XCTAssertFalse(unassigned.otherAssignedMachines.contains { $0.id == peer.id })
    }

    func testUSBRouteRequiresPhysicalRoleAndDoesNotRequireVisibleVideo() {
        XCTAssertEqual(LayoutScene.usbRoute(for: local, upstreamMachineID: chimera.id), .usbc)
        XCTAssertNil(LayoutScene.usbRoute(for: peer, upstreamMachineID: chimera.id))
        XCTAssertNil(LayoutScene.usbRoute(for: deck, upstreamMachineID: nil))
        var noVideo = chimera
        noVideo.input = nil
        XCTAssertEqual(LayoutScene.usbRoute(for: noVideo, upstreamMachineID: chimera.id), .upstream)
        var wrongLocalInput = local
        wrongLocalInput.input = .hdmi1
        XCTAssertNil(LayoutScene.usbRoute(for: wrongLocalInput, upstreamMachineID: chimera.id))
        var videoOnly = deck
        videoOnly.access = .videoOnly
        videoOnly.host = nil
        videoOnly.sshTransport = .standard
        XCTAssertNil(LayoutScene.usbRoute(for: videoOnly, upstreamMachineID: deck.id))
    }
}
