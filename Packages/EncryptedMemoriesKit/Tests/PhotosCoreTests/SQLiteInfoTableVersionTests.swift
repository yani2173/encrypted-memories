import SQLite3
import XCTest

@testable import PhotosCore

final class SQLiteInfoTableVersionTests: XCTestCase {
    private var db: OpaquePointer?

    override func setUp() {
        super.setUp()
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
    }

    override func tearDown() {
        sqlite3_close(db)
        db = nil
        super.tearDown()
    }

    func testVerifyAcceptsOnlyTheStampedVersion() {
        let row = SQLiteInfoTableVersion(table: "store_info", version: 3, stampReplacesExistingRow: true)
        XCTAssertFalse(row.verify(db), "a missing table is not the current version")
        createTable()
        XCTAssertFalse(row.verify(db), "a missing row is not the current version")

        XCTAssertTrue(row.stamp(db))
        XCTAssertTrue(row.verify(db))
        XCTAssertFalse(
            SQLiteInfoTableVersion(table: "store_info", version: 2, stampReplacesExistingRow: true).verify(db))
        XCTAssertFalse(
            SQLiteInfoTableVersion(table: "store_info", version: 4, stampReplacesExistingRow: true).verify(db),
            "a newer version is refused")
        XCTAssertFalse(
            SQLiteInfoTableVersion(table: "other_info", version: 3, stampReplacesExistingRow: true).verify(db))
    }

    func testAReplacingStampOverwritesTheRow() {
        createTable()
        XCTAssertTrue(SQLiteInfoTableVersion(table: "store_info", version: 3, stampReplacesExistingRow: true).stamp(db))
        XCTAssertTrue(SQLiteInfoTableVersion(table: "store_info", version: 4, stampReplacesExistingRow: true).stamp(db))
        XCTAssertEqual(storedVersions(), [4])
    }

    func testAPlainStampFailsOnAnExistingRowAndKeepsIt() {
        createTable()
        let row = SQLiteInfoTableVersion(table: "store_info", version: 3, stampReplacesExistingRow: false)
        XCTAssertTrue(row.stamp(db))
        XCTAssertFalse(
            SQLiteInfoTableVersion(table: "store_info", version: 4, stampReplacesExistingRow: false).stamp(db),
            "a second plain stamp fails")
        XCTAssertEqual(storedVersions(), [3], "the existing row is unchanged")
        XCTAssertTrue(row.verify(db))
    }

    private func createTable() {
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE store_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);", nil, nil, nil),
            SQLITE_OK)
    }

    private func storedVersions() -> [Int] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM store_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        var values: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW { values.append(Int(sqlite3_column_int(stmt, 0))) }
        return values
    }
}
