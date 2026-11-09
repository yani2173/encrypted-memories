import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

/// Every text bind of the upload identity manifest checks its result (#1194). A failed bind leaves its parameter NULL. An
/// unchecked link bind made `forgetRemoteLinks` and `rebindRemoteLinks` report success without changing any row, so a
/// trashed link stayed the backup proof of its photo. An unchecked nullable bind stored a record without its link.
final class UploadIdentityManifestBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 32
    private let longLink = String(repeating: "k", count: 40)

    private var directory: URL!
    private var store: UploadIdentityManifestStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(UploadIdentityManifestStore(url: databaseURL))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var databaseURL: URL { directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName) }

    private func connection() throws -> SQLiteStoreConnection { try storeConnection(store!) }

    private func lowerLengthLimit(to limit: Int32 = UploadIdentityManifestBindingFailureTests.limit) throws {
        lowerSQLiteLengthLimit(on: try connection(), to: limit)
    }

    private func assertBindFailureRecorded(file: StaticString = #filePath, line: UInt = #line) throws {
        assertRecordedBindFailure(on: try connection(), file: file, line: line)
    }

    /// Every stored row as `source_id/remote_link/outcome`, read through a separate connection.
    private func storedRows() throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                """
                SELECT source_id || '/' || ifnull(remote_link, 'NULL') || '/' || ifnull(outcome, 'NULL')
                FROM upload_identity ORDER BY 1;
                """, -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(String(cString: sqlite3_column_text(statement, 0))) }
        return rows
    }

    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "a")

    private func record(link: String?, modified: TimeInterval = 1) -> UploadIdentityRecord {
        UploadIdentityRecord(
            source: source, filename: "a.jpg", correctedName: "a.jpg", fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: modified), sha1Hex: "s", nameHash: "n", contentHash: "c",
            hashKeyEpoch: "e", remoteVolumeID: link == nil ? nil : "v", remoteLinkID: link,
            outcome: link == nil ? nil : "uploaded", updatedAt: Date(timeIntervalSince1970: 2))
    }

    func testForgetRemoteLinksWithALinkThatDoesNotBindFailsAndKeepsTheLink() throws {
        XCTAssertTrue(store.upsert(record(link: longLink)))
        let before = try storedRows()
        // The link fails to bind; the update itself then runs under the normal limit.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "UPDATE upload_identity SET remote_vol=NULL", after: nil,
            limit: Self.limit)
        defer { fault.remove() }
        XCTAssertFalse(
            store.forgetRemoteLinks([longLink], of: source),
            "A link that does not bind forgets nothing; the trashed link would stay the photo's backup proof")
        XCTAssertFalse(fault.stepped, "An update whose bind failed must not run")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testRebindRemoteLinksWithALinkThatDoesNotBindFailsAndMovesNothing() throws {
        XCTAssertTrue(store.upsert(record(link: longLink)))
        let before = try storedRows()
        // The link fails to bind; the update itself then runs under the normal limit.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "UPDATE upload_identity SET remote_link=?", after: nil,
            limit: Self.limit)
        defer { fault.remove() }
        XCTAssertFalse(
            store.rebindRemoteLinks(
                [UploadRemoteLinkMove(from: longLink, to: "kept", contentHash: "c")], hashKeyEpoch: "e"),
            "A link that does not bind moves nothing; the merge must not trash the copy the row still names")
        XCTAssertFalse(fault.stepped, "An update whose bind failed must not run")
        XCTAssertEqual(try storedRows(), before)
        try assertBindFailureRecorded()
    }

    func testUpsertWithALinkThatDoesNotBindFailsAndKeepsTheRow() throws {
        XCTAssertTrue(store.upsert(record(link: nil)))
        let before = try storedRows()
        // The link fails to bind; the write itself then runs under the normal limit.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "INSERT INTO upload_identity(", after: nil, limit: Self.limit)
        defer { fault.remove() }
        XCTAssertFalse(store.upsert(record(link: longLink)), "A link that does not bind must fail the write")
        XCTAssertFalse(fault.stepped, "A write whose bind failed must not run")
        XCTAssertEqual(try storedRows(), before, "The row must not change to a record without its link")
        try assertBindFailureRecorded()
    }

    func testRecordWithAnIdentifierLongerThanTheLimitIsNil() throws {
        let longSource = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: longLink)
        try lowerLengthLimit()
        XCTAssertNil(store.record(for: longSource))
        try assertBindFailureRecorded()
    }

    /// An epoch that does not bind counts nothing. That is no proof of a complete index without entries. The health
    /// statement itself does not prepare under a limit of 32, so this test lowers the limit only to 128 and binds a
    /// longer epoch.
    func testRemoteContentIndexHealthWithAnEpochThatDoesNotBindIsUnavailable() throws {
        try lowerLengthLimit(to: 128)
        XCTAssertEqual(
            store.remoteContentIndexHealth(hashKeyEpoch: String(repeating: "e", count: 300)), .unavailable)
        try assertBindFailureRecorded()
    }

    func testRemoteContentRecordsWithAnEpochThatDoesNotBindAreEmptyAndRecordTheFailure() throws {
        try lowerLengthLimit()
        XCTAssertEqual(store.remoteContentRecords(contentHash: "c", hashKeyEpoch: longLink, limit: 5), [])
        try assertBindFailureRecorded()
    }

    /// The conditional write after a remote check: the cached row names link L, the photo changed, and the check found
    /// L trashed. A read link that does not bind made `remote_link IS ?17` false, so the row kept `uploaded` with L and
    /// took the new size and date; the trashed link stayed the photo's backup proof.
    func testConditionalUpsertWithAReadLinkThatDoesNotBindFailsAndKeepsTheRow() throws {
        XCTAssertTrue(store.upsert(record(link: longLink)))
        let before = try storedRows()
        let beforeRecord = store.record(for: source)
        // Only the read link is longer than the limit; the write itself then runs under the normal limit.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "INSERT INTO upload_identity(", after: nil, limit: Self.limit)
        defer { fault.remove() }
        XCTAssertFalse(
            store.upsert(record(link: nil, modified: 5), keepingRemoteLinkChangedFrom: longLink),
            "A read link that does not bind must fail the write")
        XCTAssertFalse(fault.stepped, "A write whose bind failed must not run")
        fault.remove()
        XCTAssertEqual(try storedRows(), before)
        XCTAssertEqual(store.record(for: source), beforeRecord, "The row keeps its old date and size")
        try assertBindFailureRecorded()
    }

    private func proof(link: String, epoch: String) -> UploadRemoteAssetIndexRecord {
        UploadRemoteAssetIndexRecord(
            externalIdentity: UploadBackupExternalIdentity(
                identifier: "asset", revision: UploadBackupRevision(rawValue: 1)),
            resourceCount: 1, remoteLinkIDs: [link], hashKeyEpoch: epoch)
    }

    private func checkpoint(_ eventID: String) -> UploadRemoteContentIndexCheckpoint {
        UploadRemoteContentIndexCheckpoint(eventID: eventID, refreshedAt: Date(timeIntervalSince1970: 1))
    }

    /// An event removes link X. When X does not bind in the asset-proof delete, the proof that names X must stay and the
    /// checkpoint must not move past the event. Before, the delete matched nothing and the event committed, so the
    /// asset counted as backed up although its remote copy was gone.
    func testApplyChangesWithARemovedLinkThatDoesNotBindFailsAndKeepsTheProofAndTheCheckpoint() throws {
        // The asset-proof DELETE does not prepare under a limit of 32, so this test lowers the limit only to 256 and
        // removes a longer link.
        let link = String(repeating: "k", count: 1_000)
        let saved = proof(link: link, epoch: "e")
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [UploadRemoteContentIndexRecord(contentHash: "c", hashKeyEpoch: "e", remoteLinkID: link)],
                remoteAssetRecords: [saved], unresolvedIssues: [], hashKeyEpoch: "e", checkpoint: checkpoint("e1")))
        // The link binds in the content-index and unresolved-link deletes; it fails to bind only in the asset-proof
        // delete that follows them.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "AND links.remote_link=?",
            after: "DELETE FROM remote_content_unresolved WHERE key_epoch=? AND remote_link=?", limit: 256)
        defer { fault.remove() }
        XCTAssertFalse(
            store.applyRemoteContentIndexChanges(
                upserting: [], unresolvedIssues: [], removingRemoteLinkIDs: [link], hashKeyEpoch: "e",
                expectedEventID: "e1", checkpoint: checkpoint("e2")),
            "A removed link that does not bind must fail the event")
        XCTAssertTrue(fault.lowered, "The fault reached the asset-proof delete")
        XCTAssertFalse(fault.stepped, "A delete whose bind failed must not run")
        fault.remove()
        XCTAssertEqual(store.remoteContentIndexCheckpoint(hashKeyEpoch: "e")?.eventID, "e1")
        XCTAssertEqual(
            store.remoteAssetRecords(for: [saved.externalIdentity], hashKeyEpoch: "e")[saved.externalIdentity], saved)
        try assertBindFailureRecorded()
    }

    /// A rebuild deletes the asset proofs of its epoch before it writes the new ones. When the epoch does not bind in
    /// that delete, the rebuild must fail: stale proofs must never be reported under the rebuilt checkpoint.
    func testReplaceIndexWithAnEpochThatDoesNotBindInTheProofDeleteFailsAndKeepsTheOldCheckpoint() throws {
        let epoch = longLink
        let saved = proof(link: "x", epoch: epoch)
        XCTAssertTrue(
            store.replaceRemoteContentIndex(
                [], remoteAssetRecords: [saved], unresolvedIssues: [], hashKeyEpoch: epoch, checkpoint: checkpoint("e1")
            ))
        // The epoch binds in the earlier deletes; it fails to bind from the asset-proof deletes on.
        let fault = BindFailureUntilStep(
            on: try connection(), statement: "DELETE FROM remote_asset_index_link WHERE key_epoch=?;",
            after: "DELETE FROM remote_content_build_checkpoint WHERE key_epoch=?;", limit: Self.limit)
        defer { fault.remove() }
        XCTAssertFalse(
            store.replaceRemoteContentIndex(
                [], remoteAssetRecords: [], unresolvedIssues: [], hashKeyEpoch: epoch, checkpoint: checkpoint("e2")),
            "An epoch that does not bind must fail the rebuild")
        XCTAssertTrue(fault.lowered, "The fault reached the asset-proof delete")
        XCTAssertFalse(fault.stepped, "A delete whose bind failed must not run")
        fault.remove()
        XCTAssertEqual(store.remoteContentIndexCheckpoint(hashKeyEpoch: epoch)?.eventID, "e1")
        XCTAssertEqual(
            store.remoteAssetRecords(for: [saved.externalIdentity], hashKeyEpoch: epoch)[saved.externalIdentity], saved)
        try assertBindFailureRecorded()
    }
}
