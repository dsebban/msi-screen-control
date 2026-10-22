import XCTest
@testable import MSIScreenCore
@testable import MSIScreenMenu

final class DetectedPeripheralTests: XCTestCase {
    private func usb(_ id: UInt64, parent: UInt64? = nil, name: String = "Unknown USB accessory",
                     vendor: Int = 123, product: Int = 456, deviceClass: Int = 0,
                     rootHub: Bool = false, isBuiltIn: Bool? = nil) -> USBDeviceNode {
        USBDeviceNode(id: id, parentID: parent, vendor: vendor, product: product, deviceClass: deviceClass,
            rootHub: rootHub, name: name, serial: nil, isBuiltIn: isBuiltIn)
    }

    private func hid(_ id: UInt64, usb: UInt64? = nil, interface: UInt64? = nil, number: UInt8? = nil,
                     name: String = "Unknown HID accessory", transport: DeviceTransport = .usb,
                     page: UInt16 = 1, usage: UInt16 = 6, isBuiltIn: Bool? = nil) -> HIDDeviceNode {
        HIDDeviceNode(id: id, usbDeviceID: usb, interfaceID: interface, interfaceNumber: number,
            transport: transport, vendor: 123, product: 456, name: name, serial: nil,
            usages: [DeviceUsage(page: page, usage: usage)], isBuiltIn: isBuiltIn)
    }

    private func snapshot(usb: [USBDeviceNode] = [], hid: [HIDDeviceNode] = [],
                          displays: [MacDisplayInfo] = [], generation: UInt64 = 1) throws -> DeviceInventorySnapshot {
        try MacDeviceInventoryReader.build(identity: DeviceInventoryIdentity(installationKey: Data(repeating: 7, count: 32)),
            bootIdentity: "fixture-boot", displays: InventorySourceSlice(displays), usb: InventorySourceSlice(usb),
            hid: InventorySourceSlice(hid), generation: generation, checkedAtMilliseconds: 1)
    }

    func testFreshSnapshotsAddAndRemoveAnUnknownUSBPeripheral() throws {
        let before = try snapshot()
        let attached = try snapshot(usb: [usb(10)], generation: 2)
        let detached = try snapshot(generation: 3)
        XCTAssertTrue(DetectedPeripheral.from(before).isEmpty)
        let item = try XCTUnwrap(DetectedPeripheral.from(attached).first)
        XCTAssertEqual(item.name, "Unknown USB accessory")
        XCTAssertEqual(item.kind, .other)
        XCTAssertEqual(item.endpoints.count, 1)
        XCTAssertTrue(DetectedPeripheral.from(detached).isEmpty)
    }

    func testSameNameAndVendorProductTwinsRemainSeparate() throws {
        let inventory = try snapshot(usb: [usb(10), usb(11)])
        let items = DetectedPeripheral.from(inventory)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.name)), ["Unknown USB accessory"])
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertTrue(items.allSatisfy { $0.endpoints.count == 1 })
    }

    func testUSBAndMultipleHIDInterfacesShareOnlyTheirExistingPhysicalDomain() throws {
        let inventory = try snapshot(usb: [usb(10)], hid: [
            hid(30, usb: 10, interface: 20, number: 0, name: "Composite keyboard"),
            hid(31, usb: 10, interface: 21, number: 1, usage: 2)
        ])
        XCTAssertEqual(inventory.devices.count, 3)
        let items = DetectedPeripheral.from(inventory)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.name, "Composite keyboard")
        XCTAssertEqual(item.kind, .keyboard)
        XCTAssertEqual(item.endpoints.count, 3)
        XCTAssertEqual(Set(item.endpoints.map(\.physicalDomainID)), [item.id])

        let unrelated = try snapshot(hid: [hid(30, transport: .bluetooth), hid(31, transport: .bluetooth)])
        XCTAssertEqual(DetectedPeripheral.from(unrelated).count, 2, "Matching Bluetooth labels do not establish a shared physical device")
    }

    func testOSBuiltInFactsHideOnlyTheirOwnPhysicalDevice() throws {
        let inventory = try snapshot(usb: [
            usb(1, name: "Internal root", deviceClass: 9, rootHub: true, isBuiltIn: true),
            usb(10, parent: 1, name: "External keyboard", isBuiltIn: false),
            usb(11, name: "Internal accessory", isBuiltIn: true),
            usb(12, name: "Unclassified hub", deviceClass: 9, rootHub: true)
        ], hid: [
            hid(30, usb: 11, interface: 20, number: 0),
            hid(31, name: "Internal keyboard", transport: .other, isBuiltIn: true),
            hid(32, name: "External pointer", transport: .bluetooth, usage: 2, isBuiltIn: false)
        ])
        XCTAssertEqual(Set(DetectedPeripheral.from(inventory).map(\.name)),
            ["External keyboard", "Unclassified hub", "External pointer"])
        let builtInHID = try XCTUnwrap(inventory.devices.first { $0.displayName == "Internal keyboard" })
        XCTAssertEqual(builtInHID.endpoints.first?.identity.isBuiltIn, true)
        let externalUSB = try XCTUnwrap(inventory.devices.first { $0.displayName == "External keyboard" })
        XCTAssertEqual(externalUSB.endpoints.first?.identity.isBuiltIn, false)
        XCTAssertEqual(inventory.devices.count, 7, "Filtering presentation must retain the full Devices inventory")
    }

    func testDisplaysAndUnclassifiedInternalHIDStayOutOfPeripheralPresentation() throws {
        let display = MacDisplayInfo(id: 1, uuid: "fixture-display", vendor: 1, model: 2, isBuiltIn: false,
            isMain: true, isActive: true, isAsleep: false, isMirrored: false, mirrorsDisplay: 0,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), rotation: 0, mode: nil)
        let inventory = try snapshot(hid: [
            hid(30, name: "Internal sensor", transport: .other, page: 0xff00, usage: 1),
            hid(31, name: "Unclassified transport keyboard", transport: .other),
            hid(32, name: "Unknown Bluetooth accessory", transport: .bluetooth, page: 0xff00, usage: 1),
            hid(33, name: "Generic gamepad", transport: .other, usage: 5)
        ], displays: [display])
        XCTAssertEqual(Set(DetectedPeripheral.from(inventory).map(\.name)),
            ["Unclassified transport keyboard", "Unknown Bluetooth accessory", "Generic gamepad"])
        XCTAssertEqual(inventory.devices.count, 5)
    }

    func testReceiverPresentationDoesNotClaimItsHIDCollectionsArePairedDevices() throws {
        let inventory = try snapshot(usb: [usb(10, name: "Logitech Bolt", vendor: 0x046d, product: 0xc548)],
            hid: [hid(30, usb: 10, interface: 20, number: 0, name: "Receiver keyboard collection")])
        let items = DetectedPeripheral.from(inventory)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .receiver)
        XCTAssertEqual(items.first?.name, "Logitech Bolt")
        XCTAssertEqual(items.first?.endpoints.count, 2)
    }
}
