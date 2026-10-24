import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

/// The recorder waits like SQLite's busy timeout and remembers a wait that ended without success.
final class SQLiteBusyRecorderTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var slept: [Int] = []
        private var onSleep: (() -> Void)?
        var delays: [Int] { lock.withLock { slept } }
        var total: Int { lock.withLock { slept.reduce(0, +) } }
        func sleep(_ milliseconds: Int) {
            lock.withLock { slept.append(milliseconds) }
            onSleep?()
        }
        func whenSleeping(_ action: @escaping () -> Void) { onSleep = action }
    }

    /// Calls the handler as SQLite does for one locked statement, until it gives up. Returns the number of calls.
    /// A handler that never gives up ends after 10,000 calls, so the test fails instead of hanging.
    private func exhaust(_ recorder: SQLiteBusyRecorder) -> Int {
        var attempts = 0
        while attempts < 10_000, recorder.shouldRetry(afterAttempts: attempts) { attempts += 1 }
        return attempts
    }

    func testTheDelaysAreTheOnesOfSQLitesOwnBusyTimeout() {
        let clock = Clock()
        let recorder = SQLiteBusyRecorder(timeoutMs: 10_000, sleep: clock.sleep)
        for attempt in 0..<14 { XCTAssertTrue(recorder.shouldRetry(afterAttempts: attempt)) }
        // sqliteDefaultBusyCallback: 1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100, then 100 again.
        XCTAssertEqual(clock.delays, [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100, 100, 100])
    }

    func testTheTotalWaitEqualsTheBusyTimeout() {
        for timeout in [1, 2, 3, 10, 50, 228, 500, 3_000, 5_000] {
            let clock = Clock()
            let recorder = SQLiteBusyRecorder(timeoutMs: timeout, sleep: clock.sleep)
            _ = exhaust(recorder)
            XCTAssertEqual(clock.total, timeout, "a locked statement waits exactly \(timeout) ms, no more and no less")
            XCTAssertTrue(recorder.gaveUp, "the wait ended without success")
        }
    }

    func testWithoutATimeoutTheStatementFailsAtOnceAndTheRecorderKnowsIt() {
        let clock = Clock()
        let recorder = SQLiteBusyRecorder(timeoutMs: 0, sleep: clock.sleep)
        XCTAssertFalse(recorder.gaveUp)
        XCTAssertFalse(recorder.shouldRetry(afterAttempts: 0))
        XCTAssertEqual(clock.delays, [], "nothing to wait for")
        XCTAssertTrue(recorder.gaveUp)
    }

    func testTheGiveUpIsReadAndForgottenOnce() {
        let recorder = SQLiteBusyRecorder(timeoutMs: 0, sleep: { _ in })
        _ = recorder.shouldRetry(afterAttempts: 0)
        XCTAssertTrue(recorder.takeGaveUp())
        XCTAssertFalse(recorder.gaveUp, "taken once")
        _ = recorder.shouldRetry(afterAttempts: 0)
        recorder.reset()
        XCTAssertFalse(recorder.takeGaveUp(), "reset forgets")
    }

    private func database() throws -> (URL, OpaquePointer) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("busy.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE t (x INTEGER);", nil, nil, nil), SQLITE_OK)
        return (url, try XCTUnwrap(handle))
    }

    func testALockThatStaysMakesTheStatementFailAfterExactlyTheTimeout() throws {
        let (url, holder) = try database()
        defer { sqlite3_close(holder) }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        var victim: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &victim), SQLITE_OK)
        defer { sqlite3_close(victim) }
        let clock = Clock()
        let recorder = SQLiteBusyRecorder(timeoutMs: 40, sleep: clock.sleep)
        recorder.install(on: victim)

        XCTAssertEqual(sqlite3_exec(victim, "SELECT count(*) FROM t;", nil, nil, nil), SQLITE_BUSY)

        XCTAssertEqual(clock.total, 40, "SQLite called the handler until the timeout was used up")
        XCTAssertTrue(recorder.gaveUp)
    }

    func testALockThatClearsInTimeLetsTheStatementSucceedAndRecordsNothing() throws {
        let (url, holder) = try database()
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        var victim: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &victim), SQLITE_OK)
        defer { sqlite3_close(victim) }
        let clock = Clock()
        let recorder = SQLiteBusyRecorder(timeoutMs: 3_000, sleep: clock.sleep)
        recorder.install(on: victim)
        // The holder lets go during the third wait.
        clock.whenSleeping {
            if clock.delays.count == 3 {
                sqlite3_exec(holder, "COMMIT;", nil, nil, nil)
                sqlite3_close(holder)
            }
        }

        XCTAssertEqual(sqlite3_exec(victim, "SELECT count(*) FROM t;", nil, nil, nil), SQLITE_OK)

        XCTAssertEqual(clock.delays, [1, 2, 5], "it waited three times and then succeeded")
        XCTAssertFalse(recorder.gaveUp, "a lock that clears within the timeout is no give-up")
    }
}
