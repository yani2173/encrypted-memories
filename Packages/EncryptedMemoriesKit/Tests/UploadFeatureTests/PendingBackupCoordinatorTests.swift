import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class PendingBackupCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var store: PendingBackupManifestStore!
    private var recorder: PendingBackupEventRecorder!
    private var metadata: FakePendingMetadata!
    private var effects: FakePendingEffects!
    private var coordinator: PendingBackupCoordinator!
    private let date = Date(timeIntervalSince1970: 1_750_000_000.75)
    private let revision = UploadBackupRevision(rawValue: 9)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-coordinator-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let storeURL = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
        metadata = FakePendingMetadata()
        effects = FakePendingEffects()
        coordinator = makeCoordinator()
    }

    override func tearDown() async throws {
        await coordinator.close()
        recorder.finish()
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        queue.close()
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator(
        checkmarkDuration: Duration = .seconds(60),
        uncheckedAdmissionLimit: Int = 64,
        replacementJournal: (any EditReplacementJournaling)? = nil,
        identities: (any UploadIdentityStore)? = nil,
        relations: (any UploadDuplicateChecking)? = nil,
        sourceKind: UploadSourceIdentity.Kind = .photoLibraryAsset,
        membershipInterval: Duration = .zero,
        libraryChangeDelay: Duration = .zero,
        unreadableRetryDelay: Duration = .seconds(60),
        unreadableRetryLimit: Duration = .seconds(30 * 60),
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> PendingBackupCoordinator {
        PendingBackupCoordinator(
            store: store,
            queues: [sourceKind: queue],
            metadataProvider: metadata,
            effects: effects,
            recorder: recorder,
            replacementJournal: replacementJournal,
            identities: identities,
            relations: relations,
            configuration: .init(
                membershipInterval: membershipInterval,
                progressInterval: .milliseconds(1),
                doneLinger: .milliseconds(20),
                checkmarkDuration: checkmarkDuration,
                uncheckedAdmissionLimit: uncheckedAdmissionLimit,
                libraryChangeDelay: libraryChangeDelay,
                unreadableRetryDelay: unreadableRetryDelay,
                unreadableRetryLimit: unreadableRetryLimit
            ),
            now: { [date] in date },
            sleep: sleep
        )
    }

    private func source(_ id: String) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary)
    }

    private func key(_ id: String) -> PendingSourceKey {
        PendingSourceKey(kind: .photoLibraryAsset, identifier: id)
    }

    private func enqueue(_ id: String, state: UploadBackupSyncQueueState, captureOffset: TimeInterval = 0) {
        metadata.set(
            key(id),
            PendingPresentationMetadata(
                captureTime: date.addingTimeInterval(captureOffset),
                mediaType: "image/heic",
                displayName: "\(id).heic"
            ))
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id),
                    revision: revision,
                    originalFilename: "\(id).heic",
                    state: state,
                    updatedAt: date
                )))
    }

    private func setState(_ id: String, _ state: UploadBackupSyncQueueState) {
        XCTAssertTrue(
            queue.updateState(
                source: source(id), revision: revision, state: state, attempts: nil, lastError: nil, updatedAt: date))
    }

    @discardableResult
    private func waitForSnapshot(
        _ description: String,
        _ predicate: @escaping @Sendable (PendingBackupSnapshot) -> Bool
    ) async -> PendingBackupSnapshot {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let snapshot = await coordinator.currentSnapshot()
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(predicate(snapshot), description)
        return snapshot
    }

    private func tileIDs(_ snapshot: PendingBackupSnapshot) -> [String] {
        snapshot.tiles.map(\.key.identifier)
    }

    func testDismissedMissingSourceRecheckStaysHiddenThroughIncrementalReloadAndRelaunch() async throws {
        enqueue("acknowledged", state: .discovered)
        await coordinator.start()
        _ = await waitForSnapshot("the ordinary unchecked source starts visible") { $0.tiles.count == 1 }
        let reason = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        XCTAssertTrue(
            queue.updateState(
                source: source("acknowledged"), revision: revision, state: .discovered,
                attempts: nil, lastError: reason, updatedAt: date))
        _ = await waitForSnapshot("the incremental marker projection hides the tile") { $0.tiles.isEmpty }
        let pending = try XCTUnwrap(queue.entry(for: source("acknowledged"), revision: revision))
        await coordinator.close()
        coordinator = makeCoordinator()
        await coordinator.start()
        let relaunched = await coordinator.currentSnapshot()
        XCTAssertTrue(relaunched.tiles.isEmpty, "The complete reload must preserve the dismissal")
        var ordinary = pending
        ordinary.lastError = nil
        ordinary.state = .queuedForUpload
        XCTAssertTrue(queue.upsert(ordinary))
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        var released = pending
        released.state = .checking
        XCTAssertEqual(queue.claimRunnable(limit: 1, claimedAt: date).count, 1)
        released.lastError = nil
        XCTAssertEqual(
            queue.updateDismissedSourceRecheck(released, matchingState: .checking, matchingLastError: reason), true)
        let visible = await waitForSnapshot("the proof release permits exactly one tile") { $0.tiles.count == 1 }
        XCTAssertEqual(tileIDs(visible), ["acknowledged"])
    }

    // MARK: - Edits of backed-up photos

    private let edit = UploadBackupRevision(rawValue: 10)
    private let earlier = PhotoUID(volumeID: "vol", nodeID: "link-earlier")

    private func enqueueEdit(_ id: String, state: UploadBackupSyncQueueState) {
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id), revision: edit, originalFilename: "\(id).heic", state: state, updatedAt: date)))
    }

    private func makeJournalCoordinator(
        identities: (any UploadIdentityStore)? = nil,
        relations: (any UploadDuplicateChecking)? = nil
    ) throws -> EditReplacementJournalFileStore {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        coordinator = makeCoordinator(replacementJournal: journal, identities: identities, relations: relations)
        return journal
    }

    func testChangedWatchedFileShowsWithUploadEvidenceAndAfterAnUploadFailure() async throws {
        await coordinator.close()
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        coordinator = makeCoordinator(replacementJournal: journal, sourceKind: .fileURL)
        let source = UploadSourceIdentity(kind: .fileURL, identifier: "watched-photo", resource: .primary)
        let key = PendingSourceKey(source)
        metadata.set(
            key, PendingPresentationMetadata(captureTime: date, mediaType: "image/heic", displayName: "photo.heic"))
        for (revision, state) in [(revision, UploadBackupSyncQueueState.completed), (edit, .discovered)] {
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source, revision: revision, originalFilename: "photo.heic", state: state,
                        updatedAt: date)))
        }
        await coordinator.start()
        recorder.recordUploadEvidence(source: source, revision: edit, replaces: [earlier])
        XCTAssertTrue(
            queue.updateState(
                source: source, revision: edit, state: .uploading, attempts: nil, lastError: nil, updatedAt: date))
        let uploading = await waitForSnapshot("the changed watched file shows after its check") { $0.tiles.count == 1 }
        XCTAssertEqual(uploading.tiles.first?.key, key)
        XCTAssertEqual(uploading.tiles.first?.replaces, [])
        let membership = uploading.membershipRevision

        XCTAssertTrue(
            queue.updateState(
                source: source, revision: edit, state: .failedPermanent, attempts: nil, lastError: nil, updatedAt: date)
        )
        let failed = await waitForSnapshot("the watched file stays visible after an upload failure") {
            $0.membershipRevision > membership && $0.tiles.first?.badge == .attention
        }
        XCTAssertEqual(failed.tiles.first?.key, key)
        XCTAssertEqual(failed.tiles.first?.replaces, [])
    }

    func testManyReplacementEventsShareOneMembershipPublication() async throws {
        await coordinator.close()
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        let gate = PendingMembershipSleepGate()
        coordinator = makeCoordinator(
            uncheckedAdmissionLimit: 0, replacementJournal: journal, membershipInterval: .seconds(60),
            sleep: { _ in await gate.wait() })
        for index in 0..<40 { enqueue("edit-\(index)", state: .discovered) }
        await coordinator.start()
        let initial = await coordinator.currentSnapshot()
        for index in 0..<40 {
            let id = "edit-\(index)"
            try journal.addSuperseded(earlier, for: source(id))
            recorder.recordUploadEvidence(source: source(id), revision: revision, replaces: [earlier])
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(0..<40).allSatisfy({ metadata.wasRequested(key("edit-\($0)")) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue((0..<40).allSatisfy { metadata.wasRequested(key("edit-\($0)")) })
        let beforeTimer = await coordinator.currentSnapshot()
        XCTAssertEqual(beforeTimer.membershipRevision, initial.membershipRevision, "no event bypasses the throttle")
        await gate.release()
        let burst = await waitForSnapshot("all edits publish together") { $0.tiles.count == 40 }
        XCTAssertEqual(burst.membershipRevision - initial.membershipRevision, 1, "count actual membership publications")
    }

    func testRebuiltCoordinatorKeepsAnUnacknowledgedSettledReplacement() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        try journal.addSuperseded(earlier, for: source("p"))
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        try journal.settle([earlier.nodeID], related: [], trashed: true, for: source("p"))
        recorder.recordHandoff(
            source: source("p"), revision: edit, remote: PhotoUID(volumeID: "vol", nodeID: "edit"), kind: .uploaded)
        XCTAssertTrue(
            queue.updateState(
                source: source("p"), revision: edit, state: .completed, attempts: nil, lastError: nil, updatedAt: date))
        await coordinator.start()
        await waitForSnapshot("the first coordinator consumed the events") { $0.tiles.first?.isSettled == true }
        await coordinator.close()
        recorder.finish()
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), replacementJournal: journal,
            now: { [date] in date })
        coordinator = makeCoordinator(replacementJournal: journal)
        await coordinator.start()
        let rebuilt = await coordinator.currentSnapshot()
        XCTAssertEqual(rebuilt.tiles.first?.replaces, [earlier])
        XCTAssertEqual(rebuilt.tiles.first?.revision, edit)
        XCTAssertEqual(store.unacknowledgedHandoffs().count, 1)
    }

    func testLargeQueuedLoadDoesNotReadIndividualSourcesOrTheirJournals() async {
        await coordinator.close()
        let queue = CountingPendingQueue(count: 5_000, date: date)
        let journal = CountingPendingJournal()
        coordinator = PendingBackupCoordinator(
            store: store, queues: [.photoLibraryAsset: queue], metadataProvider: metadata, effects: effects,
            recorder: nil, replacementJournal: journal)
        await coordinator.start()
        XCTAssertEqual(queue.sourceReads, 0)
        XCTAssertEqual(queue.aggregateReads, 1)
        XCTAssertEqual(journal.reads, 0)
    }

    func testWatchedFolderResetDoesNotRepeatPhotoLibraryAggregateRead() async throws {
        await coordinator.close()
        let library = CountingPendingQueue(count: 0, date: date)
        let folder = CountingPendingQueue(count: 0, date: date)
        coordinator = PendingBackupCoordinator(
            store: store, queues: [.photoLibraryAsset: library, .fileURL: folder],
            metadataProvider: metadata, effects: effects, recorder: nil)
        await coordinator.start()
        XCTAssertEqual(library.aggregateReads, 1)
        folder.notifyAll()
        let folderDeadline = ContinuousClock.now + .seconds(5)
        while folder.unsettledReads < 2, ContinuousClock.now < folderDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = await coordinator.currentSnapshot()
        XCTAssertEqual(folder.unsettledReads, 2, "the watched-folder reset was consumed")
        XCTAssertEqual(library.aggregateReads, 1, "only the photo-library queue owns the cosmetic read")
        library.notifyAll()
        let libraryDeadline = ContinuousClock.now + .seconds(5)
        while library.aggregateReads < 2, ContinuousClock.now < libraryDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(library.aggregateReads, 2, "a photo-library reset still refreshes admission")
    }

    func testDurableEvidenceAloneDoesNotRecoverRetiredHistoryForARecheck() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        try journal.addSuperseded(earlier, for: source("p"))
        try journal.settle([earlier.nodeID], related: [], trashed: true, for: source("p"))
        enqueue("p", state: .alreadyBackedUp)
        // Evidence loaded from an earlier process is deliberately not sent through the live recorder.
        XCTAssertTrue(store.recordUploadEvidence(key("p"), revision: revision, at: date))
        recorder.recordHandoff(
            source: source("p"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "link-edit"),
            kind: .deduplicated)
        await coordinator.start()

        let rechecked = await waitForSnapshot("the manifest recheck hands off without an upload") {
            $0.tiles.first?.isSettled == true
        }
        XCTAssertEqual(rechecked.tiles.first?.replaces, [], "durable evidence cannot hide a restored earlier photo")
    }

    func testAnEditOfABackedUpPhotoShowsNoTileUntilItsCheckDecidesOnAnUpload() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .discovered)
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(50))
        let checking = await coordinator.currentSnapshot()
        XCTAssertTrue(
            checking.tiles.isEmpty, "the Proton photo shows until the check decided; most rechecks upload nothing")

        try journal.addSuperseded(earlier, for: source("p"))
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await waitForSnapshot("an upload decision shows the tile") { $0.tiles.count == 1 }
    }

    func testQueuedEditOfABackedUpPhotoWaitsForEvidence() async throws {
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .queuedForUpload)
        await coordinator.start()
        let queued = await coordinator.currentSnapshot()
        XCTAssertTrue(queued.tiles.isEmpty, "queued state alone does not prove an edited upload")
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        let decided = await waitForSnapshot("evidence admits the queued edit") { $0.tiles.count == 1 }
        XCTAssertEqual(decided.tiles.first?.replaces, [earlier])
    }

    func testRelaunchedQueuedEditRecoversSupersededMainWithoutLedgerRecord() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .queuedForUpload)
        try journal.addSuperseded(earlier, for: source("p"))
        XCTAssertTrue(store.recordUploadEvidence(key("p"), revision: edit, at: date))
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: edit))
        await coordinator.start()

        let recovered = await coordinator.currentSnapshot()
        XCTAssertEqual(recovered.tiles.first?.revision, edit)
        XCTAssertEqual(recovered.tiles.first?.replaces, [earlier])
        XCTAssertEqual(recovered.tiles.first?.isSettled, false)
    }

    func testNewerDiscoveredEditKeepsEarlierUploadsBeforeItsEvidence() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        try journal.addSuperseded(earlier, for: source("p"))
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()
        let first = await coordinator.currentSnapshot()
        XCTAssertEqual(first.tiles.first?.revision, edit)
        let newer = UploadBackupRevision(rawValue: edit.rawValue + 1)
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("p"), revision: newer, originalFilename: "p.heic",
                    state: .discovered, updatedAt: date)))
        let checking = await waitForSnapshot("the second edit owns the tile") { $0.tiles.first?.revision == newer }
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: newer))
        XCTAssertEqual(checking.tiles.first?.replaces, [earlier])
    }

    func testSettlementNarrowedToEmptyDoesNotFallBackToSupersededJournal() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        try journal.addSuperseded(earlier, for: source("p"))
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        recorder.settleUploadEvidence(source: source("p"), revision: edit, retired: [])
        await coordinator.start()
        XCTAssertEqual(recorder.replacementLedger.evidence(for: key("p"), revision: edit)?.replaces, [])
        // The recorded and the settled evidence arrive as two events; the settled one is final.
        let uploading = await waitForSnapshot("an empty ledger record remains authoritative") {
            $0.tiles.first?.replaces == []
        }
        XCTAssertEqual(uploading.tiles.count, 1)
    }

    func testSourceLeavingQueueDropsAllItsLedgerRevisions() async throws {
        enqueue("p", state: .uploading)
        for value in [revision, edit] {
            recorder.recordUploadEvidence(source: source("p"), revision: value, replaces: [earlier])
        }
        recorder.recordUploadEvidence(source: source("other"), revision: revision, replaces: [earlier])
        await coordinator.start()
        let initial = await coordinator.currentSnapshot()
        XCTAssertEqual(initial.tiles.count, 1)
        XCTAssertEqual(queue.removeSources(kind: .photoLibraryAsset, identifiers: ["p"]), 1)
        await waitForSnapshot("the removed source leaves the grid") { $0.tiles.isEmpty }
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: revision))
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: edit))
        XCTAssertNotNil(recorder.replacementLedger.evidence(for: key("other"), revision: revision))
    }

    func testReturnedSourceRecordsItsSameRevisionAgain() async throws {
        enqueue("p", state: .uploading)
        recorder.recordUploadEvidence(source: source("p"), revision: revision, replaces: [earlier])
        await coordinator.start()
        await waitForSnapshot("the edit shows") { $0.tiles.count == 1 }
        let excluded = await coordinator.exclude([key("p").localUID])
        XCTAssertTrue(excluded)
        // A late callback of the excluded attempt records nothing, also after the queue reloads its row.
        enqueue("p", state: .queuedForUpload)
        recorder.recordUploadEvidence(source: source("p"), revision: revision, replaces: [earlier])
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: revision))
        // The person returns the unchanged photo to backup: the same revision starts a new attempt.
        let restored = await coordinator.restore([key("p").localUID])
        XCTAssertTrue(restored)
        recorder.recordUploadEvidence(source: source("p"), revision: revision, replaces: [earlier])
        XCTAssertEqual(recorder.replacementLedger.evidence(for: key("p"), revision: revision)?.replaces, [earlier])
    }

    func testReconciliationHandoffSeedsJournalWithoutUploadEvidence() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        recorder.finish()
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), replacementJournal: journal,
            now: { [date] in date })
        coordinator = makeCoordinator(replacementJournal: journal)
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .needsRemoteReconciliation)
        try journal.addSuperseded(earlier, for: source("p"))
        await coordinator.start()
        recorder.recordHandoff(
            source: source("p"), revision: edit, remote: PhotoUID(volumeID: "vol", nodeID: "edit"), kind: .uploaded)
        let recovered = await waitForSnapshot("reconciliation captures the still-superseded main") {
            $0.tiles.first?.handoff != nil
        }
        XCTAssertEqual(recovered.tiles.first?.replaces, [earlier])
        try journal.settle([earlier.nodeID], related: [], trashed: true, for: source("p"))
        recorder.settleUploadEvidence(source: source("p"), revision: edit, retired: [earlier.nodeID])
        XCTAssertEqual(recorder.replacementLedger.replacementHandoffs().first?.evidence.replaces, [earlier])
    }

    func testAcknowledgmentDropsOnlyItsLedgerRevision() async throws {
        enqueue("p", state: .completed)
        recorder.recordUploadEvidence(source: source("p"), revision: revision, replaces: [earlier])
        recorder.recordHandoff(source: source("p"), revision: revision, remote: earlier, kind: .uploaded)
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()
        await coordinator.noteRemotePresence([key("p")])
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: revision))
        XCTAssertEqual(recorder.replacementLedger.evidence(for: key("p"), revision: edit)?.replaces, [earlier])
    }

    func testAcknowledgmentDropsOlderLedgerRevisionsAndKeepsNewerOnes() async throws {
        let newer = UploadBackupRevision(rawValue: edit.rawValue + 1)
        let other = source("other")
        for value in [revision, edit, newer] {
            recorder.recordUploadEvidence(source: source("p"), revision: value, replaces: [earlier])
            if value <= edit {
                recorder.recordHandoff(source: source("p"), revision: value, remote: earlier, kind: .uploaded)
            }
        }
        recorder.recordUploadEvidence(source: other, revision: revision, replaces: [earlier])
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .completed)
        await coordinator.start()
        let settled = await coordinator.currentSnapshot()
        XCTAssertEqual(settled.tiles.first?.revision, edit)
        XCTAssertEqual(settled.tiles.first?.isSettled, true)
        await coordinator.noteRemotePresence([key("p")])
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: revision))
        XCTAssertNil(recorder.replacementLedger.evidence(for: key("p"), revision: edit))
        XCTAssertNotNil(recorder.replacementLedger.evidence(for: key("p"), revision: newer))
        XCTAssertNotNil(recorder.replacementLedger.evidence(for: PendingSourceKey(other), revision: revision))
    }

    func testAnEditWhoseEarlierUploadOnlyTheJournalKnowsWaitsWhileDiscovered() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        // No earlier queue row, for example after a queue reset: the journal still names the earlier photo.
        try journal.addSuperseded(earlier, for: source("p"))
        metadata.set(
            key("p"), PendingPresentationMetadata(captureTime: date, mediaType: "image/heic", displayName: "p.heic"))
        enqueueEdit("p", state: .discovered)
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(50))
        let checking = await coordinator.currentSnapshot()
        XCTAssertTrue(checking.tiles.isEmpty)

        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        let uploading = await waitForSnapshot("an upload decision shows the tile") { $0.tiles.count == 1 }
        XCTAssertEqual(uploading.tiles.first?.replaces, [earlier])
    }

    func testAnEditWhoseEarlierUploadOnlyTheJournalKnowsWaitsForItsCheck() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        // No earlier queue row, for example after a queue reset: the journal still names the earlier photo.
        try journal.addSuperseded(earlier, for: source("p"))
        metadata.set(
            key("p"), PendingPresentationMetadata(captureTime: date, mediaType: "image/heic", displayName: "p.heic"))
        enqueueEdit("p", state: .queuedForUpload)
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(50))
        let checking = await coordinator.currentSnapshot()
        XCTAssertTrue(checking.tiles.isEmpty)

        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        let uploading = await waitForSnapshot("an upload decision shows the tile") { $0.tiles.count == 1 }
        XCTAssertEqual(uploading.tiles.first?.replaces, [earlier])
    }

    func testAnEditAdmittedAfterALargeScanWaitsForItsCheck() async throws {
        await coordinator.close()
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        coordinator = makeCoordinator(uncheckedAdmissionLimit: 1, replacementJournal: journal)
        enqueue("new", state: .discovered)
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .discovered)
        await coordinator.start()

        // The new photo's check decides on an upload; two unchecked rows become one, below the limit.
        recorder.recordUploadEvidence(source: source("new"), revision: revision)
        let admitted = await waitForSnapshot("the new photo shows") { $0.tiles.contains { $0.key.identifier == "new" } }
        XCTAssertFalse(
            admitted.tiles.contains { $0.key.identifier == "p" },
            "the edit's earlier photo stands alone until its check")
    }

    func testTheTileOfAnEditStandsInPlaceOfTheEarlierPhoto() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        try journal.addSuperseded(earlier, for: source("p"))
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()

        let uploading = await waitForSnapshot("the edit uploads") { $0.tiles.count == 1 }
        XCTAssertEqual(uploading.tiles.first?.replaces, [earlier])
    }

    func testOnlyAnEarlierPhotoThatMovedToTheTrashStaysHidden() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        try journal.addSuperseded(earlier, for: source("p"))
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()
        await waitForSnapshot("the edit uploads") { [earlier] in $0.tiles.first?.replaces == [earlier] }

        try journal.settle([earlier.nodeID], related: [], trashed: true, for: source("p"))
        recorder.recordHandoff(
            source: source("p"), revision: edit, remote: PhotoUID(volumeID: "vol", nodeID: "link-edit"),
            kind: .uploaded)
        XCTAssertTrue(
            queue.updateState(
                source: source("p"), revision: edit, state: .completed, attempts: nil, lastError: nil, updatedAt: date))

        let settled = await waitForSnapshot("the replacement settled") { $0.tiles.first?.isSettled == true }
        XCTAssertEqual(settled.tiles.first?.replaces, [earlier], "the trashed photo stays hidden")
    }

    func testAnEarlierPhotoThatTheReplacementKeptShowsAgain() async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator()
        try journal.addSuperseded(earlier, for: source("p"))
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()
        await waitForSnapshot("the edit uploads") { [earlier] in $0.tiles.first?.replaces == [earlier] }

        // Another photo of the library still needs the earlier upload.
        try journal.settle([earlier.nodeID], related: [], trashed: false, for: source("p"))
        recorder.settleUploadEvidence(source: source("p"), revision: edit, retired: [])
        XCTAssertTrue(
            queue.updateState(
                source: source("p"), revision: edit, state: .completed, attempts: nil, lastError: nil, updatedAt: date))
        recorder.recordHandoff(
            source: source("p"), revision: edit, remote: PhotoUID(volumeID: "vol", nodeID: "link-edit"),
            kind: .uploaded)

        let settled = await waitForSnapshot("the replacement settled") { $0.tiles.first?.isSettled == true }
        XCTAssertEqual(settled.tiles.first?.replaces, [], "a kept photo shows again")
    }

    // MARK: - Admission

    func testFewNewPhotosShowAtOnceBeforeTheirCheck() async throws {
        enqueue("a", state: .discovered)
        enqueue("b", state: .discovered, captureOffset: 1)
        enqueue("c", state: .checking, captureOffset: 2)
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["a", "b", "c"], "a few new photos show together, each with an empty ring")
        XCTAssertTrue(snapshot.tiles.allSatisfy { $0.badge == .waiting })
    }

    func testLargeScanShowsPhotosOnlyAfterTheirCheck() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(uncheckedAdmissionLimit: 1)
        enqueue("shown", state: .discovered)
        await coordinator.start()
        await waitForSnapshot("a small scan shows at once") { $0.tiles.count == 1 }

        // A large scan (a first backup, or a second device of an iCloud library) waits for each check, so copies
        // of photos already in Proton never flood the grid. The tile that already showed stays.
        for id in ["x", "y", "z"] { enqueue(id, state: .discovered, captureOffset: 5) }
        try await Task.sleep(for: .milliseconds(100))
        let large = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(large), ["shown"])

        recorder.recordUploadEvidence(source: source("x"), revision: revision)
        await waitForSnapshot("evidence admits a checked photo") {
            Set($0.tiles.map(\.key.identifier)) == ["shown", "x"]
        }
    }

    func testCheckedTileStaysThroughANewRevisionDuringALargeScan() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(uncheckedAdmissionLimit: 0)
        enqueue("p", state: .queuedForUpload)
        recorder.recordUploadEvidence(source: source("p"), revision: revision)
        await coordinator.start()
        await waitForSnapshot("the checked photo shows") { $0.tiles.count == 1 }

        // The camera finished the photo: its new revision is not checked yet.
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("p"), revision: UploadBackupRevision(rawValue: 10), originalFilename: "p.heic",
                    state: .discovered, updatedAt: date)))
        await waitForSnapshot("the tile follows the new revision") {
            $0.tiles.first?.revision == UploadBackupRevision(rawValue: 10)
        }
        for _ in 0..<20 {
            let snapshot = await coordinator.currentSnapshot()
            XCTAssertEqual(tileIDs(snapshot), ["p"], "a tile that showed must not leave for an unchecked revision")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUncheckedPhotoShowsOnceItsCheckPassed() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(uncheckedAdmissionLimit: 0)
        enqueue("fresh", state: .discovered)
        await coordinator.start()
        let initial = await coordinator.currentSnapshot()
        XCTAssertTrue(initial.tiles.isEmpty, "an unchecked photo of a large scan can be a copy of a Proton photo")

        recorder.recordUploadEvidence(source: source("fresh"), revision: revision)
        let snapshot = await waitForSnapshot("evidence admits the tile") { $0.tiles.count == 1 }
        let tile = try XCTUnwrap(snapshot.tiles.first)
        XCTAssertEqual(tile.item.uid, PhotoUID(localPending: .photoLibrary, identifier: "fresh"))
        XCTAssertEqual(tile.badge, .waiting)
        XCTAssertEqual(
            tile.item.captureTime.timeIntervalSince1970, 1_750_000_000,
            "the capture time is floored to whole seconds, as Proton stores it")
    }

    func testCheckedStatesShowWithoutStoredEvidence() async {
        enqueue("queued", state: .queuedForUpload)
        enqueue("dup", state: .alreadyBackedUp)
        enqueue("gone", state: .skippedRemoteDeletion)
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["queued"])
    }

    func testPhotoSavedByTheAppNeverShows() async {
        enqueue("saved", state: .queuedForUpload)
        await coordinator.start()
        await coordinator.recordSavedFromApp(localIdentifier: "saved", remote: PhotoUID(volumeID: "v", nodeID: "n"))
        await waitForSnapshot("a saved photo leaves the grid") { $0.tiles.isEmpty }
    }

    func testInaccessiblePhotoNeverShows() async {
        enqueue("hidden", state: .queuedForUpload)
        metadata.remove(key("hidden"))
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.tiles.isEmpty)
    }

    func testTilesFollowTimelineOrder() async {
        enqueue("late", state: .queuedForUpload, captureOffset: 60)
        enqueue("early", state: .queuedForUpload, captureOffset: -60)
        enqueue("middle", state: .queuedForUpload)
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["early", "middle", "late"])

        enqueue("first", state: .queuedForUpload, captureOffset: -120)
        await waitForSnapshot("an incremental insert keeps the order") {
            $0.tiles.map(\.key.identifier) == ["first", "early", "middle", "late"]
        }
    }

    // MARK: - Progress and handoff

    func testProgressUpdatesOnlyTheProgressMap() async throws {
        enqueue("up", state: .uploading)
        await coordinator.start()
        let before = await coordinator.currentSnapshot()

        recorder.reportProgress(source: source("up"), revision: revision, step: 7)
        let during = await waitForSnapshot("the step arrives") { !$0.progress.isEmpty }
        XCTAssertEqual(during.membershipRevision, before.membershipRevision, "progress must not rebuild tiles")
        let tile = try XCTUnwrap(during.tiles.first)
        XCTAssertEqual(during.badge(for: tile), .uploading(step: 7))

        recorder.reportProgress(source: source("up"), revision: revision, step: nil)
        await waitForSnapshot("the progress ends") { $0.progress.isEmpty }
    }

    func testSettledSourceRetiresOnlyAfterItsProtonPhotoIsListed() async throws {
        enqueue("done", state: .uploading)
        await coordinator.start()
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-done")
        recorder.recordHandoff(source: source("done"), revision: revision, remote: remote, kind: .uploaded)
        setState("done", .completed)

        let settled = await waitForSnapshot("the tile shows the checkmark") { $0.tiles.first?.isSettled == true }
        XCTAssertEqual(settled.tiles.first?.badge, .done)
        XCTAssertEqual(settled.tiles.first?.handoff, remote)

        await coordinator.noteRemotePresence([key("done")])
        await waitForSnapshot("the tile retires after the checkmark lingered") { $0.tiles.isEmpty }
        XCTAssertTrue(store.unacknowledgedHandoffs().isEmpty)
    }

    func testSettledRowKeepsItsTileBeforeTheHandoffEventArrives() async throws {
        enqueue("done", state: .uploading)
        await coordinator.start()
        await waitForSnapshot("uploading") { $0.tiles.count == 1 }
        // The runner writes the handoff first; its event travels on another stream than the queue change.
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-done")
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key("done"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        setState("done", .completed)

        let settled = await waitForSnapshot("the tile keeps its place") { $0.tiles.first?.isSettled == true }
        XCTAssertEqual(tileIDs(settled), ["done"], "a settled row must never hide its tile for a moment")
        XCTAssertEqual(settled.tiles.first?.handoff, remote)
    }

    func testNewRevisionKeepsItsTileWhileItsMetadataLoads() async throws {
        enqueue("p", state: .uploading)
        await coordinator.start()
        await waitForSnapshot("shown") { $0.tiles.count == 1 }

        // The camera finished processing the photo: a new revision arrives before the catalog knows it.
        metadata.remove(key("p"))
        let finished = UploadBackupRevision(rawValue: 10)
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("p"), revision: finished, originalFilename: "p.heic", state: .discovered,
                    updatedAt: date)))
        await waitForSnapshot("the tile follows the new revision") { $0.tiles.first?.revision == finished }
        for _ in 0..<20 {
            let snapshot = await coordinator.currentSnapshot()
            XCTAssertEqual(tileIDs(snapshot), ["p"], "the tile must never leave while its metadata loads")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCheckmarkShowsOnlyBriefly() async throws {
        await coordinator.close()
        coordinator = makeCoordinator(checkmarkDuration: .milliseconds(30))
        enqueue("done", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("done"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "l"), kind: .uploaded)
        setState("done", .completed)
        await waitForSnapshot("the checkmark shows") { $0.tiles.first?.badge == .done }
        let later = await waitForSnapshot("then the tile shows no badge") { $0.tiles.first?.badge == .backedUp }
        XCTAssertEqual(tileIDs(later), ["done"], "the tile stays until its Proton photo takes over")
    }

    func testPhotoDeletedInApplePhotosLeavesTheGrid() async throws {
        enqueue("gone", state: .queuedForUpload)
        enqueue("kept", state: .queuedForUpload)
        await coordinator.start()
        await waitForSnapshot("both show") { $0.tiles.count == 2 }

        await coordinator.noteSourcesMissing([
            PhotoUID(localPending: .photoLibrary, identifier: "gone"), PhotoUID(volumeID: "vol", nodeID: "remote"),
        ])
        let snapshot = await waitForSnapshot("the deleted photo leaves") { $0.tiles.count == 1 }
        XCTAssertEqual(tileIDs(snapshot), ["kept"])
    }

    func testUnlistedHandoffSurvivesARestart() async throws {
        enqueue("done", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("done"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "l"), kind: .uploaded)
        setState("done", .completed)
        await waitForSnapshot("settled") { $0.tiles.first?.isSettled == true }
        await coordinator.close()
        recorder.finish()

        // A relaunch builds a new recorder and coordinator over the same stores.
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
        coordinator = makeCoordinator()
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(tileIDs(snapshot), ["done"], "a completed photo whose Proton photo is not listed stays")
    }

    // MARK: - Delete and restore

    func testDeleteRemovesFromBackupAndRestoreReturnsIt() async throws {
        enqueue("pick", state: .queuedForUpload)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "pick")

        let excluded = await coordinator.exclude([uid])
        XCTAssertTrue(excluded)
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.tiles.isEmpty)
        XCTAssertEqual(snapshot.trashTiles.map(\.item.uid), [uid])
        XCTAssertEqual(snapshot.excludedTiles.map(\.item.uid), [uid])
        XCTAssertEqual(effects.removed, [["pick"]])
        XCTAssertEqual(store.sourceState(for: key("pick"))?.needsQueueSync, false)

        let restored = await coordinator.restore([uid])
        XCTAssertTrue(restored)
        XCTAssertEqual(effects.returned, [[key("pick")]])
        snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.trashTiles.isEmpty)
        XCTAssertNil(store.sourceState(for: key("pick")), "a finished restore leaves no state behind")
    }

    func testDeleteOfACommittedUploadTrashesTheProtonPhoto() async throws {
        enqueue("sent", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("sent"), revision: revision, remote: PhotoUID(volumeID: "", nodeID: "link-sent"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }

        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "sent")])

        XCTAssertEqual(effects.trashed, [[PhotoUID(volumeID: "photos-volume", nodeID: "link-sent")]])
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.trashTiles.isEmpty, "the Proton trash entry represents the photo")
        XCTAssertEqual(store.sourceState(for: key("sent"))?.remoteTrashed, true)
    }

    func testCommitThatRacesADeleteMovesThePhotoToTheTrash() async throws {
        enqueue("race", state: .uploading)
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "race")])
        XCTAssertTrue(effects.trashed.isEmpty)

        let outcome = recorder.recordHandoff(
            source: source("race"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "late"),
            kind: .uploaded)
        XCTAssertEqual(outcome, .excludedRemoteNeedsTrash)
        let deadline = ContinuousClock.now + .seconds(5)
        while effects.trashed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.trashed, [[PhotoUID(volumeID: "vol", nodeID: "late")]])
    }

    func testOnlyThePhotoWithoutAnAnswerFromProtonTriesTheTrashAgain() async throws {
        enqueue("answered", state: .uploading)
        enqueue("unanswered", state: .uploading)
        await coordinator.start()
        for id in ["answered", "unanswered"] {
            recorder.recordHandoff(
                source: source(id), revision: revision, remote: PhotoUID(volumeID: "", nodeID: "link-\(id)"),
                kind: .uploaded)
        }
        await waitForSnapshot("handoffs known") { $0.tiles.count == 2 && $0.tiles.allSatisfy { $0.handoff != nil } }
        effects.trashRetry = [PhotoUID(volumeID: "photos-volume", nodeID: "link-unanswered")]

        await coordinator.exclude([
            PhotoUID(localPending: .photoLibrary, identifier: "answered"),
            PhotoUID(localPending: .photoLibrary, identifier: "unanswered"),
        ])

        let answered = try XCTUnwrap(store.sourceState(for: key("answered")))
        let unanswered = try XCTUnwrap(store.sourceState(for: key("unanswered")))
        XCTAssertTrue(answered.remoteTrashed)
        XCTAssertFalse(answered.needsRemoteTrash, "a confirmed photo must not be trashed again")
        XCTAssertFalse(unanswered.remoteTrashed)
        XCTAssertTrue(unanswered.needsRemoteTrash, "a photo without an answer must try again")
        XCTAssertEqual(unanswered.attempts, 1)
    }

    func testFailedRemovalStaysDueAndRetries() async throws {
        enqueue("stuck", state: .queuedForUpload)
        effects.removeSucceeds = false
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "stuck")])
        let state = try XCTUnwrap(store.sourceState(for: key("stuck")))
        XCTAssertTrue(state.needsQueueSync, "a failed removal must never be forgotten")
        XCTAssertEqual(state.attempts, 1)
    }

    func testTrashListRemovalKeepsThePhotoExcluded() async throws {
        enqueue("bin", state: .queuedForUpload)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "bin")
        await coordinator.exclude([uid])

        let removed = await coordinator.removeFromTrashList([uid])
        XCTAssertTrue(removed)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.trashTiles.isEmpty)
        XCTAssertEqual(snapshot.excludedTiles.map(\.item.uid), [uid])
    }

    // MARK: - Excluded list follows the library

    /// The person excludes two photos, opens the excluded list, deletes both photos in Apple Photos, and returns to
    /// the app. Both leave the list without a relaunch; a photo that still exists stays.
    func testPhotosDeletedInApplePhotosLeaveTheExcludedListAfterALibraryChange() async throws {
        for (offset, id) in ["first", "second", "kept"].enumerated() {
            enqueue(id, state: .queuedForUpload, captureOffset: TimeInterval(offset))
        }
        await coordinator.start()
        let uids = ["first", "second", "kept"].map { PhotoUID(localPending: .photoLibrary, identifier: $0) }
        await coordinator.exclude(uids)
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(Set(snapshot.excludedTiles.map(\.item.uid)), Set(uids))

        metadata.remove(key("first"))
        metadata.remove(key("second"))
        await coordinator.noteLibraryChanged()

        let kept = PhotoUID(localPending: .photoLibrary, identifier: "kept")
        snapshot = await waitForSnapshot("the deleted photos leave the excluded list") {
            $0.excludedTiles.map(\.item.uid) == [kept]
        }
        XCTAssertEqual(snapshot.trashTiles.map(\.item.uid), [kept], "\"Recently Deleted\" drops them as well")
    }

    func testABurstOfLibraryChangesSharesOneCheck() async throws {
        await coordinator.close()
        let gate = PendingMembershipSleepGate()
        let delay = Duration.seconds(3600)
        coordinator = makeCoordinator(libraryChangeDelay: delay) { duration in
            if duration == delay { await gate.wait() } else { try await Task.sleep(for: duration) }
        }
        enqueue("gone", state: .queuedForUpload)
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "gone")])
        let readsBefore = metadata.reads(of: key("gone"))
        metadata.remove(key("gone"))

        for _ in 0..<50 { await coordinator.noteLibraryChanged() }
        await gate.release()

        await waitForSnapshot("the check ran") { $0.excludedTiles.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(metadata.reads(of: key("gone")) - readsBefore, 1, "a burst of changes shares one check")
    }

    func testALibraryChangeDuringACheckRunsOneMoreCheck() async throws {
        enqueue("late", state: .queuedForUpload)
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "late")])
        let readsBefore = metadata.reads(of: key("late"))
        let gate = LookupGate()
        metadata.fetchGate = { await gate.pass() }

        await coordinator.noteLibraryChanged()
        await gate.entered()
        // The photo is deleted while the first check reads; that check still saw it.
        metadata.remove(key("late"))
        for _ in 0..<3 { await coordinator.noteLibraryChanged() }
        gate.open()

        await waitForSnapshot("the second check drops the photo") { $0.excludedTiles.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(metadata.reads(of: key("late")) - readsBefore, 2, "changes during a check share one more check")
    }

    /// While backup is paused no pass updates the catalog, so the catalog still lists a photo deleted in Apple
    /// Photos. The thumbnail loader reports it gone; the photo leaves the list and an activation does not return it.
    func testAnExcludedPhotoReportedMissingLeavesTheListWhileTheCatalogStillListsIt() async throws {
        enqueue("gone", state: .queuedForUpload)
        enqueue("kept", state: .queuedForUpload, captureOffset: 1)
        await coordinator.start()
        let gone = PhotoUID(localPending: .photoLibrary, identifier: "gone")
        let kept = PhotoUID(localPending: .photoLibrary, identifier: "kept")
        await coordinator.exclude([gone, kept])

        await coordinator.noteSourcesMissing([gone])

        var snapshot = await waitForSnapshot("the missing photo leaves the excluded list") {
            $0.excludedTiles.map(\.item.uid) == [kept]
        }
        XCTAssertEqual(snapshot.trashTiles.map(\.item.uid), [kept])
        let readsBefore = metadata.reads(of: key("gone"))
        await coordinator.noteLibraryChanged()
        let deadline = ContinuousClock.now + .seconds(5)
        while metadata.reads(of: key("gone")) == readsBefore, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.excludedTiles.map(\.item.uid), [kept], "the stale catalog must not return the photo")
    }

    func testAPhotoExcludedDuringACheckKeepsItsEntry() async throws {
        enqueue("first", state: .queuedForUpload)
        enqueue("second", state: .queuedForUpload, captureOffset: 1)
        await coordinator.start()
        let first = PhotoUID(localPending: .photoLibrary, identifier: "first")
        let second = PhotoUID(localPending: .photoLibrary, identifier: "second")
        await coordinator.exclude([first])
        let gate = LookupGate()
        metadata.fetchGate = { await gate.pass() }

        await coordinator.noteLibraryChanged()
        await gate.entered()
        await coordinator.exclude([second])
        gate.open()

        // The check publishes only a changed list, so the test waits for it to end.
        try await Task.sleep(for: .milliseconds(200))
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(
            Set(snapshot.excludedTiles.map(\.item.uid)), [first, second],
            "a check that started before the exclusion must not drop the photo")
    }

    func testClosingStopsAPendingCheck() async throws {
        await coordinator.close()
        let gate = PendingMembershipSleepGate()
        let delay = Duration.seconds(3600)
        coordinator = makeCoordinator(libraryChangeDelay: delay) { duration in
            if duration == delay { await gate.wait() } else { try await Task.sleep(for: duration) }
        }
        enqueue("photo", state: .queuedForUpload)
        await coordinator.start()
        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "photo")])
        let readsBefore = metadata.reads(of: key("photo"))

        await coordinator.noteLibraryChanged()
        await coordinator.close()
        await gate.release()

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(metadata.reads(of: key("photo")), readsBefore, "a closed coordinator reads nothing")
    }

    func testProgressTicksKeepTheTrashListUntilAPhotoExpires() async throws {
        await coordinator.close()
        let clock = MutableClock(date)
        coordinator = PendingBackupCoordinator(
            store: store,
            queues: [.photoLibraryAsset: queue],
            metadataProvider: metadata,
            effects: effects,
            recorder: recorder,
            configuration: .init(
                membershipInterval: .zero,
                progressInterval: .milliseconds(1),
                doneLinger: .milliseconds(20),
                trashRetention: 60
            ),
            now: { clock.now }
        )
        enqueue("old", state: .queuedForUpload)
        enqueue("up", state: .uploading)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "old")
        await coordinator.exclude([uid])

        recorder.reportProgress(source: source("up"), revision: revision, step: 3)
        var snapshot = await waitForSnapshot("the step arrives") { !$0.progress.isEmpty }
        XCTAssertEqual(snapshot.trashTiles.map(\.item.uid), [uid])

        clock.advance(by: 61)
        recorder.reportProgress(source: source("up"), revision: revision, step: 4)
        snapshot = await waitForSnapshot("the expired photo leaves the trash list") { $0.trashTiles.isEmpty }
        XCTAssertEqual(snapshot.excludedTiles.map(\.item.uid), [uid], "the photo stays excluded")

        // A clock set back (for example by the network time) puts the photo into its retention again.
        clock.advance(by: -30)
        recorder.reportProgress(source: source("up"), revision: revision, step: 5)
        snapshot = await waitForSnapshot("the photo returns to the trash list") { !$0.trashTiles.isEmpty }
        XCTAssertEqual(snapshot.trashTiles.map(\.item.uid), [uid])
    }

    // MARK: - Deferred actions

    func testFavoriteOnAPendingPhotoAppliesAfterItsProtonPhotoIsListed() async throws {
        enqueue("fav", state: .uploading)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "fav")
        let stored = await coordinator.setFavorite([uid], favorite: true)
        XCTAssertTrue(stored)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.favoriteIntents[uid], true, "the heart shows at once")

        recorder.recordHandoff(
            source: source("fav"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "fav-link"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        await coordinator.noteRemotePresence([key("fav")])

        XCTAssertEqual(effects.favorites, [PhotoUID(volumeID: "vol", nodeID: "fav-link")])
        XCTAssertTrue(store.actions().isEmpty)
    }

    func testActionRunsAfterTheCommitWithoutWaitingForTheGrid() async throws {
        enqueue("quiet", state: .uploading)
        await coordinator.start()
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "quiet")
        _ = await coordinator.setFavorite([uid], favorite: true)
        recorder.recordHandoff(
            source: source("quiet"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "q"),
            kind: .uploaded)

        let deadline = ContinuousClock.now + .seconds(5)
        while effects.favorites.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.favorites, [PhotoUID(volumeID: "vol", nodeID: "q")])
    }

    func testRestoreResumesAnActionThatWaitedWhileExcluded() async throws {
        enqueue("paused", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("paused"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "p"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "paused")
        await coordinator.exclude([uid])
        _ = await coordinator.setFavorite([uid], favorite: true)
        XCTAssertTrue(effects.favorites.isEmpty, "an excluded photo receives no deferred action")

        await coordinator.restore([uid])
        XCTAssertEqual(effects.favorites, [PhotoUID(volumeID: "vol", nodeID: "p")])
    }

    func testRestoreBringsTheProtonPhotoBackBeforeTheBackupSeesIt() async throws {
        enqueue("back", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("back"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "b"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "back")
        await coordinator.exclude([uid])
        XCTAssertEqual(effects.trashed.count, 1)

        await coordinator.restore([uid])
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
    }

    /// An edit uploads while its tile hides the earlier upload of this device. The tile of that upload retired,
    /// so only the store still knows its handoff.
    private func startPendingEdit(
        earlierKind: PendingHandoffKind = .uploaded,
        identities: (any UploadIdentityStore)? = FakeIdentityStore(),
        relations: (any UploadDuplicateChecking)? = FakeChecker()
    ) async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator(identities: identities, relations: relations)
        try journal.addSuperseded(earlier, for: source("p"))
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key("p"), revision: revision, remote: earlier, kind: earlierKind, createdAt: date)),
            .recorded)
        XCTAssertTrue(store.acknowledgeHandoffs([(key("p"), revision)]))
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()
        await waitForSnapshot("the edit hides the earlier upload") { [earlier, edit] in
            $0.tiles.first?.revision == edit && $0.tiles.first?.replaces == [earlier]
        }
    }

    func testDeletingAnUnfinishedEditMovesTheHiddenEarlierUploadToTheTrash() async throws {
        try await startPendingEdit()

        await coordinator.exclude([key("p").localUID])

        XCTAssertEqual(effects.trashed, [[earlier]], "the photo the person deleted is the earlier upload")
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.remote, earlier)
        XCTAssertTrue(state.remoteTrashed)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(snapshot.tiles.isEmpty)
    }

    func testDeletingAnUnfinishedEditKeepsAnEarlierPhotoThatAnotherUploadOwns() async throws {
        // The journal and the manifest would allow the trash; the handoff that the store keeps decides.
        try await startPendingEdit(earlierKind: .deduplicated, identities: FakeIdentityStore())

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty, "a mapped photo can belong to another photo of the library")
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
    }

    /// An edit uploads weeks after the earlier upload, whose handoff the store pruned. Only the journal and the
    /// tile name the earlier upload.
    private func startPendingEditWithoutHandoff(
        identities: (any UploadIdentityStore)?,
        relations: (any UploadDuplicateChecking)? = FakeChecker()
    ) async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator(identities: identities, relations: relations)
        try journal.addSuperseded(earlier, for: source("p"))
        enqueue("p", state: .completed)
        enqueueEdit("p", state: .uploading)
        XCTAssertTrue(store.latestHandoffs(for: [key("p")]).isEmpty)
        recorder.recordUploadEvidence(source: source("p"), revision: edit, replaces: [earlier])
        await coordinator.start()
        await waitForSnapshot("the edit hides the earlier upload") { [earlier, edit] in
            $0.tiles.first?.revision == edit && $0.tiles.first?.replaces == [earlier]
        }
    }

    private func identityRow(_ id: String, linkID: String) -> UploadIdentityRecord {
        UploadIdentityRecord(
            source: source(id), filename: "\(id).heic", correctedName: "\(id).heic", fileSize: 1,
            modificationDate: date, sha1Hex: "sha-\(id)", nameHash: "name-\(id)", contentHash: "content-\(id)",
            hashKeyEpoch: "epoch", remoteVolumeID: earlier.volumeID, remoteLinkID: linkID,
            outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue, updatedAt: date)
    }

    // Mutation: return nil instead of `newestEarlierMain` when the store has no handoff; nothing is trashed.
    // Mutation: skip `forgetRemoteLinks` in `exclude`; the manifest keeps the trashed photo.
    func testDeletingAnEditWithoutAHandoffMovesTheEarlierUploadOfTheJournalToTheTrash() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        try await startPendingEditWithoutHandoff(identities: identities)

        await coordinator.exclude([key("p").localUID])

        XCTAssertEqual(effects.trashed, [[earlier]], "the photo the person deleted is the earlier upload")
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.remote, earlier)
        XCTAssertTrue(state.remoteTrashed)
        XCTAssertNil(
            identities.record(for: source("p"))?.remoteLinkID,
            "a return to the backup must not count the trashed photo as the backup of the source")
    }

    // Mutation: drop the `isNeededElsewhere` guard in `hiddenEarlierUpload`; the delete records the shared photo.
    func testDeletingAnEditWithoutAHandoffKeepsAnEarlierUploadThatAnotherSourceNeeds() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("duplicate", linkID: earlier.nodeID))
        try await startPendingEditWithoutHandoff(identities: identities)

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty, "a duplicate in Photos still counts the photo as its backup")
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
        XCTAssertEqual(store.sourceState(for: key("p"))?.desired, .excluded)
    }

    // Mutation: let `isNeededElsewhere` return false for an unknown lookup; the delete records the photo.
    func testDeletingAnEditWithoutAHandoffKeepsTheEarlierUploadWhenTheManifestCannotTell() async throws {
        try await startPendingEditWithoutHandoff(identities: UnreadableIdentityStore())

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty)
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
        XCTAssertEqual(store.sourceState(for: key("p"))?.desired, .excluded)
    }

    // Mutation: return nil from `newestEarlierMain`; the restore has no photo to bring back.
    func testRestoringAnEditWithoutAHandoffBringsTheEarlierUploadBack() async throws {
        try await startPendingEditWithoutHandoff(identities: FakeIdentityStore())
        await coordinator.exclude([key("p").localUID])

        await coordinator.restore([key("p").localUID])

        XCTAssertEqual(effects.restored, [[earlier]])
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
        XCTAssertEqual(effects.returned, [[key("p")]])
    }

    // Mutation: drop the source-state lookup in `restoreSources(ofRemote:)`; the source stays deleted.
    func testRestoringTheEarlierUploadFromTheProtonTrashRestoresAnEditWithoutAHandoff() async throws {
        try await startPendingEditWithoutHandoff(identities: FakeIdentityStore())
        await coordinator.exclude([key("p").localUID])

        await coordinator.restoreSources(ofRemote: [earlier])

        XCTAssertNotEqual(store.sourceState(for: key("p"))?.desired, .excluded)
        XCTAssertEqual(effects.returned, [[key("p")]])
    }

    func testAnEditThatCommitsAfterItsDeleteFollowsTheEarlierUploadToTheTrash() async throws {
        try await startPendingEdit()
        await coordinator.exclude([key("p").localUID])
        XCTAssertEqual(effects.trashed, [[earlier]])

        let committed = PhotoUID(volumeID: "vol", nodeID: "link-edit")
        let outcome = recorder.recordHandoff(source: source("p"), revision: edit, remote: committed, kind: .uploaded)
        XCTAssertEqual(outcome, .excludedRemoteNeedsTrash)
        let deadline = ContinuousClock.now + .seconds(5)
        while effects.trashed.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.trashed, [[earlier], [committed]])
    }

    // Mutation: keep the store's handoff of the deleted revision as the answer in `hiddenEarlierUpload`; only the
    // commit goes to the trash and the earlier upload stays in the library.
    func testAnEditWhoseCommitIsStoredButNotYetSeenStillTrashesTheEarlierUpload() async throws {
        try await startPendingEdit()
        // The upload of the edit committed and its handoff is durable, but its event has not reached the grid yet.
        let committed = PhotoUID(volumeID: "vol", nodeID: "link-edit")
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key("p"), revision: edit, remote: committed, kind: .uploaded, createdAt: date)),
            .recorded)

        await coordinator.exclude([key("p").localUID])

        let deadline = ContinuousClock.now + .seconds(5)
        while effects.trashed.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(
            Set(effects.trashed.flatMap { $0 }), [earlier, committed],
            "the person deleted the photo, so neither the earlier upload nor the edit stays in the library")
    }

    // Mutation: return the handoff's photo in `hiddenEarlierUpload` before the `isNeededElsewhere` guard.
    func testDeletingAnUnfinishedEditKeepsAHandedOffEarlierUploadThatAnotherSourceNeeds() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("duplicate", linkID: earlier.nodeID))
        try await startPendingEdit(identities: identities)

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty, "a duplicate in Photos still counts the photo as its backup")
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
        XCTAssertEqual(store.sourceState(for: key("p"))?.desired, .excluded)
    }

    // Mutation: return the handoff's photo in `hiddenEarlierUpload` before the `isNeededElsewhere` guard.
    func testDeletingAnUnfinishedEditKeepsAHandedOffEarlierUploadWhenTheManifestCannotTell() async throws {
        try await startPendingEdit(identities: UnreadableIdentityStore())

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty)
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
    }

    // Mutation: check only `[target.nodeID]` in `hiddenEarlierUpload`; the shared related file is trashed.
    func testDeletingAnEditKeepsTheEarlierUploadWhenARelatedFileIsAnotherSourcesBackup() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("duplicate", linkID: "link-related"))
        let relations = FakeChecker()
        relations.relatedLinkIDsByMainLinkID[earlier.nodeID] = ["link-related"]
        try await startPendingEdit(identities: identities, relations: relations)

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty, "the trash would take the related file of another photo with it")
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.desired, .excluded)
        XCTAssertNil(state.remote, "the delete records no photo for the trash")
        XCTAssertFalse(state.needsRemoteTrash)
    }

    // Mutation: treat a failed lookup in `hiddenEarlierUpload` as no related files; the photo is trashed.
    func testDeletingAnEditKeepsTheEarlierUploadWhenTheRelatedFilesCannotBeRead() async throws {
        let relations = FakeChecker()
        relations.relatedLookupError = URLError(.notConnectedToInternet)
        try await startPendingEdit(relations: relations)

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty)
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.desired, .excluded)
        XCTAssertNil(state.remote, "an unknown related file keeps the photo instead of deferring the delete")
        XCTAssertFalse(state.needsRemoteTrash)
        XCTAssertEqual(relations.relatedLookups, [earlier.nodeID], "one lookup, no retry")
    }

    // Mutation: drop the action token check in `exclude`; the held delete deletes the restored photo again.
    func testARestoreDuringTheLookupOfADeleteStands() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        let relations = FakeChecker()
        let gate = LookupGate()
        relations.relatedLookupGate = { await gate.pass() }
        try await startPendingEdit(identities: identities, relations: relations)
        let coordinator: PendingBackupCoordinator = self.coordinator
        let uid = key("p").localUID
        let held = Task { await coordinator.exclude([uid]) }
        await gate.entered()

        let deleted = await coordinator.exclude([uid])
        XCTAssertTrue(deleted)
        XCTAssertEqual(effects.trashed, [[earlier]])
        let restored = await coordinator.restore([uid])
        XCTAssertTrue(restored)
        gate.open()
        let heldResult = await held.value

        XCTAssertTrue(heldResult)
        XCTAssertNotEqual(store.sourceState(for: key("p"))?.desired, .excluded, "the restore is the last decision")
        XCTAssertEqual(effects.trashed, [[earlier]], "the restored photo stays")
        XCTAssertEqual(effects.restored, [[earlier]])
    }

    // Mutation: forget the links in `hiddenEarlierUpload` again; the abandoned delete erases the manifest row.
    func testADeleteThatEndsDuringItsLookupKeepsTheManifest() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        let relations = FakeChecker()
        let gate = LookupGate()
        relations.relatedLookupGate = { await gate.pass() }
        try await startPendingEdit(identities: identities, relations: relations)
        let coordinator: PendingBackupCoordinator = self.coordinator
        let uid = key("p").localUID
        let held = Task { await coordinator.exclude([uid]) }
        await gate.entered()

        await coordinator.close()
        gate.open()
        let heldResult = await held.value

        XCTAssertFalse(heldResult)
        XCTAssertEqual(identities.record(for: source("p"))?.remoteLinkID, earlier.nodeID)
        XCTAssertNotEqual(store.sourceState(for: key("p"))?.desired, .excluded)
        XCTAssertTrue(effects.trashed.isEmpty)
    }

    // Mutation: drop the `keepRemote` call in `exclude`; the photo goes to the trash while the manifest counts it.
    func testDeletingAnEditKeepsTheEarlierUploadWhenTheManifestCannotForgetIt() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        identities.rejectNextForget()
        try await startPendingEdit(identities: identities)

        await coordinator.exclude([key("p").localUID])

        XCTAssertTrue(effects.trashed.isEmpty)
        XCTAssertEqual(identities.record(for: source("p"))?.remoteLinkID, earlier.nodeID)
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.desired, .excluded)
        XCTAssertNil(state.remote, "the delete keeps the photo instead of deferring")
        XCTAssertFalse(state.needsRemoteTrash)
        XCTAssertTrue(state.listedInTrash)
    }

    // Mutation: drop the early return for a pending trash in `PendingBackupManifestStore.recordHandoff`; the
    // commit takes over the state's photo, and the earlier upload never goes to the trash.
    func testAnEditThatCommitsBeforeTheEarlierTrashIsSentTrashesBothPhotos() async throws {
        let committed = PhotoUID(volumeID: "vol", nodeID: "link-edit")
        let commit = PendingHandoff(key: key("p"), revision: edit, remote: committed, kind: .uploaded, createdAt: date)
        let manifest = try XCTUnwrap(store)
        try await startPendingEdit()
        // The edit commits after the delete is stored and before the trash of the earlier upload is sent.
        effects.onVolumeLookup = { _ = manifest.recordHandoff(commit) }

        await coordinator.exclude([key("p").localUID])

        let deadline = ContinuousClock.now + .seconds(5)
        while effects.trashed.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.trashed, [[earlier], [committed]])
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.remote, committed)
        XCTAssertTrue(state.remoteTrashed)
        XCTAssertFalse(state.needsRemoteTrash)
    }

    /// Only the earlier upload of a deleted edit needs the related-files check. The delete of an uploaded photo
    /// trashes it as before, even when another source shares it, and asks the server nothing.
    /// Mutation: check the related files before every trash in `performRemote`; the server is asked, and the shared
    /// photo stays.
    func testDeletingAnUploadedPhotoMakesNoRelatedLookup() async throws {
        await coordinator.close()
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("duplicate", linkID: "link-sent"))
        let relations = FakeChecker()
        _ = try makeJournalCoordinator(identities: identities, relations: relations)
        enqueue("sent", state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(
            source: source("sent"), revision: revision, remote: PhotoUID(volumeID: "", nodeID: "link-sent"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }

        await coordinator.exclude([PhotoUID(localPending: .photoLibrary, identifier: "sent")])

        XCTAssertEqual(effects.trashed, [[PhotoUID(volumeID: "photos-volume", nodeID: "link-sent")]])
        XCTAssertEqual(store.sourceState(for: key("sent"))?.remoteTrashed, true)
        XCTAssertTrue(relations.relatedLookups.isEmpty, "an ordinary delete makes no server call per photo")
    }

    func testRestoringADeletedEditBringsTheEarlierUploadBackBeforeTheBackupSeesIt() async throws {
        try await startPendingEdit()
        await coordinator.exclude([key("p").localUID])

        await coordinator.restore([key("p").localUID])

        XCTAssertEqual(effects.restored, [[earlier]])
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
        XCTAssertEqual(effects.returned, [[key("p")]])
    }

    func testRestoringAfterAnUndoInPhotosBringsTheEarlierUploadBack() async throws {
        try await startPendingEdit()
        await coordinator.exclude([key("p").localUID])

        // The person reverts the edit in Photos while the photo is deleted in the app.
        let undo = UploadBackupRevision(rawValue: edit.rawValue + 1)
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("p"), revision: undo, originalFilename: "p.heic", state: .discovered,
                    updatedAt: date)))
        await coordinator.restore([key("p").localUID])

        XCTAssertEqual(effects.restored, [[earlier]], "the earlier upload holds the reverted bytes again")
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
    }

    func testRetryableActionFailureKeepsTheAction() async throws {
        enqueue("album", state: .uploading)
        effects.albumResult = .retry
        await coordinator.start()
        _ = await coordinator.addToAlbum([PhotoUID(localPending: .photoLibrary, identifier: "album")], albumID: "a1")
        recorder.recordHandoff(
            source: source("album"), revision: revision, remote: PhotoUID(volumeID: "vol", nodeID: "x"),
            kind: .uploaded)
        await waitForSnapshot("handoff known") { $0.tiles.first?.handoff != nil }
        await coordinator.noteRemotePresence([key("album")])

        let action = try XCTUnwrap(store.actions().first)
        XCTAssertFalse(action.failed)
        XCTAssertEqual(action.attempts, 1)
    }

    // MARK: - Unreadable source states (#770)

    /// An undecodable due row next to healthy rows. The coordinator retries with backoff instead of every second, and
    /// after a repair and a reopen the owed trash of both sources still runs.
    func testAnUndecodableDueStateRetriesWithBackoffAndItsTrashSurvivesARepair() async throws {
        let requests = ["good", "bad"].map {
            PendingExclusionRequest(
                key: key($0), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: "link-\($0)"))
        }
        XCTAssertNotNil(store.exclude(requests, at: date))
        try setDesired("invalid", of: "bad")
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5), unreadableRetryLimit: .seconds(120),
            sleep: { duration in
                delays.append(duration)
                // The first two retries return at once, so the test sees the next delays; the third one waits.
                if duration >= .seconds(60), delays.values.filter({ $0 >= .seconds(60) }).count <= 2 { return }
                try await Task.sleep(for: .seconds(3600))
            })

        await coordinator.start()

        let deadline = ContinuousClock.now + .seconds(5)
        while delays.values.filter({ $0 >= .seconds(60) }).count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            delays.values.filter { $0 >= .seconds(60) }, [.seconds(60), .seconds(120), .seconds(120)],
            "an unreadable row retries after a minute, doubling up to the limit")
        XCTAssertFalse(delays.values.contains(.seconds(1)), "an unreadable row must not retry every second")
        XCTAssertFalse(effects.trashed.joined().contains { $0.nodeID == "link-bad" })
        XCTAssertTrue(
            effects.trashed.joined().contains { $0.nodeID == "link-good" },
            "the healthy row is trashed in the same session")

        await coordinator.close()
        try setDesired("excluded", of: "bad")
        try reopenStore()
        coordinator = makeCoordinator()
        await coordinator.start()

        let trashed = Set(effects.trashed.joined().map(\.nodeID))
        XCTAssertTrue(trashed.contains("link-bad"), "the owed trash survives the repair")
        XCTAssertTrue(trashed.contains("link-good"))
    }

    /// The state of an excluded source cannot be read. Its favorite action must wait, not run as if nothing were owed.
    func testAnActionWaitsWhileItsSourceStateCannotBeRead() async throws {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-fav")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("fav"), presentation: nil, remote: remote)], at: date))
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key("fav"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        XCTAssertTrue(store.setFavoriteIntent(key("fav"), favorite: true, at: date))
        try setDesired("invalid", of: "fav")
        await coordinator.close()
        coordinator = makeCoordinator()

        await coordinator.start()

        XCTAssertTrue(effects.favorites.isEmpty, "an unreadable state is no permission to act")
        XCTAssertEqual(store.actions().filter { $0.key == key("fav") && !$0.failed }.count, 1, "the action stays owed")

        await coordinator.close()
        try setDesired("included", of: "fav")
        try reopenStore()
        coordinator = makeCoordinator()
        await coordinator.start()
        XCTAssertEqual(effects.favorites, [remote], "after the repair the owed action runs")
    }

    /// The load at start cannot read one state, so a source without any state is unknown, too: its favorite waits.
    /// After a repair in the same session, the next retry reads every state again and the favorite runs.
    func testARepairedStateIsReadAgainByTheNextRetry() async throws {
        XCTAssertNotNil(
            store.exclude(
                [PendingExclusionRequest(key: key("bad"), presentation: nil, remote: nil)], at: date))
        XCTAssertTrue(
            Self.setColumns(
                "desired='invalid', needs_queue_sync=0", of: "bad",
                at: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-free")
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key("free"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        XCTAssertTrue(store.setFavoriteIntent(key("free"), favorite: true, at: date))
        let retry = OpenGate()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                if duration >= .seconds(60) { await retry.wait() } else { try await Task.sleep(for: duration) }
            })
        await coordinator.start()
        XCTAssertTrue(effects.favorites.isEmpty, "while one state is unreadable, a source without state is unknown")

        try setDesired("excluded", of: "bad")
        retry.open()

        let deadline = ContinuousClock.now + .seconds(5)
        while effects.favorites.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.favorites, [remote], "the retry reads every state again and runs the owed action")
    }

    /// The source returns to the backup, and its state becomes unreadable while the return runs. Its last known state
    /// would allow the favorite, but the current one is unknown, so the favorite waits until a read succeeds.
    func testAnActionWaitsWhenItsStateBecomesUnreadableAfterAnEffect() async throws {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-back")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("back"), presentation: nil, remote: nil)], at: date))
        XCTAssertNotNil(store.include([key("back")], at: date))
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key("back"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        XCTAssertTrue(store.setFavoriteIntent(key("back"), favorite: true, at: date))
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        effects.onReturn = { try? Self.setDesired("invalid", of: "back", at: url) }
        let retry = OpenGate()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                if duration >= .seconds(60) { await retry.wait() } else { try await Task.sleep(for: duration) }
            })

        await coordinator.start()

        XCTAssertEqual(effects.returned, [[key("back")]])
        XCTAssertTrue(
            effects.favorites.isEmpty, "the last known state is no permission while the current one is unknown")

        // The repaired state owes no further effect, so only the retry of the unreadable source reads it again.
        XCTAssertTrue(
            Self.setColumns(
                "desired='included', needs_queue_sync=0", of: "back",
                at: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        retry.open()
        let deadline = ContinuousClock.now + .seconds(5)
        while effects.favorites.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.favorites, [remote], "once the state reads again, the owed action runs")
    }

    /// Every state read at start. A due row becomes undecodable later; the next reconcile also backs off.
    func testADueRowThatBecomesUnreadableLaterRetriesWithBackoff() async throws {
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                try await Task.sleep(for: .seconds(3600))
            })
        await coordinator.start()
        let request = PendingExclusionRequest(
            key: key("late"), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: "link-late"))
        XCTAssertNotNil(store.exclude([request], at: date))
        try setDesired("invalid", of: "late")

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        let deadline = ContinuousClock.now + .seconds(5)
        while !delays.values.contains(.seconds(60)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(delays.values.contains(.seconds(60)), "a due row that cannot be read retries after a minute")
        XCTAssertFalse(delays.values.contains(.seconds(1)))
    }

    /// A trash finished, the store now owes the trash of a later commit, and the source's keyed read fails. The pass
    /// must not trust the last known state and dispatch the new trash again and again; it waits for the backoff.
    func testATrashWhoseStateCannotBeReadAfterwardsIsNotDispatchedAgainInTheSamePass() async throws {
        XCTAssertNotNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key("s"), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: "a"))
                ],
                at: date))
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 500)", of: "s", at: url))
        let gate = OpenGate()
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                if duration == .seconds(500) { await gate.wait() } else { try await Task.sleep(for: .seconds(3600)) }
            })
        await coordinator.start()
        let started = ContinuousClock.now + .seconds(5)
        while !delays.values.contains(.seconds(500)), ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(5))
        }
        // The store now owes the trash of photo B, while the coordinator still knows photo A.
        XCTAssertTrue(
            Self.setColumns("remote_link_id='b', next_attempt_at=\(date.timeIntervalSince1970)", of: "s", at: url))
        let failure = KeyedReadFailure()
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        gate.open()

        let deadline = ContinuousClock.now + .seconds(5)
        while !delays.values.contains(.seconds(60)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertEqual(effects.trashed.joined().filter { $0.nodeID == "b" }.count, 1, "photo B is sent once per pass")
        XCTAssertTrue(delays.values.contains(.seconds(60)), "the source waits for the backoff")
        await coordinator.close()
        failure.remove(from: store)
    }

    /// The load at start was complete. A later due read cannot read another source's row, so it may have left out
    /// this source's current state too: its favorite waits until a complete read, then runs once.
    func testAnActionWaitsWhileALaterDueReadIsIncomplete() async throws {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        XCTAssertNotNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key("bad"), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: "x"))
                ],
                at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: "bad", at: url))
        // A known included state, so only the incomplete due read can hold the favorite.
        includedLater("fav")
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-fav")
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key("fav"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        let retry = OpenGate()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                if duration == .seconds(60) { await retry.wait() } else { try await Task.sleep(for: .seconds(3600)) }
            })
        await coordinator.start()
        XCTAssertTrue(
            Self.setColumns("desired='invalid', next_attempt_at=\(date.timeIntervalSince1970)", of: "bad", at: url))
        XCTAssertTrue(store.setFavoriteIntent(key("fav"), favorite: true, at: date))

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        XCTAssertTrue(effects.favorites.isEmpty, "an incomplete due read is no permission to act")
        XCTAssertTrue(Self.setColumns("desired='excluded'", of: "bad", at: url))
        retry.open()
        let deadline = ContinuousClock.now + .seconds(5)
        while effects.favorites.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(effects.favorites, [remote], "after a complete read the action runs once")
    }

    /// The same incomplete due read decoded this source's own row, so its favorite may still run.
    func testAnIncompleteDueReadStillLetsTheSourcesItDecodedAct() async throws {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let later = date.timeIntervalSince1970 + 5000
        XCTAssertNotNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key("bad"), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: "x"))
                ],
                at: date))
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("fav"), presentation: nil, remote: nil)], at: date))
        XCTAssertNotNil(store.include([key("fav")], at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(later)", of: "bad", at: url))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(later)", of: "fav", at: url))
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-fav")
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key("fav"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await coordinator.start()
        let now = date.timeIntervalSince1970
        XCTAssertTrue(Self.setColumns("desired='invalid', next_attempt_at=\(now)", of: "bad", at: url))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(now)", of: "fav", at: url))
        XCTAssertTrue(store.setFavoriteIntent(key("fav"), favorite: true, at: date))
        keepStateAfterReturn("fav")

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        XCTAssertEqual(effects.returned, [[key("fav")]], "the due read decoded the source")
        XCTAssertEqual(effects.favorites, [remote], "a source that the incomplete read decoded may act")
    }

    /// While one row cannot be read, a readable row keeps its own retry time instead of waiting for the backoff.
    func testAReadableRetryKeepsItsTimeWhileAnotherRowIsUnreadable() async throws {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let requests = ["healthy", "bad"].map {
            PendingExclusionRequest(key: key($0), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: $0))
        }
        XCTAssertNotNil(store.exclude(requests, at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 90)", of: "healthy", at: url))
        try setDesired("invalid", of: "bad")
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                if delays.values.count == 1 { return }
                try await Task.sleep(for: .seconds(3600))
            })

        await coordinator.start()

        let deadline = ContinuousClock.now + .seconds(5)
        while delays.values.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(
            delays.values, [.seconds(60), .seconds(90)], "the backoff is 120 s, the readable row is due at 90 s")
    }

    /// A second incomplete load keeps the last known state of a source that it could not list, so a restore from the
    /// Proton trash still finds the deleted source.
    func testASecondIncompleteLoadKeepsTheLastKnownStates() async throws {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let requests = ["kept", "bad"].map {
            PendingExclusionRequest(
                key: key($0), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: "link-\($0)"))
        }
        XCTAssertNotNil(store.exclude(requests, at: date))
        try setDesired("invalid", of: "bad")
        let gate = OpenGate()
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                if delays.values.filter({ $0 >= .seconds(60) }).count == 1 {
                    await gate.wait()
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            })
        await coordinator.start()
        var deadline = ContinuousClock.now + .seconds(5)
        while !effects.trashed.joined().contains(where: { $0.nodeID == "link-kept" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let failure = SourceListFailure()
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        gate.open()

        deadline = ContinuousClock.now + .seconds(5)
        while delays.values.filter({ $0 >= .seconds(60) }).count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(failure.denied, "the second load must fail")
        failure.remove(from: store)
        await coordinator.restoreSources(ofRemote: [PhotoUID(volumeID: "vol", nodeID: "link-kept")])
        XCTAssertEqual(
            effects.restored.joined().map(\.nodeID), ["link-kept"], "the last known state finds the deleted source")
    }

    func testAZeroRetryDelayStillWaitsASecond() {
        XCTAssertEqual(
            PendingBackupCoordinator.Configuration(unreadableRetryDelay: .zero).unreadableRetryDelay, .seconds(1))
    }

    /// Once every read succeeds again, the next unreadable episode in the same session starts at the base delay.
    func testABackoffStartsAgainAfterTheStatesReadAgain() async throws {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        let requests = ["first", "second"].map {
            PendingExclusionRequest(key: key($0), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: $0))
        }
        XCTAssertNotNil(store.exclude(requests, at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 100_000)", of: "second", at: url))
        try setDesired("invalid", of: "first")
        let gate = OpenGate()
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                let backoff = duration >= .seconds(60) && duration <= .seconds(1800)
                if backoff { delays.append(duration) }
                if backoff, delays.values.count == 1 { return }
                if backoff, delays.values.count == 2 {
                    await gate.wait()
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            })
        await coordinator.start()
        var deadline = ContinuousClock.now + .seconds(5)
        while delays.values.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }

        try setDesired("excluded", of: "first")
        gate.open()
        deadline = ContinuousClock.now + .seconds(5)
        while !effects.trashed.joined().contains(where: { $0.nodeID == "first" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            Self.setColumns("desired='invalid', next_attempt_at=\(date.timeIntervalSince1970)", of: "second", at: url))
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        deadline = ContinuousClock.now + .seconds(5)
        while delays.values.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(
            delays.values, [.seconds(60), .seconds(120), .seconds(60)], "a new episode starts at one minute")
    }

    // MARK: - Unreadable source states, round 2 (#770)

    private func favoriteFixture(_ id: String) -> PhotoUID {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-\(id)")
        XCTAssertNotEqual(
            store.recordHandoff(
                PendingHandoff(key: key(id), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .failed)
        return remote
    }

    private var storeURL: URL { directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName) }

    /// An included source with a queue sync that is due only later.
    private func includedLater(_ id: String) {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: nil)], at: date))
        XCTAssertNotNil(store.include([key(id)], at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: id, at: storeURL))
    }

    /// An excluded source with a Proton photo whose trash is due only later.
    private func excludedLater(_ id: String) {
        XCTAssertNotNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key(id), presentation: nil, remote: PhotoUID(volumeID: "vol", nodeID: id))
                ],
                at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: id, at: storeURL))
    }

    /// A newer decision lands while the source returns to the backup, so the store keeps its included state with a
    /// queue sync that is due only later: the source keeps a known state after the pass.
    private func keepStateAfterReturn(_ id: String) {
        let later = date.timeIntervalSince1970 + 5000
        effects.onReturn = { [storeURL] in
            XCTAssertTrue(
                PendingBackupCoordinatorTests.setColumns(
                    "generation=generation+1, next_attempt_at=\(later)", of: id, at: storeURL))
        }
    }

    private func restartIdle() async {
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await coordinator.start()
    }

    /// The start load could not read one row. A later incomplete load no longer decodes a source either; its last
    /// known "included" state is kept for timing, but it must not let an owed favorite run.
    func testAStaleStateFromAnIncompleteLoadDoesNotAuthorizeAnAction() async throws {
        excludedLater("bad")
        includedLater("k")
        let remote = favoriteFixture("k")
        try setDesired("invalid", of: "bad")
        await restartIdle()
        XCTAssertTrue(Self.setColumns("desired='invalid'", of: "k", at: storeURL))
        XCTAssertTrue(store.setFavoriteIntent(key("k"), favorite: true, at: date))

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        XCTAssertTrue(effects.favorites.isEmpty, "a stale state from an incomplete load is no permission to act")
        XCTAssertEqual(store.actions().filter { $0.key == key("k") && !$0.failed }.count, 1, "the action stays owed")
        try setDesired("excluded", of: "bad")
        XCTAssertTrue(Self.setColumns("desired='included'", of: "k", at: storeURL))
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "again")])
        XCTAssertEqual(effects.favorites, [remote], "after a complete load the action runs")
    }

    /// A source that the incomplete load decoded may still act.
    func testASourceThatAnIncompleteLoadDecodedStillActs() async throws {
        excludedLater("bad")
        includedLater("k")
        try setDesired("invalid", of: "bad")
        await restartIdle()
        let remote = favoriteFixture("k")
        XCTAssertTrue(store.setFavoriteIntent(key("k"), favorite: true, at: date))

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        XCTAssertEqual(effects.favorites, [remote])
    }

    /// While a pass waits for a remote effect, an action request must already see that this pass's due read was
    /// incomplete; the permission of the earlier, complete pass no longer applies.
    func testAnActionDuringAPassUsesThatPassesDueRead() async throws {
        excludedLater("x")
        excludedLater("bad")
        // A known included state, so only the due read of the running pass can hold the favorite.
        includedLater("y")
        let remote = favoriteFixture("y")
        await restartIdle()
        let gate = LookupGate()
        effects.trashGate = gate
        let now = date.timeIntervalSince1970
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(now)", of: "x", at: storeURL))
        XCTAssertTrue(Self.setColumns("desired='invalid', next_attempt_at=\(now)", of: "bad", at: storeURL))
        let running = try XCTUnwrap(coordinator)
        let pass = Task { await running.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")]) }
        guard await gate.entered(within: .seconds(5)) else {
            XCTFail("the trash of the running pass never reached the gate")
            _ = await pass.value
            return
        }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "y")], favorite: true)

        XCTAssertTrue(effects.favorites.isEmpty, "the running pass's incomplete due read already holds the action")
        try setDesired("excluded", of: "bad")
        gate.open()
        _ = await pass.value
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "again")])
        XCTAssertEqual(effects.favorites, [remote], "after a complete read the action runs")
    }

    func testAZeroOrNegativeRetryLimitStillWaitsASecond() async throws {
        excludedLater("bad")
        XCTAssertTrue(
            Self.setColumns("desired='invalid', next_attempt_at=\(date.timeIntervalSince1970)", of: "bad", at: storeURL)
        )
        for limit in [Duration.zero, .seconds(-5)] {
            let delays = DelayLog()
            await coordinator.close()
            // A decode failure stays recorded on the open store; each coordinator starts on a fresh connection.
            try reopenStore()
            coordinator = makeCoordinator(
                checkmarkDuration: .seconds(5), unreadableRetryLimit: limit,
                sleep: { duration in
                    delays.append(duration)
                    if delays.values.count < 3 { return }
                    try await Task.sleep(for: .seconds(3600))
                })
            await coordinator.start()
            let deadline = ContinuousClock.now + .seconds(5)
            while delays.values.count < 3, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(delays.values.prefix(3).count, 3, "\(limit)")
            XCTAssertTrue(delays.values.prefix(3).allSatisfy { $0 >= .seconds(1) }, "limit \(limit): \(delays.values)")
        }
    }

    /// A limit below the first retry delay caps the first wait as well.
    func testARetryLimitBelowTheFirstDelayCapsTheFirstWait() async throws {
        excludedLater("bad")
        XCTAssertTrue(
            Self.setColumns("desired='invalid', next_attempt_at=\(date.timeIntervalSince1970)", of: "bad", at: storeURL)
        )
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5), unreadableRetryLimit: .seconds(30),
            sleep: { duration in
                delays.append(duration)
                try await Task.sleep(for: .seconds(3600))
            })
        await coordinator.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while delays.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(delays.values.first, .seconds(30))
    }

    /// The doubling stops at the limit. Near the largest Duration, a doubled wait would overflow; the wait stays at the
    /// limit instead.
    func testABackoffNearTheLargestDurationStaysAtTheLimit() async throws {
        excludedLater("bad")
        XCTAssertTrue(
            Self.setColumns("desired='invalid', next_attempt_at=\(date.timeIntervalSince1970)", of: "bad", at: storeURL)
        )
        // Above half of the largest Duration, so that twice this limit overflows.
        let limit = Duration.seconds(Int64.max) * 10
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5), unreadableRetryDelay: limit, unreadableRetryLimit: limit,
            sleep: { duration in
                guard duration >= .seconds(60) else { return try await Task.sleep(for: .seconds(3600)) }
                delays.append(duration)
                if delays.values.count < 3 { return }
                try await Task.sleep(for: .seconds(3600))
            })
        await coordinator.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while delays.values.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(delays.values.prefix(3), [limit, limit, limit])
    }

    /// A readable row whose retry date already passed does not shorten the wait to a second.
    func testAReadableStateWithAPastRetryDateKeepsTheBackoff() async throws {
        excludedLater("bad")
        includedLater("stuck")
        let now = date.timeIntervalSince1970
        XCTAssertTrue(Self.setColumns("desired='invalid', next_attempt_at=\(now)", of: "bad", at: storeURL))
        // A restore without a Proton photo is never sent, so this readable row stays due with a past date.
        XCTAssertTrue(
            Self.setColumns(
                "needs_queue_sync=0, needs_remote_restore=1, remote_volume_id=NULL, remote_link_id=NULL, "
                    + "next_attempt_at=\(now - 10)", of: "stuck", at: storeURL))
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                try await Task.sleep(for: .seconds(3600))
            })
        await coordinator.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while delays.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(delays.values.first, .seconds(60))
    }

    /// A complete load forgets the state of a source that left the store, so its action may run again.
    func testACompleteLoadForgetsStatesThatLeftTheStore() async throws {
        excludedLater("bad")
        excludedLater("k")
        try setDesired("invalid", of: "bad")
        await restartIdle()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "DELETE FROM source_state WHERE source_id='k';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        try setDesired("excluded", of: "bad")
        let remote = favoriteFixture("k")
        XCTAssertTrue(store.setFavoriteIntent(key("k"), favorite: true, at: date))

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        XCTAssertEqual(effects.favorites, [remote], "the complete load no longer knows the old exclusion")
    }

    /// The permission of an incomplete due read belongs to its own pass. A source decoded one pass earlier but no
    /// longer due is not decoded in the next incomplete pass, so its action waits.
    func testTheDecodedSourcesOfAnEarlierPassDoNotCarryOver() async throws {
        excludedLater("bad")
        includedLater("y")
        await restartIdle()
        let now = date.timeIntervalSince1970
        XCTAssertTrue(Self.setColumns("desired='invalid', next_attempt_at=\(now)", of: "bad", at: storeURL))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(now)", of: "y", at: storeURL))
        keepStateAfterReturn("y")
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "first")])
        XCTAssertEqual(effects.returned, [[key("y")]], "the first incomplete pass decoded the source")
        _ = favoriteFixture("y")
        XCTAssertTrue(store.setFavoriteIntent(key("y"), favorite: true, at: date))

        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "second")])

        XCTAssertTrue(effects.favorites.isEmpty, "the next incomplete pass did not decode the source")
    }

    // MARK: - Unreadable source states, round 3 (#770)

    /// An excluded source whose queue sync is due now, with a favorite that waits for it.
    private func excludedWithFavorite(_ id: String) -> PhotoUID {
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: nil)], at: date))
        let remote = favoriteFixture(id)
        XCTAssertTrue(store.setFavoriteIntent(key(id), favorite: true, at: date))
        return remote
    }

    /// Breaks the key of a source row, so a keyed read finds nothing while the full reads fail to decode it.
    private func breakKeyWhileItLeavesTheBackup(_ id: String) {
        effects.onRemove = { [storeURL] in
            XCTAssertTrue(PendingBackupCoordinatorTests.setColumns("source_kind='broken'", of: id, at: storeURL))
        }
    }

    private func sourceRows(_ id: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return -1
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM source_state WHERE source_id='\(id)';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }

    /// The incomplete load and the first due reads decoded the excluded source. While its queue sync runs, its key
    /// stops decoding: the keyed reread finds no row, and the next due read is incomplete. The absent answer is no
    /// permission: the favorite waits, stays owed, and the damaged row stays.
    func testAnAbsentRereadOfADamagedRowAfterAnIncompleteLoadIsNoPermission() async throws {
        excludedLater("bad")
        try setDesired("invalid", of: "bad")
        _ = excludedWithFavorite("k")
        breakKeyWhileItLeavesTheBackup("k")

        await restartIdle()

        XCTAssertEqual(effects.removed, [["k"]], "the queue sync ran while the key broke")
        XCTAssertTrue(effects.favorites.isEmpty, "an absent reread is no permission while a read is incomplete")
        XCTAssertEqual(store.actions().filter { $0.key == key("k") && !$0.failed }.count, 1, "the action stays owed")
        XCTAssertEqual(sourceRows("k"), 1, "the damaged row is still stored")
    }

    /// The same damage after a complete load: the incomplete due read alone already makes the absent answer
    /// unreliable.
    func testAnAbsentRereadOfADamagedRowWhileADueReadIsIncompleteIsNoPermission() async throws {
        _ = excludedWithFavorite("k")
        breakKeyWhileItLeavesTheBackup("k")

        await restartIdle()

        XCTAssertEqual(effects.removed, [["k"]], "the queue sync ran while the key broke")
        XCTAssertTrue(effects.favorites.isEmpty, "an absent reread is no permission while a due read is incomplete")
        XCTAssertEqual(store.actions().filter { $0.key == key("k") && !$0.failed }.count, 1, "the action stays owed")
    }

    /// After an incomplete load that decoded the source, its key stops decoding and a keyed reread finds no row.
    /// The due reads stay complete, because the source owes nothing yet; the incomplete load alone holds the favorite.
    func testAnAbsentRereadAfterAnIncompleteLoadIsNoPermission() async throws {
        excludedLater("bad")
        try setDesired("invalid", of: "bad")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("k"), presentation: nil, remote: nil)], at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: "k", at: storeURL))
        await restartIdle()
        XCTAssertTrue(Self.setColumns("source_kind='broken'", of: "k", at: storeURL))
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "k")
        let unlisted = await coordinator.removeFromTrashList([uid])
        XCTAssertTrue(unlisted, "the keyed reread answers absent")
        _ = favoriteFixture("k")

        _ = await coordinator.setFavorite([uid], favorite: true)

        XCTAssertTrue(effects.favorites.isEmpty, "an absent reread is no permission after an incomplete load")
        XCTAssertEqual(store.actions().filter { $0.key == key("k") && !$0.failed }.count, 1, "the action stays owed")
    }

    /// Counter-test: after complete reads, a source whose row really left the store reads as absent and acts.
    func testAnAbsentRereadAfterCompleteReadsStillActs() async throws {
        let remote = excludedWithFavorite("k")
        effects.onRemove = { [storeURL] in
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            XCTAssertEqual(
                sqlite3_exec(handle, "DELETE FROM source_state WHERE source_id='k';", nil, nil, nil), SQLITE_OK)
            sqlite3_close(handle)
        }

        await restartIdle()

        XCTAssertEqual(effects.removed, [["k"]])
        XCTAssertEqual(effects.favorites, [remote], "a healthy absent source after complete reads acts")
    }

    /// An action that arrives while a pass waits for a remote effect sees the sources that this pass decoded, not
    /// those of the earlier incomplete pass.
    func testAReentrantActionDoesNotUseTheDecodedSourcesOfAnEarlierPass() async throws {
        excludedLater("bad")
        excludedLater("x")
        includedLater("y")
        await restartIdle()
        let now = date.timeIntervalSince1970
        XCTAssertTrue(Self.setColumns("desired='invalid', next_attempt_at=\(now)", of: "bad", at: storeURL))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(now)", of: "y", at: storeURL))
        keepStateAfterReturn("y")
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "first")])
        XCTAssertEqual(effects.returned, [[key("y")]], "the first incomplete pass decoded the source")
        let remote = favoriteFixture("y")
        let gate = LookupGate()
        effects.trashGate = gate
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(now)", of: "x", at: storeURL))
        let running = try XCTUnwrap(coordinator)
        let pass = Task { await running.restore([PhotoUID(localPending: .photoLibrary, identifier: "second")]) }
        guard await gate.entered(within: .seconds(5)) else {
            XCTFail("the trash of the second pass never reached the gate")
            _ = await pass.value
            return
        }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "y")], favorite: true)

        XCTAssertTrue(effects.favorites.isEmpty, "the earlier pass's decoded sources are no permission")
        try setDesired("excluded", of: "bad")
        gate.open()
        _ = await pass.value
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "again")])
        XCTAssertEqual(effects.favorites, [remote], "after a complete read the action runs")
    }

    // MARK: - Unreadable handoffs and actions (#770 part 2)

    /// The read of the latest handoff of one source, as `runDueActions`, `scheduleActionTimer` and the delete of an
    /// edit run it.
    private static let latestHandoffRead = "ORDER BY created_at DESC, revision_us DESC LIMIT 1"

    /// Runs one statement through a second SQLite connection and reports whether it changed exactly one row.
    private func change(_ sql: String) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK && sqlite3_changes(db) == 1
    }

    /// A coordinator that records every wait it requests. Its first backoff wait (60 s to 30 min) waits for `retry`;
    /// every other wait sleeps for an hour.
    private func restartWithBackoffLog(_ delays: DelayLog, firstRetry retry: OpenGate) async {
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                if Self.backoffs(delays.values).count == 1, Self.isBackoff(duration) {
                    await retry.wait()
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            })
        await coordinator.start()
    }

    private static func isBackoff(_ duration: Duration) -> Bool {
        duration >= .seconds(60) && duration <= .seconds(1800)
    }

    /// The backoff waits among the recorded waits; a healthy wait for a far retry time is longer.
    private static func backoffs(_ waits: [Duration]) -> [Duration] { waits.filter(isBackoff) }

    /// No wait shorter than the first backoff: an unreadable action never retries every second.
    private func assertNoShortWait(_ delays: DelayLog, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            delays.values.contains { $0 < .seconds(60) }, "short waits: \(delays.values)", file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// How long exact and negative checks of the recorded waits give a timer task to record. A timer records its wait
    /// when its task starts, after the call that scheduled it returned. A negative check observes only this bounded
    /// window: a wrong timer that registers later is missed (a false pass, never a false failure).
    private static let settleWindow = Duration.milliseconds(300)

    private func settle() async throws {
        try await Task.sleep(for: Self.settleWindow)
    }

    /// The handoff of a pending photo is stored, but its read fails. The favorite neither waits for a handoff event
    /// that never comes nor runs: it stays owed, unchanged, and the reconcile backoff tries again. A second request
    /// meanwhile keeps the wait. Once the read succeeds, the favorite runs and the backoff ends.
    func testAnActionRunsAfterItsHandoffCouldNotBeRead() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let uid = PhotoUID(localPending: .photoLibrary, identifier: "k")

        _ = await coordinator.setFavorite([uid], favorite: true)
        _ = await coordinator.setFavorite([uid], favorite: true)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertTrue(effects.favorites.isEmpty, "an unreadable handoff is no Proton photo to act on")
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "one degraded wait; a second request keeps it")
        assertNoShortWait(delays)
        let owed = store.actions().filter { $0.key == key("k") }
        XCTAssertEqual(owed.count, 1, "the action is neither completed nor removed")
        XCTAssertEqual(owed.first?.attempts, 0)
        XCTAssertEqual(owed.first?.failed, false, "the action is not failed")
        failure.remove(from: store)
        retry.open()
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote], "the retry reads the handoff and runs the owed action")
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])
        try await settle()
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "after every read succeeds, the backoff ends")
        assertNoShortWait(delays)
    }

    /// The handoff row does not decode. Its favorite is retried by the backoff, not left to an event.
    func testAnActionWhoseHandoffDoesNotDecodeIsRetried() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        XCTAssertTrue(change("UPDATE handoff SET kind='broken' WHERE source_id='k';"))
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "an undecodable handoff is retried after a minute")
        assertNoShortWait(delays)
        XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='k';"))
        retry.open()
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote])
    }

    /// Counter-test: a source without any handoff still waits for its handoff event, without a timer or a backoff.
    func testAnActionWithoutAHandoffStillWaitsForItsEvent() async throws {
        includedLater("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])
        try await settle()

        XCTAssertTrue(Self.backoffs(delays.values).isEmpty, "a confirmed absent handoff starts no backoff")
        assertNoShortWait(delays)
        XCTAssertTrue(effects.favorites.isEmpty)
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-k")
        recorder.recordHandoff(source: source("k"), revision: revision, remote: remote, kind: .uploaded)
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote], "the handoff event starts the action")
        retry.open()
    }

    /// Every read of the pending actions fails at start. The owed favorite is retried by the backoff; once the reads
    /// succeed it runs, and the backoff ends.
    func testAnActionRunsAfterTheActionListCouldNotBeRead() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        XCTAssertTrue(store.setFavoriteIntent(key("k"), favorite: true, at: date))
        let failure = SourceListFailure(table: "pending_action", untilRemoved: true)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let delays = DelayLog()
        let retry = OpenGate()

        await restartWithBackoffLog(delays, firstRetry: retry)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertTrue(failure.denied)
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "an unreadable action list waits a minute")
        assertNoShortWait(delays)
        failure.remove(from: store)
        retry.open()
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote])
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])
        try await settle()
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "after every read succeeds, the backoff ends")
        assertNoShortWait(delays)
    }

    /// One action row does not decode. A healthy action runs in the same pass, and the retries stay bounded.
    func testAnUndecodableActionRowDoesNotHoldTheOthers() async throws {
        includedLater("good")
        includedLater("bad")
        let remote = favoriteFixture("good")
        _ = favoriteFixture("bad")
        XCTAssertTrue(store.setFavoriteIntent(key("good"), favorite: true, at: date))
        XCTAssertTrue(store.setFavoriteIntent(key("bad"), favorite: true, at: date))
        XCTAssertTrue(change("UPDATE pending_action SET kind='broken' WHERE source_id='bad';"))
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                guard duration >= .seconds(1), duration <= .seconds(1800) else {
                    return try await Task.sleep(for: .seconds(3600))
                }
                delays.append(duration)
                if delays.values.count < 2 { return }
                try await Task.sleep(for: .seconds(3600))
            })

        await coordinator.start()

        try await waitUntil { delays.values.count >= 2 }
        XCTAssertEqual(effects.favorites, [remote], "the healthy action runs in the same pass")
        XCTAssertEqual(delays.values.prefix(2), [.seconds(60), .seconds(120)], "the retries back off")
        XCTAssertFalse(delays.values.contains(.seconds(1)), "an undecodable action row never retries every second")
    }

    /// The delete of an edit cannot read the handoff that names its earlier upload. The journal could name another
    /// photo, so nothing goes to the trash: the delete is stored, and the manifest keeps the earlier upload.
    func testADeleteOfAnEditTrashesNothingWhenItsHandoffCannotBeRead() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        try await startPendingEditWithoutHandoff(identities: identities)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        await coordinator.exclude([key("p").localUID])

        failure.remove(from: store)
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertTrue(effects.trashed.isEmpty, "a photo chosen on an unreadable handoff is never trashed")
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.desired, .excluded, "the delete is stored")
        XCTAssertNil(state.remote)
        XCTAssertEqual(identities.record(for: source("p"))?.remoteLinkID, earlier.nodeID)
    }

    /// An album action whose handoff cannot be read is not sent, so a permanent failure of the album write can never
    /// mark it failed.
    func testAnActionWithAnUnreadableHandoffIsNeverFailed() async throws {
        includedLater("k")
        _ = favoriteFixture("k")
        effects.albumResult = .permanentFailure
        await restartIdle()
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        _ = await coordinator.addToAlbum([PhotoUID(localPending: .photoLibrary, identifier: "k")], albumID: "album")
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])

        failure.remove(from: store)
        let owed = store.actions().filter { $0.key == key("k") && $0.kind == .addToAlbum }
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.failed, false, "an action with an unreadable handoff is not failed")
        XCTAssertEqual(owed.first?.attempts, 0)
    }

    // MARK: - Unreadable handoffs and actions, round 1 (#770 part 2)

    /// The filtered read of the due actions. Only `runDueActions` runs it.
    private static let dueActionRead = "failed=0 AND next_attempt_at <= ?"

    /// The read of the due actions fails while the full list that schedules the timer still reads. The overdue
    /// favorite must wait for the backoff, never for a one-second timer.
    func testAFailedDueActionReadRetriesWithTheBackoff() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = KeyedReadFailure(matching: Self.dueActionRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "a failed due read waits for the backoff")
        assertNoShortWait(delays)
        failure.remove(from: store)
        retry.open()
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote])
    }

    /// Only the handoff read of the dispatch fails; the read that schedules the timer succeeds. The failure the
    /// dispatch saw still counts: the favorite waits for the backoff, not for a one-second timer.
    func testAFailedDispatchHandoffReadIsNotHiddenByTheSchedulingRead() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        failure.remove(from: store)
        XCTAssertEqual(failure.count, 1, "only the dispatch read failed")
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)])
        assertNoShortWait(delays)
        retry.open()
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote])
    }

    /// After an episode, a clean read of a person action outside a reconcile ends the backoff, so the next failure
    /// starts at one minute again.
    func testACleanActionReadOutsideAPassEndsTheBackoff() async throws {
        for id in ["k", "k2", "k3"] {
            includedLater(id)
            _ = favoriteFixture(id)
        }
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)
        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        failure.remove(from: store)

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k2")], favorite: true)
        XCTAssertEqual(effects.favorites.count, 2, "the clean pass runs both favorites")
        let again = KeyedReadFailure(matching: Self.latestHandoffRead)
        try again.install(on: store)
        defer { again.remove(from: store) }
        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k3")], favorite: true)
        try await waitUntil { Self.backoffs(delays.values).count >= 2 }
        try await settle()
        again.remove(from: store)

        XCTAssertEqual(
            Self.backoffs(delays.values), [.seconds(60), .seconds(60)], "a new failure starts at one minute again")
        assertNoShortWait(delays)
        retry.open()
    }

    /// A source that a restore returned to the backup still names an earlier Proton photo in its stored state. The
    /// delete of its current edit cannot read the handoff, so neither that stored photo nor the hidden earlier upload
    /// goes to the trash; the delete is stored.
    func testADeleteWithAnUnreadableHandoffTrashesNoPhotoThatTheStateStillNames() async throws {
        let retained = PhotoUID(volumeID: "vol", nodeID: "retained")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("p"), presentation: nil, remote: retained)], at: date))
        XCTAssertNotNil(store.include([key("p")], at: date))
        // Its return to the backup is due only later, so the start keeps the row and its photo.
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: "p", at: storeURL))
        XCTAssertEqual(store.sourceState(for: key("p"))?.remote, retained, "the included state keeps its photo")
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        try await startPendingEditWithoutHandoff(identities: identities)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        await coordinator.exclude([key("p").localUID])

        failure.remove(from: store)
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertTrue(effects.trashed.isEmpty, "no photo chosen on an unreadable handoff goes to the trash")
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.desired, .excluded, "the delete is stored")
        XCTAssertFalse(state.needsRemoteTrash)
        XCTAssertNil(state.remote)
    }

    /// Counter-test: with a readable handoff, the same delete trashes the hidden earlier upload, not the photo that
    /// the stored state names.
    func testADeleteWithAReadableHandoffTrashesTheHiddenEarlierUpload() async throws {
        let retained = PhotoUID(volumeID: "vol", nodeID: "retained")
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("p"), presentation: nil, remote: retained)], at: date))
        XCTAssertNotNil(store.include([key("p")], at: date))
        XCTAssertTrue(Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: "p", at: storeURL))
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        try await startPendingEditWithoutHandoff(identities: identities)

        await coordinator.exclude([key("p").localUID])

        XCTAssertEqual(effects.trashed, [[earlier]])
        XCTAssertEqual(store.sourceState(for: key("p"))?.remote, earlier)
    }

    /// The handoff of the edit's own commit has the edit's revision. It is no earlier upload, so the journal still
    /// names the photo that the delete trashes.
    func testADeleteOfAnEditWhoseOwnCommitIsStoredTrashesTheJournalPhoto() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        try await startPendingEditWithoutHandoff(identities: identities)
        let own = PhotoUID(volumeID: "vol", nodeID: "own-commit")
        let handoff = PendingHandoff(key: key("p"), revision: edit, remote: own, kind: .uploaded, createdAt: date)
        XCTAssertEqual(store.recordHandoff(handoff), .recorded)

        await coordinator.exclude([key("p").localUID])

        XCTAssertEqual(effects.trashed.first, [earlier], "the earlier upload of the journal goes to the trash first")
    }

    /// One due read per pass: the pass that reads the action also runs it, even when a second read of the due
    /// actions in the same pass would fail.
    func testOneDueReadPerPassRunsTheAction() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        await restartIdle()
        let failure = KeyedReadFailure(matching: Self.dueActionRead, skip: 1, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        failure.remove(from: store)
        XCTAssertEqual(effects.favorites, [remote], "the pass runs the action it read")
        XCTAssertEqual(failure.count, 0, "the pass reads the due actions once")
    }

    /// The read of the latest handoff cannot even be prepared. The favorite is retried by the backoff.
    func testAHandoffReadThatCannotBePreparedIsRetried() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = SourceListFailure(table: "handoff", untilRemoved: true)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertTrue(failure.denied)
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)])
        assertNoShortWait(delays)
        failure.remove(from: store)
        retry.open()
        try await waitUntil { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote])
    }

    /// An action that is due only later has an unreadable handoff. Only the read that schedules the timer sees it;
    /// it still starts the backoff, so the action is not left without any wake-up.
    func testAnUnreadableHandoffOfAnActionDueLaterIsRetried() async throws {
        includedLater("k")
        _ = favoriteFixture("k")
        XCTAssertTrue(store.setFavoriteIntent(key("k"), favorite: true, at: date))
        // Due far later, so its own timer is no backoff wait.
        let later = date.timeIntervalSince1970 + 5000
        XCTAssertTrue(change("UPDATE pending_action SET next_attempt_at=\(later) WHERE source_id='k';"))
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        // A pass with no due action: only the read that schedules the timer reads the handoff.
        _ = await coordinator.restore([PhotoUID(localPending: .photoLibrary, identifier: "other")])
        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()

        failure.remove(from: store)
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "the unreadable handoff starts the backoff")
        assertNoShortWait(delays)
        retry.open()
    }

    /// An undecodable action row is due only later. Only the full list read sees it; it still starts the backoff.
    func testAnUndecodableActionRowDueLaterIsRetried() async throws {
        includedLater("bad")
        XCTAssertTrue(store.setFavoriteIntent(key("bad"), favorite: true, at: date))
        XCTAssertTrue(
            change(
                "UPDATE pending_action SET kind='broken', next_attempt_at=\(date.timeIntervalSince1970 + 90) "
                    + "WHERE source_id='bad';"))
        let delays = DelayLog()
        let retry = OpenGate()

        await restartWithBackoffLog(delays, firstRetry: retry)

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "the incomplete list starts the backoff")
        assertNoShortWait(delays)
        retry.open()
    }

    /// While a source state cannot be read, a clean read of the actions keeps the wait of that state: it neither ends
    /// the backoff nor doubles it.
    func testACleanActionReadKeepsTheWaitOfAnUnreadableState() async throws {
        excludedLater("bad")
        XCTAssertTrue(
            Self.setColumns("desired='invalid', next_attempt_at=\(date.timeIntervalSince1970)", of: "bad", at: storeURL)
        )
        includedLater("k")
        _ = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        try await waitUntil { !Self.backoffs(delays.values).isEmpty }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        try await settle()
        XCTAssertTrue(effects.favorites.isEmpty, "the incomplete due read still holds the action (#770 part 1)")
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "the wait of the unreadable state stays")
        assertNoShortWait(delays)
        retry.open()
    }

    // MARK: - Unreadable handoffs and actions, round 2 (#770 part 2)

    /// Runs a call of `runDueActions` with two passes: the first pass sends the favorite of "b" and waits at the gate;
    /// `between` runs while it waits, then a second request makes the call read again.
    private func runTwoPassCall(between: () throws -> Void) async throws {
        let gate = LookupGate()
        effects.favoriteGate = gate
        let running = try XCTUnwrap(coordinator)
        let first = PhotoUID(localPending: .photoLibrary, identifier: "b")
        let call = Task { await running.setFavorite([first], favorite: true) }
        guard await gate.entered(within: .seconds(5)) else {
            XCTFail("the first pass never sent its favorite")
            _ = await call.value
            return
        }
        try between()
        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "a")], favorite: true)
        gate.open()
        _ = await call.value
    }

    /// The first pass of one call cannot read the handoff of "a"; the second pass of the same call reads it and runs
    /// the favorite. The failure of the first pass still counts for this call, so the reads are tried again later.
    func testAFailedHandoffReadOfAnEarlierPassInTheSameCallStillCounts() async throws {
        for id in ["a", "b"] {
            includedLater(id)
            _ = favoriteFixture(id)
        }
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        XCTAssertTrue(change("UPDATE handoff SET kind='broken' WHERE source_id='a';"))
        XCTAssertTrue(store.setFavoriteIntent(key("a"), favorite: true, at: date))

        try await runTwoPassCall {
            XCTAssertTrue(self.change("UPDATE handoff SET kind='uploaded' WHERE source_id='a';"))
        }

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertEqual(Set(effects.favorites.map(\.nodeID)), ["link-a", "link-b"], "the second pass runs the favorite")
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "the failed read of the first pass counts")
        assertNoShortWait(delays)
        retry.open()
    }

    /// The first pass of one call cannot decode a due action; the second pass decodes it. The incomplete read of the
    /// first pass still counts for this call.
    func testAnIncompleteDueReadOfAnEarlierPassInTheSameCallStillCounts() async throws {
        for id in ["a", "b"] {
            includedLater(id)
            _ = favoriteFixture(id)
        }
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        XCTAssertTrue(store.setFavoriteIntent(key("a"), favorite: true, at: date))
        XCTAssertTrue(change("UPDATE pending_action SET kind='broken' WHERE source_id='a';"))

        try await runTwoPassCall {
            XCTAssertTrue(self.change("UPDATE pending_action SET kind='favorite' WHERE source_id='a';"))
        }

        try await waitUntil { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertEqual(Set(effects.favorites.map(\.nodeID)), ["link-a", "link-b"])
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "the incomplete read of the first pass counts")
        assertNoShortWait(delays)
        retry.open()
    }

    /// Outside an episode, a clean action read leaves a healthy reconcile timer as it is.
    func testACleanActionReadDoesNotRescheduleAHealthyTimer() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        try await waitUntil { delays.values.contains(.seconds(5000)) }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)
        try await settle()

        XCTAssertEqual(effects.favorites, [remote])
        XCTAssertEqual(delays.values.filter { $0 == .seconds(5000) }.count, 1, "the healthy timer is not set again")
        XCTAssertTrue(Self.backoffs(delays.values).isEmpty)
        retry.open()
    }

    private func setDesired(_ value: String, of id: String) throws {
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        try Self.setDesired(value, of: id, at: url)
    }

    @discardableResult
    private static func setColumns(_ assignments: String, of id: String, at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "UPDATE source_state SET \(assignments) WHERE source_id='\(id)';", nil, nil, nil)
            == SQLITE_OK && sqlite3_changes(db) == 1
    }

    /// Writes through a second SQLite connection, so the store's own connection sees an unreadable row.
    private static func setDesired(_ value: String, of id: String, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "UPDATE source_state SET desired='\(value)' WHERE source_id='\(id)';", nil, nil, nil),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(db), 1)
    }

    /// A decode failure stays recorded for the open connection; a repair is seen after a reopen.
    private func reopenStore() throws {
        recorder.finish()
        store.close()
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        store = try XCTUnwrap(PendingBackupManifestStore(url: url))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
    }

    /// Holds every waiter until `open()`; afterwards `wait()` returns at once.
    private final class OpenGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters.removeAll() }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// Interrupts every read whose SQL contains `fragment` on the store's own connection, as a failing disk read would.
    /// The default is the keyed read of a source state.
    private final class KeyedReadFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var interrupted = 0
        private let fragment: String
        private var skip: Int
        private var limit: Int
        var count: Int { lock.withLock { interrupted } }

        /// Lets the first `skip` matching reads pass, then interrupts at most `limit` of them.
        init(
            matching fragment: String = "FROM source_state WHERE source_kind=? AND source_id=?", skip: Int = 0,
            limit: Int = .max
        ) {
            self.fragment = fragment
            self.skip = skip
            self.limit = limit
        }

        func install(on store: PendingBackupManifestStore) throws {
            let connection = try Self.connection(of: store)
            connection.withLock {
                _ = sqlite3_trace_v2(
                    connection.database, UInt32(SQLITE_TRACE_STMT),
                    { _, context, pointer, _ in
                        guard let context, let pointer else { return 0 }
                        let statement = OpaquePointer(pointer)
                        let failure = Unmanaged<KeyedReadFailure>.fromOpaque(context).takeUnretainedValue()
                        guard let sql = sqlite3_sql(statement).map({ String(cString: $0) }),
                            sql.contains(failure.fragment)
                        else { return 0 }
                        let interrupts = failure.lock.withLock { () -> Bool in
                            if failure.skip > 0 {
                                failure.skip -= 1
                                return false
                            }
                            guard failure.limit > 0 else { return false }
                            failure.limit -= 1
                            failure.interrupted += 1
                            return true
                        }
                        if interrupts { sqlite3_interrupt(sqlite3_db_handle(statement)) }
                        return 0
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
        }

        func remove(from store: PendingBackupManifestStore) {
            guard let connection = try? Self.connection(of: store) else { return }
            connection.withLock { _ = sqlite3_trace_v2(connection.database, 0, nil, nil) }
        }

        static func connection(of store: PendingBackupManifestStore) throws -> SQLiteStoreConnection {
            try XCTUnwrap(
                Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value
                    as? SQLiteStoreConnection)
        }
    }

    /// Denies the next read of `table` on the store's own connection, or every read until `remove` when `untilRemoved`.
    /// The default is the next full read of the source states.
    private final class SourceListFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let table: String
        private let untilRemoved: Bool
        var denied: Bool { lock.withLock { done } }

        init(table: String = "source_state", untilRemoved: Bool = false) {
            self.table = table
            self.untilRemoved = untilRemoved
        }

        func install(on store: PendingBackupManifestStore) throws {
            let connection = try KeyedReadFailure.connection(of: store)
            connection.withLock {
                _ = sqlite3_set_authorizer(
                    connection.database,
                    { context, action, table, _, _, _ in
                        guard let context, action == SQLITE_READ, let table else { return SQLITE_OK }
                        let failure = Unmanaged<SourceListFailure>.fromOpaque(context).takeUnretainedValue()
                        guard String(cString: table) == failure.table else { return SQLITE_OK }
                        return failure.lock.withLock {
                            guard !failure.done || failure.untilRemoved else { return SQLITE_OK }
                            failure.done = true
                            return SQLITE_DENY
                        }
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
        }

        func remove(from store: PendingBackupManifestStore) {
            guard let connection = try? KeyedReadFailure.connection(of: store) else { return }
            connection.withLock { _ = sqlite3_set_authorizer(connection.database, nil, nil) }
        }
    }

    private final class DelayLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Duration] = []
        var values: [Duration] { lock.withLock { recorded } }
        func append(_ duration: Duration) { lock.withLock { recorded.append(duration) } }
    }
}

private final class FakePendingMetadata: PendingSourceMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PendingSourceKey: PendingPresentationMetadata] = [:]
    private var requested = Set<PendingSourceKey>()
    private var readCounts: [PendingSourceKey: Int] = [:]
    private var gate: (@Sendable () async -> Void)?

    /// Runs after a read took its answer and before it returns.
    var fetchGate: (@Sendable () async -> Void)? {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }

    func reads(of key: PendingSourceKey) -> Int {
        lock.withLock { readCounts[key, default: 0] }
    }

    func wasRequested(_ key: PendingSourceKey) -> Bool {
        lock.withLock { requested.contains(key) }
    }

    func set(_ key: PendingSourceKey, _ value: PendingPresentationMetadata) {
        lock.withLock { values[key] = value }
    }

    func remove(_ key: PendingSourceKey) {
        _ = lock.withLock { values.removeValue(forKey: key) }
    }

    func metadata(for keys: [PendingSourceKey]) async -> [PendingSourceKey: PendingPresentationMetadata] {
        let (answer, gate) = lock.withLock {
            requested.formUnion(keys)
            for key in Set(keys) { readCounts[key, default: 0] += 1 }
            return (values.filter { keys.contains($0.key) }, gate)
        }
        await gate?()
        return answer
    }
}

private final class FakePendingEffects: PendingBackupEffects, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [[String]] = []
    private var _returned: [[PendingSourceKey]] = []
    private var _trashed: [[PhotoUID]] = []
    private var _restored: [[PhotoUID]] = []
    private var _favorites: [PhotoUID] = []
    private var _removeSucceeds = true
    private var _albumResult = PendingEffectResult.done
    private var _trashRetry = Set<PhotoUID>()
    private var _order: [String] = []

    var order: [String] { lock.withLock { _order } }

    var removed: [[String]] { lock.withLock { _removed } }
    var returned: [[PendingSourceKey]] { lock.withLock { _returned } }
    var trashed: [[PhotoUID]] { lock.withLock { _trashed } }
    var restored: [[PhotoUID]] { lock.withLock { _restored } }
    var favorites: [PhotoUID] { lock.withLock { _favorites } }
    var removeSucceeds: Bool {
        get { lock.withLock { _removeSucceeds } }
        set { lock.withLock { _removeSucceeds = newValue } }
    }
    var albumResult: PendingEffectResult {
        get { lock.withLock { _albumResult } }
        set { lock.withLock { _albumResult = newValue } }
    }
    /// Photos that the fake Proton trash leaves without an answer.
    var trashRetry: Set<PhotoUID> {
        get { lock.withLock { _trashRetry } }
        set { lock.withLock { _trashRetry = newValue } }
    }

    /// Runs once during the next removal from the backup, before the coordinator records its result.
    var onRemove: (@Sendable () -> Void)? {
        get { lock.withLock { _onRemove } }
        set { lock.withLock { _onRemove = newValue } }
    }
    private var _onRemove: (@Sendable () -> Void)?

    func removeFromBackup(kind: UploadSourceIdentity.Kind, identifiers: [String]) async -> Bool {
        let (hook, succeeds) = lock.withLock {
            _removed.append(identifiers.sorted())
            defer { _onRemove = nil }
            return (_onRemove, _removeSucceeds)
        }
        hook?()
        return succeeds
    }

    /// Runs once during the next return to the backup, before the coordinator records its result.
    var onReturn: (@Sendable () -> Void)? {
        get { lock.withLock { _onReturn } }
        set { lock.withLock { _onReturn = newValue } }
    }
    private var _onReturn: (@Sendable () -> Void)?

    func returnToBackup(_ keys: [PendingSourceKey]) async -> Bool {
        let hook = lock.withLock {
            _returned.append(keys.sorted())
            _order.append("return")
            defer { _onReturn = nil }
            return _onReturn
        }
        hook?()
        return true
    }

    /// Runs once at the next volume lookup, which comes after a delete is stored and before its trash is sent.
    var onVolumeLookup: (@Sendable () -> Void)? {
        get { lock.withLock { _onVolumeLookup } }
        set { lock.withLock { _onVolumeLookup = newValue } }
    }
    private var _onVolumeLookup: (@Sendable () -> Void)?

    func photosVolumeID() async -> String? {
        let hook = lock.withLock {
            defer { _onVolumeLookup = nil }
            return _onVolumeLookup
        }
        hook?()
        return "photos-volume"
    }

    /// Holds the next trash request until the gate opens.
    var trashGate: LookupGate? {
        get { lock.withLock { _trashGate } }
        set { lock.withLock { _trashGate = newValue } }
    }
    private var _trashGate: LookupGate?

    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        await trashGate?.pass()
        return lock.withLock {
            _trashed.append(uids)
            _order.append("trash")
            return PendingBatchEffectResult(retry: _trashRetry.intersection(uids))
        }
    }

    func restoreRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        lock.withLock {
            _restored.append(uids)
            _order.append("restore")
        }
        return .done
    }

    /// Holds the next favorite request until the gate opens.
    var favoriteGate: LookupGate? {
        get { lock.withLock { _favoriteGate } }
        set { lock.withLock { _favoriteGate = newValue } }
    }
    private var _favoriteGate: LookupGate?

    func setFavorite(_ uid: PhotoUID, favorite: Bool) async -> PendingEffectResult {
        await favoriteGate?.pass()
        lock.withLock { _favorites.append(uid) }
        return .done
    }

    func addToAlbum(_ uid: PhotoUID, albumID: String) async -> PendingEffectResult {
        lock.withLock { _albumResult }
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private actor PendingMembershipSleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class CountingPendingQueue: UploadBackupSyncQueueObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var aggregates = 0
    private var unsettled = 0
    private var observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?
    var unsettledReads: Int { lock.withLock { unsettled } }
    var aggregateReads: Int { lock.withLock { aggregates } }
    private let pending: [UploadBackupQueueRowState]
    var sourceReads: Int { lock.withLock { reads } }

    init(count: Int, date: Date) {
        pending = (0..<count).map { index in
            UploadBackupQueueRowState(
                source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "queued-\(index)"),
                revision: UploadBackupRevision(rawValue: 1), state: .queuedForUpload,
                originalFilename: "photo.heic", updatedAt: date)
        }
    }

    func setChangeObserver(_ observer: (@Sendable (UploadBackupSyncQueueChange) -> Void)?) {
        lock.withLock { self.observer = observer }
    }
    func notifyAll() {
        let callback = lock.withLock { observer }
        callback?(.all)
    }
    func unsettledRows() -> [UploadBackupQueueRowState] {
        lock.withLock { unsettled += 1 }
        return pending
    }
    func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision] {
        lock.withLock { aggregates += 1 }
        return [:]
    }
    func rows(kind: UploadSourceIdentity.Kind, identifiers: Set<String>) -> [UploadBackupQueueRowState] {
        lock.withLock { reads += identifiers.count }
        return pending.filter { identifiers.contains($0.source.identifier) }
    }
}

/// Holds the first related-files lookup until the test opens the gate; later lookups pass.
private final class LookupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var holds = 1
    private var reached = false
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let openStream: AsyncStream<Void>
    private let openContinuation: AsyncStream<Void>.Continuation

    init() {
        (enteredStream, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        (openStream, openContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func pass() async {
        let held = lock.withLock { () -> Bool in
            defer { holds -= 1 }
            if holds > 0 { reached = true }
            return holds > 0
        }
        guard held else { return }
        enteredContinuation.yield()
        for await _ in openStream { return }
    }

    /// Returns once the held lookup waits at the gate.
    func entered() async {
        for await _ in enteredStream { return }
    }

    /// Returns whether the held lookup reached the gate within `limit`. On a timeout the gate opens, so the held
    /// work and the test can finish.
    func entered(within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !lock.withLock({ reached }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard lock.withLock({ reached }) else {
            open()
            return false
        }
        return true
    }

    func open() {
        openContinuation.finish()
    }
}

/// An identity manifest that cannot tell which sources name a remote photo.
private struct UnreadableIdentityStore: UploadIdentityStore {
    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? { nil }
    func trustedRecords(contentHash: String, hashKeyEpoch: String, limit: Int) -> [UploadIdentityRecord] { [] }
    func upsert(_ record: UploadIdentityRecord) -> Bool { false }
    func sources(withRemoteLinkID linkID: String) -> [UploadSourceIdentity]? { nil }
    func forgetRemoteLinks(_ linkIDs: Set<String>, of source: UploadSourceIdentity) -> Bool { false }
}

private final class CountingPendingJournal: EditReplacementJournaling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func entry(for source: UploadSourceIdentity) -> EditReplacementJournalEntry {
        lock.withLock { count += 1 }
        return EditReplacementJournalEntry()
    }
    func keepDeleted(for source: UploadSourceIdentity) throws {}
    func backUpAgain(revision: UploadBackupRevision, for source: UploadSourceIdentity) throws {}
    func startDeletionCheck(at date: Date, for source: UploadSourceIdentity) throws {}
    func clearDeletionCheck(for source: UploadSourceIdentity) throws {}
    func clearDeletionChoice(for source: UploadSourceIdentity) throws {}
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {}
    func addRemoteSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {}
    func addProven(_ nodeID: String, inherited: [String], for source: UploadSourceIdentity) throws {}
    func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws {}
    func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {}
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws {}
    func settleGone(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {}
    func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws {}
    func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {}
}
