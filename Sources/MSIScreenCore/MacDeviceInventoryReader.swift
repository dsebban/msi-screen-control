import Foundation
import Darwin

struct DeviceInventorySources: Sendable {
    let displays: @Sendable () throws -> InventorySourceSlice<MacDisplayInfo>
    let usb: @Sendable () throws -> InventorySourceSlice<USBDeviceNode>
    let hid: @Sendable () throws -> InventorySourceSlice<HIDDeviceNode>

    static let system = DeviceInventorySources(displays: { try MacDisplayController.passiveDisplays() },
        usb: { try USBDeviceGraph.enumerateUSB() }, hid: { try USBDeviceGraph.enumerateHID() })
}

/// Independent of MSI refresh and every active peripheral reader. All source
/// enumeration and generation ownership stays on this serial utility queue.
public final class MacDeviceInventoryReader: DeviceInventoryClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MSIScreen.PassiveInventory", qos: .utility)
    private let sources: DeviceInventorySources
    private let identity: DeviceInventoryIdentity
    private let bootIdentity: String?
    private let transientBoot = UUID().uuidString
    private var generation: UInt64 = 0

    public convenience init(identity: DeviceInventoryIdentity) {
        self.init(identity: identity, bootIdentity: Self.bootSessionIdentity(), sources: .system)
    }
    init(identity: DeviceInventoryIdentity, bootIdentity: String?, sources: DeviceInventorySources) {
        self.identity = identity; self.bootIdentity = bootIdentity; self.sources = sources
    }

    public func snapshot() async throws -> DeviceInventorySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.capture() })
            }
        }
    }

    /// Fresh passive enumeration inside synchronous metadata CAS/lease checks.
    /// Call off the main actor; generation and sources retain one queue owner.
    public func snapshotSynchronously() throws -> DeviceInventorySnapshot {
        try queue.sync { try capture() }
    }
    private func capture() throws -> DeviceInventorySnapshot {
        try requireContract(generation < UInt64.max, "inventoryGenerationExhausted")
        generation += 1
        return try Self.build(identity: identity, bootIdentity: bootIdentity ?? transientBoot,
            bootIdentityAvailable: bootIdentity != nil,
            displays: Self.read(sources.displays), usb: Self.read(sources.usb), hid: Self.read(sources.hid),
            generation: generation, checkedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000))
    }

    private static func read<T>(_ source: () throws -> InventorySourceSlice<T>) -> InventorySourceSlice<T> {
        do { return try source() }
        catch DeviceContractError.invalid("registryChanged") {
            return InventorySourceSlice([], outcome: .failed(code: .changedDuringEnumeration, message: "Registry changed during enumeration"))
        } catch {
            return InventorySourceSlice([], outcome: .failed(code: .unavailable, message: "OS inventory source unavailable"))
        }
    }

    private static func bootSessionIdentity() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, (1...256).contains(size) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private struct Anchor: Hashable {
        let transport: DeviceTransport
        let vendor: Int
        let product: Int
        let serial: String
        var fields: [String] { [transport.rawValue, String(vendor), String(product), serial] }
        init?(transport: DeviceTransport, vendor: Int?, product: Int?, serial: String?) {
            guard let vendor, let product, let serial, !serial.isEmpty,
                  !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.transport = transport; self.vendor = vendor; self.product = product; self.serial = serial
        }
    }

    static func build(identity: DeviceInventoryIdentity, bootIdentity: String, bootIdentityAvailable: Bool = true,
                      displays: InventorySourceSlice<MacDisplayInfo>, usb: InventorySourceSlice<USBDeviceNode>, hid: InventorySourceSlice<HIDDeviceNode>,
                      generation: UInt64, checkedAtMilliseconds: Int64) throws -> DeviceInventorySnapshot {
        _ = try USBDeviceGraph(devices: usb.values)
        try requireContract(Set(hid.values.map(\.id)).count == hid.values.count
            && Set(displays.values.map(\.id)).count == displays.values.count, "duplicateEndpoint")
        var anchorOwners: [Anchor: Set<String>] = [:]
        for node in usb.values {
            if let anchor = Anchor(transport: .usb, vendor: node.vendor, product: node.product, serial: node.serial) {
                anchorOwners[anchor, default: []].insert("usb:\(node.id)")
            }
        }
        for node in hid.values {
            if let anchor = Anchor(transport: node.transport, vendor: node.vendor, product: node.product, serial: node.serial) {
                anchorOwners[anchor, default: []].insert(node.usbDeviceID.map { "usb:\($0)" } ?? "hid:\(node.id)")
            }
        }
        let uuidCounts = Dictionary(grouping: displays.values.filter { !$0.uuid.isEmpty }, by: \.uuid).mapValues(\.count)
        func persistent(_ anchor: Anchor?, complete: Bool) -> [String]? {
            guard identity.persistent, bootIdentityAvailable, complete, let anchor, anchorOwners[anchor]?.count == 1 else { return nil }
            return ["serial"] + anchor.fields
        }
        func eligibility(_ durable: Bool, hasAnchor: Bool = false) throws -> (DeviceBindingEligibility, DeviceUnavailable?) {
            if !identity.persistent { return (.transient, identity.unavailableReason) }
            if !bootIdentityAvailable { return (.transient, try DeviceUnavailable(code: "bootIdentityUnavailable")) }
            if durable { return (.durable, nil) }
            return (.attachmentOnly, try DeviceUnavailable(code: hasAnchor ? "nonuniqueOrIncompleteAnchor" : "attachmentOnly"))
        }
        func safeName(_ name: String?, kind: DeviceKind) -> String {
            // Bounding local presentation is not validation of a package label.
            guard let name else { return kind.rawValue }
            let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            var result = ""
            for character in clean { if result.utf8.count + String(character).utf8.count > 128 { break }; result.append(character) }
            return result.isEmpty ? kind.rawValue : result
        }
        func facts(_ transport: DeviceTransport, _ vendor: Int?, _ product: Int?, _ usages: [DeviceUsage] = [],
                   _ interface: UInt8? = nil, isBuiltIn: Bool? = nil) throws -> DevicePassiveIdentity {
            try DevicePassiveIdentity(transport: transport, vendorID: vendor.flatMap(UInt32.init(exactly:)),
                productID: product.flatMap(UInt32.init(exactly:)), interfaceNumber: interface, usages: usages, isBuiltIn: isBuiltIn)
        }
        var records: [DeviceRecord] = []
        var usbIDs: [UInt64: String] = [:], usbDomains: [UInt64: String] = [:], usbAnchors: [UInt64: [String]] = [:]
        for node in usb.values {
            let anchor = Anchor(transport: .usb, vendor: node.vendor, product: node.product, serial: node.serial)
            let durable = persistent(anchor, complete: usb.outcome == .complete)
            let attachment = [bootIdentity, "usb", String(node.id)]
            let fields = durable ?? attachment
            usbIDs[node.id] = identity.token("device-usb", fields)
            usbDomains[node.id] = identity.token("physical-domain", fields)
            usbAnchors[node.id] = durable
        }
        for display in displays.values {
            let durable = identity.persistent && bootIdentityAvailable && displays.outcome == .complete
                && !display.uuid.isEmpty && uuidCounts[display.uuid] == 1
            let attachment = [bootIdentity, "display", String(display.id)]
            let fields = durable ? ["display-uuid", display.uuid] : attachment
            let id = identity.token("device-display", fields)
            let endpoint = try DeviceEndpoint(kind: .display, id: identity.token("endpoint-display", fields),
                identity: DevicePassiveIdentity(transport: .display, vendorID: display.vendor, productID: display.model,
                    isBuiltIn: display.isBuiltIn, isMain: display.isMain, isActive: display.isActive, isAsleep: display.isAsleep,
                    pixelWidth: display.mode?.pixelWidth, pixelHeight: display.mode?.pixelHeight),
                physicalDomainID: identity.token("physical-domain-display", fields), incarnationID: identity.token("incarnation", attachment + [display.uuid]),
                address: .display(id: display.id, uuid: display.uuid.isEmpty ? nil : display.uuid))
            let (binding, reason) = try eligibility(durable, hasAnchor: !display.uuid.isEmpty)
            // No one-of-each or name-based controlsDisplay relationship.
            records.append(try DeviceRecord(id: id, displayName: safeName(display.name, kind: .display), kind: .display,
                endpoints: [endpoint], relations: [], bindingEligibility: binding, bindingReason: reason))
        }
        for node in usb.values {
            let durable = usbAnchors[node.id]
            let fields = durable ?? [bootIdentity, "usb", String(node.id)]
            let kind: DeviceKind = node.deviceClass == 9 ? .hub :
                ((node.vendor == 0x046d && node.product == 0xc548) || (node.vendor == 0x24ae && node.product == 0x186a)) ? .receiver : .other
            let endpoint = try DeviceEndpoint(kind: .usb, id: identity.token("endpoint-usb", fields),
                identity: facts(.usb, node.vendor, node.product, isBuiltIn: node.isBuiltIn), physicalDomainID: usbDomains[node.id]!,
                incarnationID: identity.token("incarnation", [bootIdentity, "usb", String(node.id), String(node.parentID ?? 0)]),
                address: .usb(registryID: node.id, parentID: node.parentID))
            let relations = try node.parentID.flatMap { usbIDs[$0] }.map { [try DeviceRelation(kind: .usbParent, targetID: $0, evidence: .osAncestry)] } ?? []
            let (binding, reason) = try eligibility(durable != nil, hasAnchor: node.serial?.isEmpty == false)
            records.append(try DeviceRecord(id: usbIDs[node.id]!, displayName: safeName(node.name, kind: kind), kind: kind,
                endpoints: [endpoint], relations: relations, bindingEligibility: binding, bindingReason: reason))
        }
        // Group collections only through a real shared interface AND USB ancestor.
        // Neither a serial nor matching VID/PID/name is grouping evidence.
        let groups = Dictionary(grouping: hid.values) { node -> String in
            if let interface = node.interfaceID, let usb = node.usbDeviceID { return "usb:\(usb):interface:\(interface)" }
            return "hid:\(node.id)"
        }
        for group in groups.values {
            let nodes = group.sorted { $0.id < $1.id }
            let first = nodes[0]
            let usages = Set(nodes.flatMap(\.usages))
            let kind: DeviceKind
            if usages.contains(where: { GameControllerClient.isController(name: "", usagePage: Int($0.page), usage: Int($0.usage)) }) { kind = .gameController }
            else if usages.contains(DeviceUsage(page: 1, usage: 6)) { kind = .keyboard }
            else if usages.contains(DeviceUsage(page: 1, usage: 2)) { kind = .pointer }
            else { kind = .other }
            let anchor = Anchor(transport: first.transport, vendor: first.vendor, product: first.product, serial: first.serial)
            let durable = first.usbDeviceID.flatMap { usbAnchors[$0] } ?? persistent(anchor,
                complete: hid.outcome == .complete && (first.transport != .usb || usb.outcome == .complete))
            let canAnchorInterface = durable != nil && hid.outcome == .complete
                && (first.usbDeviceID == nil || first.interfaceNumber != nil)
            var allEndpointsDurable = canAnchorInterface
            var endpoints: [DeviceEndpoint] = []
            for node in nodes {
                let usageFields = node.usages.map { "\($0.page):\($0.usage)" }.sorted()
                let duplicateInterface = hid.values.contains { other in
                    let samePhysical = node.usbDeviceID.map { $0 == other.usbDeviceID } ??
                        (Anchor(transport: other.transport, vendor: other.vendor, product: other.product, serial: other.serial) == anchor)
                    return other.id != node.id && samePhysical && other.interfaceNumber == node.interfaceNumber
                        && Set(other.usages) == Set(node.usages)
                }
                let endpointDurable = canAnchorInterface && !duplicateInterface
                allEndpointsDurable = allEndpointsDurable && endpointDurable
                let fields = endpointDurable ? durable! + ["interface", String(node.interfaceNumber ?? 0)] + usageFields
                    : [bootIdentity, "hid", String(node.id)]
                let domain: String
                if let usbID = node.usbDeviceID {
                    // A missing USB slice must not split siblings that still
                    // have a real common USB ancestor into separate domains.
                    domain = usbDomains[usbID] ?? identity.token("physical-domain", [bootIdentity, "usb", String(usbID)])
                } else {
                    domain = identity.token("physical-domain", durable ?? [bootIdentity, "hid", String(node.id)])
                }
                endpoints.append(try DeviceEndpoint(kind: .hid, id: identity.token("endpoint-hid", fields),
                    identity: facts(node.transport, node.vendor, node.product, node.usages, node.interfaceNumber,
                        isBuiltIn: node.isBuiltIn), physicalDomainID: domain,
                    incarnationID: identity.token("incarnation", [bootIdentity, "hid", String(node.id), String(node.usbDeviceID ?? 0), String(node.interfaceID ?? 0)]),
                    address: .hid(registryID: node.id, usbDeviceID: node.usbDeviceID, interfaceID: node.interfaceID)))
            }
            let id = identity.token("device-hid", endpoints.map(\.id).sorted())
            let relations = try first.usbDeviceID.flatMap { usbIDs[$0] }.map { [try DeviceRelation(kind: .interfaceOf, targetID: $0, evidence: .osAncestry)] } ?? []
            let (binding, reason) = try eligibility(allEndpointsDurable, hasAnchor: durable != nil)
            records.append(try DeviceRecord(id: id, displayName: safeName(first.name, kind: kind), kind: kind,
                endpoints: endpoints, relations: relations, bindingEligibility: binding, bindingReason: reason))
        }
        return try DeviceInventorySnapshot(checkedAtMilliseconds: checkedAtMilliseconds, generation: generation,
            devices: records.sorted { $0.id < $1.id }, displays: displays.outcome, usb: usb.outcome, hid: hid.outcome)
    }
}
