import Darwin
import Foundation

struct DeviceJournalRecord: Codable, Equatable {
    let operationID: UUID
    let planDigest: String
    let domainID: String
    let acceptedAtMilliseconds: Int64
    let receipt: DeviceMutationReceipt
    let terminal: Bool
    private enum CodingKeys: String, CodingKey { case operationID, planDigest, domainID, acceptedAtMilliseconds, receipt, terminal }
    init(operationID: UUID, planDigest: String, domainID: String, acceptedAtMilliseconds: Int64, receipt: DeviceMutationReceipt, terminal: Bool) {
        self.operationID = operationID; self.planDigest = planDigest; self.domainID = domainID
        self.acceptedAtMilliseconds = acceptedAtMilliseconds; self.receipt = receipt; self.terminal = terminal
    }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["operationID", "planDigest", "domainID", "acceptedAtMilliseconds", "receipt", "terminal"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(UUID.self, forKey: .operationID); planDigest = try c.decode(String.self, forKey: .planDigest)
        domainID = try c.decode(String.self, forKey: .domainID); acceptedAtMilliseconds = try c.decode(Int64.self, forKey: .acceptedAtMilliseconds)
        receipt = try c.decode(DeviceMutationReceipt.self, forKey: .receipt); terminal = try c.decode(Bool.self, forKey: .terminal)
        try requireContract(contractDigest(planDigest) && contractDigest(domainID) && acceptedAtMilliseconds >= 0
            && operationID == receipt.operationID && domainID == receipt.identity.domainID, "journalRecord")
    }
}
private struct DeviceJournalDomain: Codable {
    let schema: Int
    let domainID: String
    let epoch: UInt64
    let last: DeviceJournalRecord?
    private enum CodingKeys: String, CodingKey { case schema, domainID, epoch, last }
    init(domainID: String, epoch: UInt64 = 0, last: DeviceJournalRecord? = nil) { schema = 1; self.domainID = domainID; self.epoch = epoch; self.last = last }
    init(from decoder: Decoder) throws {
        try decoder.contractKeys(["schema", "domainID", "epoch", "last"]); let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema); domainID = try c.decode(String.self, forKey: .domainID)
        epoch = try c.decode(UInt64.self, forKey: .epoch); last = try c.decodeIfPresent(DeviceJournalRecord.self, forKey: .last)
        try requireContract(schema == 1 && contractDigest(domainID) && (last == nil || last?.domainID == domainID), "journalDomain")
    }
}

/// Not a recovery queue. A domain atomically owns its epoch and last accepted
/// claim/receipt; UUID history is archived before replacing that last claim.
/// Interrupted claims are returned as historical uncertainty, never resumed.
final class DeviceOperationJournal {
    enum Claim { case accepted(DeviceJournalRecord), existing(DeviceJournalRecord) }
    let registry: SupportRegistry
    let byteLimit: Int
    let beforePersist: ((String) throws -> Void)?
    static let retentionMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1000
    init(registry: SupportRegistry, byteLimit: Int = 64 * 1024 * 1024, beforePersist: ((String) throws -> Void)? = nil) {
        self.registry = registry; self.byteLimit = byteLimit; self.beforePersist = beforePersist
    }
    private var directory: SupportDirectory { get throws { try registry.validateRoot(); return try registry.root.directory("receipts") } }
    private func domainName(_ id: String) throws -> String {
        try requireContract(contractDigest(id), "journalDomain"); return "domain-" + id + ".json"
    }
    private func recordName(_ id: UUID) -> String { "operation-" + id.uuidString.lowercased() + ".json" }
    private func read<T: Decodable>(_ type: T.Type, name: String, in directory: SupportDirectory) throws -> T {
        let fd = try directory.file(name); defer { close(fd) }
        return try StrictJSON.decode(type, from: SupportDirectory.read(fd, limit: StrictJSON.byteLimit))
    }
    private func domain(_ id: String, in directory: SupportDirectory) throws -> DeviceJournalDomain {
        let name = try domainName(id)
        guard try directory.exists(name) else { return DeviceJournalDomain(domainID: id) }
        let value = try read(DeviceJournalDomain.self, name: name, in: directory)
        try requireContract(value.domainID == id, "journalDomain"); return value
    }
    /// Must be called under the caller's physical domain lease. The journal
    /// lock is nonblocking, and never spans a registry-lock request or await.
    func epoch(domainID: String) throws -> UInt64 {
        let directory = try directory, lock = try directory.lock("journal.lock")
        defer { withExtendedLifetime(lock) {} }; return try domain(domainID, in: directory).epoch
    }
    private func names(in directory: SupportDirectory) throws -> [String] {
        let fd = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0, let stream = fdopendir(fd) else { throw SupportStorageError.unsafeFile }
        defer { closedir(stream) }; var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name == "." || name == ".." || name == "journal.lock" { continue }
            let validDomain = name.hasPrefix("domain-") && name.hasSuffix(".json") && contractDigest(String(name.dropFirst(7).dropLast(5)))
            let validOperation = name.hasPrefix("operation-") && name.hasSuffix(".json") && UUID(uuidString: String(name.dropFirst(10).dropLast(5))) != nil
            try requireContract(validDomain || validOperation, "corruptJournal")
            result.append(name); try requireContract(result.count <= 32768, "journalFull")
        }
        return result.sorted()
    }
    private func existing(_ id: UUID, in directory: SupportDirectory) throws -> DeviceJournalRecord? {
        // The domain's atomic last record is authoritative over a crash-stale
        // archive. No search result can authorize dispatch; this only retrieves.
        var found: DeviceJournalRecord?
        for name in try names(in: directory) where name.hasPrefix("domain-") {
            let state = try read(DeviceJournalDomain.self, name: name, in: directory)
            if state.last?.operationID == id {
                try requireContract(found == nil, "duplicateJournalClaim"); found = state.last
            }
        }
        if let found { return found }
        let name = recordName(id)
        if try directory.exists(name) {
            let record = try read(DeviceJournalRecord.self, name: name, in: directory)
            try requireContract(record.operationID == id, "journalRecord"); return record
        }
        return nil
    }
    func record(operationID: UUID) throws -> DeviceJournalRecord? {
        let directory = try directory, lock = try directory.lock("journal.lock")
        defer { withExtendedLifetime(lock) {} }; return try existing(operationID, in: directory)
    }
    func receipt(operationID: UUID) throws -> DeviceMutationReceipt? { try record(operationID: operationID)?.receipt }
    private func capacity(in directory: SupportDirectory, now: Int64, reserve: Int) throws {
        var bytes: Int64 = 0
        for name in try names(in: directory) {
            let fd = try directory.file(name); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_size >= 0 else { throw SupportStorageError.unsafeFile }
            if name.hasPrefix("operation-") {
                let record = try StrictJSON.decode(DeviceJournalRecord.self, from: SupportDirectory.read(fd, limit: StrictJSON.byteLimit))
                if record.acceptedAtMilliseconds <= now - Self.retentionMilliseconds {
                    var named = stat()
                    guard fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0, SupportDirectory.same(named, info),
                          unlinkat(directory.fd, name, 0) == 0 else { throw SupportStorageError.unsafeFile }
                    continue // Only expired, checked owned records may be pruned.
                }
            }
            bytes += info.st_size
            try requireContract(bytes <= byteLimit, "journalFull")
        }
        try requireContract(reserve <= byteLimit && bytes <= Int64(byteLimit - reserve), "journalFull")
        var space = statvfs()
        guard fstatvfs(directory.fd, &space) == 0, space.f_bavail > UInt64(reserve) / max(1, UInt64(space.f_frsize)) + 1,
              fsync(directory.fd) == 0 else { throw DeviceContractError.invalid("journalPersistence") }
    }
    func claim(plan: DevicePlan, initial: DeviceMutationReceipt, now: Int64) throws -> Claim {
        try plan.validate(); try initial.validate()
        try requireContract(now >= plan.issuedAtMilliseconds && now < plan.expiresAtMilliseconds
            && initial.operationID == plan.operationID && initial.identity == plan.identity && initial.outcome == .notAttempted, "expiredOrInvalidPlan")
        let directory = try directory, lock = try directory.lock("journal.lock")
        defer { withExtendedLifetime(lock) {} }
        let digest = SupportPackageContent.hash(try StrictJSON.canonical(plan))
        if let record = try existing(plan.operationID, in: directory) {
            try requireContract(record.planDigest == digest, "operationUUIDReused"); return .existing(record)
        }
        let old = try domain(plan.identity.domainID, in: directory)
        try requireContract(old.epoch == plan.domainEpoch && old.epoch < UInt64.max, "staleDomainEpoch")
        try capacity(in: directory, now: now, reserve: StrictJSON.byteLimit * 2)
        if let last = old.last { try directory.atomicWrite(StrictJSON.canonical(last), name: recordName(last.operationID)) }
        let record = DeviceJournalRecord(operationID: plan.operationID, planDigest: digest, domainID: plan.identity.domainID,
            acceptedAtMilliseconds: now, receipt: initial, terminal: false)
        let next = DeviceJournalDomain(domainID: old.domainID, epoch: old.epoch + 1, last: record)
        try beforePersist?("claim")
        try directory.atomicWrite(StrictJSON.canonical(next), name: domainName(old.domainID))
        return .accepted(record)
    }
    /// Persist possible-write before the first mutating worker is launched.
    func markPossibleWrite(_ record: DeviceJournalRecord, receipt: DeviceMutationReceipt) throws -> DeviceJournalRecord {
        try requireContract(receipt.writeMayHaveOccurred && !receipt.verified, "journalPossibleWrite")
        return try update(record, receipt: receipt, terminal: false, phase: "possibleWrite")
    }
    @discardableResult
    func finish(_ record: DeviceJournalRecord, receipt: DeviceMutationReceipt) throws -> DeviceJournalRecord {
        try update(record, receipt: receipt, terminal: true, phase: "terminal")
    }
    private func update(_ record: DeviceJournalRecord, receipt: DeviceMutationReceipt, terminal: Bool, phase: String) throws -> DeviceJournalRecord {
        try receipt.validate()
        try requireContract(receipt.operationID == record.operationID && receipt.identity.domainID == record.domainID, "journalReceiptIdentity")
        let directory = try directory, lock = try directory.lock("journal.lock")
        defer { withExtendedLifetime(lock) {} }
        let current = try domain(record.domainID, in: directory)
        guard let last = current.last, last.operationID == record.operationID, last.planDigest == record.planDigest, !last.terminal else {
            throw DeviceContractError.invalid("journalClaimChanged")
        }
        let next = DeviceJournalRecord(operationID: record.operationID, planDigest: record.planDigest, domainID: record.domainID,
            acceptedAtMilliseconds: record.acceptedAtMilliseconds, receipt: receipt, terminal: terminal)
        try capacity(in: directory, now: record.acceptedAtMilliseconds, reserve: StrictJSON.byteLimit)
        try beforePersist?(phase)
        try directory.atomicWrite(StrictJSON.canonical(DeviceJournalDomain(domainID: current.domainID, epoch: current.epoch, last: next)), name: domainName(current.domainID))
        return next
    }
}
