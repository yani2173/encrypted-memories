import AlbumSyncCore
import Foundation
import PhotosCore
import XCTest

@testable import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Consumers of the backup queue decide only from complete reads (#1004 B2). Each case fails one SQLite statement
/// once through the real store.
final class QueueDecisionReadTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_720_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("queue-decision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeQueue(_ name: String = "queue.sqlite") throws -> UploadBackupSyncQueueManifestStore {
        try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent(name)))
    }

    private func row(
        _ id: String, state: UploadBackupSyncQueueState, revision: Int64 = 1, lastError: String? = nil,
        updatedAt: Date? = nil
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: revision),
            originalFilename: "\(id).heic", state: state, lastError: lastError, updatedAt: updatedAt ?? now)
    }

    private static let problemSQL = "WHERE state IN ('failed', 'failedPermanent', 'sourceMissing', 'blockedByDraft')"

    /// An unknown due date wakes the drain after a short wait instead of waiting for the next queue write.
    func testAnUnknownDueDateWakesTheDrainAfterThirtySeconds() throws {
        let queue = try makeQueue()
        defer { queue.close() }
        XCTAssertTrue(queue.upsert(row("later", state: .discovered, updatedAt: now.addingTimeInterval(3_600))))
        XCTAssertEqual(PhotoLibraryBackupController.nextDueDelay(in: queue, now: now), 3_600, "a healthy read")
        let fault = try SQLiteReadInterrupt(in: queue, matching: "SELECT MIN(updated_at) FROM backup_sync_queue")
        defer { fault.stop() }
        XCTAssertEqual(PhotoLibraryBackupController.nextDueDelay(in: queue, now: now), 30)
        XCTAssertTrue(fault.fired)
    }

    /// An unknown remote-index backoff keeps automatic passes waiting, as a known one does.
    func testAnUnknownRemoteIndexBackoffHoldsTheAutomaticPass() throws {
        let queue = try makeQueue()
        defer { queue.close() }
        XCTAssertFalse(PhotoLibraryBackupController.remoteIndexBackoffHoldsAutomaticPass(in: queue, now: now))
        let issue = BackupIssueRecord(kind: .remoteService, detail: "index", nextAttemptAt: now.addingTimeInterval(60))
        XCTAssertTrue(queue.setRuntimeIssue(issue, for: .remoteIndexPreparation))
        XCTAssertTrue(PhotoLibraryBackupController.remoteIndexBackoffHoldsAutomaticPass(in: queue, now: now))
        XCTAssertFalse(
            PhotoLibraryBackupController.remoteIndexBackoffHoldsAutomaticPass(
                in: queue, now: now.addingTimeInterval(61)))
        let fault = try SQLiteReadInterrupt(in: queue, matching: "SELECT value FROM backup_sync_runtime_issue")
        defer { fault.stop() }
        XCTAssertTrue(
            PhotoLibraryBackupController.remoteIndexBackoffHoldsAutomaticPass(in: queue, now: now),
            "an unread backoff still holds the automatic pass")
        XCTAssertTrue(fault.fired)
    }

    /// Dismissing a problem keeps its stored record when the read of that record fails. A missing photo needs the
    /// record to be checked again when its bytes return.
    #if DEBUG
        @MainActor
        func testAFailedRecordReadKeepsTheDismissedProblemUnchanged() async throws {
            let suite = "queue-decision-dismiss-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = PhotoLibraryBackupController(
                configuration: .init(
                    accountDataDirectory: directory, databasePolicy: .conservative, defaults: defaults),
                identityResolver: nil, uploader: MockUploader())
            let queue = try XCTUnwrap(controller.queueStoreForTesting)
            let missing = row(
                "missing", state: .sourceMissing,
                lastError: BackupIssueRecord(kind: .sourceMissing, detail: "gone").persistedValue)
            XCTAssertTrue(queue.upsert(missing))
            let item = try XCTUnwrap(controller.failedItems().first { $0.source == missing.source })
            XCTAssertTrue(item.isPermanent)
            // The dismissal reads the row twice: its own check, then the record that the dismissed row keeps.
            let fault = try SQLiteReadInterrupt(
                in: queue, matching: "SELECT original_filename, byte_count, state", occurrence: 2)
            controller.dismissFailedItem(item)
            fault.stop()
            XCTAssertTrue(fault.fired)
            let observer = try makeQueue(PhotoLibraryBackupController.queueDatabaseFileName)
            defer { observer.close() }
            XCTAssertEqual(try observer.entry(for: missing.source, revision: missing.revision), missing)
            await controller.shutdown()
        }
    #endif

    /// A problem list that a failed read cut short is no snapshot, also after the failure is forgotten.
    func testAPartialProblemReadYieldsNoSnapshotAfterRecovery() throws {
        let queue = try makeQueue()
        defer { queue.close() }
        for (index, id) in ["a", "b", "c"].enumerated() {
            XCTAssertTrue(
                queue.upsert(
                    row(
                        id, state: .failedPermanent, revision: Int64(index + 1),
                        lastError: BackupIssueRecord(kind: .deletedElsewhere, detail: "Removed").persistedValue)))
        }
        XCTAssertEqual(BackupProblemSnapshot.backup(in: queue)?.rows.count, 3)
        let fault = try SQLiteReadInterrupt(in: queue, matching: Self.problemSQL, afterRows: 2)
        defer { fault.stop() }
        XCTAssertNil(BackupProblemSnapshot.backup(in: queue), "a cut-short list must not become a bulk target")
        XCTAssertTrue(fault.fired)
    }

    /// The album report does not mistake a cut-short problem list for photos without a problem.
    func testAPartialProblemReadStopsTheAlbumReportAfterRecovery() throws {
        let queue = try makeQueue()
        defer { queue.close() }
        let ids = ["a", "b", "c"]
        for (index, id) in ids.enumerated() {
            XCTAssertTrue(
                queue.upsert(
                    row(
                        id, state: .failed, revision: Int64(index + 1),
                        lastError: BackupIssueRecord(kind: .permission, detail: "denied").persistedValue)))
        }
        XCTAssertEqual(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ids).problems.count, 3)
        let fault = try SQLiteReadInterrupt(in: queue, matching: Self.problemSQL, afterRows: 2)
        defer { fault.stop() }
        XCTAssertThrowsError(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ids)) {
            XCTAssertEqual($0 as? AlbumSyncError, .mappingStoreUnavailable)
        }
        XCTAssertTrue(fault.fired)
    }

    /// The album counts come from a complete read of the requested rows, not from a cut-short one.
    func testAPartialRowReadStopsTheAlbumReportAfterRecovery() throws {
        let queue = try makeQueue()
        defer { queue.close() }
        let ids = ["a", "b", "c"]
        for (index, id) in ids.enumerated() {
            XCTAssertTrue(queue.upsert(row(id, state: .completed, revision: Int64(index + 1))))
        }
        XCTAssertEqual(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ids).backedUp, 3)
        let fault = try SQLiteReadInterrupt(
            in: queue, matching: "SELECT source_kind, source_id, resource, revision_us, state, original_filename",
            occurrence: 2)
        defer { fault.stop() }
        XCTAssertThrowsError(try AlbumSyncBackupReport.read(from: queue, localIdentifiers: ids)) {
            XCTAssertEqual($0 as? AlbumSyncError, .mappingStoreUnavailable)
        }
        XCTAssertTrue(fault.fired)
    }
}
