import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineOrderMetadataStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func photo(_ node: String, time: Double = 500) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: node),
            captureTime: Date(timeIntervalSince1970: time), mediaType: "image/jpeg")
    }

    func testUnchangedInventorySkipsTheWritePassEvenWhenInputOrderChanges() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let policy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: policy))
        defer { store.close() }
        let items = (0..<1_000).map { photo(String($0), time: Double(500 + $0 / 2)) }
        let classified = Set(items.map(\.uid))
        let syncPasses = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: classified))
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 1)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(
            store.synchronize(items.reversed(), classifiedUIDs: classified), "unchanged inventory needs no write pass")
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 1)
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let added = photo("new-photo", time: 2_000)
        XCTAssertTrue(store.synchronize(items + [added], classifiedUIDs: classified))
        XCTAssertTrue(try store.nextPage(after: items.last?.uid).contains { $0.uid == added.uid })
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 2)
        var retimed = items
        retimed[0] = photo(items[0].uid.nodeID, time: 3_000)
        XCTAssertTrue(store.synchronize(retimed, classifiedUIDs: classified))
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 3)
    }

    func testRepeatedMetadataReadsDoNotWriteOrScanPublicationAgain() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let policy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: policy))
        defer { store.close() }
        let items = [photo("a"), photo("b")]
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.uid, TimelineOrderMetadata()) })
        let recordWrites = PhotoDiagnostics.shared.counter("timeline.order.recordWrite")
        let publishPasses = PhotoDiagnostics.shared.counter("timeline.order.publishPass")
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertTrue(store.record(values))
        XCTAssertTrue(try store.publishCompletedSeconds())
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        for _ in 0..<3 {
            XCTAssertTrue(store.record(values), "already inspected metadata needs no write")
            XCTAssertFalse(try store.publishCompletedSeconds(), "unchanged evidence needs no publication pass")
        }
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.recordWrite"), recordWrites + 1)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.publishPass"), publishPasses + 1)
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let edited = photo("edit")
        XCTAssertTrue(store.synchronize([items[0], edited], classifiedUIDs: [items[0].uid, edited.uid]))
        XCTAssertTrue(store.record([edited.uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.1))]))
        XCTAssertTrue(try store.publishCompletedSeconds(), "new evidence must publish after a skipped read")
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.recordWrite"), recordWrites + 2)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.publishPass"), publishPasses + 2)
    }

    func testFirstDetailInspectionsPublishOnlyTheirSecondsAndRepeatedReadsDoNoWork() throws {
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
        defer { store.close() }
        let items = (0..<1_000).map { photo(String($0), time: Double(500 + $0 / 2)) }
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        let fullPasses = PhotoDiagnostics.shared.counter("timeline.order.publishPass")
        let secondPasses = PhotoDiagnostics.shared.counter("timeline.order.publishSecond")
        let recordWrites = PhotoDiagnostics.shared.counter("timeline.order.recordWrite")
        for item in items {
            XCTAssertTrue(store.recordResolvedMetadata(for: item.uid, metadata: .init(), isClassified: true))
        }
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.publishPass"), fullPasses)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.publishSecond"), secondPasses + items.count)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.recordWrite"), recordWrites + items.count)
        let revision = store.revision
        XCTAssertEqual(revision, items.count / 2, "each complete second publishes once")
        for item in items.reversed() {
            XCTAssertTrue(store.recordResolvedMetadata(for: item.uid, metadata: .init(), isClassified: true))
        }
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.publishPass"), fullPasses)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.publishSecond"), secondPasses + items.count)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.order.recordWrite"), recordWrites + items.count)
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(try store.nextPage().isEmpty)
    }

    func testOnlyUnknownCollisionsAreReadAndASecondIsPublishedTogether() throws {
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
        defer { store.close() }
        let first = photo("a")
        let second = photo("b")
        let singleton = photo("c", time: 501)
        XCTAssertTrue(
            store.synchronize([first, second, singleton], classifiedUIDs: [first.uid, second.uid, singleton.uid]))
        let page = try store.nextPage(limit: 1)
        XCTAssertEqual(page.map(\.uid), [first.uid])
        XCTAssertTrue(page[0].needsOrder)
        XCTAssertTrue(store.record([first.uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.8))]))
        XCTAssertFalse(try store.publishCompletedSeconds())
        XCTAssertEqual(store.enrich([first, second]), [first, second])
        XCTAssertEqual(try store.nextPage().map(\.uid), [second.uid])
        XCTAssertTrue(store.record([second.uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.1))]))
        XCTAssertTrue(try store.publishCompletedSeconds())
        XCTAssertEqual(store.enrich([first, second]).map(\.uid), [second.uid, first.uid])
        XCTAssertTrue(try store.nextPage().isEmpty)
        XCTAssertFalse(try store.publishCompletedSeconds())
    }

    func testAbsentValuesSurviveReopenAndRefreshWithoutRepeatedReads() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let items = [photo("a"), photo("b")]
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertTrue(store.record(Dictionary(uniqueKeysWithValues: items.map { ($0.uid, TimelineOrderMetadata()) })))
        XCTAssertTrue(try store.publishCompletedSeconds())
        store.close()
        let reopened = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        defer { reopened.close() }
        XCTAssertTrue(reopened.synchronize(items.reversed(), classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertTrue(try reopened.nextPage().isEmpty)
        XCTAssertEqual(reopened.enrich(items), items)
    }

    func testReuploadKeepsTheOrderAfterRefreshAndOnAnotherDevice() throws {
        let items = [photo("a-later"), photo("z-earlier")]
        let values: [PhotoUID: TimelineOrderMetadata] = [
            items[0].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.8), stableIdentity: "asset-2"),
            items[1].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.1), stableIdentity: "asset-1"),
        ]
        for _ in 0..<2 {
            let store = try XCTUnwrap(
                TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
            defer { store.close() }
            XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
            XCTAssertTrue(store.record(values))
            XCTAssertTrue(try store.publishCompletedSeconds())
            let edited = photo("0-edit")
            let updated = [edited, items[1]]
            XCTAssertTrue(store.synchronize(updated, classifiedUIDs: Set(updated.map(\.uid))))
            XCTAssertTrue(store.record([edited.uid: values[items[0].uid]!]))
            XCTAssertTrue(try store.publishCompletedSeconds())
            XCTAssertEqual(store.enrich(updated).map(\.uid), [items[1].uid, edited.uid])
            XCTAssertTrue(store.synchronize(updated.reversed(), classifiedUIDs: Set(updated.map(\.uid))))
            XCTAssertEqual(store.enrich(updated).map(\.uid), [items[1].uid, edited.uid])
        }
    }

    func testCorruptCacheRebuildsAndAccountPurgeRemovesItsSidecars() throws {
        let base = try directory()
        let account = LibraryDatabaseLocation.prepareAccountDirectory(uid: "test-account", in: base)
        let url = account.appendingPathComponent(TimelineOrderMetadataStore.databaseFileName)
        try Data("damaged SQLite".utf8).write(to: url)
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        XCTAssertTrue(store.synchronize([photo("a"), photo("b")], classifiedUIDs: []))
        XCTAssertEqual(try store.nextPage().count, 2)
        store.close()
        for suffix in ["-wal", "-shm"] {
            try Data("derived sidecar".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + suffix))
        }
        XCTAssertTrue(LibraryDatabaseLocation.purgeAccountData(uid: "test-account", in: base))
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }
    }

    // MARK: - Issue 447: a cache that another connection holds is kept

    private func filledCache(at url: URL, policy: LibraryDatabasePolicy) throws {
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: policy))
        XCTAssertTrue(store.synchronize([photo("a"), photo("b")], classifiedUIDs: []))
        store.close()
    }

    func testACacheThatCannotBeReadIsStillReplaced() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let policy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        try filledCache(at: url, policy: policy)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: policy), "a new cache replaces it")
        defer { store.close() }

        XCTAssertEqual(try store.nextPage().count, 0, "the earlier rows are gone, as before")
    }

    func testACacheThatAnotherConnectionHoldsIsKeptAndOpensAgainLater() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let policy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)
        try filledCache(at: url, policy: policy)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        let busy = TimelineOrderMetadataStore(url: url, policy: policy)
        let busyOpened = busy != nil
        busy?.close()
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)

        XCTAssertFalse(busyOpened, "a busy cache stays unavailable for now")
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: policy))
        defer { store.close() }
        XCTAssertEqual(try store.nextPage().count, 2, "the cache opens again with its rows")
    }

    private let noWaitPolicy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)

    /// Another connection that holds the file exclusively until `COMMIT`.
    private func exclusiveHolder(of url: URL) throws -> OpaquePointer {
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        return try XCTUnwrap(blocker)
    }

    func testAQuickCheckThatMeetsALockIsNoDamage() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        try filledCache(at: url, policy: noWaitPolicy)
        let blocker = try exclusiveHolder(of: url)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let recorder = SQLiteBusyRecorder(timeoutMs: 0)
        recorder.install(on: raw)

        XCTAssertEqual(TimelineOrderMetadataStore.check(raw, recorder: recorder), .busy)
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(blocker)
        XCTAssertEqual(TimelineOrderMetadataStore.check(raw, recorder: recorder), .healthy)
    }

    func testAQuickCheckOfADamagedCacheStillFindsTheDamage() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        try filledCache(at: url, policy: noWaitPolicy)
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: Int(size) - 4_096))
        try handle.close()
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let recorder = SQLiteBusyRecorder(timeoutMs: 0)
        recorder.install(on: raw)

        XCTAssertEqual(TimelineOrderMetadataStore.check(raw, recorder: recorder), .damaged)
    }

    private func answering(_ failure: SQLiteFailure, volumeIsFull: Bool? = false) -> SQLiteFailureProbe {
        SQLiteFailureProbe(failure: { _, _ in failure }, volumeIsFull: { _, _ in volumeIsFull })
    }

    /// A progress handler that stops the check ends it with `SQLITE_INTERRUPT`: an error, not a problem string.
    func testAQuickCheckThatFailsOnAFullDiskCouldNotVerifyAndIsNoDamage() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        try filledCache(at: url, policy: noWaitPolicy)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let recorder = SQLiteBusyRecorder(timeoutMs: 0)
        recorder.install(on: raw)
        sqlite3_progress_handler(raw, 1, { _ in 1 }, nil)

        let fullDisk: [(String, SQLiteFailure, Bool?)] = [
            ("SQLITE_FULL", SQLiteFailure(code: SQLITE_FULL, systemErrno: 0), false),
            ("CANTOPEN on a full volume", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT), true),
        ]
        for (name, failure, volumeIsFull) in fullDisk {
            XCTAssertEqual(
                TimelineOrderMetadataStore.check(
                    raw, recorder: recorder, probe: answering(failure, volumeIsFull: volumeIsFull)),
                .busy, "\(name): could not verify, no damage")
        }
        let notFullDisk: [(String, SQLiteFailure, Bool?)] = [
            ("SQLITE_CORRUPT on a full volume", SQLiteFailure(code: SQLITE_CORRUPT, systemErrno: 0), true),
            ("bare IOERR", SQLiteFailure(code: SQLITE_IOERR, systemErrno: 0), true),
            ("CANTOPEN on a volume with room", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT), false),
            ("CANTOPEN on an unknown volume", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT), nil),
        ]
        for (name, failure, volumeIsFull) in notFullDisk {
            XCTAssertEqual(
                TimelineOrderMetadataStore.check(
                    raw, recorder: recorder, probe: answering(failure, volumeIsFull: volumeIsFull)),
                .damaged, "\(name): the earlier meaning")
        }
        XCTAssertEqual(
            TimelineOrderMetadataStore.check(raw, recorder: recorder), .damaged,
            "the real failure (SQLITE_INTERRUPT) names no full disk: the earlier meaning")
    }

    func testAProblemStringIsDamageWhateverSQLiteSaysAboutTheDisk() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        try filledCache(at: url, policy: noWaitPolicy)
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 4_096)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: Int(size) - 4_096))
        try handle.close()
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        let recorder = SQLiteBusyRecorder(timeoutMs: 0)
        recorder.install(on: raw)

        XCTAssertEqual(
            TimelineOrderMetadataStore.check(
                raw, recorder: recorder, probe: answering(SQLiteFailure(code: SQLITE_FULL, systemErrno: ENOSPC))),
            .damaged, "the check reads rows, so the answer about the disk does not apply")
    }

    func testAWriteThatMeetsALockKeepsTheCacheAndItsRows() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: noWaitPolicy))
        defer { store.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: []))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        XCTAssertFalse(store.record([items[0].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.2))]))
        let revision = store.rebuildRevision
        XCTAssertFalse(store.rebuildUnlessBusy(), "a lock clears by itself: the cache stays")
        XCTAssertEqual(store.rebuildRevision, revision, "no rebuild happened")
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)

        XCTAssertEqual(try store.nextPage().map(\.uid), items.map(\.uid), "the rows are still there")
        XCTAssertTrue(store.record([items[0].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.2))]))
    }

    func testAnotherFailureStillRebuildsTheCache() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: noWaitPolicy))
        defer { store.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE photo_order;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertThrowsError(try store.nextPage())
        XCTAssertTrue(store.rebuildUnlessBusy(), "a failure that is no lock rebuilds, as before")
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertEqual(try store.nextPage().map(\.uid), items.map(\.uid))
    }

    func testAnEarlierLockDoesNotHoldBackTheRebuildAfterALaterFailure() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url, policy: noWaitPolicy))
        defer { store.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store.record([items[0].uid: .init(exactCaptureTime: Date(timeIntervalSince1970: 500.2))]))
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        // The lock is gone. Later, the table breaks for another reason.
        XCTAssertEqual(sqlite3_exec(writer, "DROP TABLE photo_order;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)

        XCTAssertThrowsError(try store.nextPage())
        XCTAssertTrue(store.rebuildUnlessBusy(), "the earlier lock is forgotten")
    }

    /// A crashed writer leaves a rollback journal that only a writer can recover. The store replaces such a cache.
    func testACacheWithAHotRollbackJournalIsStillReplaced() throws {
        let directory = try directory()
        let source = directory.appendingPathComponent("source.sqlite")
        try filledCache(at: source, policy: noWaitPolicy)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        for statement in [
            "PRAGMA journal_mode=DELETE;", "PRAGMA synchronous=FULL;",
            "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000) "
                + "INSERT INTO photo_order(vol, node, t, second) SELECT 'v', 'n' || i, i, i FROM c;",
            "PRAGMA cache_size=2;", "PRAGMA cache_spill=1;", "BEGIN;",
            "UPDATE photo_order SET identity = hex(randomblob(400));",
        ] {
            XCTAssertEqual(sqlite3_exec(writer, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        // A copy taken while the write runs is what a crash leaves: changed pages and the journal that undoes them.
        let crashed = directory.appendingPathComponent("crashed.sqlite")
        try FileManager.default.copyItem(at: source, to: crashed)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source.path + "-journal"), to: URL(fileURLWithPath: crashed.path + "-journal"))
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: crashed.path + "-journal")).read(upToCount: 8)
        XCTAssertEqual(header, Data([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]), "the journal is hot")

        let store = try XCTUnwrap(
            TimelineOrderMetadataStore(url: crashed, policy: noWaitPolicy), "a new cache replaces it")
        defer { store.close() }
        XCTAssertEqual(try store.nextPage().count, 0, "the earlier rows are gone, as before")
    }

    func testOneHundredThousandPhotosUseBoundedPagesAndRetainTheUpgradeTimeline() throws {
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: directory().appendingPathComponent("order.sqlite")))
        defer { store.close() }
        let items = (0..<100_000).map { photo(String(format: "%06d", $0), time: Double(500 + $0 / 2)) }
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        var cursor: PhotoUID?
        var pages = 0
        var count = 0
        while true {
            let page = try store.nextPage(after: cursor)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 150)
            XCTAssertTrue(page.allSatisfy(\.needsOrder))
            count += page.count
            pages += 1
            cursor = page.last?.uid
        }
        XCTAssertEqual(count, 100_000)
        XCTAssertEqual(pages, 667)
        XCTAssertFalse(store.workQueryPlan().contains("TEMP B-TREE"))
    }

    func testInterruptedPassResumesOnlyUnknownMembersAndLargeSecondsStayUnpublished() throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let items = (0..<1_000).map { photo(String(format: "%04d", $0)) }
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        let firstPage = try store.nextPage()
        XCTAssertEqual(firstPage.count, 150)
        XCTAssertTrue(
            store.record(
                Dictionary(
                    uniqueKeysWithValues: firstPage.map {
                        ($0.uid, TimelineOrderMetadata(exactCaptureTime: Date(timeIntervalSince1970: 500.8)))
                    })))
        XCTAssertFalse(try store.publishCompletedSeconds())
        store.close()
        let reopened = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        defer { reopened.close() }
        XCTAssertTrue(reopened.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertEqual(try reopened.nextPage().first?.uid, items[150].uid)
        XCTAssertEqual(reopened.enrich(items), items)
    }

    func testReadFailureRebuildsOnlyTheDerivedCache() throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("order.sqlite")
        let store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
        defer { store.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE photo_order;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(store.enrich(items), items, "a broken cache must leave the timeline usable")
        XCTAssertTrue(store.synchronize(items, classifiedUIDs: Set(items.map(\.uid))))
        XCTAssertEqual(try store.nextPage().map(\.uid), items.map(\.uid))
    }

    func testUnavailableCacheDoesNotChangeTheExistingTimeline() throws {
        let directory = try directory()
        let blocked = directory.appendingPathComponent("blocked.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertNil(TimelineOrderMetadataStore(url: blocked))
        let timeline = try XCTUnwrap(TimelineMetadataStore(url: directory.appendingPathComponent("library.sqlite")))
        defer { timeline.close() }
        let items = [photo("a"), photo("b")]
        XCTAssertTrue(timeline.save(items).succeeded)
        XCTAssertEqual(try timeline.load(), items)
    }

    func testV105AndBeta1DDLKeepEveryTimelineFieldWithTheNewCache() throws {
        // Both release tags contain this exact DDL and these four feature markers.
        for release in ["1.0.5", "1.1.0-beta.1"] {
            let dir = try directory()
            let url = dir.appendingPathComponent(LibraryDatabaseLocation.databaseFileName)
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, Self.legacyDDL, nil, nil, nil), SQLITE_OK, release)
            let seed = """
                PRAGMA journal_mode=WAL;
                INSERT INTO schema_info VALUES('timeline',1),('photo_tags',1),('burst_members',1),('media_type_evidence',1);
                INSERT INTO photos VALUES('volume','a',500,'image/heic',1,'motion',4032,3024,2.5);
                INSERT INTO photo_tags VALUES('volume','a',0);
                INSERT INTO burst_members VALUES('volume','a','frame',0);
                INSERT INTO store_meta VALUES('timeline.validationToken','cursor');
                """
            XCTAssertEqual(sqlite3_exec(db, seed, nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            let cache = try XCTUnwrap(TimelineOrderMetadataStore(url: dir.appendingPathComponent("order.sqlite")))
            let timeline = try XCTUnwrap(TimelineMetadataStore(url: url))
            let saved = try timeline.load()
            XCTAssertEqual(saved.count, 1, release)
            XCTAssertEqual(saved[0].mediaType, "image/heic")
            XCTAssertEqual(saved[0].relatedVideoID, "motion")
            XCTAssertEqual(saved[0].durationSeconds, 2.5)
            XCTAssertEqual(saved[0].tags, [.favorites])
            XCTAssertEqual(saved[0].burstMemberIDs, ["frame"])
            XCTAssertEqual(timeline.loadDimensions()[saved[0].uid], PhotoPixelDimensions(width: 4032, height: 3024))
            XCTAssertEqual(timeline.validationToken(), "cursor")
            XCTAssertTrue(cache.synchronize(saved, classifiedUIDs: []))
            XCTAssertTrue(timeline.save(cache.enrich(saved)).succeeded)
            timeline.close()
            cache.close()
            let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
            XCTAssertEqual(try reopened.load(), saved)
            XCTAssertEqual(reopened.validationToken(), "cursor")
            reopened.close()
        }
    }

    private static let legacyDDL = """
            CREATE TABLE IF NOT EXISTS schema_info(feature TEXT PRIMARY KEY, version INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS photos(
              vol TEXT NOT NULL,
              node TEXT NOT NULL,
              t REAL NOT NULL,
              mime TEXT NOT NULL DEFAULT 'image/jpeg',
              live INTEGER NOT NULL DEFAULT 0,
              relvid TEXT,
              w INTEGER,
              h INTEGER,
              dur REAL,
              PRIMARY KEY (vol, node)
            );
            CREATE INDEX IF NOT EXISTS idx_photos_timeline ON photos(t, vol, node);
            CREATE TABLE IF NOT EXISTS photo_tags(
              vol TEXT NOT NULL,
              node TEXT NOT NULL,
              tag INTEGER NOT NULL,
              PRIMARY KEY (tag, vol, node)
            );
            CREATE TABLE IF NOT EXISTS burst_members(
              anchor_vol TEXT NOT NULL,
              anchor_node TEXT NOT NULL,
              member_node TEXT NOT NULL,
              seq INTEGER NOT NULL,
              PRIMARY KEY (anchor_vol, anchor_node, seq)
            );
            CREATE TABLE IF NOT EXISTS media_type_evidence(
              vol TEXT NOT NULL,
              node TEXT NOT NULL,
              mime TEXT NOT NULL,
              PRIMARY KEY (vol, node)
            );
            CREATE TABLE IF NOT EXISTS store_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
}
