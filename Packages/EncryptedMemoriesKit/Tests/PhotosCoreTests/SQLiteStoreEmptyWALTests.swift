import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class SQLiteStoreEmptyWALTests: XCTestCase {
    private let schema = "CREATE TABLE marker(value INTEGER NOT NULL);"

    func testEmptyWALHeaderOpensAndReopensThroughBothStorePolicies() throws {
        for rebuildable in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try interruptedWAL(in: root)
            XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_CANTOPEN)
            XCTAssertEqual(
                SQLiteStoreSchemaGate.compatibility(at: url, schemaSQL: schema, versionIsCurrent: verifyVersion),
                .empty)
            let first = try XCTUnwrap(open(at: url, rebuildable: rebuildable))
            XCTAssertTrue(verifyVersion(first))
            XCTAssertEqual(sqlite3_exec(first, "INSERT INTO marker VALUES(42);", nil, nil, nil), SQLITE_OK)
            sqlite3_close(first)
            let reopened = try XCTUnwrap(open(at: url, rebuildable: rebuildable))
            defer { sqlite3_close(reopened) }
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(reopened, "SELECT value FROM marker;", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 42)
        }
    }

    func testEmptyWALHeaderWithInterruptedJournalOpens() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try interruptedWAL(in: root)
        // SQLite recognizes a nonzero journal header as requiring recovery before reading the schema.
        try Data([0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7] + [UInt8](repeating: 0, count: 504))
            .write(to: URL(fileURLWithPath: url.path + "-journal"))
        XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_READONLY)
        let before = try files(at: url)
        XCTAssertEqual(
            SQLiteStoreSchemaGate.compatibility(at: url, schemaSQL: schema, versionIsCurrent: verifyVersion), .empty)
        XCTAssertEqual(try files(at: url), before, "inspection must recover only its temporary copy")
        let handle = try XCTUnwrap(open(at: url))
        XCTAssertTrue(verifyVersion(handle))
        sqlite3_close(handle)
    }

    func testAnySchemaObjectWithoutWALFailsClosedAndPreservesFiles() throws {
        for sql in [
            schema,
            schema + " INSERT INTO marker VALUES(42);",
            "CREATE VIEW marker AS SELECT 42;",
            "CREATE TABLE removed(id INTEGER PRIMARY KEY AUTOINCREMENT); DROP TABLE removed;",
        ] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = try interruptedWAL(in: root, schemaSQL: sql)
            XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_CANTOPEN)
            try assertUnavailableAndUnchanged(at: url)
        }
    }

    func testPopulatedHotJournalFailsClosedAndPreservesDatabaseAndJournal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(
            sqlite3_exec(
                writer,
                "CREATE TABLE receipt(value BLOB); INSERT INTO receipt VALUES(zeroblob(10000)); "
                    + "PRAGMA cache_size=1; BEGIN IMMEDIATE; UPDATE receipt SET value=zeroblob(12000);",
                nil, nil, nil), SQLITE_OK)
        // Spill uncommitted pages so the copied journal needs real rollback recovery.
        for _ in 0..<10 {
            XCTAssertEqual(
                sqlite3_exec(writer, "INSERT INTO receipt VALUES(zeroblob(10000));", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_db_cacheflush(writer), SQLITE_OK)
        let url = root.appendingPathComponent("interrupted.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let journal = URL(fileURLWithPath: url.path + "-journal")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.path + "-journal"), to: journal)
        XCTAssertEqual(
            Array(try Data(contentsOf: journal).prefix(8)), [0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7])
        XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_READONLY)
        try assertUnavailableAndUnchanged(at: url)
        // The counterprobe really needs recovery and contains a committed receipt afterward.
        var recovered: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &recovered), SQLITE_OK)
        defer { sqlite3_close(recovered) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(recovered, "SELECT COUNT(*) FROM receipt;", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testSchemaOnlyInWALFailsClosedAndPreservesAllSidecars() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        let emptyMainFile = try Data(contentsOf: source)
        XCTAssertEqual(sqlite3_exec(writer, schema + " INSERT INTO marker VALUES(42);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try Data(contentsOf: source), emptyMainFile, "the schema must exist only in the WAL")
        let url = root.appendingPathComponent("interrupted.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: source.path + suffix), to: URL(fileURLWithPath: url.path + suffix))
        }
        try Data([0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7] + [UInt8](repeating: 0, count: 504))
            .write(to: URL(fileURLWithPath: url.path + "-journal"))
        XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_READONLY)
        try assertUnavailableAndUnchanged(at: url)
    }

    func testNonzeroVersionWithoutSchemaFailsClosedAndPreservesFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try interruptedWAL(in: root, schemaSQL: "PRAGMA user_version=99;")
        XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_CANTOPEN)
        try assertUnavailableAndUnchanged(at: url)
    }

    func testUnreadableDatabaseFailsClosedAndPreservesFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("unreadable.sqlite")
        try Data("not a SQLite database".utf8).write(to: url)
        XCTAssertEqual(readOnlySchemaResult(at: url), SQLITE_NOTADB)
        try assertUnavailableAndUnchanged(at: url)
    }

    private func assertUnavailableAndUnchanged(at url: URL) throws {
        let before = try files(at: url)
        XCTAssertEqual(
            SQLiteStoreSchemaGate.compatibility(at: url, schemaSQL: schema, versionIsCurrent: verifyVersion),
            .unavailable)
        for rebuildable in [false, true] {
            let handle = open(at: url, rebuildable: rebuildable)
            XCTAssertNil(handle)
            sqlite3_close(handle)
            XCTAssertEqual(try files(at: url), before, "no database or journal may change on a rejected open")
        }
    }

    private func open(at url: URL, rebuildable: Bool = false) -> OpaquePointer? {
        if rebuildable {
            return SQLiteStoreSchemaGate.openRebuildableStore(
                at: url, schemaSQL: schema, policy: .conservative,
                verifyVersion: verifyVersion,
                stampVersion: { sqlite3_exec($0, "PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK })
        }
        return SQLiteStoreSchemaGate.openCurrentStore(
            at: url, schemaSQL: schema, policy: .conservative,
            verifyVersion: verifyVersion,
            stampVersion: { sqlite3_exec($0, "PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK })
    }

    private func verifyVersion(_ db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyWAL-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func interruptedWAL(in root: URL, schemaSQL: String = "") throws -> URL {
        let source = root.appendingPathComponent("source.sqlite")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        if !schemaSQL.isEmpty {
            XCTAssertEqual(sqlite3_exec(writer, schemaSQL, nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        // Capture before closing the connection, without opening or checkpointing the copied database.
        let url = root.appendingPathComponent("interrupted.sqlite")
        try FileManager.default.copyItem(at: source, to: url)
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 19)
        XCTAssertEqual(Array(bytes[18...19]), [2, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
        return url
    }

    private func readOnlySchemaResult(at url: URL) -> Int32 {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { sqlite3_close(handle) }
        guard result == SQLITE_OK else { return result }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_schema;", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else { return prepared }
        let stepped = sqlite3_step(statement)
        return stepped == SQLITE_ROW || stepped == SQLITE_DONE ? SQLITE_OK : stepped
    }

    private func files(at url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { result[suffix] = try Data(contentsOf: file) }
        }
        return result
    }
}
