import Foundation
import PhotosCore
import SQLite3

/// Persistent local photo-library catalog (`photo-library-catalog-v1.sqlite`). An incompatible,
/// corrupt, locked, or temporarily unavailable store fails closed and remains untouched. One row per
/// asset `localIdentifier`; resources ride in a single JSON column.
public final class PhotoLibraryCatalogManifestStore: PhotoLibraryCatalogStore, @unchecked Sendable {
    public static let databaseFileName = "photo-library-catalog-v1.sqlite"

    private static let schemaVersion = 3
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

    public func isOperational() -> Bool { connection.isOperational() }

    public func close() { connection.close() }

    public func entry(for localIdentifier: String) -> PhotoLibraryCatalogEntry? {
        connection.withLock { readEntry(localIdentifier) }
    }

    /// Present (not removed) entries for many identifiers with one prepared statement. Missing or removed
    /// identifiers are absent from the result.
    public func presentEntries(for localIdentifiers: [String]) -> [String: PhotoLibraryCatalogEntry] {
        guard !localIdentifiers.isEmpty else { return [:] }
        return connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
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
            else { return [:] }
            defer { sqlite3_finalize(stmt) }
            var result: [String: PhotoLibraryCatalogEntry] = [:]
            result.reserveCapacity(localIdentifiers.count)
            for identifier in localIdentifiers {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, identifier)
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { continue }
                guard connection.requireOperational(step == SQLITE_ROW),
                    let entry = decodeEntry(stmt, localIdentifier: identifier, valueOffset: 0)
                else { return [:] }
                result[identifier] = entry
            }
            return result
        }
    }

    public func presentEntries(afterLocalIdentifier: String?, limit: Int) -> [PhotoLibraryCatalogEntry] {
        let clampedLimit = max(1, limit)
        // The primary-key range keeps pages bounded; the removal index would sort the remaining library per page.
        let frontier = afterLocalIdentifier == nil ? "" : " AND local_id>?"
        return connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
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
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let afterLocalIdentifier { bindText(stmt, 1, afterLocalIdentifier) }
            sqlite3_bind_int(stmt, afterLocalIdentifier == nil ? 1 : 2, Int32(clamping: clampedLimit))
            var entries: [PhotoLibraryCatalogEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let entry = decodeEntry(stmt, localIdentifierColumn: 0, valueOffset: 1) else {
                    connection.markFailed()
                    return []
                }
                entries.append(entry)
                stepResult = sqlite3_step(stmt)
            }
            guard connection.requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return entries
        }
    }

    public func classify(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        classifyBatch([entry]).first ?? .changed
    }

    public func classifyBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        guard !entries.isEmpty else { return [] }
        return connection.withLock { classifyBatchLocked(entries) }
    }

    @discardableResult
    public func upsert(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        connection.withLock {
            let change = classifyBatchLocked([entry]).first ?? .changed
            var stmt: OpaquePointer?
            guard connection.requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK)
            else {
                return change
            }
            defer { sqlite3_finalize(stmt) }
            _ = connection.requireOperational(persist(entry, using: stmt))
            return change
        }
    }

    @discardableResult
    public func upsertBatch(_ entries: [PhotoLibraryCatalogEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return connection.withLock {
            var stmt: OpaquePointer?
            guard connection.requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK)
            else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            var didPersist = true
            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard connection.requireOperational(persist(entry, using: stmt)) else {
                    didPersist = false
                    break
                }
            }
            guard didPersist,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
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
                connection.requireOperational(
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
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            var changed = 0
            for id in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970)
                bindText(stmt, 2, id)
                guard connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
                }
                changed += Int(sqlite3_changes(db))
            }
            guard connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
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
                connection.requireOperational(
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
            sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            return PhotoLibraryCatalogMutationResult(
                affectedRows: Int(sqlite3_changes(db)),
                succeeded: true
            )
        }
    }

    public func snapshot() -> PhotoLibraryCatalogSnapshot {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT is_removed, COUNT(*) FROM photo_catalog GROUP BY is_removed;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return PhotoLibraryCatalogSnapshot() }
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
            guard connection.requireOperational(stepResult == SQLITE_DONE) else { return PhotoLibraryCatalogSnapshot() }
            return snapshot
        }
    }

    public func count() -> Int {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_catalog;", -1, &stmt, nil) == SQLITE_OK
                )
            else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard connection.requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return 0 }
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
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue(Self.reconciledLateRendersKey, 1)
                && deleteInfoValue(Self.lateRenderSweepResumePointKey)
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
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
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let cursorSaved: Bool
            if let cursor = progress.afterLocalIdentifier {
                cursorSaved = writeInfoText(Self.missingSourceSweepResumePointKey, cursor)
            } else {
                cursorSaved = deleteInfoValue(Self.missingSourceSweepResumePointKey)
            }
            guard cursorSaved, writeInfoValue64(Self.missingSourceSweepGenerationKey, progress.generation),
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func completeMissingSourceSweep(generation: Int64) -> Bool {
        connection.withLock {
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            guard writeInfoValue64(Self.reconciledMissingSourceGenerationKey, generation),
                deleteInfoValue(Self.missingSourceSweepGenerationKey),
                deleteInfoValue(Self.missingSourceSweepResumePointKey),
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func fullScanProgress() -> PhotoLibraryFullScanProgress? {
        connection.withLock {
            guard readInfoValue(Self.fullScanSnapshotReadyKey) == 1,
                let bits = readInfoValue64(Self.fullScanEpochStartKey)
            else { return nil }
            let epochStart = Date(timeIntervalSince1970: Double(bitPattern: UInt64(bitPattern: bits)))
            let cursor = Int(readInfoValue64(Self.fullScanCursorKey) ?? 0)
            return PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: max(0, cursor))
        }
    }

    @discardableResult
    public func recordFullScanProgress(_ progress: PhotoLibraryFullScanProgress) -> Bool {
        connection.withLock {
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue64(
                    Self.fullScanEpochStartKey,
                    Int64(bitPattern: progress.epochStart.timeIntervalSince1970.bitPattern)
                ) && writeInfoValue64(Self.fullScanCursorKey, Int64(progress.cursor))
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
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
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue(Self.completedFullScanKey, 1)
                && deleteInfoValue(Self.fullScanEpochStartKey)
                && deleteInfoValue(Self.fullScanCursorKey)
                && deleteInfoValue(Self.fullScanSnapshotReadyKey)
                && connection.requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func clearFullScanResumePoint() -> Bool {
        connection.withLock {
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                deleteInfoValue(Self.fullScanEpochStartKey)
                && deleteInfoValue(Self.fullScanCursorKey)
                && deleteInfoValue(Self.fullScanSnapshotReadyKey)
                && connection.requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func beginFullScanSnapshot(epochStart: Date) -> Bool {
        connection.withLock {
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                connection.requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
                && writeInfoValue64(
                    Self.fullScanEpochStartKey,
                    Int64(bitPattern: epochStart.timeIntervalSince1970.bitPattern)
                )
                && writeInfoValue64(Self.fullScanCursorKey, 0)
                && writeInfoValue(Self.fullScanSnapshotReadyKey, 0)
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
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
            var nextPosition = fullScanSnapshotCountLocked()
            guard !connection.operationFailed else { return false }
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "INSERT INTO photo_full_scan_snapshot(position, local_id) VALUES(?, ?);",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            var didWrite = true
            for identifier in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(nextPosition))
                bindText(stmt, 2, identifier)
                guard connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    didWrite = false
                    break
                }
                nextPosition += 1
            }
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func finishFullScanSnapshot() -> Bool {
        connection.withLock {
            guard connection.requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite =
                writeInfoValue64(Self.fullScanCursorKey, 0)
                && writeInfoValue(Self.fullScanSnapshotReadyKey, 1)
            guard didWrite,
                connection.requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK)
            else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func fullScanSnapshotIdentifiers(startingAt position: Int, limit: Int) -> [String] {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT local_id FROM photo_full_scan_snapshot WHERE position>=? ORDER BY position LIMIT ?;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, position)))
            sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
            var identifiers: [String] = []
            identifiers.reserveCapacity(max(1, limit))
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let identifier = columnText(stmt, 0) else {
                    connection.markFailed()
                    return []
                }
                identifiers.append(identifier)
                stepResult = sqlite3_step(stmt)
            }
            guard connection.requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return identifiers
        }
    }

    public func fullScanSnapshotCount() -> Int {
        connection.withLock { fullScanSnapshotCountLocked() }
    }

    private func fullScanSnapshotCountLocked() -> Int {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_full_scan_snapshot;", -1, &stmt, nil) == SQLITE_OK
            )
        else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard connection.requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Read/write helpers (must be called inside `connection.withLock`)

    private func classifyBatchLocked(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "SELECT content_fingerprint, metadata_revision, is_removed FROM photo_catalog WHERE local_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else {
            return Array(repeating: .changed, count: entries.count)
        }
        defer { sqlite3_finalize(stmt) }

        return entries.map { entry in
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, entry.localIdentifier)
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return .inserted }
            guard result == SQLITE_ROW else {
                connection.markFailed()
                return .changed
            }
            if sqlite3_column_int(stmt, 2) != 0 { return .changed }
            return sqlite3_column_int64(stmt, 0) == entry.contentFingerprint
                && sqlite3_column_int64(stmt, 1) == entry.metadataRevision
                ? .unchanged
                : .changed
        }
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
        bindText(stmt, 1, entry.localIdentifier)
        bindOptionalText(stmt, 2, entry.cloudIdentifier)
        bindNullableDate(stmt, 3, entry.creationDate)
        bindNullableDate(stmt, 4, entry.modificationDate)
        sqlite3_bind_int(stmt, 5, Int32(entry.pixelWidth))
        sqlite3_bind_int(stmt, 6, Int32(entry.pixelHeight))
        sqlite3_bind_double(stmt, 7, entry.durationSeconds)
        bindText(stmt, 8, entry.mediaKind.rawValue)
        // The Live Photo column holds two flags without a schema change: bit 1 is `isLivePhoto` (`.photoLive`), bit 2 is
        // `livePlaybackOff`. Photos drops `.photoLive` when the Live effect is off, so such a photo stores 2. An earlier
        // build reads every non-zero value as a Live Photo.
        sqlite3_bind_int(stmt, 9, (entry.isLivePhoto ? 1 : 0) | (entry.livePlaybackOff ? 2 : 0))
        bindText(stmt, 10, resourcesJSON)
        sqlite3_bind_int64(stmt, 11, entry.contentFingerprint)
        sqlite3_bind_int64(stmt, 12, entry.metadataRevision)
        sqlite3_bind_double(stmt, 13, entry.firstSeenAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 14, entry.lastSeenAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func readEntry(_ localIdentifier: String) -> PhotoLibraryCatalogEntry? {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
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
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, localIdentifier)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard connection.requireOperational(result == SQLITE_ROW) else { return nil }

        return decodeEntry(stmt, localIdentifier: localIdentifier, valueOffset: 0)
    }

    private func decodeEntry(
        _ stmt: OpaquePointer?,
        localIdentifierColumn: Int32? = nil,
        localIdentifier: String? = nil,
        valueOffset: Int32
    ) -> PhotoLibraryCatalogEntry? {
        guard
            let resolvedIdentifier = localIdentifier
                ?? localIdentifierColumn.flatMap({ columnText(stmt, $0) })
        else { return nil }
        guard let resourcesText = columnText(stmt, valueOffset + 8),
            let resourcesData = resourcesText.data(using: .utf8),
            let resources = try? decoder.decode([PhotoLibraryCatalogResource].self, from: resourcesData),
            let mediaKindRaw = columnText(stmt, valueOffset + 6),
            let mediaKind = PhotoLibraryCatalogMediaKind(rawValue: mediaKindRaw)
        else {
            connection.markFailed()
            return nil
        }
        return PhotoLibraryCatalogEntry(
            localIdentifier: resolvedIdentifier,
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

    private func readInfoValue(_ key: String) -> Int? {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard connection.requireOperational(result == SQLITE_ROW) else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    @discardableResult
    private func writeInfoValue(_ key: String, _ value: Int) -> Bool {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        sqlite3_bind_int(stmt, 2, Int32(value))
        return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    // 64-bit info values (the `value` column is INTEGER = 64-bit in SQLite). Used for the resumable
    // full-scan cursor and for the epoch-start instant stored as the exact bit pattern of its Double.
    private func readInfoValue64(_ key: String) -> Int64? {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard connection.requireOperational(result == SQLITE_ROW) else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    @discardableResult
    private func writeInfoValue64(_ key: String, _ value: Int64) -> Bool {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        sqlite3_bind_int64(stmt, 2, value)
        return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    // Text info values are bound as a BLOB: the `value` column has INTEGER affinity, which would turn a numeric text
    // such as "007" into the integer 7. A BLOB keeps its bytes.
    private func readInfoText(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard connection.requireOperational(result == SQLITE_ROW), sqlite3_column_type(stmt, 0) == SQLITE_BLOB else {
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
            connection.requireOperational(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                    -1, &stmt, nil
                ) == SQLITE_OK)
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(stmt, 2, buffer.baseAddress, Int32(buffer.count), transient)
        }
        return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    @discardableResult
    private func deleteInfoValue(_ key: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            connection.requireOperational(
                sqlite3_prepare_v2(db, "DELETE FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
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
            verifyVersion: verifyVersion,
            stampVersion: stampVersion
        )
    }

    private static func verifyVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "SELECT value FROM photo_catalog_info WHERE key='schema';", -1, &stmt, nil)
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
            "INSERT INTO photo_catalog_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: - Bind/column helpers

    private let transient = SQLiteStoreSchemaGate.transientDestructor

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindNullableDate(_ stmt: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date {
            sqlite3_bind_double(stmt, index, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let text = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }
}
