import Foundation
import GameController
import IOKit.hid

public struct ControllerHIDDevice: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let transport: String
    public let vendorID: String
    public let productID: String
    public let supportedByMacOS: Bool
}

public struct ControllerProfile: Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let category: String
    public let batteryPercent: Int?
    public let buttons: [String]
    public let directionPads: [String]
    public let mappings: [String: String]
    public let supportsMotion: Bool
    public let supportsHaptics: Bool
    public let supportsLight: Bool
}

public struct GameControllerSnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let hostName: String
    public let devices: [ControllerHIDDevice]
    public let profiles: [ControllerProfile]
}

public struct GameControllerProbeResult: Codable, Equatable {
    public let schemaVersion: Int
    public let checkedAt: Date
    public let durationSeconds: Int
    public let controllerNames: [String]
    /// Observed native input changes; zero is inconclusive, not a hardware fault.
    public let changesByControl: [String: Int]
}

/// Local controller state is independent of the monitor's USB owner. Bluetooth
/// controllers cannot move with the hub. No discovery/pairing or idle polling.
@MainActor
public enum GameControllerClient {
    private static var probing = false

    nonisolated static func isController(name: String, usagePage: Int, usage: Int) -> Bool {
        name == "BSP-D8" || (usagePage == 1 && (usage == 4 || usage == 5))
    }

    public static func read() async throws -> GameControllerSnapshot {
        _ = GCController.controllers()
        // The framework delivers existing-controller discovery asynchronously.
        // This bounded initial settle is only paid on an explicit refresh.
        try await Task.sleep(nanoseconds: 250_000_000)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        var devicesByID: [String: ControllerHIDDevice] = [:]
        for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] {
            func property(_ key: String) -> CFTypeRef? { IOHIDDeviceGetProperty(device, key as CFString) }
            let name = property(kIOHIDProductKey) as? String ?? "Game controller"
            // Product-only matching yielded unrelated HID devices on this Mac.
            // Filter the actual primary usage before querying native support.
            guard isController(name: name,
                usagePage: (property(kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue ?? 0,
                usage: (property(kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue ?? 0) else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID) == KERN_SUCCESS,
                  devicesByID[String(registryID)] == nil else { continue }
            devicesByID[String(registryID)] = ControllerHIDDevice(id: String(registryID), name: name,
                transport: property(kIOHIDTransportKey) as? String ?? "Unknown",
                vendorID: String(format: "%04x", (property(kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0),
                productID: String(format: "%04x", (property(kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0),
                supportedByMacOS: GCController.supportsHIDDevice(device))
        }
        let profiles = GCController.controllers().enumerated().map { index, controller in
            let input = controller.physicalInputProfile
            let names = input.buttons.keys.sorted()
            let battery = controller.battery.flatMap { $0.batteryState == .unknown ? nil : $0.batteryLevel }
            return ControllerProfile(id: index, name: controller.vendorName ?? "Game controller",
                category: controller.productCategory,
                batteryPercent: battery.flatMap { $0.isFinite && (0...1).contains($0) ? Int(($0 * 100).rounded()) : nil },
                buttons: names, directionPads: input.dpads.keys.sorted(),
                mappings: names.reduce(into: [:]) { result, name in
                    result[name] = input.mappedElementAlias(forPhysicalInputName: name)
                },
                supportsMotion: controller.motion != nil, supportsHaptics: controller.haptics != nil,
                supportsLight: controller.light != nil)
        }
        return GameControllerSnapshot(schemaVersion: 1, checkedAt: Date(),
            hostName: MacUSBPeripheralReader.hostName,
            devices: devicesByID.values.sorted { $0.id < $1.id }, profiles: profiles)
    }

    public static func probe(seconds: Int) async throws -> GameControllerProbeResult {
        guard (1...15).contains(seconds) else { throw ScreenError.message("Controller test duration must be 1–15 seconds") }
        guard !probing else { throw ScreenError.message("A controller test is already running") }
        probing = true
        defer { probing = false }
        _ = try await read()
        let controllers = GCController.controllers()
        guard !controllers.isEmpty else {
            throw ScreenError.message("No native game controller is available. Pair the BSP-D8 in Xbox mode, then refresh.")
        }
        let previousBackground = GCController.shouldMonitorBackgroundEvents
        let previousHandlers = controllers.map { $0.physicalInputProfile.valueDidChangeHandler }
        let previousQueues = controllers.map(\.handlerQueue)
        var changes: [String: Int] = [:]
        GCController.shouldMonitorBackgroundEvents = true
        defer {
            for (index, controller) in controllers.enumerated() {
                controller.physicalInputProfile.valueDidChangeHandler = previousHandlers[index]
                controller.handlerQueue = previousQueues[index]
            }
            GCController.shouldMonitorBackgroundEvents = previousBackground
        }
        for (index, controller) in controllers.enumerated() {
            controller.handlerQueue = .main
            controller.physicalInputProfile.valueDidChangeHandler = { profile, element in
                MainActor.assumeIsolated {
                    guard let name = profile.elements.first(where: { $0.value === element })?.key else { return }
                    changes["\(index):\(name)", default: 0] += 1
                }
            }
        }
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        return GameControllerProbeResult(schemaVersion: 1, checkedAt: Date(), durationSeconds: seconds,
            controllerNames: controllers.map { $0.vendorName ?? "Game controller" }, changesByControl: changes)
    }
}
