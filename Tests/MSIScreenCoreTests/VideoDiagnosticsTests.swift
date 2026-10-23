import XCTest
@testable import MSIScreenCore

final class VideoDiagnosticsTests: XCTestCase {
    private func display(_ id: UInt32 = 4, rate: Double = 60) -> MacDisplayInfo {
        MacDisplayInfo(id: id, uuid: "fixture", vendor: 0x3669, model: 0x30c5, isBuiltIn: false,
            isMain: true, isActive: true, isAsleep: false, isMirrored: false, mirrorsDisplay: 0,
            bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440), rotation: 0,
            mode: MacDisplayMode(id: 1, width: 3440, height: 1440, pixelWidth: 3440,
                                 pixelHeight: 1440, refreshRate: rate, flags: 0))
    }
    private func mode(_ rate: Double) -> VideoModeCapability {
        VideoModeCapability(width: 3440, height: 1440, pixelWidth: 3440, pixelHeight: 1440, refreshRate: rate)
    }
    private func snapshot(_ displays: [MacDisplayInfo], rates: [Double] = [60], time: TimeInterval = 0,
                          error: String? = nil, ports: [MacVideoPortState] = []) -> VideoDiagnosticsSnapshot {
        VideoDiagnosticsSnapshot(checkedAt: Date(timeIntervalSince1970: time),
            displays: displays.map { VideoDisplayDiagnostics(display: $0, modes: rates.map(mode)) },
            links: MacVideoConnectionSnapshot(connections: [], outcome: .complete, portStates: ports), error: error)
    }

    func testAvailableRatesComeFromCurrentOSModesRatherThanThePanelSpecification() {
        let state = MacDisplayState(computerName: "Mac", displays: [display()])
        let client = VideoDiagnosticsClient(services: .init(displays: { state }, modes: { _ in [self.mode(60), self.mode(60)] },
            links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) }))
        let result = client.snapshot()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.displays.first?.modes.map(\.refreshRate), [60], "Do not add the monitor's advertised 100/120 Hz when macOS only exposes 60")
    }

    func testChangedDuringReadAndUnavailableModesAreNotReportedAsAStableConnection() {
        var reads = 0
        let changed = VideoDiagnosticsClient(services: .init(displays: {
            reads += 1
            return MacDisplayState(computerName: "Mac", displays: [self.display(rate: reads == 1 ? 60 : 120)])
        }, modes: { _ in [self.mode(60)] }, links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) }))
        XCTAssertFalse(changed.snapshot().complete)
        let missing = VideoDiagnosticsClient(services: .init(
            displays: { MacDisplayState(computerName: "Mac", displays: [self.display()]) },
            modes: { _ in [] }, links: { MacVideoConnectionSnapshot(connections: [], outcome: .complete) }))
        let result = missing.snapshot()
        XCTAssertNotNil(result.error)
        XCTAssertFalse(result.complete)
    }

    func testInactivePortDiagnosticsDoNotResurrectAnAttachedMonitorOrDecodeLaneCodes() throws {
        let parsed = MacVideoConnectionReader.parseRecords([
            ["Active": false, "TransportDescription": "Port-USB-C@2/DisplayPort", "ParentPortTypeDescription": "USB-C",
             "LinkRateDescription": "8.1 Gbps (HBR3)", "DriverStatusDescription": "Ready", "HPD_StateDescription": "High",
             "LaneCount": 1, "MaxLaneCount": 4, "SerialNumber": "must-not-escape"],
            ["Active": false, "TransportDescription": "Port-HDMI@1/DisplayPort", "LaneCount": true,
             "DriverStatusDescription": String(repeating: "x", count: 97)]
        ])
        XCTAssertTrue(parsed.connections.isEmpty)
        let port = try XCTUnwrap(parsed.portStates.first { $0.transport == .usbc })
        XCTAssertFalse(port.active)
        XCTAssertEqual(port.rawLaneCount, 1, "Retain the OS code without claiming that it means one physical lane")
        XCTAssertEqual(port.linkRateDescription, "8.1 Gbps (HBR3)")
        XCTAssertNil(parsed.portStates.first { $0.hostPort == "Port-HDMI@1" }?.rawLaneCount)
        XCTAssertNil(parsed.portStates.first { $0.hostPort == "Port-HDMI@1" }?.driverStatus)
        let encoded = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
        XCTAssertFalse(encoded.contains("must-not-escape"))
    }

    func testHistoryRecordsDisconnectReconnectAndChangedCapabilitiesWithoutInventingPhysicalErrors() {
        var history = VideoStabilityHistory()
        history.observe(snapshot([display()]))
        history.observe(snapshot([], time: 2))
        history.observe(snapshot([display()], time: 4))
        history.observe(snapshot([display()], rates: [60, 100], time: 6))
        history.observe(snapshot([display(rate: 100)], rates: [60, 100], time: 8))
        XCTAssertEqual(history.events.map(\.kind), [.disconnected, .connected, .capabilities, .mode])
        XCTAssertEqual(history.changeCount, 4)
    }

    func testObservationGapDoesNotBecomeAnApparentContinuousOrHealthyInterval() {
        var history = VideoStabilityHistory()
        history.observe(snapshot([display()]))
        history.observe(snapshot([], time: 2, error: "OS read failed"))
        history.observe(snapshot([], time: 4, error: "OS read failed"))
        history.observe(snapshot([display(rate: 100)], rates: [100], time: 6))
        XCTAssertEqual(history.events.map(\.kind), [.unavailable, .resumed])
        XCTAssertEqual(history.changeCount, 0, "Changes within the observation gap are unknown")
        history.observe(snapshot([], time: 8))
        XCTAssertEqual(history.events.last?.kind, .disconnected)
    }

    func testPartialRegistryReadPreservesExplicitObservationGapAndLinkChangesAreSeparate() {
        var history = VideoStabilityHistory()
        history.observe(snapshot([display()]))
        let incomplete = VideoDiagnosticsSnapshot(checkedAt: Date(timeIntervalSince1970: 2),
            displays: [], links: MacVideoConnectionSnapshot(connections: [],
                outcome: .failed(code: .unavailable, message: "No registry access")), error: nil)
        history.observe(incomplete)
        XCTAssertEqual(history.events.last?.kind, .unavailable)
        history.observe(snapshot([display()], time: 4))
        let port = MacVideoPortState(hostPort: "USB-C@2", transport: .usbc, active: true,
            linkRateDescription: "8.1 Gbps (HBR3)", driverStatus: "Ready", hotPlugStatus: "High", rawLaneCount: 1, rawMaxLaneCount: 4)
        history.observe(snapshot([display()], time: 6, ports: [port]))
        XCTAssertEqual(history.events.last?.kind, .link)
    }

    func testHistoryRemainsBoundedAndDuplicateUUIDsNeverCrashOrChooseTheFirstMonitor() {
        var history = VideoStabilityHistory()
        for index in 0..<151 { history.observe(snapshot([display(), display(5)], rates: index % 2 == 0 ? [60] : [60, 100], time: Double(index))) }
        XCTAssertEqual(history.events.count, 100)
        XCTAssertEqual(history.changeCount, 300)
        XCTAssertNil(snapshot([display(), display(5)]).connection(for: display()))
    }
}
