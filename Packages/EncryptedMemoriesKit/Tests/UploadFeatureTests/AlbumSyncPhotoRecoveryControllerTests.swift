import AlbumSyncCore
import Foundation
import Observation
import Photos
import PhotosCore
import UploadCore
import XCTest

@testable import PhotoLibraryBackupAdapter

@MainActor
final class AlbumSyncPhotoRecoveryControllerTests: XCTestCase {
    func testRestoreBeyondSavedProblemLimitUsesFinishedSessionMembership() async throws {
        try await withFixture { fixture in
            let preceding = (0..<249).map { index in
                BackupFailedItem(
                    id: "earlier-\(index)", filename: "earlier-\(index).heic",
                    reason: "Reason", isPermanent: false, issue: .network)
            }
            fixture.controller.recordFinishedRun(
                preceding + fixture.report.problems,
                albumID: "local-album", recoveryContext: fixture.remote.context)
            XCTAssertEqual(
                fixture.controller.selectedAlbums.first?.problems.count, 200,
                "The saved last-run cache keeps its existing limit")
            XCTAssertEqual(fixture.controller.problemListItems(albumID: "local-album").count, 250)
            XCTAssertTrue(fixture.controller.canRestorePhotos(albumID: "local-album"))
            let uploads = fixture.device.server.uploadRequestCount
            let result = try await fixture.restore()
            XCTAssertEqual(result, .restored, "The photo at row 250 remains recoverable")
            XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
        }
    }

    func testFinishedSessionMembershipSurvivesStopOfLaterRun() async throws {
        try await withFixture { fixture in
            let preceding = (0..<249).map { index in
                BackupFailedItem(
                    id: "earlier-\(index)", filename: "earlier-\(index).heic",
                    reason: "Reason", isPermanent: false, issue: .network)
            }
            fixture.controller.recordFinishedRun(
                preceding + fixture.report.problems,
                albumID: "local-album", recoveryContext: fixture.remote.context)
            let finishedID = fixture.controller.problemListID(albumID: "local-album")
            fixture.controller.stopSync()
            XCTAssertEqual(fixture.controller.problemListID(albumID: "local-album"), finishedID)
            let result = try await fixture.restore()
            XCTAssertEqual(
                result, .restored,
                "Stopping later work must not discard the earlier finished problem set")
        }
    }

    func testCompleteDisplayDoesNotRequireRecoveryContext() async throws {
        try await withFixture { fixture in
            let items = (0..<1_000).map { index in
                BackupFailedItem(
                    id: "unavailable-\(index)", filename: "photo-\(index).heic",
                    reason: "Reason", isPermanent: false, issue: .network)
            }
            fixture.controller.recordFinishedRun(items, albumID: "local-album")
            XCTAssertEqual(fixture.controller.problemListItems(albumID: "local-album"), items)
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems.count, 200)
            XCTAssertFalse(fixture.controller.canRestorePhotos(albumID: "local-album"))
        }
    }

    func testRemovedAndShutDownSessionsRejectLateFinishedLists() async throws {
        try await withFixture { fixture in
            fixture.controller.removeFromSelection("local-album")
            fixture.controller.recordFinishedRun(
                fixture.report.problems,
                albumID: "local-album", recoveryContext: fixture.remote.context)
            XCTAssertNil(fixture.controller.problemListID(albumID: "local-album"))
            XCTAssertTrue(fixture.controller.problemListItems(albumID: "local-album").isEmpty)
            XCTAssertFalse(fixture.controller.canRestorePhotos(albumID: "local-album"))
        }
        try await withFixture { fixture in
            await fixture.controller.shutdown()
            fixture.controller.recordFinishedRun(
                fixture.report.problems,
                albumID: "local-album", recoveryContext: fixture.remote.context)
            XCTAssertNil(fixture.controller.problemListID(albumID: "local-album"))
            XCTAssertFalse(fixture.controller.canRestorePhotos(albumID: "local-album"))
        }
    }

    func testExplicitRestoreUsesTheControllerAndLeavesSettlementToNextSync() async throws {
        try await withFixture { fixture in
            let before = fixture.device.server.uploadRequestCount
            let journal = fixture.device.journal.entry(for: fixture.problem.source!)
            let result = try await fixture.restore()
            XCTAssertEqual(result, .restored)
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, fixture.report.problems)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, before)
            XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .active)
            let related = fixture.device.server.links.filter { $0.mainLinkID == fixture.original.nodeID }
            XCTAssertEqual(related.count, 1)
            XCTAssertTrue(related.allSatisfy { $0.state == .active })
            let restored = try await fixture.device.syncAlbum(["asset-1"], backup: fixture.backup)
            XCTAssertTrue(restored.isFullySynced)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, before)
            XCTAssertTrue(restored.problems.isEmpty)
        }
    }

    func testProblemListRestoreRunsNormalSyncAndAttachesWithoutUpload() async throws {
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let uploads = fixture.device.server.uploadRequestCount
                let source = try XCTUnwrap(fixture.problem.source)
                let journal = fixture.device.journal.entry(for: source)

                await fixture.controller.restorePhotoFromProblemList(fixture.problem, albumID: "local-album")
                await waitForSync(fixture.controller)

                XCTAssertEqual(probe.ensureBackedUpCalls, 1, "Restore must run the normal album sync once")
                let row = try XCTUnwrap(fixture.controller.selectedAlbums.first { $0.id == "local-album" })
                XCTAssertTrue(row.problems.isEmpty)
                XCTAssertFalse(row.hasNeedsAttention)
                let members = try await fixture.device.server.childMainLinkIDs(albumID: "own-album")
                XCTAssertEqual(members, [fixture.original.nodeID], "The same existing copy enters the album")
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.device.journal.entry(for: source), journal)
                XCTAssertNil(fixture.controller.lastMessage)
            })
    }

    func testProblemListUnknownRemoteKeepsTheRowAndReportsRestoreFailure() async throws {
        try await assertProblemListRestoreUnavailable(permanentlyMissing: false)
    }

    func testDeepRestoreFailureUsesTheFixedActionMessageWithoutChangingPhotoRows() async throws {
        try await withFixture { fixture in
            let preceding = (0..<249).map { index in
                BackupFailedItem(
                    id: "earlier-\(index)", filename: "earlier-\(index).heic",
                    reason: "Reason", isPermanent: false, issue: .network)
            }
            fixture.controller.recordFinishedRun(
                preceding + fixture.report.problems,
                albumID: "local-album", recoveryContext: fixture.remote.context)
            let session = fixture.controller.makeProblemListSession(albumID: "local-album")
            session.requestRefresh()
            await session.waitUntilIdle()
            XCTAssertTrue(session.requestNextPage())
            await session.waitUntilIdle()
            XCTAssertEqual(session.rows.count, 250)
            let before = session.rows
            let uploads = fixture.device.server.uploadRequestCount
            let messageChanged = XCTestExpectation(description: "Fixed action area observes restore failure")
            withObservationTracking {
                XCTAssertNil(session.fixedActionMessage)
            } onChange: {
                messageChanged.fulfill()
            }
            fixture.device.server.personEmptyTrash()
            await fixture.controller.restorePhotoFromProblemList(fixture.problem, albumID: "local-album")
            XCTAssertEqual(fixture.controller.lastMessage, L10n.string("albumsync.error_restore_photo"))
            await fulfillment(of: [messageChanged], timeout: 1)
            XCTAssertEqual(
                session.fixedActionMessage, L10n.string("albumsync.error_restore_photo"),
                "The real session must expose the error outside its scrolling photo rows")
            XCTAssertEqual(session.rows, before)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
            await session.shutdown()
            XCTAssertNil(session.fixedActionMessage)
        }
    }

    func testProblemListPermanentlyMissingRemoteKeepsTheRowAndReportsRestoreFailure() async throws {
        try await assertProblemListRestoreUnavailable(permanentlyMissing: true)
    }

    func testStoppingProblemListRestoreKeepsTheRowWithoutSyncOrAnError() async throws {
        let gate = RecoveryGate()
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            onEvidence: { await gate.wait() },
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let before = fixture.controller.selectedAlbums.first?.problems
                let uploads = fixture.device.server.uploadRequestCount
                let task = Task {
                    await fixture.controller.restorePhotoFromProblemList(fixture.problem, albumID: "local-album")
                }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.stopSync()
                await fulfillment(of: [gate.cancelled], timeout: 5)
                await gate.release()
                await task.value

                XCTAssertEqual(probe.ensureBackedUpCalls, 0)
                XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, before)
                XCTAssertNil(fixture.controller.lastMessage)
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                assertTrashed(fixture)
            })
    }

    private func assertProblemListRestoreUnavailable(permanentlyMissing: Bool) async throws {
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let before = fixture.controller.selectedAlbums.first?.problems
                let uploads = fixture.device.server.uploadRequestCount
                let source = try XCTUnwrap(fixture.problem.source)
                let journal = fixture.device.journal.entry(for: source)
                if permanentlyMissing {
                    fixture.device.server.personEmptyTrash()
                } else {
                    fixture.device.server.omitVisibility(of: [fixture.original.nodeID])
                }
                let restores = fixture.device.server.steps.filter { $0.action.hasPrefix("person restore ") }.count

                await fixture.controller.restorePhotoFromProblemList(fixture.problem, albumID: "local-album")
                await waitForSync(fixture.controller)

                XCTAssertEqual(probe.ensureBackedUpCalls, 0, "A refused restore must not start backup or album sync")
                XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, before)
                XCTAssertEqual(fixture.controller.lastMessage, L10n.string("albumsync.error_restore_photo"))
                XCTAssertEqual(fixture.controller.lastMessageStyle, .error)
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.device.journal.entry(for: source), journal)
                XCTAssertEqual(
                    fixture.device.server.steps.filter { $0.action.hasPrefix("person restore ") }.count, restores)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state,
                    permanentlyMissing ? .deleted : .trashed)
            })
    }

    func testStopCancelsHeldEvidenceAndRejectsRepeatedActionUntilItEnds() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                let repeatedFinished = XCTestExpectation(description: "Repeated action refused")
                let repeated = Task {
                    do {
                        _ = try await fixture.restore()
                        XCTFail("A second action must not start")
                    } catch {
                        XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                    }
                    repeatedFinished.fulfill()
                }
                await fulfillment(of: [repeatedFinished], timeout: 5)
                fixture.controller.stopSync()
                XCTAssertTrue(gate.wasCancelled, "Stop must cancel the owned task")
                await fulfillment(of: [gate.cancelled], timeout: 5)
                let stoppedFinished = XCTestExpectation(description: "Stopped action refused")
                let stopped = Task {
                    do {
                        _ = try await fixture.restore()
                        XCTFail("Stop must keep ownership until the lookup ends")
                    } catch {
                        XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                    }
                    stoppedFinished.fulfill()
                }
                await fulfillment(of: [stoppedFinished], timeout: 5)
                await gate.release()
                await repeated.value
                await stopped.value
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testSourceChangeDuringEvidenceRejectsTheOldVersion() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.device.library.changeModificationDate()
                await gate.release()
                do {
                    _ = try await task.value
                    XCTFail("Changed source must not restore")
                } catch {
                    XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                }
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testNewProblemGenerationCancelsAnOldActionEvenForTheSameRows() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.recordFinishedRun(
                    fixture.report.problems, albumID: "local-album",
                    recoveryContext: fixture.remote.context)
                await gate.release()
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testDeselectCancelsAnOldAction() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.removeFromSelection("local-album")
                await gate.release()
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testShutdownCancelsHeldEvidenceAndRetainsOwnership() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    let finished = await gate.finished
                    XCTAssertTrue(finished, "The released evidence has finished at this observation")
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                XCTAssertTrue(gate.wasCancelled, "Shutdown must cancel the owned task")
                await gate.release()
                await shutdown.value
                await assertCancelled(task)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
            })
    }

    func testResponseLossDoesNotSettleAndRetryReadsFreshActiveState() async throws {
        try await withFixture { fixture in
            fixture.device.server.applyNextRestoreThenFail()
            do {
                _ = try await fixture.restore()
                XCTFail("Response loss must remain an error")
            } catch {}
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, fixture.report.problems)
            let before = fixture.device.server.uploadRequestCount
            let result = try await fixture.restore()
            XCTAssertEqual(result, .alreadyActive)
            XCTAssertEqual(fixture.device.server.uploadRequestCount, before)
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, fixture.report.problems)
        }
    }

    func testCachedProblemWithoutThisSessionContextCannotRestore() async throws {
        try await withFixture { fixture in
            fixture.controller.recordFinishedRun(fixture.report.problems, albumID: "local-album")
            do {
                _ = try await fixture.restore()
                XCTFail("Cached presentation is not authority")
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    func testStopDuringProblemContextReadDoesNotStartSync() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.stopSync()
                XCTAssertTrue(gate.wasCancelled, "Stop must cancel the owned task")
                await fulfillment(of: [gate.cancelled], timeout: 5)
                await gate.release()
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while fixture.controller.isSyncing, ContinuousClock.now < deadline { await Task.yield() }
                XCTAssertFalse(fixture.controller.isSyncing)
                XCTAssertEqual(source.reads, 0, "Stop must fence the new context await before the runner starts")
                XCTAssertEqual(fixture.controller.lastMessageStyle, .information)
                XCTAssertEqual(fixture.controller.lastMessage, L10n.string("albumsync.error_stopped"))
            })
    }

    func testContextReadCancellationDoesNotStartSync() async throws {
        let errors: [any Error] = [
            CancellationError(), UploadError.cancelled,
            URLError(.cancelled), UploadError.transport(code: -999, message: "Cancelled"),
        ]
        for error in errors {
            let source = RecoveryCountingSource()
            try await withFixture(
                onContext: { throw error }, localSource: source,
                body: { fixture in
                    fixture.controller.syncNow(albumID: "local-album")
                    await waitForSync(fixture.controller)
                    XCTAssertEqual(source.reads, 0, "Context cancellation must not become optional evidence")
                })
        }
    }

    func testOrdinaryContextReadFailureFinishesSyncAndClearsRestoreAuthority() async throws {
        let source = RecoveryBatchSource()
        source.includeAsset()
        let contextReads = RecoveryContextReads()
        try await withFixture(
            onContext: { try await contextReads.failFirstRead() }, localSource: source,
            seedPreviousProblem: true,
            configure: { configuration, device in
                configuration.backupExecutorOverride = EditScenarioAlbumBackup(device: device)
            },
            body: { fixture in
                let uploads = fixture.device.server.uploadRequestCount
                let journal = fixture.device.journal.entry(for: fixture.problem.source!)
                fixture.controller.syncNow(albumID: "local-album")
                let item = try await finishedDeletionProblem(fixture)
                XCTAssertNil(fixture.controller.lastMessage, "An ordinary context error must not stop normal sync")
                let reads = await contextReads.count
                XCTAssertEqual(reads, 1, "The completed run must attempt its context read")
                guard await assertUnavailable(fixture, item: item) else { return }
                let readsAfterRefusal = await contextReads.count
                XCTAssertEqual(readsAfterRefusal, reads, "Missing context must refuse before a fresh remote read")
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)

                try await assertFreshSyncRestores(fixture)
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)
            })
    }

    func testPickerRemovalAndReselectionCannotReuseAnInFlightContext() async throws {
        try await checkRemovalDuringCompletingSync(usePicker: true)
    }

    func testRowRemovalAndReselectionCannotReuseAnInFlightContext() async throws {
        try await checkRemovalDuringCompletingSync(usePicker: false)
    }

    private func checkRemovalDuringCompletingSync(usePicker: Bool) async throws {
        for reselectBeforeCompletion in [true, false] {
            let gate = RecoveryGate()
            let source = RecoveryBatchSource(onFirstRead: { await gate.wait() })
            source.includeAsset()
            try await withFixture(
                localSource: source, automaticBatch: true, seedPreviousProblem: true,
                configure: { configuration, device in
                    configuration.backupExecutorOverride = EditScenarioAlbumBackup(device: device)
                },
                body: { fixture in
                    await fulfillment(of: [gate.entered], timeout: 5)
                    let selection = fixture.controller.selectedAlbumIDs
                    let uploads = fixture.device.server.uploadRequestCount
                    let journal = fixture.device.journal.entry(for: fixture.problem.source!)
                    if usePicker {
                        fixture.controller.applySelection(selection.subtracting(["local-album"]))
                    } else {
                        fixture.controller.removeFromSelection("local-album")
                    }
                    XCTAssertFalse(fixture.controller.selectedAlbumIDs.contains("local-album"))
                    if reselectBeforeCompletion { fixture.controller.applySelection(selection) }
                    await gate.release()
                    await waitForSync(fixture.controller)
                    if !reselectBeforeCompletion { fixture.controller.applySelection(selection) }
                    XCTAssertEqual(fixture.controller.selectedAlbumIDs, selection)
                    let item = try await finishedDeletionProblem(fixture)
                    XCTAssertNil(fixture.controller.lastMessage, "Removal must not interrupt the running sync")
                    guard await assertUnavailable(fixture, item: item) else { return }
                    XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                    XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)

                    try await assertFreshSyncRestores(fixture)
                    XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                    XCTAssertEqual(fixture.device.journal.entry(for: fixture.problem.source!), journal)
                })
        }
    }

    func testShutdownCancelsHeldProblemContextReadAndKeepsTheBatchOwned() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    XCTAssertFalse(
                        fixture.controller.isSyncing, "Shutdown must wait for the active sync task to finish")
                    let finished = await gate.finished
                    XCTAssertTrue(finished, "The released context read has finished at this observation")
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                XCTAssertTrue(fixture.controller.isSyncing, "The batch owns the context read until it returns")
                await gate.release()
                await shutdown.value
                XCTAssertEqual(source.reads, 0)
                XCTAssertNil(
                    fixture.controller.lastMessage,
                    "Shutdown must not turn a late context return into an error")
            })
    }

    func testShutdownWaitsForTheActiveSyncTaskBeforeReturning() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                XCTAssertTrue(fixture.controller.isSyncing)
                let done = RecoveryCompletion()
                let shutdown = Task {
                    await fixture.controller.shutdown()
                    done.mark()
                }
                await fulfillment(of: [gate.cancelled], timeout: 5)
                // The runner stop and the executor stop have both returned, so shutdown waits at
                // the active sync join. Until the held context read returns, the batch is running.
                await fulfillment(of: [probe.executorStopped], timeout: 5)
                XCTAssertTrue(fixture.controller.isSyncing, "The batch still owns the context read at the join")
                // Until the held context read returns, the active sync task is still running, so
                // shutdown must not have returned yet. Short negative window in the style of
                // MLSmartSearchLifecycleTests' shutdown-waits test.
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertFalse(done.isDone, "Shutdown must wait for the active sync task to finish")
                await gate.release()
                await shutdown.value
                XCTAssertTrue(done.isDone)
                XCTAssertFalse(fixture.controller.isSyncing, "Shutdown returned after the sync task finished")
                let finished = await gate.finished
                XCTAssertTrue(finished, "The released context read finished before shutdown returned")
                XCTAssertEqual(source.reads, 0)
                XCTAssertEqual(probe.stopCalls, 2)
                XCTAssertEqual(probe.ensureBackedUpCalls, 0)
            })
    }

    func testSyncNowCannotStartABatchWhileShutdownIsRunning() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        let probe = RecoveryShutdownProbeBackup(holdsFirstStop: true)
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                let shutdown = Task { await fixture.controller.shutdown() }
                // The held executor stop parks shutdown after it cleared the queue and cancelled
                // the active batch, with the batch winding down.
                await fulfillment(of: [probe.firstStopEntered], timeout: 5)
                await gate.release()
                await waitForSync(fixture.controller)
                XCTAssertFalse(fixture.controller.isSyncing)
                fixture.controller.syncNow(albumID: "local-album")
                XCTAssertFalse(
                    fixture.controller.isSyncing, "syncNow must not start a new batch during shutdown")
                XCTAssertEqual(probe.ensureBackedUpCalls, 0)
                XCTAssertEqual(source.reads, 0)
                probe.releaseFirstStop()
                await shutdown.value
                XCTAssertEqual(probe.stopCalls, 2)
                XCTAssertFalse(fixture.controller.isSyncing)
            })
    }

    func testNonDeletionProblemCannotAuthorizeRestore() async throws {
        try await withFixture { fixture in
            let item = BackupFailedItem(
                id: fixture.problem.id, filename: fixture.problem.filename, reason: "Unknown",
                isPermanent: false, issue: .unknown, source: fixture.problem.source,
                revision: fixture.problem.revision)
            fixture.controller.recordFinishedRun(
                [item], albumID: "local-album", recoveryContext: fixture.remote.context)
            do {
                _ = try await fixture.controller.restorePhoto(item, albumID: "local-album")
                XCTFail("Only a current deletion problem can authorize Restore")
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    func testChangedProblemCannotAuthorizeRestore() async throws {
        try await withFixture { fixture in
            let item = BackupFailedItem(
                id: fixture.problem.id, filename: fixture.problem.filename, reason: "Changed",
                isPermanent: false, issue: .remoteDeletion, source: fixture.problem.source,
                revision: fixture.problem.revision)
            do {
                _ = try await fixture.controller.restorePhoto(item, albumID: "local-album")
                XCTFail("An old problem must not authorize Restore")
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
            XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
        }
    }

    func testAddingSelectionDuringContextReadKeepsTheRunningBatch() async throws {
        try await checkSelectionDuringContextRead(remove: false)
    }

    func testRemovingSelectionDuringContextReadKeepsTheOtherAlbums() async throws {
        try await checkSelectionDuringContextRead(remove: true)
    }

    private func checkSelectionDuringContextRead(remove: Bool, cancellationAware: Bool = false) async throws {
        let gate = RecoveryGate()
        let source = RecoveryBatchSource()
        try await withFixture(
            onContext: {
                await gate.wait()
                if cancellationAware { try Task.checkCancellation() }
            }, localSource: source, automaticBatch: true,
            body: { fixture in
                await fulfillment(of: [gate.entered], timeout: 5)
                if remove {
                    fixture.controller.removeFromSelection("removed-album")
                } else {
                    fixture.controller.applySelection(["local-album", "next-album", "removed-album", "added-album"])
                    XCTAssertTrue(fixture.controller.selectedAlbumIDs.contains("added-album"))
                }
                XCTAssertFalse(gate.wasCancelled, "Selection changes must not cancel a sync context read")
                await gate.release()
                await waitForSync(fixture.controller)
                XCTAssertEqual(
                    source.readAlbums.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } },
                    remove ? ["local-album", "next-album"] : ["local-album", "next-album", "removed-album"])
                XCTAssertNil(fixture.controller.lastMessage, "Selection changes must not report a sync error")
            })
    }

    func testStopDuringContextTransportCancellationShowsStop() async throws {
        let errors: [any Error] = [URLError(.cancelled), UploadError.transport(code: -999, message: "Cancelled")]
        for error in errors {
            let gate = RecoveryGate()
            let source = RecoveryCountingSource()
            try await withFixture(
                onContext: {
                    await gate.wait()
                    throw error
                }, localSource: source,
                body: { fixture in
                    fixture.controller.syncNow(albumID: "local-album")
                    await fulfillment(of: [gate.entered], timeout: 5)
                    fixture.controller.stopSync()
                    XCTAssertTrue(gate.wasCancelled, "Stop must cancel the context task synchronously")
                    await gate.release()
                    await waitForSync(fixture.controller)
                    XCTAssertEqual(source.reads, 0)
                    XCTAssertEqual(fixture.controller.lastMessageStyle, .information)
                    XCTAssertEqual(fixture.controller.lastMessage, L10n.string("albumsync.error_stopped"))
                })
        }
    }

    func testSelectionDuringCancellationAwareContextReadKeepsTheBatch() async throws {
        try await checkSelectionDuringContextRead(remove: false, cancellationAware: true)
        try await checkSelectionDuringContextRead(remove: true, cancellationAware: true)
    }

    func testShutdownDuringContextTransportCancellationDoesNotShowAnError() async throws {
        let errors: [any Error] = [URLError(.cancelled), UploadError.transport(code: -999, message: "Cancelled")]
        for error in errors {
            let gate = RecoveryGate()
            let source = RecoveryCountingSource()
            try await withFixture(
                onContext: {
                    await gate.wait()
                    throw error
                }, localSource: source,
                body: { fixture in
                    fixture.controller.syncNow(albumID: "local-album")
                    await fulfillment(of: [gate.entered], timeout: 5)
                    let shutdown = Task { await fixture.controller.shutdown() }
                    await fulfillment(of: [gate.cancelled], timeout: 5)
                    XCTAssertTrue(gate.wasCancelled)
                    await gate.release()
                    await shutdown.value
                    XCTAssertEqual(source.reads, 0)
                    XCTAssertNil(fixture.controller.lastMessage, "Shutdown cancellation must not become an error line")
                })
        }
    }

    func testControllerInitSweepsAbandonedRestoreOriginals() async throws {
        try await withFixture(seedRestoreTemp: true) { fixture in
            let directory = fixture.device.directory.appendingPathComponent("album-sync-restore-temp")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            XCTAssertNotNil(fixture.device.identities.record(for: fixture.problem.source!))
        }
    }

    func testIdentityRecordChangeDuringEvidenceRejectsRestore() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                var record = try XCTUnwrap(fixture.device.identities.record(for: fixture.problem.source!))
                record.remoteLinkID = "another-link"
                XCTAssertTrue(fixture.device.identities.upsert(record))
                await gate.release()
                do {
                    _ = try await task.value
                    XCTFail("Changed identity must not restore the previous link")
                } catch {
                    XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
                }
                assertTrashed(fixture)
            })
    }

    func testAssetOutsideTheAlbumCannotRestore() async throws {
        try await withFixture(localSource: EditScenarioAlbumSource(identifiers: [])) { fixture in
            await assertUnavailable(fixture)
        }
    }

    func testChangedProblemRevisionCannotRestore() async throws {
        try await withFixture { fixture in
            let item = BackupFailedItem(
                id: fixture.problem.id, filename: fixture.problem.filename, reason: fixture.problem.reason,
                isPermanent: fixture.problem.isPermanent, issue: .remoteDeletion, source: fixture.problem.source,
                revision: .init(rawValue: -1))
            fixture.controller.recordFinishedRun(
                [item], albumID: "local-album", recoveryContext: fixture.remote.context)
            do {
                _ = try await fixture.controller.restorePhoto(item, albumID: "local-album")
                XCTFail("A different problem revision must not restore")
            } catch {
                XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            }
            assertTrashed(fixture)
        }
    }

    func testPreparedResourceVersionMustMatchCatalog() async throws {
        try await withFixture(
            configure: { configuration, device in
                configuration.recoveryResourceResolver = RecoveryAlteredResolver(
                    library: device.library, now: device.clock.now)
            },
            body: { fixture in
                await assertUnavailable(fixture)
            })
    }

    func testMissingPreparedResourceCannotRestore() async throws {
        try await withFixture(
            configure: { configuration, device in
                configuration.recoveryResourceResolver = RecoveryAlteredResolver(
                    library: device.library, now: device.clock.now, missing: true)
            },
            body: { fixture in
                await assertUnavailable(fixture)
            })
    }

    func testMissingIdentityRecordCannotRestore() async throws {
        try await withFixture { fixture in
            fixture.device.identities.close()
            await assertUnavailable(fixture)
        }
    }

    func testDeniedLibraryAccessCannotRestore() async throws {
        try await withFixture(
            configure: { configuration, _ in
                configuration.currentAccessState = { .denied }
            },
            body: { fixture in
                await assertUnavailable(fixture)
            })
    }

    func testRestoreCannotStartWhileSyncIsRunning() async throws {
        let gate = RecoveryGate()
        let source = RecoveryCountingSource()
        try await withFixture(
            onContext: { await gate.wait() }, localSource: source,
            body: { fixture in
                fixture.controller.syncNow(albumID: "local-album")
                await fulfillment(of: [gate.entered], timeout: 5)
                let refused = XCTestExpectation(description: "Restore refused during sync")
                let attempt = Task {
                    await assertUnavailable(fixture)
                    refused.fulfill()
                }
                await fulfillment(of: [refused], timeout: 5)
                XCTAssertEqual(
                    source.reads, 0, "Restore must not read the album while sync waits for context")
                fixture.controller.stopSync()
                await gate.release()
                await attempt.value
                await waitForSync(fixture.controller)
            })
    }

    func testRestoreCannotStartAfterShutdown() async throws {
        try await withFixture { fixture in
            await fixture.controller.shutdown()
            await assertUnavailable(fixture)
        }
    }

    func testQueuedSyncDoesNotStartDuringRecovery() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let task = Task { try await fixture.restore() }
                await fulfillment(of: [gate.entered], timeout: 5)
                fixture.controller.syncNow(albumID: "local-album")
                XCTAssertFalse(fixture.controller.isSyncing, "Sync cannot start while recovery owns the action")
                fixture.controller.stopSync()
                await gate.release()
                await assertCancelled(task)
                await waitForSync(fixture.controller)
                assertTrashed(fixture)
            })
    }

    func testSelectionRemovalClearsContextBeforeReselection() async throws {
        for usePicker in [true, false] {
            let gate = RecoveryGate()
            let source = RecoveryBatchSource()
            try await withFixture(
                onContext: { await gate.wait() }, localSource: source, automaticBatch: true,
                body: { fixture in
                    await fulfillment(of: [gate.entered], timeout: 5)
                    await gate.release()
                    await waitForSync(fixture.controller)
                    source.includeAsset()
                    fixture.controller.recordFinishedRun(
                        fixture.report.problems, albumID: "local-album", recoveryContext: fixture.remote.context)
                    if usePicker {
                        fixture.controller.applySelection([])
                    } else {
                        fixture.controller.removeFromSelection("local-album")
                    }
                    fixture.controller.applySelection(["local-album"])
                    XCTAssertTrue(fixture.controller.selectedAlbumIDs.contains("local-album"))
                    await assertUnavailable(fixture)
                })
        }
    }

    @discardableResult
    private func assertUnavailable(_ fixture: RecoveryControllerFixture, item: BackupFailedItem? = nil) async -> Bool {
        var unavailable = false
        do {
            let result = try await fixture.controller.restorePhoto(item ?? fixture.problem, albumID: "local-album")
            XCTFail("Unavailable evidence must not report \(result)")
        } catch {
            XCTAssertEqual(error as? AlbumSyncPhotoRecovery.Error, .unavailable)
            unavailable = (error as? AlbumSyncPhotoRecovery.Error) == .unavailable
        }
        assertTrashed(fixture)
        return unavailable
            && fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state == .trashed
    }

    private func finishedDeletionProblem(_ fixture: RecoveryControllerFixture) async throws -> BackupFailedItem {
        await waitForSync(fixture.controller)
        _ = try XCTUnwrap(
            fixture.controller.isSyncing ? nil : true, "The real executor must finish before checking Restore")
        let row = try XCTUnwrap(fixture.controller.selectedAlbums.first { $0.id == "local-album" })
        let problems = try XCTUnwrap(
            row.problems.contains(fixture.initialProblem) ? nil : row.problems,
            "A completed run must replace the previous problem")
        return try XCTUnwrap(
            problems.first { $0.issue == .remoteDeletion && $0.source == fixture.problem.source },
            "The completed run must report the current trashed photo")
    }

    private func assertFreshSyncRestores(_ fixture: RecoveryControllerFixture) async throws {
        fixture.controller.syncNow(albumID: "local-album")
        let item = try await finishedDeletionProblem(fixture)
        let result = try await fixture.controller.restorePhoto(item, albumID: "local-album")
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .active)
    }

    private func assertTrashed(_ fixture: RecoveryControllerFixture) {
        XCTAssertEqual(fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .trashed)
    }

    private func waitForSync(_ controller: AlbumSyncController) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.isSyncing, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(controller.isSyncing, "Sync completion deadline exceeded")
    }

    private func assertCancelled(_ task: Task<AlbumSyncPhotoRecovery.Result, any Error>) async {
        switch await task.result {
        case .success: XCTFail("Cancelled action must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError || UploadError.isCancellation(error))
        }
    }

    private func withFixture(
        onEvidence: @escaping @Sendable () async -> Void = {},
        onContext: @escaping @Sendable () async throws -> Void = {},
        localSource: any AlbumSyncLocalAlbumSource = EditScenarioAlbumSource(identifiers: ["asset-1"]),
        automaticBatch: Bool = false, seedRestoreTemp: Bool = false, seedPreviousProblem: Bool = false,
        configure: (inout AlbumSyncController.Configuration, EditScenarioHarness) -> Void = { _, _ in },
        body: (RecoveryControllerFixture) async throws -> Void
    ) async throws {
        let fixture = try await RecoveryControllerFixture(
            onEvidence: onEvidence, onContext: onContext, localSource: localSource,
            automaticBatch: automaticBatch, seedRestoreTemp: seedRestoreTemp,
            seedPreviousProblem: seedPreviousProblem, configure: configure)
        defer { try? fixture.device.cleanup() }
        do { try await body(fixture) } catch {
            await fixture.controller.shutdown()
            throw error
        }
        await fixture.controller.shutdown()
    }
}

struct RecoveryScenarioResolver: BackupResourceResolving {
    let library: EditScenarioLibrary
    let now: Date
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        try await library.resolve(entry, now: now)
    }
}

struct RecoveryScenarioRemote: AlbumSyncRemoteAlbumOps {
    let server: EditScenarioServer
    let context = AlbumSyncPhotoRecovery.Context(sessionID: UUID(), volumeID: "vol", hashKeyEpoch: "scenario-epoch")
    var onEvidence: @Sendable () async -> Void = {}
    var onContext: @Sendable () async throws -> Void = {}
    func photoRecoveryContext() async throws -> AlbumSyncPhotoRecovery.Context? {
        try await onContext()
        return context
    }
    func photoRecoveryState(for record: UploadIdentityRecord) async throws -> AlbumSyncPhotoRecovery.RemoteState {
        await onEvidence()
        guard let link = record.remoteLinkID else { return .unavailable }
        let snapshot = try await server.linkStateSnapshot(of: [link])
        guard snapshot.complete else { return .unavailable }
        switch snapshot.states[link] {
        case 2: return .trashed
        case 1: return .active
        default: return .unavailable
        }
    }
    func restorePhoto(
        _ uid: PhotoUID, context: AlbumSyncPhotoRecovery.Context,
        validate: @Sendable () async throws -> Void
    ) async throws {
        try await validate()
        try await server.restoreDuplicates([uid])
    }
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { try await server.listAlbums() }
    func createAlbum(name: String) async throws -> String { try await server.createAlbum(name: name) }
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        try await server.childMainLinkIDs(albumID: albumID)
    }
    func remoteDeletionStates(for links: [AlbumSyncRemoteLink]) async throws -> [String: UploadRemoteDeletionState] {
        try await server.remoteDeletionStates(for: links)
    }
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        try await server.attach(photos, albumID: albumID)
    }
}

@MainActor
private struct RecoveryControllerFixture {
    // The fixture calls this harness sequentially, before or after the owned Restore task.
    nonisolated(unsafe) let device: EditScenarioHarness
    let original: PhotoUID
    let backup: EditScenarioAlbumBackup
    let report: AlbumSyncReport
    let problem: BackupFailedItem
    let initialProblem: BackupFailedItem
    let controller: AlbumSyncController
    let remote: RecoveryScenarioRemote

    init(
        onEvidence: @escaping @Sendable () async -> Void,
        onContext: @escaping @Sendable () async throws -> Void,
        localSource: any AlbumSyncLocalAlbumSource, automaticBatch: Bool, seedRestoreTemp: Bool,
        seedPreviousProblem: Bool,
        configure: (inout AlbumSyncController.Configuration, EditScenarioHarness) -> Void
    ) async throws {
        device = try EditScenarioHarness(live: true)
        try await device.enqueue()
        await device.drain()
        original = try device.liveMain()
        device.server.personTrash(original)
        backup = EditScenarioAlbumBackup(device: device)
        report = try await device.syncAlbum(["asset-1"], backup: backup)
        problem = try XCTUnwrap(report.problems.first)
        initialProblem =
            seedPreviousProblem
            ? BackupFailedItem(
                id: "previous-run-problem", filename: problem.filename, reason: "Previous run",
                isPermanent: false, issue: .remoteDeletion, source: problem.source, revision: problem.revision)
            : problem
        let mapping = try XCTUnwrap(
            AlbumSyncMappingStore(
                url: device.directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName)))
        XCTAssertTrue(mapping.addSelection(.init(localAlbumID: "local-album", title: "Album", addedAt: .distantPast)))
        if automaticBatch {
            XCTAssertTrue(
                mapping.addSelection(.init(localAlbumID: "next-album", title: "B next", addedAt: .distantPast)))
            XCTAssertTrue(
                mapping.addSelection(.init(localAlbumID: "removed-album", title: "C removed", addedAt: .distantPast)))
        }
        if automaticBatch {
            for id in ["local-album", "next-album", "removed-album"] {
                XCTAssertTrue(
                    mapping.upsert(
                        .init(
                            localAlbumID: id, remoteAlbumID: "own-album", title: id, createdAt: .distantPast)))
            }
        }
        mapping.close()
        if seedRestoreTemp {
            let directory = device.directory.appendingPathComponent("album-sync-restore-temp")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: directory.appendingPathComponent("abandoned.partial"))
            try Data("original".utf8).write(to: directory.appendingPathComponent("abandoned.heic"))
        }
        remote = RecoveryScenarioRemote(server: device.server, onEvidence: onEvidence, onContext: onContext)
        var configuration = AlbumSyncController.Configuration(
            accountDataDirectory: device.directory, databasePolicy: .conservative)
        configuration.currentAccessState = { .full }
        configuration.localSource = localSource
        let library = device.library
        configuration.recoveryCatalog = { _ in library }
        configuration.makeChangeMonitor = { url in
            PhotoLibraryChangeMonitor(
                tokenURL: url,
                operations: .init(
                    fetch: { PHFetchResult<PHAsset>() }, register: { _ in }, unregister: { _ in }))
        }
        configuration.recoveryResourceResolver = RecoveryScenarioResolver(
            library: device.library, now: device.clock.now)
        configuration.changeSleep = { _ in
            if !automaticBatch { try await Task.sleep(nanoseconds: UInt64.max) }
        }
        configure(&configuration, device)
        controller = AlbumSyncController(
            configuration: configuration, identityResolver: device.identityResolver,
            uploader: device.deviceRemote, remoteOps: remote)
        controller.recordFinishedRun(
            seedPreviousProblem ? [initialProblem] : report.problems,
            albumID: "local-album", recoveryContext: remote.context)
    }

    func restore() async throws -> AlbumSyncPhotoRecovery.Result {
        try await controller.restorePhoto(problem, albumID: "local-album")
    }
}

private actor RecoveryGate {
    nonisolated let entered = XCTestExpectation(description: "Evidence started")
    nonisolated let cancelled = XCTestExpectation(description: "Evidence cancelled")
    nonisolated private let cancellation = RecoveryCancellationState()
    nonisolated var wasCancelled: Bool { cancellation.wasCancelled }
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var finished = false
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered.fulfill()
                if open { continuation.resume() } else { self.continuations.append(continuation) }
            }
        } onCancel: {
            cancellation.record()
            cancelled.fulfill()
        }
        finished = true
    }
    func release() {
        open = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

private final class RecoveryCountingSource: AlbumSyncLocalAlbumSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func listAlbums() async throws -> [LocalAlbumSummary] { [] }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        lock.withLock { count += 1 }
        throw CancellationError()
    }
}

/// Wraps the scenario backup and counts executor entries and `stop()` calls. The first `stop()`
/// can be held so a test parks `shutdown()` between the runner stop and the rest of its teardown.
private final class RecoveryShutdownProbeBackup: AlbumSyncBackupExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let holdsFirstStop: Bool
    private var base: (any AlbumSyncBackupExecuting)?
    private var stops = 0
    private var backups = 0
    private var firstStopContinuation: CheckedContinuation<Void, Never>?
    private var firstStopReleased = false
    let firstStopEntered = XCTestExpectation(description: "Shutdown reached the first executor stop")
    let executorStopped = XCTestExpectation(description: "Shutdown passed its executor stop")

    init(holdsFirstStop: Bool = false) {
        self.holdsFirstStop = holdsFirstStop
    }

    var stopCalls: Int { lock.withLock { stops } }
    var ensureBackedUpCalls: Int { lock.withLock { backups } }

    func setBase(_ base: any AlbumSyncBackupExecuting) {
        lock.withLock { self.base = base }
    }

    func ensureBackedUp(
        localIdentifiers: [String], onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        lock.withLock { backups += 1 }
        guard let base = lock.withLock({ base }) else { throw CancellationError() }
        return try await base.ensureBackedUp(localIdentifiers: localIdentifiers, onProgress: onProgress)
    }

    func remoteProofLinks(for localIdentifiers: [String]) async throws -> [String: AlbumSyncRemoteLink] {
        guard let base = lock.withLock({ base }) else { return [:] }
        return try await base.remoteProofLinks(for: localIdentifiers)
    }

    func stop() async {
        let count = lock.withLock {
            stops += 1
            return stops
        }
        // The first stop belongs to the runner's stop call inside shutdown(); the second one is
        // shutdown's own backup stop, whose return puts shutdown at the active sync join.
        if count == 1 { firstStopEntered.fulfill() }
        if holdsFirstStop, count == 1 {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if firstStopReleased { return true }
                    firstStopContinuation = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let base = lock.withLock({ base }) { await base.stop() }
        if count == 2 { executorStopped.fulfill() }
    }

    func releaseFirstStop() {
        let continuation = lock.withLock {
            firstStopReleased = true
            let held = firstStopContinuation
            firstStopContinuation = nil
            return held
        }
        continuation?.resume()
    }
}

/// Thread-safe completion flag for asserting that a background task has not finished yet.
private final class RecoveryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func mark() { lock.withLock { done = true } }
    var isDone: Bool { lock.withLock { done } }
}

private final class RecoveryCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var wasCancelled: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
}

private actor RecoveryContextReads {
    private(set) var count = 0
    func failFirstRead() throws {
        count += 1
        if count == 1 { throw URLError(.notConnectedToInternet) }
    }
}

private final class RecoveryBatchSource: AlbumSyncLocalAlbumSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String] = []
    private var identifiers: [String] = []
    private let onFirstRead: @Sendable () async -> Void
    init(onFirstRead: @escaping @Sendable () async -> Void = {}) {
        self.onFirstRead = onFirstRead
    }
    func includeAsset() { lock.withLock { identifiers = ["asset-1"] } }
    var readAlbums: [String] { lock.withLock { reads } }
    func listAlbums() async throws -> [LocalAlbumSummary] {
        zip(
            ["local-album", "next-album", "removed-album", "added-album"], ["Album", "B next", "C removed", "D added"]
        )
        .map { .init(id: $0.0, title: $0.1, assetCount: 0) }
    }
    func albumContents(albumID: String) async throws -> AlbumSyncLocalAlbumContents {
        let first = lock.withLock {
            reads.append(albumID)
            return reads.count == 1
        }
        if first { await onFirstRead() }
        return .present(lock.withLock { identifiers })
    }
}

private struct RecoveryAlteredResolver: BackupResourceResolving {
    let library: EditScenarioLibrary
    let now: Date
    var missing = false
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard !missing, let original = try await library.resolve(entry, now: now) else { return nil }
        let snapshot = original.candidate.snapshot
        let candidate = UploadBackupAssetCandidate(
            snapshot: .init(
                source: snapshot.source, revision: .init(rawValue: -1),
                editRevision: snapshot.editRevision, resourceCount: snapshot.resourceCount),
            originalFilename: original.candidate.originalFilename, byteCount: original.candidate.byteCount)
        return .init(
            candidate: candidate, descriptor: original.descriptor, mediaType: original.mediaType,
            captureDate: original.captureDate, secondaries: original.secondaries, cleanup: original.cleanup)
    }
}

// MARK: - Restore all (#1091)

extension AlbumSyncPhotoRecoveryControllerTests {
    func testBulkRestoreConfirmsEveryDeletedRowOfTheFinishedRunBeyondTheSavedLimit() async throws {
        try await withFixture { fixture in
            let items = otherRows(5) + missingRows(1_000) + fixture.report.problems
            fixture.controller.recordFinishedRun(
                items, albumID: "local-album", recoveryContext: fixture.remote.context)
            XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems.count, 200)
            XCTAssertTrue(fixture.controller.isBulkRestoreAvailable(albumID: "local-album"))
            let confirmation = try await unwrapAsync(await fixture.controller.prepareRestore(albumID: "local-album"))
            XCTAssertEqual(confirmation.action, .restore)
            XCTAssertEqual(confirmation.count, 1_001, "Consent covers the whole finished run, not the saved page")
            XCTAssertTrue(confirmation.items.allSatisfy { $0.issue == .remoteDeletion })
            XCTAssertTrue(confirmation.items.contains(fixture.problem))
            XCTAssertFalse(fixture.controller.bulkPhotoActions.isRunning, "Preparing never starts work")
            assertTrashed(fixture)
        }
    }

    func testBulkRestoreRestoresTheTrashedCopyKeepsRefusedRowsAndSyncsOnceWithoutUpload() async throws {
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                fixture.controller.recordFinishedRun(
                    missingRows(2) + fixture.report.problems,
                    albumID: "local-album", recoveryContext: fixture.remote.context)
                let uploads = fixture.device.server.uploadRequestCount
                let source = try XCTUnwrap(fixture.problem.source)
                let journal = fixture.device.journal.entry(for: source)

                let summary = try await runBulkRestore(fixture)

                assertSummary(summary, total: 3, completed: 1)
                XCTAssertEqual(probe.ensureBackedUpCalls, 1, "The normal album sync runs once, after the run")
                let members = try await fixture.device.server.childMainLinkIDs(albumID: "own-album")
                XCTAssertEqual(members, [fixture.original.nodeID], "The same existing copy enters the album")
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads, "A restore never uploads again")
                XCTAssertEqual(fixture.device.journal.entry(for: source), journal)
                XCTAssertNil(fixture.controller.lastMessage)
            })
    }

    func testBulkRestoreOfAPermanentlyDeletedCopyKeepsTheRowWithoutSyncOrUpload() async throws {
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let before = fixture.controller.selectedAlbums.first?.problems
                let uploads = fixture.device.server.uploadRequestCount
                fixture.device.server.personEmptyTrash()
                let restores = restoreCalls(fixture)

                let summary = try await runBulkRestore(fixture)

                assertSummary(summary, total: 1, completed: 0)
                XCTAssertEqual(probe.ensureBackedUpCalls, 0, "Nothing restored, so no sync starts")
                XCTAssertEqual(fixture.controller.selectedAlbums.first?.problems, before)
                XCTAssertEqual(restoreCalls(fixture), restores)
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .deleted)
            })
    }

    func testBulkRestoreCountsAnAlreadyActiveCopyWithoutAnotherRestoreCall() async throws {
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let first = try await fixture.restore()
                XCTAssertEqual(first, .restored)
                let restores = restoreCalls(fixture)
                let uploads = fixture.device.server.uploadRequestCount

                let summary = try await runBulkRestore(fixture)

                assertSummary(summary, total: 1, completed: 1)
                XCTAssertEqual(restoreCalls(fixture), restores, "An active copy needs no second restore")
                XCTAssertEqual(probe.ensureBackedUpCalls, 1, "The album sync still adds the active copy")
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
            })
    }

    func testBulkRestoreNeedsTheExactConfirmationAndStartsOnlyOnce() async throws {
        let gate = RecoveryGate()
        try await withFixture(
            onEvidence: { await gate.wait() },
            body: { fixture in
                let controller = fixture.controller
                let declined = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                let second = await controller.prepareRestore(albumID: "local-album")
                XCTAssertNil(second, "One open confirmation at a time")
                controller.bulkPhotoActions.dismissConfirmation()
                XCTAssertFalse(controller.startRestore(declined, albumID: "local-album"), "Cancel revokes consent")
                assertTrashed(fixture)

                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertFalse(controller.startRestore(confirmation, albumID: "next-album"), "Consent is per album")
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                await fulfillment(of: [gate.entered], timeout: 5)
                XCTAssertFalse(controller.startRestore(confirmation, albumID: "local-album"), "A repeated tap")
                let duringRun = await controller.prepareRestore(albumID: "local-album")
                XCTAssertNil(duringRun)
                XCTAssertFalse(controller.isBulkRestoreAvailable(albumID: "local-album"))
                await gate.release()
                await controller.waitUntilBulkRestoreSettled()
                XCTAssertEqual(controller.bulkPhotoActions.summary?.completed, 1)
            })
    }

    func testBulkRestoreHoldsAlbumSyncUntilTheWholeRunEnds() async throws {
        let gate = RecoveryGate()
        let pause = RecoveryGate()
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            onEvidence: { await gate.wait() },
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
                configuration.bulkActionPause = { _ in await pause.wait() }
            },
            body: { fixture in
                let controller = fixture.controller
                controller.recordFinishedRun(
                    fixture.report.problems + missingRows(1),
                    albumID: "local-album", recoveryContext: fixture.remote.context)
                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                await fulfillment(of: [gate.entered], timeout: 5)
                controller.syncNow(albumID: "local-album")
                XCTAssertFalse(controller.isSyncing)
                await gate.release()
                // The run now waits between its two photos; no per-photo restore task is active.
                await fulfillment(of: [pause.entered], timeout: 5)
                XCTAssertEqual(controller.bulkPhotoActions.processed, 1)
                XCTAssertTrue(controller.bulkPhotoActions.isRunning)
                XCTAssertFalse(controller.isSyncing, "No album sync may start between the photos of one run")
                XCTAssertFalse(
                    controller.canRestorePhotos(albumID: "local-album"),
                    "Per-photo Restore stays unavailable for the whole run")
                var refused = false
                do {
                    _ = try await controller.restorePhoto(fixture.problem, albumID: "local-album")
                } catch {
                    refused = (error as? AlbumSyncPhotoRecovery.Error) == .unavailable
                }
                XCTAssertTrue(refused, "A per-photo restore between two photos must be refused")
                await pause.release()
                await controller.waitUntilBulkRestoreSettled()
                await waitForSync(controller)
                XCTAssertEqual(probe.ensureBackedUpCalls, 1, "The held request and the run end share one sync")
                XCTAssertEqual(controller.bulkPhotoActions.summary?.completed, 1)
            })
    }

    func testStopDuringBulkRestoreEndsTheRunWithoutSyncAndKeepsTheRow() async throws {
        let gate = RecoveryGate()
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            onEvidence: { await gate.wait() },
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let controller = fixture.controller
                // The held photo is the last one: only Stop itself can end the run as cancelled.
                controller.recordFinishedRun(
                    missingRows(3) + fixture.report.problems,
                    albumID: "local-album", recoveryContext: fixture.remote.context)
                let before = controller.selectedAlbums.first?.problems
                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                await fulfillment(of: [gate.entered], timeout: 5)
                controller.stopSync()
                await fulfillment(of: [gate.cancelled], timeout: 5)
                await gate.release()
                await controller.waitUntilBulkRestoreSettled()
                await waitForSync(controller)

                let summary = try XCTUnwrap(controller.bulkPhotoActions.summary)
                XCTAssertTrue(summary.cancelled)
                XCTAssertEqual(summary.completed, 0)
                XCTAssertEqual(summary.total, 4)
                XCTAssertEqual(probe.ensureBackedUpCalls, 0)
                XCTAssertEqual(controller.selectedAlbums.first?.problems, before)
                assertTrashed(fixture)
            })
    }

    func testShutdownJoinsTheBulkRestoreAndRejectsLaterRuns() async throws {
        let pause = RecoveryGate()
        try await withFixture(
            configure: { configuration, _ in configuration.bulkActionPause = { _ in await pause.wait() } },
            body: { fixture in
                let controller = fixture.controller
                controller.recordFinishedRun(
                    fixture.report.problems + missingRows(2),
                    albumID: "local-album", recoveryContext: fixture.remote.context)
                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                await fulfillment(of: [pause.entered], timeout: 5)
                let shutdown = Task { await controller.shutdown() }
                await fulfillment(of: [pause.cancelled], timeout: 5)
                await pause.release()
                await shutdown.value
                XCTAssertFalse(controller.bulkPhotoActions.isRunning, "Shutdown joins the run before stores close")
                let summary = try XCTUnwrap(controller.bulkPhotoActions.summary)
                XCTAssertTrue(summary.cancelled)
                XCTAssertEqual(summary.completed, 1, "The photo restored before shutdown keeps its outcome")
                let afterShutdown = await controller.prepareRestore(albumID: "local-album")
                XCTAssertNil(afterShutdown)
                XCTAssertFalse(controller.startRestore(confirmation, albumID: "local-album"))
            })
    }

    func testBulkRestoreRefusesConfirmationsThatPrepareRestoreDidNotMake() async throws {
        try await withFixture { fixture in
            let controller = fixture.controller
            let restore = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
            XCTAssertEqual(restore.count, 1)
            controller.bulkPhotoActions.dismissConfirmation()
            let backUp = try XCTUnwrap(
                controller.bulkPhotoActions.prepare(fixture.report.problems, action: .backUpAgain))
            XCTAssertFalse(controller.startRestore(backUp, albumID: "local-album"), "Back Up Again consent")
            controller.bulkPhotoActions.dismissConfirmation()
            let other = try XCTUnwrap(controller.bulkPhotoActions.prepare(fixture.report.problems, action: .restore))
            XCTAssertFalse(controller.startRestore(other, albumID: "local-album"), "Consent not shown by the list")
            XCTAssertFalse(controller.bulkPhotoActions.isRunning)
            assertTrashed(fixture)
        }
    }

    func testSelectionChangeDuringBulkRestoreEndsTheRun() async throws {
        let pause = RecoveryGate()
        try await withFixture(
            configure: { configuration, _ in configuration.bulkActionPause = { _ in await pause.wait() } },
            body: { fixture in
                let controller = fixture.controller
                controller.recordFinishedRun(
                    missingRows(1) + fixture.report.problems,
                    albumID: "local-album", recoveryContext: fixture.remote.context)
                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                await fulfillment(of: [pause.entered], timeout: 5)
                // The picker invalidates recovery even when it keeps the same albums.
                controller.applySelection(controller.selectedAlbumIDs)
                await pause.release()
                await controller.waitUntilBulkRestoreSettled()
                let summary = try XCTUnwrap(controller.bulkPhotoActions.summary)
                XCTAssertTrue(summary.cancelled, "Recovery changed after consent, so the run ends")
                XCTAssertEqual(summary.completed, 0)
                assertTrashed(fixture)
            })
    }

    func testBulkRestoreConsentOfOneAlbumNeverStartsAnother() async throws {
        let source = RecoveryBatchSource()
        source.includeAsset()
        try await withFixture(
            localSource: source, automaticBatch: true,
            configure: { configuration, device in
                configuration.backupExecutorOverride = EditScenarioAlbumBackup(device: device)
            },
            body: { fixture in
                let controller = fixture.controller
                await waitForSync(controller)
                XCTAssertTrue(controller.selectedAlbumIDs.isSuperset(of: ["local-album", "next-album"]))
                for album in ["local-album", "next-album"] {
                    controller.recordFinishedRun(
                        fixture.report.problems, albumID: album, recoveryContext: fixture.remote.context)
                }
                XCTAssertTrue(controller.isBulkRestoreAvailable(albumID: "next-album"))
                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertFalse(
                    controller.startRestore(confirmation, albumID: "next-album"),
                    "Each album's finished run has its own identity")
                XCTAssertFalse(controller.bulkPhotoActions.isRunning)
                XCTAssertNil(controller.bulkRestoreAlbumID)
                assertTrashed(fixture)
                // The shared runner's progress and result belong to the album that started it, not to the other list.
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                XCTAssertEqual(controller.bulkRestoreAlbumID, "local-album")
                await controller.waitUntilBulkRestoreSettled()
                XCTAssertEqual(controller.bulkRestoreAlbumID, "local-album", "The result stays with its album")
            })
    }

    func testStopAfterARestoredPhotoLeavesTheAlbumToTheNextSync() async throws {
        let probe = RecoveryShutdownProbeBackup()
        try await withFixture(
            configure: { configuration, device in
                probe.setBase(EditScenarioAlbumBackup(device: device))
                configuration.backupExecutorOverride = probe
            },
            body: { fixture in
                let controller = fixture.controller
                controller.recordFinishedRun(
                    fixture.report.problems + missingRows(3),
                    albumID: "local-album", recoveryContext: fixture.remote.context)
                let uploads = fixture.device.server.uploadRequestCount
                let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
                XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while controller.bulkPhotoActions.processed < 1, ContinuousClock.now < deadline { await Task.yield() }
                controller.stopSync()
                await controller.waitUntilBulkRestoreSettled()
                await waitForSync(controller)

                let summary = try XCTUnwrap(controller.bulkPhotoActions.summary)
                XCTAssertTrue(summary.cancelled)
                XCTAssertEqual(summary.completed, 1)
                XCTAssertEqual(probe.ensureBackedUpCalls, 0, "Stop also stops the final album sync")
                XCTAssertEqual(
                    fixture.device.server.links.first { $0.linkID == fixture.original.nodeID }?.state, .active)

                controller.syncNow(albumID: "local-album")
                await waitForSync(controller)
                XCTAssertEqual(probe.ensureBackedUpCalls, 1)
                let members = try await fixture.device.server.childMainLinkIDs(albumID: "own-album")
                XCTAssertEqual(members, [fixture.original.nodeID], "The next sync adds the restored copy")
                XCTAssertEqual(fixture.device.server.uploadRequestCount, uploads)
            })
    }

    func testBulkRestoreRefusesConsentFromAnEarlierFinishedRun() async throws {
        try await withFixture { fixture in
            let controller = fixture.controller
            let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
            controller.recordFinishedRun(
                fixture.report.problems, albumID: "local-album", recoveryContext: fixture.remote.context)
            XCTAssertFalse(
                controller.startRestore(confirmation, albumID: "local-album"),
                "A new finished run needs fresh consent, even with the same rows")
            XCTAssertFalse(controller.bulkPhotoActions.isRunning)
            assertTrashed(fixture)
        }
    }

    private func runBulkRestore(_ fixture: RecoveryControllerFixture) async throws -> BulkPhotoActionRunner.Summary {
        let controller = fixture.controller
        let confirmation = try await unwrapAsync(await controller.prepareRestore(albumID: "local-album"))
        XCTAssertTrue(controller.startRestore(confirmation, albumID: "local-album"))
        await controller.waitUntilBulkRestoreSettled()
        await waitForSync(controller)
        return try XCTUnwrap(controller.bulkPhotoActions.summary)
    }

    private func restoreCalls(_ fixture: RecoveryControllerFixture) -> Int {
        fixture.device.server.steps.filter { $0.action.hasPrefix("person restore ") }.count
    }

    /// Rows deleted in Proton Drive whose photo is not in the album; the existing restore path refuses them.
    private func missingRows(_ count: Int) -> [BackupFailedItem] {
        (0..<count).map { index in
            BackupFailedItem(
                id: "missing-\(index)", filename: "missing-\(index).heic", reason: "Deleted",
                isPermanent: false, issue: .remoteDeletion,
                source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "missing-\(index)"))
        }
    }

    private func otherRows(_ count: Int) -> [BackupFailedItem] {
        (0..<count).map { index in
            BackupFailedItem(
                id: "other-\(index)", filename: "other-\(index).heic", reason: "Reason",
                isPermanent: false, issue: .network)
        }
    }

    private func unwrapAsync<T>(
        _ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> T {
        let unwrapped = try await value()
        return try XCTUnwrap(unwrapped, file: file, line: line)
    }

    private func assertSummary(
        _ summary: BulkPhotoActionRunner.Summary, total: Int, completed: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(summary.action, .restore, file: file, line: line)
        XCTAssertEqual(summary.total, total, file: file, line: line)
        XCTAssertEqual(summary.completed, completed, "restored", file: file, line: line)
        XCTAssertEqual(summary.stayed, total - completed, "unchanged", file: file, line: line)
        XCTAssertFalse(summary.cancelled, file: file, line: line)
    }
}
