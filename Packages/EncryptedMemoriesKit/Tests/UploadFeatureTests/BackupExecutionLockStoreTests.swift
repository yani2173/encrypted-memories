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
        XCTAssertEqual(
            store.heartbeat(runID: "owner", phase: "changed"), .unavailable, "an unreadable lock is not a lost lock")
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

    func testHeartbeatReportsALockTakenByAnotherRunOrRemovedAsLost() throws {
        let store = try makeStore()
        defer { store.close() }
        let other = try makeStore()
        defer { other.close() }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .renewed)

        clock.advance(by: 200)
        XCTAssertEqual(other.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120)).map(\.runID), ["owner"])
        XCTAssertTrue(other.acquire(owner: .background, runID: "successor").didAcquire)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: "uploading"), .lost)
        XCTAssertEqual(store.currentLock()?.runID, "successor", "a lost heartbeat never writes the row")

        XCTAssertTrue(other.release(runID: "successor"))
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .lost, "a removed lock is lost too")
        XCTAssertNil(store.currentLock(), "a lost heartbeat never recreates the row")
    }

    func testHeartbeatThatCannotReadKeepsTheLockAndRenewsLater() throws {
        let connection = try makeVerifiedConnection(url: tempDir.appendingPathComponent("unreadable-heartbeat.sqlite"))
        let store = BackupExecutionLockManifestStore(connection: connection, now: { [clock] in clock!.now })
        defer { store.close() }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        let acquired = try XCTUnwrap(store.currentLock())
        let authorization = SelectAuthorization()
        connection.withLock { authorization.install(on: connection.database) }

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .unavailable)
        XCTAssertGreaterThan(authorization.deniedSelects, 0)
        connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) }
        XCTAssertEqual(store.currentLock(), acquired, "a failed read changes nothing")

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .renewed)
        XCTAssertEqual(store.currentLock()?.heartbeatAt, clock.now)
    }

    func testHeartbeatThatCannotWriteKeepsTheLockAndRenewsLater() throws {
        let url = tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName)
        let noWait = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        let store = try XCTUnwrap(
            BackupExecutionLockManifestStore(url: url, policy: noWait, now: { [clock] in clock!.now }))
        defer { store.close() }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        let acquired = try XCTUnwrap(store.currentLock())
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .unavailable, "a busy writer is not a lost lock")
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(store.currentLock(), acquired)

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .renewed)
        XCTAssertEqual(store.currentLock()?.heartbeatAt, clock.now)
    }

    func testHeartbeatThatCannotPrepareItsWriteKeepsTheLockAndRenewsLater() throws {
        let connection = try makeVerifiedConnection(url: tempDir.appendingPathComponent("unwritable-heartbeat.sqlite"))
        let store = BackupExecutionLockManifestStore(connection: connection, now: { [clock] in clock!.now })
        defer { store.close() }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        let acquired = try XCTUnwrap(store.currentLock())
        connection.withLock {
            sqlite3_set_authorizer(
                connection.database, { _, action, _, _, _, _ in action == SQLITE_UPDATE ? SQLITE_DENY : SQLITE_OK },
                nil)
        }

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .unavailable)
        connection.withLock { sqlite3_set_authorizer(connection.database, nil, nil) }
        XCTAssertEqual(store.currentLock(), acquired)

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .renewed)
        XCTAssertEqual(store.currentLock()?.heartbeatAt, clock.now)
    }

    /// A bind that fails leaves its parameter NULL. The SELECT would then report no row, which is no lost lock.
    func testHeartbeatWhoseReadCannotBindKeepsTheLock() throws {
        let connection = try makeVerifiedConnection(url: tempDir.appendingPathComponent("read-bind.sqlite"))
        let store = BackupExecutionLockManifestStore(connection: connection, now: { [clock] in clock!.now })
        defer { store.close() }
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)
        let acquired = try XCTUnwrap(store.currentLock())
        // "photoBackup" no longer fits, so binding the lock name fails with SQLITE_TOOBIG.
        let limit = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 4) }

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .unavailable)
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
        XCTAssertEqual(store.currentLock(), acquired)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .renewed)
    }

    /// A bind that fails in the update writes nothing and is no lost lock either.
    func testHeartbeatWhoseWriteCannotBindWritesNothing() throws {
        let connection = try makeVerifiedConnection(url: tempDir.appendingPathComponent("write-bind.sqlite"))
        let store = BackupExecutionLockManifestStore(connection: connection, now: { [clock] in clock!.now })
        defer { store.close() }
        XCTAssertTrue(
            store.acquire(owner: .foreground, runID: "owner", phase: "scanning", processContext: nil).didAcquire)
        let acquired = try XCTUnwrap(store.currentLock())
        // The stored row still fits; only the long phase of the update does not.
        let limit = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 128) }

        clock.advance(by: 30)
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: String(repeating: "p", count: 200)), .unavailable)
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
        XCTAssertEqual(store.currentLock(), acquired, "a failed bind must not write a NULL phase or a new heartbeat")
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: nil), .renewed)
    }

    /// Another connection removes or replaces the row after the heartbeat read it and before it writes.
    func testHeartbeatWhoseRowChangesBeforeTheWriteIsLost() throws {
        for replacement in [nil, "successor"] {
            let url = tempDir.appendingPathComponent("raced-\(replacement ?? "removed").sqlite")
            let race = RowRace(url: url, replacement: replacement)
            let connection = try makeVerifiedConnection(url: url)
            // The heartbeat reads the clock between its read and its write; that is where the other run acts.
            let store = BackupExecutionLockManifestStore(
                connection: connection,
                now: { [clock] in
                    race.fire()
                    return clock!.now
                })
            defer { store.close() }
            XCTAssertTrue(store.acquire(owner: .foreground, runID: "owner").didAcquire)

            race.arm()
            XCTAssertEqual(store.heartbeat(runID: "owner", phase: "uploading"), .lost, "\(replacement ?? "removed")")
            XCTAssertTrue(race.fired)
            XCTAssertEqual(store.currentLock()?.runID, replacement, "the lost heartbeat writes nothing")
            XCTAssertEqual(store.currentLock()?.phase, nil)
        }
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
        XCTAssertEqual(store.heartbeat(runID: "closed", phase: "uploading"), .unavailable)
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
        XCTAssertEqual(store.heartbeat(runID: "owner", phase: "changed"), .unavailable)
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
        XCTAssertEqual(store.heartbeat(runID: "fg", phase: "uploading"), .renewed)  // heartbeat @ t0+90
        XCTAssertEqual(store.currentLock()?.phase, "uploading")

        // A cutoff 60s in the past would have reaped the original heartbeat, but the refresh saved it.
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(reaped.isEmpty, "a freshly heartbeated lock must survive stale recovery")
        XCTAssertEqual(store.currentLock()?.runID, "fg")

        XCTAssertEqual(store.heartbeat(runID: "other", phase: nil), .lost, "only the owner may heartbeat")
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

    /// Changes the lock row through a second connection the first time it fires after `arm()`.
    private final class RowRace: @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL
        private let replacement: String?
        private var armed = false
        private(set) var fired = false

        init(url: URL, replacement: String?) {
            self.url = url
            self.replacement = replacement
        }

        func arm() { lock.withLock { armed = true } }

        func fire() {
            let shouldFire = lock.withLock { () -> Bool in
                guard armed, !fired else { return false }
                fired = true
                return true
            }
            guard shouldFire else { return }
            var other: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &other), SQLITE_OK)
            defer { sqlite3_close(other) }
            let sql =
                replacement.map { "UPDATE backup_execution_lock SET run_id='\($0)';" }
                ?? "DELETE FROM backup_execution_lock;"
            XCTAssertEqual(sqlite3_exec(other, sql, nil, nil, nil), SQLITE_OK)
        }
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
