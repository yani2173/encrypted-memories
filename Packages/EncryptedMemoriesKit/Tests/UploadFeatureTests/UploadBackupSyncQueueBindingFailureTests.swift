import SQLite3
import XCTest

@testable import PhotosCore
@testable import UploadCore

/// Every bind of the backup queue checks its result (#1194). A failed bind leaves its parameter NULL: an unchecked
/// bind made a read answer "no row", made a write change nothing and report success, or stored NULL in place of the
/// value. Each test lowers SQLITE_LIMIT_LENGTH on the store's own connection and reads the limit back, so a value
/// longer than the limit fails its bind with SQLITE_TOOBIG. The operation must fail closed: the failure is recorded on
/// the connection, and the stored rows stay exactly as they were.
///
/// SQLite raises a lower limit to 30 bytes. Values that are always shorter (source kinds, states, the runtime issue
/// key, the catalog replay key) cannot fail this way; their binds use the same shared helper.
final class UploadBackupSyncQueueBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 32
    private let long = String(repeating: "x", count: 128)

    private var tempDir: URL!
    private var store: UploadBackupSyncQueueManifestStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: databaseURL))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var databaseURL: URL { tempDir.appendingPathComponent("queue.sqlite") }

    private func connection() throws -> SQLiteStoreConnection { try storeConnection(store!) }

    private func lowerLengthLimit() throws { lowerSQLiteLengthLimit(on: try connection(), to: Self.limit) }

    private func assertBindFailureRecorded(file: StaticString = #filePath, line: UInt = #line) throws {
        assertRecordedBindFailure(on: try connection(), file: file, line: line)
    }

    /// Every stored row, read through a separate connection, so the comparison never depends on the store's own
    /// failure state.
    private func storedRows() throws -> [[String]] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                """
                SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count, state, attempts,
                       last_error, updated_at, hex(remote_commit_reconciliation)
                FROM backup_sync_queue ORDER BY source_kind, source_id, resource, revision_us;
                """, -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                (0..<11).map { column in
                    sqlite3_column_type(statement, column) == SQLITE_NULL
                        ? "NULL" : String(cString: sqlite3_column_text(statement, column))
                })
        }
        return rows
    }

    private func entry(
        _ identifier: String = "a",
        kind: UploadSourceIdentity.Kind = .photoLibraryAsset,
        state: UploadBackupSyncQueueState = .discovered,
        revision: TimeInterval = 10,
        lastError: String? = nil,
        receipt: Bool = false
    ) -> UploadBackupSyncQueueEntry {
        let source = UploadSourceIdentity(kind: kind, identifier: identifier)
        return UploadBackupSyncQueueEntry(
            source: source,
            revision: UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: revision)),
            originalFilename: "a.heic",
            state: state,
            lastError: lastError,
            remoteCommitReconciliation: receipt ? reconciliation(for: source) : nil,
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    /// A receipt whose stored form is far longer than the lowered limit, for a source whose own values are short.
    private func reconciliation(for source: UploadSourceIdentity) -> UploadRemoteCommitReconciliation {
        UploadRemoteCommitReconciliation(
            source: source,
            identity: UploadIdentity(
                correctedName: "a.heic", nameHash: "name-hash", sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20), contentHash: "content-hash"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "volume", remoteLinkID: "link"))
    }

    /// Fails the binds of the next statement that contains `statement`; see `BindFailureUntilStep`.
    private func failBinds(untilStepOf statement: String, after earlier: String? = nil) throws -> BindFailureUntilStep {
        let fault = BindFailureUntilStep(on: try connection(), statement: statement, after: earlier, limit: Self.limit)
        if earlier == nil { XCTAssertEqual(fault.effectiveLimit, Self.limit, "The lowered length limit must apply") }
        return fault
    }

    private func issue(_ kind: BackupIssueKind = .network) -> String {
        BackupIssueRecord(kind: kind, detail: "detail").persistedValue
    }

    // MARK: Receipt binds (an unchecked failure loses the upload receipt)

    func testUpsertWithAReceiptLongerThanTheLimitFailsAndStoresNoRowWithoutItsReceipt() throws {
        // The upsert first reads the prior row; that read must run without the limit.
        let fault = try failBinds(untilStepOf: "INSERT INTO backup_sync_queue(", after: "SELECT state IN (")
        defer { fault.remove() }
        XCTAssertFalse(store.upsert(entry(receipt: true)), "A receipt that does not bind must fail the write")
        XCTAssertTrue(fault.lowered, "The lowered length limit must apply to the write's binds")
        XCTAssertEqual(try storedRows(), [], "No row may be stored without its receipt")
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testInsertMissingSourcesWithAReceiptLongerThanTheLimitFailsAndStoresNoRowWithoutItsReceipt() throws {
        let fault = try failBinds(untilStepOf: "INSERT INTO backup_sync_queue(")
        defer { fault.remove() }
        XCTAssertFalse(store.insertMissingSources([entry(receipt: true)]))
        XCTAssertEqual(try storedRows(), [], "No row may be stored without its receipt")
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testMarkNeedsRemoteReconciliationWithAReceiptLongerThanTheLimitFailsAndKeepsTheRow() throws {
        let row = entry()
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        let fault = try failBinds(untilStepOf: "state='needsRemoteReconciliation'")
        defer { fault.remove() }
        XCTAssertFalse(
            store.markNeedsRemoteReconciliation(
                source: row.source, revision: row.revision, reconciliation: reconciliation(for: row.source),
                lastError: nil, updatedAt: Date(timeIntervalSince1970: 200)),
            "A receipt that does not bind must fail the write")
        XCTAssertEqual(try storedRows(), before, "The row must not turn into a reconciliation without its receipt")
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    // MARK: Writes

    func testUpsertWithAnIdentifierLongerThanTheLimitFails() throws {
        try lowerLengthLimit()
        XCTAssertFalse(store.upsertBatch([entry(long)]))
        XCTAssertEqual(try storedRows(), [])
        try assertBindFailureRecorded()
    }

    func testInsertMissingSourcesWithAnIdentifierLongerThanTheLimitFails() throws {
        try lowerLengthLimit()
        XCTAssertFalse(store.insertMissingSources([entry(long)]))
        XCTAssertEqual(try storedRows(), [])
        try assertBindFailureRecorded()
    }

    func testUpdateDismissedSourceRecheckWithAReasonLongerThanTheLimitIsUnknown() throws {
        let row = entry(lastError: issue(.sourceMissing))
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        try lowerLengthLimit()
        var update = row
        update.state = .discovered
        XCTAssertNil(
            store.updateDismissedSourceRecheck(
                update, matchingState: row.state, matchingLastError: issue(.sourceMissing)),
            "A reason that does not bind is no proof that the row changed meanwhile")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testReopenForUserRetryWithAnIdentifierLongerThanTheLimitFailsAndRecordsIt() throws {
        let row = entry(long, state: .failed)
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertFalse(store.reopenForUserRetry(row, attempts: 0, updatedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testReopenRestoredCompoundWithAnIdentifierLongerThanTheLimitIsUnknown() throws {
        let row = entry(long, state: .completed)
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertNil(
            store.reopenRestoredCompound(row, at: Date(timeIntervalSince1970: 200)),
            "A key that does not bind is no proof that the row changed meanwhile")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testUpdateStateWithAReasonLongerThanTheLimitFailsAndKeepsTheRow() throws {
        let row = entry()
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        let fault = try failBinds(untilStepOf: "attempts=COALESCE(?, attempts)")
        defer { fault.remove() }
        XCTAssertFalse(
            store.updateState(
                source: row.source, revision: row.revision, state: .failed, attempts: 1, lastError: issue(),
                updatedAt: Date(timeIntervalSince1970: 200)),
            "A reason that does not bind must fail the write, not store the state without its reason")
        XCTAssertEqual(try storedRows(), before)
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testUpdateStatesWithAReasonLongerThanTheLimitFailsAndKeepsEveryRow() throws {
        let first = entry(revision: 10)
        let second = entry(revision: 20)
        XCTAssertTrue(store.upsertBatch([first, second]))
        let before = try storedRows()
        let fault = try failBinds(untilStepOf: "attempts=COALESCE(?, attempts)")
        defer { fault.remove() }
        XCTAssertFalse(
            store.updateStates(
                of: first.source,
                [
                    .init(revision: first.revision, state: .failed, lastError: issue()),
                    .init(revision: second.revision, state: .failed, lastError: nil),
                ],
                updatedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(try storedRows(), before, "No update may stay when the first one cannot bind its reason")
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testRemoveWithAnIdentifierLongerThanTheLimitFailsAndRecordsIt() throws {
        let row = entry(long)
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertFalse(store.remove(source: row.source, revision: row.revision))
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testRemoveMissingSourceWithAnIdentifierLongerThanTheLimitFailsAndRecordsIt() throws {
        let row = entry(long, state: .sourceMissing)
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertFalse(store.removeMissingSource(source: row.source, revision: row.revision))
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testRemoveSettledRevisionsWithAnIdentifierLongerThanTheLimitFails() throws {
        let kept = entry(long, state: .completed, revision: 20)
        XCTAssertTrue(store.upsertBatch([entry(long, state: .completed, revision: 10), kept]))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertFalse(
            store.removeSettledRevisions(of: kept.source, except: kept.revision),
            "A key that does not bind removes nothing; that is no successful cleanup")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testRemoveUnsavedEarlierRevisionsWithAnIdentifierLongerThanTheLimitFails() throws {
        let kept = entry(long, revision: 20)
        XCTAssertTrue(store.upsertBatch([entry(long, state: .sourceMissing, revision: 10), kept]))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertFalse(
            store.removeUnsavedEarlierRevisions(of: kept.source, through: kept.revision, except: kept.revision),
            "A key that does not bind removes nothing; that is no successful cleanup")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testRemoveSourcesWithAnIdentifierLongerThanTheLimitFailsAndRecordsIt() throws {
        let row = entry(long)
        XCTAssertTrue(store.upsert(row))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertEqual(store.removeSources(kind: row.source.kind, identifiers: [row.source.identifier]), 0)
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testRemoveFileSourcesWithARootLongerThanTheLimitFailsAndRecordsIt() throws {
        let root = "/" + long
        let inside = entry(root + "/a.heic", kind: .fileURL)
        let outside = entry("/other/b.heic", kind: .fileURL)
        XCTAssertTrue(store.upsertBatch([inside, outside]))
        let before = try storedRows()
        let fault = try failBinds(untilStepOf: "DELETE FROM backup_sync_queue WHERE source_kind=?")
        defer { fault.remove() }
        XCTAssertEqual(store.removeFileSources(outsideRootPaths: [root]), 0)
        XCTAssertEqual(try storedRows(), before)
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testSetRuntimeIssueWithAValueLongerThanTheLimitFails() throws {
        try lowerLengthLimit()
        XCTAssertFalse(
            store.setRuntimeIssue(BackupIssueRecord(kind: .network, detail: long), for: .remoteIndexPreparation))
        try assertBindFailureRecorded()
    }

    // MARK: Reads

    func testSourcesWithEntriesWithAnIdentifierLongerThanTheLimitIsUnknown() throws {
        let row = entry(long)
        XCTAssertTrue(store.upsert(row))
        try lowerLengthLimit()
        XCTAssertNil(
            store.sourcesWithEntries([row.source]),
            "A key that does not bind is no proof that the source has no rows")
        try assertBindFailureRecorded()
    }

    func testClaimRunnableExcludingASourceLongerThanTheLimitIsUnknown() throws {
        let runnable = entry("runnable")
        XCTAssertTrue(store.upsert(runnable))
        let before = try storedRows()
        try lowerLengthLimit()
        XCTAssertNil(
            store.claimRunnable(
                limit: 10, claimedAt: Date(timeIntervalSince1970: 200),
                excludingSourcesOf: [UploadSourceIdentity(kind: .photoLibraryAsset, identifier: long)]),
            "An exclusion that does not bind must not hide every row of its kind")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    /// The claim's SELECT reads the long row without the limit; only the binds of its update see it.
    func testClaimRunnableOfARowWithAnIdentifierLongerThanTheLimitFailsAndKeepsTheRow() throws {
        XCTAssertTrue(store.upsert(entry(long)))
        let before = try storedRows()
        let fault = try failBinds(untilStepOf: "SET state='checking', updated_at=?", after: "AND updated_at <= ?")
        defer { fault.remove() }
        XCTAssertNil(
            store.claimRunnable(limit: 10, claimedAt: Date(timeIntervalSince1970: 200), excludingSourcesOf: []))
        XCTAssertTrue(fault.lowered, "The lowered limit must apply to the update's binds")
        XCTAssertFalse(fault.stepped, "The update must not run after its key failed to bind")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testNextRunnableDateExcludingASourceLongerThanTheLimitIsUnknown() throws {
        XCTAssertTrue(store.upsert(entry("runnable")))
        try lowerLengthLimit()
        XCTAssertNil(
            store.nextRunnableDate(
                excludingSourcesOf: [UploadSourceIdentity(kind: .photoLibraryAsset, identifier: long)]))
        try assertBindFailureRecorded()
    }

    func testDecisionProblemEntriesWithAPrefixLongerThanTheLimitThrow() throws {
        XCTAssertGreaterThan(BackupIssueRecord.storagePrefix.utf8.count, Int(Self.limit), "The prefix must not bind")
        XCTAssertTrue(store.upsertBatch([entry("failed", state: .failed), entry("waiting", lastError: issue())]))
        let fault = try failBinds(untilStepOf: "substr(last_error, 1, ?) = ?")
        defer { fault.remove() }
        var delivered: [String] = []
        XCTAssertThrowsError(
            try store.decisionForEachProblemEntry {
                delivered.append($0.source.identifier)
                return true
            },
            "A prefix that does not bind would hide every waiting problem")
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }

    func testProblemEntriesWithAPrefixLongerThanTheLimitDeliverNothingAndRecordIt() throws {
        XCTAssertTrue(store.upsertBatch([entry("failed", state: .failed), entry("waiting", lastError: issue())]))
        let fault = try failBinds(untilStepOf: "substr(last_error, 1, ?) = ?")
        defer { fault.remove() }
        var delivered: [String] = []
        store.forEachProblemEntry {
            delivered.append($0.source.identifier)
            return true
        }
        XCTAssertEqual(delivered, [], "A partial problem list must not look complete")
        XCTAssertFalse(fault.stepped, "A statement whose bind failed must not run")
        try assertBindFailureRecorded()
    }
}
