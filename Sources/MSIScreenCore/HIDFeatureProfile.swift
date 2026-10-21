import Foundation

public enum HIDFieldCodec: String, Codable, Sendable {
    case u8, u16LE, u16BE, u32LE, u32BE, bits, asciiDecimal, enumBytes, asciiText
}

public struct HIDFeatureReport: Codable, Equatable, Sendable {
    public let id: UInt8
    /// Logical payload length, excluding the numbered report prefix.
    public let length: Int
    /// A source-reviewed promise: every byte is safe to round-trip. No masks.
    public let safeToRoundTrip: Bool
    private enum CodingKeys: String, CodingKey { case id, length, safeToRoundTrip }
    public init(id: UInt8, length: Int, safeToRoundTrip: Bool) {
        self.id = id; self.length = length; self.safeToRoundTrip = safeToRoundTrip
    }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "length", "safeToRoundTrip"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt8.self, forKey: .id); length = try c.decode(Int.self, forKey: .length)
        safeToRoundTrip = try c.decode(Bool.self, forKey: .safeToRoundTrip)
    }
}

public struct HIDFeatureField: Codable, Equatable, Sendable {
    public let id: String
    public let reportID: UInt8
    public let offset: Int
    public let width: Int
    public let codec: HIDFieldCodec
    public let bitOffset: Int
    public let bitCount: Int
    /// Choice ID to exact lowercase hex bytes. This must be a bijection.
    public let enumBytes: [String: String]
    public let writable: Bool
    private enum CodingKeys: String, CodingKey { case id, reportID, offset, width, codec, bitOffset, bitCount, enumBytes, writable }
    public init(id: String, reportID: UInt8, offset: Int, width: Int, codec: HIDFieldCodec,
                bitOffset: Int = 0, bitCount: Int = 0, enumBytes: [String: String] = [:], writable: Bool = false) {
        self.id = id; self.reportID = reportID; self.offset = offset; self.width = width; self.codec = codec
        self.bitOffset = bitOffset; self.bitCount = bitCount; self.enumBytes = enumBytes; self.writable = writable
    }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "reportID", "offset", "width", "codec", "bitOffset", "bitCount", "enumBytes", "writable"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); reportID = try c.decode(UInt8.self, forKey: .reportID)
        offset = try c.decode(Int.self, forKey: .offset); width = try c.decode(Int.self, forKey: .width)
        codec = try c.decode(HIDFieldCodec.self, forKey: .codec); bitOffset = try c.decode(Int.self, forKey: .bitOffset)
        bitCount = try c.decode(Int.self, forKey: .bitCount); enumBytes = try c.decode([String: String].self, forKey: .enumBytes)
        writable = try c.decode(Bool.self, forKey: .writable)
    }
    var bits: Set<Int> {
        if codec == .bits { return Set((offset * 8 + bitOffset)..<(offset * 8 + bitOffset + bitCount)) }
        return Set((offset * 8)..<((offset + width) * 8))
    }
    func validate(length: Int) throws {
        try requireContract(contractID(id) && offset >= 0 && width > 0 && width <= length && offset <= length - width, "fieldBounds")
        if codec == .bits {
            try requireContract(width == 1 && (0...7).contains(bitOffset) && (1...8).contains(bitCount)
                && bitCount <= 8 - bitOffset, "bitField")
        } else { try requireContract(bitOffset == 0 && bitCount == 0, "unexpectedBits") }
        switch codec {
        case .u8: try requireContract(width == 1, "codecWidth")
        case .u16LE, .u16BE: try requireContract(width == 2, "codecWidth")
        case .u32LE, .u32BE: try requireContract(width == 4, "codecWidth")
        case .asciiDecimal: try requireContract(width <= 19, "codecWidth")
        case .asciiText: try requireContract(width <= 128 && !writable, "writableText")
        case .enumBytes:
            try requireContract((1...32).contains(enumBytes.count) && uniqueIDs(Array(enumBytes.keys))
                && Set(enumBytes.values).count == enumBytes.count, "enumBijection")
            for value in enumBytes.values { let bytes = try HIDFeatureProfile.bytes(value); try requireContract(bytes.count == width, "enumWidth") }
        case .bits: break
        }
        if codec != .enumBytes { try requireContract(enumBytes.isEmpty, "unexpectedEnum") }
    }
    public func decode(_ report: [UInt8]) throws -> DeviceValue {
        try validate(length: report.count)
        let b = Array(report[offset..<(offset + width)])
        switch codec {
        case .enumBytes:
            guard let key = enumBytes.first(where: { $0.value == b.hex })?.key else { throw DeviceContractError.invalid("enumValue") }
            return .choice(key)
        case .asciiText:
            try requireContract(b.allSatisfy { (32...126).contains($0) }, "asciiText")
            return .text(String(decoding: b, as: UTF8.self))
        case .asciiDecimal:
            try requireContract(b.allSatisfy { (48...57).contains($0) }, "asciiDecimal")
            guard let number = Int64(String(decoding: b, as: UTF8.self)) else { throw DeviceContractError.invalid("codecOverflow") }
            return .integer(number)
        case .bits: return .integer(Int64((b[0] >> bitOffset) & UInt8((1 << bitCount) - 1)))
        default:
            let little = codec == .u8 || codec == .u16LE || codec == .u32LE
            let bytes = little ? b.reversed().map { $0 } : b
            return .integer(bytes.reduce(Int64(0)) { ($0 << 8) | Int64($1) })
        }
    }
    public func encode(_ value: DeviceValue, into report: inout [UInt8]) throws {
        try validate(length: report.count); try requireContract(writable, "readOnlyField")
        var bytes: [UInt8]
        if codec == .enumBytes {
            guard case .choice(let id) = value, let hex = enumBytes[id] else { throw DeviceContractError.invalid("enumValue") }
            bytes = try HIDFeatureProfile.bytes(hex)
        } else {
            guard case .integer(let n) = value, n >= 0 else { throw DeviceContractError.invalid("codecValue") }
            if codec == .asciiDecimal {
                let s = String(n); try requireContract(s.utf8.count <= width, "codecOverflow")
                bytes = Array((String(repeating: "0", count: width - s.utf8.count) + s).utf8)
            } else if codec == .bits {
                let mask = UInt8((1 << bitCount) - 1)
                try requireContract(n <= mask, "codecOverflow")
                report[offset] = (report[offset] & ~(mask << bitOffset)) | (UInt8(n) << bitOffset); return
            } else {
                try requireContract(codec != .asciiText && UInt64(n) < (UInt64(1) << (width * 8)), "codecOverflow")
                bytes = (0..<width).map { UInt8((UInt64(n) >> ($0 * 8)) & 255) }
                if codec == .u16BE || codec == .u32BE { bytes.reverse() }
            }
        }
        report.replaceSubrange(offset..<(offset + width), with: bytes)
    }
}

public enum HIDGuardKind: String, Codable, Sendable { case equals, notEquals, oneOf, integerRange }
public struct HIDFeatureGuard: Codable, Equatable, Sendable {
    public let fieldID: String
    public let kind: HIDGuardKind
    public let values: [DeviceValue]
    private enum CodingKeys: String, CodingKey { case fieldID, kind, values }
    public init(fieldID: String, kind: HIDGuardKind, values: [DeviceValue]) { self.fieldID = fieldID; self.kind = kind; self.values = values }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["fieldID", "kind", "values"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        fieldID = try c.decode(String.self, forKey: .fieldID); kind = try c.decode(HIDGuardKind.self, forKey: .kind)
        values = try c.decode([DeviceValue].self, forKey: .values)
    }
    func check(_ value: DeviceValue?) throws {
        guard let value else { throw DeviceContractError.invalid("missingGuard") }
        let matches: Bool
        switch kind {
        case .equals: matches = values.count == 1 && value == values[0]
        case .notEquals: matches = values.count == 1 && value != values[0]
        case .oneOf: matches = values.contains(value)
        case .integerRange:
            if values.count == 2, case .integer(let min) = values[0], case .integer(let max) = values[1], case .integer(let n) = value {
                matches = min <= n && n <= max
            } else { matches = false }
        }
        try requireContract(matches, "guardFailed")
    }
}

/// Components are fixed typed paths: value; template/slot.ID/option.ID;
/// destination; control.ID. They are not expressions or commands.
public struct HIDCapabilityFields: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let components: [String: String]
    private enum CodingKeys: String, CodingKey { case capabilityID, components }
    public init(capabilityID: String, components: [String: String]) { self.capabilityID = capabilityID; self.components = components }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["capabilityID", "components"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilityID = try c.decode(String.self, forKey: .capabilityID); components = try c.decode([String: String].self, forKey: .components)
    }
}

public struct HIDProfileFixture: Codable, Equatable, Sendable {
    public let reports: [String: String]
    public let expectedValues: [String: DeviceValue]
    public let operation: DeviceOperation?
    public let expectedReports: [String: String]
    private enum CodingKeys: String, CodingKey { case reports, expectedValues, operation, expectedReports }
    public init(reports: [String: String], expectedValues: [String: DeviceValue], operation: DeviceOperation?, expectedReports: [String: String]) {
        self.reports = reports; self.expectedValues = expectedValues; self.operation = operation; self.expectedReports = expectedReports
    }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["reports", "expectedValues", "operation", "expectedReports"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        reports = try c.decode([String: String].self, forKey: .reports); expectedValues = try c.decode([String: DeviceValue].self, forKey: .expectedValues)
        operation = try c.decodeIfPresent(DeviceOperation.self, forKey: .operation); expectedReports = try c.decode([String: String].self, forKey: .expectedReports)
    }
}

public struct HIDFeatureProfile: Codable, Equatable, Sendable {
    public let schema: Int
    public let engine: String
    public let reports: [HIDFeatureReport]
    public let fields: [HIDFeatureField]
    /// Every identity field is immutable and has a finite explicit allowlist.
    public let identities: [String: [DeviceValue]]
    public let guards: [HIDFeatureGuard]
    public let capabilities: [HIDCapabilityFields]
    public let fixtures: [HIDProfileFixture]
    private enum CodingKeys: String, CodingKey { case schema, engine, reports, fields, identities, guards, capabilities, fixtures }
    public init(reports: [HIDFeatureReport], fields: [HIDFeatureField], identities: [String: [DeviceValue]], guards: [HIDFeatureGuard], capabilities: [HIDCapabilityFields], fixtures: [HIDProfileFixture]) {
        schema = 1; engine = "hid-feature-fields-v1"; self.reports = reports; self.fields = fields
        self.identities = identities; self.guards = guards; self.capabilities = capabilities; self.fixtures = fixtures
    }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "engine", "reports", "fields", "identities", "guards", "capabilities", "fixtures"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); engine = try c.decode(String.self, forKey: .engine)
        reports = try c.decode([HIDFeatureReport].self, forKey: .reports); fields = try c.decode([HIDFeatureField].self, forKey: .fields)
        identities = try c.decode([String: [DeviceValue]].self, forKey: .identities); guards = try c.decode([HIDFeatureGuard].self, forKey: .guards)
        capabilities = try c.decode([HIDCapabilityFields].self, forKey: .capabilities); fixtures = try c.decode([HIDProfileFixture].self, forKey: .fixtures)
    }
    static func bytes(_ hex: String) throws -> [UInt8] {
        try requireContract(hex.utf8.count <= 8192 && hex.utf8.count % 2 == 0
            && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "reportHex")
        let b = Array(hex.utf8)
        return stride(from: 0, to: b.count, by: 2).map { UInt8(String(decoding: b[$0...($0 + 1)], as: UTF8.self), radix: 16)! }
    }
    public func validate(descriptor: DeviceDescriptor) throws {
        try descriptor.validate()
        try requireContract(schema == 1 && engine == "hid-feature-fields-v1" && (1...16).contains(reports.count)
            && Set(reports.map(\.id)).count == reports.count && reports.allSatisfy { (1...4096).contains($0.length) }
            && (1...128).contains(fields.count) && uniqueIDs(fields.map(\.id)) && !identities.isEmpty
            && (1...64).contains(fixtures.count) && guards.count <= 128, "profile")
        for field in fields {
            guard let report = reports.first(where: { $0.id == field.reportID }) else { throw DeviceContractError.invalid("fieldReport") }
            try field.validate(length: report.length)
            if field.writable { try requireContract(report.safeToRoundTrip && identities[field.id] == nil, "unsafeRoundTrip") }
        }
        // Validate every range before computing intersections: a later malformed
        // field must throw, never construct an invalid Range and trap the host.
        for field in fields {
            for other in fields where other.id != field.id && other.reportID == field.reportID && (field.writable || other.writable) {
                try requireContract(field.bits.isDisjoint(with: other.bits), "fieldOverlap")
            }
        }
        let writableBindings = capabilities.filter { binding in descriptor.capabilities.contains { $0.id == binding.capabilityID && $0.access == .readWrite } }.flatMap { $0.components.values }
        try requireContract(Set(writableBindings).count == writableBindings.count, "duplicateWritableBinding")
        for (id, allowed) in identities {
            guard let field = fields.first(where: { $0.id == id }) else { throw DeviceContractError.invalid("identityField") }
            try requireContract(!field.writable && (1...32).contains(allowed.count), "identityField")
            for value in allowed { try validate(value: value, field: field) }
        }
        for guardRule in guards {
            guard let field = fields.first(where: { $0.id == guardRule.fieldID }) else { throw DeviceContractError.invalid("guardReference") }
            try requireContract(!field.writable && (1...32).contains(guardRule.values.count), "guardDefinition")
            for value in guardRule.values { try validate(value: value, field: field) }
            switch guardRule.kind {
            case .equals, .notEquals: try requireContract(guardRule.values.count == 1, "guardDefinition")
            case .oneOf: break
            case .integerRange:
                guard guardRule.values.count == 2, case .integer(let lo) = guardRule.values[0], case .integer(let hi) = guardRule.values[1], lo <= hi else { throw DeviceContractError.invalid("guardDefinition") }
            }
        }
        try requireContract(Set(capabilities.map(\.capabilityID)) == Set(descriptor.capabilities.map(\.id))
            && uniqueIDs(capabilities.map(\.capabilityID)), "capabilityFields")
        for binding in capabilities {
            let cap = descriptor.capabilities.first { $0.id == binding.capabilityID }!
            let scope = descriptor.scopes.first { $0.id == cap.mutationScopeID }!
            let required = Self.components(for: cap.definition)
            try requireContract(Set(binding.components.keys) == required && Set(binding.components.values).count == binding.components.count, "completeFieldBinding")
            let bound = try binding.components.values.map { id -> HIDFeatureField in
                guard let field = fields.first(where: { $0.id == id }) else { throw DeviceContractError.invalid("fieldReference") }; return field
            }
            if cap.access == .readWrite {
                try requireContract(Set(binding.components.values).isSubset(of: Set(scope.observedFields)), "scopeFieldBinding")
                try requireContract(bound.allSatisfy(\.writable) && Set(bound.map(\.reportID)).count == 1
                    && Set(binding.components.values).isSubset(of: Set(scope.writableFields + scope.coupledFields)), "singleReportWrite")
            }
            func component(_ name: String) -> HIDFeatureField { fields.first { $0.id == binding.components[name]! }! }
            func choices(_ name: String, _ ids: Set<String>) throws {
                let field = component(name)
                try requireContract(field.codec == .enumBytes && Set(field.enumBytes.keys) == ids, "fieldChoiceDomain")
            }
            switch cap.definition {
            case .integer(let d):
                try validate(value: .integer(d.minimum), field: component("value")); try validate(value: .integer(d.maximum), field: component("value"))
            case .boolean:
                try validate(value: .integer(0), field: component("value")); try validate(value: .integer(1), field: component("value"))
            case .choice(let d): try choices("value", Set(d.map(\.id)))
            case .text(let d): try requireContract(component("value").codec == .asciiText && component("value").width <= d.maximumUTF8Bytes, "textField")
            case .layout(let d):
                try choices("template", Set(d.templates.map(\.id)))
                for id in Set(d.templates.flatMap { $0.slots.map(\.id) }) {
                    let allowed = Set(d.templates.flatMap { $0.slots.filter { $0.id == id }.flatMap(\.allowedInputIDs) })
                    try choices("slot." + id, allowed)
                }
                for option in d.options { try choices("option." + option.id, Set(option.choices.map(\.id))) }
            case .usbRoute(let d): try choices("destination", Set(d.destinations.map(\.id)))
            case .inputMapping(let d): for control in d.controls { try choices("control." + control.id, Set(d.actions.map(\.id))) }
            }
            for id in scope.requiredGuardFields {
                try requireContract(identities[id] != nil || guards.contains { $0.fieldID == id }, "missingGuard")
            }
        }
        for scope in descriptor.scopes {
            try requireContract(Set(scope.observedFields).isSubset(of: Set(fields.map(\.id))), "scopeFieldReference")
        }
        // Informational bindings may live outside configuration scopes, but no
        // declared identity/guard may disappear from stale/transition evidence.
        try requireContract(Set(identities.keys).union(guards.map(\.fieldID))
            .isSubset(of: Set(descriptor.scopes.flatMap(\.observedFields))), "scopeGuardReference")
    }
    private func validate(value: DeviceValue, field: HIDFeatureField) throws {
        switch (field.codec, value) {
        case (.enumBytes, .choice(let id)): try requireContract(field.enumBytes[id] != nil, "enumValue")
        case (.asciiText, .text(let text)): try requireContract(text.utf8.count == field.width && text.utf8.allSatisfy { (32...126).contains($0) }, "asciiText")
        case (_, .integer(let n)):
            try requireContract(field.codec != .enumBytes && field.codec != .asciiText && n >= 0, "fieldType")
            let writable = HIDFeatureField(id: field.id, reportID: field.reportID, offset: field.offset, width: field.width, codec: field.codec,
                bitOffset: field.bitOffset, bitCount: field.bitCount, enumBytes: field.enumBytes, writable: true)
            var b = [UInt8](repeating: 0, count: field.offset + field.width)
            try writable.encode(value, into: &b)
        default: throw DeviceContractError.invalid("fieldType")
        }
    }
    static func components(for definition: DeviceCapabilityDefinition) -> Set<String> {
        switch definition {
        case .layout(let d): return Set(["template"] + Set(d.templates.flatMap { $0.slots.map { "slot." + $0.id } }).sorted() + d.options.map { "option." + $0.id })
        case .usbRoute: return ["destination"]
        case .inputMapping(let d): return Set(d.controls.map { "control." + $0.id })
        default: return ["value"]
        }
    }
    func values(fields values: [String: DeviceValue], descriptor: DeviceDescriptor) throws -> [String: DeviceValue] {
        var result: [String: DeviceValue] = [:]
        for binding in capabilities {
            let cap = descriptor.capabilities.first { $0.id == binding.capabilityID }!
            if cap.unavailableReason != nil { continue }
            func component(_ name: String) throws -> DeviceValue {
                guard let id = binding.components[name], let value = values[id] else { throw DeviceContractError.invalid("missingField") }; return value
            }
            func choice(_ name: String) throws -> String {
                guard case .choice(let id) = try component(name) else { throw DeviceContractError.invalid("fieldType") }; return id
            }
            let value: DeviceValue
            switch cap.definition {
            case .boolean:
                guard case .integer(let n) = try component("value"), n == 0 || n == 1 else { throw DeviceContractError.invalid("booleanField") }
                value = .boolean(n == 1)
            case .layout(let d):
                let templateID = try choice("template")
                guard let template = d.templates.first(where: { $0.id == templateID }) else { throw DeviceContractError.invalid("templateMember") }
                var slots: [String: String] = [:]; var options: [String: String] = [:]
                for slot in template.slots { slots[slot.id] = try choice("slot." + slot.id) }
                for option in d.options { options[option.id] = try choice("option." + option.id) }
                value = .layout(try DeviceLayoutValue(templateID: templateID, slots: slots, options: options))
            case .usbRoute: value = .usbRoute(try DeviceUSBRouteValue(configuredDestinationID: choice("destination"), observedOwnerID: nil))
            case .inputMapping(let d):
                var mapping: [String: String] = [:]
                for control in d.controls { mapping[control.id] = try choice("control." + control.id) }; value = .inputMapping(mapping)
            default: value = try component("value")
            }
            try cap.definition.validate(value: value); result[cap.id] = value
        }
        return result
    }
    func targetFields(capabilityID: String, target: DeviceValue) throws -> [String: DeviceValue] {
        guard let binding = capabilities.first(where: { $0.capabilityID == capabilityID }) else { throw DeviceContractError.invalid("capabilityFields") }
        var components: [String: DeviceValue] = [:]
        switch target {
        case .boolean(let b): components["value"] = .integer(b ? 1 : 0)
        case .layout(let layout):
            components["template"] = .choice(layout.templateID)
            for (id, input) in layout.slots { components["slot." + id] = .choice(input) }
            for (id, value) in layout.options { components["option." + id] = .choice(value) }
        case .usbRoute(let route):
            try requireContract(route.observedOwnerID == nil, "routeIsNotOwnerObservation")
            components["destination"] = .choice(route.configuredDestinationID)
        case .inputMapping(let mapping): for (id, action) in mapping { components["control." + id] = .choice(action) }
        default: components["value"] = target
        }
        var result: [String: DeviceValue] = [:]
        for (component, value) in components {
            guard let id = binding.components[component] else { throw DeviceContractError.invalid("fieldReference") }; result[id] = value
        }
        return result
    }
}
