import Foundation
import IOKit

struct InventorySourceSlice<Value: Sendable>: Sendable {
    let values: [Value]
    let outcome: InventorySourceOutcome
    init(_ values: [Value], outcome: InventorySourceOutcome = .complete) { self.values = values; self.outcome = outcome }
}

struct USBDeviceNode: Equatable, Sendable {
    let id: UInt64
    let parentID: UInt64?
    let vendor: Int?
    let product: Int?
    let deviceClass: Int
    let rootHub: Bool
    let name: String?
    let serial: String?
    let isBuiltIn: Bool?

    init(id: UInt64, parentID: UInt64?, vendor: Int?, product: Int?, deviceClass: Int,
         rootHub: Bool, name: String?, serial: String?, isBuiltIn: Bool? = nil) {
        self.id = id; self.parentID = parentID; self.vendor = vendor; self.product = product
        self.deviceClass = deviceClass; self.rootHub = rootHub; self.name = name; self.serial = serial
        self.isBuiltIn = isBuiltIn
    }

    var peripheralProjection: PeripheralUSBDevice? {
        guard let vendor, let product else { return nil }
        return PeripheralUSBDevice(id: id, parentID: parentID, vendor: vendor, product: product, deviceClass: deviceClass, rootHub: rootHub)
    }
}

struct HIDDeviceNode: Equatable, Sendable {
    let id: UInt64
    let usbDeviceID: UInt64?
    let interfaceID: UInt64?
    let interfaceNumber: UInt8?
    let transport: DeviceTransport
    let vendor: Int?
    let product: Int?
    let name: String?
    let serial: String?
    let usages: [DeviceUsage]
    let isBuiltIn: Bool?

    init(id: UInt64, usbDeviceID: UInt64?, interfaceID: UInt64?, interfaceNumber: UInt8?,
         transport: DeviceTransport, vendor: Int?, product: Int?, name: String?, serial: String?,
         usages: [DeviceUsage], isBuiltIn: Bool? = nil) {
        self.id = id; self.usbDeviceID = usbDeviceID; self.interfaceID = interfaceID; self.interfaceNumber = interfaceNumber
        self.transport = transport; self.vendor = vendor; self.product = product; self.name = name; self.serial = serial
        self.usages = usages; self.isBuiltIn = isBuiltIn
    }
}

/// Shared enumeration/ancestry only. No HID objects, opens, callbacks, reports,
/// locks, framework discovery, SSH, or display power assertions exist here.
struct USBDeviceGraph: Sendable {
    let devices: [USBDeviceNode]

    init(devices: [USBDeviceNode]) throws {
        try requireContract(Set(devices.map(\.id)).count == devices.count, "duplicateRegistryID")
        self.devices = devices
    }

    func ancestors(of id: UInt64) -> [UInt64] {
        Self.ancestors(of: id, parent: { id in devices.first { $0.id == id }?.parentID })
    }

    static func ancestors(of id: UInt64, parent: (UInt64) -> UInt64?) -> [UInt64] {
        var result: [UInt64] = [], visited: Set<UInt64> = [id]
        var next = parent(id)
        for _ in 0..<32 {
            guard let id = next, visited.insert(id).inserted else { break }
            result.append(id); next = parent(id)
        }
        return result
    }

    static func enumerateUSB() throws -> InventorySourceSlice<USBDeviceNode> {
        var devices: [USBDeviceNode] = []
        var incomplete = false
        try enumerate("IOUSBHostDevice") { service in
            guard let id = registryID(service) else { incomplete = true; return }
            devices.append(USBDeviceNode(id: id, parentID: ancestor(service, className: "IOUSBHostDevice", includingSelf: false),
                vendor: number(service, "idVendor"), product: number(service, "idProduct"), deviceClass: number(service, "bDeviceClass") ?? -1,
                rootHub: IOObjectConformsTo(service, "AppleUSBRootHubDevice") != 0,
                name: string(service, "USB Product Name"), serial: string(service, "USB Serial Number"),
                isBuiltIn: number(service, "Built-In").map { $0 != 0 }))
        }
        return InventorySourceSlice(devices.sorted { $0.id < $1.id }, outcome: incomplete
            ? .failed(code: .identityUnavailable, message: "Some USB identities are unavailable") : .complete)
    }

    static func enumerateHID() throws -> InventorySourceSlice<HIDDeviceNode> {
        var devices: [HIDDeviceNode] = []
        var incomplete = false
        try enumerate("IOHIDDevice") { service in
            guard let id = registryID(service) else { incomplete = true; return }
            let ifaceID = ancestor(service, className: "IOUSBHostInterface", includingSelf: false)
            let ifaceNumber = ancestorNumber(service, className: "IOUSBHostInterface", key: "bInterfaceNumber")
            var usages: Set<DeviceUsage> = []
            if let pairs = property(service, "DeviceUsagePairs") as? [[String: Any]] {
                for pair in pairs {
                    if let rawPage = (pair["DeviceUsagePage"] as? NSNumber)?.intValue,
                       let rawUsage = (pair["DeviceUsage"] as? NSNumber)?.intValue,
                       let page = UInt16(exactly: rawPage), let usage = UInt16(exactly: rawUsage) {
                        usages.insert(DeviceUsage(page: page, usage: usage))
                    } else { incomplete = true }
                }
            }
            if let page = number(service, "PrimaryUsagePage").flatMap(UInt16.init(exactly:)),
               let usage = number(service, "PrimaryUsage").flatMap(UInt16.init(exactly:)) {
                usages.insert(DeviceUsage(page: page, usage: usage))
            }
            let transport: DeviceTransport
            switch string(service, "Transport") {
            case "USB": transport = .usb
            case "Bluetooth", "Bluetooth Low Energy", "BluetoothLowEnergy": transport = .bluetooth
            default: transport = .other
            }
            devices.append(HIDDeviceNode(id: id, usbDeviceID: ancestor(service, className: "IOUSBHostDevice", includingSelf: true),
                interfaceID: ifaceID, interfaceNumber: ifaceNumber.flatMap(UInt8.init(exactly:)), transport: transport,
                vendor: number(service, "VendorID"), product: number(service, "ProductID"),
                name: string(service, "Product"), serial: string(service, "SerialNumber"),
                usages: usages.sorted { ($0.page, $0.usage) < ($1.page, $1.usage) },
                isBuiltIn: number(service, "Built-In").map { $0 != 0 }))
        }
        return InventorySourceSlice(devices.sorted { $0.id < $1.id }, outcome: incomplete
            ? .failed(code: .identityUnavailable, message: "Some HID identities are unavailable") : .complete)
    }

    static func enumerate(_ className: String, body: (io_registry_entry_t) throws -> Void) throws {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            throw DeviceContractError.invalid("registryUnavailable")
        }
        // A successful search with no matches may have no iterator at all.
        // Only a non-null iterator can be invalidated during enumeration.
        guard iterator != 0 else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            try body(service)
        }
        guard IOIteratorIsValid(iterator) != 0 else { throw DeviceContractError.invalid("registryChanged") }
    }

    static func property(_ service: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    static func number(_ service: io_registry_entry_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }
    private static func string(_ service: io_registry_entry_t, _ key: String) -> String? {
        property(service, key) as? String
    }
    private static func registryID(_ service: io_registry_entry_t) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS ? id : nil
    }

    static func ancestor(_ service: io_registry_entry_t, className: String, includingSelf: Bool) -> UInt64? {
        walk(service, className: className, includingSelf: includingSelf) { registryID($0) }
    }
    private static func ancestorNumber(_ service: io_registry_entry_t, className: String, key: String) -> Int? {
        walk(service, className: className, includingSelf: false) { number($0, key) }
    }
    private static func walk<T>(_ service: io_registry_entry_t, className: String, includingSelf: Bool,
                                value: (io_registry_entry_t) -> T?) -> T? {
        var entry = service
        IOObjectRetain(entry)
        var visited: Set<UInt64> = []
        for index in 0..<32 {
            if let id = registryID(entry), !visited.insert(id).inserted { IOObjectRelease(entry); return nil }
            if (includingSelf || index > 0), IOObjectConformsTo(entry, className) != 0 {
                let result = value(entry); IOObjectRelease(entry); return result
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }
}
