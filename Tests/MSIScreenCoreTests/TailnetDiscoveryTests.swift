import XCTest
@testable import MSIScreenCore

final class TailnetDiscoveryTests: XCTestCase {
    private func node(_ id: String, os: String = "linux", online: Bool = true) -> [String: Any] {
        ["ID": id, "HostName": "Host \(id)", "DNSName": "\(id).example.ts.net.",
         "OS": os, "Online": online, "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"]]
    }

    private func fixture(_ peers: [String: Any] = [:], backend: String = "Running") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["BackendState": backend,
            "Self": node("self", os: "macOS"), "Peer": peers])
    }

    private func output(_ data: Data = Data(), termination: ProcessRunner.Termination = .exited,
                        code: Int32 = 0) -> ProcessRunner.StructuredOutput {
        .init(stdout: data, stderr: Data("warning: different CLI version".utf8), termination: termination,
              exitCode: code, signal: nil, processID: 1, cleanupConfirmed: true)
    }

    func testStableIDsAllPlatformsAndOfflineNodesSurviveDiscovery() throws {
        let date = Date(timeIntervalSince1970: 123)
        let peers: [String: Any] = ["nodekey:old-a": node("linux"),
            "nodekey:b": node("phone", os: "iOS", online: false),
            "nodekey:c": node("pc", os: "windows"), "nodekey:d": node("other", os: "futureOS")]
        let snapshot = try TailnetDiscoveryClient.parse(fixture(peers), checkedAt: date)
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.checkedAt, date)
        XCTAssertEqual(snapshot.peers.count, 5)
        XCTAssertEqual(snapshot.peers.first?.id, "self")
        XCTAssertTrue(snapshot.peers.first?.isSelf == true)
        let phone = try XCTUnwrap(snapshot.peers.first { $0.id == "phone" })
        XCTAssertEqual(phone.operatingSystem, .ios)
        XCTAssertEqual(phone.advertisedOnline, false)
        XCTAssertEqual(phone.dnsName, "phone.example.ts.net")
        XCTAssertEqual(phone.sshHostCandidate, "phone.example.ts.net")
        XCTAssertEqual(snapshot.peers.first { $0.id == "other" }?.rawOperatingSystem, "futureOS")
        XCTAssertEqual(snapshot.peers.first { $0.id == "other" }?.operatingSystem, .other)
        var changedKey = peers
        changedKey["nodekey:new-a"] = changedKey.removeValue(forKey: "nodekey:old-a")
        XCTAssertEqual(try TailnetDiscoveryClient.parse(fixture(changedKey), checkedAt: date), snapshot,
                       "Node-key rotation must not change stable identity")
    }

    func testInvalidFieldsStayIncompleteAndCannotBecomeConnectionArguments() throws {
        var unsafe = node("unsafe")
        unsafe["HostName"] = "Injected\nname"
        unsafe["DNSName"] = "-oProxyCommand=bad"
        unsafe["TailscaleIPs"] = ["100.64.0.2;bad", "::1%scope", "--option"]
        unsafe["Online"] = 1
        let snapshot = try TailnetDiscoveryClient.parse(fixture(["nodekey:x": unsafe]))
        XCTAssertEqual(snapshot.outcome, .incomplete)
        let peer = try XCTUnwrap(snapshot.peers.first { $0.id == "unsafe" })
        XCTAssertEqual(peer.name, peer.id)
        XCTAssertNil(peer.hostName)
        XCTAssertNil(peer.dnsName)
        XCTAssertNil(peer.advertisedOnline, "JSON numbers are not advertised booleans")
        XCTAssertNil(peer.sshHostCandidate)
        XCTAssertTrue(peer.addresses.isEmpty)
        XCTAssertTrue(snapshot.issues.contains { $0.code == .invalidPeerField && $0.peerID == peer.id })
    }

    func testMissingMagicDNSUsesCanonicalAddressAndRepeatedIdentityIsNotDuplicated() throws {
        var peer = node("remote")
        peer["DNSName"] = ""
        peer["TailscaleIPs"] = ["FD7A:115C:A1E0:0:0:0:0:2", "fd7a:115c:a1e0::2"]
        let snapshot = try TailnetDiscoveryClient.parse(fixture(["nodekey:a": peer, "nodekey:b": peer]))
        XCTAssertEqual(snapshot.outcome, .incomplete)
        XCTAssertEqual(snapshot.peers.filter { $0.id == "remote" }.count, 1)
        let remote = try XCTUnwrap(snapshot.peers.first { $0.id == "remote" })
        XCTAssertEqual(remote.addresses, ["fd7a:115c:a1e0::2"])
        XCTAssertEqual(remote.sshHostCandidate, "fd7a:115c:a1e0::2")
        XCTAssertTrue(snapshot.issues.contains { $0.code == .duplicatePeer })
    }

    func testStoppedMissingAndMalformedListsNeverClaimSuccessfulEmptyDiscovery() throws {
        XCTAssertEqual(try TailnetDiscoveryClient.parse(fixture(backend: "Stopped")).outcome, .incomplete)
        let missing = try TailnetDiscoveryClient.parse(Data(#"{"BackendState":"Running"}"#.utf8))
        XCTAssertEqual(missing.outcome, .incomplete)
        XCTAssertTrue(missing.issues.contains { $0.code == .missingSelf })
        XCTAssertTrue(missing.issues.contains { $0.code == .missingPeers })
        let malformedNode = try TailnetDiscoveryClient.parse(fixture(["nodekey:x": ["ID": "--invalid id"]]))
        XCTAssertEqual(malformedNode.outcome, .incomplete)
        XCTAssertEqual(malformedNode.peers.map(\.id), ["self"])
        XCTAssertThrowsError(try TailnetDiscoveryClient.parse(Data(#"{"Peer":{},"Peer":{}}"#.utf8)))
        XCTAssertThrowsError(try TailnetDiscoveryClient.parse(Data("not JSON".utf8)))
        XCTAssertThrowsError(try TailnetDiscoveryClient.parse(Data(repeating: 32, count: TailnetDiscoveryClient.outputLimit + 1)))
    }

    func testNodeCountLimitIsReportedWithoutClaimingCompleteList() throws {
        let peers = Dictionary(uniqueKeysWithValues: (0...TailnetDiscoveryClient.peerLimit).map {
            ("nodekey:\($0)", node("peer\($0)"))
        })
        let snapshot = try TailnetDiscoveryClient.parse(fixture(peers))
        XCTAssertEqual(snapshot.outcome, .incomplete)
        XCTAssertEqual(snapshot.peers.count, TailnetDiscoveryClient.peerLimit + 1)
        XCTAssertTrue(snapshot.issues.contains { $0.code == .tooManyPeers })
    }

    func testInstalledClientFallbackUsesBoundedStatusOnlyAndIgnoresStderrWarning() async throws {
        var calls: [ProcessRunner.Specification] = []
        let data = try fixture(["nodekey:x": node("remote")])
        let client = TailnetDiscoveryClient(executables: [URL(fileURLWithPath: "/fixture/old-tailscale"),
                                                        URL(fileURLWithPath: "/fixture/Tailscale")]) { spec in
            calls.append(spec)
            return calls.count == 1 ? self.output(code: 1) : self.output(data)
        }
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(calls.map(\.arguments), [["status", "--json"], ["status", "--json"]])
        XCTAssertTrue(calls.allSatisfy { $0.timeout <= 4 && $0.stdoutLimit == TailnetDiscoveryClient.outputLimit && $0.stderrLimit == 8_192 })
        XCTAssertEqual(snapshot.peers.count, 2)
    }

    func testUnavailableTimeoutTruncationAndBadJSONAreExplicitFailures() async {
        let absent = await TailnetDiscoveryClient(executables: []) { _ in
            XCTFail("Missing installation must not invoke a process")
            return self.output()
        }.snapshot()
        XCTAssertEqual(absent.outcome, .unavailable)
        let binary = URL(fileURLWithPath: "/fixture/tailscale")
        for (termination, expected) in [(ProcessRunner.Termination.timedOut, TailnetDiscoveryIssue.Code.commandTimedOut),
                                        (.outputLimitExceeded, .outputLimitExceeded)] {
            let failed = await TailnetDiscoveryClient(executables: [binary]) { _ in
                self.output(termination: termination)
            }.snapshot()
            XCTAssertEqual(failed.outcome, .failed)
            XCTAssertEqual(failed.issues.first?.code, expected)
        }
        let malformed = await TailnetDiscoveryClient(executables: [binary]) { _ in
            self.output(Data("bad JSON".utf8))
        }.snapshot()
        XCTAssertEqual(malformed.outcome, .failed)
        XCTAssertEqual(malformed.issues.first?.code, .invalidJSON)
    }
}
