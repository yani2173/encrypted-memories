import Foundation

public enum UploadBackupSyncQueueState: String, Sendable, Codable, CaseIterable {
    case discovered
    case checking
    case hashing
    case duplicateChecking
    case queuedForUpload
    case uploading
    case finalizing
    /// Bytes are committed remotely, while local manifest/finalization still needs an idempotent
    /// replay. This state may reconcile metadata but must never upload the resource again.
    case needsRemoteReconciliation
    case alreadyBackedUp
    case completed
    /// Proton proves the identical photo existed and reports it as trashed or deleted remotely.
    /// The deletion is respected: nothing uploads, and the item is a successful policy outcome
    /// without being misrepresented as currently present in Proton Drive.
    case skippedRemoteDeletion
    case sourceMissing
    case blockedByDraft
    case failed
    /// A non-retryable item failure shown until the user acknowledges it.
    case failedPermanent
    /// Acknowledged non-success. It remains durably not backed up but no longer demands attention.
    case dismissedFailure
    case paused

    public var isTerminalSuccess: Bool {
        self == .alreadyBackedUp || self == .completed || self == .skippedRemoteDeletion
    }

    public var isActive: Bool {
        switch self {
        case .checking, .hashing, .duplicateChecking, .uploading, .finalizing:
            return true
        default:
            return false
        }
    }
}

/// Exact queue row that owned a new remote commit. Keeping this inside the existing receipt JSON
/// binds descriptor evidence without changing the queue schema.
public struct UploadRemoteCommitQueueBinding: Sendable, Equatable, Codable {
    public let source: UploadSourceIdentity
    public let revision: UploadBackupRevision

    public init(source: UploadSourceIdentity, revision: UploadBackupRevision) {
        self.source = source
        self.revision = revision
    }
}

public struct UploadRemoteCommitReconciliation: Sendable, Equatable, Codable {
    public let source: UploadSourceIdentity
    public let identity: UploadIdentity
    public let receipt: UploadRemoteCommitReceipt
    /// Exact metadata captured before the irreversible upload result. Older persisted receipts do
    /// not have this field and fall back to source rematerialization during settlement recovery.
    public let descriptor: UploadResourceDescriptorSnapshot?
    /// Present for descriptor-bearing receipts written by current runners. Older descriptor-less
    /// receipts decode with no binding and retain their resolver-backed recovery contract.
    public let queueBinding: UploadRemoteCommitQueueBinding?

    public init(
        source: UploadSourceIdentity,
        identity: UploadIdentity,
        receipt: UploadRemoteCommitReceipt,
        descriptor: UploadResourceDescriptorSnapshot? = nil,
        queueBinding: UploadRemoteCommitQueueBinding? = nil
    ) {
        self.source = source
        self.identity = identity
        self.receipt = receipt
        self.descriptor = descriptor
        self.queueBinding = queueBinding
    }
}

public enum UploadRemoteCommitRecoveryError: LocalizedError, Sendable, Equatable {
    case storeUnavailable
    case malformedReceipt(UploadSourceIdentity, UploadBackupRevision)
    case invalidReceipt(UploadSourceIdentity, UploadBackupRevision)
    case descriptorUnavailable(UploadSourceIdentity, UploadBackupRevision)
    case descriptorMismatch(UploadSourceIdentity, UploadBackupRevision)
    case receiptRemovalFailed(UploadSourceIdentity, UploadBackupRevision)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            "Remote commit reconciliation store is unavailable."
        case .malformedReceipt(let source, _):
            "Remote commit reconciliation is malformed for \(source.identifier)."
        case .invalidReceipt(let source, _):
            "Remote commit receipt is invalid for \(source.identifier)."
        case .descriptorUnavailable(let source, _):
            "Committed resource metadata is unavailable for \(source.identifier)."
        case .descriptorMismatch(let source, _):
            "Committed resource metadata no longer matches \(source.identifier)."
        case .receiptRemovalFailed(let source, _):
            "Settled remote commit receipt could not be removed for \(source.identifier)."
        }
    }
}

public struct UploadBackupSyncQueueEntry: Sendable, Equatable {
    public var source: UploadSourceIdentity
    public var revision: UploadBackupRevision
    public var originalFilename: String
    public var byteCount: Int64?
    public var state: UploadBackupSyncQueueState
    public var attempts: Int
    public var lastError: String?
    public var remoteCommitReconciliation: UploadRemoteCommitReconciliation?
    public var updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        originalFilename: String,
        byteCount: Int64? = nil,
        state: UploadBackupSyncQueueState = .discovered,
        attempts: Int = 0,
        lastError: String? = nil,
        remoteCommitReconciliation: UploadRemoteCommitReconciliation? = nil,
        updatedAt: Date
    ) {
        self.source = source
        self.revision = revision
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.state = state
        self.attempts = max(0, attempts)
        self.lastError = lastError
        self.remoteCommitReconciliation = remoteCommitReconciliation
        self.updatedAt = updatedAt
    }
}

public extension UploadBackupSyncQueueEntry {
    /// A durable check request, not upload permission. Preserve the acknowledged missing reason until bytes return.
    var isDismissedSourceRecheck: Bool {
        Self.isDismissedSourceRecheck(sourceKind: source.kind, state: state, lastError: lastError)
    }

    static func isDismissedSourceRecheck(
        sourceKind: UploadSourceIdentity.Kind, state: UploadBackupSyncQueueState, lastError: String?
    ) -> Bool {
        sourceKind == .photoLibraryAsset && (state == .discovered || state == .checking)
            && BackupIssueRecord.decode(lastError)?.kind == .sourceMissing
    }
}

public struct UploadBackupSyncQueueSummary: Sendable, Equatable {
    public var total = 0
    public var waiting = 0
    /// Subset of `waiting` whose duplicate check already produced an `.upload` decision - these
    /// rows wait for bytes, not for checking. Lets UI say "queued for upload" honestly.
    public var queuedForUpload = 0
    public var active = 0
    /// Active rows in the pre-upload phase (checking/hashing/duplicateChecking).
    public var checkingActive = 0
    /// Active rows pushing or finalizing bytes (uploading/finalizing).
    public var uploadingActive = 0
    public var alreadyBackedUp = 0
    public var uploaded = 0
    /// Deliberately not re-uploaded because Proton proves the identical photo was deleted there.
    public var skippedRemoteDeletions = 0
    public var sourceMissing = 0
    public var blocked = 0
    public var failed = 0
    public var dismissedFailures = 0
    /// Subset of dismissedFailures that still owes an admitted source check. Never another photo or upload.
    public var pendingSourceRechecks = 0
    public var paused = 0

    public init() {}

    /// Items that are proven backed up (uploaded by us or confirmed active remotely). This is the
    /// only number UI may present as "gesichert".
    public var resolved: Int {
        alreadyBackedUp + uploaded
    }

    /// Successful queue outcomes, including an explicit remote deletion the backup policy respects.
    /// `resolved` stays narrower because UI may call only actually-present items "backed up".
    public var settledSuccessfully: Int {
        resolved + skippedRemoteDeletions
    }

    public var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(settledSuccessfully) / Double(total)
    }

    public var hasWork: Bool {
        total > 0 && settledSuccessfully < total
    }

    public mutating func include(_ state: UploadBackupSyncQueueState, count: Int = 1) {
        let count = max(0, count)
        total += count
        switch state {
        case .discovered:
            waiting += count
        case .queuedForUpload:
            waiting += count
            queuedForUpload += count
        case .needsRemoteReconciliation:
            waiting += count
        case .checking, .hashing, .duplicateChecking:
            active += count
            checkingActive += count
        case .uploading, .finalizing:
            active += count
            uploadingActive += count
        case .alreadyBackedUp:
            alreadyBackedUp += count
        case .completed:
            uploaded += count
        case .skippedRemoteDeletion:
            skippedRemoteDeletions += count
        case .sourceMissing:
            sourceMissing += count
        case .blockedByDraft:
            blocked += count
        case .failed:
            failed += count
        case .failedPermanent:
            failed += count
        case .dismissedFailure:
            dismissedFailures += count
        case .paused:
            paused += count
        }
    }
}

/// Account-scoped failures that block the queue as a whole rather than one photo. They live beside the
/// durable queue so a process restart cannot turn a concrete failure back into generic "waiting".
public enum BackupRuntimeIssueKey: String, Sendable, Codable {
    case remoteIndexPreparation
}

/// Durable state for rebuilding a reset backup queue from the independent photo-library catalog.
/// `inProgress` is distinct from `notStarted` so an interrupted replay resumes instead of being
/// mistaken for an already-populated queue on the next launch.
public enum UploadBackupCatalogReplayState: Int, Sendable, Codable {
    case notStarted = 0
    case inProgress = 1
    case completed = 2
}

public protocol UploadBackupSyncQueueStore: Sendable {
    /// False after a SQLite operation failed or the store was closed. An empty read is safe to
    /// interpret as "drained" only while this remains true.
    func isOperational() -> Bool
    /// Makes every committed change survive a power loss. Returns false when that is not certain.
    func synchronizeToDisk() -> Bool
    /// Persists one row. The row survives a power loss once this returns true.
    @discardableResult
    func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool
    /// Persists one discovery chunk atomically. The rows survive a power loss once this returns true. The default
    /// keeps test/fake stores source-compatible; the SQLite store reuses one statement and one transaction for the
    /// whole chunk.
    @discardableResult
    func upsertBatch(_ entries: [UploadBackupSyncQueueEntry]) -> Bool
    /// Conditional durable transition for an acknowledged missing-source check. Nil means a failed write;
    /// false means the row changed or gained a remote receipt. Only the runner can release the saved reason.
    func updateDismissedSourceRecheck(
        _ entry: UploadBackupSyncQueueEntry, matchingState: UploadBackupSyncQueueState, matchingLastError: String
    ) -> Bool?
    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry?
    /// Bounded, strict scan of every row carrying durable remote-commit evidence, independent of
    /// queue state. A malformed non-null payload is an error, never ordinary no-receipt work.
    func entriesWithRemoteCommitReconciliation(limit: Int) throws -> [UploadBackupSyncQueueEntry]
    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry]
    /// Earliest persisted eligibility time for any runnable row outside `excludedSources` (same kind and identifier,
    /// as in `claimRunnable`). Retry delays survive process death, so a restarted runner can wait for due work
    /// instead of declaring the queue drained.
    func nextRunnableDate(excludingSourcesOf excludedSources: [UploadSourceIdentity]) -> Date?
    /// Earliest eligible/backoff row for status and scheduling. Unlike `nextRunnable(limit:)`, this
    /// is ordered by eligibility rather than newest-photo execution priority.
    func earliestRunnableEntry() -> UploadBackupSyncQueueEntry?
    func earliestEntry(in state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry?
    func containsAny(in states: [UploadBackupSyncQueueState]) -> Bool
    /// Atomically reserves runnable rows for one runner. Returned entries keep their pre-claim
    /// state so the runner can mirror progress accurately; the store has already moved them to an
    /// active state, so another runner cannot take the same work. Crash recovery demotes these
    /// active rows back to runnable via `requeueStaleActive`. Rows of a source in `excludedSources` (same kind and
    /// identifier, any resource or revision) stay unclaimed: the runner passes the sources it processes, because
    /// their rows can be runnable for a moment, for example while the paired video of an uploaded photo uploads.
    func claimRunnable(
        limit: Int, claimedAt: Date, excludingSourcesOf excludedSources: [UploadSourceIdentity]
    ) -> [UploadBackupSyncQueueEntry]
    /// Rows currently in `state` whose `updatedAt` is older than `updatedBefore`, oldest first.
    /// The runner uses this to find parked `blockedByDraft` rows whose re-check backoff elapsed.
    func entries(in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int) -> [UploadBackupSyncQueueEntry]
    @discardableResult
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int
    /// Makes every non-active retryable row immediately eligible for an explicit user retry.
    /// Terminal successes, respected remote deletions, and missing local sources are untouched.
    @discardableResult
    func makeRetryableWorkEligible(updatedAt: Date) -> Int
    /// Removes one source revision that no longer belongs to the local backup set. Local deletion
    /// is user intent, not a terminal backup failure.
    @discardableResult
    func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool
    /// Removes a resolver-reported missing source and durably requests another catalog reconciliation.
    @discardableResult
    func removeMissingSource(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool
    /// Monotonic count of missing Photo Library sources removed from this queue. Nil means a failed read.
    func missingSourceDiscardGeneration() -> Int64?
    /// Sources with any queue row, across resources and revisions. Nil means a failed read.
    func sourcesWithEntries(_ sources: [UploadSourceIdentity]) -> Set<UploadSourceIdentity>?
    /// Inserts only sources without any queue row. Existing rows, including user decisions, stay untouched.
    @discardableResult
    func insertMissingSources(_ entries: [UploadBackupSyncQueueEntry]) -> Bool
    /// Removes the backed-up rows of every other revision of the source. An edit replaced its earlier upload, so a
    /// later return to an earlier revision, for example undoing the edit, must start as new work.
    @discardableResult
    func removeSettledRevisions(of source: UploadSourceIdentity, except revision: UploadBackupRevision) -> Bool
    /// Removes the rows of earlier revisions that ended without a backup (skipped as deleted, parked, or dismissed)
    /// once a later revision is backed up: the photo is in Proton Drive again, so they no longer ask or count.
    @discardableResult
    func removeUnsavedEarlierRevisions(
        of source: UploadSourceIdentity, through revision: UploadBackupRevision, except kept: UploadBackupRevision
    ) -> Bool
    /// Applies the same obsolete-revision rules to each successful entry in a scan batch.
    @discardableResult
    func removeUnsavedEarlierRevisions(of entries: [UploadBackupSyncQueueEntry]) -> Bool
    /// Removes every queued revision/resource for the supplied source identifiers. This is used by
    /// live catalog change delivery so a deletion also cancels work already claimed by the runner.
    @discardableResult
    func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int
    @discardableResult
    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool
    /// Atomically records proof of an irreversible server commit before local manifest settlement.
    /// A runner claiming this row may only replay local reconciliation, never upload its bytes.
    @discardableResult
    func markNeedsRemoteReconciliation(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        reconciliation: UploadRemoteCommitReconciliation,
        lastError: String?,
        updatedAt: Date
    ) -> Bool
    /// Acknowledges one permanent failure without claiming the item was backed up.
    @discardableResult
    func dismissPermanentFailure(source: UploadSourceIdentity, revision: UploadBackupRevision, updatedAt: Date) -> Bool
    func summary() -> UploadBackupSyncQueueSummary
    func count() -> Int
    func runtimeIssue(for key: BackupRuntimeIssueKey) -> BackupIssueRecord?
    @discardableResult
    func setRuntimeIssue(_ issue: BackupIssueRecord?, for key: BackupRuntimeIssueKey) -> Bool
}

public extension UploadBackupSyncQueueStore {
    func updateDismissedSourceRecheck(
        _ entry: UploadBackupSyncQueueEntry, matchingState: UploadBackupSyncQueueState, matchingLastError: String
    ) -> Bool? { nil }

    func isOperational() -> Bool { true }

    func removeMissingSource(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        remove(source: source, revision: revision)
    }

    func missingSourceDiscardGeneration() -> Int64? { 0 }
    func sourcesWithEntries(_ sources: [UploadSourceIdentity]) -> Set<UploadSourceIdentity>? { nil }
    func insertMissingSources(_ entries: [UploadBackupSyncQueueEntry]) -> Bool { false }

    func nextRunnableDate() -> Date? {
        nextRunnableDate(excludingSourcesOf: [])
    }

    func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        claimRunnable(limit: limit, claimedAt: claimedAt, excludingSourcesOf: [])
    }

    func upsertBatch(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        entries.allSatisfy(upsert)
    }

    func earliestRunnableEntry() -> UploadBackupSyncQueueEntry? {
        nextRunnable(limit: Int.max).min { $0.updatedAt < $1.updatedAt }
    }

    func entriesWithRemoteCommitReconciliation(limit: Int) throws -> [UploadBackupSyncQueueEntry] {
        guard isOperational() else { throw UploadRemoteCommitRecoveryError.storeUnavailable }
        let limit = max(1, limit)
        var result: [UploadBackupSyncQueueEntry] = []
        result.reserveCapacity(limit)
        for state in UploadBackupSyncQueueState.allCases {
            // Generic test stores cannot express a receipt predicate. Inspect their complete state
            // slice so ordinary rows ahead of a receipt cannot make a complete scan look empty;
            // the production SQLite store overrides this with a bounded WHERE/limit query.
            for entry in entries(in: state, updatedBefore: .distantFuture, limit: .max) {
                if entry.remoteCommitReconciliation != nil {
                    result.append(entry)
                    if result.count == limit { return result }
                }
            }
        }
        guard isOperational() else { throw UploadRemoteCommitRecoveryError.storeUnavailable }
        return result
    }

    func earliestEntry(in state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry? {
        entries(in: state, updatedBefore: .distantFuture, limit: Int.max)
            .min { $0.updatedAt < $1.updatedAt }
    }

    func containsAny(in states: [UploadBackupSyncQueueState]) -> Bool {
        states.contains { earliestEntry(in: $0) != nil }
    }

    func runtimeIssue(for key: BackupRuntimeIssueKey) -> BackupIssueRecord? { nil }

    @discardableResult
    func setRuntimeIssue(_ issue: BackupIssueRecord?, for key: BackupRuntimeIssueKey) -> Bool { true }

    @discardableResult
    func markNeedsRemoteReconciliation(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        reconciliation: UploadRemoteCommitReconciliation,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        guard var entry = entry(for: source, revision: revision) else { return false }
        entry.state = .needsRemoteReconciliation
        entry.lastError = lastError
        entry.remoteCommitReconciliation = reconciliation
        entry.updatedAt = updatedAt
        return upsert(entry)
    }

    @discardableResult
    func makeRetryableWorkEligible(updatedAt: Date) -> Int {
        var changed = 0
        for state in [
            UploadBackupSyncQueueState.failed,
            .blockedByDraft,
            .discovered,
            .queuedForUpload,
            .needsRemoteReconciliation,
        ] {
            for entry in entries(in: state, updatedBefore: .distantFuture, limit: .max) {
                guard !entry.isDismissedSourceRecheck else { continue }
                let target: UploadBackupSyncQueueState =
                    switch state {
                    case .failed, .blockedByDraft: .discovered
                    default: state
                    }
                if updateState(
                    source: entry.source,
                    revision: entry.revision,
                    state: target,
                    attempts: state == .failed ? 0 : nil,
                    lastError: entry.lastError,
                    updatedAt: updatedAt
                ) {
                    changed += 1
                }
            }
        }
        return changed
    }

    func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool { false }

    func removeSettledRevisions(of source: UploadSourceIdentity, except revision: UploadBackupRevision) -> Bool {
        true
    }

    func removeUnsavedEarlierRevisions(
        of source: UploadSourceIdentity, through revision: UploadBackupRevision, except kept: UploadBackupRevision
    ) -> Bool {
        true
    }

    func removeUnsavedEarlierRevisions(of entries: [UploadBackupSyncQueueEntry]) -> Bool {
        for entry in entries {
            guard removeUnsavedEarlierRevisions(of: entry.source, through: entry.revision, except: entry.revision)
            else {
                return false
            }
        }
        return true
    }

    func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int { 0 }

    @discardableResult
    func dismissPermanentFailure(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        updatedAt: Date
    ) -> Bool {
        updateState(
            source: source,
            revision: revision,
            state: .dismissedFailure,
            attempts: nil,
            lastError: entry(for: source, revision: revision)?.lastError,
            updatedAt: updatedAt
        )
    }
}
