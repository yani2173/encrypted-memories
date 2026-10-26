import Foundation
import PhotosCore
import UploadCore
import UploadFeature
import XCTest

@testable import PhotoLibraryBackupAdapter

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
            queue.entry(for: try XCTUnwrap(unsupported.source), revision: try XCTUnwrap(unsupported.revision))?.state,
            .dismissedFailure)
        XCTAssertFalse(fixture.controller.failedItems().contains { $0.id == unsupported.id })
        XCTAssertEqual(queue.summary().resolved, 0, "dismissal is not a successful backup")
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
            let model = BackupProblemListModel()
            let clock = BackupTestClock()
            var unavailable = 0
            await fixture.controller.readProblemList(
                using: { [failedAgain] }, afterDecision: decision, expectingItems: { true }, clock: clock,
                { model.replaceItems($0) }, { unavailable += 1 })
            XCTAssertEqual(model.items, [failedAgain], "the re-read shows the photo that failed again")
            XCTAssertEqual(model.presentation(expectsItems: true), .list)
            XCTAssertEqual(clock.sleeps, [0.25])
            XCTAssertEqual(unavailable, 0)
            await fixture.controller.shutdown()
        }

        func testADecisionReadThatStaysEmptyWhileTheSummaryCountsItemsEndsUnavailable() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-unavailable")
            defer { fixture.cleanup() }
            let model = BackupProblemListModel()
            model.replaceItems([decisionItem("photo", issue: .deletedElsewhere)])
            let clock = BackupTestClock()
            await fixture.controller.readProblemList(
                using: { [] }, afterDecision: decisionItem("photo", issue: .deletedElsewhere),
                expectingItems: { true }, clock: clock, { model.replaceItems($0) }, { model.markUnavailable() })
            XCTAssertEqual(
                model.presentation(expectsItems: true), .unavailable, "never a spinner without a reader behind it")
            XCTAssertEqual(clock.sleeps, [0.25, 0.5, 1, 2, 4])
            await fixture.controller.shutdown()
        }

        func testADecisionReadKeepsAnUnresolvedDecisionAndRemovesAResolvedOne() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-filter")
            defer { fixture.cleanup() }
            let model = BackupProblemListModel()
            let decision = decisionItem("decision", issue: .deletedElsewhere)
            let waiting = decisionItem("waiting", issue: .network)
            await fixture.controller.readProblemList(
                using: { [decision, waiting] }, afterDecision: decision, expectingItems: { false },
                clock: BackupTestClock(), { model.replaceItems($0) }, {})
            XCTAssertEqual(model.items, [decision, waiting], "a decision that is still open stays")

            let reopened = decisionItem("decision", issue: .network)
            await fixture.controller.readProblemList(
                using: { [reopened, waiting] }, afterDecision: decision, expectingItems: { false },
                clock: BackupTestClock(), { model.replaceItems($0) }, {})
            XCTAssertEqual(model.items, [waiting], "the resolved decision leaves at once")

            // Reading without a decision filters nothing.
            await fixture.controller.readProblemList(
                using: { [reopened, waiting] }, expectingItems: { false }, clock: BackupTestClock(),
                { model.replaceItems($0) }, {})
            XCTAssertEqual(model.items, [reopened, waiting])
            await fixture.controller.shutdown()
        }

        func testADecisionReadOfAnEmptyQueueShowsNothingNeedsAttention() async throws {
            let fixture = try makeControllerFixture(prefix: "backup-problem-decision-empty")
            defer { fixture.cleanup() }
            let model = BackupProblemListModel()
            XCTAssertEqual(model.presentation(expectsItems: false), .loading)
            await fixture.controller.readProblemList(
                using: { [] }, afterDecision: decisionItem("photo", issue: .deletedElsewhere),
                expectingItems: { false }, clock: BackupTestClock(), { model.replaceItems($0) }, {})
            XCTAssertEqual(model.presentation(expectsItems: false), .empty)
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
        XCTAssertEqual(queue.entry(for: seen.source, revision: seen.revision)?.state, .uploading)
        XCTAssertTrue(
            queue.updateState(
                source: seen.source, revision: seen.revision, state: .failed, attempts: 8,
                lastError: seen.lastError, updatedAt: Date()))
        let current = try XCTUnwrap(queue.entry(for: seen.source, revision: seen.revision))
        XCTAssertTrue(queue.reopenForUserRetry(current, attempts: 0, updatedAt: Date()))
        XCTAssertEqual(queue.entry(for: seen.source, revision: seen.revision)?.state, .discovered)
        XCTAssertEqual(queue.entry(for: seen.source, revision: seen.revision)?.lastError, seen.lastError)
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
                "Das Backup kann auf diesem Gerät gerade nicht weitermachen. Bitte starte die App neu.")
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
            XCTAssertEqual(controller.status.notBackedUpCount, 1)
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

        func testManualRetryResumesWhenMobileDataAllowsTheExpensivePathWithoutTheIndexBackoff() async throws {
            try await assertManualRetryResumesAfterWiFiWait(
                networkDetermined: true, returnsDuringScan: false, enablesMobileData: true)
        }

        private func assertManualRetryResumesAfterWiFiWait(
            networkDetermined: Bool, returnsDuringScan: Bool, returnsInBackgroundWindow: Bool = false,
            enablesMobileData: Bool = false
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
            XCTAssertEqual(queue.summary().resolved, 0, "An expensive path uploads nothing with mobile data off")

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
                let windowRuns = PassCounter()
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = windowRuns.increment() }
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
            XCTAssertEqual(queue.summary().resolved, 0, "The offline pass performs no upload")

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
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
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
            await window.value
            XCTAssertEqual(windowEnds.count, 1, "the window ends exactly once")
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
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }
            XCTAssertEqual(windowEnds.count, 0)

            // The iOS expiration handler cancels the work of the window.
            window.cancel()

            let ended = await waitUntil(timeout: .seconds(2)) { windowEnds.count == 1 }
            XCTAssertTrue(ended, "an expired window ends at once")
            XCTAssertEqual(runs.count, 0)
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
                await controller.backgroundCatchUp(owner: .iOSBackgroundTask) { _ in _ = runs.increment() }
                _ = windowEnds.increment()
            }
            _ = await waitUntil { controller.deferredStartWaiterCountForTesting == 1 }

            runtime.update { $0.network = LibraryNetworkState(isReachable: true, isExpensive: false) }

            let ended = await waitUntil(timeout: .seconds(5)) { windowEnds.count == 1 && scans.count == 1 }
            XCTAssertTrue(ended)
            XCTAssertEqual(runs.count, 0, "the window cannot stop the explicit pass at its expiration")
            XCTAssertEqual(owners.values, [.manual])
            await window.value
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

        /// Holds the wait for the first network path until the test releases it, so the bounded wait ends on cue.
        private func holdFirstNetworkPathWait(of controller: PhotoLibraryBackupController) -> HeldBackupSleepClock {
            let clock = HeldBackupSleepClock(clock: BackupTestClock())
            controller.replaceFirstNetworkPathSleepForTesting { wait in
                let (seconds, attoseconds) = wait.components
                try? await clock.sleep(for: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
            }
            return clock
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
            firstNetworkPathWait: Duration = .seconds(10)
        ) throws -> ControllerFixture {
            let fixture = try makeControllerFixture(
                prefix: prefix, identityResolver: FakeIdentityResolver(), runtimeSignals: source,
                firstNetworkPathWait: firstNetworkPathWait)
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
        runtimeSignals: BackupRuntimeSignalSource = .apple, firstNetworkPathWait: Duration = .seconds(10)
    ) throws -> ControllerFixture {
        let suite = "\(prefix)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if enabled { defaults.set(true, forKey: "photoBackup.enabled.v1") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults,
                runtimeSignals: runtimeSignals,
                firstNetworkPathWait: firstNetworkPathWait
            ),
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
                isNetworkDetermined: networkDetermined)
        }
    }
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
