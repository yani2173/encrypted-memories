import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

private actor SettlementLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !open else { return }
        open = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }
}

private final class SettlementEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [String] {
        lock.withLock { events }
    }
}

private final class SettlementStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UploadQueueStats()

    func store(_ stats: UploadQueueStats) {
        lock.withLock { value = stats }
    }

    var snapshot: UploadQueueStats {
        lock.withLock { value }
    }
}

private final class SettlementSequenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [UInt64] = []
    private var firstItems: [UploadItem] = []
    private var lastStats = UploadQueueStats()

    func record(_ sequence: UInt64, items: [UploadItem], stats: UploadQueueStats) {
        lock.withLock {
            if sequences.isEmpty { firstItems = items }
            sequences.append(sequence)
            lastStats = stats
        }
    }

    var received: [UInt64] { lock.withLock { sequences } }
    var itemsOfFirstEvent: [UploadItem] { lock.withLock { firstItems } }
    var latestStats: UploadQueueStats { lock.withLock { lastStats } }
}

/// Counts the reads of the durable rows and returns fixed rows, whatever its operational state says.
private final class ReadCountingSettlementStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let rows: [UploadManualSettlementRecord]
    private let operational: Bool

    init(rows: [UploadManualSettlementRecord] = [], operational: Bool = true) {
        self.rows = rows
        self.operational = operational
    }

    var readCount: Int { lock.withLock { reads } }

    func isOperational() -> Bool { operational }
    func upsert(_ record: UploadManualSettlementRecord) -> Bool { false }
    func record(for queueItemID: UploadQueueItemID) -> UploadManualSettlementRecord? { nil }
    func remove(queueItemID: UploadQueueItemID) -> Bool { false }
    func close() {}

    func allRecords() -> [UploadManualSettlementRecord] {
        lock.withLock { reads += 1 }
        return rows
    }
}

private final class SettlementIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: SettlementEventLog?
    private let recordStarted: SettlementLatch?
    private let recordGate: SettlementLatch?
    private let invalidationStarted: SettlementLatch?
    private let invalidationGate: SettlementLatch?
    private var failuresRemaining: Int
    private var _recordedCount = 0
    private var _reconciliationCount = 0
    private var _invalidationCount = 0

    init(
        failuresRemaining: Int = 0,
        eventLog: SettlementEventLog? = nil,
        recordStarted: SettlementLatch? = nil,
        recordGate: SettlementLatch? = nil,
        invalidationStarted: SettlementLatch? = nil,
        invalidationGate: SettlementLatch? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.eventLog = eventLog
        self.recordStarted = recordStarted
        self.recordGate = recordGate
        self.invalidationStarted = invalidationStarted
        self.invalidationGate = invalidationGate
    }

    var recordedCount: Int { lock.withLock { _recordedCount } }
    var reconciliationCount: Int { lock.withLock { _reconciliationCount } }
    var invalidationCount: Int { lock.withLock { _invalidationCount } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        UploadPreflightResult(
            identity: UploadIdentity(
                correctedName: descriptor.filename,
                nameHash: "name-hash",
                sha1Hex: String(repeating: "a", count: 40),
                sha1Digest: Data(repeating: 0xAA, count: 20),
                contentHash: "content-hash"
            ),
            decision: .upload
        )
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async throws {
        eventLog?.append("manifest")
        await recordStarted?.signal()
        await recordGate?.wait()
        let shouldFail = lock.withLock { () -> Bool in
            _recordedCount += 1
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if shouldFail {
            throw UploadError.backend("manifest settlement failed")
        }
    }

    func invalidateCachedRemoteState() async {
        lock.withLock { _invalidationCount += 1 }
        await invalidationStarted?.signal()
        await invalidationGate?.wait()
    }

    func remoteCommitNeedsReconciliation(_ descriptor: UploadResourceDescriptor) async {
        lock.withLock { _reconciliationCount += 1 }
    }
}

private final class SettlementUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities(
        canUpload: true,
        supportsCancel: true,
        supportsPauseResume: false,
        supportsResumeAcrossRelaunch: false
    )

    private let lock = NSLock()
    private let waitsForRelease: Bool
    private let started = SettlementLatch()
    private let release = SettlementLatch()
    private let cancelStarted = SettlementLatch()
    private var _requests: [PhotoUploadRequest] = []
    private var _cancelledTokens: [UUID] = []

    init(waitsForRelease: Bool = false) {
        self.waitsForRelease = waitsForRelease
    }

    var requestCount: Int { lock.withLock { _requests.count } }
    var cancelledCount: Int { lock.withLock { _cancelledTokens.count } }

    func waitUntilStarted() async { await started.wait() }
    func waitUntilCancelled() async { await cancelStarted.wait() }
    func releaseUpload() async { await release.signal() }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        lock.withLock { _requests.append(request) }
        await started.signal()
        if waitsForRelease { await release.wait() }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {
        lock.withLock { _cancelledTokens.append(token) }
        await cancelStarted.signal()
    }
}

private final class FailingSettlementStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UploadQueueItemID: UploadManualSettlementRecord] = [:]
    private var failed = false
    private let failOnFirstRead: Bool
    private let failOnUpsert: Bool
    private let failAfterFirstUpsert: Bool

    init(
        failOnFirstRead: Bool = false,
        failOnUpsert: Bool = false,
        failAfterFirstUpsert: Bool = false
    ) {
        self.failOnFirstRead = failOnFirstRead
        self.failOnUpsert = failOnUpsert
        self.failAfterFirstUpsert = failAfterFirstUpsert
    }

    func isOperational() -> Bool { lock.withLock { !failed } }

    @discardableResult
    func upsert(_ record: UploadManualSettlementRecord) -> Bool {
        lock.withLock {
            guard !failed else { return false }
            if failOnUpsert {
                failed = true
                return false
            }
            records[record.queueItemID] = record
            if failAfterFirstUpsert { failed = true }
            return true
        }
    }

    func record(for queueItemID: UploadQueueItemID) -> UploadManualSettlementRecord? {
        lock.withLock {
            guard !failed else { return nil }
            if failOnFirstRead {
                failed = true
                return nil
            }
            return records[queueItemID]
        }
    }

    func allRecords() -> [UploadManualSettlementRecord] {
        lock.withLock { failed ? [] : Array(records.values) }
    }

    @discardableResult
    func remove(queueItemID: UploadQueueItemID) -> Bool {
        lock.withLock {
            guard !failed else { return false }
            records.removeValue(forKey: queueItemID)
            return true
        }
    }

    func close() { lock.withLock { failed = true } }
}

private final class SettlementAlbums: AlbumAttaching, @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: SettlementEventLog?
    private let addStarted: SettlementLatch?
    private let addGate: SettlementLatch?
    private let addFinished: SettlementLatch?
    private var failuresRemaining: Int
    private var _added: [(PhotoUID, String)] = []

    init(
        failuresRemaining: Int = 0,
        eventLog: SettlementEventLog? = nil,
        addStarted: SettlementLatch? = nil,
        addGate: SettlementLatch? = nil,
        addFinished: SettlementLatch? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.eventLog = eventLog
        self.addStarted = addStarted
        self.addGate = addGate
        self.addFinished = addFinished
    }

    var added: [(PhotoUID, String)] { lock.withLock { _added } }

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        switch target {
        case .library:
            return nil
        case .existingAlbum(let id, _):
            return id
        case .newAlbum:
            return "new-album"
        }
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {
        eventLog?.append("album")
        await addStarted?.signal()
        await addGate?.wait()
        let shouldFail = lock.withLock { () -> Bool in
            _added.append((uid, albumID))
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
        if shouldFail { throw UploadError.backend("album settlement failed") }
        await addFinished?.signal()
    }

    func setCover(albumID: String, photo: PhotoUID) async throws {}
}

final class ManualUploadSettlementTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-upload-settlement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func file(named name: String = "photo.jpg") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("settlement-test-bytes".utf8).write(to: url)
        return url
    }

    private func store() throws -> UploadManualSettlementStore {
        let url = tempDir.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        return try XCTUnwrap(UploadManualSettlementStore(url: url))
    }

    private func existingAlbum() -> UploadDestination {
        UploadDestination(target: .existingAlbum(id: "album-1", title: "Test"))
    }

    private func waitForShutdownAdmissionToClose(_ manager: UploadManager) async -> Bool {
        for _ in 0..<128 {
            if await manager.snapshot().isEmpty { return true }
            await Task.yield()
        }
        return false
    }

    func testManualHealthDoesNotProbeDeniedSelect() throws {
        let store = try store()
        defer { store.close() }
        XCTAssertTrue(store.isOperational())
        try withDeniedSQLiteSelect(in: store) {
            XCTAssertTrue(store.isOperational(), "manual health checks only connection state")
        }
        XCTAssertTrue(store.isOperational(), "denied SELECT must not record a new failure")
    }

    func testManualCloseRefusesReadsAndWritesAndPreservesRows() async throws {
        let id = try await seedCompletedRow()
        let durableStore = try store()
        let record = try XCTUnwrap(durableStore.record(for: id))
        durableStore.close()
        XCTAssertFalse(durableStore.isOperational())
        XCTAssertNil(durableStore.record(for: id))
        XCTAssertTrue(durableStore.allRecords().isEmpty)
        XCTAssertFalse(durableStore.upsert(record))
        XCTAssertFalse(durableStore.remove(queueItemID: id))
        let reopened = try store()
        defer { reopened.close() }
        XCTAssertEqual(reopened.record(for: id), record)
    }

    func testManualDecodeFailureKeepsReadsAndWritesFailClosedAfterRepair() async throws {
        let id = try await seedCompletedRow()
        let durableStore = try store()
        defer { durableStore.close() }
        let record = try XCTUnwrap(durableStore.record(for: id))
        var handle: OpaquePointer?
        let url = tempDir.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE manual_upload_settlement SET payload='{';", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(durableStore.record(for: id))
        XCTAssertFalse(durableStore.isOperational())

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "UPDATE manual_upload_settlement SET payload=?;", -1, &statement, nil), SQLITE_OK
        )
        let payload = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        sqlite3_bind_text(statement, 1, payload, -1, SQLiteStoreSchemaGate.transientDestructor)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        XCTAssertNil(durableStore.record(for: id))
        XCTAssertTrue(durableStore.allRecords().isEmpty)
        XCTAssertFalse(durableStore.upsert(record))
        XCTAssertFalse(durableStore.remove(queueItemID: id))
        XCTAssertFalse(durableStore.isOperational())
    }

    func testMarkerlessSettlementShapeFailsClosedWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE manual_upload_settlement(queue_item_id TEXT); "
                    + "INSERT INTO manual_upload_settlement VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadManualSettlementStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "manual_upload_settlement"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "manual_upload_settlement_info"), -1)
    }

    func testMissingRequiredSettlementPublishesUnavailableInsteadOfEmpty() async {
        let manager = UploadManager(
            uploader: SettlementUploader(),
            settlementStore: nil,
            requiresDurableSettlement: true
        )
        let stats = SettlementStatsBox()

        await manager.setOnChange { _, snapshot in
            stats.store(snapshot)
        }

        XCTAssertTrue(stats.snapshot.persistenceUnavailable)
        XCTAssertEqual(stats.snapshot.total, 0)
        await manager.shutdown()
    }

    // MARK: - Notifications of the replay start

    // The manager numbers every notification, also when no handler exists yet. Registering the
    // ordered handler last therefore counts them: its first event carries the number of earlier
    // notifications plus one, because the registration publishes once itself. A change handler is
    // non-nil only after the replay started (both registrations assign it and start the replay in
    // one actor segment), so this is the only way to see what an enqueue before any registration
    // published.
    private func registerAndCountEarlierNotifications(
        _ manager: UploadManager
    ) async throws -> (earlier: Int, log: SettlementSequenceLog) {
        let log = SettlementSequenceLog()
        await manager.setCoordinatorCallbacks(
            onChange: { sequence, items, stats in log.record(sequence, items: items, stats: stats) },
            onCompleted: { _ in })
        let first = try XCTUnwrap(log.received.first)
        return (Int(first) - 1, log)
    }

    /// Notifications that the replay start of an enqueue adds. The control is the same enqueue after
    /// `snapshot()` started the replay silently, so the notifications of the enqueue itself cancel out.
    private func notificationsAddedByTheReplay(
        required: Bool,
        urls: [URL] = [],
        makeStore: () throws -> (any UploadManualSettlementStoreProtocol)?
    ) async throws -> (added: Int, log: SettlementSequenceLog) {
        var earlier: [Int] = []
        var freshLog = SettlementSequenceLog()
        for startedBySnapshot in [false, true] {
            let manager = UploadManager(
                uploader: SettlementUploader(),
                settlementStore: try makeStore(),
                requiresDurableSettlement: required
            )
            if startedBySnapshot { _ = await manager.snapshot() }
            _ = await manager.enqueueFiles(urls, destination: .library)
            let (count, log) = try await registerAndCountEarlierNotifications(manager)
            earlier.append(count)
            if !startedBySnapshot { freshLog = log }
            await manager.shutdown()
        }
        return (earlier[0] - earlier[1], freshLog)
    }

    private func unavailableStore() -> FailingSettlementStore {
        let store = FailingSettlementStore()
        store.close()
        return store
    }

    private func seedCompletedRow() async throws -> UploadQueueItemID {
        let durableStore = try store()
        let manager = UploadManager(
            uploader: SettlementUploader(),
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(durableStore.record(for: id)?.stage, .terminal)
        await manager.shutdown()
        return id
    }

    func testEnqueueBeforeAnyHandlerNotifiesOnceForTheReplayOfAnUnavailableRequiredStore() async throws {
        let (added, log) = try await notificationsAddedByTheReplay(required: true, urls: [try file()]) {
            self.unavailableStore()
        }

        XCTAssertEqual(added, 1)
        XCTAssertEqual(log.received.count, 1, "the handler sees only the notification of its registration")
        XCTAssertTrue(log.latestStats.persistenceUnavailable)
    }

    func testEnqueueBeforeAnyHandlerIsSilentForTheReplayOfAnUnavailableStoreThatIsNotRequired() async throws {
        let (added, _) = try await notificationsAddedByTheReplay(required: false, urls: [try file()]) {
            self.unavailableStore()
        }

        XCTAssertEqual(added, 0)
    }

    func testEnqueueBeforeAnyHandlerNotifiesOnceForTheReplayOfAnEmptyOperationalStore() async throws {
        let (added, _) = try await notificationsAddedByTheReplay(required: false) { try self.store() }

        XCTAssertEqual(added, 1)
    }

    func testEnqueueBeforeAnyHandlerNotifiesOnceForTheReplayOfRestoredRows() async throws {
        let id = try await seedCompletedRow()

        let (added, log) = try await notificationsAddedByTheReplay(required: false) { try self.store() }

        XCTAssertEqual(added, 1)
        XCTAssertEqual(log.itemsOfFirstEvent.map(\.id), [id])
        XCTAssertEqual(log.itemsOfFirstEvent.map(\.state), [.completed])
    }

    func testEnqueueWithoutAStoreNeverNotifiesForTheReplay() async throws {
        for required in [false, true] {
            let (added, _) = try await notificationsAddedByTheReplay(required: required) { nil }

            XCTAssertEqual(added, 0, "store required: \(required)")
        }
    }

    func testAShutDownManagerNeverReadsTheDurableRows() async throws {
        let counting = ReadCountingSettlementStore()
        let manager = UploadManager(uploader: SettlementUploader(), settlementStore: counting)
        await manager.shutdown()

        let items = await manager.snapshot()
        await manager.setOnChange { _, _ in }
        await manager.setCoordinatorCallbacks(onChange: { _, _, _ in }, onCompleted: { _ in })
        _ = await manager.enqueueFiles([try file()], destination: .library)
        _ = try await manager.enqueueFolder(tempDir, destination: .library)
        await manager.resumeAll()
        await manager.clearFinished()

        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(counting.readCount, 0, "a manager that was shut down does not start the replay")
    }

    func testRowsOfAStoreThatIsNotOperationalAreNotRestored() async throws {
        _ = try await seedCompletedRow()
        let seeded = try store()
        let rows = seeded.allRecords()
        seeded.close()
        XCTAssertEqual(rows.count, 1)
        let manager = UploadManager(
            uploader: SettlementUploader(),
            settlementStore: ReadCountingSettlementStore(rows: rows, operational: false)
        )

        let items = await manager.snapshot()

        XCTAssertTrue(items.isEmpty, "rows that an unavailable store still returns are not restored")
        await manager.shutdown()
    }

    func testTheReplayReadsTheStoreOnlyOnce() async throws {
        for operational in [true, false] {
            let counting = ReadCountingSettlementStore(operational: operational)
            let manager = UploadManager(uploader: SettlementUploader(), settlementStore: counting)

            _ = await manager.snapshot()
            _ = await manager.enqueueFiles([], destination: .library)
            _ = await manager.snapshot()

            XCTAssertEqual(counting.readCount, 1, "store operational: \(operational)")
            await manager.shutdown()
        }
    }

    func testSnapshotStartsTheReplayWithoutNotifying() async throws {
        let id = try await seedCompletedRow()
        let restored = UploadManager(uploader: SettlementUploader(), settlementStore: try store())
        let unavailable = UploadManager(
            uploader: SettlementUploader(),
            settlementStore: unavailableStore(),
            requiresDurableSettlement: true
        )

        let restoredItems = await restored.snapshot()
        _ = await unavailable.snapshot()
        let (restoredEarlier, _) = try await registerAndCountEarlierNotifications(restored)
        let (unavailableEarlier, _) = try await registerAndCountEarlierNotifications(unavailable)

        XCTAssertEqual(restoredItems.map(\.id), [id], "the snapshot starts the replay")
        XCTAssertEqual(restoredEarlier, 0)
        XCTAssertEqual(unavailableEarlier, 0, "an unavailable required store stays silent for a snapshot")
        await restored.shutdown()
        await unavailable.shutdown()
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

    func testLateNonCooperativeSuccessAfterCancelPersistsReceiptAndKeepsUID() async throws {
        let uploader = SettlementUploader(waitsForRelease: true)
        let resolver = SettlementIdentityResolver()
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        await uploader.waitUntilStarted()
        let cancellation = Task { await manager.cancel(id) }
        await uploader.waitUntilCancelled()
        await uploader.releaseUpload()
        await cancellation.value

        let items = await waitUntil(manager) { $0.first?.state == .completed }
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(durableStore.record(for: id)?.uploadedUID, item.uploadedUID)
        XCTAssertEqual(durableStore.record(for: id)?.stage, .terminal)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(uploader.cancelledCount, 1)

        await manager.shutdown()
    }

    func testManifestFailurePersistsReplayWorkAndNeverUploadsBytesAgain() async throws {
        let uploader = SettlementUploader()
        let failingResolver = SettlementIdentityResolver(failuresRemaining: 100)
        let firstStore = try store()
        let firstManager = UploadManager(
            uploader: uploader,
            identityResolver: failingResolver,
            settlementStore: firstStore,
            maxConcurrent: 1
        )
        let ids = await firstManager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        let failed = await waitUntil(firstManager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        XCTAssertEqual(failed.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(firstStore.record(for: id)?.stage, .manifestPending)
        XCTAssertEqual(uploader.requestCount, 1)
        await firstManager.shutdown()

        let replayResolver = SettlementIdentityResolver()
        let replayStore = try store()
        let replayManager = UploadManager(
            uploader: uploader,
            identityResolver: replayResolver,
            settlementStore: replayStore,
            maxConcurrent: 1
        )
        let coordinator = await MainActor.run {
            UploadCoordinator(
                manager: replayManager,
                uploadCapabilities: uploader.capabilities,
                canCreateAlbum: false,
                canAddToAlbum: false,
                canSetAlbumCover: false
            )
        }
        await coordinator.start()
        let replayed = await waitUntil(replayManager) { $0.first?.state == .completed }
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.completedUploadRevision == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await coordinator.start()
        await replayManager.retry(id)
        let completedRevision = await coordinator.completedUploadRevision
        let completion = await coordinator.latestCompletedUpload
        XCTAssertEqual(completedRevision, 1, "recovered upload must refresh the library exactly once")
        XCTAssertEqual(completion?.id, id)
        XCTAssertEqual(completion?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(replayed.first?.id, id)
        XCTAssertEqual(replayed.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(replayStore.record(for: id)?.stage, .terminal)
        XCTAssertEqual(uploader.requestCount, 1, "replay must never call the byte uploader")
        await replayManager.shutdown()
    }

    func testSettlementStoreReadFailureBlocksByteUpload() async throws {
        let uploader = SettlementUploader()
        let store = FailingSettlementStore(failOnFirstRead: true)
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let failed = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        XCTAssertEqual(failed.first?.id, ids.first)
        XCTAssertEqual(uploader.requestCount, 0, "an unavailable settlement store must fail closed")
        await manager.shutdown()
    }

    func testReceiptLatchPreventsRetryAfterSettlementStoreReadFailure() async throws {
        let uploader = SettlementUploader()
        let resolver = SettlementIdentityResolver(failuresRemaining: 1)
        let store = FailingSettlementStore(failAfterFirstUpsert: true)
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: store,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard case .failed(let message) = items.first?.state else { return false }
            return message == "Durable manual upload settlement could not be read."
        }

        for _ in 0..<3 {
            await manager.retry(id)
        }

        XCTAssertEqual(uploader.requestCount, 1, "a receipt-backed retry must not send bytes again")
        let visible = await manager.snapshot()
        XCTAssertEqual(visible.first?.uploadedUID, testUID("photo.jpg"))
        guard case .failed(let message) = visible.first?.state else {
            return XCTFail(
                "a settlement read failure must remain visibly failed: \(String(describing: visible.first?.state))")
        }
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("read"),
            "failure must identify the store read failure; actual: \(message)")
        await manager.shutdown()
    }

    func testAlbumAttachmentRunsOnlyAfterManifestSettlement() async throws {
        let events = SettlementEventLog()
        let manifestStarted = SettlementLatch()
        let manifestRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            eventLog: events,
            recordStarted: manifestStarted,
            recordGate: manifestRelease
        )
        let albums = SettlementAlbums(eventLog: events)
        let durableStore = try store()
        let manager = UploadManager(
            uploader: SettlementUploader(),
            albums: albums,
            identityResolver: resolver,
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)

        await manifestStarted.wait()
        XCTAssertTrue(albums.added.isEmpty)
        XCTAssertEqual(events.snapshot, ["manifest"])
        await manifestRelease.signal()

        _ = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(events.snapshot, ["manifest", "album"])
        XCTAssertEqual(albums.added.count, 1)
        XCTAssertEqual(durableStore.record(for: id)?.stage, .terminal)
        await manager.shutdown()
    }

    func testShutdownAndReopenResumeDurableSettlement() async throws {
        let uploader = SettlementUploader()
        let firstStore = try store()
        let firstAlbums = SettlementAlbums(failuresRemaining: 1)
        let firstManager = UploadManager(
            uploader: uploader,
            albums: firstAlbums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: firstStore,
            maxConcurrent: 1
        )
        let ids = await firstManager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(firstManager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        XCTAssertEqual(firstStore.record(for: id)?.stage, .albumPending)
        await firstManager.shutdown()

        let replayStore = try store()
        let replayAlbums = SettlementAlbums()
        let replayManager = UploadManager(
            uploader: uploader,
            albums: replayAlbums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: replayStore,
            maxConcurrent: 1
        )
        let resumed = await waitUntil(replayManager) { $0.first?.state == .completed }
        XCTAssertEqual(resumed.first?.id, id)
        XCTAssertEqual(replayAlbums.added.count, 1)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(replayStore.record(for: id)?.stage, .terminal)
        await replayManager.shutdown()
    }

    func testShutdownWaitsForPendingSettlementAndLateCancelCannotDemoteReceipt() async throws {
        let uploader = SettlementUploader()
        let addStarted = SettlementLatch()
        let addRelease = SettlementLatch()
        let addFinished = SettlementLatch()
        let albums = SettlementAlbums(addStarted: addStarted, addGate: addRelease, addFinished: addFinished)
        let durableStore = try store()
        let recorder = StateRecorder()
        let manager = UploadManager(
            uploader: uploader,
            albums: albums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)

        await addStarted.wait()
        XCTAssertEqual(durableStore.record(for: id)?.stage, .albumPending)
        let shutdown = Task { await manager.shutdown() }
        let lateCancel = Task { await manager.cancel(id) }
        await lateCancel.value
        XCTAssertEqual(uploader.cancelledCount, 0)
        await addRelease.signal()
        await addFinished.wait()
        await shutdown.value

        XCTAssertEqual(recorder.sequence(id).last, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
    }

    func testRepeatedReplayIsIdempotentAndProducesOneTerminalResult() async throws {
        let uploader = SettlementUploader()
        let firstStore = try store()
        let firstManager = UploadManager(
            uploader: uploader,
            albums: SettlementAlbums(failuresRemaining: 1),
            identityResolver: SettlementIdentityResolver(),
            settlementStore: firstStore,
            maxConcurrent: 1
        )
        let ids = await firstManager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(firstManager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        await firstManager.shutdown()

        let replayStore = try store()
        let addStarted = SettlementLatch()
        let addRelease = SettlementLatch()
        let replayAlbums = SettlementAlbums(addStarted: addStarted, addGate: addRelease)
        let replayManager = UploadManager(
            uploader: uploader,
            albums: replayAlbums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: replayStore,
            maxConcurrent: 1
        )
        _ = await replayManager.snapshot()
        await addStarted.wait()
        for _ in 0..<5 { _ = await replayManager.snapshot() }
        await replayManager.retry(id)
        await addRelease.signal()

        let terminal = await waitUntil(replayManager) { $0.first?.state == .completed }
        XCTAssertEqual(terminal.first?.id, id)
        XCTAssertEqual(replayAlbums.added.count, 1)
        XCTAssertEqual(replayStore.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
        await replayManager.shutdown()
    }

    func testLibraryOnlyLateCommitReconcilesWithoutUploadingAgain() async throws {
        let uploader = SettlementUploader(waitsForRelease: true)
        let resolver = SettlementIdentityResolver(failuresRemaining: 1)
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        await uploader.waitUntilStarted()
        let cancellation = Task { await manager.cancel(id) }
        await uploader.waitUntilCancelled()
        await uploader.releaseUpload()
        await cancellation.value

        let reconciled = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(reconciled.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(durableStore.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(
            resolver.reconciliationCount,
            0,
            "a durable receipt is replayed by settlement; no duplicate reconciliation callback is needed"
        )
        await manager.shutdown()
    }

    func testSettlementPersistenceFailureReconcilesExactlyOnce() async throws {
        let uploader = SettlementUploader()
        let resolver = SettlementIdentityResolver()
        let store = FailingSettlementStore(failOnUpsert: true)
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: store,
            maxConcurrent: 1
        )
        await manager.enqueueFiles([try file()], destination: .library)

        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(
            resolver.reconciliationCount,
            1,
            "withUploadDecision owns the one reconciliation callback when receipt persistence fails"
        )
        await manager.shutdown()
    }

    func testQueueTerminalStateRetainsUIDWhenAlbumSettlementFails() async throws {
        let uploader = SettlementUploader()
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            albums: SettlementAlbums(failuresRemaining: 1),
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        let failed = await waitUntil(manager) { items in
            guard let item = items.first else { return false }
            if case .failed = item.state { return true }
            return false
        }
        let item = try XCTUnwrap(failed.first)
        guard case .failed = item.state else { return XCTFail("album failure must be terminal") }
        XCTAssertTrue(item.partialSuccess)
        XCTAssertEqual(item.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(durableStore.record(for: id)?.stage, .albumPending)
        await manager.shutdown()
    }

    func testCancelDuringRetryInvalidationPreventsNewAttempt() async throws {
        let invalidationStarted = SettlementLatch()
        let invalidationRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            failuresRemaining: 1,
            invalidationStarted: invalidationStarted,
            invalidationGate: invalidationRelease
        )
        let uploader = SettlementUploader()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        let retry = Task { await manager.retry(id) }
        await invalidationStarted.wait()
        await manager.cancel(id)
        await invalidationRelease.signal()
        await retry.value

        let cancelled = await waitUntil(manager) { $0.first?.state == .cancelled }
        XCTAssertEqual(cancelled.first?.state, .cancelled)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(resolver.invalidationCount, 1)
    }

    func testShutdownJoinsRetryInvalidationAndPreventsNewAttempt() async throws {
        let invalidationStarted = SettlementLatch()
        let invalidationRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            failuresRemaining: 1,
            invalidationStarted: invalidationStarted,
            invalidationGate: invalidationRelease
        )
        let uploader = SettlementUploader()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        let retry = Task { await manager.retry(id) }
        await invalidationStarted.wait()
        let shutdown = Task { await manager.shutdown() }
        let admissionClosed = await waitForShutdownAdmissionToClose(manager)
        XCTAssertTrue(admissionClosed, "shutdown must close admission while retry invalidation is still blocked")

        let lateIDs = await manager.enqueueFiles([try file(named: "late.jpg")], destination: .library)
        XCTAssertTrue(lateIDs.isEmpty)

        await invalidationRelease.signal()
        await retry.value
        await shutdown.value

        XCTAssertEqual(uploader.requestCount, 1, "retry invalidation must not restart bytes after shutdown")
        XCTAssertEqual(resolver.invalidationCount, 1)
    }

    func testRepeatedRetryRequestsCreateOneNewAttempt() async throws {
        let invalidationStarted = SettlementLatch()
        let invalidationRelease = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            failuresRemaining: 1,
            invalidationStarted: invalidationStarted,
            invalidationGate: invalidationRelease
        )
        let uploader = SettlementUploader()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        _ = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed = state { return true }
            return false
        }

        let firstRetry = Task { await manager.retry(id) }
        await invalidationStarted.wait()
        let secondRetry = Task { await manager.retry(id) }
        await invalidationRelease.signal()
        await firstRetry.value
        await secondRetry.value

        _ = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(uploader.requestCount, 2)
        XCTAssertEqual(resolver.invalidationCount, 1)
    }
}
