import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

private actor SeededBackupLibrarySupportSource: LibrarySyncSupportSource {
    func librarySyncSupportSnapshot(now: Date) -> LibrarySyncSupportSnapshot? {
        LibrarySyncSupportSnapshot(
            lastSuccessfulLoad: .init(timestamp: now, sourcePath: .cache),
            lastFailedLoad: .init(timestamp: now, sourcePath: .authoritative, errorKind: .network),
            storedEventCursorAgeSeconds: 60, storedPhotoCount: 4, listedPhotoCount: 5,
            photosTrashedHereAwaitingLibrary: 1)
    }
}

final class BackupSupportDiagnosticsTests: XCTestCase {
    func testSeededStoresExportCountsWithoutPrivateContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = SupportDiagnosticsSources()
        let library = SeededBackupLibrarySupportSource()
        sources.registerLibrary(library)
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        defer { queue.close() }
        let journal = try XCTUnwrap(EditReplacementJournalFileStore(accountDataDirectory: directory))
        sources.registerQueue(queue, key: "private-store-path")
        sources.registerEditReplacements(journal, key: "private-journal-path")
        let now = Date()
        let privateValues = [
            "private-asset", "private-file.jpg", "/private/person/photo", "private-node", "private-volume",
            "Seed Person", "seed@example.invalid",
        ]
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: privateValues[0])
        let rows: [(UploadBackupSyncQueueState, UploadSourceIdentity.Resource, BackupIssueKind?)] = [
            (.discovered, .primary, nil),
            (.queuedForUpload, .livePairedVideo, .network),
            (.blockedByDraft, .photoKit(role: "fullSizePhoto", ordinal: 0), .remoteDraft),
            (.failedPermanent, .init(rawValue: privateValues[2]), .permission),
            (.needsRemoteReconciliation, .primary, .localState),
            (.failed, .primary, nil),
        ]
        for (index, row) in rows.enumerated() {
            let issue = row.2.map { BackupIssueRecord(kind: $0, detail: privateValues.joined(separator: " ")) }
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: UploadSourceIdentity(
                            kind: row.0 == .failed ? .fileURL : source.kind,
                            identifier: row.0 == .failed ? privateValues[2] : source.identifier,
                            resource: row.1),
                        revision: .init(rawValue: Int64(index)), originalFilename: privateValues[1],
                        state: row.0, lastError: row.0 == .failed ? privateValues[2] : issue?.persistedValue,
                        updatedAt: now)))
        }
        try journal.addSuperseded(PhotoUID(volumeID: privateValues[4], nodeID: privateValues[3]), for: source)
        try journal.addSuperseded(PhotoUID(volumeID: privateValues[4], nodeID: "private-retired"), for: source)
        try journal.settle(["private-retired"], related: ["private-related"], trashed: true, for: source)
        try journal.prepareToRetire([privateValues[3]: ["private-intent"]], for: source)

        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(report["librarySync"] as? [String: Any])
        let backup = try XCTUnwrap(report["backup"] as? [String: Any])
        let queues = try XCTUnwrap(backup["queues"] as? [[String: Any]])
        let snapshot = try XCTUnwrap(queues.first)
        XCTAssertEqual(snapshot["total"] as? Int, 6)
        XCTAssertEqual(snapshot["isAvailable"] as? Bool, true)
        let states = try XCTUnwrap(snapshot["countsByState"] as? [[String: Any]])
        XCTAssertEqual(states.first { $0["state"] as? String == "blockedByDraft" }?["count"] as? Int, 1)
        let resources = try XCTUnwrap(snapshot["countsByResourceKind"] as? [[String: Any]])
        XCTAssertEqual(resources.first { $0["resourceKind"] as? String == "primary" }?["count"] as? Int, 3)
        XCTAssertEqual(resources.first { $0["resourceKind"] as? String == "other" }?["count"] as? Int, 1)
        XCTAssertEqual(resources.first { $0["resourceKind"] as? String == "fullSizePhoto" }?["count"] as? Int, 1)
        let waiting = try XCTUnwrap(snapshot["waitingByReason"] as? [[String: Any]])
        XCTAssertEqual(waiting.first { $0["reason"] as? String == "network" }?["count"] as? Int, 1)
        XCTAssertEqual(waiting.first { $0["reason"] as? String == "unclassified" }?["count"] as? Int, 1)
        let parked = try XCTUnwrap(snapshot["parkedByReason"] as? [[String: Any]])
        XCTAssertEqual(parked.first { $0["reason"] as? String == "permission" }?["count"] as? Int, 1)
        let replacements = try XCTUnwrap(backup["editReplacements"] as? [[String: Any]])
        XCTAssertEqual(replacements.first?["sourcesWithSupersededEntries"] as? Int, 1)
        XCTAssertEqual(replacements.first?["totalSuperseded"] as? Int, 1)
        XCTAssertEqual(replacements.first?["totalRetired"] as? Int, 2)
        XCTAssertEqual(replacements.first?["rowsWithRetireIntent"] as? Int, 1)
        withExtendedLifetime(library) {}
        let text = String(decoding: data, as: UTF8.self)
        for value in privateValues + [
            "private-retired", "private-related", "private-intent", "private-store-path", "private-journal-path",
        ] {
            XCTAssertFalse(text.contains(value), value)
        }
    }

    func testDismissedSourceRechecksStayParkedWithoutChangingOrdinarySupportCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.sqlite")
        let trail = SupportEventTrail()
        var queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url, supportTrail: trail))
        defer { queue.close() }
        let privateValues = ["support-private-asset", "support-private-file.jpg", "/private/support/source"]
        let missing = BackupIssueRecord(kind: .sourceMissing, detail: privateValues.joined(separator: " "))
            .persistedValue
        let network = BackupIssueRecord(kind: .network, detail: privateValues[2]).persistedValue
        let permission = BackupIssueRecord(kind: .permission, detail: privateValues[2]).persistedValue
        let rows: [(UploadSourceIdentity.Kind, UploadBackupSyncQueueState, UploadSourceIdentity.Resource, String?)] = [
            (.photoLibraryAsset, .discovered, .primary, missing),
            (.photoLibraryAsset, .discovered, .primary, missing),
            (.photoLibraryAsset, .checking, .livePairedVideo, missing),
            (.photoLibraryAsset, .discovered, .primary, nil),
            (.photoLibraryAsset, .checking, .primary, nil),
            (.fileURL, .discovered, .primary, missing),
            (.fileURL, .checking, .livePairedVideo, missing),
            (.photoLibraryAsset, .failed, .primary, missing),
            (.photoLibraryAsset, .sourceMissing, .primary, missing),
            (.photoLibraryAsset, .dismissedFailure, .primary, missing),
            (.photoLibraryAsset, .discovered, .primary, network),
            (.photoLibraryAsset, .checking, .livePairedVideo, network),
            (.photoLibraryAsset, .queuedForUpload, .primary, missing),
            (.photoLibraryAsset, .failedPermanent, .init(rawValue: privateValues[2]), permission),
            (.photoLibraryAsset, .discovered, .primary, privateValues[2]),
        ]
        for (index, row) in rows.enumerated() {
            XCTAssertTrue(
                queue.upsert(
                    UploadBackupSyncQueueEntry(
                        source: .init(kind: row.0, identifier: "\(privateValues[0])-\(index)", resource: row.2),
                        revision: .init(rawValue: 1), originalFilename: privateValues[1], state: row.1,
                        lastError: row.3, updatedAt: Date(timeIntervalSince1970: 1_000))))
        }
        let snapshot = queue.backupSupportSnapshot()
        assertSupportSnapshot(
            snapshot, total: 15,
            states: [
                .dismissedFailure: 4, .discovered: 4, .checking: 3, .failed: 1, .sourceMissing: 1,
                .queuedForUpload: 1, .failedPermanent: 1,
            ],
            resources: [.primary: 11, .livePairedVideo: 3, .other: 1],
            waiting: [.none: 1, .sourceMissing: 3, .network: 1, .unclassified: 1],
            parked: [.sourceMissing: 5, .permission: 1])
        queue.close()
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url, supportTrail: trail))
        XCTAssertEqual(queue.backupSupportSnapshot(), snapshot)

        let sources = SupportDiagnosticsSources(trail: trail)
        sources.registerQueue(queue, key: privateValues[2])
        let data = try await SupportDiagnosticsExporter.makeJSONData(sources: sources, trail: trail)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let backup = try XCTUnwrap(report["backup"] as? [String: Any])
        let queues = try XCTUnwrap(backup["queues"] as? [[String: Any]])
        XCTAssertEqual(queues.count, 1)
        let exported = try JSONDecoder().decode(
            BackupQueueSupportSnapshot.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(queues.first)))
        XCTAssertEqual(exported, snapshot)
        let text = String(decoding: data, as: UTF8.self)
        for value in privateValues + [missing, network, permission] {
            XCTAssertFalse(text.contains(value), value)
        }
    }

    func testSupportDismissalSurvivesReopenClaimAndCrashRecoveryUntilSourceRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.sqlite")
        var queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { queue.close() }
        let now = Date(timeIntervalSince1970: 1_000)
        let missing = BackupIssueRecord(kind: .sourceMissing, detail: "support-private-detail").persistedValue
        var entry = UploadBackupSyncQueueEntry(
            source: .init(kind: .photoLibraryAsset, identifier: "support-private-asset"),
            revision: .init(rawValue: 1), originalFilename: "support-private-file.jpg", state: .dismissedFailure,
            lastError: missing, updatedAt: now)
        XCTAssertTrue(queue.upsert(entry))
        let dismissed = queue.backupSupportSnapshot()
        assertSupportSnapshot(
            dismissed, total: 1, states: [.dismissedFailure: 1], resources: [.primary: 1],
            waiting: [:], parked: [.sourceMissing: 1])

        entry.state = .discovered
        XCTAssertEqual(
            queue.updateDismissedSourceRecheck(entry, matchingState: .dismissedFailure, matchingLastError: missing),
            true)
        XCTAssertEqual(queue.backupSupportSnapshot(), dismissed)
        queue.close()
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(queue.backupSupportSnapshot(), dismissed)
        let claimed = try XCTUnwrap(
            queue.claimRunnable(limit: 1, claimedAt: now, excludingSourcesOf: []).first)
        XCTAssertEqual(claimed.state, .discovered)
        XCTAssertEqual(queue.entry(for: entry.source, revision: entry.revision)?.state, .checking)
        XCTAssertEqual(claimed.lastError, missing)
        XCTAssertEqual(queue.backupSupportSnapshot(), dismissed)
        queue.close()
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(queue.backupSupportSnapshot(), dismissed)
        XCTAssertEqual(queue.requeueStaleActive(before: now.addingTimeInterval(1), updatedAt: now), 1)
        XCTAssertEqual(queue.entry(for: entry.source, revision: entry.revision)?.state, .discovered)
        XCTAssertEqual(queue.backupSupportSnapshot(), dismissed)

        entry.state = .dismissedFailure
        XCTAssertEqual(
            queue.updateDismissedSourceRecheck(entry, matchingState: .discovered, matchingLastError: missing), true)
        XCTAssertEqual(queue.backupSupportSnapshot(), dismissed)
        entry.state = .discovered
        XCTAssertEqual(
            queue.updateDismissedSourceRecheck(entry, matchingState: .dismissedFailure, matchingLastError: missing),
            true)
        XCTAssertEqual(queue.claimRunnable(limit: 1, claimedAt: now, excludingSourcesOf: []).count, 1)
        entry.lastError = nil
        entry.byteCount = 10
        XCTAssertEqual(
            queue.updateDismissedSourceRecheck(entry, matchingState: .checking, matchingLastError: missing), true)
        assertSupportSnapshot(
            queue.backupSupportSnapshot(), total: 1, states: [.discovered: 1], resources: [.primary: 1],
            waiting: [.none: 1], parked: [:])
    }

    private func assertSupportSnapshot(
        _ snapshot: BackupQueueSupportSnapshot, total: Int,
        states: [BackupQueueSupportSnapshot.State: Int], resources: [BackupQueueSupportSnapshot.ResourceKind: Int],
        waiting: [BackupQueueSupportSnapshot.Reason: Int], parked: [BackupQueueSupportSnapshot.Reason: Int],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(snapshot.isAvailable, file: file, line: line)
        XCTAssertEqual(snapshot.total, total, file: file, line: line)
        XCTAssertEqual(
            snapshot.countsByState,
            BackupQueueSupportSnapshot.State.allCases.map { .init(state: $0, count: states[$0, default: 0]) },
            file: file, line: line)
        XCTAssertEqual(
            snapshot.countsByResourceKind,
            BackupQueueSupportSnapshot.ResourceKind.allCases.map {
                .init(resourceKind: $0, count: resources[$0, default: 0])
            },
            file: file, line: line)
        XCTAssertEqual(
            snapshot.waitingByReason,
            BackupQueueSupportSnapshot.Reason.allCases.map { .init(reason: $0, count: waiting[$0, default: 0]) },
            file: file, line: line)
        XCTAssertEqual(
            snapshot.parkedByReason,
            BackupQueueSupportSnapshot.Reason.allCases.map { .init(reason: $0, count: parked[$0, default: 0]) },
            file: file, line: line)
    }

    func testOpenQueueWithRecordedDecodeFailureReturnsUnavailableSupportSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.sqlite")
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        defer { queue.close() }
        let entry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "kept"),
            revision: UploadBackupRevision(rawValue: 10), originalFilename: "photo.heic",
            updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(queue.upsert(entry))
        XCTAssertTrue(queue.isOperational())
        XCTAssertTrue(queue.backupSupportSnapshot().isAvailable)
        XCTAssertEqual(queue.backupSupportSnapshot().total, 1)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "UPDATE backup_sync_queue SET remote_commit_reconciliation=X'7B';", nil, nil, nil),
            SQLITE_OK)

        XCTAssertNil(queue.entry(for: entry.source, revision: entry.revision))
        XCTAssertFalse(queue.isOperational())
        XCTAssertEqual(queue.backupSupportSnapshot(), BackupQueueSupportSnapshot())
        XCTAssertTrue(queue.upsert(entry), "the handle remains open after the recorded failure")
        XCTAssertEqual(queue.entry(for: entry.source, revision: entry.revision), entry)
        XCTAssertFalse(queue.isOperational(), "successful SQL cannot clear recorded failure")
        XCTAssertEqual(queue.backupSupportSnapshot(), BackupQueueSupportSnapshot())
    }

    func testClosedQueueIsUnavailableInsteadOfEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(url: directory.appendingPathComponent("queue.sqlite")))
        queue.close()
        XCTAssertFalse(queue.backupSupportSnapshot().isAvailable)
    }

    func testQueueTransitionsThatEndOrStopARowEnterTheTrailWithoutTheirErrorText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trail = SupportEventTrail()
        let queue = try XCTUnwrap(
            UploadBackupSyncQueueManifestStore(
                url: directory.appendingPathComponent("queue.sqlite"), supportTrail: trail))
        defer { queue.close() }
        let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "private-asset")
        let revision = UploadBackupRevision(rawValue: 1)
        let now = Date()
        XCTAssertTrue(
            queue.upsert(
                UploadBackupSyncQueueEntry(
                    source: source, revision: revision, originalFilename: "private-file.jpg", state: .discovered,
                    updatedAt: now)))
        let issue = BackupIssueRecord(kind: .accountStorage, detail: "private-file.jpg is too large").persistedValue
        for (state, error) in [
            (UploadBackupSyncQueueState.uploading, nil), (.failedPermanent, issue), (.queuedForUpload, nil),
            (.completed, nil),
        ] as [(UploadBackupSyncQueueState, String?)] {
            XCTAssertTrue(
                queue.updateState(
                    source: source, revision: revision, state: state, attempts: nil, lastError: error, updatedAt: now))
        }
        let hasher = SupportReportIdentifierHasher()
        let events = trail.export(hashingWith: hasher).events
        XCTAssertEqual(events.map(\.kind), [.backupRowParked, .backupRowCompleted])
        XCTAssertEqual(events.map(\.reason), [.accountStorage, BackupQueueSupportSnapshot.Reason.none])
        XCTAssertEqual(events.map(\.subject), [hasher.hash("private-asset"), hasher.hash("private-asset")])
        XCTAssertEqual(events.first?.resourceKind, .primary)
    }

    func testEveryEditOutcomeHasItsOwnTrailEvent() {
        XCTAssertEqual(BackupSyncRunner.supportEventKind(of: .replaced(retiredAny: true)), .editReplaced)
        XCTAssertEqual(BackupSyncRunner.supportEventKind(of: .waiting), .editWaiting)
        XCTAssertEqual(BackupSyncRunner.supportEventKind(of: .kept), .editKept)
        XCTAssertEqual(BackupSyncRunner.supportEventKind(of: .replacementGone), .editReplacementGone)
    }
}
