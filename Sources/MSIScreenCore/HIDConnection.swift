import Foundation
import IOKit.hid
import IOKit.pwr_mgt
import CoreGraphics
import Darwin

public enum HIDConnectionError: Error, LocalizedError, CustomStringConvertible {
    case notPresent
    public var description: String { "MSI USB controller is not connected to this Mac" }
    public var errorDescription: String? { description }
}

public final class HIDConnection: ScreenTransport {
    public var onlineVideoCount: Int? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        let matching = displays.prefix(Int(count)).filter {
            CGDisplayVendorNumber($0) == 0x3669 && CGDisplayModelNumber($0) == 0x30c5
        }
        return matching.count
    }
    private let manager: IOHIDManager?
    private let device: IOHIDDevice
    private let runLoop = CFRunLoopGetCurrent()!
    private let buffer: UnsafeMutablePointer<UInt8>
    private var reply: [UInt8]?
    private var callbackError: IOReturn?
    private let resourceLease: DeviceResourceLock
    private var displayAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0
    private let replyBudgetDeadline: TimeInterval?

    public convenience init(replyBudget: TimeInterval? = nil) throws {
        let selection = try Self.builtInSelection(from: USBDeviceGraph.enumerateUSB())
        let lease = try DeviceResourceLock(selection.request)
        try self.init(replyBudget: replyBudget, selectedEndpoint: nil, borrowedLease: lease, expectedUSBID: selection.usbID)
    }

    static func builtInSelection(from source: InventorySourceSlice<USBDeviceNode>) throws -> (usbID: UInt64, request: DeviceResourceLock.Request) {
        let graph = try MacUSBPeripheralReader.controlGraph(from: source)
        // Unknown USB identities cannot prove genuine MSI absence and authorize
        // KVM remote fallback. Inventory may still display these partial facts.
        guard graph.devices.allSatisfy({ $0.vendor != nil && $0.product != nil }) else { throw DeviceContractError.invalid("usbIdentityUnavailable") }
        let controllers = graph.devices.filter { $0.vendor == 0x1462 && $0.product == 0x3fa4 }
        guard controllers.count == 1, let controller = controllers.first else {
            if controllers.isEmpty { throw HIDConnectionError.notPresent }
            throw ScreenError.message("More than one MSI USB controller is present")
        }
        return (controller.id, try DeviceResourceLock.request(usbID: controller.id, graph: graph, affectsHub: true))
    }

    /// Passive selection, shared with fixtures. Registry identity, not VID/PID
    /// order, chooses an interface; a USB-only selection must still be unique.
    static func selectedInterface(for endpoint: DeviceEndpoint, from source: InventorySourceSlice<HIDDeviceNode>) throws -> HIDDeviceNode {
        guard case .complete = source.outcome else { throw DeviceContractError.invalid("hidInventoryIncomplete") }
        let candidates: [HIDDeviceNode]
        switch endpoint.address {
        case .hid(let id, _, _): candidates = source.values.filter { $0.id == id }
        case .usb(let id, _): candidates = source.values.filter {
            $0.usbDeviceID == id && $0.vendor == 0x1462 && $0.product == 0x3fa4
        }
        default: throw DeviceContractError.invalid("selectedMSIEndpoint")
        }
        guard candidates.count == 1, let selected = candidates.first else {
            throw DeviceContractError.invalid(candidates.isEmpty ? "absentEndpoint" : "ambiguousEndpoint")
        }
        guard selected.vendor.flatMap(UInt32.init(exactly:)) == endpoint.identity.vendorID,
              selected.product.flatMap(UInt32.init(exactly:)) == endpoint.identity.productID,
              selected.transport == endpoint.identity.transport else { throw DeviceContractError.invalid("staleEndpoint") }
        if case .hid(_, let usb, let interface) = endpoint.address {
            guard selected.usbDeviceID == usb, selected.interfaceID == interface,
                  selected.interfaceNumber == endpoint.identity.interfaceNumber,
                  Set(selected.usages) == Set(endpoint.identity.usages) else { throw DeviceContractError.invalid("staleEndpoint") }
        }
        return selected
    }

    private static func openSelectedInterface(for endpoint: DeviceEndpoint) throws -> IOHIDDevice {
        let selected = try selectedInterface(for: endpoint, from: USBDeviceGraph.enumerateHID())
        guard let matching = IORegistryEntryIDMatching(selected.id) else { throw DeviceContractError.invalid("absentEndpoint") }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw DeviceContractError.invalid("absentEndpoint") }
        defer { IOObjectRelease(service) }
        var registryID: UInt64 = 0
        guard IOObjectConformsTo(service, "IOHIDDevice") != 0,
              IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS, registryID == selected.id,
              MacUSBPeripheralReader.number(service, "VendorID") == selected.vendor,
              MacUSBPeripheralReader.number(service, "ProductID") == selected.product,
              MacUSBPeripheralReader.usbAncestor(service, includingSelf: true) == selected.usbDeviceID,
              MacUSBPeripheralReader.vendorInterfaceID(service) == selected.interfaceID,
              let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { throw DeviceContractError.invalid("staleEndpoint") }
        // No manager is opened on this path: IOHIDManagerOpen would also open
        // every other matching current/future controller before filtering.
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw ScreenError.message("Cannot open selected MSI HID interface: \(result)") }
        return device
    }

    /// The guard borrows the coordinator's actual open descriptions. This
    /// synchronous session must be destroyed on this thread before any await.
    convenience init(selectedEndpoint: DeviceEndpoint, borrowedLease: DeviceResourceLock, replyBudget: TimeInterval = 6) throws {
        let usb: UInt64
        switch selectedEndpoint.address {
        case .usb(let id, _), .hid(_, let id?, _): usb = id
        default: throw DeviceContractError.invalid("selectedMSIEndpoint")
        }
        guard selectedEndpoint.identity.vendorID == 0x1462, selectedEndpoint.identity.productID == 0x3fa4 else {
            throw DeviceContractError.invalid("selectedMSIEndpoint")
        }
        try self.init(replyBudget: replyBudget, selectedEndpoint: selectedEndpoint, borrowedLease: borrowedLease, expectedUSBID: usb)
    }

    private init(replyBudget: TimeInterval?, selectedEndpoint: DeviceEndpoint?, borrowedLease: DeviceResourceLock, expectedUSBID: UInt64) throws {
        if let replyBudget, !replyBudget.isFinite || replyBudget <= 0 {
            throw ScreenError.message("USB read deadline expired")
        }
        replyBudgetDeadline = replyBudget.map { ProcessInfo.processInfo.systemUptime + $0 }
        let source = try USBDeviceGraph.enumerateUSB()
        let required: DeviceResourceLock.Request
        if let selectedEndpoint {
            let graph = try MacUSBPeripheralReader.controlGraph(from: source)
            required = try DeviceResourceLock.selectedRequest(selectedEndpoint, graph: graph)
        } else {
            let selection = try Self.builtInSelection(from: source)
            guard selection.usbID == expectedUSBID else { throw DeviceContractError.invalid("staleEndpoint") }
            required = selection.request
        }
        guard borrowedLease.covers(required), borrowedLease.descriptor(forLegacy: "controller.lock") != nil else {
            throw DeviceContractError.invalid("missingBorrowedLease")
        }
        resourceLease = borrowedLease
        if let selectedEndpoint {
            manager = nil
            device = try Self.openSelectedInterface(for: selectedEndpoint)
        } else {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
            self.manager = manager
            IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1462, kIOHIDProductIDKey: 0x3fa4] as CFDictionary)
            let opened = IOHIDManagerOpen(manager, 0)
            guard opened == kIOReturnSuccess else { throw ScreenError.message("Cannot open MSI HID manager: \(opened)") }
            let allDevices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            let devices = allDevices.filter {
                MacUSBPeripheralReader.usbAncestor(IOHIDDeviceGetService($0), includingSelf: true) == expectedUSBID
            }
            guard devices.count == 1, allDevices.count == 1, let found = devices.first else {
                IOHIDManagerClose(manager, 0)
                if allDevices.isEmpty { throw HIDConnectionError.notPresent }
                if devices.isEmpty { throw DeviceContractError.invalid("staleEndpoint") }
                throw ScreenError.message("Expected one MSI USB controller; found \(devices.count). Connect the monitor's USB upstream cable to this Mac.")
            }
            device = found
        }
        buffer = .allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, result, _, _, _, report, count in
            guard let context else { return }
            let connection = Unmanaged<HIDConnection>.fromOpaque(context).takeUnretainedValue()
            if result == kIOReturnSuccess {
                connection.reply = Array(UnsafeBufferPointer(start: report, count: count))
            } else {
                connection.callbackError = result
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        if let manager { IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue) }
        else { IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
    }

    deinit {
        if let manager { IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue) }
        else { IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue) }
        // IOKit keys callback registrations by context, including removal.
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil,
                                              Unmanaged.passUnretained(self).toOpaque())
        if let manager { IOHIDManagerClose(manager, 0) }
        else { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        buffer.deallocate()
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion) }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion) }
    }

    public func query(_ code: String) throws -> [UInt8] {
        try MSIProtocol.value(exchange(MSIProtocol.query(code)), for: code)
    }

    public func writeSetting(_ setting: MonitorSetting, value: Int) throws {
        try MSIProtocol.acknowledge(exchange(MSIProtocol.setting(setting, value: value)))
    }

    public func writeLayout(_ state: ScreenState, primaryChanged: Bool) throws {
        let reports = try MSIProtocol.layoutReports(state, primaryChanged: primaryChanged)
        // Keep the Mac video path awake through a requested layout transition.
        // Hold these through the settle/readback interval, then release with
        // this connection; status, dry-run and unchanged requests never wake it.
        if displayAssertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "Apply MSI display layout" as CFString, &displayAssertion)
            guard result == kIOReturnSuccess else { throw ScreenError.message("Cannot keep the display awake: \(result)") }
        }
        let wake = IOPMAssertionDeclareUserActivity("Apply MSI display layout" as CFString,
                                                   kIOPMUserActiveLocal, &activityAssertion)
        guard wake == kIOReturnSuccess else { throw ScreenError.message("Cannot wake the display: \(wake)") }
        for report in reports {
            try MSIProtocol.acknowledge(exchange(report))
        }
    }

    func writeKVM(_ route: KVMRoute) -> KVMWriteReceipt {
        var attempted = false
        do {
            let packet = try MSIProtocol.kvm(route)
            discardReplies()
            attempted = true
            let result = packet.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, packet.count)
            }
            guard result == kIOReturnSuccess else { throw ScreenError.message("USB report failed: \(result)") }
            // Live bidirectional tests show KVM removes this interface before
            // ACK delivery. Sending once, then reading the destination is both
            // faster and stronger evidence than waiting on a disconnected host.
            return KVMWriteReceipt(attempted: true, completed: true, acknowledged: false, error: nil)
        } catch {
            return KVMWriteReceipt(attempted: attempted, completed: false,
                                   acknowledged: false, error: String(describing: error))
        }
    }

    private func discardReplies() {
        // Drain earlier input before associating a new reply with this request.
        for _ in 0..<32 {
            if CFRunLoopRunInMode(.defaultMode, 0, true) != .handledSource { break }
        }
        reply = nil
        callbackError = nil
    }

    private func exchange(_ bytes: [UInt8]) throws -> [UInt8] {
        discardReplies()
        if let deadline = replyBudgetDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
            throw ScreenError.message("USB read deadline expired")
        }
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, bytes.count)
        }
        guard result == kIOReturnSuccess else {
            throw ScreenError.message("USB report failed: \(result)")
        }
        // A one-second reply deadline expired after input changes; a longer
        // wait completed the same request without resending. Wait only as needed;
        // ordinary replies still return immediately, without resending it.
        let deadline = min(ProcessInfo.processInfo.systemUptime + 3, replyBudgetDeadline ?? .infinity)
        while reply == nil && callbackError == nil && ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        if let callbackError { throw ScreenError.message("USB input failed: \(callbackError)") }
        guard let reply else {
            let command = String(decoding: bytes.dropFirst().prefix(7), as: UTF8.self)
            throw ScreenError.message("No HID reply for \(command) within 3 seconds; read status before retrying a change")
        }
        return reply
    }
}
