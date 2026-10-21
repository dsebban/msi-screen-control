import XCTest
@testable import MSIScreenCore

final class DeviceCapabilityTests: XCTestCase {
    func testBuiltInProjectionDelegatesNoopAndStaleChecksWithoutNewPackets() throws {
        let transport = NoOpLayoutTests.Transport(), controller = ScreenController(transport: transport)
        let baseline = try controller.state(), value = try BuiltInDeviceProvider.layoutValue(baseline)
        try BuiltInDeviceProvider.descriptor().capabilities[0].definition.validate(value: .layout(value))
        XCTAssertEqual(try BuiltInDeviceProvider.applyLayout(value, expected: baseline, controller: controller), baseline)
        XCTAssertEqual(transport.writeCount, 0); XCTAssertEqual(transport.videoEnumerationCount, 0)
        transport.source = .usbc
        XCTAssertThrowsError(try BuiltInDeviceProvider.applyLayout(value, expected: baseline, controller: controller))
        XCTAssertEqual(transport.writeCount, 0)
    }
    func testAuthenticatedProjectionOmitsLocalTextRawGuardAndPreservationBeforeSigning() throws {
        let scope = try DeviceMutationScope(id: "scope", observedFields: ["model", "secret"], requiredGuardFields: ["secret"], writableFields: [], coupledFields: [], preservedFields: ["secret"], preservationCommitment: nil)
        let cap = try DeviceCapability(id: "model", title: "Local identifier", category: .information, presentationOrder: 0, access: .readOnly,
            definition: .text(DeviceTextDefinition(maximumUTF8Bytes: 128, exportPolicy: .localOnly, reviewEvidenceIDs: [])), mutationScopeID: scope.id,
            evidenceIDs: [], executionBudgetMilliseconds: 1000, settlingMilliseconds: 0, verification: DeviceVerification(kind: .readback, guardFieldIDs: ["secret"], ownershipRequired: false), unavailableReason: nil)
        let descriptor = try DeviceDescriptor(capabilities: [cap], scopes: [scope], evidence: [], supportsLayoutAndUSB: false)
        let state = try DeviceBackendState(identity: U3Fixture.identity(), values: ["model": .text("PRIVATE-SERIAL")],
            fields: ["model": .text("PRIVATE-SERIAL"), "secret": .text("PRIVATE-GUARD")], preservation: ["report": "PRIVATE-REPORT"])
        let auth = DeviceContractAuthentication(key: Data(repeating: 7, count: 32))
        let observation = try auth.observation(state: state, descriptor: descriptor, epoch: 42, now: 100)
        let data = try StrictJSON.canonical(observation), exported = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(exported.contains("PRIVATE")); XCTAssertTrue(observation.values.isEmpty); XCTAssertTrue(observation.guardState.isEmpty)
        XCTAssertEqual(observation.unavailable["model"]?.code, "localOnly")
        let roundTrip = try StrictJSON.decode(DeviceObservation.self, from: data); try auth.verify(roundTrip)
        XCTAssertEqual(try StrictJSON.canonical(roundTrip), data)
        let other = DeviceContractAuthentication(key: Data(repeating: 8, count: 32))
        XCTAssertThrowsError(try other.verify(roundTrip))
    }

    let digest = String(repeating: "a", count: 64)
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try StrictJSON.decode(type, from: Data(json.utf8))
    }
    func testStrictTaggedValuesRejectAmbiguityAndInvalidNumbers() throws {
        for json in [
            #"{"kind":"integer","value":1,"v\u0061lue":2}"#,
            #"{"kind":"integer","value":1,"unknown":0}"#,
            #"{"kind":"integer","value":1.5}"#,
            #"{"kind":"integer","value":9223372036854775808}"#,
            #"{"kind":"boolean","value":1}"#,
            #"{"kind":"integer","value":1} {}"#,
            #"{"kind":"layout","value":{"templateID":"one","slots":{},"options":{},"raw":1}}"#,
            #"{"integer":{"_0":1}}"#
        ] { XCTAssertThrowsError(try decode(DeviceValue.self, json), json) }
        XCTAssertThrowsError(try StrictJSON.decode(DeviceValue.self, from: Data([0xff])))
        XCTAssertThrowsError(try StrictJSON.decode(DeviceValue.self, from: Data(repeating: 32, count: StrictJSON.byteLimit + 1)))
        let value = try decode(DeviceValue.self, #"{"kind":"integer","value":-12}"#)
        XCTAssertEqual(value, .integer(-12))
        XCTAssertEqual(String(decoding: try StrictJSON.canonical(value), as: UTF8.self), #"{"kind":"integer","value":-12}"#)
    }
    func testSharedWireFixtures() throws {
        struct Cases: Decodable { let schema: Int; let validValues: [String]; let invalidValues: [String] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "device-support-cases", withExtension: "json"))
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        for json in cases.validValues {
            let value = try decode(DeviceValue.self, json)
            XCTAssertEqual(try StrictJSON.decode(DeviceValue.self, from: StrictJSON.canonical(value)), value)
        }
        for json in cases.invalidValues { XCTAssertThrowsError(try decode(DeviceValue.self, json), json) }
    }

    func layout() throws -> DeviceCapabilityDefinition {
        let inputs = try [DeviceChoice(id: "dp.9", title: "DP"), DeviceChoice(id: "hdmi.7", title: "HDMI")]
        let slots = try [DeviceLayoutSlot(id: "a", rectangle: DeviceRectangle(x: 0, y: 0, width: 5000, height: 10000, z: 0), allowedInputIDs: inputs.map(\.id)),
                         DeviceLayoutSlot(id: "b", rectangle: DeviceRectangle(x: 5000, y: 0, width: 5000, height: 10000, z: 1), allowedInputIDs: inputs.map(\.id))]
        return try .layout(DeviceLayoutDefinition(inputs: inputs,
            templates: [DeviceLayoutTemplate(id: "split", title: "Split", slots: slots, distinctInputs: true)],
            options: [DeviceLayoutOption(id: "audio", choices: [DeviceChoice(id: "left", title: "Left")])]))
    }
    func testCompleteNonMSILayoutTargetsAndGeometry() throws {
        let definition = try layout()
        let value = try DeviceLayoutValue(templateID: "split", slots: ["a": "dp.9", "b": "hdmi.7"], options: ["audio": "left"])
        try definition.validate(value: .layout(value))
        for target in [
            try DeviceLayoutValue(templateID: "split", slots: ["a": "dp.9"], options: ["audio": "left"]),
            try DeviceLayoutValue(templateID: "split", slots: ["a": "dp.9", "b": "dp.9"], options: ["audio": "left"]),
            try DeviceLayoutValue(templateID: "split", slots: ["a": "dp.9", "b": "hdmi.7"], options: [:]),
            try DeviceLayoutValue(templateID: "split", slots: ["a": "dp.9", "b": "hdmi.7"], options: ["audio": "unknown"])
        ] { XCTAssertThrowsError(try definition.validate(value: .layout(target))) }
        XCTAssertThrowsError(try DeviceRectangle(x: 9999, y: 0, width: Int.max, height: 1, z: 0))
    }
    func constraintSlots(_ allowed: [[String]]) throws -> [DeviceLayoutSlot] {
        try allowed.enumerated().map { index, inputs in
            try DeviceLayoutSlot(id: "slot\(index)",
                rectangle: DeviceRectangle(x: index * 1000, y: 0, width: 1000, height: 10000, z: index),
                allowedInputIDs: inputs)
        }
    }
    func testDistinctInputDefinitionsRejectImpossibleConstraints() throws {
        for allowed in [
            [["only"], ["only"]],
            [["a", "b"], ["a", "b"], ["a", "b"], ["c", "d"]]
        ] {
            let slots = try constraintSlots(allowed)
            XCTAssertThrowsError(try DeviceLayoutTemplate(id: "split", title: "Split", slots: slots, distinctInputs: true))
            // Exercise the definition decoding boundary too, without constructing
            // an invalid typed template once its initializer enforces feasibility.
            let reusable = try DeviceLayoutTemplate(id: "split", title: "Split", slots: slots, distinctInputs: false)
            var template = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reusable)) as? [String: Any])
            template["distinctInputs"] = true
            let inputs = Set(allowed.flatMap { $0 }).sorted().map { ["id": $0, "title": $0] }
            let definition: [String: Any] = ["inputs": inputs, "templates": [template], "options": []]
            XCTAssertThrowsError(try StrictJSON.decode(DeviceLayoutDefinition.self, from: JSONSerialization.data(withJSONObject: definition)))
        }
    }
    func testDistinctInputDefinitionsAllowFeasibleOverlaps() throws {
        let inputs = (0..<8).map { "input\($0)" }
        for (allowed, target) in [
            ([["input0", "input1"], ["input0"]], ["input1", "input0"]),
            (Array(repeating: inputs, count: 8), inputs)
        ] {
            let template = try DeviceLayoutTemplate(id: "split", title: "Split", slots: constraintSlots(allowed), distinctInputs: true)
            let definition = try DeviceCapabilityDefinition.layout(DeviceLayoutDefinition(
                inputs: inputs.map { try DeviceChoice(id: $0, title: $0) }, templates: [template], options: []))
            let value = try DeviceLayoutValue(templateID: "split", slots: Dictionary(uniqueKeysWithValues:
                target.enumerated().map { ("slot\($0.offset)", $0.element) }), options: [:])
            try definition.validate(value: .layout(value))
        }
    }

    func testIntegerOverflowStepAndWholeInputMappings() throws {
        let integer = try DeviceCapabilityDefinition.integer(DeviceIntegerDefinition(minimum: .min, maximum: .max, step: 2, unit: nil))
        try integer.validate(value: .integer(.min)); try integer.validate(value: .integer(.max - 1))
        XCTAssertThrowsError(try integer.validate(value: .integer(.max)))
        let mapping = try DeviceCapabilityDefinition.inputMapping(DeviceInputMappingDefinition(
            controls: [DeviceChoice(id: "wheel", title: "Wheel"), DeviceChoice(id: "button", title: "Button")],
            actions: [DeviceChoice(id: "onboard.back", title: "Back")]))
        try mapping.validate(value: .inputMapping(["wheel": "onboard.back", "button": "onboard.back"]))
        XCTAssertThrowsError(try mapping.validate(value: .inputMapping(["wheel": "onboard.back"])))
        XCTAssertThrowsError(try mapping.validate(value: .inputMapping(["wheel": "shell", "button": "onboard.back"])))
    }
    func testScopesPreserveGuardsAndCoupledFields() throws {
        _ = try DeviceMutationScope(id: "config", observedFields: ["target", "coupled", "guard", "reserved"],
            requiredGuardFields: ["guard"], writableFields: ["target"], coupledFields: ["coupled"], preservedFields: ["reserved"], preservationCommitment: digest)
        XCTAssertThrowsError(try DeviceMutationScope(id: "config", observedFields: ["target"], requiredGuardFields: [],
            writableFields: ["target"], coupledFields: [], preservedFields: ["target"], preservationCommitment: nil))
        XCTAssertThrowsError(try DeviceMutationScope(id: "config", observedFields: ["target"], requiredGuardFields: ["missing"],
            writableFields: ["target"], coupledFields: [], preservedFields: [], preservationCommitment: nil))
    }
    func descriptor(_ definition: DeviceCapabilityDefinition, evidence: [DeviceEvidence] = []) throws -> DeviceDescriptor {
        try DeviceDescriptor(capabilities: [DeviceCapability(id: "cap", title: "Control", category: .setting, presentationOrder: 0,
            access: { if case .text = definition { return .readOnly }; return .readWrite }(), definition: definition,
            mutationScopeID: "config", evidenceIDs: [], executionBudgetMilliseconds: 1000, settlingMilliseconds: 0,
            verification: DeviceVerification(kind: .readback, guardFieldIDs: [], ownershipRequired: false), unavailableReason: nil)],
            scopes: [DeviceMutationScope(id: "config", observedFields: ["field"], requiredGuardFields: [], writableFields: ["field"],
                coupledFields: [], preservedFields: [], preservationCommitment: nil)], evidence: evidence, supportsLayoutAndUSB: false)
    }
    func testTextClassificationAndUnavailableRouteRefuseAtContractBoundary() throws {
        let privateText = try descriptor(.text(DeviceTextDefinition(maximumUTF8Bytes: 128, exportPolicy: .localOnly, reviewEvidenceIDs: [])))
        XCTAssertEqual(try privateText.exportSafeValues(["cap": .text("secret serial")]), [:])
        XCTAssertThrowsError(try descriptor(.text(DeviceTextDefinition(maximumUTF8Bytes: 128, exportPolicy: .sourceReviewedNonpersonal, reviewEvidenceIDs: ["missing"]))))
        let route = try descriptor(.usbRoute(DeviceUSBRouteDefinition(destinations: [DeviceChoice(id: "other", title: "Other")],
            affectedDomainID: "config", reachability: .destinationRequired)))
        let operation = try DeviceOperation(kind: .setUSBRoute, capabilityID: "cap", target: .usbRoute(DeviceUSBRouteValue(configuredDestinationID: "other", observedOwnerID: nil)), usbCapabilityID: nil, usbTarget: nil)
        XCTAssertThrowsError(try route.validate(operation: operation)) // hardware-free; no endpoint/SSH exists here
    }
    func identity() throws -> DeviceContractIdentity {
        try DeviceContractIdentity(deviceID: digest, incarnationID: digest, bindingID: "binding", providerDigest: digest, domainID: digest)
    }
    func testObservationPlanCanonicalShapeAndExpiry() throws {
        let observation = try DeviceObservation(schema: 1, identity: identity(), checkedAtMilliseconds: 1, values: ["cap": .integer(4)],
            unavailable: [:], guardState: [:], scopeCommitments: ["config": digest], domainEpoch: 2, authentication: digest)
        XCTAssertEqual(try StrictJSON.decode(DeviceObservation.self, from: StrictJSON.canonical(observation)), observation)
        let operation = try DeviceOperation(kind: .setCapability, capabilityID: "cap", target: .integer(6), usbCapabilityID: nil, usbTarget: nil)
        let stage = try DevicePlanStage(id: "set", operation: operation, scopeIDs: ["config"], budgetMilliseconds: 1000)
        let plan = try DevicePlan(schema: 1, operationID: UUID(), issuedAtMilliseconds: 10, expiresAtMilliseconds: 300010,
            identity: identity(), registryRevision: 2, domainEpoch: 2, expectedCommitments: ["config": digest], operation: operation,
            stages: [stage], changes: ["cap": DeviceValueChange(before: .integer(4), after: .integer(6))], authentication: digest)
        XCTAssertEqual(try StrictJSON.canonical(StrictJSON.decode(DevicePlan.self, from: StrictJSON.canonical(plan))), try StrictJSON.canonical(plan))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: StrictJSON.canonical(plan)) as? [String: Any])
        json["expiresAtMilliseconds"] = 300011
        XCTAssertThrowsError(try StrictJSON.decode(DevicePlan.self, from: JSONSerialization.data(withJSONObject: json)))
        // Shape validation is not HMAC authentication; U3 must authenticate it.
    }
    func testImpossibleReceiptsAndMissingReadbackReject() throws {
        XCTAssertThrowsError(try DeviceStageReceipt(id: "set", attempted: false, completed: true, acknowledged: true, verified: true, failure: nil))
        XCTAssertThrowsError(try DeviceMutationReceipt(schema: 1, operationID: UUID(), identity: identity(), before: ["cap": .integer(1)], target: ["cap": .integer(2)], after: nil,
            stages: [DeviceStageReceipt(id: "set", attempted: true, completed: true, acknowledged: true, verified: true, failure: nil)], failure: nil, outcome: .verified, writeMayHaveOccurred: true, verified: true))
        let noChange = try DeviceMutationReceipt(schema: 1, operationID: UUID(), identity: identity(), before: ["cap": .integer(1)], target: ["cap": .integer(1)], after: ["cap": .integer(1)],
            stages: [], failure: nil, outcome: .noChange, writeMayHaveOccurred: false, verified: true)
        XCTAssertEqual(try StrictJSON.decode(DeviceMutationReceipt.self, from: StrictJSON.canonical(noChange)), noChange)
    }
    func testManifestRejectsNestedUnknownFieldsCollisionsAndProtectedSelectors() throws {
        let manifest = try SupportManifest(schema: 1, hostAPI: 1, id: "test.support", version: "1.0.0", name: "Support",
            backend: .nativeAdapter(relativeExecutable: "bin/adapter", architectures: [.arm64, .x86_64], minimumMacOS: "13.0"),
            selectors: [DevicePassiveSelector(transport: .usb, vendorID: 1, productID: 2, interfaceNumber: 0, usages: [])],
            trustedGuards: [], descriptor: descriptor(.boolean), files: ["bin/adapter": digest])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: StrictJSON.canonical(manifest)) as? [String: Any])
        func rejects(_ mutate: (inout [String: Any]) -> Void) throws {
            var object = original; mutate(&object)
            XCTAssertThrowsError(try StrictJSON.decode(SupportManifest.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        try rejects { $0["schema"] = 2 }
        try rejects { $0["id"] = "valid\n" }
        try rejects { $0["version"] = "1.0.0\n" }
        try rejects { $0["files"] = ["bin/adapter": digest, "BIN/ADAPTER": digest] }
        try rejects { $0["files"] = ["bin/adapter": digest, "Manifest.json": digest] }
        try rejects { $0["files"] = ["bin/adapter": digest, "bin": digest] }
        try rejects { $0["selectors"] = [["transport": "usb", "vendorID": 0x046d, "productID": 0xc548, "usages": []]] }
        try rejects { $0["selectors"] = [["transport": "usb", "vendorID": 0x24ae, "productID": 0x186a, "usages": []]] }
        try rejects { $0["selectors"] = [["transport": "usb", "vendorID": 0x1462, "productID": 0x3fa4, "usages": []]] }
        try rejects { object in
            var backend = object["backend"] as! [String: Any]; backend["minimumMacOS"] = "13.0\n"; object["backend"] = backend
        }
        try rejects { object in
            var descriptor = object["descriptor"] as! [String: Any]
            var caps = descriptor["capabilities"] as! [[String: Any]]
            caps[0]["definition"] = ["kind": "boolean", "expression": "not allowed"]
            descriptor["capabilities"] = caps; object["descriptor"] = descriptor
        }
        XCTAssertThrowsError(try DevicePassiveSelector(transport: .usb, vendorID: 65536, productID: 1, interfaceNumber: nil, usages: []))
        _ = try DevicePassiveSelector(transport: .display, vendorID: 1, productID: UInt32.max, interfaceNumber: nil, usages: [])
        let allowed = try DeviceTrustedGuard(id: "msi-identity-v1", allowedIdentities: [DeviceMSIIdentityTuple(identityHex: "3030a1", protocolHex: "563230")])
        var experimental = original
        experimental["selectors"] = [["transport": "usb", "vendorID": 0x1462, "productID": 0x3fa4, "usages": []]]
        experimental["trustedGuards"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([allowed]))
        _ = try StrictJSON.decode(SupportManifest.self, from: JSONSerialization.data(withJSONObject: experimental))
    }

    func testManifestRequiresCompleteStrictBackendAndProtection() throws {
        let manifest = try SupportManifest(schema: 1, hostAPI: 1, id: "test.support", version: "1.2.3-alpha.1+local", name: "Support",
            backend: .profile(engine: "hid-feature-fields-v1", relativePath: "profile.json"),
            selectors: [DevicePassiveSelector(transport: .usb, vendorID: 1, productID: 2, interfaceNumber: 0, usages: [DeviceUsage(page: 1, usage: 5)])],
            trustedGuards: [], descriptor: descriptor(.boolean), files: ["profile.json": digest])
        let data = try StrictJSON.canonical(manifest)
        XCTAssertEqual(try StrictJSON.decode(SupportManifest.self, from: data), manifest)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["backend"] = ["kind": "profile", "engine": "hid-feature-fields-v1", "relativePath": "profile.json", "architectures": ["arm64"]]
        XCTAssertThrowsError(try StrictJSON.decode(SupportManifest.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertFalse(SupportManifest.validRelativePath("../escape"))
        XCTAssertFalse(SupportManifest.validRelativePath("a//b"))
        XCTAssertFalse(SupportManifest.validSemanticVersion("1.0.0-01"))
        XCTAssertThrowsError(try DeviceTrustedGuard(id: "msi-identity-v1", allowedIdentities: [DeviceMSIIdentityTuple(identityHex: "3030a0", protocolHex: "563230")]))
    }
}
