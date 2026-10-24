import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class SQLiteFailureTests: XCTestCase {
    private func failure(_ code: Int32, errno systemErrno: Int32 = 0) -> SQLiteFailure {
        SQLiteFailure(code: code, systemErrno: systemErrno)
    }

    private let ioerrWrite = SQLITE_IOERR | (3 << 8)
    private let ioerrShortRead = SQLITE_IOERR | (2 << 8)

    /// `volumeIsFull` answers `volume` and records whether the classifier asked.
    private func keeps(_ failure: SQLiteFailure, volume: Bool? = nil) -> (keeps: Bool, askedVolume: Bool) {
        var asked = false
        let keeps = failure.keepsFile(volumeIsFull: {
            asked = true
            return volume
        })
        return (keeps, asked)
    }

    // MARK: The table

    func testEveryFullDiskAnswerKeepsTheFileWithoutAskingTheVolume() {
        let answers: [(String, SQLiteFailure)] = [
            ("SQLITE_FULL", failure(SQLITE_FULL)),
            ("IOERR_WRITE with ENOSPC", failure(ioerrWrite, errno: ENOSPC)),
            ("IOERR_SHORT_READ with ENOSPC", failure(ioerrShortRead, errno: ENOSPC)),
            ("IOERR_SHMSIZE", failure(SQLiteFailure.shmSize)),
            ("CANTOPEN with ENOSPC", failure(SQLITE_CANTOPEN, errno: ENOSPC)),
        ]
        for (name, answer) in answers {
            let result = keeps(answer, volume: false)
            XCTAssertTrue(result.keeps, name)
            XCTAssertFalse(result.askedVolume, "\(name): the code alone decides")
        }
    }

    func testAnIOErrorThatNamesNoFullDiskDoesNotKeepTheFile() {
        // https://www.sqlite.org/rescode.html: IOERR_WRITE "should not occur if the filesystem is full".
        XCTAssertFalse(keeps(failure(ioerrWrite), volume: true).keeps, "IOERR_WRITE alone decides nothing")
        XCTAssertFalse(keeps(failure(ioerrWrite, errno: EIO), volume: true).keeps)
        XCTAssertFalse(keeps(failure(ioerrShortRead), volume: true).keeps)
        // A bare SQLITE_IOERR names no cause, so it keeps its earlier meaning, also on a full volume.
        let bare = keeps(failure(SQLITE_IOERR), volume: true)
        XCTAssertFalse(bare.keeps, "a bare IOERR decides nothing")
        XCTAssertFalse(bare.askedVolume)
    }

    func testTheMapAndOpenCodesKeepTheFileOnlyOnAFullVolume() {
        let answers: [(String, SQLiteFailure)] = [
            ("CANTOPEN, ENOENT as measured", failure(SQLITE_CANTOPEN, errno: ENOENT)),
            ("CANTOPEN, no errno", failure(SQLITE_CANTOPEN)),
            ("IOERR_SHMOPEN, ESRCH as measured", failure(SQLiteFailure.shmOpen, errno: ESRCH)),
            ("IOERR_SHMMAP", failure(SQLiteFailure.shmMap)),
        ]
        for (name, answer) in answers {
            let full = keeps(answer, volume: true)
            XCTAssertTrue(full.keeps, "\(name): a full volume keeps the file")
            XCTAssertTrue(full.askedVolume, name)
            XCTAssertFalse(keeps(answer, volume: false).keeps, "\(name): a volume with room does not")
            XCTAssertFalse(keeps(answer, volume: nil).keeps, "\(name): an unknown volume never keeps the file")
        }
    }

    func testDamageAndEveryOtherCodeNeverKeepTheFile() {
        let answers: [(String, SQLiteFailure)] = [
            ("SQLITE_CORRUPT", failure(SQLITE_CORRUPT)),
            ("SQLITE_CORRUPT_VTAB", failure(SQLITE_CORRUPT | (1 << 8))),
            ("SQLITE_CORRUPT with ENOSPC left over", failure(SQLITE_CORRUPT, errno: ENOSPC)),
            ("SQLITE_NOTADB", failure(SQLITE_NOTADB)),
            ("SQLITE_NOTADB with ENOSPC left over", failure(SQLITE_NOTADB, errno: ENOSPC)),
            ("SQLITE_BUSY", failure(SQLITE_BUSY)),
            ("SQLITE_ERROR", failure(SQLITE_ERROR)),
            ("SQLITE_INTERRUPT", failure(SQLITE_INTERRUPT)),
            ("SQLITE_OK", failure(SQLITE_OK)),
        ]
        for (name, answer) in answers {
            let result = keeps(answer, volume: true)
            XCTAssertFalse(result.keeps, "\(name): earlier meaning, also on a full volume")
            XCTAssertFalse(result.askedVolume, "\(name): the volume is not asked")
        }
    }

    // MARK: Real connections

    private func scratchFile(_ name: String = "store.sqlite") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }

    /// SQLite's own `SQLITE_FULL`, caused by a page limit instead of a full volume. The failure is read after the
    /// `sqlite3_finalize` of the failed statement, as the gate reads it.
    func testARealSQLiteFullStaysReadableAfterTheFinalize() throws {
        let url = try scratchFile()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE t(a BLOB); INSERT INTO t VALUES(zeroblob(100));", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA max_page_count=3;", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "INSERT INTO t VALUES(zeroblob(20000));", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_FULL)
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_FULL)

        let result = keeps(SQLiteFailure(of: db))
        XCTAssertTrue(result.keeps)
        XCTAssertFalse(result.askedVolume)
    }

    func testRealCorruptionIsNeverKept() throws {
        // A file that is no database: SQLITE_NOTADB.
        let notADatabase = try scratchFile()
        try Data(repeating: 0xAB, count: 4_096).write(to: notADatabase)
        // A database that lost its tail: SQLITE_CORRUPT.
        let truncated = try scratchFile()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(truncated.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "PRAGMA page_size=4096; PRAGMA journal_mode=DELETE; "
                    + "CREATE TABLE photo_order(vol TEXT, node TEXT, t REAL, PRIMARY KEY(vol,node)); "
                    + "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<3000) "
                    + "INSERT INTO photo_order SELECT 'v', 'n'||x, x FROM c;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let handle = try FileHandle(forUpdating: truncated)
        try handle.truncate(atOffset: 4_096 * 2)
        try handle.close()

        for (name, url, expected) in [
            ("not a database", notADatabase, SQLITE_NOTADB), ("truncated", truncated, SQLITE_CORRUPT),
        ] {
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK, name)
            defer { sqlite3_close(raw) }
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(raw, "PRAGMA quick_check;", -1, &statement, nil)
            let step = prepared == SQLITE_OK ? sqlite3_step(statement) : prepared
            sqlite3_finalize(statement)
            XCTAssertEqual(step & 0xFF, expected, "\(name): the fixture produces the damage code")
            XCTAssertFalse(keeps(SQLiteFailure(of: raw), volume: true).keeps, "\(name): damage stays damage")
        }
    }

    private final class Seen: @unchecked Sendable {
        var url: URL?
    }

    func testTheProbeAsksTheVolumeOfTheFileOfTheConnection() throws {
        let url = try scratchFile("seen.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let seen = Seen()
        let probe = SQLiteFailureProbe(
            failure: { _, _ in SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT) },
            volumeIsFull: { url, _ in
                seen.url = url
                return true
            })

        XCTAssertNotEqual(sqlite3_exec(db, "SELECT * FROM no_such_table;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(probe.keepsFile(after: db, step: .verification))
        XCTAssertEqual(seen.url?.lastPathComponent, "seen.sqlite")
        seen.url = nil
        XCTAssertFalse(probe.keepsFile(after: nil, step: .verification), "no connection: unknown volume")
        XCTAssertNil(seen.url)
    }

    /// The documentation calls the error code after a successful call "undefined". This pins what SQLite does: after a
    /// failed call, every kind of successful call leaves no failure on the connection for the probe to read.
    func testASuccessfulCallAfterAFailedCallLeavesNoFailureForTheProbe() throws {
        let url = try scratchFile()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(a); INSERT INTO t VALUES(1);", nil, nil, nil), SQLITE_OK)
        let asked = Asked()
        let probe = SQLiteFailureProbe(
            failure: { _, _ in
                asked.failure = true
                return SQLiteFailure(code: SQLITE_FULL, systemErrno: 0)
            },
            volumeIsFull: { _, _ in nil })
        func fail() {
            XCTAssertNotEqual(sqlite3_exec(db, "SELECT * FROM no_such_table;", nil, nil, nil), SQLITE_OK)
            XCTAssertTrue(SQLiteFailure(of: db).isError, "the failed call leaves its failure")
        }
        func assertQuiet(_ call: String) {
            XCTAssertFalse(SQLiteFailure(of: db).isError, "after a successful \(call)")
            XCTAssertFalse(probe.keepsFile(after: db, step: .inspection), "after a successful \(call)")
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT a FROM t;", -1, &statement, nil), SQLITE_OK)

        fail()
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        assertQuiet("step with ROW")
        fail()
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        assertQuiet("step with DONE")
        fail()
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK)
        assertQuiet("finalize")
        fail()
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT a FROM t;", -1, &statement, nil), SQLITE_OK)
        assertQuiet("prepare")
        sqlite3_finalize(statement)
        fail()
        XCTAssertEqual(sqlite3_exec(db, "SELECT 1;", nil, nil, nil), SQLITE_OK)
        assertQuiet("exec")
        XCTAssertFalse(asked.failure, "the answer is not asked after a call that succeeded")
    }

    /// An in-memory connection has no file, so its volume is unknown and the volume is not asked.
    func testAConnectionWithoutAFileHasNoVolume() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertNotEqual(sqlite3_exec(db, "SELECT * FROM no_such_table;", nil, nil, nil), SQLITE_OK)
        let asked = Asked()
        let probe = SQLiteFailureProbe(
            failure: { _, _ in SQLiteFailure(code: SQLITE_CANTOPEN, systemErrno: ENOENT) },
            volumeIsFull: { _, _ in
                asked.volume = true
                return true
            })

        XCTAssertFalse(probe.keepsFile(after: db, step: .copy), "an unknown volume never keeps the file")
        XCTAssertFalse(asked.volume)
    }

    private final class Asked: @unchecked Sendable {
        var failure = false
        var volume = false
        var openWhenRead = false
    }

    /// The seam answers only after a SQLite call that failed. A call that succeeded, with the result codes OK, ROW
    /// or DONE, never reaches it.
    func testTheProbeIsNotAskedAfterACallThatDidNotFail() throws {
        let url = try scratchFile()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let asked = Asked()
        let probe = SQLiteFailureProbe(
            failure: { _, _ in
                asked.failure = true
                return SQLiteFailure(code: SQLITE_FULL, systemErrno: 0)
            },
            volumeIsFull: { _, _ in
                asked.volume = true
                return true
            })

        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t(a); INSERT INTO t VALUES(1);", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(probe.keepsFile(after: db, step: .inspection), "OK")
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT a FROM t;", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertFalse(probe.keepsFile(after: db, step: .inspection), "ROW")
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        XCTAssertFalse(probe.keepsFile(after: db, step: .inspection), "DONE")
        sqlite3_finalize(statement)
        XCTAssertFalse(asked.failure, "the answer is not asked")
        XCTAssertFalse(asked.volume)
        XCTAssertNotEqual(sqlite3_exec(db, "SELECT * FROM no_such_table;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(probe.keepsFile(after: db, step: .inspection), "a failed call reaches the answer")
        XCTAssertTrue(asked.failure)
    }

    /// The closing variant reads the connection while it is still open, then closes it.
    func testTheClosingProbeReadsBeforeItCloses() throws {
        let url = try scratchFile()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertNotEqual(sqlite3_exec(db, "SELECT * FROM no_such_table;", nil, nil, nil), SQLITE_OK)
        let asked = Asked()
        let probe = SQLiteFailureProbe(
            failure: { db, _ in
                asked.openWhenRead = sqlite3_db_filename(db, "main") != nil
                return SQLiteFailure(code: SQLITE_FULL, systemErrno: 0)
            },
            volumeIsFull: { _, _ in nil })

        XCTAssertTrue(probe.keepsFile(closing: db, step: .verification))
        XCTAssertTrue(asked.openWhenRead, "the connection was open when the probe read it")
    }

    // MARK: The volume

    func testAVolumeWithFreeBlocksIsNotFullAndAMissingPathIsUnknown() throws {
        let url = try scratchFile()
        try Data([1]).write(to: url)
        XCTAssertEqual(DeviceStorage.volumeHasNoFreeBlocks(at: url), false)
        XCTAssertEqual(DeviceStorage.volumeHasNoFreeBlocks(at: url.deletingLastPathComponent()), false)
        XCTAssertNil(DeviceStorage.volumeHasNoFreeBlocks(at: url.appendingPathComponent("missing/none")))
    }
}
