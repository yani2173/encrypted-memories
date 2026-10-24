import SQLite3
import XCTest

@testable import PhotosCore

/// Tests schema, ordering, incremental saves, learned metadata, and account purge for timeline metadata.
///
/// Each test uses a scratch directory so SQLite side effects cannot escape the fixture.
final class TimelineMetadataStoreTests: XCTestCase {
    private let uid = "user-DB1"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeStore(
        in dir: URL,
        name: String = "library-v1.sqlite",
        policy: LibraryDatabasePolicy = .conservative
    ) throws -> (TimelineMetadataStore, URL) {
        let url = dir.appendingPathComponent(name)
        let store = try XCTUnwrap(TimelineMetadataStore(url: url, policy: policy))
        return (store, url)
    }

    private func makeItem(
        vol: String = "vol1",
        node: String,
        t: Double,
        mime: String = "image/jpeg",
        live: Bool = false,
        relvid: String? = nil,
        dur: Double? = nil,
        tags: Set<PhotoTag> = [],
        burst: [String] = []
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: vol, nodeID: node),
            captureTime: Date(timeIntervalSince1970: t),
            mediaType: mime,
            isLivePhoto: live,
            relatedVideoID: relvid,
            durationSeconds: dur,
            tags: tags,
            burstMemberIDs: burst
        )
    }

    func testRefinedSameSecondSavesKeepTheLegacyDigestWithoutAFullLibrarySort() throws {
        let (store, url) = try makeStore(in: makeTempDir())
        defer { store.close() }
        let items = (0..<10_000).map { makeItem(node: String(format: "%06d", $0), t: Double(1000 + $0 / 2)) }
        XCTAssertTrue(store.save(items).succeeded)
        let digestSQL = "SELECT value FROM store_meta WHERE key='timeline.digest';"
        let legacyDigest = rawRows(url, digestSQL)
        XCTAssertEqual(legacyDigest, [["c6fffba523f8ba6359231d501cab22c03da0bb0d7421cfb1c01a2918f51768d3"]])
        #if DEBUG
            let fullSorts = store.fullSaveSortCount
        #endif
        var refined = items
        for index in stride(from: 0, to: items.count, by: 2) {
            refined[index].timelineOrder = .init(exactCaptureTime: items[index].captureTime.addingTimeInterval(0.8))
            refined[index + 1].timelineOrder = .init(exactCaptureTime: items[index].captureTime.addingTimeInterval(0.1))
            refined.swapAt(index, index + 1)
        }
        let saved = store.save(refined, validationToken: "cursor")
        XCTAssertTrue(saved.succeeded)
        XCTAssertTrue(saved.skippedUnchanged)
        #if DEBUG
            XCTAssertEqual(store.fullSaveSortCount, fullSorts, "same-second correction must not sort the full library")
        #endif
        XCTAssertEqual(rawRows(url, digestSQL), legacyDigest)
        XCTAssertEqual(try store.load(), items)
        XCTAssertEqual(store.validationToken(), "cursor")
        // Truly unordered seconds still need the original canonical fallback.
        XCTAssertTrue(store.save(Array(refined.reversed())).skippedUnchanged)
        XCTAssertEqual(rawRows(url, digestSQL), legacyDigest)
    }

    func testStoredCursorTimestampSurvivesReopenAndUnchangedSaves() throws {
        let directory = try makeTempDir()
        let (store, url) = try makeStore(in: directory)
        let items = [makeItem(node: "private-node", t: 10)]
        XCTAssertNil(store.validationTokenStoredAt())
        XCTAssertTrue(store.save(items, validationToken: "private-cursor").succeeded)
        let storedAt = try XCTUnwrap(store.validationTokenStoredAt())
        XCTAssertTrue(store.save(items, validationToken: "private-cursor").succeeded)
        XCTAssertEqual(store.validationTokenStoredAt(), storedAt)
        XCTAssertTrue(store.save(items + [makeItem(node: "second", t: 20)]).succeeded)
        XCTAssertEqual(store.validationTokenStoredAt(), storedAt)
        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url, policy: .conservative))
        defer { reopened.close() }
        XCTAssertEqual(reopened.validationTokenStoredAt(), storedAt)
        XCTAssertTrue(reopened.save(items, validationToken: nil).succeeded)
        XCTAssertNil(reopened.validationTokenStoredAt())
    }

    func testLegacyCursorAgeStaysUnknownUntilTheCursorChanges() throws {
        let (store, url) = try makeStore(in: try makeTempDir())
        defer { store.close() }
        XCTAssertTrue(store.save([], validationToken: "legacy-cursor").succeeded)
        rawExec(url, "DELETE FROM store_meta WHERE key='timeline.validationTokenStoredAt';")
        XCTAssertNil(store.validationTokenStoredAt())
        XCTAssertTrue(store.save([], validationToken: "legacy-cursor").succeeded)
        XCTAssertNil(store.validationTokenStoredAt())
        XCTAssertTrue(store.save([], validationToken: "new-cursor").succeeded)
        XCTAssertNotNil(store.validationTokenStoredAt())
    }

    func testItemsForUIDsReturnsCaptureTimeAndMediaTypeOfKnownPhotosOnly() throws {
        let (store, _) = try makeStore(in: try makeTempDir())
        let photo = makeItem(node: "photo", t: 10)
        let video = makeItem(node: "video", t: 20, mime: "video/quicktime", tags: [.videos])
        XCTAssertTrue(store.save([photo, video]).succeeded)

        let items = store.items(for: [video.uid, PhotoUID(volumeID: "vol1", nodeID: "unknown"), photo.uid])

        XCTAssertEqual(items.map(\.uid), [video.uid, photo.uid])
        XCTAssertEqual(items.map(\.captureTime), [video.captureTime, photo.captureTime])
        XCTAssertEqual(items.map(\.isVideo), [true, false])
        XCTAssertTrue(store.items(for: []).isEmpty)
    }

    /// Reads rows through a separate raw connection so assertions see exactly what is on disk
    /// (normalized rows, not what the store's own decode layer reconstructs).
    private func rawRows(_ dbURL: URL, _ sql: String) -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for column in 0..<sqlite3_column_count(stmt) {
                row.append(sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "NULL")
            }
            rows.append(row)
        }
        return rows
    }

    private func rawExec(_ dbURL: URL, _ sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    private func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Double) {
        let start = Date()
        let value = try body()
        let ms = Date().timeIntervalSince(start) * 1000
        print("[DBMicroPerf] \(label)=\(String(format: "%.2f", ms))ms")
        return (value, ms)
    }

    private func makeSyntheticItem(_ index: Int, tagsOverride: Set<PhotoTag>? = nil) -> PhotoItem {
        let isVideo = index.isMultiple(of: 11)
        let isLive = index.isMultiple(of: 17)
        let node = String(format: "node-%05d", index)
        let tags: Set<PhotoTag>
        if let tagsOverride {
            tags = tagsOverride
        } else if isVideo {
            tags = [.videos]
        } else if index.isMultiple(of: 19) {
            tags = [.favorites]
        } else {
            tags = []
        }
        let burstMembers =
            index.isMultiple(of: 97)
            ? [String(format: "burst-%05d-a", index), String(format: "burst-%05d-b", index)]
            : []
        return makeItem(
            vol: "vol\(index % 3)",
            node: node,
            t: Double(1_700_000_000 + (index / 4)),
            mime: isVideo ? "video/quicktime" : "image/jpeg",
            live: isLive,
            relvid: isLive ? String(format: "video-%05d", index) : nil,
            dur: isVideo ? Double(30 + (index % 90)) : nil,
            tags: tags,
            burst: burstMembers
        )
    }

    func testSchemaCreationStampsFeatureVersions() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)

        XCTAssertEqual(
            store.schemaInfoVersions(),
            [
                "timeline": 1,
                "photo_tags": 1,
                "burst_members": 1,
                "media_type_evidence": 1,
            ])

        let tables = Set(rawRows(url, "SELECT name FROM sqlite_master WHERE type='table';").map { $0[0] })
        XCTAssertTrue(tables.isSuperset(of: ["schema_info", "photos", "photo_tags", "burst_members"]))
        let indexes = Set(rawRows(url, "SELECT name FROM sqlite_master WHERE type='index';").map { $0[0] })
        XCTAssertTrue(indexes.contains("idx_photos_timeline"))
        store.close()
    }

    func testNewerOnDiskSchemaVersionFailsClosedWithoutDeletingTimeline() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        store.save([makeItem(node: "n1", t: 100)])
        store.close()

        // Simulate a store written by a future build: version above what this build supports.
        rawExec(
            url,
            """
            UPDATE schema_info SET version = 99 WHERE feature = 'timeline';
            DROP INDEX idx_photos_timeline;
            """)

        XCTAssertNil(TimelineMetadataStore(url: url))
        XCTAssertEqual(rawRows(url, "SELECT node FROM photos;").map { $0[0] }, ["n1"])
        XCTAssertEqual(rawRows(url, "SELECT version FROM schema_info WHERE feature='timeline';")[0][0], "99")
        XCTAssertTrue(
            rawRows(url, "SELECT name FROM sqlite_schema WHERE name='idx_photos_timeline';").isEmpty,
            "an incompatible file must not receive missing schema objects"
        )
    }

    func testMarkerlessWrongShapeFailsClosedWithoutStampingOrRepairing() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("markerless.sqlite")
        rawExec(
            url,
            """
            CREATE TABLE photos(vol TEXT NOT NULL, node TEXT NOT NULL, PRIMARY KEY(vol, node));
            INSERT INTO photos(vol, node) VALUES('legacy-volume', 'legacy-node');
            """)
        let objectsBefore = rawRows(
            url,
            "SELECT type, name, tbl_name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name;"
        )

        XCTAssertNil(TimelineMetadataStore(url: url))

        XCTAssertEqual(
            rawRows(
                url,
                "SELECT type, name, tbl_name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name;"
            ),
            objectsBefore
        )
        XCTAssertEqual(rawRows(url, "SELECT vol, node FROM photos;"), [["legacy-volume", "legacy-node"]])
        XCTAssertTrue(rawRows(url, "SELECT name FROM sqlite_schema WHERE name='schema_info';").isEmpty)
    }

    func testCurrentMarkerWithDamagedShapeFailsClosedWithoutRepairingIt() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        store.save([makeItem(node: "kept", t: 1)])
        store.close()
        rawExec(url, "DROP INDEX idx_photos_timeline;")

        XCTAssertNil(TimelineMetadataStore(url: url))
        XCTAssertEqual(rawRows(url, "SELECT node FROM photos;"), [["kept"]])
        XCTAssertTrue(rawRows(url, "SELECT name FROM sqlite_schema WHERE name='idx_photos_timeline';").isEmpty)
    }

    func testCurrentMarkerWithSemanticallyDifferentIndexFailsClosedWithoutRewritingIt() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        store.save([makeItem(node: "kept", t: 1)])
        store.close()
        rawExec(
            url,
            """
            DROP INDEX idx_photos_timeline;
            CREATE INDEX idx_photos_timeline ON photos(t DESC, vol, node);
            """)

        XCTAssertNil(TimelineMetadataStore(url: url))
        XCTAssertEqual(rawRows(url, "SELECT node FROM photos;"), [["kept"]])
        XCTAssertTrue(
            rawRows(url, "SELECT sql FROM sqlite_schema WHERE name='idx_photos_timeline';")[0][0]
                .contains("t DESC"),
            "an incompatible operational schema must remain byte-for-byte under owner control"
        )
    }

    func testEqualCaptureTimeRowsLoadInTimelineOrderAcrossCycles() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)

        // Same capture second everywhere; only (vol, node) breaks the tie. Input is shuffled.
        let expectedOrder = [
            makeItem(vol: "volA", node: "node1", t: 500),
            makeItem(vol: "volA", node: "node9", t: 500),
            makeItem(vol: "volB", node: "node2", t: 500),
            makeItem(vol: "volB", node: "node3", t: 501),
        ]
        store.save([expectedOrder[2], expectedOrder[0], expectedOrder[3], expectedOrder[1]])
        let first = try store.load()
        XCTAssertEqual(first, expectedOrder, "load must return (t, vol, node) order")

        // A second save from a differently-shuffled array must not reshuffle equal-t rows.
        store.save([expectedOrder[3], expectedOrder[1], expectedOrder[0], expectedOrder[2]])
        XCTAssertEqual(try store.load(), expectedOrder, "order must be stable across save/load cycles")
        store.close()
    }

    func testInMemoryComparatorMatchesDatabaseOrder() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let items = [
            makeItem(vol: "b", node: "a", t: 10),
            makeItem(vol: "a", node: "z", t: 10),
            makeItem(vol: "a", node: "a", t: 11),
            makeItem(vol: "c", node: "c", t: 9),
        ]
        store.save(items)
        XCTAssertEqual(
            try store.load(),
            items.sorted(by: TimelineOrder.areInIncreasingOrder),
            "TimelineOrder must be exactly the order the DB index produces"
        )
        store.close()
    }

    func testTagsNormalizeIntoPhotoTagRowsAndRoundTrip() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)

        let video = makeItem(node: "vid", t: 100, mime: "video/quicktime", dur: 12.5, tags: [.videos, .favorites])
        let plain = makeItem(node: "img", t: 200)
        store.save([video, plain])

        // Normalized rows on disk - one row per (tag, vol, node), no CSV blob anywhere.
        let rows = rawRows(url, "SELECT tag, vol, node FROM photo_tags ORDER BY tag;")
        XCTAssertEqual(
            rows,
            [
                [String(PhotoTag.favorites.rawValue), "vol1", "vid"],
                [String(PhotoTag.videos.rawValue), "vol1", "vid"],
            ])
        let photoColumns = rawRows(url, "SELECT name FROM pragma_table_info('photos');").map { $0[0] }
        XCTAssertFalse(photoColumns.contains("tags"), "photos must not carry a serialized tags blob")
        XCTAssertFalse(photoColumns.contains("burst"), "photos must not carry a serialized burst blob")

        let loaded = try store.load()
        XCTAssertEqual(loaded, [video, plain])
        XCTAssertEqual(loaded.first?.tags, [.videos, .favorites])
        XCTAssertEqual(loaded.first?.durationSeconds, 12.5)
        store.close()
    }

    func testBurstMembersNormalizeIntoRowsAndRoundTripInSequence() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)

        // Presentation order is deliberately not sorted - seq must preserve it exactly.
        let members = ["member-c", "member-a", "member-b"]
        let anchor = makeItem(node: "anchor", t: 100, tags: [.bursts], burst: members)
        store.save([anchor])

        let rows = rawRows(
            url,
            "SELECT member_node, seq FROM burst_members WHERE anchor_vol='vol1' AND anchor_node='anchor' ORDER BY seq;")
        XCTAssertEqual(rows, [["member-c", "0"], ["member-a", "1"], ["member-b", "2"]])

        for _ in 0..<2 {  // stable across repeated save/load cycles
            let loaded = try store.load()
            XCTAssertEqual(loaded.first?.burstMemberIDs, members)
            store.save(loaded)
        }
        store.close()
    }

    func testIdenticalSaveShortCircuitsWithoutRewritingRows() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let items = (0..<50).map { makeItem(node: "n\($0)", t: Double(1000 + $0)) }

        let first = store.save(items)
        XCTAssertFalse(first.skippedUnchanged)
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(first.upsertedRows, 50)
        XCTAssertEqual(first.generation, 1)

        // Identical content in a different arrival order is still a no-op (canonical digest).
        let second = store.save(items.shuffled())
        XCTAssertTrue(second.skippedUnchanged, "unchanged refresh must not rewrite rows")
        XCTAssertEqual(second.upsertedRows, 0)
        XCTAssertEqual(second.generation, 1, "generation must not advance on a skipped save")

        // The skip must survive a cold start: digest is persisted, not process state.
        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        let afterReopen = reopened.save(items)
        XCTAssertTrue(afterReopen.skippedUnchanged, "digest short-circuit must persist across launches")
        XCTAssertEqual(try reopened.load(), items.sorted(by: TimelineOrder.areInIncreasingOrder))

        // Any real change breaks the short-circuit again - but only the new row is written; the
        // 50 unchanged survivors are not rewritten (O(changes)).
        let changed = reopened.save(items + [makeItem(node: "new", t: 2000)])
        XCTAssertFalse(changed.skippedUnchanged)
        XCTAssertTrue(changed.succeeded)
        XCTAssertEqual(changed.upsertedRows, 1)
        reopened.close()
        store.close()
    }

    func testAntiJoinSweepRemovesRowsMissingFromLatestRefresh() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200, tags: [.videos])
        let c = makeItem(node: "c", t: 300)

        let first = store.save([a, b, c])
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(first.upsertedRows, 3)

        let second = store.save([a, c])  // b disappeared from the full enumeration
        XCTAssertFalse(second.skippedUnchanged)
        XCTAssertEqual(second.generation, 2)
        XCTAssertEqual(second.sweptRows, 1, "exactly the vanished row is swept")
        // O(changes): a and c are unchanged survivors, so nothing is rewritten for them.
        XCTAssertEqual(second.upsertedRows, 0, "unchanged survivors must not be rewritten")
        XCTAssertEqual(try store.load(), [a, c])

        // Feature tables follow: b's tag rows must not orphan.
        XCTAssertTrue(rawRows(url, "SELECT * FROM photo_tags WHERE node='b';").isEmpty)
        store.close()
    }

    /// A photo moved to the trash must not come back from the stored timeline at the next launch.
    func testRemovedPhotosLeaveTheStoredTimelineAndReturnWithTheNextListing() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200, tags: [.favorites], burst: ["b", "b2"])
        let c = makeItem(node: "c", t: 300)
        XCTAssertTrue(store.save([a, b, c], validationToken: "event-a").succeeded)

        XCTAssertTrue(store.remove([b.uid]))
        store.close()

        let (relaunched, _) = try makeStore(in: dir)
        XCTAssertEqual(try relaunched.load(), [a, c])
        XCTAssertTrue(rawRows(url, "SELECT * FROM photo_tags WHERE node='b';").isEmpty)
        XCTAssertTrue(rawRows(url, "SELECT * FROM burst_members WHERE anchor_node='b';").isEmpty)
        XCTAssertEqual(relaunched.validationToken(), "event-a")

        // A restore lists the same photos as before the removal; that listing must still be written.
        let restored = relaunched.save([a, b, c], validationToken: "event-b")
        XCTAssertFalse(restored.skippedUnchanged)
        XCTAssertEqual(try relaunched.load(), [a, b, c])
        relaunched.close()
    }

    func testOnlyRowsWithChangedContentAreRewrittenNullSafe() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200, mime: "video/quicktime", relvid: "v1", dur: 5)
        let c = makeItem(node: "c", t: 300)
        XCTAssertEqual(store.save([a, b, c]).upsertedRows, 3)

        // Change one field of b (duration); a and c stay byte-identical.
        let bChanged = makeItem(node: "b", t: 200, mime: "video/quicktime", relvid: "v1", dur: 9)
        let s1 = store.save([a, bChanged, c])
        XCTAssertEqual(s1.upsertedRows, 1, "only the row whose content changed is rewritten")
        XCTAssertEqual(s1.sweptRows, 0)
        XCTAssertEqual(try store.load(), [a, bChanged, c])

        // null-safe: clearing a nullable field (relvid "v1" becomes nil) is a real change.
        let bNulled = makeItem(node: "b", t: 200, mime: "video/quicktime", relvid: nil, dur: 9)
        let s2 = store.save([a, bNulled, c])
        XCTAssertEqual(s2.upsertedRows, 1, "NULL-safe guard must detect a value -> NULL transition")
        XCTAssertNil(try store.load().first { $0.uid == b.uid }?.relatedVideoID)

        // Re-saving identical content is a full no-op (digest short-circuit).
        XCTAssertTrue(store.save([a, bNulled, c]).skippedUnchanged)
        store.close()
    }

    func testTimelineLoadQueryPlanRidesTimelineIndex() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        store.save([makeItem(node: "n", t: 1)])

        let plan = store.timelineLoadQueryPlan()
        XCTAssertTrue(plan.contains("idx_photos_timeline"), "ordered load must ride the timeline index; plan: \(plan)")
        XCTAssertFalse(plan.uppercased().contains("TEMP B-TREE"), "no sort pass allowed; plan: \(plan)")
        store.close()
    }

    func testLargeSaveTruncatesWalToPolicyLimit() throws {
        let dir = try makeTempDir()
        let policy = LibraryDatabasePolicy(
            mmapBytes: 0,
            cacheSizeKiB: 2_048,
            busyTimeoutMs: 3_000,
            journalSizeLimitBytes: 4_096,
            walCheckpointRowThreshold: 1
        )
        let (store, url) = try makeStore(in: dir, policy: policy)

        let result = store.save((0..<1_000).map { makeSyntheticItem($0) })

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.upsertedRows, 0)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertLessThanOrEqual(
            fileSize(walURL),
            Int64(policy.journalSizeLimitBytes),
            "large saves must not leave a high-water WAL sidecar behind"
        )
        store.close()
    }

    func testTwentyThousandRowSyntheticSaveLoadSkipAndChangedUpsertGuard() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)

        let items = (0..<20_000).map { makeSyntheticItem($0) }
        let ordered = items.sorted(by: TimelineOrder.areInIncreasingOrder)

        let (firstSave, firstSaveMs) = timed("20k.initialSave") {
            store.save(items)
        }
        XCTAssertTrue(firstSave.succeeded)
        XCTAssertFalse(firstSave.skippedUnchanged)
        XCTAssertEqual(firstSave.generation, 1)
        XCTAssertEqual(firstSave.upsertedRows, 20_000)
        XCTAssertEqual(firstSave.sweptRows, 0)
        XCTAssertEqual(store.count(), 20_000)

        let (loaded, loadMs) = try timed("20k.load") {
            try store.load()
        }
        XCTAssertEqual(loaded.count, 20_000)
        XCTAssertEqual(loaded.first, ordered.first)
        XCTAssertEqual(loaded.last, ordered.last)
        XCTAssertEqual(loaded, ordered)

        let plan = store.timelineLoadQueryPlan()
        XCTAssertTrue(
            plan.contains("idx_photos_timeline"), "20k ordered load must ride the timeline index; plan: \(plan)")
        XCTAssertFalse(
            plan.uppercased().contains("TEMP B-TREE"), "20k load must not sort via temp b-tree; plan: \(plan)")

        let (skipSave, skipMs) = timed("20k.unchangedSkip") {
            store.save(items)
        }
        XCTAssertTrue(skipSave.succeeded)
        XCTAssertTrue(skipSave.skippedUnchanged)
        XCTAssertEqual(skipSave.generation, 1)
        XCTAssertEqual(skipSave.upsertedRows, 0)
        XCTAssertEqual(skipSave.sweptRows, 0)

        let additions = (20_000..<20_025).map { makeSyntheticItem($0, tagsOverride: [.favorites]) }
        let changedItems = Array(items.dropFirst(100)) + additions
        let (changedSave, changedMs) = timed("20k.changedUpsert") {
            store.save(changedItems)
        }
        XCTAssertTrue(changedSave.succeeded)
        XCTAssertFalse(changedSave.skippedUnchanged)
        XCTAssertEqual(changedSave.generation, 2)
        // O(changes): a +25 / −100 refresh writes only the 25 new rows and sweeps only the 100
        // vanished rows - the 19,900 unchanged survivors are not rewritten. This bounds refresh writes.
        XCTAssertEqual(changedSave.upsertedRows, 25)
        XCTAssertEqual(changedSave.sweptRows, 100)
        XCTAssertEqual(store.count(), 19_925)

        let (changedLoaded, changedLoadMs) = try timed("20k.changedLoad") {
            try store.load()
        }
        XCTAssertEqual(changedLoaded.count, 19_925)
        XCTAssertEqual(changedLoaded, changedItems.sorted(by: TimelineOrder.areInIncreasingOrder))

        print(
            "[DBMicroPerf] 20k.summary initialSaveMs=\(String(format: "%.2f", firstSaveMs)) "
                + "loadMs=\(String(format: "%.2f", loadMs)) " + "skipMs=\(String(format: "%.2f", skipMs)) "
                + "changedSaveMs=\(String(format: "%.2f", changedMs)) "
                + "changedLoadMs=\(String(format: "%.2f", changedLoadMs))"
        )
        store.close()
    }

    func testPurgeAccountDataRemovesLibraryDatabaseAndSidecars() throws {
        let base = try makeTempDir()
        let accountDir = LibraryDatabaseLocation.prepareAccountDirectory(uid: uid, in: base)

        // Backup exclusion: the store is re-derivable server metadata.
        let resourceValues = try accountDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)

        let store = try XCTUnwrap(TimelineMetadataStore(url: LibraryDatabaseLocation.databaseURL(uid: uid, in: base)))
        store.save([makeItem(node: "n", t: 1)])
        // WAL mode leaves sidecars next to the main file while the connection is open.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: LibraryDatabaseLocation.databaseURL(uid: uid, in: base).path))
        store.close()

        XCTAssertTrue(LibraryDatabaseLocation.purgeAccountData(uid: uid, in: base))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: accountDir.path), "whole per-account directory must be gone")
        // Another account's directory survives.
        LibraryDatabaseLocation.prepareAccountDirectory(uid: "OTHER", in: base)
        LibraryDatabaseLocation.purgeAccountData(uid: uid, in: base)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: LibraryDatabaseLocation.accountDirectory(uid: "OTHER", in: base).path))
    }

    func testValidationTokenPersistsAndUpdatesWithoutTimelineChurn() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let items = [makeItem(node: "stable", t: 100)]

        let first = store.save(items, validationToken: "event-a")
        XCTAssertTrue(first.succeeded)
        XCTAssertFalse(first.skippedUnchanged)
        XCTAssertEqual(store.validationToken(), "event-a")

        let updatedToken = store.save(items, validationToken: "event-b")
        XCTAssertTrue(updatedToken.succeeded)
        XCTAssertTrue(updatedToken.skippedUnchanged)
        XCTAssertEqual(
            updatedToken.generation, first.generation,
            "a metadata-only token update must not rebuild the grid generation")
        XCTAssertEqual(updatedToken.upsertedRows, 0)
        XCTAssertEqual(store.validationToken(), "event-b")

        // The original overload deliberately preserves the paired revision for non-authoritative local writes.
        XCTAssertTrue(store.save(items).skippedUnchanged)
        XCTAssertEqual(store.validationToken(), "event-b")
        store.close()

        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        XCTAssertEqual(reopened.validationToken(), "event-b")
        let cleared = reopened.save(items, validationToken: nil)
        XCTAssertTrue(cleared.succeeded)
        XCTAssertTrue(cleared.skippedUnchanged)
        XCTAssertNil(reopened.validationToken())
        reopened.close()
    }

    /// Sign-out purges SDK and library metadata directories. Every account-owned file must be gone,
    /// so adding a new store file without purge coverage fails this walk.
    func testSimulatedSignOutLeavesNoAccountOwnedMetadataFiles() throws {
        let base = try makeTempDir()  // stands in for Application Support
        let sdkDir = try makeTempDir()  // stands in for Caches/EncryptedMemories/sdk

        // Real library store with data (creates library-v1.sqlite + WAL sidecars).
        LibraryDatabaseLocation.prepareAccountDirectory(uid: uid, in: base)
        let store = try XCTUnwrap(TimelineMetadataStore(url: LibraryDatabaseLocation.databaseURL(uid: uid, in: base)))
        store.save([makeItem(node: "n", t: 1, tags: [.videos], burst: ["m"])])
        store.close()
        // Current SDK-side metadata files.
        for name in SDKMetadataStore.metadataFileNames(uid: uid) {
            try Data("x".utf8).write(to: sdkDir.appendingPathComponent(name))
        }

        SDKMetadataStore.purgeMetadata(in: sdkDir, uid: uid)
        LibraryDatabaseLocation.purgeAccountData(uid: uid, in: base)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: LibraryDatabaseLocation.accountDirectory(uid: uid, in: base).path),
            "library account directory orphaned after sign-out"
        )
        let sdkLeftovers = try FileManager.default.contentsOfDirectory(atPath: sdkDir.path)
        XCTAssertTrue(sdkLeftovers.isEmpty, "orphaned after sign-out: \(sdkLeftovers)")
        let baseLeftovers =
            FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(baseLeftovers.contains { $0.contains(uid) }, "account-tied files under base: \(baseLeftovers)")
    }

    func testLearnedVideoDurationPersistsAndSurvivesNilTimelineRefresh() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let videoWithoutDuration = makeItem(node: "video", t: 100, mime: "video/quicktime", tags: [.videos])
        store.save([videoWithoutDuration])

        let learned = store.updateDurations([videoWithoutDuration.uid: 42.75])
        XCTAssertTrue(learned.succeeded)
        XCTAssertEqual(learned.updatedRows, 1)
        XCTAssertEqual(try store.load().first?.durationSeconds, 42.75)
        XCTAssertEqual(rawRows(url, "SELECT dur FROM photos WHERE node='video';"), [["42.75"]])

        // A later changed enumeration still omits duration. It may update other timeline fields, but must not
        // erase metadata already decrypted for this video.
        let changedEnumeration = makeItem(
            node: "video",
            t: 101,
            mime: "video/quicktime",
            tags: [.videos]
        )
        let refresh = store.save([changedEnumeration])
        XCTAssertTrue(refresh.succeeded)
        XCTAssertEqual(try store.load().first?.durationSeconds, 42.75)
        store.close()
    }

    func testDurationUpdateIsValidatedAndZeroWriteWhenUnchangedOrUnknown() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let video = makeItem(node: "video", t: 100, mime: "video/quicktime", tags: [.videos])
        store.save([video])

        XCTAssertEqual(store.updateDurations([video.uid: 12.5]).updatedRows, 1)
        XCTAssertEqual(store.updateDurations([video.uid: 12.5]).updatedRows, 0)
        XCTAssertEqual(store.updateDurations([video.uid: 0]).updatedRows, 0)
        XCTAssertEqual(store.updateDurations([video.uid: .nan]).updatedRows, 0)
        let unknown = PhotoUID(volumeID: "vol1", nodeID: "unknown")
        XCTAssertEqual(store.updateDurations([unknown: 99]).updatedRows, 0)
        XCTAssertEqual(try store.load().first?.durationSeconds, 12.5)
        store.close()
    }

    private func dims(_ w: Int, _ h: Int) throws -> PhotoPixelDimensions {
        try XCTUnwrap(PhotoPixelDimensions(width: w, height: h))
    }

    func testDimensionsRoundTripAndSurviveReopen() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200)
        store.save([a, b])

        let size = try dims(320, 240)
        let result = store.updateDimensions([a.uid: size])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.updatedRows, 1)

        // On disk as real columns; undimensioned rows stay null (absent from the bulk load).
        XCTAssertEqual(rawRows(url, "SELECT w, h FROM photos WHERE node='a';"), [["320", "240"]])
        XCTAssertEqual(rawRows(url, "SELECT w, h FROM photos WHERE node='b';"), [["NULL", "NULL"]])
        XCTAssertEqual(store.loadDimensions(), [a.uid: size])

        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        XCTAssertEqual(reopened.loadDimensions(), [a.uid: size], "dimensions must survive reopen")
        reopened.close()
    }

    func testTimelineRefreshDoesNotClobberLearnedDimensions() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200)
        store.save([a, b])
        store.updateDimensions([a.uid: try dims(320, 240)])

        // A changed refresh writes only changed/new rows and never references w/h - learned
        // dimensions on unchanged rows must survive.
        let changed = store.save([a, b, makeItem(node: "c", t: 300)])
        XCTAssertFalse(changed.skippedUnchanged)
        XCTAssertEqual(store.loadDimensions(), [a.uid: try dims(320, 240)])

        // An unchanged refresh short-circuits - dimensions are not part of the timeline digest,
        // so recording them must not break the no-op skip.
        store.updateDimensions([b.uid: try dims(100, 100)])
        let skipped = store.save([a, b, makeItem(node: "c", t: 300)])
        XCTAssertTrue(skipped.skippedUnchanged, "dimension updates must not invalidate the save digest")
        XCTAssertEqual(store.loadDimensions().count, 2)
        store.close()
    }

    func testDimensionUpdateIsNoOpWhenUnchangedOrAlreadyLearned() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        store.save([a])

        XCTAssertEqual(store.updateDimensions([a.uid: try dims(320, 240)]).updatedRows, 1)
        // Repeating the same values produces zero writes.
        XCTAssertEqual(store.updateDimensions([a.uid: try dims(320, 240)]).updatedRows, 0)
        // different values in default fill mode still produce zero writes; first-seen-wins protects
        // dimensions already stored by an earlier decode.
        XCTAssertEqual(store.updateDimensions([a.uid: try dims(999, 111)]).updatedRows, 0)
        XCTAssertEqual(rawRows(url, "SELECT w, h FROM photos WHERE node='a';"), [["320", "240"]])
        store.close()
    }

    func testOverwriteModeReplacesOnlyChangedValues() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200)
        store.save([a, b])
        store.updateDimensions([a.uid: try dims(320, 240), b.uid: try dims(100, 100)])

        // Future true-dimension writer: upgrades a (differs), skips b (identical values).
        let result = store.updateDimensions(
            [a.uid: try dims(4032, 3024), b.uid: try dims(100, 100)],
            overwrite: true
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.updatedRows, 1)
        XCTAssertEqual(store.loadDimensions(), [a.uid: try dims(4032, 3024), b.uid: try dims(100, 100)])
        store.close()
    }

    func testDimensionUpdateIgnoresUnknownRows() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        store.save([makeItem(node: "a", t: 100)])

        let unknown = PhotoUID(volumeID: "vol1", nodeID: "never-enumerated")
        let result = store.updateDimensions([unknown: try dims(320, 240)])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.updatedRows, 0, "dimension updates must never invent photo rows")
        XCTAssertEqual(store.count(), 1)
        XCTAssertTrue(store.loadDimensions().isEmpty)
        store.close()
    }

    func testMediaTypeEvidenceRepairsRowsTagsAndPersistsDurably() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let missedVideo = makeItem(node: "missed-video", t: 100)
        let falseVideo = makeItem(
            node: "false-video",
            t: 200,
            mime: "video/quicktime",
            tags: [.videos]
        )
        store.save([missedVideo, falseVideo])

        let result = store.recordMediaTypeEvidence([
            missedVideo.uid: "Video/QuickTime",
            falseVideo.uid: "image/heic",
            PhotoUID(volumeID: "vol1", nodeID: "unsupported"): "application/octet-stream",
        ])

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.changedRows, 2)
        XCTAssertEqual(store.mediaTypeEvidenceRevision(), 1)
        XCTAssertEqual(
            store.mediaTypeEvidence(volumeID: "vol1"),
            [
                "missed-video": "video/quicktime",
                "false-video": "image/heic",
            ])
        let loaded = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.uid.nodeID, $0) })
        XCTAssertEqual(loaded["missed-video"]?.mediaType, "video/quicktime")
        XCTAssertTrue(loaded["missed-video"]?.tags.contains(.videos) == true)
        XCTAssertEqual(loaded["false-video"]?.mediaType, "image/heic")
        XCTAssertTrue(loaded["false-video"]?.tags.contains(.videos) == false)

        // Replaying the same batch is a zero-write no-op and does not publish a fake refresh.
        XCTAssertEqual(
            store.recordMediaTypeEvidence([
                missedVideo.uid: "video/quicktime",
                falseVideo.uid: "image/heic",
            ]).changedRows, 0)
        XCTAssertEqual(store.mediaTypeEvidenceRevision(), 1)

        let uploadCheckpoint = PhotoUID(volumeID: "vol1", nodeID: "fresh-upload")
        XCTAssertEqual(
            store.recordMediaTypeEvidence(
                [uploadCheckpoint: "video/quicktime"],
                publishRevision: false
            ).changedRows, 1)
        XCTAssertEqual(store.mediaTypeEvidenceRevision(), 1)
        XCTAssertEqual(try XCTUnwrap(store.mediaTypeEvidence(volumeID: "vol1"))["fresh-upload"], "video/quicktime")
        XCTAssertEqual(store.unmaterializedMediaTypeEvidenceNodeIDs(volumeID: "vol1"), ["fresh-upload"])

        XCTAssertTrue(store.pruneUnmaterializedMediaTypeEvidence(volumeID: "vol1"))
        XCTAssertTrue(store.unmaterializedMediaTypeEvidenceNodeIDs(volumeID: "vol1").isEmpty)
        XCTAssertNil(try XCTUnwrap(store.mediaTypeEvidence(volumeID: "vol1"))["fresh-upload"])
        XCTAssertEqual(try XCTUnwrap(store.mediaTypeEvidence(volumeID: "vol1"))["missed-video"], "video/quicktime")

        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        XCTAssertEqual(reopened.mediaTypeEvidenceRevision(), 1)
        XCTAssertEqual(try XCTUnwrap(reopened.mediaTypeEvidence(volumeID: "vol1"))["missed-video"], "video/quicktime")
        XCTAssertTrue(try reopened.load().first(where: { $0.uid == missedVideo.uid })?.isVideo == true)
        reopened.close()
    }
}
