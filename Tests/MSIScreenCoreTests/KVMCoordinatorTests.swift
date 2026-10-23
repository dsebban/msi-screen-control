import XCTest
@testable import MSIScreenCore

final class KVMCoordinatorTests: XCTestCase {
    let mac = MachineDefinition(id: "local", name: "Mac", platform: .macos, input: .usbc, host: nil)
    let linux = MachineDefinition(id: "linux", name: "Linux", platform: .linux, input: .dp, host: "test-linux")

    func testVideoOnlyLinuxDoesNotReplaceUnassignedSSHUSBHost() throws {
        var savedLinux = linux
        savedLinux.input = nil
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .dp, host: nil, access: .videoOnly)
        let registry = MachineRegistry(machines: [mac, savedLinux, deck], usbUpstreamMachineID: savedLinux.id)
        XCTAssertEqual(try KVMCoordinator(registry: registry).upstreamMachine, savedLinux)
        XCTAssertThrowsError(try KVMCoordinator(registry: registry, upstreamMachineID: deck.id))
        XCTAssertNil(try KVMCoordinator(registry: MachineRegistry(machines: [mac, deck])).upstreamMachine)
    }

    func testSavedUSBUpstreamSurvivesAddingAnotherLinuxSSHMachine() throws {
        let deck = MachineDefinition(id: "deck", name: "Steam Deck", platform: .linux,
                                     input: .hdmi1, host: "deck@steamdeck", sshTransport: .tailscale)
        let registry = MachineRegistry(machines: [mac, linux, deck], usbUpstreamMachineID: linux.id)
        XCTAssertEqual(try KVMCoordinator(registry: registry).upstreamMachine, linux)
        XCTAssertEqual(try KVMCoordinator(registry: registry, upstreamMachineID: deck.id).upstreamMachine, deck)
        var ambiguous = registry
        ambiguous.usbUpstreamMachineID = nil
        XCTAssertNil(try KVMCoordinator(registry: ambiguous).upstreamMachine,
                     "Unassigned USB-B must not adopt a network peer")
    }

    final class Endpoint: KVMEndpoint {
        var values: [KVMSnapshot?]
        var reads = 0
        var writes = 0
        var readError: Error?
        var receipt = KVMWriteReceipt(attempted: true, completed: true, acknowledged: false, error: "Disconnected")
        init(_ routes: [KVMRoute?]) {
            values = routes.map { route in
                route.map { KVMSnapshot(model: "MD342CQP", protocolVersion: "V20", route: $0) }
            }
        }
        func status(timeout: TimeInterval) async throws -> KVMSnapshot? {
            reads += 1
            if let readError { throw readError }
            return values.isEmpty ? nil : values.removeFirst()
        }
        func layout(timeout: TimeInterval) async throws -> ScreenState {
            throw ScreenError.message("No layout fixture")
        }
        func write(target: KVMRoute, expected: KVMRoute, expectedLayout: ScreenState?,
                   checkRegistry: @escaping () throws -> Void) async throws -> KVMWriteReceipt {
            try checkRegistry()
            writes += 1
            return receipt
        }
    }

    func coordinator(_ local: Endpoint, _ remote: Endpoint,
                     check: @escaping () throws -> Void = {}) -> KVMCoordinator {
        KVMCoordinator(registry: MachineRegistry(machines: [mac, linux]), upstreamMachine: linux,
                       local: local, remote: remote, checkRegistry: check, wait: {})
    }

    func testLostAckHandoffVerifiesDestinationWithoutRepeatingWrite() async throws {
        let local = Endpoint([.usbc])
        let remote = Endpoint([nil, .upstream])
        let result = try await coordinator(local, remote).set(target: .upstream, expected: .usbc)
        XCTAssertTrue(result.verified)
        XCTAssertFalse(result.acknowledged)
        XCTAssertEqual(result.after?.route, .upstream)
        XCTAssertEqual(result.after?.controlHost, .upstream)
        XCTAssertEqual(local.writes, 1)
        XCTAssertEqual(remote.writes, 0)
    }

    func testRemoteReturnWorksWithoutLocalController() async throws {
        let local = Endpoint([nil, .usbc])
        let remote = Endpoint([.upstream])
        let result = try await coordinator(local, remote).set(target: .usbc, expected: .upstream)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.after?.controlHost, .local)
        XCTAssertEqual(local.writes, 0)
        XCTAssertEqual(remote.writes, 1)
    }

    func testSenderReadbackCannotSubstituteForReceivingController() async throws {
        let local = Endpoint([.usbc, .upstream])
        let remote = Endpoint([nil, nil])
        let result = try await coordinator(local, remote).set(target: .upstream, expected: .usbc)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.after)
        XCTAssertEqual(local.reads, 1)
        XCTAssertEqual(local.writes, 1)
    }

    func testMissingDestinationRemainsUnverifiedAfterBoundedReads() async throws {
        let local = Endpoint([.usbc])
        let remote = Endpoint([nil])
        let result = try await coordinator(local, remote).set(target: .upstream, expected: .usbc)
        XCTAssertFalse(result.verified)
        XCTAssertNil(result.after)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(local.writes, 1)
        XCTAssertEqual(remote.writes, 0)
        XCTAssertEqual(remote.reads, 7) // One preflight, then six bounded reads.
    }

    func testLocalErrorDoesNotAuthorizeRemoteFallback() async {
        let local = Endpoint([])
        local.readError = ScreenError.message("Unrecognized MSI model")
        let remote = Endpoint([.upstream])
        do { _ = try await coordinator(local, remote).status(); XCTFail("Must fail locally") } catch {}
        XCTAssertEqual(remote.reads, 0)
        XCTAssertEqual(local.writes + remote.writes, 0)
    }

    func testConnectionSnapshotKeepsLocalFailureAndDoesNotProbeAnotherUSBHost() async {
        let local = Endpoint([]); local.readError = ScreenError.message("busy")
        let remote = Endpoint([.upstream])
        let result = await coordinator(local, remote).inspectConnection()
        XCTAssertEqual(result.local.state, .unavailable)
        XCTAssertEqual(result.local.error, "busy")
        XCTAssertEqual(result.upstream.state, .notChecked)
        XCTAssertEqual(remote.reads, 0)
        XCTAssertNil(result.usb)
        XCTAssertEqual(local.writes + remote.writes, 0)
    }

    func testConnectionSnapshotDistinguishesLocalAbsenceFromUpstreamFailure() async {
        let local = Endpoint([nil]), remote = Endpoint([])
        remote.readError = ScreenError.message("SSH unavailable")
        let result = await coordinator(local, remote).inspectConnection()
        XCTAssertEqual(result.local.state, .absent)
        XCTAssertEqual(result.upstream.state, .unavailable)
        XCTAssertEqual(result.upstreamMachineID, linux.id)
        XCTAssertNil(result.layout)
        XCTAssertNil(result.usb)
        XCTAssertEqual(local.writes + remote.writes, 0)
    }

    func testConnectionSnapshotPreservesUSBReadbackWhenLayoutCannotBeRead() async {
        let local = Endpoint([.usbc]), remote = Endpoint([])
        let result = await coordinator(local, remote).inspectConnection()
        XCTAssertEqual(result.local.state, .available)
        XCTAssertEqual(result.usb?.route, .usbc)
        XCTAssertNil(result.layout)
        XCTAssertNotNil(result.layoutError)
        XCTAssertEqual(remote.reads, 0)
        XCTAssertEqual(local.writes + remote.writes, 0)
    }

    func testSSHConnectionFailureIsNotReportedAsMalformedCompanionJSON() {
        let output = ProcessRunner.Output(text: "ssh: connect to host fixture port 22: Operation timed out\n",
                                          exitCode: 255, timedOut: false, truncated: false)
        XCTAssertThrowsError(try RemoteKVMEndpoint.decode(output, action: "status")) {
            XCTAssertTrue($0.localizedDescription.contains("SSH request failed"))
            XCTAssertTrue($0.localizedDescription.contains("Operation timed out"))
            XCTAssertFalse($0.localizedDescription.contains("invalid USB response"))
        }
    }

    func testStaleRouteAndRegistryChangeRejectBeforeWrite() async {
        let local = Endpoint([.usbc])
        let remote = Endpoint([])
        do {
            _ = try await coordinator(local, remote).set(target: .usbc, expected: .upstream)
            XCTFail("Must reject stale expected route")
        } catch {}
        XCTAssertEqual(local.writes + remote.writes, 0)

        let current = Endpoint([.usbc])
        let destination = Endpoint([nil])
        var checks = 0
        let controller = coordinator(current, destination) {
            checks += 1
            if checks == 2 { throw ScreenError.message("Registry changed during preflight") }
        }
        do {
            _ = try await controller.set(target: .upstream, expected: .usbc)
            XCTFail("Must recheck assignments after remote preflight")
        } catch {}
        XCTAssertEqual(current.writes + destination.writes, 0)
    }

    func testDryRunDoesNotDispatchEitherSetter() async throws {
        let local = Endpoint([.usbc])
        let remote = Endpoint([])
        let result = try await coordinator(local, remote).set(target: .upstream, expected: .usbc, dryRun: true)
        XCTAssertTrue(result.dryRun)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.writeAttempted)
        XCTAssertEqual(local.writes + remote.writes, 0)
        XCTAssertEqual(remote.reads, 0)
    }

    func testRejectedRemoteWriteDoesNotBecomeVerifiedByUnrelatedReadback() async throws {
        let local = Endpoint([nil, .usbc])
        let remote = Endpoint([.upstream])
        remote.receipt = KVMWriteReceipt(attempted: false, completed: false, acknowledged: false,
                                        error: "Stale expected route")
        let result = try await coordinator(local, remote).set(target: .usbc, expected: .upstream)
        XCTAssertFalse(result.verified)
        XCTAssertFalse(result.writeAttempted)
        XCTAssertEqual(local.reads, 1)
    }

    func testLegacyDecoderKeepsUnknownFieldAcceptanceButRejectsEscapedDuplicates() throws {
        let json = #"{"schemaVersion":1,"action":"status","present":false,"accessible":false,"writeAttempted":false,"writeCompleted":false,"acknowledged":false,"verified":false,"outcome":"not_present","future":{"field":1}}"#
        func output(_ text: String) -> ProcessRunner.Output {
            ProcessRunner.Output(text: text, exitCode: 0, timedOut: false, truncated: false)
        }
        XCTAssertFalse(try RemoteKVMEndpoint.decode(output(json), action: "status").present)
        let duplicate = json.replacingOccurrences(of: #""present":false"#, with: #""present":false,"pr\u0065sent":true"#)
        XCTAssertThrowsError(try RemoteKVMEndpoint.decode(output(duplicate), action: "status"))
    }

    func testScalarPacketsMatchVendorKVMCommands() throws {
        for (route, command) in [(KVMRoute.upstream, "5b008>0001\r"), (.usbc, "5b008>0002\r")] {
            let expected = [UInt8(1)] + Array(command.utf8)
            XCTAssertEqual(try MSIProtocol.kvm(route),
                           expected + Array(repeating: 0, count: 64 - expected.count))
        }
    }

    func testMalformedRemoteReceiptsCannotHideAttemptedWrite() throws {
        let prefix = #"{"schemaVersion":1,"action":"setKVM","present":true,"accessible":true,"state":{"model":"MD342CQP","protocolVersion":"V20","kvm":"upstream"},"#
        let suffix = #","verified":false,"outcome":"sent"}"#
        for flags in [
            #""writeAttempted":false,"writeAttempted":true,"writeCompleted":true,"acknowledged":false"#,
            #""writeAttempted":false,"writeCompleted":true,"acknowledged":false"#,
            #""writeAttempted":true,"writeCompleted":false,"acknowledged":true"#
        ] {
            let output = ProcessRunner.Output(text: prefix + flags + suffix, exitCode: 0,
                                              timedOut: false, truncated: false)
            XCTAssertThrowsError(try RemoteKVMEndpoint.decode(output, action: "setKVM"))
        }
        let sent = ProcessRunner.Output(
            text: prefix + #""writeAttempted":true,"writeCompleted":true,"acknowledged":false"# + suffix,
            exitCode: 0, timedOut: false, truncated: false)
        XCTAssertTrue(try RemoteKVMEndpoint.decode(sent, action: "setKVM").writeAttempted)
    }
}
