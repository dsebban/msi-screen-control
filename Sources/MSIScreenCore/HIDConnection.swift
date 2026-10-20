import Foundation
import IOKit.hid
import IOKit.pwr_mgt
import CoreGraphics
import Darwin

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
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let runLoop = CFRunLoopGetCurrent()!
    private let buffer: UnsafeMutablePointer<UInt8>
    private var reply: [UInt8]?
    private var callbackError: IOReturn?
    private let lockFD: Int32
    private var displayAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0

    public init() throws {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("msi-screen-control", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        lockFD = open(cache.appendingPathComponent("controller.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw ScreenError.message("Cannot open controller lock") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD)
            throw ScreenError.message("Another msi-screen process is using the monitor")
        }
        manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1462, kIOHIDProductIDKey: 0x3fa4] as CFDictionary)
        let opened = IOHIDManagerOpen(manager, 0)
        guard opened == kIOReturnSuccess else {
            close(lockFD)
            throw ScreenError.message("Cannot open MSI HID manager: \(opened)")
        }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard devices.count == 1, let found = devices.first else {
            IOHIDManagerClose(manager, 0)
            close(lockFD)
            throw ScreenError.message("Expected one MSI USB controller; found \(devices.count). Connect the monitor's USB upstream cable to this Mac.")
        }
        device = found
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
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        IOHIDManagerClose(manager, 0)
        buffer.deallocate()
        close(lockFD)
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion) }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion) }
    }

    public func query(_ code: String) throws -> [UInt8] {
        try MSIProtocol.value(exchange(MSIProtocol.query(code)), for: code)
    }

    public func writeLayout(_ state: ScreenState) throws {
        let report = try MSIProtocol.layout(state)
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
        try MSIProtocol.acknowledge(exchange(report))
    }

    private func exchange(_ bytes: [UInt8]) throws -> [UInt8] {
        // Drain earlier input before associating a new reply with this request.
        for _ in 0..<32 {
            if CFRunLoopRunInMode(.defaultMode, 0, true) != .handledSource { break }
        }
        reply = nil
        callbackError = nil
        let result = bytes.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1, $0.baseAddress!, bytes.count)
        }
        guard result == kIOReturnSuccess else {
            throw ScreenError.message("USB report failed: \(result)")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while reply == nil && callbackError == nil && ProcessInfo.processInfo.systemUptime < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        if let callbackError { throw ScreenError.message("USB input failed: \(callbackError)") }
        guard let reply else { throw ScreenError.message("No HID reply within 1 second; read status before retrying a change") }
        return reply
    }
}
