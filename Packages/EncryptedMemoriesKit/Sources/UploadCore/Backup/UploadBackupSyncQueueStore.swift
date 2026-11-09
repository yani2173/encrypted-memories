import Foundation
import PhotosCore
import SQLite3

/// Persistent sync work queue (`upload-backup-sync-queue-v1.sqlite`). The queue stores source
/// identities and revisions, not temporary export URLs; platform adapters rematerialize resources
/// when work resumes after a launch, background wake, or extension invocation.
public final class UploadBackupSyncQueueManifestStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
        enum ProblemReadEvent { case healthProbe, willLock, didLock, statement, step, row, didUnlock }
        var onProblemReadEvent: ((ProblemReadEvent) -> Void)?
    #endif
    public static let databaseFileName = "upload-backup-sync-queue-v1.sqlite"

    private static let schemaVersion = 2
    private static let schemaVersionRow = SQLiteInfoTableVersion(
        table: "backup_sync_queue_info", version: schemaVersion, stampReplacesExistingRow: true)
    private static let catalogReplayStateKey = "catalog_replay_state"
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }
    private let observerLock = NSLock()
    private let legacyObserverID = UUID()
    private var changeObservers: [UUID: @Sendable (UploadBackupSyncQueueChange) -> Void] = [:]
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
        // An automatic checkpoint can copy frames before `synchronizeToDisk()` runs; they need the same sync.
        SQLiteStoreSchemaGate.enableFullSyncCheckpoints(handle)
        connection = SQLiteStoreConnection(database: handle)
        SupportDiagnosticsSources.shared.registerQueue(self, key: url.standardizedFileURL.path)
    }

    deinit { close() }

    /// A transient failure stops the store only until the database answers again. Every decision reads strictly, so a
    /// forgotten failure never turns a failed read into a decision. One display read can still answer later than it
    /// should: `earliestRunnableEntry()` answers nil on failure, and the status then shows the next draft re-check as
    /// the next attempt, so the automatic retry can wait longer than usual (#1004).
    public func isOperational() -> Bool {
        #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
            onProblemReadEvent?(.healthProbe)
        #endif
        return connection.isOperationalAfterTransientFailure()
    }

    public func recordedFailureCount() -> UInt64 { connection.recordedFailureCount() }

    /// Starts a read under `connection.withLock`. A complete read refuses an open transaction or a lasting failure.
    private func beginReadLocked(requireComplete: Bool) throws {
        if requireComplete, !readerMayProceedLocked() { throw SQLiteStoreUnknownReadError() }
    }

    /// The answer of a read that could not run: a complete read throws, a legacy read gives `fallback` (#1004).
    private func unknownRead<T>(requireComplete: Bool, _ fallback: T) throws -> T {
        if requireComplete { throw SQLiteStoreUnknownReadError() }
        return fallback
    }

    /// Complete decision reads refuse an open transaction or a lasting failure. Call under `connection.withLock`.
    private func readerMayProceedLocked() -> Bool {
        guard let db else { return false }
        guard sqlite3_get_autocommit(db) != 0 else { return false }
        guard !connection.operationFailed || connection.failuresAreTransient else { return false }
        return true
    }

    /// Records a predicate under `withLock`, with the extended code of the failed SQLite call. A busy, locked, full,
    /// interrupted, out-of-memory or I/O failure stops the store until `isOperational()` finds the database answering
    /// again. Any other failure, and an I/O failure that reports damaged data (SQLITE_IOERR_DATA,
    /// SQLITE_IOERR_CORRUPTFS), stops it until the store is opened again.
    @discardableResult
    private func requireOperational(_ condition: Bool) -> Bool {
        connection.requireOperationalRecordingSQLiteError(condition)
    }

    /// Marks the store failed only when no failure was recorded yet. A `withDurableCommits` body that failed already
    /// recorded its own extended code; a second mark with a stale code could turn a transient failure into a lasting
    /// one (#1004).
    private func markFailedOnceUnrecorded() {
        if !connection.operationFailed {
            connection.markFailed(resultCode: db.map { sqlite3_extended_errcode($0) })
        }
    }

    /// Runs `body` with durable commits. When the setup cannot raise durability, the body never runs and the setup's
    /// own code is recorded, also after an earlier failure: a lasting PRAGMA refusal must not hide behind an earlier
    /// transient one. A body that ran records its own failures (#1004, row 9).
    private func withDurableCommitsRecordingSetup<T>(_ body: () -> T) -> T? {
        var bodyRan = false
        let result = SQLiteStoreSchemaGate.withDurableCommits(db) { () -> T in
            bodyRan = true
            return body()
        }
        if !bodyRan { markFailedWithFreshStepCode() }
        return result
    }

    /// Marks the store failed with the failed step's own extended code, replacing any earlier recorded failure. The
    /// caller invokes it right after a failed `sqlite3_step`, so the code is fresh. A lasting code must survive even
    /// when a transient failure was recorded earlier and no health check ran in between (#1004).
    private func markFailedWithFreshStepCode() {
        connection.markFailed(resultCode: db.map { sqlite3_extended_errcode($0) })
    }

    /// A full checkpoint moves every committed transaction from the WAL into the database file and syncs that file;
    /// `checkpoint_fullfsync`, set when the store opens, makes the sync an `F_FULLFSYNC`. A busy or partial checkpoint
    /// returns false.
    public func synchronizeToDisk() -> Bool {
        connection.withLock {
            SQLiteStoreSchemaGate.synchronizeToDisk(db, operationFailed: connection.operationFailed)
        }
    }

    public func close() { connection.close() }

    /// A new queue row survives a power loss once its commit returns. A catalog row written after it marks the photo
    /// as seen, so a lost queue row would leave the photo out of the backup (#352).
    /// Classifies new work inside the same transaction that commits the upserts. An offered runnable state alone
    /// is not an enqueue: an advanced row can keep its state, and an unchanged waiting row adds no work.
    private func upsertBatchUnobserved(_ entries: [UploadBackupSyncQueueEntry]) -> UploadBackupSyncQueueChange? {
        connection.withLock {
            let change =
                withDurableCommitsRecordingSetup { () -> UploadBackupSyncQueueChange? in
                    var write: OpaquePointer?
                    var prior: OpaquePointer?
                    guard
                        requireOperational(
                            sqlite3_prepare_v2(db, Self.upsertSQL, -1, &write, nil) == SQLITE_OK),
                        requireOperational(
                            sqlite3_prepare_v2(
                                db,
                                """
                                SELECT state IN (\(Self.runnableStateList)), updated_at,
                                       state IN (\(Self.upsertReplaceableStateList)), state, last_error
                                FROM backup_sync_queue
                                WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                                """, -1, &prior, nil) == SQLITE_OK),
                        requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
                    else {
                        sqlite3_finalize(write)
                        sqlite3_finalize(prior)
                        return nil
                    }
                    defer {
                        sqlite3_finalize(write)
                        sqlite3_finalize(prior)
                    }

                    var enqueued = false
                    var didPersist = true
                    for entry in entries {
                        sqlite3_reset(prior)
                        sqlite3_clear_bindings(prior)
                        // A failed bind is recorded on the connection; the batch rolls back (#1194).
                        guard (try? bindSource(entry.source, to: prior, from: 1)) != nil else {
                            didPersist = false
                            break
                        }
                        sqlite3_bind_int64(prior, 4, entry.revision.rawValue)
                        let result = sqlite3_step(prior)
                        if result == SQLITE_ROW {
                            let priorState = columnText(prior, 3).flatMap(UploadBackupSyncQueueState.init(rawValue:))
                            if let priorState,
                                UploadBackupSyncQueueEntry.isDismissedSourceRecheck(
                                    sourceKind: entry.source.kind, state: priorState, lastError: columnText(prior, 4))
                            {
                                sqlite3_reset(prior)
                                continue
                            }
                            if Self.runnableStates.contains(entry.state.rawValue) {
                                let wasRunnable = sqlite3_column_int(prior, 0) != 0
                                let wasReplaceable = sqlite3_column_int(prior, 2) != 0
                                let becomesEarlier =
                                    entry.updatedAt.timeIntervalSince1970 < sqlite3_column_double(prior, 1)
                                enqueued = enqueued || (wasReplaceable && (!wasRunnable || becomesEarlier))
                            }
                        } else if result == SQLITE_DONE {
                            enqueued = enqueued || Self.runnableStates.contains(entry.state.rawValue)
                        } else {
                            // The step just failed, so its extended code is fresh. Record it even when an earlier
                            // transient failure is already recorded: a lasting code must not be dropped by it (#1004).
                            markFailedWithFreshStepCode()
                            didPersist = false
                            break
                        }
                        sqlite3_reset(prior)
                        sqlite3_reset(write)
                        sqlite3_clear_bindings(write)
                        guard (try? bind(entry, to: write)) != nil,
                            requireOperational(sqlite3_step(write) == SQLITE_DONE)
                        else {
                            didPersist = false
                            break
                        }
                    }
                    guard didPersist,
                        requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
                    else {
                        connection.rollBack()
                        return nil
                    }
                    return UploadBackupSyncQueueChange(sources: entries.map(\.source), enqueued: enqueued)
                } ?? nil
            if change == nil { markFailedOnceUnrecorded() }
            return change
        }
    }

    /// Reads one row. Closed stores, failed binds, failed statements and a row that does not decode throw
    /// `SQLiteStoreUnknownReadError` (#1004). A lasting failure with successful SQL still answers the row, as
    /// `testQueueDecodeFailureStaysStickyAfterSuccessfulSQLAndRefusesDurability` pins.
    public func entry(
        for source: UploadSourceIdentity, revision: UploadBackupRevision
    ) throws -> UploadBackupSyncQueueEntry? {
        try connection.withLock {
            guard let db else { throw SQLiteStoreUnknownReadError() }
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
            else { throw SQLiteStoreUnknownReadError() }
            defer { sqlite3_finalize(stmt) }
            try bindSource(source, to: stmt, from: 1)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                // A row whose stored receipt does not decode is unknown, never an absent row (#1004 B2).
                guard let entry = row(stmt, source: source, revision: revision) else {
                    throw SQLiteStoreUnknownReadError()
                }
                return entry
            }
            if result != SQLITE_DONE {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                throw SQLiteStoreUnknownReadError()
            }
            return nil
        }
    }

    public func entriesWithRemoteCommitReconciliation(limit: Int) throws -> [UploadBackupSyncQueueEntry] {
        try connection.withLock {
            guard db != nil, !connection.operationFailed else {
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
                    connection.markFailed()
                    throw UploadRemoteCommitRecoveryError.storeUnavailable
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let reconciliation = reconciliation(stmt, column: 10) else {
                    connection.markFailed()
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

    public func nextRunnableDate(excludingSourcesOf excludedSources: [UploadSourceIdentity]) -> Date? {
        (try? runnableDate(excludingSourcesOf: excludedSources, requireComplete: false)) ?? nil
    }

    private func runnableDate(
        excludingSourcesOf excludedSources: [UploadSourceIdentity], requireComplete: Bool
    ) throws -> Date? {
        let exclusion = SourceExclusion(excludedSources)
        return try connection.withLock {
            try beginReadLocked(requireComplete: requireComplete)
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT MIN(updated_at) FROM backup_sync_queue "
                            + "WHERE state IN (\(Self.runnableStateList))\(exclusion.clause);",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return try unknownRead(requireComplete: requireComplete, nil) }
            defer { sqlite3_finalize(stmt) }
            _ = try bind(exclusion, to: stmt, from: 1)
            let result = sqlite3_step(stmt)
            guard requireOperational(result == SQLITE_ROW) else {
                return try unknownRead(requireComplete: requireComplete, nil)
            }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
                return nil
            }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    /// Internal, not private: test reads of the runnable rows use this same list.
    static let runnableStates: [String] = ["discovered", "queuedForUpload", "needsRemoteReconciliation"]
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
        return
            (try? earliestEntry(
                sql: "SELECT * FROM (\(perState)) ORDER BY updated_at ASC LIMIT 1;", requireComplete: false)) ?? nil
    }

    public func earliestEntry(in state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry? {
        (try? earliestEntry(sql: Self.earliestEntrySQL(forState: state.rawValue) + ";", requireComplete: false)) ?? nil
    }

    /// True when any row carries one of `states`. False is a real answer only after a successful read; a read that
    /// could not run throws `SQLiteStoreUnknownReadError`, because the recovering health probe cannot recheck a false
    /// afterwards (#1004). The answer gates scans and "queue drained" claims.
    public func containsAny(in states: [UploadBackupSyncQueueState]) throws -> Bool {
        guard !states.isEmpty else { return false }
        let values = states.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return try connection.withLock {
            guard let db else { throw SQLiteStoreUnknownReadError() }
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT 1 FROM backup_sync_queue WHERE state IN (\(values)) LIMIT 1;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { throw SQLiteStoreUnknownReadError() }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return true }
            if result != SQLITE_DONE {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                throw SQLiteStoreUnknownReadError()
            }
            return false
        }
    }

    private func claimRunnableUnobserved(
        limit: Int, claimedAt: Date, excludedSources: [UploadSourceIdentity]
    ) -> [UploadBackupSyncQueueEntry]? {
        let clampedLimit = max(1, limit)
        let exclusion = SourceExclusion(excludedSources)
        return connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return nil
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
                          AND updated_at <= ?\(exclusion.clause)
                        ORDER BY revision_us DESC, updated_at ASC
                        LIMIT ?;
                        """,
                        -1, &selectStmt, nil
                    ) == SQLITE_OK)
            else {
                connection.rollBack()
                return nil
            }
            sqlite3_bind_double(selectStmt, 1, claimedAt.timeIntervalSince1970)
            // An exclusion that does not bind must not hide every row of its kind (#1194).
            guard let limitParameter = try? bind(exclusion, to: selectStmt, from: 2) else {
                sqlite3_finalize(selectStmt)
                connection.rollBack()
                return nil
            }
            sqlite3_bind_int(selectStmt, limitParameter, Int32(clamping: clampedLimit))
            var selectResult = sqlite3_step(selectStmt)
            while selectResult == SQLITE_ROW {
                guard let source = sourceFromColumns(selectStmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    connection.markFailed()
                    sqlite3_finalize(selectStmt)
                    connection.rollBack()
                    return nil
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(selectStmt, 3))
                guard let entry = row(selectStmt, source: source, revision: revision, offset: 4) else {
                    sqlite3_finalize(selectStmt)
                    connection.rollBack()
                    return nil
                }
                selected.append(entry)
                selectResult = sqlite3_step(selectStmt)
            }
            sqlite3_finalize(selectStmt)
            guard requireOperational(selectResult == SQLITE_DONE) else {
                connection.rollBack()
                return nil
            }

            guard !selected.isEmpty else {
                guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                    connection.rollBack()
                    return nil
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
                connection.rollBack()
                return nil
            }
            defer { sqlite3_finalize(updateStmt) }

            var claimed: [UploadBackupSyncQueueEntry] = []
            for entry in selected {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                sqlite3_bind_double(updateStmt, 1, claimedAt.timeIntervalSince1970)
                guard (try? bindSource(entry.source, to: updateStmt, from: 2)) != nil else {
                    connection.rollBack()
                    return nil
                }
                sqlite3_bind_int64(updateStmt, 5, entry.revision.rawValue)
                guard requireOperational(sqlite3_step(updateStmt) == SQLITE_DONE),
                    requireOperational(sqlite3_changes(db) > 0)
                else {
                    connection.rollBack()
                    return nil
                }
                claimed.append(entry)
            }

            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                connection.rollBack()
                return nil
            }
            return claimed
        }
    }

    /// Streams the rows that keep the backup incomplete, newest revision first, until `body` returns false.
    /// A waiting row counts only when its text is an issue record; an older build's message is no problem.
    /// `body` runs under the store's lock and must not call the store.
    public func forEachProblemEntry(_ body: (UploadBackupSyncQueueEntry) -> Bool) {
        try? problemEntries(body, requireComplete: false)
    }

    private func problemEntries(_ body: (UploadBackupSyncQueueEntry) -> Bool, requireComplete: Bool) throws {
        #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
            onProblemReadEvent?(.willLock)
            defer { onProblemReadEvent?(.didUnlock) }
        #endif
        try connection.withLock {
            try beginReadLocked(requireComplete: requireComplete)
            #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                onProblemReadEvent?(.didLock)
                onProblemReadEvent?(.statement)
            #endif
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
            else { return try unknownRead(requireComplete: requireComplete, ()) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(BackupIssueRecord.storagePrefix.count))
            try connection.bindText(stmt, 2, BackupIssueRecord.storagePrefix)
            #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                onProblemReadEvent?(.step)
            #endif
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                    onProblemReadEvent?(.row)
                #endif
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    connection.markFailed()
                    return try unknownRead(requireComplete: requireComplete, ())
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let entry = row(stmt, source: source, revision: revision, offset: 4) else {
                    return try unknownRead(requireComplete: requireComplete, ())
                }
                if !entry.isDismissedSourceRecheck, !body(entry) { return }
                #if DEBUG || ENCRYPTED_MEMORIES_PROBLEM_LIST_BENCHMARK
                    onProblemReadEvent?(.step)
                #endif
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else {
                return try unknownRead(requireComplete: requireComplete, ())
            }
        }
    }

    public func updateDismissedSourceRecheck(
        _ entry: UploadBackupSyncQueueEntry, matchingState: UploadBackupSyncQueueState, matchingLastError: String
    ) -> Bool? {
        let changed: Int? = connection.withLock {
            let changed =
                withDurableCommitsRecordingSetup { () -> Int? in
                    var stmt: OpaquePointer?
                    guard
                        requireOperational(
                            sqlite3_prepare_v2(
                                db,
                                """
                                UPDATE backup_sync_queue
                                SET original_filename=?, byte_count=?, state=?, attempts=?, last_error=?, updated_at=?
                                WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?
                                  AND state=? AND last_error=? AND remote_commit_reconciliation IS NULL;
                                """, -1, &stmt, nil) == SQLITE_OK)
                    else { return nil }
                    defer { sqlite3_finalize(stmt) }
                    do {
                        try connection.bindText(stmt, 1, entry.originalFilename)
                        if let byteCount = entry.byteCount {
                            sqlite3_bind_int64(stmt, 2, byteCount)
                        } else {
                            sqlite3_bind_null(stmt, 2)
                        }
                        try connection.bindText(stmt, 3, entry.state.rawValue)
                        sqlite3_bind_int(stmt, 4, Int32(clamping: entry.attempts))
                        try connection.bindText(stmt, 5, entry.lastError)
                        sqlite3_bind_double(stmt, 6, entry.updatedAt.timeIntervalSince1970)
                        try bindSource(entry.source, to: stmt, from: 7)
                        sqlite3_bind_int64(stmt, 10, entry.revision.rawValue)
                        try connection.bindText(stmt, 11, matchingState.rawValue)
                        try connection.bindText(stmt, 12, matchingLastError)
                    } catch {
                        return nil
                    }
                    guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
                    return Int(sqlite3_changes(db))
                } ?? nil
            if changed == nil { markFailedOnceUnrecorded() }
            return changed
        }
        guard let changed else { return nil }
        if changed > 0 {
            notify(
                UploadBackupSyncQueueChange(
                    sources: [entry.source], enqueued: Self.runnableStates.contains(entry.state.rawValue)))
        }
        return changed > 0
    }

    /// Makes one row due now only while it still has the state and reason the caller saw, so a row that the
    /// runner claimed or changed meanwhile is left alone. Returns whether the row was reopened.
    public func reopenForUserRetry(
        _ entry: UploadBackupSyncQueueEntry, attempts: Int, updatedAt: Date
    ) -> Bool {
        let changed: Int? = connection.withLock {
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
            do {
                try bindSource(entry.source, to: stmt, from: 3)
                sqlite3_bind_int64(stmt, 6, entry.revision.rawValue)
                try connection.bindText(stmt, 7, entry.state.rawValue)
                try connection.bindText(stmt, 8, entry.lastError)
            } catch {
                return nil
            }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
            return Int(sqlite3_changes(db))
        }
        guard let changed else { return false }
        if changed > 0 { notify(UploadBackupSyncQueueChange(sources: [entry.source])) }
        return changed > 0
    }

    public var restoredCompoundReopener: (@Sendable (UploadBackupSyncQueueEntry, Date) -> Bool?)? {
        { [self] observed, date in reopenRestoredCompound(observed, at: date) }
    }

    /// Reopens exactly the terminal row that the restore recheck saw. A receipt or a newer revision owns its work.
    public func reopenRestoredCompound(_ observed: UploadBackupSyncQueueEntry, at date: Date) -> Bool? {
        let changed: Int? = connection.withLock {
            guard observed.state.isTerminalSuccess, observed.remoteCommitReconciliation == nil else { return 0 }
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE backup_sync_queue SET state='discovered', attempts=0, last_error=NULL, updated_at=?
                        WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=? AND state=?
                          AND updated_at=? AND last_error IS ? AND remote_commit_reconciliation IS NULL
                          AND NOT EXISTS (SELECT 1 FROM backup_sync_queue q
                            WHERE q.source_kind=backup_sync_queue.source_kind AND q.source_id=backup_sync_queue.source_id
                              AND q.revision_us>backup_sync_queue.revision_us);
                        """, -1, &stmt, nil) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            do {
                try bindSource(observed.source, to: stmt, from: 2)
                sqlite3_bind_int64(stmt, 5, observed.revision.rawValue)
                try connection.bindText(stmt, 6, observed.state.rawValue)
                sqlite3_bind_double(stmt, 7, observed.updatedAt.timeIntervalSince1970)
                try connection.bindText(stmt, 8, observed.lastError)
            } catch {
                return nil
            }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
            return Int(sqlite3_changes(db))
        }
        guard let changed else { return nil }
        if changed > 0 { notify(UploadBackupSyncQueueChange(sources: [observed.source], enqueued: true)) }
        return changed > 0
    }

    public func entries(
        in state: UploadBackupSyncQueueState,
        updatedBefore: Date,
        limit: Int
    ) -> [UploadBackupSyncQueueEntry] {
        (try? entries(in: state, updatedBefore: updatedBefore, limit: limit, requireComplete: false)) ?? []
    }

    private func entries(
        in state: UploadBackupSyncQueueState,
        updatedBefore: Date,
        limit: Int,
        requireComplete: Bool
    ) throws -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return try connection.withLock {
            try beginReadLocked(requireComplete: requireComplete)
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
            else { return try unknownRead(requireComplete: requireComplete, []) }
            defer { sqlite3_finalize(stmt) }
            try connection.bindText(stmt, 1, state.rawValue)
            sqlite3_bind_double(stmt, 2, updatedBefore.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(clamping: clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                    connection.markFailed()
                    return try unknownRead(requireComplete: requireComplete, [])
                }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                guard let entry = row(stmt, source: source, revision: revision, offset: 4) else {
                    return try unknownRead(requireComplete: requireComplete, [])
                }
                entries.append(entry)
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else {
                return try unknownRead(requireComplete: requireComplete, [])
            }
            return entries
        }
    }

    @discardableResult
    private func requeueStaleActiveUnobserved(before cutoff: Date, updatedAt: Date) -> Int? {
        connection.withLock {
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
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
            return Int(sqlite3_changes(db))
        }
    }

    /// Resets every parked `.failed` row back to runnable with a fresh retry budget. Called when
    /// the user explicitly asks to back up again (or re-enables backup), so a manual "back up now"
    /// actually retries the items behind a "needs attention" state instead of being a no-op.
    /// The reason stays, so the photo keeps its place in the problem list until the runner tries it again.
    @discardableResult
    private func requeueFailedUnobserved(updatedAt: Date) -> Int {
        connection.withLock {
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
        connection.withLock {
            let changed =
                withDurableCommitsRecordingSetup { () -> Int? in
                    guard
                        requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
                    else {
                        return nil
                    }
                    var committed = false
                    defer { if !committed { connection.rollBack() } }
                    guard let markers = dismissedSourceRecheckRowIDsLocked() else { return nil }
                    let exclusion =
                        markers.isEmpty ? "" : "AND rowid NOT IN (\(markers.map(String.init).joined(separator: ",")))"
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
                                ) \(exclusion);
                                """, -1, &stmt, nil) == SQLITE_OK)
                    else { return nil }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
                    guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return nil }
                    let count = Int(sqlite3_changes(db))
                    guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                        return nil
                    }
                    committed = true
                    return count
                } ?? nil
            if changed == nil { markFailedOnceUnrecorded() }
            return changed ?? 0
        }
    }

    /// Decode the existing reason under the caller's write transaction. Raw discovered/checking states also
    /// contain real pending uploads, so SQL cannot identify acknowledged-source checks from state alone.
    private func dismissedSourceRecheckRowIDsLocked(
        matching scope: String = "1", bindScope: (OpaquePointer?) throws -> Void = { _ in }
    ) -> [Int64]? {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT rowid, state, last_error FROM backup_sync_queue
                    WHERE source_kind='photoLibraryAsset' AND state IN ('discovered','checking')
                      AND last_error IS NOT NULL AND (\(scope));
                    """, -1, &stmt, nil) == SQLITE_OK)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard (try? bindScope(stmt)) != nil else { return nil }
        var result: [Int64] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return result }
            guard requireOperational(step == SQLITE_ROW) else { return nil }
            guard let state = columnText(stmt, 1).flatMap(UploadBackupSyncQueueState.init(rawValue:)) else {
                // The step delivered a row that the reader cannot decode. The step succeeded, so its result code
                // says nothing about the cause; an undecodable row is a lasting failure (#1004).
                connection.markFailed()
                return nil
            }
            if UploadBackupSyncQueueEntry.isDismissedSourceRecheck(
                sourceKind: .photoLibraryAsset, state: state, lastError: columnText(stmt, 2))
            {
                result.append(sqlite3_column_int64(stmt, 0))
            }
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
        connection.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.updateStateSQL, -1, &stmt, nil) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            guard
                (try? bindStateUpdate(
                    stmt, source: source, revision: revision, state: state, attempts: attempts, lastError: lastError,
                    updatedAt: updatedAt)) != nil,
                requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
            else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    /// One transaction: every revision changes, or none does. A missing row or a failed statement rolls back all of
    /// them, so a caller that sees false never finds one of them changed.
    private func updateStatesUnobserved(
        of source: UploadSourceIdentity, _ updates: [StateUpdate], updatedAt: Date
    ) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.updateStateSQL, -1, &stmt, nil) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            for update in updates {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard
                    (try? bindStateUpdate(
                        stmt, source: source, revision: update.revision, state: update.state, attempts: nil,
                        lastError: update.lastError, updatedAt: updatedAt)) != nil,
                    requireOperational(sqlite3_step(stmt) == SQLITE_DONE), sqlite3_changes(db) == 1
                else {
                    sqlite3_reset(stmt)
                    connection.rollBack()
                    return false
                }
            }
            sqlite3_reset(stmt)
            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    private static let updateStateSQL = """
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
        """

    private func bindStateUpdate(
        _ stmt: OpaquePointer?, source: UploadSourceIdentity, revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState, attempts: Int?, lastError: String?, updatedAt: Date
    ) throws {
        try connection.bindText(stmt, 1, state.rawValue)
        if let attempts {
            sqlite3_bind_int(stmt, 2, Int32(max(0, attempts)))
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        try connection.bindText(stmt, 3, lastError)
        try connection.bindText(stmt, 4, state.rawValue)
        sqlite3_bind_double(stmt, 5, updatedAt.timeIntervalSince1970)
        try bindSource(source, to: stmt, from: 6)
        sqlite3_bind_int64(stmt, 9, revision.rawValue)
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
        return connection.withLock {
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
            do {
                try connection.bindText(stmt, 1, lastError)
                // A receipt that does not bind must fail the write: the row would lose its upload receipt (#1194).
                try connection.bindBlob(stmt, 2, payload)
                sqlite3_bind_double(stmt, 3, updatedAt.timeIntervalSince1970)
                try bindSource(source, to: stmt, from: 4)
                sqlite3_bind_int64(stmt, 7, revision.rawValue)
            } catch {
                return false
            }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
            return sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    private func removeUnobserved(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        connection.withLock { removeLocked(source: source, revision: revision) }
    }

    private func removeLocked(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
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
        guard (try? bindSource(source, to: stmt, from: 1)) != nil else { return false }
        sqlite3_bind_int64(stmt, 4, revision.rawValue)
        guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return false }
        return sqlite3_changes(db) > 0
    }

    private func removeSettledRevisionsUnobserved(
        of source: UploadSourceIdentity, except revision: UploadBackupRevision
    ) -> Bool {
        connection.withLock {
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
            guard (try? bindSource(source, to: stmt, from: 1)) != nil else { return false }
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    private struct ObsoleteRevisionScope {
        let source: UploadSourceIdentity
        let through: UploadBackupRevision
        let kept: UploadBackupRevision
    }

    /// Returns changed sources only after the whole cleanup batch commits, or nil on failure.
    private func removeUnsavedEarlierRevisionsUnobserved(
        _ scopes: [ObsoleteRevisionScope]
    ) -> Set<UploadSourceIdentity>? {
        guard !scopes.isEmpty else { return [] }
        return connection.withLock {
            let changed =
                withDurableCommitsRecordingSetup { () -> Set<UploadSourceIdentity>? in
                    guard
                        requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
                    else {
                        return nil
                    }
                    var committed = false
                    defer { if !committed { connection.rollBack() } }
                    var changed: Set<UploadSourceIdentity> = []
                    for cleanup in scopes {
                        let scope = """
                            source_kind=? AND source_id=? AND resource=? AND revision_us<=? AND revision_us<>?
                            AND remote_commit_reconciliation IS NULL
                            """
                        let bindScope: (OpaquePointer?) throws -> Void = { stmt in
                            try self.bindSource(cleanup.source, to: stmt, from: 1)
                            sqlite3_bind_int64(stmt, 4, cleanup.through.rawValue)
                            sqlite3_bind_int64(stmt, 5, cleanup.kept.rawValue)
                        }
                        guard let markers = dismissedSourceRecheckRowIDsLocked(matching: scope, bindScope: bindScope)
                        else {
                            return nil
                        }
                        let markerMatch =
                            markers.isEmpty ? "0" : "rowid IN (\(markers.map(String.init).joined(separator: ",")))"
                        var stmt: OpaquePointer?
                        guard
                            requireOperational(
                                sqlite3_prepare_v2(
                                    db,
                                    """
                                    DELETE FROM backup_sync_queue WHERE \(scope)
                                      AND (state IN ('skippedRemoteDeletion','sourceMissing','failedPermanent','dismissedFailure')
                                           OR \(markerMatch));
                                    """, -1, &stmt, nil) == SQLITE_OK)
                        else { return nil }
                        defer { sqlite3_finalize(stmt) }
                        guard (try? bindScope(stmt)) != nil,
                            requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
                        else { return nil }
                        if sqlite3_changes(db) > 0 { changed.insert(cleanup.source) }
                    }
                    guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                        return nil
                    }
                    committed = true
                    return changed
                } ?? nil
            if changed == nil { markFailedOnceUnrecorded() }
            return changed
        }
    }

    @discardableResult
    private func removeSourcesUnobserved(kind: UploadSourceIdentity.Kind, identifiers: [String]) -> Int {
        let identifiers = Array(Set(identifiers))
        guard !identifiers.isEmpty else { return 0 }
        return connection.withLock {
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
                guard (try? connection.bindText(stmt, 1, kind.rawValue)) != nil,
                    (try? connection.bindText(stmt, 2, identifier)) != nil,
                    requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
                else {
                    connection.rollBack()
                    return 0
                }
                removed += Int(sqlite3_changes(db))
            }
            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                connection.rollBack()
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

        return connection.withLock {
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

            do {
                try connection.bindText(stmt, 1, UploadSourceIdentity.Kind.fileURL.rawValue)
                var binding: Int32 = 2
                for root in roots {
                    try connection.bindText(stmt, binding, root)
                    try connection.bindText(stmt, binding + 1, root)
                    try connection.bindText(stmt, binding + 2, root)
                    binding += 3
                }
            } catch {
                return 0
            }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// The rows per state, and per check reason for the check states, for the background log. It reads the whole
    /// queue, so it must not run on the main actor. Nil when the store cannot be read.
    public func queueCounts() -> UploadBackupQueueDiagnostics? {
        connection.withLock {
            var counts = UploadBackupQueueDiagnostics()
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT state, CASE WHEN state IN ('discovered','checking') THEN last_error END, COUNT(*)
                        FROM backup_sync_queue GROUP BY 1, 2;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let raw = columnText(stmt, 0), let state = UploadBackupSyncQueueState(rawValue: raw) else {
                    return nil
                }
                let rows = Int(sqlite3_column_int(stmt, 2))
                counts.rows[state, default: 0] += rows
                if state == .discovered || state == .checking {
                    let reason = UploadBackupQueueDiagnostics.checkReason(lastError: columnText(stmt, 1))
                    counts.checkReasons[state, default: [:]][reason, default: 0] += rows
                }
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return nil }
            return counts
        }
    }

    public func summary() -> UploadBackupSyncQueueSummary? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT state, source_kind,
                               CASE WHEN state IN ('discovered','checking') THEN last_error END AS check_reason, COUNT(*)
                        FROM backup_sync_queue GROUP BY state, source_kind, check_reason;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            var summary = UploadBackupSyncQueueSummary()
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let raw = columnText(stmt, 0),
                    let state = UploadBackupSyncQueueState(rawValue: raw)
                else {
                    connection.markFailed()
                    return nil
                }
                let count = Int(sqlite3_column_int(stmt, 3))
                if let kind = columnText(stmt, 1).flatMap(UploadSourceIdentity.Kind.init(rawValue:)),
                    UploadBackupSyncQueueEntry.isDismissedSourceRecheck(
                        sourceKind: kind, state: state, lastError: columnText(stmt, 2))
                {
                    summary.include(.dismissedFailure, count: count)
                    summary.pendingSourceRechecks += count
                } else {
                    summary.include(state, count: count)
                }
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else {
                return nil
            }
            return summary
        }
    }

    public func count() -> Int? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM backup_sync_queue;", -1, &stmt, nil) == SQLITE_OK
                )
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// State of the one-time catalog replay used only when this queue DB was reset independently of
    /// the durable photo catalog. Stored in the queue DB itself: a reset naturally clears the marker
    /// and requests another rebuild, while ordinary row removal does not.
    /// A nil state is an unknown read. Callers must not treat it as `.notStarted`: `.notStarted` with a non-empty
    /// queue marks an interrupted replay completed, and the remaining catalog entries are then never replayed (#1004).
    public func catalogReplayState() -> UploadBackupCatalogReplayState? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM backup_sync_queue_info WHERE key=?;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            // A failed bind would read as "never started" and complete an interrupted replay. The fixed key is shorter
            // than any length limit, so only out-of-memory can fail it.
            guard (try? connection.bindText(stmt, 1, Self.catalogReplayStateKey)) != nil else { return nil }
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return .notStarted }
            guard requireOperational(result == SQLITE_ROW) else { return nil }
            return UploadBackupCatalogReplayState(rawValue: Int(sqlite3_column_int(stmt, 0))) ?? .notStarted
        }
    }

    @discardableResult
    public func setCatalogReplayState(_ state: UploadBackupCatalogReplayState) -> Bool {
        connection.withLock {
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
            guard (try? connection.bindText(stmt, 1, Self.catalogReplayStateKey)) != nil else { return false }
            sqlite3_bind_int(stmt, 2, Int32(state.rawValue))
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    public func missingSourceDiscardGeneration() -> Int64? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT value FROM backup_sync_queue_info WHERE key='missing_source_discard_generation';",
                        -1, &stmt, nil) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return 0 }
            guard requireOperational(step == SQLITE_ROW) else { return nil }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    public func sourcesWithEntries(_ sources: [UploadSourceIdentity]) -> Set<UploadSourceIdentity>? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT 1 FROM backup_sync_queue WHERE source_kind=? AND source_id=? LIMIT 1;",
                        -1, &stmt, nil) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            var result: Set<UploadSourceIdentity> = []
            for source in sources {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                // A key that does not bind is no proof that the source has no rows (#1194).
                guard (try? connection.bindText(stmt, 1, source.kind.rawValue)) != nil,
                    (try? connection.bindText(stmt, 2, source.identifier)) != nil
                else { return nil }
                let step = sqlite3_step(stmt)
                guard requireOperational(step == SQLITE_ROW || step == SQLITE_DONE) else { return nil }
                if step == SQLITE_ROW { result.insert(source) }
            }
            return result
        }
    }

    public func insertMissingSources(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        var enqueued = false
        let result = connection.withLock { () -> Bool in
            let committed =
                withDurableCommitsRecordingSetup { () -> Bool in
                    var stmt: OpaquePointer?
                    guard
                        requireOperational(
                            sqlite3_prepare_v2(
                                db,
                                """
                                INSERT INTO backup_sync_queue(
                                    source_kind, source_id, resource, revision_us, original_filename,
                                    byte_count, state, attempts, last_error, updated_at, remote_commit_reconciliation
                                ) SELECT ?,?,?,?,?,?,?,?,?,?,? WHERE NOT EXISTS (
                                    SELECT 1 FROM backup_sync_queue WHERE source_kind=? AND source_id=?
                                );
                                """, -1, &stmt, nil) == SQLITE_OK),
                        requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
                    else {
                        sqlite3_finalize(stmt)
                        return false
                    }
                    defer { sqlite3_finalize(stmt) }
                    for entry in entries {
                        sqlite3_reset(stmt)
                        sqlite3_clear_bindings(stmt)
                        guard (try? bind(entry, to: stmt)) != nil,
                            (try? connection.bindText(stmt, 12, entry.source.kind.rawValue)) != nil,
                            (try? connection.bindText(stmt, 13, entry.source.identifier)) != nil,
                            requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
                        else {
                            connection.rollBack()
                            return false
                        }
                        if sqlite3_changes(db) > 0, Self.runnableStates.contains(entry.state.rawValue) {
                            enqueued = true
                        }
                    }
                    guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                        connection.rollBack()
                        return false
                    }
                    return true
                }
            if committed == nil { markFailedOnceUnrecorded() }
            let result = committed ?? false
            return result
        }
        if result { notify(UploadBackupSyncQueueChange(sources: entries.map(\.source), enqueued: enqueued)) }
        return result
    }

    public func removeMissingSource(source: UploadSourceIdentity, revision: UploadBackupRevision) -> Bool {
        guard source.kind == .photoLibraryAsset else { return remove(source: source, revision: revision) }
        let result = connection.withLock { () -> Bool in
            let committed =
                withDurableCommitsRecordingSetup { () -> Bool in
                    guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK)
                    else {
                        return false
                    }
                    guard removeLocked(source: source, revision: revision),
                        requireOperational(
                            sqlite3_exec(
                                db,
                                """
                                INSERT INTO backup_sync_queue_info(key, value) VALUES('missing_source_discard_generation', 1)
                                ON CONFLICT(key) DO UPDATE SET value=value+1;
                                """, nil, nil, nil) == SQLITE_OK),
                        requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
                    else {
                        connection.rollBack()
                        return false
                    }
                    return true
                }
            // A body result of false can mean an absent discard, which is not a failure; only a wrapper that could not
            // run records a failure (#1004).
            if committed == nil { markFailedOnceUnrecorded() }
            return committed ?? false
        }
        if result { notify(UploadBackupSyncQueueChange(sources: [source])) }
        return result
    }

    public func runtimeIssue(for key: BackupRuntimeIssueKey) -> BackupIssueRecord? {
        (try? runtimeIssue(for: key, requireComplete: false)) ?? nil
    }

    /// An undecodable stored value answers nil: that is a fact about the value, not a failed read.
    private func runtimeIssue(for key: BackupRuntimeIssueKey, requireComplete: Bool) throws -> BackupIssueRecord? {
        try connection.withLock {
            try beginReadLocked(requireComplete: requireComplete)
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db, "SELECT value FROM backup_sync_runtime_issue WHERE key=?;", -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return try unknownRead(requireComplete: requireComplete, nil) }
            defer { sqlite3_finalize(stmt) }
            try connection.bindText(stmt, 1, key.rawValue)
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW { return BackupIssueRecord.decode(columnText(stmt, 0)) }
            if result != SQLITE_DONE {
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return try unknownRead(requireComplete: requireComplete, nil)
            }
            return nil
        }
    }

    @discardableResult
    public func setRuntimeIssue(_ issue: BackupIssueRecord?, for key: BackupRuntimeIssueKey) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
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
                guard (try? connection.bindText(stmt, 1, key.rawValue)) != nil,
                    (try? connection.bindText(stmt, 2, issue.persistedValue)) != nil
                else { return false }
            } else {
                guard
                    requireOperational(
                        sqlite3_prepare_v2(
                            db, "DELETE FROM backup_sync_runtime_issue WHERE key=?;", -1, &stmt, nil
                        ) == SQLITE_OK)
                else { return false }
                guard (try? connection.bindText(stmt, 1, key.rawValue)) != nil else { return false }
            }
            return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    private static let upsertReplaceableStateList =
        "'discovered','queuedForUpload','failed','paused','sourceMissing','blockedByDraft','skippedRemoteDeletion'"

    /// A claimed row (`checking`) keeps its receipt like a reconciliation row: the claim carries the receipt of an
    /// upload that already reached Proton, and stale recovery resumes from it.
    private static let upsertSQL = """
        INSERT INTO backup_sync_queue(
          source_kind, source_id, resource, revision_us, original_filename,
          byte_count, state, attempts, last_error, updated_at, remote_commit_reconciliation
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source_kind, source_id, resource, revision_us) DO UPDATE SET
          original_filename=excluded.original_filename,
          byte_count=excluded.byte_count,
          state=CASE
            WHEN backup_sync_queue.state IN (\(upsertReplaceableStateList)) THEN excluded.state
            ELSE backup_sync_queue.state
          END,
          attempts=CASE
            WHEN backup_sync_queue.state IN (\(upsertReplaceableStateList)) THEN excluded.attempts
            ELSE backup_sync_queue.attempts
          END,
          last_error=CASE
            WHEN backup_sync_queue.state IN (\(upsertReplaceableStateList)) THEN excluded.last_error
            ELSE backup_sync_queue.last_error
          END,
          remote_commit_reconciliation=CASE
            WHEN backup_sync_queue.state IN ('needsRemoteReconciliation','checking')
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
            verifyVersion: schemaVersionRow.verify,
            stampVersion: schemaVersionRow.stamp
        )
    }

    /// Binds every column of one row. A failed bind throws; the caller must not step the statement (#1194).
    private func bind(_ entry: UploadBackupSyncQueueEntry, to stmt: OpaquePointer?) throws {
        try bindSource(entry.source, to: stmt, from: 1)
        sqlite3_bind_int64(stmt, 4, entry.revision.rawValue)
        try connection.bindText(stmt, 5, entry.originalFilename)
        if let byteCount = entry.byteCount {
            sqlite3_bind_int64(stmt, 6, byteCount)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        try connection.bindText(stmt, 7, entry.state.rawValue)
        sqlite3_bind_int(stmt, 8, Int32(entry.attempts))
        try connection.bindText(stmt, 9, entry.lastError)
        sqlite3_bind_double(stmt, 10, entry.updatedAt.timeIntervalSince1970)
        // A receipt that does not bind must fail the write: the row would lose its upload receipt.
        try connection.bindBlob(
            stmt, 11, entry.remoteCommitReconciliation.flatMap { try? JSONEncoder().encode($0) })
    }

    /// Binds the source's kind, identifier and resource from `first` on. Call under `connection.withLock`.
    private func bindSource(_ source: UploadSourceIdentity, to stmt: OpaquePointer?, from first: Int32) throws {
        try connection.bindText(stmt, first, source.kind.rawValue)
        try connection.bindText(stmt, first + 1, source.identifier)
        try connection.bindText(stmt, first + 2, source.resource.rawValue)
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
            connection.markFailed()
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

    private func earliestEntry(sql: String, requireComplete: Bool) throws -> UploadBackupSyncQueueEntry? {
        try connection.withLock {
            try beginReadLocked(requireComplete: requireComplete)
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK) else {
                return try unknownRead(requireComplete: requireComplete, nil)
            }
            defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            guard result == SQLITE_ROW else {
                if result != SQLITE_DONE {
                    connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                    return try unknownRead(requireComplete: requireComplete, nil)
                }
                return nil
            }
            guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else {
                connection.markFailed()
                return try unknownRead(requireComplete: requireComplete, nil)
            }
            guard
                let entry = row(
                    stmt,
                    source: source,
                    revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3)),
                    offset: 4
                )
            else { return try unknownRead(requireComplete: requireComplete, nil) }
            return entry
        }
    }

    // MARK: - Observed writes

    @discardableResult
    public func upsert(_ entry: UploadBackupSyncQueueEntry) -> Bool {
        upsertBatch([entry])
    }

    @discardableResult
    public func upsertBatch(_ entries: [UploadBackupSyncQueueEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        guard let change = upsertBatchUnobserved(entries) else { return false }
        notify(change)
        return true
    }

    public func claimRunnable(
        limit: Int, claimedAt: Date, excludingSourcesOf excludedSources: [UploadSourceIdentity]
    ) -> [UploadBackupSyncQueueEntry]? {
        let claimed = claimRunnableUnobserved(limit: limit, claimedAt: claimedAt, excludedSources: excludedSources)
        if let claimed, !claimed.isEmpty { notify(UploadBackupSyncQueueChange(sources: claimed.map(\.source))) }
        return claimed
    }

    @discardableResult
    public func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int? {
        let changed = requeueStaleActiveUnobserved(before: cutoff, updatedAt: updatedAt)
        if let changed, changed > 0 { notify(.all) }
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

    /// The new state of one revision in `updateStates`. The attempt count stays.
    public struct StateUpdate: Sendable, Equatable {
        public let revision: UploadBackupRevision
        public let state: UploadBackupSyncQueueState
        public let lastError: String?

        public init(revision: UploadBackupRevision, state: UploadBackupSyncQueueState, lastError: String?) {
            self.revision = revision
            self.state = state
            self.lastError = lastError
        }
    }

    /// Writes several revisions of one source together: every row changes, or, after a missing row or a failed
    /// statement, none does and the result is false. An empty list writes nothing and succeeds.
    @discardableResult
    public func updateStates(of source: UploadSourceIdentity, _ updates: [StateUpdate], updatedAt: Date) -> Bool {
        guard !updates.isEmpty else { return true }
        guard updateStatesUnobserved(of: source, updates, updatedAt: updatedAt) else { return false }
        for update in updates { recordSupportEvent(source: source, state: update.state, lastError: update.lastError) }
        notify(UploadBackupSyncQueueChange(sources: [source]))
        return true
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
        removeUnsavedEarlierRevisions([.init(source: source, through: revision, kept: kept)])
    }

    @discardableResult
    public func removeUnsavedEarlierRevisions(of entries: [UploadBackupSyncQueueEntry]) -> Bool {
        removeUnsavedEarlierRevisions(entries.map { .init(source: $0.source, through: $0.revision, kept: $0.revision) })
    }

    private func removeUnsavedEarlierRevisions(_ scopes: [ObsoleteRevisionScope]) -> Bool {
        guard let changed = removeUnsavedEarlierRevisionsUnobserved(scopes) else { return false }
        // Most backups remove nothing; only committed changes reach the observers.
        if !changed.isEmpty { notify(UploadBackupSyncQueueChange(sources: Array(changed))) }
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
        let observers = observerLock.withLock { Array(changeObservers.values) }
        for observer in observers { observer(change) }
    }

    /// Rows of these sources (same kind and identifier, any resource or revision) stay out of a runnable-set query.
    private struct SourceExclusion {
        var keys: [(kind: String, identifier: String)] = []

        init(_ sources: [UploadSourceIdentity]) {
            var seen: Set<String> = []
            for source in sources where seen.insert(source.kind.rawValue + "|" + source.identifier).inserted {
                keys.append((source.kind.rawValue, source.identifier))
            }
        }

        var clause: String { String(repeating: "\n  AND NOT (source_kind=? AND source_id=?)", count: keys.count) }
    }

    /// Binds the exclusion's parameters from `first` on and returns the next free parameter index. A failed bind
    /// throws; the caller must not step the statement (#1194).
    private func bind(_ exclusion: SourceExclusion, to stmt: OpaquePointer?, from first: Int32) throws -> Int32 {
        var parameter = first
        for key in exclusion.keys {
            try connection.bindText(stmt, parameter, key.kind)
            try connection.bindText(stmt, parameter + 1, key.identifier)
            parameter += 2
        }
        return parameter
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
}

extension UploadBackupSyncQueueManifestStore: UploadBackupSyncQueueObserving {
    public func setChangeObserver(_ observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?) {
        observerLock.withLock { changeObservers[legacyObserverID] = observer }
    }

    public func changes() -> AsyncStream<UploadBackupSyncQueueChange> {
        let id = UUID()
        return AsyncStream { continuation in
            observerLock.withLock { changeObservers[id] = { continuation.yield($0) } }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.observerLock.withLock { self.changeObservers.removeValue(forKey: id) }
            }
        }
    }

    private static let unsettledCondition = """
        state NOT IN ('alreadyBackedUp', 'completed', 'skippedRemoteDeletion', 'sourceMissing',
                      'dismissedFailure')
        """

    // MARK: - Complete reads for decisions (#1004)
    // Each runs the same SQL as its legacy reader. It refuses an open transaction or a lasting failure, checks the
    // binds of library values, and throws `SQLiteStoreUnknownReadError` on a failed statement or a row that does not
    // decode. It never answers a prefix.

    public func decisionUnsettledRows() throws -> [UploadBackupQueueRowState] {
        try rowStates(where: Self.unsettledCondition, bindings: [nil])
            .filter { $0.state != .dismissedFailure }
    }

    public func decisionNextRunnableDate(excludingSourcesOf excludedSources: [UploadSourceIdentity]) throws -> Date? {
        try runnableDate(excludingSourcesOf: excludedSources, requireComplete: true)
    }

    public func decisionEarliestEntry(in state: UploadBackupSyncQueueState) throws -> UploadBackupSyncQueueEntry? {
        try earliestEntry(sql: Self.earliestEntrySQL(forState: state.rawValue) + ";", requireComplete: true)
    }

    public func decisionEntries(
        in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int
    ) throws -> [UploadBackupSyncQueueEntry] {
        try entries(in: state, updatedBefore: updatedBefore, limit: limit, requireComplete: true)
    }

    public func decisionRuntimeIssue(for key: BackupRuntimeIssueKey) throws -> BackupIssueRecord? {
        try runtimeIssue(for: key, requireComplete: true)
    }

    /// Streams the problem rows as `forEachProblemEntry` does. After a throw the caller discards what it received.
    public func decisionForEachProblemEntry(_ body: (UploadBackupSyncQueueEntry) -> Bool) throws {
        try problemEntries(body, requireComplete: true)
    }

    /// Rows that upload now or wait their turn. A waiting row with an issue record belongs to the problem list
    /// (`forEachProblemEntry`), so the queue list leaves it out. A display read: a failed read shows an empty list.
    public func queueWorkRows() -> [UploadBackupQueueRowState] {
        (try? rowStates(
            where: """
                state IN ('checking', 'hashing', 'duplicateChecking', 'uploading', 'finalizing',
                          'needsRemoteReconciliation', 'discovered', 'queuedForUpload', 'paused')
                  AND (state NOT IN ('discovered', 'queuedForUpload') OR last_error IS NULL
                       OR substr(last_error, 1, ?) != ?)
                """,
            bindings: [
                { (stmt: OpaquePointer?) in
                    sqlite3_bind_int64(stmt, 1, Int64(BackupIssueRecord.storagePrefix.count))
                    try self.connection.bindText(stmt, 2, BackupIssueRecord.storagePrefix)
                }
            ]
        )) ?? []
    }

    /// Every row of the given sources, from a complete read.
    public func decisionRows(
        kind: UploadSourceIdentity.Kind, identifiers: Set<String>
    ) throws -> [UploadBackupQueueRowState] {
        guard !identifiers.isEmpty else { return [] }
        return try rowStates(
            where: "source_kind=? AND source_id=?",
            bindings: identifiers.map { identifier in
                { stmt in
                    try self.connection.bindText(stmt, 1, kind.rawValue)
                    try self.connection.bindText(stmt, 2, identifier)
                }
            }
        )
    }

    /// Cosmetic admission read: failure must not change the queue's operational health.
    public func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision] {
        connection.withLock {
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
            // A failed bind answers the same empty map as a failed statement, and like it records nothing.
            guard SQLiteBinding.text(stmt, 1, kind.rawValue) == SQLITE_OK,
                SQLiteBinding.text(stmt, 2, kind.rawValue) == SQLITE_OK
            else { return [:] }
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

    /// Runs one prepared query once for each set of bindings, so a batch of sources costs one prepare. It refuses an
    /// open transaction or a lasting failure and throws on a failed statement or a row that does not decode, so it
    /// never answers a prefix.
    private func rowStates(
        where condition: String,
        bindings: [((OpaquePointer?) throws -> Void)?]
    ) throws -> [UploadBackupQueueRowState] {
        try connection.withLock {
            guard readerMayProceedLocked() else { throw SQLiteStoreUnknownReadError() }
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT source_kind, source_id, resource, revision_us, state, original_filename, updated_at, last_error
                        FROM backup_sync_queue WHERE \(condition);
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { throw SQLiteStoreUnknownReadError() }
            defer { sqlite3_finalize(stmt) }
            var result: [UploadBackupQueueRowState] = []
            for bind in bindings {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bind?(stmt)
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    if let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2),
                        let state = columnText(stmt, 4).flatMap(UploadBackupSyncQueueState.init(rawValue:))
                    {
                        result.append(
                            UploadBackupQueueRowState(
                                source: source,
                                revision: UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3)),
                                state: UploadBackupSyncQueueEntry.isDismissedSourceRecheck(
                                    sourceKind: source.kind, state: state, lastError: columnText(stmt, 7))
                                    ? .dismissedFailure : state,
                                originalFilename: columnText(stmt, 5) ?? "",
                                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                            ))
                    } else {
                        connection.markFailed()
                        throw SQLiteStoreUnknownReadError()
                    }
                    step = sqlite3_step(stmt)
                }
                if step != SQLITE_DONE {
                    connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                    throw SQLiteStoreUnknownReadError()
                }
            }
            return result
        }
    }
}

extension UploadBackupSyncQueueManifestStore: BackupQueueSupportSource {
    /// Group only local scalar columns. No source identifier, filename, receipt, or backend detail leaves this method.
    public func backupSupportSnapshot() -> BackupQueueSupportSnapshot {
        connection.withLock {
            guard db != nil, !connection.operationFailed else { return BackupQueueSupportSnapshot() }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT state, resource, last_error, source_kind, COUNT(*) FROM backup_sync_queue
                    GROUP BY state, resource, last_error, source_kind;
                    """,
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
                let rawState = columnText(stmt, 0) ?? ""
                let lastError = columnText(stmt, 2)
                var state = BackupQueueSupportSnapshot.State(rawValue: rawState) ?? .unknown
                if let sourceKind = columnText(stmt, 3).flatMap(UploadSourceIdentity.Kind.init(rawValue:)),
                    let queueState = UploadBackupSyncQueueState(rawValue: rawState),
                    UploadBackupSyncQueueEntry.isDismissedSourceRecheck(
                        sourceKind: sourceKind, state: queueState, lastError: lastError)
                {
                    state = .dismissedFailure
                }
                let resource = Self.supportResourceKind(columnText(stmt, 1) ?? "")
                let reason = Self.supportReason(lastError)
                let count = Int(sqlite3_column_int64(stmt, 4))
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
