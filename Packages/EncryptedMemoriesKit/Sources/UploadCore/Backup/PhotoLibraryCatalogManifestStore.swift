import Foundation
import PhotosCore
import SQLite3

/// Persistent local photo-library catalog (`photo-library-catalog-v1.sqlite`). An incompatible,
/// corrupt, locked, or temporarily unavailable store fails closed and remains untouched. One row per
/// asset `localIdentifier`; resources ride in a single JSON column.
public final class PhotoLibraryCatalogManifestStore: PhotoLibraryCatalogStore, @unchecked Sendable {
    public static let databaseFileName = "photo-library-catalog-v1.sqlite"

    private static let schemaVersion = 3
    private static let schemaVersionRow = SQLiteInfoTableVersion(
        table: "photo_catalog_info", version: schemaVersion, stampReplacesExistingRow: true)
    private static let completedFullScanKey = "completed_full_scan"
    private static let fullScanEpochStartKey = "full_scan_epoch_start"
    private static let fullScanCursorKey = "full_scan_cursor"
    private static let fullScanSnapshotReadyKey = "full_scan_snapshot_ready"
    private static let reconciledLateRendersKey = "reconciled_late_renders"
    private static let lateRenderSweepResumePointKey = "late_render_sweep_resume_point"
    private static let reconciledMissingSourceGenerationKey = "reconciled_missing_source_generation"
    private static let missingSourceSweepGenerationKey = "missing_source_sweep_generation"
    private static let missingSourceSweepResumePointKey = "missing_source_sweep_resume_point"
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        SQLiteStoreSchemaGate.enableFullSyncCheckpoints(handle)
        connection = SQLiteStoreConnection(database: handle)
    }

    deinit { close() }

    /// A transient failure stops the store only until the database answers again. Every decision reads strictly, and a
    /// catalog info read that answers nil or false on failure only causes more work, a rescan or a sweep from the start
    /// (#1004).
    public func isOperational() -> Bool { connection.isOperationalAfterTransientFailure() }

    /// Records a predicate under `withLock`, with the extended code of the failed SQLite call. A busy, locked, full,
    /// interrupted, out-of-memory or I/O failure stops the store until `isOperational()` finds the database answering
    /// again. Any other failure, and an I/O failure that reports damaged data (SQLITE_IOERR_DATA,
    /// SQLITE_IOERR_CORRUPTFS), stops it until the store is opened again.
    @discardableResult
    private func requireOperational(_ condition: Bool) -> Bool {
        connection.requireOperationalRecordingSQLiteError(condition)
    }

    public func close() { connection.close() }

    /// Reads one row. A closed store and a failed statement or binding throw `SQLiteStoreUnknownReadError`; an
    /// undecodable row throws `PhotoLibraryCatalogUndecodableRowError`. Nil proves absence (#1004, #1212).
    public func entry(for localIdentifier: String) throws -> PhotoLibraryCatalogEntry? {
        try connection.withLock { try readEntry(localIdentifier) }
    }

    /// Present (not removed) entries for many identifiers with one prepared statement. Missing or removed
    /// identifiers are absent from the result. Returns nil when any requested row could not be read; nil means the
    /// result is unknown, not empty (#1004).
    public func presentEntries(for localIdentifiers: [String]) -> [String: PhotoLibraryCatalogEntry]? {
        let answer = presence(for: localIdentifiers)
        return answer.unknown.isEmpty ? answer.present : nil
    }

    /// Present entries plus the identifiers whose own row could not be read. Each identifier is its own read: an
    /// unreadable row leaves the other answers known, and an identifier in neither set is absent or removed (#1004).
    public func presence(for localIdentifiers: [String]) -> PhotoLibraryCatalogPresence {
        guard !localIdentifiers.isEmpty else { return PhotoLibraryCatalogPresence() }
        return connection.withLock {
            var answer = PhotoLibraryCatalogPresence()
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT cloud_id, creation_date, modification_date, pixel_width, pixel_height, duration_seconds,
                               media_kind, is_live_photo, resources_json, content_fingerprint, metadata_revision,
                               first_seen_at, last_seen_at, is_removed, removed_at
                        FROM photo_catalog WHERE local_id=? AND is_removed=0;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else {
                answer.unknown = Set(localIdentifiers)
                return answer
            }
            defer { sqlite3_finalize(stmt) }
            answer.present.reserveCapacity(localIdentifiers.count)
            for identifier in localIdentifiers {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard requireBound(bindText(stmt, 1, identifier)) else {
                    answer.unknown.insert(identifier)
                    continue
                }
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { continue }
                guard requireOperational(step == SQLITE_ROW),
                    let entry = decodeEntry(stmt, localIdentifier: identifier, valueOffset: 0)
                else {
                    answer.unknown.insert(identifier)
                    continue
                }
                answer.present[identifier] = entry
            }
            return answer
        }
    }

    /// Stable keyset page of present inventory rows. Returns nil when the page could not be read; nil means
    /// the result is unknown, not an empty page. A caller must not treat nil as the end of the catalog (#1004).
    /// A row whose content could not be decoded is unknown for that row only: its readable identifier is
    /// collected and the page keeps stepping (#1160). A row whose key is not exact text leaves the page unknown, and
    /// so does a row whose key sorts before every text key when a page after a cursor comes back empty (#1212).
    public func presentEntries(afterLocalIdentifier: String?, limit: Int) -> PhotoLibraryCatalogPage? {
        let clampedLimit = max(1, limit)
        // The primary-key range keeps pages bounded; the removal index would sort the remaining library per page.
        let frontier = afterLocalIdentifier == nil ? "" : " AND local_id>?"
        return connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        SELECT local_id, cloud_id, creation_date, modification_date, pixel_width, pixel_height,
                               duration_seconds, media_kind, is_live_photo, resources_json, content_fingerprint,
                               metadata_revision, first_seen_at, last_seen_at, is_removed, removed_at
                        FROM photo_catalog INDEXED BY sqlite_autoindex_photo_catalog_1
                        WHERE is_removed=0\(frontier)
                        ORDER BY local_id LIMIT ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            // A failed cursor bind leaves the parameter NULL, and `local_id>NULL` would end the catalog early.
            if let afterLocalIdentifier, !requireBound(bindText(stmt, 1, afterLocalIdentifier)) { return nil }
            guard
                requireBound(
                    sqlite3_bind_int(stmt, afterLocalIdentifier == nil ? 1 : 2, Int32(clamping: clampedLimit)))
            else { return nil }
            var page = PhotoLibraryCatalogPage()
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                // A repaired key would come back from `local_id>?` as the next cursor, so a pass could never move
                // past it. A key that cannot be read exactly means deeper damage: the page stays unknown (#1212).
                guard let localIdentifier = exactKeyText(stmt, 0) else {
                    connection.markFailed()
                    return nil
                }
                if let entry = decodeEntry(stmt, localIdentifier: localIdentifier, valueOffset: 1) {
                    page.entries.append(entry)
                } else {
                    // A readable key whose row content could not decode is unknown for that row only (#1160).
                    page.undecodableIdentifiers.append(localIdentifier)
                }
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return nil }
            // `local_id>?` never returns a NULL, INTEGER or REAL key, which sort before every text key, so a pass
            // with a cursor would end without such a row. It comes only from damage, so the end is unknown (#1212).
            if afterLocalIdentifier != nil, page.entries.isEmpty, page.undecodableIdentifiers.isEmpty {
                guard let rowBeforeTextKeysExists = presentRowBeforeTextKeysExistsLocked() else { return nil }
                guard !rowBeforeTextKeysExists else {
                    connection.markFailed()
                    return nil
                }
            }
            return page
        }
    }

    /// Whether a present row has a key that sorts before every text key: NULL, INTEGER or REAL. A comparison with a
    /// text bound would convert a stored number to text, so the read takes the storage class of the first present key
    /// in key order instead. Nil when the read failed (#1004).
    private func presentRowBeforeTextKeysExistsLocked() -> Bool? {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT typeof(local_id) FROM photo_catalog INDEXED BY sqlite_autoindex_photo_catalog_1
                    WHERE is_removed=0 ORDER BY local_id LIMIT 1;
                    """,
                    -1, &stmt, nil) == SQLITE_OK)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return false }
        guard requireOperational(step == SQLITE_ROW), let storageClass = columnText(stmt, 0) else { return nil }
        return storageClass != "text" && storageClass != "blob"
    }

    public func classifyBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        guard !entries.isEmpty else { return [] }
        return connection.withLock { classifyBatchLocked(entries) }
    }

    @discardableResult
    public func upsertBatch(_ entries: [PhotoLibraryCatalogEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return connection.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK)
            else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            var didPersist = true
            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard requireOperational(persist(entry, using: stmt)) else {
                    didPersist = false
                    break
                }
            }
            guard didPersist,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    @discardableResult
    public func markRemoved(
        _ identifiers: [String],
        removedAt: Date
    ) -> PhotoLibraryCatalogMutationResult {
        let present = identifiers.filter { !$0.isEmpty }
        guard !present.isEmpty else {
            return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: true)
        }
        return connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE photo_catalog SET is_removed=1, removed_at=?
                        WHERE local_id=? AND is_removed=0;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            var changed = 0
            for id in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard
                    requireBound([
                        sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970), bindText(stmt, 2, id),
                    ]),
                    requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
                else {
                    connection.rollBack()
                    return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
                }
                changed += Int(sqlite3_changes(db))
            }
            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                connection.rollBack()
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            return PhotoLibraryCatalogMutationResult(affectedRows: changed, succeeded: true)
        }
    }

    @discardableResult
    public func sweepRemoved(
        notSeenAfter cutoff: Date,
        removedAt: Date
    ) -> PhotoLibraryCatalogMutationResult {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        UPDATE photo_catalog SET is_removed=1, removed_at=?
                        WHERE is_removed=0 AND last_seen_at < ?;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            defer { sqlite3_finalize(stmt) }
            guard
                requireBound([
                    sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970),
                    sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970),
                ]),
                requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
            else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            return PhotoLibraryCatalogMutationResult(
                affectedRows: Int(sqlite3_changes(db)),
                succeeded: true
            )
        }
    }

    /// Returns nil when the requested read fails; nil means unknown, not empty (#1004).
    public func snapshot() -> PhotoLibraryCatalogSnapshot? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT is_removed, COUNT(*) FROM photo_catalog GROUP BY is_removed;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            var snapshot = PhotoLibraryCatalogSnapshot()
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                let removed = sqlite3_column_int(stmt, 0) != 0
                let count = Int(sqlite3_column_int(stmt, 1))
                snapshot.total += count
                if removed { snapshot.removed += count } else { snapshot.present += count }
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return nil }
            return snapshot
        }
    }

    /// Returns nil when the requested read fails; nil means unknown, not zero (#1004).
    public func count() -> Int? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_catalog;", -1, &stmt, nil) == SQLITE_OK
                )
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return nil }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// True only after a full-library scan finished successfully at least once. A PhotoKit
    /// persistent-change token can exist before our own catalog is complete; this marker prevents
    /// the first real backup pass from mistaking "changed since token" for "entire library known".
    public func hasCompletedFullScan() -> Bool {
        connection.withLock { readInfoValue(Self.completedFullScanKey) == 1 }
    }

    /// Stores the owed scan in the completion marker itself (value 0). An earlier build that reads the marker then
    /// also runs the full scan, and a store without the key keeps its meaning.
    @discardableResult
    public func markFullScanOwed() -> Bool {
        connection.withLock { writeInfoValue(Self.completedFullScanKey, 0) }
    }

    /// A full checkpoint moves every committed transaction from the WAL into the database file and syncs that file;
    /// `checkpoint_fullfsync`, set when the store opens, makes the sync an `F_FULLFSYNC`. A busy or partial checkpoint
    /// returns false.
    public func synchronizeToDisk() -> Bool {
        connection.withLock {
            SQLiteStoreSchemaGate.synchronizeToDisk(db, operationFailed: connection.operationFailed)
        }
    }

    public func hasReconciledLateRenders() -> Bool {
        connection.withLock { readInfoValue(Self.reconciledLateRendersKey) == 1 }
    }

    @discardableResult
    public func markLateRendersReconciled() -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue(Self.reconciledLateRendersKey, 1)
                && deleteInfoValue(Self.lateRenderSweepResumePointKey)
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    public func lateRenderSweepResumePoint() -> String? {
        connection.withLock { readInfoText(Self.lateRenderSweepResumePointKey) }
    }

    @discardableResult
    public func recordLateRenderSweepResumePoint(_ localIdentifier: String) -> Bool {
        connection.withLock { writeInfoText(Self.lateRenderSweepResumePointKey, localIdentifier) }
    }

    public func reconciledMissingSourceGeneration() -> Int64? {
        connection.withLock { readInfoValue64(Self.reconciledMissingSourceGenerationKey) }
    }

    public func missingSourceSweepProgress() -> PhotoLibraryMissingSourceSweepProgress? {
        connection.withLock {
            guard let generation = readInfoValue64(Self.missingSourceSweepGenerationKey) else { return nil }
            return PhotoLibraryMissingSourceSweepProgress(
                generation: generation, afterLocalIdentifier: readInfoText(Self.missingSourceSweepResumePointKey))
        }
    }

    public func recordMissingSourceSweepProgress(_ progress: PhotoLibraryMissingSourceSweepProgress) -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let cursorSaved: Bool
            if let cursor = progress.afterLocalIdentifier {
                cursorSaved = writeInfoText(Self.missingSourceSweepResumePointKey, cursor)
            } else {
                cursorSaved = deleteInfoValue(Self.missingSourceSweepResumePointKey)
            }
            guard cursorSaved, writeInfoValue64(Self.missingSourceSweepGenerationKey, progress.generation),
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    public func completeMissingSourceSweep(generation: Int64) -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            guard writeInfoValue64(Self.reconciledMissingSourceGenerationKey, generation),
                deleteInfoValue(Self.missingSourceSweepGenerationKey),
                deleteInfoValue(Self.missingSourceSweepResumePointKey),
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    /// Throws `SQLiteStoreUnknownReadError` when a value could not be read; nil means no epoch is underway (#1004).
    public func fullScanProgress() throws -> PhotoLibraryFullScanProgress? {
        try connection.withLock {
            guard try readInfoInteger(Self.fullScanSnapshotReadyKey) == 1,
                let bits = try readInfoInteger(Self.fullScanEpochStartKey)
            else { return nil }
            let epochStart = Date(timeIntervalSince1970: Double(bitPattern: UInt64(bitPattern: bits)))
            let cursor = Int(try readInfoInteger(Self.fullScanCursorKey) ?? 0)
            return PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: max(0, cursor))
        }
    }

    @discardableResult
    public func recordFullScanProgress(_ progress: PhotoLibraryFullScanProgress) -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue64(
                    Self.fullScanEpochStartKey,
                    Int64(bitPattern: progress.epochStart.timeIntervalSince1970.bitPattern)
                ) && writeInfoValue64(Self.fullScanCursorKey, Int64(progress.cursor))
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    /// Marks the full scan complete and clears the in-progress epoch. Called by the sync driver only
    /// when a scan actually reaches the end of the library (across however many resumed runs).
    @discardableResult
    public func completeFullScan() -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue(Self.completedFullScanKey, 1)
                && deleteInfoValue(Self.fullScanEpochStartKey)
                && deleteInfoValue(Self.fullScanCursorKey)
                && deleteInfoValue(Self.fullScanSnapshotReadyKey)
                && requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    @discardableResult
    public func clearFullScanResumePoint() -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                deleteInfoValue(Self.fullScanEpochStartKey)
                && deleteInfoValue(Self.fullScanCursorKey)
                && deleteInfoValue(Self.fullScanSnapshotReadyKey)
                && requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    @discardableResult
    public func beginFullScanSnapshot(epochStart: Date) -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
                && writeInfoValue64(
                    Self.fullScanEpochStartKey,
                    Int64(bitPattern: epochStart.timeIntervalSince1970.bitPattern)
                )
                && writeInfoValue64(Self.fullScanCursorKey, 0)
                && writeInfoValue(Self.fullScanSnapshotReadyKey, 0)
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    @discardableResult
    public func appendFullScanSnapshotIdentifiers(_ identifiers: [String]) -> Bool {
        let present = identifiers.filter { !$0.isEmpty }
        guard present.count == identifiers.count else { return false }
        guard !present.isEmpty else { return true }
        return connection.withLock {
            // An unknown count or recorded failure must reject the snapshot, even when later SQL still runs.
            guard var nextPosition = fullScanSnapshotCountLocked(), !connection.operationFailed else { return false }
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "INSERT INTO photo_full_scan_snapshot(position, local_id) VALUES(?, ?);",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            var didWrite = true
            for identifier in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard requireBound([sqlite3_bind_int64(stmt, 1, Int64(nextPosition)), bindText(stmt, 2, identifier)]),
                    requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
                else {
                    didWrite = false
                    break
                }
                nextPosition += 1
            }
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    @discardableResult
    public func finishFullScanSnapshot() -> Bool {
        connection.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue64(Self.fullScanCursorKey, 0)
                && writeInfoValue(Self.fullScanSnapshotReadyKey, 1)
            guard didWrite,
                requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                connection.rollBack()
                return false
            }
            return true
        }
    }

    /// Returns nil when the page could not be read; nil means unknown, not the end of the snapshot (#1004).
    public func fullScanSnapshotIdentifiers(startingAt position: Int, limit: Int) -> [String]? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT local_id FROM photo_full_scan_snapshot WHERE position>=? ORDER BY position LIMIT ?;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard
                requireBound([
                    sqlite3_bind_int64(stmt, 1, Int64(max(0, position))),
                    sqlite3_bind_int(stmt, 2, Int32(max(1, limit))),
                ])
            else { return nil }
            var identifiers: [String] = []
            identifiers.reserveCapacity(max(1, limit))
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let identifier = columnText(stmt, 0) else {
                    connection.markFailed()
                    return nil
                }
                identifiers.append(identifier)
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return nil }
            return identifiers
        }
    }

    /// Returns nil when the read fails. A zero count is only returned when the database answers and has no rows.
    public func fullScanSnapshotCount() -> Int? {
        connection.withLock { fullScanSnapshotCountLocked() }
    }

    private func fullScanSnapshotCountLocked() -> Int? {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_full_scan_snapshot;", -1, &stmt, nil) == SQLITE_OK
            )
        else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Read/write helpers (must be called inside `connection.withLock`)

    private func classifyBatchLocked(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "SELECT content_fingerprint, metadata_revision, is_removed FROM photo_catalog WHERE local_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else {
            // A shorter-than-expected answer fails the caller's completeness check even when a health check has
            // already cleared the recorded transient failure (#1004). The prepared `.changed` values of the old
            // answer could re-open backed-up revisions without a read proving them.
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var results: [PhotoLibraryCatalogChange] = []
        results.reserveCapacity(entries.count)
        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            // An unbound key matches no row and would read as inserted; the shorter answer fails the chunk (#1004).
            guard requireBound(bindText(stmt, 1, entry.localIdentifier)) else { return results }
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE {
                results.append(.inserted)
                continue
            }
            guard result == SQLITE_ROW else {
                // The step's own code keeps a transient BUSY transient. The shorter answer keeps this chunk
                // failing; a classification that no read proved must not re-open backed-up revisions (#1004).
                connection.markFailed(resultCode: sqlite3_extended_errcode(db))
                return results
            }
            if sqlite3_column_int(stmt, 2) != 0 {
                results.append(.changed)
                continue
            }
            results.append(
                sqlite3_column_int64(stmt, 0) == entry.contentFingerprint
                    && sqlite3_column_int64(stmt, 1) == entry.metadataRevision
                    ? .unchanged
                    : .changed
            )
        }
        return results
    }

    private static let upsertSQL = """
        INSERT INTO photo_catalog(
          local_id, cloud_id, creation_date, modification_date, pixel_width, pixel_height,
          duration_seconds, media_kind, is_live_photo, resources_json,
          content_fingerprint, metadata_revision, first_seen_at, last_seen_at,
          is_removed, removed_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,NULL)
        ON CONFLICT(local_id) DO UPDATE SET
          cloud_id=COALESCE(excluded.cloud_id, photo_catalog.cloud_id),
          creation_date=excluded.creation_date,
          modification_date=excluded.modification_date,
          pixel_width=excluded.pixel_width,
          pixel_height=excluded.pixel_height,
          duration_seconds=excluded.duration_seconds,
          media_kind=excluded.media_kind,
          is_live_photo=excluded.is_live_photo,
          resources_json=excluded.resources_json,
          content_fingerprint=excluded.content_fingerprint,
          metadata_revision=excluded.metadata_revision,
          last_seen_at=excluded.last_seen_at,
          is_removed=0,
          removed_at=NULL;
        """

    private func persist(_ entry: PhotoLibraryCatalogEntry, using stmt: OpaquePointer?) -> Bool {
        let resourcesJSON = (try? encoder.encode(entry.resources)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // A failed bind leaves its parameter NULL; a NULL key would still insert a row that names no photo (#1004).
        let bindings = [
            bindText(stmt, 1, entry.localIdentifier),
            bindOptionalText(stmt, 2, entry.cloudIdentifier),
            bindNullableDate(stmt, 3, entry.creationDate),
            bindNullableDate(stmt, 4, entry.modificationDate),
            sqlite3_bind_int(stmt, 5, Int32(entry.pixelWidth)),
            sqlite3_bind_int(stmt, 6, Int32(entry.pixelHeight)),
            sqlite3_bind_double(stmt, 7, entry.durationSeconds),
            bindText(stmt, 8, entry.mediaKind.rawValue),
            // The Live Photo column holds two flags without a schema change: bit 1 is `isLivePhoto` (`.photoLive`), bit 2
            // is `livePlaybackOff`. Photos drops `.photoLive` when the Live effect is off, so such a photo stores 2. An
            // earlier build reads every non-zero value as a Live Photo.
            sqlite3_bind_int(stmt, 9, (entry.isLivePhoto ? 1 : 0) | (entry.livePlaybackOff ? 2 : 0)),
            bindText(stmt, 10, resourcesJSON),
            sqlite3_bind_int64(stmt, 11, entry.contentFingerprint),
            sqlite3_bind_int64(stmt, 12, entry.metadataRevision),
            sqlite3_bind_double(stmt, 13, entry.firstSeenAt.timeIntervalSince1970),
            sqlite3_bind_double(stmt, 14, entry.lastSeenAt.timeIntervalSince1970),
        ]
        guard requireBound(bindings) else { return false }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func readEntry(_ localIdentifier: String) throws -> PhotoLibraryCatalogEntry? {
        guard let db else { throw SQLiteStoreUnknownReadError() }
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    """
                    SELECT cloud_id, creation_date, modification_date, pixel_width, pixel_height, duration_seconds,
                           media_kind, is_live_photo, resources_json, content_fingerprint, metadata_revision,
                           first_seen_at, last_seen_at, is_removed, removed_at
                    FROM photo_catalog WHERE local_id=?;
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { throw SQLiteStoreUnknownReadError() }
        defer { sqlite3_finalize(stmt) }
        try connection.requireReadableBinding(resultCode: bindText(stmt, 1, localIdentifier))
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard requireOperational(result == SQLITE_ROW) else { throw SQLiteStoreUnknownReadError() }
        // An undecodable row is unknown, not absent; the strict read still throws instead of proving absence (#1160).
        // Its own error lets a caller tell the unknown row from a failed read (#1212).
        guard let entry = decodeEntry(stmt, localIdentifier: localIdentifier, valueOffset: 0) else {
            throw PhotoLibraryCatalogUndecodableRowError()
        }
        return entry
    }

    private func decodeEntry(
        _ stmt: OpaquePointer?, localIdentifier: String, valueOffset: Int32
    ) -> PhotoLibraryCatalogEntry? {
        guard let resourcesText = columnText(stmt, valueOffset + 8),
            let resourcesData = resourcesText.data(using: .utf8),
            let resources = try? decoder.decode([PhotoLibraryCatalogResource].self, from: resourcesData),
            let mediaKindRaw = columnText(stmt, valueOffset + 6),
            let mediaKind = PhotoLibraryCatalogMediaKind(rawValue: mediaKindRaw)
        else {
            // Undecodable content is a condition of this row, not of the store: the caller reports the
            // row as unknown for its identifier, and the connection stays operational (#1160).
            return nil
        }
        return PhotoLibraryCatalogEntry(
            localIdentifier: localIdentifier,
            cloudIdentifier: columnText(stmt, valueOffset),
            creationDate: columnDate(stmt, valueOffset + 1),
            modificationDate: columnDate(stmt, valueOffset + 2),
            pixelWidth: Int(sqlite3_column_int(stmt, valueOffset + 3)),
            pixelHeight: Int(sqlite3_column_int(stmt, valueOffset + 4)),
            durationSeconds: sqlite3_column_double(stmt, valueOffset + 5),
            mediaKind: mediaKind,
            isLivePhoto: sqlite3_column_int(stmt, valueOffset + 7) & 1 != 0,
            livePlaybackOff: sqlite3_column_int(stmt, valueOffset + 7) & 2 != 0,
            resources: resources,
            contentFingerprint: sqlite3_column_int64(stmt, valueOffset + 9),
            metadataRevision: sqlite3_column_int64(stmt, valueOffset + 10),
            firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, valueOffset + 11)),
            lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, valueOffset + 12)),
            isRemoved: sqlite3_column_int(stmt, valueOffset + 13) != 0,
            removedAt: columnDate(stmt, valueOffset + 14)
        )
    }

    /// The stored integer, nil when the key has no row. Throws when the value could not be read (#1004).
    private func readInfoInteger(_ key: String) throws -> Int64? {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else { throw SQLiteStoreUnknownReadError() }
        defer { sqlite3_finalize(stmt) }
        try connection.requireReadableBinding(resultCode: bindText(stmt, 1, key))
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard requireOperational(result == SQLITE_ROW) else { throw SQLiteStoreUnknownReadError() }
        return sqlite3_column_int64(stmt, 0)
    }

    /// Markers whose unknown value only causes more work (a rescan or a sweep from the start) read nil on failure.
    private func readInfoValue(_ key: String) -> Int? {
        readInfoValue64(key).map { Int(Int32(truncatingIfNeeded: $0)) }
    }

    @discardableResult
    private func writeInfoValue(_ key: String, _ value: Int) -> Bool {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        guard requireBound([bindText(stmt, 1, key), sqlite3_bind_int(stmt, 2, Int32(value))]) else { return false }
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    // 64-bit info values (the `value` column is INTEGER = 64-bit in SQLite). Used for the resumable
    // full-scan cursor and for the epoch-start instant stored as the exact bit pattern of its Double.
    private func readInfoValue64(_ key: String) -> Int64? {
        (try? readInfoInteger(key)) ?? nil
    }

    @discardableResult
    private func writeInfoValue64(_ key: String, _ value: Int64) -> Bool {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        guard requireBound([bindText(stmt, 1, key), sqlite3_bind_int64(stmt, 2, value)]) else { return false }
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    // Text info values are bound as a BLOB: the `value` column has INTEGER affinity, which would turn a numeric text
    // such as "007" into the integer 7. A BLOB keeps its bytes.
    private func readInfoText(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard requireBound(bindText(stmt, 1, key)) else { return nil }
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard requireOperational(result == SQLITE_ROW), sqlite3_column_type(stmt, 0) == SQLITE_BLOB else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        return String(bytes: Data(bytes: bytes, count: count), encoding: .utf8)
    }

    @discardableResult
    private func writeInfoText(_ key: String, _ value: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        let bytes = Array(value.utf8)
        let valueBinding = bytes.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard requireBound([bindText(stmt, 1, key), valueBinding]) else { return false }
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    @discardableResult
    private func deleteInfoValue(_ key: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            requireOperational(
                sqlite3_prepare_v2(db, "DELETE FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        guard requireBound(bindText(stmt, 1, key)) else { return false }
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    // MARK: - Open / schema (mirrors the other backup stores)

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        openOnce(url: url, policy: policy)
    }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS photo_catalog_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS photo_catalog(
              local_id            TEXT PRIMARY KEY,
              cloud_id            TEXT,
              creation_date       REAL,
              modification_date   REAL,
              pixel_width         INTEGER NOT NULL,
              pixel_height        INTEGER NOT NULL,
              duration_seconds    REAL NOT NULL,
              media_kind          TEXT NOT NULL,
              is_live_photo       INTEGER NOT NULL,
              resources_json      TEXT NOT NULL,
              content_fingerprint INTEGER NOT NULL,
              metadata_revision   INTEGER NOT NULL,
              first_seen_at       REAL NOT NULL,
              last_seen_at        REAL NOT NULL,
              is_removed          INTEGER NOT NULL,
              removed_at          REAL
            );
            CREATE INDEX IF NOT EXISTS photo_catalog_sweep_idx ON photo_catalog(is_removed, last_seen_at);
            CREATE TABLE IF NOT EXISTS photo_full_scan_snapshot(
              position INTEGER PRIMARY KEY,
              local_id TEXT NOT NULL
            );
            """

        return SQLiteStoreSchemaGate.openCurrentStore(
            at: url,
            schemaSQL: schema,
            policy: policy,
            verifyVersion: schemaVersionRow.verify,
            stampVersion: schemaVersionRow.stamp
        )
    }

    // MARK: - Bind/column helpers

    private let transient = SQLiteStoreSchemaGate.transientDestructor

    @discardableResult
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) -> Int32 {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) -> Int32 {
        value.map { bindText(stmt, index, $0) } ?? sqlite3_bind_null(stmt, index)
    }

    private func bindNullableDate(_ stmt: OpaquePointer?, _ index: Int32, _ date: Date?) -> Int32 {
        date.map { sqlite3_bind_double(stmt, index, $0.timeIntervalSince1970) } ?? sqlite3_bind_null(stmt, index)
    }

    /// Call inside `withLock` with a binding call's own result. A failed bind leaves its parameter NULL, so the
    /// statement would answer for no row; the failure is recorded with the binding's code (#1004).
    private func requireBound(_ resultCode: Int32) -> Bool {
        guard resultCode == SQLITE_OK else {
            connection.markFailed(resultCode: resultCode)
            return false
        }
        return true
    }

    private func requireBound(_ resultCodes: [Int32]) -> Bool {
        resultCodes.allSatisfy { requireBound($0) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let text = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: text)
    }

    /// The key column as its exact stored text, or nil when it is not stored as TEXT, is not valid UTF-8, or holds a
    /// NUL byte. Such a key cannot be bound back unchanged as a page cursor, so a pass could never move past it: a
    /// BLOB sorts after every text key and would come back again (#1160, #1212).
    private func exactKeyText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) == SQLITE_TEXT, let text = sqlite3_column_text(stmt, index) else {
            return nil
        }
        let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(stmt, index)))
        guard !bytes.contains(0) else { return nil }
        return String(validating: bytes, as: UTF8.self)
    }

    private func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }
}
