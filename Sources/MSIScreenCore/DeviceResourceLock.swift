import CryptoKit
import Darwin
import Foundation

/// Ordered nonblocking descriptor leases, not live HID objects. Closing a parent
/// copy must not unlock a cooperating worker's inherited open description.
final class DeviceResourceLock {
    struct Request: Equatable {
        var domains: [String]
        var controller: Bool
        var rapoo: Bool
        init(domains: [String], controller: Bool = false, rapoo: Bool = false) {
            self.domains = Array(Set(domains)).sorted(); self.controller = controller; self.rapoo = rapoo
        }
        var orderedNames: [String] {
            domains.map { "domain-" + SupportPackageContent.hash(Data($0.utf8)) + ".lock" }
                + (controller ? ["controller.lock"] : []) + (rapoo ? ["rapoo.lock"] : [])
        }
    }
    let request: Request
    private var leases: [SupportFileLease] = []
    var descriptors: [Int32] { leases.map(\.descriptor) }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("msi-screen-control", isDirectory: true)
    }
    init(_ request: Request, directory: URL? = nil) throws {
        self.request = request
        // The legacy cache may be 0755. It is not a Support root; accept owned,
        // non-group/world-writable ancestors, without chmod or replacing anything.
        let requested = directory ?? Self.defaultDirectory
        // Foundation's historical temporary-directory API returns the OS alias
        // /var/folders. Normalize only that fixed system prefix, never arbitrary links.
        let path = requested.path.hasPrefix("/var/folders/") ? "/private" + requested.path : requested.path
        let root = try SupportDirectory.root(URL(fileURLWithPath: path, isDirectory: true), managed: false)
        var acquired: [SupportFileLease] = []
        for name in request.orderedNames { acquired.append(try root.lock(name)) }
        leases = acquired // Local partial set closes automatically on a failed acquisition.
    }
    /// Adopt explicit inherited copies of the exact named open descriptions.
    /// No independent open/flock and no LOCK_UN. Default physical lock identity
    /// is global, irrespective of a Support root override.
    init(borrowing request: Request, names: [String], firstDescriptor: Int32, directory: URL? = nil) throws {
        self.request = request
        try requireContract(names == request.orderedNames, "borrowedLeaseSet")
        let root = try SupportDirectory.root(directory ?? Self.defaultDirectory, create: false, managed: false)
        var borrowed: [SupportFileLease] = []
        for (index, name) in names.enumerated() {
            let source = firstDescriptor + Int32(index)
            var inherited = stat(); var named = stat()
            try requireContract(fstat(source, &inherited) == 0 && fstatat(root.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0
                && inherited.st_dev == named.st_dev && inherited.st_ino == named.st_ino
                && inherited.st_uid == getuid() && inherited.st_nlink == 1 && inherited.st_mode & S_IFMT == S_IFREG
                && inherited.st_mode & 0o777 == 0o600, "borrowedLeaseIdentity")
            let copy = fcntl(source, F_DUPFD_CLOEXEC, 400)
            guard copy >= 0 else { throw SupportStorageError.unsafeFile }
            borrowed.append(try SupportFileLease(descriptor: copy))
        }
        leases = borrowed
    }
    func descriptor(forLegacy name: String) -> Int32? {
        guard let index = request.orderedNames.firstIndex(of: name) else { return nil }; return descriptors[index]
    }
    func covers(_ other: Request) -> Bool {
        Set(other.domains).isSubset(of: Set(request.domains)) && (!other.controller || request.controller) && (!other.rapoo || request.rapoo)
    }
    static func request(usbID: UInt64, graph: USBDeviceGraph, affectsHub: Bool = false) throws -> Request {
        guard let target = graph.devices.first(where: { $0.id == usbID }) else { throw DeviceContractError.invalid("absentEndpoint") }
        let ids = Set([usbID] + graph.ancestors(of: usbID))
        let monitors = graph.devices.filter { $0.vendor == 0x1462 && $0.product == 0x3fa4 }
        // Each controller's real, non-root parent hub is independent. A shared
        // host root is not evidence of membership in any monitor's USB hub.
        let monitorHubIDs = Set(monitors.compactMap { monitor in
            graph.devices.first { $0.id == monitor.parentID && $0.deviceClass == 9 && !$0.rootHub }?.id
        })
        let isMonitor = target.vendor == 0x1462 && target.product == 0x3fa4
        let onMonitor = !ids.isDisjoint(with: monitorHubIDs)
        let containsMonitor = affectsHub && monitors.contains { graph.ancestors(of: $0.id).contains(usbID) }
        // MSI routing affects its sibling receivers on its physical hub. A
        // generic hub affects its own subtree, irrespective of MSI presence.
        let affectedRoot = isMonitor ? target.parentID.flatMap { monitorHubIDs.contains($0) ? $0 : nil } : usbID
        let affectsRapoo = affectsHub && affectedRoot.map { root in
            graph.devices.contains { $0.vendor == 0x24ae && $0.product == 0x186a
                && ($0.id == root || graph.ancestors(of: $0.id).contains(root)) }
        } == true
        let isRapoo = target.vendor == 0x24ae && target.product == 0x186a
        return Request(domains: ids.map { "usb:\($0)" }, controller: isMonitor || onMonitor || containsMonitor, rapoo: isRapoo || affectsRapoo)
    }
    /// A configuration HID function need not itself advertise USB hub class.
    /// A declared routing setter can remove downstream ownership, so it takes
    /// both global legacy compatibility leases conservatively, in addition to
    /// exact raw physical/ancestry leases. This is exclusion, not an inferred
    /// device association or permission to query any other controller/receiver.
    static func controlRequest(_ endpoint: DeviceEndpoint, graph: USBDeviceGraph, descriptor: DeviceDescriptor) throws -> Request {
        try controlRequest(endpoint, usbGraph: { graph }, descriptor: descriptor)
    }
    static func controlRequest(_ endpoint: DeviceEndpoint, usbGraph: () throws -> USBDeviceGraph, descriptor: DeviceDescriptor) throws -> Request {
        let selected = try selectedRequest(endpoint, usbGraph: usbGraph)
        let routing = descriptor.capabilities.contains { cap in
            if case .usbRoute = cap.definition { return cap.access == .readWrite }; return false
        }
        return Request(domains: selected.domains + configurationRequest(endpoint).domains,
            controller: selected.controller || routing, rapoo: selected.rapoo || routing)
    }
    /// Installation-scoped configuration identity survives durable reattachment.
    /// It supplements, never replaces, globally shared raw/ancestry exclusion.
    static func configurationRequest(_ endpoint: DeviceEndpoint) -> Request {
        Request(domains: ["configuration:" + endpoint.physicalDomainID])
    }
    static func selectedRequest(_ endpoint: DeviceEndpoint, graph: USBDeviceGraph) throws -> Request {
        try selectedRequest(endpoint, usbGraph: { graph })
    }
    /// Only USB-backed selections depend on complete USB ancestry. A failed
    /// unrelated USB source must not invalidate an exact non-USB HID endpoint.
    static func selectedRequest(_ endpoint: DeviceEndpoint, usbGraph: () throws -> USBDeviceGraph) throws -> Request {
        let usbID: UInt64
        switch endpoint.address {
        case .usb(let id, _), .hid(_, let id?, _): usbID = id
        case .hid(let id, nil, _):
            if endpoint.identity.transport == .usb { _ = try usbGraph() }
            return Request(domains: ["hid:\(id)"])
        case .providerObservedPaired(let receiver, _, _): return try request(usbID: receiver, graph: usbGraph())
        default: return Request(domains: ["endpoint:" + endpoint.physicalDomainID])
        }
        let graph = try usbGraph()
        guard let node = graph.devices.first(where: { $0.id == usbID }) else { throw DeviceContractError.invalid("absentEndpoint") }
        guard node.vendor.flatMap(UInt32.init(exactly:)) == endpoint.identity.vendorID,
              node.product.flatMap(UInt32.init(exactly:)) == endpoint.identity.productID else { throw DeviceContractError.invalid("staleEndpoint") }
        return try request(usbID: usbID, graph: graph, affectsHub: node.deviceClass == 9 || BuiltInControlDomainCatalog.isMSI(endpoint.identity))
    }
}
