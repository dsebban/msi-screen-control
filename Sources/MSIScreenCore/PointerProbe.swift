import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem

public enum PointerInputKind: String, Codable { case x, y, verticalWheel, horizontalWheel, button }
public enum PointerProbeAccess: String, Codable { case granted, denied, unknown }

public struct PointerUsageDescriptor: Codable, Equatable, Identifiable {
    public let usagePage: UInt32
    public let usage: UInt32
    public let kind: PointerInputKind
    public let name: String
    public let relative: Bool
    public let logicalMin: Int
    public let logicalMax: Int
    public var id: String { "\(usagePage):\(usage)" }
}

public struct PointerDescriptorSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let receiver: USBReceiverKind
    public let connection: USBReceiverConnection
    public let access: PointerProbeAccess
    public let usages: [PointerUsageDescriptor]
    public let error: String?
}

public struct PointerUsageCount: Codable, Equatable, Identifiable {
    public let descriptor: PointerUsageDescriptor
    public internal(set) var samples: Int = 0
    public internal(set) var nonzeroSamples: Int = 0
    public internal(set) var positiveSamples: Int = 0
    public internal(set) var negativeSamples: Int = 0
    public var id: String { descriptor.id }
}

public struct PointerProbeSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let requestedSeconds: Int
    public let elapsedSeconds: Double
    public let descriptor: PointerDescriptorSnapshot
    public let counts: [PointerUsageCount]
    public let completed: Bool
    public let disconnected: Bool
    public let error: String?
}

/// On-demand, local Rapoo pointer diagnostics. No raw reports, keyboard values,
/// event taps, device configuration, or background listener are used.
public struct PointerProbeClient {
    private static let queue = DispatchQueue(label: "MSIScreen.pointer-probe", qos: .utility)
    public init() {}

    public func describe() async throws -> PointerDescriptorSnapshot {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try PointerReader().descriptor }) }
        }
    }

    public func probe(seconds: Int = 10) async throws -> PointerProbeSnapshot {
        guard (1...15).contains(seconds) else {
            throw ScreenError.message("Mouse diagnostics must last between 1 and 15 seconds")
        }
        let cancellation = PointerProbeCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        let reader = try PointerReader()
                        return reader.probe(seconds: seconds, cancelled: cancellation.isCancelled)
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class PointerProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// This allowlist is applied both before registering input matching and before
/// accessing a value. Consumer keyboard/media keys and vendor usages stay out.
func pointerInputKind(page: UInt32, usage: UInt32) -> PointerInputKind? {
    switch (page, usage) {
    case (1, 0x30): return .x
    case (1, 0x31): return .y
    case (1, 0x38): return .verticalWheel
    case (12, 0x238): return .horizontalWheel
    case (9, 1...32): return .button
    default: return nil
    }
}

/// This exact mouse-interface descriptor was read from the supported 24ae:186a
/// receiver. Reading its IORegistry property does not require listening to input.
/// An unrecognized descriptor must use actual element metadata or stay unavailable;
/// VID/PID alone cannot establish a device's declared controls.
func rapooDeclaredPointerUsages(reportDescriptor: Data?) -> [PointerUsageDescriptor]? {
    let expected = "05010902a1010901a1000509150025011901290575019505810295038101050116018026ff7f093009317510950281061581257f0938750895018106050c0a380295018106c0c0"
    guard let reportDescriptor,
          reportDescriptor.map({ String(format: "%02x", $0) }).joined() == expected else { return nil }
    var usages = (1...5).map { usage in
        PointerUsageDescriptor(usagePage: 9, usage: UInt32(usage), kind: .button,
            name: "Button \(usage)", relative: false, logicalMin: 0, logicalMax: 1)
    }
    usages.append(contentsOf: [
        PointerUsageDescriptor(usagePage: 1, usage: 0x30, kind: .x,
            name: "Pointer X", relative: true, logicalMin: -32767, logicalMax: 32767),
        PointerUsageDescriptor(usagePage: 1, usage: 0x31, kind: .y,
            name: "Pointer Y", relative: true, logicalMin: -32767, logicalMax: 32767),
        PointerUsageDescriptor(usagePage: 1, usage: 0x38, kind: .verticalWheel,
            name: "Vertical wheel", relative: true, logicalMin: -127, logicalMax: 127),
        PointerUsageDescriptor(usagePage: 12, usage: 0x238, kind: .horizontalWheel,
            name: "Horizontal wheel (AC Pan)", relative: true, logicalMin: -127, logicalMax: 127)
    ])
    return usages
}

struct PointerProbeAccumulator {
    private(set) var counts: [PointerUsageCount]
    init(_ usages: [PointerUsageDescriptor]) { counts = usages.map { PointerUsageCount(descriptor: $0) } }
    mutating func record(page: UInt32, usage: UInt32, value: Int) {
        guard pointerInputKind(page: page, usage: usage) != nil,
              let index = counts.firstIndex(where: { $0.descriptor.usagePage == page && $0.descriptor.usage == usage }) else { return }
        counts[index].samples += 1
        if value != 0 { counts[index].nonzeroSamples += 1 }
        if value > 0 { counts[index].positiveSamples += 1 }
        if value < 0 { counts[index].negativeSamples += 1 }
    }
}

private final class PointerReader {
    let descriptor: PointerDescriptorSnapshot
    private var device: IOHIDDevice?
    private var accumulator: PointerProbeAccumulator
    private var disconnected = false
    private var callbackError: String?

    init() throws {
        let access: PointerProbeAccess
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: access = .granted
        case kIOHIDAccessTypeDenied: access = .denied
        default: access = .unknown
        }
        let topology = try MonitorUSBTopology(devices: MacUSBPeripheralReader.enumerateUSB())
        let connection = topology.connection(.rapoo)
        let receivers = topology.receivers(.rapoo).filter(topology.isOnMonitorHub)
        var usages: [PointerUsageDescriptor] = []
        var issue: String?
        if receivers.count == 1 {
            let devices = try Self.mouseInterfaces(usbID: receivers[0].id)
            if devices.count == 1, let selected = devices.first {
                device = selected
                let service = IOHIDDeviceGetService(selected)
                let reportDescriptor = IORegistryEntryCreateCFProperty(service, "ReportDescriptor" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
                if let declared = rapooDeclaredPointerUsages(reportDescriptor: reportDescriptor) {
                    usages = declared
                } else {
                    let elements = IOHIDDeviceCopyMatchingElements(selected, nil, 0) as? [IOHIDElement] ?? []
                    for element in elements {
                        let type = IOHIDElementGetType(element)
                        guard type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button || type == kIOHIDElementTypeInput_Axis else { continue }
                        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
                        guard let kind = pointerInputKind(page: page, usage: usage) else { continue }
                        let name: String
                        switch kind {
                        case .x: name = "Pointer X"
                        case .y: name = "Pointer Y"
                        case .verticalWheel: name = "Vertical wheel"
                        case .horizontalWheel: name = "Horizontal wheel (AC Pan)"
                        case .button: name = "Button \(usage)"
                        }
                        let entry = PointerUsageDescriptor(usagePage: page, usage: usage, kind: kind, name: name,
                            relative: IOHIDElementIsRelative(element), logicalMin: IOHIDElementGetLogicalMin(element), logicalMax: IOHIDElementGetLogicalMax(element))
                        if !usages.contains(where: { $0.id == entry.id }) { usages.append(entry) }
                    }
                }
                if usages.isEmpty {
                    issue = "Pointer metadata is unavailable; macOS did not provide pointer elements and the report descriptor is not recognized"
                }
            } else {
                issue = "The Rapoo mouse interface is missing or ambiguous"
            }
        } else {
            issue = receivers.isEmpty ? "Connect the Rapoo receiver through the monitor hub to this Mac" : "More than one Rapoo receiver is connected to the monitor hub"
        }
        usages.sort { ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage) }
        descriptor = PointerDescriptorSnapshot(schemaVersion: 1, checkedAt: Date(), receiver: .rapoo,
            connection: connection, access: access, usages: usages, error: issue)
        accumulator = PointerProbeAccumulator(usages)
    }

    func probe(seconds: Int, cancelled: () -> Bool) -> PointerProbeSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        func result(_ error: String?, completed: Bool = false) -> PointerProbeSnapshot {
            PointerProbeSnapshot(schemaVersion: 1, checkedAt: Date(), requestedSeconds: seconds,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, descriptor: descriptor,
                counts: accumulator.counts, completed: completed, disconnected: disconnected, error: error)
        }
        if let error = descriptor.error { return result(error) }
        guard descriptor.access == .granted else {
            return result("Input Monitoring access is required to observe mouse controls; descriptor metadata remains available")
        }
        guard !cancelled() else { return result("Mouse diagnostic cancelled") }
        guard let device else { return result("Rapoo mouse interface is unavailable") }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { return result("Cannot open the Rapoo mouse for diagnostics: \(opened)") }
        let runLoop = CFRunLoopGetCurrent()!
        let context = Unmanaged.passUnretained(self).toOpaque()
        let matching = descriptor.usages.map { [kIOHIDElementUsagePageKey: $0.usagePage, kIOHIDElementUsageKey: $0.usage] }
        IOHIDDeviceSetInputValueMatchingMultiple(device, matching as CFArray)
        IOHIDDeviceRegisterInputValueCallback(device, { context, status, _, value in
            guard let context else { return }
            let reader = Unmanaged<PointerReader>.fromOpaque(context).takeUnretainedValue()
            guard status == kIOReturnSuccess else { reader.callbackError = "Pointer input failed: \(status)"; return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
            // Crucially do not access the integer until this value is allowed.
            guard pointerInputKind(page: page, usage: usage) != nil else { return }
            reader.accumulator.record(page: page, usage: usage, value: IOHIDValueGetIntegerValue(value))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<PointerReader>.fromOpaque(context).takeUnretainedValue().disconnected = true
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer {
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputValueCallback(device, nil, context)
            IOHIDDeviceRegisterRemovalCallback(device, nil, context)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancelled() { return result("Mouse diagnostic cancelled") }
            if disconnected { return result("The Rapoo receiver disconnected or moved to another USB host") }
            if let error = callbackError { return result(error) }
            CFRunLoopRunInMode(.defaultMode, min(0.02, max(0, deadline - ProcessInfo.processInfo.systemUptime)), true)
        }
        if cancelled() { return result("Mouse diagnostic cancelled") }
        if disconnected { return result("The Rapoo receiver disconnected or moved to another USB host") }
        if let error = callbackError { return result(error) }
        return result(nil, completed: true)
    }

    private static func mouseInterfaces(usbID: UInt64) throws -> [IOHIDDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            throw ScreenError.message("Cannot enumerate Rapoo mouse interfaces")
        }
        defer { IOObjectRelease(iterator) }
        var result: [UInt64: IOHIDDevice] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            // Actual receiver has a separate keyboard/vendor interface. Never
            // open it or register any callback on it, even if it shares VID/PID.
            guard MacUSBPeripheralReader.number(service, "VendorID") == 0x24ae,
                  MacUSBPeripheralReader.number(service, "ProductID") == 0x186a,
                  MacUSBPeripheralReader.number(service, "PrimaryUsagePage") == 1,
                  MacUSBPeripheralReader.number(service, "PrimaryUsage") == 2,
                  MacUSBPeripheralReader.usbAncestor(service, includingSelf: true) == usbID,
                  let interface = MacUSBPeripheralReader.vendorInterfaceID(service),
                  let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            result[interface] = device
        }
        return Array(result.values)
    }
}
