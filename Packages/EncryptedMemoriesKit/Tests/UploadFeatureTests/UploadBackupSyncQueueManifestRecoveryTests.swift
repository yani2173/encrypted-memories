import SQLite3
import XCTest

@testable import PhotosCore
@testable import UploadCore

/// Exercises dormant recovery and strict decision reads while application health remains sticky.
final class UploadBackupSyncQueueManifestRecoveryTests: XCTestCase {
    private var tempDir: URL!
    private var store: UploadBackupSyncQueueManifestStore?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        WriteFaultVFS.unregister()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(file: String = "queue.sqlite") throws -> UploadBackupSyncQueueManifestStore {
        try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: tempDir.appendingPathComponent(file)))
    }

    private func entry(
        _ id: String, state: UploadBackupSyncQueueState = .discovered, revision: TimeInterval = 10.0
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id),
            revision: UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: revision)),
            originalFilename: "\(id).heic",
            state: state,
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    /// The store's own connection, as the pending store tests reach it (#982).
    private func queueConnection() throws -> SQLiteStoreConnection {
        try XCTUnwrap(
            Mirror(reflecting: store!).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
    }

    func testEveryOptionalReaderReportsItsOwnFailedStatementAsUnknown() throws {
        let source = entry("known").source
        let readers: [(String, (UploadBackupSyncQueueManifestStore) -> Bool)] = [
            ("SELECT state, source_kind", { $0.summary() == nil }),
            ("SELECT COUNT(*) FROM backup_sync_queue", { $0.count() == nil }),
            ("SELECT value FROM backup_sync_queue_info WHERE key=?", { $0.catalogReplayState() == nil }),
            (
                "SELECT value FROM backup_sync_queue_info WHERE key='missing_source_discard_generation'",
                { $0.missingSourceDiscardGeneration() == nil }
            ),
            ("SELECT 1 FROM backup_sync_queue WHERE source_kind=?", { $0.sourcesWithEntries([source]) == nil }),
        ]
        for (index, reader) in readers.enumerated() {
            for interruptStep in [false, true] {
                store = try makeStore(file: "unknown-\(index)-\(interruptStep).sqlite")
                XCTAssertTrue(store!.upsert(entry("known")))
                XCTAssertFalse(reader.1(store!), "A healthy read is known: \(reader.0)")
                if interruptStep {
                    let fault = try SQLiteReadInterrupt(in: store!, matching: reader.0)
                    XCTAssertTrue(reader.1(store!), "A failed step is unknown: \(reader.0)")
                    XCTAssertTrue(fault.fired, reader.0)
                    fault.stop()
                } else {
                    try withDeniedSQLiteSelect(in: store!) {
                        XCTAssertTrue(reader.1(store!), "A failed prepare is unknown: \(reader.0)")
                    }
                }
                store!.close()
            }
        }
    }

    func testLegacyEntryReadsHealthySQLAfterAnUnrelatedFailure() throws {
        let row = entry("known")
        try assertLegacyQueueRead { XCTAssertEqual(try $0.entry(for: row.source, revision: row.revision), row) }
    }

    func testLegacyContainsAnyReadsHealthySQLAfterAnUnrelatedFailure() throws {
        try assertLegacyQueueRead { XCTAssertTrue(try $0.containsAny(in: [.discovered])) }
    }

    func testDecisionReadRefusesALastingFailureEvenWhenItsRowsAreReadable() throws {
        try assertLegacyQueueRead {
            XCTAssertThrowsError(try $0.decisionRows(kind: .photoLibraryAsset, identifiers: ["known"]))
        }
    }

    func testLegacySummaryReadsHealthySQLAfterAnUnrelatedFailure() throws {
        try assertLegacyQueueRead { XCTAssertEqual($0.summary()?.total, 1) }
    }

    func testLegacyCountReadsHealthySQLAfterAnUnrelatedFailure() throws {
        try assertLegacyQueueRead { XCTAssertEqual($0.count(), 1) }
    }

    func testLegacyReplayStateReadsHealthySQLAfterAnUnrelatedFailure() throws {
        try assertLegacyQueueRead { XCTAssertEqual($0.catalogReplayState(), .inProgress) }
    }

    func testLegacyPresenceReadsHealthySQLAfterAnUnrelatedFailure() throws {
        let source = entry("known").source
        try assertLegacyQueueRead { XCTAssertEqual($0.sourcesWithEntries([source]), [source]) }
    }

    func testLegacyDiscardGenerationReadsHealthySQLAfterAnUnrelatedFailure() throws {
        try assertLegacyQueueRead { XCTAssertEqual($0.missingSourceDiscardGeneration(), 1) }
    }

    private func assertLegacyQueueRead(_ read: (UploadBackupSyncQueueManifestStore) throws -> Void) throws {
        store = try makeStore()
        XCTAssertTrue(store!.upsert(entry("known")))
        let discarded = entry("discarded")
        XCTAssertTrue(store!.upsert(discarded))
        XCTAssertTrue(store!.removeMissingSource(source: discarded.source, revision: discarded.revision))
        XCTAssertTrue(store!.setCatalogReplayState(.inProgress))
        try withDeniedSQLiteSelect(in: store!) {
            let unrelated = entry("unrelated")
            XCTAssertNil(try? store!.entry(for: unrelated.source, revision: unrelated.revision))
        }
        XCTAssertFalse(store!.isOperational(), "A legacy read does not clear the sticky failure")
        try read(store!)
        let connection = try queueConnection()
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        }
        try read(store!)
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertFalse(store!.isOperational())
    }

    func testATransientFailureIsForgottenOnceTheDatabaseAnswers() throws {
        store = try makeStore()
        let fault = try SQLiteReadInterrupt(in: store!, matching: "SELECT original_filename, byte_count, state")
        defer { fault.stop() }
        XCTAssertThrowsError(try store!.entry(for: entry("known").source, revision: entry("known").revision))
        XCTAssertTrue(fault.fired)
        XCTAssertTrue(store!.isOperational(), "the transient interrupt is forgotten once the database answers")
        XCTAssertTrue(store!.isOperational(), "and stays forgotten")
    }

    func testClosedStoreKeepsRecoveryUnavailable() throws {
        store = try makeStore()
        store!.close()
        XCTAssertFalse(store!.isOperational())
    }

    func testAReadLockKeepsRecoveryUnavailableUntilTheDatabaseAnswers() throws {
        store = try makeStore()
        let row = entry("locked-read")
        XCTAssertTrue(store!.upsert(row))
        let connection = try queueConnection()
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "PRAGMA journal_mode=DELETE;", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_busy_timeout(connection.database, 0), SQLITE_OK)
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempDir.appendingPathComponent("queue.sqlite").path, &handle), SQLITE_OK)
        let blocker = try XCTUnwrap(handle)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        defer { _ = sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil) }
        XCTAssertThrowsError(try store!.entry(for: row.source, revision: row.revision))
        connection.withLock { XCTAssertTrue(connection.failuresAreTransient) }
        XCTAssertFalse(store!.isOperational(), "A constant SELECT would incorrectly clear the read failure")
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store!.isOperational())
        XCTAssertEqual(try store!.entry(for: row.source, revision: row.revision), row)
    }

    /// A failed bind would make the lookup prove an absence it never read (#1004 B2).
    func testEntryBindingFailureThrowsInsteadOfProvingAbsence() throws {
        store = try makeStore()
        let connection = try queueConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        let row = entry(String(repeating: "x", count: 128))
        XCTAssertThrowsError(try store!.entry(for: row.source, revision: row.revision))
        connection.withLock {
            XCTAssertTrue(connection.operationFailed, "The failed bind must be recorded")
            XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure")
        }
    }

    func testEntryResourceBindingFailureThrowsInsteadOfProvingAbsence() throws {
        store = try makeStore()
        let connection = try queueConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        let source = UploadSourceIdentity(
            kind: .fileURL, identifier: "file", resource: .init(rawValue: String(repeating: "r", count: 128)))
        XCTAssertThrowsError(try store!.entry(for: source, revision: .init(rawValue: 1)))
        connection.withLock { XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure") }
    }

    func testDecisionBindingFailuresThrowInsteadOfProvingAbsence() throws {
        for (limit, identifier) in [(Int32(32), String(repeating: "x", count: 128))] {
            store = try makeStore(file: "decision-binding-\(limit).sqlite")
            let connection = try queueConnection()
            connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, limit) }
            XCTAssertThrowsError(try store!.decisionRows(kind: .photoLibraryAsset, identifiers: [identifier]))
            connection.withLock {
                XCTAssertTrue(connection.operationFailed, "The failed bind must be recorded")
                XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure")
            }
            store!.close()
        }
    }

    func testDecisionPrepareFailureThrowsInsteadOfProvingAbsence() throws {
        store = try makeStore()
        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertThrowsError(try store!.decisionRows(kind: .photoLibraryAsset, identifiers: ["known"]))
        }
    }

    func testDecisionKindBindingKeepsSourcesSeparate() throws {
        store = try makeStore()
        let photo = entry("shared-key")
        var file = photo
        file.source = UploadSourceIdentity(kind: .fileURL, identifier: photo.source.identifier)
        XCTAssertTrue(store!.upsertBatch([photo, file]))
        XCTAssertEqual(
            try store!.decisionRows(kind: .photoLibraryAsset, identifiers: [photo.source.identifier]).map(\.source),
            [photo.source])
        XCTAssertEqual(
            try store!.decisionRows(kind: .fileURL, identifiers: [file.source.identifier]).map(\.source),
            [file.source])
    }

    func testBindingOutOfMemoryRecordsATransientFailure() throws {
        store = try makeStore()
        let connection = try queueConnection()
        try connection.withLock {
            XCTAssertThrowsError(try connection.requireReadableBinding(resultCode: SQLITE_NOMEM))
            XCTAssertTrue(connection.operationFailed)
            XCTAssertTrue(connection.failuresAreTransient)
        }
        XCTAssertTrue(store!.isOperational())
    }

    func testDecisionReadRefusesAPartialResultAndRetriesAfterRecovery() throws {
        store = try makeStore()
        for revision in [1.0, 2.0, 3.0] {
            XCTAssertTrue(store!.upsert(entry("edited", revision: revision)))
        }
        let fault = try SQLiteReadInterrupt(
            in: store!, matching: "SELECT source_kind, source_id, resource, revision_us, state, original_filename",
            afterRows: 2)
        defer { fault.stop() }
        XCTAssertThrowsError(
            try store!.decisionRows(kind: .photoLibraryAsset, identifiers: ["edited"]),
            "A decision must never receive the prefix of a failed read")
        XCTAssertTrue(fault.fired)
        XCTAssertEqual(fault.tracedRows, 2, "The failure occurs after at least one row was returned")
        XCTAssertTrue(store!.isOperational(), "the transient interrupt is forgotten once the database answers")
        XCTAssertEqual(try store!.decisionRows(kind: .photoLibraryAsset, identifiers: ["edited"]).count, 3)
    }

    func testDecisionReadRefusesAnUndecodableRow() throws {
        store = try makeStore()
        XCTAssertTrue(store!.upsert(entry("edited", revision: 1)))
        XCTAssertTrue(store!.upsert(entry("edited", state: .failedPermanent, revision: 2)))
        XCTAssertTrue(store!.upsert(entry("edited", revision: 3)))
        let connection = try queueConnection()
        try SerializedImageMutation.install(on: connection) { image in
            let needle = Array("failedPermanent".utf8)
            let range = try XCTUnwrap(image.firstRange(of: needle))
            image[range.lowerBound] = UInt8(ascii: "x")
        }
        XCTAssertThrowsError(
            try store!.decisionRows(kind: .photoLibraryAsset, identifiers: ["edited"]),
            "A malformed row cannot disappear from a complete decision read")
        XCTAssertFalse(store!.isOperational())
    }

    func testUnknownEntryAndPresenceReadsThrowInsteadOfProvingAbsence() throws {
        store = try makeStore()
        let row = entry("known")
        XCTAssertTrue(store!.upsert(row))
        let connection = try queueConnection()
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertThrowsError(try store!.decisionRows(kind: .photoLibraryAsset, identifiers: ["known"]))
        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        let rowFault = try SQLiteReadInterrupt(in: store!, matching: "SELECT original_filename, byte_count, state")
        XCTAssertThrowsError(try store!.entry(for: row.source, revision: row.revision))
        XCTAssertTrue(rowFault.fired)
        rowFault.stop()
        XCTAssertTrue(store!.isOperational())
        let presenceFault = try SQLiteReadInterrupt(
            in: store!, matching: "SELECT 1 FROM backup_sync_queue WHERE state IN")
        XCTAssertThrowsError(try store!.containsAny(in: [.discovered]))
        XCTAssertTrue(presenceFault.fired)
        presenceFault.stop()
        XCTAssertTrue(store!.isOperational())
        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertThrowsError(try store!.entry(for: row.source, revision: row.revision))
            XCTAssertThrowsError(try store!.containsAny(in: [.discovered]))
        }
        store!.close()
        XCTAssertThrowsError(try store!.decisionRows(kind: .photoLibraryAsset, identifiers: ["known"]))
        XCTAssertThrowsError(try store!.entry(for: row.source, revision: row.revision))
        XCTAssertThrowsError(try store!.containsAny(in: [.discovered]))
        XCTAssertFalse(try store!.containsAny(in: []), "An empty set needs no read")
    }

    func testTheRecoveryProbeReadsTheDatabase() throws {
        store = try makeStore()
        let connection = try queueConnection()
        connection.withLock {
            XCTAssertEqual(
                sqlite3_set_authorizer(
                    connection.database,
                    { _, action, table, _, _, _ in
                        guard action == SQLITE_READ, let table else { return SQLITE_OK }
                        return ["sqlite_master", "sqlite_schema"].contains(String(cString: table))
                            ? SQLITE_DENY : SQLITE_OK
                    }, nil), SQLITE_OK)
        }
        defer { connection.withLock { _ = sqlite3_set_authorizer(connection.database, nil, nil) } }
        XCTAssertFalse(store!.isOperational(), "A constant SELECT cannot prove that the database answers")
        connection.withLock { _ = sqlite3_set_authorizer(connection.database, nil, nil) }
        XCTAssertFalse(store!.isOperational(), "The denied schema read must remain recorded")
    }

    // MARK: - One transient class at a time

    /// A write that fails with BUSY, LOCKED, NOMEM, INTERRUPT, IOERR or FULL refuses; the same store
    /// instance answers and persists again once the database answers, without a reopen.
    func testATransientWriteFailureStopsTheStoreOnlyUntilTheDatabaseAnswers() throws {
        for code in [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_INTERRUPT, SQLITE_IOERR, SQLITE_FULL] {
            try WriteFaultVFS.register()
            let directory = tempDir.appendingPathComponent("code-\(code)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try XCTUnwrap(
                UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
            defer { store.close() }

            let entry = self.entry("transient-\(code)")
            WriteFaultVFS.arm(code)
            XCTAssertFalse(store.upsert(entry), "the refused write (code \(code)) persists nothing")

            WriteFaultVFS.arm(nil)
            XCTAssertTrue(store.isOperational(), "code \(code): the store answers again without a reopen")
            XCTAssertTrue(store.upsert(entry), "code \(code): the same instance persists the entry")

            let read = try store.entry(for: entry.source, revision: entry.revision)
            XCTAssertEqual(read?.state, entry.state, "code \(code): the recovered write is readable")
            WriteFaultVFS.unregister()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Another connection holds the write lock, as a busy database does; once it lets go, the store works again.
    func testABusyLockOnAnotherConnectionStopsTheStoreOnlyUntilTheLockClears() throws {
        store = try makeStore()
        let url = tempDir.appendingPathComponent("queue.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let blocker = try XCTUnwrap(handle)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        let entry = self.entry("busy")
        XCTAssertFalse(store!.upsert(entry), "the busy write persists nothing")
        XCTAssertEqual(
            store!.sourcesWithEntries([entry.source]), [],
            "a transient failure does not stop the presence read")

        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store!.isOperational(), "the database answers again")
        XCTAssertTrue(store!.upsert(entry))
    }

    /// A progress handler that interrupts every statement, as a timeout or cancellation does; once it is gone, the
    /// store works again.
    func testAnInterruptStopsTheStoreOnlyUntilTheInterruptClears() throws {
        store = try makeStore()
        let connection = try queueConnection()

        connection.withLock { sqlite3_progress_handler(connection.database, 1, { _ in 1 }, nil) }
        let entry = self.entry("interrupted")
        XCTAssertFalse(store!.upsert(entry), "the interrupted write persists nothing")

        connection.withLock { sqlite3_progress_handler(connection.database, 0, nil, nil) }
        XCTAssertTrue(store!.isOperational(), "the store answers again")
        XCTAssertTrue(store!.upsert(entry))
    }

    // MARK: - Controls

    /// A COMMIT that a hook refuses writes nothing and stops the store for good, as #982 decided for the pending
    /// store; clearing the hook does not bring the instance back.
    func testARefusedCommitWritesNothingAndStopsTheStore() throws {
        store = try makeStore()
        let connection = try queueConnection()
        let entry = self.entry("refused-commit")

        connection.withLock { _ = sqlite3_commit_hook(connection.database, { _ in 1 }, nil) }
        XCTAssertFalse(store!.upsert(entry), "the refused commit persists nothing")
        connection.withLock {
            _ = sqlite3_commit_hook(connection.database, nil, nil)
            XCTAssertNotEqual(sqlite3_get_autocommit(connection.database), 0, "no transaction stays open")
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient, "a refused commit is not a passing failure")
        }

        XCTAssertFalse(store!.isOperational(), "a refused commit is a lasting failure")
        XCTAssertEqual(try store!.entry(for: entry.source, revision: entry.revision), nil, "nothing was written")
        XCTAssertTrue(store!.upsert(entry), "later calls answer on their own")
    }

    /// The dormant recovery probe refuses an open transaction; legacy readers keep their pre-activation behavior.
    func testAnOpenTransactionKeepsRecoveryUnavailable() throws {
        store = try makeStore()
        let entry = self.entry("half-written")
        XCTAssertTrue(store!.upsert(entry))
        let connection = try queueConnection()

        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store!.sourcesWithEntries([entry.source]), [entry.source], "Legacy reads retain their behavior")
        XCTAssertEqual(store!.missingSourceDiscardGeneration(), 0, "The legacy generation read still answers")
        XCTAssertFalse(store!.isOperational(), "the open transaction keeps the store stopped")

        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store!.sourcesWithEntries([entry.source]), [entry.source], "the read answers again")
        XCTAssertEqual(store!.missingSourceDiscardGeneration(), 0)
        XCTAssertTrue(store!.isOperational())
        XCTAssertTrue(store!.upsert(self.entry("after-rollback")))
    }

    /// A failed call that is not transient stays recorded, and later calls answer on their own (#982).
    func testALastingFailureKeepsRecoveryUnavailableWhileLegacyReadsContinue() throws {
        store = try makeStore()
        let entry = self.entry("lasting")
        XCTAssertTrue(store!.upsert(entry))

        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertNil(store!.sourcesWithEntries([entry.source]), "the denied read fails")
            XCTAssertFalse(store!.upsert(self.entry("during-denial")), "the denied write persists nothing")
        }

        XCTAssertFalse(store!.isOperational(), "a lasting failure stays recorded")
        XCTAssertEqual(store!.sourcesWithEntries([entry.source]), [entry.source], "The requested legacy read succeeds")
        XCTAssertTrue(store!.upsert(self.entry("after-denial")), "later calls answer on their own")
        XCTAssertEqual(store!.sourcesWithEntries([entry.source]), [entry.source], "The healthy row remains readable")

        store = nil
        let reopened = try makeStore()
        XCTAssertTrue(reopened.isOperational(), "a reopen answers again")
        XCTAssertEqual(
            reopened.sourcesWithEntries([entry.source]), [entry.source], "persisted work survives the reopen")
        reopened.close()
    }

    /// The upsert's prior-row read records its own step result code when it fails. A lasting code must replace an
    /// earlier recorded transient failure, so the store stays stopped until the database is repaired (#1004).
    func testALastingPriorRowFailureReplacesAnEarlierTransientFailure() throws {
        store = try makeStore()
        let entry = self.entry("fresh-code")
        let url = tempDir.appendingPathComponent("queue.sqlite")
        let connection = try queueConnection()

        // Step 1: a busy write records a transient failure and leaves the store recoverable.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let blocker = try XCTUnwrap(handle)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store!.upsert(entry), "the busy write persists nothing")
        connection.withLock {
            XCTAssertTrue(connection.operationFailed)
            XCTAssertTrue(connection.failuresAreTransient, "the busy write records a transient failure")
        }
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)

        // Step 2: swap a mutated image into the still-open store connection. An external write to the file stays
        // invisible to the open connection's page cache, so the mutation must travel through serialize +
        // deserialize on the store's own connection. Zeroing the primary-key index root keeps `BEGIN IMMEDIATE`
        // and the prepare working, so the prior-row keyed lookup still prepares, and only its step answers
        // SQLITE_CORRUPT, a lasting code, at the exact site that must record its own result.
        _ = try SerializedImageMutation.zeroIndexRootPage(
            on: connection, indexName: "sqlite_autoindex_backup_sync_queue_1")
        _ = url  // the file stays untouched; only the connection's in-memory image is broken

        // Step 3: the same instance now refuses the upsert, and the lasting code has replaced the transient one.
        // The health probe, which cleared busy databases until now, must not clear this failure.
        XCTAssertFalse(store!.upsert(entry), "the corrupted prior-row lookup persists nothing")
        connection.withLock {
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient, "the lasting code replaced the transient failure")
        }
        XCTAssertFalse(store!.isOperational(), "the corrupted database keeps the store stopped")
        XCTAssertThrowsError(
            try store!.entry(for: entry.source, revision: entry.revision),
            "a failed row read must stay unknown")
    }

    /// A row whose state text no longer decodes stops the queue summary. The step that delivered the row
    /// succeeded, so the absence of a result code is what records a lasting failure. The health probe still
    /// passes on the structurally valid database, and it must not clear the failure (#1004).
    func testAnUndecodableRowKeepsTheStoreStoppedAfterAPassedProbe() throws {
        store = try makeStore()
        let entry = self.entry("undecodable")
        XCTAssertTrue(store!.upsert(entry))
        XCTAssertEqual(store!.summary()?.total, 1, "the healthy summary answers")

        let connection = try queueConnection()
        // Swap a mutated image into the still-open store connection: an external write to the file stays invisible
        // to the open connection's page cache. Flip the persisted state bytes inside the serialized image. Every
        // page stays structurally valid, so the probe still answers, and only the decode of the changed text fails.
        try SerializedImageMutation.install(on: connection) { image in
            let needle = Array("discovered".utf8)
            var flipped = 0
            var searchStart = image.startIndex
            while searchStart <= image.index(image.startIndex, offsetBy: image.count - needle.count),
                let found = image[searchStart...].firstRange(of: needle)
            {
                image[found.lowerBound] = UInt8(ascii: "x")
                flipped += 1
                searchStart = found.upperBound
            }
            XCTAssertTrue(flipped > 0, "the row's state text was found in the database image")
        }

        // The database answers the probe, but the malformed row still prevents a complete summary.
        connection.withLock {
            var probe: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(connection.database, "SELECT count(*) FROM sqlite_schema;", -1, &probe, nil),
                SQLITE_OK)
            XCTAssertEqual(sqlite3_step(probe), SQLITE_ROW, "the probe passes on the valid page structure")
            sqlite3_finalize(probe)
        }
        XCTAssertNil(store!.summary(), "the undecodable row stops the summary read")
        XCTAssertFalse(store!.isOperational(), "the lasting failure stays recorded after the passing probe")
        XCTAssertEqual(store!.count(), 1, "The legacy scalar read still answers its own successful SQL")
    }

    func testARefusedUpsertWrapperRecordsFailureWithoutChangingTheRow() throws {
        try assertRefusedDurabilityWrapper { queue, row in !queue.upsertBatch([row]) }
    }

    func testARefusedDismissedRecheckWrapperRecordsFailureWithoutChangingTheRow() throws {
        try assertRefusedDurabilityWrapper(state: .dismissedFailure) { queue, row in
            queue.updateDismissedSourceRecheck(
                row, matchingState: row.state, matchingLastError: row.lastError!) == nil
        }
    }

    func testARefusedManualRetryWrapperRecordsFailureWithoutChangingTheRow() throws {
        try assertRefusedDurabilityWrapper { queue, _ in
            queue.makeRetryableWorkEligible(updatedAt: Date(timeIntervalSince1970: 200)) == 0
        }
    }

    func testARefusedRevisionCleanupWrapperRecordsFailureWithoutDeletingTheRow() throws {
        try assertRefusedDurabilityWrapper(state: .failedPermanent) { queue, row in
            !queue.removeUnsavedEarlierRevisions(
                of: row.source, through: row.revision, except: .init(rawValue: row.revision.rawValue + 1))
        }
    }

    private func assertRefusedDurabilityWrapper(
        state: UploadBackupSyncQueueState = .failed,
        file: StaticString = #filePath, line: UInt = #line,
        _ refused: (UploadBackupSyncQueueManifestStore, UploadBackupSyncQueueEntry) -> Bool
    ) throws {
        store = try makeStore()
        var row = entry("wrapper-refusal", state: state)
        row.lastError = "retained reason"
        XCTAssertTrue(store!.upsert(row), file: file, line: line)
        XCTAssertTrue(store!.isOperational(), file: file, line: line)
        let connection = try queueConnection()
        try withDeniedSQLitePragma(in: store!) {
            XCTAssertTrue(refused(store!, row), "The refused wrapper runs no mutation", file: file, line: line)
            connection.withLock {
                XCTAssertTrue(
                    connection.operationFailed, "Each wrapper records its own refusal", file: file, line: line)
            }
        }
        XCTAssertFalse(store!.isOperational(), file: file, line: line)
        XCTAssertEqual(try store!.entry(for: row.source, revision: row.revision), row, file: file, line: line)
    }

    /// A `withDurableCommits` wrapper that could not run — here because a denied PRAGMA forbids raising the
    /// durability bar — must record a failure instead of answering as if the body had simply found nothing to
    /// do (#1004, F4). Without the record, the readers would answer from a database whose commit safety is
    /// unknown, and the absent-insert path would silently swallow the failure.
    func testADurabilityWrapperThatCannotRunStopsTheInsert() throws {
        store = try makeStore()
        let entry = self.entry("durability-insert")
        let connection = try queueConnection()

        connection.withLock {
            XCTAssertEqual(
                sqlite3_exec(connection.database, "PRAGMA synchronous=3;", nil, nil, nil), SQLITE_OK,
                "the writer raises the durability bar first, as the store does")
        }
        try withDeniedSQLitePragma(in: store!) {
            XCTAssertFalse(
                store!.insertMissingSources([entry]), "the insert that could not run persists nothing")
            connection.withLock {
                XCTAssertTrue(connection.operationFailed, "the insert wrapper that could not run records a failure")
            }
        }
        XCTAssertFalse(store!.isOperational(), "the store stays stopped until the probe clears it")
    }

    /// The discard path shares the insert path's requirement: a wrapper that could not run records a failure
    /// instead of reporting a plain absent discard (#1004, F4). This test exercises only the discard, so the
    /// insert's own record cannot mask it.
    func testADurabilityWrapperThatCannotRunStopsTheDiscard() throws {
        store = try makeStore()
        let entry = self.entry("durability-discard")
        let connection = try queueConnection()

        try withDeniedSQLitePragma(in: store!) {
            XCTAssertFalse(
                store!.removeMissingSource(source: entry.source, revision: entry.revision),
                "the discard that could not run reports failure")
            connection.withLock {
                XCTAssertTrue(connection.operationFailed, "the discard wrapper that could not run records a failure")
            }
        }
        XCTAssertFalse(store!.isOperational(), "the store stays stopped until the probe clears it")
    }

    // MARK: - B2: complete reads for decisions (#1004)

    /// A setup failure of a durable write records its own lasting code even after an earlier transient failure, so a
    /// later passing probe cannot forget it (#1004, row 9).
    func testADurableWriteSetupFailureAfterATransientFailureKeepsItsLastingCode() throws {
        store = try makeStore()
        let row = entry("setup-after-busy")
        let connection = try queueConnection()
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(tempDir.appendingPathComponent("queue.sqlite").path, &handle, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK)
        let blocker = try XCTUnwrap(handle)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(store!.upsert(row), "the busy write persists nothing")
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        connection.withLock { XCTAssertTrue(connection.failuresAreTransient, "the busy write is transient") }

        try withDeniedSQLitePragma(in: store!) {
            XCTAssertFalse(store!.upsert(row), "the denied setup runs no write")
        }

        connection.withLock {
            XCTAssertFalse(connection.failuresAreTransient, "the denied setup records its own lasting code")
        }
        XCTAssertFalse(store!.isOperational(), "a passing probe must not forget the lasting failure")
        XCTAssertNil(try store!.entry(for: row.source, revision: row.revision))
    }

    func testCompleteUnsettledInventoryRefusesEveryIncompleteRead() throws {
        let rows = [entry("a", revision: 1), entry("b", revision: 2), entry("c", revision: 3)]
        let rowSQL = "SELECT source_kind, source_id, resource, revision_us, state, original_filename"

        store = try makeStore(file: "healthy.sqlite")
        XCTAssertEqual(try store!.decisionUnsettledRows(), [], "an empty queue is a complete empty answer")
        for row in rows { XCTAssertTrue(store!.upsert(row)) }
        XCTAssertEqual(
            try store!.decisionUnsettledRows().sorted { $0.source.identifier < $1.source.identifier },
            rows.map {
                UploadBackupQueueRowState(
                    source: $0.source, revision: $0.revision, state: $0.state, originalFilename: $0.originalFilename,
                    updatedAt: $0.updatedAt)
            },
            "every row with its state and revision")
        store!.close()

        store = try makeStore(file: "prepare.sqlite")
        for row in rows { XCTAssertTrue(store!.upsert(row)) }
        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertThrowsError(try store!.decisionUnsettledRows(), "a failed prepare proves no empty queue")
        }
        store!.close()

        store = try makeStore(file: "prefix.sqlite")
        for row in rows { XCTAssertTrue(store!.upsert(row)) }
        let fault = try SQLiteReadInterrupt(in: store!, matching: rowSQL, afterRows: 2)
        XCTAssertThrowsError(try store!.decisionUnsettledRows(), "a failed step after a prefix returns no prefix")
        fault.stop()
        XCTAssertTrue(fault.fired)
        XCTAssertEqual(fault.tracedRows, 2)
        store!.close()

        store = try makeStore(file: "undecodable.sqlite")
        XCTAssertTrue(store!.upsert(entry("x", state: .failed, revision: 1)))
        XCTAssertTrue(store!.upsert(entry("y", state: .failedPermanent, revision: 2)))
        let connection = try queueConnection()
        try SerializedImageMutation.install(on: connection) { image in
            let needle = Array("failedPermanent".utf8)
            let range = try XCTUnwrap(image.firstRange(of: needle))
            image[range.lowerBound] = UInt8(ascii: "x")
        }
        XCTAssertThrowsError(try store!.decisionUnsettledRows(), "an undecodable row cannot vanish from the inventory")
        XCTAssertFalse(store!.isOperational())
    }

    /// Each decision read throws on a failed step instead of answering "nothing waits".
    func testDecisionQueueReadsRefuseAFailedStep() throws {
        let issue = BackupIssueRecord(kind: .remoteService, detail: "index", automaticRetryAttempt: 3)
        let reads: [(String, String, (UploadBackupSyncQueueManifestStore) throws -> Void)] = [
            (
                "next-date", "SELECT MIN(updated_at) FROM backup_sync_queue",
                {
                    _ = try $0.decisionNextRunnableDate(excludingSourcesOf: [])
                }
            ),
            (
                "earliest", "WHERE state='blockedByDraft' ORDER BY updated_at ASC LIMIT 1",
                {
                    _ = try $0.decisionEarliestEntry(in: .blockedByDraft)
                }
            ),
            (
                "entries", "WHERE state = ? AND updated_at < ?",
                {
                    _ = try $0.decisionEntries(in: .blockedByDraft, updatedBefore: .distantFuture, limit: 10)
                }
            ),
            (
                "runtime-issue", "SELECT value FROM backup_sync_runtime_issue",
                {
                    _ = try $0.decisionRuntimeIssue(for: .remoteIndexPreparation)
                }
            ),
            (
                "problems", "WHERE state IN ('failed', 'failedPermanent'",
                {
                    try $0.decisionForEachProblemEntry { _ in true }
                }
            ),
        ]
        for (name, sql, read) in reads {
            store = try makeStore(file: "\(name).sqlite")
            XCTAssertTrue(store!.upsert(entry("runnable", revision: 1)), name)
            XCTAssertTrue(store!.upsert(entry("draft", state: .blockedByDraft, revision: 2)), name)
            XCTAssertTrue(store!.upsert(entry("failed", state: .failed, revision: 3)), name)
            XCTAssertTrue(store!.setRuntimeIssue(issue, for: .remoteIndexPreparation), name)
            XCTAssertNoThrow(try read(store!), "\(name): a healthy read answers")
            let fault = try SQLiteReadInterrupt(in: store!, matching: sql)
            XCTAssertThrowsError(try read(store!), "\(name): a failed step is no answer")
            fault.stop()
            XCTAssertTrue(fault.fired, name)
            store!.close()
        }
    }

    /// A decision read refuses a lasting failure and an open transaction, even when its rows are readable.
    func testDecisionQueueReadsRefuseALastingFailureAndAnOpenTransaction() throws {
        let reads: [(String, (UploadBackupSyncQueueManifestStore) throws -> Void)] = [
            ("next-date", { _ = try $0.decisionNextRunnableDate(excludingSourcesOf: []) }),
            ("earliest", { _ = try $0.decisionEarliestEntry(in: .blockedByDraft) }),
            ("entries", { _ = try $0.decisionEntries(in: .blockedByDraft, updatedBefore: .distantFuture, limit: 10) }),
            ("runtime-issue", { _ = try $0.decisionRuntimeIssue(for: .remoteIndexPreparation) }),
            ("problems", { try $0.decisionForEachProblemEntry { _ in true } }),
            ("unsettled", { _ = try $0.decisionUnsettledRows() }),
        ]
        for (name, read) in reads {
            for lasting in [true, false] {
                store = try makeStore(file: "\(name)-\(lasting).sqlite")
                XCTAssertTrue(store!.upsert(entry("draft", state: .blockedByDraft, revision: 2)), name)
                XCTAssertNoThrow(try read(store!), "\(name): a healthy read answers")
                let connection = try queueConnection()
                connection.withLock {
                    if lasting {
                        connection.markFailed()
                    } else {
                        XCTAssertEqual(
                            sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK, name)
                    }
                }
                XCTAssertThrowsError(
                    try read(store!), "\(name): refused while \(lasting ? "failed" : "in a transaction")")
                if !lasting {
                    connection.withLock { _ = sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil) }
                }
                store!.close()
            }
        }
    }

    /// The healthy answers of the decision reads equal the legacy answers.
    func testDecisionQueueReadsAnswerLikeTheLegacyReadsWhenHealthy() throws {
        store = try makeStore()
        XCTAssertNil(try store!.decisionNextRunnableDate(excludingSourcesOf: []), "nothing runnable is nil")
        XCTAssertNil(try store!.decisionRuntimeIssue(for: .remoteIndexPreparation))
        let issue = BackupIssueRecord(kind: .remoteService, detail: "index", automaticRetryAttempt: 3)
        XCTAssertTrue(store!.setRuntimeIssue(issue, for: .remoteIndexPreparation))
        let runnable = entry("runnable", revision: 1)
        XCTAssertTrue(store!.upsert(runnable))
        XCTAssertTrue(store!.upsert(entry("draft", state: .blockedByDraft, revision: 2)))
        XCTAssertTrue(store!.upsert(entry("failed", state: .failed, revision: 3)))
        XCTAssertEqual(
            try store!.decisionNextRunnableDate(excludingSourcesOf: []), store!.nextRunnableDate(excludingSourcesOf: [])
        )
        XCTAssertNil(try store!.decisionNextRunnableDate(excludingSourcesOf: [runnable.source]))
        XCTAssertEqual(try store!.decisionEarliestEntry(in: .blockedByDraft), store!.earliestEntry(in: .blockedByDraft))
        XCTAssertEqual(
            try store!.decisionEntries(in: .blockedByDraft, updatedBefore: .distantFuture, limit: 10),
            store!.entries(in: .blockedByDraft, updatedBefore: .distantFuture, limit: 10))
        XCTAssertEqual(try store!.decisionRuntimeIssue(for: .remoteIndexPreparation), issue)
        var strict: [UploadBackupSyncQueueEntry] = []
        try store!.decisionForEachProblemEntry {
            strict.append($0)
            return true
        }
        var legacy: [UploadBackupSyncQueueEntry] = []
        store!.forEachProblemEntry {
            legacy.append($0)
            return true
        }
        XCTAssertEqual(strict, legacy)
        XCTAssertFalse(strict.isEmpty)
    }

    /// A strict read checks its binds: a key longer than the length limit fails to bind instead of matching nothing.
    func testDecisionReadBindingFailureThrowsInsteadOfProvingNothingWaits() throws {
        store = try makeStore()
        XCTAssertTrue(store!.upsert(entry("runnable", revision: 1)))
        let connection = try queueConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        connection.withLock {
            XCTAssertEqual(sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1), 32, "the limit applies")
        }
        let excluded = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: String(repeating: "x", count: 128))
        XCTAssertThrowsError(try store!.decisionNextRunnableDate(excludingSourcesOf: [excluded]))
        connection.withLock {
            XCTAssertTrue(connection.operationFailed, "The failed bind must be recorded")
            XCTAssertFalse(connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure")
        }
    }
}

/// The shared `WriteFaultVFS` lives in `SQLiteWriteFaultVFS.swift`.
