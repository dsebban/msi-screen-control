import Foundation

public enum DisplayIdentificationError: String, Error, Codable, Equatable, Sendable {
    case invalidLength, invalidHeader, invalidChecksum, invalidExtension, invalidDataBlock
    case conflictingHDMIAddresses, invalidPhysicalAddress
}

/// A CEC topology address advertised by the sink. Its digits are not a promise
/// about a monitor's printed HDMI input labels or the source currently shown.
public struct HDMIPhysicalAddress: Codable, Equatable, Sendable {
    public let rawValue: UInt16
    public var dottedString: String {
        [12, 8, 4, 0].map { String((rawValue >> $0) & 15) }.joined(separator: ".")
    }

    public init(rawValue: UInt16) throws {
        guard rawValue != 0xffff else { throw DisplayIdentificationError.invalidPhysicalAddress }
        var ended = false
        for shift in [12, 8, 4, 0] {
            let digit = (rawValue >> shift) & 15
            guard !ended || digit == 0 else { throw DisplayIdentificationError.invalidPhysicalAddress }
            if digit == 0 { ended = true }
        }
        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey { case rawValue }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(rawValue: values.decode(UInt16.self, forKey: .rawValue))
    }
}

/// Public display identity only. Raw EDID and both numeric/textual serials are
/// deliberately excluded from its encoded form.
public struct DisplayIdentification: Codable, Equatable, Sendable {
    public let vendorID: UInt32
    public let productID: UInt32
    public let name: String?
    public let hdmiPhysicalAddress: HDMIPhysicalAddress?

    public init(edid: Data) throws {
        let bytes = [UInt8](edid)
        guard bytes.count >= 128, bytes.count <= 128 * 256, bytes.count % 128 == 0 else {
            throw DisplayIdentificationError.invalidLength
        }
        guard Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0] else {
            throw DisplayIdentificationError.invalidHeader
        }
        guard bytes.count == 128 * (1 + Int(bytes[126])) else {
            throw DisplayIdentificationError.invalidLength
        }
        for offset in stride(from: 0, to: bytes.count, by: 128) {
            guard bytes[offset..<offset + 128].reduce(0, { $0 + Int($1) }) % 256 == 0 else {
                throw DisplayIdentificationError.invalidChecksum
            }
        }
        vendorID = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        productID = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        var names: Set<String> = []
        for offset in stride(from: 54, through: 108, by: 18) {
            guard bytes[offset] == 0, bytes[offset + 1] == 0,
                  bytes[offset + 2] == 0, bytes[offset + 3] == 0xfc, bytes[offset + 4] == 0 else { continue }
            let text = bytes[offset + 5..<offset + 18].prefix { ![0, 10, 13].contains($0) }
            guard text.allSatisfy({ (0x20...0x7e).contains($0) }) else { continue }
            let value = String(bytes: text, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !value.isEmpty { names.insert(value) }
        }
        name = names.count == 1 ? names.first : nil

        var addresses: Set<UInt16> = []
        for offset in stride(from: 128, to: bytes.count, by: 128) {
            let block = Array(bytes[offset..<offset + 128])
            guard block[0] == 0x02 else { continue } // Other extension formats carry no parsed fields here.
            let end = Int(block[2])
            guard end == 0 || (4...127).contains(end) else {
                throw DisplayIdentificationError.invalidExtension
            }
            guard end != 0, block[1] >= 3 else { continue }
            var position = 4
            while position < end {
                let tag = block[position] >> 5
                let count = Int(block[position] & 31)
                let next = position + 1 + count
                guard next <= end else { throw DisplayIdentificationError.invalidDataBlock }
                if tag == 3 {
                    guard count >= 3 else { throw DisplayIdentificationError.invalidDataBlock }
                    let payload = Array(block[position + 1..<next])
                    if Array(payload.prefix(3)) == [0x03, 0x0c, 0x00] {
                        guard count >= 5 else { throw DisplayIdentificationError.invalidDataBlock }
                        let raw = UInt16(payload[3]) << 8 | UInt16(payload[4])
                        _ = try HDMIPhysicalAddress(rawValue: raw)
                        addresses.insert(raw)
                    }
                }
                position = next
            }
        }
        guard addresses.count <= 1 else { throw DisplayIdentificationError.conflictingHDMIAddresses }
        hdmiPhysicalAddress = try addresses.first.map { try HDMIPhysicalAddress(rawValue: $0) }
    }

    private enum CodingKeys: String, CodingKey { case vendorID, productID, name, hdmiPhysicalAddress }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vendorID = try values.decode(UInt32.self, forKey: .vendorID)
        productID = try values.decode(UInt32.self, forKey: .productID)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        hdmiPhysicalAddress = try values.decodeIfPresent(HDMIPhysicalAddress.self, forKey: .hdmiPhysicalAddress)
        guard vendorID <= 0xffff, productID <= 0xffff,
              name.map({ !$0.isEmpty && $0.utf8.count <= 13 && $0.utf8.allSatisfy { (0x20...0x7e).contains($0) } }) != false else {
            throw DisplayIdentificationError.invalidDataBlock
        }
    }
}
