import Foundation
import SQLite3
import XCTest

@testable import PhotosCore

final class TimelineMIMEEvidenceReadTests: XCTestCase {
    @MainActor
    func testFailedEvidencePreparationKeepsKnownOrderCacheClassifications() async throws {
        try await assertFailedReadKeepsKnownClassifications(.preparation, useOrderCache: true)
    }

    @MainActor
    func testPartialEvidenceReadKeepsKnownOrderCacheClassifications() async throws {
        try await assertFailedReadKeepsKnownClassifications(.partial, useOrderCache: true)
    }

    @MainActor
    func testFailedEvidencePreparationKeepsKnownMIMEFallbackClassifications() async throws {
        try await assertFailedReadKeepsKnownClassifications(.preparation, useOrderCache: false)
    }

    @MainActor
    func testPartialEvidenceReadKeepsKnownMIMEFallbackClassifications() async throws {
        try await assertFailedReadKeepsKnownClassifications(.partial, useOrderCache: false)
    }

    @MainActor
    func testSuccessfulEvidenceRefreshAddsWithoutRemovingKnownClassifications() async throws {
        for useOrderCache in [true, false] {
            let fixture = try fixture()
            defer {
                fixture.timeline.close()
                fixture.order.close()
            }
            let items = fixture.items
            XCTAssertTrue(fixture.timeline.recordMediaTypeEvidence([items[1].uid: "image/jpeg"]).succeeded)
            let inventory = TimelineMetadataReconciliation.Inventory(
                items: items, classifiedNodeIDs: [items[0].uid.nodeID], libraryID: "volume")
            let reader = TimelineMetadataPageReader(
                inventory: inventory, orderStore: useOrderCache ? fixture.order : nil, timelineStore: fixture.timeline)
            try await reader.prepare(isCurrent: { true })
            XCTAssertEqual(reader.useOrderCache, useOrderCache)
            let requests = try await requestedUIDs(reader)
            XCTAssertEqual(requests, [items[2].uid], "a successful refresh must add to the queued known set")
        }
    }

    @MainActor
    func testCompleteEmptyEvidenceReadIsSuccessfulAndKeepsKnownClassifications() async throws {
        for useOrderCache in [true, false] {
            let fixture = try fixture()
            defer {
                fixture.timeline.close()
                fixture.order.close()
            }
            XCTAssertEqual(fixture.timeline.mediaTypeEvidence(volumeID: "volume"), [:])
            let reader = reader(fixture, useOrderCache: useOrderCache)
            try await reader.prepare(isCurrent: { true })
            let requests = try await requestedUIDs(reader)
            XCTAssertEqual(requests, [fixture.items[2].uid])
        }
    }

    @MainActor
    func testMeasureFiftyThousandPhotoEvidenceRefresh() async throws {
        guard ProcessInfo.processInfo.environment["TIMELINE_MIME_EVIDENCE_MEASURE"] == "1" else {
            throw XCTSkip("Set TIMELINE_MIME_EVIDENCE_MEASURE=1 for the 50,000-photo timing")
        }
        let fixture = try fixture(count: 50_000)
        defer {
            fixture.timeline.close()
            fixture.order.close()
        }
        let inventory = TimelineMetadataReconciliation.Inventory(
            items: fixture.items, classifiedNodeIDs: Set(fixture.items.map { $0.uid.nodeID }), libraryID: "volume")
        XCTAssertTrue(
            fixture.timeline.recordMediaTypeEvidence(
                Dictionary(uniqueKeysWithValues: fixture.items.map { ($0.uid, "image/jpeg") }),
                publishRevision: false
            ).succeeded)
        var samples: [Double] = []
        for _ in 0..<5 {
            let reader = TimelineMetadataPageReader(
                inventory: inventory, orderStore: nil, timelineStore: fixture.timeline)
            let start = Date()
            try await reader.prepare(isCurrent: { true })
            samples.append(Date().timeIntervalSince(start) * 1000)
            let page = try await reader.nextPage(isCurrent: { true })
            XCTAssertTrue(page.isEmpty, "known classifications must not produce metadata requests")
        }
        print("50,000-photo evidence refresh milliseconds: \(samples); median: \(samples.sorted()[2])")
    }

    private enum ReadFailure { case preparation, partial }

    @MainActor
    private func assertFailedReadKeepsKnownClassifications(
        _ failure: ReadFailure, useOrderCache: Bool
    ) async throws {
        let fixture = try fixture()
        defer {
            fixture.timeline.close()
            fixture.order.close()
        }
        XCTAssertTrue(
            fixture.timeline.recordMediaTypeEvidence([
                fixture.items[0].uid: "image/jpeg", fixture.items[1].uid: "video/mp4",
            ]).succeeded)
        try installReadFailure(failure, at: fixture.url)
        // Step an unaffected query on this connection so SQLite refreshes its cached schema.
        // Otherwise prepare can succeed with the old schema and fail only on the first step.
        XCTAssertTrue(try fixture.timeline.load().isEmpty)
        XCTAssertNil(fixture.timeline.mediaTypeEvidence(volumeID: "volume"), "an incomplete read must report failure")
        let reader = reader(fixture, useOrderCache: useOrderCache)
        try await reader.prepare(isCurrent: { true })
        XCTAssertEqual(reader.useOrderCache, useOrderCache)
        let requests = try await requestedUIDs(reader)
        XCTAssertEqual(requests.count, 1, "failed evidence refresh must not repeat completed metadata requests")
        XCTAssertEqual(requests, [fixture.items[2].uid], "only the new photo needs a MIME request")
        if useOrderCache {
            XCTAssertEqual(try fixture.order.nextPage().map(\.uid), [fixture.items[2].uid])
        }
    }

    @MainActor
    private func requestedUIDs(_ reader: TimelineMetadataPageReader) async throws -> [PhotoUID] {
        var result: [PhotoUID] = []
        // Bound calls so a paging regression fails instead of hanging.
        for _ in 0..<4 {
            let page = try await reader.nextPage(isCurrent: { true })
            if page.isEmpty { return result }
            XCTAssertTrue(page.allSatisfy { !$0.needsOrder }, "unique capture seconds need only MIME checks")
            result += page.map(\.uid)
        }
        XCTFail("metadata paging did not finish")
        return result
    }

    @MainActor
    private func reader(_ fixture: Fixture, useOrderCache: Bool) -> TimelineMetadataPageReader {
        TimelineMetadataPageReader(
            inventory: .init(
                items: fixture.items, classifiedNodeIDs: Set(fixture.items.prefix(2).map { $0.uid.nodeID }),
                libraryID: "volume"),
            orderStore: useOrderCache ? fixture.order : nil, timelineStore: fixture.timeline)
    }

    private struct Fixture {
        let items: [PhotoItem]
        let timeline: TimelineMetadataStore
        let order: TimelineOrderMetadataStore
        let url: URL
    }

    @MainActor
    private func fixture(count: Int = 3) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let timeline = try XCTUnwrap(TimelineMetadataStore(url: url))
        let order = try XCTUnwrap(TimelineOrderMetadataStore(url: directory.appendingPathComponent("order.sqlite")))
        let items = (0..<count).map {
            PhotoItem(
                uid: PhotoUID(volumeID: "volume", nodeID: String(format: "%04d", $0)),
                captureTime: Date(timeIntervalSince1970: Double(500 + $0)), mediaType: "image/jpeg")
        }
        return Fixture(items: items, timeline: timeline, order: order, url: url)
    }

    private func installReadFailure(_ failure: ReadFailure, at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql: String
        switch failure {
        case .preparation:
            sql = "ALTER TABLE media_type_evidence RENAME TO fixture_evidence;"
        case .partial:
            // abs(Int64.min) produces a native step error after the first readable row.
            sql = """
                ALTER TABLE media_type_evidence RENAME TO fixture_evidence;
                CREATE VIEW media_type_evidence AS
                SELECT vol, node,
                       CASE WHEN node='0001' THEN abs(-9223372036854775808) ELSE mime END AS mime
                FROM fixture_evidence;
                """
        }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(
            handle, "SELECT node, mime FROM media_type_evidence WHERE vol='volume';", -1, &statement, nil)
        switch failure {
        case .preparation:
            XCTAssertEqual(prepared, SQLITE_ERROR)
        case .partial:
            XCTAssertEqual(prepared, SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))), "0000")
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ERROR, "the fixture must fail after returning a row")
        }
    }
}
