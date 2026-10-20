import Foundation

/// Fixed read-only HID++ getters. Feature indexes come from this device's
/// FeatureSet; an advertised ID never authorizes a setter or an event stream.
final class POPKeyboardProbe {
    private let expected: PairedUSBPeripheral
    private let request: (BoltReadRequest) throws -> BoltReadReply?
    private var softwareID: UInt8 = UInt8.random(in: 1...15)
    private var stopped = false
    private var errors: [String] = []
    private var features: [HIDPPFeature] = []
    private var featureComplete = false
    private var firmware: [PeripheralFirmware] = []
    private var battery: PeripheralBattery?
    private var fnMode: PeripheralFnMode?
    private var controls: [PeripheralControl] = []
    private var controlsComplete = false

    init(expected: PairedUSBPeripheral, request: @escaping (BoltReadRequest) throws -> BoltReadReply?) throws {
        try Self.validateExpected(expected)
        self.expected = expected
        self.request = request
    }

    static func validateExpected(_ expected: PairedUSBPeripheral) throws {
        guard (1...6).contains(expected.slot), expected.kind == .keyboard,
              expected.name == "Logi POP Keys" || expected.name == "POP Keys",
              expected.wirelessProductID.utf8.count == 4,
              expected.wirelessProductID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ScreenError.message("Select a POP Keys keyboard from the peripheral list")
        }
    }

    func read(hostName: String, platform: MachinePlatform) throws -> POPKeyboardDetails {
        guard case .pairing(.keyboard, let product)? = try request(.pairing(expected.slot)),
              product.uppercased() == expected.wirelessProductID.uppercased(),
              case .name(let name, false)? = try request(.name(expected.slot)),
              name == "Logi POP Keys" || name == "POP Keys",
              case .pong(let version)? = try request(.ping(expected.slot, softwareID: softwareID, mark: UInt8.random(in: 0...255))),
              let major = Int(version.split(separator: ".").first ?? ""), major >= 2 else {
            throw ScreenError.message("POP Keys identity or radio response changed; refresh peripherals")
        }
        capture("Feature discovery") { try discoverFeatures() }
        if !stopped { capture("Firmware") { try readFirmware() } }
        if !stopped { capture("Battery") { try readBattery() } }
        if !stopped { capture("Function-key mode") { try readFnMode() } }
        if !stopped { capture("Control mappings") { try readControls() } }
        return POPKeyboardDetails(schemaVersion: 1, checkedAt: Date(), hostName: hostName, platform: platform,
            slot: expected.slot, wirelessProductID: product, name: name, features: features,
            featureInventoryComplete: featureComplete, firmware: firmware, battery: battery, fnMode: fnMode,
            controls: controls, controlInventoryComplete: controlsComplete, errors: errors)
    }

    private func capture(_ label: String, _ work: () throws -> Void) {
        do { try work() } catch { errors.append("\(label): \(error)") }
    }

    private func get(_ index: Int, _ function: UInt8, _ parameters: [UInt8] = [], length: Int) throws -> [UInt8] {
        guard !stopped else { throw ScreenError.message("Read window ended") }
        softwareID = softwareID % 15 + 1
        let reply: BoltReadReply?
        do {
            reply = try request(.feature(slot: expected.slot, index: UInt8(index), function: function,
                                         softwareID: softwareID, parameters: parameters, responseLength: length))
        } catch {
            stopped = true
            throw error
        }
        if case .feature(let bytes)? = reply { return bytes }
        if case .featureError(let code)? = reply { throw ScreenError.message("HID++ getter returned error \(code)") }
        // GetFeatureID/GetCidInfo don't echo their requested table index.
        // Never move to another entry after a timeout and accept a late reply.
        stopped = true
        throw ScreenError.message("Query did not respond; remaining details were not read")
    }

    private func feature(_ id: Int) -> HIDPPFeature? { features.first { $0.id == id && $0.index > 0 } }
    private func word(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }

    private func discoverFeatures() throws {
        let root = try get(0, 0, [0, 1], length: 3)
        guard root[0] > 0 else { throw ScreenError.message("FeatureSet is unavailable") }
        let index = Int(root[0])
        let count = Int(try get(index, 0, length: 1)[0]) + 1
        var complete = count <= 64
        if !complete { errors.append("Feature inventory exceeds the 64-entry read limit") }
        for position in 0..<min(count, 64) {
            do {
                let bytes = try get(index, 1, [UInt8(position)], length: 4)
                let id = word(bytes, 0)
                guard !features.contains(where: { $0.id == id }) else {
                    throw ScreenError.message("Feature inventory contains a duplicate identifier")
                }
                features.append(HIDPPFeature(id: id, index: position, version: Int(bytes[3]), flags: Int(bytes[2])))
            } catch {
                complete = false
                errors.append("Feature index \(position): \(error)")
                if stopped { break }
            }
        }
        featureComplete = complete && features.count == count
    }

    private func readFirmware() throws {
        guard let feature = feature(3) else { return }
        let count = Int(try get(feature.index, 0, length: 1)[0])
        if count > 8 { errors.append("Firmware inventory exceeds the 8-entry read limit") }
        for entity in 0..<min(count, 8) {
            let bytes = try get(feature.index, 1, [UInt8(entity)], length: 8)
            switch bytes[0] & 0x0f {
            case 0, 1:
                let prefixBytes = Array(bytes[1...3])
                guard prefixBytes.allSatisfy({ (32...126).contains($0) }) else {
                    throw ScreenError.message("Firmware prefix is not printable ASCII")
                }
                firmware.append(PeripheralFirmware(kind: bytes[0] & 0x0f == 0 ? .firmware : .bootloader,
                    prefix: String(decoding: prefixBytes, as: UTF8.self),
                    version: String(format: "%02X.%02X", bytes[4], bytes[5]), build: word(bytes, 6)))
            case 2:
                firmware.append(PeripheralFirmware(kind: .hardware, prefix: nil, version: String(bytes[1]), build: nil))
            default:
                firmware.append(PeripheralFirmware(kind: .other, prefix: nil, version: nil, build: nil))
            }
        }
    }

    private func readBattery() throws {
        if let feature = feature(0x1004) {
            let bytes = try get(feature.index, 1, length: 4)
            guard bytes[0] <= 100 else { throw ScreenError.message("Invalid battery percentage") }
            battery = PeripheralBattery(featureID: feature.id, percentage: bytes[0] == 0 ? nil : Int(bytes[0]),
                level: [1: .critical, 2: .low, 4: .good, 8: .full][Int(bytes[1])],
                statusCode: Int(bytes[2]), voltageMillivolts: nil)
        } else if let feature = feature(0x1000) {
            let bytes = try get(feature.index, 0, length: 3)
            guard bytes[0] <= 100 else { throw ScreenError.message("Invalid battery percentage") }
            battery = PeripheralBattery(featureID: feature.id, percentage: bytes[0] == 0 ? nil : Int(bytes[0]),
                level: nil, statusCode: Int(bytes[2]), voltageMillivolts: nil)
        } else if let feature = feature(0x1001) {
            let bytes = try get(feature.index, 0, length: 3)
            battery = PeripheralBattery(featureID: feature.id, percentage: nil, level: nil,
                statusCode: nil, voltageMillivolts: word(bytes, 0))
        }
    }

    private func readFnMode() throws {
        if let feature = feature(0x40a2) {
            let bytes = try get(feature.index, 0, length: 2)
            fnMode = PeripheralFnMode(featureID: feature.id, inverted: bytes[0] & 1 != 0, defaultInverted: bytes[1] & 1 != 0)
        } else if let feature = feature(0x40a0) {
            let bytes = try get(feature.index, 0, length: 1)
            guard bytes[0] <= 1 else { throw ScreenError.message("Invalid function-key mode") }
            fnMode = PeripheralFnMode(featureID: feature.id, inverted: bytes[0] != 0, defaultInverted: nil)
        } else if feature(0x40a3) != nil {
            errors.append("Host-specific function-key mode is advertised; its current host setting is not read")
        }
    }

    private func readControls() throws {
        guard let feature = feature(0x1b04) else { return }
        let count = Int(try get(feature.index, 0, length: 1)[0])
        var complete = count <= 32
        if !complete { errors.append("Control inventory exceeds the 32-entry read limit") }
        for position in 0..<min(count, 32) {
            let bytes = try get(feature.index, 1, [UInt8(position)], length: 9)
            let cid = word(bytes, 0)
            guard !controls.contains(where: { $0.controlID == cid }) else {
                throw ScreenError.message("Control inventory contains a duplicate identifier")
            }
            var mapped: Int?
            var reporting: Int?
            do {
                let mapping = try get(feature.index, 2, [bytes[0], bytes[1]], length: 6)
                guard word(mapping, 0) == cid else { throw ScreenError.message("Control mapping did not echo its identifier") }
                mapped = word(mapping, 3) == 0 ? cid : word(mapping, 3)
                reporting = Int(mapping[2]) | Int(mapping[5]) << 8
            } catch {
                complete = false
                errors.append(String(format: "Control 0x%04X: %@", cid, String(describing: error)))
            }
            controls.append(PeripheralControl(controlID: cid, defaultTaskID: word(bytes, 2),
                flags: Int(bytes[4]) | Int(bytes[8]) << 8, position: Int(bytes[5]), group: Int(bytes[6]),
                groupMask: Int(bytes[7]), currentControlID: mapped, reportingFlags: reporting))
            if stopped { break }
        }
        controlsComplete = complete && controls.count == count
    }
}
