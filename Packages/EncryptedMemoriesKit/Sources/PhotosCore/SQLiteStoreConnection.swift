import Foundation
import SQLite3

/// The one implementation that binds TEXT and BLOB values for the SQLite stores (#1194). It returns the bind's own
/// result code. A failed bind leaves its parameter NULL, so a caller that steps anyway reads "no row" or stores NULL:
/// check the result, or use `SQLiteStoreConnection.bindText` and `bindBlob`, which record the failure and throw.
public enum SQLiteBinding {
    /// Binds `value` as TEXT, or SQL NULL for nil. SQLite copies the text before the call returns.
    public static func text(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) -> Int32 {
        guard let value else { return sqlite3_bind_null(statement, index) }
        return sqlite3_bind_text(statement, index, value, -1, SQLiteStoreSchemaGate.transientDestructor)
    }

    /// Binds `value` as a BLOB, or SQL NULL for nil. SQLite copies the bytes before the call returns.
    public static func blob(_ statement: OpaquePointer?, _ index: Int32, _ value: Data?) -> Int32 {
        guard let value else { return sqlite3_bind_null(statement, index) }
        return value.withUnsafeBytes { bytes in
            sqlite3_bind_blob64(
                statement, index, bytes.baseAddress, sqlite3_uint64(bytes.count),
                SQLiteStoreSchemaGate.transientDestructor)
        }
    }
}

/// Owns an already-verified store handle. Opening and connection tuning stay in SQLiteStoreSchemaGate.
/// Access the handle and failure state only inside `withLock`. Finalize each statement before that closure returns.
/// `close` and `isOperational` take the same nonrecursive lock; do not call them inside `withLock`.
public final class SQLiteStoreConnection: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var database: OpaquePointer?
    public private(set) var operationFailed = false
    /// False once a recorded failure was not transient, see `transientResultCodes`.
    public private(set) var failuresAreTransient = true
    /// Every failure recorded on this connection, also the ones that a recovering health check forgot since.
    private var failuresRecorded: UInt64 = 0
    private let optimizesOnClose: Bool

    /// The primary SQLite result codes after which the same call can succeed when it runs again: the database was
    /// busy or locked, memory or disk space ran out, an I/O call failed, or the call was interrupted. Every other code,
    /// for example a corrupt database, a file that is no database, a read-only file, a schema change, a constraint or a
    /// misuse, and an unknown cause mean that the database itself may be wrong.
    public static let transientResultCodes: Set<Int32> = [
        SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_INTERRUPT, SQLITE_IOERR, SQLITE_FULL,
    ]
    /// Extended I/O codes that report damaged data, not a passing failure: SQLITE_IOERR_DATA and
    /// SQLITE_IOERR_CORRUPTFS.
    public static let corruptionResultCodes: Set<Int32> = [SQLITE_IOERR | (32 << 8), SQLITE_IOERR | (33 << 8)]

    /// Set optimizesOnClose to false only to preserve a store that never ran `PRAGMA optimize` on close.
    public init(database: OpaquePointer, optimizesOnClose: Bool = true) {
        self.database = database
        self.optimizesOnClose = optimizesOnClose
    }

    deinit { close() }

    public func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try lock.withLock(body)
    }

    /// Call inside `withLock`. A lasting failure stays recorded for the lifetime of this connection. A transient one
    /// stays recorded until `isOperationalAfterRecovery()` or `isOperationalAfterTransientFailure()` finds the
    /// database answering again.
    public func markFailed() {
        markFailed(resultCode: nil)
    }

    /// Call inside `withLock` with the result code of the failed call, extended or primary; nil for an unknown cause.
    public func markFailed(resultCode: Int32?) {
        operationFailed = true
        failuresRecorded &+= 1
        let transient = resultCode.map {
            Self.transientResultCodes.contains($0 & 0xFF) && !Self.corruptionResultCodes.contains($0)
        }
        if transient != true { failuresAreTransient = false }
    }

    /// Call inside `withLock` with a binding call's own result. A failed bind must not turn a key into SQL NULL.
    public func requireReadableBinding(resultCode: Int32) throws {
        guard resultCode == SQLITE_OK else {
            markFailed(resultCode: resultCode)
            throw SQLiteStoreUnknownReadError()
        }
    }

    /// Call inside `withLock`. Binds TEXT, or SQL NULL for nil, through `SQLiteBinding` (#1194). A failed bind is
    /// recorded with its own code and throws `SQLiteStoreUnknownReadError`, for a read and for a write alike: the
    /// caller must not step the statement.
    public func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        try requireReadableBinding(resultCode: SQLiteBinding.text(statement, index, value))
    }

    /// Call inside `withLock`. Binds a BLOB, or SQL NULL for nil, as `bindText` binds TEXT (#1194).
    public func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ value: Data?) throws {
        try requireReadableBinding(resultCode: SQLiteBinding.blob(statement, index, value))
    }

    /// Call inside `withLock`. Ends the open transaction. Only a transaction that stays open records a failure: after a
    /// full disk, an I/O error, an interrupt or no memory, SQLite can roll back on its own, and the explicit rollback
    /// then fails without harm.
    public func rollBack() {
        guard let database else { return }
        let rollback = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
        if sqlite3_get_autocommit(database) == 0 {
            markFailed(resultCode: rollback == SQLITE_OK ? nil : sqlite3_extended_errcode(database))
        }
    }

    /// Records an unknown-cause predicate under `withLock`. A successful predicate still requires an open handle.
    /// Use `requireOperationalRecordingSQLiteError` when the failed SQLite call's code must be retained.
    /// A prior failure does not change a later successful predicate.
    /// The operational probe remains false after any recorded failure.
    @discardableResult
    public func requireOperational(_ condition: Bool) -> Bool {
        let succeeded = database != nil && condition
        if !succeeded { markFailed() }
        return succeeded
    }

    /// Records a predicate under `withLock` with the failed SQLite call's current extended code.
    /// Preserves the supplied condition, including a true condition after close, and never clears a prior failure.
    @discardableResult
    public func requireOperationalRecordingSQLiteError(_ condition: Bool) -> Bool {
        if !condition, let database {
            markFailed(resultCode: sqlite3_extended_errcode(database))
        } else if !condition {
            markFailed()
        }
        return condition
    }

    public func isOperational() -> Bool { isOperational(probeDatabase: true) }

    /// How many failures this connection recorded so far. A caller that compares two counts learns whether a failure
    /// happened in between, also after a recovering health check forgot it.
    public func recordedFailureCount() -> UInt64 { withLock { failuresRecorded } }

    /// Set probeDatabase to false only to preserve a store's existing state-only operational check.
    public func isOperational(probeDatabase: Bool) -> Bool {
        withLock {
            guard database != nil, !operationFailed else { return false }
            guard probeDatabase else { return true }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT 1;", -1, &statement, nil) == SQLITE_OK else {
                markFailed()
                return false
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                markFailed()
                return false
            }
            return true
        }
    }

    /// For a store whose transient failure stops it only until the database answers again. A transaction that a
    /// failed rollback left open stops the store. After recorded failures that were all transient, reads a page of the
    /// database and forgets the failures when it answers. Each call still fails on its own. Any other failure, and a
    /// closed connection, stay recorded.
    public func isOperationalAfterRecovery() -> Bool {
        withLock {
            guard database != nil else { return false }
            guard sqlite3_get_autocommit(database) != 0 else { return false }
            guard operationFailed else { return true }
            guard failuresAreTransient else { return false }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_schema;", -1, &statement, nil) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_ROW
            else { return false }
            operationFailed = false
            return true
        }
    }

    /// The health probe for stores that must survive transient failures (#1004): a probe failure records its code like
    /// `isOperational()`, and a successful probe forgets earlier failures only when they were all transient. An open
    /// transaction stays false via the autocommit check; a closed connection stays false. Unlike
    /// `isOperationalAfterRecovery()`, this probe records what it sees, because a restored denied SELECT must not
    /// clear the recorded failure (`testQueueHealthProbeRecordsDeniedSelect`).
    ///
    /// The probe must read the database file. A constant `SELECT 1` compiles to a program that opens no read
    /// transaction and reads no page, so it succeeds while every real read still fails with BUSY or IOERR. Reading
    /// `sqlite_schema` proves the file answers before the recorded transient failure is forgotten.
    public func isOperationalAfterTransientFailure() -> Bool {
        withLock {
            guard database != nil else { return false }
            guard sqlite3_get_autocommit(database) != 0 else { return false }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_schema;", -1, &statement, nil) == SQLITE_OK,
                sqlite3_step(statement) == SQLITE_ROW
            else {
                markFailed(resultCode: sqlite3_extended_errcode(database))
                return false
            }
            if operationFailed {
                guard failuresAreTransient else { return false }
                operationFailed = false
            }
            return true
        }
    }

    public func close() {
        withLock {
            guard database != nil else { return }
            if optimizesOnClose { sqlite3_exec(database, "PRAGMA optimize;", nil, nil, nil) }
            sqlite3_close(database)
            database = nil
        }
    }
}
