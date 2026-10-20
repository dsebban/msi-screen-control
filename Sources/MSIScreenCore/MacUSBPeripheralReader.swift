import Foundation
import SystemConfiguration
import IOKit
import IOKit.hid

struct PeripheralUSBDevice: Equatable {
    let id: UInt64
    let parentID: UInt64?
    let vendor: Int
    let product: Int
    let deviceClass: Int
    let rootHub: Bool
}

struct MonitorUSBTopology {
    let monitorHubID: UInt64?
    let devices: [PeripheralUSBDevice]

    init(devices: [PeripheralUSBDevice]) throws {
        self.devices = devices
        let controllers = devices.filter { $0.vendor == 0x1462 && $0.product == 0x3fa4 }
        guard controllers.count <= 1 else { throw ScreenError.message("More than one MSI USB controller is present") }
        if let parent = controllers.first?.parentID,
           let hub = devices.first(where: { $0.id == parent }), hub.deviceClass == 9, !hub.rootHub {
            monitorHubID = hub.id
        } else {
            monitorHubID = nil
        }
    }

    func receivers(_ kind: USBReceiverKind) -> [PeripheralUSBDevice] {
        devices.filter { kind == .bolt ? $0.vendor == 0x046d && $0.product == 0xc548
            : $0.vendor == 0x24ae && $0.product == 0x186a }
    }

    func connection(_ kind: USBReceiverKind) -> USBReceiverConnection {
        let matches = receivers(kind)
        guard !matches.isEmpty else { return .notDetected }
        guard matches.contains(where: isOnMonitorHub) else { return .elsewhere }
        return .monitorHub
    }

    func isOnMonitorHub(_ device: PeripheralUSBDevice) -> Bool {
        guard let monitorHubID else { return false }
        var parent = device.parentID
        var visited: Set<UInt64> = []
        for _ in 0..<32 {
            guard let id = parent, visited.insert(id).inserted else { return false }
            if id == monitorHubID { return true }
            parent = devices.first(where: { $0.id == id })?.parentID
        }
        return false
    }
}

enum MacUSBPeripheralReader {
    // ProcessInfo.hostName may perform reverse DNS and return a network
    // resolver's unrelated hostname. Device reports use this Mac's local name.
    static var hostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? "This Mac"
    }

    static func readDetails(expected: PairedUSBPeripheral) throws -> POPKeyboardDetails {
        try POPKeyboardProbe.validateExpected(expected)
        let topology = try MonitorUSBTopology(devices: enumerateUSB())
        let candidates = topology.receivers(.bolt).filter(topology.isOnMonitorHub)
        guard candidates.count == 1 else { throw ScreenError.message("A single Bolt receiver must be connected to the monitor hub") }
        let reader = try MacBoltReader(usbID: candidates[0].id, readWindow: 8)
        return try reader.readDetails(expected: expected)
    }

    static func read() throws -> USBPeripheralSnapshot {
        let topology = try MonitorUSBTopology(devices: enumerateUSB())
        var receivers: [USBReceiverSnapshot] = []
        for kind in USBReceiverKind.allCases {
            let connection = topology.connection(kind)
            var paired: [PairedUSBPeripheral] = []
            var failure: String?
            if kind == .bolt, connection == .monitorHub {
                let candidates = topology.receivers(kind).filter(topology.isOnMonitorHub)
                if candidates.count != 1 {
                    failure = "More than one Bolt receiver is connected to the monitor hub"
                } else {
                    do {
                        let reader = try MacBoltReader(usbID: candidates[0].id)
                        let result = reader.readDevices()
                        paired = result.devices
                        failure = result.error
                    } catch { failure = String(describing: error) }
                }
            }
            receivers.append(USBReceiverSnapshot(id: kind, connection: connection, pairedDevices: paired, error: failure))
        }
        return USBPeripheralSnapshot(schemaVersion: 1, checkedAt: Date(), hostName: hostName,
                                     platform: .macos, monitorHubPresent: topology.monitorHubID != nil, receivers: receivers)
    }

    static func enumerateUSB() throws -> [PeripheralUSBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            throw ScreenError.message("Cannot enumerate USB devices")
        }
        defer { IOObjectRelease(iterator) }
        var devices: [PeripheralUSBDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let vendor = number(service, "idVendor"), let product = number(service, "idProduct") else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            devices.append(PeripheralUSBDevice(id: id, parentID: usbAncestor(service, includingSelf: false),
                vendor: vendor, product: product, deviceClass: number(service, "bDeviceClass") ?? -1,
                rootHub: IOObjectConformsTo(service, "AppleUSBRootHubDevice") != 0))
        }
        return devices
    }

    static func number(_ service: io_registry_entry_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
    }

    static func usbAncestor(_ service: io_registry_entry_t, includingSelf: Bool) -> UInt64? {
        ancestor(service, className: "IOUSBHostDevice", includingSelf: includingSelf)
    }

    private static func ancestor(_ service: io_registry_entry_t, className: String, includingSelf: Bool) -> UInt64? {
        var entry = service
        IOObjectRetain(entry)
        for index in 0..<32 {
            if (includingSelf || index > 0), IOObjectConformsTo(entry, className) != 0 {
                var id: UInt64 = 0
                let result = IORegistryEntryGetRegistryEntryID(entry, &id)
                IOObjectRelease(entry)
                return result == KERN_SUCCESS ? id : nil
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

    static func vendorInterfaceID(_ service: io_registry_entry_t) -> UInt64? {
        ancestor(service, className: "IOUSBHostInterface", includingSelf: false)
    }
}

private final class MacBoltReader {
    private let device: IOHIDDevice
    private let runLoop = CFRunLoopGetCurrent()!
    private let buffer: UnsafeMutablePointer<UInt8>
    private let deadline: TimeInterval
    private var expected: BoltReadRequest?
    private var received: BoltReadReply?
    private var failure: Error?

    init(usbID: UInt64, readWindow: TimeInterval = 5) throws {
        deadline = ProcessInfo.processInfo.systemUptime + readWindow
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            throw ScreenError.message("Cannot enumerate Bolt vendor interface")
        }
        defer { IOObjectRelease(iterator) }
        var interfaces: [UInt64: IOHIDDevice] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            // Filter before opening: keyboard, mouse and consumer interfaces
            // never receive callbacks. HID++ has multiple top-level collections;
            // select its primary usage and deduplicate their USB interface.
            guard MacUSBPeripheralReader.number(service, "VendorID") == 0x046d,
                  MacUSBPeripheralReader.number(service, "ProductID") == 0xc548,
                  MacUSBPeripheralReader.number(service, "PrimaryUsagePage") == 0xff00,
                  MacUSBPeripheralReader.number(service, "PrimaryUsage") == 1,
                  MacUSBPeripheralReader.number(service, "MaxInputReportSize") == 20,
                  MacUSBPeripheralReader.number(service, "MaxOutputReportSize") == 20,
                  MacUSBPeripheralReader.usbAncestor(service, includingSelf: true) == usbID else { continue }
            guard let id = MacUSBPeripheralReader.vendorInterfaceID(service) else { continue }
            if let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) { interfaces[id] = candidate }
        }
        guard interfaces.count == 1, let candidate = interfaces.values.first else {
            throw ScreenError.message("Bolt vendor interface is missing or ambiguous")
        }
        device = candidate
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { throw ScreenError.message("Cannot read Bolt vendor interface: \(opened)") }
        buffer = .allocate(capacity: 20)
        buffer.initialize(repeating: 0, count: 20)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 20, { context, result, _, _, _, report, count in
            guard let context else { return }
            let reader = Unmanaged<MacBoltReader>.fromOpaque(context).takeUnretainedValue()
            guard let expected = reader.expected else { return }
            guard result == kIOReturnSuccess else {
                reader.failure = ScreenError.message("Bolt USB reply failed: \(result)")
                return
            }
            // Decoder retains only matched metadata/ping fields. No raw report,
            // pairing address, serial, unsolicited event or key data is stored.
            do { if let reply = try BoltPeripheralProtocol.decode(UnsafeBufferPointer(start: report, count: count), for: expected) {
                reader.received = reply
            } } catch { reader.failure = error }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 20, nil, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    private func request(_ request: BoltReadRequest) throws -> BoltReadReply? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ScreenError.message("Peripheral check reached its read-window budget") }
        expected = nil
        for _ in 0..<16 { if CFRunLoopRunInMode(.defaultMode, 0, true) != .handledSource { break } }
        received = nil
        failure = nil
        expected = request
        defer { expected = nil }
        let packet = request.packet
        let sent = packet.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x10, $0.baseAddress!, packet.count)
        }
        guard sent == kIOReturnSuccess else { throw ScreenError.message("Bolt read-only request failed: \(sent)") }
        let until = min(deadline, ProcessInfo.processInfo.systemUptime + 0.4)
        while received == nil, failure == nil, ProcessInfo.processInfo.systemUptime < until {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        if let failure { throw failure }
        return received
    }

    func readDevices() -> (devices: [PairedUSBPeripheral], error: String?) {
        BoltPeripheralProtocol.readDevices(request: request)
    }

    func readDetails(expected: PairedUSBPeripheral) throws -> POPKeyboardDetails {
        try POPKeyboardProbe(expected: expected, request: request).read(
            hostName: MacUSBPeripheralReader.hostName, platform: .macos)
    }
}
