import XCTest
@testable import MSIScreenCore
@testable import MSIScreenMenu

final class TailnetMachineMatchTests: XCTestCase {
    private func peer(_ id: String, dns: String, host: String = "duplicate", address: String = "100.64.0.2", isSelf: Bool = false) -> TailnetPeer {
        .init(id: id, name: "Display label", hostName: host, dnsName: dns, operatingSystem: .linux,
              rawOperatingSystem: "linux", isSelf: isSelf, advertisedOnline: true, addresses: [address])
    }
    private func machine(_ host: String) -> MachineDefinition {
        .init(id: "saved", name: "Display label", platform: .linux, input: .dp, host: host)
    }
    func testUniqueExactDNSWinsWhileAmbiguousShortNameNeverMatches() {
        let first = peer("a", dns: "one.example.ts.net")
        let second = peer("b", dns: "two.example.ts.net")
        XCTAssertNil(TailnetMachineMatch.machine(for: first, peers: [first, second], machines: [machine("deck@duplicate")]))
        XCTAssertEqual(TailnetMachineMatch.machine(for: first, peers: [first, second], machines: [machine("deck@ONE.EXAMPLE.TS.NET.")],
                                                  resolvedHosts: ["saved": "ONE.EXAMPLE.TS.NET."])?.id, "saved")
        XCTAssertNil(TailnetMachineMatch.machine(for: first, peers: [first, second], machines: [machine("unrelated-alias")]))
    }
    func testIPv6UsesCanonicalAddressAndDoesNotMatchDisplayLabel() {
        let node = peer("a", dns: "one.example.ts.net", address: "fd7a:115c:a1e0::2")
        XCTAssertNotNil(TailnetMachineMatch.machine(for: node, peers: [node], machines: [machine("deck@FD7A:115C:A1E0:0:0:0:0:2")],
                                                    resolvedHosts: ["saved": "FD7A:115C:A1E0:0:0:0:0:2"]))
        XCTAssertNil(TailnetMachineMatch.machine(for: node, peers: [node], machines: [machine("Display-label")]))
    }
    func testSelfMatchesOnlyExplicitLocalMachine() {
        let local = MachineDefinition(id: "local", name: "This Mac", platform: .macos, input: .usbc, host: nil)
        let node = peer("self", dns: "self.example.ts.net", isSelf: true)
        XCTAssertEqual(TailnetMachineMatch.machine(for: node, peers: [node], machines: [machine("self.example.ts.net"), local])?.id, "local")
    }

    func testShortOpenSSHAliasDoesNotAdoptATailscaleNode() {
        let node = peer("deck", dns: "steamdeck.example.ts.net", host: "steamdeck")
        var saved = machine("deck@steamdeck")
        XCTAssertNil(TailnetMachineMatch.machine(for: node, peers: [node], machines: [saved]))
        saved.sshTransport = .tailscale
        XCTAssertEqual(TailnetMachineMatch.machine(for: node, peers: [node], machines: [saved])?.id, "saved")
    }

    func testResolvedAliasMatchesExactAddressAndKeepsSavedDefinition() {
        let node = peer("chimera", dns: "chimera.example.ts.net", address: "100.64.0.2")
        var saved = machine("gamer@configured-alias")
        saved.input = .hdmi2
        let match = TailnetMachineMatch.machine(for: node, peers: [node], machines: [saved],
                                                resolvedHosts: [saved.id: "100.64.0.2"])
        XCTAssertEqual(match, saved)
        XCTAssertEqual(match?.input, .hdmi2)
        XCTAssertEqual(match?.host, "gamer@configured-alias")
    }

    func testResolvedRedirectOverridesOriginalExactTargetAndFailureDoesNotFallback() {
        let original = peer("original", dns: "original.example.ts.net", address: "100.64.0.1")
        let destination = peer("destination", dns: "destination.example.ts.net", address: "100.64.0.2")
        let saved = machine("original.example.ts.net")
        let peers = [original, destination]
        XCTAssertNil(TailnetMachineMatch.machine(for: original, peers: peers, machines: [saved]))
        XCTAssertNil(TailnetMachineMatch.machine(for: original, peers: peers, machines: [saved],
                                                resolvedHosts: [saved.id: "100.64.0.2"]))
        XCTAssertEqual(TailnetMachineMatch.machine(for: destination, peers: peers, machines: [saved],
                                                  resolvedHosts: [saved.id: "100.64.0.2"]), saved)
        XCTAssertNil(TailnetMachineMatch.machine(for: original, peers: peers, machines: [saved],
                                                resolvedHosts: [saved.id: "unrelated.example.net"]))
    }

    @MainActor
    func testDefinitionChangeDiscardsInFlightAliasResolution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = MachineRegistryStore(url: directory.appendingPathComponent("machines.json"))
        let saved = machine("configured-alias")
        try registry.save(MachineRegistry(machines: [saved]), replacing: MachineRegistry())
        let preferences = MonitorPreferences(registryStore: registry)
        let snapshot = TailnetDiscoverySnapshot(checkedAt: Date(), outcome: .complete, backendState: "Running",
                                               peers: [], issues: [])
        var continuation: CheckedContinuation<String?, Never>?
        let store = ComputersStore(preferences: preferences, discoverTailnet: { snapshot }, resolveSSHHost: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        store.refreshTailnet()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        guard let pending = continuation else { return XCTFail("Resolver did not start") }
        var changed = saved
        changed.host = "new-alias"
        try preferences.saveMachine(changed, replacing: saved)
        pending.resume(returning: "100.64.0.2")
        for _ in 0..<100 where store.discoveringTailnet { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(store.discoveringTailnet)
        XCTAssertTrue(store.resolvedHosts.isEmpty)
    }
}
