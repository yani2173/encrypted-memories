import Foundation
import Photos
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import PhotosCore
@testable import UploadCore

final class MissingSourceReconciliationTests: XCTestCase {
    private var directory: URL!
    private var catalog: PhotoLibraryCatalogManifestStore!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var state: UploadBackupStateManifestStore!
    private var exclusions: PendingBackupManifestStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openStores()
    }

    override func tearDownWithError() throws {
        closeStores()
        try FileManager.default.removeItem(at: directory)
    }

    private func openStores() throws {
        catalog = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(url: url(PhotoLibraryCatalogManifestStore.databaseFileName)))
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: url(UploadBackupSyncQueueManifestStore.databaseFileName)))
        state = try XCTUnwrap(UploadBackupStateManifestStore(url: url(UploadBackupStateManifestStore.databaseFileName)))
        exclusions = try XCTUnwrap(PendingBackupManifestStore(url: url(PendingBackupManifestStore.databaseFileName)))
    }

    private func closeStores() {
        catalog?.close()
        queue?.close()
        state?.close()
        exclusions?.close()
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func candidate(_ id: String, save: Bool = true) throws -> UploadBackupAssetCandidate {
        let info = PhotoBackupAssetInfo(
            localIdentifier: id, creationDate: Date(timeIntervalSince1970: 100),
            modificationDate: Date(timeIntervalSince1970: 200), pixelWidth: 10, pixelHeight: 10,
            durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "\(id).jpg", mimeType: "image/jpeg")],
            cloudIdentifier: "cloud-\(id)")
        if save {
            XCTAssertTrue(catalog.upsertBatch([PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date())]))
        }
        return try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
    }

    private func row(
        _ candidate: UploadBackupAssetCandidate, state: UploadBackupSyncQueueState = .discovered
    )
        -> UploadBackupSyncQueueEntry
    {
        UploadBackupSyncQueueEntry(
            source: candidate.snapshot.source, revision: candidate.snapshot.revision,
            originalFilename: candidate.originalFilename, state: state, updatedAt: Date(timeIntervalSince1970: 300))
    }

    private func engine(
        proof: ProofSpy? = nil, clock: BackupTestClock? = nil
    ) -> UploadBackupSyncEngine {
        UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: state), queue: queue,
            remoteProofResolver: proof, exclusions: exclusions, now: { clock?.now ?? Date() })
    }

    func testOnlyPresentUnbackedSourcesWithoutAnyQueueRowReturnAndTheSweepReadsNoRemoteProof() async throws {
        let missing = try candidate("missing")
        let complete = try candidate("complete")
        let excluded = try candidate("excluded")
        let deleted = try candidate("deleted")
        let removed = try candidate("removed")
        let parked = try candidate("parked")
        let pending = try candidate("pending")
        let preflight = UploadBackupPreflightIndex(store: state)
        try await preflight.markBackedUp(complete.snapshot)
        try await preflight.markPending(pending.snapshot)
        XCTAssertTrue(catalog.markRemoved([removed.snapshot.source.identifier], removedAt: Date()).succeeded)
        XCTAssertNotNil(
            exclusions.exclude(
                [excluded, deleted].map {
                    PendingExclusionRequest(key: PendingSourceKey($0.snapshot.source), presentation: nil, remote: nil)
                }, at: Date()))
        let parkedRow = row(parked, state: .failedPermanent)
        XCTAssertTrue(queue.upsert(parkedRow))
        let proof = ProofSpy()
        let sync = PhotoLibraryCatalogSync(store: catalog, chunkSize: 2)
        try await sync.reconcileMissingSources(engine: engine(proof: proof))
        XCTAssertEqual(queue.count(), 3)
        for candidate in [missing, pending] {
            XCTAssertNotNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        }
        for candidate in [complete, excluded, deleted, removed] {
            XCTAssertNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        }
        XCTAssertEqual(queue.entry(for: parked.snapshot.source, revision: parked.snapshot.revision), parkedRow)
        XCTAssertEqual(proof.calls, 0)
        XCTAssertEqual(catalog.reconciledMissingSourceGeneration(), 0)
        // The upgrade sweep runs once: an ordinary removal does not invent another sweep.
        XCTAssertTrue(queue.remove(source: missing.snapshot.source, revision: missing.snapshot.revision))
        try await sync.reconcileMissingSources(engine: engine(proof: proof))
        XCTAssertNil(queue.entry(for: missing.snapshot.source, revision: missing.snapshot.revision))
    }

    func testPermanentlyMissingPhotoStaysRecordedWithoutAnotherSweepOrAttemptAfterRelaunch() async throws {
        let candidate = try candidate("permanent")
        XCTAssertTrue(queue.upsert(row(candidate)))
        let tracked = PageCatalog(inner: catalog)
        let sync = PhotoLibraryCatalogSync(store: tracked)
        try await sync.reconcileMissingSources(engine: engine())
        XCTAssertEqual(tracked.pages, 2)
        let clock = BackupTestClock()
        let resolver = ScriptedBackupResolver(defaultModified: Date(timeIntervalSince1970: 200))
        resolver.set(.failure(UploadError.sourceReportedMissing("permanent.jpg"), times: 10), for: "permanent")
        let runner = runner(clock: clock, resolver: resolver)
        for wait in [3600.0, 7200, 14_400] {
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
            clock.advance(by: wait)
        }
        let progress = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(progress.sourceMissing, 1)
        let terminal = try XCTUnwrap(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(terminal.state, .sourceMissing)
        XCTAssertNil(BackupIssueRecord.decode(terminal.lastError)?.nextAttemptAt)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        try await sync.reconcileMissingSources(engine: engine())
        XCTAssertEqual(tracked.pages, 2, "The final missing report must not start another catalog sweep")
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.entry(for: terminal.source, revision: terminal.revision), terminal)

        closeStores()
        try openStores()
        let relaunchedCatalog = PageCatalog(inner: catalog)
        try await PhotoLibraryCatalogSync(store: relaunchedCatalog).reconcileMissingSources(engine: engine())
        XCTAssertEqual(relaunchedCatalog.pages, 0)
        let relaunched = self.runner(clock: clock, resolver: resolver)
        let retries = await relaunched.makeRetryableWorkEligibleNow()
        XCTAssertEqual(retries, 0, "Back Up Now must not reset the missing-source checks")
        _ = await relaunched.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(resolver.resolveCount(for: "permanent"), 4)
        XCTAssertEqual(queue.entry(for: terminal.source, revision: terminal.revision), terminal)

        // A sweep owed for another source also leaves the terminal row untouched.
        let dropped = try self.candidate("older-drop")
        XCTAssertTrue(queue.upsert(row(dropped)))
        XCTAssertTrue(queue.removeMissingSource(source: dropped.snapshot.source, revision: dropped.snapshot.revision))
        try await PhotoLibraryCatalogSync(store: relaunchedCatalog).reconcileMissingSources(engine: engine())
        XCTAssertEqual(queue.count(), 2)
        XCTAssertEqual(queue.entry(for: terminal.source, revision: terminal.revision), terminal)
        XCTAssertNotNil(queue.entry(for: dropped.snapshot.source, revision: dropped.snapshot.revision))
    }

    // MARK: - Issue 445: a photo that cannot be read must not return on every pass

    func testAPhotoThatPhotosNoLongerListsLeavesTheCatalogInsteadOfReturningOnEveryPass() async throws {
        let gone = try candidate("gone")
        let info = PhotoLibraryCatalogMapper.info(for: try XCTUnwrap(catalog.entry(for: "gone")))
        XCTAssertTrue(queue.upsert(row(gone)))
        let tracked = PageCatalog(inner: catalog)
        let sync = PhotoLibraryCatalogSync(store: tracked)
        let clock = BackupTestClock()
        try await sync.reconcileMissingSources(engine: engine(clock: clock))
        let pagesBefore = tracked.pages
        let resolver = ScriptedBackupResolver(defaultModified: Date(timeIntervalSince1970: 200))
        resolver.set(.missing, for: "gone")
        let runner = runner(
            clock: clock, resolver: resolver, markSourceUnavailable: catalogRecordsUnavailableSources())

        var totals: [Int] = []
        for _ in 1...3 {
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
            try await sync.reconcileMissingSources(engine: engine(clock: clock))
            totals.append(queue.summary().total)
            clock.advance(by: 3600)
        }

        XCTAssertEqual(totals, [0, 0, 0], "the photo must not be queued again after each pass")
        XCTAssertEqual(resolver.resolveCount(for: "gone"), 1, "Photos is asked once")
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 1)
        XCTAssertEqual(tracked.pages - pagesBefore, 1, "one catalog walk for the one drop, not one per pass")
        XCTAssertTrue(catalog.presentEntries(for: ["gone"]).isEmpty, "the catalog no longer lists the photo")
        XCTAssertEqual(queue.summary().sourceMissing, 0, "nothing is shown as a problem")

        // When Photos lists the photo again, it backs up as usual.
        let listed = PhotoLibraryCatalogSync(store: catalog, enumerator: ChangedEnumerator(info: info))
        try await listed.runPass(
            engine: engine(clock: clock),
            changes: .init(changedIdentifiers: ["gone"], deletedIdentifiers: [], requiresFullRescan: false),
            commitChanges: {})
        XCTAssertFalse(catalog.presentEntries(for: ["gone"]).isEmpty)
        resolver.set(.standard, for: "gone")
        let progress = await runner.runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testAFileThatIsGoneDuringTheBackupKeepsThePhotoInTheCatalog() async throws {
        // The temporary file of a listed photo can vanish during the backup. Only a photo that the library no
        // longer lists leaves the catalog; the earlier recovery still brings this one back.
        let candidate = try candidate("vanished-file")
        XCTAssertTrue(queue.upsert(row(candidate)))
        let clock = BackupTestClock()
        let resolver = ScriptedBackupResolver(defaultModified: Date(timeIntervalSince1970: 200))
        resolver.set(.failure(UploadError.fileMissing("vanished-file.jpg"), times: 1), for: "vanished-file")
        let runner = runner(
            clock: clock, resolver: resolver, markSourceUnavailable: catalogRecordsUnavailableSources())

        _ = await runner.runUntilDrained(mode: .eligibleOnly)

        XCTAssertFalse(catalog.presentEntries(for: ["vanished-file"]).isEmpty, "the photo stays in the catalog")
        try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine(clock: clock))
        XCTAssertNotNil(
            queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision),
            "recovery queues the photo again")
    }

    func testAPhotoWhoseFileCannotBeReadUsesTheMissingChecksInsteadOfReturningOnEveryPass() async throws {
        for code in [PHPhotosError.Code.invalidResource, .identifierNotFound] {
            let id = "unreadable-\(code.rawValue)"
            let candidate = try candidate(id)
            XCTAssertTrue(queue.upsert(row(candidate)))
            let tracked = PageCatalog(inner: catalog)
            let sync = PhotoLibraryCatalogSync(store: tracked)
            let clock = BackupTestClock()
            try await sync.reconcileMissingSources(engine: engine(clock: clock))
            let pagesBefore = tracked.pages
            let generationBefore = queue.missingSourceDiscardGeneration()
            let resolver = ScriptedBackupResolver(defaultModified: Date(timeIntervalSince1970: 200))
            let failure = PhotoLibraryResourceResolver.normalizedPhotoKitError(
                NSError(domain: PHPhotosErrorDomain, code: code.rawValue), filename: "\(id).jpg")
            resolver.set(.failure(failure, times: 100), for: id)
            let runner = runner(
                clock: clock, resolver: resolver, markSourceUnavailable: catalogRecordsUnavailableSources())

            var queued: [Bool] = []
            for wait in [3600.0, 7200, 14_400] {
                _ = await runner.runUntilDrained(mode: .eligibleOnly)
                try await sync.reconcileMissingSources(engine: engine(clock: clock))
                queued.append(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision) != nil)
                clock.advance(by: wait)
            }
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
            try await sync.reconcileMissingSources(engine: engine(clock: clock))

            XCTAssertEqual(queued, [true, true, true], "\(code): the row stays while Photos is asked again")
            let terminal = try XCTUnwrap(
                queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision), "\(code)")
            XCTAssertEqual(terminal.state, .sourceMissing, "\(code): shown once as missing after the last check")
            XCTAssertEqual(resolver.resolveCount(for: id), 4, "\(code): one attempt and three checks")
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), generationBefore, "\(code)")
            XCTAssertEqual(tracked.pages, pagesBefore, "\(code): no catalog walk")
            XCTAssertFalse(catalog.presentEntries(for: [id]).isEmpty, "\(code): the photo is still in the library")
        }
    }

    func testAChangedPhotoReopensATerminalMissingRowAtTheSameOrANewRevision() async throws {
        for newRevision in [false, true] {
            let id = newRevision ? "new-revision" : "same-revision"
            let candidate = try candidate(id)
            XCTAssertTrue(queue.upsert(row(candidate, state: .sourceMissing)))
            var info = PhotoLibraryCatalogMapper.info(for: try XCTUnwrap(catalog.entry(for: id)))
            info.resources[0].originalFilename = "available.jpg"
            if newRevision { info.modificationDate = Date(timeIntervalSince1970: 201) }
            let changed = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
            XCTAssertEqual(changed.snapshot.revision == candidate.snapshot.revision, !newRevision)
            let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: ChangedEnumerator(info: info))
            let progress = try await sync.run(engine: engine(), identifiers: [id])
            XCTAssertEqual(progress.changed, 1)
            XCTAssertEqual(
                queue.entry(for: changed.snapshot.source, revision: changed.snapshot.revision)?.state, .discovered)
            let clock = BackupTestClock(start: Date())
            let resolver = ScriptedBackupResolver(defaultModified: try XCTUnwrap(info.modificationDate))
            let uploaded = await runner(clock: clock, resolver: resolver).runUntilDrained(mode: .eligibleOnly)
            XCTAssertEqual(uploaded.uploaded, newRevision ? 2 : 1)
            XCTAssertEqual(
                queue.entry(for: changed.snapshot.source, revision: changed.snapshot.revision)?.state, .completed)
            XCTAssertEqual(queue.summary().sourceMissing, 0)
        }
    }

    func testPhotosChangeReopensMissingSourceEvenWhenCatalogMetadataIsUnchanged() async throws {
        let candidate = try candidate("available-again")
        let info = PhotoLibraryCatalogMapper.info(for: try XCTUnwrap(catalog.entry(for: "available-again")))
        let terminal = row(candidate, state: .sourceMissing)
        XCTAssertTrue(queue.upsert(terminal))
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: ChangedEnumerator(info: info))
        _ = try await sync.run(engine: engine())
        XCTAssertEqual(
            queue.entry(for: terminal.source, revision: terminal.revision), terminal,
            "An unchanged full scan must keep the terminal missing record")
        try await sync.runPass(
            engine: engine(),
            changes: .init(
                changedIdentifiers: [info.localIdentifier], deletedIdentifiers: [], requiresFullRescan: false),
            commitChanges: {})
        XCTAssertEqual(
            queue.entry(for: terminal.source, revision: terminal.revision)?.state, .discovered,
            "A Photos change must retry the file even when dates and listed resources stay the same")
        let clock = BackupTestClock(start: Date())
        let resolver = ScriptedBackupResolver(defaultModified: Date(timeIntervalSince1970: 200))
        let progress = await runner(clock: clock, resolver: resolver).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(queue.summary().sourceMissing, 0)
    }

    func testRepeatedPhotosChangesForABrokenFileNeverStartAnotherMissingSourceSweep() async throws {
        let candidate = try candidate("still-broken")
        let info = PhotoLibraryCatalogMapper.info(for: try XCTUnwrap(catalog.entry(for: "still-broken")))
        XCTAssertTrue(queue.upsert(row(candidate, state: .sourceMissing)))
        let clock = BackupTestClock()
        let engine = engine(clock: clock)
        let initialSync = PhotoLibraryCatalogSync(store: catalog, enumerator: ChangedEnumerator(info: info))
        _ = try await initialSync.run(engine: engine)
        try await initialSync.reconcileMissingSources(engine: engine)
        let tracked = PageCatalog(inner: catalog)
        let sync = PhotoLibraryCatalogSync(store: tracked, enumerator: ChangedEnumerator(info: info))
        let resolver = ScriptedBackupResolver(defaultModified: Date(timeIntervalSince1970: 200))
        resolver.set(
            .failure(UploadError.sourceReportedMissing("still-broken.jpg"), times: 100), for: info.localIdentifier)
        let runner = runner(clock: clock, resolver: resolver)
        for round in 1...3 {
            try await sync.runPass(
                engine: engine,
                changes: .init(
                    changedIdentifiers: [info.localIdentifier], deletedIdentifiers: [], requiresFullRescan: false),
                commitChanges: {})
            for wait in [3600.0, 7200, 14_400] {
                _ = await runner.runUntilDrained(mode: .eligibleOnly)
                let waiting = try XCTUnwrap(
                    queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
                XCTAssertEqual(waiting.state, .discovered)
                // Another signal during a planned check must not reset its count or due date.
                try await sync.runPass(
                    engine: engine,
                    changes: .init(
                        changedIdentifiers: [info.localIdentifier], deletedIdentifiers: [], requiresFullRescan: false),
                    commitChanges: {})
                XCTAssertEqual(queue.entry(for: waiting.source, revision: waiting.revision), waiting)
                clock.advance(by: wait)
            }
            _ = await runner.runUntilDrained(mode: .eligibleOnly)
            XCTAssertEqual(
                queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision)?.state,
                .sourceMissing)
            XCTAssertEqual(
                resolver.resolveCount(for: info.localIdentifier), round * 4,
                "Each terminal reopening permits one attempt and only three scheduled rechecks")
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
            try await sync.reconcileMissingSources(engine: engine)
            XCTAssertEqual(tracked.pages, 0, "Repeated Photos changes must not trigger a full recovery sweep")
            XCTAssertEqual(queue.count(), 1)
        }
    }

    func testPhotosChangeReopensDismissedMissingSourceWhenItsBytesReturnWithUnchangedMetadata() async throws {
        try await verifyDismissedMissingSourceReopensAfterAvailabilityProof(metadataChanged: false)
    }

    func testChangedMetadataReopensDismissedMissingSourceOnlyWhenItsBytesReturn() async throws {
        try await verifyDismissedMissingSourceReopensAfterAvailabilityProof(metadataChanged: true)
    }

    private func verifyDismissedMissingSourceReopensAfterAvailabilityProof(metadataChanged: Bool) async throws {
        let candidate = try candidate("dismissed-available")
        var info = PhotoLibraryCatalogMapper.info(for: try XCTUnwrap(catalog.entry(for: "dismissed-available")))
        if metadataChanged { info.resources[0].originalFilename = "available.jpg" }
        let offered = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: info))
        XCTAssertEqual(offered.snapshot.revision, candidate.snapshot.revision)
        let clock = BackupTestClock()
        try dismiss(candidate, issue: .init(kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail))
        let dismissed = try XCTUnwrap(
            queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        let live = UploadBackupAssetCandidate(
            snapshot: .init(
                source: offered.snapshot.source, revision: offered.snapshot.revision,
                editRevision: offered.snapshot.editRevision, resourceCount: offered.snapshot.resourceCount),
            originalFilename: offered.originalFilename)
        XCTAssertNil(live.snapshot.externalIdentity)
        XCTAssertNotNil(offered.snapshot.externalIdentity)
        let availability = AvailabilityResolver(candidate: live)
        let engine = engine(clock: clock)
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: ChangedEnumerator(info: info))
        if !metadataChanged {
            _ = try await sync.run(engine: engine)
            XCTAssertEqual(queue.entry(for: dismissed.source, revision: dismissed.revision), dismissed)
            XCTAssertEqual(availability.calls, 0)
        }
        try await sync.runPass(
            engine: engine,
            changes: .init(
                changedIdentifiers: [info.localIdentifier], deletedIdentifiers: [], requiresFullRescan: false),
            commitChanges: {})
        XCTAssertEqual(queue.entry(for: dismissed.source, revision: dismissed.revision)?.state, .discovered)
        XCTAssertEqual(availability.calls, 0)
        let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertEqual(availability.cleanups, 1)
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertEqual(queue.entry(for: dismissed.source, revision: dismissed.revision)?.state, .completed)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testChangedMetadataCannotRequeueADismissedSourceWhoseFileIsStillMissing() async throws {
        try await verifyDismissedMissingSourceStaysClosedWithoutProof(metadataChanged: true)
    }

    func testUnchangedMetadataCannotRequeueADismissedSourceWhoseFileIsStillMissing() async throws {
        try await verifyDismissedMissingSourceStaysClosedWithoutProof(metadataChanged: false)
    }

    private func verifyDismissedMissingSourceStaysClosedWithoutProof(metadataChanged: Bool) async throws {
        let candidate = try candidate("dismissed-broken")
        var info = PhotoLibraryCatalogMapper.info(for: try XCTUnwrap(catalog.entry(for: "dismissed-broken")))
        let clock = BackupTestClock()
        try dismiss(
            candidate,
            issue: .init(
                kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail, automaticRetryAttempt: 3))
        let availability = AvailabilityResolver(candidate: candidate, missing: true)
        var engine = engine(clock: clock)
        try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine)
        var tracked = PageCatalog(inner: catalog)
        for round in 1...3 {
            if metadataChanged { info.resources[0].originalFilename = "still-missing-\(round).jpg" }
            let dismissed = try XCTUnwrap(
                queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
            let sync = PhotoLibraryCatalogSync(store: tracked, enumerator: ChangedEnumerator(info: info))
            try await sync.runPass(
                engine: engine,
                changes: .init(
                    changedIdentifiers: [info.localIdentifier], deletedIdentifiers: [], requiresFullRescan: false),
                commitChanges: {})
            let pending = try XCTUnwrap(queue.entry(for: dismissed.source, revision: dismissed.revision))
            XCTAssertEqual(pending.state, .discovered)
            XCTAssertEqual(pending.lastError, dismissed.lastError)
            XCTAssertEqual(availability.calls, round - 1)
            let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
                mode: .eligibleOnly)
            XCTAssertEqual(availability.calls, round)
            XCTAssertEqual(queue.entry(for: dismissed.source, revision: dismissed.revision)?.state, .dismissedFailure)
            XCTAssertEqual(progress.needsAttention, 0)
            XCTAssertEqual(progress.dismissedFailures, 1)
            clock.advance(by: 7 * 3600)
            _ = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(mode: .eligibleOnly)
            XCTAssertEqual(availability.calls, round, "A retained dismissal never starts a timed check chain")
            try await sync.reconcileMissingSources(engine: engine)
            XCTAssertEqual(tracked.pages, 0)
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
            if round == 1 {
                closeStores()
                try openStores()
                engine = self.engine(clock: clock)
                tracked = PageCatalog(inner: catalog)
            }
        }
        XCTAssertEqual(availability.calls, 3)
        XCTAssertEqual(queue.count(), 1)
    }

    func testPhotosChangesKeepDismissedRowsWithOtherOrUnreadableReasons() async throws {
        let reasons: [BackupIssueRecord?] = [
            .init(kind: .unsupported, detail: "unsupported"),
            .init(kind: .deletedElsewhere, detail: BackupFailedItem.sourceReportedMissingDetail),
            .init(kind: .unknown, detail: BackupFailedItem.sourceReportedMissingDetail),
            nil,
        ]
        for (index, reason) in reasons.enumerated() {
            let candidate = try candidate("dismissed-other-\(index)")
            var info = PhotoLibraryCatalogMapper.info(
                for: try XCTUnwrap(catalog.entry(for: candidate.snapshot.source.identifier)))
            try dismiss(candidate, issue: reason)
            let dismissed = try XCTUnwrap(
                queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
            let availability = AvailabilityResolver(candidate: candidate)
            for metadataChanged in [false, true] {
                if metadataChanged { info.resources[0].originalFilename = "changed.jpg" }
                let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: ChangedEnumerator(info: info))
                try await sync.runPass(
                    engine: engine(),
                    changes: .init(
                        changedIdentifiers: [info.localIdentifier], deletedIdentifiers: [], requiresFullRescan: false),
                    commitChanges: {})
                XCTAssertEqual(queue.entry(for: dismissed.source, revision: dismissed.revision), dismissed)
                XCTAssertEqual(availability.calls, 0)
            }
        }
    }

    func testAvailabilityProofMustMatchTheCurrentRevisionAndContainEveryResourcesReadBytes() async throws {
        for scenario in ["different-source", "different-revision", "missing-digest", "incomplete-compound"] {
            let original = try candidate("proof-\(scenario)")
            let offered = UploadBackupAssetCandidate(
                snapshot: .init(
                    source: original.snapshot.source, revision: original.snapshot.revision,
                    editRevision: original.snapshot.editRevision,
                    resourceCount: scenario == "incomplete-compound" ? 2 : original.snapshot.resourceCount),
                originalFilename: original.originalFilename)
            try dismiss(
                offered, issue: .init(kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail))
            let dismissed = try XCTUnwrap(
                queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
            let snapshot = offered.snapshot
            let resolved = UploadBackupAssetCandidate(
                snapshot: .init(
                    source: scenario == "different-source"
                        ? .init(kind: .photoLibraryAsset, identifier: "other", resource: .primary) : snapshot.source,
                    revision: scenario == "different-revision"
                        ? .init(rawValue: snapshot.revision.rawValue + 1) : snapshot.revision,
                    editRevision: snapshot.editRevision,
                    resourceCount: snapshot.resourceCount),
                originalFilename: offered.originalFilename)
            let availability = AvailabilityResolver(
                candidate: resolved, digest: scenario == "missing-digest" ? nil : Data(repeating: 1, count: 20))
            let clock = BackupTestClock()
            try await engine(clock: clock).enqueueChangedMissingSources([offered])
            let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
                mode: .eligibleOnly)
            let pending = try XCTUnwrap(queue.entry(for: dismissed.source, revision: dismissed.revision))
            XCTAssertEqual(pending.state, .discovered)
            let issue = try XCTUnwrap(BackupIssueRecord.decode(pending.lastError))
            XCTAssertEqual(issue.kind, .sourceMissing)
            XCTAssertEqual(issue.detail, BackupIssueRecord.decode(dismissed.lastError)?.detail)
            XCTAssertEqual(issue.automaticRetryAttempt, 1)
            XCTAssertEqual(issue.nextAttemptAt, pending.updatedAt)
            XCTAssertEqual(progress.uploaded, 0)
            XCTAssertEqual(progress.dismissedFailures, 1)
            XCTAssertEqual(progress.waiting, 0)
            XCTAssertEqual(availability.calls, 1)
            XCTAssertEqual(availability.cleanups, 1)
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
            XCTAssertTrue(queue.remove(source: offered.snapshot.source, revision: offered.snapshot.revision))
        }
    }

    func testAvailabilityCheckPreservesADismissalChangedWhileReadingTheFile() async throws {
        let offered = try candidate("changed-dismissal")
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail))
        let changedIssue = BackupIssueRecord(kind: .unsupported, detail: "unsupported fixture")
        let queue = try XCTUnwrap(self.queue)
        let availability = AvailabilityResolver(
            candidate: offered,
            beforeResult: {
                XCTAssertTrue(
                    queue.updateState(
                        source: offered.snapshot.source, revision: offered.snapshot.revision, state: .dismissedFailure,
                        attempts: 8, lastError: changedIssue.persistedValue, updatedAt: Date(timeIntervalSince1970: 400)
                    ))
            })
        let clock = BackupTestClock()
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(progress.uploaded, 0)
        let retained = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(retained.state, .dismissedFailure)
        XCTAssertEqual(BackupIssueRecord.decode(retained.lastError), changedIssue)
        XCTAssertEqual(retained.attempts, 8)
        XCTAssertEqual(retained.updatedAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(availability.cleanups, 1)
    }

    func testAvailabilityCheckPreservesTheRequestOnCancellationAndTransientErrors() async throws {
        let failures: [any Error] = [
            CancellationError(), UploadError.backend("availability fixture failed"),
            UploadError.sourceUnavailable("local access failed"),
            UploadError.sourceNotReady("still processing", until: Date(timeIntervalSince1970: 500)),
        ]
        for (index, failure) in failures.enumerated() {
            let offered = try candidate("transient-proof-\(index)")
            try dismiss(
                offered, issue: .init(kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail))
            let dismissed = try XCTUnwrap(
                queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
            let clock = BackupTestClock()
            let availability = AvailabilityResolver(candidate: offered, failure: failure)
            try await engine(clock: clock).enqueueChangedMissingSources([offered])
            let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
                mode: .eligibleOnly)
            let pending = try XCTUnwrap(queue.entry(for: dismissed.source, revision: dismissed.revision))
            XCTAssertEqual(pending.state, .discovered)
            let issue = try XCTUnwrap(BackupIssueRecord.decode(pending.lastError))
            XCTAssertEqual(issue.kind, .sourceMissing)
            XCTAssertEqual(issue.detail, BackupIssueRecord.decode(dismissed.lastError)?.detail)
            XCTAssertEqual(issue.automaticRetryAttempt, failure is CancellationError ? 0 : 1)
            XCTAssertEqual(issue.nextAttemptAt, pending.updatedAt)
            XCTAssertEqual(pending.attempts, dismissed.attempts)
            XCTAssertGreaterThan(pending.updatedAt, clock.now)
            XCTAssertEqual(progress.dismissedFailures, 1)
            XCTAssertEqual(progress.needsAttention, 0)
            XCTAssertEqual(progress.waiting, 0)
            XCTAssertEqual(availability.calls, 1)
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
            XCTAssertTrue(queue.remove(source: offered.snapshot.source, revision: offered.snapshot.revision))
        }
    }

    func testBothMetadataPathsScheduleOneCheckWithoutAnEngineResolver() async throws {
        let offered = try candidate("no-availability-resolver")
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "legacy missing reason"))
        let dismissed = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        let changed = UploadBackupAssetCandidate(snapshot: offered.snapshot, originalFilename: "new-name.jpg")
        let engine = engine()
        let result = try await engine.enqueueBatch([changed])
        try await engine.enqueueChangedMissingSources([changed])
        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.queuedForWork, 0)
        let pending = try XCTUnwrap(queue.entry(for: dismissed.source, revision: dismissed.revision))
        XCTAssertEqual(pending.state, .discovered)
        XCTAssertEqual(pending.lastError, dismissed.lastError)
        XCTAssertEqual(queue.count(), 1)
    }

    func testStoredMissingReasonReopensWithoutDependingOnItsDetailText() async throws {
        let offered = try candidate("legacy-missing-reason")
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "legacy missing reason"))
        let clock = BackupTestClock()
        let availability = AvailabilityResolver(candidate: offered)
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        XCTAssertEqual(
            queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .discovered)
        XCTAssertEqual(availability.calls, 0)
        _ = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(
            queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .completed)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertEqual(availability.cleanups, 1)
    }

    func testFailedRecoveredSourceWritePreservesTheDismissalAndReportsTheFailure() async throws {
        let offered = try candidate("failed-reopen-write")
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail))
        let dismissed = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        try sql(
            url(UploadBackupSyncQueueManifestStore.databaseFileName),
            """
            CREATE TRIGGER deny_reopen BEFORE UPDATE ON backup_sync_queue
            WHEN OLD.state='dismissedFailure' AND NEW.state <> OLD.state
            BEGIN SELECT RAISE(ABORT, 'reopening unavailable'); END;
            """)
        let availability = AvailabilityResolver(candidate: offered)
        do {
            try await engine().enqueueChangedMissingSources([offered])
            XCTFail("A failed recovered-source write must keep the change retryable")
        } catch {
            guard case UploadError.backend = error else { return XCTFail("Unexpected write error: \(error)") }
        }
        XCTAssertEqual(availability.calls, 0)
        XCTAssertEqual(availability.cleanups, 0)
        closeStores()
        try sql(url(UploadBackupSyncQueueManifestStore.databaseFileName), "DROP TRIGGER deny_reopen;")
        try openStores()
        XCTAssertEqual(queue.entry(for: dismissed.source, revision: dismissed.revision), dismissed)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testDismissedSourceRecheckWaitsForMobileDataPermissionThenUploads() async throws {
        try await verifyDismissedSourceRecheckWaitsForPermission(missing: false, relaunch: false)
    }

    func testDismissedSourceRecheckWaitsForPermissionThenRetainsAMissingDismissal() async throws {
        try await verifyDismissedSourceRecheckWaitsForPermission(missing: true, relaunch: false)
    }

    func testDismissedSourceRecheckSurvivesRelaunchBeforePermissionThenUploads() async throws {
        try await verifyDismissedSourceRecheckWaitsForPermission(missing: false, relaunch: true)
    }

    func testDismissedSourceRecheckSurvivesRelaunchAndRetainsAMissingDismissal() async throws {
        try await verifyDismissedSourceRecheckWaitsForPermission(missing: true, relaunch: true)
    }

    func testDismissedSourceRecheckResistsDirectSyncUpserts() throws {
        let offered = try candidate("direct-upsert-recheck")
        var pending = row(offered)
        pending.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        XCTAssertTrue(queue.upsert(pending))
        for state in [UploadBackupSyncQueueState.discovered, .queuedForUpload, .alreadyBackedUp] {
            var replacement = row(offered, state: state)
            replacement.originalFilename = "metadata-change.jpg"
            replacement.updatedAt = pending.updatedAt.addingTimeInterval(100)
            XCTAssertTrue(queue.upsertBatch([replacement]))
            XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        }
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testDismissedSourceRecheckSurvivesSweepsAndCompletePreflightWithoutSourceAccess() async throws {
        let offered = try candidate("preflight-recheck")
        var pending = row(offered)
        pending.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        XCTAssertTrue(queue.upsert(pending))
        let proof = ProofSpy()
        let engine = engine(proof: proof)
        let tracked = PageCatalog(inner: catalog)
        let sync = PhotoLibraryCatalogSync(store: tracked)
        try await sync.reconcileMissingSources(engine: engine)
        let pages = tracked.pages
        try await UploadBackupPreflightIndex(store: state).markBackedUp(offered.snapshot)
        for _ in 0..<3 {
            try await sync.reconcileMissingSources(engine: engine)
            _ = try await engine.enqueueBatch([offered])
            try await engine.enqueueChangedMissingSources([offered])
        }
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        XCTAssertEqual(tracked.pages, pages)
        XCTAssertEqual(proof.calls, 0)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testDismissedSourceRecheckRemainsDismissedInStatusAndIncrementalQueueViews() async throws {
        let offered = try candidate("projected-recheck")
        var pending = row(offered)
        pending.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        XCTAssertTrue(queue.upsert(pending))
        let projector = BackupStatusProjector(queue: queue)
        let generation = UUID()
        await projector.start(generation: generation, context: .init(), handler: { _ in })
        let projected = await projector.projectNow(context: .init(), generation: generation, revision: 1)
        let projection = try XCTUnwrap(projected)
        XCTAssertEqual(projection.progress.total, 1)
        XCTAssertEqual(projection.progress.waiting, 0)
        XCTAssertEqual(projection.progress.dismissedFailures, 1)
        XCTAssertEqual(projection.progress.outstanding.count, 1, "The scheduler still owes a check")
        XCTAssertEqual(projection.status.needsAttentionCount, 0)
        XCTAssertEqual(projection.status.notBackedUpCount, 1)
        XCTAssertTrue(queue.unsettledRows().isEmpty)
        XCTAssertEqual(
            queue.rows(kind: .photoLibraryAsset, identifiers: [offered.snapshot.source.identifier]).map(\.state),
            [.dismissedFailure])
        await projector.stop()
    }

    func testDismissedSourceRecheckSurvivesClaimCrashRecoveryAndManualEligibility() throws {
        let offered = try candidate("claimed-recheck")
        var pending = row(offered)
        pending.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        XCTAssertTrue(queue.upsert(pending))
        let date = pending.updatedAt.addingTimeInterval(10)
        let claimed = try XCTUnwrap(queue.claimRunnable(limit: 1, claimedAt: date).first)
        XCTAssertEqual(claimed.lastError, pending.lastError)
        XCTAssertTrue(queue.unsettledRows().isEmpty)
        closeStores()
        try openStores()
        XCTAssertEqual(queue.requeueStaleActive(before: date.addingTimeInterval(1), updatedAt: date), 1)
        _ = queue.makeRetryableWorkEligible(updatedAt: date.addingTimeInterval(1))
        let restored = try XCTUnwrap(queue.entry(for: pending.source, revision: pending.revision))
        XCTAssertEqual(restored.state, .discovered)
        XCTAssertEqual(restored.lastError, pending.lastError)
        XCTAssertEqual(queue.summary().dismissedFailures, 1)
        XCTAssertEqual(queue.summary().waiting, 0)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testDismissedSourceRecheckDoesNotPrimeRemoteDuplicatesBeforeItsBytesReturn() async throws {
        let offered = try candidate("unprimed-recheck")
        var pending = row(offered)
        pending.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        XCTAssertTrue(queue.upsert(pending))
        let availability = AvailabilityResolver(candidate: offered, missing: true)
        let proof = ProofSpy()
        _ = await availabilityRunner(clock: BackupTestClock(), resolver: availability, identityResolver: proof)
            .runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertTrue(proof.primedSources.isEmpty)
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision)?.state, .dismissedFailure)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    private func verifyDismissedSourceRecheckWaitsForPermission(missing: Bool, relaunch: Bool) async throws {
        let offered = try candidate("permission-recheck")
        let issue = BackupIssueRecord(kind: .sourceMissing, detail: BackupFailedItem.sourceReportedMissingDetail)
        try dismiss(offered, issue: issue)
        let clock = BackupTestClock()
        let availability = AvailabilityResolver(candidate: offered, missing: missing)
        let network = BackupNetworkBox(.init(isNetworkExpensive: true, usesMobileData: false))
        let engine = engine(clock: clock)
        try await engine.enqueueChangedMissingSources([offered])
        let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(pending.state, .discovered, "The row holds one durable check, without releasing the dismissal")
        XCTAssertEqual(BackupIssueRecord.decode(pending.lastError), issue)
        XCTAssertEqual(availability.calls, 0, "Only admitted runner work may access the source")
        for _ in 0..<3 {
            try await engine.enqueueChangedMissingSources([offered])
            _ = try await engine.enqueueBatch([offered])
        }
        XCTAssertEqual(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision), pending)
        let waiting = await availabilityRunner(clock: clock, resolver: availability, network: network).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertTrue(waiting.isWaitingForWiFi)
        XCTAssertEqual(waiting.needsAttention, 0)
        XCTAssertEqual(waiting.dismissedFailures, 1)
        XCTAssertEqual(waiting.waiting, 0, "A deferred check is not another pending upload")
        XCTAssertEqual(availability.calls, 0)
        var problems: [UploadBackupSyncQueueEntry] = []
        queue.forEachProblemEntry {
            problems.append($0)
            return true
        }
        XCTAssertTrue(problems.isEmpty)
        XCTAssertTrue(queue.unsettledRows().isEmpty, "Pending upload reconciliation must not restore a dismissed photo")
        if relaunch {
            closeStores()
            try openStores()
            XCTAssertEqual(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision), pending)
        }
        network.set(.init(usesMobileData: false))
        let completed = await availabilityRunner(clock: clock, resolver: availability, network: network)
            .runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertEqual(completed.needsAttention, 0)
        XCTAssertEqual(completed.uploaded, missing ? 0 : 1)
        XCTAssertEqual(completed.dismissedFailures, missing ? 1 : 0)
        XCTAssertEqual(
            queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state,
            missing ? .dismissedFailure : .completed)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        let tracked = PageCatalog(inner: catalog)
        // Finish the owed upgrade sweep before measuring subsequent passes.
        try await PhotoLibraryCatalogSync(store: tracked).reconcileMissingSources(engine: self.engine())
        let pages = tracked.pages
        clock.advance(by: 7 * 3600)
        try await PhotoLibraryCatalogSync(store: tracked).reconcileMissingSources(engine: self.engine())
        _ = await availabilityRunner(clock: clock, resolver: availability, network: network).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(tracked.pages, pages)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertEqual(queue.count(), 1)
    }

    func testDismissedSourceRecheckRechecksPermissionAfterClaimBeforeReading() async throws {
        let offered = try candidate("permission-after-claim")
        let clock = BackupTestClock()
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let network = BackupNetworkBox(.unconstrained)
        let queue = try XCTUnwrap(self.queue)
        queue.setChangeObserver { _ in
            if queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state == .checking {
                network.set(.init(isNetworkExpensive: true, usesMobileData: false))
            }
        }
        let availability = AvailabilityResolver(candidate: offered)
        let progress = await availabilityRunner(clock: clock, resolver: availability, network: network).runUntilDrained(
            mode: .eligibleOnly)
        queue.setChangeObserver(nil)
        XCTAssertEqual(availability.calls, 0)
        XCTAssertEqual(progress.dismissedFailures, 1)
        XCTAssertEqual(progress.waiting, 0)
        let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(pending.state, .discovered)
        XCTAssertEqual(BackupIssueRecord.decode(pending.lastError)?.kind, .sourceMissing)
        network.set(.unconstrained)
        clock.advance(by: 2)
        _ = await availabilityRunner(clock: clock, resolver: availability, network: network).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertEqual(
            queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .completed)
    }

    func testDismissedSourceRecheckKeepsTheIncompleteDuplicateIndexWarningWhileThePassRuns() async throws {
        let offered = try candidate("permission-with-incomplete-index")
        let clock = BackupTestClock()
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let network = BackupNetworkBox(.unconstrained)
        let queue = try XCTUnwrap(self.queue)
        queue.setChangeObserver { _ in
            if queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state == .checking {
                network.set(.init(isNetworkExpensive: true, usesMobileData: false))
            }
        }
        let degraded = UploadRemoteContentIndexHealth.degraded(indexedCount: 989, unresolvedCount: 11)
        let checker = FakeChecker()
        checker.contentIndexHealth = degraded
        let availability = AvailabilityResolver(candidate: offered)
        let runner = availabilityRunner(
            clock: clock, resolver: availability, network: network,
            identityResolver: UploadDedupePipeline(store: FakeIdentityStore(), hasher: FakeHasher(), checker: checker))
        let snapshots = ProgressSnapshots()
        await runner.setOnProgress { snapshots.append($0) }

        _ = await runner.runUntilDrained(mode: .eligibleOnly)
        queue.setChangeObserver(nil)

        // The claimed recheck must take the deferral path that refreshes the progress from the queue.
        XCTAssertEqual(availability.calls, 0)
        let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(pending.state, .discovered)
        XCTAssertEqual(BackupIssueRecord.decode(pending.lastError)?.kind, .sourceMissing)
        // Every snapshot that the running pass publishes after it reported the index health, including the one
        // that follows the recheck deferral. The final snapshot (not running) is covered by the finished-pass test.
        let all = snapshots.values
        let reported = try XCTUnwrap(all.firstIndex { $0.remoteContentIndexHealth == degraded })
        let afterReport = all[reported...].filter(\.isRunning)
        for snapshot in afterReport {
            XCTAssertEqual(snapshot.remoteContentIndexHealth, degraded)
        }
    }

    private final class ProgressSnapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [BackupSyncProgress] = []
        var values: [BackupSyncProgress] { lock.withLock { stored } }
        func append(_ progress: BackupSyncProgress) { lock.withLock { stored.append(progress) } }
    }

    func testDismissedSourceRecheckRetainsTheRequestWhenPermissionChangesDuringAMissingRead() async throws {
        let offered = try candidate("permission-during-read")
        let clock = BackupTestClock()
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let network = BackupNetworkBox(.unconstrained)
        let availability = AvailabilityResolver(
            candidate: offered, missing: true,
            beforeResult: {
                network.set(.init(isNetworkAvailable: false))
            })
        let progress = await availabilityRunner(clock: clock, resolver: availability, network: network).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(availability.calls, 1)
        XCTAssertEqual(progress.dismissedFailures, 1)
        let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(pending.state, .discovered, "An offline result cannot consume the change")
        XCTAssertEqual(BackupIssueRecord.decode(pending.lastError)?.kind, .sourceMissing)
        closeStores()
        try openStores()
        network.set(.unconstrained)
        clock.advance(by: 2)
        let missing = AvailabilityResolver(candidate: offered, missing: true)
        _ = await availabilityRunner(clock: clock, resolver: missing, network: network).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(missing.calls, 1)
        XCTAssertEqual(
            queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .dismissedFailure)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testDismissedSourceRecheckKeepsNilAndFileMissingResultsDismissedWithoutASweep() async throws {
        for nilResult in [false, true] {
            let offered = try candidate(nilResult ? "nil-result" : "file-missing-result")
            let clock = BackupTestClock()
            try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
            try await engine(clock: clock).enqueueChangedMissingSources([offered])
            let availability = AvailabilityResolver(
                candidate: offered, returnsNil: nilResult,
                failure: nilResult ? nil : UploadError.fileMissing("missing fixture"))
            _ = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(mode: .eligibleOnly)
            XCTAssertEqual(
                queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .dismissedFailure
            )
            XCTAssertEqual(availability.calls, 1)
            clock.advance(by: 7 * 3600)
            _ = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(mode: .eligibleOnly)
            XCTAssertEqual(availability.calls, 1)
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        }
    }

    func testDismissedSourceRecheckConditionalWritePreservesChangedStateReasonReceiptAndRemoval() throws {
        for scenario in ["state", "reason", "receipt", "removed"] {
            let offered = try candidate("conditional-\(scenario)")
            var pending = row(offered, state: .checking)
            let reason = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
            pending.lastError = reason
            if scenario == "receipt" {
                pending.remoteCommitReconciliation = UploadRemoteCommitReconciliation(
                    source: pending.source,
                    identity: UploadIdentity(
                        correctedName: pending.originalFilename, nameHash: "fixture-name-hash",
                        sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                        contentHash: "fixture-content-hash"),
                    receipt: UploadRemoteCommitReceipt(remoteVolumeID: "fixture-volume", remoteLinkID: "fixture-link"))
            }
            XCTAssertTrue(queue.upsert(pending))
            if scenario == "removed" { XCTAssertTrue(queue.remove(source: pending.source, revision: pending.revision)) }
            var released = pending
            released.lastError = nil
            let expectedState: UploadBackupSyncQueueState = scenario == "state" ? .discovered : .checking
            let expectedReason = scenario == "reason" ? "another saved reason" : reason
            XCTAssertEqual(
                queue.updateDismissedSourceRecheck(
                    released, matchingState: expectedState, matchingLastError: expectedReason), false)
            XCTAssertEqual(
                queue.entry(for: pending.source, revision: pending.revision), scenario == "removed" ? nil : pending)
            XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        }
    }

    func testDismissedSourceRecheckRemovedDuringTheReadCannotUploadOrReturn() async throws {
        let offered = try candidate("removed-during-read")
        let clock = BackupTestClock()
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let queue = try XCTUnwrap(self.queue)
        let availability = AvailabilityResolver(
            candidate: offered,
            beforeResult: {
                XCTAssertTrue(queue.remove(source: offered.snapshot.source, revision: offered.snapshot.revision))
            })
        let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(progress.uploaded, 0)
        XCTAssertNil(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(availability.cleanups, 1)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testManualEligibilityPreservesADismissedSourceRechecksReadinessAndBackoff() async throws {
        let offered = try candidate("manual-recheck")
        let clock = BackupTestClock()
        let due = clock.now.addingTimeInterval(900)
        var pending = row(offered)
        pending.updatedAt = due
        pending.lastError =
            BackupIssueRecord(
                kind: .sourceMissing, detail: "acknowledged missing", nextAttemptAt: due, automaticRetryAttempt: 12
            ).persistedValue
        XCTAssertTrue(queue.upsert(pending))
        for _ in 0..<3 {
            XCTAssertEqual(queue.makeRetryableWorkEligible(updatedAt: clock.now), 0)
            let defaults = SpyQueueStore(inner: queue, log: BackupEventLog())
            XCTAssertEqual(defaults.makeRetryableWorkEligible(updatedAt: clock.now), 0)
            XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        }
        closeStores()
        try openStores()
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        let premature = AvailabilityResolver(candidate: offered)
        _ = await availabilityRunner(clock: clock, resolver: premature).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(premature.calls, 0)
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        try await assertDeferredDismissalPresentation(clock: clock, due: due)
    }

    func testManualEligibilityStillRedatesOrdinaryUploadRetriesAndKeepsTheirReasons() throws {
        let clock = BackupTestClock()
        var expected: [UploadBackupSyncQueueEntry] = []
        for (index, state) in [
            UploadBackupSyncQueueState.discovered, .queuedForUpload, .failed, .blockedByDraft,
        ].enumerated() {
            let offered = try candidate("manual-ordinary-\(index)")
            var entry = row(offered, state: state)
            entry.updatedAt = clock.now.addingTimeInterval(900)
            entry.attempts = 7
            entry.lastError =
                BackupIssueRecord(
                    kind: .network, detail: "temporary upload error", nextAttemptAt: entry.updatedAt,
                    automaticRetryAttempt: 12
                ).persistedValue
            XCTAssertTrue(queue.upsert(entry))
            entry.updatedAt = clock.now
            if state == .failed { entry.attempts = 0 }
            if state == .failed || state == .blockedByDraft { entry.state = .discovered }
            expected.append(entry)
        }
        XCTAssertEqual(queue.makeRetryableWorkEligible(updatedAt: clock.now), expected.count)
        for entry in expected {
            XCTAssertEqual(queue.entry(for: entry.source, revision: entry.revision), entry)
        }
        let defaults = SpyQueueStore(inner: queue, log: BackupEventLog())
        clock.advance(by: 2)
        XCTAssertEqual(defaults.makeRetryableWorkEligible(updatedAt: clock.now), expected.count)
        for var entry in expected {
            entry.updatedAt = clock.now
            XCTAssertEqual(queue.entry(for: entry.source, revision: entry.revision), entry)
        }
        let claimed = queue.claimRunnable(limit: expected.count, claimedAt: clock.now)
        XCTAssertEqual(Set(claimed.map(\.source)), Set(expected.map(\.source)))
        XCTAssertEqual(claimed.count, expected.count)
    }

    func testNewerSuccessfulRevisionRetiresAnOlderSourceRecheckBeforeItsLateResult() async throws {
        let old = try candidate("superseded-recheck")
        let clock = BackupTestClock()
        try dismiss(old, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
        try await engine(clock: clock).enqueueChangedMissingSources([old])
        let started = UploadTestBarrier(participantCount: 2)
        let release = UploadTestBarrier(participantCount: 2)
        let oldAvailability = AvailabilityResolver(candidate: old)
        let held = HeldAvailabilityResolver(inner: oldAvailability, started: started, release: release)
        let queue = try XCTUnwrap(self.queue)
        let oldUploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        let oldRunner = availabilityRunner(
            clock: clock, resolver: held, uploader: oldUploader,
            resourceCoordinator: .init(runtimeState: LibraryRuntimeState()))
        let oldRun = Task { await oldRunner.runUntilDrained(mode: .eligibleOnly) }
        await started.arriveAndWait()
        XCTAssertEqual(queue.entry(for: old.snapshot.source, revision: old.snapshot.revision)?.state, .checking)
        let newer = UploadBackupAssetCandidate(
            snapshot: .init(
                source: old.snapshot.source,
                revision: .init(rawValue: old.snapshot.revision.rawValue + 1),
                editRevision: old.snapshot.editRevision, resourceCount: 1),
            originalFilename: old.originalFilename)
        var next = row(newer)
        next.updatedAt = clock.now
        XCTAssertTrue(queue.upsert(next))
        let returned = AvailabilityResolver(candidate: newer)
        let completed = await availabilityRunner(
            clock: clock, resolver: returned, resourceCoordinator: .init(runtimeState: LibraryRuntimeState())
        ).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(completed.uploaded, 1)
        XCTAssertEqual(queue.entry(for: next.source, revision: next.revision)?.state, .completed)
        XCTAssertNil(queue.entry(for: old.snapshot.source, revision: old.snapshot.revision))
        XCTAssertEqual(queue.summary().pendingSourceRechecks, 0)
        await release.arriveAndWait()
        let late = await oldRun.value
        XCTAssertEqual(oldUploader.uploaded.count, 0)
        XCTAssertEqual(late.uploaded, 1, "Progress includes the newer successful row in the shared queue")
        XCTAssertEqual(oldAvailability.calls, 1)
        XCTAssertEqual(oldAvailability.cleanups, 1)
        XCTAssertNil(queue.entry(for: old.snapshot.source, revision: old.snapshot.revision))
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.summary().dismissedFailures, 0)
        XCTAssertEqual(queue.summary().pendingSourceRechecks, 0)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    func testSuccessfulCleanupProtectsUploadsOtherSourcesResourcesFutureRevisionsAndReceipts() throws {
        let offered = try candidate("cleanup-boundary")
        let clock = BackupTestClock()
        let keptRevision = UploadBackupRevision(rawValue: offered.snapshot.revision.rawValue + 1)
        var success = row(offered, state: .completed)
        success.revision = keptRevision
        XCTAssertTrue(queue.upsert(success))
        let reason = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
        var obsolete = row(offered)
        obsolete.lastError = reason
        XCTAssertTrue(queue.upsert(obsolete))
        var protected: [UploadBackupSyncQueueEntry] = []
        for (offset, state) in [UploadBackupSyncQueueState.discovered, .checking, .queuedForUpload].enumerated() {
            var pending = row(offered, state: state)
            pending.revision = .init(rawValue: offered.snapshot.revision.rawValue - Int64(offset) - 1)
            pending.updatedAt = clock.now.addingTimeInterval(900)
            pending.lastError = BackupIssueRecord(kind: .network, detail: "pending upload retry").persistedValue
            protected.append(pending)
        }
        var future = obsolete
        future.revision = .init(rawValue: keptRevision.rawValue + 1)
        protected.append(future)
        var secondary = obsolete
        secondary.source = .init(
            kind: offered.snapshot.source.kind, identifier: offered.snapshot.source.identifier,
            resource: .livePairedVideo)
        protected.append(secondary)
        let other = try candidate("other-cleanup-source")
        var otherMarker = row(other)
        otherMarker.lastError = reason
        protected.append(otherMarker)
        var foreignKind = obsolete
        foreignKind.source = .init(kind: .fileURL, identifier: offered.snapshot.source.identifier)
        foreignKind.state = .failedPermanent
        protected.append(foreignKind)
        var receipt = obsolete
        receipt.revision = .init(rawValue: offered.snapshot.revision.rawValue - 10)
        receipt.remoteCommitReconciliation = UploadRemoteCommitReconciliation(
            source: receipt.source,
            identity: UploadIdentity(
                correctedName: receipt.originalFilename, nameHash: "fixture-name-hash",
                sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "fixture-content-hash"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "fixture-volume", remoteLinkID: "fixture-link"))
        protected.append(receipt)
        var terminalReceipt = receipt
        terminalReceipt.revision = .init(rawValue: receipt.revision.rawValue - 1)
        terminalReceipt.state = .dismissedFailure
        protected.append(terminalReceipt)
        XCTAssertTrue(queue.upsertBatch(protected))
        XCTAssertTrue(
            queue.removeUnsavedEarlierRevisions(
                of: offered.snapshot.source, through: keptRevision, except: keptRevision))
        XCTAssertNil(queue.entry(for: obsolete.source, revision: obsolete.revision))
        XCTAssertEqual(queue.entry(for: success.source, revision: success.revision), success)
        for entry in protected {
            XCTAssertEqual(queue.entry(for: entry.source, revision: entry.revision), entry)
        }
        XCTAssertEqual(queue.count(), protected.count + 1)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    private struct HeldAvailabilityResolver: BackupResourceResolving {
        let inner: AvailabilityResolver
        let started: UploadTestBarrier
        let release: UploadTestBarrier

        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            await started.arriveAndWait()
            await release.arriveAndWait()
            return try await inner.resolve(entry)
        }
    }

    func testSourceRecheckNetworkFallbackRechecksAdmissionAfterItsLocalReadFails() async throws {
        try await verifySourceRecheckNetworkFallback(permissionCloses: true, composite: false)
    }

    func testCompositeSourceRecheckRetainsAdmissionAtTheNetworkFallback() async throws {
        try await verifySourceRecheckNetworkFallback(permissionCloses: true, composite: true)
    }

    func testSourceRecheckNetworkFallbackStillReadsWithPermission() async throws {
        try await verifySourceRecheckNetworkFallback(permissionCloses: false, composite: false)
    }

    private func verifySourceRecheckNetworkFallback(permissionCloses: Bool, composite: Bool) async throws {
        let offered = try candidate("gated-network-recheck")
        let clock = BackupTestClock()
        let queue = try XCTUnwrap(self.queue)
        try dismiss(offered, issue: .init(kind: .sourceMissing, detail: "acknowledged missing"))
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let locallyRead = UploadTestBarrier(participantCount: 2)
        let allowFallback = UploadTestBarrier(participantCount: 2)
        let fallback = NetworkFallbackAvailabilityResolver(
            inner: AvailabilityResolver(candidate: offered), locallyRead: locallyRead, allowFallback: allowFallback)
        let resolver: any BackupResourceResolving =
            composite
            ? CompositeBackupResourceResolver([.photoLibraryAsset: fallback]) : fallback
        let network = BackupNetworkBox(.unconstrained)
        let runner = availabilityRunner(clock: clock, resolver: resolver, network: network)
        let run = Task { await runner.runUntilDrained(mode: .eligibleOnly) }
        await locallyRead.arriveAndWait()
        XCTAssertEqual(fallback.requests, [false])
        XCTAssertEqual(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .checking)
        if permissionCloses { network.set(.init(isNetworkExpensive: true, usesMobileData: false)) }
        await allowFallback.arriveAndWait()
        let progress = await run.value
        XCTAssertEqual(fallback.requests, permissionCloses ? [false] : [false, true])
        XCTAssertEqual(progress.uploaded, permissionCloses ? 0 : 1)
        XCTAssertEqual(progress.needsAttention, 0)
        if permissionCloses {
            let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
            XCTAssertEqual(pending.state, .discovered)
            XCTAssertEqual(BackupIssueRecord.decode(pending.lastError)?.kind, .sourceMissing)
            XCTAssertEqual(BackupIssueRecord.decode(pending.lastError)?.automaticRetryAttempt, 0)
            XCTAssertEqual(progress.dismissedFailures, 1)
        } else {
            XCTAssertEqual(
                queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision)?.state, .completed)
            XCTAssertEqual(progress.dismissedFailures, 0)
        }
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    private final class NetworkFallbackAvailabilityResolver: BackupResourceResolving, @unchecked Sendable {
        let inner: AvailabilityResolver
        let locallyRead: UploadTestBarrier
        let allowFallback: UploadTestBarrier
        private let lock = NSLock()
        private var flags: [Bool] = []
        var requests: [Bool] { lock.withLock { flags } }

        init(inner: AvailabilityResolver, locallyRead: UploadTestBarrier, allowFallback: UploadTestBarrier) {
            self.inner = inner
            self.locallyRead = locallyRead
            self.allowFallback = allowFallback
        }

        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            try await resolve(entry, onPreparationProgress: { _ in }, readAdmission: {})
        }

        func resolve(
            _ entry: UploadBackupSyncQueueEntry, onPreparationProgress: @escaping BackupResourcePreparationHandler,
            readAdmission: @escaping @Sendable () throws -> Void
        ) async throws -> BackupResolvedResource? {
            let local = PhotoKitResourceRequestLivenessGuard<Int>(
                automaticallyStartsWatchdog: false, cancelRequest: { _ in })
            do {
                try await local.waitForCompletion {
                    self.lock.withLock { self.flags.append(false) }
                    local.complete(error: UploadError.sourceUnavailable("network access required"))
                    return 1
                }
                XCTFail("The local request must require the network fallback")
            } catch let error as UploadError {
                XCTAssertEqual(error, .sourceUnavailable("network access required"))
            }
            await locallyRead.arriveAndWait()
            await allowFallback.arriveAndWait()
            let network = PhotoKitResourceRequestLivenessGuard<Int>(
                automaticallyStartsWatchdog: false, requestAdmission: readAdmission, cancelRequest: { _ in })
            try await network.waitForCompletion {
                self.lock.withLock { self.flags.append(true) }
                network.complete(error: nil)
                return 2
            }
            return try await inner.resolve(entry)
        }
    }

    func testDismissedSourceRecheckReadinessLaterThanBackoffPreventsAnEarlyReadAcrossRelaunch() async throws {
        try await verifyDismissedSourceReadiness(previousAttempt: 0, readinessWait: 600)
    }

    func testDismissedSourceRecheckReadinessEarlierThanBackoffPreservesTheBackoffAcrossRelaunch() async throws {
        try await verifyDismissedSourceReadiness(previousAttempt: 10, readinessWait: 30)
    }

    private func verifyDismissedSourceReadiness(previousAttempt: Int, readinessWait: TimeInterval) async throws {
        let offered = try candidate("readiness-recheck")
        let clock = BackupTestClock()
        let retry = BackupRetryPolicy()
        let acknowledged = BackupIssueRecord(
            kind: .sourceMissing, detail: "acknowledged missing", automaticRetryAttempt: previousAttempt)
        try dismiss(offered, issue: acknowledged)
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let readyAt = clock.now.addingTimeInterval(readinessWait)
        let due = max(readyAt, clock.now.addingTimeInterval(retry.delay(afterAttempts: previousAttempt + 1)))
        let processing = AvailabilityResolver(
            candidate: offered, failure: UploadError.sourceNotReady("Photos still processing", until: readyAt))
        let progress = await availabilityRunner(clock: clock, resolver: processing).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(processing.calls, 1)
        XCTAssertEqual(progress.needsAttention, 0)
        XCTAssertEqual(progress.dismissedFailures, 1)
        let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        let savedReason = try XCTUnwrap(BackupIssueRecord.decode(pending.lastError))
        XCTAssertEqual(pending.state, .discovered)
        XCTAssertEqual(pending.updatedAt, due)
        XCTAssertEqual(savedReason.nextAttemptAt, due)
        XCTAssertEqual(savedReason.automaticRetryAttempt, previousAttempt + 1)
        XCTAssertEqual(savedReason.kind, acknowledged.kind)
        XCTAssertEqual(savedReason.detail, acknowledged.detail)
        try await assertDeferredDismissalPresentation(clock: clock, due: due)
        let metadata = UploadBackupAssetCandidate(
            snapshot: offered.snapshot, originalFilename: "changed-readiness.jpg", byteCount: 300)
        _ = try await engine(clock: clock).enqueueBatch([metadata])
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        closeStores()
        try openStores()
        _ = try await engine(clock: clock).enqueueBatch([metadata])
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        try await assertDeferredDismissalPresentation(clock: clock, due: due)
        clock.advance(by: due.timeIntervalSince(clock.now) - 0.25)
        let premature = AvailabilityResolver(candidate: offered)
        _ = await availabilityRunner(clock: clock, resolver: premature).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(premature.calls, 0, "Neither Photos readiness nor persisted backoff permits an earlier read")
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        clock.advance(by: 0.25)
        let returned = AvailabilityResolver(candidate: offered)
        let completed = await availabilityRunner(clock: clock, resolver: returned).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(returned.calls, 1)
        XCTAssertEqual(returned.cleanups, 1)
        XCTAssertEqual(completed.uploaded, 1)
        XCTAssertEqual(completed.needsAttention, 0)
        XCTAssertEqual(completed.dismissedFailures, 0)
        XCTAssertEqual(queue.summary().pendingSourceRechecks, 0)
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        let settled = try XCTUnwrap(queue.entry(for: pending.source, revision: pending.revision))
        XCTAssertEqual(settled.state, .completed)
        XCTAssertNil(settled.lastError)
    }

    func testDismissedSourceRecheckBackoffGrowsAcrossPhotosWaitsAndRelaunchWithoutChangingPresentation() async throws {
        let offered = try candidate("backed-off-recheck")
        let clock = BackupTestClock()
        let retry = BackupRetryPolicy()
        let acknowledged = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing")
        try dismiss(offered, issue: acknowledged)
        try await engine(clock: clock).enqueueChangedMissingSources([offered])
        let changedMetadata = UploadBackupAssetCandidate(
            snapshot: offered.snapshot, originalFilename: "changed-metadata.jpg", byteCount: 100)
        for attempt in 1...12 {
            let failure: any Error =
                attempt.isMultiple(of: 2)
                ? UploadError.sourceNotReady("still processing", until: clock.now.addingTimeInterval(600))
                : UploadError.sourceUnavailable("iCloud read interrupted")
            let availability = AvailabilityResolver(candidate: offered, failure: failure)
            let failedAt = clock.now
            let backoffDue = failedAt.addingTimeInterval(retry.delay(afterAttempts: attempt))
            let due = attempt.isMultiple(of: 2) ? max(backoffDue, failedAt.addingTimeInterval(600)) : backoffDue
            let progress = await availabilityRunner(clock: clock, resolver: availability).runUntilDrained(
                mode: .eligibleOnly)
            XCTAssertEqual(availability.calls, 1)
            let pending = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
            let issue = try XCTUnwrap(BackupIssueRecord.decode(pending.lastError))
            XCTAssertEqual(pending.state, .discovered)
            XCTAssertEqual(pending.attempts, 0)
            XCTAssertEqual(issue.kind, acknowledged.kind)
            XCTAssertEqual(issue.detail, acknowledged.detail)
            XCTAssertEqual(issue.automaticRetryAttempt, attempt)
            XCTAssertEqual(issue.nextAttemptAt, due)
            XCTAssertEqual(pending.updatedAt, due)
            XCTAssertEqual(progress.dismissedFailures, 1)
            XCTAssertEqual(progress.needsAttention, 0)
            XCTAssertEqual(progress.waiting, 0)
            try await assertDeferredDismissalPresentation(clock: clock, due: due)
            for _ in 0..<3 {
                _ = try await engine(clock: clock).enqueueBatch([changedMetadata])
                try await engine(clock: clock).enqueueChangedMissingSources([offered])
            }
            XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
            if attempt == 2 || attempt == 12 {
                closeStores()
                try openStores()
                XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
                try await assertDeferredDismissalPresentation(clock: clock, due: due)
            }
            clock.advance(by: due.timeIntervalSince(clock.now) - 0.25)
            let premature = AvailabilityResolver(candidate: offered)
            _ = await availabilityRunner(clock: clock, resolver: premature).runUntilDrained(mode: .eligibleOnly)
            XCTAssertEqual(premature.calls, 0, "No Photos read may run before the persisted due date")
            XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
            clock.advance(by: 0.25)
        }
        let returned = AvailabilityResolver(candidate: offered)
        let completed = await availabilityRunner(clock: clock, resolver: returned).runUntilDrained(mode: .eligibleOnly)
        XCTAssertEqual(returned.calls, 1)
        XCTAssertEqual(returned.cleanups, 1)
        XCTAssertEqual(completed.uploaded, 1)
        XCTAssertEqual(completed.dismissedFailures, 0)
        XCTAssertEqual(completed.needsAttention, 0)
        let settled = try XCTUnwrap(queue.entry(for: offered.snapshot.source, revision: offered.snapshot.revision))
        XCTAssertEqual(settled.state, .completed)
        XCTAssertNil(settled.lastError)
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        XCTAssertEqual(queue.summary().pendingSourceRechecks, 0)
    }

    func testDismissedSourceRecheckBackoffCountsOnlyAdmittedFailedReadsAndCapsItsOrdinal() async throws {
        let offered = try candidate("retry-ordinal-recheck")
        let clock = BackupTestClock()
        var pending = row(offered)
        pending.updatedAt = clock.now
        pending.lastError =
            BackupIssueRecord(
                kind: .sourceMissing, detail: "acknowledged missing", nextAttemptAt: clock.now,
                automaticRetryAttempt: 31
            ).persistedValue
        XCTAssertTrue(queue.upsert(pending))
        let network = BackupNetworkBox(.init(isNetworkExpensive: true, usesMobileData: false))
        let unread = AvailabilityResolver(candidate: offered)
        _ = await availabilityRunner(clock: clock, resolver: unread, network: network).runUntilDrained(
            mode: .eligibleOnly)
        XCTAssertEqual(unread.calls, 0)
        XCTAssertEqual(queue.entry(for: pending.source, revision: pending.revision), pending)
        network.set(.unconstrained)
        let queue = try XCTUnwrap(self.queue)
        queue.setChangeObserver { [pending] _ in
            if queue.entry(for: pending.source, revision: pending.revision)?.state == .checking {
                network.set(.init(isNetworkAvailable: false))
            }
        }
        _ = await availabilityRunner(clock: clock, resolver: unread, network: network).runUntilDrained(
            mode: .eligibleOnly)
        queue.setChangeObserver(nil)
        XCTAssertEqual(unread.calls, 0)
        var saved = try XCTUnwrap(queue.entry(for: pending.source, revision: pending.revision))
        XCTAssertEqual(BackupIssueRecord.decode(saved.lastError)?.automaticRetryAttempt, 31)
        network.set(.unconstrained)
        clock.advance(by: saved.updatedAt.timeIntervalSince(clock.now))
        let cancelled = AvailabilityResolver(candidate: offered, failure: CancellationError())
        _ = await availabilityRunner(clock: clock, resolver: cancelled, network: network).runUntilDrained(
            mode: .eligibleOnly)
        saved = try XCTUnwrap(queue.entry(for: pending.source, revision: pending.revision))
        XCTAssertEqual(cancelled.calls, 1)
        XCTAssertEqual(BackupIssueRecord.decode(saved.lastError)?.automaticRetryAttempt, 31)
        for _ in 0..<3 {
            clock.advance(by: saved.updatedAt.timeIntervalSince(clock.now))
            let failed = AvailabilityResolver(candidate: offered, failure: UploadError.sourceUnavailable("interrupted"))
            _ = await availabilityRunner(clock: clock, resolver: failed).runUntilDrained(mode: .eligibleOnly)
            saved = try XCTUnwrap(queue.entry(for: pending.source, revision: pending.revision))
            XCTAssertEqual(failed.calls, 1)
            XCTAssertEqual(BackupIssueRecord.decode(saved.lastError)?.automaticRetryAttempt, 32)
            XCTAssertEqual(saved.updatedAt, clock.now.addingTimeInterval(BackupRetryPolicy().maxDelay))
            XCTAssertEqual(BackupIssueRecord.decode(saved.lastError)?.nextAttemptAt, saved.updatedAt)
            XCTAssertEqual(saved.attempts, 0)
            try await assertDeferredDismissalPresentation(clock: clock, due: saved.updatedAt)
        }
    }

    private func assertDeferredDismissalPresentation(clock: BackupTestClock, due: Date) async throws {
        let projector = BackupStatusProjector(queue: queue, now: { clock.now })
        let generation = UUID()
        await projector.start(generation: generation, context: .init(), handler: { _ in })
        let projected = await projector.projectNow(context: .init(), generation: generation, revision: 1)
        await projector.stop()
        let projection = try XCTUnwrap(projected)
        XCTAssertEqual(projection.progress.total, 1)
        XCTAssertEqual(projection.progress.waiting, 0)
        XCTAssertEqual(projection.progress.dismissedFailures, 1)
        XCTAssertEqual(projection.progress.outstanding.count, 1)
        XCTAssertEqual(projection.progress.outstanding.nextAttemptAt, due)
        XCTAssertEqual(projection.status.needsAttentionCount, 0)
        XCTAssertEqual(projection.status.notBackedUpCount, 1)
        XCTAssertEqual(
            BackupAutomaticRetryPlanner.nextAttempt(
                outstandingCount: projection.progress.outstanding.count,
                queueDate: projection.progress.outstanding.nextAttemptAt,
                consecutiveNoProgressRuns: 16, now: clock.now, retryPolicy: BackupRetryPolicy()), due)
        var problems: [UploadBackupSyncQueueEntry] = []
        queue.forEachProblemEntry {
            problems.append($0)
            return true
        }
        XCTAssertTrue(problems.isEmpty)
        XCTAssertTrue(queue.unsettledRows().isEmpty)
    }

    private func availabilityRunner(
        clock: BackupTestClock, resolver: any BackupResourceResolving,
        network: BackupNetworkBox = BackupNetworkBox(.unconstrained),
        identityResolver: (any UploadIdentityResolving)? = nil,
        uploader: MockUploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false),
        resourceCoordinator: LibraryResourceCoordinator = .shared
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queue, preflight: UploadBackupPreflightIndex(store: state), resolver: resolver,
            identityResolver: identityResolver
                ?? UploadDedupePipeline(store: FakeIdentityStore(), hasher: FakeHasher(), checker: FakeChecker()),
            uploader: uploader,
            resourceCoordinator: resourceCoordinator, throttleInputs: { network.current }, clock: clock,
            now: { clock.now })
    }

    private func dismiss(_ candidate: UploadBackupAssetCandidate, issue: BackupIssueRecord?) throws {
        XCTAssertTrue(queue.upsert(row(candidate, state: .sourceMissing)))
        XCTAssertTrue(
            queue.updateState(
                source: candidate.snapshot.source, revision: candidate.snapshot.revision,
                state: .sourceMissing, attempts: 0, lastError: issue?.persistedValue,
                updatedAt: Date(timeIntervalSince1970: 300)))
        XCTAssertTrue(
            queue.dismissPermanentFailure(
                source: candidate.snapshot.source, revision: candidate.snapshot.revision,
                updatedAt: Date(timeIntervalSince1970: 301)))
    }

    private final class AvailabilityResolver: BackupResourceResolving, @unchecked Sendable {
        let candidate: UploadBackupAssetCandidate
        let missing: Bool
        let returnsNil: Bool
        let digest: Data?
        let failure: (any Error)?
        let beforeResult: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var callCount = 0
        private var cleanupCount = 0
        var calls: Int { lock.withLock { callCount } }
        var cleanups: Int { lock.withLock { cleanupCount } }

        init(
            candidate: UploadBackupAssetCandidate, missing: Bool = false, returnsNil: Bool = false,
            digest: Data? = Data(repeating: 1, count: 20), failure: (any Error)? = nil,
            beforeResult: (@Sendable () -> Void)? = nil
        ) {
            self.candidate = candidate
            self.missing = missing
            self.returnsNil = returnsNil
            self.digest = digest
            self.failure = failure
            self.beforeResult = beforeResult
        }

        func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
            lock.withLock { callCount += 1 }
            beforeResult?()
            if missing { throw UploadError.sourceReportedMissing(entry.originalFilename) }
            if let failure { throw failure }
            if returnsNil { return nil }
            return BackupResolvedResource(
                candidate: candidate,
                descriptor: UploadResourceDescriptor(
                    source: entry.source, fileURL: URL(fileURLWithPath: "/synthetic/available.jpg"),
                    filename: entry.originalFilename, fileSize: 1, modificationDate: Date(timeIntervalSince1970: 200),
                    precomputedSHA1Digest: digest),
                mediaType: "image/jpeg", captureDate: Date(timeIntervalSince1970: 100),
                cleanup: { self.lock.withLock { self.cleanupCount += 1 } })
        }
    }

    func testAnAbsentDiscardDoesNotRequestAnotherSweep() throws {
        let candidate = try candidate("absent")
        XCTAssertFalse(
            queue.removeMissingSource(source: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        XCTAssertTrue(queue.upsert(row(candidate)))
        XCTAssertTrue(
            queue.removeMissingSource(source: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 1)
        XCTAssertFalse(
            queue.removeMissingSource(source: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 1)
    }

    private func runner(
        clock: BackupTestClock, resolver: ScriptedBackupResolver,
        markSourceUnavailable: (@Sendable (UploadSourceIdentity) -> Bool)? = nil
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queue, preflight: UploadBackupPreflightIndex(store: state), resolver: resolver,
            identityResolver: UploadDedupePipeline(
                store: FakeIdentityStore(), hasher: FakeHasher(), checker: FakeChecker()),
            uploader: MockUploader(workDuration: .milliseconds(1), deliverProgress: false),
            markSourceUnavailable: markSourceUnavailable,
            clock: clock, now: { clock.now })
    }

    /// The catalog hook as the photo library backup wires it.
    private func catalogRecordsUnavailableSources() -> @Sendable (UploadSourceIdentity) -> Bool {
        let catalog = self.catalog!
        return { catalog.recordUnavailableSource($0, at: Date()) }
    }

    private struct ChangedEnumerator: PhotoLibraryAssetEnumerator {
        let info: PhotoBackupAssetInfo
        func infoChunks(
            identifiers: [String]?, startOffset: Int, chunkSize: Int
        ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield([info])
                continuation.finish()
            }
        }
    }

    func testCancelledSweepResumesAfterItsDurablePageAndDoesNotLoseALaterDropBehindTheCursor() async throws {
        let a = try candidate("A")
        _ = try candidate("B")
        _ = try candidate("C")
        let first = PageEnqueuer(inner: engine(), cancelAfterPage: 1)
        let interruptedCatalog = try XCTUnwrap(catalog)
        do {
            try await Task {
                try await PhotoLibraryCatalogSync(store: interruptedCatalog, chunkSize: 1).reconcileMissingSources(
                    engine: first)
            }.value
            XCTFail("The interrupted sweep must stop")
        } catch is CancellationError {}
        XCTAssertEqual(catalog.missingSourceSweepProgress()?.afterLocalIdentifier, "A")
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        XCTAssertTrue(queue.removeMissingSource(source: a.snapshot.source, revision: a.snapshot.revision))
        closeStores()
        try openStores()
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 1)
        let resumed = PageEnqueuer(inner: engine())
        let sync = PhotoLibraryCatalogSync(store: catalog, chunkSize: 1)
        try await sync.reconcileMissingSources(engine: resumed)
        XCTAssertEqual(resumed.firstIdentifiers, ["B", "C"])
        XCTAssertEqual(catalog.reconciledMissingSourceGeneration(), 0)
        XCTAssertNil(catalog.missingSourceSweepProgress())
        try await sync.reconcileMissingSources(engine: resumed)
        XCTAssertEqual(resumed.firstIdentifiers, ["B", "C", "A", "B", "C"])
        XCTAssertNotNil(queue.entry(for: a.snapshot.source, revision: a.snapshot.revision))
        XCTAssertEqual(catalog.reconciledMissingSourceGeneration(), 1)
        XCTAssertEqual(queue.count(), 3)
    }

    func testAFailedInsertDoesNotAdvanceThePageAndRelaunchRetriesIt() async throws {
        let candidate = try candidate("missing")
        try sql(
            url(UploadBackupSyncQueueManifestStore.databaseFileName),
            """
            CREATE TRIGGER deny_insert BEFORE INSERT ON backup_sync_queue
            BEGIN SELECT RAISE(ABORT, 'write unavailable'); END;
            """)
        do {
            try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
            XCTFail("A failed queue insert must stop the sweep")
        } catch {}
        XCTAssertNil(catalog.missingSourceSweepProgress()?.afterLocalIdentifier)
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        closeStores()
        try sql(url(UploadBackupSyncQueueManifestStore.databaseFileName), "DROP TRIGGER deny_insert;")
        try openStores()
        try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
        XCTAssertNotNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
    }

    func testUnreadableExclusionsOrStateKeepTheSweepPending() async throws {
        _ = try candidate("missing")
        exclusions.close()
        do {
            try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
            XCTFail("Unknown exclusions must stop recovery")
        } catch {}
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        XCTAssertEqual(queue.count(), 0)
        closeStores()
        try openStores()
        state.close()
        do {
            try await PhotoLibraryCatalogSync(store: catalog).reconcileMissingSources(engine: engine())
            XCTFail("Unknown backup state must stop recovery")
        } catch {}
        XCTAssertNil(catalog.reconciledMissingSourceGeneration())
        XCTAssertEqual(queue.count(), 0)
    }

    func testConditionalInsertKeepsAQueueRowAddedBeforeTheRecoveryWrite() throws {
        let candidate = try candidate("existing")
        var newer = row(candidate, state: .skippedRemoteDeletion)
        newer.revision = UploadBackupRevision(rawValue: candidate.snapshot.revision.rawValue + 1)
        newer.lastError = "kept user decision"
        XCTAssertTrue(queue.upsert(newer))
        XCTAssertTrue(queue.insertMissingSources([row(candidate)]))
        XCTAssertEqual(queue.count(), 1)
        XCTAssertEqual(queue.entry(for: newer.source, revision: newer.revision), newer)
        XCTAssertNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
    }

    func testFailedDiscardGenerationWriteRollsBackTheRemoval() throws {
        let candidate = try candidate("missing")
        XCTAssertTrue(queue.upsert(row(candidate)))
        try sql(
            url(UploadBackupSyncQueueManifestStore.databaseFileName),
            """
            CREATE TRIGGER deny_generation BEFORE INSERT ON backup_sync_queue_info
            WHEN NEW.key='missing_source_discard_generation'
            BEGIN SELECT RAISE(ABORT, 'write unavailable'); END;
            """)
        XCTAssertFalse(
            queue.removeMissingSource(source: candidate.snapshot.source, revision: candidate.snapshot.revision))
        queue.close()
        // Remove the injected trigger before the exact-schema store opens again.
        try sql(url(UploadBackupSyncQueueManifestStore.databaseFileName), "DROP TRIGGER deny_generation;")
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: url(UploadBackupSyncQueueManifestStore.databaseFileName)))
        XCTAssertNotNil(queue.entry(for: candidate.snapshot.source, revision: candidate.snapshot.revision))
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
    }

    @MainActor
    func testA100000PhotoLibraryUsesBoundedPagesOffTheMainThread() async throws {
        for start in stride(from: 0, to: 100_000, by: 200) {
            let candidates = try (start..<min(start + 200, 100_000)).map {
                try candidate(String(format: "%06d", $0), save: false)
            }
            let entries = candidates.map { candidate in
                // The catalog input uses the same plain metadata as the planner, without PhotoKit.
                PhotoLibraryCatalogEntry(
                    localIdentifier: candidate.snapshot.source.identifier,
                    creationDate: Date(timeIntervalSince1970: 100),
                    modificationDate: Date(timeIntervalSince1970: 200), pixelWidth: 10, pixelHeight: 10,
                    durationSeconds: 0, mediaKind: .image, isLivePhoto: false,
                    resources: [
                        .init(
                            role: "originalPhoto", originalFilename: candidate.originalFilename, mimeType: "image/jpeg")
                    ],
                    contentFingerprint: 0, metadataRevision: candidate.snapshot.revision.rawValue,
                    firstSeenAt: Date(), lastSeenAt: Date())
            }
            XCTAssertTrue(catalog.upsertBatch(entries))
            XCTAssertTrue(
                state.upsertBatch(
                    candidates.filter {
                        $0.snapshot.source.identifier != "000000" && $0.snapshot.source.identifier != "099999"
                    }.map {
                        UploadBackupAssetRecord(
                            source: $0.snapshot.source, revision: $0.snapshot.revision,
                            resourceCount: 1, pendingResourceCount: 0, updatedAt: Date())
                    }))
        }
        let tracked = PageCatalog(inner: catalog)
        let enqueuer = PageEnqueuer(inner: engine())
        try await PhotoLibraryCatalogSync(store: tracked, chunkSize: 200).reconcileMissingSources(engine: enqueuer)
        XCTAssertEqual(tracked.pages, 501)
        XCTAssertEqual(tracked.maximumPageSize, 200)
        XCTAssertFalse(tracked.usedMainThread)
        XCTAssertEqual(enqueuer.firstIdentifiers.count, 500)
        XCTAssertEqual(queue.count(), 2)
        XCTAssertEqual(queue.nextRunnable(limit: 2).map(\.source.identifier).sorted(), ["000000", "099999"])
    }

    private func sql(_ url: URL, _ statement: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, statement, nil, nil, nil), SQLITE_OK)
    }

    private final class ProofSpy: UploadIdentityResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        private var primed: [UploadSourceIdentity] = []
        var primedSources: [UploadSourceIdentity] { lock.withLock { primed } }
        func prime(_ descriptors: [UploadResourceDescriptor]) async {
            lock.withLock { primed.append(contentsOf: descriptors.map(\.source)) }
        }
        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw UploadError.backend("Unexpected byte read")
        }
        func remoteAssetProofs(
            for identities: [UploadBackupExternalIdentity]
        ) async throws
            -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
        {
            lock.withLock { count += 1 }
            return [:]
        }
        func recordUploaded(
            _ descriptor: UploadResourceDescriptor, identity: UploadIdentity,
            remoteVolumeID: String, remoteLinkID: String
        ) async throws {}
    }

    private final class PageEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        let inner: UploadBackupSyncEngine
        let cancelAfterPage: Int?
        private let lock = NSLock()
        private var identifiers: [String] = []
        var firstIdentifiers: [String] { lock.withLock { identifiers } }
        init(inner: UploadBackupSyncEngine, cancelAfterPage: Int? = nil) {
            self.inner = inner
            self.cancelAfterPage = cancelAfterPage
        }
        func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
            XCTFail("Recovery must use the local-only batch path")
            return UploadBackupSyncScanResult()
        }
        func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
            try await inner.enqueueMissingSources(candidates)
            let count = lock.withLock {
                identifiers.append(candidates.first?.snapshot.source.identifier ?? "")
                return identifiers.count
            }
            if count == cancelAfterPage { withUnsafeCurrentTask { $0?.cancel() } }
        }
        func missingSourceDiscardGeneration() async throws -> Int64 { try await inner.missingSourceDiscardGeneration() }
        func synchronizeQueueToDisk() async -> Bool { await inner.synchronizeQueueToDisk() }
    }

    private final class PageCatalog: PhotoLibraryCatalogStore, @unchecked Sendable {
        let inner: PhotoLibraryCatalogManifestStore
        private let lock = NSLock()
        private var metrics = (pages: 0, maximum: 0, main: false)
        var pages: Int { lock.withLock { metrics.pages } }
        var maximumPageSize: Int { lock.withLock { metrics.maximum } }
        var usedMainThread: Bool { lock.withLock { metrics.main } }
        init(inner: PhotoLibraryCatalogManifestStore) { self.inner = inner }
        func presentEntries(afterLocalIdentifier: String?, limit: Int) -> [PhotoLibraryCatalogEntry] {
            let page = inner.presentEntries(afterLocalIdentifier: afterLocalIdentifier, limit: limit)
            lock.withLock {
                metrics.pages += 1
                metrics.maximum = max(metrics.maximum, page.count)
                metrics.main = metrics.main || Thread.isMainThread
            }
            return page
        }
        func isOperational() -> Bool { inner.isOperational() }
        func reconciledMissingSourceGeneration() -> Int64? { inner.reconciledMissingSourceGeneration() }
        func missingSourceSweepProgress() -> PhotoLibraryMissingSourceSweepProgress? {
            inner.missingSourceSweepProgress()
        }
        func recordMissingSourceSweepProgress(_ p: PhotoLibraryMissingSourceSweepProgress) -> Bool {
            inner.recordMissingSourceSweepProgress(p)
        }
        func completeMissingSourceSweep(generation: Int64) -> Bool {
            inner.completeMissingSourceSweep(generation: generation)
        }
        func entry(for id: String) -> PhotoLibraryCatalogEntry? { inner.entry(for: id) }
        func classify(_ e: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange { inner.classify(e) }
        func upsert(_ e: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange { inner.upsert(e) }
        func upsertBatch(_ e: [PhotoLibraryCatalogEntry]) -> Bool { inner.upsertBatch(e) }
        func markRemoved(_ ids: [String], removedAt: Date) -> PhotoLibraryCatalogMutationResult {
            inner.markRemoved(ids, removedAt: removedAt)
        }
        func sweepRemoved(notSeenAfter: Date, removedAt: Date) -> PhotoLibraryCatalogMutationResult {
            inner.sweepRemoved(notSeenAfter: notSeenAfter, removedAt: removedAt)
        }
        func snapshot() -> PhotoLibraryCatalogSnapshot { inner.snapshot() }
        func count() -> Int { inner.count() }
        func hasCompletedFullScan() -> Bool { inner.hasCompletedFullScan() }
        func markFullScanOwed() -> Bool { inner.markFullScanOwed() }
        func synchronizeToDisk() -> Bool { inner.synchronizeToDisk() }
        func fullScanProgress() -> PhotoLibraryFullScanProgress? { inner.fullScanProgress() }
        func recordFullScanProgress(_ p: PhotoLibraryFullScanProgress) -> Bool { inner.recordFullScanProgress(p) }
        func completeFullScan() -> Bool { inner.completeFullScan() }
        func clearFullScanResumePoint() -> Bool { inner.clearFullScanResumePoint() }
        func hasReconciledLateRenders() -> Bool { inner.hasReconciledLateRenders() }
        func markLateRendersReconciled() -> Bool { inner.markLateRendersReconciled() }
        func lateRenderSweepResumePoint() -> String? { inner.lateRenderSweepResumePoint() }
        func recordLateRenderSweepResumePoint(_ id: String) -> Bool { inner.recordLateRenderSweepResumePoint(id) }
        func beginFullScanSnapshot(epochStart: Date) -> Bool { inner.beginFullScanSnapshot(epochStart: epochStart) }
        func appendFullScanSnapshotIdentifiers(_ ids: [String]) -> Bool { inner.appendFullScanSnapshotIdentifiers(ids) }
        func finishFullScanSnapshot() -> Bool { inner.finishFullScanSnapshot() }
        func fullScanSnapshotIdentifiers(startingAt: Int, limit: Int) -> [String] {
            inner.fullScanSnapshotIdentifiers(startingAt: startingAt, limit: limit)
        }
        func fullScanSnapshotCount() -> Int { inner.fullScanSnapshotCount() }
    }
}
