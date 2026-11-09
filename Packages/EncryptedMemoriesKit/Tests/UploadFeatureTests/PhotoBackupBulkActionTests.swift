import Foundation
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import PhotosCore
@testable import UploadCore

@MainActor
final class PhotoBackupBulkActionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 200)

    func testMergedSnapshotPreservesAllSiblingRevisionsBeforeConsent() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date.addingTimeInterval(1)))
        defer { fixture.cleanup() }
        try fixture.park("siblings", at: date)
        try fixture.park("siblings", at: date.addingTimeInterval(1))
        let snapshot = try XCTUnwrap(BackupProblemSnapshot.backup(in: fixture.queue))
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(
            snapshot.revisionsBySource[fixture.source("siblings")],
            Set([UploadBackupRevision(date: date), UploadBackupRevision(date: date.addingTimeInterval(1))]),
            "A merged list row must not discard the complete confirmed revision set")
        await fixture.controller.shutdown()
    }

    func testControllerConsentUsesTheFullGroupRatherThanTheLoadedPage() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
        defer { fixture.cleanup() }
        XCTAssertTrue(
            fixture.queue.upsertBatch(
                (0..<1_001).map { index in
                    UploadBackupSyncQueueEntry(
                        source: fixture.source("photo-\(index)"), revision: .init(date: date),
                        originalFilename: "photo-\(index).heic", state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)
                }))
        XCTAssertTrue(
            fixture.queue.upsert(
                .init(
                    source: fixture.source("permission"), revision: .init(date: date),
                    originalFilename: "permission.heic", state: .failed,
                    lastError: BackupIssueRecord(kind: .permission, detail: "Permission").persistedValue,
                    updatedAt: date)))
        let session = fixture.controller.makeProblemListSession()
        session.requestRefresh()
        await session.waitUntilIdle()
        XCTAssertEqual(session.rows.count, 200)
        XCTAssertEqual(session.total, 1_002)
        XCTAssertEqual(session.decisionCount, 1_001, "The footer uses the complete exact target group")
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertEqual(confirmation.count, 1_001)
        XCTAssertEqual(Set(confirmation.items.compactMap(\.source)).count, 1_001)
        XCTAssertEqual(session.rows.count, 200, "Preparing consent must not replace the visible list")
        fixture.controller.bulkPhotoActions.dismissConfirmation()
        let item = try XCTUnwrap(session.rows.first { $0.item.issue == .deletedElsewhere }?.item)
        XCTAssertTrue(session.resolveDecision(item) { fixture.controller.keepDeleted(item) })
        XCTAssertEqual(session.decisionCount, 1_000, "A committed per-photo choice updates the footer immediately")
        await session.shutdown()
        await fixture.controller.shutdown()
    }

    func testRestoreConsentNeverAuthorizesTheBackupAction() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        let item = BackupFailedItem(entry: try XCTUnwrap(fixture.entry("photo", at: date)))
        let confirmation = try XCTUnwrap(fixture.controller.bulkPhotoActions.prepare([item], action: .restore))
        XCTAssertFalse(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(fixture.entry("photo", at: date)?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("photo")).isEmpty)
        await fixture.controller.shutdown()
    }

    func testAReadOfAnotherSourceNeverReopensTheConfirmedPhoto() async throws {
        let fixture = try makeFixture(SwappedBulkSourceResolver(inner: ScriptedBackupResolver(defaultModified: date)))
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(fixture.entry("photo", at: date)?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("photo")).isEmpty)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 1)
        await fixture.controller.shutdown()
    }

    func testSourcePreflightKeepsTheDecisionWhenBackupWaitsForWiFi() async throws {
        let runtime = LibraryRuntimeState(
            initial: LibraryRuntimeSnapshot(
                network: LibraryNetworkState(isReachable: true, isExpensive: true)))
        let resolver = ScriptedBackupResolver(defaultModified: date)
        let fixture = try makeFixture(resolver, signals: .mobileDataOff(runtime))
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertFalse(fixture.controller.isBulkBackUpAgainAvailable)
        XCTAssertFalse(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(resolver.resolveCount(for: "photo"), 0)
        XCTAssertEqual(fixture.entry("photo", at: date)?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("photo")).isEmpty)
        XCTAssertNil(fixture.controller.bulkPhotoActions.summary, "a policy pause never starts a misleading run")
        await fixture.controller.shutdown()
    }

    func testSourceReadRechecksTheNetworkBeforeItsNetworkedFallback() async throws {
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: LibraryNetworkState()))
        let inner = ScriptedBackupResolver(defaultModified: date)
        let fixture = try makeFixture(
            NetworkChangingBulkResolver(inner: inner, runtime: runtime), signals: .mobileDataOff(runtime))
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        try fixture.park("untouched", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(inner.resolveCount(for: "photo"), 0)
        XCTAssertEqual(fixture.entry("photo", at: date)?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("photo")).isEmpty)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.processed, 1)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.cancelled, true)
        await fixture.controller.shutdown()
    }

    func testPolicyChangeFinishesTheAdmittedLocalReadAndStopsBeforeTheNextPhoto() async throws {
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: LibraryNetworkState()))
        let gate = BulkSourceReadGate()
        let resolver = HeldBulkSourceResolver(inner: ScriptedBackupResolver(defaultModified: date), gate: gate)
        let fixture = try makeFixture(resolver, signals: .mobileDataOff(runtime))
        defer { fixture.cleanup() }
        try fixture.park("first", at: date)
        try fixture.park("second", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        let readDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.hasStarted), ContinuousClock.now < readDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.hasStarted
        XCTAssertTrue(entered)
        runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: true) }
        let policyDeadline = ContinuousClock.now + .seconds(5)
        while fixture.controller.isBulkBackUpAgainAvailable, ContinuousClock.now < policyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(fixture.controller.isBulkBackUpAgainAvailable)
        await gate.release()
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        let states = [fixture.entry("first", at: date)?.state, fixture.entry("second", at: date)?.state]
        XCTAssertEqual(states.filter { $0 == .discovered }.count, 1)
        XCTAssertEqual(states.filter { $0 == .failedPermanent }.count, 1)
        XCTAssertEqual(
            fixture.controller.bulkPhotoActions.processed, 1, "The observer stops admission before the next row")
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 1)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 1)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.cancelled, true)
        await fixture.controller.shutdown()
    }

    func testSourceReadWaitsForTheSharedHeavyWorkPermit() async throws {
        let coordinator = LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let holderGate = BulkSourceReadGate()
        let holder = Task {
            try await coordinator.withHeavyPermit(LibraryWorkRequest(workload: .backupHashing, intent: .automatic)) {
                _ in
                await holderGate.hold()
            }
        }
        let holderDeadline = ContinuousClock.now + .seconds(5)
        while !(await holderGate.hasStarted), ContinuousClock.now < holderDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let resolver = ScriptedBackupResolver(defaultModified: date)
        let fixture = try makeFixture(resolver, coordinator: coordinator)
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        let waitDeadline = ContinuousClock.now + .seconds(5)
        while await coordinator.waitingPermitCount == 0, fixture.controller.bulkPhotoActions.summary == nil,
            ContinuousClock.now < waitDeadline
        { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await coordinator.waitingPermitCount
        XCTAssertEqual(waiting, 1)
        XCTAssertEqual(resolver.resolveCount(for: "photo"), 0, "no hashing beside the existing heavy work")
        await holderGate.release()
        try await holder.value
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        let metrics = await coordinator.metrics()
        XCTAssertEqual(metrics.permitsAcquired, 2)
        XCTAssertEqual(metrics.permitsReleased, 2)
        XCTAssertEqual(metrics.maximumConcurrentPermits, 1)
        XCTAssertEqual(fixture.entry("photo", at: date)?.state, .discovered)
        await fixture.controller.shutdown()
    }

    func testBulkUsesTheExistingDecisionAndKeepsUnavailableOrAlreadyHandledPhotos() async throws {
        let resolver = ScriptedBackupResolver(defaultModified: date)
        resolver.set(.missing, for: "missing")
        resolver.set(.transientFailure(times: 1), for: "unreadable")
        resolver.setModified(date.addingTimeInterval(1), for: "changed")
        let fixture = try makeFixture(resolver)
        defer { fixture.cleanup() }
        for id in ["good", "missing", "unreadable", "changed", "handled"] { try fixture.park(id, at: date) }
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertEqual(confirmation.count, 5)
        let handled = try XCTUnwrap(confirmation.items.first { $0.source?.identifier == "handled" })
        fixture.controller.keepDeleted(handled)
        let unchanged = ["missing", "unreadable", "changed"].map { fixture.entry($0, at: date) }

        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()

        XCTAssertEqual(fixture.entry("good", at: date)?.state, .discovered)
        XCTAssertNil(fixture.entry("good", at: date)?.lastError)
        XCTAssertEqual(fixture.journal.entry(for: fixture.source("good")).backUpAgainRevision, .init(date: date))
        XCTAssertEqual(["missing", "unreadable", "changed"].map { fixture.entry($0, at: date) }, unchanged)
        for id in ["missing", "unreadable", "changed"] {
            XCTAssertTrue(fixture.journal.entry(for: fixture.source(id)).isEmpty)
        }
        XCTAssertEqual(
            resolver.resolveCount(for: "handled"), 0, "An already handled row never reads its original again")
        XCTAssertEqual(fixture.entry("handled", at: date)?.state, .skippedRemoteDeletion)
        XCTAssertEqual(fixture.journal.entry(for: fixture.source("handled")).keptDeleted, true)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 1)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 4)
        XCTAssertFalse(fixture.controller.isSyncing, "backup is off; queuing never claims an upload completed")
        await fixture.controller.shutdown()
    }

    func testANewerDecisionAfterConfirmationNeverReceivesTheEarlierConsent() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
        defer { fixture.cleanup() }
        try fixture.park("edited", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        try fixture.park("edited", at: date.addingTimeInterval(1))
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(fixture.entry("edited", at: date)?.state, .failedPermanent)
        XCTAssertEqual(fixture.entry("edited", at: date.addingTimeInterval(1))?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("edited")).isEmpty)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 1)
        await fixture.controller.shutdown()
    }

    func testAnOlderSiblingAfterConfirmationStillRequiresFreshConsent() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
        defer { fixture.cleanup() }
        try fixture.park("edited", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        try fixture.park("edited", at: date.addingTimeInterval(-1))
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(fixture.entry("edited", at: date)?.state, .failedPermanent)
        XCTAssertEqual(fixture.entry("edited", at: date.addingTimeInterval(-1))?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("edited")).isEmpty)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
        await fixture.controller.shutdown()
    }

    func testAFailedDecisionReadAfterTheSourceReadRefusesTheDecisionEvenWithTheFullRevisionSet() async throws {
        let gate = BulkSourceReadGate()
        let fixture = try makeFixture(
            HeldBulkSourceResolver(inner: ScriptedBackupResolver(defaultModified: date), gate: gate))
        defer { fixture.cleanup() }
        try fixture.park("held", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        let stored = try XCTUnwrap(Mirror(reflecting: fixture.controller).children.first { $0.label == "queueStore" })
        let queue = try XCTUnwrap(
            Mirror(reflecting: stored.value).children.first?.value as? UploadBackupSyncQueueManifestStore)
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.hasStarted), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.hasStarted
        XCTAssertTrue(entered)
        // The decision's own read of the revisions fails after the source read, after it returned the whole parked
        // set: a newer, completed revision follows the parked one. A health check that passes again afterwards
        // proves nothing about that read.
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: fixture.source("held"), revision: UploadBackupRevision(date: date.addingTimeInterval(60)),
                    originalFilename: "held.heic", state: .completed, updatedAt: date)))
        // Other statements contain the same text (a removal and two existence checks). The test relies on none of them
        // running on this connection before the keyed revision read. If one did, it would take the fault's one match
        // without returning two rows, the keyed read would run without the fault, and XCTAssertTrue(fault.fired) below
        // fails loudly.
        let fault = try SQLiteReadInterrupt(
            in: queue, matching: "FROM backup_sync_queue WHERE source_kind=? AND source_id=?", afterRows: 2)
        defer { fault.stop() }
        await gate.release()
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertTrue(fault.fired, "the decision's revision read failed")
        XCTAssertTrue(queue.isOperational(), "the transient interrupt is forgotten once the database answers")
        XCTAssertEqual(fixture.entry("held", at: date)?.state, .failedPermanent)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("held")).isEmpty)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
        await fixture.controller.shutdown()
    }

    func testOnePhotoReopensItsCapturedSiblingRevisionsOnce() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date.addingTimeInterval(1)))
        defer { fixture.cleanup() }
        try fixture.park("edited", at: date)
        try fixture.park("edited", at: date.addingTimeInterval(1))
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        XCTAssertEqual(confirmation.count, 1)
        XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(fixture.entry("edited", at: date)?.state, .dismissedFailure)
        XCTAssertEqual(fixture.entry("edited", at: date.addingTimeInterval(1))?.state, .discovered)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 1)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 0)
        await fixture.controller.shutdown()
    }

    /// The second sibling write of the photo fails once: the photo counts as unchanged, so no revision may have
    /// changed and no consent may remain.
    #if DEBUG
        func testAFailedSiblingWriteCountsThePhotoUnchangedAndChangesNoRevision() async throws {
            let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date.addingTimeInterval(1)))
            defer { fixture.cleanup() }
            try fixture.park("edited", at: date)
            try fixture.park("edited", at: date.addingTimeInterval(1))
            let before = [fixture.entry("edited", at: date), fixture.entry("edited", at: date.addingTimeInterval(1))]
            let captured = await fixture.controller.prepareBackUpAgain()
            let confirmation = try XCTUnwrap(captured)
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let fault = try SQLiteReadInterrupt(in: queue, matching: "attempts=COALESCE(?, attempts)", occurrence: 2)
            defer { fault.stop() }
            XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
            await fixture.controller.bulkPhotoActions.waitUntilFinished()
            XCTAssertTrue(fault.fired, "the second sibling write must actually fail")
            XCTAssertEqual(
                [fixture.entry("edited", at: date), fixture.entry("edited", at: date.addingTimeInterval(1))], before,
                "a photo counted as unchanged must have no reopened or dismissed revision")
            XCTAssertTrue(fixture.journal.entry(for: fixture.source("edited")).isEmpty)
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 1)
            await fixture.controller.shutdown()
        }
    #endif

    func testCancellationDuringSourceReadNeverChangesTheDecisionOrJournal() async throws {
        let gate = BulkSourceReadGate()
        let fixture = try makeFixture(
            HeldBulkSourceResolver(inner: ScriptedBackupResolver(defaultModified: date), gate: gate))
        defer { fixture.cleanup() }
        try fixture.park("held", at: date)
        let before = fixture.entry("held", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        let started = fixture.controller.startBackUpAgain(confirmation)
        XCTAssertTrue(started)
        if started {
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await gate.hasStarted), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let reached = await gate.hasStarted
            XCTAssertTrue(reached)
        }
        fixture.controller.bulkPhotoActions.cancel()
        await gate.release()
        await fixture.controller.bulkPhotoActions.waitUntilFinished()
        XCTAssertEqual(fixture.entry("held", at: date), before)
        XCTAssertTrue(fixture.journal.entry(for: fixture.source("held")).isEmpty)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
        XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.stayed, 1)
        await fixture.controller.shutdown()
    }

    func testShutdownRevokesAnAlreadyPreparedControllerConfirmation() async throws {
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        await fixture.controller.shutdown()
        XCTAssertFalse(fixture.controller.startBackUpAgain(confirmation))
        XCTAssertNil(fixture.controller.bulkPhotoActions.confirmation)
    }

    #if DEBUG
        func testASuccessfulBatchStartsOneNormalPassOnlyAfterTheBatchAndAnUnchangedBatchStartsNone() async throws {
            for succeeds in [true, false] {
                let resolver = ScriptedBackupResolver(defaultModified: date)
                if !succeeds {
                    resolver.set(.missing, for: "first")
                    resolver.set(.missing, for: "second")
                }
                let fixture = try makeFixture(resolver, hasIdentityResolver: true)
                defer { fixture.cleanup() }
                let passGate = BulkSourceReadGate()
                fixture.controller.replacePassBodyForTesting { await passGate.hold() }
                fixture.controller.setEnabledForTesting()
                fixture.controller.setAccessStateForTesting(.full)
                var starts = 0
                fixture.controller.idleTimerHook = { running in
                    if running {
                        starts += 1
                        XCTAssertFalse(
                            fixture.controller.bulkPhotoActions.isRunning, "The pass starts after all bulk choices")
                        XCTAssertEqual(fixture.controller.bulkPhotoActions.processed, 2)
                    }
                }
                try fixture.park("first", at: date)
                try fixture.park("second", at: date)
                let captured = await fixture.controller.prepareBackUpAgain()
                let confirmation = try XCTUnwrap(captured)
                XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
                await fixture.controller.bulkPhotoActions.waitUntilFinished()
                if succeeds {
                    let deadline = ContinuousClock.now + .seconds(3)
                    while starts == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                } else {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(starts, succeeds ? 1 : 0)
                XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, succeeds ? 2 : 0)
                await passGate.release()
                await fixture.controller.shutdown()
            }
        }
    #endif

    #if DEBUG
        func testShutdownJoinsAHeldSourceReadRetiresTheRunnerAndLeavesTheDecisionUnchanged() async throws {
            let gate = BulkSourceReadGate()
            let fixture = try makeFixture(
                HeldBulkSourceResolver(inner: ScriptedBackupResolver(defaultModified: date), gate: gate),
                hasIdentityResolver: true)
            defer { fixture.cleanup() }
            fixture.controller.setEnabledForTesting()
            fixture.controller.setAccessStateForTesting(.full)
            fixture.controller.replacePassBodyForTesting {}
            var starts = 0
            fixture.controller.idleTimerHook = { if $0 { starts += 1 } }
            try fixture.park("held", at: date)
            let captured = await fixture.controller.prepareBackUpAgain()
            let confirmation = try XCTUnwrap(captured)
            XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await gate.hasStarted), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let entered = await gate.hasStarted
            XCTAssertTrue(entered)
            var returned = false
            let shutdown = Task {
                await fixture.controller.shutdown()
                returned = true
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(returned, "Shutdown must join the non-cancellable admitted read before closing stores")
            XCTAssertTrue(fixture.controller.bulkPhotoActions.isRunning)
            await gate.release()
            await shutdown.value
            XCTAssertTrue(returned)
            XCTAssertFalse(fixture.controller.bulkPhotoActions.isRunning)
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.cancelled, true)
            XCTAssertEqual(fixture.entry("held", at: date)?.state, .failedPermanent)
            XCTAssertTrue(fixture.journal.entry(for: fixture.source("held")).isEmpty)
            XCTAssertEqual(starts, 0)
            XCTAssertNil(fixture.controller.bulkPhotoActions.prepare(confirmation.items, action: .backUpAgain))
        }
    #endif

    func testPolicyPauseDismissesPendingConsentBeforeAStart() async throws {
        let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: LibraryNetworkState()))
        let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date), signals: .mobileDataOff(runtime))
        defer { fixture.cleanup() }
        try fixture.park("photo", at: date)
        let captured = await fixture.controller.prepareBackUpAgain()
        let confirmation = try XCTUnwrap(captured)
        runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: true) }
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.controller.bulkPhotoActions.confirmation != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(fixture.controller.bulkPhotoActions.confirmation)
        XCTAssertFalse(fixture.controller.isBulkBackUpAgainAvailable)
        XCTAssertFalse(fixture.controller.startBackUpAgain(confirmation))
        await fixture.controller.shutdown()
    }

    func testAccessRefusalBeforeAndAfterSourceReadKeepsTheDecision() async throws {
        for afterRead in [false, true] {
            var access = PhotoBackupAccessState.full
            let gate = BulkSourceReadGate()
            let inner = ScriptedBackupResolver(defaultModified: date)
            let fixture = try makeFixture(HeldBulkSourceResolver(inner: inner, gate: gate), access: { access })
            defer { fixture.cleanup() }
            try fixture.park("photo", at: date)
            let captured = await fixture.controller.prepareBackUpAgain()
            let confirmation = try XCTUnwrap(captured)
            if !afterRead { access = .denied }
            XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
            if afterRead {
                let deadline = ContinuousClock.now + .seconds(3)
                while !(await gate.hasStarted), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let entered = await gate.hasStarted
                XCTAssertTrue(entered)
                access = .denied
            }
            await gate.release()
            await fixture.controller.bulkPhotoActions.waitUntilFinished()
            XCTAssertEqual(fixture.entry("photo", at: date)?.state, .failedPermanent)
            XCTAssertTrue(fixture.journal.entry(for: fixture.source("photo")).isEmpty)
            XCTAssertEqual(inner.resolveCount(for: "photo"), afterRead ? 1 : 0)
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
            await fixture.controller.shutdown()
        }
    }

    func testPreflightRefusesChangedStateAndChangedReasonBeforeReadingTheSource() async throws {
        for changesState in [true, false] {
            let resolver = ScriptedBackupResolver(defaultModified: date)
            let fixture = try makeFixture(resolver)
            defer { fixture.cleanup() }
            try fixture.park("photo", at: date)
            let captured = await fixture.controller.prepareBackUpAgain()
            let confirmation = try XCTUnwrap(captured)
            XCTAssertTrue(
                fixture.queue.updateState(
                    source: fixture.source("photo"), revision: .init(date: date),
                    state: changesState ? .failed : .failedPermanent, attempts: nil,
                    lastError: BackupIssueRecord(
                        kind: changesState ? .deletedElsewhere : .permission, detail: "Changed"
                    ).persistedValue,
                    updatedAt: date))
            XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
            await fixture.controller.bulkPhotoActions.waitUntilFinished()
            XCTAssertEqual(resolver.resolveCount(for: "photo"), 0)
            XCTAssertTrue(fixture.journal.entry(for: fixture.source("photo")).isEmpty)
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
            await fixture.controller.shutdown()
        }
    }

    func testPreflightRefusesMissingJournalAndNonPrimaryPhotoNamespaces() async throws {
        let sources: [(UploadSourceIdentity, Bool)] = [
            (.init(kind: .photoLibraryAsset, identifier: "photo"), false),
            (.init(kind: .fileURL, identifier: "photo"), true),
            (.init(kind: .photoLibraryAsset, identifier: "photo", resource: .livePairedVideo), true),
        ]
        for (source, hasJournal) in sources {
            let resolver = ScriptedBackupResolver(defaultModified: date)
            let fixture = try makeFixture(resolver, hasJournal: hasJournal)
            defer { fixture.cleanup() }
            XCTAssertTrue(
                fixture.queue.upsert(
                    .init(
                        source: source, revision: .init(date: date), originalFilename: "photo.heic",
                        state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)))
            let captured = await fixture.controller.prepareBackUpAgain()
            let confirmation = try XCTUnwrap(captured)
            XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
            await fixture.controller.bulkPhotoActions.waitUntilFinished()
            XCTAssertEqual(resolver.resolveCount(for: "photo"), 0)
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 0)
            await fixture.controller.shutdown()
        }
    }

    #if DEBUG
        func testFailedFullCaptureUsesTheExistingFixedActionMessage() async throws {
            let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
            defer { fixture.cleanup() }
            try fixture.park("photo", at: date)
            let session = fixture.controller.makeProblemListSession()
            session.requestRefresh()
            await session.waitUntilIdle()
            XCTAssertEqual(session.decisionCount, 1)
            fixture.controller.queueStoreForTesting?.close()
            let confirmation = await fixture.controller.prepareBackUpAgain()
            XCTAssertNil(confirmation)
            XCTAssertEqual(session.fixedActionMessage, L10n.string("backup.error_local_state_unavailable"))
            XCTAssertEqual(session.decisionCount, 1, "The failed read retains the visible count and rows")
            await session.shutdown()
            await fixture.controller.shutdown()
        }
    #endif

    #if DEBUG
        func testCancelledCompletionNeverStartsANormalPassEvenAfterACommittedChoice() async throws {
            let gate = BulkSourceReadGate()
            let fixture = try makeFixture(
                HeldBulkSourceResolver(inner: ScriptedBackupResolver(defaultModified: date), gate: gate),
                hasIdentityResolver: true)
            defer { fixture.cleanup() }
            fixture.controller.setEnabledForTesting()
            fixture.controller.setAccessStateForTesting(.full)
            fixture.controller.replacePassBodyForTesting {}
            var starts = 0
            fixture.controller.idleTimerHook = { if $0 { starts += 1 } }
            try fixture.park("held", at: date)
            let captured = await fixture.controller.prepareBackUpAgain()
            let confirmation = try XCTUnwrap(captured)
            XCTAssertTrue(fixture.controller.startBackUpAgain(confirmation))
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await gate.hasStarted), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let owned = try XCTUnwrap(
                Mirror(reflecting: fixture.controller).children.first { $0.label == "_bulkCompletionTask" })
            let completion = try XCTUnwrap(Mirror(reflecting: owned.value).children.first?.value as? Task<Void, Never>)
            completion.cancel()
            await gate.release()
            await fixture.controller.bulkPhotoActions.waitUntilFinished()
            await completion.value
            XCTAssertEqual(fixture.controller.bulkPhotoActions.summary?.completed, 1)
            XCTAssertEqual(starts, 0, "A cancelled completion must not request a normal pass")
            await fixture.controller.shutdown()
        }
    #endif

    #if DEBUG
        func testEmptyCancelledAndRetiredCapturesDoNotShowAnError() async throws {
            let empty = try makeFixture(ScriptedBackupResolver(defaultModified: date))
            defer { empty.cleanup() }
            let emptySession = empty.controller.makeProblemListSession()
            let capturedEmpty = await empty.controller.prepareBackUpAgain()
            XCTAssertNil(capturedEmpty)
            XCTAssertNil(emptySession.fixedActionMessage)
            await emptySession.shutdown()
            await empty.controller.shutdown()
            for retires in [false, true] {
                let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
                defer { fixture.cleanup() }
                try fixture.park("held", at: date)
                let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
                let connection = try XCTUnwrap(
                    Mirror(reflecting: queue).children.first { $0.label == "connection" }?.value
                        as? SQLiteStoreConnection)
                let gate = BulkControllerSnapshotGate()
                queue.onProblemReadEvent = { if case .willLock = $0 { gate.holdOnce() } }
                let session = fixture.controller.makeProblemListSession()
                let capture = Task { await fixture.controller.prepareBackUpAgain() }
                let deadline = ContinuousClock.now + .seconds(3)
                while !gate.hasStarted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertTrue(gate.hasStarted)
                connection.withLock { connection.markFailed(resultCode: SQLITE_INTERRUPT) }
                var shutdown: Task<Void, Never>?
                if retires {
                    shutdown = Task { await fixture.controller.shutdown() }
                    while fixture.controller.isBulkBackUpAgainAvailable, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertFalse(fixture.controller.isBulkBackUpAgainAvailable)
                } else {
                    capture.cancel()
                }
                gate.release()
                let confirmation = await capture.value
                await shutdown?.value
                XCTAssertNil(confirmation)
                XCTAssertNil(session.fixedActionMessage, "Cancellation and retirement are not preparation errors")
                await session.shutdown()
                await fixture.controller.shutdown()
            }
        }
    #endif

    #if DEBUG
        func testFreshPreparationClearsThePreviousFixedError() async throws {
            let fixture = try makeFixture(ScriptedBackupResolver(defaultModified: date))
            defer { fixture.cleanup() }
            try fixture.park("photo", at: date)
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let session = fixture.controller.makeProblemListSession()
            // A transaction that stays open refuses the preparation's read and keeps the store stopped while it is open.
            let connection = try storeConnection(queue)
            connection.withLock {
                XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            }
            let failed = await fixture.controller.prepareBackUpAgain()
            connection.withLock {
                XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
            }
            XCTAssertNil(failed)
            XCTAssertEqual(session.fixedActionMessage, L10n.string("backup.error_local_state_unavailable"))
            let fresh = await fixture.controller.prepareBackUpAgain()
            XCTAssertEqual(fresh?.count, 1)
            XCTAssertNil(session.fixedActionMessage)
            await session.shutdown()
            await fixture.controller.shutdown()
        }
    #endif

    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let controller: PhotoLibraryBackupController
        let journal: EditReplacementJournalFileStore
        let queue: UploadBackupSyncQueueManifestStore

        func source(_ id: String) -> UploadSourceIdentity { .init(kind: .photoLibraryAsset, identifier: id) }
        func entry(_ id: String, at date: Date) -> UploadBackupSyncQueueEntry? {
            do { return try queue.entry(for: source(id), revision: .init(date: date)) } catch {
                XCTFail("Fixture queue read failed: \(error)")
                return nil
            }
        }
        func park(_ id: String, at date: Date) throws {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: source(id), revision: .init(date: date), originalFilename: "\(id).heic",
                        state: .failedPermanent,
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue,
                        updatedAt: date)))
        }
        func cleanup() {
            queue.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture(
        _ resolver: any BackupResourceResolving, signals: BackupRuntimeSignalSource = .wiFiWithMobileDataOff,
        coordinator: LibraryResourceCoordinator? = nil, hasJournal: Bool = true,
        hasIdentityResolver: Bool = false, access: @escaping () -> PhotoBackupAccessState = { .full }
    ) throws -> Fixture {
        let suite = "bulk-decision-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        var config = PhotoLibraryBackupController.Configuration(
            accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults,
            runtimeSignals: signals)
        config.currentAccessState = access
        config.bulkResourceResolver = resolver
        config.bulkResourceCoordinator = coordinator ?? LibraryResourceCoordinator(runtimeState: LibraryRuntimeState())
        let controller = PhotoLibraryBackupController(
            configuration: config, identityResolver: hasIdentityResolver ? FakeIdentityResolver() : nil,
            uploader: MockUploader(), replacementJournal: hasJournal ? journal : nil)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        return Fixture(
            directory: directory, defaults: defaults, suite: suite, controller: controller, journal: journal,
            queue: queue)
    }
}

private actor BulkSourceReadGate {
    private(set) var hasStarted = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        hasStarted = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private struct HeldBulkSourceResolver: BackupResourceResolving {
    let inner: ScriptedBackupResolver
    let gate: BulkSourceReadGate
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        await gate.hold()
        return try await inner.resolve(entry)
    }
}

private struct NetworkChangingBulkResolver: BackupResourceResolving {
    let inner: ScriptedBackupResolver
    let runtime: LibraryRuntimeState
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await inner.resolve(entry)
    }
    func resolve(
        _ entry: UploadBackupSyncQueueEntry, onPreparationProgress: @escaping BackupResourcePreparationHandler,
        readAdmission: @escaping BackupResourceReadAdmission
    ) async throws -> BackupResolvedResource? {
        try readAdmission()
        runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: true) }
        try readAdmission()
        return try await inner.resolve(entry)
    }
}

private struct SwappedBulkSourceResolver: BackupResourceResolving {
    let inner: ScriptedBackupResolver
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        let other = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "other-photo"), revision: entry.revision,
            originalFilename: entry.originalFilename, updatedAt: entry.updatedAt)
        return try await inner.resolve(other)
    }
}

private final class BulkControllerSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    func holdOnce() {
        let shouldHold = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        if shouldHold { _ = semaphore.wait(timeout: .now() + 5) }
    }
    func release() { semaphore.signal() }
}
