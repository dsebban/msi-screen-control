import Foundation

public enum DeviceContractError: Error, Equatable, Sendable {
    case invalid(String)
}

/// Strict boundaries are opt-in. Legacy decoders use only the duplicate-key scan.
public enum StrictJSON {
    public static let byteLimit = 256 * 1024

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= byteLimit, let text = String(data: data, encoding: .utf8) else {
            throw DeviceContractError.invalid("invalidUTF8OrSize")
        }
        try rejectDuplicateKeys(text)
        try rejectNonIntegerNumbers(data)
        // Foundation validates complete JSON grammar, including trailing data.
        guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
            throw DeviceContractError.invalid("objectRequired")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    // JSONDecoder alone accepts 1.0 for Int, which would change an
    // authenticated canonical representation after decoding.
    private static func rejectNonIntegerNumbers(_ data: Data) throws {
        var quoted = false
        var escaped = false
        var number = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true; number = false }
            else {
                if number && [46, 101, 69].contains(byte) { throw DeviceContractError.invalid("nonIntegerNumber") }
                if (48...57).contains(byte) || byte == 45 { number = true }
                else { number = false }
            }
        }
    }

    public static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= byteLimit else { throw DeviceContractError.invalid("size") }
        try rejectNonIntegerNumbers(data)
        return data
    }

    // Kept identical to the remote KVM scanner: extracting this must not tighten
    // legacy unknown-key/number/schema acceptance. JSON grammar is its decoder's job.
    static func rejectDuplicateKeys(_ text: String) throws {
        let bytes = Array(text.utf8)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 123 { objects.append([]); index += 1; continue }
            if bytes[index] == 125 { if !objects.isEmpty { objects.removeLast() }; index += 1; continue }
            guard bytes[index] == 34 else { index += 1; continue }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 { break }
                index += 1
            }
            guard index < bytes.count else { break }
            let end = index
            index += 1
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            if index < bytes.count, bytes[index] == 58 {
                guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...end])),
                      !objects.isEmpty, objects[objects.count - 1].insert(key).inserted else {
                    throw DeviceContractError.invalid("duplicateKey")
                }
            }
        }
    }
}

struct ContractKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension Decoder {
    func contractKeys(_ allowed: Set<String>) throws {
        let keys = try container(keyedBy: ContractKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: allowed) else { throw DeviceContractError.invalid("unknownKey") }
    }
}

func requireContract(_ condition: @autoclosure () -> Bool, _ code: String) throws {
    guard condition() else { throw DeviceContractError.invalid(code) }
}

func contractID(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46, 95, 45].contains($0)
    }
}

func contractLabel(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

func contractDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

func uniqueIDs(_ ids: [String]) -> Bool { ids.allSatisfy(contractID) && Set(ids).count == ids.count }
