import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineOrderFirstLaunchTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    fileprivate static func photos(_ count: Int) -> [PhotoItem] {
        (0..<count).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: String(format: "%06d", $0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0 / 2)), mediaType: "image/jpeg")
        }
    }

    func testLargeSynchronizationServesAListingBetweenCommittedChunks() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        var items = Self.photos(100_000)
        // One collision spans the first write chunk, so a detail read cannot publish it prematurely.
        items[1] = PhotoItem(
            uid: items[1].uid, captureTime: Date(timeIntervalSince1970: 100_000), mediaType: "image/jpeg")
        items[99_999] = PhotoItem(uid: items[99_999].uid, captureTime: items[0].captureTime, mediaType: "image/jpeg")
        let task = await owner.start(items, action: .observe)
        let succeeded = await task.value
        let probe = await owner.probeResult()
        XCTAssertTrue(succeeded)
        XCTAssertGreaterThan(probe.classified, 0)
        XCTAssertLessThan(probe.classified, 100_000, "the listing must run before synchronization finishes")
        XCTAssertEqual(probe.rows, probe.classified, "the yielded chunk must already be committed")
        XCTAssertTrue(probe.recorded, "a detail checkpoint must not encounter an open sync transaction")
        XCTAssertFalse(probe.published, "an incomplete inventory must not publish a completed second")
        await owner.close()
    }

    func testCancelledSynchronizationResumesAfterReopenWithoutLosingEvidenceOrSweepingEarly() async throws {
        let url = try directory().appendingPathComponent("order.sqlite")
        let owner = try CacheOwner(url: url)
        let items = Self.photos(10_000)
        await owner.seedInventory(items)
        let task = await owner.start(items, action: .cancel, probeAfter: items.count / 2)
        let succeeded = await task.value
        let probe = await owner.probeResult()
        XCTAssertFalse(succeeded)
        XCTAssertGreaterThan(probe.classified, 0)
        XCTAssertLessThan(probe.classified, items.count)
        XCTAssertEqual(probe.classified, items.count / 2)
        XCTAssertEqual(probe.rows, items.count + 1, "no sweep may run before every inventory block commits")
        let retained = await owner.storedUIDs()
        XCTAssertTrue(
            Set(items.map(\.uid)).isSubset(of: retained), "every valid existing row must survive interruption")
        await owner.close()
        let resumed = try CacheOwner(url: url)
        let retry = await resumed.start(items, action: .observe)
        let retrySucceeded = await retry.value
        XCTAssertTrue(retrySucceeded)
        let rows = await resumed.rowCount()
        XCTAssertEqual(rows, items.count)
        let firstUnknown = try await resumed.firstUnknown()
        XCTAssertEqual(firstUnknown, items[1].uid, "the first chunk's detail checkpoint must survive restart")
        let control = try CacheOwner(url: directory().appendingPathComponent("control.sqlite"))
        await control.seedInventory(items)
        let complete = await control.start(items, action: .observe)
        let completeSucceeded = await complete.value
        XCTAssertTrue(completeSucceeded)
        let resumedRows = await resumed.storedUIDs()
        let controlRows = await control.storedUIDs()
        XCTAssertEqual(resumedRows, controlRows)
        let resumedItems = await resumed.enriched(items)
        let controlItems = await control.enriched(items)
        XCTAssertEqual(resumedItems, controlItems)
        await control.close()
        await resumed.close()
    }

    func testReaderRebuildDuringSynchronizationResumesWithoutDeletingFreshEvidence() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let items = Self.photos(10_000)
        let task = await owner.start(items, action: .readerRebuild)
        let succeeded = await task.value
        let probe = await owner.probeResult()
        XCTAssertLessThan(probe.classified, items.count)
        XCTAssertTrue(probe.recorded, "the reader must rebuild and checkpoint the fresh cache")
        XCTAssertTrue(succeeded, "the pass must resume on the reader's replacement cache")
        let rows = await owner.rowCount()
        XCTAssertEqual(rows, items.count)
        let firstUnknown = try await owner.firstUnknown()
        XCTAssertEqual(firstUnknown, items[2].uid, "a second rebuild must not erase fresh evidence")
        await owner.close()
    }

    func testASecondReaderRebuildDoesNotRestartTheSamePassAgain() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let task = await owner.start(Self.photos(10_000), action: .readerRebuildTwice)
        let succeeded = await task.value
        XCTAssertFalse(succeeded, "a pass may resume after only one reader rebuild")
        _ = await owner.probeResult()
        let rebuilds = await owner.rebuildCount()
        XCTAssertEqual(rebuilds, 2, "the fixture must rebuild during both synchronization attempts")
        let rows = await owner.rowCount()
        XCTAssertEqual(rows, 2, "a third synchronization must not replace the second reader's checkpoint")
        await owner.close()
    }

    func testCancellationAfterReaderRebuildDoesNotBeginAnotherSQLPass() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let syncPasses = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        let task = await owner.start(Self.photos(10_000), action: .readerRebuildCancel)
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        _ = await owner.probeResult()
        let rebuilds = await owner.rebuildCount()
        XCTAssertEqual(rebuilds, 1)
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 1,
            "cancellation must reject new SQL preparation on the replacement cache")
        let rows = await owner.rowCount()
        XCTAssertEqual(rows, 2)
        await owner.close()
    }

    func testResumedPassCannotReplaceANewerInventoryAfterItsReaderRetry() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let syncPasses = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        let task = await owner.start(Self.photos(10_000), action: .readerRebuildThenReplace)
        let succeeded = await task.value
        _ = await owner.probeResult()
        let rebuilds = await owner.rebuildCount()
        XCTAssertEqual(rebuilds, 1, "the fixture must rebuild before replacing the resumed inventory")
        XCTAssertFalse(succeeded, "the resumed pass must not replace a newer inventory")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 3,
            "only the original pass, one reader retry, and the replacement may prepare SQL")
        let rows = await owner.rowCount()
        XCTAssertEqual(rows, 1, "the replacement inventory must keep its committed rows")
        let firstUnknown = try await owner.firstUnknown()
        XCTAssertNil(firstUnknown)
        await owner.close()
    }

    func testReaderRebuildDoesNotLetTheOldPassReplaceANewerInventory() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let task = await owner.start(Self.photos(10_000), action: .readerRebuildReplace)
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        _ = await owner.probeResult()
        let rows = await owner.rowCount()
        XCTAssertEqual(rows, 2, "the old inventory must not restart over the replacement")
        let firstUnknown = try await owner.firstUnknown()
        XCTAssertNil(firstUnknown, "replacement evidence must remain intact")
        await owner.close()
    }

    func testReaderRebuildDoesNotLetTheOldPassReopenAClosedOwner() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let task = await owner.start(Self.photos(10_000), action: .readerRebuildClose)
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        let closed = await owner.isClosed
        XCTAssertTrue(closed)
    }

    func testReplacementInventoryCannotBeOverwrittenByASuspendedPass() async throws {
        let owner = try CacheOwner(url: directory().appendingPathComponent("order.sqlite"))
        let syncPasses = PhotoDiagnostics.shared.counter("timeline.order.syncPass")
        let task = await owner.start(Self.photos(10_000), action: .replace)
        let succeeded = await task.value
        _ = await owner.probeResult()
        XCTAssertFalse(succeeded, "the replaced pass must reject its old scratch keys")
        XCTAssertEqual(
            PhotoDiagnostics.shared.counter("timeline.order.syncPass"), syncPasses + 2,
            "a replacement must not let either inventory restart without reader recovery")
        let rows = await owner.rowCount()
        XCTAssertEqual(rows, 1)
        let firstUnknown = try await owner.firstUnknown()
        XCTAssertNil(firstUnknown)
        await owner.close()
    }

    func testShutdownJoinsTheYieldingPassBeforeClosingAndPurgingItsAccount() async throws {
        let directory = try directory()
        let owner = try CacheOwner(url: directory.appendingPathComponent("order.sqlite"))
        let task = await owner.start(Self.photos(10_000), action: .shutdown)
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        await owner.waitForShutdown()
        let closed = await owner.isClosed
        XCTAssertTrue(closed)
        try FileManager.default.removeItem(at: directory)
        let replacement = try CacheOwner(url: try self.directory().appendingPathComponent("order.sqlite"))
        let next = await replacement.start(Self.photos(2), action: .observe)
        let nextSucceeded = await next.value
        XCTAssertTrue(nextSucceeded)
        await replacement.close()
    }

    func testMeasureSameSecondImportCosts() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_ORDER_MEASURE"] == "1" else {
            throw XCTSkip("Set TIMELINE_ORDER_MEASURE=1 to measure the 5,000-photo import")
        }
        let count = 5_000
        for run in 1...3 {
            let dir = try directory()
            let items = Self.photos(count).map {
                PhotoItem(uid: $0.uid, captureTime: Date(timeIntervalSince1970: 500), mediaType: "image/jpeg")
            }
            let timeline = try XCTUnwrap(TimelineMetadataStore(url: dir.appendingPathComponent("library.sqlite")))
            XCTAssertTrue(timeline.save(items).succeeded)
            let owner = try CacheOwner(url: dir.appendingPathComponent("order.sqlite"))
            let start = Date()
            let task = await owner.start(items, action: .measure)
            let succeeded = await task.value
            XCTAssertTrue(succeeded)
            let syncMs = Date().timeIntervalSince(start) * 1000
            await owner.installImportEvidence(items)
            let enrichment = await owner.measuredEnrichment(items)
            XCTAssertEqual(enrichment.items.first?.uid, items.last?.uid)
            let saveStart = Date()
            XCTAssertTrue(timeline.save(enrichment.items).skippedUnchanged)
            let saveMs = Date().timeIntervalSince(saveStart) * 1000
            let probe = await owner.probeResult()
            print(
                "ORDER_IMPORT count=\(count) run=\(run) sync_ms=\(syncMs) listing_wait_ms=\(probe.waitMs) enrich_ms=\(enrichment.durationMs) save_ms=\(saveMs)"
            )
            timeline.close()
            await owner.close()
        }
    }

    func testMeasureFirstLaunchAndRefinedSaveCosts() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_ORDER_MEASURE"] == "1" else {
            throw XCTSkip("Set TIMELINE_ORDER_MEASURE=1 to measure 10,000 and 100,000 photos")
        }
        for count in [10_000, 100_000] {
            for run in 1...3 {
                let dir = try directory()
                let items = Self.photos(count)
                let timeline = try XCTUnwrap(TimelineMetadataStore(url: dir.appendingPathComponent("library.sqlite")))
                XCTAssertTrue(timeline.save(items).succeeded)
                var refined = items
                for index in stride(from: 0, to: count, by: 2) {
                    refined[index].timelineOrder = .init(
                        exactCaptureTime: items[index].captureTime.addingTimeInterval(0.8))
                    refined[index + 1].timelineOrder = .init(
                        exactCaptureTime: items[index].captureTime.addingTimeInterval(0.1))
                    refined.swapAt(index, index + 1)
                }
                let saveStart = Date()
                XCTAssertTrue(timeline.save(refined).skippedUnchanged)
                let saveMs = Date().timeIntervalSince(saveStart) * 1000
                timeline.close()
                let owner = try CacheOwner(url: dir.appendingPathComponent("order.sqlite"))
                let start = Date()
                let task = await owner.start(items, action: .observe)
                let succeeded = await task.value
                let syncMs = Date().timeIntervalSince(start) * 1000
                XCTAssertTrue(succeeded)
                let probe = await owner.probeResult()
                let enrichMs = await owner.enrichmentCost(items)
                print(
                    "ORDER_COST count=\(count) run=\(run) sync_ms=\(syncMs) listing_wait_ms=\(probe.waitMs) enrich_ms=\(enrichMs) save_ms=\(saveMs)"
                )
                await owner.close()
            }
        }
    }
}

private actor CacheOwner {
    enum Action: Sendable, Equatable {
        case observe, measure, cancel, replace, shutdown, readerRebuild, readerRebuildReplace, readerRebuildClose
        case readerRebuildTwice, readerRebuildCancel, readerRebuildThenReplace
    }
    struct Probe: Sendable {
        var classified = 0
        var rows = 0
        var recorded = false
        var published = false
        var waitMs = 0.0
    }
    private let store: TimelineOrderMetadataStore
    private let url: URL
    private let gate = JoinedShutdownGate()
    private var task: Task<Bool, Never>?
    private var probe: Task<Probe, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var classified = 0
    private var retryReplacementScheduled = false
    private(set) var isClosed = false

    init(url: URL) throws {
        self.url = url
        store = try XCTUnwrap(TimelineOrderMetadataStore(url: url))
    }

    func start(_ items: [PhotoItem], action: Action, probeAfter: Int = 1) -> Task<Bool, Never> {
        classified = 0
        retryReplacementScheduled = false
        probe = nil
        let task = Task(priority: .background) {
            (try? await self.gate.withAdmission {
                await self.synchronize(items, action: action, probeAfter: probeAfter)
            }) ?? false
        }
        self.task = task
        return task
    }

    private func synchronize(_ items: [PhotoItem], action: Action, probeAfter: Int) async -> Bool {
        await store.synchronizeInChunks(
            items,
            isClassified: { _ in
                self.classified += 1
                if self.classified == probeAfter
                    || (action == .readerRebuildTwice
                        && self.classified == probeAfter + TimelineOrderMetadataStore.synchronizationChunkSize)
                    || (action == .readerRebuildThenReplace && self.store.rebuildRevision == 1
                        && !self.retryReplacementScheduled)
                {
                    let queuedAt = Date()
                    let inspectionAction: Action =
                        action == .readerRebuildThenReplace
                        ? (self.classified == probeAfter ? .readerRebuild : .replace) : action
                    if action == .readerRebuildThenReplace, inspectionAction == .replace {
                        self.retryReplacementScheduled = true
                    }
                    self.probe = Task(priority: .userInitiated) {
                        await self.inspect(items[0], action: inspectionAction, queuedAt: queuedAt)
                    }
                }
                return true
            })
    }

    private func inspect(_ item: PhotoItem, action: Action, queuedAt: Date) async -> Probe {
        let revision = store.revision
        let recorded =
            action != .measure && store.recordResolvedMetadata(for: item.uid, metadata: .init(), isClassified: true)
        var readerRecorded = false
        if [.readerRebuild, .readerRebuildReplace, .readerRebuildClose, .readerRebuildTwice, .readerRebuildCancel]
            .contains(action)
        {
            var db: OpaquePointer?
            if sqlite3_open(url.path, &db) == SQLITE_OK {
                _ = sqlite3_exec(db, "DROP TABLE photo_order;", nil, nil, nil)
            }
            sqlite3_close(db)
            _ = store.enrich([item])
            // A detail checkpoint can arrive after the reader rebuild and before synchronization resumes.
            db = nil
            if sqlite3_open(url.path, &db) == SQLITE_OK {
                _ = sqlite3_exec(
                    db,
                    "INSERT INTO photo_order(vol,node,t,second,mime_seen) VALUES('volume','000000',500,500,1),('volume','000001',500,500,1);",
                    nil, nil, nil)
            }
            sqlite3_close(db)
            readerRecorded = store.record([
                item.uid: .init(exactCaptureTime: item.captureTime.addingTimeInterval(0.8)),
                PhotoUID(volumeID: "volume", nodeID: "000001"): .init(
                    exactCaptureTime: item.captureTime.addingTimeInterval(0.1)),
            ])
        }
        let result = Probe(
            classified: classified, rows: rowCount(), recorded: action == .readerRebuild ? readerRecorded : recorded,
            published: ((try? store.publishCompletedSeconds()) ?? false) || store.revision != revision,
            waitMs: Date().timeIntervalSince(queuedAt) * 1000)
        switch action {
        case .observe, .measure, .readerRebuild, .readerRebuildTwice, .readerRebuildThenReplace: break
        case .readerRebuildReplace:
            _ = await store.synchronizeInChunks(
                TimelineOrderFirstLaunchTests.photos(2), isClassified: { _ in true })
        case .readerRebuildClose: close()
        case .cancel, .readerRebuildCancel: task?.cancel()
        case .replace:
            _ = await store.synchronizeInChunks(
                [TimelineOrderFirstLaunchTests.photos(1)[0]], isClassified: { _ in true })
        case .shutdown:
            gate.closeAdmission()
            shutdownTask = Task { await self.gate.run { await self.close() } }
        }
        return result
    }

    func seedInventory(_ items: [PhotoItem]) {
        let stale = PhotoItem(
            uid: PhotoUID(volumeID: "volume", nodeID: "stale"),
            captureTime: Date(timeIntervalSince1970: 1), mediaType: "image/jpeg")
        _ = store.synchronize(items + [stale], isClassified: { _ in true })
        _ = store.record([
            items[2_000].uid: .init(exactCaptureTime: items[2_000].captureTime.addingTimeInterval(0.8)),
            items[2_001].uid: .init(exactCaptureTime: items[2_001].captureTime.addingTimeInterval(0.1)),
        ])
        _ = try? store.publishCompletedSeconds()
    }

    func probeResult() async -> Probe { await probe?.value ?? Probe() }
    func waitForShutdown() async { await shutdownTask?.value }
    func rebuildCount() -> UInt64 { store.rebuildRevision }
    func firstUnknown() throws -> PhotoUID? { try store.nextPage().first?.uid }
    func enriched(_ items: [PhotoItem]) -> [PhotoItem] { store.enrich(items) }
    func storedUIDs() -> Set<PhotoUID> {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT vol,node FROM photo_order;", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var result: Set<PhotoUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let vol = sqlite3_column_text(stmt, 0), let node = sqlite3_column_text(stmt, 1) else { continue }
            result.insert(PhotoUID(volumeID: String(cString: vol), nodeID: String(cString: node)))
        }
        return result
    }
    func close() {
        store.close()
        isClosed = true
    }
    func installImportEvidence(_ items: [PhotoItem]) {
        let metadata = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { index, item in
                (
                    item.uid,
                    TimelineOrderMetadata(
                        exactCaptureTime: item.captureTime.addingTimeInterval(0.1),
                        stableIdentity: String(format: "%06d", items.count - index))
                )
            })
        _ = store.record(metadata)
        _ = try? store.publishCompletedSeconds()
    }
    func measuredEnrichment(_ items: [PhotoItem]) -> (items: [PhotoItem], durationMs: Double) {
        let start = Date()
        let enriched = store.enrich(items)
        return (enriched, Date().timeIntervalSince(start) * 1000)
    }
    func enrichmentCost(_ items: [PhotoItem]) -> Double {
        let start = Date()
        _ = store.enrich(items)
        return Date().timeIntervalSince(start) * 1000
    }
    func rowCount() -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM photo_order;", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }
}
