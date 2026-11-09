import Foundation

/// A write to the backup queue, reported after it committed. The pending grid follows the queue through
/// these notifications instead of polling it.
public enum UploadBackupSyncQueueChange: Sendable, Equatable {
    /// Rows of these sources changed (inserted, updated or removed).
    case sources([UploadSourceIdentity.Kind: Set<String>])
    /// Runnable rows of these sources were inserted or reopened by a committed enqueue write.
    case enqueued([UploadSourceIdentity.Kind: Set<String>])
    /// A bulk update touched an unknown set of rows.
    case all

    init<S: Sequence>(sources: S, enqueued: Bool = false) where S.Element == UploadSourceIdentity {
        var grouped: [UploadSourceIdentity.Kind: Set<String>] = [:]
        for source in sources { grouped[source.kind, default: []].insert(source.identifier) }
        self = enqueued ? .enqueued(grouped) : .sources(grouped)
    }
}

/// The light view of one queue row that the pending grid needs.
public struct UploadBackupQueueRowState: Sendable, Equatable {
    public let source: UploadSourceIdentity
    public let revision: UploadBackupRevision
    public let state: UploadBackupSyncQueueState
    public let originalFilename: String
    public let updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        originalFilename: String,
        updatedAt: Date
    ) {
        self.source = source
        self.revision = revision
        self.state = state
        self.originalFilename = originalFilename
        self.updatedAt = updatedAt
    }
}

/// Queue reads and change notifications for the pending grid. Only the SQLite store implements it.
public protocol UploadBackupSyncQueueObserving: Sendable {
    /// Replaces the observer. The store calls it after each committed write, outside its lock.
    func setChangeObserver(_ observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?)
    /// Adds an independent subscriber to the same committed changes. Cancellation removes only this subscriber.
    func changes() -> AsyncStream<UploadBackupSyncQueueChange>
    /// Latest backed-up revision per source, read with one aggregate query at load.
    func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision]
    /// Complete rows for a decision. Throws when a read fails or cannot return a complete result.
    func decisionRows(kind: UploadSourceIdentity.Kind, identifiers: Set<String>) throws -> [UploadBackupQueueRowState]
    /// Rows that are not settled: every state except the terminal outcomes, from a complete read. Completed rows are
    /// excluded; the pending store keeps their handoffs. Throws when the read fails or cannot return a complete result,
    /// so a failed read never looks like an empty queue (#1004).
    func decisionUnsettledRows() throws -> [UploadBackupQueueRowState]
}

public extension UploadBackupSyncQueueObserving {
    /// True only when a complete read finds no row of these sources. A removal proves itself with this read: a later
    /// health check can pass again after a failed write, so it proves nothing about the removal (#1004).
    func holdsNoRows(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Bool {
        (try? decisionRows(kind: kind, identifiers: Set(identifiers)))?.isEmpty == true
    }

    /// Stores without live notifications can still provide the pending-grid reads.
    func changes() -> AsyncStream<UploadBackupSyncQueueChange> {
        AsyncStream { $0.finish() }
    }
}
