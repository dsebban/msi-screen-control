import Foundation

/// The bridge owns representation only. Existing MSI controllers/coordinators
/// retain identity checks, packets, coupling, settling, the narrowly permitted
/// cold-transition retry, destination verification and machine-registry guards.
/// Generic experimental composition must never replace those transition owners.
public enum BuiltInDeviceProvider {
    public static func layoutValue(_ state: ScreenState) throws -> DeviceLayoutValue {
        let slots: [String: String]
        switch state.mode {
        case .off: slots = ["main": state.source1.rawValue]
        case .pbp: slots = ["left": state.source1.rawValue, "right": state.source2.rawValue]
        case .pip: slots = ["main": state.source1.rawValue, "inset": state.pipInput.rawValue]
        }
        return try DeviceLayoutValue(templateID: state.mode.rawValue, slots: slots, options: [
            "savedSecondary": state.source2.rawValue, "savedPIPInput": state.pipInput.rawValue,
            "pipSize": "size-\(state.pipSize)", "pipPosition": "position-\(state.pipPosition)"])
    }
    public static func descriptor() throws -> DeviceDescriptor {
        let inputs = try Input.allCases.map { try DeviceChoice(id: $0.rawValue, title: $0.rawValue) }
        func slot(_ id: String, _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ z: Int) throws -> DeviceLayoutSlot {
            try DeviceLayoutSlot(id: id, rectangle: DeviceRectangle(x: x, y: y, width: width, height: height, z: z), allowedInputIDs: inputs.map(\.id))
        }
        let templates = try [DeviceLayoutTemplate(id: "off", title: "Full screen", slots: [slot("main", 0, 0, 10000, 10000, 0)], distinctInputs: false),
            DeviceLayoutTemplate(id: "pbp", title: "Picture by picture", slots: [slot("left", 0, 0, 5000, 10000, 0), slot("right", 5000, 0, 5000, 10000, 1)], distinctInputs: true),
            DeviceLayoutTemplate(id: "pip", title: "Picture in picture", slots: [slot("main", 0, 0, 10000, 10000, 0), slot("inset", 7000, 7000, 3000, 3000, 1)], distinctInputs: false)]
        let definition = try DeviceLayoutDefinition(inputs: inputs, templates: templates, options: [
            DeviceLayoutOption(id: "savedSecondary", choices: inputs), DeviceLayoutOption(id: "savedPIPInput", choices: inputs),
            DeviceLayoutOption(id: "pipSize", choices: (0...2).map { try DeviceChoice(id: "size-\($0)", title: "\($0)") }),
            DeviceLayoutOption(id: "pipPosition", choices: (0...3).map { try DeviceChoice(id: "position-\($0)", title: "\($0)") })])
        let scope = try DeviceMutationScope(id: "msi.layout", observedFields: ["identity", "protocol", "mode", "source1", "source2", "pipInput", "pipSize", "pipPosition"],
            requiredGuardFields: ["identity", "protocol"], writableFields: ["mode", "source1", "source2"], coupledFields: ["pipInput"], preservedFields: ["pipSize", "pipPosition"], preservationCommitment: nil)
        let capability = try DeviceCapability(id: "msi.layout", title: "Monitor layout", category: .layout, presentationOrder: 0, access: .readWrite,
            definition: .layout(definition), mutationScopeID: scope.id, evidenceIDs: ["msi.protocol"], executionBudgetMilliseconds: 30000, settlingMilliseconds: 5000,
            verification: DeviceVerification(kind: .readback, guardFieldIDs: ["identity", "protocol"], ownershipRequired: false), unavailableReason: nil)
        return try DeviceDescriptor(capabilities: [capability], scopes: [scope], evidence: [
            DeviceEvidence(id: "msi.protocol", kind: .sourceReview, title: "MD342CQP V20 built-in controller", exportPolicy: .sourceReviewedNonpersonal)], supportsLayoutAndUSB: false)
    }
    private static func target(_ value: DeviceLayoutValue, from expected: ScreenState) throws -> ScreenState {
        let descriptor = try descriptor()
        try descriptor.capabilities[0].definition.validate(value: .layout(value))
        var target = expected
        guard let mode = DisplayMode(rawValue: value.templateID) else { throw DeviceContractError.invalid("templateMember") }
        switch mode {
        case .off:
            target = ScreenController.fullscreenTarget(from: expected, input: Input(rawValue: value.slots["main"]!)!)
        case .pbp:
            target = try ScreenController.pbpTarget(from: expected, enabled: true,
                left: Input(rawValue: value.slots["left"]!), right: Input(rawValue: value.slots["right"]!))
        case .pip:
            target.mode = .pip; target.source1 = Input(rawValue: value.slots["main"]!)!; target.pipInput = Input(rawValue: value.slots["inset"]!)!
        }
        // The bridge does not add geometry setters or override the controller's
        // secondary-input coupling. Saved fields must explicitly agree.
        let projected = try layoutValue(target)
        try requireContract(projected == value, "builtInPreservationOrCoupling")
        return target
    }
    private static func observedState(_ value: DeviceLayoutValue) throws -> ScreenState {
        try descriptor().capabilities[0].definition.validate(value: .layout(value))
        let mode = DisplayMode(rawValue: value.templateID)!
        let state = ScreenState(model: "MD342CQP", protocolVersion: "V20", mode: mode,
            source1: Input(rawValue: value.slots[mode == .pbp ? "left" : "main"]!)!,
            source2: Input(rawValue: value.options["savedSecondary"]!)!, pipInput: Input(rawValue: value.options["savedPIPInput"]!)!,
            pipSize: Int(value.options["pipSize"]!.dropFirst(5))!, pipPosition: Int(value.options["pipPosition"]!.dropFirst(9))!)
        let projected = try layoutValue(state); try requireContract(projected == value, "builtInPreservationOrCoupling")
        return state
    }
    public static func applyLayout(_ value: DeviceLayoutValue, expected: ScreenState, controller: ScreenController,
                                   beforeWrite: () throws -> Void = {}) throws -> ScreenState {
        try controller.apply(target(value, from: expected), from: expected, beforeWrite: beforeWrite)
    }
    static func backendState(_ state: ScreenState, identity: DeviceContractIdentity) throws -> DeviceBackendState {
        try DeviceBackendState(identity: identity, values: ["msi.layout": .layout(layoutValue(state))], fields: [
            "identity": .choice("MD342CQP"), "protocol": .choice("V20"), "mode": .choice(state.mode.rawValue),
            "source1": .choice(state.source1.rawValue), "source2": .choice(state.source2.rawValue), "pipInput": .choice(state.pipInput.rawValue),
            "pipSize": .integer(Int64(state.pipSize)), "pipPosition": .integer(Int64(state.pipPosition))], preservation: [:])
    }
    static func selectedTarget(endpoint: DeviceEndpoint, registryRevision: UInt64,
                               reader: DeviceInventoryClient, registryCheck: @escaping () throws -> Void) throws -> ResolvedDeviceControl {
        let identity = try DeviceContractIdentity(deviceID: endpoint.id, incarnationID: endpoint.incarnationID, bindingID: "builtin.msi",
            providerDigest: SupportPackageContent.hash(Data("builtin.MD342CQP.V20".utf8)), domainID: endpoint.physicalDomainID)
        let request = try DeviceResourceLock.selectedRequest(endpoint, graph: MacUSBPeripheralReader.controlGraph(from: USBDeviceGraph.enumerateUSB()))
        let descriptor = try descriptor()
        func withController<T>(_ body: (ScreenController) throws -> T, lease: DeviceResourceLock) throws -> T {
            let connection = try HIDConnection(selectedEndpoint: endpoint, borrowedLease: lease)
            let controller = ScreenController(transport: connection)
            return try body(controller) // Both controller and session end on this thread.
        }
        return ResolvedDeviceControl(identity: identity, descriptor: descriptor, registryRevision: registryRevision, lockRequest: request,
            revalidate: { _ in
                try registryCheck(); let current = try await reader.snapshot(); _ = try current.resolve(endpoint)
            }, read: { lease in
                try withController({ try backendState($0.state(), identity: identity) }, lease: lease)
            }, normalize: { observation, operation in
                try descriptor.validate(operation: operation)
                guard case .layout(let baseline) = observation.values["msi.layout"], case .layout(let desired) = operation.target else {
                    throw DeviceContractError.invalid("unavailableCapability")
                }
                _ = try target(desired, from: observedState(baseline)); return operation
            }, apply: { plan, expected, lease in
                try withController({ controller in
                    let before = try controller.state()
                    let state = try backendState(before, identity: identity)
                    try requireContract(state == expected, "staleBaseline")
                    guard case .layout(let value) = plan.operation.target else { throw DeviceContractError.invalid("operationType") }
                    let after = try applyLayout(value, expected: before, controller: controller) { try Task.checkCancellation(); try registryCheck() }
                    return try DeviceBackendApply(before: state, after: backendState(after, identity: identity), attempted: before != after, completed: before != after, acknowledged: before != after)
                }, lease: lease)
            }, verifyPreservation: { before, after, _ in
                try requireContract(before.fields["pipSize"] == after.fields["pipSize"] && before.fields["pipPosition"] == after.fields["pipPosition"], "preservationMismatch")
            })
    }
    public static func applySetting(_ setting: MonitorSetting, value: Int, expected: MonitorSettingsSnapshot,
                                    controller: ScreenController) throws -> MonitorSettingsSnapshot {
        try controller.apply(setting, value: value, from: expected)
    }
    public static func applyPreservingUSB(_ value: DeviceLayoutValue, expected: ScreenState, expectedUSB: KVMRoute?,
                                         coordinator: LayoutCoordinator, dryRun: Bool = false) async throws -> LayoutChangeResult {
        try await coordinator.apply(target(value, from: expected), from: expected, expectedUSB: expectedUSB, dryRun: dryRun)
    }
    public static func setUSB(_ route: KVMRoute, expected: KVMRoute, coordinator: KVMCoordinator, dryRun: Bool = false) async throws -> KVMChangeResult {
        try await coordinator.set(target: route, expected: expected, dryRun: dryRun)
    }
    public static func focus(machineID: String, expectedUSB: KVMRoute?, expectedLayout: ScreenState?,
                             coordinator: MachineFocusCoordinator, dryRun: Bool = false) async throws -> MachineFocusResult {
        try await coordinator.focus(machineID: machineID, expectedUSB: expectedUSB, expectedLayout: expectedLayout, dryRun: dryRun)
    }
}
