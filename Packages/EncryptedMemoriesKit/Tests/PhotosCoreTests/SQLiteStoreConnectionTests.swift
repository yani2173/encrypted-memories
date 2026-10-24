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
