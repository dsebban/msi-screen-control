import Foundation
import XCTest
@testable import MSIScreenCore

final class USBPeripheralTests: XCTestCase {
    func testMetadataAcceptsOnlyRequestedReceiverRegisterAndOmitsPrivateFields() throws {
        var pairing: [UInt8] = [0x11, 0xff, 0x83, 0xb5, 0x51, 1, 0x85, 0xb3] + Array(repeating: 0xaa, count: 12)
        XCTAssertEqual(try BoltPeripheralProtocol.decode(pairing, for: .pairing(1)),
                       .pairing(.keyboard, productID: "B385"))
        XCTAssertNil(try BoltPeripheralProtocol.decode(pairing, for: .pairing(2)))
        pairing[1] = 1
        XCTAssertNil(try BoltPeripheralProtocol.decode(pairing, for: .pairing(1)))
        let keyReport: [UInt8] = [1, 0, 4, 5, 0, 0, 0]
        XCTAssertNil(try BoltPeripheralProtocol.decode(keyReport, for: .pairing(1)))
        var name: [UInt8] = [0x11, 0xff, 0x83, 0xb5, 0x61, 1, 8] + Array("POP Keys".utf8) + Array(repeating: 0xaa, count: 5)
        XCTAssertEqual(try BoltPeripheralProtocol.decode(name, for: .name(1)), .name("POP Keys", truncated: false))
        name[5] = 2
        XCTAssertNil(try BoltPeripheralProtocol.decode(name, for: .name(1)))
    }

    func testPingNeedsSlotFunctionSoftwareIDAndFreshEcho() throws {
        let request = BoltReadRequest.ping(1, softwareID: 0x0b, mark: 0x79)
        let reply: [UInt8] = [0x10, 1, 0, 0x1b, 2, 0, 0x79]
        XCTAssertEqual(try BoltPeripheralProtocol.decode(reply, for: request), .pong("2.0"))
        XCTAssertNil(try BoltPeripheralProtocol.decode([UInt8(0x11)] + reply.dropFirst(), for: request))
        XCTAssertNil(try BoltPeripheralProtocol.decode(reply + Array(repeating: UInt8(0), count: 13), for: request))
        for (index, different) in [(1, UInt8(2)), (2, 1), (3, 0x1c), (6, 0x78)] {
            var stale = reply
            stale[index] = different
            XCTAssertNil(try BoltPeripheralProtocol.decode(stale, for: request))
        }
        let asleep: [UInt8] = [0x10, 1, 0x8f, 0, 0x1b, 9, 0]
        XCTAssertEqual(try BoltPeripheralProtocol.decode(asleep, for: request), .pingError(9))
        XCTAssertNil(try BoltPeripheralProtocol.decode(asleep, for: .ping(2, softwareID: 0x0b, mark: 0x79)))
    }

    func testKnownPairingSurvivesRadioFailureWithoutClaimingBluetoothOrUnpaired() {
        enum FixtureError: Error { case disconnected }
        var count = 0
        let failed = BoltPeripheralProtocol.readDevices { request in
            count += 1
            switch request {
            case .pairing: return .pairing(.keyboard, productID: "B385")
            case .name: return .name("POP Keys", truncated: false)
            case .ping: throw FixtureError.disconnected
            case .feature: XCTFail("Inventory must not query feature details"); return nil
            }
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(failed.devices.first?.name, "POP Keys")
        XCTAssertEqual(failed.devices.first?.radio, .unavailable)
        XCTAssertNil(failed.devices.first?.protocolVersion)
        XCTAssertNotNil(failed.error)
        let asleep = BoltPeripheralProtocol.readDevices { request in
            switch request {
            case .pairing(let slot): return slot == 1 ? .pairing(.keyboard, productID: "B385") : .receiverError(2)
            case .name: return .name("POP Keys", truncated: false)
            case .ping: return .pingError(9)
            case .feature: XCTFail("Inventory must not query feature details"); return nil
            }
        }
        XCTAssertEqual(asleep.devices.first?.radio, .notResponding)
        XCTAssertNil(asleep.devices.first?.protocolVersion)
        XCTAssertEqual(asleep.devices.first?.name, "POP Keys")
    }

    func testMetadataTimeoutStopsBeforeAnotherAmbiguousRegisterRequest() {
        var calls = 0
        let result = BoltPeripheralProtocol.readDevices { _ in
            calls += 1
            return nil
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(result.devices.isEmpty)
        XCTAssertNotNil(result.error)
    }

    func testTopologyIncludesNestedMonitorHubsButNotSharedHostRoot() throws {
        func device(_ id: UInt64, _ parent: UInt64?, _ vendor: Int, _ product: Int, hub: Bool = false, root: Bool = false) -> PeripheralUSBDevice {
            PeripheralUSBDevice(id: id, parentID: parent, vendor: vendor, product: product, deviceClass: hub ? 9 : 0, rootHub: root)
        }
        let root = device(1, nil, 1, 1, hub: true, root: true)
        let hub = device(2, 1, 0x2109, 0x2817, hub: true)
        let controller = device(3, 2, 0x1462, 0x3fa4)
        let bolt = device(4, 2, 0x046d, 0xc548)
        let nestedHub = device(5, 2, 2, 2, hub: true)
        let rapoo = device(6, 5, 0x24ae, 0x186a)
        let topology = try MonitorUSBTopology(devices: [root, hub, controller, bolt, nestedHub, rapoo])
        XCTAssertEqual(topology.connection(.bolt), .monitorHub)
        XCTAssertEqual(topology.connection(.rapoo), .monitorHub)
        let unrelatedHub = device(7, 1, 2, 3, hub: true)
        let offHub = try MonitorUSBTopology(devices: [root, hub, controller, bolt, unrelatedHub,
            device(6, 7, 0x24ae, 0x186a)])
        XCTAssertEqual(offHub.connection(.rapoo), .elsewhere)
        let directToRoot = try MonitorUSBTopology(devices: [root, device(3, 1, 0x1462, 0x3fa4), device(4, 1, 0x046d, 0xc548)])
        XCTAssertNil(directToRoot.monitorHubID)
        XCTAssertEqual(directToRoot.connection(.bolt), .elsewhere)
        XCTAssertThrowsError(try MonitorUSBTopology(devices: [hub, controller, device(7, 2, 0x1462, 0x3fa4)]))
    }

    func testRemoteSnapshotCannotClaimRadioResponseWithoutMatchedProtocolOrHub() throws {
        func json(connection: String = "monitorHub", monitorHub: Bool = true,
                  radio: String = "responding", version: String = #""2.0""#) -> Data {
            Data("""
            {"schemaVersion":1,"checkedAt":"2026-10-20T12:00:00Z","hostName":"linux-host","platform":"linux",
            "monitorHubPresent":\(monitorHub),"receivers":[
              {"id":"bolt","connection":"\(connection)","pairedDevices":[
                {"slot":1,"name":"POP Keys","kind":"keyboard","wirelessProductID":"B385","radio":"\(radio)","protocolVersion":\(version)}]},
              {"id":"rapoo","connection":"monitorHub","pairedDevices":[]}]}
            """.utf8)
        }
        let snapshot = try USBPeripheralClient.decodeRemote(json())
        XCTAssertEqual(snapshot.receivers[0].pairedDevices[0].radio, .responding)
        XCTAssertThrowsError(try USBPeripheralClient.decodeRemote(json(version: "null")))
        XCTAssertThrowsError(try USBPeripheralClient.decodeRemote(json(version: #""0.0""#)))
        XCTAssertThrowsError(try USBPeripheralClient.decodeRemote(json(radio: "notResponding")))
        XCTAssertThrowsError(try USBPeripheralClient.decodeRemote(json(connection: "elsewhere")))
        XCTAssertThrowsError(try USBPeripheralClient.decodeRemote(json(monitorHub: false)))
        let unavailable = try USBPeripheralClient.decodeRemote(json(radio: "unavailable", version: "null"))
        XCTAssertEqual(unavailable.receivers[0].pairedDevices[0].radio, .unavailable)
    }
}
