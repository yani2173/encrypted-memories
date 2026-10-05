import Foundation
import PhotosCore
import XCTest

@testable import UploadCore

final class BackupQueueListTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    private func row(
        _ id: String, _ state: UploadBackupSyncQueueState, revision: Int64 = 7, updatedAfter seconds: TimeInterval = 0,
        resource: UploadSourceIdentity.Resource = .primary
    ) -> UploadBackupQueueRowState {
        UploadBackupQueueRowState(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: resource),
            revision: UploadBackupRevision(rawValue: revision),
            state: state,
            originalFilename: "\(id).heic",
            updatedAt: date.addingTimeInterval(seconds))
    }

    func testRunningWorkUploadsAndQueuedWorkWaits() {
        let list = BackupQueueList(
            rows: UploadBackupSyncQueueState.allCases.map { row($0.rawValue, $0) })

        XCTAssertEqual(
            Set(list.uploading.map(\.state)),
            [.checking, .hashing, .duplicateChecking, .uploading, .finalizing, .needsRemoteReconciliation])
        XCTAssertEqual(Set(list.waiting.map(\.state)), [.discovered, .queuedForUpload, .paused])
        XCTAssertEqual(list.waitingCount, 3)
        XCTAssertFalse(list.isEmpty)
    }

    func testProblemsAndSettledWorkStayOutOfTheQueue() {
        let outside: [UploadBackupSyncQueueState] = [
            .alreadyBackedUp, .completed, .skippedRemoteDeletion, .sourceMissing, .blockedByDraft, .failed,
            .failedPermanent, .dismissedFailure,
        ]
        let list = BackupQueueList(rows: outside.map { row($0.rawValue, $0) })

        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list, .empty)
        for state in outside { XCTAssertNil(BackupQueueList.phase(of: state), state.rawValue) }
    }

    func testWaitingFilesFollowTheBackupOrderAndTheLatestUploadIsOnTop() {
        let list = BackupQueueList(rows: [
            row("old", .discovered, revision: 1),
            row("new-late", .queuedForUpload, revision: 9, updatedAfter: 5),
            row("new-early", .queuedForUpload, revision: 9, updatedAfter: 1),
            row("started-first", .uploading, updatedAfter: 1),
            row("started-last", .hashing, updatedAfter: 8),
        ])

        XCTAssertEqual(list.waiting.map(\.filename), ["new-early.heic", "new-late.heic", "old.heic"])
        XCTAssertEqual(list.uploading.map(\.filename), ["started-last.heic", "started-first.heic"])
    }

    func testTheLimitShortensOnlyTheWaitingFilesAndCountsTheRest() {
        let waiting = (0..<5).map { row("w\($0)", .discovered, revision: Int64(10 - $0)) }
        let list = BackupQueueList(rows: waiting + [row("active", .uploading)], limit: 2)

        XCTAssertEqual(list.waiting.map(\.filename), ["w0.heic", "w1.heic"])
        XCTAssertEqual(list.waitingCount, 5)
        XCTAssertEqual(list.hiddenWaitingCount, 3)
        XCTAssertEqual(list.uploading.count, 1)
    }

    func testEachResourceOfAPhotoIsItsOwnRow() {
        let list = BackupQueueList(rows: [
            row("live", .uploading, resource: .primary),
            row("live", .queuedForUpload, resource: .livePairedVideo),
        ])

        XCTAssertEqual(list.uploading.count + list.waiting.count, 2)
        XCTAssertNotEqual(list.uploading.first?.id, list.waiting.first?.id)
    }

    func testEachRowPreviewsItsOwnPhoto() {
        let list = BackupQueueList(rows: [
            row("live", .uploading, resource: .primary),
            row("live", .queuedForUpload, resource: .livePairedVideo),
            row("other", .discovered, revision: 1),
        ])

        let live = PhotoUID(localPending: .photoLibrary, identifier: "live")
        XCTAssertEqual(list.uploading.map(\.previewUID), [live])
        XCTAssertEqual(
            list.waiting.map(\.previewUID), [live, PhotoUID(localPending: .photoLibrary, identifier: "other")],
            "the paired video of a Live Photo shows the photo itself")
    }

    func testEveryQueueStateHasItsOwnWording() {
        let preview = PhotoUID(localPending: .photoLibrary, identifier: "x")
        let queued = BackupQueueList.Item(id: "q", filename: "q", state: .queuedForUpload, previewUID: preview)
            .localizedState
        for state: UploadBackupSyncQueueState in [.checking, .hashing, .uploading, .finalizing, .paused] {
            let wording = BackupQueueList.Item(id: "x", filename: "x", state: state, previewUID: preview).localizedState
            XCTAssertFalse(wording.isEmpty, state.rawValue)
            XCTAssertNotEqual(wording, queued, state.rawValue)
        }
    }
}

final class BackupQueueWorkRowsTests: XCTestCase {
    private var directory: URL!
    private var queue: UploadBackupSyncQueueManifestStore!
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-queue-list-\(UUID().uuidString)", isDirectory: true)
        queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
    }

    override func tearDownWithError() throws {
        queue.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(
        _ id: String, _ state: UploadBackupSyncQueueState, lastError: String? = nil
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: .primary),
            revision: UploadBackupRevision(rawValue: 7),
            originalFilename: "\(id).heic",
            state: state,
            lastError: lastError,
            updatedAt: date)
    }

    func testQueueWorkLeavesProblemsToTheProblemList() {
        let issue = BackupIssueRecord(kind: .network, detail: "offline").persistedValue
        XCTAssertTrue(
            queue.upsertBatch([
                entry("waiting", .discovered),
                entry("queued", .queuedForUpload, lastError: "an earlier attempt without a record"),
                entry("uploading", .uploading),
                entry("paused", .paused),
                entry("network-wait", .discovered, lastError: issue),
                entry("network-queued", .queuedForUpload, lastError: issue),
                entry("failed", .failed, lastError: issue),
                entry("permanent", .failedPermanent),
                entry("draft", .blockedByDraft),
                entry("done", .completed),
            ]))

        XCTAssertEqual(
            Set(queue.queueWorkRows().map(\.source.identifier)), ["waiting", "queued", "uploading", "paused"])

        var problems: Set<String> = []
        queue.forEachProblemEntry { problems.insert($0.source.identifier); return true }
        XCTAssertTrue(
            problems.isDisjoint(with: queue.queueWorkRows().map(\.source.identifier)),
            "a photo appears in the queue or in the problem list, never in both")
        XCTAssertTrue(queue.isOperational())
    }
}
