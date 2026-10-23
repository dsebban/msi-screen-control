import XCTest
@testable import MSIScreenCore

private func checksum(_ bytes: inout [UInt8], block: Int = 0) {
    let offset = block * 128
    bytes[offset + 127] = 0
    bytes[offset + 127] = UInt8((256 - bytes[offset..<offset + 127].reduce(0, { $0 + Int($1) }) % 256) % 256)
}

private func fixtureEDID(addresses: [UInt16] = [0x1000]) -> Data {
    var bytes = [UInt8](repeating: 0, count: addresses.isEmpty ? 128 : 256)
    bytes.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
    bytes[8] = 0x36; bytes[9] = 0x69; bytes[10] = 0xc5; bytes[11] = 0x30
    bytes.replaceSubrange(12..<16, with: [0x15, 0xcd, 0x5b, 0x07]) // Synthetic numeric serial.
    bytes[18] = 1; bytes[19] = 4
    bytes[57] = 0xfc
    bytes.replaceSubrange(59..<72, with: Array("Fixture Panel".utf8))
    bytes[75] = 0xff
    bytes.replaceSubrange(77..<90, with: Array("PRIVATE-12345".utf8))
    if !addresses.isEmpty {
        bytes[126] = 1; bytes[128] = 2; bytes[129] = 3
        bytes[130] = UInt8(4 + addresses.count * 6)
        for (index, address) in addresses.enumerated() {
            let offset = 132 + index * 6
            bytes.replaceSubrange(offset..<offset + 6,
                with: [0x65, 0x03, 0x0c, 0x00, UInt8(address >> 8), UInt8(address & 255)])
        }
        checksum(&bytes, block: 1)
    }
    checksum(&bytes)
    return Data(bytes)
}

final class DisplayIdentificationTests: XCTestCase {
    func testDisplayIdentityAndHDMITopologyExcludePrivateEDIDAndSerials() throws {
        let identity = try DisplayIdentification(edid: fixtureEDID())
        XCTAssertEqual(identity.vendorID, 0x3669)
        XCTAssertEqual(identity.productID, 0x30c5)
        XCTAssertEqual(identity.name, "Fixture Panel")
        XCTAssertEqual(identity.hdmiPhysicalAddress?.dottedString, "1.0.0.0")
        let json = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE-12345"))
        XCTAssertFalse(json.contains("123456789"))
        XCTAssertFalse(json.lowercased().contains("edid"))
        XCTAssertEqual(try JSONDecoder().decode(DisplayIdentification.self, from: Data(json.utf8)), identity)
    }

    func testTruncatedExtensionsBadHeaderAndEveryBlockChecksumAreRefused() throws {
        let complete = fixtureEDID()
        XCTAssertThrowsError(try DisplayIdentification(edid: complete.prefix(128))) {
            XCTAssertEqual($0 as? DisplayIdentificationError, .invalidLength)
        }
        var bad = [UInt8](complete); bad[0] = 1; checksum(&bad)
        XCTAssertThrowsError(try DisplayIdentification(edid: Data(bad))) {
            XCTAssertEqual($0 as? DisplayIdentificationError, .invalidHeader)
        }
        for offset in [8, 140] {
            bad = [UInt8](complete); bad[offset] ^= 1
            XCTAssertThrowsError(try DisplayIdentification(edid: Data(bad))) {
                XCTAssertEqual($0 as? DisplayIdentificationError, .invalidChecksum)
            }
        }
    }

    func testMalformedCTABoundariesAndTruncatedHDMIVendorBlocksCannotLeakAnAddress() throws {
        var bad = [UInt8](fixtureEDID()); bad[130] = 3; checksum(&bad, block: 1)
        XCTAssertThrowsError(try DisplayIdentification(edid: Data(bad))) {
            XCTAssertEqual($0 as? DisplayIdentificationError, .invalidExtension)
        }
        bad = [UInt8](fixtureEDID()); bad[132] = 0x7f; checksum(&bad, block: 1)
        XCTAssertThrowsError(try DisplayIdentification(edid: Data(bad))) {
            XCTAssertEqual($0 as? DisplayIdentificationError, .invalidDataBlock)
        }
        bad = [UInt8](fixtureEDID()); bad[130] = 8; bad[132] = 0x63; checksum(&bad, block: 1)
        XCTAssertThrowsError(try DisplayIdentification(edid: Data(bad))) {
            XCTAssertEqual($0 as? DisplayIdentificationError, .invalidDataBlock)
        }
    }

    func testMultipleHDMIVendorBlocksMustAgreeAndOtherOUIsDoNotSupplyTheAddress() throws {
        let same = try DisplayIdentification(edid: fixtureEDID(addresses: [0x1000, 0x1000]))
        XCTAssertEqual(same.hdmiPhysicalAddress?.rawValue, 0x1000)
        XCTAssertThrowsError(try DisplayIdentification(edid: fixtureEDID(addresses: [0x1000, 0x2000]))) {
            XCTAssertEqual($0 as? DisplayIdentificationError, .conflictingHDMIAddresses)
        }
        var other = [UInt8](fixtureEDID()); other[134] = 0x0d; checksum(&other, block: 1)
        XCTAssertNil(try DisplayIdentification(edid: Data(other)).hdmiPhysicalAddress)
    }

    func testInvalidCECTopologyIsRejectedInEDIDAndDecodedPublicJSON() throws {
        for address: UInt16 in [0xffff, 0x1020] {
            XCTAssertThrowsError(try DisplayIdentification(edid: fixtureEDID(addresses: [address]))) {
                XCTAssertEqual($0 as? DisplayIdentificationError, .invalidPhysicalAddress)
            }
            let json = Data("{\"rawValue\":\(address)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(HDMIPhysicalAddress.self, from: json))
        }
        XCTAssertEqual(try HDMIPhysicalAddress(rawValue: 0).dottedString, "0.0.0.0")
        XCTAssertEqual(try HDMIPhysicalAddress(rawValue: 0x1234).dottedString, "1.2.3.4")
        XCTAssertNil(try DisplayIdentification(edid: fixtureEDID(addresses: [])).hdmiPhysicalAddress)
    }
}

final class MacVideoConnectionReaderTests: XCTestCase {
    private func record(port: String = "Port-HDMI@1", active: Bool = true, edid: Data = fixtureEDID()) -> [String: Any] {
        ["IOObjectClass": "IOPortTransportStateDisplayPort", "Active": active,
         "ProductID": 0x30c5, "EDID": edid,
         "ParentBuiltInPortTypeDescription": "HDMI", "ParentPortTypeDescription": "HDMI",
         "TransportTypeDescription": "DisplayPort", "TransportDescription": port + "/DisplayPort"]
    }

    func testNativeHDMIPathDoesNotBecomeDisplayPortBecauseOfTheMacConverter() throws {
        let snapshot = MacVideoConnectionReader.parseRecords([record()])
        XCTAssertEqual(snapshot.outcome, .complete)
        let link = try XCTUnwrap(snapshot.connections.first)
        XCTAssertEqual(link.transport, .hdmi)
        XCTAssertEqual(link.hostPort, "Port-HDMI@1")
        XCTAssertEqual(link.display.hdmiPhysicalAddress?.dottedString, "1.0.0.0")
        XCTAssertEqual(link.evidenceSource, .ioKitPortTransportStateDisplayPort)
    }

    func testIdenticalDisplaysOnSeparatePortsAreBothRetainedForAmbiguityResolution() {
        let snapshot = MacVideoConnectionReader.parseRecords([record(port: "Port-HDMI@2"), record()])
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(snapshot.connections.map(\.hostPort), ["Port-HDMI@1", "Port-HDMI@2"])
        XCTAssertEqual(snapshot.connections.map { $0.display.vendorID }, [0x3669, 0x3669])
    }

    func testDisconnectedStaleEDIDDoesNotCreateAConnectionAndPartialReadsAreVisible() throws {
        var invalid = record(); invalid["EDID"] = Data([1, 2, 3])
        let snapshot = MacVideoConnectionReader.parseRecords([record(active: false), invalid, record(port: "Live")])
        XCTAssertEqual(snapshot.connections.map(\.hostPort), ["Live"])
        guard case .failed(let code, _) = snapshot.outcome else { return XCTFail("Malformed candidate must remain an incomplete source") }
        XCTAssertEqual(code, .identityUnavailable)
        var mismatch = record(); mismatch["Metadata"] = ["ProductID": 1]
        XCTAssertTrue(MacVideoConnectionReader.parseRecords([mismatch]).connections.isEmpty)
    }

    func testConflictingAdapterConnectorDescriptionsAndMissingConnectorFactsStayUnknown() throws {
        var adapter = record(); adapter["ParentBuiltInPortTypeDescription"] = "USB-C"
        var unknown = record(port: "Unknown"); unknown.removeValue(forKey: "ParentBuiltInPortTypeDescription")
        unknown.removeValue(forKey: "ParentPortTypeDescription")
        let snapshot = MacVideoConnectionReader.parseRecords([adapter, unknown])
        XCTAssertEqual(snapshot.connections.map(\.transport), [.unknown, .unknown])
    }

    func testRemotePlistUsesTheSameParserAndRejectsWrongRootsAndOversizedIdentifiers() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [record()], format: .xml, options: 0)
        let snapshot = try MacVideoConnectionReader.parseRegistryData(data)
        XCTAssertEqual(snapshot.connections.map(\.transport), [.hdmi])
        XCTAssertThrowsError(try MacVideoConnectionReader.parseRegistryData(Data("<plist/>".utf8)))
        var wrong = record(); wrong["IOObjectClass"] = "UnrelatedService"
        let wrongData = try PropertyListSerialization.data(fromPropertyList: [wrong], format: .xml, options: 0)
        XCTAssertThrowsError(try MacVideoConnectionReader.parseRegistryData(wrongData))
        let oversized = MacVideoConnectionReader.parseRecords([record(port: String(repeating: "a", count: 97))])
        XCTAssertTrue(oversized.connections.isEmpty)
        guard case .failed = oversized.outcome else { return XCTFail("Unbounded host identifier must not be admitted") }
    }
}
