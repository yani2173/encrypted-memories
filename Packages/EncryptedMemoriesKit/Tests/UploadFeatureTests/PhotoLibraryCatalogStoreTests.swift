import Foundation
import PhotoLibraryBackupAdapter
import SQLite3
import XCTest

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

    /// The controller saves the change token when the first scan reports that it can resume. Without the token, the
    /// next pass after a closed app or a pause started the scan of the whole library over.
    func testFirstFullScanReportsResumableBeforeItsChunksAndAgainWhenItResumes() async throws {
        let store = try makeStore()
        let resumable = ResumableBox(store: store, probe: "A")
        let aborting = AbortingEnumerator(
            snapshotIdentifiers: ["A", "B"],
            chunks: [[photoInfo(id: "A")]],
            thenThrow: CancellationError()
        )
        do {
            _ = try await PhotoLibraryCatalogSync(
                store: store, enumerator: aborting, chunkSize: 1, now: { Date(timeIntervalSince1970: 100) },
                onFirstScanResumable: { resumable.record() }
            ).run(engine: RecordingEnqueuer())
            XCTFail("an aborted scan must rethrow")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(
            resumable.calls, [.init(hasResumePoint: true, probeCatalogued: false)],
            "the scan reports once its snapshot is durable, before it catalogues a photo")
        XCTAssertNotNil(store.fullScanProgress(), "the aborted first scan keeps its snapshot and cursor")

        let enqueuer = RecordingEnqueuer()
        _ = try await PhotoLibraryCatalogSync(
            store: store, enumerator: StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")]), chunkSize: 1,
            now: { Date(timeIntervalSince1970: 200) },
            onFirstScanResumable: { resumable.record() }
        ).run(engine: enqueuer)

        XCTAssertEqual(enqueuer.enqueued, ["B"], "the resumed scan continues with the photo it had not reached")
        XCTAssertEqual(resumable.calls.last, ResumableBox.Call(hasResumePoint: true, probeCatalogued: true))
        XCTAssertEqual(resumable.calls.count, 2)
        XCTAssertTrue(store.hasCompletedFullScan())
    }

    /// A full scan after a completed one is a rescan for an expired or unreadable change history. The controller
    /// starts it over, so a saved token must not let a later pass skip it.
    func testLaterFullScanNeverReportsResumable() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A")])
        let resumable = ResumableBox(store: store, probe: "A")
        for seconds in [100.0, 200.0] {
            _ = try await PhotoLibraryCatalogSync(
                store: store, enumerator: enumerator, now: { Date(timeIntervalSince1970: seconds) },
                onFirstScanResumable: { resumable.record() }
            ).run(engine: RecordingEnqueuer())
        }

        XCTAssertEqual(resumable.calls.count, 1, "only the first scan of the library reports")
    }

    /// A snapshot that never completed resumes nothing: the next pass builds a new one, so no token may be saved.
    func testInterruptedSnapshotNeverReportsResumable() async throws {
        let store = try makeStore()
        let resumable = ResumableBox(store: store, probe: "A")
        do {
            _ = try await PhotoLibraryCatalogSync(
                store: store, enumerator: SnapshotFailingEnumerator(), now: { Date(timeIntervalSince1970: 100) },
                onFirstScanResumable: { resumable.record() }
            ).run(engine: RecordingEnqueuer())
            XCTFail("an interrupted snapshot must rethrow")
        } catch is CancellationError {
            // expected
        }

        XCTAssertTrue(resumable.calls.isEmpty)
        XCTAssertNil(store.fullScanProgress())
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
    }

    /// Re-opens every offered revision. Its first call cancels the pass that called it.
    private final class ReopeningEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let lock = NSLock()
        private var _reopened: [String] = []
        private var _enqueued: [String] = []
        var reopened: [String] { lock.withLock { _reopened } }
        var enqueued: [String] { lock.withLock { _enqueued } }

        func reopenBackedUpRevisions(_ reopenings: [UploadBackupReopening]) async -> [UploadBackupAssetCandidate] {
            let isFirstCall = lock.withLock { () -> Bool in
                defer { _reopened += reopenings.map(\.candidate.snapshot.source.identifier) }
                return _reopened.isEmpty
            }
            if isFirstCall { withUnsafeCurrentTask { $0?.cancel() } }
            return reopenings.map(\.candidate)
        }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            lock.withLock { _enqueued.append(candidate.snapshot.source.identifier) }
            return UploadBackupSyncScanResult()
        }
    }

    /// Ignores cancellation until explicitly released, matching a PhotoKit/SDK callback that returns late.
    private actor GatedEnqueuer: UploadBackupCandidateEnqueueing {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

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
    }

    private struct FailingEnqueuer: UploadBackupCandidateEnqueueing {
        func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
            throw UploadError.backend("forced queue failure")
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

    /// Delivers part of the identifier snapshot, then stops like a cancelled PhotoKit fetch.
    private struct SnapshotFailingEnumerator: PhotoLibraryAssetEnumerator {
        func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<PhotoLibraryIdentifierChunk, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(PhotoLibraryIdentifierChunk(identifiers: ["A"], totalCount: 2))
                continuation.finish(throwing: CancellationError())
            }
        }

        func infoChunks(
            identifiers: [String]?, startOffset: Int, chunkSize: Int
        ) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Records what the catalog held each time a first scan reported that it can resume.
    private final class ResumableBox: @unchecked Sendable {
        struct Call: Equatable {
            var hasResumePoint: Bool
            var probeCatalogued: Bool
        }

        private let store: any PhotoLibraryCatalogStore
        private let probe: String
        private let lock = NSLock()
        private var values: [Call] = []
        var calls: [Call] { lock.withLock { values } }

        init(store: any PhotoLibraryCatalogStore, probe: String) {
            self.store = store
            self.probe = probe
        }

        func record() {
            let call = Call(
                hasResumePoint: store.fullScanProgress() != nil, probeCatalogued: store.entry(for: probe) != nil)
            lock.withLock { values.append(call) }
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
