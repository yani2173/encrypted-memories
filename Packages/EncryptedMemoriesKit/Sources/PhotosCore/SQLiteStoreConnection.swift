import Foundation
import SQLite3

/// Owns an already-verified store handle. Opening and connection tuning stay in SQLiteStoreSchemaGate.
/// Access the handle and failure state only inside `withLock`. Finalize each statement before that closure returns.
/// `close` and `isOperational` take the same nonrecursive lock; do not call them inside `withLock`.
public final class SQLiteStoreConnection: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var database: OpaquePointer?
    public private(set) var operationFailed = false
    private let optimizesOnClose: Bool

    /// Set optimizesOnClose to false only to preserve a store that never ran `PRAGMA optimize` on close.
    public init(database: OpaquePointer, optimizesOnClose: Bool = true) {
        self.database = database
        self.optimizesOnClose = optimizesOnClose
    }

    deinit { close() }

    public func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try lock.withLock(body)
    }

    /// Call inside `withLock`. Failure stays recorded for the lifetime of this connection.
    public func markFailed() {
        operationFailed = true
    }

    /// Records a predicate under `withLock`. A prior failure does not change a later successful predicate.
    /// The shared type deliberately requires `database != nil`; the old helper returned the condition unchanged.
    /// Album/catalog conditions are SQL-derived; audited queue conditions are SQL-derived or literal false.
    /// A nil handle fails these conditions, preserving closed-store results; audit other stores before migration.
    /// The old helper could return true after close. The shared type rejects that case.
    /// The operational probe remains false after any recorded failure.
    @discardableResult
    public func requireOperational(_ condition: Bool) -> Bool {
        let succeeded = database != nil && condition
        if !succeeded { markFailed() }
        return succeeded
    }

    public func isOperational() -> Bool { isOperational(probeDatabase: true) }

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

    public func close() {
        withLock {
            guard database != nil else { return }
            if optimizesOnClose { sqlite3_exec(database, "PRAGMA optimize;", nil, nil, nil) }
            sqlite3_close(database)
            database = nil
        }
    }
}
