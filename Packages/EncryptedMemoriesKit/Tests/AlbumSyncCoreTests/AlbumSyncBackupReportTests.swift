import Foundation
import PhotosCore
import SQLite3
import Testing
import UploadCore

@testable import AlbumSyncCore

@Suite struct AlbumSyncBackupReportTests {
    @Test func everyReportCountIncludesOnlyRequestedPhotoResources() throws {
        let queue = try #require(
            UploadBackupSyncQueueManifestStore(
                url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")))
        defer { queue.close() }
        let states: [UploadBackupSyncQueueState] = [
            .completed, .alreadyBackedUp, .failedPermanent,
            .sourceMissing, .skippedRemoteDeletion,
        ]
        for (index, state) in states.enumerated() {
            for source in [
                UploadSourceIdentity(
                    kind: .photoLibraryAsset, identifier: "photo",
                    resource: index == 0 ? .primary : .photoKit(role: "test", ordinal: index)),
                UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "other-\(index)"),
                UploadSourceIdentity(
                    kind: .fileURL, identifier: "photo",
                    resource: index == 0 ? .primary : .photoKit(role: "test", ordinal: index)),
            ] {
                #expect(
                    queue.upsert(
                        .init(
                            source: source, revision: .init(rawValue: 42),
                            originalFilename: "test.heic", state: state, updatedAt: Date())))
            }
        }
        let report = try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo", "photo"])
        #expect(report.total == 5)
        #expect(report.backedUp == 2)
        #expect(report.failed == 1)
        #expect(report.sourceMissing == 1)
        #expect(report.skippedRemoteDeletion == 1)
        #expect(Set(report.problems.keys) == ["photo"])
        let empty = try AlbumSyncBackupReport.read(from: queue, localIdentifiers: [])
        #expect(empty.total == 0)
        #expect(empty.backedUp == 0)
        #expect(empty.failed == 0)
        #expect(empty.sourceMissing == 0)
        #expect(empty.skippedRemoteDeletion == 0)
    }

    @Test func aFailedQueueReadNeverBecomesAnEmptySuccessfulReport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try #require(UploadBackupSyncQueueManifestStore(url: url))
        defer { queue.close() }
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(
            sqlite3_exec(handle, "ALTER TABLE backup_sync_queue RENAME TO unavailable_queue;", nil, nil, nil)
                == SQLITE_OK)
        #expect(queue.isOperational())
        #expect(throws: AlbumSyncError.mappingStoreUnavailable) {
            try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo"])
        }
    }

    @Test func linklessDeletionKeepsItsReasonAndExactQueueRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let queue = try #require(UploadBackupSyncQueueManifestStore(url: url))
        defer { queue.close() }
        let revision = UploadBackupRevision(rawValue: 42)
        #expect(
            queue.upsert(
                .init(
                    source: .init(kind: .photoLibraryAsset, identifier: "photo"), revision: revision,
                    originalFilename: "photo.heic", byteCount: 5, state: .skippedRemoteDeletion, attempts: 0,
                    updatedAt: Date())))
        let report = try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo"])
        #expect(report.skippedRemoteDeletion == 1)
        #expect(report.problems["photo"]?.issue == .remoteDeletion)
        #expect(report.problems["photo"]?.revision == revision)
        #expect(report.problems["photo"]?.isRetryable == false)
        #expect(report.filenames["photo"] == "photo.heic")
        let items = AlbumSyncProblemList.items(
            missingIdentifiers: ["photo"], attachFailedIdentifiers: [], backup: report)
        #expect(items.first?.reason == L10n.string("backup.state_skipped_remote_deletion"))
        queue.close()
        #expect(throws: AlbumSyncError.mappingStoreUnavailable) {
            try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ["photo"])
        }
    }
}
