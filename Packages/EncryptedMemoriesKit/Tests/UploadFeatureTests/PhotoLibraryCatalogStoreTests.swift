import Foundation
import SQLite3
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Persistent local photo-library catalog: round-trips, change classification, removed handling,
/// and the catalog-backed scan source that feeds only new/changed candidates to the backup engine.
/// All pure/off-device - no PhotoKit, so it runs everywhere.
final class PhotoLibraryCatalogStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() throws -> PhotoLibraryCatalogManifestStore {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        return try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
    }

    private func info(
        id: String,
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_100),
        width: Int = 4032,
        height: Int = 3024,
        live: Bool = false,
        video: Bool = false,
        resources: [PhotoBackupAssetInfo.Resource]
    ) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: modified,
            pixelWidth: width, pixelHeight: height,
            durationSeconds: video ? 12 : 0,
            isLivePhoto: live, isVideo: video,
            resources: resources
        )
    }

    private func photoInfo(
        id: String, modified: Date? = Date(timeIntervalSince1970: 1_700_000_100)
    ) -> PhotoBackupAssetInfo {
        info(
            id: id, modified: modified,
            resources: [
                .init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic")
            ])
    }

    private func entry(from info: PhotoBackupAssetInfo, at seconds: TimeInterval) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date(timeIntervalSince1970: seconds))
    }

    func testInsertUpdateRoundTripPreservesFirstSeenAndClassifies() throws {
        let store = try makeStore()
        let inserted = entry(from: photoInfo(id: "A"), at: 100)

        XCTAssertEqual(store.upsert(inserted), .inserted)
        let readBack = try XCTUnwrap(store.entry(for: "A"))
        XCTAssertEqual(readBack, inserted, "the full row must round-trip byte-for-byte")

        // Same content observed later: unchanged, firstSeenAt kept, lastSeenAt advanced.
        let later = entry(from: photoInfo(id: "A"), at: 200)
        XCTAssertEqual(store.upsert(later), .unchanged)
        let afterUnchanged = try XCTUnwrap(store.entry(for: "A"))
        XCTAssertEqual(afterUnchanged.firstSeenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(afterUnchanged.lastSeenAt, Date(timeIntervalSince1970: 200))

        // A metadata-only change (new modificationDate) moves the metadata revision to changed.
        let touched = entry(from: photoInfo(id: "A", modified: Date(timeIntervalSince1970: 1_700_009_999)), at: 300)
        XCTAssertEqual(store.upsert(touched), .changed)
        XCTAssertEqual(store.entry(for: "A")?.firstSeenAt, Date(timeIntervalSince1970: 100))
    }

    func testResourceRolesOrderAndOrdinalsRoundTrip() throws {
        let store = try makeStore()
        var asset = info(
            id: "R",
            resources: [
                .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: "image/heic"),
                .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
                .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: nil),
            ])
        asset.cloudIdentifier = "icloud-R"
        let e = entry(from: asset, at: 10)
        XCTAssertEqual(store.upsert(e), .inserted)

        let read = try XCTUnwrap(store.entry(for: "R"))
        XCTAssertEqual(read.resources, e.resources, "resource role/name/mime/ordinal must survive the JSON round trip")
        XCTAssertEqual(read.resources.map(\.role), ["originalPhoto", "fullSizePhoto", "adjustmentData"])
        XCTAssertNil(read.resources[2].mimeType)
        XCTAssertEqual(read.cloudIdentifier, "icloud-R")
    }

    func testMissingCloudIdentifierDoesNotErasePreviouslyMappedIdentity() throws {
        let store = try makeStore()
        var first = photoInfo(id: "cloud")
        first.cloudIdentifier = "icloud-stable"
        XCTAssertEqual(store.upsert(entry(from: first, at: 10)), .inserted)

        let temporarilyUnmapped = photoInfo(id: "cloud")
        XCTAssertEqual(store.upsert(entry(from: temporarilyUnmapped, at: 20)), .unchanged)
        XCTAssertEqual(store.entry(for: "cloud")?.cloudIdentifier, "icloud-stable")
    }

    func testAV105RowOfALiveOffPhotoKeepsItsLiveEffectOffAfterAScanWithoutASchemaChange() throws {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG_L.HEIC", mimeType: "image/heic"),
            .init(role: .pairedVideo, originalFilename: "IMG_L.MOV", mimeType: "video/quicktime"),
        ]
        // Photos drops `.photoLive` when the Live effect is off and still lists the paired video.
        var still = info(id: "L", live: false, resources: resources)
        still.livePlaybackOff = true
        // v1.0.5 did not read the Live effect: it wrote 0 for this photo.
        var v105 = still
        v105.livePlaybackOff = false
        do {
            let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            XCTAssertEqual(store.upsert(entry(from: v105, at: 10)), .inserted)
            let on = info(id: "on", live: true, resources: resources)
            XCTAssertEqual(store.upsert(entry(from: on, at: 10)), .inserted)
            store.close()
        }
        XCTAssertEqual(liveColumn(url: url, id: "L"), 0)
        XCTAssertEqual(liveColumn(url: url, id: "on"), 1)

        let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
        let scanned = entry(from: still, at: 20)
        XCTAssertEqual(store.classifyBatch([scanned]), [.unchanged], "the Live effect alone does not re-open a photo")
        XCTAssertTrue(store.upsertBatch([scanned]))
        let recorded = try XCTUnwrap(store.entry(for: "L"))
        XCTAssertFalse(recorded.isLivePhoto, "the fingerprint keeps the value of v1.0.5")
        XCTAssertTrue(recorded.livePlaybackOff)
        XCTAssertFalse(PhotoLibraryPendingMetadataProvider.metadata(for: recorded).isLivePhoto)
        XCTAssertTrue(PhotoLibraryCatalogMapper.info(for: recorded).livePlaybackOff, "a replay plans the still photo")
        XCTAssertEqual(PhotoLibraryCatalogMapper.info(for: recorded), PhotoLibraryCatalogMapper.info(for: scanned))
        let live = try XCTUnwrap(store.entry(for: "on"))
        XCTAssertTrue(live.isLivePhoto)
        XCTAssertFalse(live.livePlaybackOff)
        XCTAssertTrue(PhotoLibraryPendingMetadataProvider.metadata(for: live).isLivePhoto)
        store.close()
        XCTAssertEqual(liveColumn(url: url, id: "L"), 2, "v1.0.5 reads any value other than 0 as a Live Photo")
    }

    private func liveColumn(url: URL, id: String) -> Int? {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT is_live_photo FROM photo_catalog WHERE local_id='\(id)';"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : nil
    }

    func testPresentEntryPagesAreStableAndExcludeRemovedRows() throws {
        let store = try makeStore()
        let entries = ["C", "A", "B"].map { entry(from: photoInfo(id: $0), at: 10) }
        XCTAssertTrue(store.upsertBatch(entries))
        XCTAssertTrue(store.markRemoved(["B"], removedAt: Date()).succeeded)

        let first = store.presentEntries(afterLocalIdentifier: nil, limit: 1)
        let second = store.presentEntries(afterLocalIdentifier: first.last?.localIdentifier, limit: 10)

        XCTAssertEqual((first + second).map(\.localIdentifier), ["A", "C"])
    }

    func testTwentyThousandCatalogBatchStructuralSmoke() throws {
        let store = try makeStore()
        let entries = (0..<20_000).map { index in
            entry(from: photoInfo(id: String(index)), at: 100)
        }

        let saveStart = Date()
        XCTAssertTrue(store.upsertBatch(entries))
        let saveMs = Date().timeIntervalSince(saveStart) * 1_000

        let classifyStart = Date()
        let classifications = store.classifyBatch(entries)
        let classifyMs = Date().timeIntervalSince(classifyStart) * 1_000

        XCTAssertEqual(store.count(), 20_000)
        XCTAssertEqual(classifications.count, 20_000)
        XCTAssertTrue(classifications.allSatisfy { $0 == .unchanged })
        let formattedSaveMs = String(format: "%.2f", saveMs)
        let formattedClassifyMs = String(format: "%.2f", classifyMs)
        print(
            "[BackupDBMicroPerf] catalog20k saveMs=\(formattedSaveMs) "
                + "classifyMs=\(formattedClassifyMs)"
        )
    }

    func testUnchangedResourcesAreStableAndEditsChangeTheFingerprint() throws {
        let base = photoInfo(id: "F")
        let same = PhotoLibraryCatalogMapper.entry(for: base, observedAt: Date(timeIntervalSince1970: 1))
        let sameAgain = PhotoLibraryCatalogMapper.entry(
            for: photoInfo(id: "F"), observedAt: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(
            same.contentFingerprint, sameAgain.contentFingerprint,
            "identical resources must fingerprint identically regardless of observation time")

        // Adding an edit render is a real structural change to different fingerprint.
        let edited = info(
            id: "F",
            resources: [
                .init(role: .originalPhoto, originalFilename: "IMG_F.HEIC", mimeType: "image/heic"),
                .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
            ])
        let editedEntry = PhotoLibraryCatalogMapper.entry(for: edited, observedAt: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(same.contentFingerprint, editedEntry.contentFingerprint)
    }

    func testFullSweepMarksUnseenRemovedAndResurrectionIsAChange() throws {
        let store = try makeStore()
        for id in ["A", "B", "C"] { XCTAssertEqual(store.upsert(entry(from: photoInfo(id: id), at: 100)), .inserted) }

        // Second pass at t=200 only re-observes A and B; C is now missing.
        for id in ["A", "B"] { store.upsert(entry(from: photoInfo(id: id), at: 200)) }
        XCTAssertEqual(
            store.sweepRemoved(
                notSeenAfter: Date(timeIntervalSince1970: 200),
                removedAt: Date(timeIntervalSince1970: 200)
            ),
            PhotoLibraryCatalogMutationResult(affectedRows: 1, succeeded: true)
        )
        XCTAssertEqual(store.entry(for: "C")?.isRemoved, true)
        XCTAssertEqual(store.entry(for: "A")?.isRemoved, false)
        XCTAssertEqual(store.snapshot(), PhotoLibraryCatalogSnapshot(total: 3, present: 2, removed: 1))

        // C comes back to a removed row reappearing is a change (re-checked by backup).
        XCTAssertEqual(store.upsert(entry(from: photoInfo(id: "C"), at: 300)), .changed)
        XCTAssertEqual(store.entry(for: "C")?.isRemoved, false)
        XCTAssertNil(store.entry(for: "C")?.removedAt)
    }

    func testMarkRemovedOnlyTouchesPresentRequestedIdentifiers() throws {
        let store = try makeStore()
        store.upsert(entry(from: photoInfo(id: "keep"), at: 100))
        store.upsert(entry(from: photoInfo(id: "gone"), at: 100))

        // "unknown" is not catalogued and must be a no-op; "keep" is not in the list, stays present.
        XCTAssertEqual(
            store.markRemoved(["gone", "unknown"], removedAt: Date(timeIntervalSince1970: 150)),
            PhotoLibraryCatalogMutationResult(affectedRows: 1, succeeded: true)
        )
        XCTAssertEqual(store.entry(for: "gone")?.isRemoved, true)
        XCTAssertEqual(store.entry(for: "keep")?.isRemoved, false)
        XCTAssertNil(store.entry(for: "unknown"))
    }

    func testRemovalMutationsReportPersistenceFailure() throws {
        let store = try makeStore()
        store.close()

        XCTAssertEqual(
            store.markRemoved(["gone"], removedAt: Date()),
            PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
        )
        XCTAssertEqual(
            store.sweepRemoved(notSeenAfter: Date(), removedAt: Date()),
            PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
        )
    }

    func testFutureSchemaFailsClosedWithoutDeletingCatalog() throws {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            store.upsert(entry(from: photoInfo(id: "A"), at: 1))
            store.close()
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE photo_catalog_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(PhotoLibraryCatalogManifestStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "photo_catalog"), 1)
    }

    func testMarkerlessCatalogShapeFailsClosedWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE photo_catalog(local_id TEXT); INSERT INTO photo_catalog VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(PhotoLibraryCatalogManifestStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "photo_catalog"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "photo_catalog_info"), -1)
    }

    private func sqliteCount(url: URL, table: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    func testCompletedFullScanMarkerPersistsAcrossReopen() throws {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            XCTAssertFalse(store.hasCompletedFullScan())
            store.completeFullScan()
            XCTAssertTrue(store.hasCompletedFullScan())
            store.close()
        }

        let reopened = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
        XCTAssertTrue(reopened.hasCompletedFullScan())
    }

    func testFullScanSnapshotRoundTripsInStableOrder() throws {
        let store = try makeStore()
        let epoch = Date(timeIntervalSince1970: 100)
        store.beginFullScanSnapshot(epochStart: epoch)
        store.appendFullScanSnapshotIdentifiers(["A", "B"])
        store.appendFullScanSnapshotIdentifiers(["C", "D"])
        XCTAssertNil(store.fullScanProgress(), "an incomplete snapshot must never be resumed")

        store.finishFullScanSnapshot()
        XCTAssertEqual(store.fullScanProgress(), PhotoLibraryFullScanProgress(epochStart: epoch, cursor: 0))
        XCTAssertEqual(store.fullScanSnapshotCount(), 4)
        XCTAssertEqual(store.fullScanSnapshotIdentifiers(startingAt: 2, limit: 2), ["C", "D"])

        store.recordFullScanProgress(PhotoLibraryFullScanProgress(epochStart: epoch, cursor: 2))
        XCTAssertEqual(store.fullScanProgress()?.cursor, 2)
        store.completeFullScan()
        XCTAssertEqual(store.fullScanSnapshotCount(), 0)
        XCTAssertNil(store.fullScanProgress())
    }

    func testResumedSnapshotCannotSkipWhenEarlierLiveAssetWasDeleted() async throws {
        let store = try makeStore()
        let epoch = Date(timeIntervalSince1970: 100)
        store.beginFullScanSnapshot(epochStart: epoch)
        store.appendFullScanSnapshotIdentifiers(["A", "B", "C", "D"])
        store.finishFullScanSnapshot()

        // A and B were durably observed before the process stopped. A then disappears, shifting a
        // live PHFetchResult. The persisted snapshot still resumes at C, not at live-array offset 2.
        store.upsert(entry(from: photoInfo(id: "A"), at: 100))
        store.upsert(entry(from: photoInfo(id: "B"), at: 100))
        store.recordFullScanProgress(PhotoLibraryFullScanProgress(epochStart: epoch, cursor: 2))
        let enumerator = StubEnumerator(infos: [photoInfo(id: "B"), photoInfo(id: "C"), photoInfo(id: "D")])
        let enqueuer = RecordingEnqueuer()

        _ = try await PhotoLibraryCatalogSync(
            store: store,
            enumerator: enumerator,
            chunkSize: 2,
            now: { Date(timeIntervalSince1970: 200) }
        ).run(engine: enqueuer)

        XCTAssertEqual(enqueuer.enqueued, ["C", "D"])
        XCTAssertNotNil(store.entry(for: "C"))
        XCTAssertNotNil(store.entry(for: "D"))
    }

    func testDriverEnqueuesOnlyNewAndChangedAssets() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])

        // First full pass: both new to both enqueued.
        let e1 = RecordingEnqueuer()
        let p1 = try await runDriver(store: store, enumerator: enumerator, engine: e1, at: 100)
        XCTAssertEqual(Set(e1.enqueued), ["A", "B"])
        XCTAssertEqual(p1.discovered, 2)
        XCTAssertEqual(p1.changed, 0)

        // Second pass, nothing changed to nothing re-checked (the big repeat-scan win).
        let e2 = RecordingEnqueuer()
        let p2 = try await runDriver(store: store, enumerator: enumerator, engine: e2, at: 200)
        XCTAssertTrue(e2.enqueued.isEmpty, "unchanged assets must not be re-handed to the backup engine")
        XCTAssertEqual(p2.discovered + p2.changed, 0)

        // Change B only to only B is re-checked.
        enumerator.infos = [
            photoInfo(id: "A"), photoInfo(id: "B", modified: Date(timeIntervalSince1970: 1_700_050_000)),
        ]
        let e3 = RecordingEnqueuer()
        let p3 = try await runDriver(store: store, enumerator: enumerator, engine: e3, at: 300)
        XCTAssertEqual(e3.enqueued, ["B"])
        XCTAssertEqual(p3.changed, 1)
        XCTAssertEqual(p3.discovered, 0)
    }

    func testDriverWritesQueueRowBeforeAdvancingCatalog() async throws {
        // The durability contract: if the process died between the queue write and the catalog
        // advance, the asset must re-yield next pass - so the catalog must not yet reflect the asset
        // at the moment its candidate is enqueued.
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])
        let enqueuer = OrderingEnqueuer(store: store)

        _ = try await runDriver(store: store, enumerator: enumerator, engine: enqueuer, at: 100)

        XCTAssertEqual(
            enqueuer.catalogAbsentAtEnqueue, ["A": true, "B": true],
            "the durable queue row must be written before the catalog marks the asset seen")
        // After the pass the catalog is advanced for both.
        XCTAssertNotNil(store.entry(for: "A"))
        XCTAssertNotNil(store.entry(for: "B"))
    }

    func testQueuePersistenceFailureDoesNotAdvanceCatalogOrCursor() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A")])

        do {
            _ = try await runDriver(
                store: store,
                enumerator: enumerator,
                engine: FailingEnqueuer(),
                at: 100
            )
            XCTFail("queue persistence failure must abort the catalog chunk")
        } catch {
            // expected
        }

        XCTAssertNil(store.entry(for: "A"), "an unqueued asset must remain unseen and re-yield")
        XCTAssertEqual(store.fullScanProgress()?.cursor, 0, "the stable frontier must not pass unqueued work")
    }

    func testOpenCatalogDecodeFailureStaysStickyAcrossSuccessfulSQLAndRejectsDurabilityAndAppend() throws {
        let store = try makeStore()
        defer { store.close() }
        XCTAssertTrue(store.upsertBatch([entry(from: photoInfo(id: "corrupt"), at: 100)]))
        XCTAssertTrue(store.beginFullScanSnapshot(epochStart: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(store.appendFullScanSnapshotIdentifiers(["kept"]))
        XCTAssertTrue(store.isOperational())
        XCTAssertTrue(store.synchronizeToDisk())

        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        do {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
            let database = try XCTUnwrap(handle)
            defer { sqlite3_close(database) }
            XCTAssertEqual(
                sqlite3_exec(
                    database, "UPDATE photo_catalog SET resources_json=X'7B' WHERE local_id='corrupt';",
                    nil, nil, nil), SQLITE_OK)
        }

        XCTAssertNil(store.entry(for: "corrupt"), "a malformed resource blob must fail decoding on the open store")
        XCTAssertFalse(store.isOperational())
        XCTAssertFalse(store.synchronizeToDisk(), "an open handle with a recorded failure cannot prove durability")
        XCTAssertFalse(store.appendFullScanSnapshotIdentifiers(["rejected"]))
        XCTAssertEqual(store.fullScanSnapshotIdentifiers(startingAt: 0, limit: 10), ["kept"])

        let later = entry(from: photoInfo(id: "later"), at: 200)
        XCTAssertTrue(store.upsertBatch([later]), "successful SQL predicates retain their existing result")
        XCTAssertEqual(store.entry(for: "later"), later, "the handle remains open and can execute SQL")
        XCTAssertFalse(store.isOperational(), "successful SQL must not reset the recorded failure")
        XCTAssertFalse(store.synchronizeToDisk())
    }

    func testSnapshotAppendRejectsEmptyIdentifiersWithoutAppendingOrRecordingFailure() throws {
        let store = try makeStore()
        defer { store.close() }
        XCTAssertTrue(store.beginFullScanSnapshot(epochStart: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(store.appendFullScanSnapshotIdentifiers(["kept"]))

        for identifiers in [[""], ["candidate", ""]] {
            XCTAssertFalse(store.appendFullScanSnapshotIdentifiers(identifiers))
            XCTAssertEqual(store.fullScanSnapshotIdentifiers(startingAt: 0, limit: 10), ["kept"])
            XCTAssertTrue(store.isOperational(), "invalid input is rejected before SQL without recording failure")
            XCTAssertTrue(store.synchronizeToDisk())
        }

        XCTAssertTrue(store.appendFullScanSnapshotIdentifiers(["later"]))
        XCTAssertEqual(store.fullScanSnapshotIdentifiers(startingAt: 0, limit: 10), ["kept", "later"])
        XCTAssertTrue(store.isOperational())
    }

    func testEmptyClassifyBatchReturnsEmptyOnOpenAndClosedStore() throws {
        try assertEmptyBatchPreservesCallerState { $0.classifyBatch([]).isEmpty }
    }

    func testEmptyPresentEntriesReturnsEmptyOnOpenAndClosedStore() throws {
        try assertEmptyBatchPreservesCallerState { $0.presentEntries(for: []).isEmpty }
    }

    func testEmptyUpsertBatchStillSucceedsAfterCloseWithoutChangingCallerState() throws {
        try assertEmptyBatchPreservesCallerState { $0.upsertBatch([]) }
    }

    func testEmptyMarkRemovedStillSucceedsAfterCloseWithoutChangingCallerState() throws {
        try assertEmptyBatchPreservesCallerState { store in
            let result = store.markRemoved([], removedAt: Date(timeIntervalSince1970: 100))
            XCTAssertEqual(result.affectedRows, 0)
            let filtered = store.markRemoved(["", ""], removedAt: Date(timeIntervalSince1970: 100))
            XCTAssertTrue(filtered.succeeded)
            XCTAssertEqual(filtered.affectedRows, 0)
            return result.succeeded
        }
    }

    func testEmptySnapshotAppendStillSucceedsAfterCloseWithoutChangingCallerState() throws {
        try assertEmptyBatchPreservesCallerState { $0.appendFullScanSnapshotIdentifiers([]) }
    }

    private func assertEmptyBatchPreservesCallerState(
        _ operation: (PhotoLibraryCatalogManifestStore) -> Bool
    ) throws {
        for closed in [false, true] {
            let url = tempDir.appendingPathComponent("\(UUID().uuidString).sqlite")
            let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            defer { store.close() }
            let original = entry(from: photoInfo(id: "kept"), at: 100)
            XCTAssertTrue(store.upsertBatch([original]))
            if closed { store.close() }
            let wasOperational = store.isOperational()
            XCTAssertEqual(wasOperational, !closed)

            XCTAssertTrue(operation(store), "an empty batch still succeeds on a closed store")
            XCTAssertEqual(store.isOperational(), wasOperational, "a no-op must preserve operational state")
            XCTAssertTrue(store.classifyBatch([]).isEmpty)
            XCTAssertTrue(store.presentEntries(for: []).isEmpty)
            XCTAssertEqual(store.isOperational(), wasOperational)
            XCTAssertEqual(store.entry(for: "kept"), closed ? nil : original)
            let later = entry(from: photoInfo(id: "later"), at: 200)
            XCTAssertEqual(store.upsertBatch([later]), !closed, "a following real write keeps its normal result")
            XCTAssertEqual(store.isOperational(), wasOperational)
            store.close()

            let reopened = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            defer { reopened.close() }
            XCTAssertEqual(reopened.entry(for: "kept"), original)
            XCTAssertEqual(reopened.entry(for: "later"), closed ? nil : later)
            XCTAssertTrue(reopened.isOperational())
        }
    }

    func testCloseRejectsReadsAndWritesAndPreservesPersistedRows() throws {
        let store = try makeStore()
        let original = entry(from: photoInfo(id: "kept"), at: 100)
        XCTAssertEqual(store.upsert(original), .inserted)
        store.close()

        XCTAssertFalse(store.isOperational())
        XCTAssertNil(store.entry(for: "kept"))
        XCTAssertFalse(store.upsertBatch([entry(from: photoInfo(id: "rejected"), at: 200)]))
        XCTAssertFalse(store.synchronizeToDisk())
        store.close()

        let reopened = try makeStore()
        defer { reopened.close() }
        XCTAssertEqual(reopened.entry(for: "kept"), original)
        XCTAssertNil(reopened.entry(for: "rejected"))
        XCTAssertTrue(reopened.isOperational())
    }

    func testUnavailableCatalogCannotMasqueradeAsAnEmptyCompletedScan() async throws {
        let store = try makeStore()
        store.close()
        let enqueuer = RecordingEnqueuer()

        do {
            _ = try await runDriver(
                store: store,
                enumerator: StubEnumerator(infos: [photoInfo(id: "A")]),
                engine: enqueuer,
                at: 100
            )
            XCTFail("an unavailable catalog must stop the scan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }

        XCTAssertTrue(enqueuer.enqueued.isEmpty)
        XCTAssertFalse(store.hasCompletedFullScan())
        XCTAssertFalse(store.isOperational())
    }

    func testDriverFullSweepMarksRemovedAndReportsProgress() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B"), photoInfo(id: "C")])
        _ = try await runDriver(store: store, enumerator: enumerator, engine: RecordingEnqueuer(), at: 100)

        // C disappears from the library on the next full scan.
        enumerator.infos = [photoInfo(id: "A"), photoInfo(id: "B")]
        let progressBox = ProgressBox()
        let e2 = RecordingEnqueuer()
        _ = try await runDriver(store: store, enumerator: enumerator, engine: e2, at: 200, progress: progressBox)

        XCTAssertTrue(e2.enqueued.isEmpty)
        XCTAssertEqual(store.entry(for: "C")?.isRemoved, true)
        XCTAssertEqual(progressBox.last?.scanned, 2)
        XCTAssertEqual(progressBox.last?.removed, 1)
        XCTAssertEqual(progressBox.last?.executionProgress?.completedUnitCount, 4)
        XCTAssertEqual(progressBox.last?.executionProgress?.totalUnitCount, 4)
    }

    func testIdentifierSnapshotReportsRealProgressBeforeMetadataEnumeration() async throws {
        let store = try makeStore()
        let progressBox = ProgressBox()
        let enumerator = AbortingEnumerator(
            snapshotIdentifiers: ["A", "B", "C"],
            chunks: [],
            thenThrow: CancellationError()
        )

        do {
            _ = try await runDriver(
                store: store,
                enumerator: enumerator,
                engine: RecordingEnqueuer(),
                at: 100,
                progress: progressBox
            )
            XCTFail("metadata enumeration should abort")
        } catch is CancellationError {
            // expected
        }

        XCTAssertTrue(
            progressBox.values.contains { progress in
                progress.executionProgress
                    == BackupExecutionProgress(
                        completedUnitCount: 3,
                        totalUnitCount: 6
                    )
            }, "the identifier snapshot must prove liveness before metadata creates queue rows")
    }

    func testDriverTargetedScanUpdatesOnlyRequestedIDsAndMarksMissing() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])
        _ = try await runDriver(store: store, enumerator: enumerator, engine: RecordingEnqueuer(), at: 100)
        let aLastSeen = store.entry(for: "A")?.lastSeenAt

        // Targeted pass for B (changed) and D (requested but not in the library to removed).
        enumerator.infos = [photoInfo(id: "B", modified: Date(timeIntervalSince1970: 1_700_060_000))]
        let e2 = RecordingEnqueuer()
        let removals = RemovalBox()
        _ = try await runDriver(
            store: store,
            enumerator: enumerator,
            engine: e2,
            identifiers: ["B", "D"],
            at: 200,
            removals: removals
        )

        XCTAssertEqual(e2.enqueued, ["B"])
        XCTAssertEqual(store.entry(for: "A")?.lastSeenAt, aLastSeen, "a targeted scan must not touch unrelated rows")
        XCTAssertEqual(store.entry(for: "A")?.isRemoved, false)
        XCTAssertNil(store.entry(for: "D"), "a requested id that was never catalogued stays absent, not invented")
        XCTAssertEqual(removals.identifiers, ["D"], "missing sources must be forwarded for queue cancellation")
    }

    /// End-to-end through the real engine + queue store: proves the driver feeds durable queue rows,
    /// exactly the seam the controller composes.
    func testDriverWithRealEngineWritesDurableQueueRows() async throws {
        let store = try makeStore()
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStateStore()),
            queue: queue,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])

        _ = try await PhotoLibraryCatalogSync(
            store: store, enumerator: enumerator, chunkSize: 2, now: { Date(timeIntervalSince1970: 100) }
        ).run(engine: engine)

        XCTAssertEqual(queue.count(), 2, "both new assets must land as durable queue rows")
        XCTAssertEqual(queue.summary().waiting, 2, "first-seen assets enter as discovered/waiting work")
        queue.close()
    }

    /// Abort mid-scan (cancellation reaching the enumerator, or an enumeration failure) must not
    /// advance the catalog for assets it never delivered - they re-yield cleanly on the next pass.
    /// Combined with the queue-row-before-catalog-advance ordering, this closes the data-loss window.
    func testAbortedScanDoesNotStrandUndeliveredAssets() async throws {
        let store = try makeStore()

        // Pass 1 delivers only A, then aborts (the real PhotoKit enumerator finishes with a
        // CancellationError the same way when its detached fetch is cancelled).
        let aborting = AbortingEnumerator(
            snapshotIdentifiers: ["A", "B"],
            chunks: [[photoInfo(id: "A")]],
            thenThrow: CancellationError()
        )
        let e1 = RecordingEnqueuer()
        do {
            _ = try await PhotoLibraryCatalogSync(
                store: store, enumerator: aborting, chunkSize: 1, now: { Date(timeIntervalSince1970: 100) }
            ).run(engine: e1)
            XCTFail("an aborted scan must rethrow, not silently succeed")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(e1.enqueued, ["A"], "the delivered asset was enqueued before the abort")
        XCTAssertNotNil(store.entry(for: "A"), "the delivered asset's catalog row is committed")
        XCTAssertEqual(store.count(), 1, "the abort must not catalog anything beyond what it delivered")

        // Pass 2 is a clean full scan that now also sees B. A is unchanged (not re-enqueued); B was
        // never stranded by the aborted pass, so it re-yields as new.
        let clean = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])
        let e2 = RecordingEnqueuer()
        _ = try await PhotoLibraryCatalogSync(
            store: store, enumerator: clean, chunkSize: 2, now: { Date(timeIntervalSince1970: 200) }
        ).run(engine: e2)

        XCTAssertEqual(e2.enqueued, ["B"], "the previously-undelivered asset re-yields; the delivered one does not")
    }

    /// Models iOS expiration while an instant targeted enqueue is suspended in an uncooperative
    /// dependency. Cancellation is the pass-generation fence: once the lock owner retires, a late
    /// return must not advance the catalog with work that the next launch now owns.
    func testCancelledTargetedEnqueueCannotWriteCatalogAfterLateReturn() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "late")])
        let gate = GatedEnqueuer()
        let sync = PhotoLibraryCatalogSync(
            store: store,
            enumerator: enumerator,
            chunkSize: 1,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let work = Task {
            try await sync.run(engine: gate, identifiers: ["late"])
        }
        await gate.waitUntilEntered()

        // Equivalent to the expiration path canceling instantWorkTask before releasing run ownership.
        work.cancel()
        await gate.release()

        do {
            _ = try await work.value
            XCTFail("a canceled generation must not settle successfully after a late dependency return")
        } catch is CancellationError {
            // expected
        }
        XCTAssertNil(store.entry(for: "late"), "the retired generation must not write the catalog")
    }

    /// The one-time late-render pass starts again after a cancelled pass and does nothing after a complete pass.
    func testLateRenderReconciliationSetsItsFlagOnlyAfterACompletePass() async throws {
        let store = try makeStore()
        let edits = ["a", "b"].map { id in
            info(
                id: id,
                resources: [
                    .init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic"),
                    .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.JPG", mimeType: "image/jpeg"),
                ])
        }
        XCTAssertTrue(store.upsertBatch((edits + [photoInfo(id: "c")]).map { entry(from: $0, at: 100) }))
        let sync = PhotoLibraryCatalogSync(store: store, enumerator: StubEnumerator(infos: []), chunkSize: 1)
        let engine = ReopeningEnqueuer()

        do {
            try await Task { try await sync.reconcileLateRendersOnce(engine: engine) }.value
            XCTFail("the first pass is cancelled after its first page")
        } catch is CancellationError {}
        XCTAssertFalse(store.hasReconciledLateRenders())

        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertTrue(store.hasReconciledLateRenders())
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "a", "b"], "only edits that list their rendered file, once per pass")
        XCTAssertEqual(engine.enqueued, ["a", "b"], "re-opened revisions are queued")
    }

    /// A failed proof read keeps the pages before it checked: the next pass, also after a relaunch, starts at the
    /// failed page and repeats no lookups for the earlier pages (#343).
    func testLateRenderReconciliationContinuesAtThePageWhoseProofReadFailed() async throws {
        var store = try makeStore()
        let infos = ["a", "b", "c", "d"].map(editInfo) + [photoInfo(id: "e")]
        XCTAssertTrue(store.upsertBatch(infos.map { entry(from: $0, at: 100) }))
        let engine = ReopeningEnqueuer(proofUnavailableAt: ["c", "c"])

        try await PhotoLibraryCatalogSync(store: store, enumerator: StubEnumerator(infos: []), chunkSize: 1)
            .reconcileLateRendersOnce(engine: engine)
        XCTAssertFalse(store.hasReconciledLateRenders())
        XCTAssertEqual(engine.reopened, ["a", "b", "c"])

        store.close()
        store = try makeStore()
        let sync = PhotoLibraryCatalogSync(store: store, enumerator: StubEnumerator(infos: []), chunkSize: 1)
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertFalse(store.hasReconciledLateRenders(), "the failed page stays pending")
        XCTAssertEqual(engine.reopened, ["a", "b", "c", "c"])

        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertTrue(store.hasReconciledLateRenders())
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertEqual(engine.reopened, ["a", "b", "c", "c", "c", "d"], "each page is checked until its proof is read")
        XCTAssertEqual(engine.enqueued, ["a", "b", "c", "d"])
    }

    /// A cancelled pass keeps the pages it finished: the next pass, also after a relaunch, continues after them and
    /// checks the cancelled page again (#356).
    func testLateRenderReconciliationContinuesAfterTheFinishedPagesOfACancelledPass() async throws {
        let first = try makeStore()
        let infos = ["a", "b", "c"].map(editInfo) + [photoInfo(id: "d")]
        XCTAssertTrue(first.upsertBatch(infos.map { entry(from: $0, at: 100) }))
        let engine = ReopeningEnqueuer(cancelsAt: "c")

        do {
            try await Task {
                try await PhotoLibraryCatalogSync(store: first, enumerator: StubEnumerator(infos: []), chunkSize: 1)
                    .reconcileLateRendersOnce(engine: engine)
            }.value
            XCTFail("the first pass is cancelled at the page of c")
        } catch is CancellationError {}
        XCTAssertFalse(first.hasReconciledLateRenders())
        XCTAssertEqual(engine.reopened, ["a", "b", "c"])

        first.close()
        let store = try makeStore()
        try await PhotoLibraryCatalogSync(store: store, enumerator: StubEnumerator(infos: []), chunkSize: 1)
            .reconcileLateRendersOnce(engine: engine)
        XCTAssertTrue(store.hasReconciledLateRenders())
        XCTAssertEqual(engine.reopened, ["a", "b", "c", "c"], "the finished pages are not checked again")
        XCTAssertEqual(engine.enqueued, ["a", "b", "c"], "the cancelled page is queued in the next pass")
    }

    /// A failed first page leaves nothing behind; the retry starts at the first page and completes.
    func testLateRenderReconciliationRetriesAFailedFirstPage() async throws {
        let store = try makeStore()
        XCTAssertTrue(store.upsertBatch(["a", "b"].map { entry(from: editInfo($0), at: 100) }))
        let sync = PhotoLibraryCatalogSync(store: store, enumerator: StubEnumerator(infos: []), chunkSize: 1)
        let engine = ReopeningEnqueuer(proofUnavailableAt: ["a"])

        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertFalse(store.hasReconciledLateRenders())
        XCTAssertNil(store.lateRenderSweepResumePoint())
        try await sync.reconcileLateRendersOnce(engine: engine)
        XCTAssertTrue(store.hasReconciledLateRenders())
        XCTAssertNil(store.lateRenderSweepResumePoint(), "a complete pass leaves no resume point")
        XCTAssertEqual(engine.reopened, ["a", "a", "b"])
        XCTAssertEqual(engine.enqueued, ["a", "b"])
    }

    /// The resume point survives a relaunch, and only the completing pass removes it.
    func testLateRenderResumePointIsClearedWhenTheSweepCompletes() throws {
        var store = try makeStore()
        XCTAssertNil(store.lateRenderSweepResumePoint(), "a store without a resume point starts at the first page")
        XCTAssertTrue(store.recordLateRenderSweepResumePoint("0042/L0/001"))
        store.close()
        store = try makeStore()
        XCTAssertEqual(store.lateRenderSweepResumePoint(), "0042/L0/001")
        XCTAssertFalse(store.hasReconciledLateRenders())
        XCTAssertTrue(store.markLateRendersReconciled())
        XCTAssertNil(store.lateRenderSweepResumePoint())
        XCTAssertTrue(store.hasReconciledLateRenders())
    }

    private func editInfo(_ id: String) -> PhotoBackupAssetInfo {
        info(
            id: id,
            resources: [
                .init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic"),
                .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.JPG", mimeType: "image/jpeg"),
            ])
    }

    private func runDriver(
        store: any PhotoLibraryCatalogStore,
        enumerator: any PhotoLibraryAssetEnumerator,
        engine: any UploadBackupCandidateEnqueueing,
        identifiers: [String]? = nil,
        at seconds: TimeInterval,
        progress: ProgressBox? = nil,
        removals: RemovalBox? = nil
    ) async throws -> PhotoLibraryCatalogProgress {
        let onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)?
        if let progress {
            onProgress = { report in progress.record(report) }
        } else {
            onProgress = nil
        }
        let sync = PhotoLibraryCatalogSync(
            store: store,
            enumerator: enumerator,
            chunkSize: 2,
            now: { Date(timeIntervalSince1970: seconds) },
            onProgress: onProgress,
            onRemoved: { identifiers in removals?.record(identifiers) }
        )
        return try await sync.run(engine: engine, identifiers: identifiers)
    }

    /// Records which candidates the driver enqueued.
    private final class RecordingEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let lock = NSLock()
        private var _enqueued: [String] = []
        var enqueued: [String] { lock.withLock { _enqueued } }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            lock.withLock { _enqueued.append(candidate.snapshot.source.identifier) }
            return UploadBackupSyncScanResult()
        }

        func synchronizeQueueToDisk() -> Bool { true }
    }

    /// Re-opens every offered revision and records each offered photo, which the real engine looks up in the
    /// state and identity stores. Without failures, its first call cancels the pass that called it. With failures,
    /// each listed photo makes one call throw `UploadBackupRemoteProofUnavailable` in turn.
    private final class ReopeningEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let lock = NSLock()
        private var _reopened: [String] = []
        private var _enqueued: [String] = []
        private var proofUnavailableAt: [String]
        private let cancelsFirstCall: Bool
        private var cancelsAt: String?
        var reopened: [String] { lock.withLock { _reopened } }
        var enqueued: [String] { lock.withLock { _enqueued } }

        /// Without arguments, the first call cancels its task. `cancelsAt` cancels the call that offers that photo.
        init(proofUnavailableAt: [String] = [], cancelsAt: String? = nil) {
            self.proofUnavailableAt = proofUnavailableAt
            self.cancelsAt = cancelsAt
            cancelsFirstCall = proofUnavailableAt.isEmpty && cancelsAt == nil
        }

        func reopenBackedUpRevisions(
            _ reopenings: [UploadBackupReopening], deferringWithoutRemoteProof: Bool
        ) async throws -> [UploadBackupAssetCandidate] {
            let identifiers = reopenings.map(\.candidate.snapshot.source.identifier)
            let cancels = lock.withLock { () -> Bool in
                guard let cancelsAt, identifiers.contains(cancelsAt) else { return false }
                self.cancelsAt = nil
                return true
            }
            let (isFirstCall, proofUnavailable) = lock.withLock { () -> (Bool, Bool) in
                defer { _reopened += identifiers }
                guard let next = proofUnavailableAt.first, identifiers.contains(next) else {
                    return (_reopened.isEmpty, false)
                }
                proofUnavailableAt.removeFirst()
                return (_reopened.isEmpty, true)
            }
            if proofUnavailable { throw UploadBackupRemoteProofUnavailable() }
            if (isFirstCall && cancelsFirstCall) || cancels { withUnsafeCurrentTask { $0?.cancel() } }
            return reopenings.map(\.candidate)
        }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            lock.withLock { _enqueued.append(candidate.snapshot.source.identifier) }
            return UploadBackupSyncScanResult()
        }

        func synchronizeQueueToDisk() -> Bool { true }
    }

    /// Ignores cancellation until explicitly released, matching a PhotoKit/SDK callback that returns late.
    private actor GatedEnqueuer: UploadBackupCandidateEnqueueing {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func synchronizeQueueToDisk() -> Bool { true }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            if !isReleased {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            return UploadBackupSyncScanResult()
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            isReleased = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private final class RemovalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var identifiers: [String] { lock.withLock { values } }

        func record(_ identifiers: [String]) {
            lock.withLock { values.append(contentsOf: identifiers.sorted()) }
        }
    }

    /// Asserts the catalog has not yet recorded an asset at the moment its candidate is enqueued.
    private final class OrderingEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let store: any PhotoLibraryCatalogStore
        private let lock = NSLock()
        private var _absent: [String: Bool] = [:]
        var catalogAbsentAtEnqueue: [String: Bool] { lock.withLock { _absent } }

        init(store: any PhotoLibraryCatalogStore) { self.store = store }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            let id = candidate.snapshot.source.identifier
            let absent = store.entry(for: id) == nil
            lock.withLock { _absent[id] = absent }
            return UploadBackupSyncScanResult()
        }

        func synchronizeQueueToDisk() -> Bool { true }
    }

    private struct FailingEnqueuer: UploadBackupCandidateEnqueueing {
        func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
            throw UploadError.backend("forced queue failure")
        }

        func synchronizeQueueToDisk() -> Bool { true }
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

    /// Yields the given chunks, then finishes with `thenThrow` - models a scan that aborts partway
    /// (cancellation reaching the producer, or a PhotoKit enumeration failure).
    private final class AbortingEnumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
        private let snapshotIdentifiers: [String]
        private let chunks: [[PhotoBackupAssetInfo]]
        private let thenThrow: any Error
        init(snapshotIdentifiers: [String], chunks: [[PhotoBackupAssetInfo]], thenThrow: any Error) {
            self.snapshotIdentifiers = snapshotIdentifiers
            self.chunks = chunks
            self.thenThrow = thenThrow
        }

        func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error> {
            let identifiers = snapshotIdentifiers
            return AsyncThrowingStream { continuation in
                continuation.yield(
                    PhotoLibraryIdentifierChunk(
                        identifiers: identifiers,
                        totalCount: identifiers.count
                    ))
                continuation.finish()
            }
        }

        func infoChunks(
            identifiers: [String]?, startOffset: Int, chunkSize: Int
        ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            let chunks = chunks
            let error = thenThrow
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish(throwing: error)
            }
        }
    }

    /// Canned enumerator: honors the targeted-identifier filter like PhotoKit would.
    private final class StubEnumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
        private let lock = NSLock()
        private var _infos: [PhotoBackupAssetInfo]
        var infos: [PhotoBackupAssetInfo] {
            get { lock.withLock { _infos } }
            set { lock.withLock { _infos = newValue } }
        }

        init(infos: [PhotoBackupAssetInfo]) { _infos = infos }

        func infoChunks(
            identifiers: [String]?, startOffset: Int, chunkSize: Int
        ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            let all = infos
            let filtered: [PhotoBackupAssetInfo]
            if let identifiers {
                let wanted = Set(identifiers)
                filtered = all.filter { wanted.contains($0.localIdentifier) }
            } else {
                filtered = all
            }
            let selected = Array(filtered.dropFirst(max(0, startOffset)))  // resume point
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

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _last: PhotoLibraryCatalogProgress?
        private var _values: [PhotoLibraryCatalogProgress] = []
        var last: PhotoLibraryCatalogProgress? { lock.withLock { _last } }
        var values: [PhotoLibraryCatalogProgress] { lock.withLock { _values } }
        func record(_ p: PhotoLibraryCatalogProgress) {
            lock.withLock {
                _last = p
                _values.append(p)
            }
        }
    }
}
