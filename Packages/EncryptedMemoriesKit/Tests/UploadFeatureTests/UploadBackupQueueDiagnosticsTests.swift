import Foundation
import XCTest

@testable import UploadCore

/// The queue counts that the background log writes at the start of a backup pass.
final class UploadBackupQueueDiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadBackupQueueDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func row(
        _ id: String, _ state: UploadBackupSyncQueueState, lastError: String? = nil
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: id), revision: .init(rawValue: 1),
            originalFilename: "\(id).jpg", state: state, lastError: lastError,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testTheCountsHoldEachStateAndTheCheckReasons() throws {
        let store = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        defer { store.close() }
        let network = BackupIssueRecord(kind: .network, detail: "offline").persistedValue
        let missing = BackupIssueRecord(kind: .sourceMissing, detail: "gone").persistedValue
        XCTAssertTrue(
            store.upsertBatch([
                row("a", .discovered),
                row("b", .discovered, lastError: network),
                row("c", .discovered, lastError: "an older plain message"),
                row("d", .checking, lastError: missing),
                row("e", .queuedForUpload, lastError: network),
                row("f", .completed),
                row("g", .completed),
                row("h", .completed),
                row("i", .alreadyBackedUp),
                row("j", .skippedRemoteDeletion),
            ]))

        let counts = try XCTUnwrap(store.queueCounts())

        XCTAssertEqual(counts.rows[.discovered], 3)
        XCTAssertEqual(counts.rows[.checking], 1)
        XCTAssertEqual(counts.rows[.queuedForUpload], 1)
        XCTAssertEqual(counts.rows[.completed], 3)
        XCTAssertNil(counts.rows[.uploading], "a state without rows has no count")
        XCTAssertEqual(counts.checkReasons[.discovered], [.none: 1, .issue(.network): 1, .unrecognized: 1])
        XCTAssertEqual(counts.checkReasons[.checking], [.issue(.sourceMissing): 1])
        XCTAssertNil(counts.checkReasons[.queuedForUpload], "only the check states have a check reason")
        XCTAssertEqual(counts.rows[.alreadyBackedUp], 1)
        XCTAssertEqual(counts.rows[.skippedRemoteDeletion], 1)
    }

    func testTheCheckReasonIsTheKindOfTheRecordedIssue() {
        XCTAssertEqual(UploadBackupQueueDiagnostics.checkReason(lastError: nil), .none)
        XCTAssertEqual(UploadBackupQueueDiagnostics.checkReason(lastError: ""), .none)
        XCTAssertEqual(UploadBackupQueueDiagnostics.checkReason(lastError: "plain text"), .unrecognized)
        XCTAssertEqual(
            UploadBackupQueueDiagnostics.checkReason(
                lastError: BackupIssueRecord(kind: .remoteDraft, detail: "x").persistedValue),
            .issue(.remoteDraft))
    }
}
