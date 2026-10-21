import Foundation

public enum DeviceSupportResolution: Equatable, Sendable {
    case builtInCandidate
    case builtInVerified
    case experimental(binding: SupportBinding, digest: String, identityState: ExperimentalIdentityState)
    case unconfigured
    case collision(candidates: [String])
    case disabled(reason: String)
}
public enum ExperimentalIdentityState: String, Sendable { case notRead, matched }

/// Static reservations never depend on an adapter's assertion or directory order.
public enum BuiltInControlDomainCatalog {
    public static func isMSI(_ identity: DevicePassiveIdentity) -> Bool { identity.vendorID == 0x1462 && identity.productID == 0x3fa4 }
    public static func isReservedReceiver(_ identity: DevicePassiveIdentity) -> Bool {
        (identity.vendorID == 0x046d && identity.productID == 0xc548) || (identity.vendorID == 0x24ae && identity.productID == 0x186a)
    }
    static func reserved(_ endpoint: DeviceEndpoint, in snapshot: DeviceInventorySnapshot) -> Bool {
        if isReservedReceiver(endpoint.identity) { return true }
        if case .providerObservedPaired(let receiver, _, _) = endpoint.address {
            let receiverEndpoints = snapshot.devices.flatMap(\.endpoints).filter {
                switch $0.address {
                case .usb(let id, _): return id == receiver
                case .hid(_, let id, _): return id == receiver
                default: return false
                }
            }
            // A paired address without its receiver facts cannot narrow the
            // reserved receiver domain. Fail closed, never trust a pairing slot.
            if receiverEndpoints.isEmpty || receiverEndpoints.contains(where: { isReservedReceiver($0.identity) }) { return true }
        }
        let records = snapshot.devices.filter { $0.endpoints.contains { $0.id == endpoint.id || $0.physicalDomainID == endpoint.physicalDomainID } }
        if records.flatMap(\.endpoints).contains(where: { isReservedReceiver($0.identity) }) { return true }
        let receiverIDs = records.flatMap(\.relations).filter { $0.kind == .pairedThrough }.map(\.targetID)
        return snapshot.devices.filter { receiverIDs.contains($0.id) }.flatMap(\.endpoints).contains { isReservedReceiver($0.identity) }
    }
    static func matches(_ selector: DevicePassiveSelector, _ identity: DevicePassiveIdentity) -> Bool {
        selector.transport == identity.transport && selector.vendorID == identity.vendorID && selector.productID == identity.productID
            && (selector.interfaceNumber == nil || selector.interfaceNumber == identity.interfaceNumber)
            && Set(selector.usages).isSubset(of: Set(identity.usages))
    }
    static func validate(_ manifest: SupportManifest, endpoint: DeviceEndpoint, snapshot: DeviceInventorySnapshot) throws {
        try manifest.validate()
        guard !reserved(endpoint, in: snapshot) else { throw DeviceContractError.invalid("reservedReceiverDomain") }
        guard manifest.selectors.contains(where: { matches($0, endpoint.identity) }) else { throw DeviceContractError.invalid("selectorMismatch") }
        if isMSI(endpoint.identity) {
            guard manifest.trustedGuards.count == 1, manifest.trustedGuards[0].id == "msi-identity-v1" else { throw DeviceContractError.invalid("requiredTrustedGuard") }
        }
    }
    static func validateLiveMSI(_ tuple: DeviceMSIIdentityTuple, manifest: SupportManifest) throws {
        try tuple.validate()
        if tuple.identityHex == "3030a0" && tuple.protocolHex == "563230" { throw DeviceContractError.invalid("providerChanged") }
        guard manifest.trustedGuards.count == 1,
              manifest.trustedGuards[0].allowedIdentities.contains(tuple) else { throw DeviceContractError.invalid("unlistedIdentity") }
    }
}

public enum DeviceSupportResolver {
    /// Metadata only: no adapter/guard execution during install or reload.
    /// Execution qualification and fresh live observations remain separate gates.
    public static func resolve(endpoint: DeviceEndpoint, snapshot: DeviceInventorySnapshot,
                               registry: SupportRegistrySnapshot) -> DeviceSupportResolution {
        let matching = registry.bindings.filter { $0.enabled && $0.selector.physicalDomainID == endpoint.physicalDomainID }
        if matching.count > 1 { return .collision(candidates: matching.map(\.id).sorted()) }
        if !matching.isEmpty { return .disabled(reason: "executionValidationPending") }
        if BuiltInControlDomainCatalog.isMSI(endpoint.identity) || BuiltInControlDomainCatalog.reserved(endpoint, in: snapshot) { return .builtInCandidate }
        return .unconfigured
    }

    /// Synchronous selected-endpoint guard. The only resource crossing into the
    /// later worker is the borrowed file lease, never this temporary HID session.
    static func guardSelected(endpoint: DeviceEndpoint, manifest: SupportManifest, lease: DeviceResourceLock,
                              snapshot: () throws -> DeviceInventorySnapshot, usbSource: () throws -> InventorySourceSlice<USBDeviceNode>,
                              queryFixture: ((String) throws -> [UInt8])? = nil) throws {
        let current = try snapshot()
        let selected = try current.resolve(endpoint)
        try BuiltInControlDomainCatalog.validate(manifest, endpoint: selected, snapshot: current)
        let graph: USBDeviceGraph
        switch selected.address {
        case .usb, .hid(_, .some, _), .providerObservedPaired:
            graph = try MacUSBPeripheralReader.controlGraph(from: usbSource())
        default: graph = try USBDeviceGraph(devices: []) // Non-USB endpoints need no USB discovery prerequisite.
        }
        let required = try DeviceResourceLock.selectedRequest(selected, graph: graph)
        guard lease.covers(required) else { throw DeviceContractError.invalid("missingBorrowedLease") }
        guard BuiltInControlDomainCatalog.isMSI(selected.identity) else { return } // Never send MSI queries to other devices.
        guard lease.descriptor(forLegacy: "controller.lock") != nil else { throw DeviceContractError.invalid("missingBorrowedLease") }
        let tuple: DeviceMSIIdentityTuple
        if let queryFixture {
            tuple = try DeviceMSIIdentityTuple(identityHex: queryFixture("00140").hex, protocolHex: queryFixture("00150").hex)
        } else {
            let connection = try HIDConnection(selectedEndpoint: selected, borrowedLease: lease)
            tuple = try DeviceMSIIdentityTuple(identityHex: connection.query("00140").hex, protocolHex: connection.query("00150").hex)
            withExtendedLifetime(connection) {}
        }
        try BuiltInControlDomainCatalog.validateLiveMSI(tuple, manifest: manifest)
    }
}
