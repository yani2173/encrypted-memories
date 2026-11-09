import Foundation
import PhotosCore
import SQLite3
import UploadFeature
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

@MainActor
final class PhotoLibraryBackupControllerStateTests: XCTestCase {
    func testShutdownReleasesTheControllerAndItsRuntimeSignals() async throws {
        var runtime: LibraryRuntimeState? = LibraryRuntimeState()
        weak var releasedRuntime = runtime
        var fixture: ControllerFixture? = try makeControllerFixture(
            prefix: "backup-deallocation",
            runtimeSignals: BackupRuntimeSignalSource(
                current: { [state = runtime!] in BackupThrottleInputs(runtime: state.snapshot(), usesMobileData: false)
                },
                updates: { [state = runtime!] in state.updates() }))
        let defaults = fixture!.defaults
        let suite = fixture!.suite
        let directory = fixture!.directory
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        weak var releasedController = fixture?.controller
        await fixture?.controller.shutdown()
        fixture = nil
        runtime = nil
        _ = await waitUntil { releasedController == nil && releasedRuntime == nil }
        XCTAssertNil(releasedController)
        XCTAssertNil(releasedRuntime, "The network observer must release its signal source after shutdown")
    }

    func testFailedItemsClassifyReasonsWithoutDisplayingTechnicalDetails() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-issue-projection")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let cases: [(BackupIssueKind, UploadBackupSyncQueueState, BackupIssueCategory, String)] = [
            (.network, .discovered, .automatic, "backup.issue_network"),
            (.remoteService, .discovered, .automatic, "backup.issue_remote_service"),
            (.deviceStorage, .discovered, .automatic, "backup.issue_device_storage"),
            (.remoteDraft, .blockedByDraft, .automatic, "backup.issue_remote_draft"),
            (.accountStorage, .discovered, .userResolvable, "backup.issue_account_storage"),
            (.permission, .failed, .userResolvable, "backup.issue_permission"),
            (.deletedElsewhere, .failedPermanent, .decision, "backup.issue_deleted_elsewhere"),
            (.remoteDraftStale, .failedPermanent, .permanent, "backup.issue_remote_draft_stale"),
            (.sourceMissing, .sourceMissing, .permanent, "backup.issue_source_missing"),
            (.unsupported, .failed, .permanent, "backup.issue_unsupported"),
            (.unknown, .failed, .userResolvable, "backup.fail_reason_generic"),
            (.unknown, .discovered, .automatic, "backup.issue_unknown_waiting"),
            (.remoteService, .failed, .userResolvable, "backup.issue_remote_service"),
            (.network, .failed, .userResolvable, "backup.issue_network"),
            (.localState, .failed, .userResolvable, "backup.error_local_state_unavailable"),
            (.unknown, .failedPermanent, .permanent, "backup.issue_permanent"),
        ]
        for (index, testCase) in cases.enumerated() {
            let (kind, state, category, key) = testCase
            let entry = UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: "reason-\(index)"),
                revision: .init(rawValue: 1), originalFilename: "reason-\(index).heic", state: state,
                lastError: BackupIssueRecord(kind: kind, detail: "PRIVATE SERVER DETAIL").persistedValue,
                updatedAt: Date())
            XCTAssertTrue(queue.upsert(entry))
            let item = try XCTUnwrap(fixture.controller.failedItems().first { $0.source == entry.source })
            XCTAssertEqual(item.category, category, "\(kind), \(state)")
            XCTAssertEqual(item.reason, L10n.string(dynamicKey: key), "\(kind), \(state)")
            XCTAssertEqual(item.technicalDetail, "PRIVATE SERVER DETAIL")
            XCTAssertFalse(item.reason.contains("PRIVATE"))
            XCTAssertEqual(item.isPermanent, category == .permanent || state == .failedPermanent)
        }
        let unsupported = try XCTUnwrap(fixture.controller.failedItems().first { $0.issue == .unsupported })
        fixture.controller.dismissFailedItem(unsupported)
        XCTAssertEqual(
            try queue.entry(for: try XCTUnwrap(unsupported.source), revision: try XCTUnwrap(unsupported.revision))?
                .state,
            .dismissedFailure)
        XCTAssertFalse(fixture.controller.failedItems().contains { $0.id == unsupported.id })
        XCTAssertEqual(queue.summary()!.resolved, 0, "dismissal is not a successful backup")
        await fixture.controller.shutdown()
    }

    /// A failed item shows the error that stopped it, and the person can stop backing it up.
    func testFailedItemShowsItsErrorAndCanBeDismissedWithoutRetry() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-failed-dismissal")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        func row(_ id: String, _ kind: BackupIssueKind, _ state: UploadBackupSyncQueueState, detail: String)
            -> UploadBackupSyncQueueEntry
        {
            UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                originalFilename: "\(id).mp4", state: state, attempts: 8,
                lastError: BackupIssueRecord(kind: kind, detail: detail).persistedValue, updatedAt: Date())
        }
        let failed = row("failed", .remoteService, .failed, detail: "  Proton rejected the file  ")
        let keyed = row("keyed", .remoteService, .failed, detail: "backup.issue_remote_service")
        let waiting = row("waiting", .remoteService, .discovered, detail: "Proton rejected the file")
        let reopened = row("reopened", .remoteService, .failed, detail: "Proton rejected the file")
        for entry in [failed, keyed, waiting, reopened] { XCTAssertTrue(queue.upsert(entry)) }

        let items = fixture.controller.failedItems()
        func item(_ entry: UploadBackupSyncQueueEntry) throws -> BackupFailedItem {
            try XCTUnwrap(items.first { $0.source == entry.source })
        }
        let failedItem = try item(failed)
        XCTAssertEqual(failedItem.failureDetail, "Proton rejected the file")
        XCTAssertTrue(failedItem.isDismissible)
        XCTAssertFalse(failedItem.isPermanent)
        XCTAssertNil(try item(keyed).failureDetail, "an app reason key is not an error message")
        XCTAssertNil(try item(waiting).failureDetail, "a row that retries by itself shows no error")
        XCTAssertFalse(try item(waiting).isDismissible)

        fixture.controller.dismissFailedItem(failedItem)
        let dismissed = try XCTUnwrap(queue.entry(for: failed.source, revision: failed.revision))
        XCTAssertEqual(dismissed.state, .dismissedFailure)
        XCTAssertEqual(dismissed.lastError, failed.lastError)
        XCTAssertFalse(fixture.controller.failedItems().contains { $0.id == failedItem.id })
        XCTAssertEqual(queue.summary().resolved, 0, "dismissal is not a successful backup")
        XCTAssertEqual(queue.summary().dismissedFailures, 1)

        // Try again reopened the row after the list was read: the dismissal must leave it backing up.
        let reopenedItem = try item(reopened)
        XCTAssertTrue(queue.reopenForUserRetry(reopened, attempts: 0, updatedAt: Date()))
        fixture.controller.dismissFailedItem(reopenedItem)
        XCTAssertEqual(queue.entry(for: reopened.source, revision: reopened.revision)?.state, .discovered)

        await fixture.controller.retryUserResolvableWork()
        XCTAssertEqual(
            queue.entry(for: failed.source, revision: failed.revision)?.state, .dismissedFailure,
            "Try again must not bring a dismissed item back")
        await fixture.controller.shutdown()
    }

    /// A list read that started before the person dismissed a row must not bring that row back.
    func testProblemListReadOvertakenByADismissalIsReadAgain() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-overtaken")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let entry = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "unsupported"),
            revision: .init(rawValue: 1), originalFilename: "unsupported.heic", state: .failed,
            lastError: BackupIssueRecord(kind: .unsupported, detail: "").persistedValue, updatedAt: Date())
        XCTAssertTrue(queue.upsert(entry))
        let controller = fixture.controller
        let item = try XCTUnwrap(controller.failedItems().first)

        var reads = 0
        var shown: [[String]] = []
        let order = BackupProblemListReadOrder()
        await controller.applyCurrentProblemList(
            order: order, generation: order.begin(),
            {
                reads += 1
                let items = controller.failedItems()
                // The person dismisses the row while the first read is under way.
                if reads == 1 { controller.dismissFailedItem(item) }
                return items
            },
            { shown.append($0.map(\.id)) })

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(shown, [[]], "the read from before the dismissal must not be shown")
        await controller.shutdown()
    }

    func testFailedItemsOmitFreshRowsAndExplainCameraAndOriginalWaits() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-wait-projection")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        for (id, state) in [("fresh", UploadBackupSyncQueueState.discovered), ("queued", .queuedForUpload)] {
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                        originalFilename: id, state: state, updatedAt: Date())))
        }
        XCTAssertTrue(fixture.controller.failedItems().isEmpty)
        XCTAssertFalse(fixture.controller.failedItems().offersUserRetry)
        for key in [
            "error.upload_source_not_ready", "backup.issue_waiting_original",
            "The edited photo is waiting for its original resources. Backup will retry automatically.",
            "Das bearbeitete Foto wartet auf seine Originalressourcen. Das Backup versucht es automatisch erneut.",
        ] {
            let record = BackupIssueRecord(kind: .unknown, detail: key, nextAttemptAt: .distantFuture)
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: key), revision: .init(rawValue: 1),
                        originalFilename: key, state: .discovered, lastError: record.persistedValue,
                        updatedAt: Date().addingTimeInterval(3_600))))
        }
        let items = fixture.controller.failedItems()
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0.category == .automatic && $0.retryDescription != nil })
        XCTAssertEqual(
            items.first { $0.filename == "error.upload_source_not_ready" }?.reason,
            L10n.string("backup.issue_source_not_ready"))
        XCTAssertEqual(
            items.first { $0.filename == "backup.issue_waiting_original" }?.reason,
            L10n.string("backup.issue_waiting_original"))
        XCTAssertTrue(
            items.filter { $0.filename != "error.upload_source_not_ready" }
                .allSatisfy { $0.reason == L10n.string("backup.issue_waiting_original") })
        XCTAssertFalse(fixture.controller.failedItems().offersUserRetry)
        XCTAssertTrue(fixture.controller.failedItems(limit: 0).isEmpty)
        await fixture.controller.shutdown()
    }

    func testUserResolvableRetryPreservesAutomaticDatesAndEveryIssueRecord() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-scoped-retry")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let future = Date().addingTimeInterval(3_600)
        let cases: [(String, BackupIssueKind, UploadBackupSyncQueueState)] = [
            ("network", .network, .discovered), ("draft", .remoteDraft, .blockedByDraft),
            ("quota", .accountStorage, .discovered), ("permission", .permission, .failed),
            ("terminal-service", .remoteService, .failed), ("unsupported", .unsupported, .failed),
            ("decision", .deletedElsewhere, .failedPermanent),
        ]
        var entries: [UploadBackupSyncQueueEntry] = []
        for (id, kind, state) in cases {
            let entry = UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
                originalFilename: id, state: state, attempts: 8,
                lastError: BackupIssueRecord(kind: kind, detail: "detail", nextAttemptAt: future).persistedValue,
                updatedAt: future)
            XCTAssertTrue(queue.upsert(entry))
            entries.append(entry)
        }
        XCTAssertTrue(fixture.controller.failedItems().offersUserRetry)
        let beforeRetry = Date()
        await fixture.controller.retryUserResolvableWork()
        let afterRetry = Date()
        for entry in entries {
            let row = try XCTUnwrap(queue.entry(for: entry.source, revision: entry.revision))
            XCTAssertEqual(row.lastError, entry.lastError, entry.originalFilename)
            let isClassB = ["quota", "permission", "terminal-service"].contains(entry.originalFilename)
            if isClassB {
                XCTAssertEqual(row.state, .discovered)
                XCTAssertEqual(row.attempts, entry.state == .failed ? 0 : entry.attempts)
                // SQLite keeps the date as a double, which can round it a fraction of a microsecond earlier.
                XCTAssertGreaterThanOrEqual(
                    row.updatedAt.timeIntervalSince1970, beforeRetry.timeIntervalSince1970 - 0.001)
                XCTAssertLessThanOrEqual(row.updatedAt.timeIntervalSince1970, afterRetry.timeIntervalSince1970 + 0.001)
            } else {
                // SQLite keeps the date as a double, so compare it within a millisecond.
                XCTAssertEqual(
                    row.updatedAt.timeIntervalSince1970, entry.updatedAt.timeIntervalSince1970, accuracy: 0.001)
                var unchanged = row
                unchanged.updatedAt = entry.updatedAt
                XCTAssertEqual(
                    unchanged, entry, "a scoped retry must not change automatic, decision, or permanent work")
            }
        }
        await fixture.controller.shutdown()
    }

    func testManyFreshOrPermanentRowsCannotHideAPhotoThePersonCanFix() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-limit")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let now = Date()
        for index in 0..<250 {
            // Newer revisions sort first. Fresh rows have no reason, legacy rows carry an earlier build's message,
            // and permanent rows are not the person's to fix.
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "fresh-\(index)"),
                        revision: .init(rawValue: 1_000 + Int64(index)), originalFilename: "fresh", state: .discovered,
                        updatedAt: now)))
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "legacy-\(index)"),
                        revision: .init(rawValue: 2_000 + Int64(index)), originalFilename: "legacy",
                        state: .discovered, lastError: "An earlier build's message", updatedAt: now)))
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "unsupported-\(index)"),
                        revision: .init(rawValue: 500 + Int64(index)), originalFilename: "unsupported",
                        state: .failed, attempts: 8,
                        lastError: BackupIssueRecord(kind: .unsupported, detail: "x").persistedValue,
                        updatedAt: now)))
        }
        let quota = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
            originalFilename: "quota.heic", state: .discovered,
            lastError: BackupIssueRecord(
                kind: .accountStorage, detail: "full", nextAttemptAt: now.addingTimeInterval(21_600)
            ).persistedValue, updatedAt: now.addingTimeInterval(21_600))
        XCTAssertTrue(queue.upsert(quota))

        let items = fixture.controller.failedItems()
        XCTAssertEqual(items.count, 200)
        XCTAssertFalse(items.contains { $0.filename == "fresh" || $0.filename == "legacy" })
        XCTAssertEqual(items.first?.filename, "quota.heic", "a photo the person can fix leads the list")
        XCTAssertTrue(items.offersUserRetry)
        await fixture.controller.retryUserResolvableWork()
        let reopened = try XCTUnwrap(queue.entry(for: quota.source, revision: quota.revision))
        XCTAssertLessThan(reopened.updatedAt, now.addingTimeInterval(60))
        // The reason stays, but the date the list and the scheduler use is the row's own, earlier date.
        let item = try XCTUnwrap(fixture.controller.failedItems(limit: 1_000).first { $0.filename == "quota.heic" })
        XCTAssertLessThan(try XCTUnwrap(item.nextAttemptAt), now.addingTimeInterval(60))
        await fixture.controller.shutdown()
    }

    /// A user retry whose reopen fails must not look complete (#1228). The interrupted UPDATE records a transient
    /// failure, and the health probe after the loop forgets it once the database answers again. Only the recorded
    /// failure count shows that the row was not reopened, so the retry reports the unavailable local state.
    func testUserResolvableRetryReportsAReopenThatFailed() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-retry-reopen-failure")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let future = Date().addingTimeInterval(3_600)
        let entry = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
            originalFilename: "quota", state: .failed, attempts: 8,
            lastError: BackupIssueRecord(kind: .accountStorage, detail: "detail", nextAttemptAt: future).persistedValue,
            updatedAt: future)
        XCTAssertTrue(queue.upsert(entry))
        XCTAssertTrue(fixture.controller.failedItems().offersUserRetry)
        let controllerQueue = try XCTUnwrap(
            Mirror(reflecting: fixture.controller).children.first { $0.label == "queueStore" }?.value
                as? UploadBackupSyncQueueManifestStore)
        let interrupt = try SQLiteReadInterrupt(
            in: controllerQueue, matching: "UPDATE backup_sync_queue SET state = 'discovered', attempts = ?")
        defer { interrupt.stop() }

        await fixture.controller.retryUserResolvableWork()

        XCTAssertTrue(interrupt.fired, "The armed interrupt really failed the reopen")
        XCTAssertEqual(
            fixture.controller.lastMessage, L10n.string("backup.error_local_state_unavailable"),
            "A reopen that failed must not look like a finished retry")
        let row = try XCTUnwrap(queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(row.state, .failed, "The row was not reopened")
        XCTAssertEqual(row.attempts, 8)
        await fixture.controller.shutdown()
    }

    func testAPhotoThePersonCanFixLeadsTheListBehindThousandsOfWaitingPhotos() async throws {
        let fixture = try makeControllerFixture(prefix: "backup-problem-offline-library")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        XCTAssertTrue(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
                    originalFilename: "quota.heic", state: .failed, attempts: 8,
                    lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue,
                    updatedAt: Date())))
        // An offline pass gives every photo of a large library a reason. Newer revisions sort first.
        let later = Date().addingTimeInterval(3_600)
        let offline = BackupIssueRecord(kind: .network, detail: "offline", nextAttemptAt: later).persistedValue
        XCTAssertTrue(
            queue.upsertBatch(
                (0..<2_500).map { index in
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: .photoLibraryAsset, identifier: "offline-\(index)"),
                        revision: .init(rawValue: 1_000 + Int64(index)), originalFilename: "offline",
                        state: .discovered, lastError: offline, updatedAt: later)
                }))
        let items = await fixture.controller.problemItems()
        XCTAssertEqual(items.count, 200)
        XCTAssertEqual(items.first?.filename, "quota.heic", "a photo the person can fix leads the list")
        XCTAssertTrue(items.offersUserRetry)
    }

    #if DEBUG
        func testAnOpenProblemListFollowsANewReasonWhileAPassRuns() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-follow")
            defer { fixture.cleanup() }
            // The controller is the only owner of its queue file, so its own store reports every write.
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            // The coalescing pause never ends: only a queue write can bring the next read.
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertFalse(shown.lists[0].offersUserRetry)

            // The pass gives a photo a reason that the person resolves; no count of the status changes.
            XCTAssertTrue(queue.upsert(quotaEntry("quota")))
            let deadline = Date().addingTimeInterval(10)
            while shown.lists.last?.offersUserRetry != true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(shown.lists.last?.offersUserRetry, true, "Try again appears without waiting for a timer")

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            clock.releaseAll()
            try await waitForCondition { shown.ended }
            follow.cancel()
            await follow.value
            XCTAssertFalse(fixture.controller.isSyncing, "following ends with the pass")
            await fixture.controller.shutdown()
        }

        func testAnEmptyFirstReadWhileTheSummaryCountsAnItemIsReadAgain() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-empty-first")
            defer { fixture.cleanup() }
            let item = BackupFailedItem(entry: quotaEntry("late"))
            let reads = ReadCounter()
            let clock = BackupTestClock()
            let shown = ShownProblemLists()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: { reads.next() == 1 ? [] : [item] }, expectingItems: { true }, clock: clock,
                { shown.lists.append($0) }, { unavailable += 1 })
            XCTAssertEqual(
                shown.lists, [[], [item]], "the empty first read is followed by a read that shows the photo")
            XCTAssertEqual(clock.sleeps, [0.25])
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testAListThatStaysEmptyWhileTheSummaryCountsItemsIsReportedAfterBoundedReads() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-stays-empty")
            defer { fixture.cleanup() }
            let reads = ReadCounter()
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: {
                    _ = reads.next()
                    return []
                }, expectingItems: { true }, clock: clock, { _ in }, { unavailable += 1 })
            XCTAssertEqual(reads.value, 6, "the first read and five re-reads")
            XCTAssertEqual(clock.sleeps, [0.25, 0.5, 1, 2, 4])
            XCTAssertEqual(unavailable, 1, "an empty list that the summary contradicts is reported, not accepted")
            await fixture.controller.shutdown()
        }

        func testAnEmptyListWithoutAttentionIsNotReadAgain() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-really-empty")
            defer { fixture.cleanup() }
            let reads = ReadCounter()
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: {
                    _ = reads.next()
                    return []
                }, expectingItems: { false }, clock: clock, { _ in }, { unavailable += 1 })
            XCTAssertEqual(reads.value, 1)
            XCTAssertTrue(clock.sleeps.isEmpty)
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testACancelledReadShowsNothingAndTheRestartReadsTheList() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-cancelled-read")
            defer { fixture.cleanup() }
            let item = BackupFailedItem(entry: quotaEntry("restart"))
            let started = ReadGate()
            let release = ReadGate()
            let shown = ShownProblemLists()
            var unavailable = 0
            let first = Task { @MainActor in
                await fixture.controller.readProblemList(
                    using: {
                        started.open()
                        await release.wait()
                        return []
                    }, expectingItems: { true }, clock: BackupTestClock(), { shown.lists.append($0) },
                    { unavailable += 1 })
            }
            await started.wait()
            first.cancel()
            release.open()
            await first.value
            XCTAssertTrue(shown.lists.isEmpty, "a cancelled read applies nothing, not even an empty list")
            XCTAssertEqual(unavailable, 0, "a cancelled read is no report either")

            // The task that starts it again reads anew and shows the photo.
            await fixture.controller.readProblemList(
                using: { [item] }, expectingItems: { true }, clock: BackupTestClock(), { shown.lists.append($0) },
                { unavailable += 1 })
            XCTAssertEqual(shown.lists, [[item]])
            await fixture.controller.shutdown()
        }

        func testAnOlderReadThatEndsAfterANewerOneNeitherAppliesNorReports() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-older-read")
            defer { fixture.cleanup() }
            let item = BackupFailedItem(entry: quotaEntry("newer"))
            let reads = ReadCounter()
            let sixthStarted = ReadGate()
            let sixthMayEnd = ReadGate()
            let shown = ShownProblemLists()
            let order = BackupProblemListReadOrder()
            var unavailable = 0
            // A manual retry whose sixth, empty result arrives late.
            let manual = Task { @MainActor in
                await fixture.controller.readProblemList(
                    using: {
                        if reads.next() == 6 {
                            sixthStarted.open()
                            await sixthMayEnd.wait()
                        }
                        return []
                    }, order: order, expectingItems: { true }, clock: BackupTestClock(),
                    { shown.lists.append($0) }, { unavailable += 1 })
            }
            await sixthStarted.wait()
            // The automatic read for a summary change starts later and shows the photo.
            await fixture.controller.readProblemList(
                using: { [item] }, order: order, expectingItems: { true }, clock: BackupTestClock(),
                { shown.lists.append($0) }, { unavailable += 1 })
            sixthMayEnd.open()
            await manual.value
            XCTAssertEqual(shown.lists.count, 6, "five empty lists of the manual read, then the newer list only")
            XCTAssertEqual(shown.lists.last, [item], "the older, empty result must not replace the newer list")
            XCTAssertEqual(unavailable, 0, "the older read must not report the list as unavailable")
            await fixture.controller.shutdown()
        }

        func testAReadThatTheControllerShutdownOvertakesNeitherAppliesNorReports() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-shutdown-read")
            defer { fixture.cleanup() }
            let started = ReadGate()
            let release = ReadGate()
            let shown = ShownProblemLists()
            var unavailable = 0
            let read = Task { @MainActor in
                await fixture.controller.readProblemList(
                    using: {
                        started.open()
                        await release.wait()
                        return []
                    }, expectingItems: { true }, clock: BackupTestClock(), { shown.lists.append($0) },
                    { unavailable += 1 })
            }
            await started.wait()
            await fixture.controller.shutdown()
            release.open()
            await read.value
            XCTAssertTrue(shown.lists.isEmpty)
            XCTAssertEqual(unavailable, 0)
        }

        func testADecisionReadThatLeavesTheListEmptyReadsAgainAndShowsTheFailedPhoto() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-reread")
            defer { fixture.cleanup() }
            let decision = decisionItem("photo", issue: .deletedElsewhere)
            // The photo failed again with another reason; the summary counts it.
            let failedAgain = decisionItem("photo", issue: .network)
            var shown: [[BackupFailedItem]] = []
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: { [failedAgain] }, afterDecision: decision, expectingItems: { true }, clock: clock,
                { shown.append($0) }, { unavailable += 1 })
            XCTAssertEqual(shown, [[], [failedAgain]], "the re-read shows the photo that failed again")
            XCTAssertEqual(clock.sleeps, [0.25])
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testADecisionReadThatStaysEmptyWhileTheSummaryCountsItemsEndsUnavailable() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-unavailable")
            defer { fixture.cleanup() }
            var shown: [[BackupFailedItem]] = []
            var unavailableAfterApplies: [Int] = []
            let clock = BackupTestClock()
            await fixture.controller.readProblemList(
                using: { [] }, afterDecision: decisionItem("photo", issue: .deletedElsewhere),
                expectingItems: { true }, clock: clock, { shown.append($0) },
                { unavailableAfterApplies.append(shown.count) })
            XCTAssertEqual(shown, Array(repeating: [], count: 6), "every read ends empty")
            XCTAssertEqual(
                unavailableAfterApplies, [6],
                "never a spinner without a reader behind it: unavailable comes once, after the last read")
            XCTAssertEqual(clock.sleeps, [0.25, 0.5, 1, 2, 4])
            await fixture.controller.shutdown()
        }

        func testADecisionReadKeepsAnUnresolvedDecisionAndRemovesAResolvedOne() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-filter")
            defer { fixture.cleanup() }
            var shown: [BackupFailedItem]?
            let decision = decisionItem("decision", issue: .deletedElsewhere)
            let waiting = decisionItem("waiting", issue: .network)
            await fixture.controller.readProblemList(
                using: { [decision, waiting] }, afterDecision: decision, expectingItems: { false },
                clock: BackupTestClock(), { shown = $0 }, {})
            XCTAssertEqual(shown, [decision, waiting], "a decision that is still open stays")

            let reopened = decisionItem("decision", issue: .network)
            await fixture.controller.readProblemList(
                using: { [reopened, waiting] }, afterDecision: decision, expectingItems: { false },
                clock: BackupTestClock(), { shown = $0 }, {})
            XCTAssertEqual(shown, [waiting], "the resolved decision leaves at once")

            // Reading without a decision filters nothing.
            await fixture.controller.readProblemList(
                using: { [reopened, waiting] }, expectingItems: { false }, clock: BackupTestClock(),
                { shown = $0 }, {})
            XCTAssertEqual(shown, [reopened, waiting])
            await fixture.controller.shutdown()
        }

        func testADecisionReadOfAnEmptyQueueShowsNothingNeedsAttention() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-empty")
            defer { fixture.cleanup() }
            var shown: [[BackupFailedItem]] = []
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: { [] }, afterDecision: decisionItem("photo", issue: .deletedElsewhere),
                expectingItems: { false }, clock: BackupTestClock(), { shown.append($0) }, { unavailable += 1 })
            XCTAssertEqual(shown, [[]], "one empty read answers: nothing needs attention")
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        private func decisionItem(_ id: String, issue: BackupIssueKind) -> BackupFailedItem {
            BackupFailedItem(
                id: id, filename: "\(id).heic", reason: "Reason", isPermanent: false, issue: issue,
                nextAttemptAt: .distantFuture)
        }

        func testTheFollowReadsAgainWhenTheFirstReadMissedThePhoto() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-follow-reread")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            // The summary counts a photo that the queue does not return yet.
            fixture.controller.problemListExpectationForTesting = { true }
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let shown = ShownProblemLists()
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { clock.isWaiting }
            XCTAssertEqual(shown.lists.count, 1, "the first read came back empty")
            XCTAssertTrue(shown.lists.first?.isEmpty == true)
            XCTAssertTrue(queue.upsert(quotaEntry("appears")))
            clock.releaseAll()
            try await waitForCondition { shown.lists.count >= 2 }
            XCTAssertGreaterThanOrEqual(shown.lists.count, 2, "the second read did not arrive")
            XCTAssertEqual(shown.lists.dropFirst().first?.map(\.filename), ["appears.heic"])
            follow.cancel()
            clock.releaseAll()
            await follow.value
            await fixture.controller.shutdown()
        }

        func testWritesDuringTheCoalescingPauseShowOnceAfterIt() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-coalesce")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertTrue(queue.upsert(quotaEntry("first")))
            try await waitForCondition { shown.lists.count == 2 }
            try await waitForCondition { clock.isWaiting }

            // Two writes inside the pause: neither shows until the pause ends, then both show in one read.
            XCTAssertTrue(queue.upsert(quotaEntry("second")))
            XCTAssertTrue(queue.upsert(quotaEntry("third")))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(shown.lists.count, 2, "writes inside the pause wait for it")
            clock.releaseAll()
            try await waitForCondition { shown.lists.count == 3 }
            if shown.lists.count >= 3 {
                XCTAssertEqual(Set(shown.lists[2].map(\.filename)), ["first.heic", "second.heic", "third.heic"])
            }

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            try await waitForCondition { shown.ended }
            follow.cancel()
            await follow.value
            await fixture.controller.shutdown()
        }

        func testTheEndOfThePassReadsTheListOnceMore() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-end")
            defer { fixture.cleanup() }
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 1)

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            try await waitForCondition { shown.ended }
            clock.releaseAll()
            follow.cancel()
            await follow.value
            XCTAssertEqual(shown.lists.count, 2, "the end of the pass shows the final list once, without a write")
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 0, "a closed list leaves nothing behind")
            await fixture.controller.shutdown()
        }

        func testAPassThatEndsDuringThePauseStillShowsItsLastWrites() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-end-in-pause")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let follow = Task {
                await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertTrue(queue.upsert(quotaEntry("first")))
            try await waitForCondition { shown.lists.count == 2 }
            try await waitForCondition { clock.isWaiting }

            // The last write of the pass and the end of the pass both fall into the pause.
            XCTAssertTrue(queue.upsert(quotaEntry("last")))
            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            clock.releaseAll()
            try await waitForCondition { shown.ended }
            follow.cancel()
            await follow.value
            XCTAssertEqual(shown.lists.count, 3, "the end of the pass reads once more after the pause")
            XCTAssertEqual(shown.lists.last.map { Set($0.map(\.filename)) }, ["first.heic", "last.heic"])
            await fixture.controller.shutdown()
        }

        func testSeveralOpenListsEachGetTheLastReadAndLeaveNothingBehind() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-several")
            defer { fixture.cleanup() }
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let first = ShownProblemLists()
            let second = ShownProblemLists()
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            let followers = [first, second].map { shown in
                Task {
                    await fixture.controller.followProblemList(clock: clock) { shown.lists.append($0) }
                    shown.ended = true
                }
            }
            try await waitForCondition { !first.lists.isEmpty && !second.lists.isEmpty }
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 2)

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            clock.releaseAll()
            try await waitForCondition { first.ended && second.ended }
            for follower in followers {
                follower.cancel()
                await follower.value
            }
            XCTAssertEqual(first.lists.count, 2, "each open list reads once more at the end of the pass")
            XCTAssertEqual(second.lists.count, 2)
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 0)
            await fixture.controller.shutdown()
        }

        func testAListClosedWhileItWaitsLeavesNothingBehind() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-closed")
            defer { fixture.cleanup() }
            let pass = Task<Void, Never> {
                while !Task.isCancelled { await Task.yield() }
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "run", task: pass))
            let shown = ShownProblemLists()
            let follow = Task {
                await fixture.controller.followProblemList(clock: HeldBackupSleepClock(clock: BackupTestClock())) {
                    shown.lists.append($0)
                }
                shown.ended = true
            }
            try await waitForCondition { !shown.lists.isEmpty }
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 1)

            follow.cancel()  // The person closes the list while it waits for the next write.
            try await waitForCondition { shown.ended }
            await follow.value
            XCTAssertEqual(fixture.controller.passStateWakeCountForTesting, 0)
            XCTAssertTrue(fixture.controller.isSyncing, "closing the list does not touch the pass")

            pass.cancel()
            await fixture.controller.finishSyncForTesting(runID: "run")
            await fixture.controller.shutdown()
        }

        private func quotaEntry(_ name: String) -> UploadBackupSyncQueueEntry {
            .init(
                source: .init(kind: .photoLibraryAsset, identifier: name), revision: .init(rawValue: 1),
                originalFilename: "\(name).heic", state: .discovered,
                lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue,
                updatedAt: Date().addingTimeInterval(3_600))
        }

        private func waitForCondition(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(condition())
        }
    #endif

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }
    }

    private actor ReadGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        nonisolated func open() { Task { await openNow() } }
        private func openNow() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @MainActor private final class ShownProblemLists {
        var lists: [[BackupFailedItem]] = []
        var ended = false
    }

    func testAUserRetryLeavesARowThatTheRunnerClaimedMeanwhile() throws {
        let fixture = try makeControllerFixture(prefix: "backup-retry-race")
        defer { fixture.cleanup() }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
        let seen = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
            originalFilename: "quota.heic", state: .failed, attempts: 8,
            lastError: BackupIssueRecord(kind: .accountStorage, detail: "full").persistedValue, updatedAt: Date())
        XCTAssertTrue(queue.upsert(seen))
        XCTAssertTrue(
            queue.updateState(
                source: seen.source, revision: seen.revision, state: .uploading, attempts: 8,
                lastError: seen.lastError, updatedAt: Date()))
        XCTAssertFalse(queue.reopenForUserRetry(seen, attempts: 0, updatedAt: Date()))
        XCTAssertEqual(try queue.entry(for: seen.source, revision: seen.revision)?.state, .uploading)
        XCTAssertTrue(
            queue.updateState(
                source: seen.source, revision: seen.revision, state: .failed, attempts: 8,
                lastError: seen.lastError, updatedAt: Date()))
        let current = try XCTUnwrap(queue.entry(for: seen.source, revision: seen.revision))
        XCTAssertTrue(queue.reopenForUserRetry(current, attempts: 0, updatedAt: Date()))
        XCTAssertEqual(try queue.entry(for: seen.source, revision: seen.revision)?.state, .discovered)
        XCTAssertEqual(try queue.entry(for: seen.source, revision: seen.revision)?.lastError, seen.lastError)
    }

    func testAFailedRowOfAnAutomaticCauseNeedsThePerson() throws {
        let entry = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "disk"), revision: .init(rawValue: 1),
            originalFilename: "disk.heic", state: .failed, attempts: 8,
            lastError: BackupIssueRecord(kind: .deviceStorage, detail: "full").persistedValue, updatedAt: Date())
        let item = BackupFailedItem(entry: entry)
        XCTAssertEqual(item.category, .userResolvable, "the app no longer plans a failed row by itself")
        XCTAssertEqual(item.reason, L10n.string("backup.issue_device_storage"), "the list names the cause")
        XCTAssertNil(item.retryDescription, "the list promises no automatic attempt")
    }

    #if DEBUG
        func testUserResolvableRetryStartsAManualPassWithoutClearingTheSystemIssue() async throws {
            let fixture = try makeControllerFixture(
                prefix: "backup-manual-retry", enabled: true, identityResolver: FakeIdentityResolver(),
                runtimeSignals: .wiFiWithMobileDataOff)
            defer { fixture.cleanup() }
            fixture.controller.setAccessStateForTesting(.full)
            // A real scan would ask PhotoKit, which waits for an authorization answer on a machine without access.
            fixture.controller.replacePassBodyForTesting {}
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .photoLibraryAsset, identifier: "quota"), revision: .init(rawValue: 1),
                        originalFilename: "quota", state: .discovered,
                        lastError: BackupIssueRecord(kind: .accountStorage, detail: "quota").persistedValue,
                        updatedAt: Date().addingTimeInterval(3_600))))
            await fixture.controller.retryUserResolvableWork()
            XCTAssertTrue(fixture.controller.isSyncing, "manual intent starts despite the system issue's future date")
            XCTAssertNotNil(fixture.controller.activeExecutionRunID)
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue)
            await fixture.controller.shutdown()
        }

        func testRunnerStopIsRetainedDeduplicatedAndBlocksCompletion() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-runner-stop")
            defer { fixture.cleanup() }
            let stop = DelayedRunnerStop()
            fixture.controller.installRunnerStopOperationForTesting {
                await stop.stop()
            }
            let orchestration = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
            }
            XCTAssertTrue(
                fixture.controller.installSyncRunForTesting(runID: "run", task: orchestration))

            fixture.controller.stopSync()
            fixture.controller.stopSync()
            await stop.waitUntilStarted()

            let stopCalls = await stop.callCount()
            XCTAssertEqual(stopCalls, 1)
            XCTAssertEqual(fixture.controller.runnerStopRunIDForTesting, "run")
            XCTAssertTrue(fixture.controller.isRunnerStopPendingForTesting)

            let finishTask = Task { @MainActor in
                await fixture.controller.finishSyncForTesting(runID: "run")
            }
            await Task.yield()
            XCTAssertTrue(fixture.controller.isSyncing)
            XCTAssertTrue(fixture.controller.isRunnerStopPendingForTesting)

            await stop.release()
            await finishTask.value
            await orchestration.value

            XCTAssertFalse(fixture.controller.isSyncing)
            XCTAssertFalse(fixture.controller.isRunnerStopPendingForTesting)
        }

        func testShutdownAwaitsTheExistingRunnerStopTask() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-runner-stop-shutdown")
            defer { fixture.cleanup() }
            let stop = DelayedRunnerStop()
            fixture.controller.installRunnerStopOperationForTesting {
                await stop.stop()
            }
            let orchestration = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
            }
            XCTAssertTrue(
                fixture.controller.installSyncRunForTesting(runID: "run", task: orchestration))

            fixture.controller.stopSync()
            await stop.waitUntilStarted()
            let shutdownReturned = CompletionLatch()
            let shutdownTask = Task { @MainActor in
                await fixture.controller.shutdown()
                await shutdownReturned.markCompleted()
            }

            await Task.yield()
            let returnedBeforeRelease = await shutdownReturned.isCompleted()
            XCTAssertFalse(returnedBeforeRelease)
            let stopCalls = await stop.callCount()
            XCTAssertEqual(stopCalls, 1)

            await stop.release()
            await shutdownTask.value
            let returnedAfterRelease = await shutdownReturned.isCompleted()
            XCTAssertTrue(returnedAfterRelease)
            await orchestration.value
        }

        func testRunScopedStopCannotCancelAnotherOwner() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-run-owner")
            defer { fixture.cleanup() }
            let cancellation = CompletionLatch()
            let task = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                await cancellation.markCompleted()
            }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "foreground", task: task))

            fixture.controller.stopSync(runID: "background")
            await Task.yield()
            let cancelledByOtherOwner = await cancellation.isCompleted()
            XCTAssertFalse(cancelledByOtherOwner)

            fixture.controller.stopSync(runID: "foreground")
            await task.value
            let cancelledByOwner = await cancellation.isCompleted()
            XCTAssertTrue(cancelledByOwner)
            await fixture.controller.shutdown()
        }

        func testBackgroundCatchUpDoesNotAdoptAnExistingRun() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-run-stand-down")
            defer { fixture.cleanup() }
            let writer = NonCooperativeWriterLatch()
            let task = makeNonCooperativeWriter(writer)
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "foreground", task: task))
            await writer.waitUntilStarted()
            await writer.waitUntilBlocked()

            var reportedRunID: String?
            let returned = CompletionLatch()
            let catchUp = Task {
                await fixture.controller.backgroundCatchUp(owner: .iOSBackgroundTask) { runID in
                    reportedRunID = runID
                }
                await returned.markCompleted()
            }
            // The call must return while the foreground run is still blocked. The deadline only guards
            // against a hang; how fast the call returns is not asserted.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !(await returned.isCompleted()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let returnedWhileBlocked = await returned.isCompleted()
            XCTAssertTrue(returnedWhileBlocked, "The catch-up waited for the foreground run.")
            XCTAssertNil(reportedRunID)
            XCTAssertEqual(fixture.controller.activeExecutionRunID, "foreground")
            let adoptedForegroundRun = await writer.isCompleted()
            XCTAssertFalse(adoptedForegroundRun)

            await writer.release()
            await task.value
            await catchUp.value
            await fixture.controller.shutdown()
        }

        func testRetirementJoinsChangePreparationAndRejectsItsLateWriter() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-preparation-retirement")
            defer { fixture.cleanup() }
            let preparation = NonCooperativeWriterLatch()
            let consumed = CompletionLatch()
            let orchestration = Task { while !Task.isCancelled { await Task.yield() } }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "prepared-run", task: orchestration))
            XCTAssertTrue(
                fixture.controller.startPreparedInstantWorkForTesting(
                    prepare: {
                        XCTAssertFalse(Thread.isMainThread)
                        await preparation.markStarted()
                        await preparation.waitUntilReleased()
                    },
                    consume: { await consumed.markCompleted() }
                ))
            await preparation.waitUntilBlocked()
            // Reaching this actor while preparation is blocked also proves UI work remains runnable.
            await fixture.controller.retireInstantWorkForTesting()
            XCTAssertTrue(fixture.controller.isRetiringInstantWorkForTesting)
            await preparation.release()
            await fixture.controller.waitForInstantWorkRetirementForTesting()
            let didConsume = await consumed.isCompleted()
            XCTAssertFalse(didConsume, "a preparation from a retired pass must never enqueue work")
            await fixture.controller.shutdown()
            await orchestration.value
        }

        func testPreparedChangesAreConsumedForTheActiveRun() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-preparation-current")
            defer { fixture.cleanup() }
            let consumed = CompletionLatch()
            let orchestration = Task { while !Task.isCancelled { await Task.yield() } }
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "current-run", task: orchestration))
            XCTAssertTrue(
                fixture.controller.startPreparedInstantWorkForTesting(
                    prepare: { XCTAssertFalse(Thread.isMainThread) },
                    consume: { await consumed.markCompleted() }
                ))
            await consumed.waitUntilCompleted()
            await fixture.controller.shutdown()
            await orchestration.value
        }

        func testExpirationTracksEveryConcurrentWriterAndRetiresUntilBothReturn() async throws {
            let suite = "photo-backup-controller-retirement-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }

            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory,
                    databasePolicy: .conservative,
                    defaults: defaults
                ),
                identityResolver: nil,
                uploader: MockUploader()
            )
            let first = NonCooperativeWriterLatch()
            let second = NonCooperativeWriterLatch()
            let firstTask = makeNonCooperativeWriter(first)
            let secondTask = makeNonCooperativeWriter(second)
            XCTAssertTrue(controller.installInstantWorkTaskForTesting(firstTask))
            XCTAssertTrue(controller.installInstantWorkTaskForTesting(secondTask))

            await first.waitUntilStarted()
            await second.waitUntilStarted()
            await first.waitUntilBlocked()
            await second.waitUntilBlocked()

            let expirationStarted = ContinuousClock.now
            await controller.retireInstantWorkForTesting()
            let expirationDuration = expirationStarted.duration(to: ContinuousClock.now)
            XCTAssertLessThan(
                expirationDuration,
                PhotoLibraryBackupController.instantWorkRetirementTimeout + .milliseconds(500),
                "expiration must return after its bounded wait instead of joining writers"
            )
            XCTAssertTrue(controller.isRetiringInstantWorkForTesting)

            await first.release()
            await firstTask.value
            XCTAssertTrue(controller.isRetiringInstantWorkForTesting)

            await second.release()
            await secondTask.value
            await controller.waitForInstantWorkRetirementForTesting()
            XCTAssertFalse(controller.isRetiringInstantWorkForTesting)
            await controller.shutdown()
        }

        func testRetirementRejectsNewTargetedWriter() async throws {
            let suite = "photo-backup-controller-retirement-guard-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }

            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory,
                    databasePolicy: .conservative,
                    defaults: defaults
                ),
                identityResolver: nil,
                uploader: MockUploader()
            )
            let writer = NonCooperativeWriterLatch()
            let writerTask = makeNonCooperativeWriter(writer)
            XCTAssertTrue(controller.installInstantWorkTaskForTesting(writerTask))
            await writer.waitUntilStarted()
            await writer.waitUntilBlocked()

            let expiration = Task { @MainActor in
                await controller.retireInstantWorkForTesting()
            }
            while !controller.isRetiringInstantWorkForTesting {
                await Task.yield()
            }

            let rejectedWriter = NonCooperativeWriterLatch()
            XCTAssertFalse(
                controller.startInstantWorkForTesting {
                    await rejectedWriter.markStarted()
                },
                "retirement must reject a new targeted writer"
            )
            await Task.yield()
            let rejectedWriterStarted = await rejectedWriter.isStarted()
            XCTAssertFalse(rejectedWriterStarted)

            await expiration.value
            await writer.release()
            await writerTask.value
            await controller.waitForInstantWorkRetirementForTesting()
            XCTAssertFalse(controller.isRetiringInstantWorkForTesting)
            await controller.shutdown()
        }

        func testShutdownJoinsRetirementAndAllTrackedWriters() async throws {
            let suite = "photo-backup-controller-retirement-shutdown-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }

            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory,
                    databasePolicy: .conservative,
                    defaults: defaults
                ),
                identityResolver: nil,
                uploader: MockUploader()
            )
            let first = NonCooperativeWriterLatch()
            let second = NonCooperativeWriterLatch()
            let firstTask = makeNonCooperativeWriter(first)
            let secondTask = makeNonCooperativeWriter(second)
            XCTAssertTrue(controller.installInstantWorkTaskForTesting(firstTask))
            XCTAssertTrue(controller.installInstantWorkTaskForTesting(secondTask))
            await first.waitUntilStarted()
            await second.waitUntilStarted()
            await first.waitUntilBlocked()
            await second.waitUntilBlocked()
            await controller.retireInstantWorkForTesting()
            XCTAssertTrue(controller.isRetiringInstantWorkForTesting)

            let shutdownReturned = CompletionLatch()
            let shutdownTask = Task { @MainActor in
                await controller.shutdown()
                await shutdownReturned.markCompleted()
            }
            await Task.yield()
            let returnedBeforeFirstRelease = await shutdownReturned.isCompleted()
            XCTAssertFalse(returnedBeforeFirstRelease)

            await first.release()
            await firstTask.value
            await Task.yield()
            let returnedBeforeSecondRelease = await shutdownReturned.isCompleted()
            XCTAssertFalse(returnedBeforeSecondRelease)

            await second.release()
            await secondTask.value
            await shutdownTask.value
            let returnedAfterWriters = await shutdownReturned.isCompleted()
            XCTAssertTrue(returnedAfterWriters)
        }

        func testShutdownDoesNotReturnBeforeNonCooperativeInstantWriterCompletes() async throws {
            let suite = "photo-backup-controller-shutdown-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }

            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory,
                    databasePolicy: .conservative,
                    defaults: defaults
                ),
                identityResolver: nil,
                uploader: MockUploader()
            )
            let writer = NonCooperativeWriterLatch()
            let writeTask = Task.detached(priority: .utility) {
                await writer.markStarted()
                await writer.waitUntilReleased()
                await writer.markCompleted()
            }
            controller.installInstantWorkTaskForTesting(writeTask)

            let shutdownStarted = CompletionLatch()
            let shutdownReturned = CompletionLatch()
            let shutdownTask = Task { @MainActor in
                await shutdownStarted.markCompleted()
                await controller.shutdown()
                await shutdownReturned.markCompleted()
            }

            await shutdownStarted.waitUntilCompleted()
            await writer.waitUntilStarted()
            await writer.waitUntilBlocked()
            await Task.yield()
            let returnedBeforeRelease = await shutdownReturned.isCompleted()
            XCTAssertFalse(
                returnedBeforeRelease,
                "shutdown must not return while the non-cooperative writer remains blocked"
            )
            await writer.release()
            await writeTask.value
            await shutdownTask.value
            let writerCompleted = await writer.isCompleted()
            let returnedAfterRelease = await shutdownReturned.isCompleted()
            XCTAssertTrue(writerCompleted)
            XCTAssertTrue(returnedAfterRelease)
        }
    #endif

    func testBackgroundExecutionCompositionReservesDiscoveryAndQueuePhases() throws {
        let catalog = BackupExecutionProgress(completedUnitCount: 50, totalUnitCount: 100)
        let queue = BackupExecutionProgress(completedUnitCount: 20, totalUnitCount: 100)

        let scanOnly = try XCTUnwrap(
            PhotoLibraryBackupExecutionProgress.combined(
                catalog: catalog,
                queue: nil,
                isScanning: true
            ))
        XCTAssertEqual(scanOnly.completedUnitCount, 125_000)
        XCTAssertEqual(scanOnly.totalUnitCount, 1_000_000)

        let combined = try XCTUnwrap(
            PhotoLibraryBackupExecutionProgress.combined(
                catalog: catalog,
                queue: queue,
                isScanning: true
            ))
        XCTAssertEqual(combined.completedUnitCount, 275_000)

        let finishedWithoutQueue = try XCTUnwrap(
            PhotoLibraryBackupExecutionProgress.combined(
                catalog: BackupExecutionProgress(completedUnitCount: 100, totalUnitCount: 100),
                queue: nil,
                isScanning: false
            ))
        XCTAssertEqual(finishedWithoutQueue.completedUnitCount, 1_000_000)
    }

    func testLivePhotoLibraryChangesAreAvailableBeforePersistentHistoryCatchesUp() {
        var buffer = PhotoLibraryLiveChangeBuffer()

        buffer.record(
            changedIdentifiers: ["new", "edited"],
            deletedIdentifiers: [],
            requiresFullRescan: false
        )
        buffer.record(
            changedIdentifiers: [],
            deletedIdentifiers: ["edited"],
            requiresFullRescan: false
        )

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.changedIdentifiers, ["new"])
        XCTAssertEqual(snapshot.deletedIdentifiers, ["edited"])
        XCTAssertFalse(snapshot.requiresFullRescan)
    }

    func testCommittingPreparedLiveChangesKeepsChangesThatArriveDuringTheScan() {
        var buffer = PhotoLibraryLiveChangeBuffer()
        buffer.record(
            changedIdentifiers: ["first"],
            deletedIdentifiers: [],
            requiresFullRescan: false
        )
        let prepared = buffer.snapshot()

        buffer.record(
            changedIdentifiers: ["second"],
            deletedIdentifiers: [],
            requiresFullRescan: false
        )
        buffer.commit(through: prepared.generation)

        let remaining = buffer.snapshot()
        XCTAssertEqual(remaining.changedIdentifiers, ["second"])
        XCTAssertEqual(remaining.deletedIdentifiers, [])
    }

    func testNonIncrementalLivePhotoKitChangeRequiresSafeFullRescan() {
        var buffer = PhotoLibraryLiveChangeBuffer()
        buffer.record(
            changedIdentifiers: [],
            deletedIdentifiers: [],
            requiresFullRescan: true
        )

        XCTAssertTrue(buffer.snapshot().requiresFullRescan)
    }

    func testCatalogReplayPolicyDoesNotResurrectRowsRemovedFromAnExistingQueue() {
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .notStarted, queueCount: 33_771, catalogCount: 34_104),
            .markCompleted,
            "an older populated queue is complete by write ordering even when stale catalog rows make counts differ"
        )
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .completed, queueCount: 33_771, catalogCount: 34_104),
            .skip,
            "later launches must not resurrect the same stale sources"
        )
    }

    func testCatalogReplayPolicyRebuildsOnlyAResetQueueAndResumesAfterInterruption() {
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .notStarted, queueCount: 0, catalogCount: 34_104),
            .replay
        )
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .inProgress, queueCount: 500, catalogCount: 34_104),
            .replay,
            "a killed rebuild must continue even after its first chunk made the queue non-empty"
        )
        XCTAssertEqual(
            BackupCatalogReplayPolicy.action(state: .notStarted, queueCount: 0, catalogCount: 0),
            .markCompleted,
            "a fresh empty pair needs no replay; the normal scan populates both stores"
        )
    }

    #if DEBUG
        func testBackupDoesNotStartWhenTheRequiredPendingStoreIsMissing() async throws {
            let suite = "photo-backup-controller-pending-store-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            defaults.set(true, forKey: "photoBackup.enabled.v1")

            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory,
                    databasePolicy: .conservative,
                    defaults: defaults
                ),
                identityResolver: FakeIdentityResolver(),
                uploader: MockUploader(),
                pendingStore: nil,
                requiresPendingStore: true
            )
            controller.setAccessStateForTesting(.full)

            // Without the exclusions an excluded photo could upload, so no pass may start.
            controller.syncNow()
            await controller.retryFailedAndSync()

            XCTAssertFalse(controller.isAvailable)
            XCTAssertFalse(controller.isSyncing)
            XCTAssertEqual(controller.lastMessage, L10n.string("backup.error_local_state_unavailable"))
            await controller.shutdown()
        }

        func testMissingSourceRecoveryFailureShowsTheLocalizedLocalStateMessage() async throws {
            let suite = "backup-recovery-local-state-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let pending = try XCTUnwrap(
                PendingBackupManifestStore(
                    url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
            defer {
                pending.close()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults,
                    runtimeSignals: .wiFiWithMobileDataOff),
                identityResolver: FakeIdentityResolver(), uploader: MockUploader(), pendingStore: pending)
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            let catalog = try XCTUnwrap(
                PhotoLibraryCatalogManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.catalogDatabaseFileName)))
            let info = PhotoBackupAssetInfo(
                localIdentifier: "dropped-photo", creationDate: nil, modificationDate: Date(timeIntervalSince1970: 200),
                pixelWidth: 10, pixelHeight: 10, durationSeconds: 0, isLivePhoto: false, isVideo: false,
                resources: [.init(role: .originalPhoto, originalFilename: "photo.jpg", mimeType: "image/jpeg")])
            XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date())]))
            catalog.close()
            controller.replaceScanForTesting { pending.close() }

            controller.syncNow()
            let finished = await waitUntil { !controller.isSyncing }

            XCTAssertTrue(finished)
            XCTAssertEqual(controller.lastMessage, L10n.string("backup.error_local_state_unavailable"))
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertEqual(queue.count(), 0, "unreadable exclusions must leave recovery pending")
            queue.close()
            await controller.shutdown()
        }

        /// Runs one pass whose scan throws `error`, and returns what the person would read afterwards.
        private func messageAfterAScan(throwing error: Error) async throws -> String? {
            let fixture = try makeControllerFixture(
                prefix: "backup-scan-failure", identityResolver: FakeIdentityResolver(),
                runtimeSignals: .wiFiWithMobileDataOff)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            let scans = PassCounter()
            controller.replaceScanForTesting {
                _ = scans.increment()
                throw error
            }

            controller.syncNow()
            let finished = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "the pass must run its scan")
            let message = controller.lastMessage
            await controller.shutdown()
            return message
        }

        func testScanFailureShowsTheLocalizedLocalStateMessageInsteadOfTheTechnicalText() async throws {
            let technical = "Photo library scan state could not be saved"
            let failures: [Error] = [
                UploadError.backend(technical), UploadError.backend("Photo library catalog could not be updated"),
                CocoaError(.fileWriteUnknown),
            ]
            for failure in failures {
                let message = try await messageAfterAScan(throwing: failure)
                XCTAssertEqual(message, L10n.string("backup.error_local_state_unavailable"), "\(failure)")
            }
            let key = "backup.error_local_state_unavailable"
            for language in ["en", "de"] {
                let translated = try XCTUnwrap(try catalogTranslation(of: key, language: language), language)
                XCTAssertFalse(translated.contains("Photo library"), language)
                XCTAssertNotEqual(translated, technical, language)
            }
            XCTAssertEqual(
                try catalogTranslation(of: key, language: "de"),
                "Das Backup kann nicht fortgesetzt werden; starte die App neu.")
        }

        func testCancelledScanShowsNoMessage() async throws {
            let message = try await messageAfterAScan(throwing: CancellationError())
            XCTAssertNil(message)
        }

        func testActivationDoesNotStartAPassWhileBackupIsPaused() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-activation-paused", enabled: true)
            defer { fixture.cleanup() }
            fixture.controller.setAccessStateForTesting(.full)
            fixture.controller.pauseBackup()

            fixture.controller.applicationDidBecomeActive()

            XCTAssertFalse(fixture.controller.isSyncing)
            await fixture.controller.shutdown()
        }

        func testActivationDoesNotStartAPassWhileBackupIsOff() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-activation-off")
            defer { fixture.cleanup() }
            fixture.controller.setAccessStateForTesting(.full)

            fixture.controller.applicationDidBecomeActive()

            XCTAssertFalse(fixture.controller.isSyncing)
            await fixture.controller.shutdown()
        }

        /// The excluded list checks its photos again on every activation, also while no pass may start.
        func testActivationTellsThePendingGridWhileBackupIsPaused() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-activation-pending")
            defer { fixture.cleanup() }
            fixture.controller.setEnabledForTesting()
            fixture.controller.setAccessStateForTesting(.full)
            fixture.controller.pauseBackup()
            var changes = 0
            fixture.controller.onLibraryChange = { changes += 1 }

            fixture.controller.applicationDidBecomeActive()

            XCTAssertEqual(changes, 1)
            XCTAssertFalse(fixture.controller.isSyncing)
            await fixture.controller.shutdown()
        }

        func testActivationKeepsTheRunningPass() async throws {
            let fixture = try makeControllerFixture(prefix: "photo-backup-activation-running", enabled: true)
            defer { fixture.cleanup() }
            let writer = NonCooperativeWriterLatch()
            let task = makeNonCooperativeWriter(writer)
            XCTAssertTrue(fixture.controller.installSyncRunForTesting(runID: "foreground", task: task))
            await writer.waitUntilStarted()
            await writer.waitUntilBlocked()

            fixture.controller.applicationDidBecomeActive()

            XCTAssertEqual(fixture.controller.activeExecutionRunID, "foreground")
            XCTAssertFalse(fixture.controller.isRunnerStopPendingForTesting)
            await writer.release()
            await task.value
            await fixture.controller.shutdown()
        }
    #endif

    func testDisablingBackupClearsPersistedUserPause() throws {
        let suite = "photo-backup-controller-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "photoBackup.userPaused.v1")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        XCTAssertTrue(controller.isUserPaused)

        controller.disableBackup()

        XCTAssertFalse(controller.isUserPaused)
        XCTAssertFalse(defaults.bool(forKey: "photoBackup.userPaused.v1"))
    }

    #if DEBUG
        // MARK: - Waiting for Wi-Fi

        func testDismissedMissingSourceRecheckKeepsTheWiFiWaitWithoutAPendingUpload() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-dismissed-source-wake", source: signals.source, dismissedSourceRecheck: true)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()

            let waiting = await waitUntil { !controller.isSyncing && controller.status.phase == .waitingForWiFi }
            XCTAssertTrue(waiting, "The deferred source check is outstanding work, so the backup waits for Wi-Fi")
            try await assertNoAutomaticResume(controller, "Wi-Fi returning resumes the deferred source check")
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(controller.status.dismissedFailures, 1)
            XCTAssertEqual(controller.status.needsAttentionCount, 0)
            XCTAssertEqual(controller.status.waitingRetry, 0)
            XCTAssertEqual(controller.status.totalConsidered, 1)
            XCTAssertEqual(controller.status.backedUp, 0)
            XCTAssertEqual(controller.status.outstandingCount, 1)
            await controller.shutdown()
        }

        func testWiFiReturningDuringTheScanStartsTheNextPassAtOnce() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-returns", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting {
                // The runner already found the cellular network; Wi-Fi returns while this pass still scans.
                if scans.increment() == 1 {
                    await signals.waitUntilRead()
                    signals.setWaitsForWiFi(false)
                }
            }

            controller.syncNow()

            let restarted = await waitUntil { scans.count >= 2 }
            XCTAssertTrue(restarted, "the next pass must not wait for the fallback timer")
            let settled = await waitUntil { scans.count >= 2 && !controller.isSyncing }
            XCTAssertTrue(settled)
            XCTAssertNotEqual(controller.status.phase, .waitingForWiFi, "the status must not stay on Wi-Fi")
            await controller.shutdown()
        }

        func testWiFiWaitSchedulesNoAutomaticResumeAndDoesNotStretchTheFallback() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-fallback", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            for pass in 1...8 {
                controller.syncNow()
                let finished = await waitUntil {
                    scans.count == pass && !controller.isSyncing && controller.status.phase == .waitingForWiFi
                }
                XCTAssertTrue(finished, "pass \(pass)")
                try await assertNoAutomaticResume(controller, "pass \(pass)")
            }

            XCTAssertEqual(scans.count, 8, "only the requested passes ran")
            XCTAssertEqual(
                controller.consecutiveNoProgressRunsForTesting, 0, "eight Wi-Fi waits are no failures")
            await controller.shutdown()
        }

        /// The end of the wait is an event: a timer would repeat the whole pass, and on iOS its date would also arm the
        /// background processing request.
        private func assertNoAutomaticResume(
            _ controller: PhotoLibraryBackupController, _ message: String,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            // The pass decides its next wake at the end of its completion; check after that decision. A runner snapshot
            // that reaches the status projector after the completion is not awaited; it can change only the shown
            // date, never schedule a timer.
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting, message, file: file, line: line)
            XCTAssertFalse(
                (controller.nextAutomaticAttemptAt ?? .distantPast) > Date(), message, file: file, line: line)
            XCTAssertEqual(controller.status.phase, .waitingForWiFi, message, file: file, line: line)
        }

        func testNetworkChangeEndsTheWiFiWaitWithANewPass() async throws {
            try await assertWiFiWaitEnds(prefix: "backup-wifi-network") { _, signals in signals.announceChange() }
        }

        func testTurningMobileDataOnEndsTheWiFiWaitWithANewPass() async throws {
            try await assertWiFiWaitEnds(prefix: "backup-wifi-setting") { controller, _ in
                controller.mobileDataSettingDidChange()
            }
        }

        private func assertWiFiWaitEnds(
            prefix: String,
            _ end: (PhotoLibraryBackupController, FakeBackupRuntimeSignals) -> Void
        ) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: prefix, source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            let waiting = await waitUntil { !controller.isSyncing && controller.status.phase == .waitingForWiFi }
            XCTAssertTrue(waiting, "the pass ends waiting for Wi-Fi")
            try await assertNoAutomaticResume(controller, "the wait ends only by the event below")
            end(controller, signals)
            XCTAssertEqual(scans.count, 1, "nothing starts while the wait holds")

            signals.setWaitsForWiFi(false)
            end(controller, signals)

            let restarted = await waitUntil { scans.count >= 2 }
            XCTAssertTrue(restarted, "the end of the wait starts a pass without the fallback timer")
            await controller.shutdown()
        }

        // MARK: - First network path

        func testUndeterminedNetworkThenWiFiStartsThePassWithoutTheWiFiMessage() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            // The bounded wait outlasts the test, so only the first path can start the pass.
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-wifi", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "no pass starts before the first network path")
            XCTAssertFalse(controller.isSyncing)
            XCTAssertNotEqual(controller.status.phase, .waitingForWiFi)

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let finished = await waitUntil(timeout: .seconds(5)) { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "the first path reports Wi-Fi and the pass starts at once")
            XCTAssertNotEqual(controller.status.phase, .waitingForWiFi)
            await controller.shutdown()
        }

        func testUndeterminedNetworkThenCellularWithMobileDataOffWaitsForWiFi() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-cellular", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0)

            runtime.update {
                $0.network = LibraryNetworkState(
                    isReachable: true, isExpensive: true, usedInterfaces: [.cellular], availableInterfaces: [.cellular])
            }

            let waiting = await waitUntil(timeout: .seconds(5)) {
                scans.count == 1 && !controller.isSyncing && controller.status.phase == .waitingForWiFi
            }
            XCTAssertTrue(waiting, "a cellular first path with mobile data off waits for Wi-Fi")
            try await assertNoAutomaticResume(controller, "cellular wait")
            await controller.shutdown()
        }

        func testCellularWithMobileDataOnStartsThePass() async throws {
            let cellular = LibraryNetworkState(isReachable: true, isExpensive: true)
            for initial in [LibraryNetworkState.undetermined, cellular] {
                let runtime = LibraryRuntimeState(initial: LibraryRuntimeSnapshot(network: initial))
                let fixture = try makeWiFiWaitFixture(
                    prefix: "backup-first-path-mobile-data", source: runtimeSource(runtime, usesMobileData: true))
                defer { fixture.cleanup() }
                let controller = fixture.controller
                let scans = PassCounter()
                controller.replaceScanForTesting { _ = scans.increment() }

                controller.syncNow()

                let finished = await waitUntil(timeout: .seconds(10)) { scans.count == 1 && !controller.isSyncing }
                XCTAssertTrue(finished, "mobile data on starts at once, determined: \(initial.isDetermined)")
                XCTAssertNotEqual(controller.status.phase, .waitingForWiFi)
                await controller.shutdown()
            }
        }

        func testTurningMobileDataOnBeforeTheFirstNetworkPathStartsThePass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let usesMobileData = LockedFlag(false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-setting",
                source: BackupRuntimeSignalSource(
                    current: {
                        BackupThrottleInputs(runtime: runtime.snapshot(), usesMobileData: usesMobileData.value)
                    },
                    updates: { runtime.updates() }),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0)

            usesMobileData.value = true
            controller.mobileDataSettingDidChange()

            let finished = await waitUntil(timeout: .seconds(5)) { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "turning mobile data on ends the wait for the first path")
            await controller.shutdown()
        }

        func testMissingFirstNetworkPathEndsInTheWiFiWaitAfterTheBoundedWait() async throws {
            // The path monitor never reports: the process state stays undetermined and mobile data is off.
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-missing", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .milliseconds(500))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            controller.syncNow()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "the pass first waits for the path")
            firstPathWait.releaseAll()

            let waiting = await waitUntil(timeout: .seconds(10)) {
                scans.count == 1 && !controller.isSyncing && controller.status.phase == .waitingForWiFi
            }
            XCTAssertTrue(waiting, "after the bounded wait the pass runs and holds uploads, as without a path")
            try await assertNoAutomaticResume(controller, "the late first path resumes the wait")

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            let resumed = await waitUntil(timeout: .seconds(10)) { scans.count == 2 }
            XCTAssertTrue(resumed, "a first path that arrives late ends the Wi-Fi wait")
            await controller.shutdown()
        }

        func testAnEndedWiFiWaitKeepsItsWakeWhenTheNextPassCannotStart() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-ended-declined", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.syncNow()
            let waiting = await waitUntil { !controller.isSyncing && controller.status.phase == .waitingForWiFi }
            XCTAssertTrue(waiting)
            try await assertNoAutomaticResume(controller, "the wait holds")

            // Wi-Fi returns, but a system issue with a later retry date declines the next automatic pass.
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            signals.setWaitsForWiFi(false)
            controller.syncNow()

            let armed = await waitUntil { controller.isAutoResumeScheduledForTesting }
            XCTAssertTrue(armed, "the declined pass still needs its automatic wake")
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        func testManualRetryResumesAfterCellularWiFiWaitWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(networkDetermined: true, returnsDuringScan: false)
        }

        func testManualRetryResumesAfterTheFirstPathWaitExpiresWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(networkDetermined: false, returnsDuringScan: false)
        }

        func testManualRetryResumesWhenWiFiReturnsDuringItsScanWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(networkDetermined: true, returnsDuringScan: true)
        }

        func testManualRetryResumesInItsOwnRunWhenABackgroundWindowSeesWiFiFirst() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, returnsInBackgroundWindow: true)
        }

        /// #983: on a locked phone nobody watches the person's retry, so a window that sees Wi-Fi carries it.
        func testAWindowCarriesThePendingManualRetryWhileTheAppIsOnlyInTheBackground() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, returnsInBackgroundWindow: true,
                windowInBackground: true)
        }

        /// The network observer can see Wi-Fi before the window comes; it leaves the retry for the window.
        func testTheNetworkObserverLeavesThePendingManualRetryForTheWindowInTheBackground() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, returnsInBackgroundWindow: true,
                windowInBackground: true, observerFirst: true)
        }

        func testManualRetryResumesWhenMobileDataAllowsTheExpensivePathWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, enablesMobileData: true)
        }

        private func assertManualRetryResumesAfterWiFiWait(
            networkDetermined: Bool, returnsDuringScan: Bool, returnsInBackgroundWindow: Bool = false,
            enablesMobileData: Bool = false, windowInBackground: Bool = false, observerFirst: Bool = false
        ) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: networkDetermined)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-wifi-retry", source: signals.source,
                firstNetworkPathWait: .milliseconds(100))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = try XCTUnwrap(queue.runtimeIssue(for: .remoteIndexPreparation))
            let scans = PassCounter()
            let owners = OwnerRecorder()
            let releaseScan = LockedFlag(!returnsDuringScan)
            controller.replaceScanForTesting {
                let pass = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if pass == 1 {
                    while !releaseScan.value, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }

            await controller.retryUserResolvableWork()
            signals.resetReads()

            let waiting = await waitUntil {
                if returnsDuringScan { return scans.count == 1 && owners.values == [.manual] && signals.hasBeenRead }
                return controller.status.phase == .waitingForWiFi && !controller.isSyncing
            }
            XCTAssertTrue(waiting, "The manual pass must reach the policy wait before the network returns")
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(owners.values, [.manual])
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue, "The wait preserves the issue")
            XCTAssertEqual(queue.summary()!.resolved, 0, "An expensive path uploads nothing with mobile data off")

            if !returnsDuringScan {
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                XCTAssertFalse(controller.isSyncing, "An expensive path cannot start the pending manual retry")
                XCTAssertEqual(scans.count, 1, "An expensive path must not consume the pending manual retry")
            }
            signals.setNetworkDetermined(true)
            if enablesMobileData {
                signals.setUsesMobileData(true)
            } else {
                signals.setWaitsForWiFi(false)
            }
            if returnsInBackgroundWindow {
                if windowInBackground { signals.setAppInBackground(true) }
                releaseScan.value = true
                if observerFirst {
                    signals.announceChange()
                    let started = await waitUntil(timeout: .milliseconds(300)) { controller.isSyncing }
                    XCTAssertFalse(started, "no run that no window can hold starts for the retry")
                    XCTAssertTrue(controller.isManualWiFiRetryPendingForTesting, "the retry waits for the window")
                }
                let windowRuns = PassCounter()
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
                if windowInBackground {
                    XCTAssertEqual(windowRuns.count, 1, "the window runs the pass and holds it until it ends")
                    XCTAssertEqual(
                        owners.values, [.manual, .iOSBackgroundTask], "the window's own pass carries the retry")
                    XCTAssertFalse(controller.isSyncing, "the window ends with its pass")
                    XCTAssertNil(
                        queue.runtimeIssue(for: .remoteIndexPreparation),
                        "the window's pass keeps the retry's right to prepare the index before its backoff date")
                    await controller.shutdown()
                    return
                }
                XCTAssertEqual(windowRuns.count, 0, "A window cannot expire the resumed manual retry")
            } else if enablesMobileData {
                controller.mobileDataSettingDidChange()
            } else {
                signals.announceChange()
            }
            releaseScan.value = true

            let resumed = await waitUntil { scans.count >= 2 && !controller.isSyncing }
            XCTAssertTrue(resumed, "The manual retry must resume before the one-hour index retry date")
            XCTAssertEqual(owners.values, [.manual, .manual])
            XCTAssertNil(queue.runtimeIssue(for: .remoteIndexPreparation), "The resumed pass prepares the index")
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            controller.syncNow()
            XCTAssertFalse(controller.isSyncing, "The admitted manual retry cannot bypass a later automatic backoff")
            await controller.shutdown()
        }

        func testBackgroundStartAfterTheFirstPathSnapshotCannotTakeADeferredManualPass() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-path-observer-gap", source: signals.source,
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            await controller.retryUserResolvableWork()
            XCTAssertFalse(controller.isSyncing)

            // Publish the snapshot without notifying the observer, as the real main-actor hop can lag the path.
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let windowRuns = PassCounter()
            await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
            signals.announceChange()

            let finished = await waitUntil { scans.count >= 1 && !controller.isSyncing }
            XCTAssertTrue(finished)
            XCTAssertEqual(windowRuns.count, 0, "The window never owns or expires the deferred manual pass")
            XCTAssertEqual(owners.values, [.manual])
            await controller.shutdown()
        }

        func testDeferredManualRetryKeepsItsOwnerWhenTheFirstKnownPathFindsABusyLock() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-path-busy-lock", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            await controller.retryUserResolvableWork()
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            // This foreground entry consumes the known snapshot before the observer, but cannot acquire the lock.
            controller.syncNow()
            XCTAssertEqual(scans.count, 0)
            XCTAssertFalse(controller.isSyncing)
            XCTAssertTrue(lock.release(runID: "other-live-run"))

            controller.syncNow()

            let finished = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "A declined admission must not consume the person's retry intent")
            XCTAssertEqual(owners.values, [.manual])
            await controller.shutdown()
        }

        func testDeferredManualRetrySurvivesItsFirstOfflinePassBeforeTheObserver() async throws {
            try await assertFirstManualOfflinePassResumes(deferred: true, holdsResumeLock: false)
        }

        func testManualRetrySurvivesLosingConnectivityAfterAdmission() async throws {
            try await assertFirstManualOfflinePassResumes(deferred: false, holdsResumeLock: false)
        }

        func testFirstOfflineManualRetryKeepsItsIntentWhenWiFiFindsABusyLock() async throws {
            try await assertFirstManualOfflinePassResumes(deferred: true, holdsResumeLock: true)
        }

        private func assertFirstManualOfflinePassResumes(deferred: Bool, holdsResumeLock: Bool) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: false, networkDetermined: !deferred)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-manual-offline", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = try XCTUnwrap(queue.runtimeIssue(for: .remoteIndexPreparation))
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }

            await controller.retryUserResolvableWork()
            // No main-actor yield: the admitted task has not evaluated the runner's policy yet.
            signals.setNetworkAvailable(false)
            if deferred {
                XCTAssertFalse(controller.isSyncing)
                signals.setNetworkDetermined(true)
                let windowRuns = PassCounter()
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
                XCTAssertEqual(windowRuns.count, 0, "The window cannot own the first offline manual pass")
            }
            let offlineFinished = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(offlineFinished)
            XCTAssertEqual(owners.values, [.manual])
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue)
            XCTAssertEqual(queue.summary()!.resolved, 0, "The offline pass performs no upload")

            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            if holdsResumeLock {
                XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            }
            signals.setNetworkAvailable(true)
            signals.resetReads()
            signals.announceChange()
            let observed = await waitUntil { signals.hasBeenRead }
            XCTAssertTrue(observed)
            if holdsResumeLock {
                controller.syncNow()
                XCTAssertFalse(controller.isSyncing, "The existing lock rejects the resumed retry")
                XCTAssertEqual(scans.count, 1)
                XCTAssertTrue(lock.release(runID: "other-live-run"))
                controller.syncNow()
            }
            let resumed = await waitUntil { scans.count == 2 && !controller.isSyncing }
            XCTAssertTrue(resumed, "The first offline manual pass must retain its retry past the saved index backoff")
            XCTAssertEqual(owners.values, [.manual, .manual])
            XCTAssertNil(queue.runtimeIssue(for: .remoteIndexPreparation))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
            controller.syncNow()
            XCTAssertFalse(controller.isSyncing, "A completed retry consumes its backoff bypass")
            await controller.shutdown()
        }

        func testManualRetrySurvivesAnOfflinePathBetweenCellularAndWiFi() async throws {
            try await assertManualRetrySurvivesOffline(retryWhileOffline: false)
        }

        func testManualRetrySurvivesAnotherRetryWhileThePathIsOffline() async throws {
            try await assertManualRetrySurvivesOffline(retryWhileOffline: true)
        }

        func testManualRetrySurvivesWiFiReturningDuringTheRepeatedOfflineScan() async throws {
            try await assertManualRetrySurvivesOffline(retryWhileOffline: true, wiFiReturnsDuringScan: true)
        }

        /// A starved projector consumer must not re-stamp `nextAutomaticAttemptAt` after a pass decided
        /// its wake plan. This replays the hosted merge-queue failure: the runner's last callback lands
        /// after `completeSyncRun` finished its final projection, carrying a stale issue and a date one
        /// hour in the future. The host could heal the date but never the planted one: the timer and
        /// the background request would both arm. Keeping it stopped is the projector's job.
        func testALateRunnerSnapshotCannotRestampTheAutomaticAttemptDate() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-late-snapshot-retry", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            controller.replaceScanForTesting {}
            let latch = StatusIngestionLatch()
            await controller.holdStatusProjectionIngestionForTesting { await latch.waitUntilOpen() }
            await controller.observeStatusProjectionIngestionForTesting { await latch.noteConsumed() }
            await controller.retryUserResolvableWork()
            let passEnded = await waitUntil { !controller.isSyncing }
            XCTAssertTrue(passEnded, "The Wi-Fi pass must finish its work")
            await latch.openGate()
            await latch.waitUntilConsumed()
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting, "A late snapshot must not arm the resume")
            XCTAssertFalse(
                (controller.nextAutomaticAttemptAt ?? .distantPast) > Date(),
                "A late snapshot must not plant a future automatic attempt date")
            XCTAssertEqual(controller.status.phase, .waitingForWiFi)
            await controller.shutdown()
        }

        private func assertManualRetrySurvivesOffline(
            retryWhileOffline: Bool, wiFiReturnsDuringScan: Bool = false
        ) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-manual-offline-wifi", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let scans = PassCounter()
            let owners = OwnerRecorder()
            let releaseOfflineScan = LockedFlag(!wiFiReturnsDuringScan)
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if scans.increment() == 2 {
                    while !releaseOfflineScan.value, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            await controller.retryUserResolvableWork()
            let waiting = await waitUntil { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(waiting)
            XCTAssertEqual(controller.status.phase, .waitingForWiFi)

            try await assertNoAutomaticResume(controller, "The initial Wi-Fi pass has settled")
            signals.setNetworkAvailable(false)
            signals.resetReads()
            signals.announceChange()
            let offlineObserved = await waitUntil { signals.hasBeenRead }
            XCTAssertTrue(offlineObserved, "The observer consumes the offline snapshot before another retry")
            if retryWhileOffline {
                await controller.retryUserResolvableWork()
            } else {
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
            }
            signals.resetReads()
            let offlinePassReady = await waitUntil {
                if wiFiReturnsDuringScan { return scans.count == 2 && signals.hasBeenRead }
                return !controller.isSyncing
            }
            XCTAssertTrue(offlinePassReady, "The repeated pass must read the offline policy before Wi-Fi returns")
            let offlinePassCount = retryWhileOffline ? 2 : 1
            XCTAssertEqual(
                scans.count, offlinePassCount, "An offline snapshot must not consume the pending manual retry")

            signals.setNetworkAvailable(true)
            signals.setWaitsForWiFi(false)
            signals.resetReads()
            signals.announceChange()
            if wiFiReturnsDuringScan {
                let wakeObserved = await waitUntil { signals.hasBeenRead }
                XCTAssertTrue(wakeObserved, "The Wi-Fi wake arrives while the offline scan still owns the pass")
                XCTAssertTrue(controller.isSyncing)
            }
            releaseOfflineScan.value = true

            let resumed = await waitUntil { scans.count > offlinePassCount && !controller.isSyncing }
            XCTAssertTrue(resumed, "The retry survives the offline path and resumes without the index backoff")
            XCTAssertEqual(owners.values, Array(repeating: .manual, count: offlinePassCount + 1))
            await controller.shutdown()
        }

        func testAWiFiWaitNeverInheritsManualIntentFromAnotherRunsLock() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true)
            let fixture = try makeWiFiWaitFixture(prefix: "backup-wifi-foreign-manual-lock", source: signals.source)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let scans = PassCounter()
            let releaseScan = LockedFlag(false)
            controller.replaceScanForTesting {
                _ = scans.increment()
                while !releaseScan.value, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            controller.syncNow()
            signals.resetReads()
            let paused = await waitUntil { scans.count == 1 && signals.hasBeenRead }
            XCTAssertTrue(paused)
            // Let the policy result settle while the scan still owns the foreground pass.
            try await Task.sleep(for: .milliseconds(300))
            try holdAutomaticPasses(in: fixture)
            let issue = try XCTUnwrap(queue.runtimeIssue(for: .remoteIndexPreparation))
            let runID = try XCTUnwrap(controller.activeExecutionRunID)
            XCTAssertTrue(lock.release(runID: runID))
            XCTAssertTrue(lock.acquire(owner: .manual, runID: "another-manual-run").didAcquire)
            releaseScan.value = true
            let ended = await waitUntil { !controller.isSyncing }
            XCTAssertTrue(ended)
            try await assertNoAutomaticResume(controller, "The foreground pass has settled on the expensive path")
            XCTAssertTrue(lock.release(runID: "another-manual-run"))

            signals.setWaitsForWiFi(false)
            signals.announceChange()

            let scheduled = await waitUntil { controller.isAutoResumeScheduledForTesting }
            XCTAssertTrue(scheduled, "An automatic pass still honors its own remote-index backoff")
            XCTAssertEqual(queue.runtimeIssue(for: .remoteIndexPreparation), issue)
            XCTAssertEqual(scans.count, 1, "Another run's manual lock cannot grant this controller a manual retry")
            await controller.shutdown()
        }

        func testAManualStartBeforeTheFirstNetworkPathStaysManual() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-manual", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            // A system issue with a later retry date holds automatic passes; only an explicit action passes it.
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))

            // This explicit action keeps the system issue, unlike "Back up now".
            await controller.retryUserResolvableWork()
            _ = await waitUntil { firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "the explicit pass waits for the first path")

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 }
            XCTAssertTrue(started, "the first path starts the explicit pass, which passes the system issue")
            await controller.shutdown()
        }

        func testABackgroundWindowBeforeTheFirstNetworkPathRunsItsPassWhenThePathArrives() async throws {
            try await assertBackgroundWindowRunsTheDeferredPass(deliverPath: true)
        }

        func testABackgroundWindowWithoutANetworkPathRunsItsPassAfterTheBoundedWait() async throws {
            try await assertBackgroundWindowRunsTheDeferredPass(deliverPath: false)
        }

        /// The OS task of a background window ends when `backgroundCatchUp` returns. It must return once, after the
        /// deferred pass of the same kind ran inside the window.
        private func assertBackgroundWindowRunsTheDeferredPass(deliverPath: Bool) async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background", source: .mobileDataOff(runtime),
                firstNetworkPathWait: deliverPath ? .seconds(60) : .milliseconds(800))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            let runs = PassCounter()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                let end = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
                return end
            }

            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 && firstPathWait.isWaiting }
            XCTAssertEqual(scans.count, 0, "the pass waits for the first path")
            XCTAssertEqual(windowEnds.count, 0, "the window stays open while its pass waits")
            if deliverPath {
                runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            } else {
                firstPathWait.releaseAll()
            }

            let ended = await waitUntil(timeout: .seconds(5)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "the window ends after its pass")
            XCTAssertEqual(scans.count, 1, "the deferred pass scanned inside the window")
            XCTAssertEqual(runs.count, 1, "the window received exactly one run")
            XCTAssertEqual(owners.values, [.iOSBackgroundTask], "the pass keeps the kind of the background window")
            let end = await window.value
            XCTAssertEqual(end, .done, "the pass ran after the path came or the first-path wait ended")
            XCTAssertEqual(windowEnds.count, 1, "the window ends exactly once")
            await controller.shutdown()
        }

        // The short grace of a pass can expire before a waiting window resumes, so a window must learn its run while
        // the run starts, before `idleTimerHook` reports it (#472).

        func testAWindowThatStartsItsPassAtOnceIsAdmittedBeforeTheRunIsReportedActive() async throws {
            try await assertWindowIsAdmittedFirst(resumeAtLaunchWaits: false, pathKnown: true)
        }

        func testAWindowThatWaitsForItsOwnPassIsAdmittedBeforeTheRunIsReportedActive() async throws {
            try await assertWindowIsAdmittedFirst(resumeAtLaunchWaits: false)
        }

        func testAWindowThatWaitsForTheResumeAtLaunchIsAdmittedBeforeTheRunIsReportedActive() async throws {
            try await assertWindowIsAdmittedFirst(resumeAtLaunchWaits: true)
        }

        private func assertWindowIsAdmittedFirst(resumeAtLaunchWaits: Bool, pathKnown: Bool = false) async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                if pathKnown { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-window-admitted-first", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            // The pass holds its scan until the test stops it, so no second pass can report itself active.
            controller.replaceScanForTesting { try await Task.sleep(for: .seconds(60)) }
            var events: [String] = []
            controller.idleTimerHook = { active in
                if active { events.append("active:\(controller.activeExecutionRunID ?? "none")") }
            }
            if resumeAtLaunchWaits { controller.syncNow() }
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(
                    owner: .iOSBackgroundTask, onRunStarted: { events.append("started:\($0)") },
                    onRunAdmitted: { events.append("admitted:\($0)") })
            }
            if !pathKnown {
                _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
                XCTAssertEqual(events, [], "nothing starts before the first path")
                runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            }

            let started = await waitUntil { events.contains { $0.hasPrefix("started:") } }
            XCTAssertTrue(started, "the waiting window receives the run")
            let runID = try XCTUnwrap(events.first.map { String($0.dropFirst("admitted:".count)) })
            XCTAssertEqual(
                events, ["admitted:\(runID)", "active:\(runID)", "started:\(runID)"],
                "the window is admitted to its run before the run is reported active, and once")
            XCTAssertEqual(controller.executionOwnerForTesting, .iOSBackgroundTask)
            controller.stopSync()
            _ = await window.value
            controller.idleTimerHook = nil
            await controller.shutdown()
        }

        func testAWindowThatAForegroundPassOutranksIsNeverAdmittedToThatPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-window-not-admitted", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.syncNow()
            var admitted: [String] = []
            var received: [String] = []
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(
                    owner: .iOSBackgroundTask, onRunStarted: { received.append($0) },
                    onRunAdmitted: { admitted.append($0) })
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            _ = await window.value
            let ran = await waitUntil { scans.count == 1 }
            XCTAssertTrue(ran, "the foreground pass that waited for the path runs")
            XCTAssertEqual(admitted, [], "a window must not protect a pass that it does not own")
            XCTAssertEqual(received, [])
            await controller.shutdown()
        }

        func testAWindowThatStoppedWaitingIsNotAdmittedToALaterWindowsPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-window-left-not-admitted", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { try await Task.sleep(for: .seconds(60)) }
            var leftAdmissions: [String] = []
            var laterAdmissions: [String] = []
            let left = Task { @MainActor in
                await controller.backgroundCatchUp(
                    owner: .iOSBackgroundTask, onRunAdmitted: { leftAdmissions.append($0) })
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            let later = Task { @MainActor in
                await controller.backgroundCatchUp(
                    owner: .iOSBackgroundTask, onRunAdmitted: { laterAdmissions.append($0) })
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 2 }
            left.cancel()
            _ = await left.value
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let admitted = await waitUntil { laterAdmissions.count == 1 }
            XCTAssertTrue(admitted, "the window that still waits is admitted to its pass")
            XCTAssertEqual(leftAdmissions, [], "a window that stopped waiting is never admitted to a later pass")
            controller.stopSync()
            _ = await later.value
            await controller.shutdown()
        }

        func testAWindowFromAnEarlierFirstPathWaitIsNotAdmittedToALaterOne() async throws {
            // "Use Cellular Data" on ends the first wait, and off opens a new one before any path arrives.
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: false, networkDetermined: false)
            signals.setAppInBackground(true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-window-earlier-wait-not-admitted", source: signals.source,
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { try await Task.sleep(for: .seconds(60)) }
            var earlierAdmissions: [String] = []
            var laterAdmissions: [String] = []
            let earlier = Task { @MainActor in
                await controller.backgroundCatchUp(
                    owner: .iOSBackgroundTask, onRunAdmitted: { earlierAdmissions.append($0) })
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            signals.setUsesMobileData(true)
            controller.mobileDataSettingDidChange()
            XCTAssertEqual(earlierAdmissions.count, 1, "the first wait ends with the earlier window's pass")
            controller.stopSync()
            _ = await earlier.value

            signals.setUsesMobileData(false)
            let later = Task { @MainActor in
                await controller.backgroundCatchUp(
                    owner: .iOSBackgroundTask, onRunAdmitted: { laterAdmissions.append($0) })
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            signals.setNetworkDetermined(true)
            controller.mobileDataSettingDidChange()

            XCTAssertEqual(laterAdmissions.count, 1, "the later window is admitted to its pass")
            XCTAssertEqual(earlierAdmissions.count, 1, "an ended window is never admitted to a later pass")
            controller.stopSync()
            _ = await later.value
            await controller.shutdown()
        }

        // MARK: The device log of a pass

        func testAPassLogsItsStartItsQueueItsStopItsEndAndWhatComesNext() async throws {
            let lines = RecordedLogLines()
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-pass-log", source: .mobileDataOff(runtime),
                backgroundLog: BackgroundWorkLog { lines.append("\($0.rawValue) \($1)") })
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { try await Task.sleep(for: .seconds(60)) }
            let projected = await waitUntil { controller.hasStatusProjectionForTesting }
            XCTAssertTrue(projected, "the pass compares with the counts of the first projection")
            let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            _ = await waitUntil { controller.activeExecutionRunID != nil }
            controller.noteLibraryChangeForTesting()
            let armed = await waitUntil { controller.isRestartAfterStopArmedForTesting }
            XCTAssertTrue(armed, "a change during the pass arms the restart after it")
            controller.stopSync()
            _ = await window.value
            let decided = await waitUntil { lines.values.contains { $0.contains("pass.next") } }
            XCTAssertTrue(decided)
            _ = await waitUntil { lines.values.contains { $0.contains("queue.snapshot") } }
            await controller.shutdown()

            let durations = #/Ms=[0-9]+/#
            let logged = lines.values.map { $0.replacing(durations, with: "Ms=N") }
            // The queue snapshot is counted off the main actor, so its line has no fixed place among the others.
            XCTAssertEqual(
                logged.filter { !$0.contains("queue.snapshot") },
                [
                    "PhotoBackupBackground pass.started owner=iosBackgroundTask scanOnly=no",
                    "PhotoBackupBackground pass.stopRequested owner=iosBackgroundTask",
                    "PhotoBackupBackground pass.ended owner=iosBackgroundTask stopped=yes stopMs=N durationMs=N"
                        + " waitedForWiFi=no pausedByPolicy=no completedRows=0 alreadyBackedUpRows=0"
                        + " skippedRemoteDeletionRows=0 failedRowsChange=0 sentBytes=0",
                    "PhotoBackupBackground pass.next branch=stoppedInBackground",
                ], "a stop in the background starts no next pass, also after a change")
            let snapshots = logged.filter { $0.contains("queue.snapshot") }
            XCTAssertEqual(snapshots.count, 1, "each pass logs one snapshot")
            // The pass checks its one row while the snapshot counts, so the line names the states, not fixed counts;
            // UploadBackupQueueDiagnosticsTests checks the counts.
            let states =
                #/^PhotoBackupBackground queue\.snapshot owner=\w+ discovered=\d checking=\d hashing=\d duplicateChecking=\d queuedForUpload=\d uploading=\d finalizing=\d needsRemoteReconciliation=\d( |$)/#
            for snapshot in snapshots {
                XCTAssertNotNil(snapshot.firstMatch(of: states), snapshot)
            }
        }

        func testAPassBeforeTheFirstStatusProjectionLogsNoBaseline() async throws {
            let lines = RecordedLogLines()
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-pass-log-no-baseline", source: .mobileDataOff(runtime),
                backgroundLog: BackgroundWorkLog { lines.append($1) })
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { try await Task.sleep(for: .seconds(60)) }
            XCTAssertFalse(controller.hasStatusProjectionForTesting, "the pass starts before the first projection")
            controller.syncNow()
            controller.stopSync()
            let ended = await waitUntil { lines.values.contains { $0.hasPrefix("pass.ended") } }
            XCTAssertTrue(ended)
            let line = try XCTUnwrap(lines.values.first { $0.hasPrefix("pass.ended") })
            XCTAssertTrue(line.hasSuffix(" baseline=none"), line)
            XCTAssertFalse(line.contains("completedRows"), "without a baseline the line counts nothing")
            await controller.shutdown()
        }

        func testAPassThatAStopEndsWhileTheAppIsOnlyInTheBackgroundStartsNoNextPass() async throws {
            try await assertWhatFollowsAStop(inBackground: true)
        }

        func testAPassThatAStopEndsInTheForegroundStillRestartsAfterAChange() async throws {
            try await assertWhatFollowsAStop(inBackground: false)
        }

        /// iOS ends a background window, and a short background time, with a stop. Then the app must start no more
        /// work: no restart after a change, no timer for the next pass (#969).
        private func assertWhatFollowsAStop(inBackground: Bool) async throws {
            let lines = RecordedLogLines()
            // The pass starts while the person uses the app; then the app goes to the background or stays in front.
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-what-follows-a-stop", source: .mobileDataOff(runtime),
                backgroundLog: BackgroundWorkLog { lines.append($1) })
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting {
                _ = scans.increment()
                try await Task.sleep(for: .seconds(60))
            }
            controller.syncNow()
            _ = await waitUntil { scans.count == 1 }
            if inBackground { runtime.update { $0.executionOpportunity = .backgroundPermitted } }
            controller.noteLibraryChangeForTesting()
            let armed = await waitUntil { controller.isRestartAfterStopArmedForTesting }
            XCTAssertTrue(armed, "a change during the pass arms the restart after it")
            controller.stopSync()
            let decided = await waitUntil { lines.values.contains { $0.hasPrefix("pass.next") } }
            XCTAssertTrue(decided, "the pass ended")
            if inBackground {
                XCTAssertFalse(controller.isSyncing, "no pass restarts after the stop")
                XCTAssertFalse(controller.isAutoResumeScheduledForTesting, "and no timer plans the next pass")
                XCTAssertEqual(scans.count, 1)
            } else {
                let restarted = await waitUntil { scans.count == 2 }
                XCTAssertTrue(restarted, "in the foreground the change still restarts the pass")
            }
            controller.stopSync()
            _ = await waitUntil { !controller.isSyncing }
            await controller.shutdown()
        }

        /// A carried retry keeps the person's intent through a policy pause, as the retry's own run does.
        func testACarriedRetryThatEndsWaitingForWiFiKeepsTheIntent() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-carried-retry-pause", source: signals.source, firstNetworkPathWait: .milliseconds(100))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            let scans = PassCounter()
            let releaseCarriedScan = LockedFlag(false)
            controller.replaceScanForTesting {
                if scans.increment() == 2 {
                    while !releaseCarriedScan.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                }
            }
            await controller.retryUserResolvableWork()
            let waiting = await waitUntil { controller.status.phase == .waitingForWiFi && !controller.isSyncing }
            XCTAssertTrue(waiting)
            XCTAssertTrue(controller.isManualWiFiRetryPendingForTesting)
            signals.setAppInBackground(true)
            signals.setWaitsForWiFi(false)
            let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let carried = await waitUntil { scans.count == 2 }
            XCTAssertTrue(carried, "the window carries the retry")
            XCTAssertFalse(controller.isManualWiFiRetryPendingForTesting, "the running pass holds the intent")
            signals.setWaitsForWiFi(true)
            releaseCarriedScan.value = true
            _ = await window.value
            XCTAssertTrue(
                controller.isManualWiFiRetryPendingForTesting, "a pass that ends waiting for Wi-Fi keeps the retry")
            await controller.shutdown()
        }

        func testAWindowThatCannotTakeTheLockKeepsThePendingManualRetry() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-carried-retry-busy-lock", source: signals.source,
                firstNetworkPathWait: .milliseconds(100))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try holdAutomaticPasses(in: fixture)
            controller.replaceScanForTesting {}
            await controller.retryUserResolvableWork()
            let waiting = await waitUntil { controller.status.phase == .waitingForWiFi && !controller.isSyncing }
            XCTAssertTrue(waiting)
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            signals.setAppInBackground(true)
            signals.setWaitsForWiFi(false)

            await controller.backgroundCatchUp(owner: .iOSBackgroundTask)

            XCTAssertFalse(controller.isSyncing, "another run holds the lock")
            XCTAssertTrue(controller.isManualWiFiRetryPendingForTesting, "a declined start keeps the person's retry")
            XCTAssertTrue(lock.release(runID: "other-live-run"))
            await controller.shutdown()
        }

        /// #998: a window takes over a pass that started in the foreground while the person's retry waited for Wi-Fi.
        func testAWindowRunsThePendingManualRetryAfterThePassItTookOver() async throws {
            let takeover = try await runTakeover(
                prefix: "backup-takeover-carries-retry", retryPending: true, wiFiReturns: true, windowExpires: false)
            defer { takeover.cleanup() }
            XCTAssertEqual(
                takeover.owners.values, [.manual, .foreground, .iOSBackgroundTask],
                "after the pass it took over, the window runs the retry as its own pass")
            XCTAssertEqual(takeover.windowRuns.count, 2, "the window holds the pass it took over and its own pass")
            XCTAssertFalse(
                takeover.controller.isManualWiFiRetryPendingForTesting, "the window's pass carried the retry")
            XCTAssertFalse(takeover.controller.isSyncing, "the window ends with its own pass")
            await takeover.controller.shutdown()
        }

        /// iOS can expire the window in the same turn in which the pass it took over ends; then no lock is busy any more.
        func testAWindowThatExpiresAsThePassItTookOverEndsLeavesThePendingManualRetry() async throws {
            let takeover = try await runTakeover(
                prefix: "backup-takeover-expires-retry", retryPending: true, wiFiReturns: true, windowExpires: true)
            defer { takeover.cleanup() }
            XCTAssertEqual(takeover.owners.values, [.manual, .foreground], "an expired window starts no pass")
            XCTAssertTrue(takeover.controller.isManualWiFiRetryPendingForTesting, "the retry waits for the next window")
            await takeover.controller.shutdown()
        }

        func testAWindowLeavesThePendingManualRetryWhileThePathStillWaitsForWiFi() async throws {
            let takeover = try await runTakeover(
                prefix: "backup-takeover-cellular-retry", retryPending: true, wiFiReturns: false, windowExpires: false)
            defer { takeover.cleanup() }
            XCTAssertEqual(
                takeover.owners.values, [.manual, .foreground], "on cellular the window starts no pass for the retry")
            XCTAssertEqual(takeover.windowRuns.count, 1)
            XCTAssertTrue(takeover.controller.isManualWiFiRetryPendingForTesting, "the retry still waits for Wi-Fi")
            await takeover.controller.shutdown()
        }

        func testAWindowWithoutAPendingManualRetryEndsWithThePassItTookOver() async throws {
            let takeover = try await runTakeover(
                prefix: "backup-takeover-no-retry", retryPending: false, wiFiReturns: true, windowExpires: false)
            defer { takeover.cleanup() }
            XCTAssertEqual(takeover.owners.values, [.foreground], "without a retry the window starts no pass")
            XCTAssertEqual(takeover.windowRuns.count, 1)
            await takeover.controller.shutdown()
        }

        private struct Takeover {
            let controller: PhotoLibraryBackupController
            let owners: OwnerRecorder
            let windowRuns: PassCounter
            let cleanup: () -> Void
        }

        /// The person's retry, if any, waits for Wi-Fi; then an automatic pass starts in the foreground and holds in its
        /// scan. The app goes to the background, and a window takes that pass over before the pass may end. An expiring
        /// window is cancelled while the pass ends: after the pass released its lock, before the window continues.
        private func runTakeover(
            prefix: String, retryPending: Bool, wiFiReturns: Bool, windowExpires: Bool
        ) async throws -> Takeover {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: true)
            let expiry = WindowExpiry()
            let fixture = try makeWiFiWaitFixture(
                prefix: prefix, source: signals.source,
                backgroundLog: BackgroundWorkLog { _, line in
                    if windowExpires, line.hasPrefix("pass.next") { expiry.expire() }
                })
            let controller = fixture.controller
            let owners = OwnerRecorder()
            let released = LockedFlag(false)
            controller.replaceScanForTesting {
                let owner = await MainActor.run { controller.executionOwnerForTesting }
                owners.record(owner)
                guard owner == .foreground else { return }
                while !released.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
            if retryPending {
                await controller.retryUserResolvableWork()
                let waiting = await waitUntil { controller.status.phase == .waitingForWiFi && !controller.isSyncing }
                XCTAssertTrue(waiting, "the manual pass reaches the Wi-Fi wait")
                XCTAssertTrue(controller.isManualWiFiRetryPendingForTesting)
            }
            controller.syncNow()
            let held = await waitUntil { owners.values.last == .foreground && controller.isSyncing }
            XCTAssertTrue(held, "on cellular the automatic pass starts as its own pass")

            signals.setAppInBackground(true)
            if wiFiReturns { signals.setWaitsForWiFi(false) }
            let windowRuns = PassCounter()
            let window = Task { @MainActor in
                _ = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
            }
            let tookOver = await waitUntil { windowRuns.count == 1 }
            XCTAssertTrue(tookOver, "the window takes the running automatic pass over")
            expiry.arm(window)
            released.value = true
            await window.value
            // A late start would show up here: let the end of the pass settle before the test reads the owners.
            _ = await waitUntil(timeout: .milliseconds(300)) { owners.values.count > (retryPending ? 3 : 2) }
            let settled = await waitUntil { !controller.isSyncing }
            XCTAssertTrue(settled)
            return Takeover(controller: controller, owners: owners, windowRuns: windowRuns, cleanup: fixture.cleanup)
        }

        func testAWindowThatExpiresWhileItWaitsForAStoppingPassEndsAtOnce() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-window-expires-in-stop", source: .mobileDataOff(runtime))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting {
                _ = scans.increment()
                try await Task.sleep(for: .seconds(60))
            }
            let stopReleased = LockedFlag(false)
            controller.installRunnerStopOperationForTesting {
                while !stopReleased.value { try? await Task.sleep(for: .milliseconds(10)) }
            }
            controller.syncNow()
            _ = await waitUntil { scans.count == 1 }
            // In the background only a window starts a pass (#832), so the automatic pass starts in the foreground.
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            controller.stopSync()
            let windowEnded = LockedFlag(false)
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                windowEnded.value = true
            }
            _ = await waitUntil(timeout: .milliseconds(100)) { windowEnded.value }
            window.cancel()
            let ended = await waitUntil(timeout: .seconds(1)) { windowEnded.value }
            XCTAssertTrue(ended, "the expiry ends the window's wait while the stop still runs")
            XCTAssertEqual(scans.count, 1, "the expired window starts no pass")
            stopReleased.value = true
            _ = await waitUntil { !controller.isSyncing }
            await controller.shutdown()
        }

        /// The short grace of an automatic pass can end with a stop just before iOS suspends the app; the next window then
        /// meets that stopping pass. It must wait for the stop and run its own pass, not adopt the ending one.
        func testAWindowThatMeetsAStoppingPassRunsItsOwnPassAfterTheStop() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(prefix: "backup-window-meets-a-stop", source: .mobileDataOff(runtime))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = scans.increment()
                try await Task.sleep(for: .seconds(60))
            }
            let stopReleased = LockedFlag(false)
            controller.installRunnerStopOperationForTesting {
                while !stopReleased.value { try? await Task.sleep(for: .milliseconds(10)) }
            }
            controller.syncNow()
            _ = await waitUntil { scans.count == 1 }
            // In the background only a window starts a pass (#832), so the automatic pass starts in the foreground.
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            controller.stopSync()
            let windowRuns = PassCounter()
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
            }
            _ = await waitUntil(timeout: .milliseconds(200)) { windowRuns.count > 0 }
            stopReleased.value = true

            let ownPass = await waitUntil { scans.count == 2 }
            XCTAssertTrue(ownPass, "the window starts its own pass once the stop ended")
            XCTAssertEqual(owners.values, [.foreground, .iOSBackgroundTask])
            XCTAssertEqual(windowRuns.count, 1, "the window holds only its own pass")
            controller.stopSync()
            _ = await window.value
            await controller.shutdown()
        }

        // MARK: Only a window starts a pass in the background (#832)

        func testWhileTheAppIsOnlyInTheBackgroundNoAutomaticStartBeginsAPass() async throws {
            try await assertAutomaticStart(inBackground: true)
        }

        func testInTheForegroundAnAutomaticStartBeginsAPass() async throws {
            try await assertAutomaticStart(inBackground: false)
        }

        /// A new photo, the network, a timer or the restart after a pass all start a pass through syncNow().
        private func assertAutomaticStart(inBackground: Bool) async throws {
            let lines = RecordedLogLines()
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = inBackground ? .backgroundPermitted : .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-background-start-rule", source: .mobileDataOff(runtime),
                backgroundLog: BackgroundWorkLog { lines.append($1) })
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { try await Task.sleep(for: .seconds(60)) }

            controller.syncNow()

            XCTAssertEqual(controller.isSyncing, !inBackground, "only a window starts a pass while no scene is shown")
            if inBackground {
                XCTAssertTrue(
                    lines.values.contains("pass.declined owner=foreground reason=appInBackground"), "\(lines.values)")
                let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
                let windowPass = await waitUntil { controller.isSyncing }
                XCTAssertTrue(windowPass, "a window still starts its own pass")
                XCTAssertEqual(controller.executionOwnerForTesting, .iOSBackgroundTask)
                controller.stopSync()
                _ = await window.value
            }
            controller.stopSync()
            _ = await waitUntil { !controller.isSyncing }
            await controller.shutdown()
        }

        func testTheResumeAtLaunchStartsNothingWhileTheAppIsOnlyInTheBackground() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-launch-resume-background-rule", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertFalse(controller.isSyncing, "a launch for a short check uploads nothing")
            XCTAssertNil(controller.deferredStartOwnerForTesting, "and leaves no pass waiting to start")
            await controller.shutdown()
        }

        func testAnExpiringBackgroundWindowEndsAtOnceAndDropsItsDeferredPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-expired", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let runs = PassCounter()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                let end = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
                return end
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0)

            // The iOS expiration handler cancels the work of the window.
            window.cancel()

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "an expired window ends at once")
            XCTAssertEqual(runs.count, 0)
            let end = await window.value
            XCTAssertEqual(end, .noNetworkPath, "the window ended while its pass still waited for the first path")
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(scans.count, 0, "the pass of the expired window does not run after it")
            XCTAssertEqual(windowEnds.count, 1, "the window ends exactly once")
            await controller.shutdown()
        }

        func testAStartAfterACancelledFirstPathTimerStillWaitsForTheUnknownPath() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-cancel-restart", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstWait = HeldBackupSleepClock(clock: BackupTestClock())
            let nextWait = HeldBackupSleepClock(clock: BackupTestClock())
            defer {
                firstWait.releaseAll()
                nextWait.releaseAll()
            }
            let timerStarted = expectation(description: "The first timer entered its held sleep")
            let timerEnded = expectation(description: "The cancelled timer released its task capture")
            controller.replaceFirstNetworkPathSleepForTesting {
                [lifetime = FirstPathTimerLifetime(ended: timerEnded)] _ in
                timerStarted.fulfill()
                try? await firstWait.sleep(for: 60)
                withExtendedLifetime(lifetime) {}
            }
            let scans = PassCounter()
            let scanned = expectation(description: "The later pass scanned after the first path arrived")
            controller.replaceScanForTesting {
                _ = scans.increment()
                scanned.fulfill()
            }
            let windowEnded = expectation(description: "The expired background window ended")
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                windowEnded.fulfill()
            }
            await fulfillment(of: [timerStarted], timeout: 5)
            XCTAssertEqual(controller.deferredStartWaiterCountForTesting, 1)
            XCTAssertFalse(controller.isSyncing)

            // Drop the controller's copy. The old task alone retains the first sleep's capture.
            controller.replaceFirstNetworkPathSleepForTesting { _ in try? await nextWait.sleep(for: 60) }
            window.cancel()
            await fulfillment(of: [windowEnded], timeout: 5)
            await window.value
            firstWait.releaseAll()
            await fulfillment(of: [timerEnded], timeout: 5)

            controller.syncNow()

            XCTAssertFalse(controller.isSyncing, "A cancelled timer must not end the next start's first-path wait")
            XCTAssertEqual(scans.count, 0, "The unknown path must still defer the later pass")
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            await fulfillment(of: [scanned], timeout: 5)
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        private final class FirstPathTimerLifetime: Sendable {
            private let ended: XCTestExpectation

            init(ended: XCTestExpectation) { self.ended = ended }

            deinit { ended.fulfill() }
        }

        func testAnExpiringBackgroundWindowKeepsADeferredForegroundPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-foreground", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                // The owner is recorded before the count rises, so a wait for the count also sees the owner.
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = scans.increment()
            }
            controller.syncNow()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = windowEnds.increment()
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            window.cancel()
            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended)

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 }
            XCTAssertTrue(started, "the foreground pass that waited for the path still runs")
            XCTAssertEqual(owners.values, [.foreground])
            await controller.shutdown()
        }

        func testABackgroundWindowNeverOwnsADeferredManualPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-manual", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                // The owner is recorded before the count rises, so a wait for the count also sees the owner.
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = scans.increment()
            }
            await controller.retryUserResolvableWork()
            let runs = PassCounter()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                let end = await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
                return end
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { windowEnds.count == 1 && scans.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(runs.count, 0, "the window cannot stop the explicit pass at its expiration")
            XCTAssertEqual(owners.values, [.manual])
            let end = await window.value
            XCTAssertEqual(end, .done, "the path came; the explicit pass runs on its own")
            await controller.shutdown()
        }

        func testABackgroundWindowCancelledBeforeItWaitsDropsItsDeferredPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-precancelled", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let release = LockedFlag(false)
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                while !release.value { await Task.yield() }
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = windowEnds.increment()
            }
            // The window expires before it reaches the wait.
            window.cancel()
            release.value = true

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended)
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(scans.count, 0, "the pass of the expired window does not run after it")
            await controller.shutdown()
        }

        func testAManualStartOutranksAForegroundStartThatAlreadyWaitsForTheFirstPath() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-foreground-then-manual", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                _ = scans.increment()
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            // A system issue with a later retry date holds automatic passes; only an explicit action passes it.
            try holdAutomaticPasses(in: fixture)

            controller.syncNow()
            await controller.retryUserResolvableWork()
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 && owners.values.count == 1 }
            XCTAssertTrue(started, "the explicit action that waited behind the automatic start runs")
            XCTAssertEqual(owners.values, [.manual])
            await controller.shutdown()
        }

        func testAnExpiringBackgroundWindowKeepsTheBoundOfADeferredForegroundPass() async throws {
            // The path monitor never reports, so only the bounded wait can start the foreground pass.
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-bound", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(2))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let firstPathWait = holdFirstNetworkPathWait(of: controller)
            defer { firstPathWait.releaseAll() }
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.syncNow()
            let windowEnds = PassCounter()
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = windowEnds.increment()
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0, "the window waits for its deferred pass")
            window.cancel()
            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended)
            firstPathWait.releaseAll()

            let started = await waitUntil(timeout: .seconds(5)) { scans.count == 1 }
            XCTAssertTrue(started, "the foreground pass still starts when its bounded wait ends")
            await controller.shutdown()
        }

        func testABackgroundWindowThatCannotStartDoesNotWaitForAnotherWindowsDeferral() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-second-window", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting {}
            let firstEnds = PassCounter()
            let first = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
                _ = firstEnds.increment()
            }
            defer { first.cancel() }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(firstEnds.count, 0, "the first window waits for its deferred pass")

            // The person pauses the backup, so the next window has nothing to start and nothing to wait for.
            controller.pauseBackup()
            let secondEnds = PassCounter()
            let second = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .macOSBackgroundActivity)
                _ = secondEnds.increment()
            }
            defer { second.cancel() }

            let ended = await waitUntil(timeout: .seconds(2)) { secondEnds.count == 1 }
            XCTAssertTrue(ended, "a window that cannot start ends at once instead of waiting for the first path")
            await controller.shutdown()
        }

        func testShutdownEndsABackgroundWindowThatWaitsForTheFirstPath() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-first-path-background-shutdown", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let runs = PassCounter()
            let windowEnds = PassCounter()
            // macOS gives a background activity no expiration, so only the shutdown can end this window.
            let window = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .macOSBackgroundActivity) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
            }
            defer { window.cancel() }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0, "the window waits for its deferred pass")

            await controller.shutdown()

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "a sign-out ends the waiting window")
            XCTAssertEqual(runs.count, 0)
            XCTAssertEqual(scans.count, 0)
        }

        // MARK: Resume at launch against a background window (#472)

        // A background window can launch the app without a scene. The account start then creates the controller, whose
        // resume at launch starts an automatic foreground pass. The window and the resume reach the controller in
        // either order. While no scene is in the foreground, the window must run that pass inside its own time. Since
        // #832 the resume starts nothing while the app is only in the background; a resume that the person's visit
        // left waiting for the first network path still meets the window after the app leaves the foreground.

        func testAResumeAtLaunchThatWaitsForTheFirstPathHandsItsPassToALaterWindow() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .foregroundActive }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-launch-resume-then-window", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true

            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the resume waits for the first path")
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            try await assertWindowRanTheOnlyPass(window, scan: scan, controller: controller)
            await controller.shutdown()
        }

        func testAWindowThatWaitsForTheFirstPathTakesThePassOfALaterResumeAtLaunch() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-window-then-launch-resume", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true

            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            // The person opens the app, so the resume at launch waits for the first path, and leaves again.
            runtime.update { $0.executionOpportunity = .foregroundActive }
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the resume waits for the first path")
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            try await assertWindowRanTheOnlyPass(window, scan: scan, controller: controller)
            await controller.shutdown()
        }

        func testAWindowRunsTheResumeAtLaunchWhenThePathArrivedBeforeItsObserver() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-launch-resume-observer-gap", source: signals.source)
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the resume waits for the first path")
            signals.setAppInBackground(true)

            // Publish the snapshot without notifying the observer, as the real main-actor hop can lag the path.
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let window = startWindow(controller, scan: scan)
            try await assertWindowRanTheOnlyPass(window, scan: scan, controller: controller)
            signals.announceChange()
            await controller.waitForSyncRunCompletionForTesting()
            XCTAssertEqual(scan.starts.count, 1, "the observer starts no second pass")
            await controller.shutdown()
        }

        func testAWindowTakesOverAResumeAtLaunchThatIsAlreadyRunning() async throws {
            let launch = try await makeRunningLaunchResume(prefix: "backup-launch-resume-running-window")
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan

            let window = startWindow(controller, scan: scan)
            let adopted = await waitUntil(timeout: .seconds(2)) { window.record.runIDs.count == 1 }
            XCTAssertTrue(adopted, "the window takes over the running automatic pass")
            XCTAssertEqual(window.record.runIDs, [launch.runID], "the window holds the run of the resume")
            XCTAssertFalse(window.record.hasEnded, "the window stays open while the pass runs")

            scan.open.value = true
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.completedScansAtEnd, 1, "the window ends only after the pass")
            XCTAssertEqual(scan.starts.count, 1, "no second pass starts")
            XCTAssertEqual(scan.owners.values, [.foreground], "the run keeps the owner that started it")
            await window.task.value
            await controller.shutdown()
        }

        func testAnExpiredWindowStopsTheResumeAtLaunchItTookOverWhileTheAppStaysInTheBackground() async throws {
            let launch = try await makeRunningLaunchResume(prefix: "backup-launch-resume-window-expired")
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil(timeout: .seconds(2)) { window.record.runIDs.count == 1 }
            let runID = try XCTUnwrap(window.record.runIDs.first, "the window takes over the running pass")

            // An expiry that names another run stops nothing.
            controller.stopBackgroundWindowRun(runID: "an-earlier-run")
            XCTAssertFalse(controller.isRunnerStopPendingForTesting, "only the window's own run can be stopped")

            // The expiration handler cancels the window's work, then stops the run it holds.
            window.task.cancel()
            controller.stopBackgroundWindowRun(runID: runID)
            XCTAssertTrue(controller.isRunnerStopPendingForTesting, "the expiry stops the pass in the background")
            XCTAssertEqual(controller.runnerStopRunIDForTesting, runID)

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && !controller.isSyncing }
            XCTAssertTrue(ended, "the window and the stopped pass end")
            scan.open.value = true
            await window.task.value
            await controller.shutdown()
        }

        func testAnExpiredWindowKeepsTheResumeAtLaunchItTookOverOnceTheAppIsInTheForeground() async throws {
            let launch = try await makeRunningLaunchResume(prefix: "backup-launch-resume-window-foreground")
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil(timeout: .seconds(2)) { window.record.runIDs.count == 1 }
            let runID = try XCTUnwrap(window.record.runIDs.first, "the window takes over the running pass")

            // The person opens the app before the window expires; they now watch this pass.
            launch.runtime.update { $0.executionOpportunity = .foregroundActive }
            window.task.cancel()
            controller.stopBackgroundWindowRun(runID: runID)
            XCTAssertFalse(controller.isRunnerStopPendingForTesting, "the expiry does not stop a pass the person sees")
            XCTAssertEqual(controller.activeExecutionRunID, runID)

            // The pass stays held until the window processed its cancellation; then the pass may finish.
            _ = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            scan.open.value = true
            await window.task.value
            XCTAssertEqual(
                window.record.completedScansAtEnd, 0, "the window ended before the pass it gave back finished")
            let finished = await waitUntil(timeout: .seconds(5)) { !controller.isSyncing }
            XCTAssertTrue(finished)
            XCTAssertEqual(scan.completions.count, 1, "the pass the person sees runs to its end")
            XCTAssertFalse(controller.isRunnerStopPendingForTesting)
            await window.task.value
            await controller.shutdown()
        }

        func testAWindowNeverTakesOverARunningManualPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-manual-running-window", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scan = HeldScan()
            scan.install(on: controller)
            await controller.retryUserResolvableWork()
            _ = await waitUntil { scan.starts.count == 1 }
            XCTAssertEqual(scan.owners.values, [.manual])

            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(2)) { window.record.hasEnded }
            XCTAssertTrue(ended, "the window ends at once next to the explicit pass")
            XCTAssertEqual(window.record.runIDs, [], "the window can never stop the explicit pass at its expiration")
            scan.open.value = true
            await controller.shutdown()
        }

        func testAWindowOwnsItsPassWhenTheResumeAtLaunchComesLater() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-window-then-running-resume", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan

            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { scan.starts.count == 1 }
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            scan.open.value = true

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs.count, 1)
            XCTAssertEqual(scan.starts.count, 1, "the resume finds the running pass and starts none")
            XCTAssertEqual(scan.owners.values, [.iOSBackgroundTask])
            await window.task.value
            await controller.shutdown()
        }

        func testAWindowThatCannotTakeTheLockGivesTheResumeAtLaunchBack() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let launch = try makeLaunchResumeFixture(prefix: "backup-takeover-busy-lock", source: signals.source)
            defer { launch.cleanup() }
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: launch.fixture.directory.appendingPathComponent(
                        PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            await assertAFailedTakeoverGivesTheResumeBack(launch: launch, signals: signals) {
                XCTAssertTrue(lock.release(runID: "other-live-run"))
            }
        }

        func testAWindowThatFindsTheLockUnreadableGivesTheResumeAtLaunchBack() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            // No busy wait, so the held write transaction below makes the lock unreadable at once.
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-takeover-unavailable-lock", source: signals.source,
                databasePolicy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0))
            defer { launch.cleanup() }
            let url = launch.fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)
            var writer: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
            defer { sqlite3_close(writer) }
            XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
            await assertAFailedTakeoverGivesTheResumeBack(launch: launch, signals: signals) {
                XCTAssertEqual(sqlite3_exec(writer, "COMMIT;", nil, nil, nil), SQLITE_OK)
            }
        }

        /// The resume at launch waits for the path while the app is in the foreground. The app leaves the foreground, the
        /// path arrives before its observer, and a window cannot start the pass it takes. The window ends without a run,
        /// and the automatic pass stays pending. In the background the observer starts nothing (#832); once the person
        /// opens the app, the observer starts the automatic pass.
        private func assertAFailedTakeoverGivesTheResumeBack(
            launch: LaunchResumeFixture, signals: FakeBackupRuntimeSignals, freeTheLock: () -> Void,
            file: StaticString = #filePath, line: UInt = #line
        ) async {
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, file: file, line: line)
            signals.setAppInBackground(true)
            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)

            let window = startWindow(controller, scan: scan)
            await window.task.value
            XCTAssertEqual(window.record.runIDs, [], "the window could not start a pass", file: file, line: line)
            XCTAssertEqual(
                controller.deferredStartOwnerForTesting, .foreground, "the automatic pass stays pending",
                file: file, line: line)

            freeTheLock()
            signals.announceChange()
            let startedInTheBackground = await waitUntil(timeout: .milliseconds(200)) { scan.starts.count > 0 }
            XCTAssertFalse(
                startedInTheBackground, "in the background only a window starts a pass", file: file, line: line)
            XCTAssertEqual(
                controller.deferredStartOwnerForTesting, .foreground, "the automatic pass still waits", file: file,
                line: line)
            signals.setAppInBackground(false)
            signals.announceChange()
            let ran = await waitUntil(timeout: .seconds(5)) { scan.completions.count == 1 && !controller.isSyncing }
            XCTAssertTrue(ran, "the observer starts the automatic pass", file: file, line: line)
            XCTAssertEqual(scan.owners.values, [.foreground], file: file, line: line)
            await controller.shutdown()
        }

        func testInTheForegroundAResumeAtLaunchThatWaitsForThePathKeepsItsPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-foreground-resume-window", source: .mobileDataOff(runtime))
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "a window never owns the pass of an open app")
            XCTAssertEqual(scan.owners.values, [.foreground])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheForegroundAWindowYieldsToAResumeAtLaunchThatWaitedBeforeItsObserver() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            let launch = try makeLaunchResumeFixture(
                prefix: "backup-foreground-resume-observer-gap", source: signals.source)
            defer { launch.cleanup() }
            let controller = launch.controller
            let scan = launch.scan
            scan.open.value = true
            launch.releaseResume()
            _ = await waitUntil { controller.launchResumeEndedForTesting }

            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "a window never owns the pass of an open app")
            XCTAssertEqual(scan.owners.values, [.foreground])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheBackgroundAWindowNeverOwnsADeferredManualPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update { $0.executionOpportunity = .backgroundPermitted }
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-background-deferred-manual-window", source: .mobileDataOff(runtime),
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scan = HeldScan()
            scan.open.value = true
            scan.install(on: controller)
            await controller.retryUserResolvableWork()
            let window = startWindow(controller, scan: scan)
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "the window cannot stop the explicit pass at its expiration")
            XCTAssertEqual(scan.owners.values, [.manual])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheBackgroundAWindowNeverTakesADeferredManualPassBeforeItsObserver() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: false)
            signals.setAppInBackground(true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "backup-background-manual-observer-gap", source: signals.source,
                firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scan = HeldScan()
            scan.open.value = true
            scan.install(on: controller)
            await controller.retryUserResolvableWork()
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .manual)

            signals.setNetworkDetermined(true)
            signals.setWaitsForWiFi(false)
            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded && scan.completions.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(window.record.runIDs, [], "the window never owns or expires the deferred manual pass")
            XCTAssertEqual(scan.owners.values, [.manual])
            await window.task.value
            await controller.shutdown()
        }

        func testInTheForegroundAWindowDoesNotTakeOverARunningResumeAtLaunch() async throws {
            let launch = try await makeRunningLaunchResume(
                prefix: "backup-foreground-running-resume-window", opportunity: .foregroundActive)
            defer { launch.fixture.cleanup() }
            let controller = launch.fixture.controller
            let scan = launch.fixture.scan

            let window = startWindow(controller, scan: scan)
            let ended = await waitUntil(timeout: .seconds(2)) { window.record.hasEnded }
            XCTAssertTrue(ended, "the window ends at once next to the pass of an open app")
            XCTAssertEqual(window.record.runIDs, [])
            scan.open.value = true
            await controller.shutdown()
        }

        /// The window ended once, after the one pass of the launch ran inside it with the window's own owner.
        private func assertWindowRanTheOnlyPass(
            _ window: BackgroundWindowProbe, scan: HeldScan, controller: PhotoLibraryBackupController,
            file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let ended = await waitUntil(timeout: .seconds(5)) { window.record.hasEnded }
            XCTAssertTrue(ended, "the window ends", file: file, line: line)
            XCTAssertEqual(window.record.runIDs.count, 1, "the window received the pass", file: file, line: line)
            XCTAssertEqual(
                window.record.completedScansAtEnd, 1, "the pass ran inside the window", file: file, line: line)
            XCTAssertEqual(
                scan.owners.values, [.iOSBackgroundTask], "the pass has the window's owner", file: file, line: line)
            XCTAssertNil(controller.deferredStartOwnerForTesting, "no resume is left waiting", file: file, line: line)
            await window.task.value
        }

        /// A backup that is on at launch with a determined path, whose resume at launch already runs and holds its scan.
        private func makeRunningLaunchResume(
            prefix: String, opportunity: LibraryExecutionOpportunity = .backgroundPermitted
        ) async throws -> (fixture: LaunchResumeFixture, runtime: LibraryRuntimeState, runID: String) {
            // The person opens the app, so the resume at launch starts its pass; then the app goes to `opportunity`.
            // In the background only a window starts a pass (#832), so the pass must start in the foreground.
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeLaunchResumeFixture(prefix: prefix, source: .mobileDataOff(runtime))
            fixture.releaseResume()
            _ = await waitUntil { fixture.scan.starts.count == 1 }
            XCTAssertEqual(fixture.scan.owners.values, [.foreground], "the resume at launch runs an automatic pass")
            let runID = try XCTUnwrap(fixture.controller.activeExecutionRunID)
            runtime.update { $0.executionOpportunity = opportunity }
            return (fixture, runtime, runID)
        }

        /// A backup that is on at launch, so the real resume at launch runs; the test decides when it may start.
        private func makeLaunchResumeFixture(
            prefix: String, source: BackupRuntimeSignalSource, databasePolicy: LibraryDatabasePolicy = .conservative
        ) throws -> LaunchResumeFixture {
            let suite = "\(prefix)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: "photoBackup.enabled.v1")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            var configuration = PhotoLibraryBackupController.Configuration(
                accountDataDirectory: directory, databasePolicy: databasePolicy, defaults: defaults,
                runtimeSignals: source, firstNetworkPathWait: .seconds(60))
            configuration.currentAccessState = { .full }
            let controller = PhotoLibraryBackupController(
                configuration: configuration, identityResolver: FakeIdentityResolver(), uploader: MockUploader())
            // Installed before the first await, so the resume at launch cannot pass the gate unseen.
            let gate = HeldBackupSleepClock(clock: BackupTestClock())
            controller.holdLaunchResumeForTesting { try? await gate.sleep(for: 0) }
            let scan = HeldScan()
            scan.install(on: controller)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(kind: .fileURL, identifier: "waiting-photo"), revision: .init(rawValue: 1),
                        originalFilename: "waiting-photo.jpg", state: .discovered, lastError: nil,
                        updatedAt: Date().addingTimeInterval(-60))))
            queue.close()
            return LaunchResumeFixture(
                fixture: ControllerFixture(
                    controller: controller, defaults: defaults, suite: suite, directory: directory),
                gate: gate, scan: scan)
        }

        private struct LaunchResumeFixture {
            let fixture: ControllerFixture
            let gate: HeldBackupSleepClock
            let scan: HeldScan

            var controller: PhotoLibraryBackupController { fixture.controller }

            func releaseResume() { gate.releaseAll() }

            func cleanup() {
                gate.releaseAll()
                scan.open.value = true
                fixture.cleanup()
            }
        }

        private struct BackgroundWindowProbe {
            let task: Task<Void, Never>
            let record: BackgroundWindowRecord
        }

        private func startWindow(_ controller: PhotoLibraryBackupController, scan: HeldScan) -> BackgroundWindowProbe {
            let record = BackgroundWindowRecord()
            let task = Task { @MainActor in
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { record.received($0) }
                record.end(completedScans: scan.completions.count)
            }
            return BackgroundWindowProbe(task: task, record: record)
        }

        /// Holds the wait for the first network path until the test releases it, so the bounded wait ends on cue.
        private func holdFirstNetworkPathWait(of controller: PhotoLibraryBackupController) -> HeldBackupSleepClock {
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            controller.replaceFirstNetworkPathSleepForTesting { wait in
                let (seconds, attoseconds) = wait.components
                try? await clock.sleep(for: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
            }
            return clock
        }

        // MARK: Refresh window (#832)

        /// A backup with one runnable photo in the queue, while no scene is in the foreground unless `inForeground`. The
        /// network is known and usable unless `networkKnown` is false.
        private func makeRefreshFixture(
            prefix: String, networkKnown: Bool = true, inForeground: Bool = false,
            runtime: LibraryRuntimeState = .makeProcessState()
        ) throws -> ControllerFixture {
            runtime.update { $0.executionOpportunity = inForeground ? .foregroundActive : .backgroundPermitted }
            if networkKnown {
                runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }
            }
            return try makeWiFiWaitFixture(
                prefix: prefix, source: .mobileDataOff(runtime), firstNetworkPathWait: .seconds(60))
        }

        private func queueSummary(_ fixture: ControllerFixture) throws -> UploadBackupSyncQueueSummary {
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            return queue.summary()!
        }

        func testARefreshScanScansUnderItsOwnOwnerAndUploadsNothing() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-only", runtime: runtime)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            let before = try queueSummary(fixture)
            XCTAssertEqual(before.waiting, 1, "one photo waits for its upload")

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(owners.values, [.iOSRefreshTask])
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "the runner never drains, so nothing uploads")
            XCTAssertEqual(try queueSummary(fixture), before, "the photo still waits")
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting, "a refresh scan in the background plans no pass")
            XCTAssertFalse(controller.isSyncing)
            // The counter sees a drain: an ordinary pass of the same backup starts one. In the background only a
            // window starts a pass (#832), so the ordinary pass starts in the foreground.
            runtime.update { $0.executionOpportunity = .foregroundActive }
            controller.syncNow()
            let drained = await waitUntil { controller.reconcileStartsForTesting == 1 }
            XCTAssertTrue(drained, "an ordinary pass starts the reconcile loop")
            await controller.shutdown()
        }

        /// A scene came to the foreground during the scan and found the pass busy. The end of the scan then plans the
        /// next pass as every pass does, so the person's backup does not wait for the next change.
        func testARefreshScanThatEndsInTheForegroundPlansTheNextPassAsBefore() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-foreground", inForeground: true)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(controller.consecutiveNoProgressRunsForTesting, 0, "a scan is no pass without progress")
            let passStarted = await waitUntil { controller.reconcileStartsForTesting == 1 }
            XCTAssertTrue(passStarted, "the person's pass starts after the scan")
            await controller.shutdown()
        }

        func testARefreshScanDoesNotWaitForTheFirstNetworkPath() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-no-path", networkKnown: false)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned, "a scan needs no network")
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(controller.deferredStartWaiterCountForTesting, 0)
            await controller.shutdown()
        }

        func testARefreshScanStartsNothingWhileAnotherPassRuns() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-busy", inForeground: true, runtime: runtime)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let release = LockedFlag(false)
            controller.replaceScanForTesting {
                _ = scans.increment()
                while !release.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            }
            controller.syncNow()
            let running = await waitUntil { scans.count == 1 }
            XCTAssertTrue(running)
            // Without a running pass, the refresh scan below would run this held scan and never end.
            if !running { release.value = true }
            runtime.update { $0.executionOpportunity = .backgroundPermitted }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .notNeeded, "the running pass scans too")
            XCTAssertEqual(scans.count, 1, "never a second scan")
            release.value = true
            await controller.waitForSyncRunCompletionForTesting()
            await controller.shutdown()
        }

        func testARefreshWindowQueuesNewPhotosWhileTheFirstPathDeferralWaits() async throws {
            try await assertRefreshWindowQueuesNewPhotos(deferred: true)
        }

        func testARefreshWindowWithoutADeferralQueuesNewPhotosAsBefore() async throws {
            try await assertRefreshWindowQueuesNewPhotos(deferred: false)
        }

        private func assertRefreshWindowQueuesNewPhotos(deferred: Bool) async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: false, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "refresh-window-first-path", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            if deferred { controller.syncNow() }
            XCTAssertEqual(controller.deferredStartOwnerForTesting, deferred ? .foreground : nil)
            signals.setAppInBackground(true)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            let state = try XCTUnwrap(
                UploadBackupStateManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.stateDatabaseFileName)))
            defer {
                queue.close()
                state.close()
            }
            let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)
            let photo = UploadBackupAssetCandidate(
                snapshot: .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "new-photo"),
                    revision: .init(rawValue: 1), resourceCount: 1), originalFilename: "new-photo.heic")
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = try await engine.enqueueBatch([photo])
            }
            let events = WindowEvents()

            let outcome = await runRefreshWindow(events: events, wait: .ready(controller))

            XCTAssertEqual(outcome, .ran)
            XCTAssertEqual(owners.values, [.iOSRefreshTask])
            XCTAssertEqual(
                try queue.entry(for: photo.snapshot.source, revision: photo.snapshot.revision)?.state, .discovered)
            XCTAssertEqual(queue.summary()!.waiting, 2, "the existing photo and the new photo both wait")
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "the refresh window never starts an upload drain")
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting, "the background scan plans no upload pass")
            XCTAssertEqual(controller.deferredStartOwnerForTesting, deferred ? .foreground : nil)
            XCTAssertEqual(
                controller.deferredStartWaiterCountForTesting, 0, "the refresh scan never waits for the path")
            XCTAssertEqual(events.values, ["next", "account", "wait", "long window"])
            await controller.shutdown()
        }

        func testARefreshWindowStartsNoUploadWhenTheDeferredFirstPathArrivesDuringItsScan() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: false, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "refresh-window-path-arrives", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.syncNow()
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground)
            signals.setAppInBackground(true)
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                await MainActor.run {
                    owners.record(controller.executionOwnerForTesting)
                    signals.setNetworkDetermined(true)
                    controller.mobileDataSettingDidChange()
                    XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground)
                    XCTAssertEqual(controller.reconcileStartsForTesting, 0)
                }
            }
            let before = try queueSummary(fixture)
            let events = WindowEvents()

            let outcome = await runRefreshWindow(events: events, wait: .ready(controller))

            XCTAssertEqual(outcome, .ran)
            XCTAssertEqual(owners.values, [.iOSRefreshTask])
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "the arriving path starts no upload")
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the full pass stays pending")
            XCTAssertEqual(try queueSummary(fixture), before)
            XCTAssertFalse(controller.isAutoResumeScheduledForTesting)
            await controller.shutdown()
        }

        /// A long window whose pass waits for the first network path keeps its start as well.
        func testARefreshScanStartsNothingWhileALongWindowWaitsForTheFirstNetworkPath() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-window-waits", networkKnown: false)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let waiting = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertTrue(waiting, "the long window waits for the first path")

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .notNeeded)
            XCTAssertEqual(scans.count, 0)
            window.cancel()
            _ = await window.value
            await controller.shutdown()
        }

        /// #1013: the automatic pass of the person's visit waited for the first network path; the path is known now,
        /// but in the background only a window starts that pass. A refresh window still scans, and the pass stays.
        func testARefreshScanRunsWhileThePersonsPassWaitsForALongWindow() async throws {
            let parked = try makeParkedVisitPass(prefix: "refresh-scan-parked")
            defer { parked.fixture.cleanup() }
            let controller = parked.fixture.controller
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned, "the refresh window scans")
            XCTAssertEqual(owners.values, [.iOSRefreshTask])
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .foreground, "the person's pass still waits")
            XCTAssertFalse(controller.isSyncing)
            await controller.shutdown()
        }

        func testARefreshScanWhileThePersonsPassWaitsUploadsNothing() async throws {
            let parked = try makeParkedVisitPass(prefix: "refresh-scan-parked-no-upload")
            defer { parked.fixture.cleanup() }
            let controller = parked.fixture.controller
            controller.replaceScanForTesting {}
            let before = try queueSummary(parked.fixture)
            XCTAssertEqual(before.waiting, 1, "one photo waits for its upload")

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "the runner never drains, so nothing uploads")
            XCTAssertEqual(try queueSummary(parked.fixture), before, "the photo still waits")
            await controller.shutdown()
        }

        /// A long window during the scan makes the scan yield, then runs the person's pass that waited for it.
        func testALongWindowDuringTheRefreshScanRunsThePersonsWaitingPass() async throws {
            let parked = try makeParkedVisitPass(prefix: "refresh-scan-parked-long-window")
            defer { parked.fixture.cleanup() }
            let controller = parked.fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let refresh = Task { @MainActor in await controller.backgroundRefreshScan() }
            let scanning = await waitUntil { scans.count == 1 }
            XCTAssertTrue(scanning)

            // A long window that does not stop the scan would wait for it forever; the watchdog bounds the test.
            let watchdogFired = LockedFlag(false)
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                watchdogFired.value = true
                controller.stopSync()
            }
            let catchUp = await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
            watchdog.cancel()

            XCTAssertFalse(watchdogFired.value, "the long window stopped the scan itself")
            XCTAssertEqual(catchUp, .done)
            XCTAssertEqual(owners.values, [.iOSRefreshTask, .iOSBackgroundTask], "the long window's pass scanned")
            XCTAssertEqual(controller.reconcileStartsForTesting, 1, "the long window's pass drained the queue")
            XCTAssertNil(controller.deferredStartOwnerForTesting, "the long window took the person's pass")
            let refreshEnd = await refresh.value
            XCTAssertEqual(refreshEnd, .yielded, "the refresh scan yielded to the long window")
            await controller.shutdown()
        }

        /// The person opens the app during the scan; the pass of their visit starts when the scan ends.
        func testTheForegroundDuringTheRefreshScanStartsThePersonsWaitingPassAfterIt() async throws {
            let parked = try makeParkedVisitPass(prefix: "refresh-scan-parked-foreground")
            defer { parked.fixture.cleanup() }
            let controller = parked.fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            let release = LockedFlag(false)
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if scans.increment() == 1 {
                    while !release.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                }
            }
            let refresh = Task { @MainActor in await controller.backgroundRefreshScan() }
            let scanning = await waitUntil { scans.count == 1 }
            XCTAssertTrue(scanning)

            parked.runtime.update { $0.executionOpportunity = .foregroundActive }
            release.value = true
            let refreshEnd = await refresh.value
            XCTAssertEqual(refreshEnd, .scanned)

            let started = await waitUntil { controller.reconcileStartsForTesting == 1 && !controller.isSyncing }
            XCTAssertTrue(started, "the person's pass runs after the scan")
            XCTAssertEqual(owners.values, [.iOSRefreshTask, .foreground])
            XCTAssertNil(controller.deferredStartOwnerForTesting)
            await controller.shutdown()
        }

        /// The person's retry waits as well once the path is known, for example behind another run's lock. It can start
        /// in the background, so the refresh window leaves the lock free for it.
        func testARefreshScanStartsNothingWhileThePersonsRetryWaitsWithTheKnownPath() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: false, networkDetermined: false)
            let fixture = try makeWiFiWaitFixture(
                prefix: "refresh-scan-parked-manual", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
            }
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            await controller.retryUserResolvableWork()
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .manual, "the retry waits for the first path")
            // The path becomes known while the other run still holds the lock; the retry keeps waiting.
            signals.setAppInBackground(true)
            signals.setNetworkDetermined(true)
            controller.mobileDataSettingDidChange()
            XCTAssertEqual(controller.deferredStartOwnerForTesting, .manual)
            XCTAssertFalse(controller.isSyncing)
            XCTAssertTrue(lock.release(runID: "other-live-run"))

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .notNeeded, "the refresh window keeps the lock free for the person's retry")
            XCTAssertEqual(owners.values, [])
            // The next network update starts the retry in the background.
            signals.announceChange()
            let started = await waitUntil { owners.values == [.manual] && !controller.isSyncing }
            XCTAssertTrue(started, "the person's retry runs")
            await controller.shutdown()
        }

        /// The person's visit starts the automatic pass before the first network path; the app then leaves the
        /// foreground, and the path arrives. In the background the pass waits for a long window or the foreground.
        private struct ParkedVisitPass {
            let fixture: ControllerFixture
            let runtime: LibraryRuntimeState
        }

        private func makeParkedVisitPass(prefix: String) throws -> ParkedVisitPass {
            let runtime = LibraryRuntimeState.makeProcessState()
            let fixture = try makeRefreshFixture(
                prefix: prefix, networkKnown: false, inForeground: true, runtime: runtime)
            fixture.controller.syncNow()
            XCTAssertFalse(fixture.controller.isSyncing, "the pass waits for the first path")
            XCTAssertEqual(fixture.controller.deferredStartOwnerForTesting, .foreground)
            runtime.update {
                $0.executionOpportunity = .backgroundPermitted
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            return ParkedVisitPass(fixture: fixture, runtime: runtime)
        }

        /// A long window arrives while a refresh scan runs. The scan yields its lock, and the long window's pass scans and
        /// uploads; the refresh window needed nothing.
        func testALongWindowTakesTheLockOverFromARefreshScan() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-yields")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let owners = OwnerRecorder()
            controller.replaceScanForTesting {
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let refresh = Task { @MainActor in
                await self.runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            }
            let scanning = await waitUntil { scans.count == 1 }
            XCTAssertTrue(scanning)

            // A long window that does not stop the scan would wait for it forever; the watchdog bounds the test.
            let watchdogFired = LockedFlag(false)
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                watchdogFired.value = true
                controller.stopSync()
            }
            let longWindow = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let catchUp = await longWindow.value
            watchdog.cancel()

            XCTAssertFalse(watchdogFired.value, "the long window stopped the scan itself")
            XCTAssertEqual(catchUp, .done)
            XCTAssertEqual(owners.values, [.iOSRefreshTask, .iOSBackgroundTask], "the long window's pass scanned")
            XCTAssertEqual(controller.reconcileStartsForTesting, 1, "the long window's pass drained the queue")
            // A scan that did not yield would hold forever; stopping it bounds the test.
            controller.stopSync()
            let refreshOutcome = await refresh.value
            XCTAssertEqual(refreshOutcome, .notNeeded)
            await controller.shutdown()
        }

        /// The long window expired while the scan it stopped came to its end: it starts no pass.
        func testAnExpiredLongWindowStartsNoPassAfterTheRefreshScanEnded() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-yield-expired")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            let release = LockedFlag(false)
            controller.replaceScanForTesting {
                // The first scan ends only when the test releases it, also after a stop.
                if scans.increment() == 1 {
                    while !release.value { try? await Task.sleep(for: .milliseconds(10)) }
                }
            }
            let refresh = Task { @MainActor in await controller.backgroundRefreshScan() }
            let scanning = await waitUntil { scans.count == 1 }
            XCTAssertTrue(scanning)
            let window = Task { @MainActor in await controller.backgroundCatchUp(owner: .iOSBackgroundTask) }
            let stopping = await waitUntil { controller.isRunnerStopPendingForTesting }
            XCTAssertTrue(stopping, "the long window stopped the scan")

            // The iOS expiration handler cancels the long window's work while it waits for the scan's end.
            window.cancel()
            release.value = true

            let end = await window.value
            XCTAssertEqual(end, .done)
            _ = await refresh.value
            XCTAssertEqual(controller.reconcileStartsForTesting, 0, "an expired window starts no pass")
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        /// Another run holds the lock, for example after a crash of a run whose lease has not ended yet. Its pass
        /// covers the scan: nothing was needed.
        func testARefreshScanWhileAnotherRunHoldsTheLockIsNotNeeded() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-busy-lock")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let lock = try XCTUnwrap(
                BackupExecutionLockManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.lockDatabaseFileName)))
            defer { lock.close() }
            XCTAssertTrue(lock.acquire(owner: .background, runID: "other-live-run").didAcquire)
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()
            XCTAssertEqual(end, .notNeeded)
            let outcome = await runRefreshWindow(events: WindowEvents(), wait: .ready(controller))
            XCTAssertEqual(outcome, .notNeeded)
            XCTAssertEqual(scans.count, 0)
            XCTAssertTrue(lock.release(runID: "other-live-run"))
            await controller.shutdown()
        }

        /// The retry date of the remote index holds upload passes, not the scan.
        func testARefreshScanRunsWhileTheRemoteIndexWaitsForItsRetry() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-index-retry")
            defer { fixture.cleanup() }
            try holdAutomaticPasses(in: fixture)
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(scans.count, 1)
            await controller.shutdown()
        }

        /// The person's retry waits for Wi-Fi, which is back. The refresh window must not start that upload pass.
        /// In the foreground, the end of the scan starts the app's own pass, and that pass resumes the retry (#1183).
        func testARefreshScanNeverStartsTheResumedManualRetry() async throws {
            let signals = FakeBackupRuntimeSignals(waitsForWiFi: true, networkDetermined: true)
            let fixture = try makeWiFiWaitFixture(
                prefix: "refresh-scan-manual-retry", source: signals.source, firstNetworkPathWait: .seconds(60))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let owners = OwnerRecorder()
            let releaseFollowUp = LockedFlag(false)
            controller.replaceScanForTesting {
                let owner = await MainActor.run { controller.executionOwnerForTesting }
                // The retry's pass after the refresh scan waits here until the test has read the retry and the scan.
                if owner == .manual, owners.values.contains(.iOSRefreshTask) {
                    while !releaseFollowUp.value, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                }
                owners.record(owner)
            }
            await controller.retryUserResolvableWork()
            let waiting = await waitUntil { controller.status.phase == .waitingForWiFi && !controller.isSyncing }
            XCTAssertTrue(waiting, "the manual pass waits for Wi-Fi")
            // Publish the snapshot without notifying the observer: the retry could resume now.
            signals.setWaitsForWiFi(false)

            let end = await controller.backgroundRefreshScan()

            XCTAssertEqual(end, .scanned)
            XCTAssertEqual(owners.values, [.manual, .iOSRefreshTask])

            // The app is in the foreground, so the end of the scan starts the app's pass, which resumes the retry.
            // Later passes, for example the automatic resume, can follow it.
            releaseFollowUp.value = true
            let resumed = await waitUntil(timeout: .seconds(30)) { owners.values.count >= 3 }
            XCTAssertTrue(resumed, "the app's pass after the scan ran")
            XCTAssertEqual(Array(owners.values.prefix(3)), [.manual, .iOSRefreshTask, .manual])
            await controller.shutdown()
        }

        func testTheEndOfTheWindowStopsTheRefreshScanAndFreesTheLock() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-stopped")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting {
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let runIDs = OwnerRecorder()
            let window = Task { @MainActor in
                await controller.backgroundRefreshScan { runIDs.record(BackupExecutionOwner(rawValue: $0)) }
            }
            let started = await waitUntil { scans.count == 1 && !runIDs.values.isEmpty }
            XCTAssertTrue(started)

            let runID = try XCTUnwrap(runIDs.values.first ?? nil).rawValue
            controller.stopBackgroundWindowRun(runID: runID)

            let end = await window.value
            XCTAssertEqual(end, .stopped)
            let next = await controller.backgroundRefreshScan()
            XCTAssertEqual(next, .scanned, "the stopped scan released the lock")
            XCTAssertEqual(scans.count, 2)
            await controller.shutdown()
        }

        private final class WindowEvents {
            var values: [String] = []
            var limit: Duration?
        }

        private func runRefreshWindow(
            events: WindowEvents, lowPower: Bool = false, didExpire: (() -> Bool)? = nil,
            wait: BackgroundAccountWait<PhotoLibraryBackupController>
        ) async -> BackgroundWindowOutcome {
            await PhotoLibraryRefreshWindow.run(
                scheduleNext: { events.values.append("next") },
                isLowPowerModeOn: { lowPower },
                startAccount: { events.values.append("account") },
                waitForController: { limit in
                    events.values.append("wait")
                    events.limit = limit
                    return wait
                },
                didExpire: didExpire ?? { false },
                backupStopped: { events.values.append("backup stopped") },
                backupPaused: { events.values.append("backup paused") },
                ensureLongWindowRequest: { events.values.append("long window") },
                onRunStarted: { _ in })
        }

        func testARefreshWindowSubmitsItsNextRequestFirstAndWaitsFifteenSecondsForTheAccount() async {
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, wait: .cannotRun(.noAccount))
            XCTAssertEqual(
                events.values, ["next", "account", "wait"], "a window that scanned nothing asks for nothing")
            XCTAssertEqual(events.limit, .seconds(15))
            XCTAssertEqual(outcome, .noAccount)
        }

        func testARefreshWindowInLowPowerModeDoesNothing() async {
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, lowPower: true, wait: .notReady)
            XCTAssertEqual(outcome, .notNeeded)
            XCTAssertEqual(events.values, ["next"], "no account start and no scan")
        }

        func testARefreshWindowWithoutItsAccountRecordsWhy() async {
            let locked = await runRefreshWindow(events: WindowEvents(), wait: .cannotRun(.endedAtOnceLocked))
            XCTAssertEqual(locked, .endedAtOnceLocked)
            let late = await runRefreshWindow(events: WindowEvents(), wait: .notReady)
            XCTAssertEqual(late, .failed)
            let expired = await runRefreshWindow(events: WindowEvents(), didExpire: { true }, wait: .notReady)
            XCTAssertEqual(expired, .expired)
        }

        func testARefreshWindowWithBackupOffOrPausedScansNothing() async throws {
            let off = try makeControllerFixture(prefix: "refresh-window-off")
            defer { off.cleanup() }
            let offScans = PassCounter()
            off.controller.replaceScanForTesting { _ = offScans.increment() }
            let offEvents = WindowEvents()
            let offOutcome = await runRefreshWindow(events: offEvents, wait: .ready(off.controller))
            XCTAssertEqual(offOutcome, .notNeeded)
            XCTAssertEqual(offScans.count, 0)
            XCTAssertEqual(offEvents.values.last, "backup stopped", "as the long window, the window stops scheduling")
            await off.controller.shutdown()

            let paused = try makeRefreshFixture(prefix: "refresh-window-paused")
            defer { paused.cleanup() }
            let pausedScans = PassCounter()
            paused.controller.replaceScanForTesting { _ = pausedScans.increment() }
            paused.controller.pauseBackup()
            let pausedEvents = WindowEvents()
            let pausedOutcome = await runRefreshWindow(events: pausedEvents, wait: .ready(paused.controller))
            XCTAssertEqual(pausedOutcome, .notNeeded)
            XCTAssertEqual(pausedScans.count, 0)
            XCTAssertEqual(pausedEvents.values.last, "backup paused")
            await paused.controller.shutdown()
        }

        /// The window expired while it waited for the account: no scan starts in it.
        func testARefreshWindowThatExpiredDuringTheAccountWaitScansNothing() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-expired")
            defer { fixture.cleanup() }
            let scans = PassCounter()
            fixture.controller.replaceScanForTesting { _ = scans.increment() }
            let outcome = await runRefreshWindow(
                events: WindowEvents(), didExpire: { true }, wait: .ready(fixture.controller))
            XCTAssertEqual(outcome, .expired)
            XCTAssertEqual(scans.count, 0)
            await fixture.controller.shutdown()
        }

        func testARefreshWindowWhoseScanWasStoppedFailed() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-stopped")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting {
                await MainActor.run { controller.stopSync() }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                throw CancellationError()
            }
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, wait: .ready(controller))
            XCTAssertEqual(outcome, .failed, "a scan stopped before the window's end did not do its work")
            XCTAssertEqual(events.values.last, "long window", "what the stopped scan queued waits for a long window")
            await controller.shutdown()
        }

        func testARefreshWindowThatExpiredDuringItsScanExpired() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-expired-scan")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let expired = LockedFlag(false)
            controller.replaceScanForTesting {
                expired.value = true
                await MainActor.run { controller.stopSync() }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                throw CancellationError()
            }
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, didExpire: { expired.value }, wait: .ready(controller))
            XCTAssertEqual(outcome, .expired)
            XCTAssertFalse(events.values.contains("long window"), "an expired window ends at once")
            await controller.shutdown()
        }

        func testARefreshWindowThatExpiredAfterItsScanExpired() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-expired-after-scan")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let expired = LockedFlag(false)
            controller.replaceScanForTesting { expired.value = true }
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, didExpire: { expired.value }, wait: .ready(controller))
            XCTAssertEqual(outcome, .expired, "an expiry decides first, as for every window")
            XCTAssertFalse(events.values.contains("long window"), "an expired window ends at once")
            await controller.shutdown()
        }

        func testARefreshScanThatFailsReportsAFailure() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-scan-fails")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.replaceScanForTesting { throw UploadError.backend("scan state could not be saved") }
            let end = await controller.backgroundRefreshScan()
            XCTAssertEqual(end, .failed)
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, wait: .ready(controller))
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(events.values.last, "long window", "a failed scan may have queued photos before it failed")
            await controller.shutdown()
        }

        /// Without photo access no scan can start; that is a failure, not "nothing needed".
        func testARefreshWindowWithoutPhotoAccessFails() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-no-access")
            defer { fixture.cleanup() }
            let controller = fixture.controller
            let scans = PassCounter()
            controller.replaceScanForTesting { _ = scans.increment() }
            controller.setAccessStateForTesting(.denied)
            let end = await controller.backgroundRefreshScan()
            XCTAssertEqual(end, .couldNotStart)
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, wait: .ready(controller))
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(scans.count, 0)
            XCTAssertFalse(events.values.contains("long window"), "a scan that never started queued nothing")
            await controller.shutdown()
        }

        /// The window's end stops a scan while a scene is in the foreground and the queue is empty. The person's pass
        /// starts after it, and the stopped scan does not count as a pass without progress.
        func testARefreshScanStoppedInTheForegroundStartsThePersonsPass() async throws {
            let runtime = LibraryRuntimeState.makeProcessState()
            runtime.update {
                $0.executionOpportunity = .foregroundActive
                $0.network = LibraryNetworkState(isReachable: true, isExpensive: false)
            }
            let fixture = try makeControllerFixture(
                prefix: "refresh-scan-foreground-stopped", identityResolver: FakeIdentityResolver(),
                runtimeSignals: .mobileDataOff(runtime))
            defer { fixture.cleanup() }
            let controller = fixture.controller
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            // An empty queue, as after a finished backup.
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertEqual(queue.summary()!.total, 0)
            queue.close()
            let scans = PassCounter()
            controller.replaceScanForTesting {
                if scans.increment() == 1 {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    throw CancellationError()
                }
            }
            let runIDs = OwnerRecorder()
            let window = Task { @MainActor in
                await controller.backgroundRefreshScan { runIDs.record(BackupExecutionOwner(rawValue: $0)) }
            }
            let started = await waitUntil { scans.count == 1 && !runIDs.values.isEmpty }
            XCTAssertTrue(started)
            guard let runID = runIDs.values.first??.rawValue else {
                window.cancel()
                _ = await window.value
                return XCTFail("the refresh scan did not start")
            }

            controller.stopBackgroundWindowRun(runID: runID)

            let end = await window.value
            XCTAssertEqual(end, .stopped)
            XCTAssertEqual(controller.consecutiveNoProgressRunsForTesting, 0)
            let passStarted = await waitUntil { controller.reconcileStartsForTesting == 1 }
            XCTAssertTrue(passStarted, "the person's pass starts after the stopped scan")
            await controller.shutdown()
        }

        func testARefreshWindowThatScannedRan() async throws {
            let fixture = try makeRefreshFixture(prefix: "refresh-window-ran")
            defer { fixture.cleanup() }
            let scans = PassCounter()
            fixture.controller.replaceScanForTesting { _ = scans.increment() }
            let events = WindowEvents()
            let outcome = await runRefreshWindow(events: events, wait: .ready(fixture.controller))
            XCTAssertEqual(outcome, .ran)
            XCTAssertEqual(scans.count, 1)
            XCTAssertEqual(
                events.values, ["next", "account", "wait", "long window"],
                "a scan that ran makes sure that iOS holds a request for the next long window")
            await fixture.controller.shutdown()
        }

        func testARefreshWindowIsRecordedAsItsOwnKind() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "refresh-window-kind-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ledger = BackgroundWindowLedger(
                fileURL: directory.appendingPathComponent("windows.json"), isPurgePending: { false })
            let heard = LockedFlag(true)
            let completion = PhotoLibraryRefreshWindow.begin(ledger: ledger) { heard.value = $0 }
            await completion.finish(.notNeeded, after: {})
            XCTAssertEqual(ledger.records().map(\.kind), [.libraryRefresh])
            XCTAssertEqual(ledger.supportSnapshot().counts.map(\.kind), [.libraryRefresh])
        }

        /// Records a remote index issue with a retry date in an hour, which holds every pass except an explicit one.
        private func holdAutomaticPasses(in fixture: ControllerFixture) throws {
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { queue.close() }
            let issue = BackupIssueRecord(
                kind: .remoteService, detail: "index unavailable", nextAttemptAt: Date().addingTimeInterval(3_600))
            XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
        }

        private func runtimeSource(_ runtime: LibraryRuntimeState, usesMobileData: Bool) -> BackupRuntimeSignalSource {
            BackupRuntimeSignalSource(
                current: { BackupThrottleInputs(runtime: runtime.snapshot(), usesMobileData: usesMobileData) },
                updates: { runtime.updates() })
        }

        /// A backup with one runnable row whose scan never touches PhotoKit; only the runner drains.
        private func makeWiFiWaitFixture(
            prefix: String, source: BackupRuntimeSignalSource, dismissedSourceRecheck: Bool = false,
            firstNetworkPathWait: Duration = .seconds(10),
            backgroundLog: BackgroundWorkLog = BackgroundWorkLog { _, _ in }
        ) throws -> ControllerFixture {
            let fixture = try makeControllerFixture(
                prefix: prefix, identityResolver: FakeIdentityResolver(), runtimeSignals: source,
                firstNetworkPathWait: firstNetworkPathWait, backgroundLog: backgroundLog)
            fixture.controller.setEnabledForTesting()
            fixture.controller.setAccessStateForTesting(.full)
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: .init(
                            kind: dismissedSourceRecheck ? .photoLibraryAsset : .fileURL, identifier: "waiting-photo"),
                        revision: .init(rawValue: 1), originalFilename: "waiting-photo.jpg", state: .discovered,
                        lastError: dismissedSourceRecheck
                            ? BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
                            : nil,
                        updatedAt: Date().addingTimeInterval(-60))))
            queue.close()
            return fixture
        }
    #endif

    private func waitUntil(timeout: Duration = .seconds(5), _ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private struct ControllerFixture {
        let controller: PhotoLibraryBackupController
        let defaults: UserDefaults
        let suite: String
        let directory: URL

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testBackupThatIsOffAtLaunchOrTurnedOffReportsThatNoIndexBuildIsNeeded() async throws {
        let resolver = FakeIdentityResolver()
        let fixture = try makeControllerFixture(prefix: "backup-off-index", enabled: false, identityResolver: resolver)
        defer { fixture.cleanup() }
        try await waitForReports(1, from: resolver, "a launch with backup off")

        fixture.controller.disableBackup()
        try await waitForReports(2, from: resolver, "turning backup off")
    }

    #if DEBUG
        func testTurningBackupOffThatWasOnReportsThatNoIndexBuildIsNeeded() async throws {
            let resolver = FakeIdentityResolver()
            let fixture = try makeControllerFixture(prefix: "backup-on-off-index", identityResolver: resolver)
            defer { fixture.cleanup() }
            try await waitForReports(1, from: resolver, "a launch with backup off")
            fixture.controller.setEnabledForTesting()

            fixture.controller.disableBackup()
            try await waitForReports(2, from: resolver, "turning backup off after it was on")
        }

        func testAPassWhoseScanFinishedWithNothingToUploadReportsThatNoIndexBuildIsNeeded() async throws {
            let resolver = FakeIdentityResolver()
            let reports = try await reportsAfterAPass(prefix: "backup-scan-done-index", resolver: resolver) {}
            XCTAssertEqual(reports, 1, "the finished scan found nothing, so no index build follows")
        }

        func testAPassWhoseScanFailedReportsNothing() async throws {
            let resolver = FakeIdentityResolver()
            let reports = try await reportsAfterAPass(prefix: "backup-scan-failed-index", resolver: resolver) {
                throw UploadError.backend("Photo library scan state could not be saved")
            }
            XCTAssertEqual(reports, 0, "a scan that did not finish may have missed photos that start an index build")
        }

        /// Runs one pass over an empty queue with `scan` in place of the photo library scan, and returns the reports of
        /// no index build that the pass sent. The launch with backup off reports once before the pass; it is not
        /// counted.
        private func reportsAfterAPass(
            prefix: String, resolver: FakeIdentityResolver, scan: @escaping @Sendable () async throws -> Void
        ) async throws -> Int {
            let fixture = try makeControllerFixture(
                prefix: prefix, identityResolver: resolver, runtimeSignals: .wiFiWithMobileDataOff)
            defer { fixture.cleanup() }
            let controller = fixture.controller
            try await waitForReports(1, from: resolver, "a launch with backup off")
            controller.setEnabledForTesting()
            controller.setAccessStateForTesting(.full)
            let scans = PassCounter()
            controller.replaceScanForTesting {
                _ = scans.increment()
                try await scan()
            }

            controller.syncNow()
            let finished = await waitUntil(timeout: .seconds(10)) { scans.count == 1 && !controller.isSyncing }
            XCTAssertTrue(finished, "the pass must run its scan and end")
            let reports = resolver.remoteIndexPreparationNotNeededCount - 1
            await controller.shutdown()
            return reports
        }
    #endif

    private func waitForReports(
        _ count: Int, from resolver: FakeIdentityResolver, _ description: String, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while resolver.remoteIndexPreparationNotNeededCount < count, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            resolver.remoteIndexPreparationNotNeededCount, count, "\(description) reports no index build", file: file,
            line: line)
    }

    private func makeControllerFixture(
        prefix: String, enabled: Bool = false, identityResolver: (any UploadIdentityResolving)? = nil,
        runtimeSignals: BackupRuntimeSignalSource = .apple, firstNetworkPathWait: Duration = .seconds(10),
        backgroundLog: BackgroundWorkLog = BackgroundWorkLog { _, _ in }
    ) throws -> ControllerFixture {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if enabled { defaults.set(true, forKey: "photoBackup.enabled.v1") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        var configuration = PhotoLibraryBackupController.Configuration(
            accountDataDirectory: directory,
            databasePolicy: .conservative,
            defaults: defaults,
            runtimeSignals: runtimeSignals,
            firstNetworkPathWait: firstNetworkPathWait
        )
        configuration.backgroundLog = backgroundLog
        let controller = PhotoLibraryBackupController(
            configuration: configuration,
            identityResolver: identityResolver,
            uploader: MockUploader()
        )
        return ControllerFixture(
            controller: controller,
            defaults: defaults,
            suite: suite,
            directory: directory
        )
    }

    /// Controls the projector's stream consumer timing for the straggler-regression test: holds
    /// each event until a gate opens, then notifies waiters after each consumed event.
    private actor StatusIngestionLatch {
        private var open = false
        private var consumedCount = 0
        private var gateWaiters: [CheckedContinuation<Void, Never>] = []
        private var consumedWaiters: [CheckedContinuation<Void, Never>] = []

        func openGate() {
            guard !open else { return }
            open = true
            let waiters = gateWaiters
            gateWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func waitUntilOpen() async {
            if open { return }
            await withCheckedContinuation { continuation in
                gateWaiters.append(continuation)
            }
        }

        func noteConsumed() {
            consumedCount += 1
            let waiters = consumedWaiters
            consumedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func waitUntilConsumed() async {
            guard consumedCount > 0 else {
                await withCheckedContinuation { continuation in
                    consumedWaiters.append(continuation)
                }
                return
            }
        }
    }

    private actor NonCooperativeWriterLatch {
        private var started = false
        private var blocked = false
        private var completed = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

        func markStarted() {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                if started {
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                }
            }
        }

        func isStarted() -> Bool { started }

        func waitUntilBlocked() async {
            guard !blocked else { return }
            await withCheckedContinuation { continuation in
                if blocked {
                    continuation.resume()
                } else {
                    blockedWaiters.append(continuation)
                }
            }
        }

        func waitUntilReleased() async {
            blocked = true
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    private func makeNonCooperativeWriter(
        _ writer: NonCooperativeWriterLatch
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await writer.markStarted()
            await writer.waitUntilReleased()
            await writer.markCompleted()
        }
    }

    private actor CompletionLatch {
        private var completed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markCompleted() {
            guard !completed else { return }
            completed = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }

        func waitUntilCompleted() async {
            guard !completed else { return }
            await withCheckedContinuation { continuation in
                if completed {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func isCompleted() -> Bool { completed }
    }

    private actor DelayedRunnerStop {
        private var calls = 0
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func stop() async {
            calls += 1
            if !started {
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func callCount() -> Int { calls }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                if started {
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                }
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}

/// Injected runtime signals: the test decides when the network is cellular with mobile data off, and when it changes.
private final class FakeBackupRuntimeSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var waitsForWiFi: Bool
    private var networkDetermined: Bool
    private var networkAvailable = true
    private var usesMobileData = false
    private var appInBackground = false
    private var reads = 0
    private var continuations: [AsyncStream<LibraryRuntimeSnapshot>.Continuation] = []

    init(waitsForWiFi: Bool, networkDetermined: Bool = true) {
        self.waitsForWiFi = waitsForWiFi
        self.networkDetermined = networkDetermined
    }

    var source: BackupRuntimeSignalSource {
        BackupRuntimeSignalSource(
            current: { self.read() },
            updates: { AsyncStream { continuation in self.lock.withLock { self.continuations.append(continuation) } } }
        )
    }

    func setWaitsForWiFi(_ value: Bool) { lock.withLock { waitsForWiFi = value } }

    func setNetworkAvailable(_ value: Bool) { lock.withLock { networkAvailable = value } }

    func setUsesMobileData(_ value: Bool) { lock.withLock { usesMobileData = value } }

    func setAppInBackground(_ value: Bool) { lock.withLock { appInBackground = value } }

    var hasBeenRead: Bool { lock.withLock { reads > 0 } }

    func resetReads() { lock.withLock { reads = 0 } }

    func setNetworkDetermined(_ value: Bool) { lock.withLock { networkDetermined = value } }

    func announceChange() {
        let continuations = lock.withLock { self.continuations }
        continuations.forEach { $0.yield(LibraryRuntimeSnapshot()) }
    }

    func waitUntilRead(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while lock.withLock({ reads == 0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func read() -> BackupThrottleInputs {
        lock.withLock {
            reads += 1
            return BackupThrottleInputs(
                isNetworkAvailable: networkAvailable, isNetworkExpensive: waitsForWiFi, usesMobileData: usesMobileData,
                isNetworkDetermined: networkDetermined, isAppInBackground: appInBackground)
        }
    }
}

#if DEBUG
    /// A scan that records its owner and runs until the test opens it. A stop cancels it before it completes.
    private final class HeldScan: @unchecked Sendable {
        let starts = PassCounter()
        let completions = PassCounter()
        let owners = OwnerRecorder()
        let open = LockedFlag(false)

        @MainActor
        func install(on controller: PhotoLibraryBackupController) {
            controller.replaceScanForTesting { [self] in
                // The owner is recorded before the count rises, so a wait for the count also sees the owner.
                owners.record(await MainActor.run { controller.executionOwnerForTesting })
                _ = starts.increment()
                while !open.value { try await Task.sleep(for: .milliseconds(5)) }
                _ = completions.increment()
            }
        }
    }
#endif

/// What one background window received from `backgroundCatchUp`, and how many scans had completed when it ended.
private final class BackgroundWindowRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    private var scansAtEnd: Int?

    var runIDs: [String] { lock.withLock { ids } }
    var hasEnded: Bool { lock.withLock { scansAtEnd != nil } }
    var completedScansAtEnd: Int? { lock.withLock { scansAtEnd } }

    func received(_ runID: String) { lock.withLock { ids.append(runID) } }
    func end(completedScans: Int) { lock.withLock { scansAtEnd = completedScans } }
}

/// Cancels one window's task from wherever the test decides that iOS expires it.
private final class WindowExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var window: Task<Void, Never>?

    func arm(_ window: Task<Void, Never>) { lock.withLock { self.window = window } }

    func expire() { lock.withLock { window }?.cancel() }
}

private final class OwnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BackupExecutionOwner?] = []

    var values: [BackupExecutionOwner?] { lock.withLock { recorded } }

    func record(_ owner: BackupExecutionOwner?) { lock.withLock { recorded.append(owner) } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class PassCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

extension PhotoLibraryBackupControllerStateTests {
    private final class RestoreAdmissionStateSpy: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var writes = 0
        var upsertCount: Int { lock.withLock { writes } }
        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            nil
        }
        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool { false }
        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { writes += 1 }
            return true
        }
        func count() -> Int { 0 }
    }

    func testRestoreAdmissionDistinguishesUnsupportedStoreFromOwnedWorkWithoutWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for terminal in [true, false] {
            let inner = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
            )
            defer { inner.close() }
            let snapshot = UploadBackupAssetSnapshot(
                source: .init(kind: .photoLibraryAsset, identifier: "restored"),
                revision: .init(rawValue: 42), resourceCount: 2)
            let candidate = UploadBackupAssetCandidate(
                snapshot: snapshot, originalFilename: "restored.heic", byteCount: 1)
            let row = UploadBackupSyncQueueEntry(
                source: snapshot.source, revision: snapshot.revision, originalFilename: candidate.originalFilename,
                state: terminal ? .completed : .uploading, attempts: 3,
                lastError: "kept", updatedAt: Date(timeIntervalSince1970: 1_000))
            XCTAssertTrue(inner.upsert(row))
            let log = BackupEventLog()
            let queue: any UploadBackupSyncQueueStore = SpyQueueStore(inner: inner, log: log)
            let state = RestoreAdmissionStateSpy()
            let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)
            let before = Date()

            let outcome = await PhotoLibraryBackupController.restoredCompoundDeferral(
                engine: engine, candidate: candidate, isCurrent: { true })

            if terminal {
                XCTAssertEqual(outcome, .unreadable, "Unsupported must not become another ordinary 30-second wait")
            } else {
                guard case .waiting(let until)? = outcome else { return XCTFail("Owned active work must still wait") }
                XCTAssertGreaterThanOrEqual(until, before.addingTimeInterval(30))
                XCTAssertLessThanOrEqual(until, Date().addingTimeInterval(30))
            }
            XCTAssertEqual(state.upsertCount, 0)
            XCTAssertTrue(log.events.isEmpty)
            XCTAssertEqual(try inner.entry(for: row.source, revision: row.revision), row)
            XCTAssertTrue(inner.isOperational())
        }
    }
}

extension PhotoLibraryBackupControllerStateTests {
    private final class Restore829Resolver: BackupResourceResolving, @unchecked Sendable {
        let candidate: UploadBackupAssetCandidate
        let primary: UploadResourceDescriptor
        let secondaries: [BackupSecondaryResource]
        let mediaType: String
        private let lock = NSLock()
        private var omitted = false
        private var reads = 0
        var resolveCount: Int { lock.withLock { reads } }
        func omitSecondary(_ value: Bool) { lock.withLock { omitted = value } }
        init(
            candidate: UploadBackupAssetCandidate, primary: UploadResourceDescriptor,
            secondaries: [BackupSecondaryResource], mediaType: String
        ) {
            self.candidate = candidate
            self.primary = primary
            self.secondaries = secondaries
            self.mediaType = mediaType
        }
        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            let omit = lock.withLock {
                reads += 1
                return omitted
            }
            return BackupResolvedResource(
                candidate: candidate, descriptor: primary, mediaType: mediaType,
                captureDate: primary.modificationDate, secondaries: omit ? [] : secondaries)
        }
    }

    #if DEBUG
        @MainActor private final class Restore829Fixture {
            enum Shape: Equatable { case photo, video, live, burst }
            let shape: Shape
            /// Adds the edit-replacement journal to the pipeline, as the account stack does.
            let replacesEdits: Bool
            var journal: EditReplacementJournalFileStore?
            let directory: URL
            let suite: String
            let defaults: UserDefaults
            let server = EditScenarioServer()
            let clock = BackupTestClock(
                start: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.up) + 2))
            var controller: PhotoLibraryBackupController!
            var pending: PendingBackupManifestStore!
            var identities: UploadIdentityManifestStore!
            var state: UploadBackupStateManifestStore!
            var catalog: PhotoLibraryCatalogManifestStore!
            var pipeline: UploadDedupePipeline!
            var runner: BackupSyncRunner!
            var resolver: Restore829Resolver!
            #if DEBUG
                var queue: UploadBackupSyncQueueManifestStore { controller.queueStoreForTesting! }
            #endif
            var key: PendingSourceKey { PendingSourceKey(resolver.candidate.snapshot.source) }

            init(shape: Shape, replacesEdits: Bool = false) throws {
                self.shape = shape
                self.replacesEdits = replacesEdits
                suite = "restore-829-\(UUID().uuidString)"
                defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try open()
            }

            private func open() throws {
                pending = try XCTUnwrap(
                    PendingBackupManifestStore(
                        url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
                identities = try XCTUnwrap(
                    UploadIdentityManifestStore(
                        url: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)))
                journal =
                    replacesEdits
                    ? try XCTUnwrap(EditReplacementJournalFileStore.shared(accountDataDirectory: directory)) : nil
                pipeline = UploadDedupePipeline(
                    store: identities, checker: server, replacementJournal: journal, now: { [clock] in clock.now })
                controller = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                    identityResolver: pipeline, uploader: server, pendingStore: pending, requiresPendingStore: true)
                state = try XCTUnwrap(
                    UploadBackupStateManifestStore(
                        url: directory.appendingPathComponent(PhotoLibraryBackupController.stateDatabaseFileName)))
                catalog = try XCTUnwrap(
                    PhotoLibraryCatalogManifestStore(
                        url: directory.appendingPathComponent(PhotoLibraryBackupController.catalogDatabaseFileName)))
                let date = Date(timeIntervalSince1970: 1_720_000_000)
                let mainRole: PhotoBackupAssetInfo.Resource.Role = shape == .video ? .originalVideo : .originalPhoto
                var resources: [PhotoBackupAssetInfo.Resource] = [
                    .init(
                        role: mainRole,
                        originalFilename: shape == .video ? "MAIN.MOV" : "MAIN.HEIC",
                        mimeType: shape == .video ? "video/quicktime" : "image/heic")
                ]
                if shape == .live {
                    resources.append(
                        .init(role: .pairedVideo, originalFilename: "PAIR.MOV", mimeType: "video/quicktime"))
                }
                if shape == .burst {
                    resources.append(.init(role: .burstMember, originalFilename: "MEMBER.HEIC", mimeType: "image/heic"))
                }
                let info = PhotoBackupAssetInfo(
                    localIdentifier: "restore-asset", creationDate: date, modificationDate: date,
                    pixelWidth: 10, pixelHeight: 10, durationSeconds: shape == .video || shape == .live ? 1 : 0,
                    isLivePhoto: shape == .live, isVideo: shape == .video, resources: resources)
                let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
                let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info))
                if try catalog.entry(for: info.localIdentifier) == nil {
                    XCTAssertTrue(
                        catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: clock.now)]))
                }
                func descriptor(_ item: PhotoBackupExportPlan.Item, primary: Bool) throws -> UploadResourceDescriptor {
                    let url = directory.appendingPathComponent(item.uploadFilename)
                    let bytes = Data("restore-829-\(item.uploadFilename)".utf8)
                    try bytes.write(to: url)
                    return UploadResourceDescriptor(
                        source: .init(
                            kind: .photoLibraryAsset, identifier: info.localIdentifier,
                            resource: primary ? .primary : item.sourceResource), fileURL: url,
                        filename: item.uploadFilename,
                        fileSize: Int64(bytes.count), modificationDate: date,
                        precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: url))
                }
                resolver = Restore829Resolver(
                    candidate: candidate, primary: try descriptor(plan.primary, primary: true),
                    secondaries: try plan.secondaries.map {
                        BackupSecondaryResource(
                            descriptor: try descriptor($0, primary: false), mediaType: $0.mimeType ?? "image/heic")
                    },
                    mediaType: plan.primary.mimeType ?? "image/heic")
                runner = BackupSyncRunner(
                    queue: queue, preflight: UploadBackupPreflightIndex(store: state, now: { [clock] in clock.now }),
                    resolver: resolver, identityResolver: pipeline, uploader: server,
                    tagAdder: SpyTagAdder(),
                    configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock,
                    events: controller.pendingRecorder, now: { [clock] in clock.now })
            }

            #if DEBUG
                func initialBackup(omittingSecondary: Bool = false) async throws -> PhotoUID {
                    resolver.omitSecondary(omittingSecondary)
                    let engine = UploadBackupSyncEngine(
                        preflight: UploadBackupPreflightIndex(store: state), queue: queue)
                    _ = try await engine.enqueueBatch([resolver.candidate])
                    await drain()
                    XCTAssertTrue(
                        try XCTUnwrap(
                            try queue.entry(
                                for: resolver.candidate.snapshot.source,
                                revision: resolver.candidate.snapshot.revision)
                        ).state.isTerminalSuccess, "Initial completion must come from the real runner")
                    let main = try XCTUnwrap(identities.record(for: resolver.candidate.snapshot.source)?.remoteLinkID)
                    resolver.omitSecondary(false)
                    return PhotoUID(volumeID: "vol", nodeID: main)
                }
            #endif

            func restoredState(
                _ main: PhotoUID, retainMemberTrash: Bool = false, marker: Bool = false
            ) throws -> PendingSourceState {
                let excluded = try XCTUnwrap(
                    pending.exclude(
                        [PendingExclusionRequest(key: key, presentation: nil, remote: main)], at: clock.now)?
                        .first)
                if marker { XCTAssertEqual(pending.beginRemoteOperation(.remoteTrash, for: [excluded]), [key]) }
                for link in server.links { server.personTrash(link.uid) }
                for link in server.links { server.personRestore(link.uid) }
                if !marker {
                    XCTAssertTrue(
                        pending.completeEffect(
                            .remoteTrash, for: key, generation: excluded.generation, remoteLinkID: main.nodeID,
                            at: clock.now))
                }
                XCTAssertTrue(
                    pending.completeEffect(.queueSync, for: key, generation: excluded.generation, at: clock.now))
                if retainMemberTrash {
                    for secondary in resolver.secondaries {
                        var row = try XCTUnwrap(identities.record(for: secondary.descriptor.source))
                        row.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
                        XCTAssertTrue(identities.upsert(row))
                    }
                }
                return try XCTUnwrap(
                    pending.includeRestoredInProton([key], confirmedRemotes: [main], at: clock.now)?.first)
            }

            func drain() async {
                clock.advance(by: 2)
                _ = await runner.runUntilDrained(mode: .eligibleOnly)
            }

            /// A crop of the main photo: a real content edit with new bytes, not a metadata change.
            func publishEditedMain() throws -> (UploadBackupAssetCandidate, Restore829Resolver) {
                var entry = try XCTUnwrap(catalog.entry(for: key.identifier))
                entry.modificationDate = try XCTUnwrap(entry.modificationDate).addingTimeInterval(1)
                entry.pixelWidth += 1
                XCTAssertTrue(catalog.upsertBatch([entry]))
                let latest = try XCTUnwrap(
                    PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry)))
                XCTAssertNotEqual(latest.snapshot.revision, resolver.candidate.snapshot.revision)
                let edited = Data("edited-restore-829-main".utf8)
                try edited.write(to: resolver.primary.fileURL)
                let primary = UploadResourceDescriptor(
                    source: resolver.primary.source, fileURL: resolver.primary.fileURL,
                    filename: resolver.primary.filename, fileSize: Int64(edited.count),
                    modificationDate: try XCTUnwrap(entry.modificationDate),
                    precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: resolver.primary.fileURL))
                let next = Restore829Resolver(
                    candidate: latest, primary: primary, secondaries: resolver.secondaries,
                    mediaType: resolver.mediaType)
                next.omitSecondary(true)
                return (latest, next)
            }

            /// An edit in Photos: a rendered full-size photo and adjustment data join the original. The render becomes the
            /// main photo and the original travels as a related file, so the replacement may trash the earlier upload.
            /// The burst member stays missing.
            func publishPhotosEdit() throws -> (UploadBackupAssetCandidate, Restore829Resolver) {
                let entry = try XCTUnwrap(catalog.entry(for: key.identifier))
                var info = PhotoLibraryCatalogMapper.info(for: entry)
                info.modificationDate = try XCTUnwrap(info.modificationDate).addingTimeInterval(1)
                info.resources += [
                    .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.HEIC", mimeType: "image/heic"),
                    .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: "application/xml"),
                ]
                XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: clock.now)]))
                let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
                let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: info))
                XCTAssertEqual(candidate.snapshot.editRevision, .unavailable, "Photos reports a real edit")
                func descriptor(_ item: PhotoBackupExportPlan.Item, primary: Bool) throws -> UploadResourceDescriptor {
                    let url = directory.appendingPathComponent(item.uploadFilename)
                    // The original keeps its bytes; the render and the adjustment data are new.
                    let bytes = Data(
                        (item.role == .originalPhoto ? "restore-829-MAIN.HEIC" : "edited-829-\(item.uploadFilename)")
                            .utf8)
                    try bytes.write(to: url)
                    return UploadResourceDescriptor(
                        source: .init(
                            kind: .photoLibraryAsset, identifier: info.localIdentifier,
                            resource: primary ? .primary : item.sourceResource), fileURL: url,
                        filename: item.uploadFilename, fileSize: Int64(bytes.count),
                        modificationDate: try XCTUnwrap(info.modificationDate),
                        precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: url))
                }
                let edited = Restore829Resolver(
                    candidate: candidate, primary: try descriptor(plan.primary, primary: true),
                    secondaries: try plan.secondaries.filter { $0.role != .burstMember }.map {
                        BackupSecondaryResource(
                            descriptor: try descriptor($0, primary: false), mediaType: $0.mimeType ?? "image/heic")
                    },
                    mediaType: plan.primary.mimeType ?? "image/heic")
                return (candidate, edited)
            }

            /// Drains with a runner that resolves through `resolver` on the same pipeline and uploader.
            func drain(with resolver: Restore829Resolver) async throws {
                let replacement = journal.map {
                    EditedPhotoReplacement(
                        remote: server, albums: server, relations: server, identities: identities, journal: $0)
                }
                let runner = BackupSyncRunner(
                    queue: queue, preflight: UploadBackupPreflightIndex(store: state, now: { [clock] in clock.now }),
                    resolver: resolver, identityResolver: pipeline, uploader: server, tagAdder: SpyTagAdder(),
                    editReplacement: replacement,
                    configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock,
                    events: controller.pendingRecorder, now: { [clock] in clock.now })
                clock.advance(by: 2)
                _ = await runner.runUntilDrained(mode: .eligibleOnly)
                await runner.stop()
            }

            func relaunch() async throws {
                await close()
                try open()
            }

            func close() async {
                await runner?.stop()
                await controller?.shutdown()
                state?.close()
                catalog?.close()
                identities?.close()
                pending?.close()
            }

            func cleanup() async {
                await close()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
        }
    #endif

    // MARK: - One pending row or one failed call never stops the backup (#982)

    /// Runs `sql` on the pending store through a second connection, as a newer build or a full disk leaves it.
    #if DEBUG
        private func executeOnPendingStore(_ f: Restore829Fixture, _ sql: String) throws {
            var handle: OpaquePointer?
            let url = f.directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
            XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            let db = try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
    #endif

    /// Every byte of the pending row of `identifier`.
    #if DEBUG
        private func rawPendingRow(_ f: Restore829Fixture, _ identifier: String) throws -> [Data?] {
            var handle: OpaquePointer?
            let url = f.directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
            XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            let db = try XCTUnwrap(handle)
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(db, "SELECT * FROM source_state WHERE source_id='\(identifier)';", -1, &stmt, nil),
                SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            return (0..<sqlite3_column_count(stmt)).map { column in
                guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
            }
        }
    #endif

    /// Queues the fixture photo through the engine that reads the exclusions of the pending store, and drains it.
    #if DEBUG
        private func backUpWithExclusions(_ f: Restore829Fixture) async throws -> UploadBackupSyncQueueEntry {
            let engine = UploadBackupSyncEngine(
                preflight: UploadBackupPreflightIndex(store: f.state), queue: f.queue, exclusions: f.pending)
            _ = try await engine.enqueueBatch([f.resolver.candidate])
            await f.drain()
            return try XCTUnwrap(
                try f.queue.entry(
                    for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
        }
    #endif

    /// A newer build wrote a value that this build does not know, into each of the three enum columns in turn. The
    /// read reports the row, the row stays unchanged, and every other photo keeps backing up.
    #if DEBUG
        func testAPendingRowThatCannotBeDecodedKeepsTheBackupOfOtherPhotos() async throws {
            for column in ["source_kind", "desired", "remote_op"] {
                try await withRestore829Fixture(.photo) { f in
                    XCTAssertTrue(f.controller.isAvailable)
                    let other = PendingSourceKey(kind: .photoLibraryAsset, identifier: "other-asset")
                    XCTAssertNotNil(
                        f.pending.exclude(
                            [PendingExclusionRequest(key: other, presentation: nil, remote: nil)], at: f.clock.now))
                    try self.executeOnPendingStore(
                        f, "UPDATE source_state SET \(column)='written-by-a-newer-build' WHERE source_id='other-asset';"
                    )
                    let before = try self.rawPendingRow(f, "other-asset")

                    XCTAssertFalse(f.pending.sourceStatesRead().complete, "the read reports the row (\(column))")
                    XCTAssertTrue(f.controller.isAvailable, "one row stops nothing (\(column))")
                    let entry = try await self.backUpWithExclusions(f)

                    XCTAssertTrue(entry.state.isTerminalSuccess, "the other photo backs up (\(column))")
                    XCTAssertTrue(f.controller.isAvailable)
                    XCTAssertEqual(
                        try self.rawPendingRow(f, "other-asset"), before, "the row stays unchanged (\(column))")
                }
            }
        }
    #endif

    /// Another connection holds the write lock of the pending store until the busy timeout ends, so the write of the
    /// upload's handoff fails, as on a busy or full disk. Once the lock is free, the backup goes on without a relaunch.
    #if DEBUG
        func testATransientPendingStoreFailureStopsTheBackupOnlyUntilTheStoreAnswersAgain() async throws {
            try await withRestore829Fixture(.photo) { f in
                var handle: OpaquePointer?
                let url = f.directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
                XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
                let blocker = try XCTUnwrap(handle)
                defer { sqlite3_close(blocker) }
                XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
                let stopped = try await self.backUpWithExclusions(f)
                XCTAssertFalse(stopped.state.isTerminalSuccess, "the upload could not be recorded")

                XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)

                XCTAssertTrue(f.controller.isAvailable, "the backup is available again without a relaunch")
                await f.drain()
                let entry = try XCTUnwrap(
                    try f.queue.entry(
                        for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
                XCTAssertTrue(entry.state.isTerminalSuccess, "the photo backs up")
            }
        }
    #endif

    #if DEBUG
        private func withRestore829Fixture(
            _ shape: Restore829Fixture.Shape, replacesEdits: Bool = false,
            _ body: @MainActor (Restore829Fixture) async throws -> Void
        ) async throws {
            let fixture = try Restore829Fixture(shape: shape, replacesEdits: replacesEdits)
            do { try await body(fixture) } catch {
                await fixture.cleanup()
                throw error
            }
            await fixture.cleanup()
        }
    #endif

    private enum Restore829StopFixtureError: Error {
        case invalid(String)
    }

    /// Every artificial wait ends independently. Expiry is invalid fixture evidence, never a kill.
    private actor Restore829StopGate {
        enum End: Sendable { case opened, expired, cleanup }
        private var end: End?
        private var waiters: [CheckedContinuation<End, Never>] = []
        private var expiry: Task<Void, Never>?

        func wait() async -> End {
            if let end { return end }
            if expiry == nil {
                expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.finish(.expired)
                }
            }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func finish(_ result: End = .opened) {
            guard end == nil else { return }
            end = result
            expiry?.cancel()
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(returning: result) }
        }

        func close() async {
            finish(.cleanup)
            let ownedExpiry = expiry
            expiry = nil
            await ownedExpiry?.value
        }
    }

    /// The first matching member never reaches the server. Later requests use the real server double.
    private final class Restore829StopUploader: PhotoUploading, @unchecked Sendable {
        let entered = Restore829StopGate()
        let nativeCancel = Restore829StopGate()
        let releaseUpload = Restore829StopGate()
        private let server: EditScenarioServer
        private let memberName: String
        private let lock = NSLock()
        private var request: PhotoUploadRequest?
        private var cancelled: [UUID] = []
        private var events: [String] = []
        private var uploadEnd: Restore829StopGate.End?

        var capabilities: UploadBackendCapabilities { server.capabilities }
        var heldRequest: PhotoUploadRequest? { lock.withLock { request } }
        var cancelledTokens: [UUID] { lock.withLock { cancelled } }
        var trace: [String] { lock.withLock { events } }
        var heldUploadEnd: Restore829StopGate.End? { lock.withLock { uploadEnd } }

        init(server: EditScenarioServer, memberName: String) {
            self.server = server
            self.memberName = memberName
        }

        func record(_ event: String) { lock.withLock { events.append(event) } }

        func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
            try await server.reserveNetwork(allowsExpensiveNetwork: allowsExpensiveNetwork)
        }

        func ensureRemoteCapacity(forBytes bytes: Int64, filename: String) async throws {
            try await server.ensureRemoteCapacity(forBytes: bytes, filename: filename)
        }

        func upload(
            _ request: PhotoUploadRequest,
            onProgress: @Sendable @escaping (UploadProgress) -> Void
        ) async throws -> PhotoUID {
            let hold = lock.withLock {
                guard self.request == nil, request.name == memberName else { return false }
                self.request = request
                events.append("upload-entered")
                return true
            }
            guard hold else { return try await server.upload(request, onProgress: onProgress) }
            await entered.finish()
            // Deliberately ignore task cancellation until the test or this gate's expiry releases us.
            let end = await releaseUpload.wait()
            lock.withLock {
                uploadEnd = end
                events.append("upload-ended")
            }
            guard case .opened = end else {
                throw Restore829StopFixtureError.invalid("held upload expired or entered cleanup")
            }
            throw CancellationError()
        }

        func cancel(token: UUID) async {
            lock.withLock {
                cancelled.append(token)
                events.append("native-cancel")
            }
            await nativeCancel.finish()
            await server.cancel(token: token)
            record("native-cancel-ended")
        }

        func close() async {
            // Release every waiter before joining any owned expiry task.
            await releaseUpload.finish(.cleanup)
            await entered.finish(.cleanup)
            await nativeCancel.finish(.cleanup)
            await releaseUpload.close()
            await entered.close()
            await nativeCancel.close()
        }
    }

    #if DEBUG
        func testStopDuringRestoredBurstMemberUploadRetainsTheExactRestoreDuty() async throws {
            try await withRestore829Fixture(.burst) { f in
                let main = try await f.initialBackup()
                let priorMember = try XCTUnwrap(f.resolver.secondaries.first)
                let priorMemberUID = try XCTUnwrap(
                    f.identities.record(for: priorMember.descriptor.source)?.remoteLinkID)
                var catalogEntry = try XCTUnwrap(f.catalog.entry(for: f.key.identifier))
                catalogEntry.modificationDate = try XCTUnwrap(catalogEntry.modificationDate).addingTimeInterval(1)
                XCTAssertTrue(f.catalog.upsertBatch([catalogEntry]))
                let latest = try XCTUnwrap(
                    PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: catalogEntry)))
                let updatedBytes = Data("updated-owned-burst-member".utf8)
                try updatedBytes.write(to: priorMember.descriptor.fileURL)
                let updatedMember = UploadResourceDescriptor(
                    source: priorMember.descriptor.source, fileURL: priorMember.descriptor.fileURL,
                    filename: priorMember.descriptor.filename, fileSize: Int64(updatedBytes.count),
                    modificationDate: try XCTUnwrap(catalogEntry.modificationDate),
                    precomputedSHA1Digest: try UploadContentSHA1.digest(ofFileAt: priorMember.descriptor.fileURL))
                f.resolver = Restore829Resolver(
                    candidate: latest, primary: f.resolver.primary,
                    secondaries: [.init(descriptor: updatedMember, mediaType: priorMember.mediaType)],
                    mediaType: f.resolver.mediaType)
                let checked = try f.restoredState(main, marker: true)
                guard !f.controller.isEnabled, f.server.uploadRequestCount == 2,
                    f.server.links.count == 2, f.server.links.first?.uid == main,
                    f.server.links.first?.state == .active, f.resolver.secondaries.count == 1,
                    checked.remote == main, checked.needsQueueSync, checked.remoteOperation == .remoteTrash,
                    let member = f.resolver.secondaries.first, member.descriptor.source.resource.isBurstMember,
                    f.identities.record(for: member.descriptor.source)?.remoteLinkID == priorMemberUID,
                    f.identities.record(for: member.descriptor.source)?.isValid(for: member.descriptor) == false,
                    f.server.links.first(where: { $0.linkID == priorMemberUID })?.state == .active
                else { throw Restore829StopFixtureError.invalid("initial backup/restore fixture") }
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key],
                    let admitted = try f.queue.entry(
                        for: f.resolver.candidate.snapshot.source,
                        revision: f.resolver.candidate.snapshot.revision),
                    !admitted.state.isTerminalSuccess, admitted.remoteCommitReconciliation == nil
                else { throw Restore829StopFixtureError.invalid("restore was not admitted for a real pass") }
                let uploader = Restore829StopUploader(
                    server: f.server,
                    memberName: ProtonPhotoNameCorrection.correctedName(for: member.descriptor.filename))
                let runner = BackupSyncRunner(
                    queue: f.queue,
                    preflight: UploadBackupPreflightIndex(store: f.state, now: { [clock = f.clock] in clock.now }),
                    resolver: f.resolver, identityResolver: f.pipeline, uploader: uploader,
                    tagAdder: SpyTagAdder(),
                    configuration: .init(throttle: .init(baseConcurrency: 1)), clock: f.clock,
                    events: f.controller.pendingRecorder, now: { [clock = f.clock] in clock.now })
                var drain: Task<BackupSyncProgress, Never>?
                var stop: Task<Void, Never>?
                @MainActor func cleanup() async {
                    // Never join a test task while its artificial upload gate remains held.
                    await uploader.close()
                    await runner.stop()
                    await stop?.value
                    _ = await drain?.value
                }
                do {
                    let resolutionsBefore = f.resolver.resolveCount
                    f.clock.advance(by: 2)
                    drain = Task {
                        let result = await runner.runUntilDrained(mode: .eligibleOnly)
                        uploader.record("drain-returned")
                        return result
                    }
                    guard case .opened = await uploader.entered.wait(),
                        let request = uploader.heldRequest, request.mainPhotoUID?.nodeID == main.nodeID,
                        request.expectedSHA1 == member.descriptor.precomputedSHA1Digest,
                        f.resolver.resolveCount > resolutionsBefore, f.queue.isOperational(),
                        f.pending.isOperational(), f.catalog.isOperational(),
                        f.identities.record(for: admitted.source)?.remoteLinkID == main.nodeID,
                        let active = try f.queue.entry(for: admitted.source, revision: admitted.revision),
                        active.state == .uploading, active.remoteCommitReconciliation == nil,
                        case .readable(let owed?) = f.pending.sourceStateRead(for: f.key),
                        owed.generation == checked.generation, owed.remote == main, owed.needsQueueSync,
                        owed.remoteOperation == .remoteTrash, f.server.uploadRequestCount == 2,
                        f.server.links.count == 2, f.server.links.first?.state == .active
                    else { throw Restore829StopFixtureError.invalid("real active member-upload prerequisite") }
                    stop = Task {
                        await runner.stop()
                        uploader.record("stop-returned")
                    }
                    guard case .opened = await uploader.nativeCancel.wait() else {
                        throw Restore829StopFixtureError.invalid("native cancellation gate expired")
                    }
                    guard uploader.cancelledTokens.first == request.cancellationToken else {
                        throw Restore829StopFixtureError.invalid("cancellation did not target the held upload")
                    }
                    await uploader.releaseUpload.finish()
                    await stop?.value
                    _ = await drain?.value
                    guard case .opened? = uploader.heldUploadEnd else {
                        throw Restore829StopFixtureError.invalid("held upload expired before explicit release")
                    }
                    XCTAssertFalse(Task.isCancelled, "Only the real runner Stop may cancel this pass")
                    XCTAssertEqual(uploader.cancelledTokens, [request.cancellationToken])
                    let trace = uploader.trace
                    let uploadEnded = trace.firstIndex(of: "upload-ended")
                    let nativeCancelEnded = trace.firstIndex(of: "native-cancel-ended")
                    let stopReturned = trace.firstIndex(of: "stop-returned")
                    XCTAssertTrue(
                        uploadEnded.map { end in stopReturned.map { end < $0 } ?? false } ?? false,
                        "Stop must join the actual upload before it returns")
                    XCTAssertTrue(
                        nativeCancelEnded.map { end in stopReturned.map { end < $0 } ?? false } ?? false,
                        "Stop must join native cancellation before it returns")
                    do {
                        try await runner.checkCancellation()
                        XCTFail("The stopped restore pass must retain its cancellation")
                    } catch { XCTAssertTrue(UploadError.isCancellation(error)) }
                    let row = try XCTUnwrap(f.queue.entry(for: admitted.source, revision: admitted.revision))
                    XCTAssertEqual(row.state, .queuedForUpload, "The interrupted compound stays runnable")
                    XCTAssertEqual(row.attempts, admitted.attempts)
                    XCTAssertNil(row.remoteCommitReconciliation)
                    XCTAssertTrue(f.queue.nextRunnableDate().map { $0 <= f.clock.now } ?? false)
                    guard f.queue.isOperational(), case .readable(let pending) = f.pending.sourceStateRead(for: f.key)
                    else {
                        throw Restore829StopFixtureError.invalid("post-Stop local state is unreadable")
                    }
                    let retained = try XCTUnwrap(pending, "Stop must retain the pending restore duty")
                    XCTAssertEqual(retained.remote, main)
                    XCTAssertEqual(retained.generation, checked.generation)
                    XCTAssertEqual(retained.attempts, checked.attempts)
                    XCTAssertTrue(retained.needsQueueSync)
                    XCTAssertEqual(retained.remoteOperation, .remoteTrash)
                    guard f.identities.record(for: admitted.source)?.remoteLinkID == main.nodeID else {
                        throw Restore829StopFixtureError.invalid("post-Stop identity read is unavailable")
                    }
                    let interruptedIdentity = try XCTUnwrap(f.identities.record(for: member.descriptor.source))
                    XCTAssertTrue(interruptedIdentity.isValid(for: member.descriptor))
                    XCTAssertNil(interruptedIdentity.remoteLinkID)
                    XCTAssertFalse(interruptedIdentity.provesUpload)
                    XCTAssertEqual(f.server.uploadRequestCount, 2)
                    XCTAssertEqual(f.server.links.count, 2)
                    XCTAssertEqual(f.server.links.first?.uid, main)
                    XCTAssertEqual(f.server.links.first?.state, .active)
                    let pendingOutcome = await f.controller.returnToBackup([checked])
                    guard case .waiting? = pendingOutcome[f.key] else {
                        XCTFail("Stop cannot acknowledge the unfinished compound")
                        await cleanup()
                        return
                    }
                    // The same uploader now forwards the member; no competing runner is started.
                    f.clock.advance(by: 2)
                    drain = Task { await runner.runUntilDrained(mode: .eligibleOnly) }
                    _ = await drain?.value
                    let completed = await f.controller.returnToBackup([checked])
                    XCTAssertEqual(completed[f.key], .completed)
                    XCTAssertEqual(f.server.uploadRequestCount, 3, "Only the updated member commits")
                    XCTAssertEqual(
                        f.server.links.filter { $0.mainLinkID == nil && $0.state == .active }.map(\.uid), [main])
                    let members = f.server.links.filter { $0.mainLinkID == main.nodeID && $0.state == .active }
                    XCTAssertEqual(members.count, 2)
                    XCTAssertEqual(members.first(where: { $0.linkID == priorMemberUID })?.state, .active)
                    let updated = try XCTUnwrap(members.first(where: { $0.linkID != priorMemberUID }))
                    XCTAssertEqual(f.identities.record(for: member.descriptor.source)?.remoteLinkID, updated.linkID)
                    XCTAssertEqual(uploader.cancelledTokens, [request.cancellationToken])
                    if completed[f.key] == .completed {
                        XCTAssertTrue(f.pending.finishRestoreRecheck(checked, outcome: .completed, at: f.clock.now))
                        XCTAssertNil(
                            f.pending.sourceState(for: f.key), "Only the later complete recheck retires the marker")
                    }
                } catch {
                    await cleanup()
                    throw error
                }
                await cleanup()
            }
        }
    #endif

    #if DEBUG
        func testRestoredPhotoVideoAndLiveWaitForRealCompoundDrainWithoutDuplicateUpload() async throws {
            for shape in [Restore829Fixture.Shape.photo, .video, .live] {
                try await withRestore829Fixture(shape) { f in
                    let main = try await f.initialBackup()
                    let checked = try f.restoredState(main, retainMemberTrash: shape == .live, marker: true)
                    let uploads = f.server.uploadRequestCount
                    let beforeReads = f.resolver.resolveCount
                    let admission = await f.controller.returnToBackup([checked])
                    guard case .waiting? = admission[f.key] else {
                        return XCTFail("Enqueue must not report compound completion")
                    }
                    XCTAssertTrue(try XCTUnwrap(f.pending.sourceState(for: f.key)).needsQueueSync)
                    XCTAssertEqual(f.pending.sourceState(for: f.key)?.remote, main)
                    XCTAssertEqual(
                        f.pending.sourceState(for: f.key)?.remoteOperation, .remoteTrash,
                        "The marker stays until the real recheck")
                    await f.drain()
                    XCTAssertGreaterThan(f.resolver.resolveCount, beforeReads)
                    let completed = await f.controller.returnToBackup([checked])
                    XCTAssertEqual(completed[f.key], .completed)
                    XCTAssertTrue(
                        f.pending.finishRestoreRecheck(
                            checked, outcome: try XCTUnwrap(completed[f.key]), at: f.clock.now))
                    XCTAssertNil(f.pending.sourceState(for: f.key), "Only this verified UID/generation marker retires")
                    XCTAssertEqual(f.server.uploadRequestCount, uploads)
                    XCTAssertEqual(f.server.links.filter { $0.state == .active }.count, shape == .live ? 2 : 1)
                    let reads = f.resolver.resolveCount
                    let repeatResult = await f.controller.returnToBackup([checked])
                    XCTAssertEqual(
                        repeatResult[f.key], .unreadable, "An acknowledged generation cannot readmit the stale request")
                    await f.drain()
                    XCTAssertEqual(f.resolver.resolveCount, reads)
                    XCTAssertEqual(f.server.uploadRequestCount, uploads)
                }
            }
        }
    #endif

    #if DEBUG
        func testRestoredBurstKeepsAnActuallyOmittedMemberPendingWithoutUpload() async throws {
            try await withRestore829Fixture(.burst) { f in
                let main = try await f.initialBackup(omittingSecondary: true)
                XCTAssertEqual(
                    f.server.uploadRequestCount, 1, "The initial resolved compound really omitted the member")
                let checked = try f.restoredState(main)
                let primary = f.identities.record(for: f.resolver.candidate.snapshot.source)
                let priorState = f.state.record(
                    for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision)
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key] else { return XCTFail("The omitted burst must remain pending") }
                await f.drain()
                let outcome = await f.controller.returnToBackup([checked])
                guard case .waiting? = outcome[f.key] else {
                    return XCTFail("A missing member cannot complete Restore")
                }
                XCTAssertTrue(
                    f.pending.finishRestoreRecheck(checked, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
                let retained = try XCTUnwrap(f.pending.sourceState(for: f.key))
                XCTAssertTrue(retained.needsQueueSync)
                XCTAssertEqual(retained.remote, main)
                XCTAssertEqual(retained.generation, checked.generation)
                XCTAssertEqual(retained.attempts, checked.attempts)
                XCTAssertEqual(f.server.uploadRequestCount, 1, "Restore cannot upload the missing member")
                let members = f.server.links.filter { $0.state == .active && $0.mainLinkID == main.nodeID }
                XCTAssertEqual(members.count, 0)
                XCTAssertNil(f.identities.record(for: try XCTUnwrap(f.resolver.secondaries.first).descriptor.source))
                XCTAssertEqual(f.identities.record(for: f.resolver.candidate.snapshot.source), primary)
                XCTAssertEqual(
                    f.state.record(
                        for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision),
                    priorState)
                XCTAssertEqual(
                    f.state.record(
                        for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision)?
                        .pendingResourceCount, 0)
            }
        }
    #endif

    #if DEBUG
        func testANewerEditUploadsWhileAnOlderRestoreWaits() async throws {
            for registersRestore in [true, false] {
                try await withRestore829Fixture(.burst) { f in
                    let main = try await f.initialBackup(omittingSecondary: true)
                    let checked = try f.restoredState(main)
                    // Control: the same state without a Restore check through the controller registers no context.
                    if registersRestore {
                        let admission = await f.controller.returnToBackup([checked])
                        guard case .waiting? = admission[f.key] else {
                            return XCTFail("The omitted burst must remain pending")
                        }
                        await f.drain()
                        let outcome = await f.controller.returnToBackup([checked])
                        guard case .waiting? = outcome[f.key] else { return XCTFail("Restore must still wait") }
                        XCTAssertTrue(
                            f.pending.finishRestoreRecheck(
                                checked, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
                    }
                    let uploadsBefore = f.server.uploadRequestCount
                    let (latest, resolver) = try f.publishEditedMain()
                    let engine = UploadBackupSyncEngine(
                        preflight: UploadBackupPreflightIndex(store: f.state), queue: f.queue)
                    _ = try await engine.enqueueBatch([latest])
                    try await f.drain(with: resolver)

                    let row = try f.queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision)
                    XCTAssertEqual(resolver.resolveCount, 1, "The edit really reached the duplicate check")
                    XCTAssertEqual(row?.state, .completed, "The newer edit backs up while the older Restore waits")
                    XCTAssertEqual(f.server.uploadRequestCount, uploadsBefore + 1, "Exactly the edited main uploads")
                    XCTAssertEqual(
                        f.identities.record(for: resolver.primary.source)?.sha1Hex,
                        UploadContentSHA1.hexString(digest: try XCTUnwrap(resolver.primary.precomputedSHA1Digest)))
                }
            }
        }
    #endif

    #if DEBUG
        func testAStaleRestoreCheckEndsItsContextOnTheNextPass() async throws {
            try await withRestore829Fixture(.burst) { f in
                let main = try await f.initialBackup(omittingSecondary: true)
                let checked = try f.restoredState(main)
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key] else { return XCTFail("The omitted burst must remain pending") }
                let primary = f.resolver.primary.withBackupRevision(f.resolver.candidate.snapshot.revision)
                var guarded = false
                do { _ = try await f.pipeline.resolve(primary) } catch {
                    guarded = UploadError.isCancellation(error)
                }
                XCTAssertFalse(guarded, "The current context admits its own revision")
                // A new decision replaces the generation that the registered context checked.
                let excluded = try XCTUnwrap(
                    f.pending.exclude(
                        [PendingExclusionRequest(key: f.key, presentation: nil, remote: main)], at: f.clock.now)?
                        .first)
                XCTAssertNotNil(f.pending.includeRestoredInProton([f.key], confirmedRemotes: [main], at: f.clock.now))
                XCTAssertNotEqual(excluded.generation, checked.generation)
                do { _ = try await f.pipeline.resolve(primary) } catch {
                    guarded = UploadError.isCancellation(error)
                }
                XCTAssertTrue(guarded, "A stale registered context still guards its own revision")

                let stale = await f.controller.returnToBackup([checked])
                XCTAssertEqual(stale[f.key], .unreadable, "The stale check reports nothing")
                guarded = false
                do { _ = try await f.pipeline.resolve(primary) } catch {
                    guarded = UploadError.isCancellation(error)
                }
                XCTAssertFalse(guarded, "The next pass ends the stale context")
            }
        }
    #endif

    /// Only a certified stale read ends a registered restore check; an unknown read keeps it (#1004 B2 row 13).
    #if DEBUG
        func testAnUnknownRestoreCheckReadKeepsTheRegisteredContext() async throws {
            try await withRestore829Fixture(.burst) { f in
                let main = try await f.initialBackup(omittingSecondary: true)
                let checked = try f.restoredState(main)
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key] else { return XCTFail("The omitted burst must remain pending") }
                let context = UploadRestoredCompoundContext(
                    source: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision,
                    generation: checked.generation, confirmedRemote: main,
                    requiredMembers: f.resolver.secondaries.map(\.descriptor.source.resource))
                guard case .waiting = try await f.pipeline.restoredPhotoOutcome(context) else {
                    return XCTFail("Fixture prerequisite: the context is registered")
                }

                let fault = try SQLiteReadInterrupt(
                    in: f.pending!, matching: "FROM source_state WHERE source_kind=? AND source_id=?")
                let unknown = await f.controller.returnToBackup([checked])
                fault.stop()

                XCTAssertTrue(fault.fired, "The current-state read of the check failed")
                XCTAssertEqual(unknown[f.key], .unreadable, "The unknown check reports nothing")
                guard case .waiting = try await f.pipeline.restoredPhotoOutcome(context) else {
                    return XCTFail("An unknown read must not end the registered context")
                }
            }
        }
    #endif

    /// An unknown catalog read in the restore check keeps the registered context too (#1004 B2 row 13).
    #if DEBUG
        func testAnUnknownRestoreCheckCatalogReadKeepsTheRegisteredContext() async throws {
            try await withRestore829Fixture(.burst) { f in
                let main = try await f.initialBackup(omittingSecondary: true)
                let checked = try f.restoredState(main)
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key] else { return XCTFail("The omitted burst must remain pending") }
                let context = UploadRestoredCompoundContext(
                    source: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision,
                    generation: checked.generation, confirmedRemote: main,
                    requiredMembers: f.resolver.secondaries.map(\.descriptor.source.resource))
                guard case .waiting = try await f.pipeline.restoredPhotoOutcome(context) else {
                    return XCTFail("Fixture prerequisite: the context is registered")
                }
                // The controller's own catalog connection. Its health check forgets the transient fault, so only the
                // failed read itself is unknown.
                let catalog = try XCTUnwrap(
                    Mirror(reflecting: f.controller!).children.first { $0.label == "catalogStore" }?.value
                        as? PhotoLibraryCatalogManifestStore)
                // The first keyed catalog read plans the check; the second is the current-state read.
                let fault = try SQLiteReadInterrupt(
                    in: catalog, matching: "FROM photo_catalog WHERE local_id=?", occurrence: 2)
                let unknown = await f.controller.returnToBackup([checked])
                fault.stop()

                XCTAssertTrue(fault.fired, "The current-state catalog read of the check failed")
                XCTAssertEqual(unknown[f.key], .unreadable, "The unknown check reports nothing")
                guard case .waiting = try await f.pipeline.restoredPhotoOutcome(context) else {
                    return XCTFail("An unknown catalog read must not end the registered context")
                }
            }
        }
    #endif

    #if DEBUG
        func testAStaleOlderCheckKeepsTheNewerRestoreContext() async throws {
            try await withRestore829Fixture(.burst) { f in
                let main = try await f.initialBackup(omittingSecondary: true)
                let older = try f.restoredState(main)
                let first = await f.controller.returnToBackup([older])
                guard case .waiting? = first[f.key] else { return XCTFail("The omitted burst must remain pending") }
                XCTAssertNotNil(
                    f.pending.exclude(
                        [PendingExclusionRequest(key: f.key, presentation: nil, remote: main)], at: f.clock.now))
                let newer = try XCTUnwrap(
                    f.pending.includeRestoredInProton([f.key], confirmedRemotes: [main], at: f.clock.now)?.first)
                XCTAssertNotEqual(newer.generation, older.generation)
                let second = await f.controller.returnToBackup([newer])
                guard case .waiting? = second[f.key] else { return XCTFail("The newer Restore must remain pending") }
                let context = UploadRestoredCompoundContext(
                    source: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision,
                    generation: newer.generation, confirmedRemote: main,
                    requiredMembers: f.resolver.secondaries.map(\.descriptor.source.resource))
                guard case .waiting = try await f.pipeline.restoredPhotoOutcome(context) else {
                    return XCTFail("Fixture prerequisite: the newer context is registered")
                }

                let stale = await f.controller.returnToBackup([older])
                XCTAssertEqual(stale[f.key], .unreadable, "The older check is stale")
                guard case .waiting = try await f.pipeline.restoredPhotoOutcome(context) else {
                    return XCTFail("A stale older check must not end the newer context")
                }
            }
        }
    #endif

    #if DEBUG
        func testRestoredLivePhotoKeepsATrashedPairedVideoPendingWithoutUpload() async throws {
            try await withRestore829Fixture(.live) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: true, marker: true)
                let paired = try XCTUnwrap(f.resolver.secondaries.first).descriptor.source
                let member = try XCTUnwrap(f.identities.record(for: paired)?.remoteLinkID)
                f.server.personTrash(.init(volumeID: "vol", nodeID: member))
                let uploads = f.server.uploadRequestCount
                let before = f.identities.record(for: paired)
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting? = admission[f.key] else { return XCTFail("A trashed paired video stays pending") }
                await f.drain()
                let outcome = await f.controller.returnToBackup([checked])
                guard case .waiting? = outcome[f.key] else {
                    return XCTFail("A skipped paired video is not a complete Restore")
                }
                XCTAssertTrue(
                    f.pending.finishRestoreRecheck(checked, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
                let retained = try XCTUnwrap(f.pending.sourceState(for: f.key))
                XCTAssertTrue(retained.needsQueueSync)
                XCTAssertEqual(retained.remote, main)
                XCTAssertEqual(retained.generation, checked.generation)
                XCTAssertEqual(retained.remoteOperation, .remoteTrash)
                XCTAssertEqual(retained.attempts, checked.attempts)
                XCTAssertEqual(f.identities.record(for: paired), before)
                XCTAssertEqual(f.server.uploadRequestCount, uploads)
                XCTAssertEqual(f.server.links.first { $0.linkID == member }?.state, .trashed)
                XCTAssertEqual(f.server.links.first { $0.linkID == main.nodeID }?.state, .active)
            }
        }
    #endif

    #if DEBUG
        func testRestoredCompoundReconstructsItsDutyAfterClosingAllAccountStores() async throws {
            try await withRestore829Fixture(.live) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: true, marker: true)
                let admission = await f.controller.returnToBackup([checked])
                guard case .waiting(let due)? = admission[f.key] else {
                    return XCTFail("The first return must stay pending")
                }
                XCTAssertTrue(f.pending.finishRestoreRecheck(checked, outcome: .waiting(until: due), at: f.clock.now))
                let durable = try XCTUnwrap(f.pending.sourceState(for: f.key))
                let uploads = f.server.uploadRequestCount
                await f.runner.stop()
                try await f.relaunch()
                XCTAssertEqual(f.pending.sourceState(for: f.key), durable)
                XCTAssertEqual(durable.remote, main)
                XCTAssertEqual(durable.attempts, checked.attempts)
                f.clock.advance(by: max(0, durable.nextAttemptAt.timeIntervalSince(f.clock.now)))
                let firstAfterRestart = await f.controller.returnToBackup([durable])
                guard case .waiting? = firstAfterRestart[f.key] else {
                    return XCTFail("New controller memory is not proof of a completed pass")
                }
                await f.drain()
                let outcome = await f.controller.returnToBackup([durable])
                XCTAssertEqual(outcome[f.key], .completed)
                XCTAssertTrue(
                    f.pending.finishRestoreRecheck(durable, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
                XCTAssertNil(f.pending.sourceState(for: f.key))
                XCTAssertEqual(f.server.uploadRequestCount, uploads)
                XCTAssertEqual(f.server.links.filter { $0.state == .active && $0.mainLinkID == main.nodeID }.count, 1)
            }
        }
    #endif

    #if DEBUG
        func testRestoredCompoundRefusesChangedGenerationAndUIDAndPlansTheLatestCatalogRevision() async throws {
            for change in ["generation=generation+1", "remote_link_id='newer-remote'"] {
                try await withRestore829Fixture(.live) { f in
                    let main = try await f.initialBackup()
                    let checked = try f.restoredState(main, retainMemberTrash: true)
                    var db: OpaquePointer?
                    XCTAssertEqual(
                        sqlite3_open(
                            f.directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName).path, &db),
                        SQLITE_OK)
                    let handle = try XCTUnwrap(db)
                    defer { sqlite3_close(handle) }
                    XCTAssertEqual(sqlite3_exec(handle, "UPDATE source_state SET \(change);", nil, nil, nil), SQLITE_OK)
                    let before = try XCTUnwrap(
                        try f.queue.entry(
                            for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision)
                    )
                    let outcome = await f.controller.returnToBackup([checked])
                    XCTAssertEqual(outcome[f.key], .unreadable)
                    XCTAssertEqual(try f.queue.entry(for: before.source, revision: before.revision), before)
                }
            }
            try await withRestore829Fixture(.photo) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main)
                var entry = try XCTUnwrap(f.catalog.entry(for: f.key.identifier))
                entry.modificationDate = try XCTUnwrap(entry.modificationDate).addingTimeInterval(1)
                XCTAssertTrue(f.catalog.upsertBatch([entry]))
                let before = try XCTUnwrap(
                    try f.queue.entry(
                        for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
                let outcome = await f.controller.returnToBackup([checked])
                guard case .waiting? = outcome[f.key] else {
                    return XCTFail("A later local revision owes a fresh recheck")
                }
                let latest = try XCTUnwrap(
                    PhotoBackupAssetPlanner.candidate(for: PhotoLibraryCatalogMapper.info(for: entry)))
                XCTAssertNotEqual(latest.snapshot.revision, before.revision)
                XCTAssertNotNil(try f.queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision))
                XCTAssertEqual(try f.queue.entry(for: before.source, revision: before.revision), before)
            }
        }
    #endif

    #if DEBUG
        func testRestoredCompoundDetectsALateAppliedTrashBeforeQueueMutation() async throws {
            try await withRestore829Fixture(.live) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: true)
                f.server.personTrash(main)
                let uploads = f.server.uploadRequestCount
                let before = try XCTUnwrap(
                    try f.queue.entry(
                        for: f.resolver.candidate.snapshot.source, revision: f.resolver.candidate.snapshot.revision))
                let outcome = await f.controller.returnToBackup([checked])
                XCTAssertEqual(outcome[f.key], .remoteTrashed)
                XCTAssertEqual(try f.queue.entry(for: before.source, revision: before.revision), before)
                XCTAssertTrue(
                    f.pending.finishRestoreRecheck(checked, outcome: try XCTUnwrap(outcome[f.key]), at: f.clock.now))
                let retained = try XCTUnwrap(f.pending.sourceState(for: f.key))
                XCTAssertTrue(retained.remoteTrashed)
                XCTAssertTrue(retained.needsRemoteRestore, "A trash that applies late still owes the real compensation")
                XCTAssertTrue(retained.needsQueueSync)
                XCTAssertEqual(retained.remote, main)
                XCTAssertEqual(f.server.uploadRequestCount, uploads)
            }
        }
    #endif

    #if DEBUG
        func testRestoredContextEndsOnShutdownAndDoesNotCrossAccountPipelines() async throws {
            try await withRestore829Fixture(.live) { f in
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: true)
                _ = await f.controller.returnToBackup([checked])
                let context = UploadRestoredCompoundContext(
                    source: f.resolver.candidate.snapshot.source,
                    revision: f.resolver.candidate.snapshot.revision, generation: checked.generation,
                    confirmedRemote: main,
                    requiredMembers: f.resolver.secondaries.map { $0.descriptor.source.resource })
                let active = try await f.pipeline.restoredPhotoOutcome(context)
                XCTAssertEqual(active, .completed)
                let other = UploadDedupePipeline(store: FakeIdentityStore(), checker: f.server)
                let foreign = try await other.restoredPhotoOutcome(context)
                XCTAssertEqual(foreign, .unreadable, "An account-local registration never crosses pipeline instances")
                await f.controller.shutdown()
                let ended = try await f.pipeline.restoredPhotoOutcome(context)
                XCTAssertEqual(ended, .unreadable)
                XCTAssertTrue(try XCTUnwrap(f.pending.sourceState(for: f.key)).needsQueueSync)
            }
        }
    #endif
}

extension PhotoLibraryBackupControllerStateTests {
    private struct Restore829ControllerEffects: PendingBackupEffects {
        let controller: PhotoLibraryBackupController
        let server: EditScenarioServer
        func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
            await controller.removeFromBackup(identifiers: identifiers)
        }
        func returnToBackup(_ keys: [PendingSourceKey]) async -> Set<PendingSourceKey> { [] }
        func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
            await controller.returnToBackup(states)
        }
        func photosVolumeID() async -> String? { "vol" }
        func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            do {
                try await server.trashDuplicates(uids)
                return .done
            } catch { return .init(retry: Set(uids)) }
        }
        func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
            do {
                try await server.restoreDuplicates(uids)
                return .done
            } catch { return .init(retry: Set(uids)) }
        }
        func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult { .permanentFailure }
        func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult { .permanentFailure }
    }

    #if DEBUG
        func testAnEditThatReplacesTheRestoredPhotoEndsRestoreWithoutCompensation() async throws {
            try await withRestore829Fixture(.burst, replacesEdits: true) { f in
                @MainActor func makeCoordinator() throws -> PendingBackupCoordinator {
                    PendingBackupCoordinator(
                        store: f.pending, queues: [.photoLibraryAsset: f.queue],
                        metadataProvider: try XCTUnwrap(f.controller.pendingMetadataProvider),
                        effects: Restore829ControllerEffects(controller: f.controller, server: f.server),
                        recorder: f.controller.pendingRecorder, replacementJournal: f.journal, relations: f.server,
                        now: { [clock = f.clock] in clock.now }
                    )
                }
                let restored = try await f.initialBackup(omittingSecondary: true)
                _ = try f.restoredState(restored)
                let coordinator = try makeCoordinator()
                do {
                    await coordinator.start()
                    let pending = await coordinator.restoreSources(ofRemote: [restored])
                    guard case .waiting? = pending.outcomes[f.key] else {
                        await coordinator.close()
                        return XCTFail("Fixture prerequisite: Restore waits for the missing burst member")
                    }
                    XCTAssertEqual(f.pending.sourceState(for: f.key)?.remote, restored)

                    let (latest, edited) = try f.publishPhotosEdit()
                    let engine = UploadBackupSyncEngine(
                        preflight: UploadBackupPreflightIndex(store: f.state), queue: f.queue)
                    _ = try await engine.enqueueBatch([latest])
                    try await f.drain(with: edited)
                    let row = try f.queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision)
                    let replacing = f.identities.record(for: edited.primary.source)?.remoteLinkID
                    let oldState = f.server.links.first { $0.uid.nodeID == restored.nodeID }?.state
                    let retired: [String] = f.journal?.entry(for: edited.primary.source).retired ?? []
                    guard row?.state.isTerminalSuccess == true, oldState == .trashed, retired == [restored.nodeID],
                        let replacing, replacing != restored.nodeID
                    else {
                        await coordinator.close()
                        return XCTFail(
                            "Fixture prerequisite: the edit uploads and the replacement trashes the old main")
                    }

                    let due = try XCTUnwrap(f.pending.sourceState(for: f.key))
                    f.clock.advance(by: max(0, due.nextAttemptAt.timeIntervalSince(f.clock.now)) + 1)
                    // An unrelated trigger runs a real reconcile pass, as a timer or another Restore would.
                    _ = await coordinator.restoreSources(ofRemote: [.init(volumeID: "vol", nodeID: "unrelated")])
                    let finalState = f.server.links.first { $0.uid.nodeID == restored.nodeID }?.state
                    XCTAssertEqual(finalState, .trashed, "The photo the edit replaced must stay in the Proton trash")
                    XCTAssertEqual(f.server.links.first { $0.linkID == replacing }?.state, .active)
                    XCTAssertNil(
                        f.pending.sourceState(for: f.key), "The edit ends the Restore duty of the replaced photo")
                    XCTAssertTrue(
                        f.server.steps.allSatisfy(\.violations.isEmpty), "\(f.server.steps.map(\.violations))")
                } catch {
                    await coordinator.close()
                    throw error
                }
                await coordinator.close()
            }
        }
    #endif

    #if DEBUG
        func testCoordinatorReconstructsAndAcknowledgesOnlyARealCompoundPassAfterRestart() async throws {
            try await withRestore829Fixture(.live) { f in
                @MainActor func makeCoordinator() throws -> PendingBackupCoordinator {
                    PendingBackupCoordinator(
                        store: f.pending, queues: [.photoLibraryAsset: f.queue],
                        metadataProvider: try XCTUnwrap(f.controller.pendingMetadataProvider),
                        effects: Restore829ControllerEffects(controller: f.controller, server: f.server),
                        recorder: f.controller.pendingRecorder, relations: f.server,
                        now: { [clock = f.clock] in clock.now }
                    )
                }
                let main = try await f.initialBackup()
                let checked = try f.restoredState(main, retainMemberTrash: true, marker: true)
                let uploads = f.server.uploadRequestCount
                var coordinator = try makeCoordinator()
                do {
                    await coordinator.start()
                    let pending = await coordinator.restoreSources(ofRemote: [main])
                    guard case .waiting? = pending.outcomes[f.key] else {
                        await coordinator.close()
                        return XCTFail("An enqueue is not an acknowledged compound pass")
                    }
                    let durable = try XCTUnwrap(f.pending.sourceState(for: f.key))
                    XCTAssertEqual(durable.remote, main)
                    XCTAssertEqual(durable.attempts, checked.attempts)
                    XCTAssertTrue(durable.needsQueueSync)
                    XCTAssertEqual(durable.remoteOperation, .remoteTrash)
                    await coordinator.close()
                    try await f.relaunch()
                    XCTAssertEqual(f.pending.sourceState(for: f.key), durable)
                    f.clock.advance(by: max(0, durable.nextAttemptAt.timeIntervalSince(f.clock.now)))
                    coordinator = try makeCoordinator()
                    await coordinator.start()
                    XCTAssertTrue(try XCTUnwrap(f.pending.sourceState(for: f.key)).needsQueueSync)
                    await f.drain()
                    let recheck = try XCTUnwrap(f.pending.sourceState(for: f.key))
                    f.clock.advance(by: max(0, recheck.nextAttemptAt.timeIntervalSince(f.clock.now)))
                    let completed = await coordinator.restoreSources(ofRemote: [main])
                    XCTAssertEqual(completed.outcomes[f.key], .completed)
                    XCTAssertNil(
                        f.pending.sourceState(for: f.key),
                        "Only a real, fresh, same-UID/generation recheck retires the marker")
                    XCTAssertEqual(f.server.uploadRequestCount, uploads)
                    XCTAssertEqual(
                        f.server.links.filter { $0.state == .active && $0.mainLinkID == main.nodeID }.count, 1)
                } catch {
                    await coordinator.close()
                    throw error
                }
                await coordinator.close()
            }
        }
    #endif
}

/// The lines of a recorded background log.
final class RecordedLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var values: [String] { lock.withLock { lines } }

    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

// MARK: - #1004 B2: the person's retry decides from the complete problem list

#if DEBUG
    extension PhotoLibraryBackupControllerStateTests {
        /// A retry whose problem list a failed read cut short reopens nothing, also after the failure is forgotten:
        /// the photos missing from the cut-short list would stay parked although the retry reported success.
        func testARetryWithACutShortProblemListReopensNothingAfterRecovery() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-retry-cut-short")
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let rows = (1...3).map { index in
                UploadBackupSyncQueueEntry(
                    source: .init(kind: .photoLibraryAsset, identifier: "permission-\(index)"),
                    revision: .init(rawValue: Int64(index)), originalFilename: "permission-\(index)", state: .failed,
                    attempts: 8,
                    lastError: BackupIssueRecord(kind: .permission, detail: "denied").persistedValue,
                    updatedAt: Date(timeIntervalSince1970: 1_720_000_000))
            }
            for row in rows { XCTAssertTrue(queue.upsert(row)) }
            XCTAssertTrue(fixture.controller.failedItems().offersUserRetry)
            let fault = try SQLiteReadInterrupt(
                in: queue, matching: "WHERE state IN ('failed', 'failedPermanent', 'sourceMissing', 'blockedByDraft')",
                afterRows: 2)
            await fixture.controller.retryUserResolvableWork()
            fault.stop()
            XCTAssertTrue(fault.fired)
            let observer = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: fixture.directory.appendingPathComponent(PhotoLibraryBackupController.queueDatabaseFileName)))
            defer { observer.close() }
            for row in rows {
                XCTAssertEqual(
                    try observer.entry(for: row.source, revision: row.revision), row,
                    "\(row.originalFilename): a cut-short list reopens no photo")
            }
            XCTAssertEqual(fixture.controller.lastMessage, L10n.string("backup.error_local_state_unavailable"))
            await fixture.controller.shutdown()
        }
    }
#endif

// MARK: - #1004 B2c: a removal for an exclusion is proven by the queue, not by a later health check

#if DEBUG
    extension PhotoLibraryBackupControllerStateTests {
        /// A removal that a transient failure undid keeps the exclusion's duty, so the retry removes the row. A later
        /// health check that passes again proves nothing about the removal.
        func testAFailedQueueRemovalKeepsTheExclusionOwed() async throws {
            let fixture = try makeControllerFixture(
                prefix: "backup-exclusion-removal", identityResolver: FakeIdentityResolver())
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let row = UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: "excluded"), revision: .init(rawValue: 1),
                originalFilename: "excluded", state: .failedPermanent, attempts: 8,
                lastError: BackupIssueRecord(kind: .permission, detail: "denied").persistedValue,
                updatedAt: Date(timeIntervalSince1970: 1_720_000_000))
            XCTAssertTrue(queue.upsert(row))

            let fault = try SQLiteReadInterrupt(
                in: queue, matching: "DELETE FROM backup_sync_queue WHERE source_kind=? AND source_id=?;")
            let removed = await fixture.controller.removeFromBackup(identifiers: ["excluded"])
            fault.stop()
            XCTAssertTrue(fault.fired)
            XCTAssertFalse(removed, "a removal that did not happen keeps its duty")
            XCTAssertEqual(try queue.entry(for: row.source, revision: row.revision), row, "the row stays")

            let retried = await fixture.controller.removeFromBackup(identifiers: ["excluded"])
            XCTAssertTrue(retried, "the retry removes the row once the database answers")
            XCTAssertNil(try queue.entry(for: row.source, revision: row.revision))
            await fixture.controller.shutdown()
        }

        /// A removal whose confirming read fails is not proven. The duty stays, and the retry finds the row gone.
        func testAnUnknownRemovalCheckKeepsTheExclusionOwed() async throws {
            let fixture = try makeControllerFixture(
                prefix: "backup-exclusion-check", identityResolver: FakeIdentityResolver())
            defer { fixture.cleanup() }
            let queue = try XCTUnwrap(fixture.controller.queueStoreForTesting)
            let row = UploadBackupSyncQueueEntry(
                source: .init(kind: .photoLibraryAsset, identifier: "excluded"), revision: .init(rawValue: 1),
                originalFilename: "excluded", state: .failedPermanent, attempts: 8,
                lastError: BackupIssueRecord(kind: .permission, detail: "denied").persistedValue,
                updatedAt: Date(timeIntervalSince1970: 1_720_000_000))
            XCTAssertTrue(queue.upsert(row))

            let fault = try SQLiteReadInterrupt(
                in: queue, matching: "SELECT source_kind, source_id, resource, revision_us, state, original_filename")
            let removed = await fixture.controller.removeFromBackup(identifiers: ["excluded"])
            fault.stop()
            XCTAssertTrue(fault.fired)
            XCTAssertFalse(removed, "a removal that no complete read confirms keeps its duty")
            XCTAssertNil(try queue.entry(for: row.source, revision: row.revision), "the removal itself ran")

            let retried = await fixture.controller.removeFromBackup(identifiers: ["excluded"])
            XCTAssertTrue(retried, "the retry confirms that the row is gone")
            await fixture.controller.shutdown()
        }
    }
#endif
