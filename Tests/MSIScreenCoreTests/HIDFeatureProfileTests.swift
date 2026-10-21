import Darwin
import Foundation
import XCTest
@testable import MSIScreenCore

/// One non-MSI report exercises the full typed surface without any HID access.
enum U3Fixture {
    static let zero = String(repeating: "0", count: 64)
    static func identity() throws -> DeviceContractIdentity {
        try DeviceContractIdentity(deviceID: String(repeating: "1", count: 64), incarnationID: String(repeating: "2", count: 64),
            bindingID: "fixture", providerDigest: zero, domainID: String(repeating: "3", count: 64))
    }
    static func operation(_ id: String, _ target: DeviceValue, kind: DeviceOperationKind = .setCapability) throws -> DeviceOperation {
        try DeviceOperation(kind: kind, capabilityID: id, target: target, usbCapabilityID: nil, usbTarget: nil)
    }
    static func layout(_ pair: Bool = false) throws -> DeviceValue {
        .layout(try DeviceLayoutValue(templateID: pair ? "pair" : "single", slots: pair ? ["main": "alpha", "sub": "beta"] : ["main": "alpha"], options: ["ratio": "equal"]))
    }
    static func descriptor(reachability: DeviceControlReachability = .remainsReachable, coupledRatio: Bool = false, information: Bool = false) throws -> DeviceDescriptor {
        let choices = try [DeviceChoice(id: "alpha", title: "Alpha"), DeviceChoice(id: "beta", title: "Beta")]
        let main = try DeviceLayoutSlot(id: "main", rectangle: DeviceRectangle(x: 0, y: 0, width: 5000, height: 10000, z: 0), allowedInputIDs: choices.map(\.id))
        let sub = try DeviceLayoutSlot(id: "sub", rectangle: DeviceRectangle(x: 5000, y: 0, width: 5000, height: 10000, z: 1), allowedInputIDs: choices.map(\.id))
        let layout = try DeviceLayoutDefinition(inputs: choices, templates: [
            DeviceLayoutTemplate(id: "single", title: "Single", slots: [main], distinctInputs: false),
            DeviceLayoutTemplate(id: "pair", title: "Pair", slots: [main, sub], distinctInputs: true)],
            options: [DeviceLayoutOption(id: "ratio", choices: [DeviceChoice(id: "equal", title: "Equal"), DeviceChoice(id: "wide", title: "Wide")])])
        let controls = try [DeviceChoice(id: "a", title: "A"), DeviceChoice(id: "b", title: "B")]
        let actions = try [DeviceChoice(id: "next", title: "Next"), DeviceChoice(id: "mute", title: "Mute")]
        let definitions: [(String, DeviceCapabilityDefinition)] = [
            ("level", .integer(try DeviceIntegerDefinition(minimum: 0, maximum: 100, step: 1, unit: nil))), ("enabled", .boolean),
            ("layout", .layout(layout)), ("route", .usbRoute(try DeviceUSBRouteDefinition(destinations: choices, affectedDomainID: "configuration", reachability: reachability))),
            ("mapping", .inputMapping(try DeviceInputMappingDefinition(controls: controls, actions: actions)))]
        let scope = try DeviceMutationScope(id: "configuration", observedFields: ["identity", "level", "enabled", "template", "main", "sub", "ratio", "route", "a", "b", "guard", "reserved"],
            requiredGuardFields: ["identity", "guard"], writableFields: ["level", "enabled", "template", "main", "sub", "ratio", "route", "a", "b"].filter { !coupledRatio || $0 != "ratio" }, coupledFields: coupledRatio ? ["ratio"] : [], preservedFields: ["reserved"], preservationCommitment: nil)
        var capabilities = try definitions.enumerated().map { index, entry in
            try DeviceCapability(id: entry.0, title: entry.0, category: .setting, presentationOrder: index, access: .readWrite, definition: entry.1,
                mutationScopeID: scope.id, evidenceIDs: ["fixture"], executionBudgetMilliseconds: 5000, settlingMilliseconds: 0,
                verification: DeviceVerification(kind: entry.0 == "route" ? .configuredRoute : .readback, guardFieldIDs: ["identity", "guard"], ownershipRequired: false), unavailableReason: nil)
        }
        if information {
            capabilities.append(try DeviceCapability(id: "information", title: "Read counter", category: .information, presentationOrder: 10,
                access: .readOnly, definition: .integer(DeviceIntegerDefinition(minimum: 0, maximum: 255, step: 1, unit: nil)),
                mutationScopeID: scope.id, evidenceIDs: ["fixture"], executionBudgetMilliseconds: 5000, settlingMilliseconds: 0,
                verification: DeviceVerification(kind: .readback, guardFieldIDs: [], ownershipRequired: false), unavailableReason: nil))
        }
        return try DeviceDescriptor(capabilities: capabilities, scopes: [scope], evidence: [DeviceEvidence(id: "fixture", kind: .offlineFixture, title: "Offline fixture", exportPolicy: .sourceReviewedNonpersonal)], supportsLayoutAndUSB: reachability == .remainsReachable)
    }
    static var baseline: String { "2a05000000010000000107cafe000000" }
    static func profile() throws -> HIDFeatureProfile {
        func choice(_ id: String, _ offset: Int, _ values: [String: String]) -> HIDFeatureField {
            HIDFeatureField(id: id, reportID: 0, offset: offset, width: 1, codec: .enumBytes, enumBytes: values, writable: true)
        }
        let fields: [HIDFeatureField] = [
            .init(id: "identity", reportID: 0, offset: 0, width: 1, codec: .u8),
            .init(id: "level", reportID: 0, offset: 1, width: 1, codec: .u8, writable: true),
            .init(id: "enabled", reportID: 0, offset: 2, width: 1, codec: .bits, bitCount: 1, writable: true),
            choice("template", 3, ["single": "00", "pair": "01"]), choice("main", 4, ["alpha": "00", "beta": "01"]),
            choice("sub", 5, ["alpha": "00", "beta": "01"]), choice("ratio", 6, ["equal": "00", "wide": "01"]),
            choice("route", 7, ["alpha": "00", "beta": "01"]), choice("a", 8, ["next": "00", "mute": "01"]),
            choice("b", 9, ["next": "00", "mute": "01"]), .init(id: "guard", reportID: 0, offset: 10, width: 1, codec: .u8),
            .init(id: "reserved", reportID: 0, offset: 11, width: 2, codec: .u16BE)]
        let values: [String: DeviceValue] = ["level": .integer(5), "enabled": .boolean(false), "layout": try layout(),
            "route": .usbRoute(try DeviceUSBRouteValue(configuredDestinationID: "alpha", observedOwnerID: nil)), "mapping": .inputMapping(["a": "next", "b": "mute"])]
        let cases: [(DeviceOperation, [Int: UInt8])] = try [
            (operation("level", .integer(20)), [1: 20]), (operation("enabled", .boolean(true)), [2: 1]),
            (operation("layout", layout(true), kind: .setLayout), [3: 1]),
            (operation("route", .usbRoute(DeviceUSBRouteValue(configuredDestinationID: "beta", observedOwnerID: nil)), kind: .setUSBRoute), [7: 1]),
            (operation("mapping", .inputMapping(["a": "mute", "b": "next"]), kind: .setInputMapping), [8: 1, 9: 0]),
            (operation("level", .integer(5)), [:])]
        let fixtures = try cases.map { operation, updates -> HIDProfileFixture in
            var expected = try HIDFeatureProfile.bytes(baseline)
            for (offset, byte) in updates { expected[offset] = byte }
            return HIDProfileFixture(reports: ["0": baseline], expectedValues: values, operation: operation, expectedReports: ["0": expected.hex])
        }
        return HIDFeatureProfile(reports: [.init(id: 0, length: 16, safeToRoundTrip: true)], fields: fields,
            identities: ["identity": [.integer(42)]], guards: [.init(fieldID: "guard", kind: .equals, values: [.integer(7)])], capabilities: [
                .init(capabilityID: "level", components: ["value": "level"]), .init(capabilityID: "enabled", components: ["value": "enabled"]),
                .init(capabilityID: "layout", components: ["template": "template", "slot.main": "main", "slot.sub": "sub", "option.ratio": "ratio"]),
                .init(capabilityID: "route", components: ["destination": "route"]), .init(capabilityID: "mapping", components: ["control.a": "a", "control.b": "b"])],
            fixtures: fixtures)
    }
    static func content(native: Data? = nil, mode: String = "normal", marker: String = "", statePath: String = "") throws -> SupportPackageContent {
        let backend: SupportBackend
        var files: [String: Data]
        if let native {
            #if arch(arm64)
            let arch: SupportArchitecture = .arm64
            #else
            let arch: SupportArchitecture = .x86_64
            #endif
            backend = .nativeAdapter(relativeExecutable: "adapter", architectures: [arch], minimumMacOS: "13.0")
            files = ["adapter": native, "fixture.json": try JSONSerialization.data(withJSONObject: ["mode": mode, "marker": marker, "statePath": statePath], options: [.sortedKeys])]
        } else { backend = .profile(engine: "hid-feature-fields-v1", relativePath: "profile.json"); files = ["profile.json": try StrictJSON.canonical(profile())] }
        let originalDescriptor = try descriptor(coupledRatio: mode == "normalizeCoupled", information: mode.hasPrefix("telemetry"))
        let packageDescriptor = try DeviceDescriptor(capabilities: originalDescriptor.capabilities, scopes: originalDescriptor.scopes,
            evidence: originalDescriptor.evidence + (native == nil ? [] : [DeviceEvidence(id: "source", kind: .sourceReview, title: "Hardware-free compliant fixture source", exportPolicy: .sourceReviewedNonpersonal)]), supportsLayoutAndUSB: true)
        let manifest = try SupportManifest(schema: 1, hostAPI: 1, id: "u3.fixture", version: "1.0.0", name: "U3 fixture", backend: backend,
            selectors: [DevicePassiveSelector(transport: .usb, vendorID: 1, productID: 2, interfaceNumber: 0, usages: [DeviceUsage(page: 1, usage: 5)])], trustedGuards: [],
            descriptor: packageDescriptor, files: files.mapValues(SupportPackageContent.hash))
        files["manifest.json"] = try StrictJSON.canonical(manifest)
        return SupportPackageContent(files: files, manifest: manifest, digest: SupportPackageContent.digest(files))
    }
    static func host() throws -> AdapterHostIdentity {
        if let ownedArtifact = ProcessInfo.processInfo.environment["MSI_U3_TEST_HOST"] {
            return try AdapterHostIdentity.capture(URL(fileURLWithPath: ownedArtifact))
        }
        let tests = Bundle(for: HIDFeatureProfileTests.self).bundleURL
        let candidate = tests.deletingLastPathComponent().appendingPathComponent("msi-screen").resolvingSymlinksInPath()
        // Foundation under translation may prefer the system /tmp alias even
        // after resolving. Normalize that fixed owned-build prefix only.
        let path = candidate.path.hasPrefix("/tmp/") ? "/private" + candidate.path : candidate.path
        return try AdapterHostIdentity.capture(URL(fileURLWithPath: path))
    }
}

final class HIDFeatureProfileTests: XCTestCase {
    func testAllCodecsBoundariesPreserveUnownedBitsAndReportNormalization() throws {
        let cases: [(HIDFieldCodec, Int, DeviceValue, [UInt8])] = [(.u8, 1, .integer(255), [255]),
            (.u16LE, 2, .integer(513), [1, 2]), (.u16BE, 2, .integer(513), [2, 1]),
            (.u32LE, 4, .integer(4294967295), [255,255,255,255]), (.u32BE, 4, .integer(16909060), [1,2,3,4]),
            (.asciiDecimal, 4, .integer(42), Array("0042".utf8))]
        for (codec, width, value, expected) in cases {
            let field = HIDFeatureField(id: "f", reportID: 1, offset: 1, width: width, codec: codec, writable: true)
            var bytes: [UInt8] = [90] + Array(repeating: 0, count: width) + [91]
            try field.encode(value, into: &bytes); XCTAssertEqual(bytes, [90] + expected + [91]); XCTAssertEqual(try field.decode(bytes), value)
            XCTAssertThrowsError(try field.encode(.integer(-1), into: &bytes))
        }
        let bits = HIDFeatureField(id: "bits", reportID: 0, offset: 0, width: 1, codec: .bits, bitOffset: 2, bitCount: 3, writable: true)
        var bytes: [UInt8] = [0xe3]; try bits.encode(.integer(5), into: &bytes); XCTAssertEqual(bytes, [0xf7]); XCTAssertEqual(try bits.decode(bytes), .integer(5))
        XCTAssertThrowsError(try bits.encode(.integer(8), into: &bytes))
        for id: UInt8 in [0, 9] {
            let report = HIDFeatureReport(id: id, length: 2, safeToRoundTrip: true)
            XCTAssertEqual(try HIDReportNormalization.payload(HIDReportNormalization.wire([3,4], report: report), report: report), [3,4])
            XCTAssertThrowsError(try HIDReportNormalization.payload([1], report: report))
        }
        let text = HIDFeatureField(id: "text", reportID: 0, offset: 0, width: 3, codec: .asciiText)
        XCTAssertEqual(try text.decode(Array("V20".utf8)), .text("V20")); XCTAssertThrowsError(try text.decode([1,2,3]))
        let decimal = HIDFeatureField(id: "d", reportID: 0, offset: 0, width: 19, codec: .asciiDecimal)
        XCTAssertThrowsError(try decimal.decode(Array("9999999999999999999".utf8)))
    }
    func testProfileFixturesCompleteTypedTargetsOneSetterNoopStaleAndFullReportMismatch() throws {
        let profile = try U3Fixture.profile(), descriptor = try U3Fixture.descriptor()
        try HIDFeatureProfileExecutor.selfTest(profile: profile, descriptor: descriptor)
        let operations = try [U3Fixture.operation("level", .integer(42)), U3Fixture.operation("enabled", .boolean(true)),
            U3Fixture.operation("layout", U3Fixture.layout(true), kind: .setLayout),
            U3Fixture.operation("route", .usbRoute(DeviceUSBRouteValue(configuredDestinationID: "beta", observedOwnerID: nil)), kind: .setUSBRoute),
            U3Fixture.operation("mapping", .inputMapping(["a": "mute", "b": "next"]), kind: .setInputMapping)]
        for operation in operations {
            let transport = try HIDFixtureTransport(profile: profile, reports: ["0": U3Fixture.baseline])
            let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: descriptor, identity: U3Fixture.identity(), transport: transport)
            let before = try executor.read(), result = try executor.apply(operation, expected: before)
            XCTAssertEqual(result.after.values[operation.capabilityID], operation.target); XCTAssertEqual(transport.setters, 1); XCTAssertEqual(transport.waits, 1)
            let noop = try executor.apply(operation, expected: result.after); XCTAssertFalse(noop.attempted); XCTAssertEqual(transport.setters, 1); XCTAssertEqual(transport.waits, 1)
            XCTAssertThrowsError(try executor.apply(operation, expected: before)); XCTAssertEqual(transport.setters, 1)
        }
        let transport = try HIDFixtureTransport(profile: profile, reports: ["0": U3Fixture.baseline])
        let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: descriptor, identity: U3Fixture.identity(), transport: transport)
        let before = try executor.read()
        transport.afterSet = { $0[0]![15] ^= 1 }
        XCTAssertThrowsError(try executor.apply(operations[0], expected: before)); XCTAssertEqual(transport.setters, 1); XCTAssertEqual(transport.waits, 1)
    }
    func testSeparateReadOnlyReportTelemetryDoesNotStaleButDeclaredGuardsAndPreservationDo() throws {
        let original = try U3Fixture.profile(), descriptor = try U3Fixture.descriptor(information: true), scope = descriptor.scopes[0]
        let guardedScope = try DeviceMutationScope(id: scope.id, observedFields: scope.observedFields + ["readGuard", "readReserved"],
            requiredGuardFields: scope.requiredGuardFields + ["readGuard"], writableFields: scope.writableFields, coupledFields: scope.coupledFields,
            preservedFields: scope.preservedFields + ["readReserved"], preservationCommitment: nil)
        let guardedDescriptor = try DeviceDescriptor(capabilities: descriptor.capabilities, scopes: [guardedScope], evidence: descriptor.evidence, supportsLayoutAndUSB: true)
        let fixtures = original.fixtures.map { fixture -> HIDProfileFixture in
            var reports = fixture.reports, expected = fixture.expectedReports, values = fixture.expectedValues
            reports["1"] = "000709"; expected["1"] = "000709"; values["information"] = .integer(0)
            return HIDProfileFixture(reports: reports, expectedValues: values, operation: fixture.operation, expectedReports: expected)
        }
        let profile = HIDFeatureProfile(reports: original.reports + [.init(id: 1, length: 3, safeToRoundTrip: false)],
            fields: original.fields + [.init(id: "information", reportID: 1, offset: 0, width: 1, codec: .u8),
                .init(id: "readGuard", reportID: 1, offset: 1, width: 1, codec: .u8),
                .init(id: "readReserved", reportID: 1, offset: 2, width: 1, codec: .u8)], identities: original.identities,
            guards: original.guards + [.init(fieldID: "readGuard", kind: .oneOf, values: [.integer(7), .integer(8)])],
            capabilities: original.capabilities + [.init(capabilityID: "information", components: ["value": "information"])], fixtures: fixtures)
        try HIDFeatureProfileExecutor.selfTest(profile: profile, descriptor: guardedDescriptor)
        let operation = try U3Fixture.operation("level", .integer(20))
        for phase in ["baseline", "after"] {
            let transport = try HIDFixtureTransport(profile: profile, reports: ["0": U3Fixture.baseline, "1": "000709"])
            let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: guardedDescriptor, identity: U3Fixture.identity(), transport: transport)
            let before = try executor.read()
            if phase == "baseline" { transport.reports[1]![0] = 1 }
            else { transport.afterSet = { $0[1]![0] = 1 } }
            do {
                let result = try executor.apply(operation, expected: before)
                XCTAssertEqual(result.after.values["level"], .integer(20)); XCTAssertEqual(transport.setters, 1)
                XCTAssertEqual(result.after.values["information"], .integer(1))
                XCTAssertEqual(Set(result.after.preservation.keys), ["0"]) // Writable report remains whole, not byte-masked.
                XCTAssertEqual(transport.reports[1]![0], 1)
            } catch { XCTFail("Unrelated read-only report drift during \(phase): \(error)") }
        }
        for offset in [1, 2] {
            for afterSet in [false, true] {
                let transport = try HIDFixtureTransport(profile: profile, reports: ["0": U3Fixture.baseline, "1": "000709"])
                let executor = try HIDFeatureProfileExecutor(profile: profile, descriptor: guardedDescriptor, identity: U3Fixture.identity(), transport: transport)
                let before = try executor.read()
                if afterSet { transport.afterSet = { $0[1]![offset] += 1 } } else { transport.reports[1]![offset] += 1 }
                XCTAssertThrowsError(try executor.apply(operation, expected: before))
                XCTAssertEqual(transport.setters, afterSet ? 1 : 0)
            }
        }
    }
    func testOverlapsUnsafeReportsIdentityWritesMissingGuardsAndUnknownKeysReject() throws {
        let profile = try U3Fixture.profile(), descriptor = try U3Fixture.descriptor()
        func replacing(_ key: String, _ value: Any) throws -> HIDFeatureProfile {
            var object = try JSONSerialization.jsonObject(with: StrictJSON.canonical(profile)) as! [String: Any]; object[key] = value
            return try StrictJSON.decode(HIDFeatureProfile.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertThrowsError(try replacing("reports", [["id": 0, "length": 16, "safeToRoundTrip": false]]).validate(descriptor: descriptor))
        let profileObject = try JSONSerialization.jsonObject(with: StrictJSON.canonical(profile)) as! [String: Any]
        var fields = profileObject["fields"] as! [[String: Any]]
        fields[1]["offset"] = 0
        XCTAssertThrowsError(try replacing("fields", fields).validate(descriptor: descriptor))
        XCTAssertThrowsError(try replacing("guards", []).validate(descriptor: descriptor))
        let transport = try HIDFixtureTransport(profile: profile, reports: ["0": U3Fixture.baseline])
        transport.reports[0]![0] = 43
        XCTAssertThrowsError(try HIDFeatureProfileExecutor(profile: profile, descriptor: descriptor, identity: U3Fixture.identity(), transport: transport).read())
        var object = try JSONSerialization.jsonObject(with: StrictJSON.canonical(profile)) as! [String: Any]; object["commands"] = []
        XCTAssertThrowsError(try StrictJSON.decode(HIDFeatureProfile.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
