import Foundation
import PhotosCore
import SQLite3

/// Persistent backup execution lock (`backup-execution-lock-v1.sqlite`). One row per named lock.
/// A future, corrupt, locked, or temporarily unavailable store fails closed and preserves ownership.
///
/// Staleness is lease-based: `acquire` treats an existing lock whose `heartbeatAt` is older than
/// `leaseInterval` before `now()` as abandoned and takes it. `recoverStaleLocks(olderThan:)` is the
/// explicit primitive the runner calls before draining so recovery provably precedes the drain.
public final class BackupExecutionLockManifestStore: BackupExecutionLockStore, @unchecked Sendable {
    public static let databaseFileName = "backup-execution-lock-v1.sqlite"
    /// Default lease: a healthy owner heartbeats well inside this; a crashed one is recoverable
    /// after it. Injected so tests and platforms can tune it.
    public static let defaultLeaseInterval: TimeInterval = 120

    private static let schemaVersion = 1
    private let connection: SQLiteStoreConnection
    private var db: OpaquePointer? { connection.database }
    private let lockName: String
    private let leaseInterval: TimeInterval
    private let now: @Sendable () -> Date

    public convenience init?(
        url: URL,
        policy: LibraryDatabasePolicy = .conservative,
        lockName: String = "photoBackup",
        leaseInterval: TimeInterval = defaultLeaseInterval,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        self.init(
            connection: SQLiteStoreConnection(database: handle), lockName: lockName, leaseInterval: leaseInterval,
            now: now)
    }

    /// Takes ownership of an already-verified connection; each store owns its connection exclusively.
    internal init(
        connection: SQLiteStoreConnection,
        lockName: String = "photoBackup",
        leaseInterval: TimeInterval = defaultLeaseInterval,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.connection = connection
        self.lockName = lockName.isEmpty ? "photoBackup" : lockName
        self.leaseInterval = max(1, leaseInterval)
        self.now = now
    }

    deinit { close() }

    public func close() { connection.close() }

    public func currentLock() -> BackupExecutionLock? {
        connection.withLock { readLock() }
    }

    public func acquire(
        owner: BackupExecutionOwner,
        runID: String,
        phase: String?,
        processContext: String?
    ) -> BackupLockAcquisition {
        connection.withLock {
            // The execution lock is durable across store instances and processes, so the read/decide/write
            // sequence must be one SQLite write transaction. An instance-local NSLock alone allows two
            // connections to both observe an empty row and both report acquisition after racing UPSERTs.
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                return .unavailable
            }
            var committed = false
            defer {
                if !committed {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }

            let moment = now()
            switch readLockResult() {
            case .failed:
                return .unavailable
            case .confirmedAbsent:
                break
            case .row(let existing):
                let isOurs = existing.runID == runID
                let isStale = existing.heartbeatAt < moment.addingTimeInterval(-leaseInterval)
                guard isOurs || isStale else {
                    committed = sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
                    return committed ? .busy(existing) : .unavailable
                }
            }
            let taken = BackupExecutionLock(
                owner: owner,
                runID: runID,
                acquiredAt: moment,
                heartbeatAt: moment,
                phase: phase,
                processContext: processContext
            )
            guard writeLock(taken), sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                return .unavailable
            }
            committed = true
            return .acquired(taken)
        }
    }

    @discardableResult
    public func heartbeat(runID: String, phase: String?) -> Bool {
        connection.withLock {
            guard let existing = readLock(), existing.runID == runID else { return false }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "UPDATE backup_execution_lock SET heartbeat_at=?, phase=? WHERE lock_name=? AND run_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now().timeIntervalSince1970)
            bindNullableText(stmt, 2, phase ?? existing.phase)
            bindText(stmt, 3, lockName)
            bindText(stmt, 4, runID)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func release(runID: String) -> Bool {
        connection.withLock {
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM backup_execution_lock WHERE lock_name=? AND run_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, lockName)
            bindText(stmt, 2, runID)
            return sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        }
    }

    @discardableResult
    public func recoverStaleLocks(olderThan cutoff: Date) -> [BackupExecutionLock] {
        connection.withLock {
            guard let existing = readLock(), existing.heartbeatAt < cutoff else { return [] }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM backup_execution_lock WHERE lock_name=? AND heartbeat_at < ?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, lockName)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 else { return [] }
            return [existing]
        }
    }

    /// Recovers a lock left by a previous process on the same platform after an OS kill / force quit.
    ///
    /// Lease-based recovery is still the primary safety net. This narrower recovery only fires when
    /// both process contexts have the expected `platform/pid-N` shape, the platform matches, the PID
    /// differs, and the caller proves that old PID is no longer alive. A live owner is never stolen.
    @discardableResult
    public func recoverAbandonedProcessLocks(
        currentProcessContext: String,
        isProcessAlive: (Int32) -> Bool
    ) -> [BackupExecutionLock] {
        connection.withLock {
            guard let existing = readLock(),
                let old = Self.parseProcessContext(existing.processContext),
                let current = Self.parseProcessContext(currentProcessContext),
                old.platform == current.platform,
                old.pid != current.pid,
                !isProcessAlive(old.pid)
            else {
                return []
            }
            var stmt: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    db,
                    "DELETE FROM backup_execution_lock WHERE lock_name=? AND run_id=?;",
                    -1, &stmt, nil
                ) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, lockName)
            bindText(stmt, 2, existing.runID)
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 else { return [] }
            return [existing]
        }
    }

    // MARK: - Read/write (must be called inside `connection.withLock`)

    private enum LockReadResult {
        case row(BackupExecutionLock)
        case confirmedAbsent
        case failed
    }

    private func readLock() -> BackupExecutionLock? {
        guard case .row(let row) = readLockResult() else { return nil }
        return row
    }

    private func readLockResult() -> LockReadResult {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                SELECT owner, run_id, acquired_at, heartbeat_at, phase, process_context
                FROM backup_execution_lock WHERE lock_name=?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return .failed }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, lockName)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return .confirmedAbsent }
        guard result == SQLITE_ROW else { return .failed }
        return .row(
            BackupExecutionLock(
                owner: BackupExecutionOwner(rawValue: columnText(stmt, 0) ?? BackupExecutionOwner.foreground.rawValue),
                runID: columnText(stmt, 1) ?? "",
                acquiredAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                heartbeatAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                phase: columnText(stmt, 4),
                processContext: columnText(stmt, 5)
            ))
    }

    private func writeLock(_ lock: BackupExecutionLock) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO backup_execution_lock(
                  lock_name, owner, run_id, acquired_at, heartbeat_at, phase, process_context
                ) VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(lock_name) DO UPDATE SET
                  owner=excluded.owner,
                  run_id=excluded.run_id,
                  acquired_at=excluded.acquired_at,
                  heartbeat_at=excluded.heartbeat_at,
                  phase=excluded.phase,
                  process_context=excluded.process_context;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, lockName)
        bindText(stmt, 2, lock.owner.rawValue)
        bindText(stmt, 3, lock.runID)
        sqlite3_bind_double(stmt, 4, lock.acquiredAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, lock.heartbeatAt.timeIntervalSince1970)
        bindNullableText(stmt, 6, lock.phase)
        bindNullableText(stmt, 7, lock.processContext)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: - Open / schema

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        openOnce(url: url, policy: policy)
    }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        let schema = """
            CREATE TABLE IF NOT EXISTS backup_execution_lock_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS backup_execution_lock(
              lock_name       TEXT PRIMARY KEY,
              owner           TEXT NOT NULL,
              run_id          TEXT NOT NULL,
              acquired_at     REAL NOT NULL,
              heartbeat_at    REAL NOT NULL,
              phase           TEXT,
              process_context TEXT
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
            sqlite3_prepare_v2(
                handle, "SELECT value FROM backup_execution_lock_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK
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
            "INSERT INTO backup_execution_lock_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    private static func parseProcessContext(_ raw: String?) -> (platform: String, pid: Int32)? {
        guard let raw,
            let slash = raw.firstIndex(of: "/")
        else { return nil }
        let platform = String(raw[..<slash])
        let suffix = raw[raw.index(after: slash)...]
        guard suffix.hasPrefix("pid-"),
            let pid = Int32(suffix.dropFirst(4)),
            !platform.isEmpty,
            pid > 0
        else { return nil }
        return (platform, pid)
    }

    // MARK: - Bind/column helpers

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
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let text = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: text)
    }
}
