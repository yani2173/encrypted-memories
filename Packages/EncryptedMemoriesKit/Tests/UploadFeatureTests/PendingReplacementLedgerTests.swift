import Foundation
import PhotosCore
import SQLite3
import XCTest

@testable import UploadCore

final class PendingReplacementLedgerTests: XCTestCase {
    private var directory: URL!
    private var store: PendingBackupManifestStore!
    private let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset", resource: .primary)
    private let revision = UploadBackupRevision(rawValue: 42)
    private let main = PhotoUID(volumeID: "vol", nodeID: "main")
    private let remote = PhotoUID(volumeID: "vol", nodeID: "new")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        store = try XCTUnwrap(
            PendingBackupManifestStore(
                url: directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)))
    }

    override func tearDownWithError() throws {
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func scalar(_ sql: String, db: OpaquePointer?) throws -> Int32 {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }

    func testReplacementActivityKeepsSchemaTwoAndReopensThroughTheExistingStore() throws {
        let recorder = PendingBackupEventRecorder(store: store)
        recorder.recordUploadEvidence(source: source, revision: revision, replaces: [main])
        recorder.recordHandoff(source: source, revision: revision, remote: remote, kind: .uploaded)
        recorder.settleUploadEvidence(source: source, revision: revision, retired: [main.nodeID])
        recorder.finish()
        store.close()
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(try scalar("SELECT value FROM pending_info WHERE key='schema';", db: db), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM pragma_table_info('upload_evidence');", db: db), 4)
        store = try XCTUnwrap(PendingBackupManifestStore(url: url))
        XCTAssertTrue(store.isOperational())
        XCTAssertEqual(store.evidenceRevisions(), [PendingSourceKey(source): [revision]])
        XCTAssertEqual(store.unacknowledgedHandoffs().first?.remote, remote)
    }

    func testRetriesAndSettlementCannotAddHistoricalOrRelatedLinks() {
        let recorder = PendingBackupEventRecorder(store: store)
        let historical = PhotoUID(volumeID: "vol", nodeID: "history")
        recorder.recordUploadEvidence(source: source, revision: revision, replaces: [main])
        recorder.recordUploadEvidence(source: source, revision: revision, replaces: [historical])
        recorder.recordHandoff(source: source, revision: revision, remote: remote, kind: .uploaded)
        recorder.settleUploadEvidence(
            source: source, revision: revision, retired: [main.nodeID, historical.nodeID, "video"])
        XCTAssertEqual(recorder.replacementLedger.replacementHandoffs().first?.evidence.replaces, [main])
        recorder.settleUploadEvidence(source: source, revision: revision, retired: [])
        recorder.recordUploadEvidence(source: source, revision: revision, replaces: [main])
        XCTAssertEqual(recorder.replacementLedger.replacementHandoffs().first?.evidence.replaces, [])
        recorder.finish()
    }

    func testRegistryRetainsRecordsAcrossRecorderRebuildAndSignOutClearsHeldReferences() throws {
        weak var retained: PendingReplacementLedger?
        do {
            let ledger = PendingReplacementLedger.shared(accountDataDirectory: directory)
            retained = ledger
            let recorder = PendingBackupEventRecorder(store: store, replacementLedger: ledger)
            recorder.recordUploadEvidence(source: source, revision: revision, replaces: [main])
            recorder.recordHandoff(source: source, revision: revision, remote: remote, kind: .uploaded)
            recorder.finish()
        }
        XCTAssertNotNil(retained, "the registry owns records after the recorder closes")
        let ledger = PendingReplacementLedger.shared(accountDataDirectory: directory)
        let rebuilt = PendingBackupEventRecorder(store: store, replacementLedger: ledger)
        XCTAssertEqual(rebuilt.replacementLedger.replacementHandoffs().first?.evidence.replaces, [main])
        PendingReplacementLedger.clearForSignOut(accountDataDirectory: directory)
        XCTAssertTrue(rebuilt.replacementLedger.replacementHandoffs().isEmpty)
        XCTAssertTrue(PendingReplacementLedger.shared(accountDataDirectory: directory).replacementHandoffs().isEmpty)
        rebuilt.finish()
    }

    func testSettlementWithClosedStoreCannotFailOrWriteStore() {
        let recorder = PendingBackupEventRecorder(store: store)
        recorder.recordUploadEvidence(source: source, revision: revision, replaces: [main])
        recorder.recordHandoff(source: source, revision: revision, remote: remote, kind: .uploaded)
        store.close()
        recorder.settleUploadEvidence(source: source, revision: revision, retired: [])
        XCTAssertEqual(recorder.replacementLedger.replacementHandoffs().first?.evidence.replaces, [])
        recorder.finish()
    }

    func testUneditedPhotoHasOneEvidenceEventAndSettlementMakesNoStoreWrite() async throws {
        let recorder = PendingBackupEventRecorder(store: store)
        let url = directory.appendingPathComponent(PendingBackupManifestStore.databaseFileName)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        recorder.recordUploadEvidence(source: source, revision: revision)
        recorder.recordHandoff(source: source, revision: revision, remote: remote, kind: .uploaded)
        let version = try scalar("PRAGMA data_version;", db: db)
        recorder.settleUploadEvidence(source: source, revision: revision, retired: [])
        XCTAssertEqual(try scalar("PRAGMA data_version;", db: db), version)
        XCTAssertTrue(recorder.replacementLedger.replacementHandoffs().isEmpty)
        recorder.finish()
        var evidenceCount = 0
        for await event in recorder.events {
            if case .evidence = event { evidenceCount += 1 }
        }
        XCTAssertEqual(evidenceCount, 1)
        XCTAssertEqual(store.evidenceRevisions(), [PendingSourceKey(source): [revision]])
    }

    func testUndoToAnEarlierRevisionAfterAcknowledgmentRecordsAgain() {
        let ledger = PendingReplacementLedger()
        let key = PendingSourceKey(source)
        let original = UploadBackupRevision(rawValue: revision.rawValue - 1)
        ledger.record(key, revision: revision, replaces: [main])
        ledger.drop([(key, revision)])
        XCTAssertNil(ledger.evidence(for: key, revision: revision))
        // Undo returns the asset to its earlier revision, and its upload replaces the edit.
        ledger.record(key, revision: original, replaces: [remote])
        XCTAssertEqual(ledger.evidence(for: key, revision: original)?.replaces, [remote])
    }

    func testRemovedAttemptIgnoresOnlyItsOwnRevisionUntilReadmitted() {
        let ledger = PendingReplacementLedger()
        let key = PendingSourceKey(source)
        let original = UploadBackupRevision(rawValue: revision.rawValue - 1)
        ledger.dropSources([(key, revision)])
        ledger.record(key, revision: revision, replaces: [main])
        XCTAssertNil(ledger.evidence(for: key, revision: revision), "a late callback of the removed attempt")
        ledger.record(key, revision: original, replaces: [main])
        XCTAssertNotNil(ledger.evidence(for: key, revision: original), "an undo is another revision")
        ledger.readmit(key)
        ledger.record(key, revision: revision, replaces: [main])
        XCTAssertNotNil(ledger.evidence(for: key, revision: revision), "a new attempt of the same revision")
    }
}
