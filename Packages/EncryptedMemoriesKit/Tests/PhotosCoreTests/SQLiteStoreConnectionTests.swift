import Foundation
import PhotosCore
import SQLite3
import XCTest

final class SQLiteStoreConnectionTests: XCTestCase {
    func testCloseRejectsLaterQueriesAndOperationalChecks() throws {
        let connection = try makeConnection()
        XCTAssertTrue(connection.isOperational())
        connection.close()

        XCTAssertFalse(connection.isOperational())
        connection.withLock {
            XCTAssertNil(connection.database)
            XCTAssertFalse(connection.operationFailed, "checking a closed connection does not mark a new failure")
            XCTAssertFalse(connection.requireOperational(true), "a true predicate cannot admit a closed handle")
            XCTAssertFalse(connection.requireOperational(query(connection.database)))
        }
        connection.close()
    }

    func testStateOnlyOperationalCheckSkipsSQLButStillRejectsFailureAndClose() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            sqlite3_set_authorizer(
                connection.database,
                { _, action, _, _, _, _ in action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK }, nil)
        }
        XCTAssertTrue(connection.isOperational(probeDatabase: false))
        connection.withLock { XCTAssertFalse(connection.operationFailed) }
        let probe: () -> Bool = connection.isOperational
        XCTAssertFalse(probe(), "the existing no-argument method still probes SQLite")
        connection.withLock { XCTAssertTrue(connection.operationFailed) }
        XCTAssertFalse(connection.isOperational(probeDatabase: false), "state-only checks reject recorded failure")
        connection.close()
        XCTAssertFalse(connection.isOperational(probeDatabase: false))

        let healthy = try makeConnection()
        healthy.close()
        XCTAssertFalse(healthy.isOperational(probeDatabase: false), "state-only checks reject a closed healthy handle")
    }

    func testFailureStaysStickyAfterASuccessfulPredicate() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            XCTAssertFalse(connection.requireOperational(false))
            XCTAssertTrue(connection.requireOperational(query(connection.database)))
            XCTAssertTrue(connection.operationFailed)
        }
        XCTAssertFalse(connection.isOperational())
        connection.close()
        connection.withLock {
            XCTAssertTrue(connection.operationFailed)
            XCTAssertNil(connection.database, "a recorded failure must not prevent close from releasing its handle")
        }
    }

    func testRecordingPredicateRetainsItsSQLiteFailureAfterLaterSuccess() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            sqlite3_set_authorizer(
                connection.database,
                { _, action, _, _, _, _ in action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK }, nil)
            XCTAssertFalse(connection.requireOperationalRecordingSQLiteError(query(connection.database)))
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient)
            sqlite3_set_authorizer(connection.database, nil, nil)
            XCTAssertTrue(connection.requireOperationalRecordingSQLiteError(query(connection.database)))
            XCTAssertTrue(connection.operationFailed)
        }
        XCTAssertFalse(connection.isOperational())
    }

    func testRecordingPredicatePreservesTheConditionAfterClose() throws {
        let connection = try makeConnection()
        connection.close()
        connection.withLock {
            XCTAssertTrue(connection.requireOperationalRecordingSQLiteError(true))
            XCTAssertFalse(connection.operationFailed)
            XCTAssertFalse(connection.requireOperationalRecordingSQLiteError(false))
            XCTAssertTrue(connection.operationFailed)
        }
        XCTAssertFalse(connection.isOperational())
    }

    // MARK: - Recovery after a transient failure (#982)

    func testATransientFailureRecoversWhenTheDatabaseAnswers() throws {
        // Busy, locked, out of memory, interrupted, I/O and full disk, primary and extended codes.
        let codes: [Int32] = [
            SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_INTERRUPT, SQLITE_IOERR, SQLITE_FULL,
            SQLITE_BUSY | (2 << 8), SQLITE_IOERR | (10 << 8),
        ]
        for code in codes {
            let connection = try makeConnection()
            defer { connection.close() }
            connection.withLock { connection.markFailed(resultCode: code) }
            XCTAssertFalse(connection.isOperational(probeDatabase: false), "\(code) is recorded")

            XCTAssertTrue(connection.isOperationalAfterRecovery(), "\(code) recovers")
            connection.withLock { XCTAssertFalse(connection.operationFailed, "\(code) is forgotten") }
        }
    }

    func testAFailureThatIsNotTransientStaysRecorded() throws {
        // A corrupt database, a file that is no database, a read-only file, a schema change, a constraint, a misuse,
        // a denied statement and an unknown cause.
        let codes: [Int32?] = [
            SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_READONLY, SQLITE_SCHEMA, SQLITE_CONSTRAINT, SQLITE_MISUSE,
            SQLITE_AUTH, SQLITE_ERROR, nil,
        ]
        for code in codes {
            let connection = try makeConnection()
            defer { connection.close() }
            connection.withLock { connection.markFailed(resultCode: code) }

            XCTAssertFalse(connection.isOperationalAfterRecovery(), "\(String(describing: code)) stays recorded")
            XCTAssertFalse(connection.isOperationalAfterRecovery(), "also at the next check")
        }
    }

    func testOneFailureThatIsNotTransientKeepsEarlierTransientFailuresRecorded() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            connection.markFailed(resultCode: SQLITE_BUSY)
            connection.markFailed(resultCode: SQLITE_CORRUPT)
            connection.markFailed(resultCode: SQLITE_FULL)
        }
        XCTAssertFalse(connection.isOperationalAfterRecovery())
    }

    func testATransientFailureDoesNotRecoverWhileATransactionIsOpen() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            connection.markFailed(resultCode: SQLITE_BUSY)
        }
        XCTAssertFalse(connection.isOperationalAfterRecovery(), "the open transaction can hold a half-done write")
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertTrue(connection.isOperationalAfterRecovery())
    }

    /// A rollback that failed can leave a transaction open with half a write in it; the store stops (#982).
    func testAnOpenTransactionStopsTheStoreWithoutARecordedFailure() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertFalse(connection.isOperationalAfterRecovery())
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertTrue(connection.isOperationalAfterRecovery())
    }

    /// After a full disk, an I/O error, an interrupt or no memory, SQLite can end the transaction on its own. The
    /// explicit rollback then fails, but no transaction stays open, and the transient failure still recovers (#982).
    func testARollbackAfterSQLiteEndedTheTransactionKeepsATransientFailureRecoverable() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            connection.markFailed(resultCode: SQLITE_FULL)
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
            connection.rollBack()
            XCTAssertNotEqual(sqlite3_extended_errcode(connection.database), SQLITE_OK, "the rollback itself failed")
            XCTAssertTrue(connection.failuresAreTransient)
        }
        XCTAssertTrue(connection.isOperationalAfterRecovery())
    }

    func testARollbackThatEndsTheTransactionRecordsNoFailure() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            connection.rollBack()
            XCTAssertNotEqual(sqlite3_get_autocommit(connection.database), 0)
            XCTAssertFalse(connection.operationFailed)
        }
        XCTAssertTrue(connection.isOperational(probeDatabase: false))
    }

    /// A rollback that leaves the transaction open can keep half a write; the store stops for good.
    func testARollbackThatLeavesTheTransactionOpenStopsTheStore() throws {
        let connection = try makeConnection()
        defer {
            connection.withLock {
                sqlite3_set_authorizer(connection.database, nil, nil)
                sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil)
            }
            connection.close()
        }
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            sqlite3_set_authorizer(
                connection.database,
                { _, action, _, _, _, _ in action == SQLITE_TRANSACTION ? SQLITE_DENY : SQLITE_OK }, nil)
            connection.rollBack()
            XCTAssertEqual(sqlite3_get_autocommit(connection.database), 0, "the denied rollback left it open")
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient)
        }
        XCTAssertFalse(connection.isOperationalAfterRecovery())
    }

    /// I/O codes that report damaged data stay recorded like a corrupt database.
    func testAnIOErrorThatReportsDamagedDataStaysRecorded() throws {
        for code in [SQLITE_IOERR | (32 << 8), SQLITE_IOERR | (33 << 8)] {
            let connection = try makeConnection()
            defer { connection.close() }
            connection.withLock { connection.markFailed(resultCode: code) }
            XCTAssertFalse(connection.isOperationalAfterRecovery(), "\(code) stays recorded")
        }
    }

    func testAClosedConnectionNeverRecovers() throws {
        let connection = try makeConnection()
        connection.withLock { connection.markFailed(resultCode: SQLITE_BUSY) }
        connection.close()
        XCTAssertFalse(connection.isOperationalAfterRecovery())
    }

    func testCloseOptimizesThenReleasesTheHandleOnlyOnce() throws {
        let connection = try makeConnection()
        let trace = Trace()
        let handle = try connection.withLock { try XCTUnwrap(connection.database) }
        trace.install(on: handle)
        defer {
            // A skipped-close mutant must not leak its test handle.
            if trace.events.last != "close" { sqlite3_close(handle) }
        }

        connection.close()
        XCTAssertEqual(trace.events, ["PRAGMA optimize;", "close"])
        connection.close()
        XCTAssertEqual(trace.events, ["PRAGMA optimize;", "close"])
        withExtendedLifetime(trace) {}
    }

    func testCloseWithoutOptimizeOnlyReleasesTheHandleOnce() throws {
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &opened), SQLITE_OK)
        let handle = try XCTUnwrap(opened)
        let connection = SQLiteStoreConnection(database: handle, optimizesOnClose: false)
        let trace = Trace()
        trace.install(on: handle)
        defer {
            if trace.events.last != "close" { sqlite3_close(handle) }
        }

        XCTAssertTrue(connection.isOperational())
        connection.close()
        XCTAssertEqual(trace.events, ["SELECT 1;", "close"], "close runs no SQL before releasing the handle")
        connection.close()
        XCTAssertEqual(trace.events, ["SELECT 1;", "close"])
        XCTAssertFalse(connection.isOperational(probeDatabase: false))
        connection.withLock { XCTAssertNil(connection.database) }
        withExtendedLifetime(trace) {}
    }

    func testDeinitializationReleasesTheHandle() throws {
        let trace = Trace()
        var connection: SQLiteStoreConnection? = try makeConnection()
        let handle = try XCTUnwrap(connection?.database)
        trace.install(on: handle)
        defer {
            if trace.events.last != "close" { sqlite3_close(handle) }
        }
        connection = nil
        XCTAssertEqual(trace.events, ["PRAGMA optimize;", "close"])
        withExtendedLifetime(trace) {}
    }

    func testProbeFinalizesItsStatementBeforeClose() throws {
        let connection = try makeConnection()
        defer {
            connection.withLock {
                // Clean up a missing-finalizer mutant before close.
                while let statement = sqlite3_next_stmt(connection.database, nil) { sqlite3_finalize(statement) }
            }
            connection.close()
        }
        XCTAssertTrue(connection.isOperational())
        connection.withLock { XCTAssertNil(sqlite3_next_stmt(connection.database, nil)) }
    }

    func testProbePrepareFailureStaysFailedAfterTheCauseIsRemoved() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        connection.withLock {
            sqlite3_set_authorizer(
                connection.database,
                { _, action, _, _, _, _ in
                    action == SQLITE_SELECT ? SQLITE_DENY : SQLITE_OK
                }, nil)
        }
        XCTAssertFalse(connection.isOperational())
        connection.withLock {
            sqlite3_set_authorizer(connection.database, nil, nil)
            XCTAssertTrue(connection.operationFailed)
            XCTAssertTrue(query(connection.database), "the SQL failure is gone")
        }
        XCTAssertFalse(connection.isOperational())
    }

    func testProbeStepFailureStaysFailedAfterTheCauseIsRemoved() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        let trace = Trace(interruptSelect: true)
        connection.withLock { trace.install(on: connection.database) }
        XCTAssertFalse(connection.isOperational())
        connection.withLock {
            sqlite3_trace_v2(connection.database, 0, nil, nil)
            XCTAssertEqual(trace.events, ["SELECT 1;"])
            XCTAssertTrue(connection.operationFailed)
            XCTAssertTrue(query(connection.database), "the interrupted step is over")
        }
        XCTAssertFalse(connection.isOperational())
    }

    func testStickyFailureSkipsTheProbe() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        let trace = Trace()
        connection.withLock {
            trace.install(on: connection.database)
            connection.markFailed()
        }
        XCTAssertFalse(connection.isOperational())
        XCTAssertTrue(trace.events.isEmpty)
        connection.withLock { sqlite3_trace_v2(connection.database, 0, nil, nil) }
    }

    func testCloseWaitsForAnOperationAndItsStatementFinalizer() throws {
        let connection = try makeConnection()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        connection.withLock {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(connection.database, "SELECT 1;", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            DispatchQueue.global().async {
                started.signal()
                connection.close()
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 1), .timedOut, "close must wait for the operation lock")
            XCTAssertNotNil(connection.database, "the operation retains its handle until its finalizer runs")
            // A mutant can clear the handle; never step a statement from that invalid lifecycle.
            if connection.database != nil { XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW) }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(connection.isOperational())
    }

    func testOperationalProbeWaitsForTheOperationLock() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        connection.withLock {
            DispatchQueue.global().async {
                started.signal()
                XCTAssertTrue(connection.isOperational())
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 1), .timedOut, "the probe shares the operation lock")
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
    }

    /// The shared binds record a failed bind with its own code and throw, so no caller steps a statement whose
    /// parameter silently became NULL (#1194).
    func testSharedBindsRecordAFailedBindAndThrow() throws {
        for kind in ["text", "blob"] {
            let connection = try makeConnection()
            defer { connection.close() }
            var statement: OpaquePointer?
            connection.withLock {
                XCTAssertEqual(sqlite3_prepare_v2(connection.database, "SELECT ?;", -1, &statement, nil), SQLITE_OK)
                _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32)
                XCTAssertEqual(sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1), 32, "the limit applies")
            }
            defer { sqlite3_finalize(statement) }
            let long = String(repeating: "x", count: 128)
            XCTAssertThrowsError(
                try connection.withLock {
                    if kind == "text" {
                        try connection.bindText(statement, 1, long)
                    } else {
                        try connection.bindBlob(statement, 1, Data(long.utf8))
                    }
                }
            ) { XCTAssertTrue($0 is SQLiteStoreUnknownReadError, "\(kind)") }
            connection.withLock {
                XCTAssertTrue(connection.operationFailed, "the failed \(kind) bind is recorded")
                XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure")
            }
            XCTAssertEqual(SQLiteBinding.text(statement, 1, long), SQLITE_TOOBIG, "the shared bind reports its code")
            XCTAssertEqual(SQLiteBinding.blob(statement, 1, Data(long.utf8)), SQLITE_TOOBIG)
        }
    }

    func testSharedBindsBindValuesAndNull() throws {
        let connection = try makeConnection()
        defer { connection.close() }
        var statement: OpaquePointer?
        connection.withLock {
            XCTAssertEqual(
                sqlite3_prepare_v2(connection.database, "SELECT ?, ?, typeof(?), typeof(?);", -1, &statement, nil),
                SQLITE_OK)
        }
        defer { sqlite3_finalize(statement) }
        XCTAssertNoThrow(
            try connection.withLock {
                try connection.bindText(statement, 1, "text")
                try connection.bindBlob(statement, 2, Data([1, 2, 3]))
                try connection.bindText(statement, 3, nil)
                try connection.bindBlob(statement, 4, nil)
            })
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "text")
        XCTAssertEqual(sqlite3_column_bytes(statement, 1), 3)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 2)), "null")
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 3)), "null")
        connection.withLock { XCTAssertFalse(connection.operationFailed) }
    }

    private func makeConnection() throws -> SQLiteStoreConnection {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &handle), SQLITE_OK)
        return SQLiteStoreConnection(database: try XCTUnwrap(handle))
    }

    private func query(_ handle: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT 1;", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        private let interruptSelect: Bool
        var events: [String] { lock.withLock { recorded } }

        init(interruptSelect: Bool = false) { self.interruptSelect = interruptSelect }

        func install(on handle: OpaquePointer?) {
            sqlite3_trace_v2(
                handle, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_CLOSE),
                { event, context, pointer, _ in
                    guard let context else { return 0 }
                    let trace = Unmanaged<Trace>.fromOpaque(context).takeUnretainedValue()
                    if event == UInt32(SQLITE_TRACE_CLOSE) {
                        trace.lock.withLock { trace.recorded.append("close") }
                    } else if let pointer, let sql = sqlite3_sql(OpaquePointer(pointer)) {
                        let text = String(cString: sql)
                        trace.lock.withLock { trace.recorded.append(text) }
                        if trace.interruptSelect && text == "SELECT 1;" {
                            sqlite3_interrupt(sqlite3_db_handle(OpaquePointer(pointer)))
                        }
                    }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}
