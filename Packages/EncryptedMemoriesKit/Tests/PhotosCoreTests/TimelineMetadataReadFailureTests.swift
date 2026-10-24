import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineMetadataReadFailureTests: TimelineMetadataReadFixture {
    func testFailedPreparationDoesNotReturnZeroWithAReadableToken() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        try execute("ALTER TABLE photos RENAME TO fixture_photos;", at: fixture.url)
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
        XCTAssertThrowsError(try fixture.store.load(), "A failed query cannot prove zero known photos")
        XCTAssertThrowsError(try fixture.store.cachedTimelineSnapshot())
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
    }

    func testFailedStepDoesNotReturnPartialPhotosWithAReadableToken() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        try execute(
            """
            ALTER TABLE photos RENAME TO fixture_photos;
            CREATE VIEW photos AS SELECT vol, node, t,
                CASE WHEN node='second' THEN abs(-9223372036854775808) ELSE mime END AS mime,
                live, relvid, dur FROM fixture_photos;
            """, at: fixture.url)
        try assertPartialReadFails(at: fixture.url)
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
        XCTAssertThrowsError(try fixture.store.load(), "A partial query cannot authorize the cached inventory")
        XCTAssertThrowsError(try fixture.store.cachedTimelineSnapshot())
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
    }

    func testMissingPhotoIdentityCannotReturnACompleteInventory() throws {
        let fixture = try makeFixture()
        defer { fixture.store.close() }
        try execute(
            """
            ALTER TABLE photos RENAME TO fixture_photos;
            CREATE VIEW photos AS SELECT NULL AS vol, node, t, mime, live, relvid, dur FROM fixture_photos;
            """, at: fixture.url)
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
        XCTAssertThrowsError(try fixture.store.load(), "Skipping unreadable identities cannot prove zero photos")
        XCTAssertThrowsError(try fixture.store.cachedTimelineSnapshot())
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
    }

    func testSuccessfulEmptyReadRetainsItsReadableToken() throws {
        let fixture = try makeFixture(items: [])
        defer { fixture.store.close() }
        XCTAssertEqual(try fixture.store.load(), [])
        let snapshot = try XCTUnwrap(fixture.store.cachedTimelineSnapshot())
        XCTAssertTrue(snapshot.sections.isEmpty)
        XCTAssertEqual(snapshot.validationToken, "matching-token")
        XCTAssertEqual(fixture.store.validationToken(), "matching-token")
    }
}

class TimelineMetadataReadFixture: XCTestCase {
    struct Fixture {
        let store: TimelineMetadataStore
        let url: URL
    }

    func makeFixture(items: [PhotoItem]? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try XCTUnwrap(TimelineMetadataStore(url: url))
        let photos =
            items
            ?? ["first", "second"].enumerated().map { index, node in
                PhotoItem(
                    uid: PhotoUID(volumeID: "volume", nodeID: node),
                    captureTime: Date(timeIntervalSince1970: Double(index)), mediaType: "image/jpeg",
                    tags: [.favorites], burstMemberIDs: ["member"])
            }
        XCTAssertTrue(store.save(photos, validationToken: "matching-token").succeeded)
        return Fixture(store: store, url: url)
    }

    func execute(_ sql: String, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func assertPartialReadFails(at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle, "SELECT vol, node, t, mime, live, relvid, dur FROM photos ORDER BY t, vol, node;",
                -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 1))), "first")
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ERROR)
    }
}
