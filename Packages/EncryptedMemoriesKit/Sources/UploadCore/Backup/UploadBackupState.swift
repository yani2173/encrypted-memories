import Foundation

/// Microsecond-quantized asset revision. Core stores revisions as integers so SQLite/user-default
/// round-trips cannot introduce floating-point drift.
public struct UploadBackupRevision: Sendable, Hashable, Comparable, Codable {
    public static let scale: Double = 1_000_000

    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(date: Date) {
        self.rawValue = Int64((date.timeIntervalSinceReferenceDate * Self.scale).rounded())
    }

    public var date: Date {
        Date(timeIntervalSinceReferenceDate: Double(rawValue) / Self.scale)
    }

    public static func < (lhs: UploadBackupRevision, rhs: UploadBackupRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Optional edit evidence supplied by a platform adapter. PhotoKit can expose adjustment metadata;
/// mutable file-system sources must use `.unavailable` when they cannot prove content stability.
public enum UploadBackupEditRevision: Sendable, Equatable, Codable {
    /// The adapter proved that a metadata revision drift did not correspond to a content edit.
    /// PhotoKit can use this for a known asset when adjustment evidence is present and empty.
    case trustedNoContentEdits
    /// The source exposes a reliable content-edit revision.
    case revision(UploadBackupRevision)
    /// The adapter could not read reliable edit evidence. Core must not assume the asset is safe.
    case unavailable
}

/// Stable identity supplied by a source ecosystem and stored in Proton's encrypted metadata.
/// PhotoKit uses its iCloud identifier plus modification revision. Core does not interpret the
/// identifier; it only accepts an exact proof returned by the authenticated backend.
public struct UploadBackupExternalIdentity: Sendable, Hashable, Equatable, Codable {
    public let identifier: String
    public let revision: UploadBackupRevision

    public init(identifier: String, revision: UploadBackupRevision) {
        precondition(!identifier.isEmpty, "External backup identity cannot be empty")
        self.identifier = identifier
        self.revision = revision
    }

    /// Proton serializes this timestamp through ISO-8601 milliseconds. Quantizing at the Core
    /// boundary keeps a locally observed Date equal to the authenticated value read back later.
    public init(identifier: String, modificationDate: Date) {
        self.init(
            identifier: identifier,
            revision: UploadBackupRevision(
                rawValue: Int64((modificationDate.timeIntervalSinceReferenceDate * 1_000).rounded()) * 1_000
            )
        )
    }
}

/// One local logical asset seen by a future backup/sync source. A Live Photo still appears as one
/// asset with multiple resources; individual resource hashing/upload remains in `UploadDedupePipeline`.
public struct UploadBackupAssetSnapshot: Sendable, Equatable {
    public let source: UploadSourceIdentity
    public let revision: UploadBackupRevision
    public let editRevision: UploadBackupEditRevision
    public let resourceCount: Int
    public let externalIdentity: UploadBackupExternalIdentity?

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        editRevision: UploadBackupEditRevision = .unavailable,
        resourceCount: Int,
        externalIdentity: UploadBackupExternalIdentity? = nil
    ) {
        precondition(resourceCount > 0, "Upload backup assets must expose at least one resource")
        self.source = source
        self.revision = revision
        self.editRevision = editRevision
        self.resourceCount = resourceCount
        self.externalIdentity = externalIdentity
    }
}

/// Persisted backup/sync state for one source revision. `pendingResourceCount == 0` means every
/// resource of that asset revision is known to be represented in Proton Drive.
public struct UploadBackupAssetRecord: Sendable, Equatable {
    public var source: UploadSourceIdentity
    public var revision: UploadBackupRevision
    public var resourceCount: Int
    public var pendingResourceCount: Int
    public var updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        resourceCount: Int,
        pendingResourceCount: Int,
        updatedAt: Date
    ) {
        precondition(resourceCount > 0, "Upload backup records must expose at least one resource")
        precondition(pendingResourceCount >= 0, "Pending resource count cannot be negative")
        self.source = source
        self.revision = revision
        self.resourceCount = resourceCount
        self.pendingResourceCount = min(pendingResourceCount, resourceCount)
        self.updatedAt = updatedAt
    }

    public var isComplete: Bool { pendingResourceCount == 0 }
}

public protocol UploadBackupStateStore: Sendable {
    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord?
    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool
    /// Reads every row needed to classify a discovery chunk. `succeeded == false` is distinct from
    /// an empty store: duplicate safety must stop on a DB read error instead of treating assets as new.
    func lookupBatch(_ snapshots: [UploadBackupAssetSnapshot]) -> [UploadBackupStateLookup]
    /// Returns false when the row was not durably stored. Callers must not publish a terminal
    /// backup state after a failed write.
    @discardableResult
    func upsert(_ record: UploadBackupAssetRecord) -> Bool
    @discardableResult
    func upsertBatch(_ records: [UploadBackupAssetRecord]) -> Bool
    /// Removes every state of `source` except `revisions`. Returns false when nothing was durably removed.
    @discardableResult
    func removeRecords(for source: UploadSourceIdentity, keeping revisions: Set<UploadBackupRevision>) -> Bool
    func count() -> Int
}

public struct UploadBackupStateLookup: Sendable {
    public var succeeded: Bool
    public var directRecord: UploadBackupAssetRecord?
    public var hasAnyRecord: Bool
    public var editRecord: UploadBackupAssetRecord?

    public init(
        succeeded: Bool = true,
        directRecord: UploadBackupAssetRecord?,
        hasAnyRecord: Bool,
        editRecord: UploadBackupAssetRecord?
    ) {
        self.succeeded = succeeded
        self.directRecord = directRecord
        self.hasAnyRecord = hasAnyRecord
        self.editRecord = editRecord
    }
}

public extension UploadBackupStateStore {
    func lookupBatch(_ snapshots: [UploadBackupAssetSnapshot]) -> [UploadBackupStateLookup] {
        snapshots.map { snapshot in
            let direct = record(for: snapshot.source, revision: snapshot.revision)
            let editRecord: UploadBackupAssetRecord? =
                if case .revision(let editRevision) = snapshot.editRevision {
                    record(for: snapshot.source, revision: editRevision)
                } else {
                    nil
                }
            return UploadBackupStateLookup(
                directRecord: direct,
                hasAnyRecord: direct != nil || hasAnyRecord(for: snapshot.source),
                editRecord: editRecord
            )
        }
    }

    func upsertBatch(_ records: [UploadBackupAssetRecord]) -> Bool {
        records.allSatisfy(upsert)
    }

    /// Stores without removal fail, so a caller never trusts a state it could not forget.
    func removeRecords(for source: UploadSourceIdentity, keeping revisions: Set<UploadBackupRevision>) -> Bool {
        false
    }
}

public enum UploadBackupCheckDecision: Sendable, Equatable {
    public enum BackendCheckReason: Sendable, Equatable {
        /// The metadata revision changed and the adapter found a reliable edit marker that has
        /// never been backed up before.
        case unseenEditRevision
        /// The metadata revision changed, but the adapter could not read enough edit evidence to
        /// safely classify it locally.
        case unreliableEditRevision
    }

    case alreadyBackedUp
    case pendingUpload(remainingResources: Int)
    case newAsset
    case needsBackendCheck(BackendCheckReason)
}

/// Shared backup/sync safety net. Platform sources do only enumeration and metadata extraction;
/// this actor owns the cross-platform "should this asset be checked/uploaded?" decision.
public actor UploadBackupPreflightIndex {
    private let store: any UploadBackupStateStore
    private let now: @Sendable () -> Date

    public init(store: any UploadBackupStateStore, now: @Sendable @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func classify(_ snapshot: UploadBackupAssetSnapshot) throws -> UploadBackupCheckDecision {
        guard let lookup = store.lookupBatch([snapshot]).first, lookup.succeeded else {
            throw UploadError.backend("Backup state could not be read")
        }
        return try classify(snapshot, lookup: lookup)
    }

    public func classifyBatch(_ snapshots: [UploadBackupAssetSnapshot]) throws -> [UploadBackupCheckDecision] {
        guard !snapshots.isEmpty else { return [] }
        let lookups = store.lookupBatch(snapshots)
        guard lookups.count == snapshots.count, lookups.allSatisfy(\.succeeded) else {
            throw UploadError.backend("Backup state batch could not be read")
        }
        return try zip(snapshots, lookups).map { snapshot, lookup in
            try classify(snapshot, lookup: lookup)
        }
    }

    private func classify(
        _ snapshot: UploadBackupAssetSnapshot,
        lookup: UploadBackupStateLookup
    ) throws -> UploadBackupCheckDecision {
        if let direct = lookup.directRecord {
            return Self.decision(for: direct)
        }

        guard lookup.hasAnyRecord else {
            return .newAsset
        }

        switch snapshot.editRevision {
        case .trustedNoContentEdits:
            try markBackedUp(snapshot)
            return .alreadyBackedUp

        case .revision(let editRevision):
            guard let editRecord = lookup.editRecord, editRecord.revision == editRevision else {
                return .needsBackendCheck(.unseenEditRevision)
            }
            if editRecord.isComplete {
                try markBackedUp(snapshot)
                return .alreadyBackedUp
            }
            return .pendingUpload(remainingResources: editRecord.pendingResourceCount)

        case .unavailable:
            return .needsBackendCheck(.unreliableEditRevision)
        }
    }

    public func markPending(_ snapshot: UploadBackupAssetSnapshot, pendingResourceCount: Int? = nil) throws {
        guard
            store.upsert(
                UploadBackupAssetRecord(
                    source: snapshot.source,
                    revision: snapshot.revision,
                    resourceCount: snapshot.resourceCount,
                    pendingResourceCount: pendingResourceCount ?? snapshot.resourceCount,
                    updatedAt: now()
                ))
        else {
            throw UploadError.backend("Backup state could not be saved")
        }
    }

    /// Whether each exact revision holds a complete state, in the order of `snapshots`.
    public func completeStates(_ snapshots: [UploadBackupAssetSnapshot]) throws -> [Bool] {
        guard !snapshots.isEmpty else { return [] }
        let lookups = store.lookupBatch(snapshots)
        guard lookups.count == snapshots.count, lookups.allSatisfy(\.succeeded) else {
            throw UploadError.backend("Backup state batch could not be read")
        }
        return lookups.map { $0.directRecord?.isComplete == true }
    }

    /// Marks a complete state of this exact revision pending again: its backup lacks a file. Returns whether the
    /// revision is pending work. A revision without a state keeps the usual classification.
    public func reopen(_ snapshot: UploadBackupAssetSnapshot) throws -> Bool {
        guard let lookup = store.lookupBatch([snapshot]).first, lookup.succeeded else {
            throw UploadError.backend("Backup state could not be read")
        }
        guard let direct = lookup.directRecord else { return false }
        guard direct.isComplete else { return true }
        try markPending(snapshot)
        return true
    }

    /// Forgets every earlier state of the asset. An edit replaced its earlier upload, so a later return to an
    /// earlier state, for example undoing the edit, is no longer backed up and must pass the duplicate check.
    public func forgetEarlierStates(of snapshot: UploadBackupAssetSnapshot) throws {
        var keeping: Set<UploadBackupRevision> = [snapshot.revision]
        if case .revision(let editRevision) = snapshot.editRevision { keeping.insert(editRevision) }
        guard store.removeRecords(for: snapshot.source, keeping: keeping) else {
            throw UploadError.backend("Backup state could not be updated")
        }
    }

    public func markBackedUp(_ snapshot: UploadBackupAssetSnapshot) throws {
        try markBackedUpBatch([snapshot])
    }

    public func markBackedUpBatch(_ snapshots: [UploadBackupAssetSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        let timestamp = now()
        var records: [UploadBackupAssetRecord] = []
        records.reserveCapacity(snapshots.count * 2)
        for snapshot in snapshots {
            records.append(
                UploadBackupAssetRecord(
                    source: snapshot.source,
                    revision: snapshot.revision,
                    resourceCount: snapshot.resourceCount,
                    pendingResourceCount: 0,
                    updatedAt: timestamp
                ))
            if case .revision(let editRevision) = snapshot.editRevision,
                editRevision != snapshot.revision
            {
                records.append(
                    UploadBackupAssetRecord(
                        source: snapshot.source,
                        revision: editRevision,
                        resourceCount: snapshot.resourceCount,
                        pendingResourceCount: 0,
                        updatedAt: timestamp
                    ))
            }
        }
        guard store.upsertBatch(records) else {
            throw UploadError.backend("Backup completion state could not be saved")
        }
    }

    private static func decision(for record: UploadBackupAssetRecord) -> UploadBackupCheckDecision {
        record.isComplete ? .alreadyBackedUp : .pendingUpload(remainingResources: record.pendingResourceCount)
    }
}
