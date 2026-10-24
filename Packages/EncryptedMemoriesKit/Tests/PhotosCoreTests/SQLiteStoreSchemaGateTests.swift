import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class SQLiteStoreSchemaGateTests: XCTestCase {
    func testRollbackJournalCommitsCanSynchronizeWhenWALIsUnavailable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE marker (value INTEGER);", nil, nil, nil), SQLITE_OK)
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &reader), SQLITE_OK)
        // A reader prevents the WAL transition, as on a store where WAL is unavailable.
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT * FROM marker;", nil, nil, nil), SQLITE_OK)
        SQLiteStoreSchemaGate.configureConnection(
            db, policy: LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 10))
        sqlite3_close(reader)
        XCTAssertEqual(try pragma("journal_mode", in: db), "delete")
        XCTAssertGreaterThanOrEqual(Int(try pragma("synchronous", in: db)) ?? 0, 2)
        XCTAssertEqual(try pragma("fullfsync", in: db), "1")
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO marker VALUES (1);", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(SQLiteStoreSchemaGate.checkpointCompletely(db))

        XCTAssertEqual(sqlite3_exec(db, "BEGIN; INSERT INTO marker VALUES (3);", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(db), "uncommitted rows cannot move the token")
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let before = try pragma("synchronous", in: db)
        XCTAssertEqual(
            SQLiteStoreSchemaGate.withDurableCommits(db) {
                sqlite3_exec(db, "INSERT INTO marker VALUES (2);", nil, nil, nil)
            }, SQLITE_OK)
        XCTAssertEqual(try pragma("synchronous", in: db), before)
        XCTAssertEqual(try pragma("fullfsync", in: db), "1")
        XCTAssertTrue(SQLiteStoreSchemaGate.checkpointCompletely(db))

        XCTAssertEqual(sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(db), "a non-durable commit cannot move the token")
    }

    func testSynchronizationRejectsMemoryAndMissingConnections() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA synchronous=FULL; PRAGMA fullfsync=ON;", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(db), "an in-memory database is not durable")
        XCTAssertFalse(SQLiteStoreSchemaGate.checkpointCompletely(nil))
    }

    private func pragma(_ name: String, in db: OpaquePointer?) throws -> String {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA \(name);", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    func testOpenCurrentStoreCreatesReopensAndRejectsIncompatibleFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaGate-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let schema = "CREATE TABLE marker (version INTEGER NOT NULL);"
        func verify(_ db: OpaquePointer?) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT version FROM marker;", -1, &statement, nil) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
        }
        func stamp(_ db: OpaquePointer?) -> Bool {
            sqlite3_exec(db, "INSERT INTO marker VALUES (1);", nil, nil, nil) == SQLITE_OK
        }
        let first = try XCTUnwrap(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        XCTAssertTrue(verify(first))
        sqlite3_close(first)

        let reopened = try XCTUnwrap(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        XCTAssertTrue(verify(reopened))
        XCTAssertEqual(sqlite3_exec(reopened, "UPDATE marker SET version = 2;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(reopened)

        XCTAssertNil(
            SQLiteStoreSchemaGate.openCurrentStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verify, stampVersion: stamp
            ))
        var inspection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &inspection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(inspection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(inspection, "SELECT version FROM marker;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
    }

    // MARK: Files that cannot be checked now

    private let markerSchema = "CREATE TABLE marker (version INTEGER NOT NULL);"
    private let noWaitPolicy = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 0)

    private func markerVersionIsCurrent(_ db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT version FROM marker;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    private func openMarkerStore(
        at url: URL, verifyVersion: ((OpaquePointer?) -> Bool)? = nil,
        copyItem: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
        createDirectory: ((URL) throws -> Void)? = nil,
        probe: SQLiteFailureProbe = .live
    ) -> SQLiteRebuildableStoreOutcome {
        SQLiteStoreSchemaGate.openRebuildableStoreOutcome(
            at: url, schemaSQL: markerSchema, policy: noWaitPolicy,
            verifyVersion: verifyVersion ?? markerVersionIsCurrent,
            stampVersion: { sqlite3_exec($0, "INSERT INTO marker VALUES (1);", nil, nil, nil) == SQLITE_OK },
            copyItem: copyItem, createDirectory: createDirectory, probe: probe)
    }

    private func marker(at url: URL) throws -> URL {
        guard case .opened(let handle) = openMarkerStore(at: url) else {
            XCTFail("the store opens")
            return url
        }
        sqlite3_close(handle)
        return url
    }

    /// Another connection that holds the file exclusively until `COMMIT`.
    private func exclusiveHolder(of url: URL) throws -> OpaquePointer {
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "PRAGMA locking_mode=EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
        return try XCTUnwrap(blocker)
    }

    private func release(_ blocker: OpaquePointer) {
        sqlite3_exec(blocker, "COMMIT;", nil, nil, nil)
        sqlite3_close(blocker)
    }

    private func isRetryLater(_ outcome: SQLiteRebuildableStoreOutcome) -> Bool {
        if case .retryLater = outcome { return true }
        return false
    }

    private func isFailed(_ outcome: SQLiteRebuildableStoreOutcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    func testAFileThatAnotherConnectionHoldsStaysAndOpensAgainWithItsRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try marker(at: directory.appendingPathComponent("held.sqlite"))
        let blocker = try exclusiveHolder(of: url)

        XCTAssertEqual(
            SQLiteStoreSchemaGate.compatibility(
                at: url, schemaSQL: markerSchema, busyTimeoutMs: 0, versionIsCurrent: markerVersionIsCurrent),
            .retryLater)
        XCTAssertTrue(isRetryLater(openMarkerStore(at: url)), "a held file is not replaced")
        release(blocker)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        guard case .opened(let reopened) = openMarkerStore(at: url) else { return XCTFail("the file opens again") }
        defer { sqlite3_close(reopened) }
        XCTAssertTrue(markerVersionIsCurrent(reopened), "the rows are still there")
    }

    func testALockThatStartsInTheMiddleOfTheInspectionIsNoOtherSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A rollback journal: a reader holds no lock between two statements, so a second connection can take the
        // file in the middle of the inspection. (In WAL mode an open reader keeps a second connection out.)
        let url = directory.appendingPathComponent("middle.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                raw,
                "PRAGMA journal_mode=DELETE; CREATE TABLE marker (version INTEGER NOT NULL); "
                    + "INSERT INTO marker VALUES (1);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        var blocker: OpaquePointer?

        // The schema read has finished. Now another connection takes the file, before the version read.
        let compatibility = SQLiteStoreSchemaGate.compatibility(
            at: url, schemaSQL: markerSchema, busyTimeoutMs: 0,
            versionIsCurrent: { db in
                blocker = try? self.exclusiveHolder(of: url)
                return self.markerVersionIsCurrent(db)
            })
        let held = try XCTUnwrap(blocker)
        defer { release(held) }

        XCTAssertEqual(compatibility, .retryLater, "a busy version read is not another schema")
    }

    func testALockThatStartsBeforeTheReadWriteVerificationKeepsTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try marker(at: directory.appendingPathComponent("verify.sqlite"))
        var calls = 0
        var blocker: OpaquePointer?

        // The first call is the read-only inspection. The second call verifies the read-write connection.
        let outcome = openMarkerStore(
            at: url,
            verifyVersion: { db in
                calls += 1
                if calls == 2 { blocker = try? self.exclusiveHolder(of: url) }
                return self.markerVersionIsCurrent(db)
            })
        let held = try XCTUnwrap(blocker)

        XCTAssertEqual(calls, 2)
        XCTAssertTrue(isRetryLater(outcome), "a busy verification is not another schema")
        release(held)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the file was not replaced")
        guard case .opened(let reopened) = openMarkerStore(at: url) else { return XCTFail("the file opens again") }
        defer { sqlite3_close(reopened) }
        XCTAssertTrue(markerVersionIsCurrent(reopened), "the rows are still there")
    }

    func testAFileWithAnotherSchemaIsStillReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("other.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TABLE other (x INTEGER);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        guard case .opened(let replaced) = openMarkerStore(at: url) else { return XCTFail("the file is replaced") }
        defer { sqlite3_close(replaced) }
        XCTAssertTrue(markerVersionIsCurrent(replaced))
    }

    /// A crashed writer leaves a rollback journal that only a writer can recover. The gate never writes to a populated
    /// original, so a store that holds such a file replaces it, as before.
    func testADatabaseWithAHotRollbackJournalIsStillReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        for statement in [
            "PRAGMA journal_mode=DELETE;", "PRAGMA synchronous=FULL;", "CREATE TABLE t (x BLOB);",
            "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000) "
                + "INSERT INTO t SELECT randomblob(500) FROM c;",
            "PRAGMA cache_size=2;", "PRAGMA cache_spill=1;", "BEGIN;", "UPDATE t SET x = randomblob(500);",
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

        XCTAssertEqual(
            SQLiteStoreSchemaGate.compatibility(
                at: crashed, schemaSQL: markerSchema, busyTimeoutMs: 0, versionIsCurrent: markerVersionIsCurrent),
            .unavailable, "a read-only check cannot recover the journal, and that is no lock")
        XCTAssertTrue(isFailed(openMarkerStore(at: crashed)), "the store may replace the file")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: crashed.path + "-journal"), "the check itself recovers nothing")
    }

    /// A WAL database whose shared-memory file cannot be created cannot be opened for now. It is no lock either.
    func testAWALDatabaseWithoutAWritableSharedMemoryFileIsStillReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        for statement in [
            "PRAGMA journal_mode=WAL;", "PRAGMA wal_autocheckpoint=0;", "CREATE TABLE t (x INTEGER);",
            "INSERT INTO t VALUES (1);",
        ] {
            XCTAssertEqual(sqlite3_exec(writer, statement, nil, nil, nil), SQLITE_OK, statement)
        }
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let copy = locked.appendingPathComponent("copy.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: source.path + "-wal"), to: URL(fileURLWithPath: copy.path + "-wal"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path + "-shm"), "no shared-memory file exists")

        XCTAssertEqual(
            SQLiteStoreSchemaGate.compatibility(
                at: copy, schemaSQL: markerSchema, busyTimeoutMs: 0, versionIsCurrent: markerVersionIsCurrent),
            .unavailable)
        XCTAssertTrue(isFailed(openMarkerStore(at: copy)), "the store may replace the file")
    }

    // MARK: A copy that fails

    /// Opens a file that a read-only check cannot read, so the gate falls back to the inspection of a copy.
    private func fileThatNeedsACopy(in directory: URL) throws -> URL {
        let url = try marker(at: directory.appendingPathComponent("needs-copy.sqlite"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        return url
    }

    func testACopyThatFindsNoRoomKeepsTheFileForALaterOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fileThatNeedsACopy(in: directory)
        let noRoom = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)

        XCTAssertTrue(
            isRetryLater(openMarkerStore(at: url, copyItem: { _, _ in throw noRoom })),
            "a full disk says nothing about the file")
        let posix = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(isRetryLater(openMarkerStore(at: url, copyItem: { _, _ in throw posix })), "also as POSIX ENOSPC")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the file stays")
    }

    func testAnInspectionDirectoryThatFindsNoRoomKeepsTheFileForALaterOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fileThatNeedsACopy(in: directory)
        let noRoom = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)

        XCTAssertTrue(
            isRetryLater(openMarkerStore(at: url, createDirectory: { _ in throw noRoom })),
            "a full disk says nothing about the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the file stays")

        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        XCTAssertTrue(
            isFailed(openMarkerStore(at: url, createDirectory: { _ in throw denied })),
            "another failure keeps its earlier meaning")
    }

    func testACopyThatFailsForAnotherReasonKeepsItsEarlierMeaning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fileThatNeedsACopy(in: directory)
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)

        XCTAssertTrue(
            isFailed(openMarkerStore(at: url, copyItem: { _, _ in throw denied })),
            "an unreadable file is not a full disk: the store may replace it")
    }

    // MARK: A full disk that SQLite reports itself

    private typealias Answer = (name: String, failure: SQLiteFailure, volumeIsFull: Bool?)

    /// What SQLite and the volume say when the disk is full. Each answer keeps the file. The last two answers are
    /// what Apple SQLite 3.54.0 reported on an HFS+ volume filled to zero: `errno` was `ENOENT` or `ESRCH`.
    private let fullDiskAnswers: [Answer] = [
        ("SQLITE_FULL", SQLiteFailure(code: SQLITE_FULL, systemErrno: 0), false),
        ("IOERR_WRITE with ENOSPC", SQLiteFailure(code: SQLITE_IOERR | (3 << 8), systemErrno: ENOSPC), false),
        ("IOERR_SHMSIZE", SQLiteFailure(code: SQLiteFailure.shmSize, systemErrno: 0), false),
        ("CANTOPEN with ENOSPC", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOSPC), false),
        ("CANTOPEN on a full volume", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT), true),
        ("IOERR_SHMOPEN on a full volume", SQLiteFailure(code: SQLiteFailure.shmOpen, systemErrno: ESRCH), true),
    ]

    /// What leaves the earlier meaning of the file. A damaged file stays damaged, also on a full volume.
    private let otherAnswers: [Answer] = [
        ("SQLITE_CORRUPT on a full volume", SQLiteFailure(code: SQLITE_CORRUPT, systemErrno: ENOSPC), true),
        ("SQLITE_NOTADB on a full volume", SQLiteFailure(code: SQLITE_NOTADB, systemErrno: ENOSPC), true),
        ("IOERR_WRITE alone", SQLiteFailure(code: SQLITE_IOERR | (3 << 8), systemErrno: 0), false),
        ("bare IOERR on a full volume", SQLiteFailure(code: SQLITE_IOERR, systemErrno: 0), true),
        ("CANTOPEN on a volume with room", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT), false),
        ("CANTOPEN on an unknown volume", SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT), nil),
        ("IOERR_SHMOPEN on a volume with room", SQLiteFailure(code: SQLiteFailure.shmOpen, systemErrno: ESRCH), false),
    ]

    /// Answers `answer` at `step`. Every other step reads the real connection and the real volume.
    private func probe(at step: SQLiteCheckStep, _ answer: Answer) -> SQLiteFailureProbe {
        SQLiteFailureProbe(
            failure: { db, current in current == step ? answer.failure : SQLiteFailure(of: db) },
            volumeIsFull: { url, current in
                current == step ? answer.volumeIsFull : DeviceStorage.volumeHasNoFreeBlocks(at: url)
            })
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A marker store with a second row, so a replaced file shows by its row count.
    private func markedStore(in directory: URL) throws -> URL {
        let url = try marker(at: directory.appendingPathComponent("\(UUID().uuidString).sqlite"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO marker VALUES (2);", nil, nil, nil), SQLITE_OK)
        return url
    }

    private func markerRowCount(at url: URL) -> Int32 {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM marker;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int(statement, 0)
    }

    /// A version check that fails the way a SQLite call fails, so the probe sees a real failure on the connection.
    private func failingVersionCheck(_ db: OpaquePointer?) -> Bool {
        XCTAssertNotEqual(sqlite3_exec(db, "SELECT * FROM no_such_table;", nil, nil, nil), SQLITE_OK)
        return false
    }

    private func closeIfOpened(_ outcome: SQLiteRebuildableStoreOutcome) -> Bool {
        guard case .opened(let handle) = outcome else { return false }
        sqlite3_close(handle)
        return true
    }

    /// A file that SQLite cannot read as a database (`SQLITE_NOTADB`), so the gate falls back to the copy.
    private func unreadableFile(in directory: URL) throws -> (url: URL, bytes: Data) {
        let url = directory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let bytes = Data(repeating: 0xAB, count: 4_096)
        try bytes.write(to: url)
        return (url, bytes)
    }

    func testAFullDiskAnswerInTheInspectionOfAPopulatedFileKeepsIt() throws {
        let directory = try scratchDirectory()
        for answer in fullDiskAnswers {
            let url = try markedStore(in: directory)
            let outcome = openMarkerStore(
                at: url, verifyVersion: { self.failingVersionCheck($0) }, probe: probe(at: .inspection, answer))
            XCTAssertTrue(isRetryLater(outcome), "\(answer.name): retry later")
            XCTAssertEqual(markerRowCount(at: url), 2, "\(answer.name): the file stays with its rows")
        }
        for answer in otherAnswers {
            let url = try markedStore(in: directory)
            let outcome = openMarkerStore(
                at: url, verifyVersion: { self.failingVersionCheck($0) }, probe: probe(at: .inspection, answer))
            XCTAssertTrue(closeIfOpened(outcome), "\(answer.name): another schema is replaced, as before")
            XCTAssertEqual(markerRowCount(at: url), 1, "\(answer.name): the file is replaced")
        }
    }

    func testAFullDiskAnswerInTheInspectionOfAnUnreadableFileKeepsItAndMakesNoCopy() throws {
        let directory = try scratchDirectory()
        for answer in fullDiskAnswers {
            let file = try unreadableFile(in: directory)
            var copies = 0
            let outcome = openMarkerStore(
                at: file.url,
                copyItem: {
                    copies += 1
                    try FileManager.default.copyItem(at: $0, to: $1)
                }, probe: probe(at: .inspection, answer))
            XCTAssertTrue(isRetryLater(outcome), "\(answer.name): retry later")
            XCTAssertEqual(copies, 0, "\(answer.name): a full disk needs no copy")
            XCTAssertEqual(try Data(contentsOf: file.url), file.bytes, "\(answer.name): the file stays")
        }
        for answer in otherAnswers {
            let file = try unreadableFile(in: directory)
            var copies = 0
            let outcome = openMarkerStore(
                at: file.url,
                copyItem: {
                    copies += 1
                    try FileManager.default.copyItem(at: $0, to: $1)
                }, probe: probe(at: .inspection, answer))
            XCTAssertTrue(isFailed(outcome), "\(answer.name): the earlier meaning")
            XCTAssertEqual(copies, 1, "\(answer.name): the inspection goes on with the copy")
        }
    }

    func testAFullDiskAnswerInTheInspectionOfTheCopyKeepsTheFile() throws {
        let directory = try scratchDirectory()
        for answer in fullDiskAnswers {
            let file = try unreadableFile(in: directory)
            let outcome = openMarkerStore(at: file.url, probe: probe(at: .copy, answer))
            XCTAssertTrue(isRetryLater(outcome), "\(answer.name): retry later")
            XCTAssertEqual(try Data(contentsOf: file.url), file.bytes, "\(answer.name): the file stays")
        }
        for answer in otherAnswers {
            let file = try unreadableFile(in: directory)
            let outcome = openMarkerStore(at: file.url, probe: probe(at: .copy, answer))
            XCTAssertTrue(isFailed(outcome), "\(answer.name): the earlier meaning")
        }
    }

    func testAFullDiskAnswerInTheVerificationKeepsTheFile() throws {
        let directory = try scratchDirectory()
        /// The first call is the read-only inspection, which finds the file current. The second call is the
        /// read-write verification, which fails with a failed SQLite call.
        func failingSecondCall(_ calls: inout Int, _ db: OpaquePointer?) -> Bool {
            calls += 1
            return calls == 1 ? markerVersionIsCurrent(db) : failingVersionCheck(db)
        }
        for answer in fullDiskAnswers {
            let url = try markedStore(in: directory)
            var calls = 0
            let outcome = openMarkerStore(
                at: url, verifyVersion: { failingSecondCall(&calls, $0) }, probe: probe(at: .verification, answer))
            XCTAssertTrue(isRetryLater(outcome), "\(answer.name): retry later")
            XCTAssertEqual(markerRowCount(at: url), 2, "\(answer.name): the file stays with its rows")
        }
        for answer in otherAnswers {
            let url = try markedStore(in: directory)
            var calls = 0
            let outcome = openMarkerStore(
                at: url, verifyVersion: { failingSecondCall(&calls, $0) }, probe: probe(at: .verification, answer))
            XCTAssertTrue(closeIfOpened(outcome), "\(answer.name): another schema is replaced, as before")
            XCTAssertEqual(markerRowCount(at: url), 1, "\(answer.name): the file is replaced")
        }
    }

    func testAnAnswerAboutTheDiskIsNotAskedWhenNoSQLiteCallFailed() throws {
        let directory = try scratchDirectory()
        var calls = 0
        let full = SQLiteFailure(code: SQLITE_FULL, systemErrno: 0)
        // Another schema is no failed call: the inspection finds the version wrong and no call fails.
        let populated = try markedStore(in: directory)
        let inspected = openMarkerStore(
            at: populated, verifyVersion: { _ in false }, probe: probe(at: .inspection, ("full", full, true)))
        XCTAssertTrue(closeIfOpened(inspected), "another schema is replaced")
        XCTAssertEqual(markerRowCount(at: populated), 1)
        // The same in the read-write verification.
        let verified = try markedStore(in: directory)
        let outcome = openMarkerStore(
            at: verified,
            verifyVersion: {
                calls += 1
                return calls == 1 && self.markerVersionIsCurrent($0)
            }, probe: probe(at: .verification, ("full", full, true)))
        XCTAssertTrue(closeIfOpened(outcome), "another schema is replaced")
        XCTAssertEqual(markerRowCount(at: verified), 1)
    }

    func testACantOpenAnswerKeepsTheFileOnlyWhenTheVolumeIsFull() throws {
        let directory = try scratchDirectory()
        let cantOpen = SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT)
        for (volumeIsFull, kept) in [(true, true), (false, false), (nil, false)] as [(Bool?, Bool)] {
            let url = try markedStore(in: directory)
            var calls = 0
            let outcome = openMarkerStore(
                at: url,
                verifyVersion: {
                    calls += 1
                    return calls == 1 ? self.markerVersionIsCurrent($0) : self.failingVersionCheck($0)
                }, probe: probe(at: .verification, ("CANTOPEN", cantOpen, volumeIsFull)))
            if kept {
                XCTAssertTrue(isRetryLater(outcome), "a full volume keeps the file")
                XCTAssertEqual(markerRowCount(at: url), 2)
            } else {
                XCTAssertTrue(closeIfOpened(outcome), "volume \(String(describing: volumeIsFull)): replaced")
                XCTAssertEqual(markerRowCount(at: url), 1)
            }
        }
    }
}
