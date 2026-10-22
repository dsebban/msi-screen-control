import XCTest
@testable import MSIScreenCore

final class MachineFocusCoordinatorTests: XCTestCase {
    static let mac = MachineDefinition(id: "mac", name: "Mac", platform: .macos, input: .usbc, host: nil)
    static let linux = MachineDefinition(id: "linux", name: "Linux", platform: .linux, input: .dp, host: "linux")
    static let baseline = ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: .pbp,
                                      source1: .hdmi1, source2: .usbc, pipInput: .usbc,
                                      pipSize: 2, pipPosition: 3)

    final class World {
        var route: KVMRoute = .usbc
        var owner: KVMControlHost = .local
        var state = baseline
        var writes: [KVMRoute] = []
        var events: [String] = []
        var announcedVideo: [Bool] = []
        var layoutReads: [KVMControlHost] = []
        var waited = 0
        var videoCalls = 0
        var failAcquisition = false
        var failFinalHandoff = false
        var failVideo = false
        var failVideoBeforeWrite = false
        var staleBeforeFinalHandoff = false
        var finalExpectedLayout: ScreenState?

        final class Endpoint: KVMEndpoint {
            let world: World
            let host: KVMControlHost
            init(_ world: World, _ host: KVMControlHost) { self.world = world; self.host = host }

            func status(timeout: TimeInterval) async throws -> KVMSnapshot? {
                world.events.append("status-\(host.rawValue)")
                guard world.owner == host else { return nil }
                return KVMSnapshot(model: "MD342CQP", protocolVersion: "V20", route: world.route)
            }

            func layout(timeout: TimeInterval) async throws -> ScreenState {
                world.layoutReads.append(host)
                world.events.append("layout-\(host.rawValue)")
                guard world.owner == host else { throw ScreenError.message("Controller is absent") }
                return world.state
            }

            func write(target: KVMRoute, expected: KVMRoute, expectedLayout: ScreenState?,
                       checkRegistry: @escaping () throws -> Void) async throws -> KVMWriteReceipt {
                try checkRegistry()
                guard world.owner == host, world.route == expected else {
                    throw ScreenError.message("Stale USB route")
                }
                if target == .upstream {
                    world.finalExpectedLayout = expectedLayout
                    if world.staleBeforeFinalHandoff { world.state.source1 = .hdmi2 }
                }
                if let expectedLayout, world.state != expectedLayout {
                    throw ScreenError.message("Stale full layout in setter session")
                }
                if target == .usbc, world.failAcquisition {
                    return KVMWriteReceipt(attempted: false, completed: false, acknowledged: false,
                                           error: "USB acquisition rejected")
                }
                world.events.append("write-\(target.rawValue)")
                world.writes.append(target)
                if target == .upstream, world.failFinalHandoff {
                    return KVMWriteReceipt(attempted: true, completed: false, acknowledged: false,
                                           error: "Uncertain final handoff")
                }
                world.route = target
                world.owner = target == .usbc ? .local : .upstream
                return KVMWriteReceipt(attempted: true, completed: true, acknowledged: false, error: nil)
            }
        }

        final class Video: LayoutVideoEndpoint {
            let world: World
            init(_ world: World) { self.world = world }
            func apply(target: ScreenState, expected: ScreenState,
                       checkRegistry: @escaping () throws -> Void,
                       onWriteAttempt: @escaping () -> Void) async throws -> ScreenState {
                world.videoCalls += 1
                world.events.append("video")
                try checkRegistry()
                guard world.owner == .local, world.route == .usbc, world.state == expected else {
                    throw ScreenError.message("Video ownership or expected layout changed")
                }
                if world.failVideoBeforeWrite { throw ScreenError.message("Video preflight rejected") }
                if target != expected { onWriteAttempt() }
                world.state = target
                if world.failVideo { throw ScreenError.message("Video readback failed after writing") }
                return target
            }
        }

        func kvmCoordinator() -> KVMCoordinator {
            let registry = MachineRegistry(machines: [mac, linux])
            return KVMCoordinator(registry: registry, upstreamMachine: linux,
                                  local: Endpoint(self, .local), remote: Endpoint(self, .upstream),
                                  checkRegistry: {}, wait: { self.waited += 1 },
                                  announce: { self.events.append("announce") })
        }

        func coordinator() -> MachineFocusCoordinator {
            MachineFocusCoordinator(registry: MachineRegistry(machines: [mac, linux]),
                                    kvm: kvmCoordinator(), video: Video(self), checkRegistry: {},
                                    announce: { videoAttempted in
                                        self.announcedVideo.append(videoAttempted)
                                        self.events.append("announce")
                                    })
        }
    }

    func testAlreadyFocusedLinuxReadsRemoteLayoutWithoutUSBMoveOrWait() async throws {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        world.state = ScreenController.fullscreenTarget(from: Self.baseline, input: .dp)
        let result = try await world.coordinator().focus(machineID: "linux")
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertEqual(result.afterUSB?.controlHost, .upstream)
        XCTAssertEqual(result.afterLayout, world.state)
        XCTAssertEqual(world.layoutReads, [.upstream])
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertEqual(world.waited, 0)
        XCTAssertFalse(world.events.contains("announce"))
    }

    func testVideoOnlyAndUnassignedFocusRejectBeforeReadingOrWritingEndpoints() async {
        let world = World()
        var unassigned = Self.linux
        unassigned.input = nil
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .dp, host: nil, access: .videoOnly)
        let registry = MachineRegistry(machines: [Self.mac, unassigned, deck])
        let coordinator = MachineFocusCoordinator(registry: registry, kvm: world.kvmCoordinator(),
                                                  video: World.Video(world), checkRegistry: {})
        for id in [unassigned.id, deck.id] {
            do {
                _ = try await coordinator.focus(machineID: id)
                XCTFail("Focus must reject a machine without video or USB control")
            } catch {}
        }
        XCTAssertTrue(world.events.isEmpty)
        XCTAssertTrue(world.writes.isEmpty)
        XCTAssertEqual(world.videoCalls, 0)
    }

    func testLinuxFocusAppliesPreservedLayoutBeforeGuardedUSBHandoff() async throws {
        let world = World()
        let result = try await world.coordinator().focus(machineID: "linux",
                                                        expectedUSB: .usbc, expectedLayout: Self.baseline)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.videoWriteAttempted)
        XCTAssertTrue(result.videoVerified)
        XCTAssertEqual(world.writes, [.upstream])
        XCTAssertEqual(world.finalExpectedLayout, result.targetLayout)
        XCTAssertEqual(result.afterLayout?.source1, .dp)
        XCTAssertEqual(result.afterLayout?.source2, Self.baseline.source2)
        XCTAssertEqual(result.afterLayout?.pipInput, Self.baseline.pipInput)
        XCTAssertEqual(result.afterLayout?.pipSize, 2)
        XCTAssertEqual(result.afterLayout?.pipPosition, 3)
        XCTAssertLessThan(try XCTUnwrap(world.events.firstIndex(of: "video")),
                          try XCTUnwrap(world.events.firstIndex(of: "write-upstream")))
    }

    func testFocusAnnouncesOnlyAfterFinalLayoutRead() async throws {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        let result = try await world.coordinator().focus(machineID: "linux")
        XCTAssertTrue(result.verified)
        XCTAssertEqual(world.events.filter { $0 == "announce" }.count, 1)
        XCTAssertEqual(world.events.last, "announce")
        XCTAssertEqual(world.events.dropLast().last, "layout-upstream")
        XCTAssertEqual(world.announcedVideo, [true])
    }

    func testStandaloneUSBChangeStillAnnouncesAfterVerification() async throws {
        let world = World()
        let result = try await world.kvmCoordinator().set(target: .upstream, expected: .usbc)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(world.events.filter { $0 == "announce" }.count, 1)
        XCTAssertEqual(world.events.suffix(2), ["status-upstream", "announce"])
    }

    func testVideoOnlyFocusAnnouncesAfterFinalRead() async throws {
        let world = World()
        let result = try await world.coordinator().focus(machineID: "mac")
        XCTAssertTrue(result.verified)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.events.filter { $0 == "announce" }.count, 1)
        XCTAssertEqual(world.events.suffix(2), ["layout-local", "announce"])
        XCTAssertEqual(world.announcedVideo, [true])
    }

    func testVideoPreflightFailureDoesNotAnnounceUnsentChanges() async throws {
        let world = World()
        world.failVideoBeforeWrite = true
        let result = try await world.coordinator().focus(machineID: "mac")
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoWriteAttempted) // Conservative public stage receipt.
        XCTAssertEqual(world.state, Self.baseline)
        XCTAssertFalse(world.events.contains("announce"))
    }

    func testUSBOnlyFocusAnnouncesWithoutInventingVideoChange() async throws {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        world.state = ScreenController.fullscreenTarget(from: Self.baseline, input: .usbc)
        let result = try await world.coordinator().focus(machineID: "mac")
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.videoWriteAttempted)
        XCTAssertEqual(world.writes, [.usbc])
        XCTAssertEqual(world.events.filter { $0 == "announce" }.count, 1)
        XCTAssertEqual(world.events.suffix(2), ["layout-local", "announce"])
        XCTAssertEqual(world.announcedVideo, [false])
    }

    func testAutoIsPinnedToUSBCEvenWhenControllerAlreadyLocal() async throws {
        let world = World()
        world.route = .auto
        let result = try await world.coordinator().focus(machineID: "mac")
        XCTAssertTrue(result.verified)
        XCTAssertEqual(world.writes, [.usbc])
        XCTAssertLessThan(try XCTUnwrap(world.events.firstIndex(of: "write-usbc")),
                          try XCTUnwrap(world.events.firstIndex(of: "video")))
        XCTAssertEqual(result.afterLayout?.source1, .usbc)
    }

    func testStaleVideoInFinalSetterPreventsUSBHandoff() async throws {
        let world = World()
        world.staleBeforeFinalHandoff = true
        let result = try await world.coordinator().focus(machineID: "linux")
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoWriteAttempted)
        XCTAssertTrue(result.videoVerified) // Completed local stage, not final focus.
        XCTAssertNil(result.afterLayout)
        XCTAssertEqual(world.finalExpectedLayout, result.targetLayout)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.route, .usbc)
        XCTAssertTrue(result.error?.contains("Stale full layout") == true)
    }

    func testFailedAcquisitionStopsBeforeVideo() async throws {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        world.failAcquisition = true
        let result = try await world.coordinator().focus(machineID: "mac")
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.videoWriteAttempted)
        XCTAssertEqual(result.usbChanges.count, 1)
        XCTAssertFalse(result.usbChanges[0].verified)
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertEqual(world.writes, [])
        XCTAssertFalse(world.events.contains("announce"))
    }

    func testFailedVideoRetainsAcquisitionAndNeverHandsOffAgain() async throws {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        world.failVideo = true
        let result = try await world.coordinator().focus(machineID: "linux")
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoWriteAttempted)
        XCTAssertFalse(result.videoVerified)
        XCTAssertNil(result.afterLayout)
        XCTAssertEqual(world.writes, [.usbc])
        XCTAssertEqual(result.usbChanges.count, 1)
        XCTAssertTrue(result.usbChanges[0].verified)
        XCTAssertEqual(result.afterUSB?.route, .usbc)
        XCTAssertEqual(world.events.filter { $0 == "announce" }.count, 1)
        XCTAssertEqual(world.events.suffix(2), ["video", "announce"])
        XCTAssertEqual(world.announcedVideo, [true])
    }

    func testUnverifiedFinalHandoffReportsPartialVideoAndSingleWrite() async throws {
        let world = World()
        world.failFinalHandoff = true
        let result = try await world.coordinator().focus(machineID: "linux")
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertTrue(result.videoWriteAttempted)
        XCTAssertNil(result.afterUSB)
        XCTAssertNil(result.afterLayout)
        XCTAssertEqual(world.writes, [.upstream])
        XCTAssertEqual(result.usbChanges.count, 1)
        XCTAssertTrue(result.usbChanges[0].writeAttempted)
        XCTAssertFalse(result.usbChanges[0].verified)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(world.events.filter { $0 == "announce" }.count, 1)
        XCTAssertEqual(world.events.last, "announce")
    }

    func testDryRunReadsLinuxAndPlansWithoutAnyWrite() async throws {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        let result = try await world.coordinator().focus(machineID: "mac", dryRun: true)
        XCTAssertTrue(result.dryRun)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.beforeLayout, Self.baseline)
        XCTAssertEqual(result.targetLayout?.source1, .usbc)
        XCTAssertEqual(world.layoutReads, [.upstream])
        XCTAssertNil(result.afterLayout)
        XCTAssertNil(result.afterUSB)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertEqual(world.waited, 0)
        XCTAssertFalse(world.events.contains("announce"))
    }

    func testStaleExpectedSnapshotsNeverAcquireUSBOrWriteVideo() async throws {
        let world = World()
        let badUSB = try await world.coordinator().focus(machineID: "linux", expectedUSB: .upstream)
        XCTAssertFalse(badUSB.verified)
        XCTAssertNotNil(badUSB.error)
        var changed = Self.baseline
        changed.source1 = .dp
        let badLayout = try await world.coordinator().focus(machineID: "linux", expectedLayout: changed)
        XCTAssertFalse(badLayout.verified)
        XCTAssertNotNil(badLayout.error)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertFalse(world.events.contains("announce"))
    }

    func testRemoteLayoutDecoderRejectsUnsupportedOrAmbiguousState() throws {
        let valid = #"{"schemaVersion":1,"action":"layout","model":"MD342CQP","protocolVersion":"V20","layout":{"model":"MD342CQP","protocolVersion":"V20","mode":"pbp","source1":"hdmi1","source2":"usbc","pipInput":"usbc","pipSize":2,"pipPosition":3}}"#
        func output(_ text: String) -> ProcessRunner.Output {
            ProcessRunner.Output(text: text, exitCode: 0, timedOut: false, truncated: false)
        }
        XCTAssertEqual(try RemoteKVMEndpoint.decodeLayout(output(valid)), Self.baseline)
        for invalid in [
            valid.replacingOccurrences(of: #""pipSize":2"#, with: #""pipSize":3"#),
            valid.replacingOccurrences(of: #""pipPosition":3"#, with: #""pipPosition":-1"#),
            valid.replacingOccurrences(of: #""mode":"pbp""#, with: #""mode":"other""#),
            valid.replacingOccurrences(of: #""source1":"hdmi1""#, with: #""source1":"other""#),
            valid.replacingOccurrences(of: #""model":"MD342CQP""#, with: #""model":"OTHER""#),
            valid.replacingOccurrences(of: #""pipSize":2"#, with: #""pipSize":0,"pipSize":2"#),
            valid.replacingOccurrences(of: #""pipSize":2"#, with: #""pip\u0053ize":0,"pipSize":2"#),
            valid.replacingOccurrences(of: #""action":"layout""#, with: #""action":"layout","writeAttempted":true"#)
        ] {
            XCTAssertThrowsError(try RemoteKVMEndpoint.decodeLayout(output(invalid)))
        }
    }

    func testCanceledVideoStageStopsAfterStaleReadBeforeHIDWrite() throws {
        let transport = NoOpLayoutTests.Transport()
        let controller = ScreenController(transport: transport)
        let before = try controller.state()
        transport.queryCount = 0
        let target = ScreenController.fullscreenTarget(from: before, input: .dp)
        XCTAssertThrowsError(try controller.apply(target, from: before) {
            XCTAssertEqual(transport.queryCount, 8)
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(transport.writeCount, 0)
    }
}
