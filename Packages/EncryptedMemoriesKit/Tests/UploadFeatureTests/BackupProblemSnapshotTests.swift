import Foundation
import SQLite3
import XCTest

@testable import UploadCore

final class BackupProblemSnapshotTests: XCTestCase {
    func testAlbumSnapshotMergesOnlyRemoteDeletionSiblingsAndPreservesReportOrder() throws {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "album-photo")
        func item(_ revision: Int64, issue: BackupIssueKind, id: String) -> BackupFailedItem {
            .init(
                id: id, filename: "photo.heic", reason: "Reason", isPermanent: true,
                issue: issue, source: source, revision: .init(rawValue: revision))
        }
        let old = item(1, issue: .remoteDeletion, id: "trash-1")
        let newest = item(2, issue: .remoteDeletion, id: "trash-2")
        let incompleteOld = item(3, issue: .deletedElsewhere, id: "incomplete-3")
        let incompleteNew = item(4, issue: .deletedElsewhere, id: "incomplete-4")
        let snapshot = try XCTUnwrap(BackupProblemSnapshot.album(items: [old, incompleteOld, newest, incompleteNew]))
        XCTAssertEqual(snapshot.rows.map(\.item), [newest, incompleteOld, incompleteNew])
        XCTAssertEqual(
            snapshot.rows.first?.id,
            BackupProblemSnapshot.album(items: [item(5, issue: .remoteDeletion, id: "trash-5")])?.rows.first?.id)
    }

    func testAlbumSnapshotRejectsAmbiguousDuplicateItemIdentities() {
        let item = BackupFailedItem(id: "duplicate", filename: "photo", reason: "Reason", isPermanent: false)
        XCTAssertNil(BackupProblemSnapshot.album(items: [item, item]))
    }

    func testUnhealthyStoreNeverStartsAProblemCapture() throws {
        try withQueue { queue, _ in
            queue.close()
            var beganRead = false
            let captured = BackupProblemSnapshot.capture(in: queue) { event in
                if event == .willRead { beganRead = true }
            }
            XCTAssertNil(captured)
            XCTAssertFalse(beganRead, "Unavailable storage must refuse admission before starting a capture")
        }
    }

    func testGroupingKeepsTheSourceKindAndResourceNamespacesSeparate() {
        let sources: [UploadSourceIdentity] = [
            .init(kind: .photoLibraryAsset, identifier: "same-id"),
            .init(kind: .photoLibraryAsset, identifier: "same-id", resource: .livePairedVideo),
            .init(kind: .fileURL, identifier: "same-id"),
        ]
        let items = sources.enumerated().map { index, source in
            BackupFailedItem(
                id: "item-\(index)", filename: "photo.heic", reason: "Reason", isPermanent: true,
                issue: .deletedElsewhere, source: source, revision: .init(rawValue: Int64(index)))
        }
        let snapshot = BackupProblemSnapshot(items: items)
        XCTAssertEqual(snapshot.rows.map(\.item), items)
        XCTAssertEqual(Set(snapshot.rows.map(\.id)).count, sources.count)
        XCTAssertEqual(Set(BackupProblemPhotoSelection(items).revisionsBySource.keys), Set(sources))
    }

    #if DEBUG
        func testCompleteSnapshotHasOneCursorScanAndPagesNeverReadTheStore() throws {
            try withQueue { queue, _ in
                XCTAssertTrue(queue.upsertBatch((0..<1_000).map { entry($0) }))
                var statements = 0
                var steps = 0
                var rows = 0
                var healthProbes = 0
                queue.onProblemReadEvent = {
                    switch $0 {
                    case .statement: statements += 1
                    case .step: steps += 1
                    case .row: rows += 1
                    case .healthProbe: healthProbes += 1
                    default: break
                    }
                }
                let snapshot = try XCTUnwrap(BackupProblemSnapshot.backup(in: queue))
                XCTAssertEqual(statements, 1)
                XCTAssertEqual(steps, 1_001)
                XCTAssertEqual(rows, 1_000)
                XCTAssertEqual(healthProbes, 2)
                let observed = [statements, steps, rows, healthProbes]
                var page = try XCTUnwrap(snapshot.page())
                while let cursor = page.next { page = try XCTUnwrap(snapshot.page(after: cursor)) }
                XCTAssertEqual([statements, steps, rows, healthProbes], observed)
            }
        }
    #endif
    func testEveryPhotoIsReachableExactlyOnceAtOneThousandAndFiveThousand() throws {
        for count in [1_000, 5_000] {
            try withQueue { queue, _ in
                XCTAssertTrue(queue.upsertBatch((0..<count).map { entry($0) }))
                let snapshot = try XCTUnwrap(BackupProblemSnapshot.backup(in: queue))
                queue.close()
                var page = try XCTUnwrap(snapshot.page())
                var reached = page.rows
                while let cursor = page.next {
                    page = try XCTUnwrap(snapshot.page(after: cursor))
                    XCTAssertLessThanOrEqual(page.rows.count, 200)
                    reached += page.rows
                }
                XCTAssertEqual(reached.count, count)
                XCTAssertEqual(Set(reached.map(\.id)).count, count)
                XCTAssertTrue(
                    reached.map { $0.item.source?.identifier }.elementsEqual(
                        (0..<count).reversed().map { "photo-\($0)" }), "newest-first order reaches the entire group")
                XCTAssertEqual(reached.dropFirst(249).first?.item.source?.identifier, "photo-\(count - 250)")
            }
        }
    }

    func testOtherReasonsNeverHideDecisionsAndStayBounded() throws {
        try withQueue { queue, _ in
            XCTAssertTrue(queue.upsertBatch((0..<1_000).map { entry($0) }))
            XCTAssertTrue(queue.upsertBatch((10_000..<11_000).map { entry($0, issue: .permission) }))
            let snapshot = try XCTUnwrap(BackupProblemSnapshot.backup(in: queue))
            XCTAssertEqual(snapshot.rows.filter { $0.item.issue == .deletedElsewhere }.count, 1_000)
            XCTAssertEqual(snapshot.rows.filter { $0.item.issue != .deletedElsewhere }.count, 200)
        }
    }

    func testOnlyDeletionDecisionSiblingsMergeAndNewestDecisionKeepsStableIdentity() throws {
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "edited")
        func item(_ revision: Int64, issue: BackupIssueKind = .deletedElsewhere) -> BackupFailedItem {
            BackupFailedItem(
                id: "edited/\(revision)", filename: "edited.heic", reason: "Reason", isPermanent: true,
                issue: issue, source: source, revision: .init(rawValue: revision))
        }
        let first = BackupProblemSnapshot(items: [item(1), item(2), item(3, issue: .permission)])
        XCTAssertEqual(first.rows.count, 2)
        XCTAssertEqual(first.rows.first?.item.revision, .init(rawValue: 2))
        XCTAssertTrue(first.rows.contains { $0.item.issue == .permission })
        let newer = BackupProblemSnapshot(items: [item(4)])
        XCTAssertEqual(first.rows.first?.id, newer.rows.first?.id)
        let permanent = BackupProblemSnapshot(items: [item(5, issue: .permission), item(6, issue: .permission)])
        XCTAssertEqual(permanent.rows.count, 2, "other per-revision actions must not resurrect an older hidden row")
    }

    func testCursorFromAnotherSnapshotAndInvalidBoundsAreRejected() throws {
        let item = BackupFailedItem(id: "one", filename: "one", reason: "Reason", isPermanent: true)
        let first = BackupProblemSnapshot(items: [item])
        let other = BackupProblemSnapshot(items: [item])
        XCTAssertNil(first.page(after: .init(snapshotID: other.id, offset: 0)))
        XCTAssertNil(first.page(after: .init(snapshotID: first.id, offset: -1)))
        XCTAssertNil(first.page(after: .init(snapshotID: first.id, offset: 2)))
        XCTAssertNil(first.page(size: 0))
        XCTAssertEqual(first.page(size: Int.max)?.rows.count, 1)
    }

    func testPartialReadNeverPublishesItsValidPrefix() throws {
        try withQueue { queue, url in
            XCTAssertTrue(queue.upsertBatch([entry(2), entry(1)]))
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(
                sqlite3_exec(
                    db, "UPDATE backup_sync_queue SET source_kind='invalid' WHERE source_id='photo-1';", nil, nil, nil),
                SQLITE_OK)
            XCTAssertNil(BackupProblemSnapshot.backup(in: queue))
        }
    }

    private func entry(_ index: Int, issue: BackupIssueKind = .deletedElsewhere) -> UploadBackupSyncQueueEntry {
        .init(
            source: .init(kind: .photoLibraryAsset, identifier: "photo-\(index)"),
            revision: .init(rawValue: Int64(index)), originalFilename: "photo-\(index).heic",
            state: issue == .deletedElsewhere ? .failedPermanent : .failed,
            lastError: BackupIssueRecord(kind: issue, detail: "Reason").persistedValue,
            updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func withQueue(_ body: (UploadBackupSyncQueueManifestStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { queue.close() }
        try body(queue, url)
    }
}
