import XCTest
@testable import MSIScreenCore

final class LayoutCoordinatorTests: XCTestCase {
    typealias World = MachineFocusCoordinatorTests.World
    static let baseline = MachineFocusCoordinatorTests.baseline
    static var target: ScreenState {
        ScreenController.fullscreenTarget(from: baseline, input: .dp)
    }

    private func coordinator(_ world: World, checkRegistry: @escaping () throws -> Void = {}) -> LayoutCoordinator {
        LayoutCoordinator(kvm: world.kvmCoordinator(), video: World.Video(world), checkRegistry: checkRegistry,
                          announce: { video in
            world.announcedVideo.append(video)
            world.events.append("announce")
        })
    }
    private func remote() -> World {
        let world = World()
        world.owner = .upstream
        world.route = .upstream
        return world
    }

    func testRemoteVideoChangeReturnsUSBAndPreservesFullRequestedLayout() async throws {
        let world = remote()
        world.state = Self.target
        let result = try await coordinator(world).apply(Self.baseline, from: Self.target, expectedUSB: .upstream)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertEqual(world.writes, [.usbc, .upstream])
        XCTAssertEqual(result.afterUSB?.controlHost, .upstream)
        XCTAssertEqual(result.afterUSB?.route, .upstream)
        XCTAssertEqual(result.afterLayout, Self.baseline)
        XCTAssertEqual(world.finalExpectedLayout, Self.baseline)
        XCTAssertEqual(result.afterLayout?.pipSize, 2)
        XCTAssertEqual(result.afterLayout?.pipPosition, 3)
        XCTAssertEqual(world.events.last, "announce")
        XCTAssertEqual(world.events.dropLast().last, "status-upstream")
        XCTAssertEqual(world.announcedVideo, [true])
    }

    func testRemoteNoopAndDryRunNeverAcquireUSBOrWait() async throws {
        let world = remote()
        let noop = try await coordinator(world).apply(Self.baseline, from: Self.baseline)
        XCTAssertTrue(noop.verified)
        XCTAssertTrue(noop.videoVerified)
        XCTAssertFalse(noop.videoWriteAttempted)
        let dry = try await coordinator(world).apply(Self.target, from: Self.baseline, dryRun: true)
        XCTAssertFalse(dry.verified)
        XCTAssertNil(dry.afterUSB)
        XCTAssertNil(dry.afterLayout)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertEqual(world.waited, 0)
        XCTAssertEqual(world.announcedVideo, [])
    }

    func testStalePlanAndAutoMutationNeverMoveUSB() async throws {
        let world = remote()
        let stale = try await coordinator(world).apply(Self.target, from: Self.target)
        XCTAssertFalse(stale.verified)
        XCTAssertNotNil(stale.error)
        let staleUSB = try await coordinator(world).apply(Self.target, from: Self.baseline, expectedUSB: .usbc)
        XCTAssertFalse(staleUSB.verified)
        XCTAssertNil(staleUSB.beforeLayout)
        world.route = .auto
        let auto = try await coordinator(world).apply(Self.target, from: Self.baseline)
        XCTAssertFalse(auto.verified)
        XCTAssertTrue(auto.error?.contains("explicitly") == true)
        let autoNoop = try await coordinator(world).apply(Self.baseline, from: Self.baseline)
        XCTAssertTrue(autoNoop.verified)
        XCTAssertEqual(world.route, .auto)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.videoCalls, 0)
    }

    func testInvalidTargetThrowsBeforeAnyStatusReadOrAcquisition() async {
        let world = remote()
        var invalid = Self.baseline
        invalid.source2 = invalid.source1
        do {
            _ = try await coordinator(world).apply(invalid, from: Self.baseline)
            XCTFail("Expected invalid target rejection")
        } catch {}
        XCTAssertEqual(world.events, [])
    }

    func testFailedAcquisitionStopsBeforeVideoAndEmitsNoMutationNotice() async throws {
        let world = remote()
        world.failAcquisition = true
        let result = try await coordinator(world).apply(Self.target, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.videoWriteAttempted)
        XCTAssertEqual(result.usbChanges.count, 1)
        XCTAssertFalse(result.usbChanges[0].writeAttempted)
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.announcedVideo, [])
    }

    func testVideoFailureLeavesAcquiredUSBAndReportsAttemptWithoutRollback() async throws {
        let world = remote()
        world.failVideo = true
        let result = try await coordinator(world).apply(Self.target, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoWriteAttempted)
        XCTAssertFalse(result.videoVerified)
        XCTAssertNil(result.afterLayout)
        XCTAssertEqual(result.afterUSB?.route, .usbc)
        XCTAssertEqual(world.writes, [.usbc])
        XCTAssertEqual(world.announcedVideo, [true])
    }

    func testChangedLayoutPreventsReturnUSBInActualSetterSession() async throws {
        let world = remote()
        world.staleBeforeFinalHandoff = true
        let result = try await coordinator(world).apply(Self.target, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertNil(result.afterLayout)
        XCTAssertEqual(world.writes, [.usbc])
        XCTAssertEqual(result.afterUSB?.route, .usbc)
        XCTAssertEqual(world.finalExpectedLayout, Self.target)
    }

    func testUncertainReturnKeepsBothReceiptsAndVerifiedVideoStage() async throws {
        let world = remote()
        world.failFinalHandoff = true
        let result = try await coordinator(world).apply(Self.target, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertNil(result.afterLayout)
        XCTAssertNil(result.afterUSB)
        XCTAssertEqual(result.usbChanges.count, 2)
        XCTAssertTrue(result.usbChanges[0].verified)
        XCTAssertTrue(result.usbChanges[1].writeAttempted)
        XCTAssertFalse(result.usbChanges[1].verified)
        XCTAssertEqual(world.writes, [.usbc, .upstream])
        XCTAssertEqual(world.announcedVideo, [true])
    }

    func testLocalLayoutNeedsNoConfiguredLinuxOrUSBSetter() async throws {
        let world = World()
        let kvm = KVMCoordinator(registry: MachineRegistry(machines: [MachineFocusCoordinatorTests.mac]),
                                 upstreamMachine: nil, local: World.Endpoint(world, .local), remote: nil,
                                 checkRegistry: {}, wait: { world.waited += 1 })
        let coordinator = LayoutCoordinator(kvm: kvm, video: World.Video(world), checkRegistry: {})
        let result = try await coordinator.apply(Self.target, from: Self.baseline)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.afterUSB?.route, .usbc)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.waited, 0)
    }

    func testCancellationAfterAcquisitionStopsInPlaceAndAnnouncesUSBOnly() async throws {
        let world = remote()
        let coordinator = coordinator(world) {
            if !world.writes.isEmpty { throw CancellationError() }
        }
        let result = try await coordinator.apply(Self.target, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.videoWriteAttempted)
        XCTAssertEqual(result.afterUSB?.route, .usbc)
        XCTAssertEqual(world.writes, [.usbc])
        XCTAssertEqual(world.videoCalls, 0)
        XCTAssertEqual(world.announcedVideo, [false])
    }

    private final class RouteChangingEndpoint: KVMEndpoint {
        let world: World
        let wrapped: World.Endpoint
        let changeAfterReads: Int
        init(_ world: World, changeAfterReads: Int = 2) {
            self.world = world
            self.changeAfterReads = changeAfterReads
            wrapped = World.Endpoint(world, .upstream)
        }
        func status(timeout: TimeInterval) async throws -> KVMSnapshot? {
            try await wrapped.status(timeout: timeout)
        }
        func layout(timeout: TimeInterval) async throws -> ScreenState {
            let state = try await wrapped.layout(timeout: timeout)
            // The initial layout read is first; change only during final read.
            if world.layoutReads.count >= changeAfterReads { world.route = .auto }
            return state
        }
        func write(target: KVMRoute, expected: KVMRoute, expectedLayout: ScreenState?,
                   checkRegistry: @escaping () throws -> Void) async throws -> KVMWriteReceipt {
            try await wrapped.write(target: target, expected: expected, expectedLayout: expectedLayout,
                                    checkRegistry: checkRegistry)
        }
    }

    func testRouteChangeDuringFinalLayoutReadCannotClaimPreservedUSB() async throws {
        let world = remote()
        let kvm = KVMCoordinator(
            registry: MachineRegistry(machines: [MachineFocusCoordinatorTests.mac, MachineFocusCoordinatorTests.linux]),
            upstreamMachine: MachineFocusCoordinatorTests.linux,
            local: World.Endpoint(world, .local), remote: RouteChangingEndpoint(world),
            checkRegistry: {}, wait: {})
        let coordinator = LayoutCoordinator(kvm: kvm, video: World.Video(world), checkRegistry: {})
        let result = try await coordinator.apply(Self.target, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertEqual(result.afterLayout, Self.target)
        XCTAssertEqual(result.afterUSB?.route, .auto)
        XCTAssertEqual(world.writes, [.usbc, .upstream])
        XCTAssertTrue(result.error?.contains("during the final layout check") == true)
    }

    func testRouteChangeDuringNoopReadReturnsFreshUSBWithoutWriting() async throws {
        let world = remote()
        let kvm = KVMCoordinator(
            registry: MachineRegistry(machines: [MachineFocusCoordinatorTests.mac, MachineFocusCoordinatorTests.linux]),
            upstreamMachine: MachineFocusCoordinatorTests.linux,
            local: World.Endpoint(world, .local), remote: RouteChangingEndpoint(world, changeAfterReads: 1),
            checkRegistry: {}, wait: {})
        let coordinator = LayoutCoordinator(kvm: kvm, video: World.Video(world), checkRegistry: {})
        let result = try await coordinator.apply(Self.baseline, from: Self.baseline)
        XCTAssertFalse(result.verified)
        XCTAssertTrue(result.videoVerified)
        XCTAssertEqual(result.afterUSB?.route, .auto)
        XCTAssertEqual(world.writes, [])
        XCTAssertEqual(world.videoCalls, 0)
    }
}
