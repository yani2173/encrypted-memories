import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class UploadBackupSyncQueueTests: XCTestCase {
    private struct RemoteProofResolver: UploadIdentityResolving {
        let proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]

        func remoteAssetProofs(
            for identities: [UploadBackupExternalIdentity]
        ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
            proofs.filter { identities.contains($0.key) }
        }

        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw UploadError.backend("byte resolver must not run during discovery")
        }

        func recordUploaded(
            _ descriptor: UploadResourceDescriptor,
            identity: UploadIdentity,
            remoteVolumeID: String,
            remoteLinkID: String
        ) async throws {}
    }

    private struct CancellingProofResolver: UploadIdentityResolving {
        var failure: any Error = CancellationError()
        func remoteAssetProofs(
            for identities: [UploadBackupExternalIdentity]
        ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
            throw failure
        }

        func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
            throw failure
        }

        func recordUploaded(
            _ descriptor: UploadResourceDescriptor,
            identity: UploadIdentity,
            remoteVolumeID: String,
            remoteLinkID: String
        ) async throws {}
    }

    private struct StaticCatalog: UploadBackupAssetCatalog {
        let items: [UploadBackupAssetCandidate]

        func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
            AsyncThrowingStream { continuation in
                for item in items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    private final class MemoryBackupStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]
        private var writes = 0
        private let onWrite: @Sendable (UploadBackupAssetRecord) -> Void
        init(onWrite: @escaping @Sendable (UploadBackupAssetRecord) -> Void = { _ in }) { self.onWrite = onWrite }
        var upsertCount: Int { lock.withLock { writes } }

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }

        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }

        func upsert(_ record: UploadBackupAssetRecord) -> Bool {
            lock.withLock {
                writes += 1
                rows[record.source, default: [:]][record.revision] = record
            }
            onWrite(record)
            return true
        }

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-backup-sync-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func source(_ id: String, resource: UploadSourceIdentity.Resource = .primary) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: resource)
    }

    private func candidate(
        id: String,
        revision seconds: TimeInterval,
        editRevision: UploadBackupEditRevision = .unavailable,
        resource: UploadSourceIdentity.Resource = .primary,
        externalIdentity: UploadBackupExternalIdentity? = nil,
        resourceCount: Int = 1
    ) -> UploadBackupAssetCandidate {
        let snapshot = UploadBackupAssetSnapshot(
            source: source(id, resource: resource),
            revision: revision(seconds),
            editRevision: editRevision,
            resourceCount: resourceCount,
            externalIdentity: externalIdentity
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: "IMG_\(id).HEIC",
            byteCount: 1024
        )
    }

    func testB1UnknownEngineReadsStopBeforeQueueAndPreflightChanges() async throws {
        for route in ["presence", "candidate", "restore", "changed", "late-main"] {
            let url = tempDir.appendingPathComponent("unknown-\(route).sqlite")
            let inner = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            defer { inner.close() }
            let observer = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            defer { observer.close() }
            let photo = candidate(id: route, revision: 42)
            let state = MemoryBackupStore()
            let index = UploadBackupPreflightIndex(store: state)
            if route == "restore" || route == "late-main" { try await index.markBackedUp(photo.snapshot) }
            let previous = state.record(for: photo.snapshot.source, revision: photo.snapshot.revision)
            let writes = state.upsertCount
            let rowState: UploadBackupSyncQueueState =
                route == "restore" || route == "late-main"
                ? .completed
                : route == "changed" ? .sourceMissing : .dismissedFailure
            let row = UploadBackupSyncQueueEntry(
                source: photo.snapshot.source, revision: photo.snapshot.revision,
                originalFilename: photo.originalFilename, state: rowState, lastError: "kept reason",
                updatedAt: Date(timeIntervalSince1970: 1_000))
            XCTAssertTrue(inner.upsert(row))
            let events = BackupEventLog()
            let queue = SpyQueueStore(inner: inner, log: events)
            let engine = UploadBackupSyncEngine(preflight: index, queue: queue)
            let fault = try SQLiteReadInterrupt(
                in: inner,
                matching:
                    route == "presence"
                    ? "SELECT 1 FROM backup_sync_queue WHERE state IN"
                    : "SELECT original_filename, byte_count, state")
            defer { fault.stop() }

            var needsChangedRetry = false
            do {
                switch route {
                case "presence", "candidate": _ = try await engine.enqueueBatch([photo])
                case "restore": _ = try await engine.reopenRestoredCompound(photo, isCurrent: { true })
                case "changed": try await engine.enqueueChangedMissingSources([photo])
                default: _ = try await engine.reopenBackedUpRevisions([.init(candidate: photo, formerMain: nil)])
                }
                XCTFail("\(route): an unknown read must stop the decision")
            } catch {
                needsChangedRetry = route == "changed"
                XCTAssertEqual(
                    error as? UploadError, .backend(L10n.string("backup.error_local_state_unavailable")), route)
            }

            XCTAssertTrue(fault.fired, route)
            XCTAssertTrue(queue.isOperational(), "The read-specific error must survive a healthy later probe: \(route)")
            XCTAssertEqual(try observer.entry(for: row.source, revision: row.revision), row, route)
            XCTAssertEqual(state.record(for: photo.snapshot.source, revision: photo.snapshot.revision), previous, route)
            XCTAssertEqual(state.upsertCount, writes, route)
            XCTAssertTrue(events.events.isEmpty, route)
            if route == "changed" {
                fault.stop()
                if needsChangedRetry { try await engine.enqueueChangedMissingSources([photo]) }
                XCTAssertEqual(
                    try observer.entry(for: row.source, revision: row.revision)?.state, .discovered,
                    "A propagated failure permits retrying the same changed missing source; it must not be silently omitted"
                )
            }
        }
    }

    func testLateMainReopeningCertifiesTheRowAgainAfterPreflight() async throws {
        for change in ["removed", "changed", "unknown", "decode"] {
            let url = tempDir.appendingPathComponent("late-main-\(change).sqlite")
            let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            defer { queue.close() }
            let observer = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            defer { observer.close() }
            let photo = candidate(id: change, revision: 42)
            let row = UploadBackupSyncQueueEntry(
                source: photo.snapshot.source, revision: photo.snapshot.revision,
                originalFilename: photo.originalFilename, state: .completed,
                updatedAt: Date(timeIntervalSince1970: 1_000))
            let state = MemoryBackupStore { record in
                guard !record.isComplete else { return }
                if change == "removed" {
                    XCTAssertTrue(queue.remove(source: row.source, revision: row.revision))
                } else if change == "decode" {
                    guard
                        let connection = Mirror(reflecting: queue).children.first(where: { $0.label == "connection" })?
                            .value as? SQLiteStoreConnection
                    else {
                        return XCTFail("The concrete queue connection must be available")
                    }
                    connection.withLock {
                        XCTAssertEqual(
                            sqlite3_exec(
                                connection.database,
                                "UPDATE backup_sync_queue SET remote_commit_reconciliation='not-json';", nil, nil, nil),
                            SQLITE_OK)
                    }
                } else if change == "changed" {
                    XCTAssertTrue(
                        queue.updateState(
                            source: row.source, revision: row.revision, state: .failedPermanent,
                            attempts: nil, lastError: "new reason", updatedAt: row.updatedAt))
                }
            }
            let index = UploadBackupPreflightIndex(store: state)
            try await index.markBackedUp(photo.snapshot)
            XCTAssertTrue(queue.upsert(row))
            let decisionQueue: any UploadBackupSyncQueueStore =
                change == "decode" ? queue : SpyQueueStore(inner: queue, log: BackupEventLog())
            let engine = UploadBackupSyncEngine(preflight: index, queue: decisionQueue)
            let fault =
                change == "unknown"
                ? try SQLiteReadInterrupt(
                    in: queue,
                    matching: "SELECT original_filename, byte_count, state", occurrence: 2) : nil
            defer { fault?.stop() }
            do {
                _ = try await engine.reopenBackedUpRevisions([.init(candidate: photo, formerMain: nil)])
                if change == "unknown" || change == "decode" {
                    XCTFail("The second unknown read must stop removal: \(change)")
                }
            } catch {
                if change == "unknown" || change == "decode" {
                    XCTAssertEqual(error as? UploadError, .backend(L10n.string("backup.error_local_state_unavailable")))
                } else {
                    XCTFail("A changed or removed row must not fail reopening: \(error)")
                }
            }
            if change == "decode" {
                XCTAssertEqual(
                    try observer.decisionRows(kind: row.source.kind, identifiers: [row.source.identifier]).map(\.state),
                    [.completed])
                XCTAssertEqual(observer.count(), 1)
                continue
            }
            let kept = try observer.entry(for: row.source, revision: row.revision)
            if change == "removed" {
                XCTAssertNil(kept)
            } else if change == "changed" {
                XCTAssertEqual(kept?.state, .failedPermanent, "The stale completed row must not authorize removal")
                XCTAssertEqual(kept?.lastError, "new reason")
            } else {
                XCTAssertTrue(try XCTUnwrap(fault).fired)
                XCTAssertEqual(kept, row, "Unknown after preflight must leave the queue row unchanged")
                fault?.stop()
                _ = try await engine.reopenBackedUpRevisions([.init(candidate: photo, formerMain: nil)])
                XCTAssertNil(
                    try observer.entry(for: row.source, revision: row.revision),
                    "A complete retry must finish reopening")
            }
        }
    }

    func testLateMainReopeningRejectsATrashedManifestMainAsUploadProof() async throws {
        for isTrashed in [false, true] {
            let queue = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(
                    url: tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")))
            defer { queue.close() }
            let photo = candidate(id: "photo", revision: 42)
            let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
            try await index.markBackedUp(photo.snapshot)
            XCTAssertTrue(
                queue.upsert(
                    .init(
                        source: photo.snapshot.source, revision: photo.snapshot.revision,
                        originalFilename: photo.originalFilename, state: .completed, updatedAt: Date())))
            let identities = FakeIdentityStore()
            let former = source("photo", resource: .photoKit(role: "originalPhoto", ordinal: 0))
            for identity in [photo.snapshot.source, former] {
                XCTAssertTrue(
                    identities.upsert(
                        .init(
                            source: identity, filename: "photo", correctedName: "photo", fileSize: 1,
                            modificationDate: .distantPast, sha1Hex: identity == former ? "original" : "render",
                            nameHash: "name", contentHash: "content", hashKeyEpoch: "epoch", remoteLinkID: "link",
                            outcome: identity == photo.snapshot.source && isTrashed ? "duplicateTrashed" : "uploaded",
                            updatedAt: .distantPast)))
            }
            let engine = UploadBackupSyncEngine(
                preflight: index, queue: queue,
                remoteProofResolver: UploadDedupePipeline(store: identities, checker: FakeChecker()))
            let reopened = try await engine.reopenBackedUpRevisions([.init(candidate: photo, formerMain: former)])
            XCTAssertEqual(reopened, isTrashed ? [photo] : [])
            XCTAssertEqual(
                try queue.entry(for: photo.snapshot.source, revision: photo.snapshot.revision) == nil, isTrashed)
        }
    }

    func testSQLiteQueueRoundTripsAndOrdersRunnableWork() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let old = UploadBackupSyncQueueEntry(
            source: source("old"),
            revision: revision(10),
            originalFilename: "old.heic",
            byteCount: 10,
            state: .queuedForUpload,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = UploadBackupSyncQueueEntry(
            source: source("new"),
            revision: revision(20),
            originalFilename: "new.heic",
            byteCount: nil,
            state: .checking,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let done = UploadBackupSyncQueueEntry(
            source: source("done"),
            revision: revision(30),
            originalFilename: "done.heic",
            state: .completed,
            updatedAt: Date(timeIntervalSince1970: 5)
        )

        store.upsert(newer)
        store.upsert(done)
        store.upsert(old)

        XCTAssertEqual(try store.entry(for: old.source, revision: old.revision), old)
        XCTAssertEqual(store.runnableEntries().map(\.source.identifier), ["old"])
        XCTAssertEqual(store.summary()!.total, 3)
        XCTAssertEqual(store.summary()!.waiting, 1)
        XCTAssertEqual(store.summary()!.active, 1)
        XCTAssertEqual(store.summary()!.uploaded, 1)
    }

    func testRemoteCommitReconciliationSurvivesReopenAndClaimsWithoutLosingReceipt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let entry = UploadBackupSyncQueueEntry(
            source: source("committed"),
            revision: revision(10),
            originalFilename: "committed.heic",
            state: .uploading,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let reconciliation = UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: entry.originalFilename,
                nameHash: "name-hash",
                sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "content-hash"
            ),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link")
        )

        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.upsert(entry))
            XCTAssertTrue(
                store.markNeedsRemoteReconciliation(
                    source: entry.source,
                    revision: entry.revision,
                    reconciliation: reconciliation,
                    lastError: "manifest unavailable",
                    updatedAt: Date(timeIntervalSince1970: 11)
                ))
        }

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let pending = try XCTUnwrap(reopened.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(pending.state, .needsRemoteReconciliation)
        XCTAssertEqual(pending.remoteCommitReconciliation, reconciliation)
        XCTAssertNil(pending.remoteCommitReconciliation?.descriptor, "legacy receipts decode without a descriptor")
        XCTAssertNil(pending.remoteCommitReconciliation?.queueBinding, "legacy receipts decode without a queue binding")
        let claimed = try XCTUnwrap(
            reopened.claimRunnable(
                limit: 1,
                claimedAt: Date(timeIntervalSince1970: 12)
            )?.first)
        XCTAssertEqual(claimed.state, .needsRemoteReconciliation)
        XCTAssertEqual(claimed.remoteCommitReconciliation, reconciliation)
        XCTAssertEqual(
            try reopened.entry(for: entry.source, revision: entry.revision)?.state,
            .checking
        )
    }

    /// A catalog scan can upsert the revision that the runner has claimed. The claim keeps the receipt of an upload that
    /// already reached Proton, and the scan must not replace it.
    func testScanUpsertOfAClaimedRowKeepsItsReceipt() throws {
        let store = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let entry = UploadBackupSyncQueueEntry(
            source: source("claimed"), revision: revision(10), originalFilename: "claimed.heic", state: .uploading,
            attempts: 2, updatedAt: Date(timeIntervalSince1970: 10))
        let reconciliation = UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: entry.originalFilename, nameHash: "name-hash",
                sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "content-hash"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link"))
        let scanned = UploadBackupSyncQueueEntry(
            source: entry.source, revision: entry.revision, originalFilename: "claimed.heic", state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 13))
        XCTAssertTrue(store.upsert(entry))
        XCTAssertTrue(
            store.markNeedsRemoteReconciliation(
                source: entry.source, revision: entry.revision, reconciliation: reconciliation,
                lastError: "manifest unavailable", updatedAt: Date(timeIntervalSince1970: 11)))
        let stored = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertGreaterThan(stored.attempts, 0)
        XCTAssertEqual(stored.lastError, "manifest unavailable")

        XCTAssertTrue(store.upsert(scanned))
        let reconciling = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(reconciling.remoteCommitReconciliation, reconciliation, "a reconciliation row keeps its receipt")
        XCTAssertEqual(reconciling.attempts, stored.attempts)
        XCTAssertEqual(reconciling.lastError, stored.lastError)
        XCTAssertEqual(store.claimRunnable(limit: 1, claimedAt: Date(timeIntervalSince1970: 12))?.count, 1)

        XCTAssertTrue(store.upsert(scanned))
        let claimed = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(claimed.state, .checking)
        XCTAssertEqual(claimed.remoteCommitReconciliation, reconciliation, "the scan keeps the claimed row's receipt")
        XCTAssertEqual(claimed.attempts, stored.attempts, "the scan keeps the claimed row's attempts")
        XCTAssertEqual(claimed.lastError, stored.lastError, "the scan keeps the claimed row's error")

        XCTAssertTrue(store.upsertBatch([scanned]))
        XCTAssertEqual(
            try store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation, reconciliation)
        XCTAssertEqual(store.requeueStaleActive(before: Date(timeIntervalSince1970: 100), updatedAt: Date()), 1)
        let recovered = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(recovered.state, .needsRemoteReconciliation, "an interrupted claim resumes from its receipt")
        XCTAssertEqual(recovered.remoteCommitReconciliation, reconciliation)
    }

    func testScanUpsertOfAnUnclaimedRowStillTakesTheIncomingReceipt() throws {
        let store = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        var entry = UploadBackupSyncQueueEntry(
            source: source("unclaimed"), revision: revision(10), originalFilename: "unclaimed.heic",
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 10))
        let reconciliation = UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: entry.originalFilename, nameHash: "name-hash",
                sha1Hex: String(repeating: "cd", count: 20), sha1Digest: Data(repeating: 0xCD, count: 20),
                contentHash: "content-hash"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link"))
        XCTAssertTrue(store.upsert(entry))

        entry.remoteCommitReconciliation = reconciliation
        XCTAssertTrue(store.upsert(entry))
        XCTAssertEqual(
            try store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation, reconciliation)

        entry.remoteCommitReconciliation = nil
        XCTAssertTrue(store.upsert(entry))
        XCTAssertNil(try store.entry(for: entry.source, revision: entry.revision)?.remoteCommitReconciliation)
    }

    func testQueueWideRuntimeIssueSurvivesReopenAndClearsExplicitly() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let expected = BackupIssueRecord(
            kind: .network,
            detail: "remote index unavailable",
            nextAttemptAt: Date(timeIntervalSinceReferenceDate: 123)
        )
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.setRuntimeIssue(expected, for: .remoteIndexPreparation))
            XCTAssertEqual(store.runtimeIssue(for: .remoteIndexPreparation), expected)
        }
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(reopened.runtimeIssue(for: .remoteIndexPreparation), expected)
        XCTAssertTrue(reopened.setRuntimeIssue(nil, for: .remoteIndexPreparation))
        XCTAssertNil(reopened.runtimeIssue(for: .remoteIndexPreparation))
    }

    func testCatalogReplayStateSurvivesReopenAndDistinguishesInterruptedRecovery() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertEqual(store.catalogReplayState(), .notStarted)
            XCTAssertTrue(store.setCatalogReplayState(.inProgress))
            XCTAssertEqual(store.catalogReplayState(), .inProgress)
        }

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(reopened.catalogReplayState(), .inProgress, "an interrupted rebuild must resume after relaunch")
        XCTAssertTrue(reopened.setCatalogReplayState(.completed))
        XCTAssertEqual(reopened.catalogReplayState(), .completed)
    }

    func testSQLiteQueueBatchRollsBackCompletelyWhenOneRowFails() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                """
                CREATE TRIGGER reject_bad_queue_row
                BEFORE INSERT ON backup_sync_queue
                WHEN NEW.source_id='bad'
                BEGIN SELECT RAISE(ABORT, 'test failure'); END;
                """,
                nil, nil, nil
            ), SQLITE_OK)
        sqlite3_close(handle)

        let entries = ["good", "bad"].map { id in
            UploadBackupSyncQueueEntry(
                source: source(id),
                revision: revision(10),
                originalFilename: "\(id).heic",
                state: .discovered,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        }
        XCTAssertFalse(store.upsertBatch(entries))
        XCTAssertEqual(store.count(), 0, "a failed discovery chunk must not leave a partial queue frontier")
        // Verify the file contains zero rows despite the failed upsert.
        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &check), SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(check, "SELECT COUNT(*) FROM backup_sync_queue;", -1, &stmt, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(
            sqlite3_column_int(stmt, 0), 0,
            "a failed discovery chunk must not leave a partial queue frontier")
        sqlite3_finalize(stmt)
    }

    func testTwentyThousandQueueBatchStructuralSmoke() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let entries = (0..<20_000).map { index in
            UploadBackupSyncQueueEntry(
                source: source(String(index)),
                revision: revision(TimeInterval(index)),
                originalFilename: "IMG_\(index).HEIC",
                state: .discovered,
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        }

        let startedAt = Date()
        XCTAssertTrue(store.upsertBatch(entries))
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000

        XCTAssertEqual(store.count(), 20_000)
        XCTAssertEqual(store.summary()!.waiting, 20_000)
        XCTAssertEqual(store.claimRunnable(limit: 1, claimedAt: Date())?.first?.source.identifier, "19999")
        let formattedElapsedMs = String(format: "%.2f", elapsedMs)
        print("[BackupDBMicroPerf] queue20k saveMs=\(formattedElapsedMs)")
    }

    func testRunnableWorkDrainsNewestPhotoFirstRegardlessOfEnqueueTime() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        // A backlog and a newly captured photo have different asset dates and update times.
        // The newest photo must drain first, protecting it ahead of the backlog.
        let oldBacklog = UploadBackupSyncQueueEntry(
            source: source("backlog"), revision: revision(100),
            originalFilename: "backlog.heic", byteCount: 1,
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let justTaken = UploadBackupSyncQueueEntry(
            source: source("fresh"), revision: revision(9_999),
            originalFilename: "fresh.heic", byteCount: 1,
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 9_000_000)
        )
        store.upsert(oldBacklog)
        store.upsert(justTaken)

        let claimed = try XCTUnwrap(store.claimRunnable(limit: 2, claimedAt: Date(timeIntervalSince1970: 9_000_001)))
        XCTAssertEqual(
            claimed.map(\.source.identifier), ["fresh", "backlog"],
            "newest photo (highest revision) drains first, even though it was enqueued last")
    }

    func testSQLiteQueueUpdatesStateWithoutRewritingDescriptor() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let entry = UploadBackupSyncQueueEntry(
            source: source("asset"),
            revision: revision(10),
            originalFilename: "asset.heic",
            byteCount: 99,
            state: .hashing,
            attempts: 1,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        store.upsert(entry)

        store.updateState(
            source: entry.source,
            revision: entry.revision,
            state: .failed,
            attempts: 2,
            lastError: "network",
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let updated = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(updated.originalFilename, "asset.heic")
        XCTAssertEqual(updated.byteCount, 99)
        XCTAssertEqual(updated.state, .failed)
        XCTAssertEqual(updated.attempts, 2)
        XCTAssertEqual(updated.lastError, "network")
    }

    func testManualRetryMakesOnlyRetryableRowsDueNow() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let future = Date(timeIntervalSince1970: 10_000)
        let now = Date(timeIntervalSince1970: 500)
        let seeded: [(String, UploadBackupSyncQueueState, Int)] = [
            ("failed", .failed, 8),
            ("draft", .blockedByDraft, 24),
            ("waiting", .discovered, 3),
            ("upload", .queuedForUpload, 4),
            ("deleted", .skippedRemoteDeletion, 0),
            ("missing", .sourceMissing, 0),
            ("permanent", .failedPermanent, 8),
            ("dismissed", .dismissedFailure, 8),
            ("done", .completed, 0),
        ]
        for (id, state, attempts) in seeded {
            XCTAssertTrue(
                store.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source(id),
                        revision: revision(1),
                        originalFilename: "\(id).heic",
                        state: state,
                        attempts: attempts,
                        lastError: "old",
                        updatedAt: future
                    )))
        }

        XCTAssertEqual(store.makeRetryableWorkEligible(updatedAt: now), 4)

        let failed = try XCTUnwrap(store.entry(for: source("failed"), revision: revision(1)))
        XCTAssertEqual(failed.state, .discovered)
        XCTAssertEqual(failed.attempts, 0, "terminal failure gets a fresh user-initiated retry budget")
        let draft = try XCTUnwrap(store.entry(for: source("draft"), revision: revision(1)))
        XCTAssertEqual(draft.state, .discovered)
        XCTAssertEqual(draft.attempts, 24, "draft history must remain available for truthful diagnostics")
        let queued = try XCTUnwrap(store.entry(for: source("upload"), revision: revision(1)))
        XCTAssertEqual(queued.state, .queuedForUpload)
        for id in ["failed", "draft", "waiting", "upload"] {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(1)))
            XCTAssertEqual(entry.updatedAt, now)
            XCTAssertEqual(entry.lastError, "old", "manual retry must preserve the reason")
        }
        for id in ["deleted", "missing", "permanent", "dismissed", "done"] {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(1)))
            XCTAssertEqual(entry.updatedAt, future, "non-retryable and successful rows must not move")
        }
    }

    func testManualRetryKeepsTheEncodedIssueAndNextAttempt() throws {
        let store = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        let future = Date(timeIntervalSince1970: 10_000)
        let record = BackupIssueRecord(
            kind: .network, detail: "transport detail", nextAttemptAt: future, automaticRetryAttempt: 6)
        let entry = UploadBackupSyncQueueEntry(
            source: source("network-record"), revision: revision(1), originalFilename: "network.heic",
            state: .discovered, attempts: 3, lastError: record.persistedValue, updatedAt: future)
        XCTAssertTrue(store.upsert(entry))
        let now = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(store.makeRetryableWorkEligible(updatedAt: now), 1)
        let retried = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(retried.updatedAt, now)
        // JSONEncoder fixes no key order, so the stored text can differ; the decoded issue must not.
        XCTAssertEqual(BackupIssueRecord.decode(retried.lastError), record)
        XCTAssertEqual(retried.attempts, 3)
        XCTAssertEqual(retried.state, .discovered)
    }

    func testPermanentFailureCanBeDismissedWithoutBecomingBackedUp() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let failed = UploadBackupSyncQueueEntry(
            source: source("stale-draft"),
            revision: revision(1),
            originalFilename: "IMG_0001.HEIC",
            state: .failedPermanent,
            attempts: 8,
            lastError: "stale draft",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertTrue(store.upsert(failed))

        XCTAssertTrue(
            store.dismissPermanentFailure(
                source: failed.source,
                revision: failed.revision,
                updatedAt: Date(timeIntervalSince1970: 200)
            ))

        let dismissed = try XCTUnwrap(store.entry(for: failed.source, revision: failed.revision))
        XCTAssertEqual(dismissed.state, .dismissedFailure)
        XCTAssertEqual(dismissed.lastError, "stale draft")
        XCTAssertEqual(store.summary()!.dismissedFailures, 1)
        XCTAssertEqual(store.summary()!.resolved, 0, "acknowledgement must never claim upload success")
        XCTAssertEqual(store.makeRetryableWorkEligible(updatedAt: Date(timeIntervalSince1970: 300)), 0)
    }

    func testSQLiteQueueListsEntriesInOneStateOldestFirst() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for (id, state, at) in [
            ("blocked-new", UploadBackupSyncQueueState.blockedByDraft, 30.0),
            ("blocked-old", .blockedByDraft, 10.0),
            ("waiting", .discovered, 5.0),
            ("blocked-future", .blockedByDraft, 100.0),
        ] {
            store.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id),
                    revision: revision(1),
                    originalFilename: "\(id).heic",
                    state: state,
                    updatedAt: Date(timeIntervalSince1970: at)
                ))
        }

        let due = store.entries(in: .blockedByDraft, updatedBefore: Date(timeIntervalSince1970: 50), limit: 10)
        XCTAssertEqual(
            due.map(\.source.identifier), ["blocked-old", "blocked-new"],
            "state filter + oldest-first ordering + strict updatedBefore cutoff")
        XCTAssertEqual(
            store.entries(in: .blockedByDraft, updatedBefore: Date(timeIntervalSince1970: 50), limit: 1).count, 1)
        XCTAssertTrue(store.entries(in: .sourceMissing, updatedBefore: .distantFuture, limit: 10).isEmpty)
    }

    func testQueueRemovalDeletesExactRevisionOrAllResourcesForSource() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for entry in [
            UploadBackupSyncQueueEntry(
                source: source("asset"), revision: revision(1), originalFilename: "asset.heic", updatedAt: .now
            ),
            UploadBackupSyncQueueEntry(
                source: source("asset"), revision: revision(2), originalFilename: "asset.heic", updatedAt: .now
            ),
            UploadBackupSyncQueueEntry(
                source: source("asset", resource: .livePairedVideo), revision: revision(2),
                originalFilename: "asset.mov", updatedAt: .now
            ),
            UploadBackupSyncQueueEntry(
                source: source("other"), revision: revision(1), originalFilename: "other.heic", updatedAt: .now
            ),
        ] {
            XCTAssertTrue(store.upsert(entry))
        }

        XCTAssertTrue(store.remove(source: source("asset"), revision: revision(1)))
        XCTAssertEqual(store.count(), 3)
        XCTAssertEqual(store.removeSources(kind: .photoLibraryAsset, identifiers: ["asset"]), 2)
        XCTAssertEqual(store.count(), 1)
        XCTAssertNotNil(try store.entry(for: source("other"), revision: revision(1)))
    }

    func testRemovingSettledRevisionsKeepsTheCurrentRevisionAndUnsettledWork() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        func entry(
            _ id: String, _ seconds: TimeInterval, _ state: UploadBackupSyncQueueState
        ) -> UploadBackupSyncQueueEntry {
            UploadBackupSyncQueueEntry(
                source: source(id), revision: revision(seconds), originalFilename: "\(id).heic", state: state,
                updatedAt: .now)
        }
        for entry in [
            entry("asset", 1, .completed), entry("asset", 2, .alreadyBackedUp), entry("asset", 3, .completed),
            entry("asset", 4, .failed), entry("asset", 5, .skippedRemoteDeletion), entry("other", 1, .completed),
        ] {
            XCTAssertTrue(store.upsert(entry))
        }

        XCTAssertTrue(store.removeSettledRevisions(of: source("asset"), except: revision(3)))

        XCTAssertNil(try store.entry(for: source("asset"), revision: revision(1)))
        XCTAssertNil(try store.entry(for: source("asset"), revision: revision(2)))
        XCTAssertEqual(try store.entry(for: source("asset"), revision: revision(3))?.state, .completed)
        XCTAssertEqual(try store.entry(for: source("asset"), revision: revision(4))?.state, .failed)
        XCTAssertEqual(try store.entry(for: source("asset"), revision: revision(5))?.state, .skippedRemoteDeletion)
        XCTAssertNotNil(try store.entry(for: source("other"), revision: revision(1)))
        // The earlier revision starts as new work when the photo returns to it.
        XCTAssertTrue(store.upsert(entry("asset", 1, .discovered)))
        XCTAssertEqual(try store.entry(for: source("asset"), revision: revision(1))?.state, .discovered)
    }

    func testFolderQueueReconciliationKeepsOnlyRegisteredRoots() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let activeRoot = tempDir.appendingPathComponent("active", isDirectory: true)
        let activeSource = UploadSourceIdentity.file(activeRoot.appendingPathComponent("nested/current.jpg"))
        let removedSource = UploadSourceIdentity.file(
            tempDir.appendingPathComponent("removed/old.jpg")
        )
        let prefixSiblingSource = UploadSourceIdentity.file(
            tempDir.appendingPathComponent("active-copy/not-current.jpg")
        )
        let photoLibrarySource = source("photo-library")

        for (source, filename) in [
            (activeSource, "current.jpg"),
            (removedSource, "old.jpg"),
            (prefixSiblingSource, "not-current.jpg"),
            (photoLibrarySource, "library.heic"),
        ] {
            XCTAssertTrue(
                store.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source,
                        revision: revision(1),
                        originalFilename: filename,
                        updatedAt: .now
                    )))
        }

        XCTAssertEqual(store.removeFileSources(outsideRootPaths: [activeRoot.path]), 2)
        XCTAssertNotNil(try store.entry(for: activeSource, revision: revision(1)))
        XCTAssertNil(try store.entry(for: removedSource, revision: revision(1)))
        XCTAssertNil(try store.entry(for: prefixSiblingSource, revision: revision(1)))
        XCTAssertNotNil(try store.entry(for: photoLibrarySource, revision: revision(1)))

        XCTAssertEqual(store.removeFileSources(outsideRootPaths: []), 1)
        XCTAssertEqual(store.count(), 1)
        XCTAssertNotNil(try store.entry(for: photoLibrarySource, revision: revision(1)))
    }

    func testTypedIssueRoundTripsAndEarliestEligibilityIgnoresExecutionPriority() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let retryAt = Date(timeIntervalSince1970: 200)
        let issue = BackupIssueRecord(
            kind: .network,
            detail: "Connection lost",
            nextAttemptAt: retryAt,
            automaticRetryAttempt: 4
        )
        let earlier = UploadBackupSyncQueueEntry(
            source: source("earlier"), revision: revision(10), originalFilename: "earlier.heic",
            state: .discovered, lastError: issue.persistedValue, updatedAt: retryAt
        )
        let newerPhotoButLaterRetry = UploadBackupSyncQueueEntry(
            source: source("later"), revision: revision(9_999), originalFilename: "later.heic",
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 400)
        )
        XCTAssertTrue(store.upsert(earlier))
        XCTAssertTrue(store.upsert(newerPhotoButLaterRetry))

        let stored = try XCTUnwrap(store.earliestRunnableEntry())
        XCTAssertEqual(stored.source.identifier, "earlier")
        XCTAssertEqual(BackupIssueRecord.decode(stored.lastError), issue)
        XCTAssertEqual(
            BackupIssueRecord.decode(
                BackupIssueRecord(kind: .network, detail: "current payload", nextAttemptAt: retryAt).persistedValue
            )?.automaticRetryAttempt,
            0
        )
        XCTAssertNil(BackupIssueRecord.decode("plain text"))
    }

    func testEarliestRunnableEntryPicksTheOldestAcrossRunnableStatesAndSkipsOthers() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        // The oldest row overall is failed and must never be picked; the oldest runnable row is
        // in needsRemoteReconciliation; discovered and queuedForUpload are strictly newer.
        let failed = UploadBackupSyncQueueEntry(
            source: source("failed"), revision: revision(10), originalFilename: "failed.heic",
            state: .failed, updatedAt: Date(timeIntervalSince1970: 10)
        )
        let reconciling = UploadBackupSyncQueueEntry(
            source: source("reconciling"), revision: revision(20), originalFilename: "reconciling.heic",
            state: .needsRemoteReconciliation, updatedAt: Date(timeIntervalSince1970: 20)
        )
        let discovered = UploadBackupSyncQueueEntry(
            source: source("discovered"), revision: revision(30), originalFilename: "discovered.heic",
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 30)
        )
        let queued = UploadBackupSyncQueueEntry(
            source: source("queued"), revision: revision(40), originalFilename: "queued.heic",
            state: .queuedForUpload, updatedAt: Date(timeIntervalSince1970: 40)
        )
        for entry in [failed, discovered, queued, reconciling] {
            XCTAssertTrue(store.upsert(entry))
        }

        let first = try XCTUnwrap(store.earliestRunnableEntry())
        XCTAssertEqual(
            first.source.identifier, "reconciling", "oldest runnable row wins even when a failed row is older")
        XCTAssertEqual(first.state, .needsRemoteReconciliation)

        XCTAssertTrue(
            store.updateState(
                source: reconciling.source,
                revision: reconciling.revision,
                state: .completed,
                attempts: nil,
                lastError: nil,
                updatedAt: Date(timeIntervalSince1970: 21)
            ))

        let second = try XCTUnwrap(store.earliestRunnableEntry())
        XCTAssertEqual(
            second.source.identifier, "discovered", "after the oldest runnable row leaves, the next oldest wins")
        XCTAssertEqual(second.state, .discovered)
    }

    func testSQLiteQueueAtomicallyClaimsRunnableRowsAndSkipsFutureBackoff() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let now = Date(timeIntervalSince1970: 100)
        let old = UploadBackupSyncQueueEntry(
            source: source("old"),
            revision: revision(10),
            originalFilename: "old.heic",
            state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let ready = UploadBackupSyncQueueEntry(
            source: source("ready"),
            revision: revision(20),
            originalFilename: "ready.heic",
            state: .queuedForUpload,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let future = UploadBackupSyncQueueEntry(
            source: source("future"),
            revision: revision(30),
            originalFilename: "future.heic",
            state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        for entry in [future, ready, old] {
            XCTAssertTrue(store.upsert(entry))
        }

        XCTAssertEqual(store.nextRunnableDate(), old.updatedAt)

        let firstClaim = try XCTUnwrap(store.claimRunnable(limit: 2, claimedAt: now))

        // Newest photo first among the eligible (future-backoff row excluded until its updated_at):
        // ready (revision 20) before the lower-revision row (revision 10).
        XCTAssertEqual(firstClaim.map(\.source.identifier), ["ready", "old"])
        XCTAssertEqual(try store.entry(for: old.source, revision: old.revision)?.state, .checking)
        XCTAssertEqual(try store.entry(for: ready.source, revision: ready.revision)?.state, .checking)
        XCTAssertEqual(try store.entry(for: future.source, revision: future.revision)?.state, .discovered)
        XCTAssertEqual(
            store.claimRunnable(limit: 10, claimedAt: now), [],
            "claimed rows are active and future-backoff rows are not claimable yet")

        let secondClaim = try XCTUnwrap(store.claimRunnable(limit: 10, claimedAt: Date(timeIntervalSince1970: 250)))
        XCTAssertEqual(secondClaim.map(\.source.identifier), ["future"])
        XCTAssertNil(store.nextRunnableDate())
    }

    func testClaimSkipsEveryRowOfAnExcludedSource() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let rows = [
            UploadBackupSyncQueueEntry(
                source: source("running"), revision: revision(30), originalFilename: "running.heic",
                state: .needsRemoteReconciliation, updatedAt: Date(timeIntervalSince1970: 10)),
            UploadBackupSyncQueueEntry(
                source: source("running", resource: .livePairedVideo), revision: revision(20),
                originalFilename: "running.mov", state: .discovered, updatedAt: Date(timeIntervalSince1970: 10)),
            UploadBackupSyncQueueEntry(
                source: source("idle"), revision: revision(10), originalFilename: "idle.heic",
                state: .discovered, updatedAt: Date(timeIntervalSince1970: 10)),
        ]
        for row in rows { XCTAssertTrue(store.upsert(row)) }
        let now = Date(timeIntervalSince1970: 100)

        let claimed = try XCTUnwrap(
            store.claimRunnable(limit: 10, claimedAt: now, excludingSourcesOf: [source("running")]))

        XCTAssertEqual(claimed.map(\.originalFilename), ["idle.heic"], "any resource of an excluded source stays")
        XCTAssertEqual(
            try store.entry(for: rows[0].source, revision: rows[0].revision)?.state, .needsRemoteReconciliation)
        XCTAssertEqual(try store.entry(for: rows[1].source, revision: rows[1].revision)?.state, .discovered)
        XCTAssertEqual(
            store.claimRunnable(limit: 10, claimedAt: now)?.map(\.originalFilename), ["running.heic", "running.mov"],
            "the rows are claimable once the source is no longer excluded")
    }

    /// The runner times its next wake from the rows it can claim, so a running source's row never sets that time.
    func testNextRunnableDateSkipsExcludedSources() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let rows = [
            UploadBackupSyncQueueEntry(
                source: source("running"), revision: revision(30), originalFilename: "running.heic",
                state: .needsRemoteReconciliation, updatedAt: Date(timeIntervalSince1970: 10)),
            UploadBackupSyncQueueEntry(
                source: source("running", resource: .livePairedVideo), revision: revision(20),
                originalFilename: "running.mov", state: .discovered, updatedAt: Date(timeIntervalSince1970: 20)),
            UploadBackupSyncQueueEntry(
                source: source("waiting"), revision: revision(10), originalFilename: "waiting.heic",
                state: .queuedForUpload, updatedAt: Date(timeIntervalSince1970: 300)),
        ]
        for row in rows { XCTAssertTrue(store.upsert(row)) }

        XCTAssertEqual(store.nextRunnableDate(), Date(timeIntervalSince1970: 10))
        XCTAssertEqual(
            store.nextRunnableDate(excludingSourcesOf: [source("running")]), Date(timeIntervalSince1970: 300),
            "any resource of an excluded source stays out")
        XCTAssertNil(store.nextRunnableDate(excludingSourcesOf: [source("running"), source("waiting")]))
    }

    func testConcurrentStoreInstancesNeverClaimTheSameRows() async throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let first = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let second = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let claimedAt = Date(timeIntervalSince1970: 500)
        let entries = (0..<40).map { index in
            UploadBackupSyncQueueEntry(
                source: source("race-\(index)"),
                revision: revision(TimeInterval(index)),
                originalFilename: "race-\(index).heic",
                state: .discovered,
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        }
        for entry in entries { XCTAssertTrue(first.upsert(entry)) }

        let gate = UploadTestBarrier(participantCount: 2)
        let claims = await withTaskGroup(
            of: [UploadBackupSyncQueueEntry].self, returning: [[UploadBackupSyncQueueEntry]].self
        ) { group in
            group.addTask {
                await gate.arriveAndWait()
                return first.claimRunnable(limit: entries.count, claimedAt: claimedAt) ?? []
            }
            group.addTask {
                await gate.arriveAndWait()
                return second.claimRunnable(limit: entries.count, claimedAt: claimedAt) ?? []
            }

            var values: [[UploadBackupSyncQueueEntry]] = []
            for await claim in group { values.append(claim) }
            return values
        }

        let identifiers = claims.flatMap { $0.map(\.source.identifier) }
        XCTAssertEqual(identifiers.count, entries.count)
        XCTAssertEqual(Set(identifiers).count, entries.count, "each durable row may be claimed only once")
        XCTAssertEqual(first.claimRunnable(limit: entries.count, claimedAt: claimedAt), [])
    }

    func testSQLiteQueueRequeuesStaleActiveStatesAfterCrash() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let old = Date(timeIntervalSince1970: 10)
        let fresh = Date(timeIntervalSince1970: 90)
        let recoveredAt = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 50)

        let staleStates: [(String, UploadBackupSyncQueueState, UploadBackupSyncQueueState)] = [
            ("checking", .checking, .discovered),
            ("hashing", .hashing, .discovered),
            ("duplicate", .duplicateChecking, .discovered),
            ("uploading", .uploading, .queuedForUpload),
            ("finalizing", .finalizing, .queuedForUpload),
        ]
        for (id, state, _) in staleStates {
            store.upsert(
                UploadBackupSyncQueueEntry(
                    source: source(id),
                    revision: revision(10),
                    originalFilename: "\(id).heic",
                    state: state,
                    updatedAt: old
                ))
        }
        store.upsert(
            UploadBackupSyncQueueEntry(
                source: source("fresh-uploading"),
                revision: revision(20),
                originalFilename: "fresh.heic",
                state: .uploading,
                updatedAt: fresh
            ))
        store.upsert(
            UploadBackupSyncQueueEntry(
                source: source("done"),
                revision: revision(30),
                originalFilename: "done.heic",
                state: .completed,
                updatedAt: old
            ))

        XCTAssertEqual(store.requeueStaleActive(before: cutoff, updatedAt: recoveredAt), staleStates.count)

        for (id, _, expected) in staleStates {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(10)))
            XCTAssertEqual(entry.state, expected)
            XCTAssertEqual(entry.updatedAt, recoveredAt)
        }
        XCTAssertEqual(try store.entry(for: source("fresh-uploading"), revision: revision(20))?.state, .uploading)
        XCTAssertEqual(try store.entry(for: source("done"), revision: revision(30))?.state, .completed)
        XCTAssertEqual(
            Set(store.runnableEntries().map(\.source.identifier)),
            Set(staleStates.map { $0.0 }),
            "recovered rows must become runnable again; stale uploading/finalizing may not disappear"
        )
    }

    func testSQLiteQueueRejectsFutureSchemaWithoutDeletingRemoteCommitReceipt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let entry = UploadBackupSyncQueueEntry(
            source: source("committed"),
            revision: revision(10),
            originalFilename: "committed.heic",
            state: .uploading,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let reconciliation = UploadRemoteCommitReconciliation(
            source: entry.source,
            identity: UploadIdentity(
                correctedName: entry.originalFilename,
                nameHash: "name-hash",
                sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20),
                contentHash: "content-hash"
            ),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link")
        )
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            XCTAssertTrue(store.upsert(entry))
            XCTAssertTrue(
                store.markNeedsRemoteReconciliation(
                    source: entry.source,
                    revision: entry.revision,
                    reconciliation: reconciliation,
                    lastError: "manifest unavailable",
                    updatedAt: Date(timeIntervalSince1970: 11)
                ))
            store.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_sync_queue_info SET value=99 WHERE key='schema';", nil, nil, nil),
            SQLITE_OK)
        sqlite3_close(handle)

        XCTAssertNil(UploadBackupSyncQueueManifestStore(url: url))

        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT state, remote_commit_reconciliation FROM backup_sync_queue WHERE source_id='committed';",
                -1,
                &stmt,
                nil
            ), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "needsRemoteReconciliation")
        XCTAssertEqual(sqlite3_column_type(stmt, 1), SQLITE_BLOB)
        XCTAssertGreaterThan(sqlite3_column_bytes(stmt, 1), 0)
    }

    func testSQLiteQueueRejectsMarkerlessWrongShapeWithoutRepairingIt() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                handle,
                "CREATE TABLE backup_sync_queue(source_id TEXT); INSERT INTO backup_sync_queue VALUES('kept');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(handle)

        XCTAssertNil(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(sqliteCount(url: url, table: "backup_sync_queue"), 1)
        XCTAssertEqual(sqliteCount(url: url, table: "backup_sync_queue_info"), -1)
    }

    func testSQLiteQueueOpenFailureDoesNotReplaceDatabaseWithAnEmptyQueue() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let original = Data("not-a-sqlite-database".utf8)
        try original.write(to: url)

        XCTAssertNil(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
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

    /// `updateStates` writes every revision of the source or none: a missing row and a failed statement both leave the
    /// rows that came before them unchanged (#1004).
    func testUpdateStatesChangesEveryRevisionOrNone() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        let photo = source("decided")
        let rows = [revision(10), revision(20)].map {
            UploadBackupSyncQueueEntry(
                source: photo, revision: $0, originalFilename: "photo.heic", state: .failedPermanent,
                lastError: "parked", updatedAt: Date(timeIntervalSinceReferenceDate: 5))
        }
        for row in rows { XCTAssertTrue(store.upsert(row)) }
        let reopen = rows.map {
            UploadBackupSyncQueueManifestStore.StateUpdate(revision: $0.revision, state: .discovered, lastError: nil)
        }
        let later = Date(timeIntervalSinceReferenceDate: 50)
        let changes = RecordedQueueChanges()
        store.setChangeObserver { changes.append($0) }

        let missing = reopen + [.init(revision: revision(30), state: .discovered, lastError: nil)]
        XCTAssertFalse(
            store.updateStates(of: photo, missing, updatedAt: later), "a missing row refuses the whole write")
        for row in rows { XCTAssertEqual(try store.entry(for: photo, revision: row.revision), row) }
        XCTAssertTrue(store.isOperational(), "a missing row is no store failure")

        let fault = try SQLiteReadInterrupt(in: store, matching: "attempts=COALESCE(?, attempts)", occurrence: 2)
        XCTAssertFalse(store.updateStates(of: photo, reopen, updatedAt: later))
        fault.stop()
        XCTAssertTrue(fault.fired)
        let observer = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { observer.close() }
        for row in rows {
            XCTAssertEqual(try observer.entry(for: photo, revision: row.revision), row, "the first write rolled back")
        }
        XCTAssertEqual(changes.values, [], "a refused write reports no change")

        let healthy = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("healthy.sqlite")))
        defer { healthy.close() }
        for row in rows { XCTAssertTrue(healthy.upsert(row)) }
        let healthyChanges = RecordedQueueChanges()
        healthy.setChangeObserver { healthyChanges.append($0) }
        XCTAssertTrue(healthy.updateStates(of: photo, reopen, updatedAt: later))
        XCTAssertEqual(
            healthyChanges.values, [UploadBackupSyncQueueChange(sources: [photo])], "one change after the commit")
        for row in rows {
            let written = try XCTUnwrap(healthy.entry(for: photo, revision: row.revision))
            XCTAssertEqual(written.state, .discovered)
            XCTAssertNil(written.lastError)
            XCTAssertEqual(written.attempts, row.attempts)
        }
        XCTAssertTrue(healthy.updateStates(of: photo, [], updatedAt: later), "an empty write changes nothing")
    }

    /// A statement error that SQLite does not roll back by itself (RAISE(ABORT) keeps the transaction open) after
    /// two written revisions: the store itself must end the transaction, so no written revision survives (#1004).
    func testUpdateStatesRollsBackAnOpenTransactionAfterALaterStatementFails() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        let photo = source("aborted")
        let rows = [revision(10), revision(20), revision(30)].map {
            UploadBackupSyncQueueEntry(
                source: photo, revision: $0, originalFilename: "photo.heic", state: .failedPermanent,
                lastError: "parked", updatedAt: Date(timeIntervalSinceReferenceDate: 5))
        }
        for row in rows { XCTAssertTrue(store.upsert(row)) }
        let connection = try XCTUnwrap(
            Mirror(reflecting: store).children.first { $0.label == "connection" }?.value as? SQLiteStoreConnection)
        let trigger = """
            CREATE TEMP TRIGGER refuse_third BEFORE UPDATE ON main.backup_sync_queue
            WHEN OLD.revision_us = \(rows[2].revision.rawValue)
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """
        XCTAssertEqual(connection.withLock { sqlite3_exec(connection.database, trigger, nil, nil, nil) }, SQLITE_OK)
        defer {
            _ = connection.withLock {
                sqlite3_exec(connection.database, "DROP TRIGGER IF EXISTS temp.refuse_third;", nil, nil, nil)
            }
        }
        let reopen = rows.map {
            UploadBackupSyncQueueManifestStore.StateUpdate(revision: $0.revision, state: .discovered, lastError: nil)
        }

        XCTAssertFalse(store.updateStates(of: photo, reopen, updatedAt: Date(timeIntervalSinceReferenceDate: 50)))

        XCTAssertNotEqual(
            connection.withLock { sqlite3_get_autocommit(connection.database) }, 0,
            "the failed write must not leave its transaction open")
        for row in rows {
            XCTAssertEqual(
                try store.entry(for: photo, revision: row.revision), row,
                "the same connection must not see the earlier revisions of the failed write")
        }
    }

    func testQueueHealthProbeRecordsDeniedSelect() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        XCTAssertTrue(store.isOperational())
        try withDeniedSQLiteSelect(in: store) {
            XCTAssertFalse(store.isOperational(), "queue health probes SQLite")
        }
        XCTAssertFalse(store.isOperational(), "restoring SELECT cannot clear recorded failure")
    }

    func testFailedBackedUpRevisionReadLeavesQueueOperational() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        // Force prepare to fail on the live store, then restore the table before testing backup writes.
        XCTAssertEqual(
            sqlite3_exec(handle, "ALTER TABLE backup_sync_queue RENAME TO unavailable_queue;", nil, nil, nil),
            SQLITE_OK)
        XCTAssertTrue(store.backedUpRevisions(kind: .photoLibraryAsset).isEmpty)
        XCTAssertEqual(
            sqlite3_exec(handle, "ALTER TABLE unavailable_queue RENAME TO backup_sync_queue;", nil, nil, nil),
            SQLITE_OK)
        XCTAssertTrue(store.isOperational(), "cosmetic read failure must not set the sticky health latch")
        let entry = UploadBackupSyncQueueEntry(
            source: source("after-read-failure"), revision: revision(10), originalFilename: "photo.heic",
            updatedAt: Date())
        XCTAssertTrue(store.upsert(entry))
        XCTAssertEqual(try store.entry(for: entry.source, revision: entry.revision)?.state, entry.state)
        XCTAssertTrue(store.isOperational())
    }

    func testFailedBackedUpRevisionPrepareLeavesQueueOperational() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        // Force prepare to fail on the live store, then restore the table before testing backup writes.
        XCTAssertEqual(
            sqlite3_exec(handle, "ALTER TABLE backup_sync_queue RENAME TO unavailable_queue;", nil, nil, nil),
            SQLITE_OK)
        // Refresh this connection's schema before the cosmetic query prepares against the renamed table.
        XCTAssertEqual(store.catalogReplayState(), .notStarted)
        XCTAssertTrue(store.isOperational())
        XCTAssertTrue(store.backedUpRevisions(kind: .photoLibraryAsset).isEmpty)
        XCTAssertEqual(
            sqlite3_exec(handle, "ALTER TABLE unavailable_queue RENAME TO backup_sync_queue;", nil, nil, nil),
            SQLITE_OK)
        XCTAssertTrue(store.isOperational(), "cosmetic read failure must not set the sticky health latch")
        let entry = UploadBackupSyncQueueEntry(
            source: source("after-read-failure"), revision: revision(10), originalFilename: "photo.heic",
            updatedAt: Date())
        XCTAssertTrue(store.upsert(entry))
        XCTAssertEqual(try store.entry(for: entry.source, revision: entry.revision)?.state, entry.state)
        XCTAssertTrue(store.isOperational())
    }

    func testBackedUpRevisionReadIncludesOnlyQueuedSourcesOfTheRequestedKind() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        for id in ["queued-edit", "history-only", "uploading-edit", "folder-queued"] {
            XCTAssertTrue(
                store.upsert(
                    UploadBackupSyncQueueEntry(
                        source: source(id), revision: revision(1), originalFilename: "photo.heic",
                        state: .completed, updatedAt: Date())))
        }
        for (id, kind, state) in [
            ("queued-edit", UploadSourceIdentity.Kind.photoLibraryAsset, UploadBackupSyncQueueState.queuedForUpload),
            ("uploading-edit", .photoLibraryAsset, .uploading),
            ("folder-queued", .fileURL, .queuedForUpload),
        ] {
            XCTAssertTrue(
                store.upsert(
                    UploadBackupSyncQueueEntry(
                        source: UploadSourceIdentity(kind: kind, identifier: id), revision: revision(2),
                        originalFilename: "photo.heic", state: state, updatedAt: Date())))
        }
        XCTAssertEqual(store.backedUpRevisions(kind: .photoLibraryAsset), ["queued-edit": revision(1)])
    }

    func testQueueDecodeFailureStaysStickyAfterSuccessfulSQLAndRefusesDurability() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { store.close() }
        let original = UploadBackupSyncQueueEntry(
            source: source("kept"), revision: revision(10), originalFilename: "photo.heic",
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.upsert(original))
        XCTAssertTrue(store.synchronizeToDisk())
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_sync_queue SET remote_commit_reconciliation=X'7B';", nil, nil, nil),
            SQLITE_OK)

        XCTAssertThrowsError(
            try store.entry(for: original.source, revision: original.revision),
            "an undecodable receipt is unknown, not an absent row")
        XCTAssertFalse(store.isOperational())
        XCTAssertFalse(store.synchronizeToDisk())
        XCTAssertTrue(store.upsert(original), "later successful SQL keeps its existing result")
        XCTAssertEqual(try store.entry(for: original.source, revision: original.revision), original)
        XCTAssertFalse(store.isOperational(), "successful SQL cannot clear recorded failure")
        XCTAssertFalse(store.synchronizeToDisk())
        XCTAssertThrowsError(try store.entriesWithRemoteCommitReconciliation(limit: 10)) { error in
            XCTAssertEqual(error as? UploadRemoteCommitRecoveryError, .storeUnavailable)
        }
    }

    func testClosePreservesQueueRowsAndEmptyBatchSuccess() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let original = UploadBackupSyncQueueEntry(
            source: source("kept"), revision: revision(10), originalFilename: "photo.heic",
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.upsert(original))
        store.close()
        XCTAssertTrue(store.upsertBatch([]))
        XCTAssertTrue(store.insertMissingSources([]))
        XCTAssertFalse(store.isOperational())
        XCTAssertFalse(store.upsert(original))
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { reopened.close() }
        XCTAssertEqual(try reopened.entry(for: original.source, revision: original.revision), original)
    }

    func testClosedSQLiteQueueFailsClosedInsteadOfLookingEmpty() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertTrue(store.isOperational())
        store.close()

        XCTAssertFalse(store.isOperational())
        XCTAssertTrue(store.runnableEntries().isEmpty)
        XCTAssertFalse(store.isOperational(), "an empty read after a DB failure must not mean drained")
        XCTAssertFalse(
            store.upsert(
                UploadBackupSyncQueueEntry(
                    source: source("closed"),
                    revision: revision(10),
                    originalFilename: "closed.heic",
                    updatedAt: Date()
                )))
    }

    func testSyncEngineScansIntoSharedQueueWithSafeDecisions() async throws {
        let backupStore = MemoryBackupStore()
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let now = Date(timeIntervalSince1970: 123)
        let index = UploadBackupPreflightIndex(store: backupStore, now: { now })
        let known = candidate(id: "known", revision: 10)
        try await index.markBackedUp(known.snapshot)
        let unchangedEdit = candidate(id: "known", revision: 20, editRevision: .revision(revision(10)))
        let newAsset = candidate(id: "new", revision: 30)
        let unknownEdit = candidate(id: "known", revision: 40, editRevision: .revision(revision(35)))
        let engine = UploadBackupSyncEngine(preflight: index, queue: queue, now: { now })

        let result = try await engine.scan(StaticCatalog(items: [unchangedEdit, newAsset, unknownEdit]))

        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.alreadyBackedUp, 1)
        XCTAssertEqual(result.queuedForWork, 2)
        XCTAssertEqual(result.backendChecksRequired, 1)
        XCTAssertEqual(
            try queue.entry(for: unchangedEdit.snapshot.source, revision: unchangedEdit.snapshot.revision)?.state,
            .alreadyBackedUp)
        XCTAssertEqual(
            try queue.entry(for: newAsset.snapshot.source, revision: newAsset.snapshot.revision)?.state, .discovered)
        XCTAssertEqual(
            try queue.entry(for: unknownEdit.snapshot.source, revision: unknownEdit.snapshot.revision)?.state, .checking
        )
    }

    func testExactRemoteAssetProofSkipsBytesAndResourceMismatchFallsBack() async throws {
        let backupStore = MemoryBackupStore()
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent("remote-proof-queue.sqlite")
            ))
        let identity = UploadBackupExternalIdentity(
            identifier: "icloud-asset",
            modificationDate: Date(timeIntervalSinceReferenceDate: 50)
        )
        let proof = UploadRemoteAssetIndexRecord(
            externalIdentity: identity,
            resourceCount: 1,
            remoteLinkIDs: ["remote-link"],
            hashKeyEpoch: "epoch-1"
        )
        let resolver = RemoteProofResolver(proofs: [identity: proof])
        let index = UploadBackupPreflightIndex(store: backupStore)
        let engine = UploadBackupSyncEngine(
            preflight: index,
            queue: queue,
            remoteProofResolver: resolver
        )
        let exact = candidate(id: "exact", revision: 10, externalIdentity: identity)
        let mismatchedCompound = candidate(
            id: "compound",
            revision: 20,
            externalIdentity: identity,
            resourceCount: 2
        )

        let result = try await engine.enqueueBatch([exact, mismatchedCompound])

        XCTAssertEqual(result.alreadyBackedUp, 1)
        XCTAssertEqual(result.queuedForWork, 1)
        XCTAssertEqual(
            try queue.entry(for: exact.snapshot.source, revision: exact.snapshot.revision)?.state, .alreadyBackedUp)
        XCTAssertEqual(
            try queue.entry(for: mismatchedCompound.snapshot.source, revision: mismatchedCompound.snapshot.revision)?
                .state,
            .discovered
        )
        let persistedDecision = try await index.classify(exact.snapshot)
        XCTAssertEqual(persistedDecision, .alreadyBackedUp)
    }

    func testRemoteProofRetiresOlderFailuresAndPreservesPendingWork() async throws {
        try await assertSuccessfulRevisionCleanup(path: .remoteProof)
    }

    func testPreflightCompletionRetiresOlderFailuresAndPreservesPendingWork() async throws {
        try await assertSuccessfulRevisionCleanup(path: .preflight)
    }

    func testExplicitCompletionRetiresOlderFailuresAndPreservesPendingWork() async throws {
        try await assertSuccessfulRevisionCleanup(path: .completion)
    }

    private enum SuccessfulRevisionPath {
        case remoteProof, preflight, completion
    }

    private func assertSuccessfulRevisionCleanup(path: SuccessfulRevisionPath) async throws {
        let url = tempDir.appendingPathComponent("successful-revision.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let identity = UploadBackupExternalIdentity(identifier: "fixture-cloud-photo", revision: revision(100))
        let latest = candidate(id: "returned", revision: 100, externalIdentity: identity)
        func entry(_ seconds: TimeInterval, _ state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry {
            UploadBackupSyncQueueEntry(
                source: latest.snapshot.source, revision: revision(seconds), originalFilename: latest.originalFilename,
                state: state, updatedAt: Date(timeIntervalSince1970: 500))
        }
        var obsolete = [
            entry(1, .sourceMissing), entry(2, .failedPermanent), entry(3, .dismissedFailure),
            entry(4, .skippedRemoteDeletion),
        ]
        for (offset, state) in [UploadBackupSyncQueueState.discovered, .checking].enumerated() {
            var marker = entry(TimeInterval(5 + offset), state)
            marker.lastError = BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
            obsolete.append(marker)
        }
        var protected = [
            entry(10, .discovered), entry(11, .checking), entry(12, .hashing), entry(13, .duplicateChecking),
            entry(14, .queuedForUpload), entry(15, .uploading), entry(16, .finalizing), entry(17, .failed),
            entry(18, .blockedByDraft), entry(19, .paused), entry(20, .completed), entry(21, .alreadyBackedUp),
            entry(101, .failedPermanent),
        ]
        var otherPhoto = entry(22, .failedPermanent)
        otherPhoto.source = source("another-photo")
        protected.append(otherPhoto)
        var otherKind = entry(23, .failedPermanent)
        otherKind.source = .init(kind: .fileURL, identifier: latest.snapshot.source.identifier)
        protected.append(otherKind)
        var otherResource = entry(24, .failedPermanent)
        otherResource.source = source("returned", resource: .livePairedVideo)
        protected.append(otherResource)
        for (offset, state) in [UploadBackupSyncQueueState.needsRemoteReconciliation, .dismissedFailure].enumerated() {
            var committed = entry(TimeInterval(25 + offset), state)
            committed.remoteCommitReconciliation = UploadRemoteCommitReconciliation(
                source: committed.source,
                identity: UploadIdentity(
                    correctedName: committed.originalFilename, nameHash: "fixture-name",
                    sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                    contentHash: "fixture-content"),
                receipt: .init(remoteVolumeID: "fixture-volume", remoteLinkID: "fixture-link"))
            protected.append(committed)
        }
        XCTAssertTrue(queue.upsertBatch(obsolete + protected))
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        let proof = UploadRemoteAssetIndexRecord(
            externalIdentity: identity, resourceCount: 1, remoteLinkIDs: ["fixture-link"], hashKeyEpoch: "fixture-epoch"
        )
        let engine = UploadBackupSyncEngine(
            preflight: index, queue: queue,
            remoteProofResolver: path == .remoteProof ? RemoteProofResolver(proofs: [identity: proof]) : nil)
        switch path {
        case .preflight:
            try await index.markBackedUp(latest.snapshot)
            let result = try await engine.enqueue(latest)
            XCTAssertEqual(result.alreadyBackedUp, 1)
            XCTAssertEqual(result.queuedForWork, 0)
        case .remoteProof:
            let result = try await engine.enqueueBatch([latest])
            XCTAssertEqual(result.alreadyBackedUp, 1)
            XCTAssertEqual(result.queuedForWork, 0)
        case .completion:
            try await engine.markCompleted(latest)
        }
        let expectedState: UploadBackupSyncQueueState = path == .completion ? .completed : .alreadyBackedUp
        XCTAssertEqual(
            try queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision)?.state, expectedState)
        for old in obsolete {
            XCTAssertNil(
                try queue.entry(for: old.source, revision: old.revision), "obsolete \(old.state) must not count")
        }
        for kept in protected {
            XCTAssertEqual(try queue.entry(for: kept.source, revision: kept.revision), kept)
        }
        XCTAssertEqual(queue.count(), protected.count + 1)
        XCTAssertEqual(queue.missingSourceDiscardGeneration(), 0)
        queue.close()
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for old in obsolete {
            XCTAssertNil(try reopened.entry(for: old.source, revision: old.revision))
        }
        for kept in protected {
            XCTAssertEqual(try reopened.entry(for: kept.source, revision: kept.revision), kept)
        }
        XCTAssertEqual(reopened.count(), protected.count + 1)
        XCTAssertEqual(reopened.missingSourceDiscardGeneration(), 0)
    }

    func testMixedDiscoveryCleansOnlyTheBackedUpCandidates() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("mixed-cleanup.sqlite")))
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        let known = candidate(id: "locally-proven", revision: 10)
        let identity = UploadBackupExternalIdentity(identifier: "fixture-remote", revision: revision(200))
        let remote = candidate(id: "remotely-proven", revision: 200, externalIdentity: identity)
        let pending = candidate(id: "still-pending", revision: 50)
        var old: [UploadBackupSyncQueueEntry] = []
        for (latest, seconds) in [(known, 1.0), (remote, 100.0), (pending, 1.0)] {
            old.append(
                UploadBackupSyncQueueEntry(
                    source: latest.snapshot.source, revision: revision(seconds),
                    originalFilename: latest.originalFilename,
                    state: .failedPermanent, updatedAt: Date(timeIntervalSince1970: 500)))
        }
        XCTAssertTrue(queue.upsertBatch(old))
        try await index.markBackedUp(known.snapshot)
        try await index.markPending(pending.snapshot)
        let proof = UploadRemoteAssetIndexRecord(
            externalIdentity: identity, resourceCount: 1, remoteLinkIDs: ["fixture-link"], hashKeyEpoch: "fixture-epoch"
        )
        let engine = UploadBackupSyncEngine(
            preflight: index, queue: queue, remoteProofResolver: RemoteProofResolver(proofs: [identity: proof]))

        let result = try await engine.enqueueBatch([known, pending, remote])

        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.alreadyBackedUp, 2)
        XCTAssertEqual(result.queuedForWork, 1)
        for settled in [known, remote] {
            XCTAssertEqual(
                try queue.entry(for: settled.snapshot.source, revision: settled.snapshot.revision)?.state,
                .alreadyBackedUp)
        }
        XCTAssertEqual(
            try queue.entry(for: pending.snapshot.source, revision: pending.snapshot.revision)?.state, .queuedForUpload)
        XCTAssertNil(try queue.entry(for: old[0].source, revision: old[0].revision))
        XCTAssertNil(try queue.entry(for: old[1].source, revision: old[1].revision))
        XCTAssertEqual(try queue.entry(for: old[2].source, revision: old[2].revision), old[2])
    }

    func testDiscoveryReportsCleanupFailureAndKeepsTheFailureUntilRetry() async throws {
        try await assertCleanupFailureIsReported(path: .preflight)
    }

    func testExplicitCompletionReportsCleanupFailureAndKeepsTheFailureUntilRetry() async throws {
        try await assertCleanupFailureIsReported(path: .completion)
    }

    func testCleanupFailureUsesTheLocalStateMessageInEnglishAndGerman() async throws {
        let failuresBefore = PhotoDiagnostics.shared.counter("backup.queue.localStateUnavailable")
        try await assertCleanupFailureIsReported(path: .preflight, checkLocalizedMessage: true)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("backup.queue.localStateUnavailable"), failuresBefore + 1)
    }

    func testCompletionCleanupFailureUsesTheLocalStateMessageInEnglishAndGerman() async throws {
        try await assertCleanupFailureIsReported(path: .completion, checkLocalizedMessage: true)
    }

    func testQueueReadFailureUsesTheLocalStateMessageInEnglishAndGerman() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("read-failure.sqlite")))
        queue.close()
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStore()), queue: queue)
        do {
            _ = try await engine.enqueue(candidate(id: "unreadable", revision: 10))
            XCTFail("An unreadable queue must stop discovery")
        } catch {
            try assertLocalStateMessage(error)
        }
    }

    func testSourceRecheckWriteFailureUsesTheLocalStateMessageInEnglishAndGerman() async throws {
        let url = tempDir.appendingPathComponent("source-check-failure.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let item = candidate(id: "source-check", revision: 10)
        let dismissed = UploadBackupSyncQueueEntry(
            source: item.snapshot.source, revision: item.snapshot.revision, originalFilename: item.originalFilename,
            state: .dismissedFailure,
            lastError: BackupIssueRecord(kind: .sourceMissing, detail: "source unavailable").persistedValue,
            updatedAt: Date(timeIntervalSince1970: 500))
        XCTAssertTrue(queue.upsert(dismissed))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TRIGGER fixture_source_check_failure BEFORE UPDATE ON backup_sync_queue BEGIN SELECT RAISE(ABORT, 'fixture source check failure'); END;",
                nil, nil, nil), SQLITE_OK)
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStore()), queue: queue)
        do {
            _ = try await engine.enqueue(item)
            XCTFail("An unsuccessful recheck write must stop discovery")
        } catch {
            try assertLocalStateMessage(error)
        }
        XCTAssertEqual(try queue.entry(for: dismissed.source, revision: dismissed.revision), dismissed)
    }

    func testBatchedCleanupMatchesSingleCleanupAndPreservesEveryProtectedRow() throws {
        let singleURL = tempDir.appendingPathComponent("single-cleanup.sqlite")
        let batchURL = tempDir.appendingPathComponent("batch-cleanup.sqlite")
        let single = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: singleURL))
        let batch = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: batchURL))
        let items = [candidate(id: "first", revision: 100), candidate(id: "second", revision: 100)]
        var obsolete: [UploadBackupSyncQueueEntry] = []
        var protected: [UploadBackupSyncQueueEntry] = []
        for item in items {
            func row(_ seconds: TimeInterval, _ state: UploadBackupSyncQueueState) -> UploadBackupSyncQueueEntry {
                .init(
                    source: item.snapshot.source, revision: revision(seconds), originalFilename: item.originalFilename,
                    state: state, updatedAt: Date(timeIntervalSince1970: 500))
            }
            obsolete += [
                row(1, .sourceMissing), row(2, .failedPermanent), row(3, .dismissedFailure),
                row(4, .skippedRemoteDeletion),
            ]
            for (offset, state) in [UploadBackupSyncQueueState.discovered, .checking].enumerated() {
                var marker = row(TimeInterval(5 + offset), state)
                marker.lastError =
                    BackupIssueRecord(kind: .sourceMissing, detail: "acknowledged missing").persistedValue
                obsolete.append(marker)
            }
            protected += [
                row(7, .discovered), row(8, .queuedForUpload), row(9, .failed), row(10, .hashing),
                row(11, .completed), row(12, .alreadyBackedUp), row(100, .failedPermanent), row(101, .sourceMissing),
            ]
            var otherReason = row(13, .checking)
            otherReason.lastError = BackupIssueRecord(kind: .unknown, detail: "source unavailable").persistedValue
            protected.append(otherReason)
            for (offset, state) in [UploadBackupSyncQueueState.failedPermanent, .discovered].enumerated() {
                var committed = row(TimeInterval(14 + offset), state)
                committed.lastError =
                    BackupIssueRecord(kind: .sourceMissing, detail: "receipt must survive").persistedValue
                committed.remoteCommitReconciliation = UploadRemoteCommitReconciliation(
                    source: committed.source,
                    identity: UploadIdentity(
                        correctedName: committed.originalFilename, nameHash: "fixture-name",
                        sha1Hex: String(repeating: "ab", count: 20), sha1Digest: Data(repeating: 0xAB, count: 20),
                        contentHash: "fixture-content"),
                    receipt: .init(remoteVolumeID: "fixture-volume", remoteLinkID: "fixture-link"))
                protected.append(committed)
            }
            protected.append(
                .init(
                    source: .init(kind: .fileURL, identifier: item.snapshot.source.identifier),
                    revision: revision(1), originalFilename: "other-kind.heic", state: .sourceMissing,
                    updatedAt: Date(timeIntervalSince1970: 500)))
            protected.append(
                .init(
                    source: source(item.snapshot.source.identifier, resource: .livePairedVideo),
                    revision: revision(1), originalFilename: "other-resource.mov", state: .failedPermanent,
                    updatedAt: Date(timeIntervalSince1970: 500)))
        }
        protected.append(
            .init(
                source: source("other-photo"), revision: revision(1), originalFilename: "other.heic",
                state: .sourceMissing, updatedAt: Date(timeIntervalSince1970: 500)))
        let fixture = obsolete + protected
        XCTAssertTrue(single.upsertBatch(fixture))
        XCTAssertTrue(batch.upsertBatch(fixture))
        let successes = items.map {
            UploadBackupSyncQueueEntry(
                source: $0.snapshot.source, revision: $0.snapshot.revision,
                originalFilename: $0.originalFilename, state: .alreadyBackedUp,
                updatedAt: Date(timeIntervalSince1970: 500))
        }
        for entry in successes {
            XCTAssertTrue(
                single.removeUnsavedEarlierRevisions(of: entry.source, through: entry.revision, except: entry.revision))
        }
        XCTAssertTrue(batch.removeUnsavedEarlierRevisions(of: successes))
        single.close()
        batch.close()
        let reopenedSingle = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: singleURL))
        let reopenedBatch = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: batchURL))
        for row in fixture {
            let expected = protected.contains(row) ? row : nil
            XCTAssertEqual(try reopenedSingle.entry(for: row.source, revision: row.revision), expected)
            XCTAssertEqual(try reopenedBatch.entry(for: row.source, revision: row.revision), expected)
            XCTAssertEqual(
                try reopenedBatch.entry(for: row.source, revision: row.revision),
                try reopenedSingle.entry(for: row.source, revision: row.revision))
        }
        XCTAssertEqual(reopenedSingle.count(), protected.count)
        XCTAssertEqual(reopenedBatch.count(), protected.count)
    }

    func testBatchedCleanupRollsBackEarlierDeletesAndReportsTheLocalizedMessage() async throws {
        try await assertScanCleanupFailure(itemCount: 2, failingIndex: 1, committedCount: 0)
    }

    func testCleanupKeepsItsTransactionInsideTheExistingScanBatch() async throws {
        try await assertScanCleanupFailure(itemCount: 129, failingIndex: 128, committedCount: 128)
    }

    private func assertScanCleanupFailure(itemCount: Int, failingIndex: Int, committedCount: Int) async throws {
        let url = tempDir.appendingPathComponent("atomic-cleanup.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let items = (0..<itemCount).map { candidate(id: "batch-\($0)", revision: 100) }
        let old = items.map {
            UploadBackupSyncQueueEntry(
                source: $0.snapshot.source, revision: revision(1),
                originalFilename: $0.originalFilename, state: .failedPermanent,
                updatedAt: Date(timeIntervalSince1970: 500))
        }
        XCTAssertTrue(queue.upsertBatch(old))
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        try await index.markBackedUpBatch(items.map(\.snapshot))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TRIGGER fixture_batch_cleanup_failure BEFORE DELETE ON backup_sync_queue WHEN OLD.source_id='batch-\(failingIndex)' BEGIN SELECT RAISE(ABORT, 'fixture batch cleanup failure'); END;",
                nil, nil, nil), SQLITE_OK)
        let engine = UploadBackupSyncEngine(preflight: index, queue: queue)
        do {
            _ = try await engine.enqueueBatch(items)
            XCTFail("A failed batch cleanup must stop the scan")
        } catch {
            try assertLocalStateMessage(error)
        }
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fixture_batch_cleanup_failure;", nil, nil, nil), SQLITE_OK)
        queue.close()
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for (index, row) in old.enumerated() {
            XCTAssertEqual(
                try reopened.entry(for: row.source, revision: row.revision), index < committedCount ? nil : row)
        }
        for item in items {
            XCTAssertEqual(
                try reopened.entry(for: item.snapshot.source, revision: item.snapshot.revision)?.state, .alreadyBackedUp
            )
        }
        XCTAssertEqual(reopened.count(), itemCount * 2 - committedCount)
    }

    func testMeasureCleanupOfFiftyThousandBackedUpItems() async throws {
        guard ProcessInfo.processInfo.environment["BACKUP_CLEANUP_MEASURE"] == "1" else {
            throw XCTSkip("Set BACKUP_CLEANUP_MEASURE=1 for the 50,000-item cleanup measurement")
        }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("cleanup-measure.sqlite")))
        let items = (0..<50_000).map { candidate(id: "fixture-\($0)", revision: 10) }
        let old = items.map { item in
            UploadBackupSyncQueueEntry(
                source: item.snapshot.source, revision: revision(1), originalFilename: item.originalFilename,
                state: .failedPermanent, updatedAt: Date(timeIntervalSince1970: 500))
        }
        XCTAssertTrue(queue.upsertBatch(old))
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        try await index.markBackedUpBatch(items.map(\.snapshot))
        let engine = UploadBackupSyncEngine(preflight: index, queue: queue)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await engine.scan(StaticCatalog(items: items))
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        print("CLEANUP_MEASUREMENT items=50000 oldFailures=50000 scanBatch=128 seconds=\(seconds)")
        XCTAssertEqual(result.scanned, 50_000)
        XCTAssertEqual(result.alreadyBackedUp, 50_000)
        XCTAssertEqual(queue.count(), 50_000)
        XCTAssertEqual(queue.summary()!.failed, 0)
        XCTAssertTrue(queue.isOperational())
        XCTAssertTrue(queue.upsertBatch(old))
        XCTAssertEqual(queue.count(), 100_000)
        let cleanupStart = DispatchTime.now().uptimeNanoseconds
        let successes = items.map {
            UploadBackupSyncQueueEntry(
                source: $0.snapshot.source, revision: $0.snapshot.revision,
                originalFilename: $0.originalFilename, state: .alreadyBackedUp,
                updatedAt: Date(timeIntervalSince1970: 500))
        }
        for start in stride(from: 0, to: successes.count, by: 128) {
            XCTAssertTrue(
                queue.removeUnsavedEarlierRevisions(of: Array(successes[start..<min(start + 128, successes.count)])))
        }
        let cleanupSeconds = Double(DispatchTime.now().uptimeNanoseconds - cleanupStart) / 1_000_000_000
        print("CLEANUP_ONLY_MEASUREMENT items=50000 oldFailures=50000 seconds=\(cleanupSeconds)")
        XCTAssertEqual(queue.count(), 50_000)
        XCTAssertEqual(queue.summary()!.failed, 0)
    }

    private func assertLocalStateMessage(_ error: Error, file: StaticString = #filePath, line: UInt = #line) throws {
        let key = "backup.error_local_state_unavailable"
        XCTAssertEqual(
            error.localizedDescription, L10n.string("backup.error_local_state_unavailable"), file: file, line: line)
        for (language, expected) in [
            ("en", "Backup cannot continue; restart the app."),
            ("de", "Das Backup kann nicht fortgesetzt werden; starte die App neu."),
        ] {
            let translated = try catalogTranslation(of: key, language: language)
            XCTAssertEqual(translated, expected, language, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("Backup queue"), language, file: file, line: line)
        }
    }

    private func assertCleanupFailureIsReported(
        path: SuccessfulRevisionPath, checkLocalizedMessage: Bool = false
    ) async throws {
        let url = tempDir.appendingPathComponent("failed-cleanup.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let latest = candidate(id: "cleanup-failure", revision: 10)
        let old = UploadBackupSyncQueueEntry(
            source: latest.snapshot.source, revision: revision(1), originalFilename: latest.originalFilename,
            state: .failedPermanent, updatedAt: Date(timeIntervalSince1970: 500))
        XCTAssertTrue(queue.upsert(old))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TRIGGER fixture_cleanup_failure BEFORE DELETE ON backup_sync_queue BEGIN SELECT RAISE(ABORT, 'fixture cleanup failure'); END;",
                nil, nil, nil),
            SQLITE_OK)
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        if path == .preflight { try await index.markBackedUp(latest.snapshot) }
        let engine = UploadBackupSyncEngine(preflight: index, queue: queue)

        do {
            if path == .completion {
                try await engine.markCompleted(latest)
            } else {
                _ = try await engine.enqueue(latest)
            }
            XCTFail("A failed cleanup must stop the caller")
        } catch UploadError.backend(let message) {
            XCTAssertFalse(queue.isOperational())
            if checkLocalizedMessage { try assertLocalStateMessage(UploadError.backend(message)) }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try queue.entry(for: old.source, revision: old.revision), old)
        XCTAssertEqual(
            try queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision)?.state,
            path == .completion ? .completed : .alreadyBackedUp)
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER fixture_cleanup_failure;", nil, nil, nil), SQLITE_OK)
        queue.close()
        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(try reopened.entry(for: old.source, revision: old.revision), old)
        let retry = UploadBackupSyncEngine(preflight: index, queue: reopened)
        let result = try await retry.enqueue(latest)
        XCTAssertEqual(result.alreadyBackedUp, 1)
        XCTAssertNil(try reopened.entry(for: old.source, revision: old.revision))
        XCTAssertEqual(reopened.count(), 1)
    }

    func testIncompleteRemoteProofDoesNotRetireOlderFailures() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("incomplete-proof.sqlite")))
        let identity = UploadBackupExternalIdentity(identifier: "fixture-compound", revision: revision(100))
        let latest = candidate(id: "unproven", revision: 100, externalIdentity: identity, resourceCount: 2)
        let old = UploadBackupSyncQueueEntry(
            source: latest.snapshot.source, revision: revision(1), originalFilename: latest.originalFilename,
            state: .failedPermanent, updatedAt: Date(timeIntervalSince1970: 500))
        XCTAssertTrue(queue.upsert(old))
        let proof = UploadRemoteAssetIndexRecord(
            externalIdentity: identity, resourceCount: 1, remoteLinkIDs: ["fixture-link"], hashKeyEpoch: "fixture-epoch"
        )
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStore()), queue: queue,
            remoteProofResolver: RemoteProofResolver(proofs: [identity: proof]))

        let result = try await engine.enqueue(latest)

        XCTAssertEqual(result.alreadyBackedUp, 0)
        XCTAssertEqual(result.queuedForWork, 1)
        XCTAssertEqual(
            try queue.entry(for: latest.snapshot.source, revision: latest.snapshot.revision)?.state, .discovered)
        XCTAssertEqual(try queue.entry(for: old.source, revision: old.revision), old)
    }

    func testTransportProofCancellationCannotCreateOrReopenQueueWork() async throws {
        let errors: [any Error] = [
            URLError(.cancelled), UploadError.cancelled,
            UploadError.transport(code: -999, message: "cancelled"),
        ]
        for route in ["discovery", "reopen", "defer"] {
            for failure in errors {
                let queue = try XCTUnwrap(
                    UploadBackupSyncQueueManifestStore(
                        url: tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")))
                defer { queue.close() }
                let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
                let asset = candidate(
                    id: "cancel", revision: 10,
                    externalIdentity: .init(identifier: "cloud-cancel", revision: revision(10)))
                if route != "discovery" {
                    try await index.markBackedUp(asset.snapshot)
                    XCTAssertTrue(
                        queue.upsert(
                            .init(
                                source: asset.snapshot.source, revision: asset.snapshot.revision,
                                originalFilename: asset.originalFilename, state: .alreadyBackedUp, updatedAt: Date())))
                }
                let engine = UploadBackupSyncEngine(
                    preflight: index, queue: queue,
                    remoteProofResolver: CancellingProofResolver(failure: failure))
                do {
                    if route == "discovery" {
                        _ = try await engine.enqueue(asset)
                    } else {
                        _ = try await engine.reopenBackedUpRevisions(
                            [.init(candidate: asset, formerMain: nil)], deferringWithoutRemoteProof: route == "defer")
                    }
                    XCTFail("\(route) must propagate transport cancellation")
                } catch {
                    XCTAssertTrue(
                        UploadError.isCancellation(error), "\(route) cannot replace cancellation with proof absence")
                    XCTAssertFalse(Task.isCancelled)
                }
                if route == "discovery" {
                    XCTAssertEqual(queue.count(), 0)
                } else {
                    let complete = try await index.completeStates([asset.snapshot])
                    XCTAssertEqual(complete, [true], "cancelled proof must not reopen the preflight record")
                    XCTAssertEqual(
                        try queue.entry(for: asset.snapshot.source, revision: asset.snapshot.revision)?.state,
                        .alreadyBackedUp)
                }
            }
        }
    }

    func testRemoteProofCancellationDoesNotPersistQueueRows() async throws {
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: tempDir.appendingPathComponent("cancelled-proof-queue.sqlite")
            ))
        let index = UploadBackupPreflightIndex(store: MemoryBackupStore())
        let engine = UploadBackupSyncEngine(
            preflight: index,
            queue: queue,
            remoteProofResolver: CancellingProofResolver()
        )
        let identity = UploadBackupExternalIdentity(
            identifier: "icloud-cancel",
            modificationDate: Date()
        )

        do {
            _ = try await engine.enqueue(
                candidate(
                    id: "cancel",
                    revision: 10,
                    externalIdentity: identity
                ))
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(queue.count(), 0)
        }
    }
}

extension UploadBackupSyncQueueTests {
    func testUnsupportedRestoreCASRefusesBeforeAnyPreflightOrQueueWrite() async throws {
        let inner = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("unsupported-restore.sqlite")))
        defer { inner.close() }
        let photo = candidate(id: "restored", revision: 42)
        let row = UploadBackupSyncQueueEntry(
            source: photo.snapshot.source, revision: photo.snapshot.revision,
            originalFilename: photo.originalFilename, state: .completed, attempts: 3,
            lastError: "kept", updatedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(inner.upsert(row))
        let log = BackupEventLog()
        let queue: any UploadBackupSyncQueueStore = SpyQueueStore(inner: inner, log: log)
        let state = MemoryBackupStore()
        let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)

        XCTAssertNil(queue.restoredCompoundReopener, "A store must explicitly supply the atomic capability")
        do {
            _ = try await engine.reopenRestoredCompound(photo, isCurrent: { true })
            XCTFail("An unsupported terminal recheck must fail, rather than return a temporary wait")
        } catch let error as UploadError {
            guard case .backend(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(message, L10n.string("backup.error_local_state_unavailable"))
        }
        XCTAssertEqual(state.upsertCount, 0, "Refusal must precede markPending")
        XCTAssertEqual(state.count(), 0)
        XCTAssertEqual(try inner.entry(for: row.source, revision: row.revision), row)
        XCTAssertTrue(log.events.isEmpty, "Refusal must not call any queue writer")
        XCTAssertTrue(inner.isOperational(), "Unsupported is not a SQLite failure")
    }

    func testDefaultRestoreCapabilityKeepsMissingAndNonterminalAdmission() async throws {
        let existingStates: [UploadBackupSyncQueueState?] = [nil, .discovered]
        for existingState in existingStates {
            let inner = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")))
            defer { inner.close() }
            let photo = candidate(id: "restored", revision: 42)
            let row = existingState.map {
                UploadBackupSyncQueueEntry(
                    source: photo.snapshot.source, revision: photo.snapshot.revision,
                    originalFilename: photo.originalFilename, state: $0, updatedAt: Date(timeIntervalSince1970: 1_000))
            }
            if let row { XCTAssertTrue(inner.upsert(row)) }
            let log = BackupEventLog()
            let queue: any UploadBackupSyncQueueStore = SpyQueueStore(inner: inner, log: log)
            let state = MemoryBackupStore()
            let engine = UploadBackupSyncEngine(preflight: UploadBackupPreflightIndex(store: state), queue: queue)

            let admitted = try await engine.reopenRestoredCompound(photo, isCurrent: { true })

            XCTAssertTrue(admitted, "Only the terminal branch needs the atomic capability")
            XCTAssertEqual(state.upsertCount, 1)
            XCTAssertEqual(
                state.record(for: photo.snapshot.source, revision: photo.snapshot.revision)?.pendingResourceCount, 1)
            XCTAssertEqual(try inner.entry(for: photo.snapshot.source, revision: photo.snapshot.revision), row)
            XCTAssertTrue(log.events.isEmpty)
        }
    }

    func testManifestRestoreCapabilityDispatchesThroughTheQueueContract() async throws {
        let inner = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("supported-restore.sqlite")))
        defer { inner.close() }
        let photo = candidate(id: "restored", revision: 42)
        let row = UploadBackupSyncQueueEntry(
            source: photo.snapshot.source, revision: photo.snapshot.revision,
            originalFilename: photo.originalFilename, state: .completed, attempts: 3,
            lastError: "kept", updatedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(inner.upsert(row))
        let queue: any UploadBackupSyncQueueStore = inner
        let state = MemoryBackupStore()
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: state), queue: queue,
            now: { Date(timeIntervalSince1970: 2_000) })

        XCTAssertNotNil(queue.restoredCompoundReopener)
        let admitted = try await engine.reopenRestoredCompound(photo, isCurrent: { true })

        XCTAssertTrue(admitted)
        XCTAssertEqual(state.upsertCount, 1)
        let reopened = try XCTUnwrap(inner.entry(for: row.source, revision: row.revision))
        XCTAssertEqual(reopened.state, .discovered)
        XCTAssertEqual(reopened.attempts, 0)
        XCTAssertNil(reopened.lastError)
        XCTAssertNil(reopened.remoteCommitReconciliation)
        XCTAssertEqual(reopened.updatedAt, Date(timeIntervalSince1970: 2_000))
    }
}

extension UploadBackupSyncQueueTests {
    func testRestoredCompoundCASRefusesEveryChangedObservedField() throws {
        for mutation in ["state='uploading'", "updated_at=1001", "last_error='changed'"] {
            let url = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")
            let q = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            defer { q.close() }
            let observed = UploadBackupSyncQueueEntry(
                source: source("restore-CAS"), revision: revision(42),
                originalFilename: "photo.heic", state: .completed, attempts: 3, lastError: "kept",
                updatedAt: Date(timeIntervalSince1970: 1000))
            XCTAssertTrue(q.upsert(observed))
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            let handle = try XCTUnwrap(db)
            defer { sqlite3_close(handle) }
            XCTAssertEqual(sqlite3_exec(handle, "UPDATE backup_sync_queue SET \(mutation);", nil, nil, nil), SQLITE_OK)
            let before = try XCTUnwrap(q.entry(for: observed.source, revision: observed.revision))
            XCTAssertEqual(q.reopenRestoredCompound(observed, at: Date(timeIntervalSince1970: 2000)), false, mutation)
            XCTAssertEqual(try q.entry(for: observed.source, revision: observed.revision), before)
            XCTAssertTrue(q.isOperational())
        }
    }

    func testRestoredCompoundCASPreservesAReceiptAddedAfterObservation() throws {
        let q = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("receipt-CAS.sqlite")))
        defer { q.close() }
        let observed = UploadBackupSyncQueueEntry(
            source: source("restore-CAS"), revision: revision(42),
            originalFilename: "photo.heic", state: .completed, updatedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(q.upsert(observed))
        let evidence = UploadRemoteCommitReconciliation(
            source: observed.source,
            identity: UploadIdentity(
                correctedName: "photo.heic", nameHash: "nh", sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20), contentHash: "ch"),
            receipt: .init(remoteVolumeID: "vol", remoteLinkID: "committed"))
        XCTAssertTrue(
            q.markNeedsRemoteReconciliation(
                source: observed.source, revision: observed.revision,
                reconciliation: evidence, lastError: nil, updatedAt: observed.updatedAt))
        // Match the observed state/date/reason again, so the receipt fence alone distinguishes this row.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempDir.appendingPathComponent("receipt-CAS.sqlite").path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_sync_queue SET state='completed', last_error=NULL;", nil, nil, nil),
            SQLITE_OK)
        let before = try XCTUnwrap(q.entry(for: observed.source, revision: observed.revision))
        XCTAssertEqual(before.remoteCommitReconciliation, evidence, "The setup must retain the committed receipt")
        XCTAssertEqual(q.reopenRestoredCompound(observed, at: Date(timeIntervalSince1970: 2000)), false)
        XCTAssertEqual(try q.entry(for: observed.source, revision: observed.revision), before)
    }

    func testRestoredCompoundCASPreservesANewerRevision() throws {
        let q = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("revision-CAS.sqlite")))
        defer { q.close() }
        let old = UploadBackupSyncQueueEntry(
            source: source("restore-CAS"), revision: revision(42),
            originalFilename: "photo.heic", state: .completed, updatedAt: Date(timeIntervalSince1970: 1000))
        var newer = old
        newer.revision = revision(43)
        newer.state = .discovered
        XCTAssertTrue(q.upsert(old))
        XCTAssertTrue(q.upsert(newer))
        XCTAssertEqual(q.reopenRestoredCompound(old, at: Date(timeIntervalSince1970: 2000)), false)
        XCTAssertEqual(try q.entry(for: old.source, revision: old.revision), old)
        XCTAssertEqual(try q.entry(for: newer.source, revision: newer.revision), newer)
    }
}

extension UploadBackupSyncQueueTests {
    func testRestoredCompoundCASChangesOnlyItsExactSourceKindIdentifierAndResource() throws {
        let q = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("neighbors-CAS.sqlite")))
        defer { q.close() }
        let observed = UploadBackupSyncQueueEntry(
            source: source("restore-CAS"), revision: revision(42),
            originalFilename: "photo.heic", state: .completed, updatedAt: Date(timeIntervalSince1970: 1000))
        var otherKind = observed
        otherKind.source = .init(kind: .fileURL, identifier: observed.source.identifier)
        var otherID = observed
        otherID.source = source("other")
        var otherResource = observed
        otherResource.source = source("restore-CAS", resource: .livePairedVideo)
        for row in [observed, otherKind, otherID, otherResource] { XCTAssertTrue(q.upsert(row)) }
        XCTAssertEqual(q.reopenRestoredCompound(observed, at: Date(timeIntervalSince1970: 2000)), true)
        for row in [otherKind, otherID, otherResource] {
            XCTAssertEqual(
                try q.entry(for: row.source, revision: row.revision), row,
                "The CAS cannot reopen another kind, identifier or resource")
        }
    }
}

extension UploadBackupSyncQueueTests {
    func testRestoredCompoundCASRejectsObservedActiveStateAndAnEarlierOwnedReceipt() throws {
        for receiptCase in [false, true] {
            let url = tempDir.appendingPathComponent(UUID().uuidString + ".sqlite")
            let q = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            defer { q.close() }
            var observed = UploadBackupSyncQueueEntry(
                source: source("restore-observed"), revision: revision(42),
                originalFilename: "photo.heic", state: receiptCase ? .completed : .uploading,
                updatedAt: Date(timeIntervalSince1970: 1000))
            if receiptCase {
                observed.remoteCommitReconciliation = .init(
                    source: observed.source,
                    identity: .init(
                        correctedName: "photo.heic", nameHash: "nh", sha1Hex: String(repeating: "ab", count: 20),
                        sha1Digest: Data(repeating: 0xAB, count: 20), contentHash: "ch"),
                    receipt: .init(remoteVolumeID: "vol", remoteLinkID: "committed"))
            }
            XCTAssertTrue(q.upsert(observed))
            if receiptCase {
                var db: OpaquePointer?
                XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
                let handle = try XCTUnwrap(db)
                defer { sqlite3_close(handle) }
                XCTAssertEqual(
                    sqlite3_exec(
                        handle, "UPDATE backup_sync_queue SET remote_commit_reconciliation=NULL;", nil, nil, nil),
                    SQLITE_OK)
            }
            let current = try XCTUnwrap(q.entry(for: observed.source, revision: observed.revision))
            XCTAssertEqual(
                q.reopenRestoredCompound(observed, at: Date(timeIntervalSince1970: 2000)), false,
                "Only the exact receipt-free terminal observation grants this CAS")
            XCTAssertEqual(try q.entry(for: current.source, revision: current.revision), current)
        }
    }
}

extension UploadBackupSyncQueueTests {
    func testRestoredCompoundCASCannotBorrowANewerReplacementWhenTheObservedRowDisappeared() throws {
        let q = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent("replacement-CAS.sqlite")))
        defer { q.close() }
        let observed = UploadBackupSyncQueueEntry(
            source: source("restore-replaced"), revision: revision(42),
            originalFilename: "photo.heic", state: .completed, updatedAt: Date(timeIntervalSince1970: 1000))
        var newer = observed
        newer.revision = revision(43)
        XCTAssertTrue(q.upsert(observed))
        XCTAssertTrue(q.remove(source: observed.source, revision: observed.revision))
        XCTAssertTrue(q.upsert(newer))
        XCTAssertEqual(q.reopenRestoredCompound(observed, at: Date(timeIntervalSince1970: 2000)), false)
        XCTAssertEqual(
            try q.entry(for: newer.source, revision: newer.revision), newer,
            "The latest terminal row cannot lend its identity to an older observation")
    }
}

private final class RecordedQueueChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [UploadBackupSyncQueueChange] = []
    var values: [UploadBackupSyncQueueChange] { lock.withLock { changes } }
    func append(_ change: UploadBackupSyncQueueChange) { lock.withLock { changes.append(change) } }
}
