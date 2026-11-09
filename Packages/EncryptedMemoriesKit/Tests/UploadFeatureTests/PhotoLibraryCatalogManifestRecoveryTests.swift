import SQLite3
import XCTest

@testable import PhotosCore
@testable import UploadCore

/// Exercises the dormant recovery primitive and explicit per-read unknown results. Application health stays
/// sticky, and legacy readers retain successful SQL results until their consumers migrate.
final class PhotoLibraryCatalogManifestRecoveryTests: XCTestCase {
    private var tempDir: URL!
    private var store: PhotoLibraryCatalogManifestStore?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        WriteFaultVFS.unregister()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(
        file: String = PhotoLibraryCatalogManifestStore.databaseFileName
    ) throws -> PhotoLibraryCatalogManifestStore {
        try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: tempDir.appendingPathComponent(file)))
    }

    private func entry(_ id: String) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogEntry(
            localIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 100),
            modificationDate: Date(timeIntervalSince1970: 200),
            pixelWidth: 10,
            pixelHeight: 10,
            durationSeconds: 0,
            mediaKind: .image,
            isLivePhoto: false,
            resources: [
                .init(role: "originalPhoto", originalFilename: "\(id).jpg", mimeType: "image/jpeg")
            ],
            contentFingerprint: 0,
            metadataRevision: 10,
            firstSeenAt: Date(),
            lastSeenAt: Date())
    }

    /// The store's own connection, as the pending store tests reach it (#982).
    private func catalogConnection() throws -> SQLiteStoreConnection {
        try XCTUnwrap(
            Mirror(reflecting: store!).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
    }

    func testEveryOptionalReaderReportsItsOwnFailedStatementAsUnknown() throws {
        let readers: [(String, (PhotoLibraryCatalogManifestStore) -> Bool)] = [
            ("SELECT cloud_id, creation_date", { $0.presentEntries(for: ["known"]) == nil }),
            ("SELECT local_id, cloud_id", { $0.presentEntries(afterLocalIdentifier: nil, limit: 10) == nil }),
            ("SELECT is_removed, COUNT(*)", { $0.snapshot() == nil }),
            ("SELECT COUNT(*) FROM photo_catalog", { $0.count() == nil }),
            ("SELECT COUNT(*) FROM photo_full_scan_snapshot", { $0.fullScanSnapshotCount() == nil }),
        ]
        for (index, reader) in readers.enumerated() {
            for interruptStep in [false, true] {
                store = try makeStore(file: "unknown-\(index)-\(interruptStep).sqlite")
                XCTAssertTrue(store!.upsertBatch([entry("known")]))
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

    func testLegacyEntryReadsHealthyRowsAfterAnUnrelatedDecodeFailure() throws {
        try assertLegacyCatalogRead { XCTAssertEqual(try $0.entry(for: "known")?.localIdentifier, "known") }
    }

    func testLegacyPresenceReadsHealthyRowsAfterAnUnrelatedDecodeFailure() throws {
        try assertLegacyCatalogRead {
            XCTAssertEqual($0.presentEntries(for: ["known"])?.keys.sorted(), ["known"])
        }
    }

    func testLegacyPageReadsHealthyRowsAfterAnUnrelatedDecodeFailure() throws {
        try assertLegacyCatalogRead {
            XCTAssertEqual(
                $0.presentEntries(afterLocalIdentifier: "broken", limit: 10)?.entries.map(\.localIdentifier), ["known"])
        }
    }

    func testLegacySnapshotReadsHealthySQLAfterAnUnrelatedDecodeFailure() throws {
        try assertLegacyCatalogRead { XCTAssertEqual($0.snapshot()?.total, 2) }
    }

    func testLegacyCountReadsHealthySQLAfterAnUnrelatedDecodeFailure() throws {
        try assertLegacyCatalogRead { XCTAssertEqual($0.count(), 2) }
    }

    private func assertLegacyCatalogRead(_ read: (PhotoLibraryCatalogManifestStore) throws -> Void) throws {
        store = try makeStore()
        XCTAssertTrue(store!.upsertBatch([entry("known"), entry("broken")]))
        let connection = try catalogConnection()
        try SerializedImageMutation.install(on: connection) { image in
            let range = try XCTUnwrap(image.firstRange(of: Array("\"broken.jpg\"".utf8)))
            image[range.lowerBound] = UInt8(ascii: "!")
        }
        XCTAssertThrowsError(try store!.entry(for: "broken"), "An undecodable row is unknown, not absent")
        XCTAssertNotNil(try store!.entry(for: "known"), "The requested row remains readable")
        XCTAssertTrue(store!.isOperational(), "An undecodable row no longer poisons the store")
        try read(store!)
        // Legacy readers keep answering their own successful SQL after a lasting failure, too.
        try withDeniedSQLiteSelect(in: store!) { XCTAssertNil(store!.count(), "the denied read fails") }
        XCTAssertFalse(store!.isOperational(), "The lasting failure remains sticky")
        try read(store!)
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
        let fault = try SQLiteReadInterrupt(in: store!, matching: "SELECT COUNT(*) FROM photo_catalog")
        defer { fault.stop() }
        XCTAssertNil(store!.count())
        XCTAssertTrue(fault.fired)
        XCTAssertTrue(store!.isOperational(), "the transient interrupt is forgotten once the database answers")
        XCTAssertTrue(store!.isOperational(), "and stays forgotten")
    }

    func testAnEntryReadThrowsAfterABindingFailure() throws {
        store = try makeStore()
        let connection = try catalogConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        XCTAssertThrowsError(try store!.entry(for: String(repeating: "x", count: 128)))
        XCTAssertFalse(store!.isOperational(), "The failed binding records a failed read")
    }

    func testAPresenceReadIsUnknownAfterABindingFailure() throws {
        store = try makeStore()
        let connection = try catalogConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        XCTAssertNil(store!.presentEntries(for: [String(repeating: "x", count: 128)]))
        XCTAssertFalse(store!.isOperational(), "The failed binding records a failed read")
    }

    func testAPageReadIsUnknownAfterABindingFailure() throws {
        store = try makeStore()
        let connection = try catalogConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        XCTAssertNil(store!.presentEntries(afterLocalIdentifier: String(repeating: "x", count: 128), limit: 10))
        XCTAssertFalse(store!.isOperational(), "The failed binding records a failed read")
    }

    func testAClassificationIsShorterAfterABindingFailure() throws {
        store = try makeStore()
        let connection = try catalogConnection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, 32) }
        XCTAssertEqual(store!.classifyBatch([entry(String(repeating: "x", count: 128))]), [])
        XCTAssertFalse(store!.isOperational(), "The failed binding records a failed read")
    }

    func testUnknownEntryReadsThrowInsteadOfProvingAbsence() throws {
        store = try makeStore()
        let row = entry("known")
        XCTAssertTrue(store!.upsertBatch([row]))
        let fault = try SQLiteReadInterrupt(in: store!, matching: "SELECT cloud_id, creation_date")
        XCTAssertThrowsError(try store!.entry(for: row.localIdentifier))
        XCTAssertTrue(fault.fired)
        fault.stop()
        XCTAssertTrue(store!.isOperational())
        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertThrowsError(try store!.entry(for: row.localIdentifier))
        }
        store!.close()
        XCTAssertThrowsError(try store!.entry(for: row.localIdentifier))
    }

    func testARejectedClassificationNeverSuppliesGuessedChanges() throws {
        store = try makeStore()
        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertTrue(store!.classifyBatch([entry("known"), entry("new")]).isEmpty)
        }
    }

    func testUndecodableCatalogRowsAreTheirOwnUnknownsAndLeaveTheStoreOperational() throws {
        for paged in [false, true] {
            store = try makeStore(file: "decode-\(paged).sqlite")
            XCTAssertTrue(store!.upsertBatch([entry("known")]))
            let connection = try catalogConnection()
            try SerializedImageMutation.install(on: connection) { image in
                let range = try XCTUnwrap(image.firstRange(of: Array("\"originalFilename\"".utf8)))
                image[range.lowerBound] = UInt8(ascii: "!")
            }
            if paged {
                let page = try XCTUnwrap(store!.presentEntries(afterLocalIdentifier: nil, limit: 10))
                XCTAssertEqual(
                    page.undecodableIdentifiers, ["known"],
                    "the undecodable row reports itself, not the page")
                XCTAssertTrue(page.entries.isEmpty, "no undecodable row masquerades as decoded")
            } else {
                XCTAssertNil(
                    store!.presentEntries(for: ["known"]),
                    "an unknown requested row keeps the whole answer unknown")
            }
            XCTAssertTrue(store!.isOperational(), "an undecodable row is its own unknown, not a store failure")
            store!.close()
        }
    }

    func testAppendRefusesAnUnknownSnapshotCountWithoutPersistingRows() throws {
        store = try makeStore()
        let fault = try SQLiteReadInterrupt(in: store!, matching: "SELECT COUNT(*) FROM photo_full_scan_snapshot")
        XCTAssertFalse(store!.appendFullScanSnapshotIdentifiers(["known"]))
        XCTAssertTrue(fault.fired)
        fault.stop()
        XCTAssertTrue(store!.isOperational())
        XCTAssertEqual(store!.fullScanSnapshotCount(), 0)
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
                PhotoLibraryCatalogManifestStore(
                    url: directory.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
            defer { store.close() }

            let entry = self.entry("transient-\(code)")
            WriteFaultVFS.arm(code)
            XCTAssertFalse(store.upsertBatch([entry]), "the refused write (code \(code)) persists nothing")

            WriteFaultVFS.arm(nil)
            XCTAssertTrue(store.isOperational(), "code \(code): the store answers again without a reopen")
            XCTAssertTrue(store.upsertBatch([entry]), "code \(code): the same instance persists the entry")

            XCTAssertEqual(
                store.presentEntries(for: [entry.localIdentifier])?.keys.sorted(),
                [entry.localIdentifier],
                "code \(code): the recovered write is readable")
            XCTAssertEqual(store.count(), 1, "code \(code): the count read answers again")
            WriteFaultVFS.unregister()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Another connection holds the write lock, as a busy database does; once it lets go, the store works again.
    func testABusyLockOnAnotherConnectionStopsTheStoreOnlyUntilTheLockClears() throws {
        store = try makeStore()
        let entry = self.entry("busy")
        XCTAssertTrue(store!.upsertBatch([entry]))

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName).path,
                &handle, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK)
        let blocker = try XCTUnwrap(handle)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)

        XCTAssertFalse(store!.upsertBatch([self.entry("blocked")]), "the busy write persists nothing")
        XCTAssertEqual(
            store!.presentEntries(for: [entry.localIdentifier])?.keys.sorted(), [entry.localIdentifier],
            "a transient failure does not stop the presence read")
        XCTAssertEqual(store!.count(), 1, "the busy database still answers the count read")

        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(store!.isOperational(), "the database answers again")
        XCTAssertTrue(store!.upsertBatch([self.entry("after-clearing")]))
    }

    /// A progress handler that interrupts every statement, as a timeout or cancellation does; once it is gone, the
    /// store works again.
    func testAnInterruptStopsTheStoreOnlyUntilTheInterruptClears() throws {
        store = try makeStore()
        let connection = try catalogConnection()

        connection.withLock { sqlite3_progress_handler(connection.database, 1, { _ in 1 }, nil) }
        XCTAssertFalse(store!.upsertBatch([self.entry("interrupted")]), "the interrupted write persists nothing")
        XCTAssertNil(store!.snapshot(), "the interrupted snapshot answers unknown, not a number")
        XCTAssertNil(store!.count(), "the interrupted count answers unknown, not zero")

        connection.withLock { sqlite3_progress_handler(connection.database, 0, nil, nil) }
        XCTAssertTrue(store!.isOperational(), "the store answers again")
        XCTAssertTrue(store!.upsertBatch([self.entry("after-interrupt")]))
    }

    // MARK: - Controls

    /// A COMMIT that a hook refuses writes nothing and stops the store for good, as #982 decided for the pending
    /// store; clearing the hook does not bring the instance back.
    func testARefusedCommitWritesNothingAndStopsTheStore() throws {
        store = try makeStore()
        let connection = try catalogConnection()
        let entry = self.entry("refused-commit")

        connection.withLock { _ = sqlite3_commit_hook(connection.database, { _ in 1 }, nil) }
        XCTAssertFalse(store!.upsertBatch([entry]), "the refused commit persists nothing")
        connection.withLock {
            _ = sqlite3_commit_hook(connection.database, nil, nil)
            XCTAssertNotEqual(sqlite3_get_autocommit(connection.database), 0, "no transaction stays open")
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient, "a refused commit is not a passing failure")
        }

        XCTAssertFalse(store!.isOperational(), "a refused commit is a lasting failure")
        XCTAssertNil(try store!.entry(for: entry.localIdentifier), "nothing was written")
        XCTAssertEqual(store!.snapshot()?.total, 0, "The successful legacy read confirms the rollback")
        XCTAssertEqual(store!.count(), 0)
        XCTAssertEqual(store!.presentEntries(for: [entry.localIdentifier])?.count, 0)
        XCTAssertEqual(store!.presentEntries(afterLocalIdentifier: nil, limit: 10)?.entries.count, 0)
        XCTAssertTrue(store!.upsertBatch([self.entry("later")]), "later calls answer on their own")
    }

    /// The dormant recovery probe refuses an open transaction; legacy readers retain their current behavior.
    func testAnOpenTransactionKeepsRecoveryUnavailable() throws {
        store = try makeStore()
        let entry = self.entry("half-written")
        XCTAssertTrue(store!.upsertBatch([entry]))
        let connection = try catalogConnection()

        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store!.snapshot()?.total, 1, "The legacy snapshot read still answers")
        XCTAssertEqual(store!.count(), 1, "The legacy count read still answers")
        XCTAssertEqual(store!.presentEntries(for: [entry.localIdentifier])?.keys.sorted(), [entry.localIdentifier])
        XCTAssertEqual(store!.presentEntries(afterLocalIdentifier: nil, limit: 10)?.entries.count, 1)
        XCTAssertEqual(store!.presentEntries(afterLocalIdentifier: entry.localIdentifier, limit: 10)?.entries.count, 0)
        XCTAssertFalse(store!.isOperational(), "the open transaction keeps the store stopped")

        connection.withLock {
            XCTAssertEqual(sqlite3_exec(connection.database, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(store!.snapshot()?.total, 1, "the snapshot read answers again")
        XCTAssertEqual(store!.count(), 1, "the count read answers again")
        XCTAssertEqual(
            store!.presentEntries(for: [entry.localIdentifier])?.keys.sorted(), [entry.localIdentifier],
            "the presence read answers again")
        XCTAssertEqual(
            store!.presentEntries(afterLocalIdentifier: nil, limit: 10)?.entries.map(\.localIdentifier),
            [entry.localIdentifier],
            "the paged read answers again")
        XCTAssertTrue(store!.isOperational())
        XCTAssertTrue(store!.upsertBatch([self.entry("after-rollback")]))
    }

    /// A lasting failure stays recorded, but legacy readers still report their own successful SQL results.
    func testALastingFailureKeepsRecoveryUnavailableWhileLegacyReadsContinue() throws {
        store = try makeStore()
        let entry = self.entry("lasting")
        XCTAssertTrue(store!.upsertBatch([entry]))

        try withDeniedSQLiteSelect(in: store!) {
            XCTAssertNil(store!.presentEntries(for: [entry.localIdentifier]), "the denied presence read fails")
            XCTAssertNil(store!.snapshot(), "the denied snapshot read fails")
            XCTAssertNil(store!.count(), "the denied count read fails")
            XCTAssertNil(
                store!.presentEntries(afterLocalIdentifier: nil, limit: 10),
                "the denied paged read answers unknown, not the end of the catalog")
            XCTAssertTrue(
                store!.upsertBatch([self.entry("during-denial")]),
                "a write carries no select, so it answers on its own while reads are denied")
        }

        XCTAssertFalse(store!.isOperational(), "a lasting failure stays recorded")
        XCTAssertEqual(store!.presentEntries(for: [entry.localIdentifier])?.keys.sorted(), [entry.localIdentifier])
        XCTAssertEqual(store!.count(), 2, "The legacy count still answers its own successful SQL")
        XCTAssertEqual(store!.presentEntries(afterLocalIdentifier: nil, limit: 10)?.entries.count, 2)
        XCTAssertTrue(store!.upsertBatch([self.entry("after-denial")]), "later calls answer on their own")
        XCTAssertEqual(store!.presentEntries(for: ["after-denial"])?.keys.sorted(), ["after-denial"])

        store = nil
        let reopened = try makeStore()
        XCTAssertTrue(reopened.isOperational(), "a reopen answers again")
        XCTAssertEqual(reopened.count(), 3, "persisted work survives the reopen")
        XCTAssertEqual(
            reopened.presentEntries(for: [entry.localIdentifier, "after-denial", "during-denial"])?.keys.sorted(),
            ["after-denial", "during-denial", entry.localIdentifier].sorted(),
            "persisted work survives the reopen")
        reopened.close()
    }

    /// A classify step that fails with SQLITE_INTERRUPT records its own transient code: the store answers again
    /// once the database does, and the short answer keeps the caller's completeness check honest (#1004, F5).
    func testATransientClassifyFailureStaysTransientUntilTheDatabaseAnswers() throws {
        store = try makeStore()
        let existing = self.entry("transient-classify")
        // A keyed lookup on a populated index reliably runs more than the progress period's virtual-machine
        // steps, so the first classify step hits the interrupt instead of completing.
        var population = [existing]
        for index in 0..<50 {
            population.append(self.entry("filler-\(index)"))
        }
        XCTAssertTrue(store!.upsertBatch(population))
        let connection = try catalogConnection()

        // A progress handler that interrupts real work only: the keyed classify lookup still prepares, but its
        // step answers SQLITE_INTERRUPT, a transient code, at the classify step's own recording site.
        connection.withLock { sqlite3_progress_handler(connection.database, 10, { _ in 1 }, nil) }
        let interrupted = store!.classifyBatch([existing, self.entry("interrupted-new")])
        connection.withLock { sqlite3_progress_handler(connection.database, 0, nil, nil) }

        XCTAssertTrue(interrupted.isEmpty, "the interrupted classification answers nothing, never guessed changes")
        connection.withLock {
            XCTAssertTrue(connection.operationFailed)
            XCTAssertTrue(connection.failuresAreTransient, "the interrupt records as a transient failure")
        }
        XCTAssertTrue(store!.isOperational(), "the probe clears the transient classify failure")
        XCTAssertEqual(
            store!.classifyBatch([existing, self.entry("recovered-new")]),
            [.unchanged, .inserted],
            "the same instance classifies again once the database answers")
    }

    /// A lasting classify failure keeps recovery unavailable. The specific failed keyed read stays unknown.
    /// The schema probe still passes, and it must not clear the failure (#1004, F5).
    func testALastingClassifyFailureKeepsRecoveryUnavailable() throws {
        store = try makeStore()
        let existing = self.entry("lasting-classify")
        XCTAssertTrue(store!.upsertBatch([existing]))
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        let connection = try catalogConnection()

        // Swap a mutated image into the still-open store connection: an external write to the file stays invisible
        // to the open connection's page cache. Zeroing the primary-key index root keeps the classify prepare and
        // the health probe answering, so only the keyed step answers SQLITE_CORRUPT, a lasting code, at the
        // classify step's own recording site.
        _ = try SerializedImageMutation.zeroIndexRootPage(
            on: connection, indexName: "sqlite_autoindex_photo_catalog_1")
        _ = url  // the file stays untouched; only the connection's in-memory image is broken

        let corrupted = store!.classifyBatch([existing, self.entry("never-classified")])
        XCTAssertTrue(corrupted.isEmpty, "the shorter answer signals the incomplete classification")
        connection.withLock {
            XCTAssertTrue(connection.operationFailed)
            XCTAssertFalse(connection.failuresAreTransient, "the corrupt step code records as lasting")
        }
        XCTAssertFalse(store!.isOperational(), "the corrupted database keeps the catalog stopped")
        XCTAssertEqual(store!.count(), 1, "The legacy scalar read still answers")
        XCTAssertNil(
            store!.presentEntries(for: [existing.localIdentifier]),
            "the lasting classify failure stops the presence read")
        XCTAssertEqual(store!.snapshot()?.total, 1, "The legacy snapshot read still answers")

        // The row is still persisted in the file; only the store's swapped-in image hides it. A raw read-only
        // handle on the untouched file proves it, and distinguishes the stopped store from an emptied catalog.
        var raw: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READONLY, nil), SQLITE_OK,
            "the untouched file still opens")
        let handle = try XCTUnwrap(raw)
        defer { sqlite3_close(handle) }
        var countStmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM photo_catalog;", -1, &countStmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(countStmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(countStmt, 0), 1, "the row is still persisted in the file")
        sqlite3_finalize(countStmt)
    }
}
