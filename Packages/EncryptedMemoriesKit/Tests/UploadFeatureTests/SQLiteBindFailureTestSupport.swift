import PhotosCore
import SQLite3
import XCTest

/// Lowers SQLITE_LIMIT_LENGTH on a store's own connection and reads it back, so the test fails unless the lowered limit
/// applies. A bind of a longer value then fails with SQLITE_TOOBIG, as a bind that runs out of memory does.
func lowerSQLiteLengthLimit(
    on connection: SQLiteStoreConnection, to limit: Int32, file: StaticString = #filePath, line: UInt = #line
) {
    connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
    let effective = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1) }
    XCTAssertEqual(effective, limit, "The lowered length limit must apply", file: file, line: line)
}

/// Fails the test unless the connection recorded a lasting failure, as a failed bind records SQLITE_TOOBIG.
func assertRecordedBindFailure(
    on connection: SQLiteStoreConnection, file: StaticString = #filePath, line: UInt = #line
) {
    connection.withLock {
        XCTAssertTrue(connection.operationFailed, "The failed bind must be recorded", file: file, line: line)
        XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure", file: file, line: line)
    }
}

/// Fails only the binds of one statement: lowers SQLITE_LIMIT_LENGTH on the store's own connection when it is created,
/// or, with `after`, when the first statement whose SQL contains `after` finishes. It restores the limit when the first
/// statement whose SQL contains `statement` starts to step, after its binds and before it builds a record. A bind of a
/// longer value fails as a bind that runs out of memory does, while the record of a statement that steps anyway is
/// written without the limit. Without that restore the record itself
/// would exceed the limit and fail the step, which hides an unchecked bind.
final class BindFailureUntilStep {
    private let connection: SQLiteStoreConnection
    private let statement: String
    private let earlier: String?
    private let limit: Int32
    private(set) var lowered = false
    private(set) var stepped = false

    init(on connection: SQLiteStoreConnection, statement: String, after earlier: String?, limit: Int32) {
        self.connection = connection
        self.statement = statement
        self.earlier = earlier
        self.limit = limit
        connection.withLock {
            if earlier == nil {
                _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit)
                lowered = true
            }
            _ = sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE),
                { event, context, statement, _ in
                    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    let fault = Unmanaged<BindFailureUntilStep>.fromOpaque(context).takeUnretainedValue()
                    let text = String(cString: sql)
                    let db = sqlite3_db_handle(OpaquePointer(statement))
                    if event == UInt32(SQLITE_TRACE_PROFILE), !fault.lowered, let earlier = fault.earlier,
                        text.contains(earlier)
                    {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, fault.limit)
                        fault.lowered = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == fault.limit
                    } else if event == UInt32(SQLITE_TRACE_STMT), fault.lowered, !fault.stepped,
                        text.contains(fault.statement)
                    {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_000_000_000)
                        fault.stepped = true
                    }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    var effectiveLimit: Int32 { connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1) } }

    func remove() {
        connection.withLock {
            _ = sqlite3_trace_v2(connection.database, 0, nil, nil)
            _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 1_000_000_000)
        }
    }
}
