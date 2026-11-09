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
        clock: ResultWriteClock? = nil,
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
            now: { [date] in clock?.now ?? date },
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

    /// Runs `action` and returns the first published snapshot that matches, so the wait ends on the publish itself
    /// instead of polling a deadline. The listener can start after `action`; the stream keeps the newest snapshot
    /// (`.bufferingNewest(1)`), so this is safe only for a predicate that stays true once it is true. A caller whose
    /// predicate can turn false again could miss its match. A pass already in flight can only cause a false pass,
    /// never a false failure; without the reconcile heal publish the target test fails, so the fired timer path is
    /// the one exercised. The timeout only stops a test whose publish never comes.
    private func publishedSnapshot(
        _ description: String,
        after action: () -> Void,
        where predicate: @escaping @Sendable (PendingBackupSnapshot) -> Bool
    ) async throws -> PendingBackupSnapshot {
        let published = expectation(description: description)
        let snapshots = coordinator.snapshots
        let listener = Task { () -> PendingBackupSnapshot? in
            for await snapshot in snapshots where predicate(snapshot) {
                published.fulfill()
                return snapshot
            }
            return nil
        }
        action()
        await fulfillment(of: [published], timeout: 30)
        listener.cancel()
        let snapshot = await listener.value
        return try XCTUnwrap(snapshot, description)
    }

    /// Waits until `clock` holds a live wait of `duration`. The wait ends on the registration itself; the timeout only
    /// stops a test whose timer never registers.
    private func waitForLiveWait(
        _ duration: Duration, on clock: ResultWriteClock, _ description: String
    ) async {
        let registered = expectation(description: description)
        let waiter = Task {
            await clock.waitForLiveWait(duration)
            registered.fulfill()
        }
        await fulfillment(of: [registered], timeout: 30)
        waiter.cancel()
    }

    private func tileIDs(_ snapshot: PendingBackupSnapshot) -> [String] {
        snapshot.tiles.map(\.key.identifier)
    }

    // MARK: - Restore recheck obligations (#829 part 2)

    private final class AppliedTrashReadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    func testConfirmedRestoreRechecksActiveStateAfterLateTrashApplies() async throws {
        await coordinator.close()
        let relations = FakeChecker()
        coordinator = makeCoordinator(relations: relations)
        let id = "restore-before-trash-applies"
        let sourceKey = key(id)
        let remote = PhotoUID(volumeID: "vol", nodeID: "late-trash-photo")
        let pendingEffects = try XCTUnwrap(effects)
        let postApplyReads = AppliedTrashReadCount()
        // The fake records a trash only after its before-application gate opens. A compensating restore
        // changes that same server state; the probe never substitutes a canned successful recheck.
        relations.onVisibilityLookup = { [relations] in
            // One genuine post-apply trash read must precede the bounded, ordinary read failure.
            // The second lookup ends this drain even if the compensation obligation is removed.
            if !pendingEffects.trashed.isEmpty, postApplyReads.next() > 1 {
                relations.linkVisibilityError = UploadError.backend("The bounded follow-up read is unavailable")
                return
            }
            let active = pendingEffects.trashed.count <= pendingEffects.restored.count
            relations.linkVisibilityByID[remote.nodeID] = RemoteLinkVisibility(
                isActive: active, mainPhotoLinkID: nil, trashTime: active ? nil : 1_750_000_001)
        }
        defer { relations.onVisibilityLookup = nil }
        enqueue(id, state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(source: source(id), revision: revision, remote: remote, kind: .uploaded)
        await waitForSnapshot("the source really owns the restored photo") { $0.tiles.first?.handoff == remote }
        let gate = LookupGate()
        effects.trashGate = gate
        let running = try XCTUnwrap(coordinator)
        let deleting = Task { await running.exclude([sourceKey.localUID]) }
        guard await gate.entered(within: .seconds(5)) else {
            gate.open()
            _ = await deleting.value
            return XCTFail("the trash request must wait before applying its remote effect")
        }
        do {
            XCTAssertTrue(effects.trashed.isEmpty, "the server has not applied the held trash")
            // The person's Proton restore succeeds now, before the old trash takes effect.
            await coordinator.restoreSources(ofRemote: [remote])
            let included = try XCTUnwrap(store.sourceState(for: sourceKey))
            XCTAssertEqual(included.desired, .included)
            XCTAssertEqual(included.remote, remote)
        } catch {
            gate.open()
            _ = await deleting.value
            throw error
        }
        gate.open()
        let deleted = await deleting.value

        XCTAssertTrue(deleted)
        XCTAssertEqual(effects.trashed, [[remote]], "the old trash really applies after the person's restore")
        XCTAssertGreaterThan(relations.linkVisibilityCallCount, 0, "acknowledgement requires a fresh activity read")
        XCTAssertEqual(effects.restored, [[remote]], "the later applied trash requires exactly one compensation")
        XCTAssertEqual(postApplyReads.count, 2, "The genuine trash read and bounded follow-up must both execute")
    }

    func testRemoteRestoreReadmitsTheExcludedKeyBesideASourceWithoutPendingState() async throws {
        let (good, missing, before, _) = try await restoreWithMissingDiscoveredKey()
        XCTAssertEqual(before.desired, .excluded)
        XCTAssertNotEqual(
            store.sourceState(for: good)?.desired, .excluded, "A source without pending state must not block it")
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertFalse(snapshot.excludedTiles.contains { $0.key == good })
        XCTAssertEqual(effects.returned, [[good]], "Only the excluded key returns to the backup")
        XCTAssertTrue(effects.restored.isEmpty, "Proton already restored this photo")
        XCTAssertEqual(store.sourceStateRead(for: missing), .readable(nil), "Nothing pending is created for it")
    }

    func testRemoteRestoreLeavesASourceWithoutPendingStateOutOfTheResult() async throws {
        let (good, _, _, result) = try await restoreWithMissingDiscoveredKey()
        XCTAssertTrue(result.discoveryComplete, "the handoffs themselves were read completely")
        XCTAssertEqual(Set(result.outcomes.keys), [good], "A source without pending state has no outcome")
        XCTAssertNotEqual(result.outcomes[good], .unreadable)
        XCTAssertTrue(result.isReadable, "The host must not report a failed restore")
    }

    // An upload leaves a handoff; a delete in the timeline only trashes the Proton photo and writes no pending
    // state. Restoring it from Recently Deleted must not report a failure.
    func testRestoringAPhotoDeletedOnlyInProtonIsReadableAndChangesNothing() async throws {
        let id = "timeline-deleted-source"
        let sourceKey = key(id)
        let remote = PhotoUID(volumeID: "vol", nodeID: "timeline-deleted-photo")
        enqueue(id, state: .uploading)
        await coordinator.start()
        recorder.recordHandoff(source: source(id), revision: revision, remote: remote, kind: .uploaded)
        await waitForSnapshot("the handoff belongs to the source") { $0.tiles.first?.handoff == remote }
        XCTAssertEqual(store.sourceStateRead(for: sourceKey), .readable(nil), "The timeline delete wrote no state")

        let result = await coordinator.restoreSources(ofRemote: [remote])

        XCTAssertTrue(result.discoveryComplete)
        XCTAssertEqual(result.outcomes, [:], "Nothing was pending for this source")
        XCTAssertTrue(result.isReadable, "The host must not report a failed restore")
        XCTAssertEqual(store.sourceStateRead(for: sourceKey), .readable(nil))
        XCTAssertTrue(effects.returned.isEmpty)
        XCTAssertTrue(effects.restored.isEmpty)
    }

    private func restoreWithMissingDiscoveredKey() async throws -> (
        PendingSourceKey, PendingSourceKey, PendingSourceState, PendingBackupRestoreResult
    ) {
        await coordinator.close()
        coordinator = makeCoordinator()
        let good = key("readable-restore-source")
        let missing = key("missing-restore-source")
        let remote = PhotoUID(volumeID: "vol", nodeID: "shared-restored-photo")
        enqueue(good.identifier, state: .uploading)
        for sourceKey in [good, missing] {
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: sourceKey, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
                .recorded)
        }
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: good, presentation: nil, remote: remote)], at: date))
        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: good, generation: 1, remoteLinkID: remote.nodeID, at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: good, generation: 1, at: date))
        let before = try XCTUnwrap(store.sourceState(for: good))
        XCTAssertEqual(store.sourceStateRead(for: missing), .readable(nil))
        await coordinator.start()

        let result = await coordinator.restoreSources(ofRemote: [remote])
        return (good, missing, before, result)
    }

    func testRestoreRecheckCleansMarkerForSameUIDAndGeneration() async throws {
        try await assertRestoreRecheckMarkerCleanup(changesGeneration: false)
    }

    func testRestoreRecheckKeepsMarkerForNewerUIDAndGeneration() async throws {
        try await assertRestoreRecheckMarkerCleanup(changesGeneration: true)
    }

    private func assertRestoreRecheckMarkerCleanup(changesGeneration: Bool) async throws {
        await coordinator.close()
        let id = "restored-marker-source"
        let sourceKey = key(id)
        let remote = PhotoUID(volumeID: "vol", nodeID: "restored-marker-photo")
        let relations = FakeChecker()
        relations.linkVisibilityByID[remote.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
        coordinator = makeCoordinator(relations: relations)
        enqueue(id, state: .alreadyBackedUp)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: sourceKey, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: sourceKey, presentation: nil, remote: remote)], at: date))
        let excluded = try XCTUnwrap(store.sourceState(for: sourceKey))
        XCTAssertEqual(store.beginRemoteOperation(.remoteTrash, for: [excluded]), [sourceKey])
        XCTAssertTrue(
            Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 5000)", of: id, at: storeURL))
        await coordinator.start()
        let later = date.timeIntervalSince1970 + 5000
        if changesGeneration {
            effects.onReturn = { [storeURL] in
                XCTAssertTrue(
                    PendingBackupCoordinatorTests.setColumns(
                        "generation=generation+1, remote_link_id='newer-marker-photo', next_attempt_at=\(later)",
                        of: id, at: storeURL))
            }
        }

        await coordinator.restoreSources(ofRemote: [remote])

        XCTAssertTrue(effects.trashed.isEmpty, "no live trash was started by this marker-recovery fixture")
        XCTAssertTrue(effects.restored.isEmpty, "a freshly active photo needs no additional restore")
        if changesGeneration {
            let current = try XCTUnwrap(store.sourceState(for: sourceKey))
            XCTAssertEqual(current.generation, excluded.generation + 2)
            XCTAssertEqual(current.remote?.nodeID, "newer-marker-photo")
            XCTAssertEqual(current.remoteOperation, .remoteTrash, "an old recheck never clears a newer marker")
            XCTAssertTrue(current.needsQueueSync)
        } else {
            XCTAssertNil(
                store.sourceState(for: sourceKey), "a successful same-UID recheck must retire the stale marker row")
        }
    }

    // MARK: - Confirmed Proton restore (#829)

    func testConfirmedRemoteRestoreOfPhotoSendsNoSecondRestore() async throws {
        try await assertConfirmedRemoteRestore(mediaType: "image/heic", isLivePhoto: false)
    }

    func testConfirmedRemoteRestoreOfVideoSendsNoSecondRestore() async throws {
        try await assertConfirmedRemoteRestore(mediaType: "video/quicktime", isLivePhoto: false)
    }

    func testConfirmedRemoteRestoreOfLivePhotoSendsNoSecondRestore() async throws {
        try await assertConfirmedRemoteRestore(mediaType: "image/heic", isLivePhoto: true)
    }

    func testRestoringAHistoricalHandoffStillRestoresTheDifferentCurrentTrashTarget() async throws {
        let id = "historical-restore"
        let sourceKey = key(id)
        let historical = PhotoUID(volumeID: "vol", nodeID: "historical-A")
        let current = PhotoUID(volumeID: "vol", nodeID: "current-B")
        enqueue(id, state: .uploading)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: sourceKey, revision: UploadBackupRevision(rawValue: revision.rawValue - 1),
                    remote: historical, kind: .uploaded, createdAt: date.addingTimeInterval(-1))), .recorded)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: sourceKey, revision: revision, remote: current, kind: .uploaded, createdAt: date)),
            .recorded)
        await coordinator.start()
        await waitForSnapshot("the current handoff is B") { $0.tiles.first?.handoff == current }
        let excluded = await coordinator.exclude([sourceKey.localUID])
        XCTAssertTrue(excluded)
        let before = try XCTUnwrap(store.sourceState(for: sourceKey))
        XCTAssertEqual(before.desired, .excluded)
        XCTAssertEqual(before.remote, current)
        XCTAssertTrue(before.remoteTrashed)
        XCTAssertEqual(effects.trashed, [[current]], "B really reached the fake remote trash")
        XCTAssertEqual(store.handoffs(forRemoteLinkIDs: [historical.nodeID]).map(\.key), [sourceKey])
        let pendingStore = try XCTUnwrap(store)
        let pendingEffects = try XCTUnwrap(effects)
        effects.onVolumeLookup = {
            guard let state = pendingStore.sourceState(for: sourceKey) else {
                XCTFail("B's compensation must remain durable before its restore dispatch")
                return
            }
            XCTAssertEqual(state.remote, current)
            XCTAssertTrue(state.remoteTrashed, "restoring A is not evidence that B left the trash")
            XCTAssertTrue(state.needsRemoteRestore, "B still needs the ordinary include compensation")
        }
        effects.onReturn = {
            XCTAssertEqual(pendingEffects.restored, [[current]], "restore B before returning the local source")
            XCTAssertFalse(pendingStore.sourceState(for: sourceKey)?.remoteTrashed ?? true)
        }

        // Only A was restored by the person; B still needs its ordinary remote restore.
        await coordinator.restoreSources(ofRemote: [historical])

        XCTAssertEqual(effects.restored, [[current]], "a historical A handoff must not silently mark B restored")
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
        XCTAssertEqual(effects.returned, [[sourceKey]])
    }

    private func assertConfirmedRemoteRestore(mediaType: String, isLivePhoto: Bool) async throws {
        let id = "restored-source"
        enqueue(id, state: .uploading)
        metadata.set(
            key(id),
            PendingPresentationMetadata(
                captureTime: date, mediaType: mediaType, isLivePhoto: isLivePhoto, displayName: "restored-media"))
        await coordinator.start()
        let remote = PhotoUID(volumeID: "vol", nodeID: "restored-photo")
        recorder.recordHandoff(source: source(id), revision: revision, remote: remote, kind: .uploaded)
        await waitForSnapshot("the handoff belongs to the source") { $0.tiles.first?.handoff == remote }
        let excluded = await coordinator.exclude([key(id).localUID])
        XCTAssertTrue(excluded)
        let prior = try XCTUnwrap(store.sourceState(for: key(id)))
        XCTAssertTrue(prior.remoteTrashed)
        let pendingStore = try XCTUnwrap(store)
        let sourceKey = key(id)
        effects.onReturn = {
            guard let state = pendingStore.sourceState(for: sourceKey) else {
                XCTFail("the included source must remain durable until queue acknowledgement")
                return
            }
            XCTAssertEqual(state.remote, remote, "the confirmed restored UID remains provenance")
            XCTAssertEqual(state.generation, prior.generation + 1)
            XCTAssertTrue(state.needsQueueSync)
            XCTAssertFalse(state.remoteTrashed)
            XCTAssertFalse(state.needsRemoteTrash)
            XCTAssertFalse(state.needsRemoteRestore)
        }

        await coordinator.restoreSources(ofRemote: [remote])

        XCTAssertTrue(effects.restored.isEmpty, "Proton already restored this photo")
        XCTAssertEqual(effects.returned, [[sourceKey]])
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertFalse(snapshot.excludedTiles.contains { $0.key == sourceKey })
        await coordinator.restoreSources(ofRemote: [remote])
        XCTAssertTrue(effects.restored.isEmpty)
        XCTAssertEqual(effects.returned, [[sourceKey]], "repeating the same restore is idempotent")
    }

    func testRemoteRestoreRefusesAReverseLookupThatCannotBePrepared() async throws {
        let remote = try await prepareRemoteRestoreLookup()
        let before = try XCTUnwrap(store.sourceState(for: key("lookup-source")))
        let failure = SourceListFailure(table: "handoff")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        await coordinator.restoreSources(ofRemote: [remote])

        failure.remove(from: store)
        XCTAssertTrue(failure.denied, "the real reverse SELECT must be rejected")
        XCTAssertEqual(store.sourceState(for: before.key), before)
        XCTAssertTrue(effects.restored.isEmpty, "unreadable discovery grants no restore effect")
        XCTAssertTrue(effects.returned.isEmpty, "cached state must not bypass unreadable discovery")
    }

    func testRemoteRestoreRefusesAnInterruptedReverseLookup() async throws {
        let remote = try await prepareRemoteRestoreLookup()
        let before = try XCTUnwrap(store.sourceState(for: key("lookup-source")))
        let failure = KeyedReadFailure(matching: "FROM handoff WHERE remote_link_id=?", limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        await coordinator.restoreSources(ofRemote: [remote])

        failure.remove(from: store)
        XCTAssertEqual(failure.count, 1, "the real reverse SELECT must be interrupted")
        XCTAssertEqual(store.sourceState(for: before.key), before)
        XCTAssertTrue(effects.restored.isEmpty)
        XCTAssertTrue(effects.returned.isEmpty, "an interrupted read cannot become cached absence")
    }

    private func prepareRemoteRestoreLookup() async throws -> PhotoUID {
        let id = "lookup-source"
        enqueue(id, state: .uploading)
        await coordinator.start()
        let remote = PhotoUID(volumeID: "vol", nodeID: "lookup-photo")
        recorder.recordHandoff(source: source(id), revision: revision, remote: remote, kind: .uploaded)
        await waitForSnapshot("the reverse lookup has a real handoff") { $0.tiles.first?.handoff == remote }
        let excluded = await coordinator.exclude([key(id).localUID])
        XCTAssertTrue(excluded)
        XCTAssertTrue(try XCTUnwrap(store.sourceState(for: key(id))).remoteTrashed)
        return remote
    }

    func testConfirmedRemoteRestoreKeepsADelayedTrashAcknowledgementFromRestoringAgain() async throws {
        let id = "delayed-trash"
        enqueue(id, state: .uploading)
        await coordinator.start()
        let remote = PhotoUID(volumeID: "vol", nodeID: "delayed-trash-photo")
        recorder.recordHandoff(source: source(id), revision: revision, remote: remote, kind: .uploaded)
        await waitForSnapshot("the handoff is visible") { $0.tiles.first?.handoff == remote }
        let gate = LookupGate()
        effects.trashCompletionGate = gate
        let running = try XCTUnwrap(coordinator)
        let sourceKey = key(id)
        let held = Task { await running.exclude([sourceKey.localUID]) }
        let reached = await gate.entered(within: .seconds(5))
        guard reached else {
            XCTFail("the trash must apply before its acknowledgement is held")
            gate.open()
            _ = await held.value
            return
        }
        defer { gate.open() }
        XCTAssertEqual(effects.trashed, [[remote]], "the fake remote already applied the trash")
        do {
            let inFlight = try XCTUnwrap(store.sourceState(for: sourceKey))
            XCTAssertEqual(inFlight.remoteOperation, .remoteTrash)

            // Proton has now restored the photo; only the earlier trash acknowledgement is delayed.
            await coordinator.restoreSources(ofRemote: [remote])
            let included = try XCTUnwrap(store.sourceState(for: sourceKey))
            XCTAssertEqual(included.desired, .included)
            XCTAssertEqual(included.remote, remote)
            XCTAssertFalse(included.needsRemoteRestore, "the confirmed restore must not schedule a redundant call")
            XCTAssertFalse(included.remoteTrashed)
        } catch {
            gate.open()
            _ = await held.value
            throw error
        }
        gate.open()
        let excluded = await held.value

        XCTAssertTrue(excluded)
        XCTAssertTrue(effects.restored.isEmpty, "the old acknowledgement must not restore this photo again")
        XCTAssertEqual(effects.returned, [[sourceKey]])
    }

    // MARK: - Later trash after an unreadable handoff (#842)

    func testLaterTrashRetriesAfterTheLatestHandoffDoesNotDecode() async throws {
        try await laterTrashAfterUnreadableHandoff(.decode)
    }

    func testLaterTrashRetriesAfterTheLatestHandoffLookupFails() async throws {
        try await laterTrashAfterUnreadableHandoff(.lookup)
    }

    func testLaterTrashRetriesAfterTheLatestHandoffStepIsInterrupted() async throws {
        try await laterTrashAfterUnreadableHandoff(.step)
    }

    func testLaterTrashRetriesAfterItsSourceRereadIsInterrupted() async throws {
        try await laterTrashAfterUnreadableHandoff(.sourceRead)
    }

    func testLaterTrashRetriesAfterItsSchedulingWriteIsRejected() async throws {
        try await laterTrashAfterUnreadableHandoff(.write)
    }

    func testLaterTrashRepeatedReadFailureKeepsBackingOffWithoutResendingTheEarlierUpload() async throws {
        try await laterTrashAfterUnreadableHandoff(.decode, repeatFailure: true)
    }

    func testLaterTrashRetryDoesNotUndoANewerReturnToBackup() async throws {
        try await laterTrashAfterUnreadableHandoff(.decode, returnToBackup: true)
    }

    func testLaterTrashRecoveryStartsAgainAfterRepairAndAnotherUnreadableCommit() async throws {
        try await laterTrashAfterUnreadableHandoff(.decode, secondEpisode: true)
    }

    private enum LaterHandoffFault { case decode, lookup, step, write, sourceRead }

    private func seedLaterTrash(acknowledgedAt createdAt: Date) throws -> PhotoUID {
        let later = PhotoUID(volumeID: "vol", nodeID: "later-upload")
        XCTAssertNotNil(
            store.exclude(
                [PendingExclusionRequest(key: key("later"), presentation: nil, remote: earlier)], at: date))
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key("later"), revision: revision, remote: later, kind: .uploaded, createdAt: createdAt)),
            .excludedRemoteNeedsTrash)
        XCTAssertTrue(store.acknowledgeHandoffs([(key("later"), revision)]))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key("later"), generation: 1, at: date))
        XCTAssertEqual(store.sourceState(for: key("later"))?.remote, earlier)
        return later
    }

    private func laterTrashAfterUnreadableHandoff(
        _ fault: LaterHandoffFault, repeatFailure: Bool = false, returnToBackup: Bool = false,
        secondEpisode: Bool = false
    ) async throws {
        await coordinator.close()
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        let later = try seedLaterTrash(acknowledgedAt: date)
        let gate = LookupGate()
        defer { gate.open() }
        effects.trashGate = gate
        let running = try XCTUnwrap(coordinator)
        let trigger = key("trigger").localUID
        let pass = Task { await running.restore([trigger]) }
        guard await gate.entered(within: .seconds(5)) else {
            gate.open()
            _ = await pass.value
            XCTFail("the earlier upload never reached the trash gate")
            return
        }
        let denial = SourceListFailure(
            table: fault == .write ? "source_state" : "handoff", untilRemoved: true,
            action: fault == .write ? SQLITE_UPDATE : SQLITE_READ, column: fault == .write ? "remote_link_id" : nil,
            transient: true)
        let interruption = KeyedReadFailure(
            matching: fault == .sourceRead
                ? "FROM source_state WHERE source_kind=? AND source_id=?" : Self.latestHandoffRead,
            skip: fault == .sourceRead ? 1 : 0, limit: fault == .sourceRead ? 1 : .max)
        defer { denial.remove(from: store) }
        defer { interruption.remove(from: store) }
        switch fault {
        case .decode:
            XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='later';"))
        case .lookup: try denial.install(on: store)
        case .step: try interruption.install(on: store)
        case .write: try denial.install(on: store)
        case .sourceRead: try interruption.install(on: store)
        }
        gate.open()
        _ = await pass.value

        let completed = try XCTUnwrap(store.sourceState(for: key("later")))
        XCTAssertTrue(completed.remoteTrashed, "the confirmed trash of A must be saved independently of the B read")
        XCTAssertFalse(completed.needsRemoteTrash, "an unreadable B is not permission to trash A again")
        XCTAssertNil(completed.remoteOperation, "the confirmed request is no longer in flight")
        XCTAssertEqual(completed.remote, earlier)
        XCTAssertEqual(Array(effects.trashed.joined()), [earlier])
        if fault == .lookup || fault == .write { XCTAssertTrue(denial.denied, "the requested SQL must actually fail") }
        if fault == .step { XCTAssertGreaterThan(interruption.count, 0, "the latest handoff step must actually fail") }
        if fault == .sourceRead {
            XCTAssertEqual(interruption.count, 1, "only the helper's second source read must fail")
        }
        try await pollWhileFalse { clock.waits.contains(.seconds(60)) }
        XCTAssertEqual(clock.waits, [.seconds(60)], "the unreadable later handoff must keep a degraded retry")
        if repeatFailure {
            clock.advance(by: .seconds(60))
            try await pollWhileFalse { clock.waits.contains(.seconds(120)) }
            XCTAssertEqual(clock.waits, [.seconds(60), .seconds(120)])
            XCTAssertEqual(Array(effects.trashed.joined()), [earlier], "the second denied cycle must not resend A")
        }
        if returnToBackup {
            let returned = await coordinator.restore([key("later").localUID])
            XCTAssertTrue(returned)
            XCTAssertEqual(effects.restored, [[earlier]], "the person's later return restores the confirmed A")
        }

        denial.remove(from: store)
        interruption.remove(from: store)
        if fault == .decode {
            XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='later';"))
        }
        clock.advance(by: repeatFailure ? .seconds(120) : .seconds(60))
        if returnToBackup {
            _ = await coordinator.restore([trigger])
            XCTAssertEqual(Array(effects.trashed.joined()), [earlier], "a newer included source must never trash B")
            await coordinator.close()
            return
        }
        try await pollWhileFalse { effects.trashed.joined().contains(later) }
        XCTAssertEqual(
            Array(effects.trashed.joined()), [earlier, later], "repair must trash B once without resending A")
        let finished = try XCTUnwrap(store.sourceState(for: key("later")))
        XCTAssertEqual(finished.remote, later)
        XCTAssertTrue(finished.remoteTrashed)
        XCTAssertFalse(finished.needsRemoteTrash)
        _ = await coordinator.restore([trigger])
        XCTAssertEqual(
            Array(effects.trashed.joined()), [earlier, later], "another reconcile must not resend either photo")
        if secondEpisode {
            let next = PhotoUID(volumeID: "vol", nodeID: "next-upload")
            let newest = PhotoUID(volumeID: "vol", nodeID: "newest-upload")
            for (revision, remote) in [(Int64(11), next), (Int64(12), newest)] {
                XCTAssertEqual(
                    store.recordHandoff(
                        PendingHandoff(
                            key: key("later"), revision: UploadBackupRevision(rawValue: revision), remote: remote,
                            kind: .uploaded, createdAt: clock.now.addingTimeInterval(Double(revision)))),
                    .excludedRemoteNeedsTrash)
            }
            // The next committed upload stays due until its date, then its confirmed trash discovers another fault.
            clock.advance(by: .seconds(12))
            let nextGate = LookupGate()
            defer { nextGate.open() }
            effects.trashGate = nextGate
            let nextPass = Task { await running.restore([trigger]) }
            guard await nextGate.entered(within: .seconds(5)) else {
                nextGate.open()
                _ = await nextPass.value
                XCTFail("the second episode did not reach its trash gate")
                return
            }
            XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='later' AND revision_us=12;"))
            nextGate.open()
            _ = await nextPass.value
            try await pollWhileFalse { clock.waits.filter { $0 == .seconds(60) }.count >= 2 }
            XCTAssertEqual(Array(effects.trashed.joined()), [earlier, later, next])
            XCTAssertEqual(clock.waits.last, .seconds(60), "a new failure episode starts at the first backoff again")
            XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='later' AND revision_us=12;"))
            clock.advance(by: .seconds(60))
            try await pollWhileFalse { effects.trashed.joined().contains(newest) }
            XCTAssertEqual(Array(effects.trashed.joined()), [earlier, later, next, newest])
        }
        await coordinator.close()
    }

    func testLaterTrashRecoveryKeepsAnOldAcknowledgedHandoffAfterRestart() async throws {
        await coordinator.close()
        let later = try seedLaterTrash(acknowledgedAt: date.addingTimeInterval(-8 * 24 * 60 * 60))
        XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='later';"))
        XCTAssertTrue(
            store.completeEffect(.remoteTrash, for: key("later"), generation: 1, remoteLinkID: earlier.nodeID, at: date)
        )
        XCTAssertTrue(try XCTUnwrap(store.sourceState(for: key("later"))).remoteTrashed)
        XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='later';"))
        recorder.finish()
        store.close()
        store = try XCTUnwrap(PendingBackupManifestStore(url: storeURL))
        recorder = PendingBackupEventRecorder(
            store: store, replacementLedger: .shared(accountDataDirectory: directory), now: { [date] in date })
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()

        try await pollWhileFalse { effects.trashed.joined().contains(later) }
        XCTAssertEqual(Array(effects.trashed.joined()), [later], "startup must recover B without resending saved A")
        XCTAssertEqual(store.latestHandoffsRead(for: [key("later")])[key("later")]?.handoff?.remote, later)
        XCTAssertEqual(store.sourceState(for: key("later"))?.remote, later)
        await coordinator.close()
    }

    private func seedLaterTrashRecoveryBatch(_ count: Int) throws {
        for index in 0..<count {
            let id = "batch-\(index)"
            let before = PhotoUID(volumeID: "vol", nodeID: "a-\(index)")
            let later = PhotoUID(volumeID: "vol", nodeID: "b-\(index)")
            let revision = UploadBackupRevision(rawValue: 9)
            XCTAssertNotNil(
                store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: before)], at: date))
            XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: 1, at: date))
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(key: key(id), revision: revision, remote: later, kind: .uploaded, createdAt: date)),
                .excludedRemoteNeedsTrash)
            XCTAssertTrue(store.acknowledgeHandoffs([(key(id), revision)]))
            // Save A's completion while its next read fails, then repair B before startup without emitting an event.
            XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='\(id)';"))
            XCTAssertTrue(store.completeEffect(.remoteTrash, for: key(id), generation: 1, at: date))
            XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='\(id)';"))
        }
    }

    func testLaterTrashStartupRecoveryReadsANewerGeneration() async throws {
        try await laterTrashStartupReadsNewDecision(returnFirst: false)
    }

    func testLaterTrashStartupRecoveryReusesAKeyAfterReturn() async throws {
        try await laterTrashStartupReadsNewDecision(returnFirst: true)
    }

    private func laterTrashStartupReadsNewDecision(returnFirst: Bool) async throws {
        await coordinator.close()
        try seedLaterTrashRecoveryBatch(1)
        // An unrelated incomplete row makes later reconciles reload the complete source inventory.
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key("bad"), presentation: nil, remote: nil)], at: date))
        try setDesired("invalid", of: "bad")
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        let target = PhotoUID(volumeID: "vol", nodeID: "b-0")
        try await pollWhileFalse { effects.trashed.joined().contains(target) }
        XCTAssertEqual(Array(effects.trashed.joined()), [target])
        let first = try XCTUnwrap(store.sourceState(for: key("batch-0")))
        if returnFirst {
            let returned = await coordinator.restore([key("batch-0").localUID])
            XCTAssertTrue(returned)
            XCTAssertNil(store.sourceState(for: key("batch-0")), "the returned source leaves the pending store")
        }

        XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='batch-0';"))
        let excluded = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key("batch-0"), presentation: nil, remote: earlier)], at: date)?.first)
        XCTAssertEqual(excluded.generation, returnFirst ? first.generation : first.generation + 1)
        XCTAssertTrue(store.completeEffect(.queueSync, for: excluded.key, generation: excluded.generation, at: date))
        // This generation needs its own recorded proof; the prior delete's duties ended at the new decision.
        XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='batch-0';"))
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: excluded.key, revision: UploadBackupRevision(rawValue: 9), remote: target, kind: .uploaded,
                    createdAt: date)),
            .excludedRemoteNeedsTrash)
        XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='batch-0';"))
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: excluded.key, generation: excluded.generation, remoteLinkID: earlier.nodeID, at: date
            ))
        XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='batch-0';"))
        _ = await coordinator.restore([key("trigger").localUID])

        try await pollWhileFalse { effects.trashed.joined().count >= 2 }
        XCTAssertEqual(
            Array(effects.trashed.joined()), [target, target], "a new decision must re-enter startup recovery")
        await coordinator.close()
    }

    func testLaterTrashRecoveryAdvancesHealthyKeysBesideAnUnreadableKeyAcrossBatches() async throws {
        await coordinator.close()
        try seedLaterTrashRecoveryBatch(201)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()

        try await pollWhileFalse { effects.trashed.joined().count >= 200 }
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(effects.trashed.joined().count, 200, "all healthy keys must advance across the batch boundary")
        XCTAssertTrue(effects.trashed.joined().allSatisfy { $0.nodeID.hasPrefix("b-") })
        try await pollWhileFalse { clock.waits.contains(.seconds(60)) }
        try await settle()
        XCTAssertEqual(
            clock.waits.last, .seconds(60), "healthy startup groups must not postpone the failed key's retry")
        failure.remove(from: store)
        clock.advance(by: .seconds(60))
        try await pollWhileFalse { effects.trashed.joined().count >= 201 }
        XCTAssertEqual(effects.trashed.joined().count, 201, "the failed key must remain retryable")
        XCTAssertEqual(Set(effects.trashed.joined()).count, 201, "recovery must not repeat completed targets")
        await coordinator.close()
    }

    func testLaterTrashStartupYieldsAfterOneBatchAndStopsWritingAfterClose() async throws {
        await coordinator.close()
        try seedLaterTrashRecoveryBatch(201)
        let gate = LookupGate()
        defer { gate.open() }
        effects.trashGate = gate
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertGreaterThan(snapshot.membershipRevision, 0, "the first snapshot must precede recovery's remote work")
        guard await gate.entered(within: .seconds(5)) else {
            XCTFail("the first recovery batch did not reach its trash gate")
            await coordinator.close()
            return
        }
        let beforeClose = store.sourceStates()
        XCTAssertEqual(beforeClose.filter { $0.remote?.nodeID.hasPrefix("b-") == true }.count, 100)
        await coordinator.close()
        gate.open()
        try await settle()
        XCTAssertEqual(store.sourceStates(), beforeClose, "close must prevent the queued second batch from writing")
    }

    func testLaterTrashUnreadableStartupSchedulesBackoffUntilRepair() async throws {
        await coordinator.close()
        try seedLaterTrashRecoveryBatch(1)
        XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='batch-0';"))
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        try await pollWhileFalse { clock.waits.contains(.seconds(60)) }
        try await settle()
        XCTAssertEqual(clock.waits, [.seconds(60)], "an unreadable-only batch must still start reconciliation backoff")
        XCTAssertTrue(effects.trashed.isEmpty)
        XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='batch-0';"))
        clock.advance(by: .seconds(60))
        let target = PhotoUID(volumeID: "vol", nodeID: "b-0")
        try await pollWhileFalse { effects.trashed.joined().contains(target) }
        XCTAssertEqual(Array(effects.trashed.joined()), [target])
        await coordinator.close()
    }

    func testLaterTrashUnchangedRecoveryKeepsTheExistingTimerAndPublication() async throws {
        await coordinator.close()
        XCTAssertNotNil(
            store.exclude(
                [PendingExclusionRequest(key: key("unchanged"), presentation: nil, remote: earlier)], at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key("unchanged"), generation: 1, at: date))
        XCTAssertTrue(store.completeEffect(.remoteTrash, for: key("unchanged"), generation: 1, at: date))
        excludedLater("future")
        XCTAssertTrue(store.completeEffect(.queueSync, for: key("future"), generation: 1, at: date))
        let before = store.sourceStates()
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        let first = await coordinator.currentSnapshot()
        try await pollWhileFalse { !clock.waits.isEmpty }
        try await settle()

        XCTAssertEqual(clock.waits, [.seconds(5000)], "a batch without new work must not replace the existing timer")
        XCTAssertEqual(store.sourceStates(), before, "unchanged recovery must not update any source-state value")
        let after = await coordinator.currentSnapshot()
        XCTAssertEqual(
            after.membershipRevision, first.membershipRevision, "recovery must not publish another membership")
        XCTAssertTrue(effects.trashed.isEmpty)
        clock.advance(by: .seconds(5000))
        let target = PhotoUID(volumeID: "vol", nodeID: "future")
        try await pollWhileFalse { effects.trashed.joined().contains(target) }
        XCTAssertEqual(
            Array(effects.trashed.joined()), [target], "the retained timer must still dispatch the other source")
        await coordinator.close()
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
        XCTAssertEqual(try queue.entry(for: pending.source, revision: pending.revision), pending)
        var released = pending
        released.state = .checking
        XCTAssertEqual(queue.claimRunnable(limit: 1, claimedAt: date)?.count, 1)
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
        relations: (any UploadDuplicateChecking)? = nil,
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws -> EditReplacementJournalFileStore {
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        coordinator = makeCoordinator(
            replacementJournal: journal, identities: identities, relations: relations,
            sleep: sleep)
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

    /// The state of one excluded photo cannot be read at start and the photo has no handoff, so the check of the
    /// excluded list cannot examine it. Once a later read of the states succeeds, the check examines that photo.
    func testAnExcludedPhotoWhoseStateFailedToLoadIsCheckedAgainAfterARead() async throws {
        let requests = ["good", "bad"].map { id in
            let presentation = PendingPresentationMetadata(
                captureTime: date, mediaType: "image/heic", displayName: "\(id).heic")
            metadata.set(key(id), presentation)
            return PendingExclusionRequest(key: key(id), presentation: presentation, remote: nil)
        }
        XCTAssertNotNil(store.exclude(requests, at: date))
        try setDesired("invalid", of: "bad")
        let gate = OpenGate()
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(sleep: { duration in
            delays.append(duration)
            if duration >= .seconds(60), delays.values.filter({ $0 >= .seconds(60) }).count == 1 {
                await gate.wait()
            } else {
                try await Task.sleep(for: duration)
            }
        })
        await coordinator.start()
        await coordinator.noteLibraryChanged()
        var deadline = ContinuousClock.now + .seconds(5)
        while metadata.reads(of: key("good")) < 2 || !delays.values.contains(where: { $0 >= .seconds(60) }),
            ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(metadata.reads(of: key("good")), 2, "the start and the library change each checked the list")
        XCTAssertEqual(metadata.reads(of: key("bad")), 0, "a state that did not load cannot be examined")

        try setDesired("excluded", of: "bad")
        gate.open()

        deadline = ContinuousClock.now + .seconds(5)
        while metadata.reads(of: key("bad")) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(metadata.reads(of: key("bad")), 1, "the next read of the states lets the check examine it")
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
        relations: (any UploadDuplicateChecking)? = FakeChecker(),
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator(identities: identities, relations: relations, sleep: sleep)
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
        relations: (any UploadDuplicateChecking)? = FakeChecker(),
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        await coordinator.close()
        let journal = try makeJournalCoordinator(
            identities: identities, relations: relations,
            sleep: sleep)
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
        let relations = FakeChecker()
        relations.linkVisibilityByID[earlier.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
        try await startPendingEditWithoutHandoff(identities: FakeIdentityStore(), relations: relations)
        await coordinator.exclude([key("p").localUID])

        await coordinator.restore([key("p").localUID])

        XCTAssertEqual(effects.restored, [[earlier]])
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
        XCTAssertEqual(effects.returned, [[key("p")]])
    }

    // Mutation: drop the source-state lookup in `restoreSources(ofRemote:)`; the source stays deleted.
    func testRestoringTheEarlierUploadFromTheProtonTrashRestoresAnEditWithoutAHandoff() async throws {
        let relations = FakeChecker()
        relations.linkVisibilityByID[earlier.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
        try await startPendingEditWithoutHandoff(identities: FakeIdentityStore(), relations: relations)
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

    func testDeletingAnOlderTileTrashesALaterCommitWhoseEventIsStillPending() async throws {
        try await startPendingEdit()
        let committed = PhotoUID(volumeID: "vol", nodeID: "later-edit-commit")
        let later = UploadBackupRevision(rawValue: edit.rawValue + 1)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key("p"), revision: later, remote: committed, kind: .uploaded, createdAt: date)),
            .recorded)
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(
            snapshot.tiles.first?.revision, edit,
            "the durable upload event has not reached this tile")
        let deleted = await coordinator.exclude([key("p").localUID])
        XCTAssertTrue(deleted)
        try await pollWhileFalse { effects.trashed.flatMap { $0 }.contains(committed) }
        XCTAssertEqual(
            Set(effects.trashed.flatMap { $0 }), [earlier, committed],
            "the delete keeps the existing this-or-later revision contract")
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
        let relations = FakeChecker()
        relations.linkVisibilityByID[earlier.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
        try await startPendingEdit(relations: relations)
        await coordinator.exclude([key("p").localUID])

        await coordinator.restore([key("p").localUID])

        XCTAssertEqual(effects.restored, [[earlier]])
        XCTAssertEqual(effects.order.suffix(2), ["restore", "return"])
        XCTAssertEqual(effects.returned, [[key("p")]])
    }

    func testRestoringAfterAnUndoInPhotosBringsTheEarlierUploadBack() async throws {
        let relations = FakeChecker()
        relations.linkVisibilityByID[earlier.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
        try await startPendingEdit(relations: relations)
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
        XCTAssertEqual(effects.favorites, [remote], "a readable rowless source acts while another state is unreadable")

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

    /// The queue result is saved before the trash starts. Only the reads after that trash fail; the pending
    /// trash completion prevents another dispatch when the backoff opens the next pass.
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
        defer { gate.open() }
        let retryGate = OpenGate()
        defer { retryGate.open() }
        let trashGate = LookupGate()
        defer { trashGate.open() }
        effects.trashGate = trashGate
        let delays = DelayLog()
        await coordinator.close()
        coordinator = makeCoordinator(
            checkmarkDuration: .seconds(5),
            sleep: { duration in
                delays.append(duration)
                if duration == .seconds(500) {
                    await gate.wait()
                } else if duration == .seconds(60) {
                    await retryGate.wait()
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            })
        await coordinator.start()
        try await pollWhileFalse { delays.values.contains(.seconds(500)) }
        XCTAssertTrue(delays.values.contains(.seconds(500)), "the initial retry is held before the fault")
        // The store now owes photo B. Its queue completion must succeed before the read fault starts.
        XCTAssertTrue(
            Self.setColumns("remote_link_id='b', next_attempt_at=\(date.timeIntervalSince1970)", of: "s", at: url))
        gate.open()
        guard await trashGate.entered(within: .seconds(5)) else {
            XCTFail("photo B never reached the trash gate")
            await coordinator.close()
            return
        }
        let beforeTrash = try XCTUnwrap(store.sourceState(for: key("s")))
        XCTAssertFalse(beforeTrash.needsQueueSync, "queue completion is durable before the fault")
        let failure = KeyedReadFailure()
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        trashGate.open()
        try await pollWhileFalse { delays.values.contains(.seconds(60)) }
        XCTAssertTrue(delays.values.contains(.seconds(60)), "the rejected trash completion starts the backoff")
        retryGate.open()
        try await pollWhileFalse { delays.values.contains(.seconds(120)) }
        XCTAssertTrue(
            delays.values.contains(.seconds(120)), "the next pass retries persistence and doubles the backoff")
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
        let failure = SourceListFailure(transient: true)
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
        XCTAssertTrue(effects.restored.isEmpty, "Proton already restored the photo")
        XCTAssertEqual(
            effects.returned, [[key("kept")]], "the last known state returns the deleted source to backup")
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

    // MARK: - Rejected result writes (#770 D3)

    func testAConfirmedTrashWhoseCompletionCannotBeWrittenIsSentOnce() async throws {
        try await rejectedWrite(.trashCompletion, repeatedWaits: true)
    }

    func testADoneFavoriteWhoseCompletionCannotBeWrittenIsSentOnce() async throws {
        try await rejectedWrite(.actionCompletion, repeatedWaits: true)
    }

    func testAFailedFavoriteWhoseFailureCannotBeWrittenIsNotSentAgain() async throws {
        try await rejectedWrite(.actionFailure)
    }

    func testARetryOfAnActionThatCannotBeWrittenWaitsForTheBackoff() async throws {
        try await rejectedWrite(.actionRetry)
    }

    func testAnUnansweredTrashWhoseRetryCannotBeWrittenWaitsForTheBackoff() async throws {
        try await rejectedWrite(.trashRetry)
    }

    func testADeferWithoutAVolumeThatCannotBeWrittenWaitsForTheBackoff() async throws {
        try await rejectedWrite(.noVolume)
    }

    func testABeginThatCannotBeWrittenSendsNothing() async throws {
        try await rejectedWrite(.begin)
    }

    func testAQueueRemovalWhoseCompletionCannotBeWrittenRunsOnce() async throws {
        try await rejectedWrite(.queueCompletion)
    }

    func testAQueueRemovalWhoseRetryCannotBeWrittenWaitsForTheBackoff() async throws {
        try await rejectedWrite(.queueRetry)
    }

    func testAnActionDeferWithoutAVolumeThatCannotBeWrittenWaitsForTheBackoff() async throws {
        try await rejectedWrite(.actionNoVolume)
    }

    func testAQueueCompletionSurvivesRepeatedRejectedWrites() async throws {
        try await rejectedWrite(.queueCompletion, repeatedWaits: true)
    }

    func testASavedQueueCompletionEndsTheWriteBackoff() async throws {
        try await savedCompletionEndsBackoff(.queueCompletion)
    }

    func testASavedFavoriteCompletionEndsTheWriteBackoff() async throws {
        try await savedCompletionEndsBackoff(.actionCompletion)
    }

    private func savedCompletionEndsBackoff(_ rejected: RejectedWrite) async throws {
        let (failure, clock, _) = try prepareRejectedWrite(rejected)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        if rejected.isQueue {
            failure.remove(from: store)
            includedLater("later")
            try failure.install(on: store)
        }
        try await startRejectedWriteClock(clock)
        XCTAssertTrue(failure.denied)
        XCTAssertEqual(clock.waits, [.seconds(60)])
        failure.remove(from: store)
        clock.advance(by: .seconds(60))
        try await pollWhileFalse { clock.waits.count >= 2 }
        try await settle()
        XCTAssertEqual(clock.waits, [.seconds(60), .seconds(4940)], "a saved result leaves only ordinary future work")
        if rejected.isQueue {
            XCTAssertEqual(store.sourceState(for: key("write"))?.needsQueueSync, false)
            XCTAssertEqual(effects.removed, [["write"]])
        } else {
            XCTAssertTrue(store.actions().isEmpty)
            XCTAssertEqual(effects.favorites.count, 1)
        }
    }

    func testASavedTrashRetryDispatchesOnlyAtItsPersistedDate() async throws {
        try await savedRetryDispatchesAtItsDate(.trashRetry)
    }

    func testASavedFavoriteRetryDispatchesOnlyAtItsPersistedDate() async throws {
        try await savedRetryDispatchesAtItsDate(.actionRetry)
    }

    private func savedRetryDispatchesAtItsDate(_ rejected: RejectedWrite) async throws {
        let (failure, clock, _) = try prepareRejectedWrite(rejected)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        try await startRejectedWriteClock(clock)
        XCTAssertTrue(failure.denied)
        XCTAssertEqual(clock.waits, [.seconds(60)])
        failure.remove(from: store)
        clock.advance(by: .seconds(60))
        try await pollWhileFalse {
            rejected.isAction
                ? store.actions().first?.attempts == 1
                : store.sourceState(for: key("write"))?.attempts == 1
        }
        try await settle()
        let next =
            rejected.isAction
            ? store.actions().first?.nextAttemptAt
            : store.sourceState(for: key("write"))?.nextAttemptAt
        XCTAssertEqual(next, date.addingTimeInterval(120))
        XCTAssertEqual(rejected.isAction ? effects.favorites.count : effects.trashed.joined().count, 1)
        XCTAssertTrue(clock.waits.dropFirst().contains(.seconds(60)), "the persisted date registers an ordinary retry")
        effects.favoriteResult = .done
        effects.trashRetry = []
        clock.advance(by: .seconds(59))
        try await settle()
        XCTAssertEqual(rejected.isAction ? effects.favorites.count : effects.trashed.joined().count, 1)
        clock.advance(by: .seconds(1))
        try await pollWhileFalse {
            rejected.isAction ? effects.favorites.count == 2 : effects.trashed.joined().count == 2
        }
        try await settle()
        XCTAssertEqual(rejected.isAction ? effects.favorites.count : effects.trashed.joined().count, 2)
        if rejected.isAction {
            XCTAssertTrue(store.actions().isEmpty)
        } else {
            XCTAssertEqual(store.sourceState(for: key("write"))?.needsRemoteTrash, false)
        }
    }

    func testAnOlderPendingQueueCompletionKeepsTheNewGenerationOwed() async throws {
        try await newerEffectSurvivesPendingCompletion(.queueCompletion)
    }

    func testAnOlderPendingTrashCompletionKeepsTheNewRemoteOwed() async throws {
        try await newerEffectSurvivesPendingCompletion(.trashCompletion)
    }

    private func newerEffectSurvivesPendingCompletion(_ rejected: RejectedWrite) async throws {
        let (failure, clock, _) = try prepareRejectedWrite(rejected)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        try await startRejectedWriteClock(clock)
        XCTAssertTrue(failure.denied)
        XCTAssertEqual(clock.waits, [.seconds(60)])
        let original = try XCTUnwrap(store.sourceState(for: key("write")))
        failure.remove(from: store)
        let laterRemote = rejected.isQueue ? nil : PhotoUID(volumeID: "vol", nodeID: "new-link")
        let newer = try XCTUnwrap(
            store.exclude(
                [PendingExclusionRequest(key: key("write"), presentation: nil, remote: laterRemote)],
                at: date.addingTimeInterval(1))?.first)
        XCTAssertEqual(newer.generation, original.generation + 1)
        XCTAssertTrue(
            Self.setColumns(
                "next_attempt_at=\(date.timeIntervalSince1970 + 600)"
                    + (rejected.isQueue ? "" : ", needs_queue_sync=0"),
                of: "write", at: storeURL))
        clock.advance(by: .seconds(60))
        try await pollWhileFalse { clock.waits.count >= 2 }
        try await settle()
        let kept = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(kept.generation, newer.generation)
        XCTAssertEqual(kept.remote, laterRemote)
        XCTAssertTrue(
            rejected.isQueue ? kept.needsQueueSync : kept.needsRemoteTrash,
            "the old completion cannot settle the newer decision")
        XCTAssertEqual(kept.remoteTrashed, false)
        XCTAssertNil(kept.remoteOperation)
        XCTAssertEqual(clock.waits, [.seconds(60), .seconds(540)])
        XCTAssertEqual(rejected.isQueue ? effects.removed.count : effects.trashed.joined().count, 1)
        clock.advance(by: .seconds(540))
        try await pollWhileFalse {
            rejected.isQueue ? effects.removed.count == 2 : effects.trashed.joined().count == 2
        }
        try await settle()
        XCTAssertEqual(rejected.isQueue ? effects.removed.count : effects.trashed.joined().count, 2)
        let finished = try XCTUnwrap(store.sourceState(for: key("write")))
        XCTAssertEqual(rejected.isQueue ? finished.needsQueueSync : finished.needsRemoteTrash, false)
        if !rejected.isQueue { XCTAssertEqual(effects.trashed.last, [try XCTUnwrap(laterRemote)]) }
    }

    func testANewerFavoriteValueCanRunWhileAnOlderCompletionWaits() async throws {
        try await newerFavoriteSurvivesPendingCompletion(favorite: false, offset: 0)
    }

    func testANewerFavoriteDateCanRunWhileAnOlderCompletionWaits() async throws {
        try await newerFavoriteSurvivesPendingCompletion(favorite: true, offset: 1)
    }

    private func newerFavoriteSurvivesPendingCompletion(favorite: Bool, offset: Int64) async throws {
        let (failure, clock, _) = try prepareRejectedWrite(.actionCompletion)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        try await startRejectedWriteClock(clock)
        XCTAssertTrue(failure.denied)
        XCTAssertEqual(clock.waits, [.seconds(60)])
        clock.advance(by: .seconds(offset))
        let stored = await coordinator.setFavorite(
            [PhotoUID(localPending: .photoLibrary, identifier: "write")], favorite: favorite)
        XCTAssertTrue(stored)
        try await settle()
        XCTAssertEqual(effects.favoriteValues, [true, favorite], "a distinct newer SQL action identity can run")
        let action = try XCTUnwrap(store.actions().first)
        XCTAssertEqual(action.desired, favorite)
        XCTAssertEqual(action.createdAt, date.addingTimeInterval(Double(offset)))
        XCTAssertEqual(clock.waits, [.seconds(60)], "neither unsaved action registers a one-second timer")
        failure.remove(from: store)
        clock.advance(by: .seconds(60 - offset))
        try await pollWhileFalse { store.actions().isEmpty && clock.waits.count >= 2 }
        try await settle()
        XCTAssertTrue(store.actions().isEmpty)
        XCTAssertEqual(effects.favoriteValues, [true, favorite], "repair saves both results without another request")
        XCTAssertEqual(clock.waits, [.seconds(60), .seconds(4940)])
    }

    func testAPendingFavoriteResultSuppressesAnotherDispatchAndShortTimer() async throws {
        let (failure, clock, _) = try prepareRejectedWrite(.actionCompletion)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        try await startRejectedWriteClock(clock)
        XCTAssertTrue(failure.denied)
        let accepted = await coordinator.setFavorite([], favorite: true)
        XCTAssertTrue(accepted)
        try await settle()
        XCTAssertEqual(effects.favoriteValues, [true])
        XCTAssertEqual(clock.waits, [.seconds(60)], "the owed action waits on reconcile, not a short action timer")
    }

    func testARejectedFavoriteResultOutsideReconcileStartsTheWriteBackoff() async throws {
        includedLater("write")
        _ = favoriteFixture("write")
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        try await startRejectedWriteClock(clock)
        XCTAssertEqual(clock.waits, [.seconds(5000)])
        let failure = SourceListFailure(
            table: "pending_action", untilRemoved: true, action: SQLITE_DELETE, transient: true)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let stored = await coordinator.setFavorite(
            [PhotoUID(localPending: .photoLibrary, identifier: "write")], favorite: true)
        XCTAssertTrue(stored)
        try await pollWhileFalse { clock.waits.count >= 2 }
        try await settle()
        XCTAssertTrue(failure.denied)
        XCTAssertEqual(effects.favoriteValues, [true])
        XCTAssertEqual(store.actions().count, 1)
        XCTAssertEqual(
            clock.waits, [.seconds(5000), .seconds(60)],
            "a rejected action result outside reconcile starts the degraded retry")
    }

    func testAFutureDateOfAnUnsavedKeyCannotShortenItsBackoff() async throws {
        try await pendingFutureDateKeepsItsBackoff(healthyOther: false)
    }

    func testAHealthyOtherKeyKeepsItsEarlierRetryBesideAnUnsavedResult() async throws {
        try await pendingFutureDateKeepsItsBackoff(healthyOther: true)
    }

    private func pendingFutureDateKeepsItsBackoff(healthyOther: Bool) async throws {
        let (failure, clock, _) = try prepareRejectedWrite(.queueCompletion)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        effects.onRemove = { [storeURL, date] in
            XCTAssertTrue(
                Self.setColumns(
                    "next_attempt_at=\(date.timeIntervalSince1970 + 10)", of: "write", at: storeURL))
        }
        let healthyRemote = PhotoUID(volumeID: "vol", nodeID: "healthy-link")
        if healthyOther {
            failure.remove(from: store)
            XCTAssertNotNil(
                store.exclude(
                    [PendingExclusionRequest(key: key("healthy"), presentation: nil, remote: healthyRemote)], at: date))
            XCTAssertTrue(
                Self.setColumns(
                    "needs_queue_sync=0, next_attempt_at=\(date.timeIntervalSince1970 + 30)",
                    of: "healthy", at: storeURL))
            try failure.install(on: store)
        }
        try await startRejectedWriteClock(clock)
        XCTAssertTrue(failure.denied)
        XCTAssertEqual(store.sourceState(for: key("write"))?.nextAttemptAt, date.addingTimeInterval(10))
        XCTAssertEqual(effects.removed, [["write"]])
        XCTAssertEqual(
            clock.waits, [healthyOther ? .seconds(30) : .seconds(60)],
            "only another readable key may shorten the degraded backoff")
        if healthyOther {
            clock.advance(by: .seconds(30))
            try await pollWhileFalse { effects.trashed.joined().contains(healthyRemote) && clock.waits.count >= 2 }
            try await settle()
            XCTAssertEqual(Array(effects.trashed.joined()), [healthyRemote])
            XCTAssertEqual(effects.removed, [["write"]], "the unsaved key does not dispatch again")
            XCTAssertEqual(clock.waits, [.seconds(30), .seconds(120)])
        }
    }

    private func startRejectedWriteClock(_ clock: ResultWriteClock) async throws {
        await coordinator.close()
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        try await pollWhileFalse { !clock.waits.isEmpty }
        try await settle()
        XCTAssertFalse(clock.waits.isEmpty, "a real timer must register before its delay is checked")
    }

    private enum RejectedWrite {
        case trashCompletion, actionCompletion, actionFailure, actionRetry, trashRetry, noVolume, begin
        case queueCompletion, queueRetry, actionNoVolume

        var isAction: Bool {
            switch self {
            case .actionCompletion, .actionFailure, .actionRetry, .actionNoVolume: true
            default: false
            }
        }

        var isQueue: Bool { self == .queueCompletion || self == .queueRetry }

        var deniedAction: Int32 { self == .actionCompletion ? SQLITE_DELETE : SQLITE_UPDATE }

        var deniedColumn: String? {
            switch self {
            case .queueCompletion: "needs_queue_sync"
            case .trashCompletion: "remote_trashed"
            case .actionCompletion: nil
            case .actionFailure: "failed"
            case .actionRetry, .trashRetry, .noVolume, .queueRetry, .actionNoVolume: "attempts"
            case .begin: "remote_op"
            }
        }
    }

    private func prepareRejectedWrite(
        _ rejected: RejectedWrite
    ) throws -> (SourceListFailure, ResultWriteClock, PhotoUID) {
        let remote = PhotoUID(volumeID: "vol", nodeID: "link-write")
        if rejected.isAction {
            includedLater("write")
            XCTAssertNotEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: key("write"), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
                .failed)
            XCTAssertTrue(store.setFavoriteIntent(key("write"), favorite: true, at: date))
        } else {
            XCTAssertNotNil(
                store.exclude(
                    [
                        PendingExclusionRequest(
                            key: key("write"), presentation: nil, remote: rejected.isQueue ? nil : remote)
                    ], at: date))
            if !rejected.isQueue {
                XCTAssertTrue(Self.setColumns("needs_queue_sync=0", of: "write", at: storeURL))
            }
        }
        if rejected == .trashRetry { effects.trashRetry = [remote] }
        if rejected == .noVolume || rejected == .actionNoVolume { effects.volumeID = nil }
        if rejected == .queueRetry { effects.removeSucceeds = false }
        if rejected == .actionFailure { effects.favoriteResult = .permanentFailure }
        if rejected == .actionRetry { effects.favoriteResult = .retry }
        let failure = SourceListFailure(
            table: rejected.isAction ? "pending_action" : "source_state", untilRemoved: true,
            action: rejected.deniedAction, column: rejected.deniedColumn, transient: true)
        try failure.install(on: store)
        return (failure, ResultWriteClock(date), remote)
    }

    private func rejectedWrite(
        _ rejected: RejectedWrite, repeatedWaits: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let (failure, clock, _) = try prepareRejectedWrite(rejected)
        defer { failure.remove(from: store) }
        defer { clock.releaseAll() }
        await coordinator.close()
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })
        await coordinator.start()
        try await pollWhileFalse { !clock.waits.isEmpty }
        XCTAssertTrue(failure.denied, "the real result write must be rejected", file: file, line: line)

        let expected: [Duration] =
            repeatedWaits
            ? [
                .seconds(60), .seconds(120), .seconds(240), .seconds(480), .seconds(960), .seconds(1800),
                // An unsaved action result keeps its source_state, so the key's real next effect date stays
                // visible (#909): the fixture parks it at +5000, and the ladder above consumed 3660 of that.
                rejected == .actionCompletion ? .seconds(1340) : .seconds(1800),
            ]
            : [.seconds(60)]
        for (index, delay) in expected.enumerated() {
            try await pollWhileFalse { clock.waits.count > index }
            XCTAssertEqual(
                Array(clock.waits.prefix(index + 1)), Array(expected.prefix(index + 1)),
                "a rejected result waits for the degraded backoff", file: file, line: line)
            guard clock.waits.count > index, clock.waits[index] == delay else { return }
            let sent =
                rejected.isAction
                ? effects.favorites.count
                : rejected.isQueue ? effects.removed.count : effects.trashed.joined().count
            XCTAssertEqual(
                sent, rejected == .noVolume || rejected == .begin || rejected == .actionNoVolume ? 0 : 1,
                "an unsaved result is not sent again", file: file, line: line)
            if index + 1 < expected.count { clock.advance(by: delay) }
        }

        failure.remove(from: store)
        effects.volumeID = "photos-volume"
        clock.advance(by: expected.last!)
        try await pollWhileFalse {
            if rejected.isAction {
                let actions = store.actions()
                switch rejected {
                case .actionCompletion: return actions.isEmpty
                case .actionFailure: return actions.first?.failed == true
                default: return actions.first?.attempts == 1
                }
            }
            let state = store.sourceState(for: key("write"))
            if rejected == .trashRetry || rejected == .noVolume || rejected == .queueRetry {
                return state?.attempts == 1
            }
            return rejected.isQueue ? state?.needsQueueSync == false : state?.needsRemoteTrash == false
        }
        if rejected.isAction {
            let actions = store.actions()
            switch rejected {
            case .actionCompletion:
                XCTAssertTrue(actions.isEmpty, "the saved completion removes the action", file: file, line: line)
            case .actionFailure:
                XCTAssertEqual(actions.first?.failed, true, "the saved failure stays final", file: file, line: line)
            default:
                XCTAssertEqual(actions.first?.attempts, 1, "the retry time is saved", file: file, line: line)
            }
            XCTAssertEqual(
                effects.favorites.count, rejected == .actionNoVolume ? 0 : 1,
                "repair saves the result without another request", file: file, line: line)
        } else {
            let state = store.sourceState(for: key("write"))
            if rejected == .trashRetry || rejected == .noVolume || rejected == .queueRetry {
                XCTAssertEqual(state?.attempts, 1, "the retry time is saved", file: file, line: line)
                XCTAssertGreaterThan(state?.nextAttemptAt ?? .distantPast, clock.now, file: file, line: line)
            } else {
                XCTAssertEqual(
                    rejected.isQueue ? state?.needsQueueSync : state?.needsRemoteTrash, false,
                    "the completion is saved", file: file, line: line)
            }
            XCTAssertEqual(
                rejected.isQueue ? effects.removed.count : effects.trashed.joined().count,
                rejected == .noVolume ? 0 : 1,
                "repair saves the result before another request", file: file, line: line)
        }
        await coordinator.close()
    }

    /// Advances only when the test requests it. Every registered wait has its own gate.
    private final class ResultWriteClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        private enum WaitState { case live, fired, cancelled }
        private var recorded: [(duration: Duration, state: WaitState)] = []
        private var sleeping: [(due: Date, gate: OpenGate, index: Int)] = []
        private var registrationWaiters: [(duration: Duration, gate: OpenGate)] = []
        var now: Date { lock.withLock { value } }
        var waits: [Duration] { lock.withLock { recorded.map(\.duration) } }
        /// Only the waits that can still fire: neither cancelled by their timer task nor already
        /// released by `advance` or `releaseAll`.
        var liveWaits: [Duration] {
            lock.withLock { recorded.filter { $0.state == .live }.map(\.duration) }
        }

        init(_ date: Date) { value = date }

        /// Returns once a live wait of `duration` exists: at once when one is already live, otherwise when `sleep`
        /// registers it. A timer task registers its wait only when it starts, after the call that scheduled it.
        func waitForLiveWait(_ duration: Duration) async {
            let gate = OpenGate()
            let live = lock.withLock { () -> Bool in
                if recorded.contains(where: { $0.duration == duration && $0.state == .live }) { return true }
                registrationWaiters.append((duration, gate))
                return false
            }
            if !live { await gate.wait() }
        }

        func sleep(_ duration: Duration) async throws {
            let gate = OpenGate()
            let (index, registered) = lock.withLock { () -> (Int, [OpenGate]) in
                recorded.append((duration, .live))
                let parts = duration.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                sleeping.append((value.addingTimeInterval(seconds), gate, recorded.count - 1))
                let registered = registrationWaiters.filter { $0.duration == duration }.map(\.gate)
                registrationWaiters.removeAll { $0.duration == duration }
                return (recorded.count - 1, registered)
            }
            registered.forEach { $0.open() }
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                lock.withLock {
                    if recorded[index].state == .live { recorded[index].state = .cancelled }
                    sleeping.removeAll { $0.index == index }
                }
                gate.open()
            }
            try Task.checkCancellation()
        }

        func advance(by duration: Duration, wakingTimers: Bool = true) {
            let due = lock.withLock { () -> [OpenGate] in
                let parts = duration.components
                value = value.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
                guard wakingTimers else { return [] }
                let due = sleeping.filter { $0.due <= value }
                sleeping.removeAll { $0.due <= value }
                due.forEach { recorded[$0.index].state = .fired }
                return due.map(\.gate)
            }
            due.forEach { $0.open() }
        }

        func releaseAll() {
            let gates = lock.withLock {
                defer {
                    sleeping.removeAll()
                    registrationWaiters.removeAll()
                }
                sleeping.forEach { recorded[$0.index].state = .fired }
                return sleeping.map(\.gate) + registrationWaiters.map(\.gate)
            }
            gates.forEach { $0.open() }
        }
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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
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
        try await pollWhileFalse { !effects.favorites.isEmpty }
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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "an undecodable handoff is retried after a minute")
        assertNoShortWait(delays)
        XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='k';"))
        retry.open()
        try await pollWhileFalse { !effects.favorites.isEmpty }
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
        try await pollWhileFalse { !effects.favorites.isEmpty }
        XCTAssertEqual(effects.favorites, [remote], "the handoff event starts the action")
        retry.open()
    }

    /// Every read of the pending actions fails at start. The owed favorite is retried by the backoff; once the reads
    /// succeed it runs, and the backoff ends.
    func testAnActionRunsAfterTheActionListCouldNotBeRead() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        XCTAssertTrue(store.setFavoriteIntent(key("k"), favorite: true, at: date))
        let failure = SourceListFailure(table: "pending_action", untilRemoved: true, transient: true)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let delays = DelayLog()
        let retry = OpenGate()

        await restartWithBackoffLog(delays, firstRetry: retry)

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertTrue(failure.denied)
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "an unreadable action list waits a minute")
        assertNoShortWait(delays)
        failure.remove(from: store)
        retry.open()
        try await pollWhileFalse { !effects.favorites.isEmpty }
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

        try await pollWhileFalse { delays.values.count >= 2 }
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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertGreaterThan(failure.count, 0)
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)], "a failed due read waits for the backoff")
        assertNoShortWait(delays)
        failure.remove(from: store)
        retry.open()
        try await pollWhileFalse { !effects.favorites.isEmpty }
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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        failure.remove(from: store)
        XCTAssertEqual(failure.count, 1, "only the dispatch read failed")
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)])
        assertNoShortWait(delays)
        retry.open()
        try await pollWhileFalse { !effects.favorites.isEmpty }
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
        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
        failure.remove(from: store)

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k2")], favorite: true)
        XCTAssertEqual(effects.favorites.count, 2, "the clean pass runs both favorites")
        let again = KeyedReadFailure(matching: Self.latestHandoffRead)
        try again.install(on: store)
        defer { again.remove(from: store) }
        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k3")], favorite: true)
        try await pollWhileFalse { Self.backoffs(delays.values).count >= 2 }
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

    // MARK: - Delete of an edit whose handoff could not be read (#989)

    /// The delete of an unfinished edit cannot read the handoff, so it names no photo. Once a backoff pass reads the
    /// handoff, the rules of the delete prove the earlier upload, and it goes to the trash.
    func testADeleteWithAnUnreadableHandoffTrashesTheEarlierUploadOnceTheHandoffReads() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        let passes = BackoffPasses()
        try await startPendingEditWithoutHandoff(identities: identities, sleep: passes.sleep)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        await coordinator.exclude([key("p").localUID])
        XCTAssertEqual(failure.count, 1, "the delete could not read the handoff")
        XCTAssertTrue(effects.trashed.isEmpty, "no photo chosen on an unreadable handoff goes to the trash")
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)

        try await pollWhileFalse { passes.waiting > 0 }
        XCTAssertTrue(effects.trashed.isEmpty, "the read waits for the unreadable backoff")
        passes.allow()

        try await pollWhileFalse { !effects.trashed.isEmpty }
        XCTAssertEqual(effects.trashed, [[earlier]], "the photo the person deleted is the earlier upload")
        let state = try XCTUnwrap(store.sourceState(for: key("p")))
        XCTAssertEqual(state.desired, .excluded)
        XCTAssertEqual(state.remote, earlier)
        XCTAssertNil(
            identities.record(for: source("p"))?.remoteLinkID,
            "a return to the backup must not count the trashed photo as the backup of the source")
    }

    private func startEarlierUploadRetryBatch(
        _ ids: [String], plain: [String] = [], relations: FakeChecker,
        sleep: @Sendable @escaping (Duration) async throws -> Void
    ) async throws -> [String: PhotoUID] {
        await coordinator.close()
        let identities = FakeIdentityStore()
        let journal = try makeJournalCoordinator(identities: identities, relations: relations, sleep: sleep)
        var targets: [String: PhotoUID] = [:]
        for id in ids {
            let remote = PhotoUID(volumeID: "vol", nodeID: "earlier-\(id)")
            targets[id] = remote
            identities.upsert(identityRow(id, linkID: remote.nodeID))
            try journal.addSuperseded(remote, for: source(id))
            enqueue(id, state: .completed)
            enqueueEdit(id, state: .uploading)
            recorder.recordUploadEvidence(source: source(id), revision: edit, replaces: [remote])
        }
        for id in plain { enqueue(id, state: .uploading) }
        await coordinator.start()
        let count = ids.count + plain.count
        await waitForSnapshot("the batch is pending") { $0.tiles.count == count }
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let deleted = await coordinator.exclude((ids + plain).map { key($0).localUID })
        XCTAssertTrue(deleted)
        XCTAssertEqual(failure.count, ids.count, "each edit had an unreadable handoff")
        XCTAssertTrue(relations.relatedLookups.isEmpty)
        XCTAssertTrue(effects.trashed.isEmpty)
        return targets
    }

    func testARetrySnapshotDoesNotRemoveANewerDeletion() async throws {
        let ids = ["retry-a", "retry-b"]
        let relations = FakeChecker()
        let passes = BackoffPasses()
        let targets = try await startEarlierUploadRetryBatch(ids, relations: relations, sleep: passes.sleep)
        let gate = LookupGate()
        defer {
            gate.open()
            passes.allow()
        }
        relations.relatedLookupGate = { await gate.pass() }
        try await pollWhileFalse { passes.waiting > 0 }
        passes.allow()
        guard await gate.entered(within: .seconds(5)) else { return XCTFail("the first retry lookup must wait") }
        let first = try XCTUnwrap(relations.relatedLookups.first)
        XCTAssertTrue(targets.values.contains { $0.nodeID == first })
        let other = try XCTUnwrap(ids.first { targets[$0]?.nodeID != first })
        let restored = await coordinator.restore([key(other).localUID])
        XCTAssertTrue(restored)
        await waitForSnapshot("the restored edit is pending again") { $0.tiles.contains { $0.key.identifier == other } }
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let deleted = await coordinator.exclude([key(other).localUID])
        XCTAssertTrue(deleted)
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(store.sourceState(for: key(other))?.generation, 3)
        failure.remove(from: store)
        gate.open()
        try await pollWhileFalse { effects.trashed.flatMap { $0 }.contains { $0.nodeID == first } }
        try await settle()
        passes.allow()
        try await pollWhileFalse { effects.trashed.flatMap { $0 }.count == 2 }

        XCTAssertEqual(
            Set(effects.trashed.flatMap { $0 }), Set(targets.values), "the newer deletion keeps its own retry")
        XCTAssertEqual(store.sourceState(for: key(other))?.remote, targets[other])
        await coordinator.close()
    }

    func testARestoreRunsBetweenEarlierUploadLookups() async throws {
        let relations = FakeChecker()
        let passes = BackoffPasses()
        let targets = try await startEarlierUploadRetryBatch(
            ["latency-a", "latency-b"], plain: ["restore-me"], relations: relations, sleep: passes.sleep)
        let first = LookupGate()
        let second = LookupGate()
        let lookups = AppliedTrashReadCount()
        defer {
            first.open()
            second.open()
            passes.allow()
        }
        relations.relatedLookupGate = {
            switch lookups.next() {
            case 1: await first.pass()
            case 2: await second.pass()
            default: break
            }
        }
        try await pollWhileFalse { passes.waiting > 0 }
        passes.allow()
        guard await first.entered(within: .seconds(5)) else { return XCTFail("the first lookup must wait") }
        let restored = await coordinator.restore([key("restore-me").localUID])
        XCTAssertTrue(restored)
        first.open()
        guard await second.entered(within: .seconds(5)) else { return XCTFail("the second lookup must wait") }

        XCTAssertTrue(
            effects.returned.flatMap { $0 }.contains(key("restore-me")),
            "the restore must reach the backup before another earlier-upload lookup starts")
        second.open()
        try await pollWhileFalse { effects.trashed.flatMap { $0 }.count == 2 }
        XCTAssertEqual(Set(effects.trashed.flatMap { $0 }), Set(targets.values), "both deletions stay eligible")
        await coordinator.close()
    }

    func testAFailedRepeatDeleteKeepsTheStoredDeletionsRetry() async throws {
        let relations = FakeChecker()
        let passes = BackoffPasses()
        let targets = try await startEarlierUploadRetryBatch(["repeat"], relations: relations, sleep: passes.sleep)
        defer { passes.allow() }
        let generation = try XCTUnwrap(store.sourceState(for: key("repeat"))).generation
        let failure = KeyedReadFailure(matching: "INSERT INTO source_state(", limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let deleted = await coordinator.exclude([key("repeat").localUID])
        XCTAssertFalse(deleted, "the repeat delete was not stored")
        XCTAssertEqual(failure.count, 1)
        failure.remove(from: store)
        XCTAssertEqual(store.sourceState(for: key("repeat"))?.generation, generation)
        try await pollWhileFalse { passes.waiting > 0 }
        passes.allow()
        try await pollWhileFalse { !effects.trashed.isEmpty }

        XCTAssertEqual(
            effects.trashed.flatMap { $0 }, [try XCTUnwrap(targets["repeat"])],
            "a failed later write cannot cancel the stored deletion's retry")
        await coordinator.close()
    }

    func testUnrelatedHandoffsDoNotPostponeAnEarlierUploadRetry() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        let deadlines = RetryDeadlineSleeps()
        defer { deadlines.releaseAll() }
        try await startPendingEditWithoutHandoff(identities: identities, sleep: deadlines.sleep)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        let deleted = await coordinator.exclude([key("p").localUID])
        XCTAssertTrue(deleted)
        XCTAssertEqual(failure.count, 1)
        failure.remove(from: store)
        try await pollWhileFalse { deadlines.waits.contains(.seconds(60)) }
        XCTAssertTrue(deadlines.waits.contains(.seconds(60)), "the first retry has a 60-second deadline")

        for index in 1...8 {
            let id = "other-upload-\(index)"
            let remote = PhotoUID(volumeID: "vol", nodeID: id)
            enqueue(id, state: .uploading)
            await waitForSnapshot("the other upload is pending") { $0.tiles.contains { $0.key.identifier == id } }
            recorder.recordHandoff(source: source(id), revision: revision, remote: remote, kind: .uploaded)
            await waitForSnapshot("the real handoff event was processed") {
                $0.tiles.contains { $0.key.identifier == id && $0.handoff == remote }
            }
            try await settle()
            deadlines.advance(by: .seconds(10))
            try await settle()
            if index == 6 {
                try await pollWhileFalse { !effects.trashed.isEmpty }
                XCTAssertEqual(effects.trashed, [[earlier]], "the original deadline fires during the event stream")
            }
        }

        XCTAssertFalse(deadlines.waits.contains { $0 > .seconds(60) }, "clean handoffs must not double the retry wait")
        XCTAssertEqual(effects.trashed, [[earlier]], "the earlier upload settles while other uploads continue")
        await coordinator.close()
    }

    /// A failed guarded write keeps the deletion eligible for the next backoff pass.
    func testAFailedEarlierUploadWriteKeepsTheRetryUntilTheWriteSucceeds() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        let passes = BackoffPasses()
        try await startPendingEditWithoutHandoff(identities: identities, sleep: passes.sleep)
        let handoffFailure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try handoffFailure.install(on: store)
        defer { handoffFailure.remove(from: store) }
        let deleted = await coordinator.exclude([key("p").localUID])
        XCTAssertTrue(deleted)
        XCTAssertEqual(handoffFailure.count, 1)
        handoffFailure.remove(from: store)
        try await pollWhileFalse { passes.waiting > 0 }

        let writeFailure = KeyedReadFailure(
            matching:
                "SET needs_remote_trash=1, remote_volume_id=?, remote_link_id=?, remote_trashed=0, listed_in_trash=0",
            limit: 1)
        try writeFailure.install(on: store)
        defer { writeFailure.remove(from: store) }
        passes.allow()
        try await pollWhileFalse { writeFailure.count == 1 }
        XCTAssertEqual(writeFailure.count, 1, "the guarded write really failed")
        XCTAssertTrue(effects.trashed.isEmpty)
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
        writeFailure.remove(from: store)
        try await pollWhileFalse { passes.waiting > 0 }
        XCTAssertGreaterThan(passes.waiting, 0, "the failed write keeps a later retry")

        passes.allow()
        try await pollWhileFalse { !effects.trashed.isEmpty }

        XCTAssertEqual(effects.trashed, [[earlier]], "the same deletion settles after the write recovers")
        XCTAssertEqual(store.sourceState(for: key("p"))?.remote, earlier)
    }

    /// The read handoff names a photo of another upload. The retry applies the same rule as the delete: the photo
    /// stays, and the retry ends.
    func testARetriedDeleteKeepsAnEarlierPhotoThatAnotherUploadOwns() async throws {
        let passes = BackoffPasses()
        try await startPendingEdit(earlierKind: .deduplicated, identities: FakeIdentityStore(), sleep: passes.sleep)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        await coordinator.exclude([key("p").localUID])
        XCTAssertEqual(failure.count, 1, "the delete could not read the handoff")

        try await pollWhileFalse { passes.waiting > 0 }
        passes.allow()
        try await settle()

        XCTAssertTrue(effects.trashed.isEmpty, "a mapped photo can belong to another photo of the library")
        XCTAssertNil(store.sourceState(for: key("p"))?.remote)
        XCTAssertEqual(passes.waiting, 0, "a read handoff ends the retry")
    }

    /// The person restores the photo before the handoff reads. The restore ends the retry: no backoff waits for it.
    func testARestoreEndsTheRetryOfAnEarlierUpload() async throws {
        let identities = FakeIdentityStore()
        identities.upsert(identityRow("p", linkID: earlier.nodeID))
        let passes = BackoffPasses()
        try await startPendingEditWithoutHandoff(identities: identities, sleep: passes.sleep)
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 1)
        try failure.install(on: store)
        defer { failure.remove(from: store) }
        await coordinator.exclude([key("p").localUID])
        XCTAssertEqual(failure.count, 1, "the delete could not read the handoff")
        try await pollWhileFalse { passes.waiting > 0 }
        let waitsBefore = passes.waits.count

        await coordinator.restore([key("p").localUID])
        try await settle()

        XCTAssertEqual(passes.waits.count, waitsBefore, "the restored photo waits for no further read: \(passes.waits)")
        XCTAssertTrue(effects.trashed.isEmpty)
    }

    /// Every unresolved delete stays eligible for a retry, including the 101st delete in the session.
    func testAll101DeletesWithUnreadableHandoffsGetAnotherCheck() async throws {
        await coordinator.close()
        let identities = FakeIdentityStore()
        let relations = FakeChecker()
        let passes = BackoffPasses()
        let journal = try makeJournalCoordinator(identities: identities, relations: relations, sleep: passes.sleep)
        let ids = (1...101).map { "unreadable-edit-\($0)" }
        let remotes = ids.map { PhotoUID(volumeID: "vol", nodeID: "earlier-\($0)") }
        for (id, remote) in zip(ids, remotes) {
            identities.upsert(identityRow(id, linkID: remote.nodeID))
            try journal.addSuperseded(remote, for: source(id))
            enqueue(id, state: .completed)
            enqueueEdit(id, state: .uploading)
            recorder.recordUploadEvidence(source: source(id), revision: edit, replaces: [remote])
        }
        await coordinator.start()
        await waitForSnapshot("all 101 edits hide their earlier uploads") { $0.tiles.count == 101 }
        let failure = KeyedReadFailure(matching: Self.latestHandoffRead)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let deleted = await coordinator.exclude(ids.map { key($0).localUID })
        XCTAssertTrue(deleted)
        XCTAssertGreaterThanOrEqual(failure.count, 101, "each delete reached its unreadable handoff")
        XCTAssertTrue(effects.trashed.isEmpty, "an unreadable handoff proves no ownership")
        XCTAssertTrue(relations.relatedLookups.isEmpty, "unreadable handoffs cause no server lookups")
        failure.remove(from: store)
        try await pollWhileFalse { passes.waiting > 0 }
        passes.allow()
        try await pollWhileFalse { effects.trashed.flatMap { $0 }.count == 101 }

        XCTAssertEqual(Set(effects.trashed.flatMap { $0 }), Set(remotes), "no delete is dropped at 100")
        XCTAssertEqual(store.sourceState(for: key(ids[100]))?.remote, remotes[100], "the 101st delete is retried")
        XCTAssertEqual(Set(relations.relatedLookups), Set(remotes.map(\.nodeID)))
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

    /// A transient failure of the latest handoff read retries the favorite through the backoff.
    func testATransientHandoffReadFailureIsRetried() async throws {
        includedLater("k")
        let remote = favoriteFixture("k")
        let delays = DelayLog()
        let retry = OpenGate()
        await restartWithBackoffLog(delays, firstRetry: retry)
        let failure = SourceListFailure(table: "handoff", untilRemoved: true, transient: true)
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        _ = await coordinator.setFavorite([PhotoUID(localPending: .photoLibrary, identifier: "k")], favorite: true)

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
        try await settle()
        XCTAssertTrue(failure.denied)
        XCTAssertTrue(effects.favorites.isEmpty)
        XCTAssertEqual(Self.backoffs(delays.values), [.seconds(60)])
        assertNoShortWait(delays)
        failure.remove(from: store)
        retry.open()
        try await pollWhileFalse { !effects.favorites.isEmpty }
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
        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
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
        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }

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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
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

        try await pollWhileFalse { !Self.backoffs(delays.values).isEmpty }
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
        try await pollWhileFalse { delays.values.contains(.seconds(5000)) }

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
        private let armAfter: String?
        private var armed: Bool
        private var skip: Int
        private var limit: Int
        var count: Int { lock.withLock { interrupted } }

        /// Lets the first `skip` matching reads pass, then interrupts at most `limit` of them.
        init(
            matching fragment: String = "FROM source_state WHERE source_kind=? AND source_id=?", skip: Int = 0,
            limit: Int = .max, armAfter: String? = nil
        ) {
            self.fragment = fragment
            self.armAfter = armAfter
            self.armed = armAfter == nil
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
                        guard let sql = sqlite3_sql(statement).map({ String(cString: $0) }) else { return 0 }
                        if let armAfter = failure.armAfter, sql.contains(armAfter) {
                            failure.lock.withLock { failure.armed = true }
                        }
                        guard sql.contains(failure.fragment) else { return 0 }
                        let interrupts = failure.lock.withLock { () -> Bool in
                            guard failure.armed else { return false }
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

        /// Matching reads answer again from now on, as a recovered disk would: the remaining
        /// budget drops to zero, so no read is interrupted again.
        func recover() {
            lock.withLock { limit = 0 }
        }

        static func connection(of store: PendingBackupManifestStore) throws -> SQLiteStoreConnection {
            try XCTUnwrap(
                Mirror(reflecting: store).children.first(where: { $0.label == "connection" })?.value
                    as? SQLiteStoreConnection)
        }
    }

    /// Fails the selected SQL operation, once or until removal. Transient recovery tests use SQLITE_INTERRUPT;
    /// the default SQLITE_AUTH is a lasting failure and never claims that removing the fault recovers the connection.
    private final class SourceListFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let table: String
        private let untilRemoved: Bool
        private let action: Int32
        private let column: String?
        private let transient: Bool
        private var interruptNextOperation = false
        var denied: Bool { lock.withLock { done } }

        init(
            table: String = "source_state", untilRemoved: Bool = false,
            action: Int32 = SQLITE_READ, column: String? = nil, transient: Bool = false
        ) {
            self.table = table
            self.untilRemoved = untilRemoved
            self.action = action
            self.column = column
            self.transient = transient
        }

        func install(on store: PendingBackupManifestStore) throws {
            let connection = try KeyedReadFailure.connection(of: store)
            connection.withLock {
                if transient {
                    sqlite3_progress_handler(
                        connection.database, 1,
                        { context in
                            guard let context else { return 0 }
                            let failure = Unmanaged<SourceListFailure>.fromOpaque(context).takeUnretainedValue()
                            return failure.lock.withLock {
                                guard failure.interruptNextOperation else { return 0 }
                                failure.interruptNextOperation = false
                                failure.done = true
                                return 1
                            }
                        }, Unmanaged.passUnretained(self).toOpaque())
                }
                _ = sqlite3_set_authorizer(
                    connection.database,
                    { context, action, table, column, _, _ in
                        guard let context, let table else { return SQLITE_OK }
                        let failure = Unmanaged<SourceListFailure>.fromOpaque(context).takeUnretainedValue()
                        guard action == failure.action, String(cString: table) == failure.table,
                            failure.column == nil || column.map({ String(cString: $0) }) == failure.column
                        else { return SQLITE_OK }
                        return failure.lock.withLock {
                            guard !failure.done || failure.untilRemoved else { return SQLITE_OK }
                            if failure.transient {
                                failure.interruptNextOperation = true
                                return SQLITE_OK
                            }
                            failure.done = true
                            return SQLITE_DENY
                        }
                    }, Unmanaged.passUnretained(self).toOpaque())
            }
        }

        func remove(from store: PendingBackupManifestStore) {
            guard let connection = try? KeyedReadFailure.connection(of: store) else { return }
            connection.withLock {
                _ = sqlite3_set_authorizer(connection.database, nil, nil)
                if transient {
                    sqlite3_progress_handler(connection.database, 0, nil, nil)
                    XCTAssertTrue(
                        connection.failuresAreTransient, "the recovery fixture must not inject lasting errors")
                }
            }
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
    private var _favoriteValues: [Bool] = []
    private var _removeSucceeds = true
    private var _albumResult = PendingEffectResult.done
    private var _favoriteResult = PendingEffectResult.done
    private var _volumeID: String? = "photos-volume"
    private var _trashRetry = Set<PhotoUID>()
    private var _order: [String] = []

    var order: [String] { lock.withLock { _order } }

    var removed: [[String]] { lock.withLock { _removed } }
    var returned: [[PendingSourceKey]] { lock.withLock { _returned } }
    var trashed: [[PhotoUID]] { lock.withLock { _trashed } }
    var restored: [[PhotoUID]] { lock.withLock { _restored } }
    var favorites: [PhotoUID] { lock.withLock { _favorites } }
    var favoriteValues: [Bool] { lock.withLock { _favoriteValues } }
    var removeSucceeds: Bool {
        get { lock.withLock { _removeSucceeds } }
        set { lock.withLock { _removeSucceeds = newValue } }
    }
    var albumResult: PendingEffectResult {
        get { lock.withLock { _albumResult } }
        set { lock.withLock { _albumResult = newValue } }
    }
    var favoriteResult: PendingEffectResult {
        get { lock.withLock { _favoriteResult } }
        set { lock.withLock { _favoriteResult = newValue } }
    }
    var volumeID: String? {
        get { lock.withLock { _volumeID } }
        set { lock.withLock { _volumeID = newValue } }
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

    func returnToBackup(_ keys: [PendingSourceKey]) async -> Set<PendingSourceKey> {
        let hook = lock.withLock {
            _returned.append(keys.sorted())
            _order.append("return")
            defer { _onReturn = nil }
            return _onReturn
        }
        hook?()
        return Set(keys)
    }

    var typedReturnOverride: [PendingSourceKey: PendingBackupReturnOutcome]? {
        get { lock.withLock { _typedReturnOverride } }
        set { lock.withLock { _typedReturnOverride = newValue } }
    }
    private var _typedReturnOverride: [PendingSourceKey: PendingBackupReturnOutcome]?

    func returnToBackup(_ states: [PendingSourceState]) async -> [PendingSourceKey: PendingBackupReturnOutcome] {
        let returned = await returnToBackup(states.map(\.key))
        if let override = typedReturnOverride { return override }
        return Dictionary(
            uniqueKeysWithValues: states.map { ($0.key, returned.contains($0.key) ? .completed : .unreadable) })
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
        return volumeID
    }

    /// Holds the next trash request until the gate opens.
    var trashGate: LookupGate? {
        get { lock.withLock { _trashGate } }
        set { lock.withLock { _trashGate = newValue } }
    }
    private var _trashGate: LookupGate?

    /// Holds only the acknowledgement after the fake remote records its applied trash.
    var trashCompletionGate: LookupGate? {
        get { lock.withLock { _trashCompletionGate } }
        set { lock.withLock { _trashCompletionGate = newValue } }
    }
    private var _trashCompletionGate: LookupGate?

    func trashRemote(_ uids: [PhotoUID]) async -> PendingBatchEffectResult {
        await trashGate?.pass()
        let answer = lock.withLock {
            _trashed.append(uids)
            _order.append("trash")
            return PendingBatchEffectResult(retry: _trashRetry.intersection(uids))
        }
        await trashCompletionGate?.pass()
        return answer
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
        return lock.withLock {
            _favorites.append(uid)
            _favoriteValues.append(favorite)
            return _favoriteResult
        }
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

/// Advances only long waits by their deadlines. Cancelled timers do not become runnable early.
private final class RetryDeadlineSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed = Duration.zero
    private var recorded: [Duration] = []
    private var pending: [(deadline: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    var waits: [Duration] { lock.withLock { recorded } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            guard duration >= .seconds(60) else { return try await Task.sleep(for: duration) }
            await withCheckedContinuation { continuation in
                lock.withLock {
                    recorded.append(duration)
                    pending.append((elapsed + duration, continuation))
                }
            }
        }
    }

    func advance(by duration: Duration) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            elapsed += duration
            let ready = pending.filter { $0.deadline <= elapsed }.map(\.continuation)
            pending.removeAll { $0.deadline <= elapsed }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    func releaseAll() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { pending.removeAll() }
            return pending.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }
}

/// Holds every backoff wait (60 s or more) until `allow()` lets one pass; shorter waits sleep for real.
private final class BackoffPasses: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    private var permits = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    var waits: [Duration] { lock.withLock { recorded } }
    var waiting: Int { lock.withLock { parked.count } }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            guard duration >= .seconds(60) else { return try await Task.sleep(for: duration) }
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    recorded.append(duration)
                    guard permits > 0 else {
                        parked.append(continuation)
                        return false
                    }
                    permits -= 1
                    return true
                }
                if resume { continuation.resume() }
            }
        }
    }

    /// Releases every parked wait; a timer that the coordinator replaced meanwhile ends without a pass. Without a
    /// parked wait, the next one passes.
    func allow() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !parked.isEmpty else {
                permits += 1
                return []
            }
            defer { parked.removeAll() }
            return parked
        }
        released.forEach { $0.resume() }
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
    func decisionUnsettledRows() throws -> [UploadBackupQueueRowState] {
        lock.withLock { unsettled += 1 }
        return pending
    }
    func backedUpRevisions(kind: UploadSourceIdentity.Kind) -> [String: UploadBackupRevision] {
        lock.withLock { aggregates += 1 }
        return [:]
    }
    func decisionRows(
        kind: UploadSourceIdentity.Kind, identifiers: Set<String>
    ) throws -> [UploadBackupQueueRowState] {
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
    func restoreDeletionChoice(
        _ previous: EditReplacementDeletionChoice, ifStill written: EditReplacementDeletionChoice,
        for source: UploadSourceIdentity
    ) throws {}
    func addSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {}
    func addRemoteSuperseded(_ uid: PhotoUID, for source: UploadSourceIdentity) throws {}
    func addProven(_ nodeID: String, inherited: [String], for source: UploadSourceIdentity) throws {}
    func prepareToRetire(_ relatedByMain: [String: [String]], for source: UploadSourceIdentity) throws {}
    func clearRetireIntent(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {}
    func settle(_ nodeIDs: Set<String>, related: Set<String>, trashed: Bool, for source: UploadSourceIdentity) throws {}
    func settleGone(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {}
    func recordUpload(edited: Bool, for source: UploadSourceIdentity) throws {}
    func unretire(_ nodeIDs: Set<String>, for source: UploadSourceIdentity) throws {}
    func supersededSourceIdentifiers() -> Set<String> { [] }
    func namesAnyLink(_ linkIDs: Set<String>) -> Bool { true }
}

extension PendingBackupCoordinatorTests {
    func testIncompleteRestoreChecksBackOffAndStopUntilRestartOrAnExplicitRestore() async throws {
        for resume in ["restart", "explicit restore"] {
            await coordinator.close()
            let id = "bounded-compound-\(resume)"
            let sourceKey = key(id)
            let remote = PhotoUID(volumeID: "vol", nodeID: id)
            let clock = ResultWriteClock(date)
            enqueue(id, state: .completed)
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(key: sourceKey, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
                ),
                .recorded)
            let excluded = try XCTUnwrap(
                store.exclude([.init(key: sourceKey, presentation: nil, remote: remote)], at: date)?.first)
            XCTAssertTrue(
                store.completeEffect(
                    .remoteTrash, for: sourceKey, generation: excluded.generation,
                    remoteLinkID: remote.nodeID, at: date))
            XCTAssertTrue(store.completeEffect(.queueSync, for: sourceKey, generation: excluded.generation, at: date))
            let relations = FakeChecker()
            relations.linkVisibilityByID[remote.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
            effects = FakePendingEffects()
            effects.typedReturnOverride = [sourceKey: .waiting(until: date)]
            coordinator = makeCoordinator(relations: relations, clock: clock)
            await coordinator.start()
            _ = await coordinator.restoreSources(ofRemote: [remote])

            for (index, delay) in [60, 300, 900].enumerated() {
                XCTAssertEqual(effects.returned.filter { $0 == [sourceKey] }.count, index + 1)
                let retained = try XCTUnwrap(store.sourceState(for: sourceKey))
                XCTAssertTrue(retained.needsQueueSync)
                XCTAssertEqual(retained.remote, remote)
                XCTAssertEqual(retained.attempts, 0)
                XCTAssertEqual(retained.nextAttemptAt, clock.now.addingTimeInterval(Double(delay)))
                clock.advance(by: .seconds(delay))
                if index < 2 {
                    // An unrelated trigger joins a real reconcile but must not reset this source's ceiling.
                    _ = await coordinator.restoreSources(ofRemote: [.init(volumeID: "vol", nodeID: "unrelated")])
                }
            }
            let reads = relations.linkVisibilityCallCount
            _ = await coordinator.restoreSources(ofRemote: [.init(volumeID: "vol", nodeID: "unrelated")])
            XCTAssertEqual(
                effects.returned.filter { $0 == [sourceKey] }.count, 3, "The session ceiling stops effect calls")
            XCTAssertEqual(relations.linkVisibilityCallCount, reads, "The ceiling stops even the preceding fresh read")
            let paused = try XCTUnwrap(store.sourceState(for: sourceKey))
            XCTAssertTrue(paused.needsQueueSync)
            XCTAssertEqual(paused.remote, remote)
            XCTAssertEqual(paused.attempts, 0)
            XCTAssertTrue(effects.restored.isEmpty)
            XCTAssertTrue(effects.trashed.isEmpty)

            effects.typedReturnOverride = [sourceKey: .completed]
            clock.advance(by: .seconds(1))
            if resume == "restart" {
                await coordinator.close()
                coordinator = makeCoordinator(relations: relations, clock: clock)
                await coordinator.start()
            } else {
                let completed = await coordinator.restoreSources(ofRemote: [remote])
                XCTAssertEqual(completed.outcomes[sourceKey], .completed)
            }
            XCTAssertNil(store.sourceState(for: sourceKey), "Fresh successful proof can retire the retained duty")
            XCTAssertEqual(effects.returned.filter { $0 == [sourceKey] }.count, 4)
        }
    }

    func testFailedRestoreReadsUseTheSameGrowingWaitsBeforeTheCeiling() async throws {
        await coordinator.close()
        let id = "offline-restore-check"
        let sourceKey = key(id)
        let remote = PhotoUID(volumeID: "vol", nodeID: id)
        let clock = ResultWriteClock(date)
        enqueue(id, state: .completed)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: sourceKey, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        let excluded = try XCTUnwrap(
            store.exclude([.init(key: sourceKey, presentation: nil, remote: remote)], at: date)?.first)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: sourceKey, generation: excluded.generation, remoteLinkID: remote.nodeID, at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: sourceKey, generation: excluded.generation, at: date))
        // No visibility entry: every fresh read fails, as it does offline.
        let relations = FakeChecker()
        effects = FakePendingEffects()
        coordinator = makeCoordinator(relations: relations, clock: clock)
        await coordinator.start()
        _ = await coordinator.restoreSources(ofRemote: [remote])

        for (index, delay) in [60, 300, 900].enumerated() {
            XCTAssertEqual(relations.linkVisibilityCallCount, index + 1, "One fresh read per automatic check")
            let retained = try XCTUnwrap(store.sourceState(for: sourceKey))
            XCTAssertTrue(retained.needsQueueSync)
            XCTAssertEqual(retained.remote, remote)
            XCTAssertEqual(retained.attempts, 0)
            XCTAssertEqual(
                retained.nextAttemptAt, clock.now.addingTimeInterval(Double(delay)),
                "Check \(index + 1) waits \(delay) seconds")
            clock.advance(by: .seconds(delay))
            _ = await coordinator.restoreSources(ofRemote: [.init(volumeID: "vol", nodeID: "unrelated")])
        }
        XCTAssertEqual(relations.linkVisibilityCallCount, 3, "The ceiling stops a fourth automatic read")
        XCTAssertTrue(effects.returned.isEmpty, "A failed read never reaches the typed effect")
        XCTAssertTrue(effects.restored.isEmpty)
    }

    func testARestoreCheckTreatsTheTrashOfAPhotoAnEditReplacedAsDone() async throws {
        for replacement in [
            "none", "unretired", "retired", "retire intent", "intent during the read", "intent during the final read",
        ] {
            await coordinator.close()
            let id = "edit-replaced-restore-\(replacement.replacingOccurrences(of: " ", with: "-"))"
            let sourceKey = key(id)
            let remote = PhotoUID(volumeID: "vol", nodeID: id)
            enqueue(id, state: .completed)
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(key: sourceKey, revision: revision, remote: remote, kind: .uploaded, createdAt: date)
                ),
                .recorded)
            let excluded = try XCTUnwrap(
                store.exclude([.init(key: sourceKey, presentation: nil, remote: remote)], at: date)?.first)
            XCTAssertTrue(
                store.completeEffect(
                    .remoteTrash, for: sourceKey, generation: excluded.generation, remoteLinkID: remote.nodeID,
                    at: date))
            XCTAssertTrue(store.completeEffect(.queueSync, for: sourceKey, generation: excluded.generation, at: date))
            // After the Restore the photo is in the Proton trash again.
            let relations = FakeChecker()
            relations.linkVisibilityByID[remote.nodeID] = .init(
                isActive: false, mainPhotoLinkID: nil, trashTime: 1_750_000_001)
            let journal = try XCTUnwrap(EditReplacementJournalFileStore.shared(accountDataDirectory: directory))
            let photo = source(id)
            switch replacement {
            case "retired", "retire intent", "unretired":
                try journal.addSuperseded(remote, for: photo)
                try journal.prepareToRetire([remote.nodeID: []], for: photo)
                if replacement != "retire intent" {
                    try journal.settle([remote.nodeID], related: [], trashed: true, for: photo)
                }
                // The person restored the replaced photo: it is in the library again by choice.
                if replacement == "unretired" { try journal.unretire([remote.nodeID], for: photo) }
            case "intent during the read":
                // The edit replacement writes its intent and trashes the photo while the fresh read runs.
                relations.linkVisibilityByID[remote.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
                relations.onVisibilityLookup = { [relations] in
                    try? journal.addSuperseded(remote, for: photo)
                    try? journal.prepareToRetire([remote.nodeID: []], for: photo)
                    relations.linkVisibilityByID[remote.nodeID] = .init(
                        isActive: false, mainPhotoLinkID: nil, trashTime: 1_750_000_002)
                }
            case "intent during the final read":
                // The compound is complete at the first read; the replacement trashes the photo before the final read.
                relations.linkVisibilityByID[remote.nodeID] = .init(isActive: true, mainPhotoLinkID: nil)
                let reads = AppliedTrashReadCount()
                relations.onVisibilityLookup = { [relations] in
                    guard reads.next() == 2 else { return }
                    try? journal.addSuperseded(remote, for: photo)
                    try? journal.prepareToRetire([remote.nodeID: []], for: photo)
                    relations.linkVisibilityByID[remote.nodeID] = .init(
                        isActive: false, mainPhotoLinkID: nil, trashTime: 1_750_000_002)
                }
            default: break
            }
            effects = FakePendingEffects()
            if replacement == "intent during the final read" { effects.typedReturnOverride = [sourceKey: .completed] }
            coordinator = makeCoordinator(replacementJournal: journal, relations: relations)
            await coordinator.start()

            let result = await coordinator.restoreSources(ofRemote: [remote])

            relations.onVisibilityLookup = nil
            if replacement == "none" || replacement == "unretired" {
                XCTAssertEqual(effects.restored, [[remote]], "\(replacement): a late trash gets its compensation")
                XCTAssertNotNil(store.sourceState(for: sourceKey))
                continue
            }
            XCTAssertTrue(effects.restored.isEmpty, "\(replacement): the edit's trash of the old photo stands")
            if replacement == "intent during the final read" {
                XCTAssertEqual(
                    effects.returned, [[sourceKey]], "The race reached the final read after a complete compound")
            } else {
                XCTAssertTrue(effects.returned.isEmpty, "\(replacement): the newer version already backed up")
            }
            XCTAssertEqual(result.outcomes[sourceKey], .completed, replacement)
            XCTAssertNil(store.sourceState(for: sourceKey), "\(replacement): the Restore duty is done")
        }
    }

    private struct LookupArmedRestoreResolver: BackupResourceResolving {
        let resource: BackupResolvedResource
        let arm: @Sendable () async -> Void

        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            await arm()
            return resource
        }
    }

    func testRevokedRestoreAdoptionCannotCreateARunnerHandoffOrRemoteTrash() async throws {
        for exactFallback in [false, true] {
            await coordinator.close()
            let id = exactFallback ? "revoked-exact" : "revoked-manifest"
            let target = source(id)
            let targetKey = key(id)
            let date = self.date
            let pending = try XCTUnwrap(store)
            let manifest = try XCTUnwrap(
                UploadIdentityManifestStore(url: directory.appendingPathComponent("\(id)-identities.sqlite")))
            defer { manifest.close() }
            let state = try XCTUnwrap(
                UploadBackupStateManifestStore(url: directory.appendingPathComponent("\(id)-backup.sqlite")))
            defer { state.close() }
            let checker = FakeChecker()
            let pipeline = UploadDedupePipeline(store: manifest, checker: checker, now: { date })
            let digest = Data(repeating: 0xCA, count: 20)
            let hex = UploadContentSHA1.hexString(digest: digest)
            let descriptor = UploadResourceDescriptor(
                source: target, fileURL: directory.appendingPathComponent(id), filename: "\(id).heic",
                fileSize: 20, modificationDate: date, precomputedSHA1Digest: digest, backupRevision: revision)
            let before = UploadIdentityRecord(
                source: target, filename: descriptor.filename, correctedName: descriptor.filename,
                fileSize: 20, modificationDate: date, sha1Hex: hex,
                nameHash: "nh(\(descriptor.filename))", contentHash: "ch(\(hex))", hashKeyEpoch: "epoch-1",
                updatedAt: date)
            XCTAssertTrue(manifest.upsert(before))
            if exactFallback {
                checker.exactActiveDuplicates = [.init(volumeID: "vol", nodeID: "foreign-donor")]
            } else {
                var donor = before
                donor.source = source("donor-\(id)")
                donor.remoteVolumeID = "vol"
                donor.remoteLinkID = "foreign-donor"
                donor.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
                XCTAssertTrue(manifest.upsert(donor))
            }
            checker.linkVisibilityByID["foreign-donor"] = .init(isActive: true, mainPhotoLinkID: nil)
            let context = UploadRestoredCompoundContext(
                source: target, revision: revision, generation: 2,
                confirmedRemote: .init(volumeID: "vol", nodeID: "confirmed"))
            try await pipeline.prepareRestoredCompound(context, isCurrent: { true })
            let reached = AppliedTrashReadCount()
            let revoke: @Sendable () async -> Void = {
                _ = reached.next()
                XCTAssertNotNil(pending.exclude([.init(key: targetKey, presentation: nil, remote: nil)], at: date))
                await pipeline.endRestoredCompound(context)
            }
            let candidate = UploadBackupAssetCandidate(
                snapshot: .init(source: target, revision: revision, resourceCount: 1),
                originalFilename: descriptor.filename, byteCount: 20)
            let resolver = LookupArmedRestoreResolver(
                resource: .init(
                    candidate: candidate, descriptor: descriptor, mediaType: "image/heic", captureDate: date),
                arm: {
                    // Arm after the real runner primes, so the suspended lookup belongs to resolve itself.
                    await pipeline.invalidateCachedRemoteState()
                    if exactFallback {
                        checker.findError = UploadError.backend("Detailed lookup unavailable")
                        checker.exactLookupGate = revoke
                    } else {
                        checker.nameLookupGate = revoke
                    }
                })
            enqueue(id, state: .queuedForUpload)
            let uploader = MockUploader()
            let clock = BackupTestClock(start: date)
            let runner = BackupSyncRunner(
                queue: queue, preflight: UploadBackupPreflightIndex(store: state), resolver: resolver,
                identityResolver: pipeline, uploader: uploader,
                configuration: .init(throttle: .init(baseConcurrency: 1)), clock: clock,
                events: recorder, now: { clock.now })
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
            await runner.stop()

            XCTAssertEqual(reached.count, 1, "The real runner must reach exactly the gated adoption lookup")
            XCTAssertEqual(manifest.record(for: target), before, "Revocation cannot write a donor identity")
            XCTAssertTrue(
                store.latestHandoffs(for: [targetKey]).isEmpty, "No donor handoff may reach the pending store")
            let excluded = try XCTUnwrap(store.sourceState(for: targetKey))
            XCTAssertEqual(excluded.desired, .excluded)
            XCTAssertNil(excluded.remote)
            XCTAssertFalse(excluded.needsRemoteTrash)
            XCTAssertTrue(uploader.requests.isEmpty)
            let interrupted = try XCTUnwrap(queue.entry(for: target, revision: revision))
            XCTAssertEqual(interrupted.attempts, 0)
            XCTAssertFalse(interrupted.state.isTerminalSuccess)
            effects = FakePendingEffects()
            coordinator = makeCoordinator()
            await coordinator.start()
            XCTAssertTrue(
                effects.trashed.isEmpty, "A revoked adoption cannot schedule remote trash through reconciliation")
        }
    }

    func testPersistentRestoreRefusalDefersCompensationWithoutBurningAttempts() async throws {
        await coordinator.close()
        let id = "persistently-refused-restore"
        let remote = PhotoUID(volumeID: "vol", nodeID: "refused-main")
        let clock = ResultWriteClock(date)
        enqueue(id, state: .completed)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: key(id), revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: remote)], at: date)?.first)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key(id), generation: excluded.generation,
                remoteLinkID: remote.nodeID, at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: excluded.generation, at: date))
        let relations = FakeChecker()
        let refused = try XCTUnwrap(effects)
        // A permanent per-item refusal is settled by the batch adapter, but the fresh read stays trashed.
        // After three requests the fixture reports an unavailable read, so a broken loop ends on data,
        // not a timeout. More than one request before the persisted due time is the direct failure.
        relations.onVisibilityLookup = {
            relations.linkVisibilityByID[remote.nodeID] = .init(
                isActive: false, mainPhotoLinkID: nil, trashTime: 1_750_000_000)
            if refused.restored.count >= 3 {
                relations.linkVisibilityError = UploadError.backend("Bounded refusal fixture exhausted")
            }
        }
        coordinator = makeCoordinator(relations: relations, clock: clock)
        await coordinator.start()

        _ = await coordinator.restoreSources(ofRemote: [remote])

        XCTAssertEqual(effects.restored, [[remote]], "One refusal must defer the next remote compensation")
        let retained = try XCTUnwrap(store.sourceState(for: key(id)))
        XCTAssertTrue(retained.needsRemoteRestore, "A refused restore still owes its exact photo")
        XCTAssertTrue(retained.needsQueueSync)
        XCTAssertEqual(retained.remote, remote)
        XCTAssertEqual(retained.attempts, 0, "An unsuccessful recheck cannot burn the effect budget")
        XCTAssertEqual(retained.nextAttemptAt, date.addingTimeInterval(60))
        clock.advance(by: .seconds(59))
        _ = await coordinator.restoreSources(ofRemote: [remote])
        XCTAssertEqual(effects.restored, [[remote]], "The persisted delay must also gate a new reconcile call")
        clock.advance(by: .seconds(1))
        _ = await coordinator.restoreSources(ofRemote: [remote])
        XCTAssertEqual(effects.restored, [[remote], [remote]], "Exactly one retry becomes due after the delay")
        let retried = try XCTUnwrap(store.sourceState(for: key(id)))
        XCTAssertTrue(retried.needsRemoteRestore)
        XCTAssertEqual(retried.remote, remote)
        XCTAssertEqual(retried.attempts, 0)
        XCTAssertEqual(retried.nextAttemptAt, clock.now.addingTimeInterval(60))
        XCTAssertTrue(effects.returned.isEmpty, "A still-trashed main cannot enter the compound recheck")
    }

    func testMissingTypedRestoreOutcomeIsUnreadableAndKeepsItsUIDOwed() async throws {
        await coordinator.close()
        let id = "missing-typed-outcome"
        enqueue(id, state: .completed)
        let remote = PhotoUID(volumeID: "vol", nodeID: "missing-typed-target")
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key(id), revision: revision,
                    remote: remote, kind: .uploaded, createdAt: date)), .recorded)
        let excluded = try XCTUnwrap(
            store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: remote)], at: date)?.first)
        XCTAssertTrue(
            store.completeEffect(
                .remoteTrash, for: key(id), generation: excluded.generation, remoteLinkID: remote.nodeID, at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: excluded.generation, at: date))
        effects.typedReturnOverride = [:]
        coordinator = makeCoordinator()
        await coordinator.start()

        let result = await coordinator.restoreSources(ofRemote: [remote])

        XCTAssertEqual(result.outcomes[key(id)], .unreadable)
        let retained = try XCTUnwrap(store.sourceState(for: key(id)))
        XCTAssertEqual(retained.remote, remote)
        XCTAssertTrue(retained.needsQueueSync)
        XCTAssertEqual(retained.nextAttemptAt, date.addingTimeInterval(60))
        XCTAssertEqual(retained.attempts, 0)
        XCTAssertTrue(effects.restored.isEmpty)
    }

    func testUnreadableDiscoveredRestoreKeyReportsTheWholeBatchWithoutReturningAHealthySubset() async throws {
        await coordinator.close()
        let remote = PhotoUID(volumeID: "vol", nodeID: "two-source-restore")
        for id in ["readable-key", "unreadable-key"] {
            enqueue(id, state: .completed)
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: key(id), revision: revision,
                        remote: remote, kind: .uploaded, createdAt: date)), .recorded)
            let excluded = try XCTUnwrap(
                store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: remote)], at: date)?
                    .first)
            XCTAssertTrue(
                store.completeEffect(
                    .remoteTrash, for: key(id), generation: excluded.generation, remoteLinkID: remote.nodeID, at: date))
            XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: excluded.generation, at: date))
        }
        coordinator = makeCoordinator()
        await coordinator.start()
        // Startup recovery may read the same keys. Arm only at this restore's reverse query;
        // its discovery reads follow without an actor suspension.
        let failure = KeyedReadFailure(limit: 1, armAfter: "FROM handoff WHERE remote_link_id=?")
        try failure.install(on: store)
        let result = await coordinator.restoreSources(ofRemote: [remote])
        failure.remove(from: store)
        XCTAssertEqual(failure.count, 1, "The keyed discovery read really failed")
        XCTAssertEqual(result.outcomes, [key("readable-key"): .unreadable, key("unreadable-key"): .unreadable])
        XCTAssertTrue(effects.returned.isEmpty, "A complete reverse query does not permit a partial source-state read")
        XCTAssertTrue(effects.restored.isEmpty)
    }
}

extension PendingBackupCoordinatorTests {
    func testConfirmedRestoreRequiresAnExplicitActiveMainBeforeCallingTheTypedEffect() async throws {
        for kind in ["missing", "inferred", "inactive", "related"] {
            await coordinator.close()
            let id = "fresh-coordinator-\(kind)"
            let remote = PhotoUID(volumeID: "vol", nodeID: "main-\(kind)")
            enqueue(id, state: .completed)
            XCTAssertEqual(
                store.recordHandoff(
                    PendingHandoff(
                        key: key(id), revision: revision, remote: remote,
                        kind: .uploaded, createdAt: date)), .recorded)
            let excluded = try XCTUnwrap(
                store.exclude([PendingExclusionRequest(key: key(id), presentation: nil, remote: remote)], at: date)?
                    .first)
            XCTAssertTrue(
                store.completeEffect(
                    .remoteTrash, for: key(id), generation: excluded.generation, remoteLinkID: remote.nodeID, at: date))
            XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: excluded.generation, at: date))
            let relations = FakeChecker()
            if kind != "missing" {
                relations.linkVisibilityByID[remote.nodeID] = .init(
                    isActive: kind != "inactive",
                    mainPhotoLinkID: kind == "related" ? "foreign" : nil, hasExplicitPhotoState: kind != "inferred")
            }
            effects = FakePendingEffects()
            coordinator = makeCoordinator(relations: relations)
            await coordinator.start()
            let result = await coordinator.restoreSources(ofRemote: [remote])
            XCTAssertEqual(result.outcomes[key(id)], .unreadable, kind)
            XCTAssertTrue(effects.returned.isEmpty, "No active proof means no controller admission: \(kind)")
            XCTAssertTrue(try XCTUnwrap(store.sourceState(for: key(id))).needsQueueSync)
            XCTAssertEqual(store.sourceState(for: key(id))?.remote, remote)
        }
    }
}

extension PendingBackupCoordinatorTests {
    func testPendingReconcileRefusesAnOpenTransaction() async throws {
        try await pendingReconcileRefuses(.openTransaction)
    }

    func testPendingReconcileRefusesALastingFailure() async throws {
        try await pendingReconcileRefuses(.lastingFailure)
    }

    func testPendingReconcileRefusesAFailedRollback() async throws {
        try await pendingReconcileRefuses(.failedRollback)
    }

    private func pendingReconcileRefuses(_ fault: PendingStoreTransactionFault) async throws {
        await coordinator.close()
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: clock.sleep)
        let id = "unavailable-deletion"
        let sourceKey = key(id)
        enqueue(id, state: .uploading)
        XCTAssertTrue(store.recordUploadEvidence(sourceKey, revision: revision, at: date))
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: sourceKey, presentation: nil, remote: nil)], at: date))
        XCTAssertTrue(store.deferEffects(for: sourceKey, at: date))
        let backingQueue = try XCTUnwrap(queue)
        let futureID = id + "-future"
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: key(futureID), presentation: nil, remote: nil)], at: date))
        XCTAssertTrue(
            Self.setColumns("next_attempt_at=\(date.timeIntervalSince1970 + 61)", of: futureID, at: storeURL))
        effects.onRemove = {
            _ = backingQueue.removeSources(kind: .photoLibraryAsset, identifiers: [id])
        }
        await coordinator.start()
        try await pollWhileFalse { clock.waits.contains(.seconds(60)) }
        XCTAssertTrue(effects.removed.isEmpty)
        let connection = try fault.install(on: store, key: sourceKey)
        defer { PendingStoreTransactionFault.remove(from: connection) }

        clock.advance(by: .seconds(60))
        try await pollWhileFalse { clock.waits.filter { $0 >= .seconds(60) }.count >= 2 }

        XCTAssertTrue(effects.removed.isEmpty, "an unavailable decision must not remove a photo from backup")
        XCTAssertNotNil(
            try queue.entry(for: source(id), revision: revision), "the real queue row must survive the refused pass")
        XCTAssertTrue(effects.trashed.isEmpty)
        XCTAssertGreaterThanOrEqual(clock.waits.filter { $0 >= .seconds(60) }.count, 2, "refusal must arm a retry")
        try await settle()
        XCTAssertEqual(clock.waits, [.seconds(60), .seconds(60)], "one existing backoff, without a short retry loop")
        if fault == .openTransaction {
            PendingStoreTransactionFault.remove(from: connection)
            XCTAssertTrue(store.isOperational())
            clock.advance(by: .seconds(60))
            try await pollWhileFalse {
                queueEntryForTesting(in: backingQueue, source: self.source(id), revision: self.revision) == nil
            }
            XCTAssertEqual(
                effects.removed, [[id, futureID].sorted()], "the next check settles committed deletes after recovery")
            XCTAssertNil(try queue.entry(for: source(id), revision: revision))
        }
        await coordinator.close()
    }

    func testPendingReconcileRefusalInvalidatesEarlierActionEligibility() async throws {
        await coordinator.close()
        let clock = ResultWriteClock(date)
        defer { clock.releaseAll() }
        coordinator = makeCoordinator(clock: clock, sleep: clock.sleep)
        let id = "unavailable-delete"
        let sourceKey = key(id)
        enqueue(id, state: .uploading)
        XCTAssertTrue(store.recordUploadEvidence(sourceKey, revision: revision, at: date))
        XCTAssertNotNil(
            store.exclude([PendingExclusionRequest(key: sourceKey, presentation: nil, remote: nil)], at: date))
        XCTAssertTrue(store.deferEffects(for: sourceKey, at: date))
        let favoriteKey = key("earlier-eligibility")
        let remote = PhotoUID(volumeID: "vol", nodeID: "favorite-photo")
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(key: favoriteKey, revision: revision, remote: remote, kind: .uploaded, createdAt: date)),
            .recorded)
        XCTAssertTrue(store.setFavoriteIntent(favoriteKey, favorite: true, at: date.addingTimeInterval(120)))
        await coordinator.start()
        try await pollWhileFalse { clock.waits.contains(.seconds(60)) }
        let connection = try PendingStoreTransactionFault.openTransaction.install(on: store, key: sourceKey)
        defer { PendingStoreTransactionFault.remove(from: connection) }

        clock.advance(by: .seconds(60))
        func refusalWaitCount() -> Int {
            clock.waits.filter { $0 == .seconds(60) || $0 == .seconds(1) }.count
        }
        try await pollWhileFalse { refusalWaitCount() >= 2 }
        XCTAssertGreaterThanOrEqual(refusalWaitCount(), 2, "the refused reconcile must finish before the event")
        // The foreground event runs before the already scheduled action timer, so this await observes the whole
        // dispatch. Waking both at once can return here while another runDueActions call still awaits its effect.
        clock.advance(by: .seconds(60), wakingTimers: false)
        await coordinator.noteRemotePresence([favoriteKey])

        XCTAssertTrue(effects.favorites.isEmpty, "an earlier complete read grants no action while the store is unknown")
        XCTAssertEqual(store.actions().count, 1, "the favorite stays owed until the decision is readable")
        await coordinator.close()
    }
}

extension PendingBackupCoordinatorTests {
    // MARK: - Degraded retry after a failed keyed reload (#913)

    private static let trashTilePresentation = PendingPresentationMetadata(
        captureTime: Date(timeIntervalSince1970: 1_750_000_000),
        mediaType: "photo",
        displayName: "Deleted photo"
    )

    /// Reads the first column of the first row as text, on its own read-only connection.
    private func sqlScalar(_ sql: String) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle
        else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }

    /// An excluded source whose remote trash is complete. `newerHandoff` inserts a handoff with a newer
    /// remote node ID than the state, so startup recovery reschedules the remote trash (`.scheduled`)
    /// and reconciles; a matching handoff keeps recovery at `.unchanged`. `tile` also lists the source
    /// in "Zuletzt gelöscht" and provides its presentation metadata, so it appears as a trash tile.
    private func excludedAndRemoteTracked(_ id: String, tile: Bool = false, newerHandoff: Bool = true) throws {
        let stateRemote = PhotoUID(volumeID: "vol", nodeID: "old-\(id)")
        XCTAssertNotNil(
            store.exclude(
                [
                    PendingExclusionRequest(
                        key: key(id), presentation: tile ? Self.trashTilePresentation : nil, remote: stateRemote)
                ],
                at: date))
        XCTAssertTrue(store.completeEffect(.queueSync, for: key(id), generation: 1, at: date))
        // The commit of a newer revision arrived before the process ended, after the old photo was
        // chosen for the trash: `recordHandoff` registers the durable duty, and the acknowledged row
        // leaves no event for the new coordinator.
        let handoffRemote = PhotoUID(volumeID: "vol", nodeID: "\(newerHandoff ? "new" : "old")-\(id)")
        let revision = UploadBackupRevision(rawValue: 9)
        XCTAssertEqual(
            store.recordHandoff(
                PendingHandoff(
                    key: key(id), revision: revision, remote: handoffRemote, kind: .uploaded, createdAt: date)),
            .excludedRemoteNeedsTrash)
        XCTAssertTrue(store.acknowledgeHandoffs([(key(id), revision)]))
        if newerHandoff {
            // The newer handoff stays unreadable while the old photo's trash completes, so the
            // completion's move-on cannot reschedule the newer duty at seed time: startup recovery
            // resumes it instead, as after a crash between the completion and the reschedule.
            XCTAssertTrue(change("UPDATE handoff SET kind='invalid' WHERE source_id='\(id)';"))
            XCTAssertTrue(store.completeEffect(.remoteTrash, for: key(id), generation: 1, at: date))
            XCTAssertTrue(change("UPDATE handoff SET kind='uploaded' WHERE source_id='\(id)';"))
        } else {
            // The record repeats the trashed photo, so it is a receipt replay that must not re-arm a duty.
            XCTAssertTrue(store.completeEffect(.remoteTrash, for: key(id), generation: 1, at: date))
        }
        if tile {
            XCTAssertTrue(Self.setColumns("listed_in_trash=1", of: id, at: storeURL))
            metadata.set(key(id), Self.trashTilePresentation)
        }
    }

    /// Startup recovery rescheduled the remote trash of a newer handoff (`.scheduled`), then the keyed
    /// reload of that source failed. The safe baseline for issue #913: the degraded regime schedules the
    /// 60 s backoff, and firing that timer retries the interrupted keyed read. While the read stays
    /// unreadable no remote trash dispatch runs, and the readable wait of the control source is also
    /// scheduled; the single reconcile timer alternates between that long wait and the backoff.
    func testStartupRecoveryInterruptedReloadSchedulesDegradedRetry() async throws {
        try excludedAndRemoteTracked("k")
        includedLater("ctrl")

        // Arms after the reschedule UPDATE of `resumeLaterTrash`, so that read itself stays readable and
        // only the recovery reload afterwards is interrupted.
        let failure = KeyedReadFailure(limit: 5, armAfter: "needs_remote_trash=1")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        try await pollWhileFalse { failure.count >= 1 }
        XCTAssertGreaterThanOrEqual(failure.count, 1, "the reload keyed read must be genuinely interrupted")

        // The safe baseline: the degraded 60 s backoff is scheduled, no action runs while the read fails,
        // and the control source keeps its readable long wait in the schedule alongside the backoff.
        let backoffDelay = Duration.seconds(60)
        try await pollWhileFalse { clock.waits.contains(backoffDelay) }
        XCTAssertTrue(
            effects.trashed.isEmpty,
            "while the keyed read fails, no remote trash dispatch may run; the handoff stays unconsumed")
        XCTAssertTrue(
            clock.waits.contains(backoffDelay),
            "issue #913 safety baseline: after the failed keyed reload, startup recovery schedules the "
                + "degraded 60 s backoff")
        XCTAssertTrue(
            clock.waits.contains { $0 > Duration.seconds(4000) && $0 < Duration.seconds(5500) },
            "the readable ~5000 s wait of the control source is also recorded; the backoff does not erase it")

        // The retry is real: firing the fake clock by the backoff makes the coordinator re-attempt the
        // interrupted keyed read (a fresh interrupt beyond the settled startup count).
        let settledCount = failure.count
        clock.advance(by: .seconds(60))
        try await pollWhileFalse { failure.count > settledCount }
        XCTAssertGreaterThan(
            failure.count, settledCount,
            "the 60 s backoff timer must fire and retry the interrupted keyed read")

        // The interrupts never corrupted the durable decision: the handoff row stays as written.
        XCTAssertEqual(
            sqlScalar("SELECT remote_link_id FROM handoff WHERE source_id='k' AND revision_us=9;"),
            "new-k",
            "the interrupted reads must not change the handoff row")

        failure.remove(from: store)
        await coordinator.close()
        clock.releaseAll()
    }

    /// The same recovery scenario with healthy reads: the remote trash of the newer handoff is dispatched,
    /// the readable schedule (~5000 s) carries the timer, and no degraded backoff is ever scheduled.
    func testStartupRecoveryHealthyReadControlSchedulesReadableWait() async throws {
        try excludedAndRemoteTracked("k")
        includedLater("ctrl")

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()

        let resumedRemote = PhotoUID(volumeID: "vol", nodeID: "new-k")
        try await pollWhileFalse { effects.trashed.count >= 1 }
        XCTAssertEqual(effects.trashed, [[resumedRemote]], "healthy reads must dispatch the rescheduled remote trash")

        try await pollWhileFalse {
            clock.waits.contains { $0 > Duration.seconds(4000) && $0 < Duration.seconds(5500) }
        }
        XCTAssertTrue(
            clock.waits.contains { $0 > Duration.seconds(4000) && $0 < Duration.seconds(5500) },
            "the healthy path must schedule the long readable wait of the included source")
        XCTAssertFalse(
            clock.waits.contains(Duration.seconds(60)),
            "the healthy path must not schedule the degraded backoff wait")
        XCTAssertEqual(
            clock.waits.filter { $0 < Duration.seconds(130) }, [],
            "the healthy path must not record any degraded backoff wait")

        await coordinator.close()
        clock.releaseAll()
    }

    /// The `removeFromTrashList` failure route for issue #913: the unlist commits, the keyed reload
    /// after it fails, and the last known state is stale, so the tile stays in the trash list. The
    /// degraded 60 s retry must be scheduled, as startup recovery does, and firing it must repair
    /// the stale tile once the read answers again.
    func testRemoveFromTrashListFailedReloadSchedulesDegradedRetry() async throws {
        try excludedAndRemoteTracked("t", tile: true, newerHandoff: false)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        let trashKey = self.key("t")
        _ = await waitForSnapshot("the fixture must first show the source in the trash list") {
            $0.trashTiles.contains { $0.key == trashKey }
        }

        // Arms after the unlist UPDATE, so the keyed read inside `unlistFromTrash` itself stays readable.
        // Without a limit, every later keyed read also fails until `recover()`: a pass that startup or
        // another route still has in flight cannot repair the stale tile before the retry fires.
        let failure = KeyedReadFailure(armAfter: "listed_in_trash=0")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let result = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t")
        ])
        XCTAssertTrue(
            result,
            "removeFromTrashList must return true when the unlist succeeds despite the reload failure")
        XCTAssertGreaterThanOrEqual(failure.count, 1, "the reload keyed read after the unlist must be interrupted")
        XCTAssertEqual(
            sqlScalar("SELECT listed_in_trash FROM source_state WHERE source_id='t';"), "0",
            "the unlist must be committed in the store")

        // The observable symptom: the last known state is stale, so the tile stays in the trash list.
        try await settle()
        let staleSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(
            staleSnapshot.trashTiles.contains { $0.key == key("t") },
            "the failed reload must leave the stale trash tile until a read succeeds")

        // The repair (#913): the degraded 60 s retry is scheduled, as startup recovery does in the same
        // situation, so the stale tile repairs itself instead of staying until another trigger.
        let backoffDelay = Duration.seconds(60)
        await waitForLiveWait(backoffDelay, on: clock, "the degraded 60 s retry must register its wait")
        XCTAssertTrue(
            clock.liveWaits.contains(backoffDelay),
            "issue #913: removeFromTrashList must schedule the degraded 60 s retry after its reload failed, "
                + "as startup recovery does")

        // Firing the retry repairs the tile: the reads recover first, so the keyed read of the fired
        // pass answers, and the trash list drops the stale tile.
        failure.recover()

        // The membership interval is zero, so the publish after the fired timer needs no further
        // clock step; the wait ends on the published repair instead of a guessed delay.
        let repairedSnapshot = try await publishedSnapshot(
            "the fired 60 s retry must repair the stale trash tile",
            after: { clock.advance(by: backoffDelay) },
            where: { $0.trashTiles.allSatisfy { $0.key != trashKey } })
        XCTAssertTrue(
            repairedSnapshot.excludedTiles.contains { $0.key == key("t") },
            "the source stays excluded and keeps its settings tile after the repair")

        await coordinator.close()
        clock.releaseAll()
    }

    /// The healthy control of the same route: without the read failure, the tile leaves the trash list
    /// and stays in the excluded list, and no degraded backoff is ever scheduled.
    func testRemoveFromTrashListHealthyReadControlRemovesTile() async throws {
        try excludedAndRemoteTracked("t", tile: true, newerHandoff: false)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        let trashKey = self.key("t")
        _ = await waitForSnapshot("the fixture must first show the source in the trash list") {
            $0.trashTiles.contains { $0.key == trashKey }
        }

        let result = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t")
        ])
        XCTAssertTrue(result, "removeFromTrashList must succeed with healthy reads")
        XCTAssertEqual(
            sqlScalar("SELECT listed_in_trash FROM source_state WHERE source_id='t';"), "0",
            "the unlist must be committed in the store")

        let removedSnapshot = await waitForSnapshot("the tile must leave the trash list") {
            $0.trashTiles.allSatisfy { $0.key != trashKey }
        }
        XCTAssertTrue(
            removedSnapshot.excludedTiles.contains { $0.key == key("t") },
            "the source stays excluded and keeps its settings tile")
        XCTAssertFalse(
            clock.waits.contains(Duration.seconds(60)),
            "the healthy route must not schedule the degraded backoff wait")
        XCTAssertEqual(
            clock.waits.filter { $0 < Duration.seconds(130) }, [],
            "the healthy route must not record any degraded backoff wait")

        await coordinator.close()
        clock.releaseAll()
    }

    /// A recovery-path heal must publish the shown lists: the source stayed unreadable in the
    /// later-trash set, so its duty is retried by `resumeLaterTrash`, whose keyed reload then
    /// succeeds while the generic heal block's read stays interrupted. Without the publish of
    /// that heal the stale trash tile survives the fired retry that read the source.
    func testRecoveryHealOfUnreadableLaterTrashPublishesMembership() async throws {
        try excludedAndRemoteTracked("k", tile: true, newerHandoff: false)

        // Startup recovery's handoff read fails, so the source enters the unreadable later-trash
        // set while its keyed state reads stay readable. The read can also be retried by the
        // startup reconcile, so the fault budget covers both passes.
        let handoffFailure = KeyedReadFailure(matching: Self.latestHandoffRead, limit: 2)
        try handoffFailure.install(on: store)
        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        let trashKey = self.key("k")
        _ = await waitForSnapshot("the fixture must first show the source in the trash list") {
            $0.trashTiles.contains { $0.key == trashKey }
        }
        try await pollWhileFalse { handoffFailure.count >= 1 }
        XCTAssertGreaterThanOrEqual(
            handoffFailure.count, 1, "startup recovery must read the source's handoff")
        try await settle()
        handoffFailure.remove(from: store)

        // The unlist commits and its keyed reload fails, so the shown list keeps the stale tile
        // and the source state degrades, while the unreadable later-trash duty keeps its retry.
        let reloadFailure = KeyedReadFailure(limit: 2, armAfter: "listed_in_trash=0")
        try reloadFailure.install(on: store)
        defer { reloadFailure.remove(from: store) }

        let result = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "k")
        ])
        XCTAssertTrue(
            result, "removeFromTrashList must return true when the unlist succeeds despite the reload failure")
        XCTAssertEqual(
            sqlScalar("SELECT listed_in_trash FROM source_state WHERE source_id='k';"), "0",
            "the unlist must be committed in the store")

        try await settle()
        let staleSnapshot = await coordinator.currentSnapshot()
        XCTAssertTrue(
            staleSnapshot.trashTiles.contains { $0.key == trashKey },
            "the failed reload must keep the stale trash tile")

        // Fire the single live degraded retry timer. Its reconcile must heal the source in the
        // recovery reload, because the generic heal block's keyed read stays interrupted.
        let retryDelay = Duration.seconds(60)
        await waitForLiveWait(retryDelay, on: clock, "the degraded 60 s retry must register its wait")
        XCTAssertEqual(
            clock.liveWaits, [retryDelay], "the degraded regime must keep exactly one live timer: the 60 s retry")

        let repairedSnapshot = try await publishedSnapshot(
            "the recovery-path heal must publish the membership and drop the stale trash tile",
            after: { clock.advance(by: retryDelay) },
            where: { $0.trashTiles.allSatisfy { $0.key != trashKey } })
        XCTAssertTrue(
            repairedSnapshot.excludedTiles.contains { $0.key == trashKey },
            "the source stays excluded and keeps its settings tile after the recovery heal")
        XCTAssertEqual(
            reloadFailure.count, 2,
            "the generic heal block's keyed read must stay interrupted, so only the recovery reload can heal")

        await coordinator.close()
        clock.releaseAll()
    }

    /// The second failed unlist of the same degraded episode must keep the first countdown (#913, review
    /// round 1): `scheduleReconcileTimer` restarts its timer, so re-arming after a later failed reload
    /// would delay the pending retry by another full wait. A second 60 s wait must never be recorded.
    func testRemoveFromTrashListKeepsAnExistingDegradedCountdown() async throws {
        try excludedAndRemoteTracked("t1", tile: true, newerHandoff: false)
        try excludedAndRemoteTracked("t2", tile: true, newerHandoff: false)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        await coordinator.start()
        let firstKey = self.key("t1")
        let secondKey = self.key("t2")
        _ = await waitForSnapshot("both sources must first appear in the trash list") {
            $0.trashTiles.contains { $0.key == firstKey }
                && $0.trashTiles.contains { $0.key == secondKey }
        }

        // Two separate fault episodes: the first failure interrupts the reload after the first unlist.
        // The second failure stays unarmed until the second unlist UPDATE commits, so the read before
        // that write passes (#982) and only the reload after it fails.
        let firstFailure = KeyedReadFailure(limit: 1, armAfter: "listed_in_trash=0")
        try firstFailure.install(on: store)

        let first = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t1")
        ])
        XCTAssertTrue(first, "the first unlist must commit and arm the degraded countdown")
        try await pollWhileFalse { clock.waits.contains(Duration.seconds(60)) }
        XCTAssertEqual(firstFailure.count, 1, "the first failed reload must be interrupted")
        firstFailure.remove(from: store)

        let secondFailure = KeyedReadFailure(limit: 1, armAfter: "listed_in_trash=0")
        try secondFailure.install(on: store)
        defer { secondFailure.remove(from: store) }

        let second = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t2")
        ])
        XCTAssertTrue(second, "the second unlist must commit too")
        try await pollWhileFalse { secondFailure.count == 1 }
        XCTAssertEqual(
            secondFailure.count, 1,
            "the second reload must fail as well, entering the same degraded episode")

        try await settle()
        XCTAssertEqual(
            clock.waits.filter { $0 == Duration.seconds(60) }.count, 1,
            "a later failed unlist must not restart the already pending degraded countdown")

        await coordinator.close()
        clock.releaseAll()
    }

    /// Review round 2 of #913: the `!reconcileRunning` leg of the degraded-retry guard. While a
    /// reconcile pass awaits the remote trash dispatch of another source, a `removeFromTrashList`
    /// whose keyed reload fails must not arm the degraded countdown itself; the pass-end
    /// `scheduleReconcileTimer` arms it once. Arming mid-pass would restart that countdown when the
    /// pass ends and so double the wait.
    func testRemoveFromTrashListDuringReconcilePassDoesNotDoubleDegradedWait() async throws {
        // "d" owes the remote trash of a newer handoff, so the recovery pass awaits its dispatch.
        try excludedAndRemoteTracked("d")
        // "t" is only shown in the trash list; the keyed reload after its unlist is the one that fails.
        try excludedAndRemoteTracked("t", tile: true, newerHandoff: false)

        let clock = ResultWriteClock(date)
        coordinator = makeCoordinator(clock: clock, sleep: { try await clock.sleep($0) })

        // Holds the remote trash of "d", so the reconcile pass stays suspended mid-flight and
        // `reconcileRunning` stays true for the whole unlist below.
        let trashGate = LookupGate()
        effects.trashGate = trashGate
        defer { trashGate.open() }

        await coordinator.start()
        let reached = await trashGate.entered(within: .seconds(5))
        XCTAssertTrue(
            reached,
            "the reconcile pass must reach and hold the remote trash dispatch of \"d\"")

        // Arms after the unlist UPDATE, so the keyed read before that write stays readable (#982).
        let failure = KeyedReadFailure(limit: 1, armAfter: "listed_in_trash=0")
        try failure.install(on: store)
        defer { failure.remove(from: store) }

        let result = await coordinator.removeFromTrashList([
            PhotoUID(localPending: .photoLibrary, identifier: "t")
        ])
        XCTAssertTrue(
            result,
            "removeFromTrashList must return true when the unlist succeeds despite the reload failure")
        XCTAssertEqual(failure.count, 1, "the reload keyed read after the unlist must be interrupted")

        // Mid-pass, no countdown may be armed: the running pass owns the end-of-pass scheduling.
        try await settle()
        XCTAssertFalse(
            clock.waits.contains { $0 >= .seconds(30) && $0 <= .seconds(130) },
            "while the pass runs, the failed unlist must not arm the degraded countdown itself")

        // Releasing the trash ends the pass; its end-of-pass scheduling arms the countdown once.
        trashGate.open()
        try await pollWhileFalse { !effects.trashed.isEmpty }
        XCTAssertEqual(
            effects.trashed, [[PhotoUID(volumeID: "vol", nodeID: "new-d")]],
            "the held pass must finish its remote trash dispatch")
        try await pollWhileFalse { clock.waits.contains(Duration.seconds(60)) }
        XCTAssertEqual(
            clock.waits.filter { $0 == Duration.seconds(60) }.count, 1,
            "the pass-end scheduling must arm exactly one degraded 60 s countdown")
        XCTAssertFalse(
            clock.waits.contains { $0 > Duration.seconds(60) && $0 <= .seconds(130) },
            "no doubled degraded wait may follow the pass-end countdown")

        await coordinator.close()
        clock.releaseAll()
    }
}
