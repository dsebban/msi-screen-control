import Darwin
import Foundation
import IOKit.hid

protocol HIDFeatureTransport: AnyObject {
    func get(_ report: HIDFeatureReport) throws -> [UInt8]
    func set(_ report: HIDFeatureReport, payload: [UInt8]) throws
    func settle(milliseconds: Int) throws
}

/// The logical profile has no report-ID byte. IOKit uses the ID as an API
/// argument and, for numbered reports, also as the report's first wire byte.
enum HIDReportNormalization {
    static func payload(_ wire: [UInt8], report: HIDFeatureReport) throws -> [UInt8] {
        if report.id == 0 {
            try requireContract(wire.count == report.length, "reportLength"); return wire
        }
        try requireContract(wire.count == report.length + 1 && wire.first == report.id, "reportIDOrLength")
        return Array(wire.dropFirst())
    }
    static func wire(_ payload: [UInt8], report: HIDFeatureReport) throws -> [UInt8] {
        try requireContract(payload.count == report.length, "reportLength")
        return (report.id == 0 ? [] : [report.id]) + payload
    }
}

/// All methods and teardown run synchronously on the worker's creating thread.
/// Open the exact registry service, never a VID/PID-wide IOHIDManager.
final class SelectedHIDFeatureTransport: HIDFeatureTransport {
    private let device: IOHIDDevice
    private let runLoop: CFRunLoop
    private let check: () throws -> Void
    init(endpoint: DeviceEndpoint, check: @escaping () throws -> Void) throws {
        self.check = check; try check()
        guard case .hid(let id, let usbID, let interfaceID) = endpoint.address else { throw DeviceContractError.invalid("profileRequiresHIDEndpoint") }
        let selected = try HIDConnection.selectedInterface(for: endpoint, from: USBDeviceGraph.enumerateHID())
        guard selected.id == id, let matching = IORegistryEntryIDMatching(id) else { throw DeviceContractError.invalid("staleEndpoint") }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw DeviceContractError.invalid("absentEndpoint") }
        defer { IOObjectRelease(service) }
        var actualID: UInt64 = 0
        guard IOObjectConformsTo(service, "IOHIDDevice") != 0,
              IORegistryEntryGetRegistryEntryID(service, &actualID) == KERN_SUCCESS, actualID == id,
              MacUSBPeripheralReader.usbAncestor(service, includingSelf: true) == usbID,
              MacUSBPeripheralReader.vendorInterfaceID(service) == interfaceID,
              MacUSBPeripheralReader.number(service, "VendorID") == selected.vendor,
              MacUSBPeripheralReader.number(service, "ProductID") == selected.product,
              let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { throw DeviceContractError.invalid("staleEndpoint") }
        try check()
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { throw DeviceContractError.invalid("deviceAccessDenied") }
        self.device = device; runLoop = CFRunLoopGetCurrent()
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
    }
    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    func get(_ report: HIDFeatureReport) throws -> [UInt8] {
        try check()
        var bytes = [UInt8](repeating: 0, count: report.length + (report.id == 0 ? 0 : 1))
        if report.id != 0 { bytes[0] = report.id }
        var count = bytes.count
        let result = bytes.withUnsafeMutableBufferPointer { IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(report.id), $0.baseAddress!, &count) }
        try requireContract(result == kIOReturnSuccess, "featureReadFailed")
        try check()
        return try HIDReportNormalization.payload(Array(bytes.prefix(count)), report: report)
    }
    func set(_ report: HIDFeatureReport, payload: [UInt8]) throws {
        try check(); let bytes = try HIDReportNormalization.wire(payload, report: report)
        let result = bytes.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(report.id), $0.baseAddress!, bytes.count) }
        try requireContract(result == kIOReturnSuccess, "featureWriteFailed")
    }
    func settle(milliseconds: Int) throws {
        let end = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
        while ProcessInfo.processInfo.systemUptime < end {
            try check(); Thread.sleep(forTimeInterval: min(0.01, end - ProcessInfo.processInfo.systemUptime))
        }
        try check()
    }
}

final class HIDFeatureProfileExecutor {
    let profile: HIDFeatureProfile
    let descriptor: DeviceDescriptor
    let identity: DeviceContractIdentity
    let transport: HIDFeatureTransport
    init(profile: HIDFeatureProfile, descriptor: DeviceDescriptor, identity: DeviceContractIdentity, transport: HIDFeatureTransport) throws {
        try profile.validate(descriptor: descriptor)
        self.profile = profile; self.descriptor = descriptor; self.identity = identity; self.transport = transport
    }
    func read() throws -> DeviceBackendState {
        var reports: [String: String] = [:]; var fields: [String: DeviceValue] = [:]
        for report in profile.reports {
            let payload = try transport.get(report)
            try requireContract(payload.count == report.length, "reportLength")
            // Every byte of any writable report is configuration/preservation
            // evidence. A separate read-only report contributes only explicitly
            // declared configuration fields; its telemetry is not round-tripped.
            if profile.fields.contains(where: { $0.reportID == report.id && $0.writable }) { reports[String(report.id)] = payload.hex }
            for field in profile.fields where field.reportID == report.id { fields[field.id] = try field.decode(payload) }
        }
        for (id, allowed) in profile.identities { try requireContract(fields[id].map { allowed.contains($0) } == true, "identityMismatch") }
        for guardRule in profile.guards { try guardRule.check(fields[guardRule.fieldID]) }
        let configurationFields = Set(descriptor.scopes.flatMap(\.observedFields))
        return try DeviceBackendState(identity: identity, values: profile.values(fields: fields, descriptor: descriptor),
            fields: fields.filter { configurationFields.contains($0.key) }, preservation: reports, unavailable: Dictionary(uniqueKeysWithValues: descriptor.capabilities.compactMap { cap in cap.unavailableReason.map { (cap.id, $0) } }))
    }
    func apply(_ operation: DeviceOperation, expected: DeviceBackendState) throws -> DeviceBackendApply {
        try descriptor.validate(operation: operation)
        try requireContract(operation.kind != .setLayoutAndUSB, "compositionRequiresStages")
        let before = try read()
        try requireContract(before.hasSameConfiguration(as: expected, descriptor: descriptor), "staleBaseline")
        let targets = try profile.targetFields(capabilityID: operation.capabilityID, target: operation.target)
        let boundFields = try targets.keys.map { id -> HIDFeatureField in
            guard let f = profile.fields.first(where: { $0.id == id }) else { throw DeviceContractError.invalid("fieldReference") }; return f
        }
        try requireContract(Set(boundFields.map(\.reportID)).count == 1, "singleReportWrite")
        let report = profile.reports.first { $0.id == boundFields[0].reportID }!
        let original = try HIDFeatureProfile.bytes(before.preservation[String(report.id)]!)
        var target = original
        for field in boundFields { try field.encode(targets[field.id]!, into: &target) }
        if target == original { return try DeviceBackendApply(before: before, after: before, attempted: false, completed: false, acknowledged: false) }
        // Exactly one setter and one settling interval. On any failure the host
        // retains its durable possible-write claim; this layer never retries.
        try transport.set(report, payload: target)
        let cap = descriptor.capabilities.first { $0.id == operation.capabilityID }!
        try transport.settle(milliseconds: cap.settlingMilliseconds)
        let after = try read()
        for (id, bytes) in before.preservation {
            try requireContract(after.preservation[id] == (id == String(report.id) ? target.hex : bytes), "fullReportMismatch")
        }
        try before.verifyTransition(to: after, operation: operation, descriptor: descriptor)
        return try DeviceBackendApply(before: before, after: after, attempted: true, completed: true, acknowledged: true)
    }
    static func selfTest(profile: HIDFeatureProfile, descriptor: DeviceDescriptor) throws {
        try profile.validate(descriptor: descriptor)
        let zero = String(repeating: "0", count: 64)
        let identity = try DeviceContractIdentity(deviceID: zero, incarnationID: zero, bindingID: "fixture", providerDigest: zero, domainID: zero)
        for fixture in profile.fixtures {
            let transport = try HIDFixtureTransport(profile: profile, reports: fixture.reports)
            let executor = try Self(profile: profile, descriptor: descriptor, identity: identity, transport: transport)
            let before = try executor.read()
            try requireContract(before.values == fixture.expectedValues, "fixtureValues")
            if let operation = fixture.operation {
                let result = try executor.apply(operation, expected: before)
                // Deterministic selfTest vectors still check every fixture
                // report, even those excluded from configuration commitments.
                let actualReports = Dictionary(uniqueKeysWithValues: transport.reports.map { (String($0.key), $0.value.hex) })
                try requireContract(actualReports == fixture.expectedReports && transport.setters == (result.attempted ? 1 : 0)
                    && transport.waits == (result.attempted ? 1 : 0), "fixtureApply")
            } else { try requireContract(fixture.expectedReports == fixture.reports, "fixtureReports") }
        }
    }
}

/// In-memory fixtures cannot resolve or open any live endpoint.
final class HIDFixtureTransport: HIDFeatureTransport {
    var reports: [UInt8: [UInt8]] = [:]
    var setters = 0
    var waits = 0
    var afterSet: ((inout [UInt8: [UInt8]]) -> Void)?
    init(profile: HIDFeatureProfile, reports: [String: String]) throws {
        try requireContract(Set(reports.keys) == Set(profile.reports.map { String($0.id) }), "fixtureReportSet")
        for report in profile.reports {
            let bytes = try HIDFeatureProfile.bytes(reports[String(report.id)]!)
            try requireContract(bytes.count == report.length, "fixtureReportLength"); self.reports[report.id] = bytes
        }
    }
    func get(_ report: HIDFeatureReport) throws -> [UInt8] {
        guard let bytes = reports[report.id] else { throw DeviceContractError.invalid("fixtureReport") }; return bytes
    }
    func set(_ report: HIDFeatureReport, payload: [UInt8]) throws { setters += 1; reports[report.id] = payload; afterSet?(&reports) }
    func settle(milliseconds: Int) throws { waits += 1 }
}
