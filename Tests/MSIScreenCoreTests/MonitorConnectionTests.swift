import XCTest
@testable import MSIScreenCore

final class MonitorConnectionTests: XCTestCase {
    private let local = MachineDefinition(id: "local", name: "Saved Mac alias", platform: .macos, input: .usbc, host: nil)
    private let peer = MachineDefinition(id: "peer", name: "Saved peer", platform: .macos, input: .hdmi1, host: "peer")
    private let linux = MachineDefinition(id: "linux", name: "Saved Linux alias", platform: .linux, input: .hdmi2, host: "linux")

    private func display(_ id: UInt32 = 4, monitor: Bool = true) -> MacDisplayInfo {
        MacDisplayInfo(id: id, uuid: "fixture-\(id)", vendor: monitor ? 0x3669 : 0x610,
            model: monitor ? 0x30c5 : 1, isBuiltIn: !monitor, isMain: monitor, isActive: true,
            isAsleep: false, isMirrored: false, mirrorsDisplay: 0,
            bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440), rotation: 0,
            mode: MacDisplayMode(id: 54, width: 3440, height: 1440, pixelWidth: 3440,
                                 pixelHeight: 1440, refreshRate: 100, flags: 0))
    }
    private func identity(_ address: UInt16 = 0x1000) throws -> DisplayIdentification {
        try JSONDecoder().decode(DisplayIdentification.self, from: Data("""
        {"vendorID":13929,"productID":12485,"name":"Fixture MSI","hdmiPhysicalAddress":{"rawValue":\(address)}}
        """.utf8))
    }
    private func link(_ transport: VideoTransport = .hdmi, port: String = "Mac-HDMI@1") throws -> MacVideoConnection {
        try MacVideoConnection(transport: transport, hostPort: port, display: identity())
    }
    private func video(_ displays: [MacDisplayInfo], links: [MacVideoConnection]) -> MonitorVideoObservation {
        MonitorVideoObservation(displays: .success(MacDisplayState(computerName: "Observed Mac", displays: displays)),
            links: MacVideoConnectionSnapshot(connections: links, outcome: .complete))
    }
    private var absentUSB: MonitorControlConnection {
        MonitorControlConnection(local: .init(.absent), upstream: .init(.absent), upstreamMachineID: linux.id,
                                 usb: nil, layout: nil, layoutError: nil)
    }
    private func failedStatus(_ machine: MachineDefinition) -> MachineStatus {
        MachineStatus(machineID: machine.id, configuredName: machine.name, observedName: nil,
            platform: machine.platform, checkedAt: Date(), reachable: nil, user: nil, architecture: nil,
            macDisplays: nil, connectors: [], error: "SSH unavailable")
    }

    func testHDMIVideoSurvivesAbsentUSBAndStaleSavedAssignmentsWithoutInventingLayout() async throws {
        let registry = MachineRegistry(machines: [local, peer, linux], usbUpstreamMachineID: linux.id)
        let snapshot = MacDisplayState(computerName: "Observed Mac", displays: [display()])
        let links = MacVideoConnectionSnapshot(connections: [try link()], outcome: .complete)
        let client = MonitorConnectionClient(services: .init(displays: { snapshot }, links: { links },
            machine: { machine in
                XCTAssertFalse(machine.isLocal, "The aggregate must use its independently observed local display, not re-query it through a saved entry")
                return self.failedStatus(machine)
            }, control: { supplied in XCTAssertEqual(supplied, registry); return self.absentUSB }))
        let result = await client.snapshot(registry: .success(registry))
        XCTAssertEqual(result.localVideo.state, .detected)
        XCTAssertEqual(result.localVideo.displays.first?.display?.mode?.refreshRate, 100)
        XCTAssertEqual(result.usbControl.local.state, .absent)
        XCTAssertNil(result.usbControl.layout)
        let observed = try XCTUnwrap(result.machines.first)
        XCTAssertEqual(observed.observedName, "Observed Mac")
        XCTAssertEqual(observed.configuredName, local.name)
        XCTAssertEqual(observed.configuredInput, .usbc)
        XCTAssertEqual(observed.displays.first?.inferredMonitorInput, .hdmi1)
        XCTAssertEqual(observed.assignment, .conflictsWithInference)
        XCTAssertNil(result.machines[1].observedName)
        XCTAssertEqual(registry.machines.map(\.input), [.usbc, .hdmi1, .hdmi2])
        XCTAssertFalse(result.complete, "Unreachable sources must remain incomplete, not become configured-name discoveries")
    }

    func testLocalDisplayDetectionDoesNotRequireASavedLocalMachine() async throws {
        let client = MonitorConnectionClient(services: .init(
            displays: { MacDisplayState(computerName: "Unconfigured Mac", displays: [self.display()]) },
            links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) },
            machine: { machine in XCTFail("No machine should be queried"); return self.failedStatus(machine) },
            control: { _ in self.absentUSB }))
        let result = await client.snapshot(registry: .success(MachineRegistry(machines: [])))
        XCTAssertEqual(result.localVideo.state, .detected)
        XCTAssertEqual(result.localVideo.computerName, "Unconfigured Mac")
        XCTAssertTrue(result.machines.isEmpty)
        XCTAssertNil(result.localVideo.displays.first?.inferredMonitorInput)
    }

    func testNoVideoAndFailedVideoReadAreDifferentFromAConnectedDisplay() throws {
        XCTAssertEqual(video([display(1, monitor: false)], links: []).state, .notDetected)
        let failed = MonitorVideoObservation(displays: .failure(ScreenError.message("Display source failed")),
            links: MacVideoConnectionSnapshot(connections: [], outcome: .complete))
        XCTAssertEqual(failed.state, .unknown)
        XCTAssertNotNil(failed.error)
        XCTAssertNil(failed.computerName)
        XCTAssertTrue(failed.displays.isEmpty)
    }

    func testDuplicateDisplayOrLinkIdentitiesNeverPickTheFirstConnector() throws {
        for observation in [
            video([display(), display(5)], links: [try link()]),
            video([display()], links: [try link(), try link(port: "Second-Mac-port")])
        ] {
            XCTAssertTrue(observation.displays.allSatisfy { $0.association == .ambiguous })
            XCTAssertTrue(observation.displays.allSatisfy { $0.inferredMonitorInput == nil && $0.transport == .unknown })
        }
    }

    func testPartialConnectorReadDoesNotEraseQuartzDisplayOrInventItsInput() throws {
        let observation = MonitorVideoObservation(displays: .success(MacDisplayState(computerName: "Mac", displays: [display()])),
            links: MacVideoConnectionSnapshot(connections: [try link()],
                outcome: .failed(code: .changedDuringEnumeration, message: "Port changed")))
        XCTAssertEqual(observation.state, .detected)
        XCTAssertNotNil(observation.connectorError)
        XCTAssertNil(observation.displays.first?.inferredMonitorInput)
    }

    func testHDMIAddressAdvertisedOnOtherTransportsCannotBecomeAnHDMIInput() throws {
        for transport in [VideoTransport.usbc, .displayPort, .unknown] {
            let connection = try XCTUnwrap(video([display()], links: [try link(transport)]).displays.first)
            XCTAssertEqual(connection.transport, transport)
            XCTAssertNotNil(connection.identification?.hdmiPhysicalAddress)
            XCTAssertNil(connection.inferredMonitorInput)
        }
    }

    func testLinuxHDMIOutputOneCanObserveTopologyTwoWithoutUsingItsSavedInputOrAlias() throws {
        var definition = linux; definition.input = .dp
        let connector = LinuxDisplayConnector(id: "card0-HDMI-A-1", status: .connected, modes: ["3440x1440"],
                                             identification: try identity(0x2000))
        let status = MachineStatus(machineID: definition.id, configuredName: definition.name, observedName: "observed-linux",
            platform: .linux, checkedAt: Date(), reachable: true, user: nil, architecture: nil,
            macDisplays: nil, connectors: [connector], error: nil)
        let result = MachineConnectionObservation(machine: definition, status: status, localVideo: nil)
        XCTAssertEqual(result.observedName, "observed-linux")
        XCTAssertEqual(result.configuredInput, .dp)
        XCTAssertEqual(result.video, .detected)
        XCTAssertEqual(result.displays.first?.hostConnector, "card0-HDMI-A-1")
        XCTAssertEqual(result.displays.first?.inferredMonitorInput, .hdmi2)
        XCTAssertEqual(result.assignment, .conflictsWithInference)
        XCTAssertNil(result.displays.first?.display, "Advertised modes must not invent an active Linux resolution")
    }

    func testConnectedLinuxOutputWithUnknownDisplayIdentityIsNotAnAbsentMonitor() async {
        let connector = LinuxDisplayConnector(id: "card0-DP-1", status: .connected, modes: [], identificationError: "unreadable")
        let status = MachineStatus(machineID: linux.id, configuredName: linux.name, observedName: "observed-linux",
            platform: .linux, checkedAt: Date(), reachable: true, user: nil, architecture: nil,
            macDisplays: nil, connectors: [connector], error: nil)
        let result = MachineConnectionObservation(machine: linux, status: status, localVideo: nil)
        XCTAssertEqual(result.video, .unknown)
        XCTAssertTrue(result.displays.isEmpty)
        XCTAssertEqual(result.connectors.first?.identificationError, "unreadable")
        let client = MonitorConnectionClient(services: .init(
            displays: { MacDisplayState(computerName: "Mac", displays: []) },
            links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) },
            machine: { _ in status }, control: { _ in self.absentUSB }))
        let snapshot = await client.snapshot(registry: .success(MachineRegistry(machines: [linux])))
        XCTAssertFalse(snapshot.complete)
        XCTAssertEqual(snapshot.machines.first?.connectors.first?.identificationError, "unreadable")
    }

    func testLegacyLinuxConnectorWithoutEDIDRemainsPartialDespiteSuccessfulSSH() async {
        let status = MachineStatus(machineID: linux.id, configuredName: linux.name, observedName: "observed-linux",
            platform: .linux, checkedAt: Date(), reachable: true, user: nil, architecture: nil,
            macDisplays: nil, connectors: [.init(id: "card0-HDMI-A-1", status: .connected, modes: ["3440x1440"])], error: nil)
        let client = MonitorConnectionClient(services: .init(
            displays: { MacDisplayState(computerName: "Mac", displays: []) },
            links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) },
            machine: { _ in status }, control: { _ in self.absentUSB }))
        let snapshot = await client.snapshot(registry: .success(MachineRegistry(machines: [linux])))
        XCTAssertEqual(snapshot.machines.first?.video, .unknown)
        XCTAssertNil(snapshot.machines.first?.error)
        XCTAssertFalse(snapshot.complete, "A successful SSH response without display identity cannot establish complete video observations")
    }

    func testInvalidRegistryPreservesIndependentLocalVideoWithoutProbingItsHosts() async {
        let client = MonitorConnectionClient(services: .init(
            displays: { MacDisplayState(computerName: "Observed Mac", displays: [self.display()]) },
            links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) },
            machine: { machine in XCTFail("Unvalidated configuration must not cause SSH"); return self.failedStatus(machine) },
            control: { registry in XCTAssertTrue(registry.machines.isEmpty); return self.absentUSB }))
        for source: Result<MachineRegistry, Error> in [
            .failure(ScreenError.message("Registry unavailable")),
            .success(MachineRegistry(machines: [local, local]))
        ] {
            let result = await client.snapshot(registry: source)
            XCTAssertEqual(result.localVideo.state, .detected)
            XCTAssertEqual(result.localVideo.computerName, "Observed Mac")
            XCTAssertNotNil(result.registryError)
            XCTAssertTrue(result.machines.isEmpty)
            XCTAssertFalse(result.complete)
        }
    }

    func testFailedLocalDisplaySourceIsNotRetriedThroughItsConfiguredMachine() async {
        var reads = 0
        let client = MonitorConnectionClient(services: .init(
            displays: { reads += 1; throw ScreenError.message("Display source unavailable") },
            links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) },
            machine: { machine in XCTFail("Local failure must not cause a second display query"); return self.failedStatus(machine) },
            control: { _ in self.absentUSB }))
        let result = await client.snapshot(registry: .success(MachineRegistry(machines: [local])))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(result.localVideo.state, .unknown)
        XCTAssertNil(result.machines.first?.observedName)
        XCTAssertEqual(result.machines.first?.video, .unknown)
        XCTAssertFalse(result.complete)
    }
}
