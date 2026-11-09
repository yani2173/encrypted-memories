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
    func isOperationalAllowingTransientRecovery() -> Bool { operational }
    func hasLastingFailure() -> Bool { !operational }
    func upsert(_ record: UploadManualSettlementRecord) -> Bool { false }
    func remove(queueItemID: UploadQueueItemID) -> Bool { false }
    func close() {}

    func readOutcome(for queueItemID: UploadQueueItemID) -> UploadManualSettlementReadOutcome {
        operational ? .absent : .unreadable
    }

    func readAllOutcome() -> UploadManualSettlementListReadOutcome {
        lock.withLock { reads += 1 }
        return operational ? .records(rows) : .unreadable
    }
}

private final class SettlementIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: SettlementEventLog?
    private let recordStarted: SettlementLatch?
    private let recordGate: SettlementLatch?
    private let recordCancelled: SettlementLatch?
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
        recordCancelled: SettlementLatch? = nil,
        invalidationStarted: SettlementLatch? = nil,
        invalidationGate: SettlementLatch? = nil
    ) {
        self.failuresRemaining = failuresRemaining
        self.eventLog = eventLog
        self.recordStarted = recordStarted
        self.recordGate = recordGate
        self.recordCancelled = recordCancelled
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
        // The gate holds through task cancellation; `recordCancelled` only reports it, so a test
        // knows that a shutdown has passed its cancellation claims before it opens the gate.
        let recordCancelled = recordCancelled
        await withTaskCancellationHandler {
            await recordGate?.wait()
        } onCancel: {
            if let recordCancelled { Task { await recordCancelled.signal() } }
        }
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
    private let throwsWhenCancelled: Bool
    private let started = SettlementLatch()
    private let release = SettlementLatch()
    private let cancelStarted = SettlementLatch()
    private var _requests: [PhotoUploadRequest] = []
    private var _cancelledTokens: [UUID] = []

    init(waitsForRelease: Bool = false, throwsWhenCancelled: Bool = false) {
        self.waitsForRelease = waitsForRelease
        self.throwsWhenCancelled = throwsWhenCancelled
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
        if waitsForRelease {
            // A parked upload must yield to task cancellation. Cancel guards that wrongly
            // proceed (for example when a settlement read turns unreadable) cancel the upload
            // task; without a cancellation-aware park, those tests would hang instead of
            // failing on their state assertions (#1104).
            await withTaskCancellationHandler {
                await release.wait()
            } onCancel: {
                Task { await release.signal() }
            }
        }
        // A real transport ends a cancelled transfer with a cancellation error.
        if throwsWhenCancelled { try Task.checkCancellation() }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {
        lock.withLock { _cancelledTokens.append(token) }
        await cancelStarted.signal()
    }
}

/// Uploads the first request straight through and parks the second at a latch (#1104). A test can
/// hold one item mid-upload while an earlier item sits failed with a still-pending settlement row.
private final class SecondUploadParkingUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities(
        canUpload: true,
        supportsCancel: true,
        supportsPauseResume: false,
        supportsResumeAcrossRelaunch: false
    )

    private let lock = NSLock()
    private var _requests: [PhotoUploadRequest] = []
    private let parked = SettlementLatch()
    private let release = SettlementLatch()

    var requestCount: Int { lock.withLock { _requests.count } }

    func waitUntilSecondUploadParked() async { await parked.wait() }
    func releaseSecondUpload() async { await release.signal() }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        let index = lock.withLock {
            _requests.append(request)
            return _requests.count
        }
        if index == 2 {
            await parked.signal()
            await release.wait()
        }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {}
}

private final class FailingSettlementStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UploadQueueItemID: UploadManualSettlementRecord] = [:]
    private var failed = false
    private let failOnFirstRead: Bool
    private let failOnUpsert: Bool
    private let failAfterFirstUpsert: Bool
    private let healOnLaterOperations: Bool

    init(
        failOnFirstRead: Bool = false,
        failOnUpsert: Bool = false,
        failAfterFirstUpsert: Bool = false,
        healOnLaterOperations: Bool = false
    ) {
        self.failOnFirstRead = failOnFirstRead
        self.failOnUpsert = failOnUpsert
        self.failAfterFirstUpsert = failAfterFirstUpsert
        self.healOnLaterOperations = healOnLaterOperations
    }

    func isOperational() -> Bool {
        lock.withLock {
            guard failed else { return true }
            guard healOnLaterOperations else { return false }
            return true
        }
    }

    func isOperationalAllowingTransientRecovery() -> Bool { isOperational() }
    func hasLastingFailure() -> Bool { !isOperational() }

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

    func readOutcome(for queueItemID: UploadQueueItemID) -> UploadManualSettlementReadOutcome {
        lock.withLock {
            guard !failed else { return .unreadable }
            if failOnFirstRead {
                failed = true
                return .unreadable
            }
            guard let record = records[queueItemID] else { return .absent }
            return .found(record)
        }
    }

    func readAllOutcome() -> UploadManualSettlementListReadOutcome {
        lock.withLock { failed ? .unreadable : .records(Array(records.values)) }
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

/// Store double for the enqueue gate (#1104). The flag-only probe and the healing probe can
/// disagree, the way a transiently failed settlement write records a flag-only failure that the
/// healing probe clears as soon as the database answers again.
private final class EnqueueGateStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UploadQueueItemID: UploadManualSettlementRecord] = [:]
    private let flagOperational: Bool
    private let heals: Bool

    init(flagOperational: Bool, heals: Bool) {
        self.flagOperational = flagOperational
        self.heals = heals
    }

    func isOperational() -> Bool { flagOperational }
    func isOperationalAllowingTransientRecovery() -> Bool { heals }
    func hasLastingFailure() -> Bool { !heals }

    @discardableResult
    func upsert(_ record: UploadManualSettlementRecord) -> Bool {
        lock.withLock {
            records[record.queueItemID] = record
            return true
        }
    }

    func readOutcome(for queueItemID: UploadQueueItemID) -> UploadManualSettlementReadOutcome {
        lock.withLock {
            guard let record = records[queueItemID] else { return .absent }
            return .found(record)
        }
    }

    func readAllOutcome() -> UploadManualSettlementListReadOutcome {
        lock.withLock { .records(Array(records.values)) }
    }

    @discardableResult
    func remove(queueItemID: UploadQueueItemID) -> Bool {
        lock.withLock { records.removeValue(forKey: queueItemID) != nil }
    }

    func close() {}
}

/// Store double that scripts per-job read results in order (#1104). Tests arm the exact read a
/// production path performs, so guards are provable against the store's real answers: a queued
/// `.unreadable` answer, a flip between two reads, or a first read that says `.absent`.
private final class ScriptedReadStore: UploadManualSettlementStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UploadQueueItemID: UploadManualSettlementRecord] = [:]
    private var queuedReads: [UploadManualSettlementReadOutcome] = []
    private var removed: [UploadQueueItemID] = []
    private var readsFail = false
    private var sweepsFail = false
    private var lastingFailure: Bool
    private let operationalFlag: Bool

    init(operational: Bool = true) {
        self.operationalFlag = operational
        self.lastingFailure = !operational
    }

    func isOperational() -> Bool { operationalFlag }
    func isOperationalAllowingTransientRecovery() -> Bool { operationalFlag }
    func hasLastingFailure() -> Bool { lock.withLock { lastingFailure } }

    /// Reports a lasting failure from now on, the way a refused constraint write latches the store.
    func setLastingFailure(_ lasting: Bool) {
        lock.withLock { lastingFailure = lasting }
    }

    /// Scripted answers that no read has consumed yet.
    var unconsumedScriptedReads: Int { lock.withLock { queuedReads.count } }

    /// While set, every single-row read answers `.unreadable`, after any scripted answers.
    func setReadsFail(_ fail: Bool) {
        lock.withLock { readsFail = fail }
    }

    /// While set, every sweep of the whole table answers `.unreadable`.
    func setSweepsFail(_ fail: Bool) {
        lock.withLock { sweepsFail = fail }
    }

    /// Queues the next `readOutcome` answers, oldest first. Reads after the queue empties answer
    /// `.absent`, the healthy answer of an empty store.
    func scriptReads(_ outcomes: [UploadManualSettlementReadOutcome]) {
        lock.withLock { queuedReads.append(contentsOf: outcomes) }
    }

    var removedIDs: [UploadQueueItemID] { lock.withLock { removed } }

    @discardableResult
    func upsert(_ record: UploadManualSettlementRecord) -> Bool {
        lock.withLock {
            records[record.queueItemID] = record
            return true
        }
    }

    func readOutcome(for queueItemID: UploadQueueItemID) -> UploadManualSettlementReadOutcome {
        lock.withLock {
            if !queuedReads.isEmpty { return queuedReads.removeFirst() }
            if readsFail { return .unreadable }
            guard let record = records[queueItemID] else { return .absent }
            return .found(record)
        }
    }

    func readAllOutcome() -> UploadManualSettlementListReadOutcome {
        lock.withLock { sweepsFail ? .unreadable : .records(Array(records.values)) }
    }

    @discardableResult
    func remove(queueItemID: UploadQueueItemID) -> Bool {
        lock.withLock {
            removed.append(queueItemID)
            return records.removeValue(forKey: queueItemID) != nil
        }
    }

    func close() {}
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
        XCTAssertFalse(durableStore.hasLastingFailure())
        durableStore.close()
        XCTAssertFalse(durableStore.isOperational())
        XCTAssertTrue(durableStore.hasLastingFailure(), "A closed connection is a lasting failure")
        XCTAssertNil(durableStore.record(for: id))
        XCTAssertTrue(durableStore.allRecords().isEmpty)
        XCTAssertFalse(durableStore.upsert(record))
        XCTAssertFalse(durableStore.remove(queueItemID: id))
        let reopened = try store()
        defer { reopened.close() }
        XCTAssertEqual(reopened.record(for: id), record)
    }

    /// A row that carried a `mainResource` key in the descriptor snapshot, null or set, still decodes. A row written
    /// now leaves the key out, which an Optional field of an earlier build reads as nil.
    func testSettlementRowsOfEarlierBuildsWithAMainResourceStillDecode() async throws {
        let id = try await seedCompletedRow()
        let seeded = try store()
        let record = try XCTUnwrap(seeded.record(for: id))
        seeded.close()
        let url = tempDir.appendingPathComponent(UploadManualSettlementStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        func payload() throws -> [String: Any] {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(handle, "SELECT payload FROM manual_upload_settlement;", -1, &statement, nil),
                SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            let text = try XCTUnwrap(sqlite3_column_text(statement, 0))
            let object = try JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))
            return try XCTUnwrap(object as? [String: Any])
        }
        func write(_ object: [String: Any]) throws {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(handle, "UPDATE manual_upload_settlement SET payload=?;", -1, &statement, nil),
                SQLITE_OK)
            sqlite3_bind_text(statement, 1, text, -1, SQLiteStoreSchemaGate.transientDestructor)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        let current = try payload()
        let descriptor = try XCTUnwrap(current["descriptor"] as? [String: Any])
        XCTAssertNil(descriptor["mainResource"], "a row written now has no mainResource key")
        struct EarlierSnapshot: Decodable { let mainResource: UploadSourceIdentity? }
        let earlierRead = try JSONDecoder().decode(
            EarlierSnapshot.self, from: try JSONSerialization.data(withJSONObject: descriptor))
        XCTAssertNil(earlierRead.mainResource, "an earlier build reads the missing key as nil")

        let main = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "main")))
        for earlierValue in [NSNull(), main] {
            var earlierDescriptor = descriptor
            earlierDescriptor["mainResource"] = earlierValue
            var earlierRow = current
            earlierRow["descriptor"] = earlierDescriptor
            try write(earlierRow)
            let reopened = try store()
            guard case .found(let read) = reopened.readOutcome(for: id) else {
                XCTFail("a row with mainResource \(earlierValue) must stay readable")
                reopened.close()
                continue
            }
            XCTAssertEqual(read, record, "mainResource \(earlierValue)")
            reopened.close()
        }
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

    func testEnqueueBeforeAnyHandlerNotifiesAgainForTheReplayOfAnUnavailableRequiredStore() async throws {
        let (added, log) = try await notificationsAddedByTheReplay(required: true, urls: [try file()]) {
            self.unavailableStore()
        }

        // An unreadable sweep no longer latches the replay (#1104): the enqueue retries the
        // sweep even after a snapshot already attempted it, so both control runs notify
        // equally and their difference cancels out. The fresh run below still shows the
        // unavailable-store notification to the first handler that registers.
        XCTAssertEqual(added, 0)
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

    func testTheReplayReadsAHealthyStoreOnceAndRetriesAnUnreadableSweep() async throws {
        // A readable sweep latches: later triggers never re-read the whole store (#1104).
        let healthy = ReadCountingSettlementStore(operational: true)
        let healthyManager = UploadManager(uploader: SettlementUploader(), settlementStore: healthy)
        _ = await healthyManager.snapshot()
        _ = await healthyManager.enqueueFiles([], destination: .library)
        _ = await healthyManager.snapshot()
        XCTAssertEqual(healthy.readCount, 1, "the sweep of a readable store runs once")
        await healthyManager.shutdown()

        // An unreadable sweep must not latch the replay (#1104): every later trigger retries
        // it, so one transient read failure cannot keep pending rows dark for the whole
        // session. Re-latching after a failed sweep is the regression this half kills.
        let unreadable = ReadCountingSettlementStore(operational: false)
        let manager = UploadManager(uploader: SettlementUploader(), settlementStore: unreadable)
        _ = await manager.snapshot()
        XCTAssertEqual(unreadable.readCount, 1)
        _ = await manager.snapshot()
        XCTAssertGreaterThan(
            unreadable.readCount, 1, "the second snapshot must retry the unreadable sweep")
        let retried = unreadable.readCount
        _ = await manager.enqueueFiles([], destination: .library)
        XCTAssertGreaterThan(
            unreadable.readCount, retried, "the enqueue must retry the unreadable sweep too")
        await manager.shutdown()
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

    func testAHealedStoreFailureStillBlocksByteUpload() async throws {
        let uploader = SettlementUploader()
        // The read fails once and the latch stays, but `isOperational()` reports healed, the
        // way a later operation on a transiently failed connection does. A gate that consults
        // the store after the failed read would read the healed state and allow the bytes.
        let store = FailingSettlementStore(failOnFirstRead: true, healOnLaterOperations: true)
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let failed = await waitUntil(manager) { items in
            guard let state = items.first?.state else { return false }
            if case .failed(let message) = state {
                return message == "Durable manual upload settlement is unavailable; byte upload is blocked."
            }
            return false
        }

        XCTAssertEqual(failed.first?.id, ids.first)
        XCTAssertTrue(store.isOperational(), "the store models a connection healed by a later operation")
        XCTAssertEqual(
            uploader.requestCount,
            0,
            "a read that failed is never proof of absence, even after a later operation healed the store"
        )
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

        // The retry schedules a durable settlement; the read failure surfaces through the
        // scheduled task, so the failed state converges asynchronously.
        let visible = await waitUntil(manager) { items in
            guard case .failed = items.first?.state else { return false }
            return true
        }
        XCTAssertEqual(uploader.requestCount, 1, "a receipt-backed retry must not send bytes again")
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

    func testRetryOnASettledRecordNeverReopensSettlement() async throws {
        let uploader = SettlementUploader()
        let durableStore = try store()
        defer { durableStore.close() }
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )

        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        let completed = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(completed.first?.id, id)
        XCTAssertEqual(durableStore.record(for: id)?.stage, .terminal)
        XCTAssertEqual(uploader.requestCount, 1)

        // The job now caches a proven terminal record. Retry on it must stay a no-op: a
        // settled upload never returns to finalizing, and never schedules another settlement.
        await manager.retry(id)
        let after = await manager.snapshot()

        XCTAssertEqual(
            after.first?.state, .completed,
            "retry on a proven terminal record must never reopen settlement")
        XCTAssertEqual(uploader.requestCount, 1, "settled bytes must never upload again")
        await manager.shutdown()
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

    func testRetryWithOnlyAnInMemoryReceiptAndAnUnreadableStoreIsANoOp() async throws {
        let uploader = SettlementUploader()
        let store = FailingSettlementStore(failOnUpsert: true)
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: store,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        let failed = await waitUntil(manager) { items in
            guard case .failed = items.first?.state else { return false }
            return true
        }
        guard case .failed(let originalMessage) = failed.first?.state else {
            return XCTFail(
                "the receipt persistence failure must be visible: \(String(describing: failed.first?.state))"
            )
        }

        await manager.retry(id)

        let after = await manager.snapshot()
        XCTAssertEqual(uploader.requestCount, 1, "a retry must not send bytes without a durable record")
        guard case .failed(let message) = after.first?.state else {
            return XCTFail(
                "retry without an in-memory settlement record must stay failed: "
                    + String(describing: after.first?.state)
            )
        }
        XCTAssertEqual(
            message,
            originalMessage,
            "retry must be a no-op while the store cannot be read; the bytes must never be re-uploaded"
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

    func testEnqueueAcceptsASettlementStoreHealedAfterATransientWriteFailure() async throws {
        let uploader = SettlementUploader()
        // The flag-only probe still records the transient write failure, but the database answers
        // again. New manual uploads must not stay refused for the rest of the session (#1104).
        let store = EnqueueGateStore(flagOperational: false, heals: true)
        // A settlement needs an identity resolver to reach a terminal stage, otherwise the
        // store only ever sees the manifest-pending receipt without a terminal state.
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: store,
            maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let completed = await waitUntil(manager) { $0.first?.state == .completed }

        XCTAssertEqual(completed.first?.id, ids.first)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(store.record(for: try XCTUnwrap(ids.first))?.terminalState, .completed)
        await manager.shutdown()
    }

    func testEnqueueStillRefusesASettlementStoreWithALastingFailure() async throws {
        let uploader = SettlementUploader()
        let store = EnqueueGateStore(flagOperational: false, heals: false)
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let failed = await waitUntil(manager) { items in
            guard case .failed(let message) = items.first?.state else { return false }
            return message == "Durable manual upload settlement is unavailable."
        }

        XCTAssertEqual(failed.first?.id, ids.first)
        XCTAssertEqual(uploader.requestCount, 0, "a lasting settlement failure must refuse new uploads")
        await manager.shutdown()
    }

    func testFolderEnqueueAcceptsASettlementStoreHealedAfterATransientWriteFailure() async throws {
        let uploader = SettlementUploader()
        // The folder gate must use the healing check too: the flag-only probe still records
        // the transient write failure, so folder uploads must not stay refused all
        // session (#1104).
        let store = EnqueueGateStore(flagOperational: false, heals: true)
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: store,
            maxConcurrent: 1)
        _ = try file(named: "batch-photo.jpg")
        let ids = try await manager.enqueueFolder(tempDir, destination: .library)
        let completed = await waitUntil(manager) { $0.first?.state == .completed }

        XCTAssertEqual(completed.first?.id, ids.first)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(store.record(for: try XCTUnwrap(ids.first))?.terminalState, .completed)
        await manager.shutdown()
    }

    func testFolderEnqueueStillRefusesASettlementStoreWithALastingFailure() async throws {
        let uploader = SettlementUploader()
        let store = EnqueueGateStore(flagOperational: false, heals: false)
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        _ = try file(named: "batch-photo.jpg")
        let ids = try await manager.enqueueFolder(tempDir, destination: .library)
        let failed = await waitUntil(manager) { items in
            guard case .failed(let message) = items.first?.state else { return false }
            return message == "Durable manual upload settlement is unavailable."
        }

        XCTAssertEqual(failed.first?.id, ids.first)
        XCTAssertEqual(uploader.requestCount, 0, "a lasting settlement failure must refuse new folder uploads")
        await manager.shutdown()
    }

    // MARK: Unreadable reads fail closed (#1104)

    /// An item refused at enqueue has no receipt and no settlement record in memory, so it has no
    /// durable row: the only writers of that row cache the record in the same actor step. Clear
    /// finished removes it from memory alone, without reading a store that cannot be read (#1104).
    func testClearFinishedRemovesAnItemRefusedAtEnqueueWithoutReadingTheStore() async throws {
        let uploader = SettlementUploader()
        let store = ScriptedReadStore(operational: false)
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        let refused = await waitUntil(manager) { ($0.first?.state.isTerminal ?? false) == true }
        XCTAssertEqual(refused.first?.id, id)

        store.scriptReads([.unreadable])
        await manager.clearFinished()
        let after = await manager.snapshot()

        XCTAssertEqual(after, [], "Clear finished removes an item that never reached the server")
        XCTAssertEqual(store.unconsumedScriptedReads, 1, "Clear finished must not read the store for it")
        XCTAssertTrue(store.removedIDs.isEmpty, "An item without a durable row has nothing to delete")
        XCTAssertEqual(uploader.requestCount, 0)
        await manager.shutdown()
    }

    /// A proven-terminal settlement has finished, so Clear finished removes the item and deletes
    /// its durable row; no later launch replays it (#1104).
    func testClearFinishedRemovesTheRowOfACompletedSettlement() async throws {
        let uploader = SettlementUploader()
        let durableStore = try store()
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: durableStore,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        let completed = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(completed.first?.state, .completed)
        XCTAssertEqual(durableStore.record(for: id)?.terminalState, .completed)

        await manager.clearFinished()
        let after = await manager.snapshot()
        XCTAssertEqual(after, [])
        guard case .absent = durableStore.readOutcome(for: id) else {
            XCTFail("Clear finished must delete the row of a proven-terminal settlement")
            await manager.shutdown()
            return
        }
        await manager.shutdown()
    }

    /// A pending settlement whose store then fails for good cannot settle before a relaunch: the
    /// row offers no Retry, and Clear finished drops the item but never deletes its durable row,
    /// which keeps the pending stage for the next launch (#1104).
    func testALastingFailureHidesRetryOfAPendingSettlementAndClearFinishedKeepsItsRow() async throws {
        let uploader = SettlementUploader()
        let albums = SettlementAlbums(failuresRemaining: 100)
        let store = ScriptedReadStore()
        let manager = UploadManager(
            uploader: uploader,
            albums: albums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: store,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)
        // The album step fails after the settlement task released the item, so it fails with a
        // still-pending album record in memory and on disk.
        let failed = await waitUntil(manager) { items in
            if case .failed = items.first?.state { return true }
            return false
        }
        let item = try XCTUnwrap(failed.first)
        XCTAssertEqual(store.record(for: id)?.stage, .albumPending)
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: item, capabilities: uploader.capabilities), [.retry],
            "While the store works, Retry can settle the pending album step")

        store.setLastingFailure(true)
        let latched = await manager.snapshot()
        XCTAssertEqual(
            UploadQueuePresentation.rowActions(for: try XCTUnwrap(latched.first), capabilities: uploader.capabilities),
            [],
            "With a lasting store failure no settlement step can run, so the row offers no Retry")

        await manager.clearFinished()
        let after = await manager.snapshot()
        XCTAssertEqual(after, [], "Clear finished drops an item that cannot settle before a relaunch")
        XCTAssertTrue(store.removedIDs.isEmpty, "Clear finished must never delete a pending durable row")
        XCTAssertEqual(store.record(for: id)?.stage, .albumPending, "The pending row stays for the relaunch")
        XCTAssertEqual(uploader.requestCount, 1)
        await manager.shutdown()
    }

    /// Retry of an item without a receipt or a settlement record decides from memory, as on main:
    /// the item has no durable row, so Retry queues a new byte attempt, and the byte gate refuses
    /// it while the store cannot be read (#1104).
    func testRetryOfAnItemWithoutAReceiptQueuesABytePassThatTheByteGateRefuses() async throws {
        let uploader = SettlementUploader(waitsForRelease: true, throwsWhenCancelled: true)
        let store = ScriptedReadStore()
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        await uploader.waitUntilStarted()
        await manager.cancel(id)
        let cancelled = await manager.snapshot()
        XCTAssertEqual(cancelled.first?.state, .cancelled)

        store.setReadsFail(true)
        await manager.retry(id)
        let blocked = try XCTUnwrap(
            UploadError.backend("Durable manual upload settlement is unavailable; byte upload is blocked.")
                .errorDescription)
        let items = await waitUntil(manager) { $0.first?.state == .failed(message: blocked) }
        XCTAssertEqual(
            items.first?.state, .failed(message: blocked),
            "Retry must queue the item again; the byte gate then refuses it with its own reason")
        XCTAssertEqual(uploader.requestCount, 1, "The byte gate must stop a second upload")
        store.setReadsFail(false)
        await manager.shutdown()
    }

    /// The keep predicate must treat a cached still-pending record as pending (#1104). A failed
    /// item whose durable row is pending keeps its queue position through Clear finished: it is
    /// the oldest unfinished work and must not demote behind younger in-flight items. A predicate
    /// that trusts only a proven-terminal record keeps this order; one that keys on the pending
    /// flag alone re-orders the item to the end of the queue.
    func testClearFinishedKeepsAFailedPendingSettlementAheadOfYoungerWork() async throws {
        let uploader = SecondUploadParkingUploader()
        // Every manifest write fails, so the first item fails durably while its durable row and
        // the cached record keep the manifest-pending stage; it stays failed until Retry.
        let resolver = SettlementIdentityResolver(failuresRemaining: 100)
        let store = try store()
        let manager = UploadManager(
            uploader: uploader,
            identityResolver: resolver,
            settlementStore: store,
            maxConcurrent: 1
        )

        let ids = await manager.enqueueFiles(
            [try file(named: "a.jpg"), try file(named: "b.jpg")],
            destination: .library
        )
        XCTAssertEqual(ids.count, 2)
        let firstID = try XCTUnwrap(ids.first)
        let secondID = try XCTUnwrap(ids.last)

        // Item one fails on the manifest write; item two parks mid-upload.
        let failed = await waitUntil(manager) { items in
            guard let item = items.first, item.id == firstID else { return false }
            if case .failed = item.state { return true }
            return false
        }
        XCTAssertNotNil(failed.first?.uploadedUID, "The failed item keeps its upload receipt")
        XCTAssertEqual(store.record(for: firstID)?.stage, .manifestPending)
        await uploader.waitUntilSecondUploadParked()

        await manager.clearFinished()
        let after = await manager.snapshot()

        XCTAssertEqual(
            after.map(\.id), [firstID, secondID],
            "Clear finished must keep the oldest pending-settlement item ahead of younger work")
        XCTAssertFalse(
            store.allRecords().isEmpty,
            "The still-pending durable row must survive Clear finished")

        await uploader.releaseSecondUpload()
        let settled = await waitUntil(manager) { items in
            guard items.count == 2 else { return false }
            guard items.last?.id == secondID, items.last?.state == .completed else { return false }
            guard let first = items.first, first.id == firstID else { return false }
            if case .failed = first.state { return true }
            return false
        }
        XCTAssertEqual(
            settled.map(\.id), [firstID, secondID],
            "Finishing the younger item must not reorder the queue")
        XCTAssertEqual(uploader.requestCount, 2, "Only the parked item uploaded in this session")
        await manager.shutdown()
    }

    // MARK: Pause, cancel and shutdown decide from in-memory evidence (#1104)

    /// A live upload whose receipt row is persisted must never pause, even while every store read
    /// fails. The persisting write caches the pending record in the same actor step, so the cache is
    /// the durable evidence; a failed read can neither strand nor demote the settlement.
    func testPauseNeverDemotesALiveUploadWithAPersistedReceiptWhileStoreReadsFail() async throws {
        let recordStarted = SettlementLatch()
        let recordGate = SettlementLatch()
        let resolver = SettlementIdentityResolver(recordStarted: recordStarted, recordGate: recordGate)
        let uploader = SettlementUploader()
        let store = ScriptedReadStore()
        let manager = UploadManager(
            uploader: uploader, identityResolver: resolver, settlementStore: store, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        await recordStarted.wait()
        XCTAssertEqual(store.record(for: id)?.stage, .manifestPending, "The receipt row is persisted")
        let beforeItems = await manager.snapshot()
        let before = try XCTUnwrap(beforeItems.first?.state)
        XCTAssertTrue(before.isActive, "The upload is still live inside its manifest step")

        store.setReadsFail(true)
        await manager.pause(id)
        let afterPause = await manager.snapshot()
        XCTAssertEqual(
            afterPause.first?.state, before,
            "Pause must not act on a live upload whose receipt row is persisted")
        store.setReadsFail(false)

        await recordGate.signal()
        let items = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(items.first?.state, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(resolver.recordedCount, 1)
        await manager.shutdown()
    }

    /// Cancel must never demote a pending album settlement to cancelled, even while every store
    /// read fails. The settlement task owns the item; its cached pending record decides.
    func testCancelNeverDemotesAPendingAlbumSettlementWhileStoreReadsFail() async throws {
        let uploader = SettlementUploader()
        let addStarted = SettlementLatch()
        let addGate = SettlementLatch()
        let albums = SettlementAlbums(addStarted: addStarted, addGate: addGate)
        let store = ScriptedReadStore()
        let manager = UploadManager(
            uploader: uploader,
            albums: albums,
            identityResolver: SettlementIdentityResolver(),
            settlementStore: store,
            maxConcurrent: 1
        )
        let ids = await manager.enqueueFiles([try file()], destination: existingAlbum())
        let id = try XCTUnwrap(ids.first)

        await addStarted.wait()
        XCTAssertEqual(store.record(for: id)?.stage, .albumPending)
        store.setReadsFail(true)
        await manager.cancel(id)
        let afterCancel = await manager.snapshot()
        XCTAssertEqual(
            afterCancel.first?.state, .finalizing,
            "Cancel must not demote a pending album settlement")
        XCTAssertEqual(uploader.cancelledCount, 0)
        store.setReadsFail(false)

        await addGate.signal()
        let items = await waitUntil(manager) { $0.first?.state == .completed }
        XCTAssertEqual(items.first?.state, .completed)
        XCTAssertEqual(store.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
        await manager.shutdown()
    }

    /// Shutdown must not claim the native cancellation of a live upload whose receipt row is
    /// persisted, even while every store read fails. The row stays pending for the next launch.
    func testShutdownNeverCancelsALiveUploadWithAPersistedReceiptWhileStoreReadsFail() async throws {
        let recordStarted = SettlementLatch()
        let recordGate = SettlementLatch()
        let recordCancelled = SettlementLatch()
        let resolver = SettlementIdentityResolver(
            recordStarted: recordStarted, recordGate: recordGate, recordCancelled: recordCancelled)
        let uploader = SettlementUploader()
        let store = ScriptedReadStore()
        let recorder = StateRecorder()
        let manager = UploadManager(
            uploader: uploader, identityResolver: resolver, settlementStore: store, maxConcurrent: 1)
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        await recordStarted.wait()
        XCTAssertEqual(store.record(for: id)?.stage, .manifestPending, "The receipt row is persisted")
        store.setReadsFail(true)
        let shutdown = Task { await manager.shutdown() }
        // Shutdown cancels the item task only after its cancellation claims ran.
        await recordCancelled.wait()
        await recordGate.signal()
        await shutdown.value
        store.setReadsFail(false)

        XCTAssertEqual(uploader.cancelledCount, 0, "The native uploader must never see this token")
        XCTAssertFalse(
            recorder.sequence(id).contains(.cancelled),
            "Shutdown must not demote a live upload whose receipt row is persisted")
        XCTAssertEqual(
            store.record(for: id)?.stage, .manifestPending,
            "The receipt row stays pending, so the next launch settles it")
        XCTAssertEqual(uploader.requestCount, 1)
    }

    /// A fresh upload has no receipt and no settlement record in memory, so it has no durable row:
    /// the only writer of that row caches the record in the same actor step. Pause, cancel and
    /// shutdown must act on such an upload even after the settlement store failed for good.
    private func liveFreshUploadWithALastingStoreFailure() async throws -> (
        manager: UploadManager, id: UploadQueueItemID, uploader: SettlementUploader
    ) {
        let uploader = SettlementUploader(waitsForRelease: true, throwsWhenCancelled: true)
        let durableStore = try store()
        let manager = UploadManager(uploader: uploader, settlementStore: durableStore, maxConcurrent: 1)
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        await uploader.waitUntilStarted()
        // A closed connection is a lasting failure: no read can succeed again in this session.
        durableStore.close()
        XCTAssertTrue(durableStore.hasLastingFailure())
        guard case .unreadable = durableStore.readOutcome(for: id) else {
            XCTFail("Every read of the closed store must be unreadable")
            return (manager, id, uploader)
        }
        return (manager, id, uploader)
    }

    func testPauseActsOnALiveFreshUploadWhileTheStoreHasALastingFailure() async throws {
        let (manager, id, uploader) = try await liveFreshUploadWithALastingStoreFailure()
        await manager.pause(id)
        let items = await manager.snapshot()
        XCTAssertEqual(items.first?.state, .paused, "Pause must stop a fresh upload without a receipt")
        XCTAssertEqual(uploader.requestCount, 1)
        await manager.shutdown()
    }

    func testCancelActsOnALiveFreshUploadWhileTheStoreHasALastingFailure() async throws {
        let (manager, id, uploader) = try await liveFreshUploadWithALastingStoreFailure()
        // A cancel that wrongly declines the claim waits for the parked upload. Run it beside the
        // test and release the upload after the assertions, so that defect fails instead of hanging.
        let cancellation = Task { await manager.cancel(id) }
        let items = await waitUntil(manager) {
            $0.first?.state == .cancelled && uploader.cancelledCount == 1
        }
        XCTAssertEqual(items.first?.state, .cancelled, "Cancel must stop a fresh upload without a receipt")
        XCTAssertEqual(uploader.cancelledCount, 1, "Cancel must reach the native uploader")
        XCTAssertEqual(uploader.requestCount, 1)
        await uploader.releaseUpload()
        await cancellation.value
        await manager.shutdown()
    }

    func testShutdownCancelsALiveFreshUploadWhileTheStoreHasALastingFailure() async throws {
        let (manager, _, uploader) = try await liveFreshUploadWithALastingStoreFailure()
        await manager.shutdown()
        XCTAssertEqual(uploader.cancelledCount, 1, "Sign-out must cancel a fresh upload without a receipt")
        XCTAssertEqual(uploader.requestCount, 1)
    }

    // MARK: Late replay sweep (#1104)

    /// A replay sweep that succeeds only after a live upload of this session wrote its receipt row
    /// must leave that row to the live upload. A second owner would record the manifest twice.
    func testALateReplaySweepLeavesTheRowOfALiveUploadToThatUpload() async throws {
        let recordStarted = SettlementLatch()
        let recordGate = SettlementLatch()
        let resolver = SettlementIdentityResolver(recordStarted: recordStarted, recordGate: recordGate)
        let uploader = SettlementUploader()
        let store = ScriptedReadStore()
        store.setSweepsFail(true)
        let recorder = StateRecorder()
        let manager = UploadManager(
            uploader: uploader, identityResolver: resolver, settlementStore: store, maxConcurrent: 1)
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)

        await recordStarted.wait()
        XCTAssertEqual(store.record(for: id)?.stage, .manifestPending, "The live upload wrote its row")
        // The sweep heals now. The next snapshot runs it while the live upload owns the row.
        store.setSweepsFail(false)
        _ = await manager.snapshot()
        await recordGate.signal()
        _ = await waitUntil(manager) { $0.first?.state == .completed }
        // Shutdown joins every item and settlement task, so the counts below are final.
        await manager.shutdown()

        XCTAssertEqual(resolver.recordedCount, 1, "The manifest must be recorded exactly once")
        XCTAssertEqual(recorder.sequence(id).last, .completed)
        XCTAssertEqual(store.record(for: id)?.terminalState, .completed)
        XCTAssertEqual(uploader.requestCount, 1)
    }

    func testUploadCompletionKeepsBytesRetryableWhenTheSettlementReadIsUnreadable() async throws {
        let uploader = SettlementUploader()
        let store = ScriptedReadStore()
        let manager = UploadManager(uploader: uploader, settlementStore: store, maxConcurrent: 1)

        // The non-scoped upload path reads the store twice: the byte-upload gate reads before
        // the bytes start, and the completion path reads again after they committed. The first
        // answer must allow the upload; the second is unreadable, which is no proof that no
        // settlement exists, so the item must stay visibly failed and retryable instead of
        // completing without durable proof (#1104).
        store.scriptReads([.absent, .unreadable])
        let ids = await manager.enqueueFiles([try file()], destination: .library)
        let id = try XCTUnwrap(ids.first)
        let items = await waitUntil(manager) { items in
            guard let item = items.first else { return false }
            return item.state.isTerminal
        }

        XCTAssertEqual(
            items.first?.state,
            .failed(message: "Durable manual upload settlement could not be read."),
            "An unreadable completion read is no proof that no settlement exists; the item"
                + " must stay visibly failed and retryable, not complete (#1104)")
        XCTAssertEqual(items.first?.id, id)
        XCTAssertEqual(items.first?.uploadedUID, testUID("photo.jpg"))
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertTrue(store.removedIDs.isEmpty)
        await manager.shutdown()
    }
}
