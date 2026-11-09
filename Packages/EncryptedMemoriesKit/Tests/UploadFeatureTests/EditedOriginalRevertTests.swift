import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

/// Crash safety and ordering: copy before trash, favorite/album carry-over per step, resume without duplicates,
/// foreign draft blocks and leaves everything intact.
final class EditedOriginalRevertTests: XCTestCase {
    private var tempDir: URL!
    private var server: FakeRevertRemote!
    private var journalStore: EditedOriginalRevertJournalFileStore!
    private var admission: JoinedShutdownGate!

    private let editedMain = PhotoUID(volumeID: "own", nodeID: "edited")
    private let original = PhotoUID(volumeID: "own", nodeID: "original")

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edited-original-revert-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        server = FakeRevertRemote(ownVolumeID: "own")
        journalStore = EditedOriginalRevertJournalFileStore(accountDataDirectory: tempDir)
        admission = JoinedShutdownGate()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeOrchestrator(
        journalStore store: (any EditedOriginalRevertJournalStore)? = nil
    ) -> EditedOriginalRevert {
        EditedOriginalRevert(
            remote: server,
            albums: server,
            copier: server.makeCopier(tempDirectory: tempDir.appendingPathComponent("work")),
            relations: server,
            journalStore: store ?? journalStore,
            admission: admission
        )
    }

    // MARK: Happy path

    func testHappyPathRestoresCopyCarriesFavoriteAndAlbumsThenTrashesTheEditedMain() async throws {
        let restoredName = "IMG_0001 (original).heic"
        let copyUID = try await makeOrchestrator().revert(
            editedMain: editedMain, original: original, restoredName: restoredName)

        XCTAssertEqual(server.uploadNames(), [restoredName])
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertTrue(server.favoriteWrites().contains(copyUID))
        let albumAdds = server.albumAdds()
        for albumID in ["album1", "album2"] {
            XCTAssertTrue(
                albumAdds.contains { $0.album.albumID == albumID && $0.album.volumeID == "own" && $0.uid == copyUID },
                "missing add to \(albumID)")
        }
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertTrue(server.invalidatedCachedRemoteState())
    }

    func testForeignDraftBlocksAndLeavesNothingTrashed() async throws {
        server.setForeignDraft(clientUID: "other")
        do {
            try await performRevert()
            XCTFail("should block")
        } catch let error as EditedOriginalRevert.RevertError {
            // The error names the person's source filename, not the corrected upload name.
            XCTAssertEqual(error, .blockedByForeignDraft("original.heic"))
        }
        XCTAssertTrue(server.trashCalls().isEmpty)
        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain))
    }

    func testCrashDuringCopyResumesWithoutDuplicateUpload() async throws {
        server.failUploadOnce()
        do {
            try await performRevert()
            XCTFail("upload should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .copying)
        XCTAssertNil(journal.copyUID)
        XCTAssertTrue(server.trashCalls().isEmpty)

        let copyUID = try await performRevert()
        XCTAssertNotNil(copyUID)
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(server.trashCalls().count, 1)
    }

    func testCrashDuringTrashStepResumesWithoutReupload() async throws {
        server.failTrashOnce()
        do {
            try await performRevert()
            XCTFail("trash should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .trashingEdit)
        XCTAssertNotNil(journal.copyUID)

        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertEqual(outcomes.count, 1)
        let result = try outcomes.first!.result.get()
        XCTAssertEqual(result, journal.copyUID!)
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(server.trashCalls().count, 1)
    }

    func testResumeOfAPendingCopyDoesNotFireAutomatically() async throws {
        server.failUploadOnce()
        do {
            try await performRevert()
        } catch {}
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - The automatic resume never makes a copy

    /// The resume at app start has no tap behind it, so it must never download or upload. A journal whose confirmed
    /// copy vanished stays exactly as it is, and the person's next Revert tap makes the copy again.
    func testResumeNeverMakesANewCopyWhenTheConfirmedCopyVanished() async throws {
        server.failTrashOnce()
        do {
            try await performRevert()
            XCTFail("trash should fail")
        } catch {}
        let before = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        let vanishedCopy = try XCTUnwrap(before.copyUID)
        server.markTrashed(nodeID: vanishedCopy.nodeID)
        let logBefore = server.operationLog()

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertTrue(outcomes.isEmpty, "a journal that needs a new copy waits for the person and reports nothing")
        XCTAssertEqual(
            server.operationLog(), logBefore, "the resume writes nothing: no upload, favorite, album or trash")
        XCTAssertEqual(server.uploadNames().count, 1, "only the first attempt uploaded")
        XCTAssertEqual(
            try journalStore.journal(forEditedMain: editedMain), before, "the journal stays pending, unchanged")

        // The person taps Revert again: the same journal continues, makes the copy and finishes.
        let newCopy = try await performRevert()
        XCTAssertNotEqual(newCopy, vanishedCopy)
        XCTAssertEqual(server.uploadNames().count, 2)
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// A journal in the trash step that never recorded a copy is the same case: the resume waits for the person.
    func testResumeNeverMakesACopyForATrashStepWithoutARecordedCopy() async throws {
        let orphan = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
            phase: .trashingEdit)
        try journalStore.save(orphan)

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(server.operationLog().isEmpty, "no write of any kind")
        XCTAssertEqual(try journalStore.journal(forEditedMain: editedMain), orphan)

        _ = try await performRevert()
        XCTAssertEqual(server.uploadNames().count, 1, "the person's tap makes the copy once")
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    // MARK: - The resume acts only on the journal that is on disk right now

    /// A journal at phase `copying` with a confirmed copy is the state after a failed carry-over. The resume must not
    /// continue it: that would write the favorite tag and the album memberships without a tap.
    func testResumeNeverContinuesACopyingJournalThatHasAConfirmedCopy() async throws {
        server.failAlbumAddOnce(albumID: "album1")
        do {
            _ = try await performRevert()
            XCTFail("album add should fail")
        } catch {}
        let before = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(before.phase, .copying)
        XCTAssertNotNil(before.copyUID)
        let logBefore = server.operationLog()

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(server.operationLog(), logBefore, "no favorite, album or trash write without a tap")
        XCTAssertEqual(try journalStore.journal(forEditedMain: editedMain), before)
    }

    /// The resume reads the list of journals once, and a tap can finish before the resume reaches a journal. The
    /// resume then must neither write that journal back nor trash the edited photo again.
    func testAResumeNeverBringsBackAJournalThatATapFinishedMeanwhile() async throws {
        server.seedStandaloneCopy(nodeID: "copy-1", contentHash: "ch-computed")
        let snapshot = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
            copyUID: server.uid("copy-1"), favoriteDone: true, addedAlbumIDs: ["album1", "album2"],
            phase: .trashingEdit)
        try journalStore.save(snapshot)
        let store = RacingJournalStore(base: journalStore) { [journalStore] in
            try journalStore?.remove(forEditedMain: snapshot.editedMainUID)
        }

        let outcomes = try await makeOrchestrator(journalStore: store).resumePending()

        XCTAssertTrue(outcomes.isEmpty, "the finished journal is no work for the resume")
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain), "the journal does not come back")
        XCTAssertTrue(server.trashCalls().isEmpty, "the edited photo is not trashed a second time")
    }

    /// The same race, but the tap moved the journal on: the resume must not write its older state over the newer one.
    func testAResumeNeverWritesAnOlderJournalOverANewerOne() async throws {
        server.seedStandaloneCopy(nodeID: "copy-1", contentHash: "ch-computed")
        let snapshot = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
            copyUID: server.uid("copy-1"), favoriteDone: true, addedAlbumIDs: ["album1", "album2"],
            phase: .trashingEdit)
        try journalStore.save(snapshot)
        var newer = snapshot
        newer.phase = .repointingDevice
        let store = RacingJournalStore(base: journalStore) { [journalStore, newer] in
            try journalStore?.save(newer)
        }

        let outcomes = try await makeOrchestrator(journalStore: store).resumePending()

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(try journalStore.journal(forEditedMain: editedMain), newer, "the newer state stays")
        XCTAssertTrue(server.trashCalls().isEmpty)
    }

    // MARK: - The summary that both hosts log at app start

    func testTheSummaryCountsAFinishedTrashStep() async throws {
        server.failTrashOnce()
        do {
            _ = try await performRevert()
            XCTFail("trash should fail")
        } catch {}

        let summary = await makeOrchestrator().resumeAndSummarize()

        XCTAssertEqual(summary.finished, 1)
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertNil(summary.readFailure)
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    func testTheSummaryReportsAFailedStepAndKeepsItsJournal() async throws {
        server.failTrashOnce()
        do {
            _ = try await performRevert()
            XCTFail("trash should fail")
        } catch {}
        server.failTrashOnce()

        let summary = await makeOrchestrator().resumeAndSummarize()

        XCTAssertEqual(summary.finished, 0)
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain))
    }

    func testTheSummaryOfAJournalThatWaitsForThePersonIsEmpty() async throws {
        try journalStore.save(
            EditedOriginalRevertJournal(
                editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
                phase: .trashingEdit))

        let summary = await makeOrchestrator().resumeAndSummarize()

        XCTAssertEqual(summary.finished, 0)
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertNil(summary.readFailure)
        XCTAssertTrue(server.operationLog().isEmpty)
    }

    func testTheSummaryReportsAnAccountThatShutDown() async throws {
        admission.closeAdmission()

        let summary = await makeOrchestrator().resumeAndSummarize()

        XCTAssertEqual(summary.finished, 0)
        XCTAssertTrue(summary.readFailure is CancellationError)
    }

    func testTheSummaryLogLineNamesTheCountsAndTheErrors() {
        struct StepFailure: Error {}
        struct ReadFailure: Error {}
        let quiet = EditedOriginalRevertResumeSummary(finished: 2, failures: [], readFailure: nil)
        XCTAssertEqual(quiet.logLine, "revert: resumed trash steps finished=2 failed=0")

        let loud = EditedOriginalRevertResumeSummary(
            finished: 0, failures: [StepFailure()], readFailure: ReadFailure())
        XCTAssertTrue(loud.logLine.contains("finished=0 failed=1"))
        XCTAssertTrue(loud.logLine.contains("StepFailure"), "the error of a failed step is in the line")
        XCTAssertTrue(
            loud.logLine.contains("unread=") && loud.logLine.contains("ReadFailure"), "a read failure is named")
    }

    /// The log line can reach a support report. It names the kind of each error and never its payload: a blocked
    /// draft carries the person's file name, and a file error carries a path.
    func testTheSummaryLogLineNeverContainsAFileNameAPathOrAnIdentifier() {
        let secretName = "IMG_SECRET_0042.heic"
        let secretPath = "/example/private/\(secretName)"
        let summary = EditedOriginalRevertResumeSummary(
            finished: 1,
            failures: [
                EditedOriginalRevert.RevertError.blockedByForeignDraft(secretName),
                CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: secretPath]),
            ],
            readFailure: CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: secretPath]))

        let line = summary.logLine

        XCTAssertFalse(line.contains("IMG_SECRET"), line)
        XCTAssertFalse(line.contains("/example"), line)
        XCTAssertFalse(line.contains(".heic"), line)
        XCTAssertTrue(line.contains("blockedByForeignDraft"), "the kind of the error stays visible: \(line)")
        XCTAssertTrue(
            line.contains("NSCocoaErrorDomain#4"), "the domain and code of a foreign error stay visible: \(line)")
    }

    private func performRevert() async throws -> PhotoUID {
        try await makeOrchestrator().revert(
            editedMain: editedMain, original: original, restoredName: "IMG_0001 (original).heic")
    }

    // MARK: - Ordering and resume safety tests

    /// F3: Pins that the carry-over (favorite + albums) runs before the trash. The operation log captures the exact sequence.
    func testCarryOverRunsBeforeTrash() async throws {
        let restoredName = "IMG_0001 (original).heic"
        let copyUID = try await makeOrchestrator().revert(
            editedMain: editedMain, original: original, restoredName: restoredName)

        let log = server.operationLog()
        // Expected order: upload -> favorite -> albums -> trash
        let uploadIdx = log.firstIndex { $0.starts(with: "upload:") }
        let favoriteIdx = log.firstIndex { $0.starts(with: "favorite:") }
        let albumIdx = log.firstIndex { $0.starts(with: "album:") }
        let trashIdx = log.firstIndex { $0.starts(with: "trash:") }

        XCTAssertNotNil(uploadIdx, "upload should occur")
        XCTAssertNotNil(favoriteIdx, "favorite write should occur")
        XCTAssertNotNil(albumIdx, "album add should occur")
        XCTAssertNotNil(trashIdx, "trash should occur")

        if let u = uploadIdx, let f = favoriteIdx, let a = albumIdx, let t = trashIdx {
            XCTAssertTrue(
                u < f && f < a && a < t,
                "Order violation: expected upload → favorite → album(s) → trash, got \(log)")
        }

        // Assert the copy has the favorite and albums
        XCTAssertTrue(server.favoriteWrites().contains(copyUID))
        let albumAdds = server.albumAdds()
        for albumID in ["album1", "album2"] {
            XCTAssertTrue(
                albumAdds.contains { $0.album.albumID == albumID && $0.uid == copyUID },
                "missing add to \(albumID)")
        }
    }

    /// F4: A crashed session committed the upload on the server but never recorded it in the journal. The next
    /// revert adopts the committed photo instead of uploading the original a second time.
    func testRevertAfterCommittedUploadAdoptsWithoutDuplicateUpload() async throws {
        // The committed copy of the crashed session: same content hash, still active.
        server.seedStandaloneCopy(nodeID: "copy-from-crashed", contentHash: "ch-computed")

        let copyUID = try await performRevert()

        XCTAssertEqual(copyUID.nodeID, "copy-from-crashed", "the committed copy is adopted")
        XCTAssertEqual(server.uploadNames().count, 0, "adoption uploads nothing")
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// F1: Copy vanishes between confirm and trash; the person's next Revert re-confirms before trash.
    func testTrashStepReconfirmsCopyIsActive() async throws {
        // Start revert, fail trash, then delete the copy externally
        server.failTrashOnce()
        do {
            try await performRevert()
            XCTFail("trash should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .trashingEdit)
        XCTAssertNotNil(journal.copyUID)

        // Simulate deletion of the copy by another device
        if let copyNode = journal.copyUID?.nodeID {
            server.markTrashed(nodeID: copyNode)
        }

        // The person taps Revert again: the same journal makes the copy again, then succeeds. The automatic
        // resume never does this (see testResumeNeverMakesANewCopyWhenTheConfirmedCopyVanished).
        let newCopyUID = try await performRevert()
        XCTAssertNotEqual(newCopyUID.nodeID, journal.copyUID?.nodeID, "new copy should be created")

        // Verify upload count increased by exactly one (the re-copy)
        XCTAssertEqual(server.uploadNames().count, 2, "two uploads total: initial + re-copy")
    }

    /// F2: The carry-over state of a copy that disappeared is void. The new copy receives the favorite tag and
    /// the albums again, so it never silently misses them.
    func testCarryOverStateResetsWhenCopyIsRemade() async throws {
        // The trash step fails after the carry-over completed, so the journal records favoriteDone and the albums.
        server.failTrashOnce()
        do {
            try await performRevert()
            XCTFail("trash should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.favoriteDone, true)
        XCTAssertFalse(journal.addedAlbumIDs.isEmpty, "albums should have been attempted")

        // Delete the copy
        if let copyNode = journal.copyUID?.nodeID {
            server.markTrashed(nodeID: copyNode)
        }

        // The person taps Revert again: reset favoriteDone=false, recreate the copy, redo favorite + albums
        _ = try await performRevert()

        // Verify favorite was written to the new copy
        let finalLog = server.operationLog()
        let favoriteCount = finalLog.filter { $0.starts(with: "favorite:") }.count
        XCTAssertEqual(favoriteCount, 2, "favorite should be written twice: initial attempt + re-copy")
    }

    /// F5: Abandon a stuck .copying journal when the edited main is already trashed.
    func testAbandonRemovesStuckJournalWhenEditIsTrashed() async throws {
        // Start revert, it gets stuck at .copying
        server.failUploadOnce()
        do {
            try await performRevert()
            XCTFail("upload should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .copying)

        // Delete the edited main (simulate user deleting it from another device)
        server.markTrashed(nodeID: "edited")

        // Attempt revert again: it should throw editAlreadyTrashed
        do {
            try await performRevert()
            XCTFail("should throw editAlreadyTrashed")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .editAlreadyTrashed)
        }

        // Journal is still there: the user can abandon it
        try await makeOrchestrator().abandon(editedMain: editedMain)
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain), "journal should be abandoned")
    }

    /// Tier A gap 1: The server reports a stale duplicate row (active, no live node). The copy policy adopts it,
    /// but the revert guard `copyNotConfirmed` must reject it and abort before trash.
    func testStaleDuplicateAdoptionFailsWithCopyNotConfirmed() async throws {
        // Seed a stale row with the same content hash as the upload would produce
        server.seedStaleDuplicateRow(nodeID: "stale-node", contentHash: "ch-computed")

        do {
            _ = try await performRevert()
            XCTFail("should fail with copyNotConfirmed")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .copyNotConfirmed, "stale row should be rejected")
        }

        // Nothing trashed: the edited main stays active
        XCTAssertTrue(server.trashCalls().isEmpty)
        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Tier A gap 2: `trashReplaced` reports success but the server bug leaves the photo active. The guard
    /// `editNotTrashed` must fail and keep the journal for the next attempt.
    func testIneffectiveTrashFailsWithEditNotTrashed() async throws {
        server.makeTrashIneffective()

        do {
            _ = try await performRevert()
            XCTFail("should fail with editNotTrashed")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .editNotTrashed)
        }

        // The edited main is still active
        let active = try await server.activeUIDs(among: [editedMain])
        XCTAssertTrue(active.contains(editedMain), "edit should still be active")

        // Journal persists for retry
        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Tier A gap 3: Another device deletes the copy right after the album add but before trash. The person's next
    /// Revert detects the missing copy via `copyIsInactive`, re-makes it, and retries carry-over + trash.
    func testCopyDeletedBetweenAlbumAddAndTrashTriggersRerun() async throws {
        server.deleteCopyOnAlbumAdd()

        // First attempt: the fake deletes the copy after album add; ensureCopy completes, trash sees no copy
        do {
            _ = try await performRevert()
            XCTFail("should fail because copy vanished")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .trashingEdit)
        // The journal keeps the vanished copy UID. The person's next Revert detects the inactive copy and re-makes it.
        XCTAssertNotNil(journal.copyUID)
        XCTAssertTrue(server.trashCalls().isEmpty, "nothing is trashed while the copy is unconfirmed")

        let recoveredCopyUID = try await performRevert()

        XCTAssertNotNil(recoveredCopyUID)
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Tier A gap 4: While one revert runs, a second `revert` and an `abandon` of the same edited main both
    /// throw `editAlreadyRunning`. The running revert then completes normally and clears the journal.
    func testSecondRevertAndAbandonWhileRunningThrowEditAlreadyRunning() async throws {
        server.pauseNextUpload()

        let orchestrator = makeOrchestrator()
        let editedMainUID = editedMain
        let originalUID = original
        let firstRevert = Task {
            try await orchestrator.revert(
                editedMain: editedMainUID, original: originalUID, restoredName: "IMG_0001 (original).heic")
        }

        // Poll until the first revert is suspended inside its upload.
        for _ in 0..<500 where !server.uploadIsSuspended {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(server.uploadIsSuspended, "the first revert should be suspended in its upload")

        // The same orchestrator instance must reject the concurrent calls: `running` is per instance.
        do {
            _ = try await orchestrator.revert(
                editedMain: editedMain, original: original, restoredName: "IMG_0001 (original).heic")
            XCTFail("second revert should throw editAlreadyRunning")
        } catch EditedOriginalRevert.RevertError.editAlreadyRunning {
            // Expected
        }

        do {
            try await orchestrator.abandon(editedMain: editedMain)
            XCTFail("abandon should throw editAlreadyRunning")
        } catch EditedOriginalRevert.RevertError.editAlreadyRunning {
            // Expected
        }

        // The journal survives while the revert runs and is not abandoned.
        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain))

        server.releaseUpload()
        _ = try await firstRevert.value
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Tier A gap 5: a journal that lost its `restoredName` is no work for the resume, because it needs a new copy.
    /// The person's next Revert supplies the name again. The `ensureCopy` guard against a missing name has no
    /// direct test: no public call reaches it.
    func testEnsureCopyFailsWithoutRestoredName() async throws {
        // Create a journal manually at .trashingEdit without a copyUID and without restoredName
        let brokenJournal = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original", restoredName: nil, phase: .trashingEdit)
        try journalStore.save(brokenJournal)

        // The resume needs a copy for this journal, so it waits for the person and writes nothing.
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(server.operationLog().isEmpty)

        // Journal persists for manual recovery
        XCTAssertEqual(try journalStore.journal(forEditedMain: editedMain), brokenJournal)

        // The person's Revert supplies the name, makes the copy through the actor and finishes the journal.
        _ = try await performRevert()
        XCTAssertEqual(server.uploadNames(), ["IMG_0001 (original).heic"])
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Row 07: a journal that carries an empty restored name is no work for the resume, and the resume writes
    /// nothing. The person's next Revert replaces the name and finishes.
    func testResumeOfAJournalWithAnEmptyRestoredNameFailsBeforeAnyWrite() async throws {
        let namelessJournal = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original", restoredName: "", phase: .trashingEdit)
        try journalStore.save(namelessJournal)

        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertTrue(outcomes.isEmpty, "the resume needs a copy for this journal and waits for the person")

        XCTAssertTrue(server.uploadNames().isEmpty, "no upload may happen for an empty name")
        XCTAssertTrue(server.trashCalls().isEmpty, "no trash may happen for an empty name")
        XCTAssertEqual(try journalStore.journal(forEditedMain: editedMain), namelessJournal)

        // The person's Revert supplies the name, makes the copy through the actor and finishes the journal.
        _ = try await performRevert()
        XCTAssertEqual(server.uploadNames(), ["IMG_0001 (original).heic"])
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Tier A gap 6: `copyMustBeMadeAgain` returns true when the journal reached .trashingEdit without a
    /// copyUID, forcing a re-make even though the phase suggests the copy step completed.
    func testTrashingEditWithoutCopyUIDForcesRerun() async throws {
        // Journal at .trashingEdit but copyUID was never set (crash before save)
        let orphanJournal = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original", restoredName: "IMG_0001 (original).heic",
            phase: .trashingEdit)
        try journalStore.save(orphanJournal)

        // The person's Revert must re-make the copy and succeed
        let resultCopyUID = try await performRevert()
        XCTAssertFalse(resultCopyUID.nodeID.isEmpty)
        XCTAssertEqual(server.uploadNames().count, 1, "the copy is made exactly once")
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Row 02: `abandon` only removes a journal that still copies. A journal that reached the trash step is
    /// final: the user consented and the copy exists, so the trash step must still finish over `resumePending`.
    /// Removing that guard would drop an already-decided trash step and keep both versions as duplicates.
    func testAbandonKeepsAJournalThatReachedTheTrashStep() async throws {
        server.failTrashOnce()
        do {
            try await performRevert()
            XCTFail("trash should fail")
        } catch {}

        try await makeOrchestrator().abandon(editedMain: editedMain)

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .trashingEdit, "a trash-step journal is never abandoned")

        // The resume finishes the operation that abandon refused to drop.
        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNoThrow(try outcomes.first!.result.get())
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Row 05: a stale duplicate row must abort the revert before any carry-over write and before the trash.
    /// The phase stays `.copying`, and neither the favorite nor an album ever lands on the stale link.
    func testStaleDuplicateAdoptionWritesNothingAndKeepsTheCopyingPhase() async throws {
        server.seedStaleDuplicateRow(nodeID: "stale-node", contentHash: "ch-computed")

        do {
            _ = try await performRevert()
            XCTFail("should fail with copyNotConfirmed")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .copyNotConfirmed, "stale row should be rejected")
        }

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .copying, "nothing was carried over, so the phase never advances")
        XCTAssertEqual(
            server.operationLog().filter { $0.contains("stale-node") }, [],
            "no favorite or album write ever addresses the stale link")
        XCTAssertTrue(server.trashCalls().isEmpty)
    }

    /// Row 06: a carry-over failure after a committed copy. The retry keeps the journaled copy: one upload
    /// and one download in total, and the favorite is written once.
    func testCarryOverFailureRetriesWithoutASecondUpload() async throws {
        server.failAlbumAddOnce(albumID: "album1")

        do {
            _ = try await performRevert()
            XCTFail("album add should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .copying)
        XCTAssertNotNil(journal.copyUID, "the copy survived the failed carry-over")
        XCTAssertTrue(journal.favoriteDone, "the favorite write was journaled before the album failure")

        // The retry reuses the journaled copy.
        _ = try await performRevert()

        XCTAssertEqual(server.uploadNames().count, 1, "the copy is never uploaded twice")
        XCTAssertEqual(server.downloads(), 1, "the original is never downloaded twice")
        XCTAssertEqual(
            server.operationLog().filter { $0.starts(with: "favorite:") }.count, 1,
            "the favorite is written once")
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Row 07 (entry guard): an empty restored name fails before any write and leaves no journal behind.
    func testEmptyRestoredNameFailsBeforeAnyWrite() async throws {
        do {
            _ = try await makeOrchestrator().revert(
                editedMain: editedMain, original: original, restoredName: "")
            XCTFail("an empty name must fail")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .invalidRestoredName)
        }

        XCTAssertTrue(server.uploadNames().isEmpty)
        XCTAssertTrue(server.trashCalls().isEmpty)
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Row 10: an edited photo without a favorite tag must not become one through the revert.
    func testANonFavoriteEditStaysNonFavorite() async throws {
        server.setFavorites([])

        let copyUID = try await performRevert()

        XCTAssertEqual(
            server.operationLog().filter { $0.starts(with: "favorite:") }, [],
            "a revert never invents a favorite tag")
        XCTAssertFalse(server.favoriteWrites().contains(copyUID))
    }

    /// Row 11: a partial album failure. Each album is added exactly once across the attempts.
    func testPartialAlbumFailureOnRetryAddsEachAlbumExactlyOnce() async throws {
        server.failAlbumAddOnce(albumID: "album2")

        do {
            _ = try await performRevert()
            XCTFail("album add should fail")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.addedAlbumIDs, ["album1"], "the first album write is journaled")

        _ = try await performRevert()

        let albumAdds = server.albumAdds()
        for albumID in ["album1", "album2"] {
            XCTAssertEqual(
                albumAdds.filter { $0.album.albumID == albumID }.count, 1,
                "album \(albumID) must be addressed exactly once")
        }
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// Row 13: the trash commits on the server, then the call fails. The resume must not trash the
    /// already-trashed photo a second time; the guard that reads the main's state before the call is what
    /// stops the repeat.
    func testATrashThatCommitsBeforeAFailingCallResumesWithoutRetrashing() async throws {
        server.failAfterTrashCommitOnce()

        do {
            _ = try await performRevert()
            XCTFail("the trash call should fail after its commit")
        } catch {}

        let journal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(journal.phase, .trashingEdit)

        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNoThrow(try outcomes.first!.result.get())

        XCTAssertEqual(server.trashCalls().count, 1, "an already-trashed main is never trashed again")
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// F4: a "copy" that is a related file of another photo must not pass as a confirmed standalone copy.
    /// Without the standalone check, the trash step would remove the edited main and leave only a hidden
    /// related file, so the library would hold no visible photo of the shot.
    func testARelatedFileCopyIsRejectedAndTheEditIsKept() async throws {
        server.seedStandaloneCopy(nodeID: "copy-related", contentHash: "ch-computed")
        server.setMainPhoto(ofLinkID: "copy-related", toMainID: "other-main")

        let journal = EditedOriginalRevertJournal(
            editedMainUID: editedMain, originalLinkID: "original",
            restoredName: "IMG_0001 (original).heic",
            copyUID: PhotoUID(volumeID: "own", nodeID: "copy-related"),
            favoriteDone: true, phase: .trashingEdit)
        try journalStore.save(journal)

        // The automatic resume treats the rejected copy as a vanished one: it waits for the person.
        let resumed = try await makeOrchestrator().resumePending()
        XCTAssertTrue(resumed.isEmpty)
        XCTAssertEqual(try journalStore.journal(forEditedMain: editedMain), journal)

        do {
            _ = try await performRevert()
            XCTFail("a related file must not count as a confirmed copy")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .copyNotConfirmed)
        }
        XCTAssertTrue(server.trashCalls().isEmpty, "the edited main is never trashed")
        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain))
        // The run lowered the phase back to copying: the confirmed copy was rejected before any carry-over
        // write, so the person re-triggers the revert with the original. Pin the phase, because the trash
        // step would reject the same copy with the same error and otherwise hide a dropped copy check.
        let savedJournal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(savedJournal.phase, .copying)
        XCTAssertEqual(
            server.operationLog().filter { $0.starts(with: "favorite:") || $0.starts(with: "album:") }, [],
            "no carry-over write happens before the copy is confirmed")
    }

    /// Tier A: the standalone check reads the server twice, once after the copy and once after the
    /// carry-over. Another device can attach the copy to another main photo between those two reads. The
    /// copy is still active, but it is no longer a standalone main, so the trash step must fail closed.
    func testACopyAttachedToAnotherMainDuringTheCarryOverFailsTheTrashStep() async throws {
        server.attachTheCopyToAnotherMainOnAlbumAdd(mainID: "other-main")

        do {
            _ = try await performRevert()
            XCTFail("the trash step must reject the copy that stopped being a standalone main")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .copyNotConfirmed)
        }

        XCTAssertTrue(server.trashCalls().isEmpty, "the edited main is never trashed without a confirmed copy")
        let savedJournal = try XCTUnwrap(try journalStore.journal(forEditedMain: editedMain))
        XCTAssertEqual(savedJournal.phase, .trashingEdit)
    }

    /// F8: an interrupted revert keeps its original. A retry that names another related file would restore
    /// the wrong bytes, so it fails with `originalMismatch` and keeps the journal.
    func testRevertWithAMismatchedOriginalThrowsOriginalMismatch() async throws {
        server.failTrashOnce()
        do {
            try await performRevert()
            XCTFail("trash should fail")
        } catch {}

        let otherOriginal = PhotoUID(volumeID: "own", nodeID: "other-original")
        do {
            _ = try await makeOrchestrator().revert(
                editedMain: editedMain, original: otherOriginal, restoredName: "IMG_0001 (original).heic")
            XCTFail("a mismatched original must fail")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .originalMismatch)
        }

        XCTAssertNotNil(try journalStore.journal(forEditedMain: editedMain), "the journal is kept")
    }

    /// F9: one corrupt journal file must not stop the resume of every other revert. The corrupt journal is
    /// skipped; the healthy one finishes.
    func testACorruptJournalFileDoesNotStopOtherResumes() async throws {
        let journalDirectory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try Data("not a journal".utf8).write(
            to: journalDirectory.appendingPathComponent("corrupt.json"))

        // A healthy journal for another edited main, already in the trash step with a confirmed copy.
        server.seedStandaloneCopy(nodeID: "copy-x", contentHash: "ch-computed")
        let healthyJournal = EditedOriginalRevertJournal(
            editedMainUID: PhotoUID(volumeID: "own", nodeID: "edited-b"),
            originalLinkID: "original",
            restoredName: "IMG_B (original).heic",
            copyUID: PhotoUID(volumeID: "own", nodeID: "copy-x"),
            favoriteDone: true,
            phase: .trashingEdit)
        try journalStore.save(healthyJournal)

        let outcomes = try await makeOrchestrator().resumePending()
        XCTAssertEqual(outcomes.count, 1, "the corrupt journal is skipped, not thrown")
        XCTAssertNoThrow(try outcomes.first!.result.get())
        XCTAssertNil(try journalStore.journal(forEditedMain: healthyJournal.editedMainUID))
    }

    /// F15: the trash step must fail closed when the server answer for the copy link carries no Photo role
    /// data. `isActiveMain` alone accepts such a link, because the answer can report it active with a nil
    /// main photo; the journal's confirmed copy would be unverified while the trash step runs.
    func testATrashStepWithoutExplicitPhotoRoleDataFailsClosed() async throws {
        server.seedStandaloneCopy(nodeID: "copy-x", contentHash: "ch-computed")
        server.withholdExplicitPhotoState(nodeID: "copy-x")
        try journalStore.save(
            EditedOriginalRevertJournal(
                editedMainUID: editedMain, originalLinkID: original.nodeID,
                restoredName: "IMG_0001 (original).heic",
                copyUID: server.uid("copy-x"), favoriteDone: true, phase: .trashingEdit))

        do {
            _ = try await makeOrchestrator().revert(
                editedMain: editedMain, original: original, restoredName: "IMG_0001 (original).heic")
            XCTFail("a link without Photo role data must not confirm the copy")
        } catch let error as EditedOriginalRevert.RevertError {
            XCTAssertEqual(error, .copyNotConfirmed)
        }
        XCTAssertTrue(server.trashCalls().isEmpty, "the edited main is never trashed on an unconfirmed copy")
    }

    /// F16: a crash after the trash leaves the journal in `.repointingDevice`. A resume must finish the
    /// device step even when the person deleted the restored copy meanwhile: the copy re-check must not
    /// lower the phase back to copying, or the resume would report `editAlreadyTrashed`, drop the
    /// device-side step, and remove the journal as failed.
    func testAResumeAfterTheTrashKeepsTheRepointingPhaseWhenTheCopyWasDeleted() async throws {
        server.seedStandaloneCopy(nodeID: "copy-1", contentHash: "ch-computed")
        server.markTrashed(nodeID: "copy-1")
        server.markTrashed(nodeID: "edited")
        try journalStore.save(
            EditedOriginalRevertJournal(
                editedMainUID: editedMain, originalLinkID: original.nodeID,
                restoredName: "IMG_0001 (original).heic",
                copyUID: server.uid("copy-1"), favoriteDone: true, addedAlbumIDs: ["album1", "album2"],
                phase: .repointingDevice))

        let outcomes = try await makeOrchestrator().resumePending()

        XCTAssertEqual(outcomes.count, 1, "the repointing journal is served by the resume, not skipped")
        let outcome = try XCTUnwrap(outcomes.first, "the resume must report the repointing journal")
        XCTAssertNoThrow(try outcome.result.get())
        XCTAssertNil(
            try journalStore.journal(forEditedMain: editedMain),
            "the device step finished and removed the journal")
        XCTAssertTrue(server.uploadNames().isEmpty, "the copy is never made again after the trash")
    }

    /// F17 row `:156`: a resume must skip an edit whose revert another task is running right now. The
    /// journal survives; this resume reports no outcome for it, so the person's running revert is not
    /// reported as failed. This test pins the skip that a shared guard previously hid.
    func testAResumeSkipsAnEditWhoseRevertRunsRightNowAndKeepsItsJournal() async throws {
        let orchestrator = makeOrchestrator()
        let editedMainUID = editedMain
        let originalUID = original
        server.pauseNextTrash()
        let trashSuspended = XCTestExpectation(description: "the first revert reaches its trash call")
        server.onTrashSuspended = { trashSuspended.fulfill() }
        let firstRevert = Task {
            try await orchestrator.revert(
                editedMain: editedMainUID, original: originalUID, restoredName: "IMG_0001 (original).heic")
        }

        // A revert that fails before its trash call must fail this test, not hang the whole suite, so the
        // wait has a time limit.
        await fulfillment(of: [trashSuspended], timeout: 10)
        XCTAssertTrue(server.trashIsSuspended, "the first revert should be suspended in its trash call")

        let outcomes = try await orchestrator.resumePending()
        XCTAssertTrue(outcomes.isEmpty, "a resume must not report the busy edit, and must not run it")
        XCTAssertNotNil(
            try journalStore.journal(forEditedMain: editedMain),
            "the busy edit keeps its journal for the next resume")

        server.releaseTrash()
        _ = try await firstRevert.value
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain))
    }

    /// F18: an undecodable journal is not a dead end for its photo. `revert` treats it as missing and starts
    /// a fresh run over the file.
    func testRevertStartsAFreshRunOverAnUndecodableJournal() async throws {
        try corruptTheJournalFile()
        XCTAssertThrowsError(
            try journalStore.journal(forEditedMain: editedMain), "the file is undecodable, not absent")

        let restoredName = "IMG_0001 (original).heic"
        _ = try await makeOrchestrator().revert(editedMain: editedMain, original: original, restoredName: restoredName)

        XCTAssertEqual(server.uploadNames(), [restoredName], "the fresh run makes the copy again")
        XCTAssertTrue(server.trashCalls().contains { $0.contains(editedMain) })
        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain), "the finished run leaves no journal")
    }

    /// F18: `abandon` removes an undecodable journal instead of leaving the photo a dead end.
    func testAbandonRemovesAnUndecodableJournal() async throws {
        try corruptTheJournalFile()
        XCTAssertThrowsError(
            try journalStore.journal(forEditedMain: editedMain), "the file is undecodable, not absent")

        try await makeOrchestrator().abandon(editedMain: editedMain)

        XCTAssertNil(try journalStore.journal(forEditedMain: editedMain), "abandon removed the file")
        XCTAssertEqual(try journalStore.pendingJournals().count, 0)
    }

    /// F19: a journal path that exists but cannot be read as file data throws out of `revert` and
    /// `abandon`. A fresh run would replace the file and lose the recorded phase and copy, and `abandon`
    /// would remove a journal whose phase is unknown.
    func testRevertAndAbandonThrowOverAJournalFileThatCannotBeRead() async throws {
        let unreadable = try makeTheJournalFileUnreadable()

        do {
            _ = try await makeOrchestrator().revert(
                editedMain: editedMain, original: original, restoredName: "IMG_0001 (original).heic")
            XCTFail("revert must rethrow the read error instead of starting a fresh run")
        } catch {}
        do {
            try await makeOrchestrator().abandon(editedMain: editedMain)
            XCTFail("abandon must rethrow the read error instead of removing the file")
        } catch {}

        XCTAssertTrue(server.uploadNames().isEmpty, "no fresh run replaced the unreadable journal")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unreadable.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue, "the unreadable journal stays until its read error clears")
    }

    /// Saves a journal for `editedMain` and then corrupts its file, as a truncated write would.
    private func corruptTheJournalFile() throws {
        try journalStore.save(.init(editedMainUID: editedMain, originalLinkID: original.nodeID))
        let directory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
        try Data("not a journal".utf8).write(to: file)
    }

    /// F19: removes the read permission of the journal file of `editedMain`, a path that exists but
    /// cannot be read as file data, as an I/O error or a permission change would. The file stays a
    /// regular file, so a fresh run would replace it: only the rethrown read error keeps it in place.
    /// Returns the unreadable path.
    private func makeTheJournalFileUnreadable() throws -> URL {
        try journalStore.save(.init(editedMainUID: editedMain, originalLinkID: original.nodeID))
        let directory = tempDir.appendingPathComponent(
            EditedOriginalRevertJournalFileStore.directoryName, isDirectory: true)
        let file = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        return file
    }
}

// MARK: Fake Remote

/// A journal store that changes the disk right after `pendingJournals` returned its list, like a tap that finishes
/// while a resume works on an earlier journal.
private final class RacingJournalStore: EditedOriginalRevertJournalStore, @unchecked Sendable {
    private let base: EditedOriginalRevertJournalFileStore
    private let afterPendingRead: @Sendable () throws -> Void

    init(base: EditedOriginalRevertJournalFileStore, afterPendingRead: @escaping @Sendable () throws -> Void) {
        self.base = base
        self.afterPendingRead = afterPendingRead
    }

    func journal(forEditedMain mainUID: PhotoUID) throws -> EditedOriginalRevertJournal? {
        try base.journal(forEditedMain: mainUID)
    }
    func decodableJournal(forEditedMain mainUID: PhotoUID) throws -> EditedOriginalRevertJournal? {
        try base.decodableJournal(forEditedMain: mainUID)
    }
    func save(_ journal: EditedOriginalRevertJournal) throws { try base.save(journal) }
    func remove(forEditedMain mainUID: PhotoUID) throws { try base.remove(forEditedMain: mainUID) }
    func pendingJournals() throws -> [EditedOriginalRevertJournal] {
        let snapshot = try base.pendingJournals()
        try afterPendingRead()
        return snapshot
    }
}

private final class FakeRevertRemote: EditedOriginalRevertRemote, SeriesAlbumCarryOver, PhotoUploading,
    UploadDuplicateChecking, @unchecked Sendable
{
    private let lock = NSLock()
    private let ownVolumeID: String
    private var nodes:
        [String: (
            name: String, state: RemotePhotoDuplicate.LinkState, clientUID: String?, contentHash: String?
        )] = [
            "original": ("original.heic", .active, nil, "ch-original"),
            "edited": ("edited.heic", .active, nil, "ch-edited"),
        ]
    private var uploads: [(name: String, uid: PhotoUID)] = []
    private var _trashCalls: [[PhotoUID]] = []
    private var _favorites: Set<String> = ["edited"]
    private var _albumMemberships: [String: Set<String>] = ["album1": ["edited"], "album2": ["edited"]]
    private var _albumAdds: [(uid: PhotoUID, album: SeriesAlbumReference)] = []
    private var _operationLog: [String] = []
    private var uploadFailures = 0
    private var trashFailures = 0
    private var postCommitTrashFailures = 0
    /// Links whose state answer carries no Photo role data.
    private var _withheldRoleNodeIDs: Set<String> = []
    /// Attaches the next album-added photo to this main, as another device would.
    private var _attachAlbumAddToMainID: String?
    /// Suspends the next `trashReplaced` call until `releaseTrash()` runs, so a test can interleave a
    /// `resumePending` against a revert that is in flight in the trash step.
    private var _pauseNextTrash = false
    private var _trashGate: CheckedContinuation<Void, Never>? = nil
    /// True when `releaseTrash()` ran before the paused trash call installed its continuation, so the
    /// call must resume itself instead of parking in a gate nobody holds anymore.
    private var _trashReleaseRequested = false
    /// Album IDs whose next add fails once, for carry-over failure tests.
    private var failingAlbumAdds: Set<String> = []
    /// Names of files this fake downloaded, so a test can pin the download count.
    private var downloadCount = 0
    private var foreignDraftClientUID: String?
    /// Duplicate rows that the server reports although no live node backs them.
    private var staleRows: [RemotePhotoDuplicate] = []
    /// When true, `trashReplaced` reports success without moving the photo out of the library.
    private var trashIneffective = false
    /// When true, the next album add deletes the added photo, as another device would.
    private var deleteOnAlbumAdd = false
    private var _invalidatedCachedRemoteState = false
    private var _uploadGate: CheckedContinuation<Void, Never>?
    private var _uploadBlocked = false
    private let admission = UploadNetworkAdmission()

    /// Content hash that the backend records for an uploaded node. The upload dedupe path compares it with
    /// `contentHash(forSHA1Hex:)`, so a later attempt can adopt a copy that a crashed session already committed.
    private let contentHashForUploaded = "ch-computed"

    /// Link IDs whose `linkVisibility` answer names a main photo, so the node is a related file, not a
    /// standalone photo.
    private var relatedFileMains: [String: String] = [:]

    init(ownVolumeID: String) {
        self.ownVolumeID = ownVolumeID
    }

    func operationLog() -> [String] { lock.withLock { _operationLog } }

    /// Marks `linkID` as a related file of `mainLinkID`, so `linkVisibility` reports the node as owned by
    /// another photo.
    func setMainPhoto(ofLinkID linkID: String, toMainID mainLinkID: String) {
        lock.withLock { relatedFileMains[linkID] = mainLinkID }
    }

    /// Seeds a standalone active photo that an earlier session committed but never journaled.
    func seedStandaloneCopy(nodeID: String, contentHash: String) {
        lock.withLock { nodes[nodeID] = ("IMG_0001 (original).heic", .active, nil, contentHash) }
    }

    /// Seeds a duplicate row that the server reports as active, although no live photo backs it: the row is
    /// stale. The copy policy adopts the row, and the revert must then reject the copy as not confirmed.
    func seedStaleDuplicateRow(nodeID: String, contentHash: String) {
        lock.withLock {
            staleRows.append(.init(nameHash: "nh", contentHash: contentHash, linkState: .active, linkID: nodeID))
        }
    }

    /// Makes `trashReplaced` report success without moving the photo out of the library, as a server bug would.
    func makeTrashIneffective() { lock.withLock { trashIneffective = true } }

    /// Deletes the copy after the first album add, as another device would between confirmation and trash.
    func deleteCopyOnAlbumAdd() { lock.withLock { deleteOnAlbumAdd = true } }

    /// Suspends the next upload until `releaseUpload()` runs, so a test can run code while a revert is
    /// in flight. The upload resumes afterwards and completes normally.
    func pauseNextUpload() { lock.withLock { _uploadBlocked = true } }

    /// Ends the pause of a suspended upload. Harmless when no upload is suspended.
    func releaseUpload() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _uploadBlocked = false
            let gate = _uploadGate
            _uploadGate = nil
            return gate
        }
        continuation?.resume()
    }

    /// True once the paused upload is actually suspended, so the test knows the revert is in flight.
    var uploadIsSuspended: Bool { lock.withLock { _uploadGate != nil } }

    /// Moves a node out of the active state, as the person or another device would.
    func markTrashed(nodeID: String) {
        lock.withLock { nodes[nodeID]?.state = .trashed }
    }

    /// The state answer of this link carries no Photo role data, as `DriveSession` reports when a revision's
    /// Photo role is missing: the link can be active, but its role data is not trustworthy.
    func withholdExplicitPhotoState(nodeID: String) {
        lock.withLock { _ = _withheldRoleNodeIDs.insert(nodeID) }
    }

    func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: ownVolumeID, nodeID: id) }

    func makeCopier(tempDirectory: URL) -> RelatedPhotoCopier {
        RelatedPhotoCopier(
            uploader: self, duplicateChecker: self, provider: self,
            tempDirectory: tempDirectory, currentClientUID: "test")
    }

    func setForeignDraft(clientUID: String) {
        lock.withLock { foreignDraftClientUID = clientUID }
    }

    func failUploadOnce() { lock.withLock { uploadFailures = 1 } }
    func failTrashOnce() { lock.withLock { trashFailures = 1 } }

    /// Makes the next `trashReplaced` throw after it has already moved the photos to the trash, as a server
    /// would when the connection drops after the commit.
    func failAfterTrashCommitOnce() { lock.withLock { postCommitTrashFailures = 1 } }

    /// Makes the next add to `albumID` fail once.
    func failAlbumAddOnce(albumID: String) { lock.withLock { _ = failingAlbumAdds.insert(albumID) } }

    /// Attaches the copy of the next album add to another main photo, as another device would between the
    /// carry-over and the trash step. The copy stays active, but it is no longer a standalone main.
    func attachTheCopyToAnotherMainOnAlbumAdd(mainID: String) {
        lock.withLock { _attachAlbumAddToMainID = mainID }
    }

    /// Suspends the next `trashReplaced` call until `releaseTrash()` runs, so a test can run a
    /// `resumePending` while a revert is in flight in the trash step.
    func pauseNextTrash() { lock.withLock { _pauseNextTrash = true } }

    /// Ends the pause of a suspended trash call. Harmless when no trash call is suspended, and safe
    /// before the call installed its continuation: the next call resumes itself.
    func releaseTrash() {
        lock.withLock {
            if _pauseNextTrash { _trashReleaseRequested = true }
            _pauseNextTrash = false
            if let gate = _trashGate {
                _trashGate = nil
                gate.resume()
            }
        }
    }

    /// True once the paused trash call is actually suspended, so the test knows the revert is in flight.
    var trashIsSuspended: Bool { lock.withLock { _trashGate != nil } }

    /// Called once, when the paused trash call is actually suspended, so a test can await the suspension
    /// through an expectation with a time limit instead of a wait without one.
    var onTrashSuspended: (@Sendable () -> Void)?

    /// Replaces the set of favorites, so a test can start without a favorite tag on the edited photo.
    func setFavorites(_ nodeIDs: Set<String>) { lock.withLock { _favorites = nodeIDs } }

    /// Number of source downloads so far.
    func downloads() -> Int { lock.withLock { downloadCount } }

    func uploadNames() -> [String] { lock.withLock { uploads.map(\.name) } }
    func trashCalls() -> [[PhotoUID]] { lock.withLock { _trashCalls } }
    func favoriteWrites() -> Set<PhotoUID> { lock.withLock { Set(_favorites.compactMap { uid($0) }) } }
    func albumAdds() -> [(uid: PhotoUID, album: SeriesAlbumReference)] { lock.withLock { _albumAdds } }
    func invalidatedCachedRemoteState() -> Bool { lock.withLock { _invalidatedCachedRemoteState } }

    // PhotoCarryOverRemote

    func ownPhotosVolumeID() async throws -> String { ownVolumeID }

    func activeUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock {
            Set(uids.filter { nodes[$0.nodeID]?.state == .active })
        }
    }

    func favoriteUIDs(among uids: [PhotoUID]) async throws -> Set<PhotoUID> {
        lock.withLock { Set(uids.filter { _favorites.contains($0.nodeID) }) }
    }

    func markFavorite(_ uids: [PhotoUID]) async throws {
        lock.withLock {
            for uid in uids {
                _favorites.insert(uid.nodeID)
                _operationLog.append("favorite:\(uid.nodeID)")
            }
        }
    }

    // EditReplacementRemote

    func trashReplaced(_ uids: [PhotoUID]) async throws {
        // The pause applies to one trash call: a run that reaches this point again (a bug) fails
        // downstream instead of parking a second continuation forever. `releaseTrash()` can run between
        // the check above and this installation: the request is then answered here, so the gate is
        // never left holding a continuation nobody will resume.
        if lock.withLock({ _pauseNextTrash }) {
            await withCheckedContinuation { continuation in
                let park: Bool = lock.withLock { () -> Bool in
                    _pauseNextTrash = false
                    if _trashReleaseRequested {
                        _trashReleaseRequested = false
                        return false
                    }
                    _trashGate = continuation
                    return true
                }
                if park {
                    onTrashSuspended?()
                } else {
                    continuation.resume()
                }
            }
        }
        try lock.withLock {
            if trashFailures > 0 {
                trashFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "trash unavailable")
            }
            _trashCalls.append(uids)
            for uid in uids {
                if !trashIneffective { nodes[uid.nodeID]?.state = .trashed }
                _operationLog.append("trash:\(uid.nodeID)")
            }
            if postCommitTrashFailures > 0 {
                postCommitTrashFailures -= 1
                throw UploadError.retryableBackend(
                    code: 503, message: "connection dropped after the trash commit")
            }
        }
    }

    // OriginalFileProvider

    func originalSource(for uid: PhotoUID) async throws -> EditedOriginalSource {
        lock.withLock {
            let node = nodes[uid.nodeID]!
            return EditedOriginalSource(
                filename: node.name, mediaType: "image/heic",
                captureTime: Date(), modificationDate: Date(), additionalMetadata: [])
        }
    }

    func writeOriginal(
        for uid: PhotoUID, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let data = Data("original-bytes".utf8)
        try data.write(to: destination)
        lock.withLock { downloadCount += 1 }
        onProgress(1)
    }

    // PhotoUploading

    var capabilities: UploadBackendCapabilities { .sdkUploader }

    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await admission.reserve(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }

    func upload(
        _ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        // A second upload that arrives while one is parked would overwrite the parked continuation and hang
        // the run forever. Fail it instead of crashing the process, so the rest of the suite keeps running.
        if lock.withLock({ _uploadBlocked && _uploadGate != nil }) {
            throw UploadError.retryableBackend(
                code: 509, message: "a second upload arrived while one was already suspended")
        }
        // A paused upload suspends here so a test can interleave other calls against a revert in flight.
        if lock.withLock({ _uploadBlocked }) {
            await withCheckedContinuation { continuation in
                lock.withLock { _uploadGate = continuation }
            }
        }
        return try lock.withLock {
            if uploadFailures > 0 {
                uploadFailures -= 1
                throw UploadError.retryableBackend(code: 503, message: "upload unavailable")
            }
            let uid = PhotoUID(volumeID: ownVolumeID, nodeID: "copy-\(uploads.count)")
            uploads.append((request.name, uid))
            nodes[uid.nodeID] = (request.name, .active, nil, contentHashForUploaded)
            _operationLog.append("upload:\(uid.nodeID)")
            onProgress(.init(phase: .uploading, fraction: 1))
            return uid
        }
    }

    func cancel(token: UUID) async {}

    // UploadDuplicateChecking

    func nameHash(forCorrectedName _: String) async throws -> String { "nh" }
    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] { names.map { _ in "nh" } }
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String { "ch-computed" }
    func hashKeyEpoch() async throws -> String { "epoch" }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        lock.withLock {
            var result: [RemotePhotoDuplicate] = []
            // Insert foreign draft if set
            if let fd = foreignDraftClientUID {
                result.append(
                    .init(nameHash: "nh", contentHash: nil, linkState: .draft, linkID: "draft-foreign", clientUID: fd))
            }
            // Append all node rows
            for (nodeID, (_, state, clientUID, contentHash)) in nodes {
                result.append(
                    .init(
                        nameHash: "nh", contentHash: contentHash, linkState: state, linkID: nodeID, clientUID: clientUID
                    ))
            }
            // Stale rows describe photos that no live node backs.
            result.append(contentsOf: staleRows)
            return result
        }
    }

    func relatedPhotoLinkIDs(ofMainLinkID mainLinkID: String) async throws -> Set<String> {
        lock.withLock {
            guard mainLinkID == "edited" else { return [] }
            return ["original"]
        }
    }

    func recordUploaded(contentHash: String, remoteLinkID: String) async {}

    func invalidateCachedRemoteState() async {
        lock.withLock { _invalidatedCachedRemoteState = true }
    }

    func linkVisibility(of linkIDs: [String]) async throws -> [String: RemoteLinkVisibility] {
        lock.withLock {
            var result: [String: RemoteLinkVisibility] = [:]
            for id in linkIDs {
                if let node = nodes[id] {
                    let withheld = _withheldRoleNodeIDs.contains(id)
                    result[id] = RemoteLinkVisibility(
                        isActive: node.state == .active,
                        mainPhotoLinkID: withheld ? nil : relatedFileMains[id],
                        hasExplicitPhotoState: !withheld)
                }
            }
            return result
        }
    }

    // SeriesAlbumCarryOver

    func albums(containing uid: PhotoUID) async throws -> [SeriesAlbumReference] {
        try await albums(containing: [uid])[uid] ?? []
    }

    func albums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        lock.withLock {
            var result: [PhotoUID: [SeriesAlbumReference]] = [:]
            for uid in uids {
                var refs: [SeriesAlbumReference] = []
                for (albumID, members) in _albumMemberships.sorted(by: { $0.key < $1.key }) {
                    if members.contains(uid.nodeID) {
                        refs.append(SeriesAlbumReference(volumeID: ownVolumeID, albumID: albumID))
                    }
                }
                result[uid] = refs
            }
            return result
        }
    }

    func currentAlbums(containing uids: [PhotoUID]) async throws -> [PhotoUID: [SeriesAlbumReference]] {
        try await albums(containing: uids)
    }

    func addPhotos(_ uids: [PhotoUID], toOwnAlbum albumID: String) async throws {
        try lock.withLock {
            if failingAlbumAdds.contains(albumID) {
                failingAlbumAdds.remove(albumID)
                throw UploadError.retryableBackend(code: 503, message: "album add unavailable")
            }
            for uid in uids {
                if _albumMemberships[albumID] == nil {
                    _albumMemberships[albumID] = []
                }
                _albumMemberships[albumID]?.insert(uid.nodeID)
                _albumAdds.append((uid, SeriesAlbumReference(volumeID: ownVolumeID, albumID: albumID)))
                _operationLog.append("album:\(albumID):\(uid.nodeID)")
            }
            if deleteOnAlbumAdd {
                deleteOnAlbumAdd = false
                for uid in uids { nodes[uid.nodeID] = nil }
            }
            if let attachMainID = _attachAlbumAddToMainID {
                _attachAlbumAddToMainID = nil
                for uid in uids { relatedFileMains[uid.nodeID] = attachMainID }
            }
        }
    }

    func ownAlbumCovers() async throws -> [String: String] { [:] }
    func setCover(_ uid: PhotoUID, ofOwnAlbum albumID: String) async throws {}
}
