import Foundation
import PhotosCore
import SQLite3
import UploadCore
import XCTest

/// Every text bind of the manual settlement store checks its result (#1194). A failed bind leaves its parameter NULL: an
/// unchecked key bind made a read report "no settlement row" for a row that exists, so the byte gate could allow a
/// second upload of committed bytes, and made a removal report success without removing anything. Each test lowers
/// SQLITE_LIMIT_LENGTH on the store's own connection and reads it back, so a queue item key (36 characters) fails its
/// bind with SQLITE_TOOBIG.
final class ManualUploadSettlementBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 32

    private var directory: URL!
    private var store: UploadManualSettlementStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("settlement-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(UploadManualSettlementStore(url: databaseURL))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent(UploadManualSettlementStore.databaseFileName) }

    private func connection() throws -> SQLiteStoreConnection {
        try XCTUnwrap(
            Mirror(reflecting: store!).children.first(where: { $0.label == "connection" })?.value
                as? SQLiteStoreConnection)
    }

    private func lowerLengthLimit() throws {
        let connection = try connection()
        connection.withLock { _ = sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, Self.limit) }
        let effective = connection.withLock { sqlite3_limit(connection.database, SQLITE_LIMIT_LENGTH, -1) }
        XCTAssertEqual(effective, Self.limit, "The lowered length limit must apply")
    }

    private func assertBindFailureRecorded(file: StaticString = #filePath, line: UInt = #line) throws {
        let connection = try connection()
        connection.withLock {
            XCTAssertTrue(connection.operationFailed, "The failed bind must be recorded", file: file, line: line)
            XCTAssertFalse(
                connection.failuresAreTransient, "SQLITE_TOOBIG is a lasting failure", file: file, line: line)
        }
    }

    /// The stored keys, read through a separate connection.
    private func storedKeys() throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle, "SELECT ifnull(queue_item_id, 'NULL') FROM manual_upload_settlement ORDER BY 1;", -1,
                &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            keys.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return keys
    }

    private func record(_ id: UploadQueueItemID = UUID()) -> UploadManualSettlementRecord {
        let url = directory.appendingPathComponent("photo.jpg")
        let descriptor = UploadResourceDescriptor(
            source: .file(url), fileURL: url, filename: "photo.jpg", fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1))
        return UploadManualSettlementRecord(
            queueItemID: id, ordinal: 0, descriptor: UploadResourceDescriptorSnapshot(descriptor),
            identity: UploadIdentity(
                correctedName: "photo.jpg", nameHash: "nh", sha1Hex: String(repeating: "ab", count: 20),
                sha1Digest: Data(repeating: 0xAB, count: 20), contentHash: "ch"),
            receipt: UploadRemoteCommitReceipt(remoteVolumeID: "vol", remoteLinkID: "link"),
            displayName: "photo.jpg", mediaType: "image/jpeg", byteCount: 1, resolvedAlbumID: nil,
            destination: UploadManualSettlementDestination(target: .library), stage: .manifestPending,
            updatedAt: Date(timeIntervalSince1970: 100))
    }

    func testReadOutcomeWithAKeyThatDoesNotBindIsUnreadable() throws {
        let saved = record()
        XCTAssertTrue(store.upsert(saved))
        try lowerLengthLimit()
        guard case .unreadable = store.readOutcome(for: saved.queueItemID) else {
            return XCTFail("A key that does not bind is no proof that the settlement row is absent")
        }
        try assertBindFailureRecorded()
    }

    func testRemoveWithAKeyThatDoesNotBindFailsAndKeepsTheRow() throws {
        let saved = record()
        XCTAssertTrue(store.upsert(saved))
        let before = try storedKeys()
        try lowerLengthLimit()
        XCTAssertFalse(
            store.remove(queueItemID: saved.queueItemID),
            "A key that does not bind removes nothing; that is no successful removal")
        XCTAssertEqual(try storedKeys(), before)
        try assertBindFailureRecorded()
    }

    /// A pin. A length fault cannot fail the key bind alone: the payload always exceeds the limit too, so its bind fails
    /// and the NOT NULL on `payload` refused this write before the fix as well. A key-only failure, such as SQLITE_NOMEM,
    /// stored a row under a NULL key, because `queue_item_id` allows NULL; the checked binds now refuse that write.
    func testUpsertWithAKeyThatDoesNotBindFailsAndStoresNoRow() throws {
        try lowerLengthLimit()
        XCTAssertFalse(store.upsert(record()))
        XCTAssertEqual(try storedKeys(), [], "No row may be stored under a NULL key")
        try assertBindFailureRecorded()
    }
}
