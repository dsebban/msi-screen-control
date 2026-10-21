import Foundation

// These are inert contracts. Authentication, persistence and dispatch belong to
// the later control runtime; decoding a declaration never authorizes a write.
public enum DeviceAccess: String, Codable, Sendable { case readOnly, readWrite }
public enum DeviceEvidenceKind: String, Codable, Sendable {
    case declared, deviceMetadata, sourceReview, vendorReview, offlineFixture, protocolReadback, physicalObservation
}
public enum DeviceTextExport: String, Codable, Sendable { case localOnly, sourceReviewedNonpersonal }
public enum DeviceCapabilityCategory: String, Codable, Sendable { case setting, layout, usb, input, information }
public enum DeviceVerificationKind: String, Codable, Sendable { case readback, configuredRoute, destinationObservation }
public enum DeviceControlReachability: String, Codable, Sendable { case remainsReachable, destinationRequired, unavailable }
public enum DeviceOperationKind: String, Codable, Sendable {
    case setCapability, setLayout, setUSBRoute, setInputMapping, setLayoutAndUSB
}
public enum DeviceMutationOutcome: String, Codable, Sendable { case notAttempted, noChange, verified, unverified, cancelled }

public struct DeviceUnavailable: Codable, Equatable, Sendable {
    public let code: String

    public init(code: String) throws {
        self.code = code
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case code }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["code"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(code), "unavailableCode")
    }
}

public struct DeviceEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let kind: DeviceEvidenceKind
    public let title: String
    public let exportPolicy: DeviceTextExport

    public init(id: String, kind: DeviceEvidenceKind, title: String, exportPolicy: DeviceTextExport) throws {
        self.id = id
        self.kind = kind
        self.title = title
        self.exportPolicy = exportPolicy
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, kind, title, exportPolicy }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "kind", "title", "exportPolicy"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(DeviceEvidenceKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        exportPolicy = try c.decode(DeviceTextExport.self, forKey: .exportPolicy)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(id) && contractLabel(title), "evidence")
        // A declaration is never upgraded to protocol or physical evidence here.
    }
}

public struct DeviceChoice: Codable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) throws {
        self.id = id
        self.title = title
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, title }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "title"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(id) && contractLabel(title), "choice")
    }
}

public struct DeviceIntegerDefinition: Codable, Equatable, Sendable {
    public let minimum: Int64
    public let maximum: Int64
    public let step: Int64
    public let unit: String?

    public init(minimum: Int64, maximum: Int64, step: Int64, unit: String?) throws {
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.unit = unit
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case minimum, maximum, step, unit }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["minimum", "maximum", "step", "unit"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minimum = try c.decode(Int64.self, forKey: .minimum)
        maximum = try c.decode(Int64.self, forKey: .maximum)
        step = try c.decode(Int64.self, forKey: .step)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        try validate()
    }
    public func validate() throws {
        try requireContract(minimum <= maximum && step > 0, "integerBounds")
        if let unit { try requireContract(contractLabel(unit), "unit") }
    }
}

public struct DeviceTextDefinition: Codable, Equatable, Sendable {
    public let maximumUTF8Bytes: Int
    public let exportPolicy: DeviceTextExport
    public let reviewEvidenceIDs: [String]

    public init(maximumUTF8Bytes: Int, exportPolicy: DeviceTextExport, reviewEvidenceIDs: [String]) throws {
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.exportPolicy = exportPolicy
        self.reviewEvidenceIDs = reviewEvidenceIDs
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case maximumUTF8Bytes, exportPolicy, reviewEvidenceIDs }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["maximumUTF8Bytes", "exportPolicy", "reviewEvidenceIDs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maximumUTF8Bytes = try c.decode(Int.self, forKey: .maximumUTF8Bytes)
        exportPolicy = try c.decode(DeviceTextExport.self, forKey: .exportPolicy)
        reviewEvidenceIDs = try c.decode([String].self, forKey: .reviewEvidenceIDs)
        try validate()
    }
    public func validate() throws {
        try requireContract((1...128).contains(maximumUTF8Bytes) && uniqueIDs(reviewEvidenceIDs), "text")
        try requireContract(exportPolicy == .localOnly || !reviewEvidenceIDs.isEmpty, "textReview")
    }
}

public struct DeviceRectangle: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let z: Int

    public init(x: Int, y: Int, width: Int, height: Int, z: Int) throws {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.z = z
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case x, y, width, height, z }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["x", "y", "width", "height", "z"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Int.self, forKey: .x)
        y = try c.decode(Int.self, forKey: .y)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        z = try c.decode(Int.self, forKey: .z)
        try validate()
    }
    public func validate() throws {
        try requireContract((0...10000).contains(x) && (0...10000).contains(y)
            && (1...10000).contains(width) && (1...10000).contains(height)
            && width <= 10000 - x && height <= 10000 - y && (0...7).contains(z), "rectangle")
    }
}

public struct DeviceLayoutSlot: Codable, Equatable, Sendable {
    public let id: String
    public let rectangle: DeviceRectangle
    public let allowedInputIDs: [String]

    public init(id: String, rectangle: DeviceRectangle, allowedInputIDs: [String]) throws {
        self.id = id
        self.rectangle = rectangle
        self.allowedInputIDs = allowedInputIDs
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, rectangle, allowedInputIDs }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "rectangle", "allowedInputIDs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rectangle = try c.decode(DeviceRectangle.self, forKey: .rectangle)
        allowedInputIDs = try c.decode([String].self, forKey: .allowedInputIDs)
        try validate()
    }
    public func validate() throws {
        try rectangle.validate()
        try requireContract(contractID(id) && !allowedInputIDs.isEmpty && uniqueIDs(allowedInputIDs), "slot")
    }
}

public struct DeviceLayoutTemplate: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let slots: [DeviceLayoutSlot]
    public let distinctInputs: Bool

    public init(id: String, title: String, slots: [DeviceLayoutSlot], distinctInputs: Bool) throws {
        self.id = id
        self.title = title
        self.slots = slots
        self.distinctInputs = distinctInputs
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, title, slots, distinctInputs }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "title", "slots", "distinctInputs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        slots = try c.decode([DeviceLayoutSlot].self, forKey: .slots)
        distinctInputs = try c.decode(Bool.self, forKey: .distinctInputs)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(id) && contractLabel(title) && (1...8).contains(slots.count)
            && uniqueIDs(slots.map(\.id)), "template")
        try slots.forEach { try $0.validate() }
        if distinctInputs {
            // Hall's condition is necessary and sufficient for a distinct
            // assignment: every subset needs at least as many allowed inputs.
            // Eight slots bound this check to 255 nonempty subsets.
            for mask in 1..<(1 << slots.count) {
                var allowed: Set<String> = []
                for index in slots.indices where mask & (1 << index) != 0 {
                    allowed.formUnion(slots[index].allowedInputIDs)
                }
                try requireContract(allowed.count >= mask.nonzeroBitCount, "infeasibleDistinctInputs")
            }
        }
    }
}

public struct DeviceLayoutOption: Codable, Equatable, Sendable {
    public let id: String
    public let choices: [DeviceChoice]

    public init(id: String, choices: [DeviceChoice]) throws {
        self.id = id
        self.choices = choices
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, choices }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "choices"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        choices = try c.decode([DeviceChoice].self, forKey: .choices)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(id) && (1...32).contains(choices.count) && uniqueIDs(choices.map(\.id)), "layoutOption")
        try choices.forEach { try $0.validate() }
    }
}

public struct DeviceLayoutDefinition: Codable, Equatable, Sendable {
    public let inputs: [DeviceChoice]
    public let templates: [DeviceLayoutTemplate]
    public let options: [DeviceLayoutOption]

    public init(inputs: [DeviceChoice], templates: [DeviceLayoutTemplate], options: [DeviceLayoutOption]) throws {
        self.inputs = inputs
        self.templates = templates
        self.options = options
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case inputs, templates, options }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["inputs", "templates", "options"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputs = try c.decode([DeviceChoice].self, forKey: .inputs)
        templates = try c.decode([DeviceLayoutTemplate].self, forKey: .templates)
        options = try c.decode([DeviceLayoutOption].self, forKey: .options)
        try validate()
    }
    public func validate() throws {
        try requireContract((1...32).contains(inputs.count) && (1...32).contains(templates.count)
            && options.count <= 32 && uniqueIDs(inputs.map(\.id)) && uniqueIDs(templates.map(\.id))
            && uniqueIDs(options.map(\.id)), "layoutDefinition")
        try inputs.forEach { try $0.validate() }; try templates.forEach { try $0.validate() }
        try options.forEach { try $0.validate() }
        let ids = Set(inputs.map(\.id))
        try requireContract(templates.allSatisfy { $0.slots.allSatisfy { Set($0.allowedInputIDs).isSubset(of: ids) } }, "slotInputs")
    }
}

public struct DeviceLayoutValue: Codable, Equatable, Sendable {
    public let templateID: String
    public let slots: [String: String]
    public let options: [String: String]

    public init(templateID: String, slots: [String: String], options: [String: String]) throws {
        self.templateID = templateID
        self.slots = slots
        self.options = options
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case templateID, slots, options }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["templateID", "slots", "options"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateID = try c.decode(String.self, forKey: .templateID)
        slots = try c.decode([String: String].self, forKey: .slots)
        options = try c.decode([String: String].self, forKey: .options)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(templateID) && uniqueIDs(Array(slots.keys)) && uniqueIDs(Array(options.keys))
            && slots.values.allSatisfy(contractID) && options.values.allSatisfy(contractID), "layoutValue")
    }
}

public struct DeviceUSBRouteDefinition: Codable, Equatable, Sendable {
    public let destinations: [DeviceChoice]
    public let affectedDomainID: String
    public let reachability: DeviceControlReachability

    public init(destinations: [DeviceChoice], affectedDomainID: String, reachability: DeviceControlReachability) throws {
        self.destinations = destinations
        self.affectedDomainID = affectedDomainID
        self.reachability = reachability
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case destinations, affectedDomainID, reachability }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["destinations", "affectedDomainID", "reachability"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinations = try c.decode([DeviceChoice].self, forKey: .destinations)
        affectedDomainID = try c.decode(String.self, forKey: .affectedDomainID)
        reachability = try c.decode(DeviceControlReachability.self, forKey: .reachability)
        try validate()
    }
    public func validate() throws {
        try requireContract((1...32).contains(destinations.count) && uniqueIDs(destinations.map(\.id))
            && contractID(affectedDomainID), "usbRoute")
        try destinations.forEach { try $0.validate() }
    }
}

public struct DeviceUSBRouteValue: Codable, Equatable, Sendable {
    public let configuredDestinationID: String
    public let observedOwnerID: String?

    public init(configuredDestinationID: String, observedOwnerID: String?) throws {
        self.configuredDestinationID = configuredDestinationID
        self.observedOwnerID = observedOwnerID
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case configuredDestinationID, observedOwnerID }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["configuredDestinationID", "observedOwnerID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configuredDestinationID = try c.decode(String.self, forKey: .configuredDestinationID)
        observedOwnerID = try c.decodeIfPresent(String.self, forKey: .observedOwnerID)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(configuredDestinationID) && observedOwnerID.map(contractID) != false, "usbRouteValue")
    }
}

public struct DeviceInputMappingDefinition: Codable, Equatable, Sendable {
    public let controls: [DeviceChoice]
    public let actions: [DeviceChoice]

    public init(controls: [DeviceChoice], actions: [DeviceChoice]) throws {
        self.controls = controls
        self.actions = actions
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case controls, actions }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["controls", "actions"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controls = try c.decode([DeviceChoice].self, forKey: .controls)
        actions = try c.decode([DeviceChoice].self, forKey: .actions)
        try validate()
    }
    public func validate() throws {
        try requireContract((1...128).contains(controls.count) && (1...128).contains(actions.count)
            && uniqueIDs(controls.map(\.id)) && uniqueIDs(actions.map(\.id)), "inputMapping")
        try controls.forEach { try $0.validate() }; try actions.forEach { try $0.validate() }
    }
}

public enum DeviceValue: Equatable, Sendable, Codable {
    case integer(Int64), boolean(Bool), choice(String), text(String)
    case layout(DeviceLayoutValue), usbRoute(DeviceUSBRouteValue), inputMapping([String: String])
    private enum CodingKeys: String, CodingKey { case kind, value }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["kind", "value"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "integer": self = .integer(try c.decode(Int64.self, forKey: .value))
        case "boolean": self = .boolean(try c.decode(Bool.self, forKey: .value))
        case "choice": self = .choice(try c.decode(String.self, forKey: .value))
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "layout": self = .layout(try c.decode(DeviceLayoutValue.self, forKey: .value))
        case "usbRoute": self = .usbRoute(try c.decode(DeviceUSBRouteValue.self, forKey: .value))
        case "inputMapping": self = .inputMapping(try c.decode([String: String].self, forKey: .value))
        default: throw DeviceContractError.invalid("valueKind")
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let v): try c.encode("integer", forKey: .kind); try c.encode(v, forKey: .value)
        case .boolean(let v): try c.encode("boolean", forKey: .kind); try c.encode(v, forKey: .value)
        case .choice(let v): try c.encode("choice", forKey: .kind); try c.encode(v, forKey: .value)
        case .text(let v): try c.encode("text", forKey: .kind); try c.encode(v, forKey: .value)
        case .layout(let v): try c.encode("layout", forKey: .kind); try c.encode(v, forKey: .value)
        case .usbRoute(let v): try c.encode("usbRoute", forKey: .kind); try c.encode(v, forKey: .value)
        case .inputMapping(let v): try c.encode("inputMapping", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }
    public func validate() throws {
        switch self {
        case .choice(let v): try requireContract(contractID(v), "choiceValue")
        case .text(let v): try requireContract(v.utf8.count <= 128 && !v.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, "textValue")
        case .layout(let v): try v.validate()
        case .usbRoute(let v): try v.validate()
        case .inputMapping(let v): try requireContract(v.count <= 128 && uniqueIDs(Array(v.keys)) && v.values.allSatisfy(contractID), "mappingValue")
        default: break
        }
    }
}

extension DeviceValue {
    /// Configured policy and an optional owner assertion are distinct targets.
    /// Omitting an owner never claims receiving-host enumeration.
    func matchesTarget(_ actual: DeviceValue?) -> Bool {
        if case .usbRoute(let wanted) = self, case .usbRoute(let observed) = actual {
            return wanted.configuredDestinationID == observed.configuredDestinationID
                && (wanted.observedOwnerID == nil || wanted.observedOwnerID == observed.observedOwnerID)
        }
        return self == actual
    }
}

public enum DeviceCapabilityDefinition: Equatable, Sendable, Codable {
    case integer(DeviceIntegerDefinition), boolean, choice([DeviceChoice]), text(DeviceTextDefinition)
    case layout(DeviceLayoutDefinition), usbRoute(DeviceUSBRouteDefinition), inputMapping(DeviceInputMappingDefinition)
    private enum CodingKeys: String, CodingKey { case kind, definition }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        try decoder.contractKeys(kind == "boolean" ? ["kind"] : ["kind", "definition"])
        switch kind {
        case "integer": self = .integer(try c.decode(DeviceIntegerDefinition.self, forKey: .definition))
        case "boolean": self = .boolean
        case "choice": self = .choice(try c.decode([DeviceChoice].self, forKey: .definition))
        case "text": self = .text(try c.decode(DeviceTextDefinition.self, forKey: .definition))
        case "layout": self = .layout(try c.decode(DeviceLayoutDefinition.self, forKey: .definition))
        case "usbRoute": self = .usbRoute(try c.decode(DeviceUSBRouteDefinition.self, forKey: .definition))
        case "inputMapping": self = .inputMapping(try c.decode(DeviceInputMappingDefinition.self, forKey: .definition))
        default: throw DeviceContractError.invalid("definitionKind")
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let v): try c.encode("integer", forKey: .kind); try c.encode(v, forKey: .definition)
        case .boolean: try c.encode("boolean", forKey: .kind)
        case .choice(let v): try c.encode("choice", forKey: .kind); try c.encode(v, forKey: .definition)
        case .text(let v): try c.encode("text", forKey: .kind); try c.encode(v, forKey: .definition)
        case .layout(let v): try c.encode("layout", forKey: .kind); try c.encode(v, forKey: .definition)
        case .usbRoute(let v): try c.encode("usbRoute", forKey: .kind); try c.encode(v, forKey: .definition)
        case .inputMapping(let v): try c.encode("inputMapping", forKey: .kind); try c.encode(v, forKey: .definition)
        }
    }
    public func validate() throws {
        switch self {
        case .integer(let v): try v.validate()
        case .boolean: break
        case .choice(let v):
            try requireContract((1...32).contains(v.count) && uniqueIDs(v.map(\.id)), "choiceDefinition")
            try v.forEach { try $0.validate() }
        case .text(let v): try v.validate()
        case .layout(let v): try v.validate()
        case .usbRoute(let v): try v.validate()
        case .inputMapping(let v): try v.validate()
        }
    }
    public func validate(value: DeviceValue) throws {
        try value.validate()
        switch (self, value) {
        case (.integer(let d), .integer(let v)):
            try requireContract(v >= d.minimum && v <= d.maximum, "integerValue")
            // Unsigned distance avoids overflow for the full Int64 domain.
            let distance = UInt64(bitPattern: v) &- UInt64(bitPattern: d.minimum)
            try requireContract(distance % UInt64(d.step) == 0, "integerStep")
        case (.boolean, .boolean): break
        case (.choice(let d), .choice(let v)): try requireContract(d.contains { $0.id == v }, "choiceMember")
        case (.text(let d), .text(let v)): try requireContract(v.utf8.count <= d.maximumUTF8Bytes, "textLength")
        case (.layout(let d), .layout(let v)):
            guard let template = d.templates.first(where: { $0.id == v.templateID }) else { throw DeviceContractError.invalid("templateMember") }
            try requireContract(Set(v.slots.keys) == Set(template.slots.map(\.id)) && Set(v.options.keys) == Set(d.options.map(\.id)), "completeLayout")
            try requireContract(template.slots.allSatisfy { $0.allowedInputIDs.contains(v.slots[$0.id]!) }
                && d.options.allSatisfy { option in option.choices.contains { $0.id == v.options[option.id] } }, "layoutMember")
            try requireContract(!template.distinctInputs || Set(v.slots.values).count == v.slots.count, "distinctInputs")
        case (.usbRoute(let d), .usbRoute(let v)):
            try requireContract(d.destinations.contains { $0.id == v.configuredDestinationID }
                && (v.observedOwnerID == nil || d.destinations.contains { $0.id == v.observedOwnerID }), "routeMember")
        case (.inputMapping(let d), .inputMapping(let v)):
            try requireContract(Set(v.keys) == Set(d.controls.map(\.id)) && v.values.allSatisfy { value in d.actions.contains { $0.id == value } }, "completeMapping")
        default: throw DeviceContractError.invalid("valueType")
        }
    }
}

public struct DeviceMutationScope: Codable, Equatable, Sendable {
    public let id: String
    public let observedFields: [String]
    public let requiredGuardFields: [String]
    public let writableFields: [String]
    public let coupledFields: [String]
    public let preservedFields: [String]
    public let preservationCommitment: String?

    public init(id: String, observedFields: [String], requiredGuardFields: [String], writableFields: [String], coupledFields: [String], preservedFields: [String], preservationCommitment: String?) throws {
        self.id = id
        self.observedFields = observedFields
        self.requiredGuardFields = requiredGuardFields
        self.writableFields = writableFields
        self.coupledFields = coupledFields
        self.preservedFields = preservedFields
        self.preservationCommitment = preservationCommitment
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, observedFields, requiredGuardFields, writableFields, coupledFields, preservedFields, preservationCommitment }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "observedFields", "requiredGuardFields", "writableFields", "coupledFields", "preservedFields", "preservationCommitment"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        observedFields = try c.decode([String].self, forKey: .observedFields)
        requiredGuardFields = try c.decode([String].self, forKey: .requiredGuardFields)
        writableFields = try c.decode([String].self, forKey: .writableFields)
        coupledFields = try c.decode([String].self, forKey: .coupledFields)
        preservedFields = try c.decode([String].self, forKey: .preservedFields)
        preservationCommitment = try c.decodeIfPresent(String.self, forKey: .preservationCommitment)
        try validate()
    }
    public func validate() throws {
        let groups = [observedFields, requiredGuardFields, writableFields, coupledFields, preservedFields]
        try requireContract(contractID(id) && groups.allSatisfy(uniqueIDs), "scopeFields")
        let observed = Set(observedFields), changed = Set(writableFields + coupledFields)
        try requireContract(Set(requiredGuardFields + writableFields + coupledFields + preservedFields).isSubset(of: observed)
            && Set(writableFields).isDisjoint(with: coupledFields) && changed.isDisjoint(with: preservedFields)
            && changed.isDisjoint(with: requiredGuardFields), "scopeDomains")
        if let preservationCommitment { try requireContract(contractDigest(preservationCommitment), "preservationCommitment") }
    }
}

public struct DeviceVerification: Codable, Equatable, Sendable {
    public let kind: DeviceVerificationKind
    public let guardFieldIDs: [String]
    public let ownershipRequired: Bool

    public init(kind: DeviceVerificationKind, guardFieldIDs: [String], ownershipRequired: Bool) throws {
        self.kind = kind
        self.guardFieldIDs = guardFieldIDs
        self.ownershipRequired = ownershipRequired
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case kind, guardFieldIDs, ownershipRequired }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["kind", "guardFieldIDs", "ownershipRequired"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(DeviceVerificationKind.self, forKey: .kind)
        guardFieldIDs = try c.decode([String].self, forKey: .guardFieldIDs)
        ownershipRequired = try c.decode(Bool.self, forKey: .ownershipRequired)
        try validate()
    }
    public func validate() throws {
        try requireContract(uniqueIDs(guardFieldIDs), "verificationGuards")
    }
}

public struct DeviceCapability: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let category: DeviceCapabilityCategory
    public let presentationOrder: Int
    public let access: DeviceAccess
    public let definition: DeviceCapabilityDefinition
    public let mutationScopeID: String
    public let evidenceIDs: [String]
    public let executionBudgetMilliseconds: Int
    public let settlingMilliseconds: Int
    public let verification: DeviceVerification
    public let unavailableReason: DeviceUnavailable?

    public init(id: String, title: String, category: DeviceCapabilityCategory, presentationOrder: Int, access: DeviceAccess, definition: DeviceCapabilityDefinition, mutationScopeID: String, evidenceIDs: [String], executionBudgetMilliseconds: Int, settlingMilliseconds: Int, verification: DeviceVerification, unavailableReason: DeviceUnavailable?) throws {
        self.id = id
        self.title = title
        self.category = category
        self.presentationOrder = presentationOrder
        self.access = access
        self.definition = definition
        self.mutationScopeID = mutationScopeID
        self.evidenceIDs = evidenceIDs
        self.executionBudgetMilliseconds = executionBudgetMilliseconds
        self.settlingMilliseconds = settlingMilliseconds
        self.verification = verification
        self.unavailableReason = unavailableReason
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, title, category, presentationOrder, access, definition, mutationScopeID, evidenceIDs, executionBudgetMilliseconds, settlingMilliseconds, verification, unavailableReason }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "title", "category", "presentationOrder", "access", "definition", "mutationScopeID", "evidenceIDs", "executionBudgetMilliseconds", "settlingMilliseconds", "verification", "unavailableReason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        category = try c.decode(DeviceCapabilityCategory.self, forKey: .category)
        presentationOrder = try c.decode(Int.self, forKey: .presentationOrder)
        access = try c.decode(DeviceAccess.self, forKey: .access)
        definition = try c.decode(DeviceCapabilityDefinition.self, forKey: .definition)
        mutationScopeID = try c.decode(String.self, forKey: .mutationScopeID)
        evidenceIDs = try c.decode([String].self, forKey: .evidenceIDs)
        executionBudgetMilliseconds = try c.decode(Int.self, forKey: .executionBudgetMilliseconds)
        settlingMilliseconds = try c.decode(Int.self, forKey: .settlingMilliseconds)
        verification = try c.decode(DeviceVerification.self, forKey: .verification)
        unavailableReason = try c.decodeIfPresent(DeviceUnavailable.self, forKey: .unavailableReason)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(id) && contractLabel(title) && contractID(mutationScopeID)
            && uniqueIDs(evidenceIDs) && (0...65535).contains(presentationOrder)
            && (1...30000).contains(executionBudgetMilliseconds) && (0...5000).contains(settlingMilliseconds)
            && settlingMilliseconds <= executionBudgetMilliseconds, "capability")
        try definition.validate(); try verification.validate(); try unavailableReason?.validate()
        if case .text = definition { try requireContract(access == .readOnly, "writableText") }
    }
}

public struct DeviceOperation: Codable, Equatable, Sendable {
    public let kind: DeviceOperationKind
    public let capabilityID: String
    public let target: DeviceValue
    public let usbCapabilityID: String?
    public let usbTarget: DeviceUSBRouteValue?

    public init(kind: DeviceOperationKind, capabilityID: String, target: DeviceValue, usbCapabilityID: String?, usbTarget: DeviceUSBRouteValue?) throws {
        self.kind = kind
        self.capabilityID = capabilityID
        self.target = target
        self.usbCapabilityID = usbCapabilityID
        self.usbTarget = usbTarget
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case kind, capabilityID, target, usbCapabilityID, usbTarget }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["kind", "capabilityID", "target", "usbCapabilityID", "usbTarget"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(DeviceOperationKind.self, forKey: .kind)
        capabilityID = try c.decode(String.self, forKey: .capabilityID)
        target = try c.decode(DeviceValue.self, forKey: .target)
        usbCapabilityID = try c.decodeIfPresent(String.self, forKey: .usbCapabilityID)
        usbTarget = try c.decodeIfPresent(DeviceUSBRouteValue.self, forKey: .usbTarget)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(capabilityID), "operationCapability")
        try target.validate(); try usbTarget?.validate()
        switch (kind, target) {
        case (.setCapability, .integer), (.setCapability, .boolean), (.setCapability, .choice),
             (.setLayout, .layout), (.setUSBRoute, .usbRoute), (.setInputMapping, .inputMapping):
            try requireContract(usbCapabilityID == nil && usbTarget == nil, "operationFields")
        case (.setLayoutAndUSB, .layout):
            try requireContract(usbCapabilityID.map(contractID) == true && usbCapabilityID != capabilityID && usbTarget != nil, "composedTarget")
        default: throw DeviceContractError.invalid("operationType")
        }
    }
}

public struct DeviceDescriptor: Codable, Equatable, Sendable {
    public let capabilities: [DeviceCapability]
    public let scopes: [DeviceMutationScope]
    public let evidence: [DeviceEvidence]
    public let supportsLayoutAndUSB: Bool

    public init(capabilities: [DeviceCapability], scopes: [DeviceMutationScope], evidence: [DeviceEvidence], supportsLayoutAndUSB: Bool) throws {
        self.capabilities = capabilities
        self.scopes = scopes
        self.evidence = evidence
        self.supportsLayoutAndUSB = supportsLayoutAndUSB
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case capabilities, scopes, evidence, supportsLayoutAndUSB }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["capabilities", "scopes", "evidence", "supportsLayoutAndUSB"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try c.decode([DeviceCapability].self, forKey: .capabilities)
        scopes = try c.decode([DeviceMutationScope].self, forKey: .scopes)
        evidence = try c.decode([DeviceEvidence].self, forKey: .evidence)
        supportsLayoutAndUSB = try c.decode(Bool.self, forKey: .supportsLayoutAndUSB)
        try validate()
    }
    public func validate() throws {
        try requireContract(capabilities.count <= 64 && scopes.count <= 64 && evidence.count <= 128
            && uniqueIDs(capabilities.map(\.id)) && uniqueIDs(scopes.map(\.id)) && uniqueIDs(evidence.map(\.id)), "descriptor")
        try scopes.forEach { try $0.validate() }; try evidence.forEach { try $0.validate() }
        let evidenceIDs = Set(evidence.map(\.id))
        for cap in capabilities {
            try cap.validate()
            guard let scope = scopes.first(where: { $0.id == cap.mutationScopeID }) else { throw DeviceContractError.invalid("scopeReference") }
            try requireContract(Set(cap.evidenceIDs).isSubset(of: evidenceIDs)
                && Set(cap.verification.guardFieldIDs).isSubset(of: scope.requiredGuardFields), "capabilityReferences")
            if cap.access == .readWrite { try requireContract(!scope.writableFields.isEmpty, "emptyWriteScope") }
            if case .text(let text) = cap.definition {
                try requireContract(Set(text.reviewEvidenceIDs).isSubset(of: evidenceIDs), "textEvidence")
                if text.exportPolicy == .sourceReviewedNonpersonal {
                    try requireContract(text.reviewEvidenceIDs.allSatisfy { id in evidence.contains { $0.id == id && [.sourceReview, .vendorReview].contains($0.kind) && $0.exportPolicy == .sourceReviewedNonpersonal } }, "textSourceReview")
                }
            }
        }
        if supportsLayoutAndUSB {
            try requireContract(capabilities.contains { if case .layout = $0.definition { return $0.access == .readWrite }; return false }
                && capabilities.contains { if case .usbRoute(let route) = $0.definition { return $0.access == .readWrite && route.reachability == .remainsReachable }; return false }, "composition")
        }
    }
}

extension DeviceDescriptor {
    public func validate(operation: DeviceOperation) throws {
        try validate(); try operation.validate()
        func check(_ id: String, _ value: DeviceValue, composed: Bool) throws {
            guard let cap = capabilities.first(where: { $0.id == id }), cap.access == .readWrite,
                  cap.unavailableReason == nil else { throw DeviceContractError.invalid("unavailableCapability") }
            try cap.definition.validate(value: value)
            try requireContract(cap.verification.kind != .destinationObservation, "unavailableVerification")
            if case .usbRoute(let route) = cap.definition {
                // Generic v1 has no destination transport. Refuse before dispatch.
                try requireContract(route.reachability == .remainsReachable, "unavailableVerification")
                if case .usbRoute(let target) = value { try requireContract(target.observedOwnerID == nil, "observedOwnerIsReadOnly") }
            } else {
                try requireContract(!cap.verification.ownershipRequired && cap.verification.kind == .readback, "unavailableVerification")
            }
        }
        try check(operation.capabilityID, operation.target, composed: operation.kind == .setLayoutAndUSB)
        if operation.kind == .setLayoutAndUSB {
            try requireContract(supportsLayoutAndUSB, "compositionNotAdvertised")
            try check(operation.usbCapabilityID!, .usbRoute(operation.usbTarget!), composed: true)
        }
    }

    /// A normalizer cannot reinterpret an explicit scalar/destination/template.
    /// Within complete layouts/mappings it may change only components whose
    /// stable field ID (or qualified component ID) is declared coupled.
    func validateNormalization(request: DeviceOperation, normalized: DeviceOperation) throws {
        try validate(operation: request); try validate(operation: normalized)
        try requireContract(request.kind == normalized.kind && request.capabilityID == normalized.capabilityID
            && request.usbCapabilityID == normalized.usbCapabilityID && request.usbTarget == normalized.usbTarget, "undeclaredNormalization")
        if request.target == normalized.target { return }
        let cap = capabilities.first { $0.id == request.capabilityID }!
        let coupled = Set(scopes.first { $0.id == cap.mutationScopeID }!.coupledFields)
        func check(_ before: [String: String], _ after: [String: String], prefix: String) throws {
            try requireContract(Set(before.keys) == Set(after.keys), "undeclaredNormalization")
            for (id, value) in before where after[id] != value {
                try requireContract(coupled.contains(id) || coupled.contains(prefix + id), "undeclaredNormalization")
            }
        }
        switch (request.target, normalized.target) {
        case (.layout(let before), .layout(let after)):
            try requireContract(before.templateID == after.templateID, "undeclaredNormalization")
            try check(before.slots, after.slots, prefix: "slot.")
            try check(before.options, after.options, prefix: "option.")
        case (.inputMapping(let before), .inputMapping(let after)): try check(before, after, prefix: "control.")
        default: throw DeviceContractError.invalid("undeclaredNormalization")
        }
    }

    /// The authenticated public observation must be built from this projection,
    /// never authenticated first and then redacted. Raw preservation is absent.
    public func exportSafeValues(_ values: [String: DeviceValue]) throws -> [String: DeviceValue] {
        try validate()
        var result: [String: DeviceValue] = [:]
        for (id, value) in values {
            guard let cap = capabilities.first(where: { $0.id == id }) else { throw DeviceContractError.invalid("undeclaredValue") }
            try cap.definition.validate(value: value)
            if case .text(let text) = cap.definition, text.exportPolicy == .localOnly { continue }
            result[id] = value
        }
        return result
    }
}

public struct DeviceContractIdentity: Codable, Equatable, Sendable {
    public let deviceID: String
    public let incarnationID: String
    public let bindingID: String
    public let providerDigest: String
    public let domainID: String

    public init(deviceID: String, incarnationID: String, bindingID: String, providerDigest: String, domainID: String) throws {
        self.deviceID = deviceID
        self.incarnationID = incarnationID
        self.bindingID = bindingID
        self.providerDigest = providerDigest
        self.domainID = domainID
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case deviceID, incarnationID, bindingID, providerDigest, domainID }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["deviceID", "incarnationID", "bindingID", "providerDigest", "domainID"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        incarnationID = try c.decode(String.self, forKey: .incarnationID)
        bindingID = try c.decode(String.self, forKey: .bindingID)
        providerDigest = try c.decode(String.self, forKey: .providerDigest)
        domainID = try c.decode(String.self, forKey: .domainID)
        try validate()
    }
    public func validate() throws {
        try requireContract([deviceID, incarnationID, domainID].allSatisfy(contractDigest)
            && contractID(bindingID) && contractDigest(providerDigest), "contractIdentity")
    }
}

public struct DeviceObservation: Codable, Equatable, Sendable {
    public let schema: Int
    public let identity: DeviceContractIdentity
    public let checkedAtMilliseconds: Int64
    public let values: [String: DeviceValue]
    public let unavailable: [String: DeviceUnavailable]
    public let guardState: [String: DeviceValue]
    public let scopeCommitments: [String: String]
    public let domainEpoch: UInt64
    public let authentication: String

    public init(schema: Int, identity: DeviceContractIdentity, checkedAtMilliseconds: Int64, values: [String: DeviceValue], unavailable: [String: DeviceUnavailable], guardState: [String: DeviceValue], scopeCommitments: [String: String], domainEpoch: UInt64, authentication: String) throws {
        self.schema = schema
        self.identity = identity
        self.checkedAtMilliseconds = checkedAtMilliseconds
        self.values = values
        self.unavailable = unavailable
        self.guardState = guardState
        self.scopeCommitments = scopeCommitments
        self.domainEpoch = domainEpoch
        self.authentication = authentication
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case schema, identity, checkedAtMilliseconds, values, unavailable, guardState, scopeCommitments, domainEpoch, authentication }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "identity", "checkedAtMilliseconds", "values", "unavailable", "guardState", "scopeCommitments", "domainEpoch", "authentication"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        identity = try c.decode(DeviceContractIdentity.self, forKey: .identity)
        checkedAtMilliseconds = try c.decode(Int64.self, forKey: .checkedAtMilliseconds)
        values = try c.decode([String: DeviceValue].self, forKey: .values)
        unavailable = try c.decode([String: DeviceUnavailable].self, forKey: .unavailable)
        guardState = try c.decode([String: DeviceValue].self, forKey: .guardState)
        scopeCommitments = try c.decode([String: String].self, forKey: .scopeCommitments)
        domainEpoch = try c.decode(UInt64.self, forKey: .domainEpoch)
        authentication = try c.decode(String.self, forKey: .authentication)
        try validate()
    }
    public func validate() throws {
        try identity.validate()
        try requireContract(schema == 1 && checkedAtMilliseconds >= 0 && contractDigest(authentication)
            && uniqueIDs(Array(values.keys)) && uniqueIDs(Array(unavailable.keys)) && uniqueIDs(Array(guardState.keys))
            && uniqueIDs(Array(scopeCommitments.keys)) && Set(values.keys).isDisjoint(with: unavailable.keys)
            && scopeCommitments.values.allSatisfy(contractDigest), "observation")
        try values.values.forEach { try $0.validate() }; try guardState.values.forEach { try $0.validate() }
        try unavailable.values.forEach { try $0.validate() }
    }
}

public struct DevicePlanStage: Codable, Equatable, Sendable {
    public let id: String
    public let operation: DeviceOperation
    public let scopeIDs: [String]
    public let budgetMilliseconds: Int

    public init(id: String, operation: DeviceOperation, scopeIDs: [String], budgetMilliseconds: Int) throws {
        self.id = id
        self.operation = operation
        self.scopeIDs = scopeIDs
        self.budgetMilliseconds = budgetMilliseconds
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, operation, scopeIDs, budgetMilliseconds }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "operation", "scopeIDs", "budgetMilliseconds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        operation = try c.decode(DeviceOperation.self, forKey: .operation)
        scopeIDs = try c.decode([String].self, forKey: .scopeIDs)
        budgetMilliseconds = try c.decode(Int.self, forKey: .budgetMilliseconds)
        try validate()
    }
    public func validate() throws {
        try operation.validate()
        try requireContract(contractID(id) && !scopeIDs.isEmpty && uniqueIDs(scopeIDs) && (1...30000).contains(budgetMilliseconds), "stage")
    }
}

public struct DeviceValueChange: Codable, Equatable, Sendable {
    public let before: DeviceValue
    public let after: DeviceValue

    public init(before: DeviceValue, after: DeviceValue) throws {
        self.before = before
        self.after = after
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case before, after }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["before", "after"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decode(DeviceValue.self, forKey: .before)
        after = try c.decode(DeviceValue.self, forKey: .after)
        try validate()
    }
    public func validate() throws {
        try before.validate(); try after.validate(); try requireContract(before != after, "unchangedEffect")
    }
}

public struct DevicePlan: Codable, Equatable, Sendable {
    public let schema: Int
    public let operationID: UUID
    public let issuedAtMilliseconds: Int64
    public let expiresAtMilliseconds: Int64
    public let identity: DeviceContractIdentity
    public let registryRevision: UInt64
    public let domainEpoch: UInt64
    public let expectedCommitments: [String: String]
    public let operation: DeviceOperation
    public let stages: [DevicePlanStage]
    public let changes: [String: DeviceValueChange]
    public let authentication: String

    public init(schema: Int, operationID: UUID, issuedAtMilliseconds: Int64, expiresAtMilliseconds: Int64, identity: DeviceContractIdentity, registryRevision: UInt64, domainEpoch: UInt64, expectedCommitments: [String: String], operation: DeviceOperation, stages: [DevicePlanStage], changes: [String: DeviceValueChange], authentication: String) throws {
        self.schema = schema
        self.operationID = operationID
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.identity = identity
        self.registryRevision = registryRevision
        self.domainEpoch = domainEpoch
        self.expectedCommitments = expectedCommitments
        self.operation = operation
        self.stages = stages
        self.changes = changes
        self.authentication = authentication
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case schema, operationID, issuedAtMilliseconds, expiresAtMilliseconds, identity, registryRevision, domainEpoch, expectedCommitments, operation, stages, changes, authentication }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "operationID", "issuedAtMilliseconds", "expiresAtMilliseconds", "identity", "registryRevision", "domainEpoch", "expectedCommitments", "operation", "stages", "changes", "authentication"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        operationID = try c.decode(UUID.self, forKey: .operationID)
        issuedAtMilliseconds = try c.decode(Int64.self, forKey: .issuedAtMilliseconds)
        expiresAtMilliseconds = try c.decode(Int64.self, forKey: .expiresAtMilliseconds)
        identity = try c.decode(DeviceContractIdentity.self, forKey: .identity)
        registryRevision = try c.decode(UInt64.self, forKey: .registryRevision)
        domainEpoch = try c.decode(UInt64.self, forKey: .domainEpoch)
        expectedCommitments = try c.decode([String: String].self, forKey: .expectedCommitments)
        operation = try c.decode(DeviceOperation.self, forKey: .operation)
        stages = try c.decode([DevicePlanStage].self, forKey: .stages)
        changes = try c.decode([String: DeviceValueChange].self, forKey: .changes)
        authentication = try c.decode(String.self, forKey: .authentication)
        try validate()
    }
    public func validate() throws {
        try identity.validate(); try operation.validate()
        try requireContract(schema == 1 && issuedAtMilliseconds >= 0 && issuedAtMilliseconds <= Int64.max - 300000
            && expiresAtMilliseconds == issuedAtMilliseconds + 300000 && contractDigest(authentication)
            && !expectedCommitments.isEmpty && uniqueIDs(Array(expectedCommitments.keys))
            && expectedCommitments.values.allSatisfy(contractDigest) && (1...64).contains(stages.count)
            && uniqueIDs(stages.map(\.id)) && uniqueIDs(Array(changes.keys)), "plan")
        try stages.forEach { try $0.validate() }; try changes.values.forEach { try $0.validate() }
        try requireContract(stages.reduce(Int64(0)) { $0 + Int64($1.budgetMilliseconds) } <= 120000, "composedBudget")
    }
}

public struct DeviceStageReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let attempted: Bool
    public let completed: Bool
    public let acknowledged: Bool
    public let verified: Bool
    public let failure: DeviceUnavailable?

    public init(id: String, attempted: Bool, completed: Bool, acknowledged: Bool, verified: Bool, failure: DeviceUnavailable?) throws {
        self.id = id
        self.attempted = attempted
        self.completed = completed
        self.acknowledged = acknowledged
        self.verified = verified
        self.failure = failure
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, attempted, completed, acknowledged, verified, failure }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["id", "attempted", "completed", "acknowledged", "verified", "failure"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        attempted = try c.decode(Bool.self, forKey: .attempted)
        completed = try c.decode(Bool.self, forKey: .completed)
        acknowledged = try c.decode(Bool.self, forKey: .acknowledged)
        verified = try c.decode(Bool.self, forKey: .verified)
        failure = try c.decodeIfPresent(DeviceUnavailable.self, forKey: .failure)
        try validate()
    }
    public func validate() throws {
        try requireContract(contractID(id) && (!completed || attempted) && (!acknowledged || completed)
            && (!verified || (completed && failure == nil)), "stageFlags")
        try failure?.validate()
    }
}

public struct DeviceMutationReceipt: Codable, Equatable, Sendable {
    public let schema: Int
    public let operationID: UUID
    public let identity: DeviceContractIdentity
    public let before: [String: DeviceValue]
    public let target: [String: DeviceValue]
    public let after: [String: DeviceValue]?
    public let stages: [DeviceStageReceipt]
    public let failure: DeviceUnavailable?
    public let outcome: DeviceMutationOutcome
    public let writeMayHaveOccurred: Bool
    public let verified: Bool

    public init(schema: Int, operationID: UUID, identity: DeviceContractIdentity, before: [String: DeviceValue], target: [String: DeviceValue], after: [String: DeviceValue]?, stages: [DeviceStageReceipt], failure: DeviceUnavailable?, outcome: DeviceMutationOutcome, writeMayHaveOccurred: Bool, verified: Bool) throws {
        self.schema = schema
        self.operationID = operationID
        self.identity = identity
        self.before = before
        self.target = target
        self.after = after
        self.stages = stages
        self.failure = failure
        self.outcome = outcome
        self.writeMayHaveOccurred = writeMayHaveOccurred
        self.verified = verified
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case schema, operationID, identity, before, target, after, stages, failure, outcome, writeMayHaveOccurred, verified }
    public init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "operationID", "identity", "before", "target", "after", "stages", "failure", "outcome", "writeMayHaveOccurred", "verified"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        operationID = try c.decode(UUID.self, forKey: .operationID)
        identity = try c.decode(DeviceContractIdentity.self, forKey: .identity)
        before = try c.decode([String: DeviceValue].self, forKey: .before)
        target = try c.decode([String: DeviceValue].self, forKey: .target)
        after = try c.decodeIfPresent([String: DeviceValue].self, forKey: .after)
        stages = try c.decode([DeviceStageReceipt].self, forKey: .stages)
        failure = try c.decodeIfPresent(DeviceUnavailable.self, forKey: .failure)
        outcome = try c.decode(DeviceMutationOutcome.self, forKey: .outcome)
        writeMayHaveOccurred = try c.decode(Bool.self, forKey: .writeMayHaveOccurred)
        verified = try c.decode(Bool.self, forKey: .verified)
        try validate()
    }
    public func validate() throws {
        try identity.validate(); try failure?.validate()
        try requireContract(schema == 1 && stages.count <= 64 && uniqueIDs(stages.map(\.id))
            && uniqueIDs(Array(before.keys)) && uniqueIDs(Array(target.keys)) && after.map { uniqueIDs(Array($0.keys)) } != false, "receipt")
        try before.values.forEach { try $0.validate() }; try target.values.forEach { try $0.validate() }
        try after?.values.forEach { try $0.validate() }; try stages.forEach { try $0.validate() }
        let attempted = stages.contains { $0.attempted }
        try requireContract(!attempted || writeMayHaveOccurred, "possibleWrite")
        try requireContract(verified == (outcome == .verified || outcome == .noChange), "receiptVerified")
        if verified {
            try requireContract(failure == nil && after != nil && !target.isEmpty
                && target.allSatisfy { $0.value.matchesTarget(after?[$0.key]) } && stages.allSatisfy { $0.verified }, "missingReadback")
        }
        if outcome == .noChange { try requireContract(!writeMayHaveOccurred && !attempted && before == after, "noChangeWrite") }
        if outcome == .notAttempted { try requireContract(!writeMayHaveOccurred && !attempted, "notAttemptedWrite") }
        if outcome == .verified { try requireContract(writeMayHaveOccurred && attempted, "verifiedWithoutAttempt") }
    }
}
