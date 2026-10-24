import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Durable backup execution ownership: acquire/heartbeat/release, live-lock exclusion, lease-based
/// stale recovery, and the "crash never permanently blocks backup" guarantee. Clock is injected, so
/// every timing assertion is deterministic - no sleeps, no flakes.
final class BackupExecutionLockStoreTests: XCTestCase {
    private var tempDir: URL!
    private var clock: ClockBox!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = ClockBox(start: Date(timeIntervalSince1970: 1_000_000))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(lease: TimeInterval = 120) throws -> BackupExecutionLockManifestStore {
        let url = tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName)
        return try XCTUnwrap(
            BackupExecutionLockManifestStore(
                url: url, lockName: "photoBackup", leaseInterval: lease, now: { [clock] in clock!.now }
            ))
    }

    func testInjectedConnectionPreservesURLInitializerBehavior() throws {
        let url = tempDir.appendingPathComponent("injected.sqlite")
        let connection = try makeVerifiedConnection(url: url)
        let injected = BackupExecutionLockManifestStore(
            connection: connection, lockName: "", leaseInterval: 0, now: { [clock] in clock!.now })
        let opened = try XCTUnwrap(
            BackupExecutionLockManifestStore(
                url: tempDir.appendingPathComponent("opened.sqlite"), lockName: "", leaseInterval: 0,
                now: { [clock] in clock!.now }))
        defer {
            injected.close()
            opened.close()
        }

        XCTAssertEqual(
            injected.acquire(owner: .foreground, runID: "owner"), opened.acquire(owner: .foreground, runID: "owner"))
        let defaultNameReader = try XCTUnwrap(BackupExecutionLockManifestStore(url: url))
        defer { defaultNameReader.close() }
        XCTAssertEqual(defaultNameReader.currentLock(), injected.currentLock())
        clock.advance(by: 0.5)
        guard case .busy = injected.acquire(owner: .manual, runID: "other") else {
            return XCTFail("the minimum lease still protects a live owner")
        }
        clock.advance(by: 1)
        XCTAssertEqual(
            injected.acquire(owner: .manual, runID: "other"), opened.acquire(owner: .manual, runID: "other"))
        XCTAssertEqual(injected.currentLock()?.runID, "other")
    }

    func testSelectAuthorizerAllowsUpsertReadsOnTheInjectedConnection() throws {
        let connection = try makeVerifiedConnection(url: tempDir.appendingPathComponent("authorizer.sqlite"))
        let store = BackupExecutionLockManifestStore(connection: connection, now: { [clock] in clock!.now })
        defer { store.close() }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        let expected = try XCTUnwrap(store.currentLock())
        let authorization = SelectAuthorization()
        connection.withLock { authorization.install(on: connection.database) }
        defer { connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) } }

        XCTAssertNil(store.currentLock())
        XCTAssertGreaterThan(authorization.deniedSelects, 0)
        connection.withLock {
            XCTAssertEqual(
                sqlite3_exec(
                    connection.database,
                    """
                    INSERT INTO backup_execution_lock(lock_name, owner, run_id, acquired_at, heartbeat_at)
                    VALUES('authorizer-control', 'manual', 'control', 0, 0)
                    ON CONFLICT(lock_name) DO UPDATE SET run_id=excluded.run_id;
                    """, nil, nil, nil), SQLITE_OK)
            XCTAssertFalse(connection.operationFailed)
        }
        XCTAssertGreaterThan(authorization.allowedInserts, 0)
        XCTAssertGreaterThan(authorization.allowedUpdates, 0)
        XCTAssertGreaterThan(authorization.allowedReads, 0)
        connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) }
        XCTAssertEqual(store.currentLock(), expected)
    }

    func testDeniedOwnershipReadDoesNotOverwriteALiveOwner() throws {
        try assertFailedOwnershipReadFailsClosed(duringPrepare: true)
    }

    func testInterruptedOwnershipReadDoesNotOverwriteALiveOwner() throws {
        try assertFailedOwnershipReadFailsClosed(duringPrepare: false)
    }

    private func assertFailedOwnershipReadFailsClosed(duringPrepare: Bool) throws {
        let connection = try makeVerifiedConnection(url: tempDir.appendingPathComponent("failed-read.sqlite"))
        let store = BackupExecutionLockManifestStore(connection: connection, now: { [clock] in clock!.now })
        defer {
            connection.withLock {
                // Release statements owned by a missing-finalizer mutation before closing the handle.
                while let statement = sqlite3_next_stmt(connection.database, nil) { sqlite3_finalize(statement) }
            }
            store.close()
        }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        let expected = try XCTUnwrap(store.currentLock())
        connection.withLock { XCTAssertNil(sqlite3_next_stmt(connection.database, nil)) }
        let authorization = SelectAuthorization()
        let interruption = SelectInterruption()
        connection.withLock {
            if duringPrepare {
                authorization.install(on: connection.database)
            } else {
                interruption.install(on: connection.database)
            }
        }
        defer {
            connection.withLock {
                sqlite3_set_authorizer(connection.database, nil, nil)
                sqlite3_trace_v2(connection.database, 0, nil, nil)
            }
        }

        XCTAssertEqual(
            store.acquire(owner: .manual, runID: "contender"), .unavailable,
            "an unreadable lock must not admit a new owner")
        XCTAssertGreaterThan(duringPrepare ? authorization.deniedSelects : interruption.interruptedSelects, 0)
        XCTAssertFalse(store.heartbeat(runID: "owner", phase: "changed"))
        XCTAssertTrue(store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(
            store.recoverAbandonedProcessLocks(
                currentProcessContext: "ios/pid-456", isProcessAlive: { _ in false }
            ).isEmpty)
        connection.withLock {
            XCTAssertNil(sqlite3_next_stmt(connection.database, nil))
            XCTAssertEqual(sqlite3_get_autocommit(connection.database), 1, "a failed read must release the transaction")
            XCTAssertFalse(connection.operationFailed, "the failure is local to the read")
            sqlite3_set_authorizer(connection.database, nil, nil)
            sqlite3_trace_v2(connection.database, 0, nil, nil)
        }
        XCTAssertEqual(store.currentLock(), expected, "a failed read must preserve every existing owner field")
        XCTAssertEqual(store.acquire(owner: .manual, runID: "contender"), .busy(expected))
        XCTAssertTrue(store.release(runID: "owner"))
        XCTAssertTrue(
            store.acquire(owner: .manual, runID: "later").didAcquire, "confirmed absence still permits acquisition")
    }

    func testAcquireAndRelease() throws {
        let store = try makeStore()
        XCTAssertNil(store.currentLock())

        let outcome = store.acquire(owner: .foreground, runID: "run-1")
        guard case .acquired(let lock) = outcome else { return XCTFail("expected acquire on a free lock") }
        XCTAssertEqual(lock.owner, .foreground)
        XCTAssertEqual(lock.runID, "run-1")
        XCTAssertEqual(store.currentLock()?.runID, "run-1")

        XCTAssertTrue(store.release(runID: "run-1"))
        XCTAssertNil(store.currentLock())
        XCTAssertFalse(store.release(runID: "run-1"), "releasing an already-free lock reports no change")
    }

    func testReleaseRequiresOwnership() throws {
        let store = try makeStore()
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "run-1").didAcquire)
        XCTAssertFalse(store.release(runID: "someone-else"), "a non-owner must not release the lock")
        XCTAssertEqual(store.currentLock()?.runID, "run-1")
    }

    func testSecondOwnerCannotAcquireLiveLock() throws {
        let store = try makeStore()
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)

        // A background window firing while the foreground pass is live must stand down.
        let outcome = store.acquire(owner: .iOSBackgroundTask, runID: "bg")
        guard case .busy(let current) = outcome else { return XCTFail("a live lock must report busy") }
        XCTAssertEqual(current.owner, .foreground)
        XCTAssertEqual(current.runID, "fg")
    }

    func testConcurrentStoreInstancesAcquireExactlyOnce() async throws {
        let first = try makeStore()
        let second = try makeStore()

        for iteration in 0..<100 {
            if let current = first.currentLock() {
                XCTAssertTrue(first.release(runID: current.runID))
            }

            let gate = UploadTestBarrier(participantCount: 2)
            let outcomes = await withTaskGroup(of: BackupLockAcquisition.self, returning: [BackupLockAcquisition].self)
            { group in
                group.addTask {
                    await gate.arriveAndWait()
                    return first.acquire(owner: .foreground, runID: "first-\(iteration)")
                }
                group.addTask {
                    await gate.arriveAndWait()
                    return second.acquire(owner: .iOSBackgroundTask, runID: "second-\(iteration)")
                }

                var values: [BackupLockAcquisition] = []
                for await outcome in group { values.append(outcome) }
                return values
            }

            XCTAssertEqual(outcomes.filter(\.didAcquire).count, 1, "iteration \(iteration)")
            XCTAssertEqual(
                outcomes.filter {
                    if case .busy = $0 { return true }
                    return false
                }.count, 1, "the losing connection must observe the committed owner")
            let winner = try XCTUnwrap(first.currentLock())
            XCTAssertTrue(winner.runID == "first-\(iteration)" || winner.runID == "second-\(iteration)")
        }
    }

    func testClosedStoreFailsUnavailableInsteadOfClaimingOwnership() throws {
        let store = try makeStore()
        store.close()

        XCTAssertNil(store.currentLock())
        XCTAssertEqual(store.acquire(owner: .foreground, runID: "closed"), .unavailable)
        XCTAssertFalse(store.heartbeat(runID: "closed", phase: "uploading"))
        XCTAssertFalse(store.release(runID: "closed"))
        XCTAssertTrue(store.recoverStaleLocks(olderThan: clock.now).isEmpty)
    }

    func testClosePreservesOwnershipWhenTheStoreReopens() throws {
        let store = try makeStore()
        XCTAssertTrue(
            store.acquire(
                owner: .foreground, runID: "owner", phase: "uploading", processContext: "ios/pid-123"
            ).didAcquire)
        let expected = try XCTUnwrap(store.currentLock())

        store.close()
        store.close()

        XCTAssertNil(store.currentLock())
        XCTAssertEqual(store.acquire(owner: .manual, runID: "closed"), .unavailable)
        XCTAssertFalse(store.heartbeat(runID: "owner", phase: "changed"))
        XCTAssertFalse(store.release(runID: "owner"))
        XCTAssertTrue(store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(
            store.recoverAbandonedProcessLocks(
                currentProcessContext: "ios/pid-456", isProcessAlive: { _ in false }
            ).isEmpty)

        let reopened = try makeStore()
        defer { reopened.close() }
        XCTAssertEqual(reopened.currentLock(), expected)
        XCTAssertEqual(reopened.acquire(owner: .manual, runID: "other"), .busy(expected))
        XCTAssertTrue(reopened.release(runID: "owner"))
        XCTAssertNil(reopened.currentLock())
    }

    func testConcurrentRecoveryOfStaleLockStillElectsOneOwner() async throws {
        let first = try makeStore(lease: 120)
        let second = try makeStore(lease: 120)
        XCTAssertTrue(first.acquire(owner: .foreground, runID: "crashed").didAcquire)
        clock.advance(by: 121)

        let gate = UploadTestBarrier(participantCount: 2)
        let outcomes = await withTaskGroup(of: BackupLockAcquisition.self, returning: [BackupLockAcquisition].self) {
            group in
            group.addTask {
                await gate.arriveAndWait()
                return first.acquire(owner: .foreground, runID: "recovery-first")
            }
            group.addTask {
                await gate.arriveAndWait()
                return second.acquire(owner: .iOSBackgroundTask, runID: "recovery-second")
            }

            var values: [BackupLockAcquisition] = []
            for await outcome in group { values.append(outcome) }
            return values
        }

        XCTAssertEqual(outcomes.filter(\.didAcquire).count, 1)
        XCTAssertEqual(
            outcomes.filter {
                if case .busy = $0 { return true }
                return false
            }.count, 1)
        XCTAssertNotEqual(first.currentLock()?.runID, "crashed")
    }

    func testSameRunReacquiresAndRefreshes() throws {
        let store = try makeStore()
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)
        clock.advance(by: 10)
        let outcome = store.acquire(owner: .foreground, runID: "fg")
        XCTAssertTrue(outcome.didAcquire, "the same run may re-acquire its own lock")
        XCTAssertEqual(store.currentLock()?.heartbeatAt, Date(timeIntervalSince1970: 1_000_010))
    }

    func testHeartbeatExtendsLockAgainstRecovery() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)  // heartbeat @ t0

        clock.advance(by: 90)
        XCTAssertTrue(store.heartbeat(runID: "fg", phase: "uploading"))  // heartbeat @ t0+90
        XCTAssertEqual(store.currentLock()?.phase, "uploading")

        // A cutoff 60s in the past would have reaped the original heartbeat, but the refresh saved it.
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(reaped.isEmpty, "a freshly heartbeated lock must survive stale recovery")
        XCTAssertEqual(store.currentLock()?.runID, "fg")

        XCTAssertFalse(store.heartbeat(runID: "other", phase: nil), "only the owner may heartbeat")
    }

    func testStaleLockCanBeRecoveredAndReacquired() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(owner: .iOSBackgroundTask, runID: "bg").didAcquire)

        // The background run "crashes": no release. A different run cannot take a still-live lock.
        clock.advance(by: 60)
        XCTAssertFalse(store.acquire(owner: .foreground, runID: "fg").didAcquire)

        // Past the lease, an explicit recovery reaps it and the next start acquires cleanly.
        clock.advance(by: 100)  // now t0 + 160 > lease
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120))
        XCTAssertEqual(reaped.map(\.runID), ["bg"])
        XCTAssertTrue(
            store.acquire(owner: .foreground, runID: "fg").didAcquire,
            "a stale background lock recovers on the next foreground start")
    }

    func testAbandonedProcessLockCanBeRecoveredBeforeLeaseExpires() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(
            store.acquire(
                owner: .foreground,
                runID: "old",
                phase: "uploading",
                processContext: "ios/pid-123"
            ).didAcquire)

        let recovered = store.recoverAbandonedProcessLocks(
            currentProcessContext: "ios/pid-456",
            isProcessAlive: { pid in pid != 123 }
        )

        XCTAssertEqual(recovered.map(\.runID), ["old"])
        XCTAssertNil(store.currentLock())
        XCTAssertTrue(
            store.acquire(
                owner: .foreground,
                runID: "new",
                phase: "scanning",
                processContext: "ios/pid-456"
            ).didAcquire)
    }

    func testAbandonedProcessRecoveryDoesNotStealLiveOrUnrelatedLocks() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(
            store.acquire(
                owner: .foreground,
                runID: "live",
                phase: "uploading",
                processContext: "ios/pid-123"
            ).didAcquire)

        XCTAssertTrue(
            store.recoverAbandonedProcessLocks(
                currentProcessContext: "ios/pid-456",
                isProcessAlive: { _ in true }
            ).isEmpty)
        XCTAssertEqual(store.currentLock()?.runID, "live")

        XCTAssertTrue(
            store.recoverAbandonedProcessLocks(
                currentProcessContext: "macos/pid-456",
                isProcessAlive: { _ in false }
            ).isEmpty)
        XCTAssertEqual(store.currentLock()?.runID, "live")
    }

    func testAcquireAutoRecoversStaleWithoutExplicitCall() throws {
        let store = try makeStore(lease: 30)
        XCTAssertTrue(store.acquire(owner: .background, runID: "dead").didAcquire)
        clock.advance(by: 45)  // past the 30s lease with no heartbeat
        let outcome = store.acquire(owner: .foreground, runID: "fresh")
        XCTAssertTrue(outcome.didAcquire, "a lock never permanently blocks backup after a crash")
        XCTAssertEqual(store.currentLock()?.runID, "fresh")
    }

    func testRecoveryIsNoOpWhileLockIsLive() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)
        clock.advance(by: 30)
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120))
        XCTAssertTrue(reaped.isEmpty)
        XCTAssertEqual(store.currentLock()?.runID, "fg")
    }

    /// Verifies that stale-lock recovery leaves queued work runnable.
    func testCrashRecoveryLeavesLockFreeAndQueueRunnable() throws {
        let store = try makeStore(lease: 120)
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))

        // A run acquires the lock and leaves a row mid-upload, then the process dies.
        XCTAssertTrue(store.acquire(owner: .iOSBackgroundTask, runID: "bg").didAcquire)
        queue.upsert(
            UploadBackupSyncQueueEntry(
                source: .file(URL(fileURLWithPath: "/p/a.jpg")),
                revision: UploadBackupRevision(date: Date(timeIntervalSince1970: 10)),
                originalFilename: "a.jpg",
                state: .uploading,
                updatedAt: clock.now
            ))

        // Next start: recover the stale lock, then the queue's stale-active recovery makes the row
        // runnable again. Neither the lock nor the row is permanently stuck.
        clock.advance(by: 200)
        _ = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120))
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)
        XCTAssertEqual(queue.requeueStaleActive(before: clock.now, updatedAt: clock.now), 1)
        XCTAssertEqual(queue.nextRunnable(limit: 10).map(\.source.identifier), ["/p/a.jpg"])
        queue.close()
    }

    func testFutureSchemaFailsClosedWithoutDeletingExecutionLock() throws {
        let url = tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(BackupExecutionLockManifestStore(url: url, now: { [clock] in clock!.now }))
            _ = store.acquire(owner: .foreground, runID: "fg")
            store.close()
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_execution_lock_info SET value=99 WHERE key='schema';", nil, nil, nil),
            SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertNil(BackupExecutionLockManifestStore(url: url, now: { [clock] in clock!.now }))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_execution_lock"), 1)
    }

    func testMarkerlessExecutionLockShapeFailsClosedWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE backup_execution_lock(run_id TEXT); INSERT INTO backup_execution_lock VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(BackupExecutionLockManifestStore(url: url, now: { [clock] in clock!.now }))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_execution_lock"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_execution_lock_info"), -1)
    }

    private func makeVerifiedConnection(url: URL) throws -> SQLiteStoreConnection {
        let verified = try XCTUnwrap(BackupExecutionLockManifestStore(url: url))
        verified.close()
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw NSError(domain: "SQLiteTestConnection", code: Int(status))
        }
        return SQLiteStoreConnection(database: handle)
    }

    private final class SelectInterruption {
        private(set) var interruptedSelects = 0

        func install(on handle: OpaquePointer?) {
            XCTAssertEqual(
                sqlite3_trace_v2(
                    handle, UInt32(SQLITE_TRACE_STMT),
                    { _, context, pointer, _ in
                        guard let context, let pointer else { return 0 }
                        let statement = OpaquePointer(pointer)
                        guard let sql = sqlite3_sql(statement), String(cString: sql).hasPrefix("SELECT ") else {
                            return 0
                        }
                        let interruption = Unmanaged<SelectInterruption>.fromOpaque(context).takeUnretainedValue()
                        interruption.interruptedSelects += 1
                        sqlite3_interrupt(sqlite3_db_handle(statement))
                        return 0
                    }, Unmanaged.passUnretained(self).toOpaque()), SQLITE_OK)
        }
    }

    private final class SelectAuthorization {
        private(set) var deniedSelects = 0
        private(set) var allowedInserts = 0
        private(set) var allowedUpdates = 0
        private(set) var allowedReads = 0

        func install(on handle: OpaquePointer?) {
            XCTAssertEqual(
                sqlite3_set_authorizer(
                    handle,
                    { context, action, _, _, _, _ in
                        guard let context else { return SQLITE_DENY }
                        let authorization = Unmanaged<SelectAuthorization>.fromOpaque(context).takeUnretainedValue()
                        switch action {
                        case SQLITE_SELECT:
                            authorization.deniedSelects += 1
                            return SQLITE_DENY
                        case SQLITE_INSERT: authorization.allowedInserts += 1
                        case SQLITE_UPDATE: authorization.allowedUpdates += 1
                        case SQLITE_READ: authorization.allowedReads += 1
                        default: break
                        }
                        return SQLITE_OK
                    }, Unmanaged.passUnretained(self).toOpaque()), SQLITE_OK)
        }
    }

    private func sqliteCount(url: URL, table: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { current = start }
        var now: Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }
}
