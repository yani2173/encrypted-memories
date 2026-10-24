import Foundation
import PhotosCore
import SQLite3

/// Persistent local-album to Proton-album mapping (`album-sync-mapping-v1.sqlite`). Lives in the
/// per-account data directory next to the upload manifest, so the sign-out purge covers it.
///
/// This is not a rebuildable cache: losing a mapping means the next sync would go through the
/// name-conflict flow again (never silent attach-by-name). An incompatible schema disables sync
/// instead of guessing or deleting this authoritative mapping.
///
/// Stores ids, titles, and counts - never photo names, hashes, or key material. Thread-safe via an
/// internal lock (UI thread reads, sync runner writes).
public final class AlbumSyncMappingStore: @unchecked Sendable {
    public static let databaseFileName = "album-sync-mapping-v1.sqlite"

    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }
    private static let schemaVersion = 1

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        connection = SQLiteStoreConnection(database: handle)
    }

    deinit { close() }

    public func isOperational() -> Bool { connection.isOperational() }

    public func close() { connection.close() }

    // MARK: Open / schema

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        // Album mappings are authoritative state, not a rebuildable cache. A transient open,
        // schema, or I/O failure must disable sync instead of deleting the durable mapping.
        openOnce(url: url, policy: policy)
    }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS mapping_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS album_sync_mapping(
              local_album_id  TEXT PRIMARY KEY,
              remote_album_id TEXT NOT NULL,
              title           TEXT NOT NULL,
              mode            TEXT NOT NULL,
              created_at      REAL NOT NULL,
              last_synced_at  REAL,
              last_attached   INTEGER NOT NULL DEFAULT 0,
              last_failed     INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS album_sync_selection(
              local_album_id  TEXT PRIMARY KEY,
              title           TEXT NOT NULL,
              added_at        REAL NOT NULL
            );
            """

        return SQLiteStoreSchemaGate.openCurrentStore(
            at: url,
            schemaSQL: schema,
            policy: policy,
            includeMemoryTuning: false,
            verifyVersion: verifyVersion,
            stampVersion: stampVersion
        )
    }

    private static func verifyVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(handle, "SELECT value FROM mapping_info WHERE key='schema';", -1, &stmt, nil)
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
            "INSERT INTO mapping_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: API

    public func mapping(localAlbumID: String) -> AlbumSyncMapping? {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT local_album_id, remote_album_id, title, mode, created_at, last_synced_at, last_attached, last_failed "
                            + "FROM album_sync_mapping WHERE local_album_id=?;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localAlbumID, -1, Self.transient)
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return nil }
            guard connection.requireOperational(result == SQLITE_ROW), let mapping = Self.rowToMapping(stmt) else {
                connection.markFailed()
                return nil
            }
            return mapping
        }
    }

    public func allMappings() -> [AlbumSyncMapping] {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT local_album_id, remote_album_id, title, mode, created_at, last_synced_at, last_attached, last_failed "
                            + "FROM album_sync_mapping ORDER BY title;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [AlbumSyncMapping] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let mapping = Self.rowToMapping(stmt) else {
                    connection.markFailed()
                    return []
                }
                result.append(mapping)
                stepResult = sqlite3_step(stmt)
            }
            guard connection.requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return result
        }
    }

    @discardableResult
    public func upsert(_ mapping: AlbumSyncMapping) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        """
                        INSERT INTO album_sync_mapping
                          (local_album_id, remote_album_id, title, mode, created_at, last_synced_at, last_attached, last_failed)
                        VALUES (?,?,?,?,?,?,?,?)
                        ON CONFLICT(local_album_id) DO UPDATE SET
                          remote_album_id=excluded.remote_album_id, title=excluded.title, mode=excluded.mode,
                          last_synced_at=excluded.last_synced_at, last_attached=excluded.last_attached,
                          last_failed=excluded.last_failed;
                        """,
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, mapping.localAlbumID, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, mapping.remoteAlbumID, -1, Self.transient)
            sqlite3_bind_text(stmt, 3, mapping.title, -1, Self.transient)
            sqlite3_bind_text(stmt, 4, mapping.mode.rawValue, -1, Self.transient)
            sqlite3_bind_double(stmt, 5, mapping.createdAt.timeIntervalSinceReferenceDate)
            if let synced = mapping.lastSyncedAt {
                sqlite3_bind_double(stmt, 6, synced.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int64(stmt, 7, Int64(mapping.lastAttachedCount))
            sqlite3_bind_int64(stmt, 8, Int64(mapping.lastFailedCount))
            return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    @discardableResult
    public func removeMapping(localAlbumID: String) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(db, "DELETE FROM album_sync_mapping WHERE local_album_id=?;", -1, &stmt, nil)
                        == SQLITE_OK
                )
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localAlbumID, -1, Self.transient)
            return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    // MARK: Selection (which local albums the user chose to sync)

    /// Deselecting an album removes only the selection row. The album mapping stays, so
    /// re-selecting later reuses the same Proton album without a name-conflict round.
    public func selections() -> [AlbumSyncSelection] {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "SELECT local_album_id, title, added_at FROM album_sync_selection ORDER BY title;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [AlbumSyncSelection] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                    let title = sqlite3_column_text(stmt, 1).map({ String(cString: $0) })
                else {
                    connection.markFailed()
                    return []
                }
                result.append(
                    AlbumSyncSelection(
                        localAlbumID: id,
                        title: title,
                        addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
                    ))
                stepResult = sqlite3_step(stmt)
            }
            guard connection.requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return result
        }
    }

    @discardableResult
    public func addSelection(_ selection: AlbumSyncSelection) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(
                        db,
                        "INSERT INTO album_sync_selection(local_album_id, title, added_at) VALUES (?,?,?) "
                            + "ON CONFLICT(local_album_id) DO UPDATE SET title=excluded.title;",
                        -1, &stmt, nil
                    ) == SQLITE_OK)
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, selection.localAlbumID, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, selection.title, -1, Self.transient)
            sqlite3_bind_double(stmt, 3, selection.addedAt.timeIntervalSinceReferenceDate)
            return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    @discardableResult
    public func removeSelection(localAlbumID: String) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                connection.requireOperational(
                    sqlite3_prepare_v2(db, "DELETE FROM album_sync_selection WHERE local_album_id=?;", -1, &stmt, nil)
                        == SQLITE_OK
                )
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localAlbumID, -1, Self.transient)
            return connection.requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
        }
    }

    // MARK: Row mapping

    private static let transient = SQLiteStoreSchemaGate.transientDestructor

    private static func rowToMapping(_ stmt: OpaquePointer?) -> AlbumSyncMapping? {
        guard let local = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
            let remote = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
            let title = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
            let modeRaw = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
            let mode = AlbumSyncMode(rawValue: modeRaw)
        else {
            return nil
        }
        let created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
        let synced: Date? =
            sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
        return AlbumSyncMapping(
            localAlbumID: local,
            remoteAlbumID: remote,
            title: title,
            mode: mode,
            createdAt: created,
            lastSyncedAt: synced,
            lastAttachedCount: Int(sqlite3_column_int64(stmt, 6)),
            lastFailedCount: Int(sqlite3_column_int64(stmt, 7))
        )
    }
}
