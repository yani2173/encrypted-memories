import Foundation
import OSLog
import SQLite3

/// Classifies an opened SQLite connection before a store applies persistent pragmas or schema DDL.
public enum SQLiteStoreSchemaState: Sendable, Equatable {
    case empty
    case populated
    case unavailable
}

public enum SQLiteStoreSchemaCompatibility: Sendable, Equatable {
    case empty
    case current
    case incompatible
    case unavailable
    /// The check could not finish now, and the file may be fine: another connection holds it for longer than the busy
    /// timeout, or a full disk stopped the check, at the temporary copy or in SQLite itself (see `SQLiteFailure`).
    case retryLater
}

private enum SQLiteStoreOpenResult {
    case opened(OpaquePointer)
    /// The file holds another schema or version.
    case incompatible
    /// The file could not be read, created, or initialized.
    case failed
    /// The file may be fine, but it could not be checked now. See `SQLiteStoreSchemaCompatibility.retryLater`.
    case retryLater
}

/// The result of opening a rebuildable store.
public enum SQLiteRebuildableStoreOutcome {
    case opened(OpaquePointer)
    /// The file stays on disk untouched, and the next open reads it again.
    case retryLater
    case failed
}

/// Exact-schema gate for operational and user-authored stores.
///
/// Existing files are inspected read-only. If that fails, only a temporary copy permits recovery writes.
/// A recovered copy must have no schema objects. A populated database must contain the exact tables,
/// columns, constraints, and indexes produced by this build's schema SQL. This keeps schema changes explicit
/// and prevents markerless or future files from being modified while an older build tries to open them.
public enum SQLiteStoreSchemaGate {
    private static let logger = Logger(subsystem: "at.oncloud.encryptedmemories", category: "SQLiteStore")
    /// `SQLITE_TRANSIENT`: SQLite copies bound text and blobs before the bind call returns.
    public static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// Opens an operational store only when the file is empty or already matches this build's exact schema.
    ///
    /// The file is inspected read-only first. An empty store is created, configured, and stamped; a current store
    /// is verified and configured. Every other state closes the connection and returns `nil` without writing.
    public static func openCurrentStore(
        at url: URL,
        schemaSQL: String,
        policy: LibraryDatabasePolicy,
        includeMemoryTuning: Bool = true,
        verifyVersion: (OpaquePointer?) -> Bool,
        stampVersion: (OpaquePointer?) -> Bool
    ) -> OpaquePointer? {
        guard
            case .opened(let handle) = openStore(
                at: url,
                schemaSQL: schemaSQL,
                policy: policy,
                includeMemoryTuning: includeMemoryTuning,
                verifyVersion: verifyVersion,
                stampVersion: stampVersion
            )
        else { return nil }
        return handle
    }

    /// Opens a rebuildable cache. A file with another schema is deleted together with its WAL and shared-memory
    /// files and created once more. A read, create, or delete failure returns `nil` and leaves the file in place.
    /// A file that cannot be checked now (`retryLater`) also returns `nil` and stays untouched.
    public static func openRebuildableStore(
        at url: URL,
        schemaSQL: String,
        policy: LibraryDatabasePolicy,
        enforceForeignKeys: Bool = false,
        verifyVersion: (OpaquePointer?) -> Bool,
        stampVersion: (OpaquePointer?) -> Bool
    ) -> OpaquePointer? {
        guard
            case .opened(let handle) = openRebuildableStoreOutcome(
                at: url, schemaSQL: schemaSQL, policy: policy, enforceForeignKeys: enforceForeignKeys,
                verifyVersion: verifyVersion, stampVersion: stampVersion)
        else { return nil }
        return handle
    }

    /// Like `openRebuildableStore`, and it tells a file that stays on disk for a later open (`retryLater`) from a
    /// failure that a caller may repair by removing the file.
    public static func openRebuildableStoreOutcome(
        at url: URL,
        schemaSQL: String,
        policy: LibraryDatabasePolicy,
        enforceForeignKeys: Bool = false,
        verifyVersion: (OpaquePointer?) -> Bool,
        stampVersion: (OpaquePointer?) -> Bool,
        copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        createDirectory: ((URL) throws -> Void)? = nil,
        probe: SQLiteFailureProbe = .live
    ) -> SQLiteRebuildableStoreOutcome {
        func open() -> SQLiteStoreOpenResult {
            openStore(
                at: url,
                schemaSQL: schemaSQL,
                policy: policy,
                enforceForeignKeys: enforceForeignKeys,
                verifyVersion: verifyVersion,
                stampVersion: stampVersion,
                copyItem: copyItem,
                createDirectory: createDirectory,
                probe: probe
            )
        }
        switch open() {
        case .opened(let handle):
            return .opened(handle)
        case .failed:
            return .failed
        case .retryLater:
            return .retryLater
        case .incompatible:
            guard removeDatabaseFiles(at: url), case .opened(let handle) = open() else { return .failed }
            return .opened(handle)
        }
    }

    /// Removes a database file and its `-wal` and `-shm` files. Missing files count as removed.
    public static func removeDatabaseFiles(at url: URL) -> Bool {
        guard !url.hasDirectoryPath else { return false }
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                return false
            }
        }
        return true
    }

    /// The one open sequence for every store: read-only inspection, read-write open, busy timeout, optional
    /// foreign keys, then either schema creation or exact verification, and connection tuning.
    private static func openStore(
        at url: URL,
        schemaSQL: String,
        policy: LibraryDatabasePolicy,
        includeMemoryTuning: Bool = true,
        enforceForeignKeys: Bool = false,
        verifyVersion: (OpaquePointer?) -> Bool,
        stampVersion: (OpaquePointer?) -> Bool,
        copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        createDirectory: ((URL) throws -> Void)? = nil,
        probe: SQLiteFailureProbe = .live
    ) -> SQLiteStoreOpenResult {
        let compatibility = compatibility(
            at: url,
            schemaSQL: schemaSQL,
            busyTimeoutMs: policy.busyTimeoutMs,
            versionIsCurrent: verifyVersion,
            copyItem: copyItem,
            createDirectory: createDirectory,
            probe: probe
        )
        guard compatibility != .incompatible else { return .incompatible }
        guard compatibility != .unavailable else { return .failed }
        guard compatibility != .retryLater else { return .retryLater }
        var opened: OpaquePointer?
        let flags =
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            | (compatibility == .empty ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let handle = opened else {
            sqlite3_close(opened)
            return .failed
        }
        // The verification below waits as long as the busy timeout and tells a lock from another schema.
        let busy = SQLiteBusyRecorder(timeoutMs: policy.busyTimeoutMs)
        busy.install(on: handle)
        if enforceForeignKeys {
            sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        }
        switch compatibility {
        case .empty:
            configureConnection(handle, policy: policy, includeMemoryTuning: includeMemoryTuning)
            guard
                initializeCurrentSchema(
                    handle,
                    schemaSQL: schemaSQL,
                    stamp: { stampVersion(handle) }
                )
            else {
                sqlite3_close(handle)
                return .failed
            }
        case .current:
            guard verifyVersion(handle),
                matchesCurrentSchema(handle, schemaSQL: schemaSQL)
            else {
                // A lock that did not clear, or a failure that says nothing about the file, keeps it. The probe reads
                // the failure and then closes the connection.
                let keepsFile = probe.keepsFile(closing: handle, step: .verification)
                return keepsFile || busy.gaveUp ? .retryLater : .incompatible
            }
            configureConnection(handle, policy: policy, includeMemoryTuning: includeMemoryTuning)
        case .incompatible:
            sqlite3_close(handle)
            return .incompatible
        case .unavailable, .retryLater:
            sqlite3_close(handle)
            return .failed
        }
        return .opened(handle)
    }

    /// Inspects an existing database through a read-only connection. Missing files are empty stores.
    /// If inspection fails, a read-write inspection of a temporary copy can prove the recovered database empty.
    /// Populated or unreadable copies remain unavailable; recovery never modifies the original during inspection.
    public static func compatibility(
        at url: URL,
        schemaSQL: String,
        busyTimeoutMs: Int = 5_000,
        versionIsCurrent: (OpaquePointer?) -> Bool,
        copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        createDirectory: ((URL) throws -> Void)? = nil,
        probe: SQLiteFailureProbe = .live
    ) -> SQLiteStoreSchemaCompatibility {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        var inspection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &inspection, flags, nil) == SQLITE_OK,
            let inspection
        else {
            sqlite3_close(inspection)
            return compatibilityOfWritableCopy(
                at: url, busyTimeoutMs: busyTimeoutMs, copyItem: copyItem, createDirectory: createDirectory,
                probe: probe)
        }
        defer { sqlite3_close(inspection) }
        // A statement that meets a lock waits as long as the busy timeout. If the lock stays, no answer of this
        // inspection is reliable: the file may be fine, and the caller must not replace it.
        let busy = SQLiteBusyRecorder(timeoutMs: busyTimeoutMs)
        busy.install(on: inspection)
        // A failure that says nothing about the file, such as a full disk, ends the inspection the same way. SQLite
        // keeps the failure only until the next call, so each check below reads it right after the failed read.
        func keepsFile() -> Bool { busy.gaveUp || probe.keepsFile(after: inspection, step: .inspection) }
        switch state(of: inspection) {
        case .empty:
            guard let version = userVersion(of: inspection) else { return busy.gaveUp ? .retryLater : .unavailable }
            if busy.gaveUp { return .retryLater }
            return version == 0 ? .empty : .incompatible
        case .populated:
            let current =
                versionIsCurrent(inspection)
                && matchesCurrentSchema(inspection, schemaSQL: schemaSQL)
            if current { return busy.gaveUp ? .retryLater : .current }
            return keepsFile() ? .retryLater : .incompatible
        case .unavailable:
            if keepsFile() { return .retryLater }
            return compatibilityOfWritableCopy(
                at: url, busyTimeoutMs: busyTimeoutMs, copyItem: copyItem, createDirectory: createDirectory,
                probe: probe)
        }
    }

    /// The private directory of a recovery inspection. A test passes its own `createDirectory` to simulate a full disk.
    private static func createInspectionDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    /// A read-write schema read can roll back a hot journal. Preserve the original and all its sidecars,
    /// even when recovery finds a populated database that this build must refuse to open.
    private static func compatibilityOfWritableCopy(
        at url: URL,
        busyTimeoutMs: Int,
        copyItem: (URL, URL) throws -> Void,
        createDirectory: ((URL) throws -> Void)?,
        probe: SQLiteFailureProbe
    ) -> SQLiteStoreSchemaCompatibility {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteStoreInspection-\(UUID().uuidString)", isDirectory: true)
        do {
            try (createDirectory ?? Self.createInspectionDirectory)(directory)
        } catch {
            logger.error("SQLite could not create its temporary recovery inspection.")
            // A full disk says nothing about the file, so it stays. Any other failure keeps its earlier meaning.
            return DeviceStorage.isOutOfSpace(error) ? .retryLater : .unavailable
        }

        var compatibility = SQLiteStoreSchemaCompatibility.unavailable
        do {
            let copy = directory.appendingPathComponent("store.sqlite")
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let original = URL(fileURLWithPath: url.path + suffix)
                if suffix.isEmpty || FileManager.default.fileExists(atPath: original.path) {
                    try copyItem(original, URL(fileURLWithPath: copy.path + suffix))
                }
            }
            compatibility = emptyCompatibility(at: copy, busyTimeoutMs: busyTimeoutMs, probe: probe)
        } catch {
            logger.error("SQLite could not copy the database and journals for recovery inspection.")
            // A full disk says nothing about the file, so it stays. An unreadable file keeps its earlier meaning.
            compatibility = DeviceStorage.isOutOfSpace(error) ? .retryLater : .unavailable
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error("SQLite could not remove its temporary recovery inspection.")
            return .unavailable
        }
        return compatibility
    }

    private static func emptyCompatibility(
        at url: URL, busyTimeoutMs: Int, probe: SQLiteFailureProbe
    ) -> SQLiteStoreSchemaCompatibility {
        var inspection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &inspection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            let inspection
        else {
            sqlite3_close(inspection)
            return .unavailable
        }
        defer { sqlite3_close(inspection) }
        sqlite3_busy_timeout(inspection, Int32(clamping: busyTimeoutMs))
        // A failure that says nothing about the file, such as a full disk, keeps it. Each return below reads the
        // failure right after the failed call.
        func unavailable() -> SQLiteStoreSchemaCompatibility {
            probe.keepsFile(after: inspection, step: .copy) ? .retryLater : .unavailable
        }
        // Include SQLite's own objects, such as sqlite_sequence. Any remaining object forbids initialization.
        guard userVersion(of: inspection) == 0 else { return unavailable() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(inspection, "SELECT 1 FROM sqlite_schema LIMIT 1;", -1, &statement, nil) == SQLITE_OK
        else {
            return unavailable()
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE ? .empty : unavailable()
    }

    /// Applies connection-local tuning only after the caller accepts the existing schema.
    public static func configureConnection(
        _ db: OpaquePointer?,
        policy: LibraryDatabasePolicy,
        includeMemoryTuning: Bool = true
    ) {
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        let usesWAL = pragmaValue("journal_mode", in: db) == "wal"
        // EXTRA also syncs the containing directory after deleting a rollback journal. FULL alone does not guarantee
        // power-loss durability in DELETE mode (https://www.sqlite.org/pragma.html#pragma_synchronous).
        if !usesWAL { logger.warning("WAL unavailable; using durable rollback-journal commits.") }
        let sync = usesWAL ? "NORMAL" : "EXTRA"
        if sqlite3_exec(db, "PRAGMA synchronous=\(sync);", nil, nil, nil) != SQLITE_OK
            || sqlite3_exec(db, "PRAGMA fullfsync=\(usesWAL ? "OFF" : "ON");", nil, nil, nil) != SQLITE_OK
        {
            logger.error("SQLite refused the commit synchronization settings.")
        }
        var pragmas = [
            "PRAGMA busy_timeout=\(policy.busyTimeoutMs);",
            "PRAGMA journal_size_limit=\(policy.journalSizeLimitBytes);",
        ]
        if includeMemoryTuning {
            pragmas.append("PRAGMA cache_size=-\(max(0, policy.cacheSizeKiB));")
            pragmas.append("PRAGMA mmap_size=\(max(0, policy.mmapBytes));")
        }
        for pragma in pragmas {
            sqlite3_exec(db, pragma, nil, nil, nil)
        }
    }

    /// Makes every checkpoint of the connection sync with `F_FULLFSYNC`, automatic checkpoints included. The flag
    /// belongs to the connection, so each open sets it again.
    public static func enableFullSyncCheckpoints(_ db: OpaquePointer?) {
        sqlite3_exec(db, "PRAGMA checkpoint_fullfsync=ON;", nil, nil, nil)
    }

    /// Runs `body` with commits that survive a power loss, then restores the connection's previous settings.
    /// In WAL mode, `synchronous=FULL` syncs the WAL after each commit, and `fullfsync` makes that sync an
    /// `F_FULLFSYNC` on Apple platforms (https://www.sqlite.org/pragma.html#pragma_synchronous). The caller holds the
    /// lock of its connection and calls this outside a transaction: SQLite refuses the change inside one. Returns nil
    /// without running `body` when the connection refuses the setting.
    public static func withDurableCommits<T>(_ db: OpaquePointer?, _ body: () throws -> T) rethrows -> T? {
        guard let synchronous = pragmaValue("synchronous", in: db).flatMap(Int.init),
            let fullfsync = pragmaValue("fullfsync", in: db).flatMap(Int.init),
            sqlite3_exec(db, "PRAGMA synchronous=\(max(2, synchronous));", nil, nil, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_exec(db, "PRAGMA synchronous=\(synchronous);", nil, nil, nil) }
        guard sqlite3_exec(db, "PRAGMA fullfsync=ON;", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(db, "PRAGMA fullfsync=\(fullfsync);", nil, nil, nil) }
        return try body()
    }

    /// Synchronizes an operational store while its caller holds the connection lock. A closed or failed store
    /// cannot prove that its data is durable.
    public static func synchronizeToDisk(_ db: OpaquePointer?, operationFailed: Bool) -> Bool {
        guard let db, !operationFailed else { return false }
        return checkpointCompletely(db)
    }

    /// Copies every committed transaction from the WAL into the database file and syncs that file (a FULL
    /// checkpoint). Rollback-journal commits need no checkpoint when their connection already commits durably.
    /// A busy, partial, or failed checkpoint returns false.
    public static func checkpointCompletely(_ db: OpaquePointer?) -> Bool {
        guard let db, let journal = pragmaValue("journal_mode", in: db), sqlite3_get_autocommit(db) != 0 else {
            logger.error("SQLite synchronization failed: no readable connection or an open transaction.")
            return false
        }
        if journal != "wal" {
            guard ["delete", "truncate", "persist"].contains(journal),
                let synchronous = pragmaValue("synchronous", in: db).flatMap(Int.init), synchronous >= 2,
                pragmaValue("fullfsync", in: db) == "1"
            else {
                logger.error("SQLite synchronization failed: non-WAL commits are not durable.")
                return false
            }
            // Rollback-journal commits already sync the database. There is no WAL to checkpoint.
            return true
        }
        var logFrames: Int32 = -1
        var checkpointedFrames: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_FULL, &logFrames, &checkpointedFrames)
        guard result == SQLITE_OK && logFrames >= 0 && logFrames == checkpointedFrames else {
            logger.error(
                "SQLite synchronization failed: checkpoint result \(result), frames \(checkpointedFrames)/\(logFrames)."
            )
            return false
        }
        return true
    }

    private static func pragmaValue(_ name: String, in db: OpaquePointer?) -> String? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    public static func state(of db: OpaquePointer?) -> SQLiteStoreSchemaState {
        guard let objects = schemaObjects(in: db) else { return .unavailable }
        return objects.isEmpty ? .empty : .populated
    }

    private static func userVersion(of db: OpaquePointer?) -> Int32? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0)
    }

    public static func matchesCurrentSchema(
        _ db: OpaquePointer?,
        schemaSQL: String
    ) -> Bool {
        var reference: OpaquePointer?
        guard sqlite3_open(":memory:", &reference) == SQLITE_OK, let reference else {
            sqlite3_close(reference)
            return false
        }
        defer { sqlite3_close(reference) }
        guard sqlite3_exec(reference, schemaSQL, nil, nil, nil) == SQLITE_OK,
            let expectedObjects = schemaObjects(in: reference),
            let actualObjects = schemaObjects(in: db),
            expectedObjects == actualObjects
        else { return false }

        for object in expectedObjects where object.type == "table" {
            guard let expected = tableSignature(in: reference, named: object.name),
                let actual = tableSignature(in: db, named: object.name),
                expected == actual
            else { return false }
        }
        return true
    }

    /// Creates and stamps a new schema as one transaction. The caller must first prove that `db` is empty.
    public static func initializeCurrentSchema(
        _ db: OpaquePointer?,
        schemaSQL: String,
        stamp: () -> Bool
    ) -> Bool {
        guard state(of: db) == .empty,
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
        else { return false }

        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        }
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK,
            stamp(),
            matchesCurrentSchema(db, schemaSQL: schemaSQL),
            sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
        else { return false }
        committed = true
        return true
    }

    private struct SchemaObject: Equatable {
        let type: String
        let name: String
        let tableName: String
        let canonicalSQL: String?
    }

    private struct TableSignature: Equatable {
        let metadata: TableMetadata
        let columns: [Column]
        let indexes: [Index]
        let foreignKeys: [ForeignKey]
    }

    private struct TableMetadata: Equatable {
        let type: String
        let columnCount: Int32
        let withoutRowID: Bool
        let strict: Bool
    }

    private struct Column: Equatable {
        let identifier: Int32
        let name: String
        let declaredType: String
        let isNotNull: Bool
        let defaultValue: String?
        let primaryKeyPosition: Int32
        let hidden: Int32
    }

    private struct Index: Equatable {
        let name: String
        let isUnique: Bool
        let origin: String
        let isPartial: Bool
        let columns: [IndexColumn]
    }

    private struct IndexColumn: Equatable {
        let sequence: Int32
        let columnIdentifier: Int32
        let name: String?
        let descending: Bool
        let collation: String?
        let isKey: Bool
    }

    private struct ForeignKey: Equatable {
        let identifier: Int32
        let sequence: Int32
        let table: String
        let from: String
        let to: String?
        let onUpdate: String
        let onDelete: String
        let match: String
    }

    private static func schemaObjects(in db: OpaquePointer?) -> [SchemaObject]? {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT type, name, tbl_name, sql FROM sqlite_schema "
                    + "WHERE type IN ('table','index','view','trigger') AND name NOT LIKE 'sqlite_%' "
                    + "ORDER BY type, name, tbl_name;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }

        var objects: [SchemaObject] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let type = text(statement, 0),
                let name = text(statement, 1),
                let tableName = text(statement, 2)
            else { return nil }
            objects.append(
                SchemaObject(
                    type: type,
                    name: name,
                    tableName: tableName,
                    canonicalSQL: text(statement, 3).map(canonicalSQL)
                )
            )
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? objects : nil
    }

    private static func tableSignature(in db: OpaquePointer?, named table: String) -> TableSignature? {
        guard let metadata = tableMetadata(in: db, named: table),
            let columns = columns(in: db, table: table),
            let indexes = indexes(in: db, table: table),
            let foreignKeys = foreignKeys(in: db, table: table)
        else { return nil }
        return TableSignature(
            metadata: metadata,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys
        )
    }

    private static func tableMetadata(in db: OpaquePointer?, named table: String) -> TableMetadata? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_list;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if text(statement, 1) == table {
                guard let type = text(statement, 2) else { return nil }
                return TableMetadata(
                    type: type,
                    columnCount: sqlite3_column_int(statement, 3),
                    withoutRowID: sqlite3_column_int(statement, 4) != 0,
                    strict: sqlite3_column_int(statement, 5) != 0
                )
            }
            result = sqlite3_step(statement)
        }
        return nil
    }

    private static func columns(in db: OpaquePointer?, table: String) -> [Column]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_xinfo(\(literal(table)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var columns: [Column] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = text(statement, 1), let declaredType = text(statement, 2) else { return nil }
            columns.append(
                Column(
                    identifier: sqlite3_column_int(statement, 0),
                    name: name,
                    declaredType: declaredType,
                    isNotNull: sqlite3_column_int(statement, 3) != 0,
                    defaultValue: text(statement, 4),
                    primaryKeyPosition: sqlite3_column_int(statement, 5),
                    hidden: sqlite3_column_int(statement, 6)
                ))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? columns : nil
    }

    private static func indexes(in db: OpaquePointer?, table: String) -> [Index]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA index_list(\(literal(table)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var indexes: [Index] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let name = text(statement, 1),
                let origin = text(statement, 3),
                let columns = indexColumns(in: db, index: name)
            else { return nil }
            indexes.append(
                Index(
                    name: name,
                    isUnique: sqlite3_column_int(statement, 2) != 0,
                    origin: origin,
                    isPartial: sqlite3_column_int(statement, 4) != 0,
                    columns: columns
                ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return nil }
        return indexes.sorted { $0.name < $1.name }
    }

    private static func indexColumns(in db: OpaquePointer?, index: String) -> [IndexColumn]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA index_xinfo(\(literal(index)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var columns: [IndexColumn] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            columns.append(
                IndexColumn(
                    sequence: sqlite3_column_int(statement, 0),
                    columnIdentifier: sqlite3_column_int(statement, 1),
                    name: text(statement, 2),
                    descending: sqlite3_column_int(statement, 3) != 0,
                    collation: text(statement, 4),
                    isKey: sqlite3_column_int(statement, 5) != 0
                ))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? columns : nil
    }

    private static func foreignKeys(in db: OpaquePointer?, table: String) -> [ForeignKey]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_list(\(literal(table)));", -1, &statement, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var keys: [ForeignKey] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let targetTable = text(statement, 2),
                let from = text(statement, 3),
                let onUpdate = text(statement, 5),
                let onDelete = text(statement, 6),
                let match = text(statement, 7)
            else { return nil }
            keys.append(
                ForeignKey(
                    identifier: sqlite3_column_int(statement, 0),
                    sequence: sqlite3_column_int(statement, 1),
                    table: targetTable,
                    from: from,
                    to: text(statement, 4),
                    onUpdate: onUpdate,
                    onDelete: onDelete,
                    match: match
                ))
            result = sqlite3_step(statement)
        }
        return result == SQLITE_DONE ? keys : nil
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
            let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// SQLite preserves schema SQL text. Normalize only insignificant unquoted whitespace and ASCII case.
    /// Quoted identifiers and literals remain byte-exact, so CHECK clauses and trigger bodies cannot drift.
    private static func canonicalSQL(_ sql: String) -> String {
        let scalars = Array(sql.unicodeScalars)
        var result = String.UnicodeScalarView()
        var quoteEnd: Unicode.Scalar?
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if let activeQuoteEnd = quoteEnd {
                result.append(scalar)
                if scalar == activeQuoteEnd {
                    if index + 1 < scalars.count, scalars[index + 1] == activeQuoteEnd {
                        result.append(scalars[index + 1])
                        index += 1
                    } else {
                        quoteEnd = nil
                    }
                }
            } else if scalar == "'" || scalar == "\"" || scalar == "`" {
                quoteEnd = scalar
                result.append(scalar)
            } else if scalar == "[" {
                quoteEnd = "]"
                result.append(scalar)
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if scalar.value >= 65, scalar.value <= 90,
                    let lower = Unicode.Scalar(scalar.value + 32)
                {
                    result.append(lower)
                } else {
                    result.append(scalar)
                }
            }
            index += 1
        }
        return String(result)
    }
}
