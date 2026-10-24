import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineMetadataAuxiliaryReadFailureTests: TimelineMetadataReadFixture {
    func testFailedTagPreparationDiscardsCacheWithAReadableToken() throws {
        try assertRejectedRead(table: "photo_tags", projection: nil)
    }

    func testPartialTagReadDiscardsCacheWithAReadableToken() throws {
        try assertRejectedRead(
            table: "photo_tags",
            projection: "vol, node, CASE WHEN node='second' THEN abs(-9223372036854775808) ELSE tag END AS tag")
    }

    func testUnknownTagNumberDiscardsCacheWithAReadableToken() throws {
        try assertUnmappableTagRow("99")
    }

    func testTagNumberBeyondThirtyTwoBitsDiscardsCacheWithAReadableToken() throws {
        // The low 32 bits of this number are 0, the Favorites tag.
        try assertUnmappableTagRow("4294967296")
    }

    func testTextTagDiscardsCacheWithAReadableToken() throws {
        try assertUnmappableTagRow("'x'")
    }

    private func assertUnmappableTagRow(_ tagLiteral: String) throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        try execute(
            "INSERT INTO photo_tags(vol, node, tag) VALUES('volume', 'second', \(tagLiteral));", at: fixture.url)
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
        XCTAssertThrowsError(try fixture.store.load(), "A tag row that cannot be mapped is an incomplete read")
        XCTAssertThrowsError(try fixture.store.cachedTimelineSnapshot(), "No token may authorize a dropped tag")
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
    }

    func testFailedSeriesPreparationDiscardsCacheWithAReadableToken() throws {
        try assertRejectedRead(table: "burst_members", projection: nil)
    }

    func testPartialSeriesReadDiscardsCacheWithAReadableToken() throws {
        try assertRejectedRead(
            table: "burst_members",
            projection:
                "anchor_vol, anchor_node, seq, CASE WHEN anchor_node='second' THEN abs(-9223372036854775808) ELSE member_node END AS member_node"
        )
    }

    func testUnreadableTagIdentityDiscardsCacheWithAReadableToken() throws {
        try assertRejectedRead(table: "photo_tags", projection: "NULL AS vol, node, tag", partial: false)
    }

    func testUnreadableSeriesIdentityDiscardsCacheWithAReadableToken() throws {
        try assertRejectedRead(
            table: "burst_members", projection: "anchor_vol, anchor_node, seq, NULL AS member_node", partial: false)
    }

    private func assertRejectedRead(table: String, projection: String?, partial: Bool = true) throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        var sql = "ALTER TABLE \(table) RENAME TO fixture_rows;"
        if let projection { sql += "CREATE VIEW \(table) AS SELECT \(projection) FROM fixture_rows;" }
        try execute(sql, at: fixture.url)
        if projection != nil, partial {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(fixture.url.path, &handle), SQLITE_OK)
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT * FROM \(table);", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ERROR)
        }
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
        XCTAssertThrowsError(try fixture.store.load(), "Incomplete \(table) must report failure")
        XCTAssertThrowsError(try fixture.store.cachedTimelineSnapshot(), "No token may authorize an incomplete cache")
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
    }
}
