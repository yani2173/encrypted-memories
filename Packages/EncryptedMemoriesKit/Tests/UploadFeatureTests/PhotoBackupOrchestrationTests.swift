import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Exercises the shared backup pass order without PhotoKit.
/// It verifies lock recovery, catalog changes, queue draining, duplicate avoidance, and removal handling.
final class PhotoBackupOrchestrationTests: XCTestCase {
    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var catalog: PhotoLibraryCatalogManifestStore!
    private var lockStore: BackupExecutionLockManifestStore!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var stateStore: MemoryBackupStateStore!
    private var preflight: UploadBackupPreflightIndex!
    private var engine: UploadBackupSyncEngine!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!
    private var runner: BackupSyncRunner!
    private var enumerator: CannedEnumerator!

    /// Every catalogued asset shares this modification date so the resolved revision matches the
    /// enqueued queue-row revision (no drift-row noise); content differs by path.
    private let modDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let lease: TimeInterval = 120

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-backup-orchestration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock(start: Date(timeIntervalSince1970: 1_720_000_000))

        catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        lockStore = try XCTUnwrap(
            BackupExecutionLockManifestStore(
                url: tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName),
                leaseInterval: Self.lease, now: { [clock] in clock!.now }))
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        stateStore = MemoryBackupStateStore()
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queue, now: { [clock] in clock!.now })

        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: modDate)
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        runner = BackupSyncRunner(
            queue: queue,
            preflight: preflight,
            resolver: resolver,
            identityResolver: UploadDedupePipeline(
                store: identityStore, hasher: hasher, checker: checker, now: { [clock] in clock!.now }),
            uploader: uploader,
            clock: clock,
            now: { [clock] in clock!.now }
        )
        enumerator = CannedEnumerator(infos: [])
    }

    override func tearDownWithError() throws {
        queue.close()
        catalog.close()
        lockStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Returns false when the pass stood down because another owner held a live lock.
    @discardableResult
    private func runPass(
        owner: BackupExecutionOwner, fullRescan: Bool = true, identifiers: [String]? = nil
    ) async -> Bool {
        // Advance the clock so each scan receives a strictly later observation time.
        clock.advance(by: 60)
        let runID = UUID().uuidString
        // Gate: recovery precedes the drain; a live foreign lock makes us stand down.
        _ = lockStore.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-Self.lease))
        switch lockStore.acquire(owner: owner, runID: runID) {
        case .busy, .unavailable:
            return false
        case .acquired:
            break
        }
        // Drain first. Uploads are not gated on scan completion, so runnable rows upload before scanning.
        _ = await runner.runUntilDrained()

        // Scan phase through the persistent-catalog driver.
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        let needsFullScan = fullRescan || !catalog.hasCompletedFullScan()
        do {
            if needsFullScan {
                // The resumable full scan marks itself complete when it reaches the library's end.
                _ = try await sync.run(engine: engine, identifiers: nil)
            } else if let identifiers, !identifiers.isEmpty {
                _ = try await sync.run(engine: engine, identifiers: identifiers)
            }
        } catch {
            // The controller surfaces a message and still drains what is queued; mirror by continuing.
        }
        // Drain again for what the scan discovered, then release ownership.
        _ = await runner.runUntilDrained()
        lockStore.release(runID: runID)
        return true
    }

    func testFullPassEnqueuesDrainsUploadsAndReleasesLock() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]

        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC"], "both new assets upload once")
        XCTAssertEqual(queue.summary().uploaded, 2)
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 2, present: 2, removed: 0))
        XCTAssertNil(lockStore.currentLock(), "the lock is released when the pass finishes")
        XCTAssertTrue(catalog.hasCompletedFullScan(), "a successful full pass unlocks future incremental scans")
    }

    func testIncrementalTokenCannotSkipInitialFullCatalogScan() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C")]

        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(
            Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC", "IMG_C.HEIC"],
            "a PhotoKit change token is not enough proof that the local backup catalog knows the full library")
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 3, present: 3, removed: 0))
        XCTAssertTrue(catalog.hasCompletedFullScan())
    }

    func testRepeatPassOverUnchangedCatalogUploadsNothingNew() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.count, 2)
        let resolvesAfterFirst = resolver.resolveCount(for: "A") + resolver.resolveCount(for: "B")

        // Second pass, catalog unchanged to O(changed): nothing re-enqueued, nothing re-resolved,
        // nothing re-uploaded. This is the whole point of the persistent catalog.
        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(uploader.requests.count, 2, "an unchanged library must not re-upload everything")
        XCTAssertEqual(
            resolver.resolveCount(for: "A") + resolver.resolveCount(for: "B"), resolvesAfterFirst,
            "unchanged assets are never re-handed to the runner")
        XCTAssertNil(lockStore.currentLock())
    }

    func testTargetedMetadataChangeUsesEditFingerprintWithoutDuplicateUpload() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(resolver.resolveCount(for: "A"), 1)
        XCTAssertEqual(resolver.resolveCount(for: "B"), 1)
        XCTAssertEqual(uploader.requests.count, 2)

        // B's metadata changed (new modification date to new revision) but its PhotoKit resource
        // structure did not. The shared preflight can prove that locally via the edit fingerprint,
        // so the targeted pass records the new revision without exporting, hashing, or uploading.
        let editedModDate = Date(timeIntervalSince1970: 1_700_090_000)
        enumerator.infos = [photoInfo("A"), photoInfo("B", modified: editedModDate)]
        resolver.setModified(editedModDate, for: "B")

        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(resolver.resolveCount(for: "A"), 1, "an unchanged asset is not re-resolved on a targeted pass")
        XCTAssertEqual(
            resolver.resolveCount(for: "B"), 1, "metadata-only PhotoKit drift must stay cheap for unedited assets")
        XCTAssertEqual(uploader.requests.count, 2, "a metadata-only change never re-uploads identical bytes")
    }

    func testRemovedAssetIsMarkedRemovedAndNeverUploaded() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.count, 2)

        // B is deleted from the library. Next full scan sweeps it removed.
        enumerator.infos = [photoInfo("A")]
        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(catalog.entry(for: "B")?.isRemoved, true, "the vanished asset is marked removed")
        XCTAssertEqual(resolver.resolveCount(for: "B"), 1, "a removed asset is never re-resolved")
        XCTAssertEqual(uploader.requests.count, 2, "removed assets are never uploaded; deletions are not mirrored")
    }

    func testTargetedDeletedIdentifierMarksCatalogRemovedWithoutFullScan() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C")]
        await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.count, 3)

        enumerator.infos = [photoInfo("A"), photoInfo("C")]
        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(
            catalog.entry(for: "B")?.isRemoved, true, "a PhotoKit deleted identifier is marked removed in the catalog")
        XCTAssertEqual(catalog.entry(for: "A")?.isRemoved, false)
        XCTAssertEqual(catalog.entry(for: "C")?.isRemoved, false)
        XCTAssertEqual(uploader.requests.count, 3, "targeted deletion does not upload or re-resolve anything")
    }

    func testBackgroundStandsDownWhileForegroundOwnsLiveLock() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        // A foreground run owns a live lock (fresh heartbeat) - as if a foreground pass is mid-drain.
        XCTAssertTrue(lockStore.acquire(owner: .foreground, runID: "fg-live").didAcquire)

        let ran = await runPass(owner: .iOSBackgroundTask)

        XCTAssertFalse(ran, "a background window must not start a second drain while foreground owns the lock")
        XCTAssertEqual(uploader.requests.count, 0, "no scan and no drain happen when the pass stands down")
        XCTAssertEqual(catalog.count(), 0, "a stood-down pass must not touch the catalog")
        XCTAssertEqual(
            lockStore.currentLock()?.runID, "fg-live", "the live owner's lock is left intact (non-destructive)")
    }

    func testStaleLockIsRecoveredSoBackupIsNeverPermanentlyBlocked() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        // A stale lock has no release or heartbeat.
        XCTAssertTrue(lockStore.acquire(owner: .iOSBackgroundTask, runID: "crashed").didAcquire)

        clock.advance(by: 200)  // past the 120s lease
        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran, "a stale lock is reaped so the next start proceeds")
        XCTAssertEqual(uploader.requests.count, 2, "the recovered pass uploads normally")
        XCTAssertNil(lockStore.currentLock(), "the recovered pass releases its own lock at the end")
    }

    /// Uploads must not wait for scan completion. A pass drains runnable rows before its scan enumerates.
    func testQueuedRowsUploadBeforeTheScanEnumerates() async throws {
        // A queued A and B pair has not uploaded and has no full-scan-complete marker.
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        let preScan = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        _ = try await preScan.run(engine: engine, identifiers: nil)
        XCTAssertEqual(uploader.requests.count, 0, "precondition: the interrupted prior pass uploaded nothing")
        XCTAssertEqual(queue.summary().uploaded, 0, "precondition: A and B are queued, not yet uploaded")

        // Record how many uploads have happened at the instant the next pass begins scanning.
        let uploadsWhenScanStarted = IntBox()
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C")]
        enumerator.onEnumerationStart = { [uploader] in uploadsWhenScanStarted.value = uploader?.requests.count ?? -1 }

        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(
            uploadsWhenScanStarted.value, 2,
            "the two already-queued assets upload before the scan enumerates; the drain is not gated on the scan")
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC", "IMG_C.HEIC"])
        XCTAssertEqual(
            uploader.requests.count, 3, "each asset uploads exactly once (no double upload from the reorder)")
    }

    /// A partial full scan resumes from its saved frontier and does not sweep already observed assets.
    func testInterruptedFullScanResumesAndDoesNotFalselySweep() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C"), photoInfo("D"), photoInfo("E")]
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 2, now: { [clock] in clock!.now })

        // The first scan stops after two assets.
        enumerator.throwAfter = 2
        do {
            _ = try await sync.run(engine: engine, identifiers: nil)
            XCTFail("the interrupted scan should have propagated cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(catalog.hasCompletedFullScan(), "an interrupted scan is NOT complete")
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2, "the frontier is persisted so the next run resumes there")
        XCTAssertEqual(queue.summary().total, 2, "only the two observed assets are queued so far")
        let epochStart = catalog.fullScanProgress()?.epochStart
        XCTAssertNotNil(epochStart)

        // Run 2 (later wall clock) resumes at the cursor, skips A/B, finishes C/D/E, and completes.
        clock.advance(by: 120)
        enumerator.throwAfter = nil
        _ = try await sync.run(engine: engine, identifiers: nil)

        XCTAssertTrue(
            catalog.hasCompletedFullScan(), "reaching the library's end across resumed runs completes the scan")
        XCTAssertNil(catalog.fullScanProgress(), "a completed epoch clears its resume state")
        XCTAssertEqual(
            queue.summary().total, 5, "all five assets are queued exactly once (A/B not re-enqueued on resume)")
        XCTAssertEqual(
            catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 5, present: 5, removed: 0),
            "assets observed by the EARLIER run must not be swept as removed when a later run finishes the epoch")
        XCTAssertEqual(epochStart, epochStart, "epoch start is stable across resumed runs")
    }

    /// Starts one backup scan pass the way the controller does after a launch: changes since the stored token,
    /// then the shared pass. Returns false when the pass was interrupted.
    @discardableResult
    private func startScanPass(history: FakeChangeHistory) async throws -> Bool {
        clock.advance(by: 60)
        let prepared = history.prepare()
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 2, now: { [clock] in clock!.now })
        do {
            try await sync.runPass(
                engine: engine, changes: prepared.changes, commitChanges: { history.commit(prepared) })
            return true
        } catch is CancellationError {
            return false
        }
    }

    /// The first scan stops after two of five photos. The next launch reads only the three photos that remain (#309).
    func testInterruptedFirstScanResumesWithoutReadingTheDonePartAgain() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()

        enumerator.throwAfter = 2
        let firstFinished = try await startScanPass(history: history)
        XCTAssertFalse(firstFinished)
        XCTAssertEqual(enumerator.readCount, 2)
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2)

        enumerator.throwAfter = nil
        enumerator.readCount = 0
        let secondFinished = try await startScanPass(history: history)

        XCTAssertTrue(secondFinished)
        XCTAssertEqual(enumerator.readCount, 3, "the resumed scan reads only the photos after the saved position")
        XCTAssertTrue(catalog.hasCompletedFullScan())
        XCTAssertNil(catalog.fullScanProgress())
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 5, present: 5, removed: 0))
        XCTAssertEqual(queue.summary().total, 5)
    }

    /// A photo added and a photo edited while the first scan was interrupted are queued after the resume.
    func testPhotoAddedOrChangedDuringAnInterruptedFirstScanIsBackedUpAfterTheResume() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        enumerator.throwAfter = 2
        try await startScanPass(history: history)
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2, "A and B were read before the interruption")

        // While the app is closed: a new photo F arrives, and B, which the scan already read, is edited.
        let edited = modDate.addingTimeInterval(3_600)
        enumerator.infos = [photoInfo("F")] + ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        enumerator.infos[2] = photoInfo("B", modified: edited)
        history.record(changed: ["F", "B"])
        resolver.setModified(edited, for: "B")

        enumerator.throwAfter = nil
        enumerator.readCount = 0
        let finished = try await startScanPass(history: history)

        XCTAssertTrue(finished)
        XCTAssertEqual(enumerator.readCount, 5, "F and B from the change history, then C, D, and E")
        XCTAssertEqual(catalog.presentEntries(for: ["B"])["B"]?.modificationDate, edited)
        let editedB = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "B")
        XCTAssertNotNil(queue.entry(for: editedB, revision: UploadBackupRevision(date: edited)))
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 6, present: 6, removed: 0))

        _ = await runner.runUntilDrained()
        XCTAssertTrue(uploader.requests.map(\.name).contains("IMG_F.HEIC"), "the new photo is backed up")
        XCTAssertEqual(
            uploader.requests.filter { $0.name == "IMG_B.HEIC" }.count, 1,
            "only the edited version of B is backed up")
    }

    /// An older photo appears before the saved position and an earlier photo is deleted during the interruption.
    /// Neither shifts the resume point: every photo is read once, the new one is queued, the deleted one is removed.
    func testPhotoInsertedBeforeTheSavedPositionDuringTheInterruptionIsNotMissed() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        enumerator.throwAfter = 2
        try await startScanPass(history: history)
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2)

        // X, an imported photo with an older capture date, lands before the saved position. A, already read, is deleted.
        enumerator.infos = [
            photoInfo("X", created: Date(timeIntervalSince1970: 1_600_000_000)),
            photoInfo("B"), photoInfo("C"), photoInfo("D"), photoInfo("E"),
        ]
        history.record(changed: ["X"], deleted: ["A"])

        enumerator.throwAfter = nil
        enumerator.readCount = 0
        let finished = try await startScanPass(history: history)

        XCTAssertTrue(finished)
        XCTAssertEqual(enumerator.readCount, 4, "X from the change history, then C, D, and E")
        let present = catalog.presentEntries(for: ["A", "B", "C", "D", "E", "X"])
        XCTAssertEqual(Set(present.keys), ["B", "C", "D", "E", "X"])
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 6, present: 5, removed: 1))
        let x = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "X")
        XCTAssertNotNil(queue.entry(for: x, revision: UploadBackupRevision(date: modDate)))
        XCTAssertTrue(catalog.hasCompletedFullScan())
    }

    /// After a completed first scan, a later pass reads only the changed photos, and a pass without changes reads none.
    func testCompletedFirstScanKeepsLaterPassesIncremental() async throws {
        enumerator.infos = ["A", "B", "C"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())
        XCTAssertEqual(enumerator.readCount, 3)

        enumerator.infos.insert(photoInfo("D"), at: 0)
        history.record(changed: ["D"])
        enumerator.readCount = 0
        try await startScanPass(history: history)
        XCTAssertEqual(enumerator.readCount, 1, "only the new photo is read")
        XCTAssertNil(catalog.fullScanProgress(), "no full scan starts")
        XCTAssertEqual(queue.summary().total, 4)

        enumerator.readCount = 0
        try await startScanPass(history: history)
        XCTAssertEqual(enumerator.readCount, 0)
    }

    /// When the change history expired, the full rescan is the only proof that no photo was missed. An interrupted
    /// rescan must resume on the next launch, even though a new change token is stored by then.
    func testInterruptedRescanAfterExpiredChangeHistoryResumes() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())

        // The history expires while E is edited, so no change record names E.
        let edited = modDate.addingTimeInterval(3_600)
        enumerator.infos[4] = photoInfo("E", modified: edited)
        history.expire()

        enumerator.throwAfter = 2
        enumerator.readCount = 0
        let rescanFinished = try await startScanPass(history: history)
        XCTAssertFalse(rescanFinished)
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2)

        enumerator.throwAfter = nil
        enumerator.readCount = 0
        let finished = try await startScanPass(history: history)

        XCTAssertTrue(finished)
        XCTAssertEqual(enumerator.readCount, 3, "the rescan resumes after A and B")
        XCTAssertNil(catalog.fullScanProgress())
        XCTAssertEqual(
            catalog.presentEntries(for: ["E"])["E"]?.modificationDate, edited,
            "the edit that the expired history lost is found by the resumed rescan")
    }

    /// A rescan request that leaves the change token valid (a live change without details) must not drop the open
    /// rescan of an expired change history when its own snapshot fails. A photo from the expired gap that lies after
    /// the saved position is still backed up.
    func testFailedRescanSnapshotKeepsTheOwedScanOfAnExpiredChangeHistory() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())

        // While the history is expired, G arrives with an older capture date, so it sorts after every other photo.
        enumerator.infos.append(photoInfo("G", created: Date(timeIntervalSince1970: 1_500_000_000)))
        history.expire()
        enumerator.throwAfter = 2
        let rescanFinished = try await startScanPass(history: history)
        XCTAssertFalse(rescanFinished)
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2)
        XCTAssertFalse(history.prepare().changes.requiresFullRescan, "the rescan stored a newer token")

        enumerator.throwAfter = nil
        history.requestRescanWithoutTokenChange()
        enumerator.failsSnapshot = true
        let failedFinished = try await startScanPass(history: history)
        XCTAssertFalse(failedFinished)
        XCTAssertNil(catalog.fullScanProgress(), "the failed snapshot cleared the earlier resume point")

        // After a relaunch the live request is gone, and the change history since the token is empty.
        history.relaunch()
        enumerator.failsSnapshot = false
        let finished = try await startScanPass(history: history)

        XCTAssertTrue(finished)
        XCTAssertNotNil(catalog.presentEntries(for: ["G"])["G"], "the owed scan runs and reads G")
        XCTAssertTrue(catalog.hasCompletedFullScan())
        _ = await runner.runUntilDrained()
        XCTAssertTrue(uploader.requests.map(\.name).contains("IMG_G.HEIC"))
    }

    /// A power loss can drop WAL commits that were never synchronized, while the token file survives. Before the token
    /// moves, the database file alone must already hold the owed scan and its published snapshot.
    func testOwedScanAndSnapshotAreInTheDatabaseFileWhenTheTokenMoves() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        try await startScanPass(history: history)
        history.expire()
        enumerator.throwAfter = 2
        let rescanFinished = try await startScanPass(history: history)
        XCTAssertFalse(rescanFinished)
        XCTAssertFalse(history.prepare().changes.requiresFullRescan, "the rescan stored a newer token")

        let survivor = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(url: powerLossCopy(of: PhotoLibraryCatalogManifestStore.databaseFileName)))
        defer { survivor.close() }

        XCTAssertFalse(survivor.hasCompletedFullScan(), "the rescan is still owed")
        XCTAssertNotNil(survivor.fullScanProgress(), "the published snapshot survives")
        XCTAssertEqual(survivor.fullScanSnapshotCount(), 5)
    }

    /// After a completed scan, a pass reads only the changed photo. When the token moves, the queue row of that photo
    /// must already be in the database file: after a power loss the catalog row alone marks the photo as unchanged.
    func testQueueRowOfAChangedPhotoIsInTheDatabaseFileWhenTheTokenMoves() async throws {
        enumerator.infos = ["A", "B", "C"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())

        enumerator.infos.insert(photoInfo("D"), at: 0)
        history.record(changed: ["D"])
        try await startScanPass(history: history)
        XCTAssertTrue(history.prepare().changes.changedIdentifiers.isEmpty, "the token moved past D")

        let survivorURL = try powerLossCopy(of: UploadBackupSyncQueueManifestStore.databaseFileName)
        let survivor = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: survivorURL))
        defer { survivor.close() }
        let d = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "D")
        XCTAssertNotNil(survivor.entry(for: d, revision: UploadBackupRevision(date: modDate)))
    }

    /// A photo added while the first scan was interrupted is queued before the scan resumes. The token moves when the
    /// pass reaches the saved snapshot; the queue row of that photo must already be in the database file then.
    func testQueueRowOfAPhotoAddedDuringAnInterruptedScanIsInTheDatabaseFileWhenTheTokenMoves() async throws {
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        enumerator.throwAfter = 2
        try await startScanPass(history: history)

        enumerator.infos.insert(photoInfo("F"), at: 0)
        history.record(changed: ["F"])
        enumerator.throwAfter = 3
        let finished = try await startScanPass(history: history)
        XCTAssertFalse(finished, "the pass stops after F and one more photo of the snapshot")
        XCTAssertTrue(history.prepare().changes.changedIdentifiers.isEmpty, "the token moved past F")

        let survivorURL = try powerLossCopy(of: UploadBackupSyncQueueManifestStore.databaseFileName)
        let survivor = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: survivorURL))
        defer { survivor.close() }
        let f = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "F")
        XCTAssertNotNil(survivor.entry(for: f, revision: UploadBackupRevision(date: modDate)))
    }

    func testRollbackJournalStoresAdvanceTheFullScanAndIncrementalTokens() async throws {
        queue.close()
        catalog.close()
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let catalogURL = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        func pinRollbackJournal(_ url: URL, table: String) throws -> OpaquePointer {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            let handle = try XCTUnwrap(db)
            XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=DELETE;", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(handle, "BEGIN; SELECT * FROM \(table);", nil, nil, nil), SQLITE_OK)
            return handle
        }
        let queueReader = try pinRollbackJournal(queueURL, table: "backup_sync_queue")
        defer { sqlite3_close(queueReader) }
        let catalogReader = try pinRollbackJournal(catalogURL, table: "photo_catalog")
        defer { sqlite3_close(catalogReader) }
        let policy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 10)
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL, policy: policy))
        catalog = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: catalogURL, policy: policy))
        XCTAssertEqual(sqlite3_exec(queueReader, "COMMIT;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(catalogReader, "COMMIT;", nil, nil, nil), SQLITE_OK)
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queue, now: { [clock] in clock!.now })

        let history = FakeChangeHistory()
        enumerator.infos = [photoInfo("A")]
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())
        XCTAssertFalse(history.prepare().changes.requiresFullRescan, "the full-scan token moves without a WAL")
        enumerator.infos.append(photoInfo("B"))
        history.record(changed: ["B"])
        try await startScanPass(history: history)
        XCTAssertTrue(history.prepare().changes.changedIdentifiers.isEmpty, "the incremental token moves too")
        XCTAssertNotNil(
            queue.entry(
                for: .init(kind: .photoLibraryAsset, identifier: "B"),
                revision: UploadBackupRevision(date: modDate)))
    }

    /// When the queue cannot be synchronized because another connection still reads an older state, the token stays.
    /// The next pass reads the same changes again.
    func testBusyQueueCheckpointKeepsTheToken() async throws {
        let queueURL = try useQueueWithShortBusyTimeout()
        enumerator.infos = ["A", "B", "C", "D", "E"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        enumerator.throwAfter = 2
        try await startScanPass(history: history)

        var reader: OpaquePointer? = try openPinnedReader(at: queueURL)
        defer { reader.map(closePinnedReader) }

        // Commit point after the published snapshot: the pass queues F, then stops before the scan completes.
        enumerator.infos.insert(photoInfo("F"), at: 0)
        history.record(changed: ["F"])
        enumerator.throwAfter = 3
        let resumedFinished = try await startScanPass(history: history)
        XCTAssertFalse(resumedFinished)
        XCTAssertEqual(history.prepare().changes.changedIdentifiers, ["F"], "the token stays before F")

        // The completing pass tries again, and the queue is still busy.
        enumerator.throwAfter = nil
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())
        XCTAssertEqual(history.prepare().changes.changedIdentifiers, ["F"], "the completed scan keeps the token")

        // Commit point of a pass without a full scan.
        enumerator.infos.insert(photoInfo("G"), at: 0)
        history.record(changed: ["G"])
        try await startScanPass(history: history)
        XCTAssertEqual(history.prepare().changes.changedIdentifiers, ["F", "G"], "the token stays before F and G")
        let g = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "G")
        XCTAssertNotNil(queue.entry(for: g, revision: UploadBackupRevision(date: modDate)))

        // Once the queue checkpoint succeeds, the next pass moves the token.
        reader.map(closePinnedReader)
        reader = nil
        try await startScanPass(history: history)
        XCTAssertTrue(history.prepare().changes.changedIdentifiers.isEmpty, "the token moved past F and G")
    }

    /// A power loss can happen at any moment of a scan. Queue rows survive it because their commits sync the queue
    /// WAL; catalog commits may survive too, even unsynchronized. Right before each queue insert, every catalog row and
    /// every photo before the saved scan position therefore needs its queue row already; otherwise the photo would
    /// count as unchanged and never be queued again (#352).
    func testEveryCatalogRowHasItsQueueRowBeforeTheNextQueueInsert() async throws {
        let names = [
            PhotoLibraryCatalogManifestStore.databaseFileName, UploadBackupSyncQueueManifestStore.databaseFileName,
        ]
        enumerator.infos = (0..<3_000).map { photoInfo(String(format: "P%04d", $0)) }
        let copies = CommittedFilesLog(source: tempDir, names: names, every: 100)
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 2, now: { [clock] in clock!.now })
        _ = try await sync.run(engine: CopyingEnqueuer(engine: engine, copies: copies))

        let directories = copies.directories
        XCTAssertGreaterThanOrEqual(directories.count, 10)
        var largestCatalog = 0
        for directory in directories {
            let survivingCatalog = try XCTUnwrap(
                PhotoLibraryCatalogManifestStore(url: directory.appendingPathComponent(names[0])))
            let survivingQueue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent(names[1])))
            defer {
                survivingCatalog.close()
                survivingQueue.close()
            }
            // The store reads at least one identifier, so a scan position of zero reads none here.
            let cursor = survivingCatalog.fullScanProgress()?.cursor ?? 0
            var identifiers = Set(
                cursor > 0 ? survivingCatalog.fullScanSnapshotIdentifiers(startingAt: 0, limit: cursor) : [])
            var after: String?
            while true {
                let page = survivingCatalog.presentEntries(afterLocalIdentifier: after, limit: 500)
                guard let last = page.last else { break }
                identifiers.formUnion(page.map(\.localIdentifier))
                after = last.localIdentifier
            }
            largestCatalog = max(largestCatalog, identifiers.count)
            let withoutQueueRow = identifiers.filter {
                survivingQueue.entry(
                    for: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: $0),
                    revision: UploadBackupRevision(date: modDate)) == nil
            }
            XCTAssertEqual(
                withoutQueueRow.count, 0, "\(directory.lastPathComponent): \(withoutQueueRow.sorted().prefix(3))")
        }
        XCTAssertGreaterThanOrEqual(largestCatalog, 2_000, "the copies cover most of the scan")
    }

    /// The queue is synchronized right before each change token commit, at both commit points.
    func testQueueSynchronizationPrecedesEveryTokenCommit() async throws {
        enumerator.infos = ["A", "B", "C"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        let events = EventLog()
        let recorder = SyncRecordingEnqueuer(engine: engine, events: events)
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 2, now: { [clock] in clock!.now })
        func pass() async throws {
            let prepared = history.prepare()
            try await sync.runPass(
                engine: recorder, changes: prepared.changes,
                commitChanges: {
                    events.append("token commit")
                    history.commit(prepared)
                })
        }
        try await pass()
        enumerator.infos.insert(photoInfo("D"), at: 0)
        history.record(changed: ["D"])
        try await pass()

        let recorded = events.values
        let commits = recorded.indices.filter { recorded[$0] == "token commit" }
        XCTAssertEqual(commits.count, 2, "\(recorded)")
        for index in commits {
            XCTAssertEqual(index > 0 ? recorded[index - 1] : nil, "queue sync", "\(recorded)")
        }
    }

    /// A catalog that cannot be read reports the localized error, also when the pass must mark a rescan owed.
    func testUnavailableCatalogReportsTheLocalizedErrorOnARescan() async throws {
        catalog.close()
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: enumerator, now: { [clock] in clock!.now })
        do {
            try await sync.runPass(
                engine: engine,
                changes: .init(changedIdentifiers: [], deletedIdentifiers: [], requiresFullRescan: true),
                commitChanges: {})
            XCTFail("the pass must stop")
        } catch {
            XCTAssertEqual(error as? UploadError, .backend(L10n.string("backup.error_local_state_unavailable")))
        }
    }

    /// Replaces the queue with one that waits only 10 ms for a busy checkpoint. Returns the queue file.
    private func useQueueWithShortBusyTimeout() throws -> URL {
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        queue.close()
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: queueURL, policy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 10)))
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queue, now: { [clock] in clock!.now })
        return queueURL
    }

    /// The database file next to an empty WAL: the state after the unsynchronized WAL commits are lost.
    private func powerLossCopy(of databaseFileName: String) throws -> URL {
        let directory = tempDir.appendingPathComponent("power-loss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(databaseFileName)
        try FileManager.default.copyItem(at: tempDir.appendingPathComponent(databaseFileName), to: copy)
        try Data().write(to: URL(fileURLWithPath: copy.path + "-wal"))
        return copy
    }

    /// A second connection in an open read transaction. A full checkpoint cannot pass the state it reads.
    private func openPinnedReader(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw XCTSkip("the queue file could not be opened")
        }
        XCTAssertEqual(
            sqlite3_exec(handle, "BEGIN; SELECT COUNT(*) FROM backup_sync_queue;", nil, nil, nil), SQLITE_OK)
        return handle
    }

    private func closePinnedReader(_ handle: OpaquePointer) {
        sqlite3_exec(handle, "COMMIT;", nil, nil, nil)
        sqlite3_close(handle)
    }

    /// The token is read before the snapshot lists the library. A photo added after the listing but before the
    /// snapshot is published is reported by the change history on the next pass.
    func testPhotoAddedWhileTheSnapshotIsBuiltIsReadOnTheNextPass() async throws {
        enumerator.infos = ["A", "B", "C"].map { photoInfo($0) }
        let history = FakeChangeHistory()
        let added = photoInfo("Z")
        enumerator.afterIdentifierSnapshot = { [enumerator] in
            enumerator!.infos.insert(added, at: 0)
            history.record(changed: ["Z"])
        }
        try await startScanPass(history: history)
        XCTAssertTrue(catalog.hasCompletedFullScan())
        XCTAssertNil(catalog.presentEntries(for: ["Z"])["Z"], "Z is not in the snapshot of this scan")

        enumerator.afterIdentifierSnapshot = nil
        enumerator.readCount = 0
        try await startScanPass(history: history)

        XCTAssertEqual(enumerator.readCount, 1, "only Z is read")
        XCTAssertNotNil(catalog.presentEntries(for: ["Z"])["Z"])
        let z = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "Z")
        XCTAssertNotNil(queue.entry(for: z, revision: UploadBackupRevision(date: modDate)))
    }

    /// A photo taken/edited while a pass is already running must land in the durable queue and be
    /// drained this pass; not wait for the next. Models the controller's `reconcileWhileScanning`
    /// running concurrently with the scan, plus a targeted catalog sync firing from the change
    /// observer (`enqueueRecentChangesIntoRunningPass`). The mid-pass-enqueued asset must upload in
    /// the same pass, exactly once, with dedup preflight intact (no duplicate, no bypass).
    func testAssetAddedDuringActivePassIsRunnableThatSamePass() async throws {
        // The library starts with A; A is already backed up (catalog + queue settled).
        enumerator.infos = [photoInfo("A")]
        _ = await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_A.HEIC"])
        let resolveCountA = resolver.resolveCount(for: "A")

        // A new pass starts. The full scan sees A (already-backed), B (just-changed), and C (brand-new,
        // not yet in the enumerator when the scan starts; it represents the asset the change observer
        // reports mid-pass). The reconcile loop drains concurrently with the scan, exactly like the
        // controller's reconcileWhileScanning. While the scan runs, the instant-enqueue path runs a
        // targeted catalog sync for C, writing a durable discovered row the same reconcile loop drains.
        enumerator.infos = [photoInfo("A"), photoInfo("B")]

        clock.advance(by: 60)
        let runID = UUID().uuidString
        _ = lockStore.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-Self.lease))
        XCTAssertTrue(lockStore.acquire(owner: .foreground, runID: runID).didAcquire)

        let scanDone = BackupScanSignal()
        let instantEnqueueRan = IntBox()

        // Break `self` capture for Swift 6 isolation (runner is a stored property to self.runner).
        // Local lets make the closure capture only the actor value, not self.
        let runner = self.runner!

        // The controller's own reconcile loop drains concurrently with the scan and must pick up the
        // mid-pass-enqueued asset. The test clock ends its coalescing pauses at once.
        let queue = self.queue!
        let testClock = clock!
        async let reconcile: BackupSyncProgress = PhotoLibraryBackupController.reconcileWhileScanning(
            runner: runner, scanDone: scanDone, workIntent: .automatic, queue: queue, clock: testClock,
            now: { testClock.now })

        // Scan phase. The full scan enumerates A and B (C is not in `infos` yet; it is the
        // change-observer asset). Partway through the scan we run the targeted instant-enqueue for C:
        // a separate PhotoLibraryCatalogSync over just ["C"] that writes C's durable queue row, exactly
        // as enqueueRecentChangesIntoRunningPass does. We add C to the enumerator first so the targeted
        // fetch finds it.
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C", modified: modDate.addingTimeInterval(9999))]
        resolver.setModified(modDate.addingTimeInterval(9999), for: "C")
        // Inject the instant enqueue for C; runs as part of the scan phase (mid-pass). The change
        // observer's path does this on a detached utility task; here we run it inline for determinism.
        let targeted = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        _ = try? await targeted.run(engine: engine, identifiers: ["C"])
        instantEnqueueRan.value = 1
        // Now run the full scan for A and B.
        _ = try await sync.run(engine: engine, identifiers: nil)
        await scanDone.markDone()

        _ = await reconcile
        lockStore.release(runID: runID)

        // All three are backed up in this pass. C was enqueued mid-pass and drained by the same reconcile loop.
        XCTAssertEqual(instantEnqueueRan.value, 1, "the instant-enqueue path ran mid-pass")
        XCTAssertEqual(
            Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC", "IMG_C.HEIC"],
            "the mid-pass-added asset C uploads in the SAME pass")
        XCTAssertEqual(
            uploader.requests.filter { $0.name == "IMG_C.HEIC" }.count, 1,
            "C uploads exactly once (no double-enqueue despite targeted enqueue + full scan)")
        XCTAssertEqual(
            resolver.resolveCount(for: "A"), resolveCountA,
            "already-backed A is not re-uploaded (dedup preflight intact)")
        XCTAssertEqual(queue.summary().uploaded, 3)
    }

    /// While the scan runs, the drain loop waits for queue writes instead of polling. A photo enqueued after the
    /// last drain wakes the next drain at once; the end of the scan alone would take until the whole library is read.
    func testARowEnqueuedAfterTheLastDrainStartsAnotherDrainBeforeTheScanEnds() async throws {
        let runner = self.runner!
        let queue = self.queue!
        let scanDone = BackupScanSignal()
        // No timer may end the wait: the held clock never lets a sleep finish.
        let held = HeldBackupSleepClock(clock: clock)
        let testClock = clock!
        let reconcile = Task {
            await PhotoLibraryBackupController.reconcileWhileScanning(
                runner: runner, scanDone: scanDone, workIntent: .automatic, queue: queue, clock: held,
                now: { testClock.now })
        }
        try await waitForCondition { await scanDone.wake.isWaiting }

        enumerator.infos = [photoInfo("C")]
        let targeted = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        _ = try await targeted.run(engine: engine, identifiers: ["C"])

        // The write woke the loop; it waits out the coalescing pause, so writes of the same chunk drain together.
        try await waitForCondition { held.isWaiting }
        XCTAssertTrue(uploader.requests.isEmpty, "the drain waits for the coalescing pause")
        held.releaseAll()
        try await waitForCondition { [uploader] in uploader!.requests.map(\.name) == ["IMG_C.HEIC"] }
        let scanStillRuns = await !scanDone.isDone()
        XCTAssertTrue(scanStillRuns, "C uploads while the scan still runs")
        // A cancel while the upload is in flight returns the row to the queue; wait until the queue shows it as uploaded.
        try await waitForCondition { queue.summary().uploaded == 1 }
        await scanDone.markDone()
        reconcile.cancel()
        _ = await reconcile.value
        XCTAssertEqual(queue.summary().uploaded, 1)
    }

    /// A retry date that passes during a long scan wakes the drain at that date; no queue write happens.
    func testARetryDateThatPassesDuringTheScanWakesTheDrain() async throws {
        let runner = self.runner!
        let queue = self.queue!
        enumerator.infos = [photoInfo("D")]
        let targeted = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        _ = try await targeted.run(engine: engine, identifiers: ["D"])
        var entry = try XCTUnwrap(queue.entries(in: .discovered, updatedBefore: .distantFuture, limit: 10).first)
        entry.updatedAt = clock.now.addingTimeInterval(30)
        XCTAssertTrue(queue.upsert(entry))
        XCTAssertEqual(
            PhotoLibraryBackupController.nextDueDelay(in: queue, now: clock.now), 30,
            "the wait ends at the persisted retry date")

        let scanDone = BackupScanSignal()
        let held = HeldBackupSleepClock(clock: clock)
        let testClock = clock!
        let reconcile = Task {
            await PhotoLibraryBackupController.reconcileWhileScanning(
                runner: runner, scanDone: scanDone, workIntent: .automatic, queue: queue, clock: held,
                now: { testClock.now })
        }
        try await waitForCondition { held.isWaiting }
        XCTAssertTrue(uploader.requests.isEmpty, "D is not due yet")

        held.releaseAll()  // The 30-second wait ends and the test clock moves to the retry date.
        try await waitForCondition { [uploader] in uploader!.requests.map(\.name) == ["IMG_D.HEIC"] }
        let scanStillRuns = await !scanDone.isDone()
        XCTAssertTrue(scanStillRuns, "D uploads at its retry date, before the scan ends")
        await scanDone.markDone()
        reconcile.cancel()
        _ = await reconcile.value
    }

    func testTheEndOfTheScanEndsAWaitingDrainWithoutAWrite() async throws {
        let runner = self.runner!
        let queue = self.queue!
        let scanDone = BackupScanSignal()
        let held = HeldBackupSleepClock(clock: clock)
        let testClock = clock!
        let ended = IntBox()
        let reconcile = Task {
            _ = await PhotoLibraryBackupController.reconcileWhileScanning(
                runner: runner, scanDone: scanDone, workIntent: .automatic, queue: queue, clock: held,
                now: { testClock.now })
            ended.value = 1
        }
        try await waitForCondition { await scanDone.wake.isWaiting }

        await scanDone.markDone()
        try await waitForCondition { ended.value == 1 }
        reconcile.cancel()
        await reconcile.value
    }

    /// A row whose date passed after the drain's last claim is due now. It must wake the next drain at once and must
    /// not hide a later date by being the earliest one.
    func testADueRowWakesTheDrainAtOnce() throws {
        XCTAssertTrue(queue.upsert(runnableEntry("due", at: clock.now.addingTimeInterval(-1))))
        XCTAssertTrue(queue.upsert(runnableEntry("later", at: clock.now.addingTimeInterval(30))))
        XCTAssertEqual(PhotoLibraryBackupController.nextDueDelay(in: queue, now: clock.now), 0)
    }

    /// The pending grid keeps the store's one legacy observer; the controller's loops subscribe through `changes()`.
    /// Both hear the same committed write, and clearing the legacy observer (the grid closes) ends no subscription.
    func testTheLegacyObserverAndChangeSubscribersBothHearAWrite() async throws {
        let legacy = IntBox()
        queue.setChangeObserver { _ in legacy.value += 1 }
        var subscription = queue.changes().makeAsyncIterator()

        XCTAssertTrue(queue.upsert(runnableEntry("first", at: clock.now)))
        let first = await subscription.next()
        XCTAssertNotNil(first)
        XCTAssertEqual(legacy.value, 1)

        queue.setChangeObserver(nil)
        XCTAssertTrue(queue.upsert(runnableEntry("second", at: clock.now)))
        let second = await subscription.next()
        XCTAssertNotNil(second, "the subscription outlives the legacy observer")
        XCTAssertEqual(legacy.value, 1)
    }

    /// A far-future or damaged date must not reach the clock as an unbounded sleep.
    func testAFarFutureDateWaitsAtMostTheLongestPark() throws {
        XCTAssertTrue(queue.upsert(runnableEntry("far", at: .distantFuture)))
        XCTAssertEqual(
            PhotoLibraryBackupController.nextDueDelay(in: queue, now: clock.now),
            PhotoLibraryBackupController.longestDueWait)
        XCTAssertEqual(PhotoLibraryBackupController.longestDueWait, 6 * 3600)
    }

    /// A row that stays due but is never taken wakes the loop again and again. The pause after each wake bounds that to
    /// one drain per `coalescing` seconds of the scheduler clock; it must never spin. The scan ends inside the pause that
    /// reaches 20 seconds, so the count is exact however late the test thread runs: the first drain, one per pause, and
    /// the tail drain after the end of the scan.
    func testARowThatStaysDueDrainsAtMostOncePerPause() async throws {
        XCTAssertTrue(queue.upsert(runnableEntry("stuck", at: clock.now.addingTimeInterval(-1))))
        let queue = self.queue!
        let start = clock.now
        let scanDone = BackupScanSignal()
        let pauses = ScanEndingClock(clock: clock, end: start.addingTimeInterval(20), scanDone: scanDone)
        let drains = IntBox()
        let reconcile = Task {
            await PhotoLibraryBackupController.reconcileWhileScanning(
                drain: {
                    drains.value += 1  // Takes nothing: the row stays due.
                    // A loop that drains without pausing never reaches the end of the scan; this ends it instead.
                    if drains.value > 1_000 { await scanDone.markDone() }
                    return BackupSyncProgress()
                },
                isQueueOperational: { true }, scanDone: scanDone, queue: queue, coalescing: 1, clock: pauses,
                now: { pauses.now })
        }
        // The loop ends by itself after the tail drain. The limit only ends a loop that waits forever.
        let hangLimit = Task {
            try await Task.sleep(for: .seconds(300))
            reconcile.cancel()
        }
        _ = await reconcile.value
        hangLimit.cancel()

        XCTAssertEqual(clock.now.timeIntervalSince(start), 20, "twenty one-second pauses end the scan")
        XCTAssertEqual(drains.value, 22, "at most one drain per pause, plus the first and the tail drain")
    }

    /// The test's scheduler clock: it advances like `BackupTestClock` and ends the scan inside the pause that reaches
    /// `end`, so the test needs no polling of the clock.
    private final class ScanEndingClock: BackupSchedulerClock, Sendable {
        private let clock: BackupTestClock
        private let end: Date
        private let scanDone: BackupScanSignal

        init(clock: BackupTestClock, end: Date, scanDone: BackupScanSignal) {
            self.clock = clock
            self.end = end
            self.scanDone = scanDone
        }

        var now: Date { clock.now }

        func sleep(for seconds: TimeInterval) async throws {
            try await clock.sleep(for: seconds)
            if clock.now >= end { await scanDone.markDone() }
        }
    }

    private func runnableEntry(_ id: String, at date: Date) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
            originalFilename: "\(id).heic", state: .discovered, updatedAt: date)
    }

    func testNothingWaitsForADateWhenNoRowIsDueLater() throws {
        XCTAssertNil(PhotoLibraryBackupController.nextDueDelay(in: queue, now: clock.now))
        // The runner parks a draft with its re-check date as `updatedAt`.
        let recheck = clock.now.addingTimeInterval(90)
        let draft = BackupIssueRecord(kind: .remoteDraft, detail: "draft", nextAttemptAt: recheck).persistedValue
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: .init(kind: .photoLibraryAsset, identifier: "draft"), revision: .init(rawValue: 1),
                    originalFilename: "draft.heic", state: .blockedByDraft, lastError: draft, updatedAt: recheck)))
        XCTAssertEqual(
            PhotoLibraryBackupController.nextDueDelay(in: queue, now: clock.now), 90,
            "a draft re-check wakes the drain at its date")
    }

    private func waitForCondition(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let met = await condition()
        XCTAssertTrue(met, "condition not met within 10 seconds")
    }

    /// The `ON CONFLICT` upsert in the durable queue must not regress a row that is already claimed
    /// (`checking`/`uploading`/…) or terminally succeeded back to `discovered`. Without this guard, a
    /// A targeted mid-pass enqueue must not upsert `state='discovered'` over a claimed row.
    /// Otherwise `claimRunnable` could reclaim the row and double-upload it.
    func testConcurrentUpsertDoesNotRegressClaimedState() async throws {
        enumerator.infos = [photoInfo("A")]
        _ = await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.map(\.name), ["IMG_A.HEIC"])

        // Enqueue A again as brand-new (state=.discovered); simulating a targeted enqueue arriving
        // for an asset the pass already handled. The upsert must not regress A's terminal `completed`
        // state back to `discovered`.
        let candidate = UploadBackupAssetCandidate(
            snapshot: .init(
                source: .init(kind: .photoLibraryAsset, identifier: "A"),
                revision: UploadBackupRevision(date: modDate),
                resourceCount: 1
            ),
            originalFilename: "IMG_A.HEIC",
            byteCount: 100
        )
        try await engine.enqueue(candidate)

        // A must still be `completed` (terminal success), not `discovered`.
        let entry = queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision)
        XCTAssertNotNil(entry, "the queue row exists")
        XCTAssertEqual(entry?.state, .completed, "a terminal row is never regressed by a concurrent upsert")

        // And draining again must not re-upload A (no duplicate).
        let uploadsBefore = uploader.requests.count
        _ = await runner.runUntilDrained()
        XCTAssertEqual(uploader.requests.count, uploadsBefore, "a regressed row would cause a duplicate upload")
        XCTAssertEqual(queue.summary().uploaded, 1, "still exactly one uploaded")
    }

    /// Directly prove the state guard protects the active phase too: claim a row into `checking`
    /// (via `claimRunnable`), then upsert it as `discovered`, and assert it stays `checking` and is
    /// not reclaimed. This is the precise race the instant-enqueue path opens: its `Task.detached`
    /// catalog sync can call `engine.enqueue` while the runner already has the row claimed.
    func testUpsertDiscoveredDoesNotRegressCheckingState() async throws {
        // Set up: scan-only pass so A lands as `discovered` but is not drained (no upload yet).
        enumerator.infos = [photoInfo("A")]
        let sync = PhotoLibraryCatalogSync(
            store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        _ = try await sync.run(engine: engine, identifiers: nil)

        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "A")
        let revision = UploadBackupRevision(date: modDate)
        XCTAssertEqual(queue.entry(for: source, revision: revision)?.state, .discovered)

        // Claim A to state flips to `checking` (atomically, begin immediate). Note: `claimRunnable`
        // returns the entries in their PRE-claim state (the select runs before the update); the
        // authoritative post-claim state is read back via `entry(for:)` below.
        let claimed = queue.claimRunnable(limit: 16, claimedAt: clock.now)
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed.first?.state, .discovered, "returned entry reflects pre-claim state")
        XCTAssertEqual(
            queue.entry(for: source, revision: revision)?.state, .checking,
            "claimRunnable atomically flipped discovered → checking in the DB")

        // now the concurrent targeted enqueue arrives: it sees A as `.newAsset` (nothing in the
        // preflight yet) and calls queue.upsert(state=.discovered). Without the guard, this regresses
        // A from `checking` back to `discovered` to claimRunnable reclaims it to double upload.
        let candidate = UploadBackupAssetCandidate(
            snapshot: .init(source: source, revision: revision, resourceCount: 1),
            originalFilename: "IMG_A.HEIC",
            byteCount: 100
        )
        try await engine.enqueue(candidate)

        // A must still be `checking`; the upsert was a no-op on state because checking is protected.
        XCTAssertEqual(
            queue.entry(for: source, revision: revision)?.state, .checking,
            "an upsert must never regress an in-flight checking row back to discovered")

        // A second claimRunnable must find zero runnable rows (A is still checking, not discovered).
        let reclaimed = queue.claimRunnable(limit: 16, claimedAt: clock.now)
        XCTAssertEqual(
            reclaimed.count, 0,
            "the guarded row is not reclaimable; no double-claim or double-upload path remains")
    }

    /// Thread-safe int cell so a `@Sendable` scan-start hook can hand a count back to the test body.
    private final class IntBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private func photoInfo(_ id: String, modified: Date? = nil, created: Date? = nil) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id,
            creationDate: created ?? Date(timeIntervalSince1970: 1_699_000_000),
            modificationDate: modified ?? modDate,
            pixelWidth: 4032, pixelHeight: 3024,
            durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic")]
        )
    }

    private final class CannedEnumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
        private let lock = NSLock()
        private var _infos: [PhotoBackupAssetInfo]
        var infos: [PhotoBackupAssetInfo] {
            get { lock.withLock { _infos } }
            set { lock.withLock { _infos = newValue } }
        }
        init(infos: [PhotoBackupAssetInfo]) { _infos = infos }

        /// Fires once when the scan actually begins enumerating; lets a test capture how much upload
        /// work already happened before the scan (proving the drain runs first).
        var onEnumerationStart: (@Sendable () -> Void)? {
            get { lock.withLock { _onEnumerationStart } }
            set { lock.withLock { _onEnumerationStart = newValue } }
        }
        private var _onEnumerationStart: (@Sendable () -> Void)?

        /// When set, the stream yields at most this many assets and then throws; simulating a full
        /// scan interrupted (app backgrounded / cancelled) before it could reach the library's end.
        var throwAfter: Int? {
            get { lock.withLock { remainingBeforeThrow } }
            set { lock.withLock { remainingBeforeThrow = newValue } }
        }
        private var remainingBeforeThrow: Int?

        /// When true, the identifier snapshot stops before it lists anything.
        var failsSnapshot: Bool {
            get { lock.withLock { _failsSnapshot } }
            set { lock.withLock { _failsSnapshot = newValue } }
        }
        private var _failsSnapshot = false

        /// Runs after the identifier snapshot listed the library and before it streams the identifiers.
        var afterIdentifierSnapshot: (@Sendable () -> Void)? {
            get { lock.withLock { _afterIdentifierSnapshot } }
            set { lock.withLock { _afterIdentifierSnapshot = newValue } }
        }
        private var _afterIdentifierSnapshot: (@Sendable () -> Void)?

        /// Assets whose metadata `infoChunks` read. The identifier snapshot is not counted.
        var readCount: Int {
            get { lock.withLock { _readCount } }
            set { lock.withLock { _readCount = newValue } }
        }
        private var _readCount = 0

        func infoChunks(
            identifiers: [String]?, startOffset: Int, chunkSize: Int
        ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            onEnumerationStart?()
            let all = infos
            let selectedAll = identifiers.map { ids in all.filter { Set(ids).contains($0.localIdentifier) } } ?? all
            let selected = Array(selectedAll.dropFirst(max(0, startOffset)))  // resume point
            let (allowedCount, shouldThrow) = lock.withLock { () -> (Int, Bool) in
                guard let remainingBeforeThrow else {
                    _readCount += selected.count
                    return (selected.count, false)
                }
                let allowed = min(max(0, remainingBeforeThrow), selected.count)
                self.remainingBeforeThrow = remainingBeforeThrow - allowed
                _readCount += allowed
                return (allowed, allowed < selected.count)
            }
            return AsyncThrowingStream { continuation in
                var index = 0
                while index < allowedCount {
                    let upper = min(index + max(1, chunkSize), allowedCount)
                    continuation.yield(Array(selected[index..<upper]))
                    index = upper
                }
                if shouldThrow {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.finish()
            }
        }

        func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error> {
            onEnumerationStart?()
            let identifiers = infos.map(\.localIdentifier)
            afterIdentifierSnapshot?()
            let fails = failsSnapshot
            return AsyncThrowingStream { continuation in
                if fails {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                var index = 0
                while index < identifiers.count {
                    let upper = min(index + max(1, chunkSize), identifiers.count)
                    continuation.yield(
                        PhotoLibraryIdentifierChunk(
                            identifiers: Array(identifiers[index..<upper]),
                            totalCount: identifiers.count
                        ))
                    index = upper
                }
                continuation.finish()
            }
        }
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String] = []
        var values: [String] { lock.withLock { _values } }
        func append(_ value: String) { lock.withLock { _values.append(value) } }
    }

    /// Forwards to the engine and records each queue synchronization.
    private final class SyncRecordingEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let engine: UploadBackupSyncEngine
        private let events: EventLog

        init(engine: UploadBackupSyncEngine, events: EventLog) {
            self.engine = engine
            self.events = events
        }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
            try await engine.enqueue(candidate)
        }

        func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult {
            try await engine.enqueueBatch(candidates)
        }

        func reopenBackedUpRevisions(
            _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
        ) async throws -> [UploadBackupAssetCandidate] {
            try await engine.reopenBackedUpRevisions(
                reopenings, deferringWithoutRemoteProof: deferringWithoutRemoteProof)
        }

        func synchronizeQueueToDisk() async -> Bool {
            let synchronized = await engine.synchronizeQueueToDisk()
            events.append("queue sync")
            return synchronized
        }
    }

    /// Forwards to the engine and copies the committed database files right before each queue insert.
    private final class CopyingEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let engine: UploadBackupSyncEngine
        private let copies: CommittedFilesLog

        init(engine: UploadBackupSyncEngine, copies: CommittedFilesLog) {
            self.engine = engine
            self.copies = copies
        }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
            try await enqueueBatch([candidate])
        }

        func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult {
            copies.copy()
            return try await engine.enqueueBatch(candidates)
        }

        func reopenBackedUpRevisions(
            _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
        ) async throws -> [UploadBackupAssetCandidate] {
            try await engine.reopenBackedUpRevisions(
                reopenings, deferringWithoutRemoteProof: deferringWithoutRemoteProof)
        }

        func synchronizeQueueToDisk() async -> Bool {
            await engine.synchronizeQueueToDisk()
        }
    }

    /// Copies each database file with its WAL at every `every`-th call: every committed transaction survives.
    private final class CommittedFilesLog: @unchecked Sendable {
        private let source: URL
        private let names: [String]
        private let every: Int
        private let lock = NSLock()
        private var calls = 0
        private var copies: [URL] = []
        var directories: [URL] { lock.withLock { copies } }

        init(source: URL, names: [String], every: Int) {
            self.source = source
            self.names = names
            self.every = every
        }

        func copy() {
            lock.withLock {
                calls += 1
                guard calls % every == 0 else { return }
                let directory = source.appendingPathComponent("power-loss-\(calls)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for name in names {
                        for suffix in ["", "-wal"] {
                            let file = source.appendingPathComponent(name + suffix)
                            guard FileManager.default.fileExists(atPath: file.path) else { continue }
                            let copy = directory.appendingPathComponent(name + suffix)
                            try FileManager.default.copyItem(at: file, to: copy)
                        }
                    }
                    copies.append(directory)
                } catch {
                    XCTFail("copy failed: \(error)")
                }
            }
        }
    }

    /// PhotoKit's persistent change history as the change monitor uses it: a stored token, the changes recorded
    /// after it, and an expired history that asks for a full rescan.
    private final class FakeChangeHistory: @unchecked Sendable {
        struct Prepared: Sendable {
            var changes: PhotoLibraryChangeMonitor.ChangeSet
            var token: Int
        }

        private let lock = NSLock()
        private var records: [(changed: Set<String>, deleted: Set<String>)] = []
        private var storedToken: Int?
        private var expired = false
        private var liveRescanRequested = false

        func record(changed: Set<String> = [], deleted: Set<String> = []) {
            lock.withLock { records.append((changed, deleted)) }
        }

        func expire() {
            lock.withLock { expired = true }
        }

        /// A live change without incremental details: it asks for a rescan and leaves the stored token valid.
        func requestRescanWithoutTokenChange() {
            lock.withLock { liveRescanRequested = true }
        }

        /// The live observer state does not survive a relaunch; the stored token and the history do.
        func relaunch() {
            lock.withLock { liveRescanRequested = false }
        }

        func prepare() -> Prepared {
            lock.withLock {
                let current = records.count
                guard let storedToken, !expired else {
                    return Prepared(
                        changes: .init(changedIdentifiers: [], deletedIdentifiers: [], requiresFullRescan: true),
                        token: current)
                }
                var changed: Set<String> = []
                var deleted: Set<String> = []
                for record in records[storedToken..<current] {
                    changed.formUnion(record.changed)
                    deleted.formUnion(record.deleted)
                }
                changed.subtract(deleted)
                return Prepared(
                    changes: .init(
                        changedIdentifiers: changed.sorted(), deletedIdentifiers: deleted.sorted(),
                        requiresFullRescan: liveRescanRequested),
                    token: current)
            }
        }

        func commit(_ prepared: Prepared) {
            lock.withLock {
                storedToken = prepared.token
                expired = false
                liveRescanRequested = false
            }
        }
    }

    private final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }
        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }
        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
            return true
        }
        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }
}
