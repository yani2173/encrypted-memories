import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// A failed catalog read never means absent, complete, removed or inaccessible (#1004). Each test drives the real
/// catalog store through its production consumer: the catalog sync, the pending metadata provider and the pending
/// coordinator.
final class CatalogReadFailClosedTests: XCTestCase {
    private var directory: URL!
    private var closers: [() async -> Void] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-fail-closed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for close in closers.reversed() { await close() }
        closers.removeAll()
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCatalog() throws -> PhotoLibraryCatalogManifestStore {
        let store = try XCTUnwrap(
            PhotoLibraryCatalogManifestStore(
                url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        closers.append { store.close() }
        return store
    }

    private func photo(_ id: String, modified: TimeInterval = 1_700_000_100) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: modified), pixelWidth: 10, pixelHeight: 10,
            durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic")])
    }

    /// An edit that lists its rendered file next to the original.
    private func edit(_ id: String, modified: TimeInterval = 1_700_000_100) -> PhotoBackupAssetInfo {
        var info = photo(id, modified: modified)
        info.resources.append(
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.JPG", mimeType: "image/jpeg"))
        return info
    }

    private func entry(_ info: PhotoBackupAssetInfo, at seconds: TimeInterval = 100) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date(timeIntervalSince1970: seconds))
    }

    private func sync(
        _ store: PhotoLibraryCatalogManifestStore, infos: [PhotoBackupAssetInfo] = [], at seconds: TimeInterval = 100,
        chunkSize: Int = 10
    ) -> PhotoLibraryCatalogSync {
        PhotoLibraryCatalogSync(
            store: store, enumerator: Enumerator(infos: infos), chunkSize: chunkSize,
            now: { Date(timeIntervalSince1970: seconds) })
    }

    /// An identifier longer than the length limit that `LengthLimitAfterWrite` sets.
    private let longIdentifier = "m" + String(repeating: "x", count: 600)

    // MARK: - Full scan (H1-H3): hazards that appear once recovery clears a transient failure

    func testAFailedSnapshotCountNeverSweepsTheLibraryOrCompletesTheScan() async throws {
        let store = try makeCatalog()
        let infos = ["a", "b", "c"].map { photo($0) }
        _ = try await sync(store, infos: infos, at: 100).run(engine: Enqueuer())
        XCTAssertTrue(store.markFullScanOwed(), "a rescan is owed again")

        // The snapshot append reads the count first; the second count is the one that sizes the scan.
        let fault = try SQLiteReadInterrupt(
            in: store, matching: "SELECT COUNT(*) FROM photo_full_scan_snapshot", occurrence: 2)
        do {
            _ = try await sync(store, infos: infos, at: 200).run(engine: Enqueuer())
            XCTFail("an unknown snapshot size must stop the scan")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        for id in ["a", "b", "c"] {
            XCTAssertEqual(try store.entry(for: id)?.isRemoved, false, "an unknown count must not sweep \(id)")
        }
        XCTAssertFalse(store.hasCompletedFullScan(), "an unknown count must not complete the owed scan")
    }

    func testAFailedSnapshotPageKeepsTheResumePoint() async throws {
        let store = try makeCatalog()
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT local_id FROM photo_full_scan_snapshot")
        do {
            _ = try await sync(store, infos: ["a", "b", "c"].map { photo($0) }).run(engine: Enqueuer())
            XCTFail("an unknown snapshot page must stop the scan")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertEqual(try store.fullScanProgress()?.cursor, 0, "an unknown page keeps the epoch and its cursor")
        XCTAssertEqual(store.fullScanSnapshotCount(), 3, "an unknown page keeps the saved snapshot")
    }

    func testAFailedResumeReadKeepsTheInterruptedScanEpoch() async throws {
        let store = try makeCatalog()
        let epoch = PhotoLibraryFullScanProgress(epochStart: Date(timeIntervalSince1970: 100), cursor: 1)
        XCTAssertTrue(store.beginFullScanSnapshot(epochStart: epoch.epochStart))
        XCTAssertTrue(store.appendFullScanSnapshotIdentifiers(["a", "b", "c"]))
        XCTAssertTrue(store.finishFullScanSnapshot())
        XCTAssertTrue(store.recordFullScanProgress(epoch))

        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT value FROM photo_catalog_info WHERE key=?")
        do {
            _ = try await sync(store, infos: ["a", "b", "c"].map { photo($0) }, at: 200).run(engine: Enqueuer())
            XCTFail("an unknown resume point must stop the scan")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertEqual(try store.fullScanProgress(), epoch, "an unknown resume point must not start a new epoch")
    }

    // MARK: - Sweeps (H4, H5): a failed cursor bind exists today

    func testAFailedLateRenderCursorBindNeverCompletesThePass() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", longIdentifier, "z"].map { entry(edit($0)) }))
        let limit = try LengthLimitAfterWrite(in: store, marker: longIdentifier, limit: 400)
        let engine = Enqueuer()
        do {
            try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: engine)
            XCTFail("an unknown page must stop the pass")
        } catch {}
        let applied = limit.remove()

        XCTAssertLessThan(try XCTUnwrap(applied), Int32(longIdentifier.utf8.count), "the next cursor bind fails")
        XCTAssertFalse(store.hasReconciledLateRenders(), "the page after the failed bind is still unchecked")
        XCTAssertEqual(engine.reopened, ["a", longIdentifier])
    }

    func testAFailedMissingSourceCursorBindNeverCompletesTheSweep() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", longIdentifier, "z"].map { entry(photo($0)) }))
        let limit = try LengthLimitAfterWrite(in: store, marker: longIdentifier, limit: 400)
        let engine = Enqueuer()
        do {
            try await sync(store, chunkSize: 1).reconcileMissingSources(engine: engine)
            XCTFail("an unknown page must stop the sweep")
        } catch {}
        let applied = limit.remove()

        XCTAssertLessThan(try XCTUnwrap(applied), Int32(longIdentifier.utf8.count), "the next cursor bind fails")
        XCTAssertNotEqual(
            store.reconciledMissingSourceGeneration(), Enqueuer.generation,
            "the page after the failed bind is still unchecked")
        XCTAssertEqual(engine.recovered, ["a", longIdentifier])
    }

    func testAnUnknownLateRenderPageNeverCompletesThePass() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(edit($0)) }))
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT local_id, cloud_id", occurrence: 2)
        do {
            try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: Enqueuer())
            XCTFail("an unknown page must stop the pass")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertFalse(store.hasReconciledLateRenders(), "an unknown page is not the end of the catalog")
    }

    func testAnUnknownMissingSourcePageNeverCompletesTheSweep() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(photo($0)) }))
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT local_id, cloud_id", occurrence: 2)
        do {
            try await sync(store, chunkSize: 1).reconcileMissingSources(engine: Enqueuer())
            XCTFail("an unknown page must stop the sweep")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertNotEqual(
            store.reconciledMissingSourceGeneration(), Enqueuer.generation,
            "an unknown page is not the end of the catalog")
    }

    // MARK: - Short classification (#1161)

    /// After a transient read failure the batch classification answers shorter, and the probe clears the failure.
    /// The scan must stop before it records the observation, so the next scan still enqueues the new photo.
    func testAShortClassificationStopsTheScanBeforeItRecordsTheObservation() async throws {
        let store = try makeCatalog()
        let engine = Enqueuer()
        let fault = try SQLiteReadInterrupt(
            in: store, matching: "SELECT content_fingerprint, metadata_revision, is_removed FROM photo_catalog")
        do {
            _ = try await sync(store, infos: [photo("a")]).run(engine: engine, identifiers: ["a"])
            XCTFail("a short classification must stop the chunk")
        } catch let error as UploadError {
            XCTAssertEqual(error, .backend("Photo library catalog classification was incomplete"))
        }
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertTrue(store.isOperational(), "the probe clears the transient interrupt")
        XCTAssertNil(try store.entry(for: "a"), "the catalog records no observation that no classification covered")
        XCTAssertTrue(engine.enqueued.isEmpty)

        _ = try await sync(store, infos: [photo("a")]).run(engine: engine, identifiers: ["a"])
        XCTAssertEqual(engine.enqueued, ["a"], "the next scan classifies and enqueues the photo")
    }

    // MARK: - Late render (H6)

    func testAFailedStoredEntryReadNeverSkipsALateRenderReopening() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch([entry(photo("a"))]))
        let engine = Enqueuer()
        // Photos now lists the rendered file of "a": classification reads first, then the stored row.
        let fault = try SQLiteReadInterrupt(in: store, matching: "FROM photo_catalog WHERE local_id=?", occurrence: 2)
        do {
            _ = try await sync(store, infos: [edit("a", modified: 1_700_000_200)], at: 200)
                .run(engine: engine, identifiers: ["a"])
            XCTFail("an unknown stored row must stop the chunk")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        let stored = try XCTUnwrap(store.entry(for: "a"))
        XCTAssertFalse(
            PhotoBackupAssetPlanner.listsRender(PhotoLibraryCatalogMapper.info(for: stored)),
            "the catalog must not record the render that no reopening covered")
        XCTAssertTrue(engine.enqueued.isEmpty)
    }

    // MARK: - Binding results (H8)

    func testAFailedRemovalBindReportsAFailedRemoval() throws {
        let store = try makeCatalog()
        try setLengthLimit(400, on: store)
        let result = store.markRemoved([longIdentifier], removedAt: Date())
        XCTAssertFalse(result.succeeded, "an unbound identifier matches no row; that is no removal")
        XCTAssertFalse(store.isOperational())
    }

    func testAFailedIdentifierBindWritesNoCatalogRow() throws {
        let store = try makeCatalog()
        try setLengthLimit(400, on: store)
        var unbound = photo(longIdentifier)
        unbound.resources[0].originalFilename = "IMG_LONG.HEIC"
        XCTAssertFalse(store.upsertBatch([entry(unbound)]), "an unbound identifier is no observation")
        try setLengthLimit(1_000_000, on: store)
        XCTAssertEqual(store.count(), 0, "no row without an identifier")
    }

    // The missing-source info keys are longer than the effective length floor of 30 bytes: 31
    // (`missing_source_sweep_generation`), 33 (`missing_source_sweep_resume_point`) and 36
    // (`reconciled_missing_source_generation`). An unbound key would write or delete under a NULL key and report
    // success. `KeyBindFailureAfterBegin` fails only the first bind after the transaction starts.

    func testAFailedCursorKeyBindSavesNoSweepProgress() throws {
        let store = try makeCatalog()
        let fault = try KeyBindFailureAfterBegin(in: store)
        let progress = PhotoLibraryMissingSourceSweepProgress(generation: 1, afterLocalIdentifier: "a")
        XCTAssertFalse(store.recordMissingSourceSweepProgress(progress), "the cursor key did not bind")
        XCTAssertTrue(fault.remove(), "the cursor write was the only statement under the limit")
        XCTAssertNil(store.missingSourceSweepProgress(), "nothing of the refused progress was saved")
    }

    func testAFailedCompletionKeyBindLeavesTheSweepOwed() throws {
        let store = try makeCatalog()
        let fault = try KeyBindFailureAfterBegin(in: store)
        XCTAssertFalse(store.completeMissingSourceSweep(generation: 1), "the completion key did not bind")
        XCTAssertTrue(fault.remove(), "the completion write was the only statement under the limit")
        XCTAssertNil(store.reconciledMissingSourceGeneration(), "the sweep is still owed")
    }

    func testAFailedDeletionKeyBindKeepsTheSavedCursor() throws {
        let store = try makeCatalog()
        let saved = PhotoLibraryMissingSourceSweepProgress(generation: 1, afterLocalIdentifier: "a")
        XCTAssertTrue(store.recordMissingSourceSweepProgress(saved))
        let fault = try KeyBindFailureAfterBegin(in: store)
        // A new sweep without a cursor deletes the saved one first; that deletion cannot bind its key.
        XCTAssertFalse(
            store.recordMissingSourceSweepProgress(PhotoLibraryMissingSourceSweepProgress(generation: 2)),
            "the cursor key of the deletion did not bind")
        XCTAssertTrue(fault.remove(), "the deletion was the only statement under the limit")
        XCTAssertEqual(store.missingSourceSweepProgress(), saved, "the refused change kept the saved progress")
    }

    private func setLengthLimit(_ limit: Int32, on store: PhotoLibraryCatalogManifestStore) throws {
        let connection = try storeConnection(store)
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
        let effective = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1) }
        XCTAssertEqual(effective, limit, "the effective limit is the requested one")
    }

    // MARK: - Pending grid (H7, row 11)

    private func makeCoordinator(
        catalog: PhotoLibraryCatalogManifestStore
    ) throws -> (PendingBackupCoordinator, UploadBackupSyncQueueManifestStore) {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let pending = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
        let recorder = PendingBackupEventRecorder(
            store: pending, replacementLedger: .shared(accountDataDirectory: directory), now: { Date() })
        let coordinator = PendingBackupCoordinator(
            store: pending, queues: [.photoLibraryAsset: queue],
            metadataProvider: PhotoLibraryPendingMetadataProvider(catalog: catalog), effects: InertPendingEffects(),
            recorder: recorder,
            configuration: .init(
                membershipInterval: .zero, progressInterval: .milliseconds(1), libraryChangeDelay: .zero))
        closers.append {
            await coordinator.close()
            recorder.finish()
            queue.close()
            pending.close()
        }
        return (coordinator, queue)
    }

    private func queueRow(
        _ id: String, state: UploadBackupSyncQueueState = .queuedForUpload
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
            revision: UploadBackupRevision(rawValue: 9), originalFilename: "IMG_\(id).HEIC", state: state,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Breaks the resources of one catalog row on the store's own connection; the other rows stay readable.
    private func corrupt(_ id: String, in catalog: PhotoLibraryCatalogManifestStore, repair: Bool = false) throws {
        try SerializedImageMutation.install(on: storeConnection(catalog)) { image in
            let healthy = Array("\"IMG_\(id).HEIC\"".utf8)
            var broken = healthy
            broken[0] = UInt8(ascii: "!")
            let range = try XCTUnwrap(image.firstRange(of: repair ? broken : healthy))
            image[range.lowerBound] = repair ? healthy[0] : broken[0]
        }
    }

    private func waitFor(
        _ coordinator: PendingBackupCoordinator, _ description: String,
        _ predicate: @escaping (PendingBackupSnapshot) -> Bool
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

    func testAnUnrelatedUndecodableCatalogRowKeepsHealthyPendingTilesVisible() async throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(catalog.upsertBatch(["known", "broken"].map { entry(photo($0)) }))
        let (coordinator, queue) = try makeCoordinator(catalog: catalog)
        XCTAssertTrue(queue.upsert(queueRow("known")))
        XCTAssertTrue(queue.upsert(queueRow("broken")))
        try corrupt("broken", in: catalog)

        await coordinator.start()

        let tiles = await coordinator.currentSnapshot().tiles.map(\.key.identifier)
        XCTAssertEqual(tiles, ["known"], "only the undecodable row is unknown; the healthy row keeps its tile")
    }

    /// Each photo is its own read, whatever the request order: only the undecodable row is unknown, a healthy row
    /// keeps its metadata, and a photo without a row is neither (#1004 row 11).
    func testAnUndecodableRowLeavesEveryOtherPendingAnswerKnown() async throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(catalog.upsertBatch(["known", "broken"].map { entry(photo($0)) }))
        try corrupt("broken", in: catalog)
        let provider = PhotoLibraryPendingMetadataProvider(catalog: catalog)
        let key = { PendingSourceKey(kind: .photoLibraryAsset, identifier: $0) }
        for order in [["broken", "known", "absent"], ["known", "absent", "broken"]] {
            let answer = await provider.metadataAnswer(for: order.map(key))
            XCTAssertEqual(Set(answer.metadata.keys), [key("known")], "order \(order)")
            XCTAssertEqual(answer.unknown, [key("broken")], "order \(order)")
        }
    }

    func testAnUnknownCatalogReadNeverMarksThePendingSourceInaccessible() async throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(catalog.upsertBatch([entry(photo("flaky"))]))
        let (coordinator, queue) = try makeCoordinator(catalog: catalog)
        XCTAssertTrue(queue.upsert(queueRow("flaky")))
        try corrupt("flaky", in: catalog)
        await coordinator.start()
        let hidden = await coordinator.currentSnapshot().tiles
        XCTAssertTrue(hidden.isEmpty, "fixture: the unknown row has no metadata yet")

        try corrupt("flaky", in: catalog, repair: true)
        XCTAssertTrue(
            queue.updateState(
                source: queueRow("flaky").source, revision: queueRow("flaky").revision, state: .uploading,
                attempts: nil, lastError: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_001)))

        _ = await waitFor(coordinator, "the next event reads the unknown row again and shows its tile") {
            $0.tiles.map(\.key.identifier) == ["flaky"]
        }
    }

    func testAnUnknownCatalogReadKeepsExcludedPhotosListed() async throws {
        let catalog = try makeCatalog()
        let ids = ["kept", "broken", "deleted"]
        XCTAssertTrue(catalog.upsertBatch(ids.map { entry(photo($0)) }))
        let (coordinator, queue) = try makeCoordinator(catalog: catalog)
        for id in ids { XCTAssertTrue(queue.upsert(queueRow(id))) }
        await coordinator.start()
        let uids = ids.map { PhotoUID(localPending: .photoLibrary, identifier: $0) }
        _ = await coordinator.exclude(uids)
        let listed = await coordinator.currentSnapshot().excludedTiles.map(\.key.identifier)
        XCTAssertEqual(Set(listed), Set(ids), "fixture: all three are listed")

        XCTAssertTrue(catalog.markRemoved(["deleted"], removedAt: Date()).succeeded)
        try corrupt("broken", in: catalog)
        await coordinator.noteLibraryChanged()

        let snapshot = await waitFor(coordinator, "the certified absent photo leaves the list") {
            !$0.excludedTiles.contains { $0.key.identifier == "deleted" }
        }
        let remaining = Set(snapshot.excludedTiles.map(\.key.identifier))
        XCTAssertTrue(remaining.contains("kept"), "a healthy row stays listed after an unrelated decode failure")
        XCTAssertTrue(remaining.contains("broken"), "an unknown read keeps the earlier answer")
    }

    // MARK: - B2c: recovery from transient catalog failures

    /// A transient failure stops only the read that hit it. Once the database answers, the next scan runs and
    /// completes.
    func testATransientCatalogFailureDoesNotStopTheNextScan() async throws {
        let store = try makeCatalog()
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT COUNT(*) FROM photo_catalog;")
        XCTAssertNil(store.count(), "the interrupted read is unknown")
        fault.stop()
        XCTAssertTrue(fault.fired)

        do {
            _ = try await sync(store, infos: ["a", "b"].map { photo($0) }).run(engine: Enqueuer())
        } catch {
            XCTFail("the next scan runs once the database answers: \(error)")
        }
        XCTAssertTrue(store.hasCompletedFullScan(), "the next scan completes")
        XCTAssertEqual(try store.entry(for: "a")?.isRemoved, false)
        XCTAssertEqual(try store.entry(for: "b")?.isRemoved, false)
    }

    // MARK: - An undecodable catalog row is its own unknown, not the page's (#1160)

    /// One payload-undecodable row stops neither the store nor the later pages of the same pass.
    func testAnUndecodableCatalogRowStopsNeitherTheStoreNorItsLaterPages() throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "broken", "c"].map { entry(photo($0)) }))
        try corrupt("broken", in: store)

        _ = store.presentEntries(afterLocalIdentifier: nil, limit: 10)
        XCTAssertTrue(store.isOperational(), "an undecodable row is its own unknown, not a store failure")
        XCTAssertEqual(
            store.presentEntries(afterLocalIdentifier: "a", limit: 10)?.entries.map(\.localIdentifier), ["c"])
    }

    /// The late-render pass queues every row past an undecodable one, and keeps its one-time flag
    /// withheld so the next pass tries the unknown row again.
    func testLateRenderReconciliationReachesRowsPastAnUndecodableOneAndWithholdsItsFlag() async throws {
        let store = try makeCatalog()
        let infos = ["a", "b", "c"].map { edit($0) } + [photo("d")]
        XCTAssertTrue(store.upsertBatch(infos.map { entry($0) }))
        try corrupt("b", in: store)
        let engine = Enqueuer()
        let counted = PhotoDiagnostics.shared.counter("backup.lateRenders.undecodableRow")

        try await sync(store, infos: [], chunkSize: 1).reconcileLateRendersOnce(engine: engine)

        XCTAssertEqual(engine.reopened, ["a", "c"], "the pass reaches rows past the undecodable one")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("backup.lateRenders.undecodableRow"), counted + 1,
            "the pass counts the undecodable row once")
        XCTAssertFalse(store.hasReconciledLateRenders(), "the flag stays withheld while a row is unknown")
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(
            store.lateRenderSweepResumePoint(), "a", "the checkpoint stays before the first unknown page")
    }

    /// The missing-source sweep recovers every row past an undecodable one, and stays owed so the
    /// next sweep tries the unknown row again.
    func testMissingSourceSweepReachesRowsPastAnUndecodableOneAndStaysOwed() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "broken", "c"].map { entry(photo($0)) }))
        try corrupt("broken", in: store)
        let engine = Enqueuer()
        let counted = PhotoDiagnostics.shared.counter("backup.missingSources.undecodableRow")

        try await sync(store, infos: [], chunkSize: 1).reconcileMissingSources(engine: engine)

        XCTAssertEqual(engine.recovered, ["a", "c"], "the sweep reaches rows past the undecodable one")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("backup.missingSources.undecodableRow"), counted + 1,
            "the sweep counts the undecodable row once")
        XCTAssertNil(
            store.reconciledMissingSourceGeneration(), "the sweep stays owed while a row is unknown")
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(
            store.missingSourceSweepProgress()?.afterLocalIdentifier, "a",
            "the checkpoint stays before the first unknown page")
    }

    /// The catalog replay queues every row past an undecodable one, keeps its marker in progress so
    /// the next launch tries the unknown row again, and a later converging run writes no duplicates.
    func testCatalogReplayReachesRowsPastAnUndecodableOneAndStaysInProgress() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "broken", "c"].map { entry(photo($0)) }))
        try corrupt("broken", in: store)
        let (queue, engine) = try await makeReplayQueue()
        let counted = PhotoDiagnostics.shared.counter("backup.catalogReplay.undecodableRow")

        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine)

        XCTAssertEqual(queue.count(), 2, "the replay queues the rows around the undecodable one")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("backup.catalogReplay.undecodableRow"), counted + 1,
            "the replay counts the undecodable row once")
        XCTAssertEqual(queue.catalogReplayState(), .inProgress, "the marker stays unfinished")
        XCTAssertTrue(store.isOperational())

        try corrupt("broken", in: store, repair: true)
        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine)
        XCTAssertEqual(queue.count(), 3)
        XCTAssertEqual(queue.catalogReplayState(), .completed)
        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine)
        XCTAssertEqual(queue.count(), 3, "a converged replay writes no duplicate queue rows")
    }

    /// A clean page after the page with the undecodable row does not let the replay record itself completed.
    func testCatalogReplayStaysInProgressWhenCleanPagesFollowTheUndecodableRow() async throws {
        let store = try makeCatalog()
        let ids = (0...500).map { String(format: "p%04d", $0) }
        XCTAssertTrue(store.upsertBatch(ids.map { entry(photo($0)) }))
        try corrupt("p0001", in: store)
        let (queue, engine) = try await makeReplayQueue()

        try await PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery(
            catalogStore: store, queueStore: queue, engine: engine)

        XCTAssertEqual(queue.count(), 500, "the replay queues every row on both pages but the undecodable one")
        XCTAssertEqual(queue.catalogReplayState(), .inProgress, "the clean second page does not finish the replay")
    }

    /// A discard after the sweep saved its progress can drop photos on earlier pages. While a row stays
    /// unknown, the sweep then starts again on the first page for the new generation.
    func testMissingSourceSweepStartsAgainForANewGenerationWhileARowStaysUnknown() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "broken", "c"].map { entry(photo($0)) }))
        try corrupt("broken", in: store)
        let engine = Enqueuer()
        try await sync(store, infos: [], chunkSize: 1).reconcileMissingSources(engine: engine)
        XCTAssertEqual(store.missingSourceSweepProgress()?.afterLocalIdentifier, "a")

        engine.discardGeneration = Enqueuer.generation + 1
        try await sync(store, infos: [], chunkSize: 1).reconcileMissingSources(engine: engine)
        XCTAssertEqual(
            store.missingSourceSweepProgress(),
            PhotoLibraryMissingSourceSweepProgress(generation: Enqueuer.generation + 1),
            "the next sweep starts on the first page for the new generation")

        try await sync(store, infos: [], chunkSize: 1).reconcileMissingSources(engine: engine)
        XCTAssertEqual(
            engine.recovered, ["a", "c", "c", "a", "c"],
            "the new generation checks the page before the saved progress again")
        XCTAssertNil(store.reconciledMissingSourceGeneration(), "the sweep stays owed while a row is unknown")
    }

    // MARK: - Unknown rows on the other catalog paths (#1212)

    /// Photos now lists the rendered file of an edit whose stored row cannot be decoded. The unknown row may have
    /// recorded the original as main photo, so the scan re-opens the edit, and it goes on with the other photos.
    func testAnUndecodableStoredRowReopensTheLateRenderAndKeepsTheScanGoing() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(photo($0)) }))
        try corrupt("a", in: store)
        let engine = Enqueuer()

        _ = try await sync(store, infos: ["a", "b"].map { edit($0, modified: 1_700_000_200) }, at: 200)
            .run(engine: engine, identifiers: ["a", "b"])

        XCTAssertEqual(engine.reopened, ["a", "b"], "the unknown row re-opens like a known row without the render")
        XCTAssertEqual(engine.enqueued, ["a", "b"], "the unknown row holds back no photo")
        XCTAssertTrue(store.isOperational())
        let rewritten = try XCTUnwrap(try store.entry(for: "a"), "the chunk rewrites the unknown row")
        XCTAssertTrue(PhotoBackupAssetPlanner.listsRender(PhotoLibraryCatalogMapper.info(for: rewritten)))
    }

    /// The upload metadata reads the cloud identifier that the catalog holds. An unknown row answers nil, so the
    /// metadata asks Photos, and the row changes neither the store nor the answer for another photo.
    func testAnUnknownRowLeavesTheCloudIdentifierToPhotos() throws {
        let store = try makeCatalog()
        XCTAssertTrue(
            store.upsertBatch(
                ["a", "b"].map {
                    var info = photo($0)
                    info.cloudIdentifier = "cloud-\($0)"
                    return entry(info)
                }))
        try corrupt("a", in: store)

        XCTAssertNil(store.cachedCloudIdentifier(for: "a"))
        XCTAssertTrue(store.isOperational(), "an undecodable row is its own unknown, not a store failure")
        XCTAssertEqual(store.cachedCloudIdentifier(for: "b"), "cloud-b")
    }

    /// A key that is not valid UTF-8, on a row whose content decodes, would come back repaired as the next cursor, and
    /// `local_id>?` would return the row again. The pass must stop with an unknown page instead of paging forever.
    func testAHealthyRowWithADamagedKeyStopsTheLateRenderPassInsteadOfLooping() async throws {
        try await assertDamagedKeyStopsTheLateRenderPass(reaching: ["a"]) { store in
            try changeCatalog(store, "UPDATE photo_catalog SET local_id=CAST(X'7AFF' AS TEXT) WHERE local_id='z';")
            return store
        }
    }

    /// A key stored as a BLOB with valid UTF-8 sorts after every text key. Read as text, it would become the cursor,
    /// and `local_id>?` would return the same BLOB again.
    func testAHealthyRowWithABlobKeyStopsTheLateRenderPassInsteadOfLooping() async throws {
        try await assertDamagedKeyStopsTheLateRenderPass(reaching: ["a"]) { store in
            try changeCatalog(store, "UPDATE photo_catalog SET local_id=X'7A7A' WHERE local_id='z';")
            return store
        }
    }

    /// An INTEGER key sorts before every text key, so the first page meets it before any other row.
    func testAHealthyRowWithAnIntegerKeyStopsTheLateRenderPass() async throws {
        try await assertDamagedKeyStopsTheLateRenderPass(reaching: []) { store in
            try reopen(store) { try storeIntegerCatalogKey(5, replacing: "z", inClosedCatalogAt: $0) }
        }
    }

    /// `local_id>?` never returns a row without a key. A late-render pass that resumes after a saved key must not
    /// reach the end past that row and record itself complete.
    func testARowWithoutAKeyKeepsAResumedLateRenderPassOwed() async throws {
        try await assertKeyBeforeTextKeepsAResumedLateRenderPassOwed { store in
            try changeCatalog(store, "UPDATE photo_catalog SET local_id=NULL WHERE local_id='c';")
            return store
        }
    }

    /// An INTEGER key sorts before every text key, so `local_id>?` never returns it either.
    func testARowWithAnIntegerKeyKeepsAResumedLateRenderPassOwed() async throws {
        try await assertKeyBeforeTextKeepsAResumedLateRenderPassOwed { store in
            try reopen(store) { try storeIntegerCatalogKey(5, replacing: "c", inClosedCatalogAt: $0) }
        }
    }

    /// Closes `store`, lets `damage` change its file, and opens the catalog again.
    private func reopen(
        _ store: PhotoLibraryCatalogManifestStore, after damage: (URL) throws -> Void
    ) throws -> PhotoLibraryCatalogManifestStore {
        store.close()
        try damage(directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName))
        return try makeCatalog()
    }

    /// Damages the key of the last of the edits "a" and "z", then runs one late-render pass for at most 10 seconds.
    /// `damage` returns the store to use: the same one, or one opened again on the damaged file.
    private func assertDamagedKeyStopsTheLateRenderPass(
        reaching reached: [String],
        damage: (PhotoLibraryCatalogManifestStore) throws -> PhotoLibraryCatalogManifestStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let seeded = try makeCatalog()
        XCTAssertTrue(seeded.upsertBatch(["a", "z"].map { entry(edit($0)) }), file: file, line: line)
        XCTAssertTrue(seeded.synchronizeToDisk(), file: file, line: line)
        let store = try damage(seeded)
        let pass = sync(store, chunkSize: 1)
        let engine = Enqueuer()

        let outcome = await boundedRun(seconds: 10) { try await pass.reconcileLateRendersOnce(engine: engine) }

        guard case .failure(let error) = try XCTUnwrap(outcome, "the pass must end, not page the same row forever")
        else { return XCTFail("a damaged key must stop the pass", file: file, line: line) }
        XCTAssertEqual(
            error as? UploadError, .backend("Photo library catalog could not be read"), file: file, line: line)
        XCTAssertEqual(
            engine.reopened, reached, "the pass reached the rows before the damaged key", file: file, line: line)
        XCTAssertFalse(store.hasReconciledLateRenders(), file: file, line: line)
        XCTAssertFalse(
            store.isOperational(), "a damaged key means deeper damage and keeps the store failed", file: file,
            line: line)
    }

    /// Resumes a late-render pass after "a" over the edits "a", "b" and "c", with the key of "c" damaged.
    /// `damage` returns the store to use: the same one, or one opened again on the damaged file.
    private func assertKeyBeforeTextKeepsAResumedLateRenderPassOwed(
        damage: (PhotoLibraryCatalogManifestStore) throws -> PhotoLibraryCatalogManifestStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let seeded = try makeCatalog()
        XCTAssertTrue(seeded.upsertBatch(["a", "b", "c"].map { entry(edit($0)) }), file: file, line: line)
        XCTAssertTrue(seeded.recordLateRenderSweepResumePoint("a"), file: file, line: line)
        XCTAssertTrue(seeded.synchronizeToDisk(), file: file, line: line)
        let store = try damage(seeded)
        let engine = Enqueuer()

        do {
            try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: engine)
            XCTFail("a key before every text key leaves the end of the catalog unknown", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? UploadError, .backend("Photo library catalog could not be read"), file: file, line: line)
        }

        XCTAssertEqual(
            engine.reopened, ["b"], "the pass still reached the rows before the end", file: file, line: line)
        XCTAssertFalse(store.hasReconciledLateRenders(), "the pass stays owed", file: file, line: line)
        XCTAssertFalse(
            store.isOperational(), "a damaged key means deeper damage and keeps the store failed", file: file,
            line: line)
    }

    /// The missing-source sweep resumes after its saved key, too, and must not complete past a row without a key.
    func testARowWithoutAKeyKeepsAResumedMissingSourceSweepOwed() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "b", "c"].map { entry(photo($0)) }))
        XCTAssertTrue(
            store.recordMissingSourceSweepProgress(
                PhotoLibraryMissingSourceSweepProgress(generation: Enqueuer.generation, afterLocalIdentifier: "a")))
        try changeCatalog(store, "UPDATE photo_catalog SET local_id=NULL WHERE local_id='c';")
        let engine = Enqueuer()

        do {
            try await sync(store, chunkSize: 1).reconcileMissingSources(engine: engine)
            XCTFail("a row without a key leaves the end of the catalog unknown")
        } catch {
            XCTAssertEqual(error as? UploadError, .backend("Photo library catalog could not be read"))
        }

        XCTAssertEqual(engine.recovered, ["b"], "the sweep still reached the rows before the end")
        XCTAssertNotEqual(store.reconciledMissingSourceGeneration(), Enqueuer.generation, "the sweep stays owed")
    }

    /// A failed check for rows without a key is unknown, not "no such row": the resumed pass stays owed, and the next
    /// pass completes once the check reads.
    func testAFailedCheckForRowsWithoutAKeyNeverCompletesTheResumedPass() async throws {
        let store = try makeCatalog()
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(edit($0)) }))
        XCTAssertTrue(store.recordLateRenderSweepResumePoint("a"))
        let fault = try SQLiteReadInterrupt(in: store, matching: "SELECT typeof(local_id) FROM photo_catalog")
        do {
            try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: Enqueuer())
            XCTFail("an unknown end must stop the pass")
        } catch {}
        fault.stop()

        XCTAssertTrue(fault.fired)
        XCTAssertFalse(store.hasReconciledLateRenders(), "an unknown end is not the end of the catalog")
        XCTAssertTrue(store.isOperational(), "the probe clears the transient interrupt")
        try await sync(store, chunkSize: 1).reconcileLateRendersOnce(engine: Enqueuer())
        XCTAssertTrue(store.hasReconciledLateRenders(), "the next pass completes once the check reads")
    }

    /// Runs `sql` on the store's own connection, as damage from outside the store would leave the file.
    private func changeCatalog(_ store: PhotoLibraryCatalogManifestStore, _ sql: String) throws {
        let connection = try storeConnection(store)
        XCTAssertEqual(connection.withLock { sqlite3_exec(connection.database, sql, nil, nil, nil) }, SQLITE_OK)
    }

    /// Runs `pass` for at most `seconds`. Nil when it did not end in time; the pass is then cancelled.
    private func boundedRun(
        seconds: Int, _ pass: @escaping @Sendable () async throws -> Void
    ) async -> Result<Void, any Error>? {
        await withTaskGroup(of: Result<Void, any Error>?.self) { group in
            group.addTask {
                do {
                    try await pass()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func makeReplayQueue() async throws -> (UploadBackupSyncQueueManifestStore, UploadBackupSyncEngine) {
        let queueURL = directory.appendingPathComponent(
            await PhotoLibraryBackupController.queueDatabaseFileName)
        let stateURL = directory.appendingPathComponent(
            await PhotoLibraryBackupController.stateDatabaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        closers.append { queue.close() }
        let state = try XCTUnwrap(UploadBackupStateManifestStore(url: stateURL))
        closers.append { state.close() }
        return (queue, UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue))
    }
}

// MARK: - Fixtures

/// Lowers SQLITE_LIMIT_LENGTH on the store's own connection right after the info write that stores `marker`. The
/// value was stored and read normally, and only its next bind fails, as a bind that runs out of memory does.
private final class LengthLimitAfterWrite {
    private let connection: SQLiteStoreConnection
    private let marker: String
    private let limit: Int32
    private var applied: Int32?

    init(in store: Any, marker: String, limit: Int32) throws {
        connection = try storeConnection(store)
        // sqlite3_expanded_sql renders a BLOB parameter as lowercase hexadecimal.
        self.marker = marker.utf8.prefix(16).map { String(format: "%02x", $0) }.joined()
        self.limit = limit
        connection.withLock {
            _ = sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_PROFILE),
                { _, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let hook = Unmanaged<LengthLimitAfterWrite>.fromOpaque(context).takeUnretainedValue()
                    guard hook.applied == nil, let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else {
                        return 0
                    }
                    defer { sqlite3_free(expanded) }
                    let sql = String(cString: expanded)
                    guard sql.hasPrefix("INSERT INTO photo_catalog_info"), sql.contains(hook.marker) else { return 0 }
                    let db = sqlite3_db_handle(OpaquePointer(statement))
                    _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, hook.limit)
                    hook.applied = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1)
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Removes the hook and the limit. Returns the effective limit that applied, or nil when no write matched.
    func remove() -> Int32? {
        connection.withLock {
            _ = sqlite3_trace_v2(connection.database, 0, nil, nil)
            _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 1_000_000_000)
        }
        return applied
    }
}

/// Fails exactly one bind: lowers SQLITE_LIMIT_LENGTH to the 30-byte floor once `BEGIN IMMEDIATE` finishes, and restores
/// it when the next statement starts to step, after its binds and before it builds a record. A bind of a longer value
/// fails as a bind that runs out of memory does; the record and every later statement run without the limit.
private final class KeyBindFailureAfterBegin {
    private let connection: SQLiteStoreConnection
    private var lowered = false
    private var restored = false

    init(in store: Any) throws {
        connection = try storeConnection(store)
        connection.withLock {
            _ = sqlite3_trace_v2(
                connection.database, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE),
                { event, context, statement, _ in
                    guard let context, let statement else { return 0 }
                    let fault = Unmanaged<KeyBindFailureAfterBegin>.fromOpaque(context).takeUnretainedValue()
                    let db = sqlite3_db_handle(OpaquePointer(statement))
                    if event == UInt32(SQLITE_TRACE_PROFILE), !fault.lowered,
                        let sql = sqlite3_sql(OpaquePointer(statement)),
                        String(cString: sql).hasPrefix("BEGIN IMMEDIATE")
                    {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 30)
                        fault.lowered = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == 30
                    } else if event == UInt32(SQLITE_TRACE_STMT), fault.lowered, !fault.restored {
                        _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_000_000_000)
                        fault.restored = true
                    }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Removes the hook. True when the limit applied to one statement and was restored.
    func remove() -> Bool {
        connection.withLock {
            _ = sqlite3_trace_v2(connection.database, 0, nil, nil)
            _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 1_000_000_000)
        }
        return lowered && restored
    }
}

private final class Enumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
    let infos: [PhotoBackupAssetInfo]
    init(infos: [PhotoBackupAssetInfo]) { self.infos = infos }

    func infoChunks(
        identifiers: [String]?, startOffset: Int, chunkSize: Int
    ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        let wanted = identifiers.map(Set.init)
        let selected = Array(infos.filter { wanted?.contains($0.localIdentifier) ?? true }.dropFirst(startOffset))
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < selected.count {
                let upper = min(index + max(1, chunkSize), selected.count)
                continuation.yield(Array(selected[index..<upper]))
                index = upper
            }
            continuation.finish()
        }
    }
}

private final class Enqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
    static let generation: Int64 = 1
    private let lock = NSLock()
    private var _enqueued: [String] = []
    private var _reopened: [String] = []
    private var _recovered: [String] = []
    private var _discardGeneration = Enqueuer.generation
    var discardGeneration: Int64 {
        get { lock.withLock { _discardGeneration } }
        set { lock.withLock { _discardGeneration = newValue } }
    }
    var enqueued: [String] { lock.withLock { _enqueued } }
    var reopened: [String] { lock.withLock { _reopened } }
    var recovered: [String] { lock.withLock { _recovered } }

    func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
        lock.withLock { _enqueued.append(candidate.snapshot.source.identifier) }
        return UploadBackupSyncScanResult()
    }

    func reopenBackedUpRevisions(
        _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
    ) async throws -> [UploadBackupAssetCandidate] {
        lock.withLock { _reopened += reopenings.map(\.candidate.snapshot.source.identifier) }
        return []
    }

    func enqueueMissingSources(_ candidates: [UploadBackupAssetCandidate]) async throws {
        lock.withLock { _recovered += candidates.map(\.snapshot.source.identifier) }
    }

    func missingSourceDiscardGeneration() async throws -> Int64 { discardGeneration }
    func synchronizeQueueToDisk() async -> Bool { true }
}
