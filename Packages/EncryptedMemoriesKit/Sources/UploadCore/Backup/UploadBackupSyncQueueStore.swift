import Foundation
import PhotosCore
import SQLite3

/// Persistent sync work queue (`upload-backup-sync-queue-v1.sqlite`). The queue stores source
/// identities and revisions, not temporary export URLs; platform adapters rematerialize resources
/// when work resumes after a launch, background wake, or extension invocation.
public final class UploadBackupSyncQueueManifestStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    public static let databaseFileName = "upload-backup-sync-queue-v1.sqlite"

    private static let schemaVersion = 2
    private static let catalogReplayStateKey = "catalog_replay_state"
    private var db: OpaquePointer?
    private var operationFailed = false
    private let lock = NSLock()
    private let observerLock = NSLock()
    private var changeObserver: (@Sendable (UploadBackupSyncQueueChange) -> Void)?
    private let supportTrail: SupportEventTrail

    public init?(
        url: URL, policy: LibraryDatabasePolicy = .conservative, supportTrail: SupportEventTrail = .shared
    ) {
        self.supportTrail = supportTrail
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This queue can contain the only durable receipt for a remotely committed upload.
        // Open failures must therefore fail closed and leave the database untouched for a
        // compatible future build or explicit recovery. Never replace it with an empty queue.
        guard let handle = Self.openOnce(url: url, policy: policy) else { return nil }
        db = handle
        SupportDiagnosticsSources.shared.registerQueue(self, key: url.standardizedFileURL.path)
    }

    deinit { close() }

    public func isOperational() -> Bool {
        lock.withLock {
            guard db != nil, !operationFailed else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1;", -1, &stmt, nil) == SQLITE_OK else {
                operationFailed = true
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                operationFailed = true
                return false
            }
            return true
        }
    }

    public func close() {
        lock.withLock {
            guard db != nil else { return }
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    @discardableResult
    private func upsertUnobserved(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK) else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bind(entry, to: stmt)
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    @discardableResult
    private func upsertBatchUnobserved(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK),
                requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_finalize(stmt)
                return false
            }
            defer { sqlite3_finalize(stmt) }

            var didPersist = true
            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(entry, to: stmt)
                guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    didPersist = false
                    break
                }
            }
            guard didPersist,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT original_filename, byte_count, state, attempts, last_error, updated_at,
                               remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                return row(stmt, source: source, revision: revision)
            }
            if result != SQLITE_DONE { operationFailed = true }
            return nil
        }
    }

    public func entriesWithRemoteCommitReconciliation(limit: Int) throws -> [UploadBackupSyncQueueEntry] {
        try lock.withLock {
            guard db != nil, !operationFailed else {
                throw UploadRemoteCommitRecoveryError.storeUnavailable
            }
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE remote_commit_reconciliation IS NOT NULL
                        ORDER BY updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { throw UploadRemoteCommitRecoveryError.storeUnavailable }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clamping: max(1, limit)))

            var entries: [UploadBackupSyncQueueEntry] = []
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    throw UploadRemoteCommitRecoveryError.storeUnavailable
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let reconciliation = strictReconciliation(stmt, column: 10) else {
                    operationFailed = true
                    throw UploadRemoteCommitRecoveryError.malformedReceipt(source, revision)
                }
                entries.append(
                    UploadBackupSyncQueueEntry(
                        source: source,
                        revision: revision,
                        originalFilename: columnText(stmt, 4) ?? "",
                        byteCount: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                            ? nil : sqlite3_column_int64(stmt, 5),
                        state: UploadBackupSyncQueueState(rawValue: columnText(stmt, 6) ?? "") ?? .failed,
                        attempts: Int(sqlite3_column_int(stmt, 7)),
                        lastError: columnText(stmt, 8),
                        remoteCommitReconciliation: reconciliation,
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                    ))
                result = sqlite3_step(stmt)
            }
            guard requireOperational(result == SQLITE_DONE) else {
                throw UploadRemoteCommitRecoveryError.storeUnavailable
            }
            return entries
        }
    }

    public func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state IN (\(Self.runnableStateList))
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    return []
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let entry = row(stmt, source: source, revision: revision, offset: 4) else { return [] }
                entries.append(entry)
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return entries
        }
    }

    public func nextRunnableDate() -> Date? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT MIN(updated_at) FROM backup_sync_queue "
                            + "WHERE state IN (\(Self.runnableStateList));",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            guard requireOperational(result == SQLITE_ROW) else { return nil }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
                return nil
            }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    private static let runnableStates: [String] = ["discovered", "queuedForUpload", "needsRemoteReconciliation"]
    /// SQL literal of `runnableStates`; every runnable-set query interpolates this one list.
    private static let runnableStateList = runnableStates.map { "'\($0)'" }.joined(separator: ", ")

    private static let entryColumns = """
        source_kind, source_id, resource, revision_us, original_filename, byte_count,
               state, attempts, last_error, updated_at, remote_commit_reconciliation
        """

    private static func earliestEntrySQL(forState state: String) -> String {
        "SELECT \(entryColumns) FROM backup_sync_queue WHERE state='\(state)' ORDER BY updated_at ASC LIMIT 1"
    }

    public func earliestRunnableEntry() -> UploadBackupSyncQueueEntry? {
        let perState = Self.runnableStates
            .map { "SELECT * FROM (\(Self.earliestEntrySQL(forState: $0)))" }
            .joined(separator: " UNION ALL ")
        return earliestEntry(sql: "SELECT * FROM (\(perState)) ORDER BY updated_at ASC LIMIT 1;")
    }

    public func earliestEntry(in state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry? {
        earliestEntry(sql: Self.earliestEntrySQL(forState: state.rawValue) + ";")
    }

    public func containsAny(in states: [UploadBackupSyncQueueState]) -> Bool {
        guard !states.isEmpty else { return false }
        let values = states.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT 1 FROM backup_sync_queue WHERE state IN (\(values)) LIMIT 1;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return true }
            if result != SQLITE_DONE { operationFailed = true }
            return false
        }
    }

    private func claimRunnableUnobserved(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return []
            }
            var selected: [UploadBackupSyncQueueEntry] = []
            var selectStmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state IN (\(Self.runnableStateList))
                          AND updated_at <= ?
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &selectStmt, nil
                    ) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            sqlite3_bind_double(selectStmt, 1, claimedAt.timeIntervalSince1970)
            sqlite3_bind_int(selectStmt, 2, Int32(clampedLimit))
            var selectResult = sqlite3_step(selectStmt)
            while selectResult == SQLITE_ROW {
                guard let source = sourceFromColumns(selectStmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    sqlite3_finalize(selectStmt)
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(selectStmt, 3))
                guard let entry = row(selectStmt, source: source, revision: revision, offset: 4) else {
                    sqlite3_finalize(selectStmt)
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                selected.append(entry)
                selectResult = sqlite3_step(selectStmt)
            }
            sqlite3_finalize(selectStmt)
            guard requireOperational(selectResult == SQLITE_DONE) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }

            guard !selected.isEmpty else {
                guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                return []
            }

            var updateStmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue
                        SET state='checking', updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?
                          AND state IN (\(Self.runnableStateList));
                        """,
                        -1, &updateStmt, nil
                    ) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            defer { sqlite3_finalize(updateStmt) }

            var claimed: [UploadBackupSyncQueueEntry] = []
            for entry in selected {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                sqlite3_bind_double(updateStmt, 1, claimedAt.timeIntervalSince1970)
                bindText(updateStmt, 2, entry.source.kind.rawValue)
                bindText(updateStmt, 3, entry.source.identifier)
                bindText(updateStmt, 4, entry.source.resource.rawValue)
                sqlite3_bind_int64(updateStmt, 5, entry.revision.rawValue)
                guard requireOperational(sqlite3_step(updateStmt) == SQLITE_DONE),
                    requireOperational(sqlite3_changes(db) > 0)
                else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return []
                }
                claimed.append(entry)
            }

            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            return claimed
        }
    }

    /// Streams the rows that keep the backup incomplete, newest revision first, until `body` returns false.
    /// A waiting row counts only when its text is an issue record; an older build's message is no problem.
    /// `body` runs under the store's lock and must not call the store.
    public func forEachProblemEntry(_ body: (UploadBackupSyncQueueEntry) -> Bool) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state IN ('failed', 'failedPermanent', 'sourceMissing', 'blockedByDraft')
                           OR (state IN ('discovered', 'queuedForUpload') AND substr(last_error, 1, ?) = ?)
                        ORDER BY revision_us DESC, updated_at ASC;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(BackupIssueRecord.storagePrefix.count))
            bindText(stmt, 2, BackupIssueRecord.storagePrefix)
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    return
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let entry = row(stmt, source: source, revision: revision, offset: 4) else { return }
                guard body(entry) else { return }
                stepResult = sqlite3_step(stmt)
            }
            _ = requireOperational(stepResult == SQLITE_DONE)
        }
    }

    /// Makes one row due now only while it still has the state and reason the caller saw, so a row that the
    /// runner claimed or changed meanwhile is left alone. Returns whether the row was reopened.
    public func reopenForUserRetry(
        _ entry: UploadBackupSyncQueueEntry, attempts: Int, updatedAt: Date
    ) -> Bool {
        let changed: Int? = lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET state = 'discovered', attempts = ?, updated_at = ?
                        WHERE source_kind = ? AND source_id = ? AND resource = ? AND revision_us = ?
                          AND state = ? AND last_error IS ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(attempts))
            sqlite3_bind_double(stmt, 2, updatedAt.timeIntervalSince1970)
            bindText(stmt, 3, entry.source.kind.rawValue)
            bindText(stmt, 4, entry.source.identifier)
            bindText(stmt, 5, entry.source.resource.rawValue)
            sqlite3_bind_int64(stmt, 6, entry.revision.rawValue)
            bindText(stmt, 7, entry.state.rawValue)
            bindNullableText(stmt, 8, entry.lastError)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
            return Int(sqlite3_changes(db))
        }
        guard let changed else { return false }
        if changed > 0 { notify(UploadBackupSyncQueueChange(sources: [entry.source])) }
        return changed > 0
    }

    public func entries(
        in state: UploadBackupSyncQueueState,
        updatedBefore: Date,
        limit: Int
    ) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                               state, attempts, last_error, updated_at, remote_commit_reconciliation
                        FROM backup_sync_queue
                        WHERE state = ? AND updated_at < ?
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            sqlite3_bind_double(stmt, 2, updatedBefore.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(clamping: clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    operationFailed = true
                    return []
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let entry = row(stmt, source: source, revision: revision, offset: 4) else { return [] }
                entries.append(entry)
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return entries
        }
    }

    @discardableResult
    private func requeueStaleActiveUnobserved(before cutoff: Date, updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state = CASE state
                            WHEN 'checking' THEN CASE
                              WHEN remote_commit_reconciliation IS NOT NULL THEN 'needsRemoteReconciliation'
                              ELSE 'discovered'
                            END
                            WHEN 'hashing' THEN 'discovered'
                            WHEN 'duplicateChecking' THEN 'discovered'
                            WHEN 'uploading' THEN 'queuedForUpload'
                            WHEN 'finalizing' THEN 'queuedForUpload'
                            ELSE state
                          END,
                          updated_at = ?
                        WHERE updated_at < ?
                          AND state IN ('checking', 'hashing', 'duplicateChecking', 'uploading', 'finalizing');
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// Resets every parked `.failed` row back to runnable with a fresh retry budget. Called when
    /// the user explicitly asks to back up again (or re-enables backup), so a manual "back up now"
    /// actually retries the items behind a "needs attention" state instead of being a no-op.
    /// The reason stays, so the photo keeps its place in the problem list until the runner tries it again.
    @discardableResult
    private func requeueFailedUnobserved(updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue
                        SET state = 'discovered', attempts = 0, updated_at = ?
                        WHERE state = 'failed';
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// Atomic manual retry: failed work receives a fresh retry budget, while draft/network-backed-off
    /// work keeps its attempt history but becomes due now. Successful and non-retryable rows never move.
    @discardableResult
    private func makeRetryableWorkEligibleUnobserved(updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state = CASE
                            WHEN state IN ('failed', 'blockedByDraft') THEN 'discovered'
                            ELSE state
                          END,
                          attempts = CASE WHEN state = 'failed' THEN 0 ELSE attempts END,
                          updated_at = ?
                        WHERE state IN (
                          'failed', 'blockedByDraft', 'discovered', 'queuedForUpload',
                          'needsRemoteReconciliation'
                        );
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    @discardableResult
    private func updateStateUnobserved(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state=?,
                          attempts=COALESCE(?, attempts),
                          last_error=?,
                          remote_commit_reconciliation=CASE
                            WHEN ?='needsRemoteReconciliation' THEN remote_commit_reconciliation
                            ELSE NULL
                          END,
                          updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            if let attempts {
                sqlite3_bind_int(stmt, 2, Int32(max(0, attempts)))
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            bindNullableText(stmt, 3, lastError)
            bindText(stmt, 4, state.rawValue)
            sqlite3_bind_double(stmt, 5, updatedAt.timeIntervalSince1970)
            bindText(stmt, 6, source.kind.rawValue)
            bindText(stmt, 7, source.identifier)
            bindText(stmt, 8, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 9, revision.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    private func markNeedsRemoteReconciliationUnobserved(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        reconciliation: UploadRemoteCommitReconciliation,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        guard let payload = try? JSONEncoder().encode(reconciliation) else { return false }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET
                          state='needsRemoteReconciliation',
                          last_error=?,
                          remote_commit_reconciliation=?,
                          updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindNullableText(stmt, 1, lastError)
            _ = payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(bytes.count), transient)
            }
            sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970)
            bindText(stmt, 4, source.kind.rawValue)
            bindText(stmt, 5, source.identifier)
            bindText(stmt, 6, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 7, revision.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    private func removeUnobserved(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        DELETE FROM backup_sync_queue
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    private func removeSettledRevisionsUnobserved(
        of source: UploadSourceIdentity, except revision: UploadBackupRevision
    ) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        DELETE FROM backup_sync_queue
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us<>?
                          AND state IN ('alreadyBackedUp','completed');
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    /// Returns the number of removed rows, or nil when the store failed.
    private func removeUnsavedEarlierRevisionsUnobserved(
        of source: UploadSourceIdentity, through revision: UploadBackupRevision, except kept: UploadBackupRevision
    ) -> Int? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        DELETE FROM backup_sync_queue
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us<=? AND revision_us<>?
                          AND state IN ('skippedRemoteDeletion','failedPermanent','dismissedFailure');
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            sqlite3_bind_int64(stmt, 5, kept.rawValue)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
            return Int(sqlite3_changes(db))
        }
    }

    @discardableResult
    private func removeSourcesUnobserved(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        let identifiers = Array(Set(identifiers))
        guard !identifiers.isEmpty else { return 0 }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "DELETE FROM backup_sync_queue WHERE source_kind=? AND source_id=?;",
                        -1, &stmt, nil
                    ) == SQLITE_OK),
                requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_finalize(stmt)
                return 0
            }
            defer { sqlite3_finalize(stmt) }

            var removed = 0
            for identifier in identifiers {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, kind.rawValue)
                bindText(stmt, 2, identifier)
                guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return 0
                }
                removed += Int(sqlite3_changes(db))
            }
            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return 0
            }
            return removed
        }
    }

    /// Removes folder-backup rows that no longer belong to any registered folder root.
    /// Photo-library rows use a different source kind and are never affected.
    @discardableResult
    private func removeFileSourcesUnobserved(outsideRootPaths rootPaths: [String]) -> Int {
        let roots = Array(
            Set(
                rootPaths.map {
                    URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
                }))
        if roots.contains("/") { return 0 }

        return lock.withLock {
            var sql = "DELETE FROM backup_sync_queue WHERE source_kind=?"
            if !roots.isEmpty {
                let retainedRootClauses = Array(
                    repeating: "(source_id=? OR substr(source_id, 1, length(?)+1)=? || '/')",
                    count: roots.count
                )
                sql += " AND NOT (\(retainedRootClauses.joined(separator: " OR ")))"
            }
            sql += ";"

            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK) else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, UploadSourceIdentity.Kind.fileURL.rawValue)
            var binding: Int32 = 2
            for root in roots {
                bindText(stmt, binding, root)
                bindText(stmt, binding + 1, root)
                bindText(stmt, binding + 2, root)
                binding += 3
            }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    public func summary() -> UploadBackupSyncQueueSummary {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT state, COUNT(*) FROM backup_sync_queue GROUP BY state;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return UploadBackupSyncQueueSummary() }
            defer { sqlite3_finalize(stmt) }
            var summary = UploadBackupSyncQueueSummary()
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let raw = columnText(stmt, 0),
                    let state = UploadBackupSyncQueueState(rawValue: raw)
                else {
                    operationFailed = true
                    return UploadBackupSyncQueueSummary()
                }
                summary.include(state, count: Int(sqlite3_column_int(stmt, 1)))
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return UploadBackupSyncQueueSummary() }
            return summary
        }
    }

    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM backup_sync_queue;", -1, &stmt, nil) == SQLITE_OK
                )
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// State of the one-time catalog replay used only when this queue DB was reset independently of
    /// the durable photo catalog. Stored in the queue DB itself: a reset naturally clears the marker
    /// and requests another rebuild, while ordinary row removal does not.
    public func catalogReplayState() -> UploadBackupCatalogReplayState {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM backup_sync_queue_info WHERE key=?;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return .notStarted }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.catalogReplayStateKey)
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return .notStarted }
            guard requireOperational(result == SQLITE_ROW) else { return .notStarted }
            return UploadBackupCatalogReplayState(rawValue: Int(sqlite3_column_int(stmt, 0))) ?? .notStarted
        }
    }

    @discardableResult
    public func setCatalogReplayState(_ state: UploadBackupCatalogReplayState) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "INSERT INTO backup_sync_queue_info(key, value) VALUES(?, ?) "
                            + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.catalogReplayStateKey)
            sqlite3_bind_int(stmt, 2, Int32(state.rawValue))
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    public func runtimeIssue(for key: BackupRuntimeIssueKey) -> BackupIssueRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM backup_sync_runtime_issue WHERE key=?;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, key.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return BackupIssueRecord.decode(columnText(stmt, 0)) }
            if result != SQLITE_DONE { operationFailed = true }
            return nil
        }
    }

    @discardableResult
    public func setRuntimeIssue(_ issue: BackupIssueRecord?, for key: BackupRuntimeIssueKey) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            if let issue {
                guard
                    requireOperational(
                        sqlite3_prepare_v2(
                            db,
                            "INSERT INTO backup_sync_runtime_issue(key, value) VALUES(?, ?) "
                                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                            -1, &stmt, nil
                        ) == SQLITE_OK)
                else { return false }
                bindText(stmt, 1, key.rawValue)
                bindText(stmt, 2, issue.persistedValue)
            } else {
                guard
                    requireOperational(
                        sqlite3_prepare_v2(
                            db, "DELETE FROM backup_sync_runtime_issue WHERE key=?;", -1, &stmt, nil
                        ) == SQLITE_OK)
                else { return false }
                bindText(stmt, 1, key.rawValue)
            }
            defer { sqlite3_finalize(stmt) }
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    private static let upsertSQL = """
        INSERT INTO backup_sync_queue(
          source_kind, source_id, resource, revision_us, original_filename,
          byte_count, state, attempts, last_error, updated_at, remote_commit_reconciliation
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source_kind, source_id, resource, revision_us) DO UPDATE SET
          original_filename=excluded.original_filename,
          byte_count=excluded.byte_count,
          state=CASE
            WHEN backup_sync_queue.state IN (
              'discovered','queuedForUpload','failed','paused',
              'sourceMissing','blockedByDraft','skippedRemoteDeletion'
            ) THEN excluded.state
            ELSE backup_sync_queue.state
          END,
          attempts=CASE
            WHEN backup_sync_queue.state IN (
              'discovered','queuedForUpload','failed','paused',
              'sourceMissing','blockedByDraft','skippedRemoteDeletion'
            ) THEN excluded.attempts
            ELSE backup_sync_queue.attempts
          END,
          last_error=CASE
            WHEN backup_sync_queue.state IN (
              'discovered','queuedForUpload','failed','paused',
              'sourceMissing','blockedByDraft','skippedRemoteDeletion'
            ) THEN excluded.last_error
            ELSE backup_sync_queue.last_error
          END,
          remote_commit_reconciliation=CASE
            WHEN backup_sync_queue.state='needsRemoteReconciliation'
              THEN backup_sync_queue.remote_commit_reconciliation
            ELSE excluded.remote_commit_reconciliation
          END,
          updated_at=CASE
            WHEN backup_sync_queue.state='needsRemoteReconciliation'
              THEN backup_sync_queue.updated_at
            ELSE excluded.updated_at
          END;
        """

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS backup_sync_queue_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS backup_sync_runtime_issue(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS backup_sync_queue(
              source_kind       TEXT NOT NULL,
              source_id         TEXT NOT NULL,
              resource          TEXT NOT NULL,
              revision_us       INTEGER NOT NULL,
              original_filename TEXT NOT NULL,
              byte_count        INTEGER,
              state             TEXT NOT NULL,
              attempts          INTEGER NOT NULL,
              last_error        TEXT,
              updated_at        REAL NOT NULL,
              remote_commit_reconciliation BLOB,
              PRIMARY KEY(source_kind, source_id, resource, revision_us)
            );
            CREATE INDEX IF NOT EXISTS backup_sync_queue_runnable_idx
              ON backup_sync_queue(state, updated_at);
            CREATE INDEX IF NOT EXISTS backup_sync_queue_priority_idx
              ON backup_sync_queue(state, revision_us DESC);
            CREATE INDEX IF NOT EXISTS backup_sync_queue_source_idx
              ON backup_sync_queue(source_kind, source_id, resource);
            """

        return SQLiteStoreSchemaGate.openCurrentStore(
            at: url,
            schemaSQL: schema,
            policy: policy,
            verifyVersion: verifyVersion,
            stampVersion: stampVersion
        )
    }

    private static func verifyVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "SELECT value FROM backup_sync_queue_info WHERE key='schema';", -1, &stmt, nil)
                == SQLITE_OK
        else {
            return false
        }
        var onDisk: Int?
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        return result == SQLITE_ROW && onDisk == schemaVersion
    }

    private static func stampVersion(_ handle: OpaquePointer?) -> Bool {
        return sqlite3_exec(
            handle,
            "INSERT INTO backup_sync_queue_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    private func bind(_ entry: UploadBackupSyncQueueEntry, to stmt: OpaquePointer?) {
        bindText(stmt, 1, entry.source.kind.rawValue)
        bindText(stmt, 2, entry.source.identifier)
        bindText(stmt, 3, entry.source.resource.rawValue)
        sqlite3_bind_int64(stmt, 4, entry.revision.rawValue)
        bindText(stmt, 5, entry.originalFilename)
        if let byteCount = entry.byteCount {
            sqlite3_bind_int64(stmt, 6, byteCount)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, 7, entry.state.rawValue)
        sqlite3_bind_int(stmt, 8, Int32(entry.attempts))
        bindNullableText(stmt, 9, entry.lastError)
        sqlite3_bind_double(stmt, 10, entry.updatedAt.timeIntervalSince1970)
        if let reconciliation = entry.remoteCommitReconciliation,
            let data = try? JSONEncoder().encode(reconciliation)
        {
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 11, bytes.baseAddress, Int32(bytes.count), transient)
            }
        } else {
            sqlite3_bind_null(stmt, 11)
        }
    }

    private func row(
        _ stmt: OpaquePointer?,
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        offset: Int32 = 0
    ) -> UploadBackupSyncQueueEntry? {
        let reconciliationColumn = offset + 6
        let hasReconciliation = sqlite3_column_type(stmt, reconciliationColumn) != SQLITE_NULL
        let decodedReconciliation = reconciliation(stmt, column: reconciliationColumn)
        guard !hasReconciliation || decodedReconciliation != nil else {
            operationFailed = true
            return nil
        }
        return UploadBackupSyncQueueEntry(
            source: source,
            revision: revision,
            originalFilename: columnText(stmt, offset) ?? "",
            byteCount: sqlite3_column_type(stmt, offset + 1) == SQLITE_NULL
                ? nil : sqlite3_column_int64(stmt, offset + 1),
            state: UploadBackupSyncQueueState(rawValue: columnText(stmt, offset + 2) ?? "") ?? .failed,
            attempts: Int(sqlite3_column_int(stmt, offset + 3)),
            lastError: columnText(stmt, offset + 4),
            remoteCommitReconciliation: decodedReconciliation,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, offset + 5))
        )
    }

    private func sourceFromColumns(
        _ stmt: OpaquePointer?,
        kindColumn: Int32,
        idColumn: Int32,
        resourceColumn: Int32
    ) -> UploadSourceIdentity? {
        guard let kindRaw = columnText(stmt, kindColumn),
            let kind = UploadSourceIdentity.Kind(rawValue: kindRaw),
            let id = columnText(stmt, idColumn),
            let resourceRaw = columnText(stmt, resourceColumn)
        else {
            return nil
        }
        let resource = UploadSourceIdentity.Resource(rawValue: resourceRaw)
        return UploadSourceIdentity(kind: kind, identifier: id, resource: resource)
    }

    private func earliestEntry(sql: String) -> UploadBackupSyncQueueEntry? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK) else { return nil }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            guard result == SQLITE_ROW else {
                if result != SQLITE_DONE { operationFailed = true }
                return nil
            }
            guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                operationFailed = true
                return nil
            }
            return row(
                stmt,
                source: source,
                revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3)),
                offset: 4
            )
        }
    }

    // MARK: - Observed writes

    @discardableResult
    public func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        let result = upsertUnobserved(entry)
        if result { notify(UploadBackupSyncQueueChange(sources: [entry.source])) }
        return result
    }

    @discardableResult
    public func upsertBatch(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        let result = upsertBatchUnobserved(entries)
        if result, !entries.isEmpty { notify(UploadBackupSyncQueueChange(sources: entries.map(\.source))) }
        return result
    }

    public func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        let claimed = claimRunnableUnobserved(limit: limit, claimedAt: claimedAt)
        if !claimed.isEmpty { notify(UploadBackupSyncQueueChange(sources: claimed.map(\.source))) }
        return claimed
    }

    @discardableResult
    public func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        let changed = requeueStaleActiveUnobserved(before: cutoff, updatedAt: updatedAt)
        if changed > 0 { notify(.all) }
        return changed
    }

    @discardableResult
    public func requeueFailed(updatedAt: Date) -> Int {
        let changed = requeueFailedUnobserved(updatedAt: updatedAt)
        if changed > 0 { notify(.all) }
        return changed
    }

    @discardableResult
    public func makeRetryableWorkEligible(updatedAt: Date) -> Int {
        let changed = makeRetryableWorkEligibleUnobserved(updatedAt: updatedAt)
        if changed > 0 { notify(.all) }
        return changed
    }

    @discardableResult
    public func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        let result = updateStateUnobserved(
            source: source,
            revision: revision,
            state: state,
            attempts: attempts,
            lastError: lastError,
            updatedAt: updatedAt
        )
        if result {
            recordSupportEvent(source: source, state: state, lastError: lastError)
            notify(UploadBackupSyncQueueChange(sources: [source]))
        }
        return result
    }

    @discardableResult
    public func markNeedsRemoteReconciliation(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        reconciliation: UploadRemoteCommitReconciliation,
        lastError: String?,
        updatedAt: Date
    ) -> Bool {
        let result = markNeedsRemoteReconciliationUnobserved(
            source: source,
            revision: revision,
            reconciliation: reconciliation,
            lastError: lastError,
            updatedAt: updatedAt
        )
        if result {
            recordSupportEvent(source: source, state: .needsRemoteReconciliation, lastError: lastError)
            notify(UploadBackupSyncQueueChange(sources: [source]))
        }
        return result
    }

    @discardableResult
    public func remove(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        let result = removeUnobserved(source: source, revision: revision)
        if result { notify(UploadBackupSyncQueueChange(sources: [source])) }
        return result
    }

    @discardableResult
    public func removeUnsavedEarlierRevisions(
        of source: UploadSourceIdentity, through revision: UploadBackupRevision, except kept: UploadBackupRevision
    ) -> Bool {
        guard let removed = removeUnsavedEarlierRevisionsUnobserved(of: source, through: revision, except: kept)
        else { return false }
        // Most backups remove nothing; only a real change reaches the observers.
        if removed > 0 { notify(UploadBackupSyncQueueChange(sources: [source])) }
        return true
    }

    @discardableResult
    public func removeSettledRevisions(
        of source: UploadSourceIdentity, except revision: UploadBackupRevision
    ) -> Bool {
        let result = removeSettledRevisionsUnobserved(of: source, except: revision)
        if result { notify(UploadBackupSyncQueueChange(sources: [source])) }
        return result
    }

    @discardableResult
    public func removeSources(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        let removed = removeSourcesUnobserved(kind: kind, identifiers: identifiers)
        if removed > 0 { notify(.sources([kind: Set(identifiers)])) }
        return removed
    }

    @discardableResult
    public func removeFileSources(outsideRootPaths rootPaths: [String]) -> Int {
        let removed = removeFileSourcesUnobserved(outsideRootPaths: rootPaths)
        if removed > 0 { notify(.all) }
        return removed
    }

    private func notify(_ change: UploadBackupSyncQueueChange) {
        let observer = observerLock.withLock { changeObserver }
        observer?(change)
    }

    private let transient = SQLiteStoreSchemaGate.transientDestructor

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindNullableText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
            let text = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: text)
    }

    private func reconciliation(
        _ stmt: OpaquePointer?,
        column: Int32
    ) -> UploadRemoteCommitReconciliation? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
            let bytes = sqlite3_column_blob(stmt, column)
        else {
            return nil
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
        return try? JSONDecoder().decode(UploadRemoteCommitReconciliation.self, from: data)
    }

    private func strictReconciliation(
        _ stmt: OpaquePointer?,
        column: Int32
    ) -> UploadRemoteCommitReconciliation? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
            let bytes = sqlite3_column_blob(stmt, column)
        else {
            return nil
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
        return try? JSONDecoder().decode(UploadRemoteCommitReconciliation.self, from: data)
    }

    @discardableResult
    private func requireOperational(_ condition: Bool) -> Bool {
        if !condition { operationFailed = true }
        return condition
    }
}

extension UploadBackupSyncQueueManifestStore: UploadBackupSyncQueueObserving {
    public func setChangeObserver(_ observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?) {
        observerLock.withLock { changeObserver = observer }
    }

    public func unsettledRows() -> [UploadBackupQueueRowState] {
        rowStates(
            where: """
                state NOT IN ('alreadyBackedUp', 'completed', 'skippedRemoteDeletion', 'sourceMissing',
                              'dismissedFailure')
                """,
            bindings: [nil]
        )
    }

    /// Rows that upload now or wait their turn. A waiting row with an issue record belongs to the problem list
    /// (`forEachProblemEntry`), so the queue list leaves it out.
    public func queueWorkRows() -> [UploadBackupQueueRowState] {
        rowStates(
            where: """
                state IN ('checking', 'hashing', 'duplicateChecking', 'uploading', 'finalizing',
                          'needsRemoteReconciliation', 'discovered', 'queuedForUpload', 'paused')
                  AND (state NOT IN ('discovered', 'queuedForUpload') OR last_error IS NULL
                       OR substr(last_error, 1, ?) != ?)
                """,
            bindings: [
                { (stmt: OpaquePointer?) in
                    sqlite3_bind_int64(stmt, 1, Int64(BackupIssueRecord.storagePrefix.count))
                    self.bindText(stmt, 2, BackupIssueRecord.storagePrefix)
                }
            ]
        )
    }

    public func rows(kind: UploadSourceIdentity.Kind, identifiers: Set<String>) -> [UploadBackupQueueRowState] {
        guard !identifiers.isEmpty else { return [] }
        return rowStates(
            where: "source_kind=? AND source_id=?",
            bindings: identifiers.map { identifier in
                { stmt in
                    self.bindText(stmt, 1, kind.rawValue)
                    self.bindText(stmt, 2, identifier)
                }
            }
        )
    }

    /// Cosmetic admission read: failure must not change the queue's operational health.
    public func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT source_id, MAX(revision_us) FROM backup_sync_queue
                    WHERE source_kind=? AND state IN ('alreadyBackedUp', 'completed')
                      AND source_id IN (
                        SELECT source_id FROM backup_sync_queue WHERE source_kind=? AND state='queuedForUpload'
                      )
                    GROUP BY source_id;
                    """,
                    -1, &stmt, nil) == SQLITE_OK
            else { return [:] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, kind.rawValue)
            bindText(stmt, 2, kind.rawValue)
            var result: [String: UploadBackupRevision] = [:]
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                if let identifier = columnText(stmt, 0) {
                    result[identifier] = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 1))
                }
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { return [:] }
            return result
        }
    }

    /// Runs one prepared query once for each set of bindings, so a batch of sources costs one prepare.
    private func rowStates(
        where condition: String,
        bindings: [((OpaquePointer?) -> Void)?]
    ) -> [UploadBackupQueueRowState] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, state, original_filename, updated_at
                        FROM backup_sync_queue WHERE \(condition);
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [UploadBackupQueueRowState] = []
            for bind in bindings {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind?(stmt)
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    if let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2),
                        let state = columnText(stmt, 4).flatMap(UploadBackupSyncQueueState.init(rawValue:))
                    {
                        result.append(
                            UploadBackupQueueRowState(
                                source: source,
                                revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3)),
                                state: state,
                                originalFilename: columnText(stmt, 5) ?? "",
                                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                            ))
                    } else {
                        operationFailed = true
                    }
                    step = sqlite3_step(stmt)
                }
                if step != SQLITE_DONE { operationFailed = true }
            }
            return result
        }
    }
}

extension UploadBackupSyncQueueManifestStore: BackupQueueSupportSource {
    /// Group only local scalar columns. No source, filename, receipt, or backend detail can leave this method.
    public func backupSupportSnapshot() -> BackupQueueSupportSnapshot {
        lock.withLock {
            guard db != nil, !operationFailed else { return BackupQueueSupportSnapshot() }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "SELECT state, resource, last_error, COUNT(*) FROM backup_sync_queue GROUP BY state, resource, last_error;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return BackupQueueSupportSnapshot() }
            defer { sqlite3_finalize(stmt) }
            var states: [BackupQueueSupportSnapshot.State: Int] = [:]
            var resources: [BackupQueueSupportSnapshot.ResourceKind: Int] = [:]
            var waiting: [BackupQueueSupportSnapshot.Reason: Int] = [:]
            var parked: [BackupQueueSupportSnapshot.Reason: Int] = [:]
            var total = 0
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                let state = BackupQueueSupportSnapshot.State(rawValue: columnText(stmt, 0) ?? "") ?? .unknown
                let resource = Self.supportResourceKind(columnText(stmt, 1) ?? "")
                let reason = Self.supportReason(columnText(stmt, 2))
                let count = Int(sqlite3_column_int64(stmt, 3))
                total += count
                states[state, default: 0] += count
                resources[resource, default: 0] += count
                switch state {
                case .discovered, .queuedForUpload, .needsRemoteReconciliation, .failed:
                    waiting[reason, default: 0] += count
                case .blockedByDraft, .failedPermanent, .paused, .sourceMissing, .dismissedFailure:
                    parked[reason, default: 0] += count
                default:
                    break
                }
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { return BackupQueueSupportSnapshot() }
            var result = BackupQueueSupportSnapshot()
            result.isAvailable = true
            result.total = total
            result.countsByState = BackupQueueSupportSnapshot.State.allCases.map {
                .init(state: $0, count: states[$0, default: 0])
            }
            result.countsByResourceKind = BackupQueueSupportSnapshot.ResourceKind.allCases.map {
                .init(resourceKind: $0, count: resources[$0, default: 0])
            }
            result.waitingByReason = BackupQueueSupportSnapshot.Reason.allCases.map {
                .init(reason: $0, count: waiting[$0, default: 0])
            }
            result.parkedByReason = BackupQueueSupportSnapshot.Reason.allCases.map {
                .init(reason: $0, count: parked[$0, default: 0])
            }
            return result
        }
    }

    /// Only the issue kind of a stored error leaves the device, never its text.
    private static func supportReason(_ error: String?) -> BackupQueueSupportSnapshot.Reason {
        if let issue = BackupIssueRecord.decode(error) {
            return BackupQueueSupportSnapshot.Reason(rawValue: issue.kind.rawValue) ?? .unknown
        }
        return (error?.isEmpty ?? true) ? .none : .unclassified
    }

    /// Transitions that end, pause, or retry a row. Steady progress (checking, hashing, uploading) is left out,
    /// so the bounded trail keeps the events that explain a stuck or failed photo.
    private func recordSupportEvent(
        source: UploadSourceIdentity, state: UploadBackupSyncQueueState, lastError: String?
    ) {
        let kind: SupportEventTrail.Kind
        switch state {
        case .completed: kind = .backupRowCompleted
        case .alreadyBackedUp: kind = .backupRowAlreadyBackedUp
        case .skippedRemoteDeletion: kind = .backupRowSkipped
        case .needsRemoteReconciliation: kind = .backupRowNeedsReconciliation
        case .failed: kind = .backupRowWaiting
        case .discovered, .queuedForUpload:
            guard lastError?.isEmpty == false else { return }
            kind = .backupRowWaiting
        case .blockedByDraft, .failedPermanent, .paused, .sourceMissing, .dismissedFailure: kind = .backupRowParked
        default: return
        }
        supportTrail.record(
            kind, subject: source.identifier, resourceKind: Self.supportResourceKind(source.resource.rawValue),
            reason: Self.supportReason(lastError))
    }

    private static func supportResourceKind(_ raw: String) -> BackupQueueSupportSnapshot.ResourceKind {
        if raw == UploadSourceIdentity.Resource.primary.rawValue { return .primary }
        if raw == UploadSourceIdentity.Resource.livePairedVideo.rawValue { return .livePairedVideo }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "photoKit", !parts[2].isEmpty,
            parts[2].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let role = BackupQueueSupportSnapshot.ResourceKind(rawValue: String(parts[1])),
            role != .primary, role != .livePairedVideo
        else { return .other }
        return role
    }
}
